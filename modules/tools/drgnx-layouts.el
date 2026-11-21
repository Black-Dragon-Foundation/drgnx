;;; drgnx-layouts.el --- Module tools/layouts: arrangements of the grid, per project; one key cycles -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A layout is an arrangement of the grid (wb/drgnx-grid.el): which docks show, with what, and how the editor area is
;; shaped.  Each built-in layout is a TREE builder (`drgnx-layouts--build-tree'): Agent (the Explorer, the editor
;; beside the current agent's chat tile, the Agents list on the right), Editor (the Explorer and the editors, the panel
;; as it was), Zen (one editor, its text centred), Browser (the editor and a web page tile), Work (the Explorer, the
;; editor on the Work map lens, its Detail docked right), Code (the Explorer, the editor, the Agents side), Work + Code
;; (two windows: Work, and Code beside it, on a second monitor when there is one) and Review (the review screen with
;; the changes by task).  A kind no module defines yet shows as its tile's placeholder.
;; Leaving a layout remembers its arrangement for this frame; coming back restores it.  An apply is one step of the
;; layout undo stack (`drgnx-grid-push' `preset').  A layout never kills a buffer or a process and never asks.
;; The arrangements are kept per project in `$XDG_STATE_HOME/drgnx/layouts/PROJECT.eld'; Save Layout As… keeps one of
;; your own in layouts.eld.  See docs/guide/layouts.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-paths)
(require 'drgnx-config)
(require 'drgnx-file)
(require 'drgnx-wb)
(require 'drgnx-grid-tree)
(require 'drgnx-grid)
(require 'drgnx-grid-frames)

(declare-function drgnx-wb-sidebar-view "drgnx-wb")
(declare-function drgnx-grid-tree "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-apply-tree "drgnx-grid" (tree &optional frame))
(declare-function drgnx-grid-tiles "drgnx-grid" (&optional frame filter))
(declare-function drgnx-grid-full-size-p "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-full-size-toggle "drgnx-grid" (&optional window))
(declare-function drgnx-grid-forget-full-size "drgnx-grid" (&optional frame))
(declare-function drgnx-grid--next-id "drgnx-grid" (frame))
(declare-function drgnx-grid--dock-default-px "drgnx-grid" (dock kinds frame))
(declare-function drgnx-grid-snapshot "drgnx-grid-frames" (&optional why))
(declare-function drgnx-grid-restore "drgnx-grid-frames" (snap))
(declare-function drgnx-grid-push "drgnx-grid-frames" (why &optional frame tree))
(declare-function drgnx-grid-frame-id "drgnx-grid-frames" (frame))
(declare-function drgnx-grid--snapshot-frame-p "drgnx-grid-frames" (frame))
(declare-function drgnx-grid--frame-snapshot-p "drgnx-grid-frames" (snap))
(declare-function drgnx-grid--frame-snapshot-tree "drgnx-grid-frames" (frame))
(declare-function drgnx-pixels-scale "drgnx-pixels" (&optional frame))
(declare-function drgnx-pane-define-kind "drgnx-panes")
(declare-function drgnx-pane-undefine-kind "drgnx-panes" (kind))
(declare-function drgnx-notify "drgnx-notice")
(declare-function drgnx-persist--visit "drgnx-persist" (file))
(declare-function drgnx-persist--grid-from-v2 "drgnx-persist" (state))
(declare-function drgnx-replace--bar-clear "drgnx-replace")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-panel-list-last-active "drgnx-agent-panel-list")
(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-work-space-workspace "drgnx-work-space" (&optional frame))
(declare-function drgnx-work-map-buffers "drgnx-work-map")
(declare-function drgnx-frame-role "drgnx-frames" (frame))
(defvar drgnx-wb--areas)

(defcustom drgnx-layouts-zen-width 100
  "Text width in the Zen layout, in columns."
  :type 'integer :group 'drgnx)

(defvar drgnx-layouts
  '((agent :left explorer :right agents :panel nil :editor editor+agent)
    (editor :left explorer :right nil :panel keep :editor one)
    (zen :left nil :right nil :panel nil :editor zen)
    (browser :left nil :right nil :panel nil :editor editor+browser)
    (work :left explorer :right work-detail :panel nil :editor work)
    (code :left explorer :right agents-side :panel nil :editor one)
    (work-and-code :frames (work code))
    (review :left nil :right nil :panel nil :editor review))
  "The built-in layouts, in the order Next Layout cycles them: NAME → (:left VIEW :right KIND :panel KIND :editor
SHAPE), or (:frames (LAYOUT LAYOUT)) for a layout of two windows.  VIEW is the side bar's view; KIND a right or
bottom area tab or a pane kind (one no module defines yet shows its placeholder); nil hides the dock and `keep'
leaves it as it is; SHAPE is a key of `drgnx-layouts-shapes'.  Your own layouts (layouts.eld) follow them.")

(defvar drgnx-layouts-returning '(zen)
  "The layouts that keep the arrangement they were entered from (frame parameter `drgnx-layouts-zen-return'):
leaving one for a layout not used yet builds that layout from it, and `drgnx-layouts-back' with no layout picked
before puts it back as it was.")

(defvar drgnx-layouts-shapes
  '((one . drgnx-layouts--one) (editor+agent . drgnx-layouts--editor+agent) (zen . drgnx-layouts--zen)
    (work . drgnx-layouts--work) (review . drgnx-layouts--review))
  "Editor shapes: SHAPE → a function of (EDITOR WIDTH HEIGHT SCALE) returning the editor area's TREE node.  EDITOR is
the editor area's node now, WIDTH and HEIGHT the frame pixels it gets, SCALE the frame's (`drgnx-grid-tree-join').  A
shape not registered here (the Browser layout's `editor+browser' until the browser module adds it) is `one'.")

;;;; Layouts: built in and your own

(defun drgnx-layouts-current (&optional frame)
  "The layout FRAME shows: the last one applied, or nil before any (that arrangement has no name)."
  (frame-parameter frame 'drgnx-layouts-current))

(defun drgnx-layouts--name-p (x)
  "Whether X can name a layout: a symbol that is not nil, t or a keyword."
  (and (symbolp x) x (not (eq x t)) (not (keywordp x))))

(defun drgnx-layouts--define-config ()
  "Define the config file `layouts' (layouts.eld).  The module's setup calls this first; teardown undefines it."
  (drgnx-config-define
   'layouts
   :file "layouts.eld" :shape 'alist :version 1 :reload 'mtime :last-good t :default nil
   :schema '(alist (pred drgnx-layouts--name-p "a layout name: a symbol, not nil, t or a keyword")
                   (plist (:left (or symbol null) "The left dock's view")
                          (:right (or symbol null) "The right area's tab")
                          (:panel (or symbol null) "The panel's tab")
                          (:editor symbol "The editor area's shape")
                          (:tree any "The grid (`drgnx-grid-tree')")
                          (:windows any "The editor area's window state (before the grid: read through the migration)")
                          (:px (plist (:left (or natnum null)) (:panel (or natnum null)) (:right (or natnum null)))
                               "Sizes in pixels")))
   :header ";; drgnx: your layouts, written by View: Save Layout As… (docs/guide/layouts.md)\n"
   :doc "Your own layouts; the built-in ones are not stored."))

(defun drgnx-layouts--user ()
  "Your layouts from layouts.eld: NAME → plist, without the entries named like a built-in layout (those stay in
the file).  A file with a mistake gives its last good copy; with the module off, no layouts."
  (and (drgnx-config-defined-p 'layouts)
       (seq-remove (lambda (e) (assq (car e) drgnx-layouts)) (drgnx-config-get 'layouts))))

(defun drgnx-layouts--all () (append drgnx-layouts (drgnx-layouts--user)))

(defun drgnx-layouts-names ()
  "Every layout's name, the built-in ones first: the order Next Layout cycles."
  (mapcar #'car (drgnx-layouts--all)))

;;;; Trees

(defun drgnx-layouts--leaves (tree kind)
  "TREE's leaves of KIND (`editor' or `tile')."
  (seq-filter (lambda (l) (eq (car l) kind)) (drgnx-grid-tree-leaves tree)))

(defun drgnx-layouts--editor-area (tree)
  "TREE's editor area, a copy: the node that holds every editor leaf and nothing else, else its editor leaves side by
side; a frame with no editor gets a new one."
  (let* ((editors (drgnx-layouts--leaves tree 'editor)) (n (length editors)))
    (copy-tree
     (or (and editors
              (cl-labels ((find (node)
                            (let ((leaves (drgnx-grid-tree-leaves node)))
                              (cond ((and (= (length leaves) n) (cl-every (lambda (l) (eq (car l) 'editor)) leaves)) node)
                                    ((memq (car node) '(row col)) (seq-some #'find (nthcdr 5 node)))))))
                (find tree)))
         (if (cdr editors)
             (append (list 'row :px nil :share nil)
                     (mapcar (lambda (e) (let ((e (copy-tree e))) (setf (nth 2 e) 1 (nth 4 e) (/ 1.0 n)) e)) editors))
           (or (car editors) (list 'editor :px nil :share nil :id (drgnx-grid--next-id (selected-frame)) :tabs nil :shown nil)))))))

(defun drgnx-layouts--tile (kind frame &optional dock state)
  "A new tool tile leaf showing KIND on FRAME, docked to DOCK, with STATE."
  (list 'tile :px nil :share nil :id (drgnx-grid--next-id frame) :kinds (list kind) :shown kind :dock dock :state state))

(defun drgnx-layouts--beside (editor kinds width scale)
  "EDITOR with a tool tile of each of KINDS to its right, in equal parts of WIDTH."
  (drgnx-grid-tree-join 'row (cons editor (mapcar (lambda (k) (drgnx-layouts--tile k (selected-frame))) kinds))
                        (make-list (1+ (length kinds)) nil) width scale))

;;;; Editor shapes

(defun drgnx-layouts--one (editor _width _height _scale)
  "The editor area as it is."
  editor)

(defun drgnx-layouts--editor+agent (editor width _height scale)
  "EDITOR with the current agent's chat tile (kind `agent') to its right."
  (drgnx-layouts--beside editor '(agent) width scale))

(defun drgnx-layouts--zen (editor _width _height _scale)
  "The editor used last alone (the others' tabs go to it)."
  (let ((id (window-parameter (drgnx-wb-editor-window) 'drgnx-tile-id)) (leaves (drgnx-layouts--leaves editor 'editor)))
    (copy-tree (or (seq-find (lambda (l) (eql (plist-get (cdr l) :id) id)) leaves) (car leaves)))))

(defun drgnx-layouts--work (editor _width _height _scale)
  "EDITOR with the editor used last on the newest Work map lens, when there is one."
  (when-let* (((fboundp 'drgnx-work-map-buffers)) (map (car (drgnx-work-map-buffers)))
              (id (window-parameter (drgnx-wb-editor-window) 'drgnx-tile-id))
              (leaf (or (seq-find (lambda (l) (eql (plist-get (cdr l) :id) id)) (drgnx-layouts--leaves editor 'editor))
                        (car (drgnx-layouts--leaves editor 'editor)))))
    (plist-put (cdr leaf) :shown (buffer-name map))
    (plist-put (cdr leaf) :tabs (cons (buffer-name map) (remove (buffer-name map) (plist-get (cdr leaf) :tabs)))))
  editor)

(defun drgnx-layouts--review (editor width _height scale)
  "EDITOR with the review screen and the changes by task to its right."
  (drgnx-layouts--beside editor '(review-screen changes-by-task) width scale))

(defun drgnx-layouts--registry-put (registry key value)
  "Set REGISTRY (a symbol whose value is an alist) so KEY maps to VALUE, or has no entry when VALUE is nil.
The alist is rebuilt, never changed in place: the built-ins are quoted constants, and a test's
`copy-sequence' of the registry shares its cells."
  (set registry (let ((rest (seq-remove (lambda (e) (eq (car-safe e) key)) (symbol-value registry))))
                  (if value (cons (cons key value) rest) rest))))

(defun drgnx-layouts-define-shape (shape fn)
  "Teach the layouts the editor SHAPE: FN, a function of (EDITOR WIDTH HEIGHT SCALE) returning the editor area's
node (`drgnx-layouts-shapes').  Returns SHAPE.  In a module's setup the registration is undone with the module (the
entry that was there before comes back, unless someone has set another since); the layouts that name SHAPE keep it
and arrange as `one' while it is gone."
  (let ((previous (alist-get shape drgnx-layouts-shapes)))
    (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape fn)
    (drgnx-modules-push-undo
     (format "layout shape %s" shape)
     (lambda ()
       (when (eq (alist-get shape drgnx-layouts-shapes) fn)
         (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape previous)))))
  shape)

(defun drgnx-layouts-undefine-shape (shape)
  "Remove the editor SHAPE; a layout that names it arranges as `one' from now on.  Layouts are not touched."
  (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape nil)
  nil)

;;;; Panes: tiles a layout fills

(defun drgnx-layouts-define-pane (kind filler &optional title)
  "Teach the layouts a pane of KIND, a tool tile homed right whose content FILLER (a function of the window) puts in
it: `drgnx-pane-define-kind' with `:fill'.  TITLE defaults to KIND capitalized.  Its tiles already shown (a restart
before the kind's module set up) fill in place.  From a module's setup, the kind goes with the module."
  (drgnx-pane-define-kind kind :title (or title (capitalize (symbol-name kind))) :home 'right :fill filler))

(defun drgnx-layouts-undefine-pane (kind)
  "Forget the pane KIND: its tiles show their placeholder until it is defined again."
  (when (drgnx-pane-undefine-kind kind)
    (drgnx-pane--call-optional :undefined kind)))

(defun drgnx-layouts-pane-window (kind)
  "The tile of pane KIND (`drgnx-layouts-define-pane'), made beside the editor and filled when none shows (a pane is a
tile of its own, never the right dock's tab).  Without the grid: `drgnx-pane-show'.  The selected window stays."
  (if (not (drgnx-grid-on-p)) (drgnx-pane-show kind)
    (or (drgnx-grid--tile-of kind (selected-frame))
        (let ((editor (drgnx-wb-editor-window)))
          (unless (drgnx-grid-room-p editor 'right) (user-error "No room there"))
          (save-selected-window (drgnx-grid--new-tile editor 'right (list kind)))))))

(defun drgnx-layouts--current-agent ()
  "The running agent session that acted last (the newest on a tie), or nil."
  (when (fboundp 'drgnx-agents-sessions)
    (let ((at (lambda (s) (or (and (fboundp 'drgnx-agent-panel-list-last-active) (drgnx-agent-panel-list-last-active s)) 0))))
      (car (sort (seq-remove (lambda (s) (eq (drgnx-agent-session-status s) 'exited)) (drgnx-agents-sessions))
                 (lambda (a b) (> (funcall at a) (funcall at b))))))))

(defun drgnx-layouts--agent-buffer ()
  "The current agent's panel, else a buffer that says how to start one."
  (if-let* ((s (drgnx-layouts--current-agent)) ((fboundp 'drgnx-agent-panel-buffer)) (id (drgnx-agent-session-remote s)))
      (drgnx-agent-panel-buffer id)
    (with-current-buffer (get-buffer-create "*drgnx: no agent*")
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "No agent yet — Agents: New Agent Session… starts one here.\n"))
      (current-buffer))))

(defun drgnx-layouts--fill-agent (pane)
  "Show the current agent's chat (else the hint) in PANE."
  (set-window-buffer pane (drgnx-layouts--agent-buffer)))

;;;; Building a layout's tree

(defun drgnx-layouts--px (def key)
  "Layout DEF's size for KEY (:left, :panel, :right) in frame pixels: a built-in's `(logical N)' scaled, else N."
  (let ((px (plist-get (plist-get def :px) key)))
    (if (eq (car-safe px) 'logical) (drgnx-px (cadr px)) (and (natnump px) px))))

(defun drgnx-layouts--dock (def key cur frame)
  "The dock KEY (:left, :panel or :right) layout DEF asks for, as (NODE . PX) in FRAME's pixels, or nil for none.
`keep' takes the dock CUR (the tree now) has.  A size DEF gives is noted as intent `:by layout' (a size you chose
stays)."
  (let* ((v (plist-get def key)) (dock (pcase key (:left 'left) (:panel 'bottom) (:right 'right)))
         (area (pcase key (:panel 'panel) (:right 'right)))
         (px (drgnx-layouts--px def key)))
    (when px (drgnx-state-note-intent frame :sizes (if (eq key :panel) 'panel dock) px :by 'layout))
    (cond
     ((eq v 'keep)
      (when-let* ((leaf (seq-find (lambda (l) (eq (plist-get (cdr l) :dock) dock)) (drgnx-layouts--leaves cur 'tile))))
        (cons (copy-tree leaf) (drgnx-grid-tree-from-logical (plist-get (cdr leaf) :px) (drgnx-pixels-scale frame)))))
     ((null v) nil)
     (t
      (let* ((kinds (if (eq key :left) '(side-bar) (list v)))
             (node (cond ((eq key :left)
                          (drgnx-layouts--tile 'side-bar frame 'left (and (drgnx-wb--view-defined-p v) (list :view v))))
                         ((assq v (plist-get (alist-get area drgnx-wb--areas) :tabs))
                          (drgnx-layouts--tile v frame dock (list :area area)))
                         (t (drgnx-layouts--tile v frame dock)))))
        (cons node (or (plist-get (drgnx-state-intent frame :sizes (if (eq key :panel) 'panel dock)) :px)
                       (drgnx-grid--dock-default-px dock kinds frame))))))))

(defun drgnx-layouts--build-tree (def cur frame)
  "FRAME's TREE for layout DEF, built from CUR (its tree now, or the arrangement Zen was entered from): the left
dock, the editor area shaped by DEF's :editor over the panel, the right dock.  A user layout's own :tree is used as
it is, an older one's window state through the migration of format 2."
  (cond
   ((plist-get def :tree) (copy-tree (plist-get def :tree)))
   ((plist-get def :windows)
    (require 'drgnx-persist)
    (let ((side (lambda (key prop) (let ((v (plist-get def key)))
                                     (list :shown (and v t) prop v :px (plist-get (plist-get def :px) key))))))
      (drgnx-persist--grid-from-v2 (list :left (funcall side :left :view) :panel (funcall side :panel :tab)
                                         :right (funcall side :right :tab) :main (plist-get def :windows)))))
   (t
    (let* ((fw (frame-pixel-width frame)) (fh (frame-pixel-height frame)) (scale (drgnx-pixels-scale frame))
           (left (drgnx-layouts--dock def :left cur frame))
           (panel (drgnx-layouts--dock def :panel cur frame))
           (right (drgnx-layouts--dock def :right cur frame))
           (fw (max 1 (min fw (- fw (or (cdr left) 0) (or (cdr right) 0)))))
           (shape (or (alist-get (plist-get def :editor) drgnx-layouts-shapes) #'drgnx-layouts--one))
           (area (funcall shape (drgnx-layouts--editor-area cur) fw (- fh (or (cdr panel) 0)) scale))
           (center (if panel (drgnx-grid-tree-join 'col (list area (car panel)) (list nil (cdr panel)) fh scale) area))
           (row (delq nil (list left (cons center nil) right))))
      (drgnx-grid-tree-join 'row (mapcar #'car row) (mapcar #'cdr row) (frame-pixel-width frame) scale)))))

;;;; Remembered arrangements

(defun drgnx-layouts--frame-part (frame)
  "FRAME's arrangement: (:tree TREE :full ID), its tree and the tile it shows full size."
  (list :tree (if (fboundp 'drgnx-grid--frame-snapshot-tree) (drgnx-grid--frame-snapshot-tree frame) (drgnx-grid-tree frame))
        :full (car (drgnx-grid-full-size-p frame))))

(defun drgnx-layouts--part-p (part)
  "Non-nil when PART is an arrangement (`drgnx-layouts--frame-part') that can be put back."
  (and (drgnx-grid-tree--plist-p part) (drgnx-grid-valid-tree-p (plist-get part :tree))
       (or (null (plist-get part :full)) (integerp (plist-get part :full)))))

(defun drgnx-layouts--remember (name part)
  (let ((states (copy-alist (frame-parameter nil 'drgnx-layouts-state))))
    (setf (alist-get name states) part)
    (set-frame-parameter nil 'drgnx-layouts-state states)))

(defun drgnx-layouts--visit (tree)
  "Visit the files TREE's editors show or hold (at most 50 a tile), without asking anything: an arrangement read
from a file names files a new Emacs has not opened."
  (dolist (leaf (drgnx-layouts--leaves tree 'editor))
    (let ((p (cdr leaf)))
      (dolist (f (cons (plist-get p :shown) (seq-take (plist-get p :tabs) 50)))
        (when (and (stringp f) (file-name-absolute-p f) (fboundp 'drgnx-persist--visit)) (drgnx-persist--visit f))))))

(defun drgnx-layouts--put (frame part)
  "Arrange FRAME as PART (`drgnx-layouts--frame-part'): through the layout snapshot (`drgnx-grid-restore') when FRAME
takes part in one, the other windows as they are; else its grid alone."
  (drgnx-layouts--visit (plist-get part :tree))
  (if (and (fboundp 'drgnx-grid--snapshot-frame-p) (drgnx-grid--snapshot-frame-p frame))
      (let* ((snap (drgnx-grid-snapshot 'preset)) (id (drgnx-grid-frame-id frame)))
        (dolist (s (plist-get snap :frames))
          (when (eql (plist-get s :id) id)
            (plist-put s :tree (plist-get part :tree)) (plist-put s :full (plist-get part :full))))
        (drgnx-grid-restore snap))
    (drgnx-grid-forget-full-size frame)
    (drgnx-grid-apply-tree (plist-get part :tree) frame))
  ;; an editor the arrangement kept (the same window) shows its tabs and file as they were left, not as Zen or a
  ;; restart left them
  (dolist (leaf (drgnx-layouts--leaves (plist-get part :tree) 'editor))
    (let* ((p (cdr leaf))
           (w (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) (plist-get p :id))) (drgnx-grid-tiles frame 'editor)))
           (tabs (delq nil (mapcar #'drgnx-grid--named-buffer (plist-get p :tabs))))
           (shown (drgnx-grid--named-buffer (plist-get p :shown))))
      (when w
        (when tabs (set-window-parameter w 'drgnx-tabs tabs))
        (when (and shown (not (eq shown (window-buffer w))))
          (set-window-buffer w shown)
          (when (plist-get p :start) (set-window-start w (plist-get p :start) t))
          (when (plist-get p :point) (set-window-point w (plist-get p :point))))))))

;;;; Two windows: Work + Code

(defun drgnx-layouts--second-monitor ()
  "The work area (X Y W H) of the second monitor, or nil with one."
  (when-let* ((m (cadr (display-monitor-attributes-list)))) (alist-get 'workarea m)))

(defvar drgnx-grid--frame-ids)

(defun drgnx-layouts--apply-frames (names)
  "Arrange the selected frame as layout (car NAMES) and a second window as (cadr NAMES): the window this made before
when it is still open, else a new one, on the second monitor when there is one.  The other windows stay as they are."
  (let* ((main (selected-frame))
         (other (seq-find (lambda (f) (and (frame-live-p f) (not (eq f main)) (frame-parameter f 'drgnx-layouts-second)))
                          (frame-list)))
         (other-id (if other (drgnx-grid-frame-id other) (setq drgnx-grid--frame-ids (1+ drgnx-grid--frame-ids))))
         (main-tree (drgnx-layouts--build-tree (alist-get (car names) (drgnx-layouts--all))
                                               (drgnx-grid--frame-snapshot-tree main) main))
         (other-tree (drgnx-layouts--build-tree (alist-get (cadr names) (drgnx-layouts--all))
                                                (if other (drgnx-grid--frame-snapshot-tree other)
                                                  (list 'editor :px nil :share nil :id 1 :tabs nil :shown "*scratch*"))
                                                main))
         (geometry (drgnx-layouts--second-monitor))
         (frames (list (list :id (drgnx-grid-frame-id main) :role (if (eq (drgnx-frame-role main) 'main) 'main 'aux)
                             :tree main-tree)
                       (append (list :id other-id :role 'aux :tree other-tree) (and geometry (list :geometry geometry))))))
    (dolist (s (plist-get (drgnx-grid-snapshot 'preset) :frames))
      (unless (memql (plist-get s :id) (list (drgnx-grid-frame-id main) other-id))
        (setq frames (append frames (list s)))))
    ;; one main frame: the workbench's (another window applying this is an aux one), else this one
    (unless (seq-find (lambda (s) (eq (plist-get s :role) 'main)) frames)
      (setcar frames (plist-put (copy-sequence (car frames)) :role 'main)))
    (drgnx-layouts--visit main-tree)
    (drgnx-grid-restore (list :at (float-time) :why 'preset :frames frames))
    (when-let* ((f (seq-find (lambda (f) (eql (drgnx-grid-frame-id f) other-id)) (frame-list))))
      (set-frame-parameter f 'drgnx-layouts-second t))
    (select-frame main)))

;;;; Apply

(defun drgnx-layouts--close-bars ()
  "Close this frame's find bars (windows of role `bar', which tools/replace defines): an arrangement must not
keep their windows."
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (eq (drgnx-state-window-role w) 'bar))
      (when (fboundp 'drgnx-replace--bar-clear) (with-current-buffer (window-buffer w) (drgnx-replace--bar-clear)))
      (ignore-errors (delete-window w)))))

(defun drgnx-layouts--centre (frame)
  "Margins on FRAME's editor windows that leave `drgnx-layouts-zen-width' columns of text in the middle."
  (dolist (w (window-list frame 'nomini))
    (when (drgnx-signal-editor-window-p w)
      (let* ((m (window-margins w))
             (width (+ (window-body-width w) (or (car m) 0) (or (cdr m) 0)))
             (side (max 0 (/ (- width drgnx-layouts-zen-width) 2))))
        (set-window-margins w side side)))))

(defun drgnx-layouts--zen-resize (frame)
  "While FRAME shows Zen, centre its text again (on `window-size-change-functions')."
  (when (eq (frame-parameter frame 'drgnx-layouts-current) 'zen)
    (drgnx-layouts--centre frame)))

(defun drgnx-layouts--zen-margins (from to)
  "Going FROM a layout TO another: centre the text entering Zen, clear the margins leaving it."
  (cond ((eq to 'zen)
         (drgnx-layouts--centre nil)
         (add-hook 'window-size-change-functions #'drgnx-layouts--zen-resize))
        ((eq from 'zen)
         (dolist (w (window-list nil 'nomini))
           (when (drgnx-signal-editor-window-p w) (set-window-margins w 0 0)))
         (unless (seq-some (lambda (f) (eq (frame-parameter f 'drgnx-layouts-current) 'zen)) (frame-list))
           (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)))))

(defun drgnx-layouts-apply (name &optional fresh)
  "Arrange the selected frame as layout NAME, one step of the layout undo stack (`drgnx-grid-push' `preset').
The arrangement being left is remembered for its layout (frame parameter `drgnx-layouts-state', and the project's
store); NAME's remembered arrangement comes back, or (also with FRESH) NAME's definition builds one.  No buffer or
process is killed and nothing is asked.  Entering Zen (or another of `drgnx-layouts-returning') keeps the
arrangement it came from (frame parameter `drgnx-layouts-zen-return'): leaving it for a layout not used yet builds
that layout from it, and NAME nil (leaving it when no layout was picked before) puts it back as it was."
  (drgnx-layouts--load-project)
  (let* ((frame (selected-frame))
         (from (drgnx-layouts-current))
         (back (and (memq from drgnx-layouts-returning) (not (eq name from))
                    (frame-parameter nil 'drgnx-layouts-zen-return)))
         (def (cond (name (or (alist-get name (drgnx-layouts--all)) (user-error "No layout named %s" name)))
                    (back nil)
                    (t (user-error "No layout named")))))
    (drgnx-layouts--close-bars)
    (let ((part (drgnx-layouts--frame-part frame)))
      (when from (drgnx-layouts--remember from part))
      (when (and (memq name drgnx-layouts-returning) (not (memq from drgnx-layouts-returning)))
        (set-frame-parameter nil 'drgnx-layouts-zen-return part))
      (drgnx-grid-push 'preset)
      (if (plist-get def :frames)
          (drgnx-layouts--apply-frames (plist-get def :frames))
        (let ((memory (and (not fresh) (if name (alist-get name (frame-parameter nil 'drgnx-layouts-state)) back))))
          (drgnx-layouts--put frame
                              (if (drgnx-layouts--part-p memory) memory
                                (list :tree (drgnx-layouts--build-tree
                                             def (plist-get (if (drgnx-layouts--part-p back) back part) :tree) frame)))))))
    (when (and (memq from drgnx-layouts-returning) (not (memq name drgnx-layouts-returning)))
      (set-frame-parameter nil 'drgnx-layouts-zen-return nil))
    (unless (or (null from) (eq from name)) (set-frame-parameter nil 'drgnx-layouts-previous from))
    (set-frame-parameter nil 'drgnx-layouts-current name)
    (drgnx-layouts--zen-margins from name)
    (unless (drgnx-signal-editor-window-p (selected-window)) (select-window (drgnx-wb-editor-window)))
    (drgnx-state-use-editor (selected-window) :by 'layout)
    (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply nil t))
    (drgnx-layouts--save-soon)
    name))

;;;; Commands

(defun drgnx-layouts-agent ()
  "Layout Agent: the Explorer, the editor beside the current agent's chat, the Agents list on the right."
  (interactive)
  (drgnx-layouts-apply 'agent))

(defun drgnx-layouts-editor ()
  "Layout Editor: the Explorer, the editors and the panel as it was; the agent docks hidden."
  (interactive)
  (drgnx-layouts-apply 'editor))

(defun drgnx-layouts-zen ()
  "Layout Zen: only the file, its text centred; again to go back to the layout before (or, when none
was picked yet, to the arrangement you had)."
  (interactive)
  (if (eq (drgnx-layouts-current) 'zen) (drgnx-layouts-back) (drgnx-layouts-apply 'zen)))

(defun drgnx-layouts-back ()
  "Leave the current layout for the one before it; when none was picked before, the arrangement it was entered
from (one of `drgnx-layouts-returning'), else Editor."
  (let ((back (frame-parameter nil 'drgnx-layouts-previous)))
    (drgnx-layouts-apply (cond ((and back (not (eq back (drgnx-layouts-current))) (memq back (drgnx-layouts-names))) back)
                               ((frame-parameter nil 'drgnx-layouts-zen-return) nil)
                               (t 'editor)))))

(defun drgnx-layouts-browser ()
  "Layout Browser: the editor and a web page beside it (the page comes with the browser module)."
  (interactive)
  (drgnx-layouts-apply 'browser))

(defun drgnx-layouts-work ()
  "Layout Work: the Explorer, the editor on the Work map lens, its Detail docked right."
  (interactive)
  (drgnx-layouts-apply 'work))

(defun drgnx-layouts-code ()
  "Layout Code: the Explorer, the editor, the Agents side on the right."
  (interactive)
  (drgnx-layouts-apply 'code))

(defun drgnx-layouts-work-and-code ()
  "Layout Work + Code: this window as Work, a second one as Code (on the second monitor when there is one)."
  (interactive)
  (drgnx-layouts-apply 'work-and-code))

(defun drgnx-layouts-review ()
  "Layout Review: the editor, the review screen and the changes by task."
  (interactive)
  (drgnx-layouts-apply 'review))

(defun drgnx-layouts-tile-reset ()
  "Reset Tiles to the Layout: build the frame's current layout again (Editor before any), every docked tile back in
its dock; the arrangement before is one step of Restore Previous Layout."
  (interactive)
  (drgnx-layouts-apply (or (drgnx-layouts-current) 'editor) t))

(defun drgnx-layouts-next ()
  "The next layout: Agent, Editor, Zen, Browser, Work, Code, Work + Code, Review, yours, and around."
  (interactive)
  (let* ((names (drgnx-layouts-names))
         (name (or (cadr (memq (drgnx-layouts-current) names)) (car names))))
    (drgnx-layouts-apply name)
    (message "Layout: %s" (capitalize (symbol-name name)))))

(defun drgnx-layouts-pick (name)
  "Switch to the layout NAME (asked, with completion)."
  (interactive (list (intern (completing-read "Layout: " (mapcar #'symbol-name (drgnx-layouts-names)) nil t))))
  (drgnx-layouts-apply name))

(defun drgnx-layouts-save (name)
  "Save the selected frame's arrangement as your layout NAME (in layouts.eld, its grid as `:tree'); you are then in
it.  NAME is a string or a symbol.  Only that entry of the file changes; a layouts.eld with a mistake is left as it
is and `drgnx-config-refused' says where the mistake is."
  (interactive (list (read-string "Save layout as: ")))
  (let ((sym (if (stringp name) (intern (string-trim name)) name)))
    (when (and (stringp name) (string-empty-p (string-trim name))) (user-error "A layout needs a name"))
    (unless (drgnx-layouts--name-p sym) (user-error "%S is not a layout name" sym))
    (when (assq sym drgnx-layouts) (user-error "%s is a built-in layout: choose another name" sym))
    (drgnx-layouts--close-bars)
    (let* ((part (drgnx-layouts--frame-part (selected-frame)))
           (def (list :editor (or (plist-get (alist-get (drgnx-layouts-current) (drgnx-layouts--all)) :editor) 'one)
                      :tree (plist-get part :tree))))
      (drgnx-config-update
       'layouts
       (lambda (data)
         (if (assq sym data)
             (mapcar (lambda (e) (if (eq (car e) sym) (cons sym def) e)) data)
           (append data (list (cons sym def))))))
      (when-let* ((from (drgnx-layouts-current)))
        (drgnx-layouts--remember from part)
        (unless (eq from sym) (set-frame-parameter nil 'drgnx-layouts-previous from)))
      (drgnx-layouts--remember sym part)
      (set-frame-parameter nil 'drgnx-layouts-current sym)
      (drgnx-layouts--save-soon)
      (message "Saved layout %s" sym)
      sym)))

(defun drgnx-layouts--define-commands ()
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((layout-agent "Layout Agent" drgnx-layouts-agent
                                 "The Explorer, the editor beside the current agent's chat, the Agents list on the right")
                   (layout-editor "Layout Editor" drgnx-layouts-editor "The Explorer, the editors and the panel; the agent docks hidden")
                   (layout-zen "Layout Zen" drgnx-layouts-zen "Only the file, centred; again to go back")
                   (layout-browser "Layout Browser" drgnx-layouts-browser "The editor and a web page beside it")
                   (layout-work "Layout Work" drgnx-layouts-work "The Explorer, the editor on the Work map, its Detail on the right")
                   (layout-code "Layout Code" drgnx-layouts-code "The Explorer, the editor, the Agents side on the right")
                   (layout-work-and-code "Layout Work + Code" drgnx-layouts-work-and-code
                                         "This window as Work, a second one as Code (on a second monitor when there is one)")
                   (layout-review "Layout Review" drgnx-layouts-review "The editor, the review screen and the changes by task")
                   (layout-next "Next Layout" drgnx-layouts-next "Agent, Editor, Zen, Browser, Work, Code, Work + Code, Review, yours, and around")
                   (layout-save "Save Layout As…" drgnx-layouts-save "This arrangement as a layout of your own")
                   (layout-pick "Layout…" drgnx-layouts-pick "Switch to a layout by name")
                   (tile-reset "Reset Tiles to the Layout" drgnx-layouts-tile-reset
                               "Build the current layout again, every docked tile back in its dock")))
    (drgnx-command-define id :category "View" :title title :command fn :doc doc :scope 'window)))

;;;; The project's store: $XDG_STATE_HOME/drgnx/layouts/PROJECT.eld

(defconst drgnx-layouts-store-version 1 "The format of a project's layouts file.")

(defvar drgnx-layouts--project-ids (make-hash-table :test #'eq :weakness 'key)
  "Frame → (DIRECTORY . PROJECT-ID): the project id last found for the directory of the frame's selected buffer.")

(defun drgnx-layouts-project-id (&optional frame)
  "The project FRAME works in, for its layouts: the workspace id when tools/work-space is on (`drgnx-work-space-
workspace', found with git, so cached per frame and directory), else \"global\"."
  (let* ((frame (or frame (selected-frame)))
         (dir (with-current-buffer (window-buffer (frame-selected-window frame)) default-directory))
         (hit (gethash frame drgnx-layouts--project-ids)))
    (if (equal (car hit) dir) (cdr hit)
      (let ((id (or (and (drgnx-module-running-p 'tools/work-space) (fboundp 'drgnx-work-space-workspace)
                         (plist-get (drgnx-work-space-workspace frame) :id))
                    "global")))
        (puthash frame (cons dir id) drgnx-layouts--project-ids)
        id))))

(defun drgnx-layouts-store-file (project)
  "PROJECT's layouts file (its id made a file name)."
  (expand-file-name (concat "layouts/" (replace-regexp-in-string "[^A-Za-z0-9_-]" "-" project) ".eld")
                    (drgnx-state-dir)))

(defun drgnx-layouts--store (frame)
  "What FRAME's project keeps: (:version :layout :previous :snapshot PART :arrangements ((NAME . PART)…) :zen-return)."
  (list :version drgnx-layouts-store-version
        :layout (frame-parameter frame 'drgnx-layouts-current)
        :previous (frame-parameter frame 'drgnx-layouts-previous)
        :snapshot (drgnx-layouts--frame-part frame)
        :arrangements (frame-parameter frame 'drgnx-layouts-state)
        :zen-return (frame-parameter frame 'drgnx-layouts-zen-return)))

(defun drgnx-layouts--write (frame)
  "Write FRAME's project store (`drgnx-layouts--store') to its project's file."
  (when-let* (((frame-live-p frame)) (project (frame-parameter frame 'drgnx-layouts-project)))
    (condition-case err
        (drgnx-file-write (drgnx-layouts-store-file project) (with-selected-frame frame (drgnx-layouts--store frame))
                          :header ";; drgnx: this project's layouts (docs/guide/layouts.md)")
      (file-error (drgnx-notify 'wb 'fail (format "The layouts of %s were not saved: %s" project
                                                  (error-message-string err))
                                :id (cons 'layouts-write project))))))

(defun drgnx-layouts--save-soon (&optional frame)
  "Write FRAME's project store 2 s after its last arrangement change."
  (let ((frame (or frame (selected-frame))))
    (when-let* ((project (frame-parameter frame 'drgnx-layouts-project)))
      (drgnx-timer-debounce (cons 'layouts-save project) 2 #'drgnx-layouts--write :args (list frame) :owner :core))))

(defun drgnx-layouts--save-all ()
  "Write every frame's project store now (on exit), the pending writes with them."
  (dolist (f (frame-list))
    (when-let* ((project (frame-parameter f 'drgnx-layouts-project)))
      (drgnx-timer-cancel (cons 'layouts-save project))
      (drgnx-layouts--write f))))

(defun drgnx-layouts--read (project)
  "PROJECT's store as read from its file, checked: nil when missing, unreadable or of another version."
  (let ((data (plist-get (drgnx-file-read (drgnx-layouts-store-file project)) :data)))
    (and (drgnx-grid-tree--plist-p data) (eql (plist-get data :version) drgnx-layouts-store-version) data)))

(defun drgnx-layouts--known (name) (and (symbolp name) name (alist-get name (drgnx-layouts--all)) name))

(defun drgnx-layouts--load-project (&optional frame)
  "When FRAME's project is not the one its layouts are from (a project opened in it, or it switched project), write
the old project's store and take the new one's: its current layout (not applied: the frame stays as it is),
previous layout and remembered arrangements.  A crafted file's arrangements that are not valid are left out."
  (let* ((frame (or frame (selected-frame))) (project (drgnx-layouts-project-id frame)))
    (unless (equal project (frame-parameter frame 'drgnx-layouts-project))
      (when (frame-parameter frame 'drgnx-layouts-project) (drgnx-layouts--save-all))
      (set-frame-parameter frame 'drgnx-layouts-project project)
      (let ((data (drgnx-layouts--read project)))
        (dolist (p '(drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-state drgnx-layouts-zen-return))
          (set-frame-parameter frame p nil))
        (when data
          (let* ((name (drgnx-layouts--known (plist-get data :layout)))
                 (arrangements
                  (and (proper-list-p (plist-get data :arrangements))
                       (delq nil (mapcar (lambda (e) (and (consp e) (drgnx-layouts--known (car e))
                                                          (drgnx-layouts--part-p (cdr e)) (cons (car e) (cdr e))))
                                         (plist-get data :arrangements))))))
            (when (and name (drgnx-layouts--part-p (plist-get data :snapshot)))
              (setf (alist-get name arrangements) (plist-get data :snapshot)))
            (set-frame-parameter frame 'drgnx-layouts-current name)
            (set-frame-parameter frame 'drgnx-layouts-previous (drgnx-layouts--known (plist-get data :previous)))
            (set-frame-parameter frame 'drgnx-layouts-state arrangements)
            (set-frame-parameter frame 'drgnx-layouts-zen-return
                                 (and (drgnx-layouts--part-p (plist-get data :zen-return)) (plist-get data :zen-return)))))))))

;;;; Survive a restart

(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)

(defun drgnx-layouts--persist-state ()
  "The selected frame's layout for `drgnx-persist-state-functions': (:layout NAME), or nothing before any layout was
applied.  The arrangements are in the project's store, written now with the workbench."
  (when-let* ((name (drgnx-layouts-current)))
    (when-let* ((project (frame-parameter nil 'drgnx-layouts-project)))
      (drgnx-timer-cancel (cons 'layouts-save project)))
    (drgnx-layouts--write (selected-frame))
    (list :layout name)))

(defun drgnx-layouts--adopt (frame)
  "After a restart, FRAME's project store comes back (its windows came back as they were): the layout saved with its
workbench is its current one, Zen's margins put back, each layout's last arrangement kept.  A layout that no longer
exists is ignored.  Never prompts."
  (when (and (frame-live-p frame) (null (frame-parameter frame 'drgnx-layouts-current)))
    (with-selected-frame frame
      (set-frame-parameter frame 'drgnx-layouts-project nil)
      (drgnx-layouts--load-project frame)
      (let ((name (drgnx-layouts--known (plist-get (frame-parameter frame 'drgnx-persist-extra) :layout))))
        (set-frame-parameter frame 'drgnx-layouts-current name)
        (when name (drgnx-layouts--zen-margins nil name)))
      (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame)))))

(defun drgnx-layouts--wire-persist ()
  "Keep the current layout in the saved workbench and take it back after a restart; write the projects' stores on
exit.  A frame restored before this ran (the module sets up at idle) is adopted now."
  (require 'drgnx-persist)
  (add-hook 'drgnx-persist-state-functions #'drgnx-layouts--persist-state)
  (add-hook 'drgnx-persist-after-restore-functions #'drgnx-layouts--adopt)
  (add-hook 'kill-emacs-hook #'drgnx-layouts--save-all)
  (mapc #'drgnx-layouts--adopt (frame-list)))

(defun drgnx-layouts--teardown ()
  "Write the projects' stores, then forget the layouts in every frame: Zen's margins and its resize hook go, and the
frame parameters of the current layout, the remembered arrangements, the previous layout, Zen's way back and the
project they are from."
  (drgnx-layouts--save-all)
  (dolist (f (frame-list))
    (when (eq (frame-parameter f 'drgnx-layouts-current) 'zen)
      (with-selected-frame f (drgnx-layouts--zen-margins 'zen nil)))
    (dolist (p '(drgnx-layouts-current drgnx-layouts-state drgnx-layouts-previous drgnx-layouts-zen-return
                                       drgnx-layouts-project))
      (set-frame-parameter f p nil)))
  (clrhash drgnx-layouts--project-ids)
  (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize))

(drgnx-module-define 'tools/layouts
                     :doc "Layouts: Agent, Editor, Zen, Browser, Work, Code, Work + Code, Review and your own; one key cycles."
                     :stage 'idle :requires '(core/workbench)
                     :teardown #'drgnx-layouts--teardown
                     :setup
                     (lambda ()
                       (require 'drgnx-area)
                       (require 'drgnx-groups)
                       (require 'drgnx-grid-frames)
                       (require 'drgnx-persist)
                       (drgnx-layouts--define-config)
                       (drgnx-layouts-define-pane 'agent #'drgnx-layouts--fill-agent "Agent")
                       (drgnx-layouts--wire-persist)
                       (drgnx-layouts--define-commands)))

(provide 'drgnx-layouts)
;;; drgnx-layouts.el ends here
