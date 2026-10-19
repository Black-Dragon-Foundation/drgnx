;;; modal-isolated-test.el --- batch tests: the tests that load evil run in their own Emacs -*- lexical-binding: t -*-
;; Evil cannot be unloaded from a process, so test/unit/isolated/*.el (not picked up by the main run) run in a
;; fresh batch Emacs through the runner; one test here per file reports the child's result and output.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-evil/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/mod-evil-isolated.el" "^drgnx-evil/"))))

(ert-deftest drgnx-evil-more/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/mod-evil-more-isolated.el"
                                         "^drgnx-evil-more/"))))

(ert-deftest drgnx-evil-flag/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/mod-evil-flag-isolated.el"
                                         "^drgnx-evil-flag/"))))

(ert-deftest drgnx-evil-lazy/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/mod-evil-lazy-isolated.el"
                                         "^drgnx-evil-lazy/"))))

(ert-deftest drgnx-modal-fixture/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/modal-fixture-isolated.el"
                                         "^drgnx-modal-fixture/"))))

(provide 'modal-isolated-test)
;;; modal-isolated-test.el ends here
