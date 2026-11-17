;;; drgnx-grid-frames.el --- The layout snapshot across frames and the layout undo stack -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A snapshot is every workbench frame's place in the layout, as data that reads back (no window, frame or buffer):
;;   (:at TIME :why WHY :frames (FRAME-SNAP...))
;;   FRAME-SNAP: (:id N :role main|aux :monitor KEY :geometry (L T W H) :shell PLIST :tree TREE :full ID-or-nil)
;; KEY is the monitor's identity (`drgnx-monitors--identity'), TREE the frame's grid (`drgnx-grid-tree'; the tree it
;; goes back to while a tile shows full size), :full that tile's id, :shell the frame's shell (its own plist, filled
;; by the tear-out task), :id the frame's own number (`drgnx-grid-frame-id', kept in a weak table, not on the frame).  Terminal frames take no part, except in
;; batch, where every frame is the initial terminal's.  `drgnx-grid-restore' puts a snapshot back; `drgnx-grid-push'
;; keeps snapshots on the layout undo stack, which Restore Previous Layout walks back.
;; See docs/develop/core.md, "The layout snapshot and the undo stack".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-grid-tree)
(require 'drgnx-frames)
(require 'drgnx-monitors)

(declare-function drgnx-grid-tree "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-apply-tree "drgnx-grid" (tree &optional frame))
(declare-function drgnx-grid-tiles "drgnx-grid" (&optional frame filter))
(declare-function drgnx-grid-full-size-p "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-full-size-toggle "drgnx-grid" (&optional window))
(declare-function drgnx-grid-forget-full-size "drgnx-grid" (&optional frame))
(declare-function drgnx-chrome-tabs "drgnx-chrome" (w))
(declare-function drgnx-chrome-apply "drgnx-chrome" (&optional frame note))
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defcustom drgnx-grid-stack-max 20
  "The most snapshots the layout undo stack keeps (Restore Previous Layout); the oldest go first."
  :type 'natnum :group 'drgnx-grid)

(defvar drgnx-grid--stack nil
  "The layout undo stack: snapshots (`drgnx-grid-snapshot'), newest first, at most `drgnx-grid-stack-max'.")

(defconst drgnx-grid-push-whys '(move tear-out preset fold-in full-size restore foreign)
  "Why a snapshot was pushed: the change it was taken before.")

;;;; Frames

(defvar drgnx-grid--frame-ids 0 "The last frame number `drgnx-grid-frame-id' gave.")

(defvar drgnx-grid--frame-id-table (make-hash-table :test #'eq :weakness 'key)
  "Each frame's number in snapshots (`drgnx-grid-frame-id'); weak, a deleted frame's entry goes with it.")

(defun drgnx-grid-frame-id (frame)
  "FRAME's own number in snapshots, given the first time it is asked (`drgnx-grid--frame-id-table')."
  (or (gethash frame drgnx-grid--frame-id-table)
      (puthash frame (setq drgnx-grid--frame-ids (1+ drgnx-grid--frame-ids)) drgnx-grid--frame-id-table)))

(defun drgnx-grid--snapshot-frame-p (frame)
  "Non-nil when FRAME takes part in snapshots: a live, visible root frame of the workbench, graphical (terminal frames
take no part) or, in batch, the initial terminal's."
  (and (frame-live-p frame) (not (frame-parent frame)) (frame-visible-p frame)
       (or (display-graphic-p frame) noninteractive)
       (not (eq (frame-parameter frame 'drgnx-frame-role) 'editor))))

(defun drgnx-grid--snapshot-frames ()
  "The frames a snapshot holds: the main one first, then the others oldest first."
  (let ((frames (seq-filter #'drgnx-grid--snapshot-frame-p (reverse (frame-list)))))
    (append (seq-filter (lambda (f) (eq (drgnx-frame-role f) 'main)) frames)
            (seq-remove (lambda (f) (eq (drgnx-frame-role f) 'main)) frames))))

(defun drgnx-grid--frame-snapshot-tree (frame)
  "FRAME's tree in a snapshot: while a tile shows full size, the tree it goes back to."
  (let ((full (drgnx-grid-full-size-p frame))) (if full (cdr full) (drgnx-grid-tree frame))))

(defun drgnx-grid--frame-snapshot (frame)
  "FRAME's part of a snapshot (FRAME-SNAP, see the Commentary)."
  (let ((mon (frame-parameter frame 'drgnx-monitor)) (pos (frame-position frame)) (full (drgnx-grid-full-size-p frame)))
    (list :id (drgnx-grid-frame-id frame)
          :role (drgnx-frame-role frame)
          :monitor (and (consp mon) (drgnx-monitors--identity mon))
          :geometry (list (car pos) (cdr pos) (frame-pixel-width frame) (frame-pixel-height frame))
          :shell (copy-tree (frame-parameter frame 'drgnx-grid-shell))
          :tree (drgnx-grid--frame-snapshot-tree frame)
          :full (car full))))

(defun drgnx-grid-snapshot (&optional why)
  "Every workbench frame's place in the layout, as data that reads back: (:at TIME :why WHY :frames (FRAME-SNAP...)).
See the Commentary."
  (list :at (float-time) :why why :frames (mapcar #'drgnx-grid--frame-snapshot (drgnx-grid--snapshot-frames))))

;;;; Restore

(defun drgnx-grid--frame-snapshot-p (snap)
  "Non-nil when SNAP is a FRAME-SNAP a restore can build from."
  (and (drgnx-grid-tree--plist-p snap)
       (memq (plist-get snap :role) '(main aux))
       (or (null (plist-get snap :id)) (natnump (plist-get snap :id)))
       (drgnx-grid-valid-tree-p (plist-get snap :tree))
       (let ((g (plist-get snap :geometry))) (or (null g) (and (proper-list-p g) (= (length g) 4) (cl-every #'integerp g))))
       (or (null (plist-get snap :full)) (integerp (plist-get snap :full)))))

(defun drgnx-grid-valid-snapshot-p (snap)
  "Non-nil when SNAP is a snapshot (`drgnx-grid-snapshot') a restore can build from: one main frame, every frame valid."
  (and (drgnx-grid-tree--plist-p snap)
       (let ((frames (plist-get snap :frames)))
         (and (proper-list-p frames) frames
              (cl-every #'drgnx-grid--frame-snapshot-p frames)
              (= 1 (seq-count (lambda (s) (eq (plist-get s :role) 'main)) frames))))))

(defun drgnx-grid--frame-by-id (id)
  (and id (seq-find (lambda (f) (and (frame-live-p f) (eql (gethash f drgnx-grid--frame-id-table) id))) (frame-list))))

(defun drgnx-grid--place-frame (frame snap)
  "Put graphical FRAME where SNAP's :geometry says (until the monitors' fold, on whatever monitor that is)."
  (when-let* (((display-graphic-p frame)) (g (plist-get snap :geometry)))
    (let ((pos (frame-position frame)))
      (unless (equal (list (car pos) (cdr pos)) (list (nth 0 g) (nth 1 g)))
        (set-frame-position frame (nth 0 g) (nth 1 g))))
    (unless (equal (list (frame-pixel-width frame) (frame-pixel-height frame)) (list (nth 2 g) (nth 3 g)))
      (set-frame-size frame (nth 2 g) (nth 3 g) t))))

(defun drgnx-grid--frame-buffers (frame)
  "The buffers FRAME's editor tiles show or hold as tabs."
  (delete-dups (mapcan (lambda (w) (append (list (window-buffer w))
                                           (seq-filter #'buffer-live-p (copy-sequence (window-parameter w 'drgnx-tabs)))))
                       (drgnx-grid-tiles frame 'editor))))

(defun drgnx-grid--fold-buffers (buffers main)
  "BUFFERS become tabs of MAIN's editor tile used last, first in its row (none is killed)."
  (when-let* ((buffers (seq-filter #'buffer-live-p buffers))
              (w (or (seq-find (lambda (w) (eq w (frame-selected-window main))) (drgnx-grid-tiles main 'editor))
                     (car (drgnx-grid-tiles main 'editor)))))
    (set-window-parameter w 'drgnx-tabs
                          (append buffers (seq-remove (lambda (b) (memq b buffers)) (window-parameter w 'drgnx-tabs))))))

(defun drgnx-grid-restore (snap)
  "Put the layout SNAP (`drgnx-grid-snapshot') back: an aux frame it has and that is gone is made again, each frame
gets its tree (`drgnx-grid-apply-tree') and place, its tile shown full size again when it was, and an aux frame SNAP
lacks is deleted, its editors' buffers becoming tabs of the main frame's editor (nothing is killed, saved or asked).
A SNAP that is not valid changes nothing and gives one notice.  Non-nil when restored."
  (if (not (drgnx-grid-valid-snapshot-p snap))
      (progn (drgnx-notify 'wb 'warn "A saved layout was not valid; nothing changed") nil)
    (let* ((selected (selected-frame))
           (main (or (seq-find (lambda (f) (eq (drgnx-frame-role f) 'main)) (drgnx-grid--snapshot-frames)) selected))
           (kept nil) (changed nil))
      (dolist (s (plist-get snap :frames))
        (let ((frame (if (eq (plist-get s :role) 'main) main
                       (or (drgnx-grid--frame-by-id (plist-get s :id))
                           (let ((f (drgnx-frames--new (get-scratch-buffer-create) nil)))
                             (when (plist-get s :id) (puthash f (plist-get s :id) drgnx-grid--frame-id-table))
                             f)))))
          (push frame kept)
          ;; a frame already as SNAP has it is left alone
          (unless (and (equal (car (drgnx-grid-full-size-p frame)) (plist-get s :full))
                       (equal (drgnx-grid--frame-snapshot-tree frame) (plist-get s :tree)))
            (push frame changed)
            (drgnx-grid-forget-full-size frame)
            (drgnx-grid-apply-tree (plist-get s :tree) frame))
          (drgnx-grid--place-frame frame s)
          (when-let* ((id (plist-get s :full)) ((not (drgnx-grid-full-size-p frame)))
                      (w (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) id)) (drgnx-grid-tiles frame))))
            (drgnx-grid-full-size-toggle w))))
      (dolist (f (drgnx-grid--snapshot-frames))
        (unless (or (memq f kept) (eq (drgnx-frame-role f) 'main))
          (drgnx-grid--fold-buffers (drgnx-grid--frame-buffers f) main)
          (push main changed)
          (delete-frame f t)))
      (when (fboundp 'drgnx-chrome-apply)
        (dolist (f (delete-dups changed)) (when (frame-live-p f) (drgnx-chrome-apply f t))))
      (select-frame (if (frame-live-p selected) selected main))
      t)))

;;;; Tear-out: Move to New Window

(declare-function drgnx-grid-tile-main "drgnx-grid-ops" (window))
(declare-function drgnx-grid--state "drgnx-grid-ops" (window))
(declare-function drgnx-grid--put "drgnx-grid-ops" (state window))
(declare-function drgnx-grid--undock "drgnx-grid-ops" (window))
(declare-function drgnx-grid--entries "drgnx-grid-ops" (window))
(declare-function drgnx-grid--delete-tile "drgnx-grid" (window))
(declare-function drgnx-grid--tile-root "drgnx-grid" (window))
(declare-function drgnx-grid--main-of "drgnx-grid" (window))
(declare-function drgnx-grid--next-id "drgnx-grid" (frame))
(declare-function drgnx-grid--note-good "drgnx-grid" (frame))
(declare-function drgnx-grid--fill-leaf "drgnx-grid" (node w frame))
(declare-function drgnx-grid--tool-tile "drgnx-grid" (w kinds frame horizontal))
(declare-function drgnx-grid--put-buffer "drgnx-grid" (window kind frame &optional buffer))
(declare-function drgnx-grid--put-row "drgnx-grid" (window))
(declare-function drgnx-grid--bring-to-front "drgnx-grid" (window kind frame &optional buffer))
(declare-function drgnx-grid-editor-tile-p "drgnx-grid" (window))
(declare-function drgnx-grid-leave-full-size "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-show "drgnx-grid" (kind))
(declare-function drgnx-chrome--close "drgnx-chrome" (w b))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab))
(defvar drgnx-wb--areas)

(defun drgnx-grid--leave-frame (me frame)
  "Tile ME leaves FRAME as a move leaves it (its space to the tile it took it from); FRAME's last editor stays, empty
\(its tabs gone, `*scratch*' shown)."
  (when (eq (drgnx-grid-tile-main (frame-selected-window frame)) me)
    (when-let* ((other (seq-find (lambda (w) (not (eq (drgnx-grid-tile-main w) me))) (drgnx-grid-tiles frame 'editor))))
      (set-frame-selected-window frame other)))
  (if (and (drgnx-grid-editor-tile-p me) (not (cdr (drgnx-grid-tiles frame 'editor))))
      (progn (set-window-parameter me 'drgnx-tabs nil)
             (set-window-buffer me (get-scratch-buffer-create)))
    (set-window-parameter me 'delete-window nil)
    (drgnx-grid--delete-tile (drgnx-grid--tile-root me)))
  (drgnx-grid--note-good frame)
  (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame t)))

(defun drgnx-grid--new-frame-done (new main)
  "NEW, a frame made by a tear-out, selected with MAIN, its one tile, selected and its rows drawn."
  (drgnx-grid--note-good new)
  (select-frame-set-input-focus new)
  (select-window main)
  (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply new t))
  new)

(defun drgnx-grid-move-to-new-frame (&optional window)
  "Move WINDOW's tile (default the selected window's) to a new window, as that window's only tile: the tile whole (a
conversation's three windows go together), with its kind, stack, buffers, start and point; an editor with its tabs.  A
docked tile is no dock's there.  It leaves its window as a move does; a window's last editor stays, empty.  The layout
before is pushed (`drgnx-grid-push' `tear-out').  Returns the new frame."
  (interactive)
  (let* ((me (drgnx-grid-tile-main (or window (selected-window)))) (frame (window-frame me)))
    (drgnx-grid-leave-full-size frame)
    (drgnx-grid-push 'tear-out)
    (let* ((editor (drgnx-grid-editor-tile-p me))
           ;; an editor goes as its window's state (buffer, tabs, start, point, parameters: as a move); a tool tile is
           ;; made again there from its stack and buffer, so its companions (a conversation's header and composer)
           ;; come with it, fitted to the new window (a whole atom's state cannot be put into a frame's only window)
           (state (and editor (drgnx-grid--state me)))
           (entries (and (not editor) (drgnx-grid--entries me)))
           (buffer (window-buffer me)) (start (window-start me)) (point (window-point me))
           (new (drgnx-frames--new (get-scratch-buffer-create) nil))
           (w (frame-first-window new)))
      (drgnx-grid--leave-frame me frame)
      (if editor
          (drgnx-grid--put state w)
        (drgnx-grid--tool-tile w entries new nil)
        (drgnx-grid--put-buffer w (car entries) new buffer)
        (set-window-start w start t)
        (set-window-point w point)
        (drgnx-grid--put-row w))
      (let ((main (drgnx-grid--main-of (frame-root-window new))))
        (set-window-parameter main 'drgnx-tile-id (drgnx-grid--next-id new))
        (drgnx-grid--undock main)
        (drgnx-grid--new-frame-done new main)))))

(defun drgnx-grid-move-tab-to-new-frame (&optional window kind)
  "Move to New Window: tab KIND of WINDOW's tile (default the selected window's shown tab: an editor's buffer, a tool
tile's front kind, a docked area's tab) to a new window.  One of several tabs goes alone (an editor's file leaves its
tabs, a kind leaves the stack), into a tile of its own there; a tile's only tab moves the tile whole
\(`drgnx-grid-move-to-new-frame').  Returns the new frame."
  (interactive)
  (let* ((me (drgnx-grid-tile-main (or window (selected-window)))) (frame (window-frame me))
         (editor (drgnx-grid-editor-tile-p me))
         (stack (window-parameter me 'drgnx-pane-stack))
         (kind (or kind (if editor (window-buffer me) (car (drgnx-grid--entries me))))))
    (cond
     ((and editor (remq kind (drgnx-chrome-tabs me)))
      (drgnx-grid-leave-full-size frame)
      (drgnx-grid-push 'tear-out)
      (drgnx-chrome--close me kind)
      (let ((new (drgnx-frames--new kind (list kind))))
        (drgnx-grid--new-frame-done new (frame-first-window new))))
     ((and (not editor) (cdr stack) (memq kind stack))
      (drgnx-grid-leave-full-size frame)
      (drgnx-grid-push 'tear-out)
      (set-window-parameter me 'drgnx-pane-stack (remq kind stack))
      (when (eq kind (car stack)) (drgnx-grid--bring-to-front me (car (remq kind stack)) frame))
      (let* ((new (drgnx-frames--new (get-scratch-buffer-create) nil)) (w (frame-first-window new)))
        (drgnx-grid--fill-leaf (list 'tile :id (drgnx-grid--next-id new) :kinds (list kind) :shown kind) w new)
        (drgnx-grid--new-frame-done new w)))
     (t
      ;; a docked area's other tab: shown first, then its tile moves
      (let ((role (window-parameter me 'drgnx-role)))
        (when (and (not editor) (not stack) role (assq role drgnx-wb--areas) (not (eq kind (car (drgnx-grid--entries me)))))
          (setq me (drgnx-grid-tile-main (drgnx-wb-area-show role kind)))))
      (drgnx-grid-move-to-new-frame me)))))

(defun drgnx-grid-tab-menu (window kind)
  "The context menu of tab KIND of WINDOW's tile (an editor's buffer, a tool tile's or docked area's kind)."
  (list 'keymap "Tab"
        (list 'move-to-new-window 'menu-item "Move to New Window"
              (lambda () (interactive) (drgnx-grid-move-tab-to-new-frame window kind)))))

(defun drgnx-grid-tab-menu-click (event)
  "A right click on a tab or a tile's grip: its context menu (`drgnx-grid-tab-menu')."
  (interactive "e")
  (let* ((posn (event-start event)) (w (posn-window posn)) (s (posn-string posn))
         (prop (lambda (p) (and s (get-text-property (cdr s) p (car s)))))
         (kind (or (funcall prop 'drgnx-buffer) (funcall prop 'drgnx-grid-kind) (cdr (funcall prop 'drgnx-tab)))))
    (when (window-live-p w)
      (let ((choice (x-popup-menu event (drgnx-grid-tab-menu w kind))))
        (when-let* ((cmd (and choice (lookup-key (drgnx-grid-tab-menu w kind) (apply #'vector choice)))))
          (call-interactively cmd))))))

;;;; The stack

(defun drgnx-grid--same-layout-p (a b)
  "Non-nil when snapshots A and B hold the same layout (their time and why aside)."
  (equal (plist-get a :frames) (plist-get b :frames)))

(defun drgnx-grid-push (why &optional frame tree)
  "Push a snapshot taken now, with WHY (one of `drgnx-grid-push-whys'), onto the layout undo stack; with FRAME and
TREE, FRAME's part holds TREE instead of its tree now (a grid that was collapsed: the tree before).  A snapshot equal to
the newest is not pushed again.  The stack keeps `drgnx-grid-stack-max'."
  (let ((snap (drgnx-grid-snapshot why)))
    (when (and frame tree)
      (let ((id (drgnx-grid-frame-id frame)))
        (dolist (s (plist-get snap :frames))
          (when (eql (plist-get s :id) id) (plist-put s :tree tree) (plist-put s :full nil)))))
    (unless (and drgnx-grid--stack (drgnx-grid--same-layout-p snap (car drgnx-grid--stack)))
      (setq drgnx-grid--stack (seq-take (cons snap drgnx-grid--stack) drgnx-grid-stack-max)))
    snap))

(defun drgnx-grid-restore-previous ()
  "Restore Previous Layout: the layout before the last change to it (a move, a preset, a tear-out, a package that
collapsed the grid…), taken off the layout undo stack.  With none, the echo area says so."
  (interactive)
  (if-let* ((snap (pop drgnx-grid--stack)))
      (drgnx-grid-restore snap)
    (message "No earlier layout")))

(provide 'drgnx-grid-frames)
;;; drgnx-grid-frames.el ends here
