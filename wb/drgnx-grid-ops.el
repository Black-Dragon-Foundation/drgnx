;;; drgnx-grid-ops.el --- Moving tiles by keys: neighbour, move, swap, stack, unstack, resize -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The grid's tile moves (wb/drgnx-grid.el holds the tiles).  A tile is its whole atom (`drgnx-grid--tile-root'): a
;; move, a swap or a stack carries its parts along.  Moves go by pixel edges, as windmove does, across atoms and docks.
;; A move with no room changes nothing and says "No room there"; every move first pushes the grid on the layout undo
;; stack (`drgnx-grid-push' `move').  See docs/develop/core.md, "Moving tiles".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-grid)

(declare-function drgnx-chrome-tabs "drgnx-chrome" (w))
(declare-function drgnx-chrome-apply "drgnx-chrome" (&optional frame note))
(declare-function drgnx-wb-area-tab "drgnx-area" (area))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(declare-function drgnx-wb-area-hide "drgnx-area" (area))
(defvar drgnx-wb--areas)

(defcustom drgnx-grid-resize-step-px 24
  "One step of Resize Tiles (`drgnx-grid-resize-mode') in a graphical frame, in logical pixels; a terminal's is one
column or line."
  :type 'natnum :group 'drgnx-grid)

(eval-and-compile
  (defconst drgnx-grid--sides '((left . left) (right . right) (up . above) (down . below))
    "A direction and the side of a window it names."))

;;;; Tiles and neighbours

(defun drgnx-grid-tile-main (window)
  "The tile WINDOW belongs to, as its main window (the tile's own window, not a part), or nil."
  (when (window-live-p window)
    (let ((root (drgnx-grid--tile-root window)))
      (if (window-live-p root) root (drgnx-grid--main-of root)))))

(defun drgnx-grid--edges (window)
  "Tile WINDOW's whole pixel edges: its atom's."
  (window-pixel-edges (drgnx-grid--tile-root window)))

(defun drgnx-grid-neighbour (window direction)
  "The tile next to WINDOW's tile in DIRECTION (`left', `right', `up', `down'), as its main window, or nil at the
grid's edge.  By pixel edges, as windmove does: the tiles whose facing edge meets WINDOW's tile's, the one overlapping
it most along that edge (ties: the one holding the cursor's line or column), across atoms and docks."
  (let* ((me (drgnx-grid-tile-main window))
         (e (drgnx-grid--edges me))
         (horizontal (memq direction '(left right)))
         (gap (+ 2 (if horizontal (frame-right-divider-width (window-frame me)) (frame-bottom-divider-width (window-frame me)))))
         (edge (pcase direction ('left (nth 0 e)) ('right (nth 2 e)) ('up (nth 1 e)) ('down (nth 3 e))
                      (_ (error "No such direction: %S" direction))))
         (point (let ((p (ignore-errors (pos-visible-in-window-p (window-point window) window t)))
                      (we (window-pixel-edges window)))
                  (if p (if horizontal (+ (nth 1 we) (cadr p)) (+ (nth 0 we) (car p)))
                    (if horizontal (nth 1 e) (nth 0 e)))))
         best best-overlap best-hit)
    (dolist (w (drgnx-grid-tiles (window-frame me)))
      (unless (eq w me)
        (let* ((o (drgnx-grid--edges w))
               (facing (pcase direction ('left (nth 2 o)) ('right (nth 0 o)) ('up (nth 3 o)) ('down (nth 1 o))))
               (lo (max (if horizontal (nth 1 e) (nth 0 e)) (if horizontal (nth 1 o) (nth 0 o))))
               (hi (min (if horizontal (nth 3 e) (nth 2 e)) (if horizontal (nth 3 o) (nth 2 o))))
               (overlap (- hi lo))
               (hit (and (<= (if horizontal (nth 1 o) (nth 0 o)) point) (< point (if horizontal (nth 3 o) (nth 2 o))))))
          (when (and (<= (abs (- facing edge)) gap) (> overlap 0)
                     (or (null best) (and hit (not best-hit))
                         (and (eq (and hit t) (and best-hit t)) (> overlap best-overlap))))
            (setq best w best-overlap overlap best-hit hit)))))
    best))

;;;; Carrying a tile's windows

(defun drgnx-grid--persistent (root)
  "`window-persistent-parameters' with every parameter of ROOT's windows saved: a tile's state carries them all."
  (let ((params (copy-sequence window-persistent-parameters)))
    (walk-window-tree (lambda (w) (dolist (p (window-parameters w))
                                    (unless (assq (car p) params) (push (cons (car p) t) params))))
                      (window-frame root) nil 'nomini)
    (dolist (p '(window-atom window-preserved-size)) (setf (alist-get p params) t))
    params))

(defun drgnx-grid--state (window)
  "Tile WINDOW's whole state (its atom's windows, buffers and every parameter), for `drgnx-grid--put'."
  (let* ((root (drgnx-grid--tile-root window)) (window-persistent-parameters (drgnx-grid--persistent root)))
    ;; a lone window's preserved size is its place's (a dock's width or height): it stays behind, or the place it
    ;; lands in would take that size (a swap would trade the places' sizes); an atom's inner ones (the composer) go along
    (when (window-live-p root) (setq window-persistent-parameters (assq-delete-all 'window-preserved-size
                                                                                   window-persistent-parameters)))
    (cons window-persistent-parameters (window-state-get root))))

(defun drgnx-grid--put (state window)
  "Put STATE (`drgnx-grid--state') into WINDOW, which it replaces: WINDOW's own parameters go first, so none is left
on the window the state's first part lands in.  The caller finds the tile again by its id."
  (when (window-live-p window)
    (dolist (p (window-parameters window)) (set-window-parameter window (car p) nil)))
  (let ((window-persistent-parameters (car state)) (window-resize-pixelwise t) (ignore-window-parameters t))
    (window-state-put (cdr state) window t)))

(defun drgnx-grid--find-id (id frame)
  "FRAME's tile whose main window has tile id ID."
  (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) id)) (drgnx-grid-tiles frame)))

(defun drgnx-grid--undock (window)
  "WINDOW's tile is no dock's any more (moved): its windows lose `drgnx-tile-dock', and a docked area's window becomes
a tool tile holding the area's shown tab (else it would be no tile at all)."
  (let* ((main (drgnx-grid-tile-main window)) (role (window-parameter main 'drgnx-role))
         (entries (and role (not (eq role 'tile)) (window-parameter main 'drgnx-tile-dock) (drgnx-grid--entries main))))
    (walk-window-subtree (lambda (w) (set-window-parameter w 'drgnx-tile-dock nil)) (drgnx-grid--tile-root window) t)
    (when entries
      (set-window-parameter main 'drgnx-role 'tile)
      (set-window-parameter main 'drgnx-pane-stack (copy-sequence entries))
      (dolist (p '((no-other-window . t) (mode-line-format . none) (delete-window . drgnx-grid--delete-window)))
        (set-window-parameter main (car p) (cdr p)))
      (window-preserve-size main t nil) (window-preserve-size main nil nil)
      (drgnx-grid--put-row main))))

(defun drgnx-grid--no-room ()
  (user-error "No room there"))

;;;; Move, swap, stack, unstack

(defun drgnx-grid-move (window target zone)
  "Move WINDOW's tile to ZONE of TARGET's tile: `left', `right', `above' or `below' it (taking half of it), or
`center' (stacked onto it, `drgnx-grid-stack').  Its space goes to the tile it leaves (R3); every other tile stays.
A docked tile moved is no dock's any more.  No room: nothing changes, \"No room there\".  Returns the moved tile."
  (let* ((me (drgnx-grid-tile-main window)) (onto (drgnx-grid-tile-main target)) (frame (window-frame me)))
    (cond
     ((eq zone 'center) (drgnx-grid-stack me onto))
     ((or (eq me onto) (not onto)) (drgnx-grid--no-room))
     ((not (drgnx-grid-room-p onto zone)) (drgnx-grid--no-room))
     (t
      (drgnx-grid-leave-full-size frame)
      (drgnx-grid-push 'move)
      (let* ((state (drgnx-grid--state me)) (id (window-parameter onto 'drgnx-tile-id))
             (mine (window-parameter me 'drgnx-tile-id))
             (selected (eq (drgnx-grid-tile-main (selected-window)) me)))
        (set-window-parameter me 'delete-window nil)
        (drgnx-grid--delete-tile (drgnx-grid--tile-root me))
        (let ((onto (drgnx-grid--find-id id frame)) main)
          (drgnx-grid--put state (drgnx-grid-split-tile onto zone))
          (setq main (drgnx-grid--find-id mine frame))
          (drgnx-grid--undock main)
          (when selected (select-window main))
          (drgnx-grid--note-good frame)
          (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame))
          main))))))

(defun drgnx-grid-swap (a b)
  "Swap the contents of A's tile and B's tile; the sizes stay with the places.  Returns A's contents' new window."
  (let* ((a (drgnx-grid-tile-main a)) (b (drgnx-grid-tile-main b)) (frame (window-frame a)))
    (when (or (not b) (eq a b)) (drgnx-grid--no-room))
    (drgnx-grid-leave-full-size frame)
    (drgnx-grid-push 'move)
    (let* ((selected (eq (drgnx-grid-tile-main (selected-window)) a))
           (sa (drgnx-grid--state a)) (sb (drgnx-grid--state b))
           (ra (drgnx-grid--tile-root a)) (rb (drgnx-grid--tile-root b))
           (ida (window-parameter a 'drgnx-tile-id)) (idb (window-parameter b 'drgnx-tile-id)))
      ;; window-state-put also restores the preserved sizes it was given: the places keep theirs
      (drgnx-grid--put sb ra)
      (drgnx-grid--put sa rb)
      (let ((na (drgnx-grid--find-id ida frame)))
        (drgnx-grid--undock na)
        (drgnx-grid--undock (drgnx-grid--find-id idb frame))
        (when selected (select-window na))
        (drgnx-grid--note-good frame)
        (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame))
        na))))

(defun drgnx-grid--entries (window)
  "The stack entries tile WINDOW holds: a tool tile's stack, a docked area's shown tab."
  (or (window-parameter window 'drgnx-pane-stack)
      (let ((role (window-parameter window 'drgnx-role)))
        (and role (assq role drgnx-wb--areas) (drgnx-wb-area-tab role) (list (drgnx-wb-area-tab role))))))

(defun drgnx-grid-stack (window onto)
  "Stack WINDOW's tile onto ONTO's: an editor's tabs join an editor's, a tool tile's kinds (a docked area's shown tab)
join a tool tile's stack; WINDOW's tile goes, its space to its neighbour.  Anything else changes nothing."
  (let* ((me (drgnx-grid-tile-main window)) (onto (drgnx-grid-tile-main onto)) (frame (window-frame me)))
    (cond
     ((or (not onto) (eq me onto)) (drgnx-grid--no-room))
     ((and (drgnx-grid-editor-tile-p me) (drgnx-grid-editor-tile-p onto))
      (drgnx-grid-leave-full-size frame)
      (drgnx-grid-push 'move)
      (let ((tabs (append (drgnx-chrome-tabs me) (list (window-buffer me))))
            (selected (eq (drgnx-grid-tile-main (selected-window)) me)))
        (set-window-parameter onto 'drgnx-tabs
                              (append (window-parameter onto 'drgnx-tabs)
                                      (seq-remove (lambda (b) (memq b (window-parameter onto 'drgnx-tabs))) (delete-dups tabs))))
        (set-window-buffer onto (window-buffer me))
        (set-window-parameter me 'delete-window nil)
        (drgnx-grid--delete-tile me)
        (when selected (select-window onto))
        (drgnx-grid--note-good frame)
        (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame))
        onto))
     ((and (eq (window-parameter onto 'drgnx-role) 'tile) (not (window-parameter onto 'drgnx-tile-temporary))
           (drgnx-grid--entries me))
      (drgnx-grid-leave-full-size frame)
      (drgnx-grid-push 'move)
      (let ((entries (drgnx-grid--entries me)) (selected (eq (drgnx-grid-tile-main (selected-window)) me)))
        (if (eq (window-parameter me 'drgnx-role) 'tile)
            (progn (drgnx-grid--remember me)
                   (set-window-parameter me 'delete-window nil)
                   (drgnx-grid--delete-tile (drgnx-grid--tile-root me)))
          (drgnx-wb-area-hide (window-parameter me 'drgnx-role)))
        (set-window-parameter onto 'drgnx-pane-stack
                              (append (window-parameter onto 'drgnx-pane-stack)
                                      (seq-remove (lambda (e) (member e (window-parameter onto 'drgnx-pane-stack))) entries)))
        (drgnx-grid--bring-to-front onto (car entries) frame)
        (when selected (select-window onto))
        (drgnx-grid--note-good frame)
        onto))
     (t (user-error "Only editors stack onto editors, and panes onto a tile of panes")))))

(defun drgnx-grid-unstack (window)
  "Put the shown tab of WINDOW's tile into a new tile beside it, on the side with more room (right when the tile is
wider than tall): an editor's buffer into a new editor tile, a tool tile's front kind (a docked area's tab) into a new
tool tile.  A tile with one tab, or no room: nothing changes.  Returns the new tile."
  (let* ((me (drgnx-grid-tile-main window)) (frame (window-frame me))
         (root (drgnx-grid--tile-root me))
         (side (if (>= (window-pixel-width root) (window-pixel-height root)) 'right 'below)))
    (cond
     ((drgnx-grid-editor-tile-p me)
      (let* ((shown (window-buffer me)) (rest (remq shown (drgnx-chrome-tabs me))))
        (unless rest (user-error "One tab: nothing to unstack"))
        (unless (drgnx-grid-room-p me side) (drgnx-grid--no-room))
        (drgnx-grid-push 'move)
        (let ((new (drgnx-grid-split-tile me side)))
          (set-window-dedicated-p new nil)
          (set-window-parameter me 'drgnx-tabs (remq shown (window-parameter me 'drgnx-tabs)))
          (set-window-buffer me (car (last rest)))
          (set-window-buffer new shown)
          (set-window-parameter new 'drgnx-tabs (list shown))
          (drgnx-grid--adopt new)
          (select-window new)
          (drgnx-grid--note-good frame)
          new)))
     (t
      (let* ((entries (drgnx-grid--entries me)) (stack (window-parameter me 'drgnx-pane-stack))
             (area (and (not stack) (window-parameter me 'drgnx-role)))
             (others (and area (seq-remove (lambda (k) (eq k (car entries)))
                                           (mapcar #'car (plist-get (alist-get area drgnx-wb--areas) :tabs))))))
        (unless (and entries (if stack (cdr stack) others)) (user-error "One tab: nothing to unstack"))
        (unless (drgnx-grid-room-p me side) (drgnx-grid--no-room))
        (drgnx-grid-push 'move)
        (let ((new (drgnx-grid--new-tile me side (list (car entries)))))
          (if stack
              (progn (set-window-parameter me 'drgnx-pane-stack (cdr stack))
                     (drgnx-grid--bring-to-front me (cadr stack) frame))
            (drgnx-wb-area-show area (car others)))
          (drgnx-grid--note-good frame)
          new))))))

;;;; Resize Tiles

(defun drgnx-grid--step (frame horizontal)
  (if (display-graphic-p frame)
      (drgnx-grid-tree-from-logical drgnx-grid-resize-step-px (drgnx-pixels-scale frame))
    (if horizontal (frame-char-width frame) (frame-char-height frame))))

(defun drgnx-grid-resize-step (direction)
  "Move an edge of the selected tile one step toward DIRECTION (`left', `right', `up', `down'): the edge on that side,
which grows the tile, or, at the grid's edge, the opposite one, which shrinks it.  Only the tile beyond that edge gives
or takes the space.  A docked tile's size is noted as intent."
  (let* ((me (drgnx-grid-tile-main (selected-window))) (frame (window-frame me))
         (horizontal (and (memq direction '(left right)) t))
         (step (drgnx-grid--step frame horizontal))
         (forward (memq direction '(right down)))
         (back (if horizontal (if forward 'left 'right) (if forward 'up 'down)))
         (ahead (drgnx-grid-neighbour me direction)) (behind (drgnx-grid-neighbour me back))
         ;; an edge is a window's trailing edge: ours toward right/down, the neighbour's toward left/up
         (move (cond ((and forward ahead) (cons (drgnx-grid--tile-root me) step))
                     ((and (not forward) ahead) (cons (drgnx-grid--tile-root ahead) (- step)))
                     ((and forward behind) (cons (drgnx-grid--tile-root behind) step))
                     ((and (not forward) behind) (cons (drgnx-grid--tile-root me) (- step))))))
    (when move
      (drgnx-grid--sized
       frame (lambda () (ignore-errors (adjust-window-trailing-edge (car move) (cdr move) horizontal t)))))
    (when-let* ((dock (window-parameter me 'drgnx-tile-dock)))
      (window-preserve-size me (drgnx-grid--horizontal-dock-p dock) t)
      (drgnx-state-note-intent frame :sizes dock (window-size me (drgnx-grid--horizontal-dock-p dock) t)))))

(defvar drgnx-grid-resize-map (make-sparse-keymap)
  "Resize Tiles' keys (the profiles' tile-resize-left/right/up/down, the arrows): each steps; any other key ends it and
does what it does.")

(defun drgnx-grid-resize-left () "Resize Tiles: grow toward the left." (interactive) (drgnx-grid-resize-step 'left))
(defun drgnx-grid-resize-right () "Resize Tiles: grow toward the right." (interactive) (drgnx-grid-resize-step 'right))
(defun drgnx-grid-resize-up () "Resize Tiles: grow upward." (interactive) (drgnx-grid-resize-step 'up))
(defun drgnx-grid-resize-down () "Resize Tiles: grow downward." (interactive) (drgnx-grid-resize-step 'down))
(dolist (f '(drgnx-grid-resize-left drgnx-grid-resize-right drgnx-grid-resize-up drgnx-grid-resize-down))
  (put f 'repeat-map 'drgnx-grid-resize-map))

(defun drgnx-grid-resize-mode ()
  "Resize Tiles: the arrows grow the selected tile toward them (or shrink it at the grid's edge), one step each; any
other key ends it and does what it does.  The hint is in the echo area."
  (interactive)
  (message "Resize Tiles: arrows grow or shrink, any other key ends")
  (set-transient-map drgnx-grid-resize-map t (lambda () (message nil))))

;;;; Drag and drop inside a frame (`drgnx-grid-drag')

(defface drgnx-grid-drop '((t :inherit highlight))
  "A drop target's tab line while a tile is dragged over it (\"⤓ drop: split right\")."
  :group 'drgnx-grid)

(defconst drgnx-grid--zone-words
  '((left . "split left") (right . "split right") (above . "split up") (below . "split down") (center . "stack"))
  "What a drop on each zone does, as the target's tab line says it.")

(defvar drgnx-grid--drag-shown nil
  "The drag's feedback now: (WINDOW ZONE PARAM ITS-OWN-LINE), PARAM the line it is on, or nil.")

(defun drgnx-grid--row-param (window)
  "The line WINDOW's tab row is on: `header-line-format' for a docked area (its row is its header line), else
`tab-line-format'."
  (if (and (memq (window-parameter window 'tab-line-format) '(nil none))
           (not (memq (window-parameter window 'header-line-format) '(nil none))))
      'header-line-format
    'tab-line-format))

(defun drgnx-grid--frame-xy (posn)
  "POSN's frame pixel position, (X . Y), or nil when it is on no window (outside every frame, on a frame's edge)."
  (let ((w (posn-window posn)) (xy (posn-x-y posn)))
    (when (and (window-live-p w) xy)
      (let ((e (if (posn-area posn) (window-pixel-edges w) (window-body-pixel-edges w))))
        (cons (+ (nth 0 e) (car xy)) (+ (nth 1 e) (cdr xy)))))))

(defun drgnx-grid-drop-target (frame x y)
  "The tile of FRAME (default the selected one) under frame pixel X, Y and the zone of it there (`drgnx-grid-zone'),
as (MAIN-WINDOW . ZONE); nil on no tile."
  (seq-some (lambda (w) (let ((e (drgnx-grid--edges w)))
                          (and (<= (nth 0 e) x) (< x (nth 2 e)) (<= (nth 1 e) y) (< y (nth 3 e))
                               (cons w (drgnx-grid-zone e x y)))))
            (drgnx-grid-tiles (or frame (selected-frame)))))

(defun drgnx-grid--drag-clear ()
  "Give the feedback's window its tab line back."
  (when-let* ((shown drgnx-grid--drag-shown))
    (setq drgnx-grid--drag-shown nil)
    (when (window-live-p (car shown)) (set-window-parameter (car shown) (nth 2 shown) (nth 3 shown)))))

(defun drgnx-grid--drag-show (target zone)
  "Say on TARGET's tab row (`drgnx-grid--row-param'), and on no other, what a drop on ZONE of it does (nil TARGET:
say it nowhere)."
  (unless (and drgnx-grid--drag-shown (eq (car drgnx-grid--drag-shown) target) (eq (nth 1 drgnx-grid--drag-shown) zone))
    (drgnx-grid--drag-clear)
    (when (window-live-p target)
      (let ((param (drgnx-grid--row-param target)))
        (setq drgnx-grid--drag-shown (list target zone param (window-parameter target param)))
        (set-window-parameter target param
                              (propertize (format " ⤓ drop: %s " (alist-get zone drgnx-grid--zone-words))
                                          'face 'drgnx-grid-drop))))))

(defun drgnx-grid--drop (window target zone)
  "Drop WINDOW's tile on ZONE of TARGET's (`drgnx-grid-move').  On itself, on no tile or where there is no room,
nothing changes and the echo area says \"Nothing moved\".  Returns the moved tile or nil."
  (if (or (not (window-live-p target)) (eq (drgnx-grid-tile-main target) (drgnx-grid-tile-main window)))
      (progn (message "Nothing moved") nil)
    (condition-case nil (drgnx-grid-move window target zone)
      (user-error (message "Nothing moved") nil))))

(defun drgnx-grid--drag (window &optional kind)
  "Drag WINDOW's tile (with KIND, that one tab of a tool tile) under `track-mouse' until a button goes up: each
movement finds the tile and zone under the pointer and says so on that tile's tab line; the release drops there
\(`drgnx-grid--drop'); Esc or \\`C-g' cancels.  Returns the moved tile, or nil."
  (let ((frame (window-frame window)) (done nil) (result nil) (inhibit-quit t))
    (unwind-protect
        (track-mouse
          (setq track-mouse 'dragging)
          (while (not done)
            ;; `read-key': a terminal's motion and release are decoded only through `input-decode-map'
            (let ((ev (read-key)))
              (cond
               ((mouse-movement-p ev)
                (let* ((xy (drgnx-grid--frame-xy (event-start ev)))
                       (hit (and xy (eq (window-frame (posn-window (event-start ev))) frame)
                                 (drgnx-grid-drop-target frame (car xy) (cdr xy)))))
                  (if hit (drgnx-grid--drag-show (car hit) (cdr hit)) (drgnx-grid--drag-clear))
                  (redisplay)))
               ((and (consp ev) (memq (event-basic-type ev) '(mouse-1 mouse-2 mouse-3)))
                (setq done t)
                (drgnx-grid--drag-clear)
                (let* ((end (event-end ev)) (xy (drgnx-grid--frame-xy end))
                       (hit (and xy (eq (window-frame (posn-window end)) frame)
                                 (drgnx-grid-drop-target frame (car xy) (cdr xy)))))
                  (setq result (drgnx-grid--drop (drgnx-grid--drag-source window kind hit) (car hit) (cdr hit)))))
               ((memq ev '(27 7 escape)) (setq done t) (message "Nothing moved"))))))
      (drgnx-grid--drag-clear))
    result))

(defun drgnx-grid--drag-source (window kind hit)
  "The tile a drag of WINDOW (with KIND, one tab dragged out of its row: a pane kind of a tool tile, or a buffer of an
editor's tabs) drops on HIT: the tile itself, or, when KIND is one of several tabs and HIT is another tile, a tile of
its own unstacked beside first (`drgnx-grid-unstack')."
  (if (and kind hit (not (eq (drgnx-grid-tile-main (car hit)) (drgnx-grid-tile-main window)))
           (if (bufferp kind)
               (remq kind (drgnx-chrome-tabs window))
             (cdr (window-parameter window 'drgnx-pane-stack))))
      (with-selected-window window
        (if (bufferp kind) (set-window-buffer window kind) (drgnx-grid-show kind))
        (drgnx-grid-unstack window))
    window))

(defun drgnx-grid-grip-press (event)
  "A press on a tile's grip (the ⠿ at its tab line's start): drag the tile (`drgnx-grid--drag').  Off
\(`drgnx-grid-drag' nil), nothing."
  (interactive "e")
  (let ((w (posn-window (event-start event))))
    (when (and drgnx-grid-drag (window-live-p w)) (drgnx-grid--drag w))))

(defun drgnx-grid-tab-press (event kind click)
  "A press on a tab of KIND (a pane kind, or an editor's buffer): released on the same tab row it is a click (CLICK
called with EVENT); dragged off the row it moves that tab (`drgnx-grid--drag', `drgnx-grid--drag-source').  Off
\(`drgnx-grid-drag' nil), the click."
  (let ((w (posn-window (event-start event))) (area (posn-area (event-start event))))
    (when (window-live-p w)
      (if (not drgnx-grid-drag)
          (funcall click event)
        ;; `read-key', not `read-event': on a terminal the release is xterm-mouse's bytes, decoded only through
        ;; `input-decode-map' (`read-event' would return their ESC).  Under `track-mouse', so that the first motion
        ;; off the row is an event (a terminal reports no motion otherwise); motion on the row is skipped.
        (let ((ev (track-mouse
                    (let (e)
                      (while (progn (setq e (read-key))
                                    (and (mouse-movement-p e) (eq (posn-window (event-start e)) w)
                                         (eq (posn-area (event-start e)) area))))
                      e))))
          (if (and (consp ev) (eq (event-basic-type ev) 'mouse-1) (not (mouse-movement-p ev))
                   (eq (posn-window (event-end ev)) w) (eq (posn-area (event-end ev)) area))
              (funcall click event)
            (setq unread-command-events (cons ev unread-command-events))
            (drgnx-grid--drag w kind)))))))

(defun drgnx-grid--tab-press (event)
  "A press on a tool tile's tab (`drgnx-grid-tab-press')."
  (interactive "e")
  (let ((s (posn-string (event-start event))))
    (drgnx-grid-tab-press event (and s (get-text-property (cdr s) 'drgnx-grid-kind (car s))) #'drgnx-grid--tab-click)))

;;;; The pane backend's move and stack (`drgnx-pane-move', `drgnx-pane-stack')

(defun drgnx-grid--kind-window (kind)
  (or (drgnx-grid--backend-window kind (selected-frame)) (user-error "%s does not show" kind)))

(defun drgnx-grid--backend-move (kind target zone)
  (drgnx-grid-move (drgnx-grid--kind-window kind) (drgnx-grid--kind-window target) zone))

(defun drgnx-grid--backend-stack (kind onto)
  (drgnx-grid-stack (drgnx-grid--kind-window kind) (drgnx-grid--kind-window onto)))

;;;; The commands' directions

(defmacro drgnx-grid--by-direction (name doc fn)
  "Define NAME-left … NAME-down, interactive, calling FN with the selected tile's main window and its neighbour in
that direction, and the direction's side.  DOC is the docstring's start."
  `(progn
     ,@(mapcar (lambda (d)
                 `(defun ,(intern (format "%s-%s" name (car d))) ()
                    ,(format "%s %s." doc (car d))
                    (interactive)
                    (let* ((me (drgnx-grid-tile-main (selected-window)))
                           (other (drgnx-grid-neighbour me ',(car d))))
                      (unless other (user-error "No tile there"))
                      (funcall ,fn me other ',(cdr d)))))
               drgnx-grid--sides)))

(drgnx-grid--by-direction drgnx-grid-move-tile "Move the selected tile beyond its neighbour to the"
                          (lambda (me other side) (drgnx-grid-move me other side)))
(drgnx-grid--by-direction drgnx-grid-swap-tile "Swap the selected tile with its neighbour to the"
                          (lambda (me other _side) (drgnx-grid-swap me other)))
(drgnx-grid--by-direction drgnx-grid-stack-tile "Stack the selected tile onto its neighbour to the"
                          (lambda (me other _side) (drgnx-grid-stack me other)))

(defun drgnx-grid-unstack-tile ()
  "Unstack the Shown Tab: into a new tile beside this one."
  (interactive)
  (drgnx-grid-unstack (selected-window)))

(defun drgnx-grid-exchange ()
  "Vim's `C-w x': swap the selected tile with the one to its right, else the one below."
  (interactive)
  (let* ((me (drgnx-grid-tile-main (selected-window)))
         (other (or (drgnx-grid-neighbour me 'right) (drgnx-grid-neighbour me 'down))))
    (unless other (user-error "No tile there"))
    (drgnx-grid-swap me other)))

(defun drgnx-grid-focus-direction (direction)
  "Select the tile next to the selected one in DIRECTION (`drgnx-grid-neighbour'); at the grid's edge nothing changes."
  (when-let* ((w (drgnx-grid-neighbour (selected-window) direction))) (select-window w)))

(provide 'drgnx-grid-ops)
;;; drgnx-grid-ops.el ends here
