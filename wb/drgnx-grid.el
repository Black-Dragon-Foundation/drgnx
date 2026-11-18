;;; drgnx-grid.el --- The tiled grid: every pane a tile on Emacs's own window tree -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A tile is a live window and a container an internal window: the grid is Emacs's window tree, and drgnx keeps no
;; second tree beside it (`drgnx-grid-tree' is only its snapshot format).  Two kinds of tile:
;; - a tool tile: window parameter `drgnx-role' `tile', `drgnx-pane-stack' (the pane kinds it holds, the shown one
;;   first), `drgnx-tile-id' (an integer, per frame) and `drgnx-tile-dock' (`left', `right', `bottom', or nil once it
;;   was moved away from its home); it is dedicated, never selected unless asked, and `delete-window' on it hides it;
;; - an editor tile: an ordinary editor window (no role), with a `drgnx-tile-id' and its tabs (`drgnx-tabs').
;; Every tile carries `no-delete-other-windows', so `delete-other-windows' cannot collapse a layout.
;; The rules the grid keeps are R1–R8 (docs/develop/core.md, "Tiles and the `grid' backend"), each with a test in
;; test/unit/grid-rules-test.el.  The grid is the `grid' backend of pane kinds (`drgnx-pane--backends'): callers keep
;; calling `drgnx-pane-show', `-hide', `-focus', `-window' and `-resize'.  See docs/develop/core.md, "The grid".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-state)
(require 'drgnx-state-intent)
(require 'drgnx-pixels)
(require 'drgnx-ui-kit)                 ; the grip's glyph (`drgnx-face-glyph')
(require 'drgnx-grid-tree)
(require 'drgnx-panes)

(defvar drgnx-rules--placing)
(defvar drgnx-rules-never-cover-modes)
(defvar drgnx-wb-dock-columns)
(declare-function drgnx-wb-focus-editor "drgnx-wb")
(declare-function drgnx-area--remember "drgnx-area" (area window))
(declare-function drgnx-grid--tab-press "drgnx-grid-ops" (event))
(declare-function drgnx-grid-tab-menu-click "drgnx-grid-frames" (event))
(declare-function drgnx-grid-grip-press "drgnx-grid-ops" (event))
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-wb-close-button "drgnx-wb")
(declare-function drgnx-wb-bar "drgnx-wb")

(defgroup drgnx-grid nil "The tiled grid: every pane a tile." :group 'drgnx)

(defcustom drgnx-grid-min-px 120
  "The least width or height of a tile in a graphical frame, in logical pixels (`drgnx-px')."
  :type 'natnum :group 'drgnx-grid)

(defcustom drgnx-grid-min-columns 12
  "The least width of a tile in a terminal frame, in columns."
  :type 'natnum :group 'drgnx-grid)

(defcustom drgnx-grid-min-lines 3
  "The least height of a tile in a terminal frame, in lines."
  :type 'natnum :group 'drgnx-grid)

(defcustom drgnx-grid-placements '((work-trail :below-map t :narrow work-detail))
  "Where a kind's tile goes the first time it shows while the Work map does (work-space §9.3): KIND → PLIST.
`:below-map' t: a tile of its own below the map's.  `:narrow' OTHER: when the frame is narrower than
`drgnx-grid-narrow-px', with OTHER instead, when OTHER shows: stacked onto OTHER's tile, or a tile below OTHER's dock."
  :type '(alist :key-type symbol :value-type plist) :group 'drgnx-grid)

(defcustom drgnx-grid-narrow-px 1200
  "Below this frame width, in logical pixels, a placement's `:narrow' applies (`drgnx-grid-placements')."
  :type 'natnum :group 'drgnx-grid)

(defconst drgnx-grid-docks '(left bottom right) "The homes a tool tile docks at.")

(defvar drgnx-grid--into nil
  "A live window `drgnx-grid-split-dock' hands out in place of a new one: bound by `drgnx-grid-apply-tree' while the
side bar or an area fills the window it made for them.")

(defconst drgnx-grid--default-size '((left . 32) (bottom . 12) (right . 50))
  "A dock's size the first time it shows, in columns (left, right) or lines (bottom), when its kinds give none.")

;;;; Tiles

(defun drgnx-grid-root (&optional frame)
  "The root of FRAME's grid: `window-main-window' (the frame's root less the shell's side windows, the rail), less the
status bar's row when the bar runs across the frame (the root's last child, `drgnx-statusbar')."
  (let* ((main (window-main-window frame)) (last (and (not (window-live-p main)) (window-last-child main))))
    (if (and last (eq (window-parameter last 'drgnx-role) 'statusbar) (eq (window-prev-sibling last) (window-child main)))
        (window-child main)
      main)))

(defun drgnx-grid-on-p ()
  "Non-nil when pane kinds live in the grid (`drgnx-pane-backend' `grid'): the docks and the areas are then tiles."
  (eq drgnx-pane-backend 'grid))

(defun drgnx-grid-tool-tile-p (window)
  "Non-nil when WINDOW is a live tool tile: role `tile', or the main window of a docked tile (`drgnx-tile-dock': the
side bar, the panel, the right side), never one of its parts (`drgnx-tile-part')."
  (and (window-live-p window)
       (or (eq (window-parameter window 'drgnx-role) 'tile) (window-parameter window 'drgnx-tile-dock))
       (not (window-parameter window 'drgnx-tile-part))))

(defun drgnx-grid-editor-tile-p (window)
  "Non-nil when WINDOW is a live editor tile: an editor window of the state store (no role, no side)."
  (and (window-live-p window) (eq (drgnx-state-window-role window) 'editor)))

(defun drgnx-grid-tiles (&optional frame filter)
  "FRAME's tiles in reading order (top-left to bottom-right).  FILTER `editor' or `tool' keeps only those."
  (let ((frame (or frame (selected-frame))))
    (seq-filter (lambda (w) (pcase filter
                              ('editor (drgnx-grid-editor-tile-p w))
                              ('tool (drgnx-grid-tool-tile-p w))
                              (_ (or (drgnx-grid-tool-tile-p w) (drgnx-grid-editor-tile-p w)))))
                (window-list frame 'nomini (frame-first-window frame)))))

(defun drgnx-grid--next-id (frame)
  "A new tile id on FRAME."
  (let ((n (1+ (or (frame-parameter frame 'drgnx-grid-next-id) 0))))
    (set-frame-parameter frame 'drgnx-grid-next-id n)
    n))

(defun drgnx-grid-tile-id (window)
  "WINDOW's tile id, given one first if it has none."
  (or (window-parameter window 'drgnx-tile-id)
      (set-window-parameter window 'drgnx-tile-id (drgnx-grid--next-id (window-frame window)))))

(defun drgnx-grid--tile-by-id (id frame)
  (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) id)) (window-list frame 'nomini)))

(defun drgnx-grid--adopt (window)
  "Make editor WINDOW an editor tile: an id, `no-delete-other-windows', and the grid's `delete-window' (R8)."
  (drgnx-grid-tile-id window)
  (set-window-parameter window 'no-delete-other-windows t)
  (unless (window-parameter window 'delete-window)
    (set-window-parameter window 'delete-window #'drgnx-grid--delete-editor)))

(defun drgnx-grid--adopt-editors (&optional frame)
  "Adopt FRAME's editor windows as editor tiles (those that are not yet)."
  (dolist (w (drgnx-grid-tiles frame 'editor))
    (unless (window-parameter w 'no-delete-other-windows) (drgnx-grid--adopt w))))

(defun drgnx-grid--windows-changed (data)
  "The store's `windows-changed' while the grid is on: a new editor window (a split) becomes an editor tile, and a
grid a package's own window calls collapsed is noted for undo (`drgnx-grid--watch-foreign')."
  (when-let* ((frame (plist-get data :frame)) ((frame-live-p frame)))
    (drgnx-grid--watch-foreign frame)
    (drgnx-grid--adopt-editors frame)))

;;;; Stack entries: a kind, or one instance of it

;; A tool tile's stack (`drgnx-pane-stack') holds entries: a KIND (a symbol), or (KIND . KEY), one instance of a kind
;; whose definition has `:instance' (KEY → its buffer) and `:instance-key' (a buffer → its KEY, or nil): the agent
;; panel's sessions, each in a tile of its own (`drgnx-grid--show-instance').
(defun drgnx-grid--entry-kind (entry)
  "The kind of stack ENTRY."
  (if (consp entry) (car entry) entry))

;;;; Kinds' buffers, starts and points, per frame

(defvar drgnx-grid--kinds (make-hash-table :test 'eq :weakness 'key)
  "Frame → alist KIND → (BUFFER START POINT): where each kind was left on that frame.
Kept out of frame parameters: a buffer object in one would make the saved frame state unreadable.")

(defun drgnx-grid--saved (kind frame)
  (alist-get kind (gethash frame drgnx-grid--kinds) nil nil #'equal))

(defun drgnx-grid--remember (window)
  "Remember the buffer, start and point tile WINDOW shows for its shown kind."
  (when-let* (((drgnx-grid-tool-tile-p window)) (kind (car (window-parameter window 'drgnx-pane-stack))))
    (setf (alist-get kind (gethash (window-frame window) drgnx-grid--kinds) nil nil #'equal)
          (list (window-buffer window) (window-start window) (window-point window)))))

(defun drgnx-grid--placeholder (entry)
  "ENTRY's kind's placeholder: its :placeholder function's buffer, else the tile placeholder
\(`drgnx-grid-tile-placeholder')."
  (let* ((kind (drgnx-grid--entry-kind entry)) (spec (drgnx-pane-kind kind)) (fn (plist-get spec :placeholder))
         (b (and (functionp fn) (funcall fn))))
    (if (buffer-live-p b) b (drgnx-grid-tile-placeholder kind))))

;;;; The tile placeholder: a kind whose module is off, or whose content is gone

(defvar drgnx-grid-placeholder-mode-map (make-sparse-keymap)
  "Keys of a tile placeholder: Open (RET) and Close (x), bound through the command registry.")

(define-derived-mode drgnx-grid-placeholder-mode special-mode "Tile"
  "A tile whose kind is not defined (its module is off) or has nothing to show.  It fills in place when the kind is
defined again (`drgnx-grid--kind-defined')."
  (setq-local cursor-type nil truncate-lines t)
  (drgnx-ui-kit-focus-remap-enable))

(defvar-local drgnx-grid-placeholder-kind nil "The kind the tile placeholder in this buffer stands for.")

(defun drgnx-grid--placeholder-name (kind) (format " *drgnx tile: %s*" kind))

(defun drgnx-grid-tile-placeholder (kind)
  "KIND's tile placeholder buffer, ` *drgnx tile: KIND*': one line saying what waits there (its title, or KIND when it
is not defined) and the keys, RET to open it and x to close the tile, as kit key hints.  The line is a kit row in the
selected state (`drgnx-row-selected', which follows the tile's focus).  Its text is written again at each call."
  (let* ((b (get-buffer-create (drgnx-grid--placeholder-name kind) t))
         (key (lambda (k) (drgnx-ui-kit-key-hint k nil 'text)))
         (text (if (drgnx-pane-kind kind)
                   (format "%s · nothing to show · %s open · %s close" (drgnx-grid--title kind)
                           (funcall key "↵") (funcall key "x"))
                 (format "%s · waits for its module · %s choose · %s close" kind (funcall key "↵") (funcall key "x")))))
    (add-face-text-property 0 (length text) (drgnx-ui-kit-row-face 'selected) t text)
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-grid-placeholder-mode) (drgnx-grid-placeholder-mode))
      (setq drgnx-grid-placeholder-kind kind)
      (unless (equal-including-properties (buffer-string) text)
        (let ((inhibit-read-only t)) (erase-buffer) (insert text) (goto-char (point-min)))))
    b))

(defun drgnx-grid--placeholder-window ()
  "The tool tile showing the current buffer, a tile placeholder (the selected window when it does)."
  (if (eq (window-buffer) (current-buffer)) (selected-window) (get-buffer-window (current-buffer))))

(defun drgnx-grid-placeholder-open ()
  "In a tile placeholder: show its kind's own content in the tile when the kind is defined, else choose what the tile
shows (`drgnx-grid-pick-kind')."
  (interactive)
  (let ((kind drgnx-grid-placeholder-kind) (w (drgnx-grid--placeholder-window)))
    (when (window-live-p w)
      (if (drgnx-pane-kind kind)
          (progn (drgnx-grid--put-buffer w (car (window-parameter w 'drgnx-pane-stack)) (window-frame w))
                 (drgnx-grid--put-row w))
        (set-window-parameter w 'drgnx-pane-stack nil)
        (drgnx-grid-pick-kind w)))))

(defun drgnx-grid-placeholder-close ()
  "In a tile placeholder: hide its tile (`drgnx-grid-hide')."
  (interactive)
  (let ((w (drgnx-grid--placeholder-window)))
    (when (window-live-p w)
      (with-selected-frame (window-frame w) (drgnx-grid-hide (car (window-parameter w 'drgnx-pane-stack)))))))

(defun drgnx-grid--kind-tiles (kind)
  "The tool tiles of every frame whose shown entry is KIND's, as (WINDOW . ENTRY)."
  (let (out)
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (let ((entry (car (window-parameter w 'drgnx-pane-stack))))
          (when (and (drgnx-grid-tool-tile-p w) entry (eq (drgnx-grid--entry-kind entry) kind))
            (push (cons w entry) out)))))
    out))

(defun drgnx-grid--kind-undefined (kind)
  "KIND is no longer defined (its module turned off): its tiles stay where they are and show its placeholder."
  (pcase-dolist (`(,w . ,entry) (drgnx-grid--kind-tiles kind))
    (setf (alist-get entry (gethash (window-frame w) drgnx-grid--kinds) nil nil #'equal) nil)
    (set-window-dedicated-p w nil)
    (set-window-buffer w (drgnx-grid-tile-placeholder kind))
    (set-window-dedicated-p w 'drgnx)
    (drgnx-grid--put-row w)))

(defun drgnx-grid--kind-defined (kind)
  "KIND is defined (again): its tiles that show its placeholder show its content."
  (pcase-dolist (`(,w . ,entry) (drgnx-grid--kind-tiles kind))
    (when (eq (window-buffer w) (get-buffer (drgnx-grid--placeholder-name kind)))
      (set-window-dedicated-p w nil)
      (drgnx-grid--put-buffer w entry (window-frame w))
      (drgnx-grid--put-row w))))

(defun drgnx-grid--buffer-for (kind frame &optional buffer)
  "The buffer KIND shows on FRAME: BUFFER when given, else the one it was left on, else its own (`:buffer'), else
its placeholder.  Also the saved start and point, as (BUFFER START POINT); START and POINT nil when none apply."
  (let ((saved (drgnx-grid--saved kind frame)))
    (cond ((buffer-live-p buffer) (list buffer nil nil))
          ((buffer-live-p (car saved)) saved)
          (t (let* ((spec (drgnx-pane-kind (drgnx-grid--entry-kind kind)))
                    (b (if (consp kind) (let ((fn (plist-get spec :instance))) (and fn (funcall fn (cdr kind))))
                         (and spec (plist-get spec :buffer))))
                    (own (cond ((functionp b) (funcall b)) ((stringp b) (get-buffer-create b)) ((buffer-live-p b) b))))
               (list (if (buffer-live-p own) own (drgnx-grid--placeholder kind)) nil nil))))))

(defun drgnx-grid--put-buffer (window kind frame &optional buffer)
  "Show KIND in tool tile WINDOW (its buffer, start and point as left, or BUFFER).  A kind with a `:fill' function (a
layout's pane: `drgnx-layouts-define-pane') and no BUFFER given fills WINDOW itself."
  (pcase-let* ((fill (and (not buffer) (plist-get (drgnx-pane-kind (drgnx-grid--entry-kind kind)) :fill)))
               (`(,b ,start ,point) (if fill
                                        (progn (funcall fill window) (list (window-buffer window) nil nil))
                                      (drgnx-grid--buffer-for kind frame buffer))))
    (unless (eq (window-buffer window) b)
      (set-window-buffer window b)
      ;; Emacs preserves a size only for the buffer it was set with: set again for this one
      (when-let* ((dock (window-parameter window 'drgnx-tile-dock)))
        (window-preserve-size window (drgnx-grid--horizontal-dock-p dock) t)))
    (set-window-dedicated-p window 'drgnx)
    (when start (set-window-start window start t))
    (when point (set-window-point window point))
    (with-current-buffer b (add-hook 'kill-buffer-hook #'drgnx-grid--killed nil t))
    (drgnx-grid--companions window kind b)
    b))

(defun drgnx-grid--companions (window kind buffer)
  "Show the companions KIND's `:companions' gives BUFFER in parts of tool tile WINDOW (role `tile': a docked area keeps
its own, `drgnx-area--companions'): the buffer above and the one below in windows of their own, fitted to their text
(at most a third of the tile), deleted when there is none."
  (when (eq (window-parameter window 'drgnx-role) 'tile)
    (let* ((fn (plist-get (drgnx-pane-kind (drgnx-grid--entry-kind kind)) :companions))
           (parts (and fn (not (eq buffer (drgnx-grid--placeholder kind))) (funcall fn buffer))))
      (cl-loop for which in '(above below) for want in (list (nth 0 parts) (nth 1 parts))
               for have = (drgnx-grid--part-of window which)
               do (cond ((not (buffer-live-p want)) (when have (drgnx-grid-delete-part have)))
                        (have (set-window-dedicated-p have nil) (set-window-buffer have want)
                              (set-window-dedicated-p have 'drgnx))
                        (t (let ((part (drgnx-grid-add-part window which
                                                            (max (window-default-line-height window)
                                                                 (/ (window-pixel-height window) 6)))))
                             (pcase-dolist (`(,k . ,v) `((drgnx-role . tile) (drgnx-grid-companion . ,which)
                                                         (no-other-window . t) (mode-line-format . none)
                                                         (header-line-format . none) (tab-line-format . none)
                                                         (delete-window . drgnx-grid--delete-companion)))
                               (set-window-parameter part k v))
                             (set-window-buffer part want)
                             (set-window-dedicated-p part 'drgnx)
                             (let ((window-resize-pixelwise t))
                               (ignore-errors
                                 (fit-window-to-buffer part (max 1 (/ (window-total-height window) 3)) 1))))))))))

(defun drgnx-grid--delete-companion (part)
  "`delete-window' on a companion PART: its tile hides, as `delete-window' on the tile's own window does."
  (let ((main nil))
    (walk-window-subtree (lambda (w) (when (drgnx-grid-tool-tile-p w) (setq main w))) (drgnx-grid--tile-root part))
    (if main (drgnx-grid--delete-window main) (drgnx-grid-delete-part part))))

(defun drgnx-grid--part-of (window which)
  "Tool tile WINDOW's companion part WHICH (`above', `below'), or nil."
  (let ((root (drgnx-grid--tile-root window)))
    (unless (window-live-p root)
      (let (found)
        (walk-window-subtree (lambda (w) (when (eq (window-parameter w 'drgnx-grid-companion) which) (setq found w)))
                             root)
        found))))

(defun drgnx-grid--killed ()
  "The current buffer is being killed: tiles showing it show their kind's placeholder (R6)."
  (let ((dying (current-buffer)))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (when (and (drgnx-grid-tool-tile-p w) (eq (window-buffer w) dying)
                   (not (window-parameter w 'drgnx-tile-temporary)))
          (let ((kind (car (window-parameter w 'drgnx-pane-stack))))
            (setf (alist-get kind (gethash f drgnx-grid--kinds) nil nil #'equal) nil)
            (let ((p (drgnx-grid--placeholder kind)))
              (unless (eq p dying)
                (set-window-buffer w p)
                (set-window-dedicated-p w 'drgnx)))
            (drgnx-grid--put-row w)))))))

;;;; Sizes

(defun drgnx-grid--horizontal-dock-p (dock) (memq dock '(left right)))

(defun drgnx-grid-min-size (frame horizontal)
  "The least width (HORIZONTAL) or height of a tile on FRAME, in its pixels."
  (if (display-graphic-p frame)
      (drgnx-px drgnx-grid-min-px frame)
    (if horizontal (* drgnx-grid-min-columns (frame-char-width frame))
      (* drgnx-grid-min-lines (frame-char-height frame)))))

(defun drgnx-grid--home (kind) (plist-get (drgnx-pane-kind kind) :home))

(defun drgnx-grid--dock-default-px (dock kinds frame)
  "DOCK's size the first time it shows on FRAME: its intent (`:sizes'), else the first of KINDS' :size, else
`drgnx-grid--default-size', in columns or lines made pixels."
  (or (plist-get (drgnx-state-intent frame :sizes dock) :px)
      (let ((n (or (seq-some (lambda (k) (plist-get (drgnx-pane-kind k) :size)) kinds)
                   (if (eq dock 'left) (or (bound-and-true-p drgnx-wb-dock-columns) 32)
                     (alist-get dock drgnx-grid--default-size)))))
        (if (drgnx-grid--horizontal-dock-p dock) (* n (frame-char-width frame)) (* n (frame-char-height frame))))))

(defun drgnx-grid-home-size (dock fraction minimum &optional frame)
  "Give DOCK (`left', `bottom', `right') on FRAME FRACTION of the frame's columns (lines for `bottom'), at least MINIMUM
of them: the size its tile has now, when it shows (a tile that cannot be that size stays as it is), and comes back at
\(the `:sizes' intent, by `auto').  A terminal's layout sizes its docks so (ui/terminal-layout).  Returns the size in
FRAME's pixels."
  (let* ((frame (or frame (selected-frame))) (horizontal (drgnx-grid--horizontal-dock-p dock))
         (unit (if horizontal (frame-char-width frame) (frame-char-height frame)))
         (px (* unit (max minimum (round (* fraction (if horizontal (frame-width frame) (frame-height frame))))))))
    (drgnx-state-note-intent frame :sizes dock px :by 'auto)
    (when-let* ((w (drgnx-grid-dock dock frame)))
      (let ((root (drgnx-grid--tile-root w)) (window-resize-pixelwise t))
        (ignore-errors (window-resize root (- px (window-size root horizontal t)) horizontal nil t))))
    px))

(defun drgnx-grid--min-along (window horizontal frame)
  "The least width (HORIZONTAL) or height of WINDOW's tiles together: `drgnx-grid-min-size' per tile, summed along a
combination in that direction, the largest across one."
  (if (window-live-p window)
      (drgnx-grid-min-size frame horizontal)
    (let ((sizes (mapcar (lambda (c) (drgnx-grid--min-along c horizontal frame)) (drgnx-grid--children window))))
      (if (window-combined-p (window-child window) horizontal) (apply #'+ sizes) (apply #'max sizes)))))

(defun drgnx-grid--dock-to (window dock px frame)
  "Resize DOCK's tile (main window WINDOW) on FRAME to PX pixels along its dock, but never so that the tiles beside
it have less than their least size (`drgnx-grid--min-along'): when they have less already, the dock gives way to
them.  Return its size after."
  (let* ((root (drgnx-grid--tile-root window)) (horizontal (drgnx-grid--horizontal-dock-p dock))
         (beside (drgnx-grid--beside dock frame))
         (delta (min (- px (window-size root horizontal t))
                     (- (window-size beside horizontal t) (drgnx-grid--min-along beside horizontal frame))))
         (window-resize-pixelwise t))
    (unless (zerop delta) (ignore-errors (window-resize root delta horizontal nil t)))
    (window-size root horizontal t)))

(defun drgnx-grid-keep-dock-sizes (frame)
  "FRAME's docks (the side bar, the panel, the right side) at their logical sizes, as VS Code's side bar keeps its
width.  Run at each window size change and scale change (`window-size-change-functions',
`nidhogg-frame-scale-change-functions').  The scale is `drgnx-pixels-scale' (the display's times the UI scale).
While the grid keeps its size and scale, a dock's size is its logical size, unless it is the size this function gave
it (a dock that gave way keeps the size it wants).  When the grid's size or scale changed (a monitor of another
scale, the UI scale, the window resized, the echo area grown with the font): each shown dock is given its logical
size in the window's pixels now, the editors taking the difference, but never below their least size
\(`drgnx-grid--dock-to'); a hidden dock comes back at it (its `:sizes' intent).  Kept in FRAME's parameter
`drgnx-grid--docks': (SCALE WANTED GIVEN SIZE), WANTED dock → logical px, GIVEN dock → the pixels given at SCALE,
SIZE the grid root's pixel size then (`drgnx-grid-root').  Nothing while a tile shows full size or a temporary window
shows."
  (when (and (frame-live-p frame) (display-graphic-p frame)
             (not (frame-parameter frame 'drgnx-grid-full)) (not (drgnx-grid--temporary-windows frame)))
    (let* ((scale (drgnx-pixels-scale frame))
           (size (let ((root (drgnx-grid-root frame))) (cons (window-pixel-width root) (window-pixel-height root))))
           (rec (frame-parameter frame 'drgnx-grid--docks))
           (wanted (copy-alist (nth 1 rec))) (given nil)
           (giving (and rec (or (/= scale (car rec)) (not (equal size (nth 3 rec)))))))
      (if giving
          (dolist (dock drgnx-grid-docks)
            (when-let* ((logical (alist-get dock wanted)))
              (if-let* ((w (drgnx-grid-dock dock frame)))
                  (push (cons dock (drgnx-grid--dock-to w dock (drgnx-px logical frame) frame)) given)
                (when (drgnx-state-intent frame :sizes dock)
                  (drgnx-state-note-intent frame :sizes dock (drgnx-px logical frame) :by 'auto)))))
        (setq given (copy-alist (nth 2 rec)))
        (dolist (dock drgnx-grid-docks)
          (when-let* ((w (drgnx-grid-dock dock frame)))
            (let ((px (window-size (drgnx-grid--tile-root w) (drgnx-grid--horizontal-dock-p dock) t)))
              (unless (eql px (alist-get dock given))
                (setf (alist-get dock wanted) (drgnx-grid-tree-to-logical px scale)
                      (alist-get dock given nil t) nil))))))
      (set-frame-parameter frame 'drgnx-grid--docks (list scale wanted given size)))))

;;;; Docks

(defun drgnx-grid-dock (dock &optional frame)
  "The tool tile docked at DOCK (`left', `bottom', `right') on FRAME, or nil."
  (seq-find (lambda (w) (and (drgnx-grid-tool-tile-p w) (eq (window-parameter w 'drgnx-tile-dock) dock)))
            (window-list (or frame (selected-frame)) 'nomini)))

(defun drgnx-grid--children (window)
  (let ((c (window-child window)) out)
    (while c (push c out) (setq c (window-next-sibling c)))
    (nreverse out)))

(defun drgnx-grid--leaves (window)
  "The live windows under WINDOW (itself when live)."
  (if (window-live-p window) (list window) (mapcan #'drgnx-grid--leaves (drgnx-grid--children window))))

(defun drgnx-grid--lca (windows)
  "The smallest window (live or internal) holding every one of WINDOWS."
  (let ((node (car windows)))
    (while (and node (not (seq-every-p (lambda (w) (memq w (drgnx-grid--leaves node))) windows)))
      (setq node (window-parent node)))
    node))

(defun drgnx-grid--center (frame)
  "The part of FRAME's grid between the left and right docks: the smallest window holding every tile that is not
docked left or right; nil when there is none."
  (let ((inner (seq-remove (lambda (w) (memq (window-parameter w 'drgnx-tile-dock) '(left right)))
                           (drgnx-grid-tiles frame))))
    (and inner (drgnx-grid--lca inner))))

(defun drgnx-grid--beside (dock frame)
  "The smallest window holding every tile of FRAME not docked at DOCK, else the grid's root."
  (let ((tiles (seq-remove (lambda (w) (eq (window-parameter w 'drgnx-tile-dock) dock)) (drgnx-grid-tiles frame))))
    (or (and tiles (drgnx-grid--lca tiles)) (drgnx-grid-root frame))))

(defun drgnx-grid--dock-target (dock frame)
  "Where DOCK's tile is split from on FRAME, as (WINDOW . SIDE): the left and right docks run the grid's full height
beside everything but the other side dock (the editor groups all give their share, as they would to a side window);
the bottom dock sits under the part between them (`drgnx-grid--center')."
  (pcase dock
    ('left (cons (drgnx-grid--beside 'left frame) 'left))
    ('right (cons (drgnx-grid--beside 'right frame) 'right))
    ('bottom (let ((left (drgnx-grid-dock 'left frame)) (right (drgnx-grid-dock 'right frame)))
               ;; under the part between the side docks, or under the whole grid when no side dock shows
               (cons (or (and (or left right) (drgnx-grid--center frame)) (drgnx-grid-root frame)) 'below)))))

(defun drgnx-grid--remembered-target (memory frame)
  "Where a hidden tile goes back to on FRAME, from its MEMORY: (WINDOW . SIDE), WINDOW the smallest window holding
the tiles it last gave its space to that still live; nil when none does."
  (let ((live (delq nil (mapcar (lambda (id) (drgnx-grid--tile-by-id id frame)) (plist-get memory :neighbour)))))
    (and live (plist-get memory :side) (cons (drgnx-grid--lca live) (plist-get memory :side)))))

(defun drgnx-grid--memory (key &optional frame)
  (alist-get key (frame-parameter frame 'drgnx-grid-memory) nil nil #'equal))

(defun drgnx-grid--set-memory (key value &optional frame)
  (let ((all (copy-alist (frame-parameter frame 'drgnx-grid-memory))))
    (setf (alist-get key all nil nil #'equal) value)
    (set-frame-parameter frame 'drgnx-grid-memory all)))

(defun drgnx-grid-split-dock (dock &optional px frame kinds)
  "A new window for DOCK's tile on FRAME (R2): split from the tiles it last gave its space to, else from its dock's
neighbour (`drgnx-grid--dock-target').  PX is its size in pixels along the split (left and right a width, bottom a
height); nil: DOCK's `:sizes' intent, else KINDS' `:size', else `drgnx-grid--default-size'.  It is clamped so the
new window and the one it comes from keep `drgnx-grid-min-size' (at most half the room each).  The window gets
`drgnx-tile-dock' DOCK, an id and `no-delete-other-windows'; the caller gives it its role, buffer and the rest.
A tile shown full size comes back first, with every other tile (`drgnx-grid-leave-full-size')."
  (if (window-live-p drgnx-grid--into)
      (let ((w drgnx-grid--into))
        (setq drgnx-grid--into nil)                     ; one window, for the first split only
        (set-window-parameter w 'drgnx-tile-dock dock)
        (set-window-parameter w 'no-delete-other-windows t)
        (drgnx-grid-tile-id w)
        w)
    (drgnx-grid-leave-full-size frame)
    (drgnx-grid--split-dock dock px frame kinds)))

(defun drgnx-grid--split-dock (dock px frame kinds)
  (drgnx-grid--adopt-editors frame)
  (let* ((frame (or frame (selected-frame)))
         (memory (drgnx-grid--memory dock frame))
         (target (or (drgnx-grid--remembered-target memory frame) (drgnx-grid--dock-target dock frame)))
         (window (car target)) (side (cdr target))
         (horizontal (and (memq side '(left right)) t))
         (room (window-size window horizontal t))
         (least (min (drgnx-grid-min-size frame horizontal) (/ room 2)))
         (px (max least (min (or px (drgnx-grid--dock-default-px dock kinds frame)) (- room least))))
         ;; the grid's root split gets a parent of its own: the status bar's row stays the frame root's other child
         (w (let ((drgnx-rules--placing t) (window-combination-limit (eq window (drgnx-grid-root frame)))
                  (window-combination-resize nil)
                  (ignore-window-parameters t) (window-resize-pixelwise t))
              (split-window window (- px) side t))))
    (set-window-parameter w 'drgnx-tile-dock dock)
    (set-window-parameter w 'no-delete-other-windows t)
    (drgnx-grid-tile-id w)
    w))

(defun drgnx-grid--tile-root (window)
  "The window that holds tile WINDOW whole: its atom's root (`window-atom-root'), else WINDOW."
  (let ((root (window-atom-root window))) (if (and root (not (window-live-p root))) root window)))

(defun drgnx-grid-remove-dock (window)
  "Delete the docked tile whose main window is WINDOW, with its parts (the whole atom), giving its space back as R3
says, and remember where it was for its next show (`drgnx-grid-memory', keyed by its dock).  Its size is the
caller's to note (`:sizes' intent)."
  (let* ((frame (window-frame window)) (dock (window-parameter window 'drgnx-tile-dock))
         (memory (drgnx-grid--delete-tile (drgnx-grid--tile-root window))))
    (when dock (drgnx-grid--set-memory dock memory frame))
    (drgnx-grid--note-good frame)
    t))

(defun drgnx-grid-add-part (window side &optional px)
  "Split a part off tile WINDOW on SIDE (`above', `below'), PX pixels tall (nil: half), and make the tile's windows
one atom: a split from any of them goes beside the whole tile, and `delete-window' on one deletes the tile.  The part
carries `drgnx-tile-part' t and the tile's dock; the caller gives it its role, buffer and the rest."
  (let* ((root (let ((r (window-atom-root window))) (and r (not (window-live-p r)) r)))
         (part (let ((drgnx-rules--placing t) (window-combination-limit (not root)) (window-combination-resize nil)
                     (ignore-window-parameters t) (window-resize-pixelwise t))
                 (split-window window (and px (- px)) side t))))
    (window-make-atom (or root (window-parent part)))
    (set-window-parameter part 'drgnx-tile-part t)
    (set-window-parameter part 'drgnx-tile-dock (window-parameter window 'drgnx-tile-dock))
    (set-window-parameter part 'no-delete-other-windows t)
    part))

(defun drgnx-grid-delete-part (part)
  "Delete PART of a tile alone, not the whole atom: its space goes to the tile's other windows.  A tile left with one
window is no atom any more."
  (when (window-live-p part)
    (let ((sibling (or (window-left part) (window-right part))))
      (let ((ignore-window-parameters t) (window-combination-resize nil)) (delete-window part))
      (when (and (window-valid-p sibling) (not (window-parameter (window-parent sibling) 'window-atom)))
        (walk-window-subtree (lambda (w) (set-window-parameter w 'window-atom nil)) sibling t)))))

(defun drgnx-grid--tool-tile (w kinds frame horizontal)
  "Make window W a tool tile holding KINDS on FRAME, its stack's front shown; its size along HORIZONTAL kept."
  (set-window-parameter w 'drgnx-role 'tile)
  (set-window-parameter w 'drgnx-pane-stack (copy-sequence kinds))
  (dolist (p '((no-other-window . t) (mode-line-format . none) (delete-window . drgnx-grid--delete-window)
               (quit-restore . nil)))
    (set-window-parameter w (car p) (cdr p)))
  (set-window-scroll-bars w nil nil nil nil t)
  (drgnx-grid--put-buffer w (car kinds) frame)
  ;; after the scroll bars: Emacs keeps the size only while it equals the body size it recorded
  (window-preserve-size w (and horizontal t) t)
  w)

(defun drgnx-grid--make-tool-tile (dock kinds frame)
  "Split a new tool tile for DOCK holding KINDS on FRAME (`drgnx-grid-split-dock'), its stack's front shown."
  (drgnx-grid--tool-tile (drgnx-grid-split-dock dock nil frame kinds) kinds frame (drgnx-grid--horizontal-dock-p dock)))

(defun drgnx-grid--dock-of (kind)
  "The dock KIND lives at: its home (`left', `bottom', `right'), nil for an editor kind."
  (car (memq (drgnx-grid--home kind) drgnx-grid-docks)))

;;;; Show, hide, focus

(defun drgnx-grid--tile-of (kind frame)
  "The tool tile on FRAME whose stack holds KIND (a stack entry: a kind, or an instance of one), or nil."
  (seq-find (lambda (w) (and (drgnx-grid-tool-tile-p w) (member kind (window-parameter w 'drgnx-pane-stack))))
            (window-list frame 'nomini)))

(defun drgnx-grid-window (kind &optional frame)
  "The window showing KIND on FRAME: the tool tile whose stack shows it in front, or, for an editor kind, the window
showing the last buffer it put there; nil when it does not show."
  (let ((frame (or frame (selected-frame))))
    (if (eq (drgnx-grid--home (drgnx-grid--entry-kind kind)) 'editor)
        (drgnx-pane--areas-window kind frame)
      (let ((w (drgnx-grid--tile-of kind frame)))
        (and w (equal (car (window-parameter w 'drgnx-pane-stack)) kind) w)))))

(defun drgnx-grid--bring-to-front (window kind frame &optional buffer)
  "Show KIND in WINDOW, whose stack holds it: the window and every edge stay (R1)."
  (let ((stack (window-parameter window 'drgnx-pane-stack)))
    (unless (equal (car stack) kind)
      (drgnx-grid--remember window)
      (set-window-parameter window 'drgnx-pane-stack (cons kind (remove kind stack))))
    (drgnx-grid--put-buffer window kind frame buffer)
    (drgnx-grid--put-row window)
    window))

(cl-defun drgnx-grid-show (kind &key buffer select dock)
  "Show pane KIND on the selected frame and return its window.
R1: a kind in a stack comes to the front, the window and its edges unchanged.  R2: a hidden kind joins its dock's
tile (DOCK, else its home) when that shows, else a new tile splits its remembered neighbour, else its dock's, taking
space from that window only.  R5: the selected window stays unless SELECT.  BUFFER: what KIND shows.  KIND may be
a stack entry (KIND . KEY), an instance of a kind (`drgnx-grid--entry-kind')."
  (let* ((frame (selected-frame)) (selected (selected-window)) (spec (drgnx-pane--spec (drgnx-grid--entry-kind kind))))
    (prog1
        (if (eq (plist-get spec :home) 'editor)
            (drgnx-pane--areas-show kind buffer select)
          (drgnx-grid--adopt-editors frame)
          (let* ((dock (or dock (drgnx-grid--dock-of (drgnx-grid--entry-kind kind))))
                 (w (or (drgnx-grid--tile-of kind frame)
                        (when-let* ((tile (drgnx-grid-dock dock frame)))
                          (set-window-parameter tile 'drgnx-pane-stack
                                                (append (window-parameter tile 'drgnx-pane-stack) (list kind)))
                          tile))))
            (if w (drgnx-grid--bring-to-front w kind frame buffer)
              (when (setq w (drgnx-grid--make-tool-tile dock (list kind) frame))
                (when buffer (drgnx-grid--put-buffer w kind frame buffer))
                (drgnx-grid--put-row w)))
            (when w
              (when-let* ((fn (plist-get spec :on-show))) (funcall fn w))
              (when select (select-window w)))
            w))
      (unless (or select (eq (selected-window) selected) (not (window-live-p selected)))
        (select-window selected 'norecord)))))

(defun drgnx-grid--touches-p (window edge-px horizontal before)
  "Non-nil when WINDOW's edge along HORIZONTAL meets EDGE-PX: its right (or bottom) edge when BEFORE (it lies before
the deleted window), else its left (or top) edge."
  (let ((e (window-pixel-edges window)))
    (if horizontal (= (if before (nth 2 e) (nth 0 e)) edge-px)
      (= (if before (nth 3 e) (nth 1 e)) edge-px))))

(defun drgnx-grid--delete-tile (window)
  "Delete tile WINDOW, its space going to its sibling only and, inside the sibling, to the tiles along its edge (R3).
Returns the memory to come back with: (:side SIDE :neighbour IDS), SIDE where WINDOW was beside the sibling."
  (let* ((horizontal (window-combined-p window t))
         (sibling (or (window-left window) (window-right window)))
         (before (and sibling (eq sibling (window-left window))))
         (e (window-pixel-edges window))
         (edge (if horizontal (if before (nth 0 e) (nth 2 e)) (if before (nth 1 e) (nth 3 e))))
         (leaves (and sibling (drgnx-grid--leaves sibling)))
         (along (seq-filter (lambda (w) (drgnx-grid--touches-p w edge horizontal before)) leaves))
         (others (seq-difference leaves along))
         (kept (mapcar (lambda (w) (cons w (window-parameter w 'window-preserved-size))) others))
         (memory (and sibling
                      (list :side (if horizontal (if before 'right 'left) (if before 'below 'above))
                            :neighbour (delq nil (mapcar (lambda (w) (window-parameter w 'drgnx-tile-id)) leaves))))))
    (unwind-protect
        (progn
          (dolist (w others) (window-preserve-size w horizontal t))
          (set-window-parameter window 'delete-window nil)
          (let ((ignore-window-parameters t) (window-combination-resize nil)) (delete-window window)))
      (pcase-dolist (`(,w . ,size) kept)
        (when (window-live-p w) (set-window-parameter w 'window-preserved-size size))))
    memory))

(defun drgnx-grid-hide (kind)
  "Hide the tool tile showing KIND in front (R3): its space goes back to the neighbour it took it from, and where it
was, its size and its stack are remembered for the next show (R4).  A kind not in front is left alone."
  (let* ((frame (selected-frame)) (w (drgnx-grid-window kind frame)))
    (when (drgnx-grid-tool-tile-p w)
      (drgnx-grid--remember w)
      (let* ((dock (window-parameter w 'drgnx-tile-dock))
             (horizontal (if dock (drgnx-grid--horizontal-dock-p dock) (window-combined-p w t)))
             (px (if horizontal (window-pixel-width w) (window-pixel-height w))))
        (when dock (drgnx-state-note-intent frame :sizes dock px :by 'auto))
        (when (eq (selected-window) w)
          (select-window (or (drgnx-state-editor-window frame) (car (drgnx-grid-tiles frame 'editor)))))
        (let ((memory (drgnx-grid--delete-tile w))
              (logical (drgnx-grid-tree-to-logical px (drgnx-pixels-scale frame))))
          (drgnx-grid--set-memory (or dock kind) (append memory (list :px logical :dock dock)) frame))
        (drgnx-grid--note-good frame)
        t))))

(defun drgnx-grid--delete-window (window)
  "`delete-window' on a tool tile (C-x 0, a package deleting a window it once had): hide it (R7)."
  (with-selected-frame (window-frame window)
    (drgnx-grid-hide (car (window-parameter window 'drgnx-pane-stack)))))

(defun drgnx-grid--delete-editor (window)
  "`delete-window' on an editor tile: deleted, unless it is its frame's last editor tile (R8)."
  (if (<= (length (drgnx-grid-tiles (window-frame window) 'editor)) 1)
      (user-error "The last editor tile stays")
    (set-window-parameter window 'delete-window nil)
    (let ((ignore-window-parameters nil)) (delete-window window))))

(defun drgnx-grid-focus (kind)
  "Show KIND and select its window; its :on-focus runs with the window."
  (let ((w (drgnx-grid-show kind :select t)))
    (when-let* ((fn (plist-get (drgnx-pane-kind kind) :on-focus)) ((window-live-p w))) (funcall fn w))
    w))

(defun drgnx-grid-resize (kind px horizontal)
  "Give KIND's tile PX pixels: its dock's dimension (left and right a width, bottom a height), else HORIZONTAL's.
A docked tile's size is noted as its dock's `:sizes' intent.  The window, or nil when KIND does not show."
  (let* ((frame (selected-frame)) (dock (drgnx-grid--dock-of kind)) (w (drgnx-grid-window kind frame))
         (dock (or (and w (window-parameter w 'drgnx-tile-dock)) (and (not w) dock))))
    (when dock (drgnx-state-note-intent frame :sizes dock px))
    (when (window-live-p w)
      (let ((horizontal (if dock (drgnx-grid--horizontal-dock-p dock) horizontal)) (window-resize-pixelwise t))
        (ignore-errors (window-resize w (- px (window-size w horizontal t)) horizontal 'preserved t))
        (window-preserve-size w horizontal t)
        w))))

(defun drgnx-grid-toggle-dock (dock)
  "Hide DOCK's tile when it shows, else show it with the kind it showed last (its first kind the first time)."
  (drgnx-grid-leave-full-size)
  (let ((w (drgnx-grid-dock dock)))
    (if w (drgnx-grid-hide (car (window-parameter w 'drgnx-pane-stack)))
      (let* ((memory (drgnx-grid--memory dock))
             (kind (or (car (plist-get memory :kinds)) (car (drgnx-pane-kinds dock)))))
        (when kind (drgnx-grid-show kind))))))

;;;; Splitting tiles, the tile picker, Close Tile

(defun drgnx-grid-tile-window-p (window)
  "Non-nil when WINDOW belongs to a tool tile: the tile's window, or a part of its atom (a section, a companion)."
  (and (window-live-p window) (or (drgnx-grid-tool-tile-p window) (window-parameter window 'drgnx-tile-part)) t))

(defun drgnx-grid-room-p (window side)
  "Non-nil when WINDOW's whole tile can split in two along SIDE, each half at least the least tile size
\(`drgnx-grid-min-size')."
  (let ((horizontal (and (memq side '(left right)) t)))
    (>= (window-size (drgnx-grid--tile-root window) horizontal t)
        (* 2 (drgnx-grid-min-size (window-frame window) horizontal)))))

(defun drgnx-grid-split-tile (window side)
  "A new window beside WINDOW's whole tile (its atom, `drgnx-grid--tile-root') on SIDE (`right', `below'), taking half
of the tile, pixelwise; an id and `no-delete-other-windows'.  The caller gives it what it shows.  A tile shown full
size comes back first, with every other tile.  No room for two tiles (`drgnx-grid-room-p'): nothing changes, a
`user-error' \"No room there\"."
  (drgnx-grid-leave-full-size (window-frame window))
  (unless (drgnx-grid-room-p window side) (user-error "No room there"))
  (let ((new (let ((drgnx-rules--placing t) (window-combination-limit nil) (window-combination-resize nil)
                   (ignore-window-parameters t) (window-resize-pixelwise t))
               (split-window (drgnx-grid--tile-root window) nil side t))))
    (set-window-parameter new 'window-atom nil)
    (set-window-parameter new 'no-delete-other-windows t)
    (drgnx-grid-tile-id new)
    new))

(defun drgnx-grid--title (kind)
  "KIND's title as its tab shows it; an instance (KIND . KEY) its buffer's name."
  (if (consp kind)
      (string-trim (buffer-name (car (drgnx-grid--buffer-for kind (selected-frame)))) "[ *]+" "[ *]+")
    (let ((title (or (plist-get (drgnx-pane-kind kind) :title) (capitalize (symbol-name kind)))))
      (if (functionp title) (funcall title) title))))

(defun drgnx-grid--make-editor (window)
  "Make WINDOW an editor tile showing the most recent editor's buffer, and select it."
  (set-window-buffer window (window-buffer (or (drgnx-state-editor-window (window-frame window))
                                               (car (drgnx-grid-tiles (window-frame window) 'editor)))))
  (set-window-parameter window 'drgnx-tabs nil)
  (drgnx-grid--adopt window)
  (select-window window)
  window)

(defun drgnx-grid-pick-kind (window)
  "Ask what the new tile WINDOW shows, \"Editor\" or a pane kind by its title, and show it there: an editor tile, or a
tool tile holding the kind (moved off its dock or tile when it shows elsewhere).  Quitting the question deletes WINDOW.
For invoked commands only (`split-editor-right' and `split-editor-down' on a tool tile).  Returns `editor' or the kind."
  (let* ((frame (window-frame window))
         (choices (cons (cons "Editor" 'editor)
                        (mapcar (lambda (k) (cons (drgnx-grid--title k) k))
                                (seq-remove (lambda (k) (plist-get (drgnx-pane-kind k) :sidebar)) (drgnx-pane-kinds)))))
         (picked nil))
    (unwind-protect
        (setq picked (cdr (assoc (completing-read "Show in this tile: " choices nil t) choices)))
      (unless picked
        (when (window-live-p window) (let ((ignore-window-parameters t)) (delete-window window)))))
    (if (eq picked 'editor) (drgnx-grid--make-editor window)
      (when (drgnx-pane-window picked frame) (drgnx-pane-hide picked))
      (drgnx-grid--tool-tile window (list picked) frame (window-combined-p window t))
      (drgnx-grid--put-row window))
    picked))

;;;; The tab row (today's drawing; the kit's tab later)

(defun drgnx-grid--tab-click (event)
  "A click on a tool tile's tab: show that kind."
  (interactive "e")
  (when-let* ((s (posn-string (event-start event))) (kind (get-text-property (cdr s) 'drgnx-grid-kind (car s))))
    (with-selected-window (posn-window (event-start event)) (drgnx-grid-show kind))))

(defvar drgnx-grid--tab-map
  (let ((m (make-sparse-keymap)))
    (define-key m [tab-line down-mouse-1] #'drgnx-grid--tab-press)
    (define-key m [tab-line mouse-1] #'drgnx-grid--tab-click)
    (define-key m [tab-line mouse-3] #'drgnx-grid-tab-menu-click) ; its menu: Move to New Window
    m)
  "A tool tile's tab: a click shows it, a drag off the row moves it (`drgnx-grid--tab-press').")

(defcustom drgnx-grid-drag t
  "Non-nil: a tile moves by dragging its grip (the ⠿ at its tab line's start) or one of its tabs off the row onto
another tile's edge (a split there) or middle (a stack).  Nil: no grip is drawn and drags do nothing."
  :type 'boolean :group 'drgnx-grid)

(defvar drgnx-grid-grip-map
  (let ((m (make-sparse-keymap)))
    (define-key m [tab-line down-mouse-1] #'drgnx-grid-grip-press)
    (define-key m [header-line down-mouse-1] #'drgnx-grid-grip-press) ; a docked area's row is its header line
    (define-key m [tab-line mouse-3] #'drgnx-grid-tab-menu-click)
    (define-key m [header-line mouse-3] #'drgnx-grid-tab-menu-click)
    m)
  "The grip's mouse map: a press drags the tile (`drgnx-grid-grip-press').")

(defun drgnx-grid--grip (&optional frame)
  "The grip string for a tab row on FRAME (default the selected one): the kit's `grip-vertical' glyph, its ASCII
form on a terminal that is not UTF-8 (`drgnx-face-glyph'); \"\" when `drgnx-grid-drag' is off."
  (if drgnx-grid-drag
      (propertize (concat " " (drgnx-face-glyph 'grip-vertical frame)) 'local-map drgnx-grid-grip-map 'mouse-face 'highlight
                  'pointer 'hand 'help-echo "Drag to move this tile")
    ""))

(defun drgnx-grid--close-click (event)
  "A click on a tool tile's ✕: hide the tile."
  (interactive "e")
  (let ((w (posn-window (event-start event))))
    (when (drgnx-grid-tool-tile-p w)
      (with-selected-frame (window-frame w) (drgnx-grid-hide (car (window-parameter w 'drgnx-pane-stack)))))))

(defun drgnx-grid--tab-row (window)
  "Tool tile WINDOW's tab row: its kinds in their definition order as the kit's panel tabs (`drgnx-ui-kit-tab'), the
shown one selected, then the ✕."
  (let* ((stack (window-parameter window 'drgnx-pane-stack)) (shown (car stack))
         (kinds (seq-filter (lambda (k) (member k stack)) (append (drgnx-pane-kinds) stack))))
    (concat
     (drgnx-grid--grip (window-frame window))
     (mapconcat (lambda (k)
                  (let ((s (drgnx-ui-kit-tab (drgnx-grid--title k) 'panel (if (equal k shown) 'selected 'rest)
                                             nil nil 'tab-line nil (window-frame window))))
                    (add-text-properties 0 (length s) (list 'drgnx-grid-kind k 'mouse-face 'drgnx-hover
                                                            'local-map drgnx-grid--tab-map 'help-echo "Show this tab")
                                         s)                    s))
                (delete-dups kinds) " ")
     (propertize " " 'display '(space :align-to (- right 3)))
     (if (fboundp 'drgnx-wb-close-button)
         (drgnx-wb-close-button #'drgnx-grid--close-click "Close (Esc, q)")
       "x"))))

(defun drgnx-grid--put-row (window)
  "Set tool tile WINDOW's tab row as its `tab-line-format' (the chrome reads `drgnx-grid-tab-row')."
  (when (drgnx-grid-tool-tile-p window)
    (let ((row (drgnx-grid--tab-row window)))
      (set-window-parameter window 'drgnx-grid-tab-row row)
      (set-window-parameter window 'tab-line-format row))))

;;;; The backend

(defun drgnx-grid--define (kind spec old)
  "The `grid' backend's :define: as the docks' (the sections, tabs and editor place rules stay the shared data)."
  (drgnx-pane--areas-define kind spec old))

;; A docked kind (home `left', `bottom', `right') lives in its dock's tile, whose contents the side bar's sections and
;; the areas' tabs keep (their buffers, starts, points, placeholders, companions): with the grid on, those make and
;; delete their windows as tiles (`drgnx-grid-split-dock', `drgnx-grid-remove-dock', `drgnx-grid-add-part').  The
;; grid's own stack (`drgnx-grid-show') holds a kind moved off its dock.
(defun drgnx-grid--docked-p (kind)
  "Non-nil when KIND lives in its dock (a home `left', `bottom' or `right'), not in a tile it was moved to."
  (and (drgnx-grid--dock-of kind) (not (drgnx-grid--tile-of kind (selected-frame)))))
(defun drgnx-grid--map-window (&optional frame)
  "FRAME's editor tile showing the Work map (a mode of `drgnx-rules-never-cover-modes'), or nil."
  (let ((modes (bound-and-true-p drgnx-rules-never-cover-modes)))
    (and modes
         (seq-find (lambda (w) (apply #'provided-mode-derived-p (buffer-local-value 'major-mode (window-buffer w)) modes))
                   (drgnx-grid-tiles frame 'editor)))))

(defun drgnx-grid--new-tile (window side entries)
  "A new tool tile holding ENTRIES split off WINDOW's whole tile on SIDE, its front shown; its tab row set."
  (let ((w (drgnx-grid--tool-tile (drgnx-grid-split-tile window side) entries (selected-frame)
                                  (and (memq side '(left right)) t))))
    (drgnx-grid--put-row w)
    w))

(defun drgnx-grid--place (kind)
  "KIND's first window by `drgnx-grid-placements' while the Work map shows, or nil when no placement applies."
  (when-let* ((place (alist-get kind drgnx-grid-placements))
              ((not (drgnx-grid--backend-window kind (selected-frame))))
              (map (drgnx-grid--map-window)))
    (let* ((frame (selected-frame))
           (narrow (< (drgnx-grid-tree-to-logical (frame-pixel-width frame) (drgnx-pixels-scale frame))
                      drgnx-grid-narrow-px))
           (other (and narrow (plist-get place :narrow)))
           (beside (and other (drgnx-grid--backend-window other frame))))
      (cond ((and beside (eq (window-parameter beside 'drgnx-role) 'tile))
             (set-window-parameter beside 'drgnx-pane-stack (cons kind (window-parameter beside 'drgnx-pane-stack)))
             (drgnx-grid--bring-to-front beside kind frame))
            ((and beside (drgnx-grid-room-p beside 'below)) (drgnx-grid--new-tile beside 'below (list kind)))
            ((and (plist-get place :below-map) (drgnx-grid-room-p map 'below))
             (drgnx-grid--new-tile map 'below (list kind)))))))

(defun drgnx-grid--instance-windows (kind frame)
  "The windows on FRAME showing an instance of KIND: its docked window, then the tiles holding its instances."
  (let ((docked (and (drgnx-grid--docked-p kind) (drgnx-pane--areas-window kind frame))))
    (append (and docked (list docked))
            (seq-filter (lambda (w) (and (drgnx-grid-tool-tile-p w)
                                         (seq-some (lambda (e) (and (consp e) (eq (car e) kind)))
                                                   (window-parameter w 'drgnx-pane-stack))))
                        (drgnx-grid-tiles frame 'tool)))))

(defun drgnx-grid--show-instance (kind buffer select)
  "Show BUFFER, an instance of KIND (`:instance-key' gives its key), and return its window; nil when KIND has no
instances, BUFFER is none of them, or it shows as KIND always did: the first instance (its dock).  Another gets a tile
of its own, left of the first; from the third on they stack onto the last instance tile."
  (when-let* ((spec (drgnx-pane-kind kind)) (key-fn (plist-get spec :instance-key)) ((buffer-live-p buffer))
              (key (funcall key-fn buffer)))
    (let* ((frame (selected-frame)) (entry (cons kind key))
           (docked (and (drgnx-grid--docked-p kind) (drgnx-pane--areas-window kind frame)))
           (windows (drgnx-grid--instance-windows kind frame)))
      (cond ((drgnx-grid--tile-of entry frame) (drgnx-grid-show entry :buffer buffer :select select))
            ;; none shows, or the dock shows this one or none: the kind's own way (one agent: the right dock)
            ((or (null windows) (and docked (member (funcall key-fn (window-buffer docked)) (list nil key)))) nil)
            ;; one shows and there is no room beside it: the kind's own way (the dock shows this one)
            ((and (null (cdr windows)) (not (drgnx-grid-room-p (car windows) 'left))) nil)
            (t (let ((w (if (cdr windows)
                            (let ((last (car (last windows))))
                              (set-window-parameter last 'drgnx-pane-stack
                                                    (append (window-parameter last 'drgnx-pane-stack) (list entry)))
                              (drgnx-grid--bring-to-front last entry frame buffer))
                          (let ((new (drgnx-grid--new-tile (car windows) 'left (list entry))))
                            (drgnx-grid--put-buffer new entry frame buffer)
                            (drgnx-grid--put-row new)
                            new))))
                 (when select (select-window w))
                 w))))))

(defun drgnx-grid--leave-unless-shown (kind)
  "A grid command on KIND while a tile shows full size: every tile comes back first, unless KIND is what shows."
  (unless (window-live-p (drgnx-grid--backend-window kind (selected-frame))) (drgnx-grid-leave-full-size)))
(defun drgnx-grid--backend-show (kind buffer select)
  (drgnx-grid--leave-unless-shown kind)
  (or (drgnx-grid--show-instance kind buffer select)
      (let ((w (drgnx-grid--place kind)))
        (when (and w select) (select-window w))
        w)
      (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-show kind buffer select)
        (drgnx-grid-show kind :buffer buffer :select select))))
(defun drgnx-grid--backend-hide (kind)
  (drgnx-grid-leave-full-size)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-hide kind) (drgnx-grid-hide kind)))
(defun drgnx-grid--backend-window (kind frame)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-window kind frame) (drgnx-grid-window kind frame)))
(defun drgnx-grid--backend-focus (kind)
  (drgnx-grid--leave-unless-shown kind)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-focus kind) (drgnx-grid-focus kind)))
(defun drgnx-grid--backend-resize (kind px horizontal)
  (drgnx-grid-leave-full-size)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-resize kind px horizontal) (drgnx-grid-resize kind px horizontal)))

(setf (alist-get 'grid drgnx-pane--backends)
      (list :define #'drgnx-grid--define :show #'drgnx-grid--backend-show :hide #'drgnx-grid--backend-hide
            :window #'drgnx-grid--backend-window :focus #'drgnx-grid--backend-focus
            :resize #'drgnx-grid--backend-resize :move #'drgnx-grid--backend-move :stack #'drgnx-grid--backend-stack
            :defined #'drgnx-grid--kind-defined :undefined #'drgnx-grid--kind-undefined
            :keeps #'drgnx-grid--tile-of))

;;;; Packages' window calls

(defun drgnx-grid--balance-editors-only (balance &rest args)
  "Around `balance-windows': the tool tiles keep their sizes (R7), so only editor tiles are balanced.
Their buffers' `window-size-fixed' is t for the call (Emacs balances around a fixed window, never a preserved one)."
  (let ((kept nil))
    (unwind-protect
        (progn
          (dolist (w (window-list nil 'nomini))
            (when-let* (((or (window-parameter w 'drgnx-tile-dock) (eq (window-parameter w 'drgnx-role) 'tile)))
                        (b (window-buffer w)))
              (unless (assq b kept)
                (with-current-buffer b
                  (push (list b (local-variable-p 'window-size-fixed) window-size-fixed) kept)
                  (setq-local window-size-fixed t)))))
          (apply balance args))
      (pcase-dolist (`(,b ,local ,value) kept)
        (when (buffer-live-p b)
          (with-current-buffer b
            (if local (setq-local window-size-fixed value) (kill-local-variable 'window-size-fixed))))))))

(defvar ediff-window-setup-function)
(defvar ediff-after-quit-hook-internal)
(declare-function ediff-setup-windows-plain "ediff-wind" (buffer-A buffer-B buffer-C control-buffer))

(defvar drgnx-grid--ediff-previous nil
  "`ediff-window-setup-function' before `drgnx-grid-mode' set it, as (VALUE), or nil when it was unbound.")

(defun drgnx-grid--ediff-restore (tile before)
  "ediff quit: TILE's frame is back to its windows BEFORE (those ediff added inside the tile go)."
  (when (window-live-p tile)
    (dolist (w (window-list (window-frame tile) 'nomini))
      (unless (memq w before)
        (let ((ignore-window-parameters t)) (ignore-errors (delete-window w)))))))

(defun drgnx-grid-ediff-setup (buffer-A buffer-B buffer-C control-buffer)
  "`ediff-window-setup-function' while the grid is on: ediff's windows (A, B, C and its control window) lay out inside
the current editor tile, nested in it (`window-combination-limit'), and leave on quit; no other tile moves and no
frame is made (the plain setup, never ediff's frames)."
  (let* ((tile (if (drgnx-grid-editor-tile-p (selected-window)) (selected-window)
                 (or (drgnx-state-editor-window) (car (drgnx-grid-tiles nil 'editor)))))
         (before (window-list (window-frame tile) 'nomini)))
    (select-window tile)
    (let ((window-combination-limit t)
          ;; the control window under the tile's own windows, not at the frame's bottom ("direction bottom")
          (display-buffer-overriding-action
           (list (lambda (buffer alist)
                   (when (eq buffer control-buffer)
                     (display-buffer-in-direction
                      buffer `((direction . below) (window . ,(or (window-parent tile) tile)) ,@alist)))))))
      (ediff-setup-windows-plain buffer-A buffer-B buffer-C control-buffer))
    (with-current-buffer control-buffer
      (add-hook 'ediff-after-quit-hook-internal (lambda () (drgnx-grid--ediff-restore tile before)) nil t))))

;;;; One frame's tree, its apply, full size

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(declare-function drgnx-wb-area-tab "drgnx-area" (area))
(declare-function drgnx-wb-show-sidebar "drgnx-wb" ())
(declare-function drgnx-wb-sidebar-view "drgnx-wb" (&optional frame))
(declare-function drgnx-chrome-tabs "drgnx-chrome" (w))
(declare-function drgnx-chrome-apply "drgnx-chrome" (&optional frame note))
(defvar drgnx-wb--areas)

(defun drgnx-grid--atom-root-p (window)
  "Non-nil when WINDOW is an internal window holding one tile's atom."
  (and (not (window-live-p window)) (window-parameter window 'window-atom)
       (eq (window-atom-root window) window)))

(defun drgnx-grid--main-of (window)
  "The tile's main window under WINDOW (a live window, or an atom's root): the first that is not a part."
  (if (window-live-p window) window
    (or (seq-find (lambda (w) (not (window-parameter w 'drgnx-tile-part))) (drgnx-grid--leaves window))
        (car (drgnx-grid--leaves window)))))

(defun drgnx-grid--buffer-name (b)
  "How a tree names buffer B: its file, else its name."
  (or (buffer-file-name b) (buffer-name b)))

(defun drgnx-grid--named-buffer (name)
  "The live buffer a tree's NAME stands for (a file's buffer, else one of that name), or nil.  Nothing is visited."
  (and (stringp name) (or (get-file-buffer name) (get-buffer name))))

(defun drgnx-grid--leaf (w)
  "The tree node of the tile whose main window is W (Task 2's format, without :px and :share)."
  (let ((role (window-parameter w 'drgnx-role)) (dock (window-parameter w 'drgnx-tile-dock))
        (id (drgnx-grid-tile-id w)))
    (cond ((eq role 'tile)
           (let ((stack (window-parameter w 'drgnx-pane-stack)))
             (list 'tile :id id :kinds stack :shown (car stack) :dock dock :state nil)))
          ((eq role 'dock)
           (list 'tile :id id :kinds '(side-bar) :shown 'side-bar :dock (or dock 'left)
                 :state (list :view (drgnx-wb-sidebar-view (window-frame w))
                              ;; its sections' heights, logical, top to bottom: the side bar made again has them
                              :parts (let ((scale (drgnx-pixels-scale (window-frame w))))
                                       (mapcar (lambda (p) (max 1 (drgnx-grid-tree-to-logical (window-pixel-height p) scale)))
                                               (drgnx-grid--leaves (drgnx-grid--tile-root w)))))))
          ((and role (assq role drgnx-wb--areas))
           (let ((tab (drgnx-wb-area-tab role)))
             (list 'tile :id id :kinds (and tab (list tab)) :shown tab :dock dock :state (list :area role))))
          (t (let ((b (window-buffer w)))
               (list 'editor :id id
                     :tabs (delete-dups (mapcar #'drgnx-grid--buffer-name
                                                (seq-filter #'buffer-live-p (window-parameter w 'drgnx-tabs))))
                     :shown (drgnx-grid--buffer-name b) :point (window-point w) :start (window-start w)))))))

(defun drgnx-grid--node (window scale parent horizontal)
  "WINDOW's tree node; PARENT the pixel size of its parent along HORIZONTAL (nil at the root)."
  (let* ((px (and parent (window-size window horizontal t)))
         (sizes (and parent (list :px (max 1 (drgnx-grid-tree-to-logical px scale))
                                  :share (min 1.0 (max 1e-4 (/ (float px) parent)))))))
    (if (or (window-live-p window) (drgnx-grid--atom-root-p window))
        (let ((leaf (drgnx-grid--leaf (drgnx-grid--main-of window))))
          (cons (car leaf) (append sizes (cdr leaf))))
      (let* ((row (and (window-left-child window) t))
             (size (window-size window row t)))
        (append (list (if row 'row 'col) :px (plist-get sizes :px) :share (plist-get sizes :share))
                (mapcar (lambda (c) (drgnx-grid--node c scale size row)) (drgnx-grid--children window)))))))

(defun drgnx-grid-tree (&optional frame)
  "FRAME's grid as a TREE (Task 2's format: `drgnx-grid-valid-tree-p'), its sizes logical pixels at FRAME's scale.
An editor tile names its buffers by file, else by name.  While a temporary window shows (a temporary tile, a popup
row: `drgnx-grid--temporary-p'), the tree is the one from before the first of them (`drgnx-grid--good'): those are
never saved."
  (let ((frame (or frame (selected-frame))))
    (or (and (drgnx-grid--temporary-windows frame) (frame-parameter frame 'drgnx-grid--good))
        (with-selected-frame frame
          (drgnx-grid--adopt-editors frame)
          (drgnx-grid--node (drgnx-grid-root frame) (drgnx-pixels-scale frame) nil nil)))))

;;; Apply

(defun drgnx-grid--tree-ids (node)
  (delq nil (mapcar (lambda (l) (plist-get (cdr l) :id)) (drgnx-grid-tree-leaves node))))

(defun drgnx-grid--live-shape (window keep)
  "WINDOW's tree restricted to the tile ids KEEP: an id, or (row|col SHAPE…) of two or more; nil when none is kept."
  (if (or (window-live-p window) (drgnx-grid--atom-root-p window))
      (let ((id (window-parameter (drgnx-grid--main-of window) 'drgnx-tile-id))) (and (memq id keep) id))
    (let ((kids (delq nil (mapcar (lambda (c) (drgnx-grid--live-shape c keep)) (drgnx-grid--children window)))))
      (if (cdr kids) (cons (if (window-left-child window) 'row 'col) kids) (car kids)))))

(defun drgnx-grid--tree-shape (node keep)
  "NODE restricted to the ids KEEP, as `drgnx-grid--live-shape' gives it."
  (if (memq (car node) '(tile editor))
      (let ((id (plist-get (cdr node) :id))) (and (memq id keep) id))
    (let ((kids (delq nil (mapcar (lambda (c) (drgnx-grid--tree-shape c keep)) (nthcdr 5 node)))))
      (if (cdr kids) (cons (car node) kids) (car kids)))))

(defun drgnx-grid--split-new (window side limit &optional size)
  "A new window split off WINDOW on SIDE, SIZE pixels of it (nil: half); LIMIT: a parent of their own
(`window-combination-limit')."
  (let ((drgnx-rules--placing t) (window-combination-limit limit) (window-combination-resize nil)
        (ignore-window-parameters t) (window-resize-pixelwise t) (window-min-width 1) (window-min-height 1))
    (split-window window (and size (- size)) side t)))

(defun drgnx-grid--grow (node w keep)
  "Make NODE's windows from W, the live or internal window holding the part of NODE that has kept tiles (all of it
when none has).  Only splits: W and the kept windows stay.  Returns ((NODE . WINDOW)…) for every node."
  (if (memq (car node) '(tile editor))
      (list (cons node w))
    (let* ((children (nthcdr 5 node)) (n (length children)) (row (eq (car node) 'row))
           (kept (mapcar (lambda (c) (and (drgnx-grid--tree-shape c keep) t)) children))
           (wins (make-vector n nil)) (out nil))
      (if (> (cl-count t kept) 1)
          ;; W is the matching row or col: its children are the kept children's windows, in order
          (let ((live (drgnx-grid--children w)))
            (dotimes (i n) (when (nth i kept) (aset wins i (pop live))))
            (push (cons node w) out))
        (aset wins (or (cl-position t kept) 0) w))
      ;; the others split off their neighbours: after a kept one to its right (below), before it to its left (above),
      ;; each new window taking its equal part of the room the windows still to come share with the one split (halving
      ;; each time would leave no room for the fifth)
      (let* ((first (cl-position-if #'identity wins)) (multi (> (cl-count t kept) 1)) (own (not multi))
             (run (lambda (i step) (let ((m 0)) (while (and (< -1 i n) (null (aref wins i))) (setq m (1+ m) i (+ i step))) m)))
             (split (lambda (from side m stays)
                      (drgnx-grid--split-new from side (prog1 own (setq own nil))
                                             (max 1 (/ (* (window-size from row t) m) (+ m stays)))))))
        (cl-loop for i from (1+ first) below n
                 unless (aref wins i)
                 ;; the first split off the one window that holds all of NODE leaves it room for those before it too
                 do (aset wins i (funcall split (aref wins (1- i)) (if row 'right 'below) (funcall run i 1)
                                          (if (and (not multi) (= i (1+ first))) (1+ first) 1))))
        (cl-loop for i downfrom (1- first) to 0
                 unless (aref wins i)
                 do (aset wins i (funcall split (aref wins (1+ i)) (if row 'left 'above) (funcall run i -1) 1)))
        (unless multi (push (cons node (window-parent (aref wins first))) out)))
      (dotimes (i n)
        (setq out (nconc out (drgnx-grid--grow (nth i children) (aref wins i) keep))))
      out)))

(defun drgnx-grid--size (node window scale)
  "Give WINDOW's children (NODE's) their sizes: NODE's logical :px at SCALE when they add up to WINDOW's size, else
their :share of it; pixelwise, each taking from the next."
  (let* ((children (nthcdr 5 node)) (row (eq (car node) 'row)) (kids (drgnx-grid--children window))
         (total (window-size window row t))
         (pxs (mapcar (lambda (c) (drgnx-grid-tree-from-logical (plist-get (cdr c) :px) scale)) children))
         (targets (if (= (apply #'+ pxs) total) pxs
                    (let ((left total))
                      (cl-loop for (c . more) on children
                               collect (if more (let ((p (round (* (or (plist-get (cdr c) :share) (/ 1.0 (length children)))
                                                                   total))))
                                                  (setq left (- left p)) p)
                                         left))))))
    (when (= (length kids) (length children))
      ;; each window's trailing edge moved to its target, so only the next window gives or takes the difference
      (cl-loop for k in kids for target in targets for more on kids
               when (cdr more)
               do (let ((window-resize-pixelwise t) (delta (- target (window-size k row t))))
                    (unless (zerop delta) (ignore-errors (adjust-window-trailing-edge k delta row t))))))))

(defun drgnx-grid--part-heights (window parts scale)
  "Give the parts of WINDOW's tile (its atom's windows, top to bottom) the heights PARTS, logical pixels at SCALE: in
proportion when they do not add up to the tile's height.  Nothing when the tile has another number of parts."
  (let* ((wins (drgnx-grid--leaves (drgnx-grid--tile-root window)))
         (total (apply #'+ (mapcar #'window-pixel-height wins)))
         (pxs (mapcar (lambda (l) (drgnx-grid-tree-from-logical l scale)) parts))
         (sum (apply #'+ pxs)))
    (when (and (cdr wins) (= (length wins) (length parts)) (> sum 0))
      (unless (= sum total) (setq pxs (mapcar (lambda (p) (round (* p (/ (float total) sum)))) pxs)))
      (cl-loop for w in wins for target in pxs for more on wins
               when (cdr more)
               do (let ((window-resize-pixelwise t) (delta (- target (window-pixel-height w))))
                    (unless (zerop delta) (ignore-errors (adjust-window-trailing-edge w delta nil t))))))))

(defun drgnx-grid--sized (frame fn)
  "Call FN with FRAME's preserved sizes (`window-preserve-size') lifted, so it may set any size; then every window that
had one keeps the size it has now."
  (let ((kept (delq nil (mapcar (lambda (w) (let ((p (window-parameter w 'window-preserved-size))) (and p (cons w p))))
                                (window-list frame 'nomini)))))
    (dolist (e kept) (set-window-parameter (car e) 'window-preserved-size nil))
    (unwind-protect (funcall fn)
      (pcase-dolist (`(,w _ ,width ,height) kept)
        (when (window-live-p w)
          (when width (window-preserve-size w t t))
          (when height (window-preserve-size w nil t)))))))

(defun drgnx-grid--fill-leaf (node w frame)
  "Give W, a window made for leaf NODE, what NODE shows: an editor's buffers, a docked area or the side bar, or a tool
tile's stack (an unknown kind shows its placeholder)."
  (let* ((p (cdr node)) (id (plist-get p :id)) (state (plist-get p :state)) (dock (plist-get p :dock)))
    (when id (set-window-parameter w 'drgnx-tile-id id))
    (set-window-parameter w 'no-delete-other-windows t)
    (pcase (car node)
      ('editor
       (let* ((tabs (delq nil (mapcar #'drgnx-grid--named-buffer (plist-get p :tabs))))
              (shown (or (drgnx-grid--named-buffer (plist-get p :shown)) (car tabs) (get-scratch-buffer-create))))
         (set-window-dedicated-p w nil)
         (set-window-buffer w shown)
         (set-window-parameter w 'drgnx-tabs tabs)
         (when (plist-get p :start) (set-window-start w (plist-get p :start) t))
         (when (plist-get p :point) (set-window-point w (plist-get p :point)))
         (drgnx-grid--adopt w)))
      (_
       (when dock (set-window-parameter w 'drgnx-tile-dock dock))
       ;; the area and the side bar make their window through `drgnx-grid-split-dock', which hands them W
       (cond ((plist-get state :area)
              (let ((drgnx-grid--into w)) (drgnx-wb-area-show (plist-get state :area) (plist-get p :shown))))
             ((memq 'side-bar (plist-get p :kinds))
              (when-let* ((view (plist-get state :view))) (set-frame-parameter frame 'drgnx-wb-view view))
              (let ((drgnx-grid--into w)) (drgnx-wb-show-sidebar)))
             (t (drgnx-grid--tool-tile w (or (plist-get p :kinds) (list (plist-get p :shown))) frame
                                       (and dock (drgnx-grid--horizontal-dock-p dock)))
                (drgnx-grid--put-row w)))))))

(defun drgnx-grid--delete-leaf (window)
  "Delete the tile held by WINDOW (live, or an atom's root) as it is, its space to its siblings.  A docked area's tile
first notes what its tab shows (`drgnx-area--remember'), so the tab comes back with that buffer."
  (let* ((main (drgnx-grid--main-of window)) (role (window-parameter main 'drgnx-role)))
    (when (and role (assq role (bound-and-true-p drgnx-wb--areas))) (drgnx-area--remember role main)))
  (let ((ignore-window-parameters t) (window-combination-resize nil))
    (ignore-errors (delete-window window))))

(defun drgnx-grid--leaf-windows (frame)
  "The windows holding one tile each under FRAME's grid root: live windows and atoms' roots."
  (let (out)
    (cl-labels ((walk (w) (if (or (window-live-p w) (drgnx-grid--atom-root-p w)) (push w out)
                            (mapc #'walk (drgnx-grid--children w)))))
      (walk (drgnx-grid-root frame)))
    (nreverse out)))

(defun drgnx-grid-apply-tree (tree &optional frame)
  "Arrange FRAME's grid as TREE (`drgnx-grid-tree').  An invalid TREE changes nothing and gives one warning.
The live tiles whose ids TREE holds stay (the same windows), the others are deleted and TREE's missing tiles split off
the kept ones; sizes are TREE's logical pixels at FRAME's scale (its shares when those do not add up).  An unknown kind
shows its placeholder.  No buffer is killed: an editor tile leaving the grid gives its tabs to the editor you used
last.  When the kept tiles are arranged otherwise than TREE has them, only the first stays.  Non-nil when applied."
  (let ((frame (or frame (selected-frame))))
    (if (not (drgnx-grid-valid-tree-p tree))
        (progn (drgnx-notify 'wb 'warn "A saved arrangement of the tiles was not valid; nothing changed") nil)
      (with-selected-frame frame
        (drgnx-grid--adopt-editors frame)
        (let* ((ids (drgnx-grid--tree-ids tree)) (orphans nil)
               (selected (selected-window)))
          ;; tiles made later get ids above TREE's
          (set-frame-parameter frame 'drgnx-grid-next-id (apply #'max (or (frame-parameter frame 'drgnx-grid-next-id) 0) ids))
          ;; the tiles TREE does not hold go (an editor's tabs stay with the editors)
          (dolist (w (drgnx-grid--leaf-windows frame))
            (let ((main (drgnx-grid--main-of w)))
              (unless (memq (window-parameter main 'drgnx-tile-id) ids)
                (when (and (drgnx-grid-editor-tile-p main) (cdr (drgnx-grid--leaf-windows frame)))
                  (setq orphans (append orphans (drgnx-chrome-tabs main) (list (window-buffer main)))))
                (when (cdr (drgnx-grid--leaf-windows frame)) (drgnx-grid--delete-leaf w)))))
          (let* ((leaves (drgnx-grid--leaf-windows frame))
                 (keep (delq nil (mapcar (lambda (w) (car (memq (window-parameter (drgnx-grid--main-of w) 'drgnx-tile-id) ids)))
                                         leaves))))
            ;; kept tiles arranged otherwise than TREE: keep the first only
            (unless (equal (drgnx-grid--live-shape (drgnx-grid-root frame) keep) (drgnx-grid--tree-shape tree keep))
              (let ((first (seq-find (lambda (id) (memq id keep)) ids)))
                (dolist (w leaves)
                  (unless (eql (window-parameter (drgnx-grid--main-of w) 'drgnx-tile-id) first)
                    (when (and (drgnx-grid-editor-tile-p (drgnx-grid--main-of w)) (cdr (drgnx-grid--leaf-windows frame)))
                      (setq orphans (append orphans (drgnx-chrome-tabs (drgnx-grid--main-of w)))))
                    (when (cdr (drgnx-grid--leaf-windows frame)) (drgnx-grid--delete-leaf w))))
                (setq keep (and first (list first)))))
            ;; nothing kept: TREE's first leaf gets a plain window in place of the one left
            (unless keep
              (let* ((last (car (drgnx-grid--leaf-windows frame))) (main (drgnx-grid--main-of last))
                     (fresh (drgnx-grid--split-new last 'right t)))
                (when (drgnx-grid-editor-tile-p main)
                  (setq orphans (append orphans (drgnx-chrome-tabs main) (list (window-buffer main)))))
                (drgnx-grid--delete-leaf last)
                (set-window-dedicated-p fresh nil)))
            (let* ((scale (drgnx-pixels-scale frame))
                   (made (drgnx-grid--grow tree (drgnx-grid-root frame) keep)))
              (pcase-dolist (`(,node . ,w) made)
                (when (and (memq (car node) '(tile editor)) (window-live-p w)
                           (not (memq (window-parameter w 'drgnx-tile-id) keep)))
                  (drgnx-grid--fill-leaf node w frame)))
              (drgnx-grid--sized
               frame (lambda ()
                       (pcase-dolist (`(,node . ,w) made)
                         (when (and (memq (car node) '(row col)) (window-valid-p w)) (drgnx-grid--size node w scale)))
                       ;; a side bar made again: its sections as tall as they were, once its own size is set
                       (pcase-dolist (`(,node . ,w) made)
                         (when-let* (((eq (car node) 'tile)) ((window-live-p w))
                                     ((not (memq (window-parameter w 'drgnx-tile-id) keep)))
                                     (parts (plist-get (plist-get (cdr node) :state) :parts)))
                           (drgnx-grid--part-heights w parts scale)))))
              (let ((top (apply #'max 0 ids)))
                (when (> top (or (frame-parameter frame 'drgnx-grid-next-id) 0))
                  (set-frame-parameter frame 'drgnx-grid-next-id top)))))
          ;; the leaving editors' buffers become tabs of the editor you used last
          (when-let* ((orphans (seq-filter #'buffer-live-p (delete-dups orphans)))
                      (mru (or (drgnx-state-editor-window frame) (car (drgnx-grid-tiles frame 'editor)))))
            (set-window-parameter mru 'drgnx-tabs
                                  (append (window-parameter mru 'drgnx-tabs)
                                          (seq-remove (lambda (b) (memq b (window-parameter mru 'drgnx-tabs))) orphans))))
          (when (window-live-p selected) (select-window selected 'norecord))
          (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame))
          (drgnx-grid--note-good frame)
          t)))))

;;; Full size

(defun drgnx-grid--keep-only (window)
  "Delete every tile of WINDOW's frame but WINDOW's (its atom stays whole), past `no-delete-other-windows'."
  (let ((mine (drgnx-grid--tile-root window)))
    (dolist (w (drgnx-grid--leaf-windows (window-frame window)))
      (unless (eq w mine) (drgnx-grid--delete-leaf w)))))

(defun drgnx-grid-full-size-p (&optional frame)
  "Non-nil while a tile of FRAME shows full size: (ID . TREE), the tile and the tree it goes back to."
  (frame-parameter frame 'drgnx-grid-full))

(defun drgnx-grid--full-note (count)
  "The note a full-size tile's tab row starts with: \"Full size · 1 of COUNT · KEY back\"."
  (let ((key (substitute-command-keys "\\[drgnx-grid-full-size-toggle]")))
    (propertize (format " Full size · 1 of %d · %s back " count
                        (if (string-prefix-p "M-x " key) "tile-full-size" key))
                'face 'shadow)))

(defun drgnx-grid-forget-full-size (&optional frame)
  "FRAME shows no tile full size any more, though its tiles stay as they are (a layout put its own arrangement back).
The saved tree, or nil when there was none."
  (when-let* ((full (drgnx-grid-full-size-p frame)))
    (set-frame-parameter frame 'drgnx-grid-full nil)
    (dolist (w (window-list frame 'nomini)) (set-window-parameter w 'drgnx-grid-full-note nil))
    (cdr full)))

(defun drgnx-grid-leave-full-size (&optional frame)
  "Back from full size on FRAME, when it shows one: the saved tree, exact (`drgnx-grid-apply-tree')."
  (when-let* ((tree (drgnx-grid-forget-full-size frame)))
    (drgnx-grid-apply-tree tree frame)))

(defun drgnx-grid-full-size-toggle (&optional window)
  "Show WINDOW's tile (default: the selected window's) alone, at the grid's full size; again to put every tile back
as it was.  The tab row says so, with the key back."
  (interactive)
  (let* ((window (or window (selected-window))) (frame (window-frame window)))
    (if (drgnx-grid-full-size-p frame)
        (drgnx-grid-leave-full-size frame)
      (let* ((main (drgnx-grid--main-of (drgnx-grid--tile-root window)))
             (tree (drgnx-grid-tree frame)))
        (set-frame-parameter frame 'drgnx-grid-full (cons (drgnx-grid-tile-id main) tree))
        (drgnx-grid--keep-only main)
        (set-window-parameter main 'drgnx-grid-full-note (drgnx-grid--full-note (length (drgnx-grid-tree-leaves tree))))
        (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame))))))

;;; Temporary windows, the popup row, and a grid a package collapsed

(defun drgnx-grid--temporary-p (window)
  "Non-nil when WINDOW is temporary: a tile `drgnx-tile-temporary' (a package's side window, a diff) or the popup row."
  (or (window-parameter window 'drgnx-tile-temporary) (eq (window-parameter window 'drgnx-role) 'popup)))

(defun drgnx-grid--temporary-windows (frame)
  (seq-filter #'drgnx-grid--temporary-p (window-list frame 'nomini)))

(defun drgnx-grid--note-good (frame)
  "Record FRAME's tree as the last good one (`drgnx-grid--good'), unless a temporary window or full size shows."
  (unless (or (drgnx-grid--temporary-windows frame) (frame-parameter frame 'drgnx-grid-full))
    (set-frame-parameter frame 'drgnx-grid--good (drgnx-grid-tree frame))))

(defun drgnx-grid--split-root (side px frame)
  "A new window on SIDE of FRAME's grid root, PX pixels along SIDE, the root's tiles as one sibling."
  (let ((drgnx-rules--placing t) (window-combination-limit t) (window-combination-resize nil)
        (ignore-window-parameters t) (window-resize-pixelwise t))
    (split-window (drgnx-grid-root frame) (- px) side t)))

(defun drgnx-grid--delete-temporary (window)
  "`delete-window' on a temporary tile: deleted, its space going back to its sibling."
  (drgnx-grid--delete-tile window))

(defun drgnx-grid-temporary-tile (buffer alist)
  "Show BUFFER in a temporary tile on ALIST's `side' of the grid (a package's `display-buffer-in-side-window' with no
rule for it): a tile of its own, never a side window, `drgnx-tile-temporary' t, so the tree leaves it out.  ALIST's
`window-width' or `window-height' (lines or columns, or a fraction) sizes it, else a quarter of the grid.  A temporary
tile already showing BUFFER is reused.  Returns the window."
  (let* ((frame (selected-frame))
         (side (pcase (cdr (assq 'side alist)) ('left 'left) ('right 'right) ('top 'above) (_ 'below)))
         (horizontal (memq side '(left right)))
         (have (seq-find (lambda (w) (and (window-parameter w 'drgnx-tile-temporary) (eq (window-buffer w) buffer)))
                         (window-list frame 'nomini))))
    (or have
        (let* ((root (drgnx-grid-root frame))
               (room (window-size root horizontal t))
               (want (cdr (assq (if horizontal 'window-width 'window-height) alist)))
               (px (cond ((integerp want) (* want (if horizontal (frame-char-width frame) (frame-char-height frame))))
                         ((floatp want) (round (* want room)))
                         (t (/ room 4))))
               (px (max (drgnx-grid-min-size frame horizontal) (min px (/ room 2)))))
          (drgnx-grid--note-good frame)
          (let ((w (drgnx-grid--split-root side px frame)))
            (pcase-dolist (`(,k . ,v) '((drgnx-role . tile) (drgnx-tile-temporary . t) (no-delete-other-windows . t)
                                        (no-other-window . t) (mode-line-format . none)
                                        (delete-window . drgnx-grid--delete-temporary)))
              (set-window-parameter w k v))
            (drgnx-grid-tile-id w)
            (window--display-buffer buffer w 'window alist)
            (set-window-dedicated-p w t)
            w)))))

(defun drgnx-grid-popup-row (buffer fraction)
  "A temporary row under FRAME's grid showing BUFFER, role `popup' (the popup lane when no panel shows to borrow),
fitted to BUFFER, at most FRACTION of the frame (default 0.33).  It is no tile: deleting it leaves the grid as it was."
  (let* ((frame (selected-frame)) (line (frame-char-height frame))
         (most (max line (floor (* (or fraction 0.33) (frame-pixel-height frame))))))
    (drgnx-grid--note-good frame)
    (let ((w (drgnx-grid--split-root 'below (min most (* 3 line)) frame)))
      (pcase-dolist (`(,k . ,v) '((drgnx-role . popup) (no-delete-other-windows . t) (no-other-window . t)))
        (set-window-parameter w k v))
      (set-window-buffer w buffer)
      (set-window-dedicated-p w 'drgnx)
      (let ((window-resize-pixelwise t)) (ignore-errors (fit-window-to-buffer w (max 1 (/ most line)) 1)))
      w)))

(defun drgnx-grid-end-popup-row (window)
  "Delete the popup row WINDOW: the grid as it was before it (`drgnx-grid--good'), to the pixel."
  (let* ((frame (window-frame window)) (good (frame-parameter frame 'drgnx-grid--good)))
    (let ((ignore-window-parameters t) (window-combination-resize nil)) (delete-window window))
    (when (and good (not (drgnx-grid--temporary-windows frame)) (not (equal (drgnx-grid-tree frame) good)))
      (drgnx-grid-apply-tree good frame))))

(defun drgnx-grid--watch-foreign (frame)
  "A grid that lost two or more tiles at once, past the grid's own commands (a package's `delete-other-windows' or
`set-window-configuration': Review Focus 3), is pushed, as it was, on the layout undo stack; then FRAME's tree now is
the last good one."
  (let ((good (frame-parameter frame 'drgnx-grid--good)))
    (when (and good (not (frame-parameter frame 'drgnx-grid-full)) (not (drgnx-grid--temporary-windows frame)))
      (let* ((live (mapcar (lambda (w) (window-parameter w 'drgnx-tile-id)) (drgnx-grid-tiles frame)))
             (lost (seq-remove (lambda (id) (memq id live)) (drgnx-grid--tree-ids good))))
        (when (cdr lost) (drgnx-grid-push 'foreign frame good)))))
  (drgnx-grid--note-good frame))

;; The side bar as one kind: the left dock with the current view's sections (the flow plan's places show it).
(drgnx-pane-define-kind 'side-bar :title "Side Bar" :home 'left :sidebar t)

(define-minor-mode drgnx-grid-mode
  "The tiled grid: pane kinds live in tiles, ordinary windows of Emacs's window tree (`drgnx-pane-backend' `grid').
Off, they live in the docks again (`areas')."
  :global t :group 'drgnx-grid
  (if drgnx-grid-mode
      (progn
        (setq drgnx-pane-backend 'grid)
        (drgnx-state-subscribe 'windows-changed #'drgnx-grid--windows-changed :lane 'now)
        ;; a monitor of another scale, the UI scale: the docks keep their logical sizes (noted at each resize)
        (add-hook 'nidhogg-frame-scale-change-functions #'drgnx-grid-keep-dock-sizes)
        (add-hook 'window-size-change-functions #'drgnx-grid-keep-dock-sizes)
        (advice-add 'balance-windows :around #'drgnx-grid--balance-editors-only)
        (unless (eq (bound-and-true-p ediff-window-setup-function) #'drgnx-grid-ediff-setup)
          (setq drgnx-grid--ediff-previous (and (boundp 'ediff-window-setup-function) (list ediff-window-setup-function)))
          (setq ediff-window-setup-function #'drgnx-grid-ediff-setup))
        (dolist (f (frame-list)) (drgnx-grid--adopt-editors f)))
    (when (eq (bound-and-true-p ediff-window-setup-function) #'drgnx-grid-ediff-setup)
      (if drgnx-grid--ediff-previous (setq ediff-window-setup-function (car drgnx-grid--ediff-previous))
        (makunbound 'ediff-window-setup-function))
      (setq drgnx-grid--ediff-previous nil))
    (setq drgnx-pane-backend 'areas)
    (drgnx-state-unsubscribe 'windows-changed #'drgnx-grid--windows-changed)
    (remove-hook 'nidhogg-frame-scale-change-functions #'drgnx-grid-keep-dock-sizes)
    (remove-hook 'window-size-change-functions #'drgnx-grid-keep-dock-sizes)
    (advice-remove 'balance-windows #'drgnx-grid--balance-editors-only)
    (dolist (f (frame-list)) (drgnx-grid--release f))))

(defun drgnx-grid--release (frame)
  "The grid off: FRAME's editor windows are plain windows again (no id, `delete-other-windows' deletes them), and
once no tile is left the frame's grid bookkeeping is emptied (a frame parameter can only be set to nil)."
  (dolist (w (drgnx-grid-tiles frame 'editor))
    (when (window-parameter w 'drgnx-tile-id)
      (set-window-parameter w 'drgnx-tile-id nil)
      (set-window-parameter w 'no-delete-other-windows nil)
      (when (eq (window-parameter w 'delete-window) #'drgnx-grid--delete-editor)
        (set-window-parameter w 'delete-window nil))))
  (unless (seq-some (lambda (w) (window-parameter w 'drgnx-tile-id)) (window-list frame 'nomini))
    (dolist (p '(drgnx-grid-next-id drgnx-grid--good drgnx-grid-memory drgnx-grid-full drgnx-grid--docks))
      (when (frame-parameter frame p) (set-frame-parameter frame p nil)))))

(provide 'drgnx-grid)
(require 'drgnx-grid-ops)               ; moving tiles: it needs this file first
(require 'drgnx-grid-frames)            ; the layout snapshot and undo stack (`drgnx-grid-push')
;;; drgnx-grid.el ends here
