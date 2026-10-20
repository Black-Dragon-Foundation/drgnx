;;; drgnx-agents-test.el --- live: the Agents tab with the mock ACP agent in a GUI session -*- lexical-binding: t -*-
;; Sending during a running turn queues (shown in the list), Stop ends the turn within a second,
;; the transcript is in the editor and the list in the right dock, nothing unrouted.
(require 'ert)
(require 'drgnx-ui)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-ui-repo-dir) nil t)

(defun drgnx-live-ag--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 60) :v))))

(defun drgnx-live-ag--until (sess form secs)
  "Poll FORM in SESS until non-nil; its value (`drgnx-test-wait', at least 30 s or SECS)."
  (drgnx-test-wait (lambda () (drgnx-live-ag--q sess form)) :secs (max 30 secs) :what form))

(ert-deftest drgnx-live/agents-queue-stop-and-the-dock ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-agents-live" t)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment))
         (mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
         (s (drgnx-ui-start "drgnx" "1400x800" 30)) (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (drgnx-live-ag--q sess (format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                                                  (drgnx-agents-ui-view)
                                                  (setq drgnx-live--s (drgnx-agents-start \"mock\" %S)) t)" mock root))
          (should (drgnx-live-ag--until sess "(eq (drgnx-agent-session-status drgnx-live--s) 'idle)" 10))
          (drgnx-live-ag--q sess "(progn (drgnx-agents-ui-transcript drgnx-live--s) (drgnx-agents-send drgnx-live--s \"slow please\") (drgnx-agents-send drgnx-live--s \"and then this\") t)")
          ;; the list says it, the turn goes on (the slow turn lasts 3 s: checked first)
          (should (drgnx-live-ag--until sess "(and (with-current-buffer \"*drgnx Agents*\" (string-search \"1 queued\" (buffer-string))) t)" 2))
          (should (eq (drgnx-live-ag--q sess "(drgnx-agent-session-status drgnx-live--s)") 'busy))
          (should (equal (drgnx-live-ag--q sess "(list (buffer-name (window-buffer (drgnx-wb-area-window 'right))) (drgnx-wb-area-tab 'right))")
                         '("*drgnx Agents*" agents)))
          (should (drgnx-live-ag--q sess "(and (seq-find (lambda (w) (and (string-prefix-p \"*agent: \" (buffer-name (window-buffer w))) (drgnx-signal-editor-window-p w))) (window-list)) t)"))
          ;; Stop: the turn ends within a second; the queued message waits
          (let ((dt (drgnx-live-ag--q sess "(let ((t0 (float-time))) (drgnx-agents-stop drgnx-live--s)
                                              (while (and (eq (drgnx-agent-session-status drgnx-live--s) 'busy) (< (- (float-time) t0) 3)) (accept-process-output nil 0.02))
                                              (- (float-time) t0))")))
            (should (< dt 1.0)))
          (should (equal (drgnx-live-ag--q sess "(drgnx-agent-session-queue drgnx-live--s)") '("and then this")))
          (drgnx-ui-measure sess nil)
          (should (equal (drgnx-live-ag--q sess "(length drgnx-wb-unrouted)") 0)))
      (ignore-errors (drgnx-live-ag--q sess "(progn (drgnx-agents-kill drgnx-live--s) t)"))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

;;; drgnx-agents-test.el ends here
