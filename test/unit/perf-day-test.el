;;; perf-day-test.el --- batch tests: the synthetic day (composition, transcript replay, LSP replay, rules) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf-run)

(defconst perf-day-test--dir
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name)))
  "The repository root (test/unit/'s grandparent).")

(ert-deftest drgnx-perf-day/composition-is-pinned ()
  ;; every input is a file under test/fixtures/day/, the seed is fixed, and no workload of the day is one the container
  ;; skips; the composition's SHA changes when an input does
  (let* ((drgnx-ui-repo-dir perf-day-test--dir)
         (c (drgnx-perf-day-composition)))
    (should (equal (plist-get c :seed) "drgnx-day-1"))
    (should (plist-get c :files))
    (dolist (f (plist-get c :files))
      (should (string-prefix-p "test/fixtures/" f))
      (should (file-exists-p (expand-file-name f perf-day-test--dir))))
    (should (file-exists-p (expand-file-name "test/fixtures/lsp-replay.el" perf-day-test--dir)))
    (should (string-match-p "\\`[0-9a-f]\\{12\\}\\'" (plist-get c :sha)))
    (should (equal (plist-get c :sha) (plist-get (drgnx-perf-day-composition) :sha)))
    (let ((all (drgnx-perf-run--workloads)))
      (should (memq 'transcript-replay (plist-get c :workloads)))
      (dolist (w (plist-get c :workloads))
        (should-not (assq w drgnx-perf-run-container-skipped))
        (should (plist-get (cdr (assq w all)) :actions))))))

(ert-deftest drgnx-perf-day/transcript-replay-runs-without-an-agent ()
  ;; a session with no process; a chunk per tick, the next tick set at the recorded pace; the transcript grows
  (require 'drgnx-agents)
  (let* ((chunks '((40 . "one ") (25 . "two ") (60 . "three")))
         (drgnx-agents--sessions nil) (drgnx-perf--replays nil)
         starts changed)
    (cl-letf (((symbol-function 'drgnx-timer-start)
               (lambda (key secs fn &rest r) (push (list key secs fn (plist-get r :args)) starts) key))
              ((symbol-function 'drgnx-timer-cancel) #'ignore)
              ((symbol-function 'drgnx-agents--changed) (lambda (s) (push s changed)))
              ((symbol-function 'make-process) (lambda (&rest _) (error "A process was started")))
              ((symbol-function 'start-process) (lambda (&rest _) (error "A process was started"))))
      (let ((s (drgnx-perf-replay-start "day-a" chunks)))
        (should (memq s drgnx-agents--sessions))
        (should-not (drgnx-agent-session-conn s))
        (should (equal (nth 1 (car starts)) 0.04))            ; the first chunk's delay
        (drgnx-perf-replay-tick "day-a")
        (should (equal (nth 1 (car starts)) 0.025))           ; the second's
        (drgnx-perf-replay-tick "day-a")
        (drgnx-perf-replay-tick "day-a")
        (should (equal (drgnx-agents-entry-text (car (drgnx-agent-session-entries s))) "one two three"))
        (should (= (drgnx-perf-replay-count "day-a") 3))
        (should (= (length changed) 3))
        ;; the recording ended: the answer is done and the loop starts again
        (should (plist-get (car (drgnx-agent-session-entries s)) :done))
        (should (equal (nth 1 (car starts)) 0.04))
        (drgnx-perf-replay-stop "day-a")
        (should-not (memq s drgnx-agents--sessions))
        (should (= (drgnx-perf-replay-count "day-a") 0))))))

(ert-deftest drgnx-perf-day/lsp-replay-answers-initialize ()
  ;; the stub, a batch Emacs on stdio, answers `initialize' from the recording and `shutdown' with null, and
  ;; leaves a notification unanswered
  (let* ((out "") (stub (expand-file-name "test/fixtures/lsp-replay.el" perf-day-test--dir))
         (frame (lambda (json) (format "Content-Length: %d\r\n\r\n%s" (string-bytes json) json)))
         (proc (make-process :name "lsp-replay-test" :connection-type 'pipe :noquery t
                             :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" stub)
                             :filter (lambda (_p s) (setq out (concat out s))))))
    (unwind-protect
        (let ((wait (lambda (re) (let ((d (+ (float-time) 30)))
                                   (while (and (not (string-match-p re out)) (< (float-time) d)) (accept-process-output proc 0.2))))))
          (process-send-string proc (funcall frame "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"))
          (funcall wait "\"id\":1")
          (should (string-match "Content-Length: [0-9]+\r\n\r\n{[^\n]*\"id\":1[^\n]*\"serverInfo\":{\"name\":\"replay\"" out))
          (process-send-string proc (funcall frame "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"))
          (process-send-string proc (funcall frame "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}"))
          (funcall wait "\"id\":2")
          (should (string-match-p "\"id\":2,\"result\":null" out))
          (should (= 2 (with-temp-buffer (insert out) (how-many "Content-Length:" (point-min))))))   ; one answer each, none for the notification
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest drgnx-perf-day/no-400mb-rule ()
  ;; the soak's 400 MB cap is not the day's: a flat 1 GB passes, 25 % growth across the steady rounds fails, and so
  ;; does a workload's error
  (let ((flat (mapcar (lambda (kb) (list :rss_kb kb)) '(1048576 1048576 1050000 1048576))))
    (should-not (drgnx-perf-day-verdict flat nil)))
  (let ((fails (drgnx-perf-day-verdict (mapcar (lambda (kb) (list :rss_kb kb)) '(1000000 1100000 1250000)) nil)))
    (should (= 1 (length fails)))
    (should (string-match-p "grew 25\\.0%" (car fails))))
  (should (drgnx-perf-day-verdict (list (list :rss_kb 1000) (list :rss_kb 1000)) '("typing: boom"))))

(ert-deftest drgnx-perf-day/a-round-fails-when-a-replay-or-the-language-server-died ()
  ;; after each steady round both background replays must have produced since the last one and eglot must be up
  (should-not (drgnx-perf-day-liveness-fails 2 '(10 20) '(:replays [15 30] :eglot t)))
  (let ((fails (drgnx-perf-day-liveness-fails 3 '(15 30) '(:replays [15 41] :eglot t))))
    (should (= 1 (length fails)))
    (should (string-match-p "round 3: replay day-1 stopped" (car fails))))
  (let ((fails (drgnx-perf-day-liveness-fails 1 '(0 0) '(:replays (5 6) :eglot :false))))
    (should (= 1 (length fails)))
    (should (string-match-p "language server" (car fails)))))
