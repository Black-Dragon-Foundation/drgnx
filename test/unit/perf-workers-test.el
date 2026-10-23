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
