;;; hub-daemon-start-test.el --- batch tests: a drgnx daemon asks for the hub when it has started -*- lexical-binding: t -*-
;; test-class: det
;; The nightly backup runs inside the hub, so a daemon that never asked for one never backed up.  Nothing here starts a
;; hub: `drgnx-hub--ensure-running' is the one door and is recorded or made to fail.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(require 'drgnx-doctor)

(defmacro drgnx-hub-daemon-start-test--with (daemon &rest body)
  "BODY as a DAEMON (or not) that is not a batch run; `drgnx-hub--ensure-running' records its callbacks in CALLS."
  (declare (indent 1))
  `(let ((calls nil) (noninteractive (not ,daemon)))
     (cl-letf (((symbol-function 'daemonp) (lambda () ,daemon))
               ((symbol-function 'drgnx-hub--ensure-running) (lambda (cb) (push cb calls) nil))
               ((symbol-function 'drgnx-hub-connect) (lambda () (push 'connect calls))))
       (let ((process-environment (cons "DRGNX_NO_HUB_START" (cl-remove-if (lambda (e) (string-prefix-p "DRGNX_NO_HUB_START" e)) process-environment))))
         (unwind-protect (progn ,@body)
           (drgnx-timer-cancel 'hub-daemon-start))))))

(ert-deftest drgnx-hub-daemon-start/a-daemon-asks-for-the-hub-without-waiting ()
  (drgnx-hub-daemon-start-test--with t
    (let ((noninteractive nil))
      (drgnx-hub-ask-at-daemon-start)
      (should-not calls)                                    ; nothing at once: a timer defers it
      (should (drgnx-timer-active-p 'hub-daemon-start))
      (drgnx-hub--ask-for-hub)
      (should (equal calls (list #'drgnx-hub--daemon-start-answered))))))   ; asked once; no connect, so no keys go

(ert-deftest drgnx-hub-daemon-start/not-in-a-batch-run-or-a-plain-emacs ()
  (drgnx-hub-daemon-start-test--with nil
    (drgnx-hub-ask-at-daemon-start)
    (should-not (drgnx-timer-active-p 'hub-daemon-start))
    (let ((noninteractive nil)) (drgnx-hub-ask-at-daemon-start))   ; a plain Emacs, not a daemon
    (should-not (drgnx-timer-active-p 'hub-daemon-start)))
  (drgnx-hub-daemon-start-test--with t
    (let ((noninteractive t)) (drgnx-hub-ask-at-daemon-start))     ; a batch run, even one called a daemon
    (should-not (drgnx-timer-active-p 'hub-daemon-start))))

(ert-deftest drgnx-hub-daemon-start/the-off-switch-and-a-missing-binary-are-quiet ()
  (let ((noninteractive nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () t))
              ((symbol-function 'drgnx-hub--ensure-running)
               (lambda (_cb) (error "Ratatoskr is not built: run `drgnx runtime build'"))))
      (should-not (drgnx-hub--ask-for-hub))                  ; no error escapes
      (let ((process-environment (cons "DRGNX_NO_HUB_START=1" process-environment)))
        (should-not (drgnx-hub-ask-at-daemon-start))
        (should-not (drgnx-timer-active-p 'hub-daemon-start))))))

(ert-deftest drgnx-hub-daemon-start/a-failed-start-is-a-notice-and-a-started-hub-gets-nothing ()
  (let (notified handed)
    (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest a) (push a notified)))
              ((symbol-function 'drgnx-hub--hand-over) (lambda () (setq handed t))))
      (drgnx-hub--daemon-start-answered nil)                 ; up: nothing is handed over, nothing said
      (should-not (or handed notified))
      (drgnx-hub--daemon-start-answered "Ratatoskr did not start: x")
      (should (= (length notified) 1))
      (should-not handed))))

(ert-deftest drgnx-hub-daemon-start/doctor-says-the-hub-is-down-when-the-backup-is-old ()
  (let* ((stale "the last backup is 200 hours old (the nightly one runs at 03:00): `drgnx graph backup`")
         (check (lambda (running)
                  (drgnx-doctor-check
                   'store (list :ratatoskr (list :report (list :running running
                                                               :store (list :schema 7 :backup_age_s 720000
                                                                            :warnings (vector stale)))))))))
    (let ((r (funcall check nil)))
      (should (eq (car r) 'warn))
      (should (string-search "200 hours old" (nth 1 r)))
      (should (string-search "hub is not running" (nth 1 r)))
      (should (string-search "nightly backup cannot run" (nth 1 r))))
    (let ((r (funcall check '(:commit "abc" :pid 1))))      ; a running hub: the warning as it was
      (should (equal (nth 1 r) stale)))))

(provide 'hub-daemon-start-test)
;;; hub-daemon-start-test.el ends here
