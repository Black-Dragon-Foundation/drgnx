;;; core-timer-own-test.el --- batch tests: a module's timers die with its run (teardown wiring) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-timer-own-test--seen nil "What `:teardown' saw of the table, or `unset'.")
(defvar drgnx-timer-own-test--later nil "A function a setup made with `drgnx-modules-with-owner'.")
(defvar drgnx-timer-own-test--buffer nil "A buffer a setup passes as an owner.")

(defun drgnx-timer-own-test--note () nil)
(defun drgnx-timer-own-test--teardown ()
  (setq drgnx-timer-own-test--seen (hash-table-count drgnx-timer--table)))

(defmacro drgnx-timer-own-test--with (spec &rest body)
  "BODY on the virtual clock with a fresh module table holding `test/a' (SPEC: its keyword arguments)."
  (declare (indent 1))
  `(let* ((drgnx-modules--table (list (cons 'test/a ,spec)))
          (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
          (drgnx-modules--features nil) (drgnx-modules--left nil)
          (drgnx-timer-own-test--seen 'unset) (drgnx-timer-own-test--later nil))
     (drgnx-test-with-clock () ,@body)))

(defun drgnx-timer-own-test--on ()
  (drgnx-modules--run-one 'test/a (alist-get 'test/a drgnx-modules--table) 'startup))
(defun drgnx-timer-own-test--timers () (+ (length timer-list) (length timer-idle-list)))

(ert-deftest drgnx-timer-own/a-module-off-leaves-no-timer ()
  (drgnx-timer-own-test--with
      (list :setup (lambda ()
                     (drgnx-timer-start 'own-setup 60 #'drgnx-timer-own-test--note :repeat 60)
                     (setq drgnx-timer-own-test--later
                           (drgnx-modules-with-owner
                             (drgnx-timer-start 'own-deferred 60 #'drgnx-timer-own-test--note))))
            :teardown #'drgnx-timer-own-test--teardown)
    (drgnx-timer-own-test--on)
    (funcall drgnx-timer-own-test--later)
    (drgnx-timer-start 'own-hook 60 #'drgnx-timer-own-test--note :owner 'test/a :idle t)   ; a later hook
    (should (= 3 (hash-table-count drgnx-timer--table)))
    (should (= 3 (drgnx-timer-own-test--timers)))
    (should-not (drgnx-module-teardown 'test/a))
    (should (= 0 drgnx-timer-own-test--seen))            ; gone before :teardown ran
    (should (= 0 (hash-table-count drgnx-timer--table)))
    (should (= 0 (drgnx-timer-own-test--timers)))))

(ert-deftest drgnx-timer-own/a-rolled-back-setup-leaves-no-timer ()
  (drgnx-timer-own-test--with
      (list :setup (lambda ()
                     (drgnx-timer-start 'own-setup 60 #'drgnx-timer-own-test--note)
                     (error "Setup failed")))
    (drgnx-timer-own-test--on)
    (should (eq (plist-get (alist-get 'test/a drgnx-modules--report) :status) 'failed))
    (should (= 0 (hash-table-count drgnx-timer--table)))
    (should (= 0 (drgnx-timer-own-test--timers)))))

(ert-deftest drgnx-timer-own/off-on-off-three-times-leaves-one-timer-per-key ()
  (drgnx-timer-own-test--with
      (list :setup (lambda ()
                     (drgnx-timer-start 'own-a 60 #'drgnx-timer-own-test--note :repeat 60)
                     (drgnx-timer-start 'own-b 60 #'drgnx-timer-own-test--note :idle t)))
    (dotimes (_ 3)
      (drgnx-timer-own-test--on)
      (should (= 2 (hash-table-count drgnx-timer--table)))
      (should (= 2 (drgnx-timer-own-test--timers)))
      (should-not (drgnx-module-teardown 'test/a))
      (should (= 0 (hash-table-count drgnx-timer--table)))
      (should (= 0 (drgnx-timer-own-test--timers))))))

(ert-deftest drgnx-timer-own/a-buffer-owned-timer-outlives-its-module ()
  ;; owners are separate: a timer owned by a live buffer is not the module's
  (drgnx-timer-own-test--with
      (list :setup (lambda ()
                     (drgnx-timer-start 'own-mod 60 #'drgnx-timer-own-test--note)
                     (drgnx-timer-start 'own-buf 60 #'drgnx-timer-own-test--note :owner drgnx-timer-own-test--buffer)))
    (let ((drgnx-timer-own-test--buffer (generate-new-buffer " own-owner")))
      (unwind-protect
          (progn
            (drgnx-timer-own-test--on)
            (should (= 2 (hash-table-count drgnx-timer--table)))
            (should-not (drgnx-module-teardown 'test/a))
            (should-not (drgnx-timer-active-p 'own-mod))
            (should (drgnx-timer-active-p 'own-buf))
            (should (= 1 (drgnx-timer-own-test--timers)))
            (kill-buffer drgnx-timer-own-test--buffer)
            (should-not (drgnx-timer-active-p 'own-buf))
            (should (= 0 (drgnx-timer-own-test--timers))))
        (when (buffer-live-p drgnx-timer-own-test--buffer) (kill-buffer drgnx-timer-own-test--buffer))))))

(provide 'core-timer-own-test)
;;; core-timer-own-test.el ends here
