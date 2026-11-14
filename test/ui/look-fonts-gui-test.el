;;; look-fonts-gui-test.el --- GUI tests: font roles apply at once to every frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every measurement is taken after `drgnx-test-wait-presented', so the frames have been drawn with the
;; new faces.  The role faces are written with no restart; the doctor names a role whose family is not installed.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
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

(drgnx-look-gui-deftest drgnx-ui-look-fonts/live-apply-every-frame ()
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
      (delete-frame second)
      (drgnx-look-fonts-off))))

(drgnx-look-gui-deftest drgnx-ui-look-fonts/off-puts-the-session-font-back ()
  "Pattern D: on, then off: the frame's `font' and `default''s attributes (for new frames and on the frame) are the
session's again; off undoes all of on, at once."
  (skip-unless (display-graphic-p))
  (let* ((f (selected-frame))
         (now (lambda () (list (frame-parameter f 'font) (face-attribute 'default :family f)
                               (mapcar (lambda (a) (face-attribute 'default a t)) '(:family :foundry :height :weight)))))
         (was (funcall now)))
    (unwind-protect
        (progn
          (drgnx-look-fonts-on)
          (drgnx-test-wait-presented)
          (should-not (equal was (funcall now)))          ; on changed the font
          (drgnx-look-fonts-off)
          (drgnx-test-wait-presented)
          (should (equal was (funcall now))))
      (drgnx-look-fonts-off))))

(drgnx-look-gui-deftest drgnx-ui-look-fonts/the-code-font-under-each-theme ()
  "Pattern D: under each of drgnx's themes (they style `default', so Emacs skips its defface spec) the frame's
`default' is the code role's, not the frame's own font: with the code role following the desktop and the desktop
answering a 27 px monospace font (twice the 13.5 px default, so the frame's lines are plainly taller whatever fonts
the machine has), and with the defaults the family when it is installed; a theme loaded before the faces are written
and one loaded after alike."
  (skip-unless (display-graphic-p))
  (let ((was custom-enabled-themes)
        (installed (find-font (font-spec :family "JetBrains Mono"))))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-test-wait-presented)
          (let ((plain (frame-char-height)))
            (drgnx-look-fonts-on)
            (when installed
              (drgnx-test-wait-presented)
              (should (equal "JetBrains Mono" (face-attribute 'default :family (selected-frame)))))
            (let ((drgnx-look-font-code 'follow-desktop))
              (drgnx-look-fonts-desktop-answer '(:ui ("sans-serif" . 13) :code ("monospace" . 27)))
              (dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast))
                (unless (equal custom-enabled-themes (list theme))
                  (mapc #'disable-theme custom-enabled-themes)
                  (load-theme theme t))
                (drgnx-test-wait-presented)
                (should (equal (list theme t) (list theme (> (frame-char-height) (* 1.5 plain)))))))))
      (drgnx-look-fonts-off)
      (drgnx-look-fonts-reset)
      (mapc #'disable-theme custom-enabled-themes)
      (mapc (lambda (th) (load-theme th t)) (reverse was)))))

(drgnx-look-gui-deftest drgnx-ui-look-fonts/fallback-names-the-role ()
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
