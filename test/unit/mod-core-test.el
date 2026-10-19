;;; mod-core-test.el --- batch tests: core/basics and core/workbench stay on until restart, recorded exactly -*- lexical-binding: t -*-
;; Both modules are `:teardown 'restart': Preferences turns them off at the next start.  Their record is exact
;; all the same, so a test sets them up strictly and the module helper unwinds them: nothing is left.
(require 'ert)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
;; The libraries the setups load, loaded with this file: their own top level (the panel areas, the routing rules)
;; is theirs and stays, so the leak census does not count it against a test.
(dolist (f '("core/drgnx-basics" "core/drgnx-workbench"))
  (mapc #'require (drgnx-test-modules--requires (expand-file-name (concat "modules/" f ".el") drgnx-dir))))

(defvar drgnx-trust-mode)

(defconst drgnx-mod-core-test--options
  '(ring-bell-function use-dialog-box use-short-answers inhibit-startup-screen
                       native-comp-async-report-warnings-errors project-list-file)
  "The options core/basics sets.")

(defun drgnx-mod-core-test--options ()
  (mapcar (lambda (v) (cons v (if (default-boundp v) (default-value v) 'unbound))) drgnx-mod-core-test--options))

(ert-deftest drgnx-mod-core/basics-stays-on-and-is-recorded-exactly ()
  (let ((before (drgnx-mod-core-test--options)) (trust (bound-and-true-p drgnx-trust-mode)) inside)
    (drgnx-test-with-modules '(core/basics) :strict t
                             (should (eq (plist-get (alist-get 'core/basics (drgnx-modules-report)) :status) 'ok))
                             (should (equal (drgnx-module-teardown 'core/basics) '("restart")))   ; stays on
                             (should (eq ring-bell-function #'ignore))
                             (should drgnx-trust-mode)
                             (should (memq #'drgnx-basics--note-closed (default-value 'kill-buffer-hook)))
                             (setq inside (drgnx-mod-core-test--options)))
    (should-not (equal inside before))
    (should (equal (drgnx-mod-core-test--options) before))
    (should (eq (bound-and-true-p drgnx-trust-mode) trust))))

(ert-deftest drgnx-mod-core/workbench-stays-on-and-is-recorded-exactly ()
  (let ((modes '(drgnx-signal-mode drgnx-rules-mode drgnx-chrome-mode drgnx-frames-mode drgnx-persist-mode)))
    (drgnx-test-with-modules '(core/workbench) :strict t
                             (should (eq (plist-get (alist-get 'core/workbench (drgnx-modules-report)) :status) 'ok))
                             (should (equal (drgnx-module-teardown 'core/workbench) '("restart")))
                             (should (equal (seq-filter #'symbol-value modes) modes)))
    (should-not (seq-filter (lambda (m) (and (boundp m) (symbol-value m))) modes))))

(provide 'mod-core-test)
;;; mod-core-test.el ends here
