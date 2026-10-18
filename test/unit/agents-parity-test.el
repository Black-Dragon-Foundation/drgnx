;;; agents-parity-test.el --- the parity suite: context %, /compact, slash commands, for any profile -*- lexical-binding: t -*-
;; Against the mock by default; DRGNX_AGENT_PROFILE=NAME runs the same assertions against a real
;; profile (agents.eld) — the user's step: it uses their subscription or API key and the network.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-paths)

(defun drgnx-parity--wait (pred secs)
  (let ((deadline (+ (float-time) secs)) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (accept-process-output nil 0.05))
    v))

(ert-deftest drgnx-parity/context-compact-and-slash-commands ()
  (let* ((real (getenv "DRGNX_AGENT_PROFILE"))
         (drgnx-agents-profiles
          (unless real
            (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l"
                                              (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))))
         (drgnx-agents--sessions nil)
         (secs (if real 120 10))
         (s (drgnx-agents-start (or real "mock") temporary-file-directory)))
    (unwind-protect
        (progn
          (should (drgnx-parity--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)) secs))
          (should (drgnx-parity--wait (lambda () (drgnx-agent-session-commands s)) secs))     ; slash commands listed
          (drgnx-agents-send s (concat "Reply with the word ok. " (make-string 300 ?w)))
          (should (drgnx-parity--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)) secs))
          (let ((before (drgnx-agents-context-percent s)))
            (should (numberp before))                                                          ; context % shown
            (drgnx-agents-send s "/compact")
            (should (drgnx-parity--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)) secs))
            (should (<= (drgnx-agents-context-percent s) before))))                            ; /compact lowers it
      (drgnx-agents-kill s))))

;;; agents-parity-test.el ends here
