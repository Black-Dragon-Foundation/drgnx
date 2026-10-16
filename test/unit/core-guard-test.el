;;; core-guard-test.el --- batch tests: no prompts in automatic paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-guard)

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
