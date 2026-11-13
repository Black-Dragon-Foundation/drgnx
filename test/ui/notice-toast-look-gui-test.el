;;; notice-toast-look-gui-test.el --- GUI tests: a toast's colours under each theme (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Pattern D: the picture is taken after `drgnx-test-wait-presented'.  A separate file from notice-toast-gui-test.el:
;; loading the look fixture and the themes changes the frame, and the geometry row there reads the plain one.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-notice-toast-look-gui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-notice-toast-look-gui-test--repo)))
(require 'drgnx)
(require 'drgnx-notice-toast)
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-notice-toast-look-gui-test--repo) nil t)

(defconst drgnx-notice-toast-look-gui-test--variants
  '((drgnx-dark . dark) (drgnx-light . light) (drgnx-high-contrast . hc))
  "The themes a toast is checked under, and their token variants.")

(drgnx-look-gui-deftest drgnx-ui-notice-toast/the-toast-is-the-overlay-surface-in-every-variant ()
  "LOOK-FLOAT-LIGHT-HC-ROWS-1, pattern D: under dark, light and high contrast the empty part of a toast (right of its
text, in its first row) is the `overlay' token of that variant; the toast must not take the editor's or the gap's colour."
  (skip-unless (drgnx-uitest-glitnir-p))
  (drgnx-uitest-bare-frame)
  (let ((root (drgnx-uitest-root-frame)) (drgnx-notice-style 'float)
        (drgnx-notice-toast--visible nil) (drgnx-notice-toast--waiting nil))
    (unwind-protect
        (pcase-dolist (`(,theme . ,variant) drgnx-notice-toast-look-gui-test--variants)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (drgnx-notice-toast-delete-all)
          (setq drgnx-notice-toast--visible nil drgnx-notice-toast--waiting nil)
          (drgnx-notice-toast-admit '(:source config :id 1 :severity warn :life event :text "A toast" :detail "More"))
          (drgnx-notice-toast--sync)
          (drgnx-test-wait-presented)
          (let* ((toast (seq-find (lambda (f) (frame-parameter f 'drgnx-notice-toast)) (frame-list)))
                 (s (drgnx-uitest-device-scale root))
                 (pos (frame-position toast))
                 (x (round (* s (+ (car pos) (- (frame-pixel-width toast) 40)))))
                 (y (round (* s (+ (cdr pos) 14))))
                 (want (cons 255 (mapcar (lambda (c) (round (* 255 c)))
                                         (drgnx-color-rgb (drgnx-look-token 'overlay variant)))))
                 (got (drgnx-uitest-pixel (drgnx-uitest-snapshot) x y)))
            (should (equal want got))))
      (drgnx-notice-toast-delete-all)
      (mapc #'disable-theme custom-enabled-themes))))

(provide 'notice-toast-look-gui-test)
;;; notice-toast-look-gui-test.el ends here
