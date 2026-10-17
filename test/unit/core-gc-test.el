;;; core-gc-test.el --- batch tests: GC during and after startup -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-gc)
(require 'drgnx-paths)

(ert-deftest drgnx-gc/startup-collects-rarely-then-a-steady-threshold-and-idle-collection ()
  (let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6) (timer-idle-list nil))
    (drgnx-gc-setup)
    (should (= gc-cons-threshold drgnx-gc-cons-threshold))
    (should (< gc-cons-percentage 0.6))
    (should (seq-find (lambda (tm) (eq (timer--function tm) #'drgnx-gc--idle)) timer-idle-list))
    (drgnx-gc-setup)                                    ; once only
    (should (= 1 (seq-count (lambda (tm) (eq (timer--function tm) #'drgnx-gc--idle)) timer-idle-list)))))

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
  (let ((gc-cons-threshold most-positive-fixnum) (timer-idle-list nil))
    (cl-letf (((symbol-function 'drgnx-guard-mode) #'ignore) ((symbol-function 'drgnx-hooks-install) #'ignore)
              ((symbol-function 'drgnx-pkg-activate) #'ignore) ((symbol-function 'drgnx-pkg-guard-mode) #'ignore)
              ((symbol-function 'drgnx--core-commands) (lambda () (error "Broken"))))
      (should-error (drgnx-init))
      (should (= gc-cons-threshold drgnx-gc-cons-threshold)))))

;;; core-gc-test.el ends here
