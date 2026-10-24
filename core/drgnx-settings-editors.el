;;; drgnx-settings-editors.el --- Settings: value editors and validation -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Settings page's editors (design §7): one per kind of type.  Inline for the simple kinds (a toggle, a number
;; with bounds, text, a file or directory with a picker, a drop-down, completion, the Shortcuts recorder), a
;; `widget.el' pane for composite types, a Lisp editor (read by the data reader, checked by the type's `:match') for
;; `sexp' and computed types.  Every value goes through `drgnx-settings-editors-commit': it is checked
;; (`drgnx-setting-check', the bounds), refused when it looks like a credential ("use your keyring") or when the
;; setting is code and the tab is Shared, and then written with `drgnx-settings-file-put'.
;; Plugs into the page through `drgnx-settings-page-editor-function'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)
(require 'drgnx-setting)
(require 'drgnx-file)
(require 'drgnx-settings-file)

(declare-function drgnx-secrets-looks-like "drgnx-secrets" (text))
(declare-function drgnx-settings-page--file "drgnx-settings-page" (tab root))
(declare-function drgnx-settings-page-refresh "drgnx-settings-page" ())
(declare-function drgnx-settings-page--button "drgnx-settings-page" (label fn &optional help))
(declare-function drgnx-settings-page--value-text "drgnx-settings-page" (value))
(defvar drgnx-settings-page--root)
(defvar drgnx-settings-page-editor-function)

;;;; Kinds

(defun drgnx-settings-editors--head (type)
  "The head symbol of the custom TYPE."
  (if (consp type) (car type) type))

(defun drgnx-settings-editors-kind (var)
  "The editor kind of VAR: `toggle', `number', `text', `file', `directory', `choice', `completion', `shortcuts',
`widget' (a composite type) or `lisp' (`sexp', a computed or unknown type)."
  (let* ((type (get var 'custom-type)) (h (drgnx-settings-editors--head type)))
    (cond ((memq h '(boolean)) 'toggle)
          ((memq h '(integer natnum number float)) 'number)
          ((memq h '(string regexp)) 'text)
          ((eq h 'file) 'file)
          ((eq h 'directory) 'directory)
          ((eq h 'key-sequence) 'shortcuts)
          ((eq h 'symbol) 'completion)
          ((and (memq h '(choice radio))
                (cl-every (lambda (o) (and (consp o) (eq (car o) 'const))) (cdr type)))
           'choice)
          ((eq h 'const) 'choice)
          ((memq h '(repeat list cons alist plist set checklist vector group choice radio lazy))
           'widget)
          (t 'lisp))))

(defun drgnx-settings-editors-bounds (var)
  "(MIN . MAX) of a numeric VAR from its type's or schema's `:min' and `:max' (either may be nil)."
  (let* ((type (get var 'custom-type))
         (schema (plist-get (drgnx-setting-meta var) :schema))
         (opts (or (and (consp type) (memq (car type) '(integer number natnum float)) (cdr type))
                   (and (consp schema) (memq (car schema) '(integer number)) (cdr schema)))))
    (cons (plist-get opts :min) (plist-get opts :max))))

;;;; Validation

(defun drgnx-settings-editors--strings (value)
  "Every string in VALUE, joined by newlines."
  (let (out)
    (cl-labels ((walk (x) (cond ((stringp x) (push x out))
                                ((consp x) (walk (car x)) (walk (cdr x)))
                                ((vectorp x) (mapc #'walk x)))))
      (walk value))
    (mapconcat #'identity (nreverse out) "\n")))

(defun drgnx-settings-editors-check (var value tab)
  "Nil when VALUE may be saved for VAR at TAB, else `(PATH . MESSAGE)' naming why."
  (let ((b (and (numberp value) (drgnx-settings-editors-bounds var)))
        (code (eq (plist-get (drgnx-setting-meta var) :workspace) 'code)))
    (or (and b (car b) (< value (car b)) (cons nil (format "%s is below the lowest allowed, %s" value (car b))))
        (and b (cdr b) (> value (cdr b)) (cons nil (format "%s is above the highest allowed, %s" value (cdr b))))
        (drgnx-setting-check var value)
        (and code (eq tab 'shared)
             (cons nil (format "%s is code: it is saved in User or your Workspace file, never in Shared" var)))
        (progn (require 'drgnx-secrets)
               (when-let* ((rule (drgnx-secrets-looks-like (drgnx-settings-editors--strings value))))
                 (cons nil (format "that looks like a secret (%s): use your keyring, not a setting" rule)))))))

(defun drgnx-settings-editors-commit (var tab root value)
  "Check VALUE and save it as VAR's entry at TAB for ROOT.  A refused value is a `user-error' naming its path."
  (when-let* ((bad (drgnx-settings-editors-check var value tab)))
    (user-error "%s: %s%s" var (if (car bad) (format "%s: " (car bad)) "") (cdr bad)))
  (let ((f (drgnx-settings-page--file tab root)))
    (unless f (user-error "%s: there is no settings file at the %s tab" var tab))
    (drgnx-settings-file-put (car f) (cdr f) nil var value)
    (clrhash (symbol-value 'drgnx-settings-page--docs))
    value))

;;;; The Lisp editor

(defun drgnx-settings-editors-read-lisp (text)
  "TEXT read as one data form by the data reader (`drgnx-file--parse'); a `user-error' when it does not read."
  (pcase (drgnx-file--parse text)
    (`(ok . ,x) (drgnx-settings-file--unquote x))
    (`(problem . ,p) (user-error "Does not read as data: %s" (if (consp p) (or (plist-get p :message) p) p)))
    (_ (user-error "Write one value"))))

;;;; Asking

(defun drgnx-settings-editors--ask (var kind current)
  "Ask the user for VAR's new value of KIND; CURRENT is the value now."
  (pcase kind
    ('toggle (not current))
    ('number (let* ((b (drgnx-settings-editors-bounds var))
                    (n (read-number (format "%s%s: " var (if (or (car b) (cdr b)) (format " [%s..%s]" (or (car b) "") (or (cdr b) "")) ""))
                                    (and (numberp current) current))))
               n))
    ('text (read-string (format "%s: " var) (and (stringp current) current)))
    ('file (read-file-name (format "%s: " var) nil nil nil (and (stringp current) current)))
    ('directory (read-directory-name (format "%s: " var) nil nil nil (and (stringp current) current)))
    ('choice (let ((pick (completing-read
                          (format "%s: " var)
                          (mapcar #'prin1-to-string (drgnx-settings-editors--consts (get var 'custom-type)))
                          nil t (prin1-to-string current))))
               (car (read-from-string pick))))
    ('completion (intern (completing-read (format "%s: " var) (mapcar #'symbol-name (and (symbolp current) (list current)))
                                          nil nil (and current (symbol-name current)))))
    ('shortcuts (let ((keys (read-key-sequence (format "%s, press the keys: " var))))
                  (kbd (key-description keys))))
    (_ (drgnx-settings-editors-read-lisp
        (read-from-minibuffer (format "%s (Lisp data): " var) (prin1-to-string current))))))

(defun drgnx-settings-editors--consts (type)
  "The values of the `const' alternatives of TYPE."
  (if (eq (car-safe type) 'const)
      (list (car (last type)))
    (mapcar (lambda (o) (car (last o))) (cdr type))))

;;;; The widget pane

(defvar-local drgnx-settings-editors--pane nil "(VAR TAB ROOT WIDGET) of a widget pane.")

(defun drgnx-settings-editors-widget-pane (var tab root value)
  "Open the widget pane of VAR (a composite type) at TAB for ROOT, holding VALUE; returns its buffer."
  (let ((buf (get-buffer-create (format "*Setting: %s*" var))))
    (with-current-buffer buf
      (kill-all-local-variables)
      (let ((inhibit-read-only t)) (erase-buffer))
      (remove-overlays)
      (widget-insert (format "%s\n\n" var))
      (let ((w (widget-create (widget-convert (get var 'custom-type)) :tag (symbol-name var) :value value)))
        (setq drgnx-settings-editors--pane (list var tab root w)))
      (widget-insert "\n")
      (widget-create 'push-button :notify (lambda (&rest _) (drgnx-settings-editors-pane-apply)) "Apply")
      (widget-insert " ")
      (widget-create 'push-button :notify (lambda (&rest _) (kill-buffer (current-buffer))) "Cancel")
      (widget-insert "\n")
      (use-local-map widget-keymap)
      (widget-setup)
      (goto-char (point-min)))
    buf))

(defun drgnx-settings-editors-pane-apply ()
  "Save the widget pane's value; the pane closes when it is saved."
  (interactive)
  (pcase-let ((`(,var ,tab ,root ,w) drgnx-settings-editors--pane))
    (drgnx-settings-editors-commit var tab root (widget-value w))
    (kill-buffer (current-buffer))
    (when (fboundp 'drgnx-settings-page-refresh)
      (ignore-errors (drgnx-settings-page-refresh)))))

;;;; Drawing

(defun drgnx-settings-editors--act (var tab root kind current)
  "Edit VAR: ask (or open the pane), then save."
  (if (eq kind 'widget)
      (pop-to-buffer (drgnx-settings-editors-widget-pane var tab root current))
    (drgnx-settings-editors-commit var tab root (drgnx-settings-editors--ask var kind current))
    (when (fboundp 'drgnx-settings-page-refresh) (drgnx-settings-page-refresh))))

(defun drgnx-settings-editors-draw (row)
  "The editor of ROW as a string: the value at the tab and a button that edits it."
  (if (plist-get row :global-only) ""
    (let* ((var (plist-get row :var)) (tab (plist-get row :tab))
           (root (and (boundp 'drgnx-settings-page--root) drgnx-settings-page--root))
           (kind (drgnx-settings-editors-kind var))
           (current (if (plist-get row :entry-p) (plist-get row :tab-value) (plist-get row :effective))))
      (concat (if (eq kind 'toggle)
                  (format "%s " (if current "[x] on" "[ ] off"))
                (format "Value: %s " (drgnx-settings-page--value-text current)))
              (drgnx-settings-page--button
               (if (eq kind 'toggle) "Toggle" "Edit")
               (lambda () (drgnx-settings-editors--act var tab root kind current))
               (format "Edit %s (%s)" var kind))))))

(setq drgnx-settings-page-editor-function #'drgnx-settings-editors-draw)

(provide 'drgnx-settings-editors)
;;; drgnx-settings-editors.el ends here
