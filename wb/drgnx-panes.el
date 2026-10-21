;;; drgnx-panes.el --- Pane kinds: one definition per pane -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every pane (Explorer, agents, terminal, Work graph, help, …) is one data definition, a *kind*
;; (`drgnx-pane-define-kind').  Callers show, hide, focus and look up panes by kind and never use
;; the dock, area or section API directly.  `drgnx-pane-backend' says where kinds live: `areas'
;; (today's left dock, bottom panel and right dock) until the tiled grid arrives, which registers
;; its own functions in `drgnx-pane--backends'.  Showing a pane never selects it unless asked.
;; See docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wb)
(require 'drgnx-rules)
(require 'drgnx-area)
(require 'drgnx-state-intent)

(require 'drgnx-modules-helpers)
(require 'drgnx-frame-kind)
(require 'drgnx-notice)

(declare-function drgnx-layouts-define-pane "drgnx-layouts")

(defvar drgnx-pane-backend 'areas
  "Where pane kinds live: `areas' (the docks) or `grid'.
`areas' is the left dock, the bottom panel and the right dock.")

(defvar drgnx-pane--kinds nil
  "Alist KIND → plist (:title :buffer :placeholder :home :size :view :slot :height :fill :on-show
:on-focus :stack), in definition order.")

(defconst drgnx-pane--homes '(left bottom right editor))

(defconst drgnx-pane--areas '((bottom . panel) (right . right))
  "Home → the area (`drgnx-wb-define-area') that holds its kinds before the grid.")

(defun drgnx-pane-kind (kind)
  "The plist KIND was defined with, or nil."
  (alist-get kind drgnx-pane--kinds))

(defun drgnx-pane-kinds (&optional home)
  "Every kind in definition order; with HOME (`left', `bottom', `right' or `editor') only that home's."
  (let ((all (mapcar #'car drgnx-pane--kinds)))
    (if home (seq-filter (lambda (k) (eq (plist-get (drgnx-pane-kind k) :home) home)) all) all)))

(defvar drgnx-state--kind-owners nil
  "Alist KIND → the module whose setup defined it (`drgnx-modules--current'), nil for a kind core defines at load.")

(defun drgnx-state-kind-owner (kind)
  "The module that defined pane KIND (its setup was running), or nil: core's, or not defined."
  (alist-get kind drgnx-state--kind-owners))

(defun drgnx-pane--spec (kind)
  (or (drgnx-pane-kind kind) (user-error "No pane kind %s" kind)))

(defun drgnx-pane--area (kind)
  "The area KIND's home maps to, or nil (left and editor kinds have none)."
  (alist-get (plist-get (drgnx-pane-kind kind) :home) drgnx-pane--areas))

(defun drgnx-pane--buffer (spec kind)
  "The buffer KIND shows when nothing else is given.
SPEC's :buffer (a function, a buffer, or a name made if missing), else its :placeholder function, else a blank one."
  (let ((b (plist-get spec :buffer)))
    (cond ((functionp b) (funcall b))
          ((stringp b) (get-buffer-create b))
          ((buffer-live-p b) b)
          ((functionp (plist-get spec :placeholder)) (funcall (plist-get spec :placeholder)))
          (t (or (get-buffer (format " *drgnx %s*" kind))
                 (with-current-buffer (get-buffer-create (format " *drgnx %s*" kind) t)
                   (special-mode)
                   (current-buffer)))))))

(defun drgnx-pane--editor-matcher (spec)
  "The `drgnx-wb-place' matcher an `editor' SPEC with a named :buffer installs, or nil."
  (when (eq (plist-get spec :home) 'editor)
    (let ((b (plist-get spec :buffer)))
      (when-let* ((name (cond ((stringp b) b) ((bufferp b) (buffer-name b)))))
        (concat "\\`" (regexp-quote name) "\\'")))))

(defun drgnx-pane--matcher-used-by-other-p (matcher kind)
  "Non-nil if an editor kind other than KIND places its buffer with MATCHER."
  (seq-some (lambda (k) (and (not (eq (car k) kind)) (equal matcher (drgnx-pane--editor-matcher (cdr k)))))
            drgnx-pane--kinds))

(defvar drgnx-pane--last (make-hash-table :test 'eq :weakness 'key)
  "Frame → alist KIND → the last buffer the kind showed there.
Kept out of frame parameters: a buffer object in one would make the saved frame state unreadable.")

(defun drgnx-pane--remember (kind buffer)
  "Remember BUFFER as the last one KIND showed on the selected frame (an editor kind's window is found by it)."
  (setf (alist-get kind (gethash (selected-frame) drgnx-pane--last)) buffer))

;;;; The `areas' backend: forwards to today's docks

(defun drgnx-pane--areas-define (kind spec old)
  "Forward KIND's SPEC to the docks; OLD, the spec it replaces, is taken out of its dock first."
  (when (and old (not (eq (plist-get old :home) (plist-get spec :home))))
    (setq drgnx-wb--sections (assq-delete-all kind drgnx-wb--sections))
    (when-let* ((area (alist-get (plist-get old :home) drgnx-pane--areas))
                (spec (alist-get area drgnx-wb--areas)))
      (setf (alist-get area drgnx-wb--areas)
            (plist-put (copy-sequence spec) :tabs (assq-delete-all kind (copy-sequence (plist-get spec :tabs)))))))
  (when-let* ((matcher (and old (drgnx-pane--editor-matcher old)))
              ((not (equal matcher (drgnx-pane--editor-matcher spec))))
              ((not (drgnx-pane--matcher-used-by-other-p matcher kind))))
    (setq drgnx-rules--table (assoc-delete-all matcher drgnx-rules--table)))
  (pcase (plist-get spec :home)
    ('left
     (drgnx-wb-define-section
      kind :slot (or (plist-get spec :slot) 0) :title (plist-get spec :title)
      :buffer (lambda () (drgnx-pane--buffer (drgnx-pane--spec kind) kind))
      :height (plist-get spec :height) :view (plist-get spec :view)
      :on-show (plist-get spec :on-show) :on-focus (plist-get spec :on-focus)))
    ((or 'bottom 'right)
     (drgnx-wb-define-tab (alist-get (plist-get spec :home) drgnx-pane--areas) kind
                          :title (plist-get spec :title)
                          :placeholder (lambda () (drgnx-pane--buffer (drgnx-pane--spec kind) kind))))
    ('editor
     (when-let* ((matcher (drgnx-pane--editor-matcher spec)))
       (drgnx-wb-place matcher 'editor)))))

(defun drgnx-pane--areas-window (kind &optional frame)
  (let ((spec (drgnx-pane--spec kind)))
    (pcase (plist-get spec :home)
      ('left (drgnx-wb-section-window kind frame))
      ((or 'bottom 'right)
       (let ((area (drgnx-pane--area kind)))
         (with-selected-frame (or frame (selected-frame))
           (and (eq (drgnx-wb-area-tab area) kind) (drgnx-wb-area-window area frame)))))
      ('editor
       (let* ((b (alist-get kind (gethash (or frame (selected-frame)) drgnx-pane--last)))
              (b (if (buffer-live-p b) b
                   (let ((s (plist-get spec :buffer))) (if (stringp s) (get-buffer s) s)))))
         (and (buffer-live-p b) (get-buffer-window b (or frame (selected-frame)))))))))

(defun drgnx-pane--areas-show (kind buffer select)
  (let* ((spec (drgnx-pane--spec kind)) (home (plist-get spec :home))
         (selected (selected-window)))
    ;; A view swap deletes the dock windows and would move focus to the new dock: leave the dock first.
    ;; Only when the view changes; otherwise nothing is selected, so the buffer order and use times stay.
    (when (and (eq home 'left) (not select) (eq (window-parameter selected 'drgnx-role) 'dock)
               (not (eq (or (plist-get spec :view) 'explorer) (drgnx-wb-sidebar-view))))
      (select-window (drgnx-wb-editor-window) 'norecord))
    (prog1
        (pcase home
          ('left
           (let ((was (drgnx-wb-section-window kind)))
             (drgnx-wb-show-view (or (plist-get spec :view) 'explorer))
             (let ((w (drgnx-wb-section-window kind)))
               (when (and w select) (drgnx-wb-focus-section kind))
               ;; a dock that was hidden or swapped in ran :on-show itself; an already shown section needs it now
               (when-let* ((fn (plist-get spec :on-show)) (_ (and was w))) (funcall fn w))
               w)))
          ((or 'bottom 'right)
           (let ((w (drgnx-wb-area-show (drgnx-pane--area kind) kind buffer)))
             (drgnx-state-note-intent nil :front (drgnx-pane--area kind) kind) ; by the running write
             (when-let* ((fn (plist-get spec :on-show))) (funcall fn w))
             (when select (select-window w))
             w))
          ('editor
           (let* ((b (or buffer (drgnx-pane--buffer spec kind)))
                  (w (drgnx-wb-show-in-editor b select)))
             (drgnx-pane--remember kind b)
             (when-let* ((fn (plist-get spec :on-show))) (funcall fn w))
             w)))
      (unless (or select (eq (selected-window) selected) (not (window-live-p selected)))
        (select-window selected 'norecord)))))

(defun drgnx-pane--areas-hide (kind)
  (pcase (plist-get (drgnx-pane--spec kind) :home)
    ((or 'left 'bottom 'right)
     (when (drgnx-pane--areas-window kind)
       (if (eq (plist-get (drgnx-pane--spec kind) :home) 'left)
           (drgnx-wb-hide-sidebar)      ; the dock hides as a whole
         (drgnx-wb-area-hide (drgnx-pane--area kind)))))))

(defun drgnx-pane--areas-focus (kind)
  (let ((w (drgnx-pane--areas-show kind nil t)))
    (when-let* ((fn (plist-get (drgnx-pane--spec kind) :on-focus))
                ((not (eq (plist-get (drgnx-pane--spec kind) :home) 'left))))
      (funcall fn w))
    w))

(defun drgnx-pane--areas-resize (kind px _horizontal)
  "Give KIND's dock or area PX pixels — the dock's width (left), the panel's height (bottom), the right dock's
width (right) — and note it as the size it comes back at (`:sizes', by the running write).  Pixelwise, as
`drgnx-area--create' does; the windows keep their preserved size, at the new one.  HORIZONTAL is the grid's:
here the home decides.  The window when KIND shows, else nil (the size waits for the next show).  An editor
kind has no size of its own: nil, nothing noted."
  (let ((home (plist-get (drgnx-pane--spec kind) :home)))
    (when (memq home '(left bottom right))
      (drgnx-state-note-intent nil :sizes home px)
      (when-let* ((w (drgnx-pane--areas-window kind)))
        (let ((horizontal (not (eq home 'bottom)))
              (windows (if (eq home 'left) (drgnx-wb--dock-windows) (list w)))
              (window-resize-pixelwise t))      ; or the size is rounded to whole lines or columns
          (ignore-errors
            (window-resize (car windows)
                           (- px (if horizontal (window-pixel-width w) (window-pixel-height w)))
                           horizontal 'preserved t))
          (dolist (x windows) (window-preserve-size x horizontal t))
          w)))))

(defvar drgnx-pane--backends
  `((areas :define drgnx-pane--areas-define :show drgnx-pane--areas-show :hide drgnx-pane--areas-hide
           :window drgnx-pane--areas-window :focus drgnx-pane--areas-focus :resize drgnx-pane--areas-resize))
  "Alist BACKEND → plist of the functions that carry out each pane operation.  The dispatch point:
the grid registers `grid' here.  :define takes (KIND SPEC OLD-SPEC), :show (KIND BUFFER SELECT), :hide (KIND),
:window (KIND FRAME), :focus (KIND), :resize (KIND PX HORIZONTAL), :move (KIND TARGET ZONE), :stack (KIND
ONTO).  The `areas' backend has no :move and no :stack: moving panes needs the grid.")

(defun drgnx-pane--call (op &rest args)
  "Run operation OP (:define, :show, …) of the current `drgnx-pane-backend' with ARGS."
  (let ((fn (plist-get (alist-get drgnx-pane-backend drgnx-pane--backends) op)))
    (unless fn (error "No %s operation for pane backend %s" op drgnx-pane-backend))
    (apply fn args)))

;;;; Ownership: a kind belongs to the module whose setup defined it

(defun drgnx-pane-undefine-kind (kind)
  "Remove pane KIND: from `drgnx-pane--kinds' and the owner table, and from its dock section, area tab or editor
place rule (an editor rule another kind shares stays).  Where KIND shows, the dock or area closes its window
\(`drgnx-wb-undefine-section' and `-tab'); nothing is noted as intent.  Non-nil if KIND was defined."
  (when-let* ((spec (drgnx-pane-kind kind)))
    (pcase (plist-get spec :home)
      ('left (drgnx-wb-undefine-section kind))
      ((or 'bottom 'right) (drgnx-wb-undefine-tab (drgnx-pane--area kind) kind))
      ('editor
       (when-let* ((matcher (drgnx-pane--editor-matcher spec))
                   ((not (drgnx-pane--matcher-used-by-other-p matcher kind))))
         (drgnx-wb-unplace matcher))))
    (setq drgnx-pane--kinds (assq-delete-all kind drgnx-pane--kinds)
          drgnx-state--kind-owners (assq-delete-all kind drgnx-state--kind-owners))
    t))

(defun drgnx-pane--teardown-kind (kind prev)
  "The undo of KIND's definition, while it is still the module's: hide KIND, put PREV back or remove KIND.
PREV is nil (KIND was not defined before) or (SPEC OWNER), the definition this one replaced.  An area's front
tab is intent and survives: it is read first and noted `:by teardown' after the tab is gone, so the module
turned on again finds it in front.  The hide is `:by teardown', which keeps a size you chose.  A left kind is
not hidden: that would close the whole dock; its section just goes."
  (let ((home (plist-get (drgnx-pane-kind kind) :home)) fronts)
    (when-let* ((area (alist-get home drgnx-pane--areas)))
      (dolist (frame (frame-list))
        (when (drgnx-state-workbench-frame-p frame)
          (when (eq (drgnx-state-intent frame :front area) kind) (push (cons frame area) fronts))
          (when (drgnx-pane-window kind frame)
            (with-selected-frame frame (drgnx-pane-hide kind :by 'teardown))))))
    (if prev
        (let ((old (car prev)))
          (drgnx-pane--call :define kind old (drgnx-pane-kind kind))
          (setf (alist-get kind drgnx-pane--kinds) old
                (alist-get kind drgnx-state--kind-owners) (cadr prev)))
      (drgnx-pane-undefine-kind kind))
    (pcase-dolist (`(,frame . ,area) fronts)
      (when (frame-live-p frame) (drgnx-state-note-intent frame :front area kind :by 'teardown)))))

(defun drgnx-pane--show-again (kind)
  "Show the new KIND again `:by teardown' on each frame where its area shows and has KIND in front: the
module it belongs to was turned off, and on again, while the area stayed up."
  (when-let* (((eq drgnx-pane-backend 'areas))
              (area (drgnx-pane--area kind)))
    (dolist (frame (frame-list))
      (when (and (drgnx-state-workbench-frame-p frame) (eq (drgnx-state-intent frame :front area) kind)
                 (drgnx-wb-area-window area frame))
        (condition-case err (with-selected-frame frame (drgnx-pane-show kind :by 'teardown))
          (error (drgnx-notify 'wb 'warn (format "showing pane %s again failed: %s" kind (error-message-string err))
                               :id (cons 'pane-show kind))))))))

;;;; The API

(cl-defun drgnx-pane-define-kind (kind &key title buffer placeholder home size view slot height fill on-show
                                       on-focus stack)
  "Define pane KIND (a symbol); re-defining replaces.  Returns KIND.
HOME is `left', `bottom', `right' or `editor' (default `bottom').  TITLE is a string (a left kind's may be a
function).  BUFFER: a function returning the kind's buffer, or a buffer, or a buffer name (made when
missing); an `editor' kind with a name or buffer also gets a `drgnx-wb-place' rule sending it to the editor.
PLACEHOLDER: a function returning the buffer shown while there is none.
SIZE: columns or lines the first time (the grid reads it; the docks keep their own).
VIEW: the sidebar view a `left' kind belongs to.
SLOT and HEIGHT: as `drgnx-wb-define-section's.
FILL: a function of the window, as `drgnx-layouts-define-pane's filler.
ON-SHOW and ON-FOCUS: functions of the window.
STACK: the kind this one stacks with by default (the grid reads it).
Called from a module's setup, the definition records the module as the kind's owner (`drgnx-state-kind-owner')
and its undo \"pane kind KIND\": KIND hidden `:by teardown' where it shows (its size, front tab and places
are kept as intent), then the previous definition put back or `drgnx-pane-undefine-kind' — only while KIND is
still the one defined here.  Defining a new KIND that is in front in an area that shows shows it again."
  (let ((home (or home 'bottom)))
    (unless (memq home drgnx-pane--homes) (user-error "Bad pane home %s" home))
    (let ((spec (list :title title :buffer buffer :placeholder placeholder :home home :size size :view view
                      :slot slot :height height :fill fill :on-show on-show :on-focus on-focus :stack stack))
          (old (drgnx-pane-kind kind)) (old-owner (drgnx-state-kind-owner kind)))
      (drgnx-pane--call :define kind spec old)         ; first: an error leaves the kinds as they were
      (if old (setf (alist-get kind drgnx-pane--kinds) spec)       ; a new kind goes last, a redefined one stays put
        (setq drgnx-pane--kinds (append drgnx-pane--kinds (list (cons kind spec)))))
      (setf (alist-get kind drgnx-state--kind-owners) drgnx-modules--current)
      (when (drgnx-modules--recording-p)
        (let* ((target (list 'pane-kind kind)) (box (drgnx-module--claim target (and old (list old old-owner)))))
          (drgnx-modules-push-undo
           (format "pane kind %s" kind)
           (lambda ()
             (drgnx-module--release target box
                                    (lambda () (eq (drgnx-pane-kind kind) spec))
                                    (lambda (prev) (drgnx-pane--teardown-kind kind prev)))))))
      (unless old (drgnx-pane--show-again kind))
      (when fill
        (with-eval-after-load 'drgnx-layouts (drgnx-layouts-define-pane kind fill)))
      kind)))

;; Every operation that changes windows is a write (`drgnx-state-with-write'): BY says who asked — `user',
;; `auto', `layout', `restore', `teardown' or `other'; nil is `user' inside a command, `auto' outside.

(cl-defun drgnx-pane-show (kind &key buffer select by)
  "Show pane KIND, with BUFFER if given, and return its window.
It never changes the selected window unless SELECT is non-nil.  A left kind ignores BUFFER (a section's
buffer is its own).  BY: who asked (see above); a bottom or right kind becomes its area's `:front' intent."
  (drgnx-pane--spec kind)
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call :show kind buffer select)))

(cl-defun drgnx-pane-hide (kind &key by)
  "Hide pane KIND when it shows; a kind that is not shown (another view's, a tab behind another) is left alone.
A left kind hides its whole dock.  An editor kind has no hide: it does nothing.  The size the pane had is
noted `:by auto' whoever asks, so a size you chose is never replaced by a squeezed one.  BY: who asked."
  (drgnx-pane--spec kind)
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call :hide kind)))

(defun drgnx-pane-window (kind &optional frame)
  "The window showing pane KIND on FRAME, or nil.
Nil for a kind that is not the front tab of its area or not in the dock's view.  An editor kind's window is the
one showing the last buffer `drgnx-pane-show' or `drgnx-pane-focus' put there on FRAME."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :window kind frame))

(cl-defun drgnx-pane-toggle (kind &key by)
  "Hide pane KIND when it shows, else show it (without selecting).
An editor kind has no hide, so toggling one that shows does nothing.  BY: who asked."
  (if (drgnx-pane-window kind) (drgnx-pane-hide kind :by by) (drgnx-pane-show kind :by by)))

(cl-defun drgnx-pane-focus (kind &key by)
  "Show pane KIND and move focus to it; returns its window.  BY: who asked."
  (drgnx-pane--spec kind)
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call :focus kind)))

(cl-defun drgnx-pane-resize (kind px &key horizontal by)
  "Give pane KIND PX pixels and note it as the size KIND comes back at (`:sizes' intent, BY: who asked).
HORIZONTAL: the width rather than the height, for the grid; the docks' home decides (the left and right docks'
width, the panel's height).  A size you chose is replaced only by you or a restore (`drgnx-state-note-intent');
the window still takes PX.  Returns KIND's window, or nil when it does not show (the size is noted for the
next show) or has no size (an editor kind)."
  (drgnx-pane--spec kind)
  (unless (and (integerp px) (> px 0)) (error "drgnx-pane-resize: %S is not a size in pixels" px))
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call :resize kind px horizontal)))

(defun drgnx-pane--call-on-the-grid (op &rest args)
  "Run OP like `drgnx-pane--call', or say that moving panes needs the grid when the backend has no OP."
  (unless (plist-get (alist-get drgnx-pane-backend drgnx-pane--backends) op)
    (user-error "Moving panes needs the grid"))
  (apply #'drgnx-pane--call op args))

(cl-defun drgnx-pane-move (kind target zone &key by)
  "Move pane KIND to ZONE of pane TARGET (the grid's move; B7).  BY: who asked.
Before the grid the `areas' backend has no move: a `user-error'."
  (drgnx-pane--spec kind)
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call-on-the-grid :move kind target zone)))

(cl-defun drgnx-pane-stack (kind onto &key by)
  "Stack pane KIND with pane ONTO, as tabs of one pane (the grid's stack; B7).  BY: who asked.
Before the grid the `areas' backend has no stack: a `user-error'."
  (drgnx-pane--spec kind)
  (drgnx-state-with-write (nil by)
    (drgnx-pane--call-on-the-grid :stack kind onto)))

(provide 'drgnx-panes)
;;; drgnx-panes.el ends here
