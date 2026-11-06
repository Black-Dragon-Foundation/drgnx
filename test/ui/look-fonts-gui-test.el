;;; look-fonts-gui-test.el --- GUI tests: font roles apply at once to every frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every measurement is taken after `drgnx-test-wait-presented', so the frames have been drawn with the
;; new faces.  The role faces are written with no restart; the doctor names a role whose family is not installed.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-look-fonts-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-fonts-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-doctor)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-look-fonts-ui-test--repo) nil t)

(defvar drgnx-look-font-code)
(defvar drgnx-look-font-ui)

(ert-deftest drgnx-ui-look-fonts/live-apply-every-frame ()
  "Pattern D: a size change of the code role resizes `default' on two frames, with no restart; the old size comes
back with the old value."
  (skip-unless (display-graphic-p))
  (let ((second (make-frame '((name . "look-fonts-second"))))
        (first (selected-frame)))
    (unwind-protect
        (progn
          (drgnx-look-fonts-on)
          (drgnx-test-wait-presented)
          (let ((before (mapcar (lambda (f) (frame-char-height f)) (list first second))))
            (let ((drgnx-look-font-code '(:size 1.5)))
              (drgnx-look-fonts-apply)
              (drgnx-test-wait-presented)
              (should (cl-every #'> (mapcar (lambda (f) (frame-char-height f)) (list first second)) before)))
            (drgnx-look-fonts-apply)
            (drgnx-test-wait-presented)
            (should (equal before (mapcar (lambda (f) (frame-char-height f)) (list first second))))))
      (drgnx-look-fonts-off)
      (delete-frame second))))

(ert-deftest drgnx-ui-look-fonts/the-code-font-under-each-theme ()
  "Pattern D: under each of drgnx's themes (they style `default', so Emacs skips its defface spec) the frame's
`default' is the code role's: 13.5 px (`:height' 101), the family when it is installed; a theme loaded before the
faces are written and one loaded after alike."
  (skip-unless (display-graphic-p))
  (let ((was custom-enabled-themes)
        (installed (find-font (font-spec :family "JetBrains Mono"))))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-look-fonts-on)
          (dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast))
            (unless (equal custom-enabled-themes (list theme))
              (mapc #'disable-theme custom-enabled-themes)
              (load-theme theme t))
            (drgnx-test-wait-presented)
            (should (equal (list theme 101) (list theme (face-attribute 'default :height (selected-frame)))))
            (when installed
              (should (equal (list theme "JetBrains Mono")
                             (list theme (face-attribute 'default :family (selected-frame))))))))
      (drgnx-look-fonts-off)
      (mapc #'disable-theme custom-enabled-themes)
      (mapc (lambda (th) (load-theme th t)) (reverse was)))))

(ert-deftest drgnx-ui-look-fonts/fallback-names-the-role ()
  "Pattern D: a family that is not installed is reported for the role that asked for it."
  (skip-unless (display-graphic-p))
  (let ((drgnx-look-font-ui '(:family "Drgnx Missing Family Sans" :fallback ("sans-serif"))))
    (drgnx-look-fonts-on)
    (unwind-protect
        (progn
          (drgnx-test-wait-presented)
          (let ((entry (assq 'ui (drgnx-look-fonts-fallbacks (selected-frame)))))
            (should entry)
            (should (equal "Drgnx Missing Family Sans" (nth 1 entry))))
          (let ((row (drgnx-doctor-check 'fonts (list :font-fallbacks (drgnx-look-fonts-fallback-report)))))
            (should (eq 'warn (car row)))
            (should (string-match-p "ui: Drgnx Missing Family Sans" (cadr row)))))
      (drgnx-look-fonts-off))))

(provide 'look-fonts-gui-test)
;;; look-fonts-gui-test.el ends here
