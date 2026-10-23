;;; perf-workers-test.el --- batch tests: the perf lab's worker rows (DRGNX_PERF_WORKERS, report-only rows, completion metrics, digests, phases, the 2-core shape) -*- lexical-binding: t -*-
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

(ert-deftest drgnx-perf-workers/phase-ms-in-verdict ()
  (let* ((run (lambda (wait) (list :workers (list :phase-ms (list :treesit-wait wait :json 5.0)) :input (list :p95 4.0))))
         (rounds (cl-loop for i below 10 collect (list :a (funcall run (+ 2.0 (* 0.1 (% i 3)))) :b (funcall run (+ 5.0 (* 0.1 (% i 3)))))))
         (vs (drgnx-perf-ab-metric-verdicts rounds)))
    (should (eq (plist-get (cdr (assoc '(:workers :phase-ms :treesit-wait) vs)) :verdict) 'regressed))
    (should (eq (plist-get (cdr (assoc '(:workers :phase-ms :json) vs)) :verdict) 'no-regression))
    (should (eq (plist-get (cdr (assoc '(:input :p95) vs)) :verdict) 'no-regression))
    ;; a path neither side reports is left out
    (should-not (assoc '(:complete-ms) vs))))

(ert-deftest drgnx-perf-workers/cpus-cpuset ()
  (should (equal (drgnx-perf-cpuset-args "2") '("--cpuset-cpus" "0-1")))
  (should (equal (drgnx-perf-cpuset-args "4") '("--cpuset-cpus" "0-3")))
  (should-not (drgnx-perf-cpuset-args nil))
  (should-error (drgnx-perf-cpuset-args "3"))
  ;; the container runner builds the same arguments
  (let ((text (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string))))
    (should (string-match-p "--cpuset-cpus 0-1" text))
    (should (string-match-p "--cpuset-cpus 0-3" text))))

;;;; Task 8: the workloads of §17.6

(ert-deftest drgnx-perf-workers/workloads-registered ()
  "Every workload of the design's table is a workload with a budget row that is report-only for a step, a completion
form and a digest, and a setup form that reads."
  (let ((ws (drgnx-perf-run--workloads)) (budgets (drgnx-perf-run--budgets)))
    (dolist (n '(lsp-burst lsp-typing ts-open ts-paste ts-typing ts-typing-unclosed compile-flood image-open
                           explorer-expand explorer-git quick-open-large autosave-typing))
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

(defun perf-workers-test--frames (bytes)
  "The payload sizes of the framed messages in the unibyte string BYTES: a reply counts its result text only."
  (let ((pos 0) sizes)
    (while (string-match "Content-Length: \\([0-9]+\\)\r\n\r\n" bytes pos)
      (let* ((len (string-to-number (match-string 1 bytes))) (start (match-end 0)) (end (+ start len)))
        (when (> end (length bytes)) (setq pos (length bytes)) (setq len nil))
        (when len
          (let ((body (substring bytes start end)))
            (push (if (string-match "\\`{\"jsonrpc\":\"2.0\",\"id\":[0-9]+,\"result\":" body)
                      (- len (match-end 0) 1)
                    len)
                  sizes))
          (setq pos end))))
    (nreverse sizes)))

(ert-deftest drgnx-perf-workers/capture-is-replayable ()
  "Each recorded corpus replays through the stub: the messages and bytes it sends equal the capture's manifest."
  (skip-unless (eq system-type 'gnu/linux))   ; the stub reads its stdin through /proc
  (let* ((dir (expand-file-name "test/fixtures/workers" drgnx-dir))
         (manifest (with-temp-buffer (insert-file-contents (expand-file-name "manifest.eld" dir)) (read (current-buffer))))
         (stub (expand-file-name "test/fixtures/lsp-replay.el" drgnx-dir))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (should (= (length manifest) 3))
    (let ((process-environment (cons "LSP_REPLAY_LIBRARY=1" process-environment)))
      (load stub nil t))
    (dolist (entry manifest)
      (let* ((file (expand-file-name (format "corpus-%s.eld.gz" (car entry)) dir))
             (corpus (lsp-replay-corpus-read file))
             (want (list :messages (plist-get (cdr entry) :messages) :bytes (plist-get (cdr entry) :bytes))))
        (should (equal (lsp-replay-corpus-totals corpus) want))   ; the manifest describes the corpus
        ;; and the stub, as a process, sends exactly that
        (let* ((out "") (id 0)
               (process-environment (append (list (concat "LSP_REPLAY_CORPUS=" file)) process-environment))
               (proc (make-process :name "perf-workers-test-stub" :noquery t :connection-type 'pipe :coding 'binary
                                   :command (list emacs "--batch" "-Q" "-l" stub)
                                   :filter (lambda (_p s) (setq out (concat out s))))))
          (unwind-protect
              (cl-flet ((send (json) (process-send-string proc (format "Content-Length: %d\r\n\r\n%s" (string-bytes json) json))))
                (send "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}")
                (send "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}")
                (dolist (r (plist-get corpus :replies))
                  (send (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":%S,\"params\":{}}" (cl-incf id) (car r))))
                (let ((deadline (+ (float-time) 60)))
                  (while (and (< (float-time) deadline)
                              (< (length (perf-workers-test--frames out)) (plist-get want :messages)))
                    (accept-process-output proc 0.1))))
            (when (process-live-p proc) (delete-process proc)))
          (let ((sizes (perf-workers-test--frames out)))
            (should (= (length sizes) (plist-get want :messages)))
            (should (= (apply #'+ sizes) (plist-get want :bytes)))))))))

;;; perf-workers-test.el ends here
