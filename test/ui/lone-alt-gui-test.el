;;; lone-alt-gui-test.el --- GUI test: a lone Alt is an event of its own (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real keyboard (`drgnx-uitest-keyboard-type': mutter's RemoteDesktop, sway's wtype, KWin's fake input), whose keys
;; go through the compositor and Nidhogg's shell as a keyboard's do.  Alt pressed and released with nothing between
;; is `lone-alt' (Nidhogg's `nidhogg-lone-modifier-events'), which the VS Code profile binds to the menu (☰); Alt+F
;; stays M-f.

(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defun drgnx-ui-lone-alt--typed (keys)
  "Type KEYS ((NAME . DOWN) ...) on the session's real keyboard; the key events Emacs read after them, in order
\(characters and the lone-modifier symbols; focus and other events left out)."
  (seq-filter (lambda (ev) (or (integerp ev) (memq ev '(lone-alt lone-control lone-shift lone-super))))
              (drgnx-uitest-keyboard-type keys)))

(ert-deftest drgnx-ui-lone-alt/alt-alone-is-lone-alt-and-alt-f-is-m-f ()
  "Alt pressed and released alone reads as `lone-alt'; Alt held over F reads as M-f and no `lone-alt' (VS Code's
compact menu: a lone Alt opens it, Alt+letter opens that menu)."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-keyboard-available-p))
  (should (boundp 'nidhogg-lone-modifier-events))           ; Nidhogg's: a missing primitive is a failure
  (let ((old (symbol-value 'nidhogg-lone-modifier-events)))
    (set 'nidhogg-lone-modifier-events '(alt))
    (unwind-protect
        (progn
          (should (equal (drgnx-ui-lone-alt--typed '(("Alt_L" . t) ("Alt_L" . nil))) '(lone-alt)))
          (should (equal (drgnx-ui-lone-alt--typed '(("Alt_L" . t) ("f" . t) ("f" . nil) ("Alt_L" . nil))) (list ?\M-f)))
          ;; off: a lone Alt is nothing
          (set 'nidhogg-lone-modifier-events nil)
          (should (equal (drgnx-ui-lone-alt--typed '(("Alt_L" . t) ("Alt_L" . nil))) nil)))
      (set 'nidhogg-lone-modifier-events old))))

(provide 'lone-alt-gui-test)
;;; lone-alt-gui-test.el ends here
