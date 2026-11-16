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
(require 'drgnx-grid-tree)
(require 'drgnx-panes)

(defvar drgnx-rules--placing)
(defvar drgnx-wb-dock-columns)
(declare-function drgnx-wb-focus-editor "drgnx-wb")
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

(defconst drgnx-grid-docks '(left bottom right) "The homes a tool tile docks at.")

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
  "The store's `windows-changed' while the grid is on: a new editor window (a split) becomes an editor tile."
  (when-let* ((frame (plist-get data :frame)) ((frame-live-p frame)))
    (drgnx-grid--adopt-editors frame)))

;;;; Kinds' buffers, starts and points, per frame

(defvar drgnx-grid--kinds (make-hash-table :test 'eq :weakness 'key)
  "Frame → alist KIND → (BUFFER START POINT): where each kind was left on that frame.
Kept out of frame parameters: a buffer object in one would make the saved frame state unreadable.")

(defun drgnx-grid--saved (kind frame)
  (alist-get kind (gethash frame drgnx-grid--kinds)))

(defun drgnx-grid--remember (window)
  "Remember the buffer, start and point tile WINDOW shows for its shown kind."
  (when-let* (((drgnx-grid-tool-tile-p window)) (kind (car (window-parameter window 'drgnx-pane-stack))))
    (setf (alist-get kind (gethash (window-frame window) drgnx-grid--kinds))
          (list (window-buffer window) (window-start window) (window-point window)))))

(defun drgnx-grid--placeholder (kind)
  "KIND's placeholder: its :placeholder function's buffer, else a blank special buffer named after it."
  (let* ((spec (drgnx-pane-kind kind)) (fn (plist-get spec :placeholder))
         (b (and (functionp fn) (funcall fn))))
    (if (buffer-live-p b) b
      (or (get-buffer (format " *drgnx %s*" kind))
          (with-current-buffer (get-buffer-create (format " *drgnx %s*" kind) t)
            (special-mode)
            (setq-local cursor-type nil)
            (current-buffer))))))

(defun drgnx-grid--buffer-for (kind frame &optional buffer)
  "The buffer KIND shows on FRAME: BUFFER when given, else the one it was left on, else its own (`:buffer'), else
its placeholder.  Also the saved start and point, as (BUFFER START POINT); START and POINT nil when none apply."
  (let ((saved (drgnx-grid--saved kind frame)))
    (cond ((buffer-live-p buffer) (list buffer nil nil))
          ((buffer-live-p (car saved)) saved)
          (t (let* ((spec (drgnx-pane-kind kind)) (b (and spec (plist-get spec :buffer)))
                    (own (cond ((functionp b) (funcall b)) ((stringp b) (get-buffer-create b)) ((buffer-live-p b) b))))
               (list (if (buffer-live-p own) own (drgnx-grid--placeholder kind)) nil nil))))))

(defun drgnx-grid--put-buffer (window kind frame &optional buffer)
  "Show KIND in tool tile WINDOW (its buffer, start and point as left, or BUFFER)."
  (pcase-let ((`(,b ,start ,point) (drgnx-grid--buffer-for kind frame buffer)))
    (unless (eq (window-buffer window) b)
      (set-window-buffer window b)
      ;; Emacs preserves a size only for the buffer it was set with: set again for this one
      (when-let* ((dock (window-parameter window 'drgnx-tile-dock)))
        (window-preserve-size window (drgnx-grid--horizontal-dock-p dock) t)))
    (set-window-dedicated-p window 'drgnx)
    (when start (set-window-start window start t))
    (when point (set-window-point window point))
    (with-current-buffer b (add-hook 'kill-buffer-hook #'drgnx-grid--killed nil t))
    b))

(defun drgnx-grid--killed ()
  "The current buffer is being killed: tiles showing it show their kind's placeholder (R6)."
  (let ((dying (current-buffer)))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (when (and (drgnx-grid-tool-tile-p w) (eq (window-buffer w) dying))
          (let ((kind (car (window-parameter w 'drgnx-pane-stack))))
            (setf (alist-get kind (gethash f drgnx-grid--kinds)) nil)
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
  (alist-get key (frame-parameter frame 'drgnx-grid-memory)))

(defun drgnx-grid--set-memory (key value &optional frame)
  (let ((all (copy-alist (frame-parameter frame 'drgnx-grid-memory))))
    (setf (alist-get key all) value)
    (set-frame-parameter frame 'drgnx-grid-memory all)))

(defun drgnx-grid-split-dock (dock &optional px frame kinds)
  "A new window for DOCK's tile on FRAME (R2): split from the tiles it last gave its space to, else from its dock's
neighbour (`drgnx-grid--dock-target').  PX is its size in pixels along the split (left and right a width, bottom a
height); nil: DOCK's `:sizes' intent, else KINDS' `:size', else `drgnx-grid--default-size'.  It is clamped so the
new window and the one it comes from keep `drgnx-grid-min-size' (at most half the room each).  The window gets
`drgnx-tile-dock' DOCK, an id and `no-delete-other-windows'; the caller gives it its role, buffer and the rest."
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
  "The tool tile on FRAME whose stack holds KIND, or nil."
  (seq-find (lambda (w) (and (drgnx-grid-tool-tile-p w) (memq kind (window-parameter w 'drgnx-pane-stack))))
            (window-list frame 'nomini)))

(defun drgnx-grid-window (kind &optional frame)
  "The window showing KIND on FRAME: the tool tile whose stack shows it in front, or, for an editor kind, the window
showing the last buffer it put there; nil when it does not show."
  (let ((frame (or frame (selected-frame))))
    (if (eq (drgnx-grid--home kind) 'editor)
        (drgnx-pane--areas-window kind frame)
      (let ((w (drgnx-grid--tile-of kind frame)))
        (and w (eq (car (window-parameter w 'drgnx-pane-stack)) kind) w)))))

(defun drgnx-grid--bring-to-front (window kind frame &optional buffer)
  "Show KIND in WINDOW, whose stack holds it: the window and every edge stay (R1)."
  (let ((stack (window-parameter window 'drgnx-pane-stack)))
    (unless (eq (car stack) kind)
      (drgnx-grid--remember window)
      (set-window-parameter window 'drgnx-pane-stack (cons kind (remq kind stack))))
    (drgnx-grid--put-buffer window kind frame buffer)
    (drgnx-grid--put-row window)
    window))

(cl-defun drgnx-grid-show (kind &key buffer select dock)
  "Show pane KIND on the selected frame and return its window.
R1: a kind in a stack comes to the front, the window and its edges unchanged.  R2: a hidden kind joins its dock's
tile (DOCK, else its home) when that shows, else a new tile splits its remembered neighbour, else its dock's, taking
space from that window only.  R5: the selected window stays unless SELECT.  BUFFER: what KIND shows."
  (let* ((frame (selected-frame)) (selected (selected-window)) (spec (drgnx-pane--spec kind)))
    (prog1
        (if (eq (plist-get spec :home) 'editor)
            (drgnx-pane--areas-show kind buffer select)
          (drgnx-grid--adopt-editors frame)
          (let* ((dock (or dock (drgnx-grid--dock-of kind)))
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
  (let ((w (drgnx-grid-dock dock)))
    (if w (drgnx-grid-hide (car (window-parameter w 'drgnx-pane-stack)))
      (let* ((memory (drgnx-grid--memory dock))
             (kind (or (car (plist-get memory :kinds)) (car (drgnx-pane-kinds dock)))))
        (when kind (drgnx-grid-show kind))))))

;;;; Splitting tiles, the tile picker, Close Tile

(defun drgnx-grid-tile-window-p (window)
  "Non-nil when WINDOW belongs to a tool tile: the tile's window, or a part of its atom (a section, a companion)."
  (and (window-live-p window) (or (drgnx-grid-tool-tile-p window) (window-parameter window 'drgnx-tile-part)) t))

(defun drgnx-grid-split-tile (window side)
  "A new window beside WINDOW's whole tile (its atom, `drgnx-grid--tile-root') on SIDE (`right', `below'), taking half
of the tile, pixelwise; an id and `no-delete-other-windows'.  The caller gives it what it shows."
  (let ((new (let ((drgnx-rules--placing t) (window-combination-limit nil) (window-combination-resize nil)
                   (ignore-window-parameters t) (window-resize-pixelwise t))
               (split-window (drgnx-grid--tile-root window) nil side t))))
    (set-window-parameter new 'window-atom nil)
    (set-window-parameter new 'no-delete-other-windows t)
    (drgnx-grid-tile-id new)
    new))

(defun drgnx-grid--title (kind)
  "KIND's title as its tab shows it."
  (let ((title (or (plist-get (drgnx-pane-kind kind) :title) (capitalize (symbol-name kind)))))
    (if (functionp title) (funcall title) title)))

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
  (let ((m (make-sparse-keymap))) (define-key m [tab-line mouse-1] #'drgnx-grid--tab-click) m))

(defun drgnx-grid--close-click (event)
  "A click on a tool tile's ✕: hide the tile."
  (interactive "e")
  (let ((w (posn-window (event-start event))))
    (when (drgnx-grid-tool-tile-p w)
      (with-selected-frame (window-frame w) (drgnx-grid-hide (car (window-parameter w 'drgnx-pane-stack)))))))

(defun drgnx-grid--tab-row (window)
  "Tool tile WINDOW's tab row: its kinds in their definition order, the shown one current, then the ✕."
  (let* ((stack (window-parameter window 'drgnx-pane-stack)) (shown (car stack))
         (kinds (seq-filter (lambda (k) (memq k stack)) (append (drgnx-pane-kinds) stack))))
    (concat
     (mapconcat (lambda (k)
                  (let ((title (drgnx-grid--title k)))
                    (propertize (concat " " title " ")
                                'face (if (eq k shown) 'tab-line-tab-current 'tab-line-tab-inactive)
                                'drgnx-grid-kind k 'mouse-face 'highlight 'local-map drgnx-grid--tab-map
                                'help-echo "Show this tab")))
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
(defun drgnx-grid--backend-show (kind buffer select)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-show kind buffer select)
    (drgnx-grid-show kind :buffer buffer :select select)))
(defun drgnx-grid--backend-hide (kind)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-hide kind) (drgnx-grid-hide kind)))
(defun drgnx-grid--backend-window (kind frame)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-window kind frame) (drgnx-grid-window kind frame)))
(defun drgnx-grid--backend-focus (kind)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-focus kind) (drgnx-grid-focus kind)))
(defun drgnx-grid--backend-resize (kind px horizontal)
  (if (drgnx-grid--docked-p kind) (drgnx-pane--areas-resize kind px horizontal) (drgnx-grid-resize kind px horizontal)))

(setf (alist-get 'grid drgnx-pane--backends)
      (list :define #'drgnx-grid--define :show #'drgnx-grid--backend-show :hide #'drgnx-grid--backend-hide
            :window #'drgnx-grid--backend-window :focus #'drgnx-grid--backend-focus
            :resize #'drgnx-grid--backend-resize))

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
    (advice-remove 'balance-windows #'drgnx-grid--balance-editors-only)))

(provide 'drgnx-grid)
;;; drgnx-grid.el ends here
