;;; icons-gui-test.el --- GUI tests: an icon takes its face's colour (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the picture is taken after `drgnx-test-wait-presented'.  An icon drawn in `shadow' on the editor's
;; background has its darkest (most different from the background) stroke pixel within 24 per channel of the
;; face's foreground (anti-aliasing), at whatever scale the run has (DRGNX_UI_SCALE: 1, 1.25, 2).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-icons-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-icons-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-icons)

(ert-deftest drgnx-ui-icons/icon-takes-the-face-colour ()
  "Pattern D: a `folder' icon in `shadow' shows `shadow''s foreground, not the default text colour."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'svg))
  (drgnx-uitest-bare-frame)
  (with-current-buffer (get-buffer-create "*icons-ui*")
    (erase-buffer)
    ;; no cursor: its box sits in the scanned row and is further from the background than any stroke pixel
    (setq-local cursor-type nil)
    (insert (make-string 6 ?\s) (drgnx-look-icon 'folder 'shadow) (make-string 6 ?\s) "\n")
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (drgnx-test-wait-presented)
    (let* ((rgb (lambda (name attr) (mapcar (lambda (c) (/ c 257)) (color-values (funcall attr name nil t)))))
           (want (funcall rgb 'shadow #'face-foreground))
           (bg (funcall rgb 'default #'face-background))
           (s (drgnx-uitest-device-scale (selected-frame)))
           (edges (window-pixel-edges))
           (snap (drgnx-uitest-snapshot))
           (best nil) (best-d nil))
      ;; the stroke pixels are those furthest from the background in the window's first text row
      (cl-loop for y from (round (* s (nth 1 edges))) below (round (* s (+ (nth 1 edges) (line-pixel-height))))
               do (cl-loop for x from (round (* s (nth 0 edges))) below (round (* s (nth 2 edges)))
                           do (let* ((v (cdr (drgnx-uitest-pixel snap x y)))
                                     (d (apply #'+ (cl-mapcar (lambda (a b) (abs (- a b))) v bg))))
                                (when (or (null best-d) (> d best-d)) (setq best v best-d d)))))
      (should best)
      (should (cl-every (lambda (a b) (<= (abs (- a b)) 24)) best want)))
    (kill-buffer "*icons-ui*")))

(require 'drgnx-monitors-fixture (expand-file-name "../fixtures/monitors-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-pixels)

(defun drgnx-icons-ui-test--drawn-width (icon)
  "The width ICON takes in the selected window once presented: its row's text pixel width less the spaces'."
  (with-current-buffer (get-buffer-create "*icons-ui*")
    (erase-buffer)
    (setq-local cursor-type nil)
    (insert "x" icon "x")
    (set-window-buffer (selected-window) (current-buffer))
    (drgnx-test-wait-presented)
    (- (car (window-text-pixel-size nil 1 4)) (car (window-text-pixel-size nil 1 2))
       (car (window-text-pixel-size nil 3 4)))))

(defun drgnx-icons-ui-test--sizes-at (frame s)
  "On FRAME (selected), a 16 px and a 14 px icon are `drgnx-px' of them at total scale S, as images and as drawn."
  (dolist (size '(16 14))
    (let* ((icon (drgnx-look-icon 'folder nil size)) (want (drgnx-px size frame s)))
      (should (equal (image-size (get-text-property 0 'display icon) t frame) (cons want want)))
      (when (eq frame (drgnx-uitest-root-frame))
        (should (= (drgnx-icons-ui-test--drawn-width icon) want))))))

(ert-deftest drgnx-ui-icons/size-at-the-frame-scale ()
  "Pattern D: an icon is `drgnx-px' of its size at the frame's scale, a whole number of the frame's pixels (16 px:
16, 20, 21, 24, 32 at 1, 1.25, 4/3, 1.5, 2), as an image and as drawn; at a UI scale of 110 % it is the display scale
× 1.1 (22 at 1.25); on a second monitor at another scale, an icon made there has that monitor's size."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'svg))
  (drgnx-uitest-bare-frame)
  (let* ((f (selected-frame)) (s (float (frame-scale-factor f))))
    (unwind-protect
        (progn
          (drgnx-icons-ui-test--sizes-at f s)
          (drgnx-pixels-set-ui-scale f 1.1)
          (drgnx-icons-ui-test--sizes-at f (* s 1.1))
          (drgnx-pixels-set-ui-scale f nil)
          (drgnx-icons-ui-test--sizes-at f s)
          (when (drgnx-test-second-monitor-p)
            (let ((g (drgnx-test-frame-on-second-monitor "drgnx-icons-second")))
              (unwind-protect
                  (let ((s2 (float (frame-scale-factor g))))
                    (with-selected-frame g (drgnx-icons-ui-test--sizes-at g s2))
                    (should-not (= (drgnx-px 16 g s2) (drgnx-px 16 f s)))
                    (drgnx-icons-ui-test--sizes-at f s))
                (delete-frame g)))))
      (drgnx-pixels-set-ui-scale f nil)
      (when (get-buffer "*icons-ui*") (kill-buffer "*icons-ui*")))))

(provide 'icons-gui-test)
;;; icons-gui-test.el ends here
