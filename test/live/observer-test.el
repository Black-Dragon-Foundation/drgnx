;;; observer-test.el --- live tests: the harness does not perturb the session -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(defmacro drgnx-observer--with-session (var &rest body)
  "Run BODY with VAR bound to a fresh minimal session; stop it afterwards."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-observer" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (drgnx-ui-start "minimal" nil 20))
          (,var (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect (progn ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(ert-deftest drgnx-live/harness-calls-run-no-session-hooks ()
  (drgnx-observer--with-session sess
    (drgnx-ui-call sess "(progn (defvar obs-n 0)
      (add-hook 'first-change-hook (lambda () (setq obs-n (1+ obs-n))))
      (add-hook 'buffer-list-update-hook (lambda () (setq obs-n (1+ obs-n))))
      (drgnx-uitest--json (list :ok t)))")
    (dotimes (_ 10) (drgnx-ui-call sess "(drgnx-uitest-api-status)"))
    (drgnx-ui-state sess)
    (drgnx-ui-screenshot sess (make-temp-file "drgnx-obs" nil ".png"))
    (should (= (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :n obs-n))") :n) 0))))

(ert-deftest drgnx-live/debounced-follower-is-seen ()
  ;; The gryphn shape: commands and any first change re-arm a 0.15 s timer that moves point back.
  (drgnx-observer--with-session sess
    (drgnx-ui-call sess "(progn
      (switch-to-buffer (get-buffer-create \"*obs*\"))
      (dotimes (i 40) (insert (format \"line %02d\\n\" i)))
      (goto-char (point-min))
      (defvar obs-timer nil)
      (defun obs-schedule (&rest _)
        (when (timerp obs-timer) (cancel-timer obs-timer))
        (setq obs-timer (run-with-timer 0.15 nil (lambda ()
          (with-selected-window (get-buffer-window \"*obs*\") (goto-char (point-min)))))))
      (add-hook 'post-command-hook #'obs-schedule)
      (add-hook 'first-change-hook #'obs-schedule)
      (drgnx-uitest--json (list :ok t)))")
    (sleep-for 0.5)
    (let ((r (drgnx-ui-measure sess (list (list :buffer "*obs*" :text "line 10")))))
      (should (>= (plist-get r :oscillations) 1))
      (should (>= (plist-get r :settle_ms) 100)))))
