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

(provide 'icons-gui-test)
;;; icons-gui-test.el ends here
