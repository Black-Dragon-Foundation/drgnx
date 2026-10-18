;;; modal-fixture-test.el --- batch tests: the modal test fixture finds evil in DRGNX_MODAL_ELPA and never writes there -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(ert-deftest drgnx-modal-fixture/finds-evil ()
  (drgnx-modal-test-with-evil
    (require 'evil)
    (should (featurep 'evil))
    (should (locate-library "evil-collection"))))

(ert-deftest drgnx-modal-fixture/never-writes-the-elpa ()
  (drgnx-modal-test-with-evil
    (let ((before (drgnx-modal-test--listing)))
      (require 'evil)
      (require 'evil-collection)
      (should (equal before (drgnx-modal-test--listing))))))

(provide 'modal-fixture-test)
;;; modal-fixture-test.el ends here
