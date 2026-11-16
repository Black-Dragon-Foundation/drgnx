;;; lone-alt-gui-test.el --- GUI test: a lone Alt is an event of its own (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real keyboard: headless mutter's RemoteDesktop session types keysyms, which go through the compositor and
;; Nidhogg's shell as a keyboard's keys do.  Alt pressed and released with nothing between is `lone-alt' (Nidhogg's
;; `nidhogg-lone-modifier-events'), which the VS Code profile binds to the menu (☰); Alt+F stays M-f.  Mutter only.

(require 'ert)
(require 'dbus)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-lone-alt--rd "org.gnome.Mutter.RemoteDesktop" "Mutter's RemoteDesktop service and interface.")

(defun drgnx-ui-lone-alt--typed (keys)
  "Type KEYS ((KEYSYM . DOWN) ...) on a RemoteDesktop keyboard; the key events Emacs read after them, in order
\(characters and the lone-modifier symbols; focus and other events left out), read until none came for half a
second.  The keys go without waiting for their answers: `dbus-call-method' reads events while it waits, and a key
read there is lost."
  (let* ((rd drgnx-ui-lone-alt--rd) (iface (concat rd ".Session"))
         (path (dbus-call-method :session rd "/org/gnome/Mutter/RemoteDesktop" rd "CreateSession"))
         (got nil) (ev nil))
    (dbus-call-method :session rd path iface "Start")
    (unwind-protect
        (progn
          ;; the virtual keyboard's first key reaches no one
          (dbus-call-method :session rd path iface "NotifyKeyboardKeysym" :uint32 #xffe1 t)
          (dbus-call-method :session rd path iface "NotifyKeyboardKeysym" :uint32 #xffe1 nil)
          (while (read-event nil nil 0.5))
          (dolist (k keys)
            (dbus-call-method-asynchronously :session rd path iface "NotifyKeyboardKeysym" nil
                                             :uint32 (car k) (and (cdr k) t)))
          (while (setq ev (read-event nil nil 0.5))
            (when (or (integerp ev) (memq ev '(lone-alt lone-control lone-shift lone-super)))
              (push ev got))))
      (ignore-errors (dbus-call-method :session rd path iface "Stop")))
    (nreverse got)))

(ert-deftest drgnx-ui-lone-alt/alt-alone-is-lone-alt-and-alt-f-is-m-f ()
  "Alt pressed and released alone reads as `lone-alt'; Alt held over F reads as M-f and no `lone-alt' (VS Code's
compact menu: a lone Alt opens it, Alt+letter opens that menu)."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (should (boundp 'nidhogg-lone-modifier-events))           ; Nidhogg's: a missing primitive is a failure
  (let ((old (symbol-value 'nidhogg-lone-modifier-events)))
    (set 'nidhogg-lone-modifier-events '(alt))
    (unwind-protect
        (progn
          (should (equal (drgnx-ui-lone-alt--typed '((#xffe9 . t) (#xffe9 . nil))) '(lone-alt)))
          (should (equal (drgnx-ui-lone-alt--typed '((#xffe9 . t) (?f . t) (?f . nil) (#xffe9 . nil))) (list ?\M-f)))
          ;; off: a lone Alt is nothing
          (set 'nidhogg-lone-modifier-events nil)
          (should (equal (drgnx-ui-lone-alt--typed '((#xffe9 . t) (#xffe9 . nil))) nil)))
      (set 'nidhogg-lone-modifier-events old))))

(provide 'lone-alt-gui-test)
;;; lone-alt-gui-test.el ends here
