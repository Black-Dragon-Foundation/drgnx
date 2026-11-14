;;; look-themes-test.el --- GUI tests: drgnx's themes paint the surfaces their tokens name -*- lexical-binding: t -*-
;; test-class: det

;; Under each of drgnx's three themes, a text-free pixel of an editor window is the `editor' token, of a window whose
;; text is on `drgnx-surface-panel' the `panel' token, and of the mode line the `gap' token.  Pattern D: every picture
;; is taken after `drgnx-test-wait-presented'.  The Explorer itself takes `panel' when the body-chrome task lands, so
;; the panel row uses a window of its own whose buffer is remapped to the panel face.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-themes--repo           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-themes--repo)))
(require 'drgnx)
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-themes--repo) nil t)

(defun drgnx-ui-look-themes--argb (hex)
  "HEX as the (A R G B) a snapshot pixel is."
  (cons 255 (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb hex))))

(defun drgnx-ui-look-themes--pixel (window x-frac y-frac)
  "The pixel of WINDOW's picture at the fractions X-FRAC, Y-FRAC of its pixel rectangle (device pixels)."
  (pcase-let* ((s (drgnx-uitest-device-scale (window-frame window)))
               (`(,l ,tp ,r ,b) (mapcar (lambda (e) (round (* s e))) (window-pixel-edges window))))
    (drgnx-uitest-pixel (drgnx-uitest-snapshot) (+ l (floor (* x-frac (- r l)))) (+ tp (floor (* y-frac (- b tp)))))))

(drgnx-look-gui-deftest drgnx-ui-look-themes/surface-pixels ()
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create " *look-themes*")))
    (unwind-protect
        (pcase-dolist (`(,variant . ,theme) '((dark . drgnx-dark) (light . drgnx-light) (hc . drgnx-high-contrast)))
          (delete-other-windows)
          (let* ((editor (selected-window)) (side (split-window editor nil 'right)))
            (switch-to-buffer (get-buffer-create "*look-themes-editor*"))
            ;; a mode line without text: the default one ends in ERT's progress, the running test's name, which
            ;; reaches the pixel looked at
            (setq-local mode-line-format " ")
            (with-current-buffer buf
              (erase-buffer)
              (setq-local face-remapping-alist '((default drgnx-surface-panel)) cursor-type nil mode-line-format nil))
            (set-window-buffer side buf)
            (mapc #'disable-theme custom-enabled-themes)
            (load-theme theme t)
            (drgnx-test-wait-presented)
            (let ((token (lambda (name) (drgnx-ui-look-themes--argb (drgnx-look-token name variant)))))
              (should (equal (funcall token 'editor) (drgnx-ui-look-themes--pixel editor 0.5 0.5)))
              (should (equal (funcall token 'panel) (drgnx-ui-look-themes--pixel side 0.5 0.5)))
              ;; the mode line is the bottom row of the editor window's rectangle, at its far right
              (should (equal (funcall token 'gap) (drgnx-ui-look-themes--pixel editor 0.97 0.995))))))
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

(provide 'look-themes-test)
;;; look-themes-test.el ends here
