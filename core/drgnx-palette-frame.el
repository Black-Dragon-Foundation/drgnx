;;; drgnx-palette-frame.el --- The command palette's own child frame -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Under Glitnir the palette floats: vertico's `vertico-buffer' shows the minibuffer buffer itself (the prompt, the
;; typed text and the candidates) in a window of this child frame, made once, shown and hidden.  The minibuffer
;; window, and keyboard focus, stay in the editor frame.  The frame is drgnx's own, not a posframe.
;; `vertico-buffer-hide-prompt' hides the real prompt; `vertico-count' follows the window's height.
;; See docs/guide/palette.md.

;;; Code:
(require 'cl-lib)

(defvar vertico-count)
(defvar drgnx-look-palette)
(declare-function vertico-buffer-mode "vertico-buffer")
(declare-function glitnir-active-p "glitnir")

(defcustom drgnx-palette-frame-width 640
  "The floating palette's width, in logical pixels (less when the editor frame is narrower)."
  :type 'natnum :group 'drgnx-face)

(defcustom drgnx-palette-frame-top 0.12
  "The floating palette's distance from the top of the editor frame, as a fraction of its height."
  :type 'number :group 'drgnx-face)

(defconst drgnx-palette-frame-row-px 32 "A palette row's height in logical pixels (the minibuffer's own rows are 24).")
(defconst drgnx-palette-frame-minibuffer-row-px 24 "A candidate row's height in the echo area, in logical pixels.")

(defvar drgnx-palette-frame--frame nil "The palette's child frame, once made; reused until the module goes off.")

(defconst drgnx-palette-frame--buffer " *drgnx-palette-frame*"
  "The plain buffer the palette's window shows between uses.")

(defconst drgnx-palette-frame-multiform
  '(drgnx-palette-frame-buffer (vertico-buffer-display-action drgnx-palette-frame--display))
  "The settings `vertico-multiform-categories' holds for the palette's category, `drgnx-command'.")

(defun drgnx-palette-frame-wanted-p ()
  "Non-nil when the palette floats: Glitnir is active on a graphical frame."
  (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p) t))

(defun drgnx-palette-frame--px (frame logical)
  "LOGICAL pixels in FRAME's own pixels: a frame of Nidhogg's Wayland shell counts device pixels."
  (if (featurep 'nidhogg-wayland) (round (* logical (frame-scale-factor frame))) logical))

(defun drgnx-palette-frame--params (parent)
  "The frame parameters of the palette's child frame under PARENT."
  `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-palette") (drgnx-palette . t)
    (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t)
    (skip-taskbar . t) (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t)
    (internal-border-width . ,(drgnx-palette-frame--px parent 8)) (border-width . 0)
    (child-frame-border-width . ,(drgnx-palette-frame--px
                                  parent (or (alist-get 'child-frame-border-width (drgnx-palette-frame--look)) 0)))
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0) (tab-bar-lines-keep-state . t)
    (left-fringe . 0) (right-fringe . 0) (vertical-scroll-bars) (horizontal-scroll-bars)
    (visibility . nil)
    ,@(assq-delete-all 'child-frame-border-width (copy-sequence (drgnx-palette-frame--look)))))

(defun drgnx-palette-frame--look ()
  "The look's parameters for the palette's frame (the variant's table, or the user's `drgnx-look-palette')."
  (if (fboundp 'drgnx-look-palette-current) (drgnx-look-palette-current) (bound-and-true-p drgnx-look-palette)))

(defun drgnx-palette-frame-restyle ()
  "Give the palette's frame, when it exists, the look's parameters again (a theme changed the variant).  A key the
new table leaves out is cleared; the border width is in the parent's pixels."
  (when (frame-live-p drgnx-palette-frame--frame)
    (let ((look (drgnx-palette-frame--look)) (parent (frame-parent drgnx-palette-frame--frame)))
      (dolist (k '(shadow backdrop-blur))
        (unless (assq k look) (set-frame-parameter drgnx-palette-frame--frame k nil)))
      (set-frame-parameter drgnx-palette-frame--frame 'child-frame-border-width
                           (drgnx-palette-frame--px (or parent drgnx-palette-frame--frame)
                                                    (or (alist-get 'child-frame-border-width look) 0)))
      (dolist (p look)
        (unless (eq (car p) 'child-frame-border-width) (set-frame-parameter drgnx-palette-frame--frame (car p) (cdr p)))))))

(defun drgnx-palette-frame--ensure (parent)
  "The palette's frame, made if need be, under PARENT."
  (unless (frame-live-p drgnx-palette-frame--frame)
    (setq drgnx-palette-frame--frame (make-frame (drgnx-palette-frame--params parent))))
  (unless (eq (frame-parent drgnx-palette-frame--frame) parent)
    (set-frame-parameter drgnx-palette-frame--frame 'parent-frame parent))
  drgnx-palette-frame--frame)

(defun drgnx-palette-frame--place (frame parent)
  "Size FRAME for the candidates and put it top-centre in PARENT.
The window is `vertico-count' + 2 lines high: `vertico-buffer' takes the mode line and the input line off."
  (let* ((lh (drgnx-palette-frame--px parent drgnx-palette-frame-row-px))
         (width (min (drgnx-palette-frame--px parent drgnx-palette-frame-width)
                     (max (drgnx-palette-frame--px parent 100)
                          (- (frame-pixel-width parent) (drgnx-palette-frame--px parent 32)))))
         (count (default-value 'vertico-count)))
    (set-frame-size frame width (* lh (+ count 2)) t)
    (set-frame-position frame (max 0 (/ (- (frame-pixel-width parent) (frame-pixel-width frame)) 2))
                        (round (* drgnx-palette-frame-top (frame-pixel-height parent))))))

(declare-function drgnx-wb--natural-row-height "drgnx-wb")

(defun drgnx-palette-frame--spacing (rows)
  "The `line-spacing' that brings a UI row to ROWS logical pixels: the extra half above, half below; nil on a
terminal or before the dock's measure exists."
  (when (and (display-graphic-p) (fboundp 'drgnx-wb--natural-row-height))
    (let* ((scale (if (fboundp 'frame-scale-factor) (float (frame-scale-factor)) 1.0))
           (extra (max 0 (- (round (* rows scale)) (drgnx-wb--natural-row-height)))))
      (cons (/ extra 2) (- extra (/ extra 2))))))

(defun drgnx-palette-frame-minibuffer-rows ()
  "On `minibuffer-setup-hook': this minibuffer's candidate rows are 24 logical pixels in the UI font."
  (face-remap-add-relative 'default 'drgnx-ui-text)
  (when-let* ((spacing (drgnx-palette-frame--spacing drgnx-palette-frame-minibuffer-row-px)))
    (setq-local line-spacing spacing)))

(defun drgnx-palette-frame--display (buffer _alist)
  "The display action of `vertico-buffer-display-action' for the palette: the frame's window, frame shown.
`vertico-buffer' puts the minibuffer buffer in it; its rows are the palette's 32 pixels."
  (when-let* (((buffer-live-p buffer)) (spacing (drgnx-palette-frame--spacing drgnx-palette-frame-row-px)))
    (with-current-buffer buffer (setq-local line-spacing spacing)))
  (let* ((parent (window-frame (minibuffer-selected-window)))
         (frame (drgnx-palette-frame--ensure parent)))
    (drgnx-palette-frame--place frame parent)
    (make-frame-visible frame)
    (frame-root-window frame)))

(defun drgnx-palette-frame-hide ()
  "Hide the palette's frame and give its window a plain buffer again, when the minibuffer that ends is the palette's.
Any other (a question on top of the open palette, or a prompt with the palette closed) changes nothing.
`vertico-buffer' restores nothing here (the window is not in the selected frame's list, and a sole window is
not deleted), so the dedication and the window parameters it set are cleared here."
  (when (frame-live-p drgnx-palette-frame--frame)
    (let ((win (frame-root-window drgnx-palette-frame--frame)))
      (when (eq (window-buffer win) (window-buffer (active-minibuffer-window)))
        (set-window-parameter win 'no-other-window nil)
        (set-window-parameter win 'no-delete-other-windows nil)
        (set-window-dedicated-p win nil)
        (set-window-buffer win (get-buffer-create drgnx-palette-frame--buffer))
        (when (frame-visible-p drgnx-palette-frame--frame)
          (make-frame-invisible drgnx-palette-frame--frame))))))

(defun drgnx-palette-frame-delete ()
  "Delete the palette's frame and its buffer (the module's teardown)."
  (when (frame-live-p drgnx-palette-frame--frame) (delete-frame drgnx-palette-frame--frame t))
  (setq drgnx-palette-frame--frame nil)
  (when-let* ((b (get-buffer drgnx-palette-frame--buffer))) (kill-buffer b)))

(defun drgnx-palette-frame-buffer (&optional arg)
  "The multiform setting of the palette's category: `vertico-buffer-mode' on (ARG > 0) only when it floats.
Off (ARG < 0) always."
  (when (or (and arg (< arg 0)) (drgnx-palette-frame-wanted-p))
    (vertico-buffer-mode arg)))

(provide 'drgnx-palette-frame)
;;; drgnx-palette-frame.el ends here
