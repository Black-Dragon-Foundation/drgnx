;;; drgnx-decor.el --- Decorations: chips, badges, buttons, card rows, agent cursors -*- lexical-binding: t -*-

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

(defgroup drgnx-decor nil "Chips, badges, buttons, cards and agent cursors." :group 'drgnx-face)

;;;; Faces

(defface drgnx-chip '((t :inherit (drgnx-ui-caption drgnx-chip-quiet) :box (:line-width (1 . 2) :style flat-button)))
  "A small rounded label inside text (design §3.5 `.chip'): the quiet chip's tint, room inside it (a flat box in its
own background, never a ring in the text colour), radius 4 where the compositor rounds." :group 'drgnx-decor)
(defface drgnx-badge '((t :inherit (drgnx-ui-caption drgnx-chip-accent) :box (:line-width (1 . 2) :style flat-button)))
  "A pill: an accent chip with the largest radius." :group 'drgnx-decor)
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

(defconst drgnx-decor--boxes
  '((drgnx-chip :line-width (1 . 2) :style flat-button :corner-radius 4)
    (drgnx-badge :line-width (1 . 2) :style flat-button :corner-radius 99)
    (drgnx-focus-ring :line-width 2 :corner-radius 6)
    (drgnx-card-top :line-width 1 :corner-radius 8 :open (bottom))
    (drgnx-card-mid :line-width 1 :corner-radius 8 :open (top bottom))
    (drgnx-card-bottom :line-width 1 :corner-radius 8 :open (top))
    (drgnx-card-single :line-width 1 :corner-radius 8))
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

;;;; Chips, buttons, card rows

(defun drgnx-decor-chip (text &optional face icon)
  "A chip: an unboxed gap, then TEXT boxed with FACE (default `drgnx-chip') with room either side (`.chip' padding
0 7px: 6 px stretches and the box's 1 on a graphical frame, a space on a terminal), so that high contrast's ring
\(the theme's box) keeps the same room.  ICON, an image spec, comes first inside the room, 5 px before TEXT."
  (let* ((face (or face 'drgnx-chip)) (graphic (display-graphic-p))
         (pad (lambda (n) (if graphic (propertize " " 'display `(space :width (,n)) 'face face) (propertize " " 'face face)))))
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

;;;; Agent cursors

(cl-defstruct (drgnx-decor--cursor (:constructor drgnx-decor--cursor-make))
  overlay color name pending label-until)

(defvar drgnx-decor--cursors (make-hash-table :test #'equal)
  "(BUFFER . AGENT) to its `drgnx-decor--cursor'.")

(defconst drgnx-decor-cursor-batch 0.05 "Seconds in which an agent's cursor moves are collected into one.")
(defconst drgnx-decor-cursor-label-time 2 "Seconds a cursor's name tag shows after a move.")

(defun drgnx-decor--face-box (face)
  "The `:box' FACE (a face, a list of faces, or a plist) specifies, or nil."
  (cond ((null face) nil)
        ((keywordp (car-safe face)) (plist-get face :box))
        ((consp face) (cl-some #'drgnx-decor--face-box face))
        ((facep face) (let ((box (face-attribute face :box nil t))) (and box (not (eq box 'unspecified)) box)))))

(defun drgnx-decor--box-at (pos)
  "The box of the text at POS, from its `face' property and the overlays other than agent cursors; nil if unboxed."
  (and (<= (point-min) pos) (< pos (point-max))
       (or (drgnx-decor--face-box (get-text-property pos 'face))
           (cl-some (lambda (ov)
                      (and (not (overlay-get ov 'drgnx-decor-cursor)) (drgnx-decor--face-box (overlay-get ov 'face))))
                    (sort (overlays-at pos) (lambda (a b) (> (or (overlay-get a 'priority) 0)
                                                             (or (overlay-get b 'priority) 0))))))))

(defun drgnx-decor--cursor-face (pos color name label)
  "The face of an agent cursor at POS in the current buffer, in COLOR; NAME is its tag when LABEL.
Where the glyph and both neighbours are unboxed: the bar (a 2 px left edge).  Otherwise the underlying box,
restated, with only the background and the tag changed (a boxed cursor face would take its neighbour's edge)."
  (let* ((glitnir (drgnx-decor--glitnir-p))
         (under (or (drgnx-decor--box-at pos) (drgnx-decor--box-at (1- pos)) (drgnx-decor--box-at (1+ pos))))
         (tag (and glitnir label (list :label name))))
    (cond (under
           (list :background color
                 :box (if (and tag (keywordp (car-safe under))) (append under tag) under)))
          (glitnir (list :background color
                         :box (append (list :line-width '(-2 . -1) :color color :open '(top right bottom)) tag)))
          ((display-graphic-p) (list :background color))
          ;; a terminal has no 2 px edge: the character under the bar in the colour's inverse
          (t (list :foreground color :inverse-video t)))))

(defun drgnx-decor--cursor-apply (cur)
  "Put CUR's overlay's face in line with its position and name tag."
  (let ((ov (drgnx-decor--cursor-overlay cur)))
    (with-current-buffer (overlay-buffer ov)
      (let ((pos (overlay-start ov)) (color (drgnx-decor--cursor-color cur)) (name (drgnx-decor--cursor-name cur)))
        (overlay-put ov 'face (drgnx-decor--cursor-face
                               pos color name (and (drgnx-decor--cursor-label-until cur) t)))
        (overlay-put ov 'mouse-face (drgnx-decor--cursor-face pos color name t))))))

(defun drgnx-decor--cursor-key (buffer agent) (cons buffer agent))

(defun drgnx-decor--sweep ()
  "Prune cursors of dead buffers; drop the name tags that are due and arm the timer for the next one."
  (let ((now (drgnx-timer-now)) next)
    (maphash
     (lambda (key cur)
       (if (not (buffer-live-p (car key)))
           (progn (remhash key drgnx-decor--cursors) (ignore-errors (delete-overlay (drgnx-decor--cursor-overlay cur))))
         (let ((until (drgnx-decor--cursor-label-until cur)))
           (when (and until (not (eq until 'always)))
             (if (<= until (+ now 1e-6))
                 (progn (setf (drgnx-decor--cursor-label-until cur) nil) (drgnx-decor--cursor-apply cur))
               (setq next (min until (or next until))))))))
     drgnx-decor--cursors)
    (when next (drgnx-timer-start 'decor-cursor-label (- next now) #'drgnx-decor--sweep))))

(defun drgnx-decor--flush ()
  "Apply every agent's last pending position (one overlay move each) and show their name tags."
  (let (moved)
    (maphash
     (lambda (key cur)
       (let ((pos (drgnx-decor--cursor-pending cur)))
         (when (and pos (buffer-live-p (car key)))
           (with-current-buffer (car key)
             (let ((pos (max (point-min) (min pos (max (point-min) (1- (point-max)))))))
               (move-overlay (drgnx-decor--cursor-overlay cur) pos (min (point-max) (1+ pos)))))
           (setf (drgnx-decor--cursor-pending cur) nil
                 (drgnx-decor--cursor-label-until cur) (+ (drgnx-timer-now) drgnx-decor-cursor-label-time))
           (drgnx-decor--cursor-apply cur)
           (setq moved t))))
     drgnx-decor--cursors)
    (when moved (drgnx-timer-start 'decor-cursor-label drgnx-decor-cursor-label-time #'drgnx-decor--sweep))))

(defun drgnx-decor-cursor-put (buffer agent pos color name)
  "Show AGENT's cursor in BUFFER at POS, in COLOR (a theme colour), tagged NAME: one overlay at (POS, POS+1).
An existing cursor of AGENT in BUFFER is replaced.  The tag shows for 2 s."
  (drgnx-decor-cursor-remove buffer agent)
  (with-current-buffer buffer
    (let* ((pos (max (point-min) (min pos (point-max))))
           (ov (make-overlay pos (min (point-max) (1+ pos)) buffer))
           (cur (drgnx-decor--cursor-make :overlay ov :color color :name name
                                          :label-until (+ (drgnx-timer-now) drgnx-decor-cursor-label-time))))
      (overlay-put ov 'drgnx-decor-cursor agent)
      (overlay-put ov 'priority 100)
      (puthash (drgnx-decor--cursor-key buffer agent) cur drgnx-decor--cursors)
      (drgnx-decor--cursor-apply cur)
      (drgnx-timer-start 'decor-cursor-label drgnx-decor-cursor-label-time #'drgnx-decor--sweep)
      ov)))

(defun drgnx-decor-cursor-move (buffer agent pos)
  "Move AGENT's cursor in BUFFER to POS.  Moves are batched: one 50 ms timer for all agents applies the last."
  (when-let* ((cur (gethash (drgnx-decor--cursor-key buffer agent) drgnx-decor--cursors)))
    (setf (drgnx-decor--cursor-pending cur) pos)
    (drgnx-timer-soon 'decor-cursor-flush drgnx-decor-cursor-batch #'drgnx-decor--flush)))

(defvar drgnx-decor--label-mode 'activity
  "How name tags show on cursors moved now: `activity' (2 s after a move) or `never'; `drgnx-decor-cursor-keep-label'
holds one tag on.")

;; A frame the editor client applies at once does not wait for the 50 ms batch.

(defun drgnx-decor-cursor-move-now (buffer agent pos)
  "Move AGENT's cursor in BUFFER to POS now: the same overlay moves, no batch timer.  Its name tag follows the tag mode
\(`drgnx-decor-cursor-label-mode')."
  (when-let* ((cur (gethash (drgnx-decor--cursor-key buffer agent) drgnx-decor--cursors)))
    (with-current-buffer buffer
      (let ((pos (max (point-min) (min pos (max (point-min) (1- (point-max)))))))
        (move-overlay (drgnx-decor--cursor-overlay cur) pos (min (point-max) (1+ pos)))))
    (setf (drgnx-decor--cursor-pending cur) nil)
    (unless (eq (drgnx-decor--cursor-label-until cur) 'always)
      (setf (drgnx-decor--cursor-label-until cur)
            (and (not (eq drgnx-decor--label-mode 'never)) (+ (drgnx-timer-now) drgnx-decor-cursor-label-time))))
    (drgnx-decor--cursor-apply cur)
    (when (numberp (drgnx-decor--cursor-label-until cur))
      (drgnx-timer-start 'decor-cursor-label drgnx-decor-cursor-label-time #'drgnx-decor--sweep))))

(defun drgnx-decor-cursor-label-mode (mode)
  "Set the tag mode for cursors moved now: `activity' or `never'."
  (setq drgnx-decor--label-mode mode))

(defun drgnx-decor-cursor-keep-label (buffer agent keep)
  "KEEP non-nil: AGENT's name tag in BUFFER stays on; nil: it follows the tag mode again."
  (when-let* ((cur (gethash (drgnx-decor--cursor-key buffer agent) drgnx-decor--cursors)))
    (setf (drgnx-decor--cursor-label-until cur)
          (cond (keep 'always) ((eq drgnx-decor--label-mode 'never) nil)
                (t (+ (drgnx-timer-now) drgnx-decor-cursor-label-time))))
    (drgnx-decor--cursor-apply cur)))

(defun drgnx-decor-cursor-overlay (buffer agent)
  "AGENT's cursor overlay in BUFFER, or nil."
  (when-let* ((cur (gethash (drgnx-decor--cursor-key buffer agent) drgnx-decor--cursors)))
    (drgnx-decor--cursor-overlay cur)))

(defun drgnx-decor-cursor-label-state (buffer agent)
  "AGENT's tag in BUFFER: `always', the time it is due off, or nil (not shown)."
  (when-let* ((cur (gethash (drgnx-decor--cursor-key buffer agent) drgnx-decor--cursors)))
    (drgnx-decor--cursor-label-until cur)))

(defun drgnx-decor-cursor-remove (buffer agent)
  "Remove AGENT's cursor from BUFFER."
  (let ((key (drgnx-decor--cursor-key buffer agent)))
    (when-let* ((cur (gethash key drgnx-decor--cursors)))
      (delete-overlay (drgnx-decor--cursor-overlay cur))
      (remhash key drgnx-decor--cursors)
      (when (zerop (hash-table-count drgnx-decor--cursors))
        (drgnx-timer-cancel 'decor-cursor-flush)
        (drgnx-timer-cancel 'decor-cursor-label)))))

(provide 'drgnx-decor)
