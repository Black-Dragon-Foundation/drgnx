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

(ert-deftest drgnx-gc/early-init-defers-collection-while-starting ()
  (let ((gc-cons-threshold 800000) (early (expand-file-name "init/early-init.el" drgnx-dir)))
    (load early nil t)
    (should (= gc-cons-threshold most-positive-fixnum))))

;;; core-gc-test.el ends here
