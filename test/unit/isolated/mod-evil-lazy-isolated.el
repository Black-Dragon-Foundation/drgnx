;;; mod-evil-lazy-isolated.el --- batch tests (own Emacs, test/unit/modal-isolated-test.el): evil-collection loads each mode's keys with the mode's library -*- lexical-binding: t -*-
;; Needs the real evil and evil-collection: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it the
;; test skips.  Its own file because a library cannot be unloaded: the test needs a process where `info' and `magit'
;; are not loaded.  The macros come from mod-evil-isolated.el (its tests are defined too, never selected here).
(require 'ert)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "test/unit/isolated/mod-evil-isolated" drgnx-dir) nil t)

(declare-function dired "dired")

;; dired is loaded in this process already (the Explorer needs it), so its keys are in at once; `info' is the
;; library that arrives later.
(ert-deftest drgnx-evil-lazy/collection-waits-for-each-mode ()
  (drgnx-evil-test--fresh 'evil 'evil-collection 'info 'magit 'evil-collection-info)
  (drgnx-evil-test--running
    (should (featurep 'evil-collection))
    (should (featurep 'evil-collection-dired))
    (let ((buf (dired (file-name-as-directory (concat root "home")))))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (should (eq evil-state 'normal))
            (should (eq (key-binding "j") 'dired-next-line)))
        (kill-buffer buf)))
    (should-not (featurep 'evil-collection-info))
    (should-not (featurep 'evil-collection-magit))
    (require 'info)
    (should (featurep 'evil-collection-info))
    (should-not (featurep 'evil-collection-magit))))

(provide 'mod-evil-lazy-isolated)
;;; mod-evil-lazy-isolated.el ends here
