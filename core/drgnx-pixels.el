;;; drgnx-pixels.el --- the look's pixel measure: how wide a string is, in a face -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The bars and the tab rows are laid out in pixels, not columns.  `drgnx-look-pixel-width' is the one function that
;; measures a string in a face.  It runs only when a row's memo changes, never from an `:eval' on its own: callers
;; keep the result in their memo, keyed on `drgnx-pixels-generation' (which the font roles bump) and on the frame's
;; character cell, so a zoom, a scale change or a font change measures again.
;;
;; `string-pixel-width' shows its text in a temporary window, which fires the window and buffer hooks; the measure
;; keeps those quiet and does not nest (a measure asked for while one runs gives an estimate from the cell width).
;; It also reports two pixels more than the advances of the glyphs: the slack is worked out per face from
;; 2 × width("x") − width("xx") and taken off, so a string measures the width its glyphs are drawn in.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar drgnx-pixels-generation 0
  "Counts the changes of the fonts the measure depends on (the font roles): part of the memo keys of the bars.")

(defconst drgnx-pixels--quiet-hooks
  '(window-buffer-change-functions window-configuration-change-hook window-selection-change-functions
                                   window-state-change-functions window-size-change-functions buffer-list-update-hook)
  "The hooks the measure's temporary window must not fire.")

(defvar drgnx-pixels--measuring nil "Non-nil while a measure runs.")

(defun drgnx-pixels--raw-width (string face)
  "`string-pixel-width' of STRING with FACE added, with the window and buffer hooks quiet."
  (let ((s (copy-sequence string)) (drgnx-pixels--measuring t))
    (when face (add-face-text-property 0 (length s) face t s))
    (cl-progv drgnx-pixels--quiet-hooks (make-list (length drgnx-pixels--quiet-hooks) nil)
      (string-pixel-width s))))

(defvar drgnx-pixels--slack nil
  "(KEY . PIXELS): the slack `string-pixel-width' adds in the faces of KEY (the face, the frame's character cell,
`drgnx-pixels-generation').")

(defun drgnx-pixels--slack (face)
  "The slack for FACE, worked out again when the face, the character cell or the fonts change."
  (let ((key (list face (frame-char-width) (frame-char-height) drgnx-pixels-generation)))
    (unless (equal (car drgnx-pixels--slack) key)
      (setq drgnx-pixels--slack
            (cons key (- (* 2 (drgnx-pixels--raw-width "x" face)) (drgnx-pixels--raw-width "xx" face)))))
    (cdr drgnx-pixels--slack)))

(defun drgnx-look-pixel-width (string &optional face)
  "The width of STRING in pixels (the advances of its glyphs), shown in FACE (a face or a list of faces) on top of
its own faces.  Call it when a row's memo changes, never on every redisplay."
  (cond ((string-empty-p string) 0)
        (drgnx-pixels--measuring (* (string-width string) (frame-char-width)))   ; asked for while one runs: an estimate
        (t (max 0 (- (drgnx-pixels--raw-width string face) (drgnx-pixels--slack face))))))

;;;; Rows of an exact height

(defun drgnx-pixels-scale (&optional frame)
  "FRAME's scale (1.0 without a native shell): a logical pixel is this many device pixels."
  (if (fboundp 'frame-scale-factor) (float (frame-scale-factor frame)) 1.0))

(defun drgnx-pixels-font-extent (face &optional frame)
  "(ASCENT . DESCENT) in pixels of the font FACE shows on a graphical FRAME, or nil (a terminal, no such font)."
  (let ((frame (or frame (selected-frame))))
    (when (display-graphic-p frame)
      (when-let* ((font (ignore-errors (face-font face frame ?x)))
                  (info (ignore-errors (font-info font frame))))
        (cons (aref info 7) (aref info 8))))))

(defun drgnx-pixels-box-height (face height &optional frame)
  "The width of the box above and below text in FACE that makes a row of HEIGHT pixels (0 when the text is taller or
the frame has no such font): a box of this width on both sides leaves the row at most one pixel short."
  (if-let* ((extent (drgnx-pixels-font-extent face frame)))
      (max 0 (/ (- height (car extent) (cdr extent)) 2))
    0))

(defun drgnx-pixels-spacer (face height descent &optional frame)
  "A string of one character, no width, that makes the row it is in HEIGHT pixels high with DESCENT pixels below the
baseline: the text on that row keeps its place and sits DESCENT above the row's bottom.  nil when the frame has no
font to measure (a terminal) or the row is already tall enough."
  (when-let* ((extent (drgnx-pixels-font-extent face frame))
              ((> height (+ (car extent) (cdr extent)))))
    (let* ((ascent (- height (max descent (cdr extent))))
           (pct (min 100 (ceiling (* 100.0 ascent) height))))
      (propertize " " 'face face 'display `(space :width (1) :height (,height) :ascent ,pct)))))

(provide 'drgnx-pixels)
;;; drgnx-pixels.el ends here
