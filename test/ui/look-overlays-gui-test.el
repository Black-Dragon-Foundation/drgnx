;;; look-overlays-gui-test.el --- GUI tests: the region and the matches over text (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every position and picture is read after `drgnx-test-wait-presented'.  A plain buffer in the selected
;; window of a bare frame, under the dark theme, with the decoration boxes at the frame's scale (as ui/look runs them);
;; each overlay face is put on a span of it by an overlay.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-overlays--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-overlays--repo)))
(require 'drgnx)
(require 'drgnx-color)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-ui-look-overlays--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-overlays--repo) nil t)

(defconst drgnx-ui-look-overlays--text "(defun drgnx-sample (alpha beta)\n  (+ alpha beta gamma))\n")

(defmacro drgnx-ui-look-overlays--with (&rest body)
  "BODY in a buffer of `drgnx-ui-look-overlays--text' shown in the selected window of a bare frame, dark theme, the
boxes scaled.  Everything undone after."
  (declare (indent 0))
  `(let ((buf (get-buffer-create " *look-overlays*")))
     (drgnx-uitest-bare-frame)
     (delete-other-windows)
     (mapc #'disable-theme custom-enabled-themes)
     (load-theme 'drgnx-dark t)
     (unwind-protect
         (progn
           (drgnx-decor-scale-on)
           (with-current-buffer buf
             (erase-buffer) (insert drgnx-ui-look-overlays--text) (setq-local cursor-type nil) (goto-char (point-max)))
           (set-window-buffer (selected-window) buf)
           (drgnx-test-wait-presented)
           ,@body)
       (drgnx-decor-scale-off)
       (mapc #'disable-theme custom-enabled-themes)
       (kill-buffer buf))))

(defun drgnx-ui-look-overlays--xys ()
  "The window's (X . Y) of every character of the buffer."
  (with-current-buffer " *look-overlays*"
    (cl-loop for p from (point-min) below (point-max) collect (posn-x-y (posn-at-point p)))))

(defun drgnx-ui-look-overlays--put (face beg end)
  "An overlay of FACE over BEG..END of the sample buffer, presented."
  (prog1 (let ((o (make-overlay beg end (get-buffer " *look-overlays*")))) (overlay-put o 'face face) o)
    (drgnx-test-wait-presented)))

(defun drgnx-ui-look-overlays--rgb (face)
  "FACE's background as (R G B), 8 bits."
  (mapcar (lambda (c) (round (/ c 257.0))) (color-values (face-background face nil t))))

(defun drgnx-ui-look-overlays--near (a b)
  "Non-nil when pixels A and B are within 6 of each other in every channel (an arc's edge is antialiased)."
  (cl-every (lambda (x y) (<= (abs (- x y)) 6)) a b))

(drgnx-look-gui-deftest drgnx-ui-look-overlays/a-box-never-moves-text ()
  "Pattern D: the region, `lazy-highlight' and `isearch' over a span inside a line and over a span across a line's
end leave every character where it was, in x and y: their boxes are drawn inside the glyphs."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-overlays--with
    (let ((plain (drgnx-ui-look-overlays--xys)))
      (dolist (face '(region lazy-highlight isearch))
        (dolist (span '((8 . 13) (22 . 40)))
          (let ((o (drgnx-ui-look-overlays--put face (car span) (cdr span))))
            (unwind-protect (should (equal (list face span plain) (list face span (drgnx-ui-look-overlays--xys))))
              (delete-overlay o))))))))

(drgnx-look-gui-deftest drgnx-ui-look-overlays/the-region-is-rounded-and-isearch-ringed ()
  "Pattern D, window-dark.html `.ln .sel' and design \"Matches\": under Glitnir the region's run has rounded corners
\(its top-left pixel is the editor's colour, its inside, above the text, the selection's), and a region across a
line's end stops there (six columns past it is the editor's colour); the current match is the matches' tint inside a
ring of the accent (its top edge is the accent, its inside the tint, not an opaque accent fill)."
  (skip-unless (and (display-graphic-p) (featurep 'glitnir)))
  (drgnx-ui-look-overlays--with
    (let* ((s (drgnx-uitest-device-scale (selected-frame))) (origin (drgnx-uitest--text-origin (selected-window)))
           (accent (mapcar (lambda (c) (round (/ c 257.0)))
                           (color-values (drgnx-look-token 'accent 'dark)))))
      (cl-flet ((at (pos dx dy) (let ((xy (posn-x-y (posn-at-point pos))))
                                  (list (round (* s (+ (car origin) (car xy) dx)))
                                        (round (* s (+ (cdr origin) (cdr xy) dy)))))))
        (let ((o (drgnx-ui-look-overlays--put 'region 8 20)))
          (unwind-protect
              (let ((snap (drgnx-uitest-snapshot)) (corner (at 8 0 0)) (mid (at 12 (/ (frame-char-width) 2) 3)))
                (should (drgnx-ui-look-overlays--near (cdr (drgnx-uitest-pixel snap (car corner) (cadr corner)))
                                                      (drgnx-ui-look-overlays--rgb 'default)))
                (should (drgnx-ui-look-overlays--near (cdr (drgnx-uitest-pixel snap (car mid) (cadr mid)))
                                                      (drgnx-ui-look-overlays--rgb 'region))))
            (delete-overlay o)))
        (let ((o (drgnx-ui-look-overlays--put 'region 8 40))
              (eol (with-current-buffer " *look-overlays*" (save-excursion (goto-char (point-min)) (pos-eol)))))
          (unwind-protect
              (let ((snap (drgnx-uitest-snapshot)) (past (at eol (* 6 (frame-char-width)) 3)))
                (should (drgnx-ui-look-overlays--near (cdr (drgnx-uitest-pixel snap (car past) (cadr past)))
                                                      (drgnx-ui-look-overlays--rgb 'default))))
            (delete-overlay o)))
        (let ((o (drgnx-ui-look-overlays--put 'isearch 8 20)))
          (unwind-protect
              (let ((snap (drgnx-uitest-snapshot)) (edge (at 12 (/ (frame-char-width) 2) 0))
                    (mid (at 12 (/ (frame-char-width) 2) 3)))
                (should (drgnx-ui-look-overlays--near (cdr (drgnx-uitest-pixel snap (car edge) (cadr edge))) accent))
                (should (drgnx-ui-look-overlays--near (cdr (drgnx-uitest-pixel snap (car mid) (cadr mid)))
                                                      (drgnx-ui-look-overlays--rgb 'lazy-highlight))))
            (delete-overlay o)))))))

(provide 'look-overlays-gui-test)
;;; look-overlays-gui-test.el ends here
