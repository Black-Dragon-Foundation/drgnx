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
;; window, or `side' for a package's own side window.  See docs/develop/core.md, "The workbench state store".

;;; Code:
(require 'cl-lib)
(require 'drgnx-frame-kind)
(require 'drgnx-modules-helpers)

(defvar drgnx-wb--areas)                ; drgnx-area.el: the areas' tabs (read, when loaded)
(defvar drgnx-pane--last)               ; drgnx-panes.el: frame → kind → the last buffer an editor kind showed

(defvar drgnx-signal-errors nil "Recent subscriber errors (newest first).")

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
\(`drgnx-state-use-editor') — so what changed between OLD and NEW is found here.  Records are never
changed in place."
  (unless old (drgnx-state--note-frame frame))
  (puthash frame new drgnx-state--frames)
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
                (unless (drgnx-state--same-p frame old parameters)
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
  (let ((frame (or frame (selected-frame))))
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
run, `drgnx-state--writing' is (:by BY)."
  (declare (indent 1) (debug ((form &optional form) body)))
  (let ((frame (make-symbol "frame")))
    `(let* ((,frame (or ,(car spec) (selected-frame)))
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
  (drgnx-state--observe frame))

(defun drgnx-state--pre-command ()
  "A command starts: writes default to `user' (`drgnx-state-default-by')."
  (setq drgnx-state--in-command t))

(defun drgnx-state--post-command ()
  "A command ended: observe the selected frame (even when redisplay is skipped), then leave the command."
  (drgnx-state--observe (selected-frame))
  (setq drgnx-state--in-command nil))

(defun drgnx-state--frame-made (frame)
  "From `after-make-frame-functions': record FRAME before its first redisplay."
  (drgnx-state--observe frame))

(defun drgnx-state--frame-deleted (frame)
  "From `delete-frame-functions' (FRAME still live), or FRAME is no workbench frame: its record goes."
  (when (gethash frame drgnx-state--frames)
    (remhash frame drgnx-state--frames)
    (setq drgnx-state--order (remq frame drgnx-state--order))))

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
On, it observes every live workbench frame, oldest first; off, the records go."
  :global t :group 'drgnx
  (drgnx-state--install drgnx-state-mode)
  (if drgnx-state-mode
      (dolist (f (reverse (frame-list))) (drgnx-state--observe f))
    (clrhash drgnx-state--frames)
    (setq drgnx-state--order nil drgnx-state--in-command nil)))

(provide 'drgnx-state)
;;; drgnx-state.el ends here
