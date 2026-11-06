;;; faces-test.el --- batch tests: the semantic faces and the hover-revealed control -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure; face specs and a fixture theme read back, no process, timer or window state.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-faces)

(defun drgnx-faces-test--spec-attr (face attr)
  "ATTR in FACE's defface spec, the clause for any display."
  (plist-get (cdr (assq t (get face 'face-defface-spec))) attr))

(ert-deftest drgnx-faces/third-party-defaults-inherit-standard-faces ()
  (pcase-dolist (`(,face . ,parent)
                 '((drgnx-surface-gap . default) (drgnx-surface-panel . default) (drgnx-surface-raised . default)
                   (drgnx-surface-overlay . default)
                   (drgnx-text-muted . shadow) (drgnx-text-subtle . shadow) (drgnx-text-disabled . shadow)
                   (drgnx-border . window-divider) (drgnx-border-strong . vertical-border)
                   (drgnx-accent . link) (drgnx-hover . highlight) (drgnx-selected . region)
                   (drgnx-selected-quiet . drgnx-surface-raised) (drgnx-status-attention . error)
                   (drgnx-agent-1 . default) (drgnx-agent-2 . default) (drgnx-agent-3 . default)
                   (drgnx-agent-4 . default) (drgnx-agent-5 . default) (drgnx-agent-6 . default)))
    (should (facep face))
    (should (eq parent (drgnx-faces-test--spec-attr face :inherit))))
  (should-not (drgnx-faces-test--spec-attr 'drgnx-accent :underline))
  (should (eq 'drgnx-hover (car (ensure-list (drgnx-faces-test--spec-attr 'drgnx-hover-row :inherit)))))
  (should (facep 'drgnx-focus))
  (should (facep 'drgnx-control-hidden)))

(ert-deftest drgnx-faces/hover-has-the-focus-box-widths ()
  (let ((hover (drgnx-faces-test--spec-attr 'drgnx-hover :box))
        (focus (drgnx-faces-test--spec-attr 'drgnx-focus :box)))
    (should (equal '(-2 . -2) (plist-get hover :line-width)))
    (should (equal (plist-get hover :line-width) (plist-get focus :line-width)))))

(ert-deftest drgnx-faces/hover-control-hidden-then-real ()
  (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (&rest _) 'gui)))
    (should (eq 'drgnx-control-hidden (get-text-property 0 'face (drgnx-look-hover-control "×"))))
    (should (eq 'drgnx-ui-close (get-text-property 0 'face (drgnx-look-hover-control "×" t)))))
  (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (&rest _) 'tty)))
    (should (eq 'drgnx-ui-close (get-text-property 0 'face (drgnx-look-hover-control "×"))))))

(ert-deftest drgnx-faces/face-color-resolves-inherit-for-gui ()
  (deftheme drgnx-faces-test-fixture "Fixture: region gets a background, with a clause for 256-colour terminals.")
  (custom-theme-set-faces
   'drgnx-faces-test-fixture
   '(region ((((type tty) (min-colors 256)) :background "color-18") (t :background "#112233"))))
  (provide-theme 'drgnx-faces-test-fixture)
  (unwind-protect
      (progn
        (enable-theme 'drgnx-faces-test-fixture)
        (should (equal "#112233" (drgnx-face-color 'drgnx-selected :background 'gui)))
        (should (equal "color-18" (drgnx-face-color 'drgnx-selected :background 'tty256)))
        (should-not (drgnx-face-color 'drgnx-selected :foreground 'gui)))
    (disable-theme 'drgnx-faces-test-fixture)))

(ert-deftest drgnx-faces/needs-you-inherits-attention ()
  (should (eq 'drgnx-status-attention (face-attribute 'drgnx-status-needs-you :inherit nil nil))))

(provide 'faces-test)
;;; faces-test.el ends here
