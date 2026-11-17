;;; drgnx-decor.el --- Decorations: chips, badges, buttons, card rows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Faces and helpers for modern UI inside a buffer.  Under Glitnir the faces' `:box' carries three extra keys
;; (`:corner-radius', `:open', `:label') and the runs are drawn rounded; without it they are plain boxes and
;; backgrounds (stock validation rejects the keys, so they are set only under `(featurep 'glitnir)').  No colours are
;; written here: the faces inherit the theme's, and a box without `:color' takes its face's foreground.
;; See docs/guide/modules.md, ui/look.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-timer)
(require 'drgnx-modules)
(require 'drgnx-faces)
(require 'drgnx-type-faces)
(require 'drgnx-pixels)                  ; `drgnx-px'

(defgroup drgnx-decor nil "Chips, badges, buttons and cards." :group 'drgnx-face)

;;;; Faces

(defface drgnx-chip '((t :inherit (drgnx-ui-caption drgnx-chip-quiet) :box (:line-width (1 . 2) :style flat-button)))
  "A small rounded label inside text (design §3.5 `.chip'): the quiet chip's tint, room inside it (a flat box in its
own background, never a ring in the text colour), radius 4 where the compositor rounds." :group 'drgnx-decor)
(defface drgnx-badge '((t :inherit (drgnx-ui-caption drgnx-chip-accent) :box (:line-width (1 . 2) :style flat-button)))
  "A pill: an accent chip with the largest radius." :group 'drgnx-decor)
(defface drgnx-chip-solid '((t :inherit drgnx-kit-chip-accent-solid))
  "A chip on the accent's solid fill with its text colour (the theme sets the colours): a trail step's number."
  :group 'drgnx-decor)
(defface drgnx-button '((t :inherit (drgnx-ui-text drgnx-control)))
  "A clickable text button: the look's control (`drgnx-control', its fill and hairline)." :group 'drgnx-decor)
(defface drgnx-button-hover '((t :inherit (highlight drgnx-ui-text drgnx-control)))
  "A button under the pointer: the hover fill on the control's ring (a highlight cannot change metrics)."
  :group 'drgnx-decor)
(defface drgnx-button-pressed '((t :inherit (drgnx-selected drgnx-ui-text drgnx-control)))
  "A button while the mouse button is down: the selection's fill on the control's ring." :group 'drgnx-decor)
(defface drgnx-focus-ring '((t :inherit link :underline nil :box (:line-width 2)))
  "The keyboard focus on a chip or button: a ring in the link colour." :group 'drgnx-decor)
(defface drgnx-card-top '((t :inherit secondary-selection :box (:line-width 1)))
  "The first row of a card." :group 'drgnx-decor)
(defface drgnx-card-mid '((t :inherit secondary-selection :box (:line-width 1)))
  "A middle row of a card." :group 'drgnx-decor)
(defface drgnx-card-bottom '((t :inherit secondary-selection :box (:line-width 1)))
  "The last row of a card." :group 'drgnx-decor)
(defface drgnx-card-single '((t :inherit secondary-selection :box (:line-width 1)))
  "A card of one row." :group 'drgnx-decor)
(defface drgnx-card-sel-top '((t :inherit secondary-selection :box (:line-width 2)))
  "The first row of the selected card: the accent ring (the themes give its colour)." :group 'drgnx-decor)
(defface drgnx-card-sel-mid '((t :inherit secondary-selection :box (:line-width 2)))
  "A middle row of the selected card." :group 'drgnx-decor)
(defface drgnx-card-sel-bottom '((t :inherit secondary-selection :box (:line-width 2)))
  "The last row of the selected card." :group 'drgnx-decor)
(defface drgnx-card-sel-single '((t :inherit secondary-selection :box (:line-width 2)))
  "The selected card of one row." :group 'drgnx-decor)

(defconst drgnx-decor--boxes
  '((drgnx-chip :line-width (1 . 2) :style flat-button :corner-radius 4)
    (drgnx-badge :line-width (1 . 2) :style flat-button :corner-radius 99)
    (drgnx-focus-ring :line-width 2 :corner-radius 6)
    (drgnx-card-top :line-width 1 :corner-radius 8 :open (bottom))
    (drgnx-card-mid :line-width 1 :corner-radius 8 :open (top bottom))
    (drgnx-card-bottom :line-width 1 :corner-radius 8 :open (top))
    (drgnx-card-single :line-width 1 :corner-radius 8)
    (drgnx-card-sel-top :line-width 2 :corner-radius 8 :open (bottom))
    (drgnx-card-sel-mid :line-width 2 :corner-radius 8 :open (top bottom))
    (drgnx-card-sel-bottom :line-width 2 :corner-radius 8 :open (top))
    (drgnx-card-sel-single :line-width 2 :corner-radius 8))
  "Each decoration face and its `:box' under Glitnir.  Without Glitnir only `:line-width' and `:style' stay.  The
buttons are not here: their ring and radius are `drgnx-control''s, from the theme.")

(defun drgnx-decor--glitnir-p ()
  "Non-nil when this Emacs accepts the Glitnir box keys."
  (featurep 'glitnir))

(defun drgnx-decor-box (face)
  "The `:box' plist of decoration FACE for this Emacs: with the Glitnir keys under Glitnir, plain otherwise."
  (let ((plist (cdr (assq face drgnx-decor--boxes))))
    (if (drgnx-decor--glitnir-p) (copy-sequence plist)
      (append (list :line-width (plist-get plist :line-width))
              (and (plist-get plist :style) (list :style (plist-get plist :style)))))))

(defun drgnx-decor-faces-on ()
  "Give every decoration face its `:box' with the Glitnir keys, through the module's recorded face-spec door
\(undone when the module goes).  Does nothing without Glitnir: the faces' defface specs are the plain boxes."
  (when (drgnx-decor--glitnir-p)
    (dolist (entry drgnx-decor--boxes)
      (let ((attrs (copy-sequence (cdar (get (car entry) 'face-defface-spec)))))
        (drgnx-module-face-spec (car entry) `((t ,@(plist-put attrs :box (drgnx-decor-box (car entry))))))))))

;;;; Boxes at each frame's scale

(defconst drgnx-decor--scaled-faces
  '(drgnx-chip drgnx-badge drgnx-focus-ring drgnx-card-top drgnx-card-mid drgnx-card-bottom drgnx-card-single
               drgnx-card-sel-top drgnx-card-sel-mid drgnx-card-sel-bottom drgnx-card-sel-single
               drgnx-hover drgnx-focus drgnx-control drgnx-control-primary drgnx-pill drgnx-pill-on region isearch lazy-highlight
               drgnx-wb-tab drgnx-wb-tab-current
               diff-refine-added diff-refine-removed diff-refine-changed
               ;; the Search view's preview and sheet: a diff line's rounded tint and its words'
               drgnx-replace-preview-del drgnx-replace-preview-add drgnx-replace-preview-word-old
               drgnx-replace-preview-word-new)
  "The faces whose `:box' is in logical pixels: on each frame its line width goes through `drgnx-px-line' (then
`drgnx-pixels-box-width', which gives Nidhogg's shells the width back in the logical pixels they scale themselves)
and its corner radius through `drgnx-px'.")

(defun drgnx-decor--scale-width (w frame)
  "A box line width W (logical, negative drawn inside) as FRAME's `:box' width: drawn `drgnx-px-line' wide."
  (if (and (numberp w) (/= w 0))
      (drgnx-pixels-box-width (* (if (< w 0) -1 1) (drgnx-px-line (abs w) frame)) frame)
    w))

(defun drgnx-decor-scale-box (box frame)
  "The `:box' value BOX, in logical pixels, in FRAME's own pixels."
  (cond ((numberp box) (drgnx-decor--scale-width box frame))
        ((consp box)
         (let ((b (copy-sequence box)) (lw (plist-get box :line-width)) (r (plist-get box :corner-radius)))
           (when lw
             (setq b (plist-put b :line-width (if (consp lw)
                                                  (cons (drgnx-decor--scale-width (car lw) frame)
                                                        (drgnx-decor--scale-width (cdr lw) frame))
                                                (drgnx-decor--scale-width lw frame)))))
           (when (numberp r) (setq b (plist-put b :corner-radius (drgnx-px r frame))))
           b))
        (t box)))

(defun drgnx-decor-scale-frame (frame &optional logical)
  "Give FRAME its own boxes of `drgnx-decor--scaled-faces': each face as its specs (defface, themes, the module's)
make it on FRAME, its box at FRAME's scale; with LOGICAL only the specs' (undoing it)."
  (when (and (frame-live-p frame) (display-graphic-p frame))
    (dolist (face drgnx-decor--scaled-faces)
      (when (facep face)
        (face-spec-recalc face frame)
        (unless logical
          (let* ((box (face-attribute face :box frame)) (want (drgnx-decor-scale-box box frame)))
            (unless (equal want box)
              (set-face-attribute face frame :box want))))))))

(defun drgnx-decor--scale-all (&rest _)
  "Every frame's boxes at its scale (a theme, the density or the UI scale changed)."
  (dolist (f (frame-list)) (drgnx-decor-scale-frame f)))

(defun drgnx-decor-scale-on ()
  "Boxes at each frame's scale, now and when a frame is made, its scale changes, a theme comes or the UI scale or
density changes, until `drgnx-decor-scale-off'."
  (add-hook 'after-make-frame-functions #'drgnx-decor-scale-frame)
  (add-hook 'nidhogg-frame-scale-change-functions #'drgnx-decor-scale-frame)
  (add-hook 'enable-theme-functions #'drgnx-decor--scale-all 95)
  (add-hook 'disable-theme-functions #'drgnx-decor--scale-all 95)
  (add-hook 'drgnx-look-density-changed-hook #'drgnx-decor--scale-all)
  (drgnx-decor--scale-all))

(defun drgnx-decor-scale-off ()
  "Undo `drgnx-decor-scale-on': the hooks go and every frame's boxes are the logical ones again."
  (remove-hook 'after-make-frame-functions #'drgnx-decor-scale-frame)
  (remove-hook 'nidhogg-frame-scale-change-functions #'drgnx-decor-scale-frame)
  (remove-hook 'enable-theme-functions #'drgnx-decor--scale-all)
  (remove-hook 'disable-theme-functions #'drgnx-decor--scale-all)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-decor--scale-all)
  (dolist (f (frame-list)) (drgnx-decor-scale-frame f t)))

;;;; Chips, buttons, card rows

(defun drgnx-decor-chip (text &optional face icon)
  "A chip: an unboxed gap, then TEXT boxed with FACE (default `drgnx-chip') with room either side (`.chip' padding
0 7px: 6 px stretches and the box's 1 on a graphical frame, a space on a terminal), so that high contrast's ring
\(the theme's box) keeps the same room.  ICON, an image spec, comes first inside the room, 5 px before TEXT."
  (let* ((face (or face 'drgnx-chip)) (graphic (display-graphic-p))
         (pad (lambda (n) (if graphic
                              (propertize " " 'display `(space :width (,(drgnx-px n))) 'face face)
                            (propertize " " 'face face)))))
    (concat " "
            (funcall pad 6)
            (when icon
              (concat (propertize " " 'display icon 'face face) (funcall pad 5)))
            (propertize text 'face face)
            (funcall pad 6))))

(defun drgnx-decor--button-extent (pos)
  "The (BEG . END) of the button text around POS."
  (let ((id (get-text-property pos 'drgnx-decor-button)))
    (and id (cons (previous-single-property-change (1+ pos) 'drgnx-decor-button nil (point-min))
                  (or (next-single-property-change pos 'drgnx-decor-button nil (point-max)) (point-max))))))

(defun drgnx-decor--press (event)
  "A mouse button went down on a decoration button: show it pressed; run its action on release over it."
  (interactive "e")
  (let* ((start (event-start event)) (pos (posn-point start)) (win (posn-window start)))
    (when (and pos (window-live-p win))
      (with-current-buffer (window-buffer win)
        (let* ((ext (drgnx-decor--button-extent pos)) (action (get-text-property pos 'drgnx-decor-action)) ev)
          (when ext
            (let ((inhibit-read-only t) (modified (buffer-modified-p)))
              (put-text-property (car ext) (cdr ext) 'face 'drgnx-button-pressed)
              (unwind-protect
                  (track-mouse
                    (while (progn (setq ev (read-event)) (mouse-movement-p ev))))
                (put-text-property (car ext) (cdr ext) 'face 'drgnx-button)
                (restore-buffer-modified-p modified)))
            (when (and (eq (car-safe ev) 'mouse-1) (eq (posn-window (event-start ev)) win)
                       (eql (posn-point (event-start ev)) pos)
                       action)
              (funcall action))))))))

(defvar drgnx-decor-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'drgnx-decor--press)
    (define-key map [mouse-1] #'ignore)
    map)
  "The keymap of every decoration button: the mouse here, the keys of `decor-activate' from the profiles.")

(defun drgnx-decor-activate ()
  "Run the action of the decoration button at point."
  (interactive)
  (when-let* ((action (get-text-property (point) 'drgnx-decor-action)))
    (funcall action)))

(defun drgnx-decor-button (text action)
  "A button: TEXT that calls ACTION (a function of no arguments) on a click or on the keys of `decor-activate'.
It shows `drgnx-button-hover' under the pointer and `drgnx-button-pressed' while the mouse button is down."
  (propertize text 'face 'drgnx-button 'mouse-face 'drgnx-button-hover 'keymap drgnx-decor-button-map
              'drgnx-decor-button t 'drgnx-decor-action action 'follow-link t))

(defun drgnx-decor-card-rows (lines width)
  "LINES as card rows WIDTH columns wide, one string.
Each row is its own box run (a box run spans lines, so rows cannot rely on soft wrap): the text filled to
WIDTH columns, a boxed `(space :align-to COL)' stretch that closes the run at the card's right edge (COL counts
from the window's left edge, so the card starts at column 0), and an unboxed newline."
  (let ((n (length lines)) (i 0))
    (mapconcat
     (lambda (line)
       (let ((face (cond ((= n 1) 'drgnx-card-single) ((= i 0) 'drgnx-card-top)
                         ((= i (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid))))
         (cl-incf i)
         (concat (propertize (truncate-string-to-width line width nil ?\s) 'face face)
                 (propertize " " 'display `(space :align-to ,(1+ width)) 'face face)
                 "\n")))
     lines "")))

(provide 'drgnx-decor)
