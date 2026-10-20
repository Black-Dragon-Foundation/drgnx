;;; drgnx-state.el --- The workbench state store: one observed snapshot per frame -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One record per workbench frame (`gui' or `tty', `drgnx-state-frame-kind'): its kind, role, visibility, size,
;; monitor, selected window, most recently used editor window, its windows (role, pane kind, buffer, pixel edges,
;; dedication) and the pane kinds that show.  The record is a cache of Emacs's window tree with one writer, the
;; observer: it never moves a window or sets a parameter, it only looks.  Readers ask the store
;; (`drgnx-state-editor-window', `drgnx-state-pane-window', …) instead of walking windows themselves.
;;
;; The observer (`drgnx-state--observe') first compares the record with the live frame in place, building
;; nothing; only on a difference does it take the record anew.  `drgnx-state-mode' runs it from
;; `window-state-change-functions' (any change, from any source, before the frame is drawn), at the end of every
;; command, and when frames come and go.  Code that changes windows and reads the store in the same breath calls
;; `drgnx-state-sync' (or writes inside `drgnx-state-with-write'); batch tests call it too.
;;
;; Roles come from one table (`drgnx-state-define-role'); a window whose `drgnx-role' is not in it is an editor
;; window, or `side' for a package's own side window.
;;
;; What changed between two records goes out as typed events (`drgnx-state-subscribe', `drgnx-state-events'):
;; on the `now' lane inside the observation, before the frame is drawn, or on the `idle' lane, coalesced and
;; delivered by the change bus's one idle flush (`drgnx-signal--flush', which observes the selected frame first).
;; See docs/develop/core.md, "The workbench state store".

;;; Code:
(require 'cl-lib)
(require 'drgnx-frame-kind)
(require 'drgnx-modules-helpers)
(require 'drgnx-timer)                  ; the off path cancels the shared flush, `signal-flush'

(defvar drgnx-wb--areas)                ; drgnx-area.el: the areas' tabs (read, when loaded)
(defvar drgnx-pane--last)               ; drgnx-panes.el: frame → kind → the last buffer an editor kind showed

;; Shared with the change bus (`drgnx-signal.el', which loads the store): one error list, one idle flush.
(defvar drgnx-signal-errors nil "Recent subscriber errors of the store and the bus (newest first, at most 20).")
(defvar drgnx-signal-delay 0.05 "Idle seconds before the bus's flush delivers the idle lane and the buffer edges.")
(declare-function drgnx-signal--schedule "drgnx-signal")
(defvar drgnx-signal-mode)

;;;; Records

;; Vectors: the in-place check reads them on every command.  Internal: readers use the functions below.
(cl-defstruct (drgnx-state--fr (:type vector) (:constructor drgnx-state--fr-make) (:copier nil))
  "A frame's record."
  kind role visible size monitor selected editor windows panes)

(cl-defstruct (drgnx-state--win (:type vector) (:constructor drgnx-state--win-make) (:copier nil))
  "A window's record.  EDGES: pixel (LEFT TOP WIDTH HEIGHT)."
  window role kind buffer edges dedicated)

(defvar drgnx-state--frames (make-hash-table :test 'eq :weakness 'key)
  "Frame → its record, for workbench frames.  Weak on the frame; a deleted frame's record also goes in
`delete-frame-functions'.")

(defvar drgnx-state--order nil
  "The recorded frames, oldest first (the order they were first observed).  Dead frames are dropped
when a frame is added; readers skip them.")

(defvar drgnx-state--observing nil
  "Non-nil while an observation runs: a change made meanwhile is seen at the next observation, never
recursively.")

;; Events (see "Events" below)
(defvar drgnx-state--now nil
  "Alist EVENT → the functions subscribed to it on the `now' lane, in subscription order.")
(defvar drgnx-state--idle nil
  "Alist EVENT → the functions subscribed to it on the `idle' lane, in subscription order.")
(defvar drgnx-state--queue nil
  "Idle calls waiting, newest first: (FN EVENT FRAME KIND DATA), one per FN, EVENT, FRAME and KIND (the
data's `:kind'), holding the last DATA.  Bounded: subscribers × events × frames × kinds.  The bus's idle
flush (`drgnx-signal--flush') makes them.")
(defvar drgnx-state--selected-frame nil
  "The frame that was selected at the last record stored for it (`selected-changed' names it as
`:old-frame' when another frame becomes the selected one).")
(defvar drgnx-state--watching nil
  "Non-nil while the mode's hooks observe (or the mode comes on): only then is the selected frame the
user's, so only then is a frame switch seen.  A sync or write may run inside `with-selected-frame'.")

;;;; Roles

(defvar drgnx-state--roles nil
  "Alist ROLE → (:chrome C): every non-editor role, C one of `drgnx-state--chromes' (what the chrome
draws for its windows: `dock', `area', `lane' or nothing).")

(defconst drgnx-state--chromes '(dock area lane nil))

(defun drgnx-state--put-role (role entry)
  "Make ENTRY, (ROLE :chrome C), ROLE's entry in the role table, in its place; ENTRY nil removes ROLE."
  (let ((old (assq role drgnx-state--roles)))
    (setq drgnx-state--roles
          (cond ((null entry) (remq old drgnx-state--roles))
                (old (mapcar (lambda (e) (if (eq e old) entry e)) drgnx-state--roles))
                (t (append drgnx-state--roles (list entry)))))))

(cl-defun drgnx-state-define-role (role &key chrome)
  "Define ROLE, a non-editor window role (the value of the `drgnx-role' window parameter); return ROLE.
CHROME, what the chrome draws for its windows, is one of `dock', `area', `lane' or nil.  Re-defining
replaces.  Called from a module's setup, the definition claims ROLE and records its undo \"state role
ROLE\": the previous definition put back, or ROLE removed — only while ROLE is still the one defined
here.  Two modules defining the same ROLE may be torn down in either order (`drgnx-module--claim')."
  (unless (and role (symbolp role) (not (memq role '(t editor))))
    (error "drgnx-state-define-role: %S is not a role" role))
  (unless (memq chrome drgnx-state--chromes)
    (error "drgnx-state-define-role %s: :chrome must be one of %S, not %S" role drgnx-state--chromes chrome))
  (let ((old (assq role drgnx-state--roles))
        (entry (list role :chrome chrome)))
    (drgnx-state--put-role role entry)
    (when (drgnx-modules--recording-p)
      (let* ((target (list 'state-role role))
             (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "state role %s" role)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (eq (assq role drgnx-state--roles) entry))
            (lambda (prev) (drgnx-state--put-role role prev)))))))
    role))

(defun drgnx-state-undefine-role (role)
  "Remove ROLE from the role table: its windows read as editor (or side) windows from the next
observation.  Non-nil if ROLE was defined."
  (when (assq role drgnx-state--roles)
    (drgnx-state--put-role role nil)
    t))

(defun drgnx-state-role-chrome (role)
  "What the chrome draws for ROLE's windows: `dock', `area', `lane' or nil (also for an unknown role)."
  (plist-get (cdr (assq role drgnx-state--roles)) :chrome))

;; The built-in roles belong to core (defined at load: never undone).
(dolist (r '((dock . dock) (panel . area) (right . area) (popup . lane)))
  (drgnx-state-define-role (car r) :chrome (cdr r)))

(defun drgnx-state--classify (window)
  "WINDOW's role, live: a popup lane (a `drgnx-popup' parameter, also the panel a popup borrowed) is
`popup'; else a `drgnx-role' in the role table is that role; else a side window is `side'; else
`editor'.  Nil for the minibuffer."
  (cond ((window-minibuffer-p window) nil)
        ((window-parameter window 'drgnx-popup) 'popup)
        ((let ((role (window-parameter window 'drgnx-role)))
           (and role (assq role drgnx-state--roles) role)))
        ((window-parameter window 'window-side) 'side)
        (t 'editor)))

;;;; Taking a record

(defun drgnx-state--area-front (area frame)
  "The tab AREA shows on FRAME, as `drgnx-wb-area-tab' says for the selected frame."
  (or (plist-get (alist-get area (frame-parameter frame 'drgnx-wb-areas)) :tab)
      (and (boundp 'drgnx-wb--areas) (car (car (plist-get (alist-get area drgnx-wb--areas) :tabs))))))

(defun drgnx-state--editor-kind (window frame)
  "The editor-home pane kind whose last buffer on FRAME WINDOW shows, or nil (`drgnx-pane--last')."
  (and (boundp 'drgnx-pane--last) (hash-table-p drgnx-pane--last)
       (car (rassq (window-buffer window) (gethash frame drgnx-pane--last)))))

(defun drgnx-state--kind (window role frame)
  "The pane kind WINDOW (of ROLE, on FRAME) shows, or nil.
A dock window: its section.  An area: its front tab.  An editor window: its layouts pane, or the
editor-home kind whose last buffer it shows."
  (pcase (drgnx-state-role-chrome role)
    ('dock (window-parameter window 'drgnx-section))
    ('area (drgnx-state--area-front role frame))
    (_ (and (eq role 'editor)
            (or (window-parameter window 'drgnx-layouts-pane) (drgnx-state--editor-kind window frame))))))

(defun drgnx-state--mru-editor (selected records previous)
  "The MRU editor window among RECORDS: SELECTED when it is an editor window; else PREVIOUS (the
frame's last one) while it is still an editor window there; else the one with the highest
`window-use-time'; else nil."
  (let ((sel nil) (prev nil) (best nil) (best-time -1))
    (dolist (r records)
      (when (eq (drgnx-state--win-role r) 'editor)
        (let ((w (drgnx-state--win-window r)))
          (cond ((eq w selected) (setq sel w))
                ((eq w previous) (setq prev w)))
          (let ((time (window-use-time w)))
            (when (> time best-time) (setq best w best-time time))))))
    (or sel prev best)))

(defun drgnx-state--note-frame (frame)
  "Append FRAME to `drgnx-state--order', dropping dead frames."
  (let ((live nil))
    (dolist (f drgnx-state--order) (when (frame-live-p f) (push f live)))
    (setq drgnx-state--order (nreverse (cons frame live)))))

(defun drgnx-state--rebuild (frame old)
  "Take FRAME's record anew and store it; return it.  OLD: the record it replaces, or nil."
  (let ((records nil) (panes nil))
    (dolist (w (window-list frame 'nomini (frame-first-window frame)))
      (let* ((role (drgnx-state--classify w))
             (kind (drgnx-state--kind w role frame)))
        (push (drgnx-state--win-make :window w :role role :kind kind :buffer (window-buffer w)
                                     :edges (list (window-pixel-left w) (window-pixel-top w)
                                                  (window-pixel-width w) (window-pixel-height w))
                                     :dedicated (window-dedicated-p w))
              records)
        (when (and kind (not (assq kind panes))) (push (cons kind w) panes))))
    (setq records (nreverse records))
    (let* ((selected (frame-selected-window frame))
           (rec (drgnx-state--fr-make
                 :kind (drgnx-state-frame-kind frame)
                 :role (frame-parameter frame 'drgnx-frame-role)
                 :visible (frame-visible-p frame)
                 :size (list (frame-text-cols frame) (frame-text-lines frame)
                             (frame-pixel-width frame) (frame-pixel-height frame))
                 :monitor (frame-parameter frame 'drgnx-monitor)
                 :selected selected
                 :editor (drgnx-state--mru-editor selected records (and old (drgnx-state--fr-editor old)))
                 :windows records
                 :panes (nreverse panes))))
      (drgnx-state--put frame old rec))))

(defun drgnx-state--put (frame old new)
  "Store NEW as FRAME's record in place of OLD (nil: FRAME's first); return NEW.
The one place a record is replaced — by an observation (`drgnx-state--rebuild') or a write
\(`drgnx-state-use-editor') — so what changed between OLD and NEW is found here and emitted
\(`drgnx-state--diff'), after NEW is stored: a `now' subscriber that writes (`drgnx-state-use-editor')
replaces NEW, not OLD.  Records are never changed in place."
  (unless old (drgnx-state--note-frame frame))
  (puthash frame new drgnx-state--frames)
  (let* ((prev drgnx-state--selected-frame)
         (switched (and drgnx-state--watching (eq frame (selected-frame)) (not (eq frame prev)))))
    (when switched (setq drgnx-state--selected-frame frame))
    (when (or drgnx-state--now drgnx-state--idle)
      (drgnx-state--diff frame old new switched prev)))
  new)

;;;; The in-place check: compares, builds nothing

(defun drgnx-state--same-windows-p (frame records)
  "Non-nil if FRAME's windows, in order, are those of RECORDS, each with the same buffer, role, edges,
dedication and pane kind.  The kind as far as it can be told without allocating: a dock window's
`drgnx-section', an editor window's `drgnx-layouts-pane' or editor kind (`drgnx-pane--last').  An area's
front tab is not compared: it is a frame parameter (`frame-parameter' copies them all), and a tab switch
changes the area's buffer anyway.  Walks the windows with `next-window': it allocates nothing."
  (let* ((first (frame-first-window frame)) (w first) (same t)
         (last (and (boundp 'drgnx-pane--last) (hash-table-p drgnx-pane--last)
                    (gethash frame drgnx-pane--last))))
    (while (and same w)
      (let ((r (car records)) (role nil))
        (if (and r (eq w (drgnx-state--win-window r))
                 (eq (window-buffer w) (drgnx-state--win-buffer r))
                 (eq (setq role (drgnx-state--classify w)) (drgnx-state--win-role r))
                 (let ((e (drgnx-state--win-edges r)))
                   (and (eq (car e) (window-pixel-left w)) (eq (nth 1 e) (window-pixel-top w))
                        (eq (nth 2 e) (window-pixel-width w)) (eq (nth 3 e) (window-pixel-height w))))
                 (eq (window-dedicated-p w) (drgnx-state--win-dedicated r))
                 (cond ((eq role 'editor)
                        (eq (drgnx-state--win-kind r)
                            (or (window-parameter w 'drgnx-layouts-pane) (car (rassq (window-buffer w) last)))))
                       ((eq (plist-get (cdr (assq role drgnx-state--roles)) :chrome) 'dock)
                        (eq (drgnx-state--win-kind r) (window-parameter w 'drgnx-section)))
                       (t t)))
            (setq records (cdr records)
                  w (let ((next (next-window w 'nomini frame))) (unless (eq next first) next)))
          (setq same nil))))
    (and same (null records))))

(defun drgnx-state--same-p (frame rec &optional parameters)
  "Non-nil if REC still describes FRAME: its size, visibility, selected window and windows
\(`drgnx-state--same-windows-p'); with PARAMETERS also its `drgnx-frame-role' and `drgnx-monitor'.
Those two only on request: `frame-parameter' copies all of a frame's parameters to read one of ours
\(2 conses per parameter), too much for every command; their writers call `drgnx-state-sync'."
  (let ((size (drgnx-state--fr-size rec)))
    (and (eq (frame-selected-window frame) (drgnx-state--fr-selected rec))
         (eq (frame-text-cols frame) (car size)) (eq (frame-text-lines frame) (nth 1 size))
         (eq (frame-pixel-width frame) (nth 2 size)) (eq (frame-pixel-height frame) (nth 3 size))
         (eq (frame-visible-p frame) (drgnx-state--fr-visible rec))
         (or (not parameters)
             (and (eq (frame-parameter frame 'drgnx-frame-role) (drgnx-state--fr-role rec))
                  (equal (frame-parameter frame 'drgnx-monitor) (drgnx-state--fr-monitor rec))))
         (drgnx-state--same-windows-p frame (drgnx-state--fr-windows rec)))))

;;;; The observer

(defun drgnx-state--error (what fn err)
  "Record ERR, raised by FN during WHAT, in `drgnx-signal-errors' (the bus's format, at most 20)."
  (push (format "%s %s: %s" what fn (error-message-string err)) drgnx-signal-errors)
  (when (nthcdr 20 drgnx-signal-errors)
    (setq drgnx-signal-errors (take 20 drgnx-signal-errors))))

(defun drgnx-state--observe (frame &optional parameters)
  "Bring FRAME's record up to date; non-nil (the new record) when it was taken anew.
An in-place check first, which allocates nothing; a new record only when something differs.  PARAMETERS:
also compare the frame parameters the record copies (`drgnx-state--same-p'; `drgnx-state-sync' does).
A frame that is not a workbench frame (any more) has no record.  Never prompts; an error is recorded,
not raised.  During an observation it does nothing: a change made meanwhile waits for the next one."
  (unless drgnx-state--observing
    (let ((drgnx-state--observing t) (inhibit-interaction t))
      (condition-case err
          (let ((old (gethash frame drgnx-state--frames)))
            ;; A recorded frame was a workbench frame: its terminal, graphic-ness and minibuffer never change,
            ;; only its life and its parent.  So it is not classified again (`terminal-name' makes a string).
            (if (and old (frame-live-p frame) (not (frame-parent frame)))
                (if (drgnx-state--same-p frame old parameters)
                    ;; the same windows, but now the selected frame: only `selected-changed'
                    (when (and drgnx-state--watching (eq frame (selected-frame))
                               (not (eq frame drgnx-state--selected-frame)))
                      (drgnx-state--put frame old old)
                      nil)
                  (drgnx-state--rebuild frame old))
              (if (drgnx-state-workbench-frame-p frame)
                  (drgnx-state--rebuild frame old)
                (drgnx-state--frame-deleted frame)
                nil)))
        (error (drgnx-state--error 'observe 'drgnx-state--observe err) nil)))))

(defun drgnx-state-sync (&optional frame)
  "Observe FRAME (default: the selected frame) now and return a copy of its record; nil for a frame that is
not a workbench frame.  For code that changes windows and reads the store in the same breath, for code that
sets `drgnx-frame-role' or `drgnx-monitor' (setting a frame parameter is no window change, and only this
observation compares them), and for batch tests (no redisplay runs there).  The copy is shallow: the lists
in it are the store's and are read-only."
  (let ((frame (or frame (selected-frame))) (drgnx-state--watching nil)) ; maybe inside `with-selected-frame'
    (drgnx-state--observe frame t)
    (let ((rec (and (frame-live-p frame) (gethash frame drgnx-state--frames))))
      (and rec (copy-sequence rec)))))

;;;; Writes

(defvar drgnx-state--writing nil
  "Nil, or (:by BY) while a write runs (`drgnx-state-with-write'), dynamically bound.")

(defvar drgnx-state--in-command nil
  "Non-nil while a command runs: set by `drgnx-state--pre-command', cleared by `drgnx-state--post-command'.")

(defun drgnx-state-default-by ()
  "Who asked for a write when the caller does not say: `user' inside a command, else `auto'."
  (if drgnx-state--in-command 'user 'auto))

(defmacro drgnx-state-with-write (spec &rest body)
  "Run BODY as a write to FRAME's windows on behalf of BY, then observe FRAME; return BODY's value.
SPEC is (FRAME &optional BY).  FRAME nil: the frame selected when BODY starts.  BY: who asked — `user',
`auto', `layout', `restore', `teardown'; nil: `drgnx-state-default-by'.  While BODY and the observation
run, `drgnx-state--writing' is (:by BY).  A write sees no frame switch (it may run inside
`with-selected-frame'; `drgnx-state--watching')."
  (declare (indent 1) (debug ((form &optional form) body)))
  (let ((frame (make-symbol "frame")))
    `(let* ((,frame (or ,(car spec) (selected-frame)))
            (drgnx-state--watching nil)
            (drgnx-state--writing (list :by (or ,(cadr spec) (drgnx-state-default-by)))))
       (prog1 (progn ,@body) (drgnx-state-sync ,frame)))))

(cl-defun drgnx-state-use-editor (window &key by)
  "Make WINDOW its frame's MRU editor window without selecting it; return WINDOW.
The choice holds until the frame's record is next taken anew (`drgnx-state--rebuild') while an editor
window is selected: any change to the frame's windows — a selection, a buffer, a split, a resize — then
makes the selected editor window the editor again.  While the dock or another non-editor window is
selected, it holds as long as WINDOW lives.  BY: who asked (`drgnx-state-with-write').
Nil, and nothing changes, for a window that is not an editor window of a workbench frame, and for one
whose frame has no record while an observation runs (a `now' subscriber's call: the frame is recorded
at the next observation).  During an observation a recorded frame's choice is set."
  (when (and (window-live-p window) (eq (drgnx-state--classify window) 'editor))
    (let ((frame (window-frame window)) (done nil))
      (when (drgnx-state-workbench-frame-p frame)
        (drgnx-state-with-write (frame by)
          (drgnx-state--observe frame t)
          (when-let* ((rec (gethash frame drgnx-state--frames)))
            (let ((new (copy-sequence rec)))
              (setf (drgnx-state--fr-editor new) window)
              (drgnx-state--put frame rec new)
              (setq done t))))
        (and done window)))))

;;;; Events: what changed between two records, to whom

(defconst drgnx-state-events
  '(frame-added frame-kind frame-resized windows-changed groups-changed pane-hidden pane-shown pane-resized
                selected-changed editor-changed frame-removed)
  "The store's events, in the order one observation emits them; `frame-removed' comes on its own.")

(defcustom drgnx-state-user-resize-commands
  '(mouse-drag-vertical-line mouse-drag-mode-line mouse-drag-header-line enlarge-window shrink-window
                             enlarge-window-horizontally shrink-window-horizontally)
  "Commands whose window changes are the user's own resizes: their events carry `:cause user'.
A mouse drag on a divider counts at each step: Emacs 30+ runs the steps as commands of a transient map (so
`this-command' is a closure) with `track-mouse' set to `dragging', which is what is checked."
  :type '(repeat function) :group 'drgnx)

(defun drgnx-state--lane-var (lane)
  (pcase lane
    ('now 'drgnx-state--now)
    ('idle 'drgnx-state--idle)
    (_ (error "drgnx-state-subscribe: :lane must be `now' or `idle', not %S" lane))))

(defun drgnx-state--lane-of (event fn)
  "The lane FN is subscribed to EVENT on, or nil."
  (cond ((memq fn (cdr (assq event drgnx-state--now))) 'now)
        ((memq fn (cdr (assq event drgnx-state--idle))) 'idle)))

(defun drgnx-state--set-fns (var event fns)
  "Make FNS EVENT's functions in the lane alist VAR, building a new alist (a delivery may be walking the
old one)."
  (let ((rest (cl-remove event (symbol-value var) :key #'car)))
    (set var (if fns (append rest (list (cons event fns))) rest))))

(defun drgnx-state--subscribe-1 (event fn lane)
  "Subscribe FN to EVENT on LANE, leaving its other lane; nothing when it is there already."
  (let ((was (drgnx-state--lane-of event fn)))
    (unless (eq was lane)
      (when was (drgnx-state-unsubscribe event fn))
      (let ((var (drgnx-state--lane-var lane)))
        (drgnx-state--set-fns var event (append (cdr (assq event (symbol-value var))) (list fn)))))))

(cl-defun drgnx-state-subscribe (event fn &key (lane 'idle))
  "Call FN with a plist when EVENT happens; return FN.
EVENT is one of `drgnx-state-events'.  FN is a named function (a symbol: a lambda is refused).  LANE:
`idle' (the default) calls FN once Emacs is idle, coalesced per FN, EVENT, frame and kind with the last data;
`now' calls it inside the observation — possibly during redisplay, before the frame is drawn — for cheap
reactions only (a mode-line update, a window parameter, a timer; never a window move, a buffer scan or a
process call).  Each (EVENT FN) pair is subscribed once; subscribing it again on the other lane moves it.
Called from a module's setup, it records its undo \"state subscription EVENT FN\": FN unsubscribed only if
it was not subscribed before, and only while it is still on LANE (`drgnx-module--claim')."
  (unless (memq event drgnx-state-events)
    (error "drgnx-state-subscribe: %S is not an event of the store" event))
  (unless (and fn (symbolp fn))
    (error "drgnx-state-subscribe %s: FN must be a named function, not %S" event fn))
  (drgnx-state--lane-var lane)
  (let ((was (drgnx-state--lane-of event fn)))
    (drgnx-state--subscribe-1 event fn lane)
    (when (drgnx-modules--recording-p)
      (let* ((target (list 'state-subscription event fn))
             (box (drgnx-module--claim target was)))
        (drgnx-modules-push-undo
         (format "state subscription %s %s" event fn)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (eq (drgnx-state--lane-of event fn) lane))
            (lambda (prev) (if prev (drgnx-state--subscribe-1 event fn prev)
                             (drgnx-state-unsubscribe event fn))))))))
    fn))

(defun drgnx-state-unsubscribe (event fn)
  "Stop calling FN for EVENT (either lane), and drop its waiting idle calls; non-nil if it was subscribed."
  (let ((lane (drgnx-state--lane-of event fn)))
    (when lane
      (let ((var (drgnx-state--lane-var lane)))
        (drgnx-state--set-fns var event (remq fn (cdr (assq event (symbol-value var))))))
      (setq drgnx-state--queue
            (cl-remove-if (lambda (c) (and (eq (car c) fn) (eq (nth 1 c) event))) drgnx-state--queue))
      t)))

(defun drgnx-state--wants (event)
  "Non-nil if a function is subscribed to EVENT."
  (or (assq event drgnx-state--now) (assq event drgnx-state--idle)))

(defun drgnx-state--call (event fn data)
  "Call FN with DATA, never prompting; an error is recorded in `drgnx-signal-errors' as \"EVENT FN: message\"."
  (let ((inhibit-interaction t))
    (condition-case err (funcall fn data)
      (error (drgnx-state--error event fn err)))))

(defun drgnx-state--emit (event data)
  "Deliver EVENT with DATA: call its `now' functions, in order, and queue its `idle' ones."
  (dolist (fn (cdr (assq event drgnx-state--now)))
    (drgnx-state--call event fn data))
  (dolist (fn (cdr (assq event drgnx-state--idle)))
    (drgnx-state--queue-call fn event data)))

(defun drgnx-state--queue-call (fn event data)
  "Queue FN's call for EVENT with DATA, replacing the data of a waiting call for the same frame and kind;
arm the bus's idle flush (one timer for the store and the bus)."
  (let ((frame (plist-get data :frame)) (kind (plist-get data :kind)) (found nil))
    (dolist (c drgnx-state--queue)
      (when (and (not found) (eq (car c) fn) (eq (nth 1 c) event) (eq (nth 2 c) frame) (eq (nth 3 c) kind))
        (setq found c)))
    (if found
        (setcar (nthcdr 4 found) data)
      (push (list fn event frame kind data) drgnx-state--queue)))
  (drgnx-signal--schedule))

(defun drgnx-state--deliver-idle ()
  "Make the waiting idle calls, oldest first (the bus's flush calls it, after `drgnx-state-sync')."
  (let ((calls (reverse drgnx-state--queue)))
    (setq drgnx-state--queue nil)
    (dolist (c calls)
      (drgnx-state--call (nth 1 c) (car c) (nth 4 c)))))

(defun drgnx-state--drop-idle ()
  "Forget the waiting idle calls (the bus's flush stays armed while the bus is on: it has its own edges)."
  (setq drgnx-state--queue nil))

(defun drgnx-state--cause ()
  "(CAUSE . BY) for the change being observed: (write . BY) inside a write (`drgnx-state-with-write');
\(user . user) inside one of `drgnx-state-user-resize-commands' or a mouse drag of a divider; else (other)."
  (cond (drgnx-state--writing (cons 'write (plist-get drgnx-state--writing :by)))
        ((and drgnx-state--in-command
              (or (memq this-command drgnx-state-user-resize-commands)
                  (eq track-mouse 'dragging)))  ; Emacs 30+: each step of a divider drag runs a transient-map closure
         '(user . user))
        (t '(other))))

(defun drgnx-state--frame-plist (rec)
  (list :kind (drgnx-state--fr-kind rec) :role (drgnx-state--fr-role rec) :monitor (drgnx-state--fr-monitor rec)))

(defun drgnx-state--size-plist (rec)
  (let ((s (drgnx-state--fr-size rec)))
    (list :cols (nth 0 s) :lines (nth 1 s) :width (nth 2 s) :height (nth 3 s))))

(defun drgnx-state--win-of (window records)
  "WINDOW's record among RECORDS, or nil."
  (let ((found nil))
    (dolist (r records)
      (when (and (not found) (eq (drgnx-state--win-window r) window)) (setq found r)))
    found))

(defun drgnx-state--same-shown-p (old new)
  "Non-nil if the window records OLD and NEW have the same windows, in order, each with the same buffer and role."
  (while (and old new
              (eq (drgnx-state--win-window (car old)) (drgnx-state--win-window (car new)))
              (eq (drgnx-state--win-buffer (car old)) (drgnx-state--win-buffer (car new)))
              (eq (drgnx-state--win-role (car old)) (drgnx-state--win-role (car new))))
    (setq old (cdr old) new (cdr new)))
  (and (null old) (null new)))

(defun drgnx-state--editors (records)
  (let ((out nil))
    (dolist (r records)
      (when (eq (drgnx-state--win-role r) 'editor) (push (drgnx-state--win-window r) out)))
    (nreverse out)))

(defun drgnx-state--minus (a b)
  "The elements of A that are not in B (`memq'), in A's order."
  (let ((out nil))
    (dolist (x a) (unless (memq x b) (push x out)))
    (nreverse out)))

(defun drgnx-state--diff (frame old new switched prev)
  "Emit what changed on FRAME from OLD (nil: FRAME is new) to NEW, in the order of `drgnx-state-events'.
SWITCHED: FRAME has just become the selected frame; PREV: the frame selected before it.  An event nobody
subscribes to is not computed."
  (let* ((cause (drgnx-state--cause)) (by (cdr cause)) (cause (car cause))
         (ow (and old (drgnx-state--fr-windows old))) (nw (drgnx-state--fr-windows new)))
    (when (and (null old) (drgnx-state--wants 'frame-added))
      (drgnx-state--emit 'frame-added (list :frame frame :kind (drgnx-state--fr-kind new))))
    (when (and old (drgnx-state--wants 'frame-kind)
               (not (and (eq (drgnx-state--fr-kind old) (drgnx-state--fr-kind new))
                         (eq (drgnx-state--fr-role old) (drgnx-state--fr-role new))
                         (equal (drgnx-state--fr-monitor old) (drgnx-state--fr-monitor new)))))
      (drgnx-state--emit 'frame-kind (list :frame frame :old (drgnx-state--frame-plist old)
                                           :new (drgnx-state--frame-plist new))))
    (when (and old (drgnx-state--wants 'frame-resized)
               (not (equal (drgnx-state--fr-size old) (drgnx-state--fr-size new))))
      (drgnx-state--emit 'frame-resized (list :frame frame :old (drgnx-state--size-plist old)
                                              :new (drgnx-state--size-plist new))))
    (when (and (drgnx-state--wants 'windows-changed) (not (drgnx-state--same-shown-p ow nw)))
      (drgnx-state--emit 'windows-changed (list :frame frame :windows (mapcar #'drgnx-state--win-window nw))))
    (when (drgnx-state--wants 'groups-changed)
      (let* ((oe (drgnx-state--editors ow)) (ne (drgnx-state--editors nw))
             (added (drgnx-state--minus ne oe)) (removed (drgnx-state--minus oe ne)))
        (when (or added removed)
          (drgnx-state--emit 'groups-changed (list :frame frame :added added :removed removed)))))
    (let ((op (and old (drgnx-state--fr-panes old))) (np (drgnx-state--fr-panes new)))
      (when (drgnx-state--wants 'pane-hidden)
        (dolist (p op)
          (unless (eq (cdr p) (cdr (assq (car p) np)))
            (drgnx-state--emit 'pane-hidden (list :frame frame :kind (car p) :window (cdr p) :cause cause :by by)))))
      (when (drgnx-state--wants 'pane-shown)
        (dolist (p np)
          (unless (eq (cdr p) (cdr (assq (car p) op)))
            (drgnx-state--emit 'pane-shown (list :frame frame :kind (car p) :window (cdr p) :cause cause :by by))))))
    (when (and old (drgnx-state--wants 'pane-resized))
      (dolist (r nw)
        (when (or (drgnx-state--win-kind r) (eq (drgnx-state--win-role r) 'editor))
          (let ((o (drgnx-state--win-of (drgnx-state--win-window r) ow)))
            (when (and o (not (equal (drgnx-state--win-edges o) (drgnx-state--win-edges r))))
              (drgnx-state--emit 'pane-resized
                                 (list :frame frame :window (drgnx-state--win-window r) :kind (drgnx-state--win-kind r)
                                       :old (copy-sequence (drgnx-state--win-edges o))
                                       :new (copy-sequence (drgnx-state--win-edges r))
                                       :cause cause :by by)))))))
    (let ((os (and old (drgnx-state--fr-selected old))) (ns (drgnx-state--fr-selected new)))
      (when (and (drgnx-state--wants 'selected-changed) (or switched (not (eq os ns))))
        (drgnx-state--emit 'selected-changed
                           (list :frame frame :window ns
                                 :old-window (if switched (and (frame-live-p prev) (frame-selected-window prev)) os)
                                 :old-frame (if switched prev frame)))))
    ;; A `now' subscriber that chose an editor (`drgnx-state-use-editor') replaced NEW and reported its own
    ;; `editor-changed': this one would name an editor that is no longer the frame's.
    (when (and (drgnx-state--wants 'editor-changed) (eq new (gethash frame drgnx-state--frames)))
      (let* ((oe (and old (drgnx-state--fr-editor old))) (ne (drgnx-state--fr-editor new))
             (ob (let ((r (and oe (drgnx-state--win-of oe ow)))) (and r (drgnx-state--win-buffer r))))
             (nb (let ((r (and ne (drgnx-state--win-of ne nw)))) (and r (drgnx-state--win-buffer r)))))
        (unless (and (eq oe ne) (eq ob nb))
          (drgnx-state--emit 'editor-changed (list :frame frame :window ne :buffer nb :old-window oe :old-buffer ob)))))))

;;;; Reads: from the records, nil for a dead window or frame

(defun drgnx-state--record (frame)
  "FRAME's record (nil: the selected frame's), or nil when FRAME is dead or not recorded."
  (let ((frame (or frame (selected-frame))))
    (and (frame-live-p frame) (gethash frame drgnx-state--frames))))

(defun drgnx-state--window-record (window)
  "WINDOW's record in its frame's record, or nil."
  (when (window-live-p window)
    (let ((rec (drgnx-state--record (window-frame window))) (found nil))
      (when rec
        (dolist (r (drgnx-state--fr-windows rec))
          (when (eq (drgnx-state--win-window r) window) (setq found r))))
      found)))

(defun drgnx-state-editor-window (&optional frame)
  "FRAME's most recently used editor window (default: the selected frame's), or nil."
  (let* ((rec (drgnx-state--record frame)) (w (and rec (drgnx-state--fr-editor rec))))
    (and (window-live-p w) w)))

(defun drgnx-state-selected-window (&optional frame)
  "FRAME's selected window as last observed (default: the selected frame's), or nil."
  (let* ((rec (drgnx-state--record frame)) (w (and rec (drgnx-state--fr-selected rec))))
    (and (window-live-p w) w)))

(defun drgnx-state-frames (&optional kind)
  "The recorded frames, oldest first; with KIND (`gui' or `tty') only those."
  (let ((out nil))
    (dolist (f drgnx-state--order)
      (let ((rec (drgnx-state--record f)))
        (when (and rec (or (null kind) (eq kind (drgnx-state--fr-kind rec))))
          (push f out))))
    (nreverse out)))

(defun drgnx-state-main-frame ()
  "The oldest recorded frame whose `drgnx-frame-role' is `main', or nil."
  (let ((found nil))
    (dolist (f drgnx-state--order)
      (unless found
        (let ((rec (drgnx-state--record f)))
          (when (and rec (eq 'main (drgnx-state--fr-role rec))) (setq found f)))))
    found))

(defun drgnx-state-windows (frame &optional role)
  "FRAME's windows in order (from its first window), as last observed; with ROLE only those of ROLE."
  (let ((rec (drgnx-state--record frame)) (out nil))
    (when rec
      (dolist (r (drgnx-state--fr-windows rec))
        (let ((w (drgnx-state--win-window r)))
          (when (and (window-live-p w) (or (null role) (eq role (drgnx-state--win-role r))))
            (push w out)))))
    (nreverse out)))

(defun drgnx-state-window-role (window)
  "WINDOW's role: a role of the table, `side', `editor', or nil (the minibuffer, a dead window).
From the record; a window not observed yet is classified live by the same rule."
  (when (window-live-p window)
    (let ((r (drgnx-state--window-record window)))
      (if r (drgnx-state--win-role r) (drgnx-state--classify window)))))

(defun drgnx-state-edges (window)
  "WINDOW's pixel edges as last observed: (LEFT TOP WIDTH HEIGHT), or nil."
  (let ((r (drgnx-state--window-record window)))
    (and r (copy-sequence (drgnx-state--win-edges r)))))

(defun drgnx-state-pane-window (kind &optional frame)
  "The window showing pane KIND on FRAME (default: the selected frame), or nil."
  (let* ((rec (drgnx-state--record frame))
         (w (and rec (cdr (assq kind (drgnx-state--fr-panes rec))))))
    (and (window-live-p w) w)))

(defun drgnx-state-pane-shown-p (kind &optional frame)
  "Non-nil if pane KIND shows on FRAME (default: the selected frame) and FRAME is visible (not iconified)."
  (let ((rec (drgnx-state--record frame)))
    (and rec (eq t (drgnx-state--fr-visible rec)) (drgnx-state-pane-window kind frame) t)))

(defun drgnx-state-shown-kinds (&optional frame)
  "The pane kinds that show on FRAME (default: the selected frame), in window order, whether or not FRAME
is visible."
  (let ((rec (drgnx-state--record frame)) (out nil))
    (when rec
      (dolist (p (drgnx-state--fr-panes rec))
        (when (window-live-p (cdr p)) (push (car p) out))))
    (nreverse out)))

(defun drgnx-state-frame-size (frame)
  "FRAME's size as last observed: (:cols :lines :width :height) — text columns and lines, pixel width and
height — or nil."
  (let ((rec (drgnx-state--record frame)))
    (when rec
      (let ((s (drgnx-state--fr-size rec)))
        (list :cols (nth 0 s) :lines (nth 1 s) :width (nth 2 s) :height (nth 3 s))))))

;;;; The mode: when the observer runs

(defun drgnx-state--on-window-state-change (frame)
  "From the default value of `window-state-change-functions': FRAME's windows changed (during redisplay,
before FRAME is drawn)."
  (let ((drgnx-state--watching t)) (drgnx-state--observe frame)))

(defun drgnx-state--pre-command ()
  "A command starts: writes default to `user' (`drgnx-state-default-by')."
  (setq drgnx-state--in-command t))

(defun drgnx-state--post-command ()
  "A command ended: observe the selected frame (even when redisplay is skipped), then leave the command."
  (let ((drgnx-state--watching t)) (drgnx-state--observe (selected-frame)))
  (setq drgnx-state--in-command nil))

(defun drgnx-state--frame-made (frame)
  "From `after-make-frame-functions': record FRAME before its first redisplay."
  (let ((drgnx-state--watching t)) (drgnx-state--observe frame)))

(defun drgnx-state--frame-deleted (frame)
  "From `delete-frame-functions' (FRAME still live), or FRAME is no workbench frame: its record goes,
then `frame-removed' is emitted (FRAME is still live for its subscribers)."
  (when (gethash frame drgnx-state--frames)
    (remhash frame drgnx-state--frames)
    (setq drgnx-state--order (remq frame drgnx-state--order))
    (when (eq frame drgnx-state--selected-frame) (setq drgnx-state--selected-frame nil))
    (when (drgnx-state--wants 'frame-removed)
      (drgnx-state--emit 'frame-removed (list :frame frame)))))

(defconst drgnx-state--hook-table
  '((window-state-change-functions drgnx-state--on-window-state-change)
    (post-command-hook drgnx-state--post-command -90) ; first: other post-command code reads the new state
    (pre-command-hook drgnx-state--pre-command)
    (after-make-frame-functions drgnx-state--frame-made)
    (delete-frame-functions drgnx-state--frame-deleted))
  "(HOOK FUNCTION DEPTH): what `drgnx-state-mode' adds (to the hooks' default values).")

(defun drgnx-state--install (on)
  "Add the store's hook functions when ON, else remove them."
  (pcase-dolist (`(,hook ,fn ,depth) drgnx-state--hook-table)
    (if on (add-hook hook fn depth) (remove-hook hook fn))))

(define-minor-mode drgnx-state-mode
  "The workbench state store: keep one record per workbench frame, observed when windows change.
On, it observes every live workbench frame, oldest first; off, the records go, and so does the shared idle
flush `signal-flush' unless the bus (`drgnx-signal-mode') is still on."
  :global t :group 'drgnx
  (drgnx-state--install drgnx-state-mode)
  (if drgnx-state-mode
      (let ((drgnx-state--watching t)) (dolist (f (reverse (frame-list))) (drgnx-state--observe f)))
    (clrhash drgnx-state--frames)
    (drgnx-state--drop-idle)
    (unless (bound-and-true-p drgnx-signal-mode) (drgnx-timer-cancel 'signal-flush))
    (setq drgnx-state--order nil drgnx-state--in-command nil drgnx-state--selected-frame nil)))

(provide 'drgnx-state)
;;; drgnx-state.el ends here
