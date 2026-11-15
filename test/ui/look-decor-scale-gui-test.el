;;; look-decor-scale-gui-test.el --- GUI tests: the decoration boxes at the frame's scale (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the boxes are read from the frame's faces after each change.  The run's scale is DRGNX_UI_SCALE (1,
;; 1.25, 4/3, 1.5, 2); the UI scale (`drgnx-pixels-set-ui-scale' on the root frame) takes the frame to 2 within the row.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-look-decor-scale-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-decor-scale-ui-test--repo)))
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-look-decor-scale-ui-test--repo) nil t)

(defconst drgnx-look-decor-scale-ui-test--want
  '((1.0 1 2 8) (1.25 1 3 10) (1.3333333333333333 1 3 11) (1.5 1 3 12) (2.0 2 4 16))
  "Per scale: a card's edge, the focus ring's width, a card's radius, in device pixels.")

(defun drgnx-look-decor-scale-ui-test--drawn (face)
  "The width FACE's box is drawn at in the selected window, in device pixels: half of what it adds to a line's height
\(a positive width is drawn outside the glyphs, above and below).  Read from the glyph rows, not the face: the shell
may scale a face's width when it realizes it."
  (let ((b (get-buffer-create " *look-decor-drawn*")))
    (with-current-buffer b
      (erase-buffer)
      (insert "x\n" (propertize "x" 'face face) "\n")
      (set-window-buffer (selected-window) b)
      (redisplay t)
      (save-excursion
        (goto-char (point-min))
        (let ((plain (line-pixel-height)))
          (forward-line 1)
          (/ (- (line-pixel-height) plain) 2))))))

(defun drgnx-look-decor-scale-ui-test--check (frame)
  "The boxes on FRAME are drawn at the table's widths for FRAME's whole scale, and the radius is the table's."
  (let* ((s (drgnx-pixels-scale frame))
         (want (cdr (seq-find (lambda (r) (< (abs (- (car r) s)) 0.001)) drgnx-look-decor-scale-ui-test--want)))
         (card (face-attribute 'drgnx-card-single :box frame)))
    (should want)
    (should (equal (list 'card (drgnx-look-decor-scale-ui-test--drawn 'drgnx-card-single)) (list 'card (nth 0 want))))
    (should (equal (list 'ring (drgnx-look-decor-scale-ui-test--drawn 'drgnx-focus-ring)) (list 'ring (nth 1 want))))
    (when (featurep 'glitnir)
      (should (equal (plist-get card :corner-radius) (nth 2 want))))))

(drgnx-look-gui-deftest drgnx-ui-look-decor/boxes-follow-the-scale ()
  "Pattern D: with the boxes on, the frame's card edge, focus ring and card radius are the run's scale's; a UI scale
that takes the frame to 2 gives 2's at once (the density's change hook, which the UI scale runs); a scale change
\(Nidhogg's `nidhogg-frame-scale-change-functions') after the UI scale goes gives the run's values back; off, the
logical boxes come back."
  (skip-unless (display-graphic-p))
  (let ((f (selected-frame)) (faces '(drgnx-card-single drgnx-focus-ring)))
    (unwind-protect
        (progn
          ;; the Glitnir boxes (radius too), as ui/look's `drgnx-decor-faces-on' gives them
          (dolist (face faces)
            (face-spec-set face `((t :inherit secondary-selection :box ,(drgnx-decor-box face)))))
          (drgnx-decor-scale-on)
          (drgnx-look-decor-scale-ui-test--check f)
          (drgnx-pixels-set-ui-scale f (/ 2.0 (drgnx-pixels-scale f)))
          (run-hooks 'drgnx-look-density-changed-hook)
          (should (< (abs (- (drgnx-pixels-scale f) 2.0)) 0.001))
          (drgnx-look-decor-scale-ui-test--check f)
          (drgnx-pixels-set-ui-scale f nil)
          (run-hook-with-args 'nidhogg-frame-scale-change-functions f)
          (drgnx-look-decor-scale-ui-test--check f)
          (drgnx-decor-scale-off)
          (should (equal (plist-get (face-attribute 'drgnx-card-single :box f) :line-width) 1)))
      (drgnx-pixels-set-ui-scale f nil)
      (drgnx-decor-scale-off)
      (dolist (face faces) (face-spec-set face (get face 'face-defface-spec)))
      (when (get-buffer " *look-decor-drawn*") (kill-buffer " *look-decor-drawn*")))))

(provide 'look-decor-scale-gui-test)
;;; look-decor-scale-gui-test.el ends here
