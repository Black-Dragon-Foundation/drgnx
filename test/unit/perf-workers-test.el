;;; perf-workers-test.el --- batch tests: the perf lab's worker rows (DRGNX_PERF_WORKERS, report-only rows, completion metrics, digests, phases, the 2-core shape) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-perf-run)
(require 'drgnx-paths)
(require 'drgnx-timer)

;; special here too: `features' is not special in Emacs (fns.c), so a `let' of it needs the declaration
(defvar features)

(defun perf-workers-test--applied (value)
  "What `nidhogg-workers-apply' receives when $DRGNX_PERF_WORKERS is VALUE (nil: unset), as the lab applies it."
  (let ((process-environment (if value (cons (concat "DRGNX_PERF_WORKERS=" value) process-environment)
                               (cons "DRGNX_PERF_WORKERS" process-environment)))
        (features (cons 'nidhogg-workers features))
        (drgnx-perf--workers-applied nil) got)
    (cl-letf (((symbol-function 'nidhogg-workers-apply) (lambda (spec) (push spec got))))
      (drgnx-perf--workers-env)
      (drgnx-perf--workers-env))                ; once per session
    got))

(ert-deftest drgnx-perf-workers/env-maps-to-apply ()
  (should (equal (perf-workers-test--applied "off") '("off")))
  (should (equal (perf-workers-test--applied "on") '("on")))
  (should (equal (perf-workers-test--applied "+nidhogg-workers-treesit+nidhogg-treesit-defer")
                 '("+nidhogg-workers-treesit+nidhogg-treesit-defer")))
  (should (equal (perf-workers-test--applied nil) '("default")))
  ;; without the feature: nothing is applied, and the probe says so
  (let ((features (remq 'nidhogg-workers features)) (drgnx-perf--workers-applied nil))
    (should-not (drgnx-perf--workers-env))
    (should (equal (drgnx-perf--workers-end) '(:workers nil)))))

(defvar perf-workers-test--order nil "What the session did, newest first: (apply SPEC) and (setup).")

(ert-deftest drgnx-perf-workers/switch-applied-before-the-setup ()
  "A workload's `:setup' runs with $DRGNX_PERF_WORKERS applied.  lsp-burst's setup opens its jsonrpc connections,
and Nidhogg frames a connection only if the switch is on when it opens: with the switch applied at the first
recording, the first workload of a session ran unframed in both arms of an A/B.  Pattern D: the session is this
Emacs (each form is read and evaluated here), `nidhogg-workers-apply' records."
  (let ((process-environment (cons "DRGNX_PERF_WORKERS=+nidhogg-workers-framing" process-environment))
        (features (cons 'nidhogg-workers features))
        (drgnx-perf--workers-applied nil)
        (perf-workers-test--order nil))
    (cl-letf (((symbol-function 'nidhogg-workers-apply) (lambda (spec) (push (list 'apply spec) perf-workers-test--order)))
              ((symbol-function 'drgnx-ui-call) (lambda (_sess form &optional _timeout) (eval (read form) t)))
              ((symbol-function 'drgnx-uitest--json) #'identity)
              ((symbol-function 'drgnx-ui-measure) #'ignore))
      (drgnx-perf-run-workload 'sess '(:setup "(progn (push '(setup) perf-workers-test--order) t)"
                                              :measure "(list :x 1)" :repeat 1)))
    (should (equal (reverse perf-workers-test--order) '((apply "+nidhogg-workers-framing") (setup))))))

(ert-deftest drgnx-perf-workers/agent-stream-has-a-turn-for-every-run ()
  "The mock agent runs the n-th line of its script for the n-th prompt, and a prompt past the last line runs its own
words (a two-chunk turn that ends at once, so the run's check, typed while it streamed, fails).  One mock serves a
setup's runs: in an A/A both sides' warm-ups and rounds, `drgnx-perf-ab-min-rounds' each.  Pattern D: the setup form."
  (let* ((spec (cdr (assq 'agent-stream (drgnx-perf-run--workloads))))
         (setup (plist-get spec :setup)))
    (should (string-match "(make-list \\([0-9]+\\) (drgnx-perf--stream))" setup))
    (should (>= (string-to-number (match-string 1 setup)) (* 2 (1+ drgnx-perf-ab-min-rounds))))))

(ert-deftest drgnx-perf-workers/worker-wait-is-judged ()
  ;; Nidhogg's phase-ms: symbol keys, worker-wait by reason.  The probe gives numbers only (worker-wait's total and
  ;; each reason), :wait-ms sums treesit-wait and worker-wait, and the A/B judges worker-wait like a phase
  (let ((features (cons 'nidhogg-workers features)))
    (cl-letf (((symbol-function 'nidhogg-workers-stats)
               (lambda (&rest _) (list :phase-ms (list 'image 5.6 'treesit-wait 2.0
                                                       'worker-wait (list 'display 200.25 'image-pixels 3.0 'drain 0.0))
                                       :deferrals (list 'treesit 0 'image 1)))))
      (let ((w (plist-get (drgnx-perf--workers-end) :workers)))
        (should (equal (plist-get w :phase-ms)
                       (list 'image (drgnx-perf--round 5.6) 'treesit-wait (drgnx-perf--round 2.0)
                             'worker-wait (drgnx-perf--round 203.25) 'worker-wait-display (drgnx-perf--round 200.25)
                             'worker-wait-image-pixels (drgnx-perf--round 3.0) 'worker-wait-drain (drgnx-perf--round 0.0)
                             ;; image + its waits (display, image-pixels), each rounded first
                             'image-with-waits (drgnx-perf--round (+ 5.6 (drgnx-perf--round 200.25) 3.0)))))
        (should (equal (plist-get w :wait-ms) (drgnx-perf--round 205.25)))))
    ;; treesit-with-waits: the synchronous parses plus the waits for nh-parse
    (cl-letf (((symbol-function 'nidhogg-workers-stats)
               (lambda (&rest _) (list :phase-ms (list 'treesit 40.5 'treesit-wait 12.25)))))
      (should (equal (plist-get (plist-get (plist-get (drgnx-perf--workers-end) :workers) :phase-ms) 'treesit-with-waits)
                     (drgnx-perf--round (+ 40.5 (drgnx-perf--round 12.25)))))))   ; each rounded first
  ;; a phase explains, it does not decide: no verdict for it, a line in the explain block
  (let* ((run (lambda (wait) (list :workers (list :phase-ms (list 'image 1.0 'worker-wait wait)) :input (list :p95 4.0))))
         (rounds (cl-loop for i below 8 collect (list :a (funcall run 0.0) :b (funcall run (+ 200.0 i)))))
         (vs (drgnx-perf-ab-metric-verdicts rounds)))
    (should-not (assoc '(:workers :phase-ms worker-wait) vs))
    (should (equal (assq 'worker-wait (drgnx-perf-ab-phase-explain (funcall run 0.0) (funcall run 200.0)))
                   '(worker-wait 0.0 200.0)))))

(ert-deftest drgnx-perf-workers/report-only-row ()
  (let ((results '((typing :alloc (:p50 20))))
        (budgets '((typing (:alloc :p50) 10 :report-only ot2))))
    (let ((process-environment (cons "DRGNX_PERF_LANDED" process-environment)))
      (should-not (drgnx-perf-verdict results budgets))
      (should (string-match-p "report" (car (drgnx-perf-report results budgets)))))
    (let ((process-environment (cons "DRGNX_PERF_LANDED=ot2" process-environment)))
      (should (string-match-p "typing alloc p50 20 > 10" (car (drgnx-perf-verdict results budgets))))
      (should-not (drgnx-perf-report results budgets)))
    ;; another step landing does not promote it
    (let ((process-environment (cons "DRGNX_PERF_LANDED=ot1,ot3" process-environment)))
      (should-not (drgnx-perf-verdict results budgets)))))

(ert-deftest drgnx-perf-workers/completion-metric ()
  (let ((now 100.0) (done nil) (drgnx-perf--complete nil))
    (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () now))
              ((symbol-function 'drgnx-timer-start) #'ignore)
              ((symbol-function 'drgnx-timer-cancel) #'ignore))
      (drgnx-perf-complete-begin (lambda () done))
      (setq now 100.05)
      (drgnx-perf-complete-poll)
      (should-not (nth 2 drgnx-perf--complete))
      (setq now 100.12 done t)
      (drgnx-perf-complete-poll)
      (setq now 101.0)                  ; later polls do not move it
      (drgnx-perf-complete-poll)
      (should (equal (drgnx-perf-complete-end) '(:complete-ms 120.0))))
    (should-not drgnx-perf--complete)
    ;; never complete: nil
    (cl-letf (((symbol-function 'drgnx-timer-start) #'ignore)
              ((symbol-function 'drgnx-timer-cancel) #'ignore))
      (drgnx-perf-complete-begin (lambda () nil))
      (should (equal (drgnx-perf-complete-end) '(:complete-ms nil))))))

(ert-deftest drgnx-perf-workers/extras-await-completion ()
  "The lab reads `:complete-ms' and the digest only once the work is done (or after the wait), not when the keys end."
  (let ((polls 0) sent)
    (cl-letf (((symbol-function 'drgnx-perf-run--call)
               (lambda (_sess form &optional _timeout)
                 (push form sent)
                 (cond ((string-match-p "(nth 2 drgnx-perf--complete)" form) (>= (cl-incf polls) 3))
                       ((string-match-p "drgnx-perf-complete-end" form) '(:complete-ms 2500.0))
                       (t '(:digest "d")))))
              ((symbol-function 'sleep-for) #'ignore))
      (should (equal (drgnx-perf-run--extras 'sess '(:complete-when "(done)" :digest "(digest)"))
                     '(:complete-ms 2500.0 :digest "d")))
      (should (= polls 3))
      (should (string-match-p "drgnx-perf-complete-end" (nth 1 sent)))   ; after the last poll, before the digest
      ;; no completion form: no wait
      (setq polls 0 sent nil)
      (drgnx-perf-run--extras 'sess '(:digest "(digest)"))
      (should (= polls 0)))))

(defun perf-workers-test--rounds (a b)
  "ROUNDS where the A side's runs are the plists A and B's the plists B (ten rounds)."
  (cl-loop repeat 10 collect (list :a a :b b)))

(ert-deftest drgnx-perf-workers/digest-mismatch-fails-ab ()
  (should (equal (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "y")))
                 '(:verdict regressed :why digest)))
  (should (eq (plist-get (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "x"))) :verdict)
              'no-regression))
  (should (eq (plist-get (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:input nil) '(:input nil))) :verdict)
              'not-comparable))
  (let ((line (drgnx-perf-ab--extra-lines
               (list :digest-verdict (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "y")))))))
    (should (string-match-p "regressed (digest)" line))))

(ert-deftest drgnx-perf-workers/cal-rows-registered ()
  (should (equal (mapcar #'car drgnx-perf-cal-rows) '(cal-costs cal-pressure cal-pty)))
  ;; every row reads workloads the lab has
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (row drgnx-perf-cal-rows)
      (dolist (w (plist-get (cdr row) :workloads)) (should (assq w ws)))))
  ;; the rows with a timers flag record the timers' ms per command
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (w '(terminal-output compile-flood lsp-burst lsp-typing)) (should (plist-get (cdr (assq w ws)) :timers))))
  (should (string-match-p "(drgnx-perf-begin t)" (drgnx-perf-run--begin-form '(:timers t))))
  (should-not (string-match-p "(drgnx-perf-begin t)" (drgnx-perf-run--begin-form '(:actions nil))))
  ;; a key the Nidhogg build lacks prints n/a; one it has prints its value; a workload that did not run has no line
  (let ((lines (drgnx-perf-cal-lines '((ts-open :cal (:costs (:parse 3)))
                                       (terminal-output :cal (:ahead (:p50 4096 :max 16384)))
                                       (live-view :error "x")))))
    (should (member "cal-costs ts-open: costs (:parse 3), decisions n/a (Task 55/57), policy n/a (Task 55/57)" lines))
    (should (member "cal-pty terminal-output: ahead (:p50 4096 :max 16384)" lines))
    (should (= (length lines) 2))))

(ert-deftest drgnx-perf-workers/cpus-cpuset ()
  ;; a 7900X numbers the cores first (CPU n and n + 12 share a core); a 4900HS puts a core's threads side by side
  (let ((desktop (mapcar (lambda (c) (cons c (% c 12))) (number-sequence 0 23)))
        (laptop (mapcar (lambda (c) (cons c (/ c 2))) (number-sequence 0 15))))
    (should (equal (drgnx-perf-cpuset-args "2" desktop) '("--cpuset-cpus" "0,1")))
    (should (equal (drgnx-perf-cpuset-args "4" desktop) '("--cpuset-cpus" "0,1,2,3")))
    (should (equal (drgnx-perf-cpuset-args "2" laptop) '("--cpuset-cpus" "0,2")))
    (should (equal (drgnx-perf-cpuset-args "4" laptop) '("--cpuset-cpus" "0,2,4,6")))
    ;; too few cores to pick from: the old range
    (should (equal (drgnx-perf-cpuset-args "4" '((0 . 0) (1 . 1))) '("--cpuset-cpus" "0-3"))))
  (should-not (drgnx-perf-cpuset-args nil))
  (should-error (drgnx-perf-cpuset-args "3"))
  ;; the container runner picks the cores the same way
  (let ((text (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string))))
    (should (string-match-p "lscpu -p=CPU,CORE" text))
    (should (string-match-p "--cpuset-cpus \"\\${cpus:-0-" text))))

;;;; Task 8: the workloads of §17.6

(ert-deftest drgnx-perf-workers/workloads-registered ()
  "Every workload of the design's table is a workload with a budget row that is report-only for a step, a completion
form and a digest, and a setup form that reads."
  (let ((ws (drgnx-perf-run--workloads)) (budgets (drgnx-perf-run--budgets)))
    (dolist (n '(lsp-burst lsp-typing ts-open ts-paste ts-typing ts-typing-unclosed compile-flood image-open
                           explorer-expand explorer-git quick-open-large quick-open-typing quick-open-typing-old
                           agents-line-motion agents-line-motion-old autosave-typing))
      (let ((spec (cdr (assq n ws))) (rows (seq-filter (lambda (b) (eq (car b) n)) budgets)))
        (should spec)
        (should (stringp (plist-get spec :complete-when)))
        (should (stringp (plist-get spec :digest)))
        (should (consp (read (plist-get spec :setup))))
        (should (plist-get spec :actions))
        (should rows)
        (dolist (r rows)
          (should (plist-get (nthcdr 3 r) :report-only))
          (should (memq (plist-get (nthcdr 3 r) :report-only) '(ot2 ot3 ot4 ot5 ot6 ot8))))))
    ;; the existing workloads are still there, unchanged in kind
    (dolist (n '(agent-stream terminal-output live-view)) (should (assq n ws)))))

;;;; Task 8 fixes: the workloads' own correctness

(defun perf-workers-test--session ()
  (load (expand-file-name "test/fixtures/workers/perf-session.el" drgnx-dir) nil t))

(ert-deftest drgnx-perf-workers/ts-paste-has-enough-commands-for-p95 ()
  "ts-paste keeps its input p95 row: the three repeats give the 100 samples a p95 needs."
  (let* ((acts (plist-get (cdr (assq 'ts-paste (drgnx-perf-run--workloads))) :actions))
         (n (apply #'+ (mapcar (lambda (a) (if (plist-get a :type) (length (plist-get a :type)) 1)) acts))))
    (should (>= (* 3 n) 100))))

(ert-deftest drgnx-perf-workers/image-count-includes-first-picture ()
  "The preview's picture at `point-min' counts (shr starts the first paragraph there)."
  (perf-workers-test--session)
  (with-temp-buffer
    (dotimes (_ 3)
      (insert (propertize " " 'display (list 'image :type 'png :file "x.png")))
      (insert "\n"))
    (should (= (drgnx-perf-w--count-images (current-buffer)) 3))
    ;; two pictures in a row, no text between
    (erase-buffer)
    (insert (propertize " " 'display (list 'image :type 'png :file "a.png")))
    (insert (propertize " " 'display (list 'image :type 'png :file "b.png")))
    (should (= (drgnx-perf-w--count-images (current-buffer)) 2))))

(ert-deftest drgnx-perf-workers/ts-edit-each-restarts-from-the-file ()
  "A repeat does not inherit the buffer the last repeat edited: same size at the start, not modified."
  (perf-workers-test--session)
  (unwind-protect
      ;; the visit without the grammar check: what is under test is which buffer the repeat starts from
      (cl-letf (((symbol-function 'drgnx-perf-w--ts-visit)
                 (lambda (file _mode &optional _window)
                   (let ((buf (find-file-noselect file))) (set-window-buffer (selected-window) buf) buf))))
        (drgnx-perf-w-ts-setup '(1))
        (let ((modes-before (list electric-pair-mode show-paren-mode which-function-mode)) base)
          (drgnx-perf-w-ts-edit-each)
          (setq base drgnx-perf-w--ts-base)
          (with-current-buffer (window-buffer) (insert (make-string 5000 ?x)))
          (should (= (buffer-size (window-buffer)) (+ base 5000)))
          (drgnx-perf-w-ts-edit-each)
          (should (= (buffer-size (window-buffer)) base))
          (should (= drgnx-perf-w--ts-base base))
          (should-not (buffer-modified-p (window-buffer)))
          (drgnx-perf-w-ts-edit-teardown)
          (should (equal modes-before (list electric-pair-mode show-paren-mode which-function-mode)))))
    (drgnx-perf-w-ts-open-teardown)))

(defvar nidhogg-workers-treesit--pending)
(defvar jit-lock-context-unfontify-pos)

(ert-deftest drgnx-perf-workers/ts-digest-waits-for-settled-colour ()
  "ts-typing completes, and so reads its digest, only once every key's command ran and the colour has settled: no
parse job and no deferred region for the buffer, and jit-lock's contextual refontification after the last key done."
  (perf-workers-test--session)
  (let ((buf (generate-new-buffer " perf-ts-settle")) busy (drgnx-perf-w--ts-commands 0))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (insert "int x;\n")
            (cl-letf (((symbol-function 'drgnx-perf-w--colored-p) (lambda (&optional _window) t))
                      ((symbol-function 'nidhogg-workers--treesit-busy-p) (lambda (_buffer) busy)))
              (setq-local jit-lock-context-unfontify-pos (point-max))
              ;; coloured before the keys (the lab polls from before them): not done until all 3 have run
              (should-not (drgnx-perf-w-ts-edit-done 3))
              (dotimes (_ 3) (drgnx-perf-w--ts-count-command))
              (should (drgnx-perf-w-ts-edit-done 3))
              ;; a parse job runs for the buffer
              (setq busy t)
              (should-not (drgnx-perf-w-ts-edit-done 3))
              (setq busy nil)
              ;; a region waits for the parse (deferral)
              (setq-local nidhogg-workers-treesit--pending (list (cons 1 2)))
              (should-not (drgnx-perf-w-ts-edit-done 3))
              (setq-local nidhogg-workers-treesit--pending nil)
              ;; jit-lock has not refontified after the last edit yet; reading does not do it for jit-lock
              (setq-local jit-lock-context-unfontify-pos 3)
              (should-not (drgnx-perf-w-ts-edit-done 3))
              (should (= jit-lock-context-unfontify-pos 3))
              (setq-local jit-lock-context-unfontify-pos (point-max))
              (should (drgnx-perf-w-ts-edit-done 3))
              (setq-local jit-lock-context-unfontify-pos nil)
              (should (drgnx-perf-w-ts-edit-done 3)))))
      (kill-buffer buf))))

(ert-deftest drgnx-perf-workers/ts-open-digest-waits-for-deferred-chunk ()
  "ts-open takes its digest only once the window's colour has settled: while a deferred chunk still waits for its
parse the window shows colour (first-colour latency is recorded) but no digest is taken; after the landing it is."
  (perf-workers-test--session)
  (let ((buf (generate-new-buffer " perf-ts-open")) (timers 0)
        (drgnx-perf-w--ts-digests nil) (drgnx-perf-w--stats nil) (drgnx-perf-w--ts-queue nil))
    (unwind-protect
        (save-window-excursion
          (setq drgnx-perf-w--other-window (selected-window))
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (insert "int x;\n")
            (setq-local jit-lock-context-unfontify-pos (point-max))
            ;; a chunk deferred and still plain: it counts as fontified
            (setq-local nidhogg-workers-treesit--pending (list (cons 1 2))))
          (cl-letf (((symbol-function 'drgnx-perf-w--colored-p) (lambda (&optional _window) t))
                    ((symbol-function 'drgnx-perf-w--visible-digest) (lambda (&optional _window) "md5"))
                    ((symbol-function 'run-with-timer) (lambda (&rest _) (cl-incf timers) nil)))
            (drgnx-perf-w--ts-await "k" (float-time) (float-time))
            (should (plist-get drgnx-perf-w--stats :colored_ms))
            (should-not drgnx-perf-w--ts-digests)
            (with-current-buffer buf (setq-local nidhogg-workers-treesit--pending nil))
            (drgnx-perf-w--ts-await "k" (float-time) (float-time) (float-time))
            (should (equal drgnx-perf-w--ts-digests '(("k" . "md5"))))))
      (setq drgnx-perf-w--other-window nil)
      (kill-buffer buf))))

(ert-deftest drgnx-perf-workers/completion-polls-while-idle ()
  "The completion poll is a repeating wall timer that polls only while Emacs is idle: an idle timer runs once per idle
period, so work finishing later in the pause after the keys was never seen."
  (let (started (polls 0) (idle nil) (drgnx-perf--complete nil))
    (cl-letf (((symbol-function 'drgnx-timer-start) (lambda (&rest args) (setq started args)))
              ((symbol-function 'drgnx-timer-cancel) #'ignore)
              ((symbol-function 'current-idle-time) (lambda () idle)))
      (drgnx-perf-complete-begin (lambda () (cl-incf polls) nil))
      (should-not (plist-get (nthcdr 3 started) :idle))
      (should (equal (plist-get (nthcdr 3 started) :repeat) 0.01))
      (funcall (nth 2 started))         ; inside a command: no poll
      (should (= polls 0))
      (setq idle '(0 1 0 0))
      (funcall (nth 2 started))
      (funcall (nth 2 started))         ; and again in the same idle period
      (should (= polls 2))
      (drgnx-perf-complete-end))))

(ert-deftest drgnx-perf-workers/autosave-digest-is-the-files-content ()
  "autosave-typing's digest hashes the saved file, less what was typed first; it is real, and moves when the file does."
  (perf-workers-test--session)
  (let (clean typed)
    (unwind-protect
        (progn
          (drgnx-perf-w-autosave-each)
          (drgnx-perf-w--autosave-fire)
          (setq clean (drgnx-perf-w-autosave-digest))
          (drgnx-perf-w-autosave-teardown)
          ;; the same, with three keys typed before the auto-save started
          (drgnx-perf-w-autosave-each)
          (with-current-buffer drgnx-perf-w--as-buffer (insert "abc"))
          (drgnx-perf-w--autosave-fire)
          (setq typed (drgnx-perf-w-autosave-digest))
          (should (string-match-p "\\`t 50000000 [0-9a-f]\\{32\\}\\'" clean))
          (should (equal clean typed))
          ;; a damaged file gives another digest
          (with-temp-file drgnx-perf-w--as-file (insert "short"))
          (should-not (equal clean (drgnx-perf-w-autosave-digest))))
      (drgnx-perf-w-autosave-teardown))))

(ert-deftest drgnx-perf-workers/results-json-takes-lists ()
  ;; An --ab-env result carries the order the sides ran in, ("a" "b" "b" "a" ...): the results file writes it as an
  ;; array (it failed with (wrong-type-argument symbolp "a") and no file, gate OT2's first A/B).
  (let ((file (make-temp-file "perf-workers-json" nil ".json")))
    (unwind-protect
        (progn
          (drgnx-perf-run--write-results file '((ts-typing :status "judged" :order ("a" "b" "b" "a") :n 4)))
          (let ((doc (with-temp-buffer (insert-file-contents file) (json-parse-buffer :object-type 'plist))))
            (should (equal (plist-get (plist-get (plist-get doc :results) :ts-typing) :order) ["a" "b" "b" "a"]))))
      (delete-file file))))

(ert-deftest drgnx-perf-workers/decisions-serialize-in-the-session ()
  ;; The session's reply is `json-serialize'd: the decision alist failed it ("symbolp, (ts inline estimate)").
  (let ((d (drgnx-perf--decisions-json '(((ts inline estimate) . 3) ((image offload cost) . 1)))))
    (should (equal d ["ts inline estimate 3" "image offload cost 1"]))
    (should (json-serialize (list :cal (list :decisions d))))))

(ert-deftest drgnx-perf-workers/results-json-takes-decision-counts ()
  ;; The calibration record's :decisions is an alist (((AREA OUTCOME REASON) . N) ...): dotted pairs and symbols.
  (let ((file (make-temp-file "perf-workers-json" nil ".json")))
    (unwind-protect
        (progn
          (drgnx-perf-run--write-results file '((ts-typing :cal (:decisions (((ts inline estimate) . 3))))))
          (let ((doc (with-temp-buffer (insert-file-contents file) (json-parse-buffer :object-type 'plist))))
            (should (equal (plist-get (plist-get (plist-get (plist-get doc :results) :ts-typing) :cal) :decisions)
                           [[["ts" "inline" "estimate"] 3]]))))
      (delete-file file))))

(defvar drgnx-perf-w--lsp-heads)
(defvar drgnx-perf-w--lsp-notes)
(declare-function drgnx-perf-w--lsp-note "perf-session")
(declare-function drgnx-perf-w-lsp-typing-digest "perf-session")

(defun perf-workers-test--flood (clear-at)
  "The lsp-typing digest after 150 flood messages of one server, the round's list cleared after CLEAR-AT of them (nil: never)."
  (setq drgnx-perf-w--lsp-heads nil drgnx-perf-w--lsp-notes nil)
  (cl-letf (((symbol-function 'jsonrpc-name) (lambda (_c) "perf-lsp-c")))
    (dotimes (i 150)
      (when (eql i clear-at) (setq drgnx-perf-w--lsp-notes nil))
      (drgnx-perf-w--lsp-note 'conn (intern (format "m%d" i)) nil)))
  (drgnx-perf-w-lsp-typing-digest))

(ert-deftest drgnx-perf-workers/lsp-typing-digest-ignores-where-a-round-starts ()
  "lsp-typing's flood runs on across rounds while each round clears the list of messages, so the first 100 of a round
began at a different place each time (8 digests in 8 rounds).  The digest is of the first messages of the session.
Pattern D: the digest of the same flood, whether or not a round started in the middle of it."
  (perf-workers-test--session)
  (should (equal (perf-workers-test--flood nil) (perf-workers-test--flood 40))))

(defvar drgnx-perf-w--tmp)
(defvar drgnx-perf-w--qo-files)
(declare-function drgnx-perf-w-quick-open-digest "perf-session")

(ert-deftest drgnx-perf-workers/quick-open-digest-is-relative-to-the-root ()
  "Each session lists a repository in its own temporary directory: the digest names the files by their path under it, so
the two arms agree.  Pattern D: the same listing under two roots."
  (perf-workers-test--session)
  (let ((digest (lambda (tmp)
                  (setq drgnx-perf-w--tmp tmp
                        drgnx-perf-w--qo-files (mapcar (lambda (f) (concat tmp "/big/" f)) '("d1/a" "d0/b" "d0/a")))
                  (drgnx-perf-w-quick-open-digest))))
    (should (equal (funcall digest "/tmp/drgnx-perf-wAAA") (funcall digest "/tmp/drgnx-perf-wBBB")))))

(defvar drgnx-quick-open--state)
(defvar drgnx-perf-w--qot-seen)
(defvar drgnx-perf-w--qot-listed)
(defvar drgnx-perf-w--qot-old)
(defvar drgnx-perf-w--tmp)
(declare-function drgnx-perf-w-quick-open-typing-each "perf-session")
(declare-function drgnx-perf-w--qot-note "perf-session")
(declare-function drgnx-perf-w-quick-open-typing-done "perf-session")
(declare-function drgnx-quick-open--step "drgnx-quick-open")
(declare-function drgnx-quick-open--init "drgnx-quick-open")

(defun perf-workers-test--qot-keys (done-first inputs)
  "Quick Open's state after each of INPUTS, noted as the workload's post-command does; DONE-FIRST: the listing had
ended before the first key.  Returns whether the workload counts the run as done."
  (require 'drgnx-quick-open)
  (setq drgnx-perf-w--qot-seen nil drgnx-perf-w--qot-listed nil drgnx-perf-w--qot-old t)
  (let ((drgnx-quick-open--state (car (drgnx-quick-open--step (drgnx-quick-open--init) '(batch ("d012/f001.txt" "d013/f000.txt"))))))
    (when done-first (setq drgnx-quick-open--state (car (drgnx-quick-open--step drgnx-quick-open--state '(done)))))
    (dolist (in inputs)
      (setq drgnx-quick-open--state (car (drgnx-quick-open--step drgnx-quick-open--state (list 'input in))))
      (cl-letf (((symbol-function 'minibufferp) (lambda (&rest _) t))
                ((symbol-function 'minibuffer-contents-no-properties) (lambda () in)))
        (let ((this-command 'self-insert-command)) (drgnx-perf-w--qot-note)))
      (setq drgnx-quick-open--state (car (drgnx-quick-open--step drgnx-quick-open--state '(done))))))
  (drgnx-perf-w-quick-open-typing-done))


(ert-deftest drgnx-perf-workers/quick-open-typing-needs-every-key-on-a-finished-listing ()
  "quick-open-typing measures keys over the whole list: a run whose first key came while the files were still being
listed, or that lost a key, is not done.  Pattern D: the three runs."
  (perf-workers-test--session)
  (let ((keys (mapcar (lambda (n) (substring "d012/f001.txt" 0 n)) (number-sequence 1 13))))
    (should (perf-workers-test--qot-keys t keys))
    (should-not (perf-workers-test--qot-keys nil keys))
    (should-not (perf-workers-test--qot-keys t (butlast keys)))
    (should (equal (car drgnx-perf-w--qot-seen) "d012/f001.tx"))))

;; the first run (2026-11-07) opened Quick Open from a timer: drgnx refuses a prompt there, and the session had no hub
(ert-deftest drgnx-perf-workers/quick-open-typing-opens-by-its-key-on-its-path ()
  "Both quick-open-typing workloads open Quick Open by its key, queued for the command loop (a timer's prompt is
refused), and measure only the typed keys; the hub's one starts a hub and stops it, and a run on the other path is not
done.  Pattern D: the specs, the each functions and the predicate."
  (perf-workers-test--session)
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (n '(quick-open-typing quick-open-typing-old))
      (let ((spec (cdr (assq n ws))))
        (should (equal (car (plist-get spec :actions)) '(:type "d")))
        (should-not (string-match-p "run-at-time" (plist-get spec :each)))
        (should (eq (and (string-match-p "drgnx-perf--hub-start" (plist-get spec :setup)) t) (eq n 'quick-open-typing)))
        (should (eq (and (string-match-p "drgnx-perf--hub-stop" (plist-get spec :teardown)) t) (eq n 'quick-open-typing))))))
  (cl-letf (((symbol-function 'find-file-noselect) (lambda (&rest _) (current-buffer)))
            ((symbol-function 'switch-to-buffer) #'ignore))
    (let ((unread-command-events nil) (drgnx-perf-w--tmp temporary-file-directory))
      (drgnx-perf-w-quick-open-typing-each)
      (remove-hook 'post-command-hook #'drgnx-perf-w--qot-note)
      (should (equal unread-command-events (listify-key-sequence (kbd "C-p"))))))
  ;; the stream path's run, read as the hub workload's, is not done
  (should (perf-workers-test--qot-keys t (mapcar (lambda (n) (substring "d012/f001.txt" 0 n)) (number-sequence 1 13))))
  (let ((drgnx-perf-w--qot-old nil))
    (should-not (drgnx-perf-w-quick-open-typing-done))))

;;; perf-workers-test.el ends here
