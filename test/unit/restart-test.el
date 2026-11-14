;;; restart-test.el --- batch tests: restarting drgnx from the editor (core/drgnx-restart.el) -*- lexical-binding: t -*-
;; test-class: det
;; The questions, the spawn and `kill-emacs' are stubbed: nothing here starts a process or ends this Emacs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-restart)

(defmacro drgnx-restart-test--with (answer &rest body)
  "BODY with the quit questions answered ANSWER; `spawned' and `killed' hold what was started and whether Emacs quit."
  (declare (indent 1) (debug t))
  `(let (spawned killed)
     (cl-letf (((symbol-function 'drgnx-session-quit-confirm) (lambda () ,answer))
               ((symbol-function 'drgnx-restart--spawn) (lambda (argv &optional unit) (push (list argv unit) spawned)))
               ((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t))))
       ,@body)))

(ert-deftest drgnx-restart/a-service-session-restarts-the-unit ()
  (let ((process-environment (cons "INVOCATION_ID=0123456789abcdef" process-environment)))
    (drgnx-restart-test--with t
      (cl-letf (((symbol-function 'drgnx-restart--cgroup)
                 (lambda () "0::/user.slice/user-1000.slice/user@1000.service/app.slice/drgnx.service\n")))
        (drgnx-restart)
        (should (equal (mapcar #'car spawned) '(("systemctl" "--user" "restart" "drgnx"))))
        (should-not killed)))))

(ert-deftest drgnx-restart/a-launch-agent-session-restarts-the-agent ()
  ;; macOS: launchd names the job of the daemon it started in XPC_SERVICE_NAME
  (let ((process-environment (cons "XPC_SERVICE_NAME=org.blackdragonfoundation.drgnx" process-environment)))
    (drgnx-restart-test--with t
      (cl-letf (((symbol-function 'drgnx-restart--cgroup) #'ignore))
        (drgnx-restart)
        (should (equal (mapcar #'car spawned)
                       (list (list "launchctl" "kickstart" "-k"
                                   (format "gui/%d/org.blackdragonfoundation.drgnx" (user-uid))))))
        (should-not killed)))))

(ert-deftest drgnx-restart/asks-first-and-spawns-only-on-yes ()
  (let ((process-environment (cons "INVOCATION_ID=" (cl-remove-if (lambda (e) (string-prefix-p "INVOCATION_ID=" e))
                                                                  process-environment))))
    (drgnx-restart-test--with nil
      (drgnx-restart)
      (should-not spawned)
      (should-not killed))
    (drgnx-restart-test--with t
      (cl-letf (((symbol-function 'drgnx-restart--cgroup) (lambda () "0::/user.slice/session-3.scope\n")))
        (drgnx-restart))
      (should (= (length spawned) 1))
      (should killed)
      (let ((argv (car (car spawned))))
        (should (equal (seq-take argv 2) '("sh" "-c")))
        (should (string-search (format "kill -0 %d" (emacs-pid)) (nth 2 argv)))
        (should (string-search " open" (nth 2 argv)))))))

;;; restart-test.el ends here
