;;; core-gc-test.el --- batch tests: GC during and after startup -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-gc)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-gc-test--clocked (&rest body)
  "BODY on the virtual clock, the idle GC's key cancelled after it."
  (declare (indent 0))
  `(drgnx-test-with-clock ()
     (unwind-protect (progn ,@body) (drgnx-gc-mode -1) (drgnx-timer-cancel 'gc-idle))))

(ert-deftest drgnx-gc/startup-collects-rarely-then-a-steady-threshold-and-idle-collection ()
  (let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (should (= gc-cons-threshold drgnx-gc-cons-threshold))
      (should (< gc-cons-percentage 0.6))
      (should (drgnx-timer-active-p 'gc-idle))
      (should (equal (drgnx-timer-describe (car timer-idle-list))
                     '(:key gc-idle :owner :core :kind start :fn drgnx-gc--idle))))))

(ert-deftest drgnx-gc/setup-twice-leaves-one-idle-timer ()
  (let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (drgnx-gc-setup)                                    ; the key is replaced: once only
      (should (= 1 (length timer-idle-list)))
      (should (equal (drgnx-timer-pending) '((gc-idle :core start))))
      (let ((gcs 0) (gc-cons-threshold 1000000))          ; and it collects, once per pause (after real allocation)
        (cl-letf (((symbol-function 'garbage-collect) (lambda () (cl-incf gcs) nil)))
          (let ((junk (make-string 300000 ?x))) (ignore junk))
          (drgnx-test-idle (+ drgnx-gc-idle-seconds 1)))
        (should (= gcs 1))))))

(ert-deftest drgnx-gc/early-init-defers-collection-while-starting-and-always-ends-it ()
  ;; bounded while starting; restored after startup even when drgnx-init never ran (I4)
  (let ((gc-cons-threshold 800000) (gc-cons-percentage 0.1) (default-frame-alist default-frame-alist)
        (emacs-startup-hook nil) (load-prefer-newer load-prefer-newer)
        (process-environment (seq-remove (lambda (e) (string-prefix-p "DRGNX_STARTUP_TRACE=" e)) process-environment))
        (early (expand-file-name "init/early-init.el" drgnx-dir)))
    (load early nil t)
    (should (> gc-cons-threshold (* 100 1024 1024)))
    (should (< gc-cons-threshold most-positive-fixnum))
    (run-hooks 'emacs-startup-hook)                       ; drgnx-init did not run
    (should (<= gc-cons-threshold drgnx-gc-cons-threshold))))

(ert-deftest drgnx-gc/a-failing-drgnx-init-still-sets-the-steady-threshold ()
  (require 'drgnx)
  ;; on the virtual clock: the timers the steps before the failure start (the notice session file's, …) end with it
  (let ((gc-cons-threshold most-positive-fixnum))
    (drgnx-test-with-clock (:allow-pending t)
      (cl-letf (((symbol-function 'drgnx-guard-mode) #'ignore) ((symbol-function 'drgnx-hooks-install) #'ignore)
                ((symbol-function 'drgnx-pkg-activate) #'ignore) ((symbol-function 'drgnx-pkg-guard-mode) #'ignore)
                ((symbol-function 'drgnx--core-commands) (lambda () (error "Broken"))))
        (unwind-protect
            (progn (should-error (drgnx-init))
                   (should (= gc-cons-threshold drgnx-gc-cons-threshold)))
          (drgnx-gc-mode -1)
          (drgnx-timer-cancel 'gc-idle))))))

(ert-deftest drgnx-gc/the-users-own-threshold-is-kept ()
  ;; M8-5: a threshold the user set (no longer early-init's startup value) is left alone.
  (let ((gc-cons-threshold (* 16 1024 1024)) (gc-cons-percentage 0.2))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (should (= gc-cons-threshold (* 16 1024 1024)))
      (should (= gc-cons-percentage 0.2))
      (should (drgnx-timer-active-p 'gc-idle)))))

(ert-deftest drgnx-gc/gcmh-is-left-to-do-its-work ()
  ;; M8-5: gcmh-mode collects at idle and sets the threshold itself: no idle timer, no threshold.
  (skip-unless (not (boundp 'gcmh-mode)))   ; never shadow a loaded gcmh
  (let ((gc-cons-threshold (* 1024 1024 1024)))
    (set 'gcmh-mode t)
    (unwind-protect
        (progn (drgnx-gc-setup)
               (should (= gc-cons-threshold (* 1024 1024 1024)))
               (should-not (drgnx-timer-active-p 'gc-idle)))
      (drgnx-gc-mode -1)
      (drgnx-timer-cancel 'gc-idle)
      (makunbound 'gcmh-mode))))

;;; core-gc-test.el ends here
