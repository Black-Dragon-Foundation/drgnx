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
(require 'drgnx-pixels)

(defvar vertico-count)
(defvar vertico-buffer-hide-prompt)
(defvar drgnx-look-palette)
(declare-function vertico-buffer-mode "vertico-buffer")
(declare-function glitnir-active-p "glitnir")
(declare-function face-remap-remove-relative "face-remap")

(defcustom drgnx-palette-frame-width 640
  "The floating palette's width, in logical pixels (less when the editor frame is narrower)."
  :type 'natnum :group 'drgnx-face)

(defcustom drgnx-palette-frame-top 0.12
  "The floating palette's distance from the top of the editor frame, as a fraction of its height."
  :type 'number :group 'drgnx-face)

(defconst drgnx-palette-frame-row-px 32 "A palette row's height in logical pixels (the minibuffer's own rows are 24).")
(defconst drgnx-palette-frame-footer-px 30 "The footer's height in logical pixels, its keys in the middle (palette.html).")
(defconst drgnx-palette-frame-footer-gap-px 6 "The gap above the footer, in logical pixels (palette.html).")
(defconst drgnx-palette-frame-minibuffer-row-px 24 "A candidate row's height in the echo area, in logical pixels.")

(defvar drgnx-palette-frame--frame nil "The palette's child frame, once made; reused until the module goes off.")

(defconst drgnx-palette-frame--buffer " *drgnx-palette-frame*"
  "The plain buffer the palette's window shows between uses.")

(defconst drgnx-palette-frame-multiform
  '(drgnx-palette-frame-buffer (vertico-buffer-display-action drgnx-palette-frame--display (drgnx-explicit . t))
                               (vertico-count-format) (vertico-group-format . "%s"))
  "The settings `vertico-multiform-categories' holds for the palette's category, `drgnx-command'.  The action is
marked explicit, so the workbench's placement rules leave it to the palette's frame.  No count, and a group's title
is the palette's own (`drgnx-palette--group-title'): no rule line.")

(defun drgnx-palette-frame-wanted-p ()
  "Non-nil when the palette floats: Glitnir is active on a graphical frame."
  (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p) t))

(defun drgnx-palette-frame--px (frame logical)
  "LOGICAL pixels in FRAME's own pixels, by the pixel rule (`drgnx-px': the display scale on a native shell times the
UI scale, half up)."
  (drgnx-px logical frame))

(defun drgnx-palette-frame-ring (frame)
  "The width of the box's ring (the look's `child-frame-border-width', logical) in FRAME's pixels, by the line rule
\(`drgnx-px-line': a 1 px ring is 1 device pixel at 1.25, 4/3 and 1.5, 2 at 2); 0 without one."
  (let ((w (or (alist-get 'child-frame-border-width (drgnx-palette-frame--look)) 0)))
    (if (> w 0) (drgnx-px-line w frame) 0)))

(defun drgnx-palette-frame--params (parent)
  "The frame parameters of the palette's child frame under PARENT."
  `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-palette") (drgnx-palette . t)
    (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t)
    (skip-taskbar . t) (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t)
    (internal-border-width . ,(drgnx-palette-frame--px parent 8)) (border-width . 0)
    (child-frame-border-width . ,(drgnx-palette-frame-ring parent))
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
                           (drgnx-palette-frame-ring (or parent drgnx-palette-frame--frame)))
      (dolist (p look)
        (unless (eq (car p) 'child-frame-border-width) (set-frame-parameter drgnx-palette-frame--frame (car p) (cdr p)))))))

(defun drgnx-palette-frame--ensure (parent)
  "The palette's frame, made if need be, under PARENT."
  (unless (frame-live-p drgnx-palette-frame--frame)
    (setq drgnx-palette-frame--frame (make-frame (drgnx-palette-frame--params parent))))
  (unless (eq (frame-parent drgnx-palette-frame--frame) parent)
    (set-frame-parameter drgnx-palette-frame--frame 'parent-frame parent))
  ;; the frame is reused: its border and ring follow the parent's scale now (a UI scale or a monitor changed since)
  (dolist (p `((internal-border-width . ,(drgnx-palette-frame--px parent 8))
               (child-frame-border-width . ,(drgnx-palette-frame-ring parent))))
    (unless (eql (frame-parameter drgnx-palette-frame--frame (car p)) (cdr p))
      (set-frame-parameter drgnx-palette-frame--frame (car p) (cdr p))))
  drgnx-palette-frame--frame)

(defun drgnx-palette-frame--place (frame parent lh)
  "Size FRAME for the candidates and put it top-centre in PARENT.
The window holds the input line and `vertico-count' lines of LH pixels, then the footer (`drgnx-palette-frame--height')."
  (let* ((width (min (drgnx-palette-frame--px parent drgnx-palette-frame-width)
                     (max (drgnx-palette-frame--px parent 100)
                          (- (frame-pixel-width parent) (drgnx-palette-frame--px parent 32)))))
         (count (default-value 'vertico-count)))
    (set-frame-size frame width (drgnx-palette-frame--height parent count lh) t)
    (set-frame-position frame (max 0 (/ (- (frame-pixel-width parent) (frame-pixel-width frame)) 2))
                        (round (* drgnx-palette-frame-top (frame-pixel-height parent))))))

(declare-function drgnx-wb--natural-row-height "drgnx-wb")

(defun drgnx-palette-frame--spacing (rows)
  "The `line-spacing' that brings a UI row to ROWS logical pixels: the extra half above, half below; nil on a
terminal or before the dock's measure exists."
  (when (and (display-graphic-p) (fboundp 'drgnx-wb--natural-row-height))
    (let ((extra (max 0 (- (drgnx-px rows) (drgnx-wb--natural-row-height)))))
      (cons (/ extra 2) (- extra (/ extra 2))))))

(defvar-local drgnx-palette-frame--floats nil
  "Non-nil in the minibuffer buffer the palette's frame shows: its rows are the palette's, not the echo area's.")

(defun drgnx-palette-frame--rows (row-px)
  "The current minibuffer buffer's rows are ROW-PX logical pixels high (its `line-spacing')."
  (when-let* ((spacing (drgnx-palette-frame--spacing row-px)))
    (setq-local line-spacing spacing)))

(defun drgnx-palette-frame-minibuffer-rows ()
  "On `minibuffer-setup-hook': this minibuffer's candidate rows are in the UI font, 24 logical pixels high (32 when
the palette's frame shows it, whichever of the two ran first)."
  (face-remap-add-relative 'default 'drgnx-ui-text)
  (drgnx-palette-frame--rows (if drgnx-palette-frame--floats drgnx-palette-frame-row-px
                               drgnx-palette-frame-minibuffer-row-px)))

(declare-function drgnx-palette-keycap "drgnx-palette")
(declare-function drgnx-look-icon "drgnx-icons")
(defvar drgnx-palette-row-padding)

(defvar drgnx-palette-frame--dressing nil
  "(PROMPT-OVERLAY HINT . FACE-REMAP-COOKIES) of the minibuffer the palette's frame shows, while it shows it.")

(defun drgnx-palette-frame--lead ()
  "The room before the input row's icon and the footer: a row's inset and padding."
  (propertize " " 'display `(space :width (,(drgnx-px (+ 6 drgnx-palette-row-padding))))))

(defun drgnx-palette-frame--hint ()
  "The input row's hint at the right edge: what the palette searches, `#' for a code question and, when an agent can
be asked, `@' for one."
  (let ((s (concat (propertize "Commands · " 'face 'drgnx-text-subtle) (drgnx-palette-keycap "#")
                   (propertize " code" 'face 'drgnx-text-subtle)
                   (when (and (fboundp 'drgnx-palette--ask-command) (drgnx-palette--ask-command))
                     (concat (propertize " · " 'face 'drgnx-text-subtle) (drgnx-palette-keycap "@")
                             (propertize " agents" 'face 'drgnx-text-subtle))))))
    (concat (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width s (current-buffer))
                                                                     (drgnx-px (+ 6 drgnx-palette-row-padding)))))))
            s)))

(defun drgnx-palette-frame--footer ()
  "The footer's keys (palette.html `.foot'): move, run, preview, close."
  (let ((gap (propertize "   " 'face 'drgnx-text-subtle)))
    (concat (drgnx-palette-frame--lead)
            (drgnx-palette-keycap "↑") " " (drgnx-palette-keycap "↓") (propertize " move" 'face 'drgnx-text-subtle) gap
            (drgnx-palette-keycap "↵") (propertize " run" 'face 'drgnx-text-subtle) gap
            (drgnx-palette-keycap "Tab") (propertize " preview" 'face 'drgnx-text-subtle) gap
            (drgnx-palette-keycap "Esc") (propertize " close" 'face 'drgnx-text-subtle))))

(defun drgnx-palette-frame--dress (win)
  "In the palette's window WIN only: the prompt shows as the search icon, the hint follows the typed text at the right
edge (`drgnx-palette-frame-hint-candidates'), and the mode line is the footer of keys on the box's own surface.  The
echo area keeps the minibuffer as it is."
  (drgnx-palette-frame--undress)
  (let ((prompt (make-overlay (point-min) (minibuffer-prompt-end) nil t nil)))
    ;; an image inside an overlay's `display' string is not drawn: the prompt is hidden and the icon is a before-string
    (overlay-put prompt 'window win)
    (overlay-put prompt 'invisible t)
    ;; the echo box gives this minibuffer the input row's inset as its `line-prefix' (`drgnx-look-echo'), but the lead
    ;; below is that inset here: no prefix while the palette shows it (redisplay does not take an overlay's empty one
    ;; over a buffer's at a line that starts in hidden text)
    (kill-local-variable 'line-prefix)
    (overlay-put prompt 'before-string
                 (concat (drgnx-palette-frame--lead) (drgnx-look-icon 'search 'drgnx-text-subtle) " "))
    (set-window-parameter win 'mode-line-format (drgnx-palette-frame--footer))
    (add-hook 'pre-redisplay-functions #'drgnx-palette-frame--keep-count 90 t)
    (let* ((cookies (list (face-remap-add-relative 'mode-line 'drgnx-palette-footer)
                          (face-remap-add-relative 'mode-line-inactive 'drgnx-palette-footer)))
           ;; the footer is `drgnx-palette-frame-footer-px' high, its keys in the middle (palette.html `.foot'): its
           ;; font's height and a pad above and below (measured from the face: the window's mode line height is the
           ;; last redisplay's)
           (text (window-font-height win 'drgnx-palette-footer))
           (pad (max 0 (/ (- (drgnx-px drgnx-palette-frame-footer-px) text) 2)))
           (box `(:box (:line-width (0 . ,pad) :style flat-button))))
      (setq-local drgnx-palette-frame--footer-height (+ text pad pad))
      (setq drgnx-palette-frame--dressing
            (cons prompt (cons (drgnx-palette-frame--hint)
                               (append (list (face-remap-add-relative 'mode-line box)
                                             (face-remap-add-relative 'mode-line-inactive box))
                                       cookies)))))))

(defun drgnx-palette-frame--height (parent rows lh &optional footer)
  "The palette's text height, in PARENT's frame pixels, for ROWS rows of LH pixels below the input row: the rows, the
gap above the footer and the footer (FOOTER pixels, its measured height; else `drgnx-palette-frame-footer-px')."
  (+ (* lh (1+ rows)) (drgnx-palette-frame--px parent drgnx-palette-frame-footer-gap-px)
     (or footer (drgnx-palette-frame--px parent drgnx-palette-frame-footer-px))))

(defvar-local drgnx-palette-frame--footer-height nil
  "In the dressed minibuffer: the footer's height in pixels, its font and its pads.")

(defvar vertico--candidates-ov)

(defun drgnx-palette-frame--selected-in-p (string start end)
  "Non-nil when a face of STRING between START and END is `vertico-current' (the selected row)."
  (let ((i start) found)
    (while (and (not found) (< i end))
      (let ((face (get-text-property i 'face string)))
        (setq found (if (and (consp face) (not (keywordp (car face)))) (memq 'vertico-current face)
                      (eq face 'vertico-current))
              i (next-single-property-change i 'face string end))))
    found))

(defun drgnx-palette-frame--hairline (rows color)
  "ROWS (vertico's lines after the input row, from the newline that ends it) with the hairline under the input row
\(palette.html `.in'): an overline in COLOR over the first line, a group's title or the first row, stretched to the
right edge.  Unchanged without COLOR or a first line, or when the first line is the selected row: an overline would
cross its rounded fill (a face has one box and the line is drawn inside it)."
  (let ((end (and color (> (length rows) 1) (eq (aref rows 0) ?\n) (string-search "\n" rows 1))))
    (if (or (not end) (drgnx-palette-frame--selected-in-p rows 1 end))
        rows
      (let ((line (concat (substring rows 1 end) (propertize " " 'display '(space :align-to right)))))
        (add-face-text-property 0 (length line) (list :overline color) t line)
        (concat "\n" line (substring rows end))))))

(defun drgnx-palette-frame-after-candidates (lines)
  "After vertico draws LINES (its overlay's string: a space that takes the cursor, then the rows): put the hint between
that space and the rows, so it ends the input row and the cursor stays after the typed text; and fit the box to its
rows, the input row and the footer (at most `vertico-count' rows, the height it opened at).  Only in the minibuffer
the palette's frame shows."
  (when-let* ((d drgnx-palette-frame--dressing)
              ((eq (current-buffer) (overlay-buffer (car d))))
              (ov (bound-and-true-p vertico--candidates-ov))
              (s (overlay-get ov 'before-string))
              ((> (length s) 0)))
    (overlay-put ov 'before-string (concat (substring s 0 1) (cadr d)
                                           (drgnx-palette-frame--hairline (substring s 1)
                                                                          (face-background 'drgnx-border nil t))))
    (when (frame-live-p drgnx-palette-frame--frame)
      (let ((h (drgnx-palette-frame--height (or (frame-parent drgnx-palette-frame--frame) drgnx-palette-frame--frame)
                                            (min (length lines) (default-value 'vertico-count)) (default-line-height)
                                            drgnx-palette-frame--footer-height)))
        (unless (= h (frame-text-height drgnx-palette-frame--frame))
          (set-frame-size drgnx-palette-frame--frame (frame-text-width drgnx-palette-frame--frame) h t))))))

(defun drgnx-palette-frame--keep-count (_window)
  "On the dressed minibuffer's `pre-redisplay-functions', after `vertico-buffer''s: `vertico-count' stays the most
rows the box shows, not the rows of a box fitted to fewer."
  (setq-local vertico-count (default-value 'vertico-count)))

(defun drgnx-palette-frame--undress ()
  "Take the input row's overlay and the footer's remaps off the current minibuffer buffer."
  (when drgnx-palette-frame--dressing
    (remove-hook 'pre-redisplay-functions #'drgnx-palette-frame--keep-count t)
    (delete-overlay (car drgnx-palette-frame--dressing))
    (mapc #'face-remap-remove-relative (cddr drgnx-palette-frame--dressing))
    (setq drgnx-palette-frame--dressing nil)))

(defface drgnx-palette-footer '((t :inherit (drgnx-ui-caption default) :box nil :overline nil :underline nil))
  "The floating palette's footer of keys: the caption size on the box's own surface, not a mode line's."
  :group 'drgnx-face)

(defun drgnx-palette-frame--display (_buffer _alist)
  "The display action of `vertico-buffer-display-action' for the palette: the frame's window, frame shown.
`vertico-buffer' puts the minibuffer buffer in it (the buffer given here is a stand-in it kills at once), so the
minibuffer buffer's rows become the palette's 32 pixels.  The window is as many of its lines high as `vertico-buffer'
counts in it (`default-line-height'), so the list is `vertico-count' long."
  (let* ((mb (window-buffer (active-minibuffer-window)))
         (lh (with-current-buffer mb
               (setq-local drgnx-palette-frame--floats t)
               ;; In the echo box the minibuffer window is its frame's root, which cannot shrink: `vertico-buffer'
               ;; would signal at every redisplay.  The box is hidden while the palette floats (below).
               (when (frame-root-window-p (active-minibuffer-window))
                 (setq-local vertico-buffer-hide-prompt nil))
               (drgnx-palette-frame--rows drgnx-palette-frame-row-px)
               (default-line-height)))
         (parent (window-frame (minibuffer-selected-window)))
         (frame (drgnx-palette-frame--ensure parent)))
    (drgnx-palette-frame--place frame parent lh)
    (with-current-buffer mb (drgnx-palette-frame--dress (frame-root-window frame)))
    (make-frame-visible frame)
    ;; a minibuffer in a box of its own (a child frame whose root it is): the palette is the prompt now
    (let ((box (window-frame (active-minibuffer-window))))
      (when (and (frame-parent box) (frame-visible-p box) (frame-root-window-p (active-minibuffer-window)))
        (make-frame-invisible box)))
    (frame-root-window frame)))

(defun drgnx-palette-frame-hide ()
  "Hide the palette's frame and give its window a plain buffer again, when the minibuffer that ends is the palette's.
Any other (a question on top of the open palette, or a prompt with the palette closed) changes nothing.
`vertico-buffer' restores nothing here (the window is not in the selected frame's list, and a sole window is
not deleted), so the dedication and the window parameters it set are cleared here."
  (when (frame-live-p drgnx-palette-frame--frame)
    (let ((win (frame-root-window drgnx-palette-frame--frame)))
      (when (eq (window-buffer win) (window-buffer (active-minibuffer-window)))
        (drgnx-palette-frame--undress)
        (set-window-parameter win 'mode-line-format nil)
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
