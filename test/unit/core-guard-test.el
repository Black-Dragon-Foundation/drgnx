;;; core-guard-test.el --- batch tests: no prompts in automatic paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-guard)
(require 'drgnx-timer)

(defun drgnx-test--fake-prompt (&rest _) 'answered)

(defmacro drgnx-test--with-guard (&rest body)
  `(let ((drgnx-guard-prompt-functions '(drgnx-test--fake-prompt)))
     (drgnx-guard-mode 1)
     (unwind-protect (progn ,@body) (drgnx-guard-mode -1))))

(ert-deftest drgnx-guard/commands-may-prompt ()
  (drgnx-test--with-guard
   (should (eq (drgnx-test--fake-prompt "q") 'answered))))

(ert-deftest drgnx-guard/timers-may-not ()
  (drgnx-test--with-guard
   (let ((drgnx-guard--timer-fn 'some-timer))
     (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path))))

(ert-deftest drgnx-guard/automatic-blocks-may-not ()
  (drgnx-test--with-guard
   (should-error (drgnx-automatic (drgnx-test--fake-prompt "q")) :type 'drgnx-prompt-in-automatic-path)))

(ert-deftest drgnx-guard/daemon-startup-may-not ()
  (drgnx-test--with-guard
   (cl-letf (((symbol-function 'drgnx-guard--daemon-starting-p) (lambda () t)))
     (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path))))

(ert-deftest drgnx-guard/error-names-the-prompt ()
  (drgnx-test--with-guard
   (let ((err (should-error (drgnx-automatic (drgnx-test--fake-prompt "Delete everything? "))
                            :type 'drgnx-prompt-in-automatic-path)))
     (should (string-search "Delete everything?" (error-message-string err))))))

(ert-deftest drgnx-guard/off-means-off ()
  (let ((drgnx-guard-prompt-functions '(drgnx-test--fake-prompt)))
    (drgnx-guard-mode 1) (drgnx-guard-mode -1)
    (should (eq (drgnx-automatic (drgnx-test--fake-prompt "q")) 'answered))))

;;;; Deferred fixes (M2-1)

(ert-deftest drgnx-guard/the-other-prompts-are-guarded ()
  ;; read-multiple-choice, read-answer, read-key and read-char-choice ask too; read-event does not
  ;; (sit-for uses it).
  (dolist (fn '(read-multiple-choice read-answer read-key read-char-choice))
    (should (memq fn drgnx-guard-prompt-functions)))
  (should-not (memq 'read-event drgnx-guard-prompt-functions)))

(ert-deftest drgnx-guard/daemon-start-lasts-until-window-setup ()
  ;; after-init-hook and emacs-startup-hook run after after-init-time is set: still nobody to answer.
  (let ((after-init-time nil) (window-setup-hook nil) (drgnx-guard--started nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () t)))
      (drgnx-test--with-guard
       (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path)
       (setq after-init-time (current-time))          ; after-init-hook, emacs-startup-hook
       (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path)
       (run-hooks 'window-setup-hook)                  ; the last of startup
       (should (eq (drgnx-test--fake-prompt "q") 'answered))))))

(ert-deftest drgnx-guard/turned-on-after-startup-the-daemon-may-ask ()
  (let ((after-init-time (current-time)) (window-setup-hook nil) (drgnx-guard--started nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () t)))
      (drgnx-test--with-guard
       (should (eq (drgnx-test--fake-prompt "q") 'answered))))))

(defun drgnx-guard-test--named () nil)

(ert-deftest drgnx-guard/a-layer-timer-is-named-by-its-function ()
  (drgnx-test--with-guard
   (let ((raw (run-with-timer 3600 nil #'drgnx-guard-test--named)))
     (unwind-protect
         (progn
           (drgnx-timer-start 'guard-k 3600 #'drgnx-guard-test--named)
           (let ((tm (drgnx-timer--entry-timer (gethash 'guard-k drgnx-timer--table))))
             (should (eq 'drgnx-guard-test--named (drgnx-guard--timer (lambda (_) drgnx-guard--timer-fn) tm)))
             (should (eq 'drgnx-guard-test--named (drgnx-guard--timer (lambda (_) drgnx-guard--timer-fn) raw)))))   ; a raw timer as before
       (drgnx-timer-cancel 'guard-k)
       (cancel-timer raw)))))
