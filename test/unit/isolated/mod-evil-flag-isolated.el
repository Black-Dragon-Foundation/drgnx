;;; mod-evil-flag-isolated.el --- batch tests (own Emacs, test/unit/modal-isolated-test.el): the no-collection flag of editor/evil -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it the test skips.
;; Its own file because evil-collection cannot be unloaded: the first engine start of a process registers it, so
;; "the flag keeps it out" needs a process where nothing started the engine before.  The macros come from
;; mod-evil-isolated.el (its tests are defined too, never selected here).
(require 'ert)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "test/unit/isolated/mod-evil-isolated" drgnx-dir) nil t)

(declare-function dired "dired")

(defun drgnx-evil-flag-test--flag (root)
  "In the temp configuration under ROOT: editor/evil is chosen and has the flag no-collection."
  (write-region (concat "(drgnx-settings :version 1 (drgnx-modules-enabled (editor/evil))"
                        " (drgnx-modules-flags ((editor/evil no-collection)))"
                        " (drgnx-keys-layers ((vim app editing window))))\n")
                nil (concat root "config/settings.el") nil 'silent))

;; dired is loaded in this process already (the Explorer needs it); ediff is not.
(ert-deftest drgnx-evil-flag/keeps-collection-keys-out ()
  (drgnx-evil-test--fresh 'evil 'evil-collection 'evil-collection-dired 'ediff)
  (drgnx-evil-test--with
    (drgnx-evil-flag-test--flag root)
    (should (drgnx-module-flag-p 'editor/evil 'no-collection))
    (require 'dired)                    ; the Explorer no longer loads it
    (should (eq (drgnx-evil-test--run) 'ok))
    (should (eq drgnx-modal-running 'evil))
    (should-not (featurep 'evil-collection))
    (should-not (featurep 'evil-collection-dired))
    (require 'ediff)
    (should-not (featurep 'evil-collection-ediff))
    (let ((buf (dired (file-name-as-directory (concat root "home")))))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (should-not (eq (key-binding "j") 'dired-next-line)))
        (kill-buffer buf)))))

(provide 'mod-evil-flag-isolated)
;;; mod-evil-flag-isolated.el ends here
