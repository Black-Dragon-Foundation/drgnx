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
  "The buffer KIND shows when nothing else is given: SPEC's :buffer or :placeholder function, else a blank one."
  (let ((fn (or (plist-get spec :buffer) (plist-get spec :placeholder))))
    (cond ((functionp fn) (funcall fn))
          (t (or (get-buffer (format " *drgnx %s*" kind))
                 (with-current-buffer (get-buffer-create (format " *drgnx %s*" kind) t)
                   (special-mode)
                   (current-buffer)))))))

;;;; The `areas' backend: forwards to today's docks

(defun drgnx-pane--areas-define (kind spec old)
  "Forward KIND's SPEC to the docks; OLD, the spec it replaces, is taken out of its dock first."
  (when (and old (not (eq (plist-get old :home) (plist-get spec :home))))
    (setq drgnx-wb--sections (assq-delete-all kind drgnx-wb--sections))
    (when-let* ((area (alist-get (plist-get old :home) drgnx-pane--areas))
                (spec (alist-get area drgnx-wb--areas)))
      (setf (alist-get area drgnx-wb--areas)
            (plist-put (copy-sequence spec) :tabs (assq-delete-all kind (copy-sequence (plist-get spec :tabs)))))))
  (pcase (plist-get spec :home)
    ('left
     (drgnx-wb-define-section
      kind :slot (or (plist-get spec :slot) 0) :title (plist-get spec :title)
      :buffer (lambda () (drgnx-pane--buffer (drgnx-pane--spec kind) kind))
      :height (plist-get spec :height) :view (plist-get spec :view)
      :on-show (plist-get spec :on-show) :on-focus (plist-get spec :on-focus)))
    ((or 'bottom 'right)
     (drgnx-wb-define-tab (drgnx-pane--area kind) kind :title (plist-get spec :title)
                          :placeholder (lambda () (drgnx-pane--buffer (drgnx-pane--spec kind) kind))))
    ('editor
     (when-let* ((b (plist-get spec :buffer))
                 (name (cond ((stringp b) b) ((bufferp b) (buffer-name b)))))
       (drgnx-wb-place (concat "\\`" (regexp-quote name) "\\'") 'editor)))))

(defun drgnx-pane--areas-window (kind &optional frame)
  (let ((spec (drgnx-pane--spec kind)))
    (pcase (plist-get spec :home)
      ('left (drgnx-wb-section-window kind frame))
      ((or 'bottom 'right)
       (let ((area (drgnx-pane--area kind)))
         (with-selected-frame (or frame (selected-frame))
           (and (eq (drgnx-wb-area-tab area) kind) (drgnx-wb-area-window area frame)))))
      ('editor
       (let ((b (plist-get spec :buffer)))
         (when-let* ((b (if (stringp b) (get-buffer b) b)) ((bufferp b)))
           (get-buffer-window b (or frame t))))))))

(defun drgnx-pane--areas-show (kind buffer select)
  (let* ((spec (drgnx-pane--spec kind)) (home (plist-get spec :home))
         (selected (selected-window)))
    (prog1
        (pcase home
          ('left
           (drgnx-wb-show-view (or (plist-get spec :view) 'explorer))
           (if select (progn (drgnx-wb-focus-section kind) (drgnx-wb-section-window kind))
             (drgnx-wb-section-window kind)))
          ((or 'bottom 'right)
           (let ((w (drgnx-wb-area-show (drgnx-pane--area kind) kind buffer)))
             (when-let* ((fn (plist-get spec :on-show))) (funcall fn w))
             (when select (select-window w))
             w))
          ('editor
           (let ((b (or buffer (drgnx-pane--buffer spec kind))))
             (drgnx-wb-show-in-editor b select))))
      (unless (or select (eq (selected-window) selected) (not (window-live-p selected)))
        (select-window selected 'norecord)))))

(defun drgnx-pane--areas-hide (kind)
  (pcase (plist-get (drgnx-pane--spec kind) :home)
    ('left (drgnx-wb-hide-sidebar))      ; the dock hides as a whole
    ((or 'bottom 'right)
     (when (drgnx-pane--areas-window kind) (drgnx-wb-area-hide (drgnx-pane--area kind))))))

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
function).  BUFFER: a function returning the kind's buffer (an `editor' kind: its buffer's name, which
`drgnx-wb-place' sends to the editor).  PLACEHOLDER: a function returning the buffer shown while there is
none.  SIZE: columns or lines the first time (the grid reads it; the docks keep their own).  VIEW: the sidebar
view a `left' kind belongs to.  SLOT and HEIGHT: as `drgnx-wb-define-section's.  FILL: a function of the
window, as `drgnx-layouts-define-pane's filler.  ON-SHOW and ON-FOCUS: functions of the window.  STACK: the
kind this one stacks with by default (the grid reads it)."
  (let ((home (or home 'bottom)))
    (unless (memq home drgnx-pane--homes) (user-error "Bad pane home %s" home))
    (let ((spec (list :title title :buffer buffer :placeholder placeholder :home home :size size :view view
                      :slot slot :height height :fill fill :on-show on-show :on-focus on-focus :stack stack)))
      (let ((old (drgnx-pane-kind kind)))
        (if old (setf (alist-get kind drgnx-pane--kinds) spec)       ; a new kind goes last, a redefined one stays put
          (setq drgnx-pane--kinds (append drgnx-pane--kinds (list (cons kind spec)))))
        (drgnx-pane--call :define kind spec old))
      (when fill
        (with-eval-after-load 'drgnx-layouts (drgnx-layouts-define-pane kind fill)))
      kind)))

(cl-defun drgnx-pane-show (kind &key buffer select)
  "Show pane KIND, with BUFFER if given, and return its window.
It never changes the selected window unless SELECT is non-nil."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :show kind buffer select))

(defun drgnx-pane-hide (kind)
  "Hide pane KIND (a left kind hides its whole dock; an editor kind cannot hide)."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :hide kind))

(defun drgnx-pane-window (kind &optional frame)
  "The window showing pane KIND on FRAME, or nil."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :window kind frame))

(defun drgnx-pane-toggle (kind)
  "Hide pane KIND when it shows, else show it (without selecting)."
  (if (drgnx-pane-window kind) (drgnx-pane-hide kind) (drgnx-pane-show kind)))

(defun drgnx-pane-focus (kind)
  "Show pane KIND and move focus to it; returns its window."
  (drgnx-pane--spec kind)
  (drgnx-pane--call :focus kind))

(provide 'drgnx-panes)
;;; drgnx-panes.el ends here
