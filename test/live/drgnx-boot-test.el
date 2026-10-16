;;; drgnx-boot-test.el --- live smoke test: drgnx boots in a session (config=drgnx) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/drgnx-boots-and-its-surfaces-work ()
  (let* ((root (make-temp-file "drgnx-boot" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (should (eq (plist-get (plist-get s :ready) :init_error) :false))
          (let ((info (drgnx-ui-call sess "(drgnx-uitest--json
                     (list :commands (length (drgnx-commands-all))
                           :problems (length drgnx-commands-problems)
                           :guard (if drgnx-guard-mode t :false)
                           :basics (format \"%S\" (alist-get 'core/basics (drgnx-modules-report)))))")))
            (should (> (plist-get info :commands) 2))
            (should (= (plist-get info :problems) 0))
            (should (eq (plist-get info :guard) t))
            (should (string-search ":error nil" (plist-get info :basics))))
          ;; The palette opens on C-S-p and lists registry commands.
          (drgnx-ui-measure sess (list (list :keys "C-S-p")))
          (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-boot-status)") :prompt) "Command: "))
          (drgnx-ui-measure sess (list (list :keys "C-g")))
          ;; VS Code keys by default: F1 is the palette too, C-k C-s the key sheet.
          (drgnx-ui-measure sess (list (list :keys "<f1>")))
          (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-boot-status)") :prompt) "Command: "))
          (drgnx-ui-measure sess (list (list :keys "C-g")))
          (drgnx-ui-measure sess (list (list :keys "C-k C-s")))
          (should (seq-find (lambda (w) (equal (plist-get w :buffer) "*drgnx keys*"))
                            (plist-get (drgnx-ui-state sess) :windows)))
          ;; A prompt from a timer signals instead of freezing the session.
          (should (string-search "drgnx-prompt-in-automatic-path"
                                 (plist-get (drgnx-ui-call sess "(progn (setq drgnx-test-timer-result nil)
                                    (run-with-timer 0 nil (lambda () (setq drgnx-test-timer-result
                                      (condition-case e (y-or-n-p \"Really? \") (error (format \"%S\" (car e)))))))
                                    (sleep-for 0.3)
                                    (drgnx-uitest--json (list :r (format \"%s\" drgnx-test-timer-result))))") :r))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
