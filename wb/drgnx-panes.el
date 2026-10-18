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
              ;; another editor kind may still use it
              ((not (seq-some (lambda (k)
                                (and (not (eq (car k) kind)) (equal matcher (drgnx-pane--editor-matcher (cdr k)))))
                              drgnx-pane--kinds))))
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

(defvar drgnx-pane--backends
  `((areas :define drgnx-pane--areas-define :show drgnx-pane--areas-show :hide drgnx-pane--areas-hide
           :window drgnx-pane--areas-window :focus drgnx-pane--areas-focus))
  "Alist BACKEND → plist of the functions that carry out each pane operation.  The dispatch point:
the grid registers `grid' here.  :define takes (KIND SPEC OLD-SPEC), :show (KIND BUFFER SELECT), :hide (KIND),
:window (KIND FRAME), :focus (KIND).")

(defun drgnx-pane--call (op &rest args)
  "Run operation OP (:define, :show, …) of the current `drgnx-pane-backend' with ARGS."
  (let ((fn (plist-get (alist-get drgnx-pane-backend drgnx-pane--backends) op)))
    (unless fn (error "No %s operation for pane backend %s" op drgnx-pane-backend))
    (apply fn args)))

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
STACK: the kind this one stacks with by default (the grid reads it)."
  (let ((home (or home 'bottom)))
    (unless (memq home drgnx-pane--homes) (user-error "Bad pane home %s" home))
    (let ((spec (list :title title :buffer buffer :placeholder placeholder :home home :size size :view view
                      :slot slot :height height :fill fill :on-show on-show :on-focus on-focus :stack stack))
          (old (drgnx-pane-kind kind)))
      (drgnx-pane--call :define kind spec old)         ; first: an error leaves the kinds as they were
      (if old (setf (alist-get kind drgnx-pane--kinds) spec)       ; a new kind goes last, a redefined one stays put
        (setq drgnx-pane--kinds (append drgnx-pane--kinds (list (cons kind spec)))))
      (when fill
        (with-eval-after-load 'drgnx-layouts (drgnx-layouts-define-pane kind fill)))
      kind)))

(cl-defun drgnx-pane-show (kind &key buffer select)
  "Show pane KIND, with BUFFER if given, and return its window.
It never changes the selected window unless SELECT is non-nil.  A left kind ignores BUFFER (a section's
buffer is its own)."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :show kind buffer select))

(defun drgnx-pane-hide (kind)
  "Hide pane KIND when it shows; a kind that is not shown (another view's, a tab behind another) is left alone.
A left kind hides its whole dock.  An editor kind has no hide: it does nothing."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :hide kind))

(defun drgnx-pane-window (kind &optional frame)
  "The window showing pane KIND on FRAME, or nil.
Nil for a kind that is not the front tab of its area or not in the dock's view.  An editor kind's window is the
one showing the last buffer `drgnx-pane-show' or `drgnx-pane-focus' put there on FRAME."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :window kind frame))

(defun drgnx-pane-toggle (kind)
  "Hide pane KIND when it shows, else show it (without selecting).
An editor kind has no hide, so toggling one that shows does nothing."
  (if (drgnx-pane-window kind) (drgnx-pane-hide kind) (drgnx-pane-show kind)))

(defun drgnx-pane-focus (kind)
  "Show pane KIND and move focus to it; returns its window."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :focus kind))

(provide 'drgnx-panes)
;;; drgnx-panes.el ends here
