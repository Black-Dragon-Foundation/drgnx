;;; drgnx-ruler.el --- The scroll bar: a strip at each window's right edge with the file's marks -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The scroll bar of every scrollable surface (the minimap design's state A, docs/guide/minimap.md): a strip 12
;; logical pixels wide in the window's right fringe, with a thumb over the part shown and the buffer's marks in lanes.
;; It shows on editors and on every list and page drgnx draws (the Explorer, Outline, Search, Problems, Source
;; Control, the panel's views, the palette's lists, Settings…), and is hidden while the content fits.
;;
;; One owner draws it; producers hand it marks.  A producer registers a function in a buffer (`drgnx-ruler-source'),
;; which returns the marks it has now: (POS LANE FACE PRIORITY [SHAPE END]), LANE `left', `middle', `right' or `full',
;; SHAPE nil (a bar) or `dot' (a breakpoint's), END a position the mark runs to (a hunk's last line).  The ruler asks
;; its producers again when one says its marks changed (`drgnx-ruler-refresh') and, debounced, after an edit.
;;
;; Each mark has a kind (`drgnx-ruler-kinds': a change, a problem, a search hit, a breakpoint, a bookmark…), from its
;; face or its producer.  On Nidhogg the owner hands each kind's marks, once per change of that kind, to the buffer
;; text's line model (`nidhogg-lines-set-marks', Hlidskjalf), which shifts them with every edit and answers the
;; next-mark keys and the counts (core/drgnx-marks.el) without a scan; the strip then measures visible lines.
;;
;; Nidhogg draws it (Glitnir's overview ruler, the window parameter `glitnir-ruler'): the fringe is widened by the
;; strip while it is on, next to the text, and keeps that width while the strip hides (nothing reflows when the
;; content grows past the window).  The fringe's own pixels stay outermost, so the card edge's drag
;; (`drgnx-look-edge-drag') keeps its place.  Marks sit at their position's fraction of the buffer, by characters as
;; Emacs's scroll bar measures; the thumb moves with a scroll, and the strip hides while everything shows, in C:
;; nothing here runs on a scroll.  A view the hub sends a window of (the Explorer of a big tree) names its rows
;; through `drgnx-ruler-span-function', so the thumb stands for the whole view.  The parameter is set only when the
;; marks, the span or the window's fringe change.  A press on the strip goes there and a drag scrolls (the one place
;; Lisp runs per pointer motion, while the button is held).  On a terminal the strip is one column: the window gets a
;; one-column right margin (`drgnx-margins-ruler') whose cells Nidhogg fills in the frame's desired matrix (`┃' over
;; the rows shown, `│' elsewhere, `▐' a mark), so a scroll there runs no Lisp either.  Without Nidhogg's feature
;; `glitnir-ruler' there is no strip.  docs/develop/core.md, "The scroll bar and its marks".

;;; Code:
(require 'cl-lib)
(require 'drgnx-pixels)
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-margins)

(declare-function glitnir-ruler-position "glitnir" (posn))
(declare-function glitnir-ruler-fraction "glitnir" (posn))
(declare-function drgnx-look-edge-drag "drgnx-look" (event))
(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-set-marks "nidhogg-lines" (buffer kind marks))

(defgroup drgnx-minimap nil "The scroll bar, the minimap and their marks." :group 'drgnx)

(defvar drgnx-scrollbar-mode)

(defun drgnx-ruler--setting-changed (&rest _)
  "A scroll bar setting changed: every window's strip again, now."
  (when drgnx-scrollbar-mode (drgnx-scrollbar-refresh-all)))

(defun drgnx-ruler--kinds-changed (&rest _)
  "The kinds shown changed: every buffer's marks asked again."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-ruler-mode b) (drgnx-ruler-refresh b))))

(drgnx-defsetting drgnx-minimap-ruler t
  "Non-nil: every scrollable window has the scroll bar, a strip at its right edge with the thumb and the file's
marks.  Nil: only windows whose buffer has marks (a debugger's breakpoints) show the strip."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-ruler--setting-changed)

(drgnx-defsetting drgnx-minimap-hide-short t
  "Non-nil: the scroll bar hides while the window shows all of its content (it comes back once the content runs
past the window; the text keeps its width either way)."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-ruler--setting-changed)

(defconst drgnx-ruler-kinds '(change error warning info hit breakpoint bookmark symbol agent pin other)
  "The marks' kinds; a kind's index is its number in the line model (`nidhogg-lines-set-marks').")

(drgnx-defsetting drgnx-marks-kinds drgnx-ruler-kinds
  "The kinds of marks the scroll bar and the next-mark keys show (`drgnx-ruler-kinds'): changes, errors, warnings,
notes, search hits, breakpoints, bookmarks, symbol uses, agent edits, pinned regions, and any other producer's."
  :type '(set (const change) (const error) (const warning) (const info) (const hit) (const breakpoint)
              (const bookmark) (const symbol) (const agent) (const pin) (const other))
  :group 'drgnx-minimap :scope 'global :apply #'drgnx-ruler--kinds-changed)

(defvar drgnx-ruler-owner-kinds
  '((hunks . change) (search . hit) (debug . breakpoint) (bookmarks . bookmark) (symbol . symbol) (agent . agent)
    (pins . pin))
  "Each producer's kind of marks (`drgnx-ruler-source''s OWNER), unless the mark's face names one
\(`drgnx-ruler-face-kinds').")

(defvar drgnx-ruler-face-kinds
  '((drgnx-marks-error . error) (drgnx-marks-warning . warning) (drgnx-marks-info . info))
  "The kinds a mark's face names, over its producer's (a producer of problems gives each severity its face).")

(defface drgnx-ruler-view '((t :inherit default))
  "The scroll bar's thumb over the part of the content the window shows: its foreground, at 26 % (minimap.css
`.sbar .thumb')." :group 'drgnx-minimap)

(defconst drgnx-ruler--thumb-opacity 0.26 "How opaque the thumb is drawn in `drgnx-ruler-view's foreground.")

(defconst drgnx-ruler--lanes '((left 1 . 4) (middle 4 . 8) (right 8 . 11) (full 0 . 12))
  "Each lane's x range in the strip, in logical pixels (minimap.css `.mk.l', `.mk.c', `.mk.r').")

(defconst drgnx-ruler--width 12 "The strip's width in logical pixels.")
(defconst drgnx-ruler--thumb-inset 3 "The thumb's inset from either side of the strip, logical pixels.")
(defconst drgnx-ruler--thumb-radius 3 "The thumb's corner radius, logical pixels.")
(defconst drgnx-ruler--mark-height 2 "A mark's height, logical pixels.")
(defconst drgnx-ruler--mark-radius 1 "A mark's corner radius, logical pixels.")
(defconst drgnx-ruler--dot '(3 9 6 3) "A `dot' mark (a breakpoint): its x range, height and radius, logical pixels.")

(defvar-local drgnx-ruler--sources nil "This buffer's producers: an alist OWNER → FUNCTION (no arguments) → marks.")
(defvar-local drgnx-ruler--marks nil
  "The marks as last asked, drawn in this order: (POS LANE FACE PRIORITY SHAPE END KIND) each.")
(defvar-local drgnx-ruler--sent nil
  "The marks the line model was last given: an alist KIND → their vectors; t after an edit (the model has moved
them, so the next sync gives every kind again).")

(defvar-local drgnx-ruler-span-function nil
  "Nil, or a function of no arguments giving the buffer's rows as a part of a view: (FROM LENGTH TOTAL), the buffer
holding rows FROM to FROM + LENGTH of TOTAL (a list the hub sends a window of), or nil when it holds them all.  The
strip then stands for the TOTAL rows.  Whoever moves the window calls `drgnx-ruler-update' after the draw.")

(defvar-local drgnx-hscrollbar nil
  "Non-nil: this buffer's windows get the horizontal strip as an editor's do (`drgnx-minimap-hstrip'), though the
buffer is not a file's.  Lists that cut their rows with an ellipsis leave it nil.")

(defvar-local drgnx-ruler-goto-fraction-function nil
  "Nil, or a function of (WINDOW FRACTION): a press or drag on the strip of a view with a span went to FRACTION of
the whole, outside the rows the buffer holds; it brings those rows and puts WINDOW there.")

(defvar drgnx-ruler-mode)

(defun drgnx-ruler-available-p ()
  "Whether this Emacs draws the ruler on the selected frame: Nidhogg's Glitnir, on a graphical frame (a strip in the
fringe) or a terminal's (a margin column; not batch Emacs's initial frame, which is no terminal anyone sees)."
  (and (featurep 'glitnir-ruler) (or (display-graphic-p) (not (frame-initial-p))) t))

(defun drgnx-ruler--column-p (window)
  "Whether WINDOW's strip is a terminal's margin column, not a strip in its fringe."
  (not (display-graphic-p (window-frame window))))

(defun drgnx-scrollbar-window-p (window)
  "Whether WINDOW is a scrollable surface that gets the scroll bar: an editor group, a docked pane (the Explorer, the
panel, the right dock), a popup lane, or a window of a child frame (a palette's list); never the minibuffer, chrome
\(the status bar and other windows with a `drgnx-role' that is not a pane), a package's side window, or a window
marked `drgnx-minimap-exclude' (the peek card's, the sticky header's) or of a frame with that parameter (Nidhogg's
menus: sized to their rows, a strip would cut them)."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'drgnx-minimap-exclude))
       (not (frame-parameter (window-frame window) 'drgnx-minimap-exclude))
       (let ((role (window-parameter window 'drgnx-role)))
         (if role
             (memq role '(dock panel right))
           (or (window-parameter window 'drgnx-popup)
               (frame-parent (window-frame window))
               (not (window-parameter window 'window-side)))))
       t))

(defun drgnx-ruler--wants-p (window)
  "Whether WINDOW shows the strip now: its buffer has marks, or the scroll bar is on and WINDOW is a surface."
  (and (with-selected-frame (window-frame window) (drgnx-ruler-available-p))
       (with-current-buffer (window-buffer window)
         (or (and drgnx-ruler-mode drgnx-ruler--marks)
             (and drgnx-scrollbar-mode drgnx-minimap-ruler (drgnx-scrollbar-window-p window))))
       t))

(defun drgnx-ruler-source (owner function &optional buffer)
  "OWNER's marks in BUFFER (default current) come from FUNCTION; nil FUNCTION takes OWNER's marks away."
  (with-current-buffer (or buffer (current-buffer))
    (setq drgnx-ruler--sources (if function
                                   (cons (cons owner function) (assq-delete-all owner drgnx-ruler--sources))
                                 (assq-delete-all owner drgnx-ruler--sources)))
    (if drgnx-ruler--sources
        (if drgnx-ruler-mode (drgnx-ruler-refresh) (drgnx-ruler-mode 1))
      (when drgnx-ruler-mode (drgnx-ruler-mode -1)))))

(defun drgnx-ruler--kind (owner m)
  "The kind of OWNER's mark M: its face's (`drgnx-ruler-face-kinds'), else OWNER's, else `other'."
  (or (alist-get (nth 2 m) drgnx-ruler-face-kinds) (alist-get owner drgnx-ruler-owner-kinds) 'other))

(defun drgnx-ruler--ask ()
  "The producers' marks of the kinds shown (`drgnx-marks-kinds'), each with its kind, the highest PRIORITY last
\(drawn on top)."
  (let (marks)
    (pcase-dolist (`(,owner . ,f) drgnx-ruler--sources)
      (dolist (m (funcall f))
        (let ((kind (drgnx-ruler--kind owner m)))
          (when (memq kind drgnx-marks-kinds)
            (push (list (nth 0 m) (nth 1 m) (nth 2 m) (nth 3 m) (nth 4 m) (nth 5 m) kind) marks)))))
    (sort marks (lambda (a b) (< (or (nth 3 a) 0) (or (nth 3 b) 0))))))

(defun drgnx-ruler--sync ()
  "Give the buffer text's line model each kind's marks whose set changed since it was last given them (Nidhogg)."
  (when (fboundp 'nidhogg-lines-set-marks)
    (let (by-kind)
      (dolist (m drgnx-ruler--marks)
        (push (vector (nth 0 m) (nth 5 m) (cl-position (nth 1 m) '(left middle right full)) 0 (or (nth 3 m) 0))
              (alist-get (nth 6 m) by-kind)))
      (when (or by-kind drgnx-ruler--sent)
        (nidhogg-lines-enable)
        (let ((all (eq drgnx-ruler--sent t)))
          (when all (setq drgnx-ruler--sent nil))
          (dolist (k drgnx-ruler-kinds)
            (let ((new (sort (alist-get k by-kind) (lambda (a b) (< (aref a 0) (aref b 0))))))
              (unless (and (not all) (equal new (alist-get k drgnx-ruler--sent)))
                (nidhogg-lines-set-marks nil (cl-position k drgnx-ruler-kinds) new)
                (setf (alist-get k drgnx-ruler--sent nil 'remove) new)))))))))

(defun drgnx-ruler--mark (m frame)
  "Mark M, (POS LANE FACE PRIORITY [SHAPE END]), as `glitnir-ruler' takes it for FRAME: (POS X0 X1 FACE HEIGHT
RADIUS [END])."
  (pcase-let ((`(,x0 ,x1 ,h ,r) (if (eq (nth 4 m) 'dot)
                                    drgnx-ruler--dot
                                  (let ((lane (alist-get (nth 1 m) drgnx-ruler--lanes)))
                                    (list (car lane) (cdr lane) drgnx-ruler--mark-height drgnx-ruler--mark-radius)))))
    (append (list (car m) (drgnx-px x0 frame) (drgnx-px x1 frame) (nth 2 m) (drgnx-px h frame) (drgnx-px r frame))
            (and (nth 5 m) (list (nth 5 m))))))

(defun drgnx-ruler--spec (window)
  "WINDOW's `glitnir-ruler': the strip in its fringe, beside the text, the thumb, the span and the marks."
  (let ((frame (window-frame window))
        (span (and drgnx-ruler-span-function (funcall drgnx-ruler-span-function))))
    (append
     (list :width (drgnx-px drgnx-ruler--width frame)
           :right (or (window-parameter window 'drgnx-ruler-fringe) 0)
           :height (drgnx-px drgnx-ruler--mark-height frame)
           :band (cons 'drgnx-ruler-view drgnx-ruler--thumb-opacity)
           :thumb-inset (drgnx-px drgnx-ruler--thumb-inset frame)
           :radius (drgnx-px drgnx-ruler--thumb-radius frame)
           :hide-short (and drgnx-minimap-hide-short t))
     (and span (list :span span))
     (list :marks (mapcar (lambda (m) (drgnx-ruler--mark m frame)) (and drgnx-ruler-mode drgnx-ruler--marks))))))

(defun drgnx-ruler--show (window)
  "Give WINDOW the strip: its right fringe widened by the strip (once), or on a terminal a one-column right margin
\(`drgnx-margins-ruler'), and the spec, set only when it changed."
  (if (drgnx-ruler--column-p window)
      (drgnx-margins-ruler window t)
    (let* ((fr (window-fringes window))
           ;; the strip, and what an owner reserves inside it (a sticky minimap: `drgnx-ruler-reserve')
           (width (+ (drgnx-px drgnx-ruler--width (window-frame window))
                     (or (window-parameter window 'drgnx-ruler-reserve) 0)))
           (own (or (window-parameter window 'drgnx-ruler-fringe) (cadr fr))))
      (unless (and (window-parameter window 'drgnx-ruler-fringe) (= (cadr fr) (+ own width)))
        (setq own (if (window-parameter window 'drgnx-ruler-fringe) own (cadr fr)))
        (set-window-parameter window 'drgnx-ruler-fringe own)
        (set-window-fringes window (car fr) (+ own width) (nth 2 fr)))))
  (let ((spec (with-current-buffer (window-buffer window) (drgnx-ruler--spec window))))
    (unless (equal spec (window-parameter window 'glitnir-ruler))
      (set-window-parameter window 'glitnir-ruler spec))))

(defun drgnx-ruler-reserve (window px)
  "Widen WINDOW's right fringe by PX device pixels inside its strip (nil: none), narrowing the text: a sticky minimap
opens there instead of over the text.  The strip stays outermost."
  (set-window-parameter window 'drgnx-ruler-reserve px)
  (when (window-parameter window 'drgnx-ruler-fringe) (drgnx-ruler--show window)))

(defun drgnx-ruler--hide (window)
  "Take the strip from WINDOW: the marks, and its fringe back to its own width (a terminal's margin column)."
  (when (window-live-p window)
    (when (window-parameter window 'drgnx-margins-ruler) (drgnx-margins-ruler window nil))
    (set-window-parameter window 'drgnx-ruler-reserve nil)
    (when-let* ((own (window-parameter window 'drgnx-ruler-fringe)))
      (let ((fr (window-fringes window)))
        (set-window-fringes window (car fr) own (nth 2 fr)))
      (set-window-parameter window 'drgnx-ruler-fringe nil))
    (when (window-parameter window 'glitnir-ruler)
      (set-window-parameter window 'glitnir-ruler nil))))

(defvar drgnx-ruler-place-functions nil
  "Functions called with WINDOW and whether it shows the strip, each time its strip is placed (the minimap widens
out of the strip: `editor/minimap').")

(defun drgnx-ruler--place (window)
  "WINDOW's strip as it should be now: shown with its spec, or gone."
  (let ((on (drgnx-ruler--wants-p window)))
    (if on (drgnx-ruler--show window) (drgnx-ruler--hide window))
    (run-hook-with-args 'drgnx-ruler-place-functions window on)))

(defun drgnx-ruler-update (&optional buffer)
  "Give every window showing BUFFER (default current) its strip again, without asking the producers: its span moved
or a setting changed."
  (with-current-buffer (or buffer (current-buffer))
    (dolist (w (get-buffer-window-list nil nil t)) (drgnx-ruler--place w))))

(defun drgnx-ruler-refresh (&optional buffer)
  "Ask BUFFER's producers again (default current), and give every window showing it the marks."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-ruler-mode
      (setq drgnx-ruler--marks (drgnx-ruler--ask))
      (drgnx-ruler--sync))
    (drgnx-ruler-update)))

(defun drgnx-ruler--buffer-changed (frame-or-window)
  "`window-buffer-change-functions' (global): a window that now shows another buffer gets that buffer's strip, or
loses the strip."
  (dolist (w (if (windowp frame-or-window) (list frame-or-window) (window-list frame-or-window 'nomini)))
    (let ((on (drgnx-ruler--wants-p w)))
      (if on
          (drgnx-ruler--show w)
        (when (or (window-parameter w 'glitnir-ruler) (window-parameter w 'drgnx-ruler-fringe)
                  (window-parameter w 'drgnx-margins-ruler))
          (drgnx-ruler--hide w)))
      (run-hook-with-args 'drgnx-ruler-place-functions w on))))

(defun drgnx-ruler--changed (&rest _)
  "`after-change-functions': the marks are asked again once the typing rests, and given to the line model again."
  (when drgnx-ruler--sent (setq drgnx-ruler--sent t))
  (drgnx-timer-debounce (cons 'ruler (current-buffer)) 0.3 #'drgnx-ruler-refresh :args (list (current-buffer))
                        :owner (current-buffer)))

(defun drgnx-ruler--off ()
  "`change-major-mode-hook' and `kill-buffer-hook': the ruler goes before the buffer's locals do."
  (drgnx-ruler-mode -1))

(defun drgnx-ruler--goto (window posn)
  "Show in WINDOW the place POSN, a press on its strip, stands for, centred: the thumb's middle under the pointer."
  (let ((frac (and (fboundp 'glitnir-ruler-fraction) (glitnir-ruler-fraction posn)))
        (span (with-current-buffer (window-buffer window)
                (and drgnx-ruler-span-function (funcall drgnx-ruler-span-function)))))
    (if (and frac span (let ((row (* frac (nth 2 span))))
                         (or (< row (nth 0 span)) (>= row (+ (nth 0 span) (nth 1 span))))))
        (with-current-buffer (window-buffer window)
          (when drgnx-ruler-goto-fraction-function (funcall drgnx-ruler-goto-fraction-function window frac)))
      (when-let* ((pos (and (fboundp 'glitnir-ruler-position) (glitnir-ruler-position posn))))
        (with-selected-window window
          (goto-char pos)
          (recenter))))))

(defun drgnx-ruler--on-strip-p (posn)
  "Whether POSN, in a right fringe, is on the strip (not the fringe's own pixels outside it, the card edge's)."
  (let* ((w (posn-window posn))
         (own (window-parameter w 'drgnx-ruler-fringe))
         (edges (window-pixel-edges w)))
    (and own (window-parameter w 'glitnir--ruler)
         (< (+ (car edges) (car (posn-x-y posn)))
            (- (nth 2 edges) (window-right-divider-width w) (window-scroll-bar-width w) own)))))

(defun drgnx-ruler-press (event)
  "A press on a window's right fringe: on the strip it goes to that place and a drag scrolls with the pointer until
the button comes up (Lisp per motion only while the button is held); off the strip, the card edge's drag."
  (interactive "e")
  (let* ((posn (event-start event)) (w (posn-window posn)))
    (if (not (and (window-live-p w) (drgnx-ruler--on-strip-p posn)))
        (when (fboundp 'drgnx-look-edge-drag) (drgnx-look-edge-drag event))
      (drgnx-ruler--goto w posn)
      (track-mouse
        (let (e done)
          (while (not done)
            (setq e (read-event))
            (cond ((mouse-movement-p e)
                   (let ((p (event-start e)))
                     (when (eq (posn-window p) w)
                       (drgnx-ruler--goto w (list w 'right-fringe (posn-x-y p) 0 nil nil nil nil nil nil)))))
                  ((memq (event-basic-type e) '(mouse-1)) (setq done t))
                  ((not (memq 'down (event-modifiers e))) (setq done t)))))))))

(defun drgnx-ruler-click (event)
  "Mouse EVENT on the ruler's strip: its window shows that place of the file, centred."
  (interactive "e")
  (let ((posn (event-start event)))
    (when (window-live-p (posn-window posn)) (drgnx-ruler--goto (posn-window posn) posn))))

(defvar-keymap drgnx-ruler-mode-map
  :doc "The ruler's mouse: a click on the strip goes there."
  "<right-fringe> <mouse-1>" #'drgnx-ruler-click)

(define-minor-mode drgnx-ruler-mode
  "The overview ruler's marks at this buffer's windows' right edge, while producers have marks (`drgnx-ruler-source')."
  :group 'drgnx-minimap :keymap drgnx-ruler-mode-map
  (if drgnx-ruler-mode
      (progn
        (add-hook 'after-change-functions #'drgnx-ruler--changed nil t)
        (add-hook 'change-major-mode-hook #'drgnx-ruler--off nil t)
        (add-hook 'kill-buffer-hook #'drgnx-ruler--off nil t)
        (add-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed)
        (drgnx-ruler-refresh))
    (remove-hook 'after-change-functions #'drgnx-ruler--changed t)
    (remove-hook 'change-major-mode-hook #'drgnx-ruler--off t)
    (remove-hook 'kill-buffer-hook #'drgnx-ruler--off t)
    (drgnx-timer-cancel (cons 'ruler (current-buffer)))
    (setq drgnx-ruler--marks nil drgnx-ruler--sources nil)
    (drgnx-ruler--sync)
    (mapc #'drgnx-ruler--place (get-buffer-window-list nil nil t))
    (unless (or drgnx-scrollbar-mode
                (seq-some (lambda (b) (and (not (eq b (current-buffer))) (buffer-local-value 'drgnx-ruler-mode b)))
                          (buffer-list)))
      (remove-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed))))

(defun drgnx-scrollbar-refresh-all ()
  "Every live window's strip as it should be now (the scroll bar turned on or off, a setting, the scale or theme)."
  (dolist (f (frame-list))
    (dolist (w (window-list f 'nomini)) (drgnx-ruler--place w))))

(defun drgnx-scrollbar--frame-made (frame)
  "`after-make-frame-functions': a new frame's windows get the strip."
  (dolist (w (window-list frame 'nomini)) (drgnx-ruler--place w)))

(defvar-keymap drgnx-scrollbar-mode-map
  :doc "The scroll bar's mouse: a press on the strip goes there, a drag scrolls."
  "<right-fringe> <down-mouse-1>" #'drgnx-ruler-press
  "<right-fringe> <mouse-1>" #'ignore)

(define-minor-mode drgnx-scrollbar-mode
  "The scroll bar on every scrollable surface (`drgnx-scrollbar-window-p'): a strip at the window's right edge with
the thumb and the buffer's marks, hidden while the content fits (`drgnx-minimap-hide-short')."
  :global t :group 'drgnx-minimap :keymap drgnx-scrollbar-mode-map
  (if drgnx-scrollbar-mode
      (progn
        (add-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed)
        (add-hook 'after-make-frame-functions #'drgnx-scrollbar--frame-made))
    (remove-hook 'after-make-frame-functions #'drgnx-scrollbar--frame-made)
    (unless (seq-some (lambda (b) (buffer-local-value 'drgnx-ruler-mode b)) (buffer-list))
      (remove-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed)))
  (drgnx-scrollbar-refresh-all))

(provide 'drgnx-ruler)
;;; drgnx-ruler.el ends here
