;;; modal-panels-test.el --- batch tests: panels under the Vim stack (evil in its own Emacs) -*- lexical-binding: t -*-
;; The tests that load evil are test/unit/isolated/modal-panels-isolated.el, run in a fresh batch Emacs
;; (docs/develop/harness.md, "Modal tests"); this file starts them.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-modal-panels/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/modal-panels-isolated.el"
                                         "^drgnx-modal-panels/"))))

(provide 'modal-panels-test)
;;; modal-panels-test.el ends here
