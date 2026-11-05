;;; mod-evil-setq-isolated.el --- batch tests (own Emacs, test/unit/modal-isolated-test.el): editor/evil and the user's own setq -*- lexical-binding: t -*-
;; test-class: det
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it the test skips.
;; Its own file because evil cannot be unloaded: the test needs a process where nothing loaded evil before.  The
;; macros come from mod-evil-isolated.el (its tests are defined too, never selected here).
(require 'ert)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "test/unit/isolated/mod-evil-isolated" drgnx-dir) nil t)

(ert-deftest drgnx-evil-setq/setup-does-not-pass-for-the-users-own-setq ()
  ;; the flag evil reads as it loads is bound for the load, not set: no `changed' stash (the user's value, which
  ;; would win over the module from then on) and the module's claim holds the value
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vim app editing window)) t
      (should-not (featurep 'evil))
      (should (eq (drgnx-evil-test--run) 'ok))
      (should (eq evil-want-C-u-scroll t))
      (should-not (assq 'changed (get 'evil-want-C-u-scroll 'theme-value)))
      (should (assq 'drgnx (get 'evil-want-C-u-scroll 'theme-value)))
      (should (eq (keymap-lookup evil-motion-state-map "C-u") #'evil-scroll-up)))))

(provide 'mod-evil-setq-isolated)
;;; mod-evil-setq-isolated.el ends here
