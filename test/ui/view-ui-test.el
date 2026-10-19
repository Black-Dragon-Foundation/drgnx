;;; view-ui-test.el --- GUI tests: views drawing live while you type (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)
(defconst drgnx-view-ui-test--repo                          ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-view-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-view-ui-test--repo))
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-view-ui-test--repo) nil t)

(defun drgnx-view-ui-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(ert-deftest drgnx-view-ui/a-streaming-transcript-has-no-jank ()
  ;; The mock agent streams 100-character chunks, 50 a second, into a transcript in the other window while keys are
  ;; typed into this one: the transcript grows from its own timer and keeps its windows where they were (the jank
  ;; guard sees no window moved by a timer).  tools/agents is set up for the test (and torn down after) unless it is on.
  (let* ((on (eq (plist-get (alist-get 'tools/agents drgnx-modules--report) :status) 'ok))
         (root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (drgnx-agents-profiles
          (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l"
                                            (expand-file-name "test/fixtures/mock-acp.el" drgnx-view-ui-test--repo)))))
         (typing (get-buffer-create "*drgnx-view-ui typing*")) (s nil) (transcript nil))
    (unwind-protect
        (with-selected-frame root
          (unless on
            (should-not (drgnx-modules--run-setup 'tools/agents (plist-get (cdr (assq 'tools/agents drgnx-modules--table)) :setup)))
            (drgnx-modules--record 'tools/agents 'startup 0 'ok))
          (should (drgnx-view-type-p 'agent-transcript))
          (setq s (drgnx-agents-start "mock" temporary-file-directory))
          (should (drgnx-view-ui-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
          (delete-other-windows)
          (switch-to-buffer typing)
          (setq transcript (drgnx-agents-ui-transcript-buffer s))
          (set-window-buffer (split-window nil nil 'right) transcript)
          (let ((grown (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view transcript)) :rows-grown)))
            (drgnx-agents-send s "stream 1000")                                ; 20 s of it
            (should (drgnx-view-ui-test--wait (lambda () (string-search "chunk 2 " (with-current-buffer transcript (buffer-string))))))
            ;; the stream never lets the session settle: 4 s are enough for the 33 keys (one per 40 ms)
            (let ((r (drgnx-uitest-run (drgnx-uitest-type-events "(let ((x 1)) (message \"%s\" x)) ") 4)))
              (should (= 0 (plist-get r :guard_violations))))
            (should (eq (drgnx-agent-session-status s) 'busy))                 ; typed while it streamed
            (should (> (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view transcript)) :rows-grown) grown))
            (with-current-buffer typing (should (string-search "message" (buffer-string))))))
      (when s (ignore-errors (drgnx-agents-kill s)))
      (with-selected-frame root (set-window-configuration config))
      (when (buffer-live-p transcript) (kill-buffer transcript))
      (kill-buffer typing)
      (unless on (drgnx-module-teardown 'tools/agents)))))

;;; view-ui-test.el ends here
