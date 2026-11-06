;;; drgnx-extensions-index.el --- Extensions: the modes each installed package adds, read from its autoloads -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; <cache>/extensions/modes.eld, written in batch after every change of the packages directory that worked
;; (`drgnx-pkg-after-change-functions'): for each installed package, what its autoloads file — read as data, never
;; evaluated — adds: (PKG :auto ((REGEXP . MODE)…) :interpreter (…) :magic (…) :minor (MODE…) :scope SCOPE).
;; SCOPE is `global' when the autoloads hold an `add-hook', an `advice-add', a global minor mode, a global key binding
;; or a theme (anywhere in them: inside `with-eval-after-load' too); else `narrow' when they add a file-mode entry or
;; a buffer minor mode; else `none'.  Only a `narrow' package can be off in one project (`drgnx-packages-off').
;; See docs/develop/extensions.md, "In one project".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-pkg-progress)

(defun drgnx-extensions-index-file () (expand-file-name "extensions/modes.eld" (drgnx-cache-dir)))

(defconst drgnx-extensions-index--alists
  '((auto-mode-alist . :auto) (interpreter-mode-alist . :interpreter) (magic-mode-alist . :magic)
    (magic-fallback-mode-alist . :magic))
  "The mode alists an autoloads file may add to, and the index key of each.")

(defconst drgnx-extensions-index--global-calls
  '(add-hook advice-add add-function global-set-key global-unset-key keymap-global-set keymap-global-unset
             load-theme enable-theme custom-theme-set-variables custom-theme-set-faces deftheme)
  "Calls that change Emacs as a whole, wherever they are in an autoloads file.")

(defconst drgnx-extensions-index--global-maps
  '(global-map esc-map ctl-x-map ctl-x-4-map ctl-x-5-map ctl-x-r-map mode-specific-map help-map goto-map search-map)
  "Keymaps every buffer sees: a binding in one of them is global.")

(defun drgnx-extensions-index--forms (file)
  "The forms of FILE, read (never evaluated); nil for a file that is not there."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((forms nil) (load-file-name nil) (read-circle nil))
        (condition-case nil (while t (push (read (current-buffer)) forms))
          ((end-of-file invalid-read-syntax) nil))
        (nreverse forms)))))

(defun drgnx-extensions-index--constant (form)
  "FORM's value when it is a constant (a quoted datum, `(cons A B)' of constants, a string, a number), else `:no'."
  (cond ((or (stringp form) (numberp form) (keywordp form) (memq form '(nil t))) form)
        ((memq (car-safe form) '(quote function)) (cadr form))
        ((and (eq (car-safe form) 'cons) (= (length form) 3))
         (let ((a (drgnx-extensions-index--constant (nth 1 form))) (b (drgnx-extensions-index--constant (nth 2 form))))
           (if (or (eq a :no) (eq b :no)) :no (cons a b))))
        (t :no)))

(defun drgnx-extensions-index--global-key-p (form)
  "Whether FORM binds a key in a keymap every buffer sees."
  (and (memq (car-safe form) '(define-key keymap-set keymap-unset))
       (let ((map (nth 1 form)))
         (or (memq map drgnx-extensions-index--global-maps) (equal map '(current-global-map))))))

(defun drgnx-extensions-index-of (file)
  "What the autoloads FILE adds: (:auto :interpreter :magic :minor :scope), read as data."
  (let ((out (list :auto nil :interpreter nil :magic nil)) (minor nil) (vars nil) (global nil))
    (cl-labels ((walk (form)
                  (when (consp form)
                    (pcase form
                      (`(add-to-list (quote ,var) ,elt . ,_)
                       (let ((key (alist-get var drgnx-extensions-index--alists))
                             (e (drgnx-extensions-index--constant elt)))
                         (cond ((eq var 'custom-theme-load-path) (setq global t))
                               ((and key (consp e)) (plist-put out key (append (plist-get out key) (list e)))))))
                      (`(autoload (quote ,name) ,_ ,(and doc (pred stringp)) . ,_)
                       (when (and (symbolp name) (string-suffix-p "-mode" (symbol-name name))
                                  (string-match-p "(fn &optional ARG)\\'" doc))
                         (push name minor)))
                      (`(,(or 'defvar 'custom-autoload) ,var . ,_)
                       (let ((v (if (eq (car form) 'custom-autoload) (drgnx-extensions-index--constant var) var)))
                         (when (symbolp v) (push v vars)))))
                    (when (or (memq (car form) drgnx-extensions-index--global-calls)
                              (drgnx-extensions-index--global-key-p form))
                      (setq global t))
                    (unless (eq (car form) 'quote)
                      (let ((x form)) (while (consp x) (walk (car x)) (setq x (cdr x))))))))
      (mapc #'walk (drgnx-extensions-index--forms file)))
    ;; a minor mode with a variable of its own in the autoloads is a global one
    (let ((globals (seq-filter (lambda (m) (memq m vars)) minor)))
      (when globals (setq global t))
      (setq minor (nreverse (seq-difference minor globals))))
    (append out (list :minor minor
                      :scope (cond (global 'global)
                                   ((or (plist-get out :auto) (plist-get out :interpreter) (plist-get out :magic) minor)
                                    'narrow)
                                   (t 'none))))))

(defun drgnx-extensions-index-build (&optional elpa file)
  "Write the modes index (FILE, default `drgnx-extensions-index-file') of the packages in ELPA (default the packages
directory): ((PKG . PLIST)…), sorted by name.  Returns it."
  (let* ((elpa (file-name-as-directory (or elpa (drgnx-elpa-dir))))
         (index (mapcar (lambda (dir)
                          (let ((name (car (drgnx-pkg--dir-package dir))))
                            (cons (intern name)
                                  (drgnx-extensions-index-of (expand-file-name (format "%s/%s-autoloads.el" dir name) elpa)))))
                        (drgnx-pkg--package-dirs elpa))))
    (drgnx-file-write (or file (drgnx-extensions-index-file)) index
                      :header ";; drgnx: the modes the installed packages add (written after every change; do not edit)")
    index))

(defvar drgnx-extensions-index--cache nil "(STAMP . INDEX) of the modes index last read: one file, one entry.")

(defun drgnx-extensions-index-read ()
  "The modes index ((PKG . PLIST)…), read again only when the file changed; nil when there is none."
  (let* ((file (drgnx-extensions-index-file)) (stamp (drgnx-file-stamp file)))
    (cond ((null stamp) (setq drgnx-extensions-index--cache nil))
          ((equal (car drgnx-extensions-index--cache) stamp) (cdr drgnx-extensions-index--cache))
          (t (let ((data (plist-get (ignore-errors (drgnx-file-read file)) :data)))
               (setq drgnx-extensions-index--cache (cons stamp (and (proper-list-p data) data)))
               (cdr drgnx-extensions-index--cache))))))

(defun drgnx-extensions-index-counts (index)
  "How many packages of INDEX are of each scope: (:narrow N :global N :none N)."
  (let ((n 0) (g 0) (z 0))
    (dolist (e index)
      (pcase (plist-get (cdr e) :scope) ('narrow (cl-incf n)) ('global (cl-incf g)) (_ (cl-incf z))))
    (list :narrow n :global g :none z)))

(defun drgnx-extensions-index-modes (entry)
  "The major modes the index ENTRY (a plist) maps files to."
  (let (out)
    (dolist (key '(:auto :interpreter :magic))
      (dolist (e (plist-get entry key))
        (let ((m (if (consp (cdr e)) (cadr e) (cdr e))))
          (when (and m (symbolp m)) (cl-pushnew m out)))))
    (nreverse out)))

(provide 'drgnx-extensions-index)
;;; drgnx-extensions-index.el ends here
