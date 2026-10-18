;;; mod-evil-ex-test.el --- batch tests: Vim's ex commands, ZZ and C-w keys run drgnx's commands (evil in its own Emacs) -*- lexical-binding: t -*-
;; The tests that load evil are test/unit/isolated/mod-evil-ex-isolated.el, run in a fresh batch Emacs
;; (docs/develop/harness.md, "Modal tests"); this file starts them.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(ert-deftest drgnx-evil-ex/own-process ()
  (should (null (drgnx-modal-test-isolated-result "test/unit/isolated/mod-evil-ex-isolated.el" "^drgnx-evil-ex/"))))

(provide 'mod-evil-ex-test)
;;; mod-evil-ex-test.el ends here
