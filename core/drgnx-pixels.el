;;; drgnx-pixels.el --- the look's pixels: logical to frame pixels, and how wide a string is -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The look's sizes are logical pixels.  `drgnx-px' turns one into the frame's own pixels (device pixels on Nidhogg's
;; native shells, at any scale) with one rounding rule, half up, and `drgnx-px-line' does it for lines, which stay
;; whole and at least one pixel.  Every size the look draws goes through them, never its own `frame-scale-factor'.
;;
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

;;;; Logical pixels to frame pixels: the one rule

(defun drgnx-pixels-device-p ()
  "Non-nil when frame pixels are device pixels: Nidhogg's native shells (Wayland and Naglfar).  Elsewhere (a
terminal, a port that lays out in logical pixels) a frame pixel is a logical pixel."
  (or (featurep 'nidhogg-wayland) (featurep 'naglfar)))

(defvar drgnx-pixels--ui-scales (make-hash-table :test #'eq :weakness 'key)
  "Root frame → its UI scale, a float other than 1.0 (`drgnx-pixels-set-ui-scale').  A table, not a frame parameter:
`frame-parameter' copies the frame's whole parameter list to read a parameter of drgnx's own, and the scale is read
on every bar build and row.  Weak on the frame: an entry goes with its frame.")

(defun drgnx-pixels-set-ui-scale (frame scale)
  "Give the root FRAME the UI scale SCALE (a number; nil or 1: none), which `drgnx-pixels-ui-scale' reads."
  (if (and (numberp scale) (/= scale 1))
      (puthash frame (float scale) drgnx-pixels--ui-scales)
    (remhash frame drgnx-pixels--ui-scales)))

(defun drgnx-pixels-ui-scale (&optional frame)
  "The UI scale on FRAME (default the selected frame): its root frame's, which the look's UI scale sets
\(modules/ui/drgnx-look-scale.el, through `drgnx-pixels-set-ui-scale'); 1.0 without one.  Conses nothing."
  (let ((f (or frame (selected-frame))))
    (while (frame-parent f) (setq f (frame-parent f)))
    (gethash f drgnx-pixels--ui-scales 1.0)))

(defun drgnx-pixels-scale (&optional frame)
  "FRAME's frame pixels per logical pixel: its display scale on a native shell (1.0 elsewhere) times the UI scale."
  (* (if (and (drgnx-pixels-device-p) (fboundp 'frame-scale-factor)) (float (frame-scale-factor frame)) 1.0)
     (drgnx-pixels-ui-scale frame)))

(defconst drgnx-pixels--epsilon 1e-9
  "What `drgnx-px' and `drgnx-px-line' forgive a product: 1.5 × 4/3 is 1.9999999999999998 in floats.")

(defun drgnx-px (logical &optional frame scale)
  "LOGICAL pixels in FRAME's own pixels, rounded half up (Emacs's `round' sends 32.5 to 32 but 47.5 to 48, so
neighbouring sizes would wobble in opposite directions).  SCALE, when given, replaces FRAME's (`drgnx-pixels-scale').
A size made of parts adds the parts' results: the sum of rounded parts, never the rounded sum."
  (floor (+ (* logical (or scale (drgnx-pixels-scale frame))) 0.5 drgnx-pixels--epsilon)))

(defun drgnx-px-line (width &optional frame scale)
  "A line WIDTH logical pixels wide in FRAME's own pixels, whole and never blurred: a thin line (1 logical pixel or
less) is max(1, floor(scale)) pixels, 1 at 1.25 and 4/3 and 2 at 2; a line under 2 is max(1, floor(WIDTH × scale));
a wider one is `drgnx-px'.  SCALE, when given, replaces FRAME's."
  (let ((s (or scale (drgnx-pixels-scale frame))))
    (cond ((<= width 1) (max 1 (floor (+ s drgnx-pixels--epsilon))))
          ((< width 2) (max 1 (floor (+ (* width s) drgnx-pixels--epsilon))))
          (t (drgnx-px width frame s)))))

(defvar drgnx-pixels--fonts (make-hash-table :test #'eq :weakness 'key)
  "A font's name (the string `face-font' gives: the font's own, the same string while a face shows that font) →
\(HEIGHT ASCENT . DESCENT), its fields of `font-info'.  `font-info' makes a new vector and strings at each call, and
the bars ask on every build, so a font is read once.  Weak on the name: an entry goes with its font.")

(defun drgnx-pixels-font-metrics (face &optional frame)
  "(HEIGHT ASCENT . DESCENT) in pixels of the font FACE shows on a graphical FRAME, or nil (a terminal, no such font).
They are the 4th, 9th and 10th fields of `font-info''s vector (the 8th is MAX-WIDTH), read once per font
\(`drgnx-pixels--fonts'): a face that shows another font (a font role, a zoom, a scale) gives another name.
Allocates nothing for a font already read."
  (let ((frame (or frame (selected-frame))))
    (when (display-graphic-p frame)
      (when-let* ((font (ignore-errors (face-font face frame ?x))))
        (or (gethash font drgnx-pixels--fonts)
            (when-let* ((info (ignore-errors (font-info font frame))))
              (puthash font (cons (aref info 3) (cons (aref info 8) (aref info 9))) drgnx-pixels--fonts)))))))

(defun drgnx-pixels-font-extent (face &optional frame)
  "(ASCENT . DESCENT) in pixels of the font FACE shows on a graphical FRAME, or nil (a terminal, no such font)
\(`drgnx-pixels-font-metrics': allocates nothing for a font already read)."
  (cdr (drgnx-pixels-font-metrics face frame)))

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
