;;; drgnx-setting.el --- Settings: drgnx-defsetting and the metadata -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-defsetting' declares one of drgnx's own settings: a `defcustom' plus drgnx's keys, kept in the symbol
;; property `drgnx-setting'.  `drgnx-setting-meta' gives the eight keys of any variable, declared or inferred from
;; Emacs's own data (docs/develop/settings.md, "Declaring a setting").  `drgnx-setting-check' tests a value.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-schema)

(defconst drgnx-setting-keys '(:scope :workspace :merge :on-error :apply :runtime :agents :schema)
  "drgnx's keys of a setting, in the order `drgnx-setting-meta' returns them.")

(defconst drgnx-setting--defcustom-keys
  '(:type :options :set :get :initialize :group :require :version :package-version :link :load :tag :set-after
          :local :risky :safe :standard :prefix :help-echo :custom :documentation-property)
  "The keywords `defcustom' itself accepts; every other keyword of `drgnx-defsetting' must be one of drgnx's.")

(defconst drgnx-setting--code-suffixes '("-interpreter" "-executable" "-program-name" "-args" "-arguments")
  "Name endings that mark a setting holding a program or its arguments (design 4.4): `:workspace code'.")

(defconst drgnx-setting--never-names
  '(enable-local-variables enable-local-eval ignored-local-variables trusted-content custom-file load-path
                           package-archives drgnx-user-lisp-files)
  "Emacs's and drgnx's security settings that no workspace may set (design 13): `:workspace never'.")

(defconst drgnx-setting--never-prefixes '("safe-local-variable-" "drgnx-trust-")
  "Name prefixes of the same set.")

(defvar drgnx-setting-meta-functions nil
  "Functions that refine a setting's metadata (the described settings, Task 31).
Each is called with the variable and its plist so far and returns a plist of the keys it overrides, or nil.")

(defvar drgnx-setting--names nil "Every variable declared through `drgnx-defsetting'.")
(defvar drgnx-setting--cache (make-hash-table :test 'eq) "Symbol -> (STAMP . META); see `drgnx-setting--stamp'.")

;;;; Declaring

(defun drgnx-setting--declare (var plist)
  "Record PLIST as the drgnx keys of VAR."
  (put var 'drgnx-setting plist)
  (cl-pushnew var drgnx-setting--names)
  (remhash var drgnx-setting--cache)
  var)

(defmacro drgnx-defsetting (name default doc &rest args)
  "Declare the setting NAME as a `defcustom' with default DEFAULT and documentation DOC.
ARGS are `defcustom' keywords and drgnx's: `:scope', `:workspace', `:merge', `:on-error', `:apply', `:runtime',
`:agents', `:schema' (values are evaluated, as in `defcustom').  drgnx's keys go to the symbol property
`drgnx-setting'; any other unknown keyword is an error when the form is compiled."
  (declare (indent defun) (doc-string 3))
  (let (custom own)
    (while args
      (let ((key (pop args)))
        (unless (keywordp key) (error "drgnx-defsetting %s: %S is not a keyword" name key))
        (unless args (error "drgnx-defsetting %s: %s has no value" name key))
        (let ((value (pop args)))
          (cond ((memq key drgnx-setting-keys) (setq own (append own (list key value))))
                ((memq key drgnx-setting--defcustom-keys) (setq custom (append custom (list key value))))
                (t (error "drgnx-defsetting %s: unknown key %s" name key))))))
    `(progn
       (defcustom ,name ,default ,doc ,@custom)
       (drgnx-setting--declare ',name (list ,@own)))))

(defun drgnx-setting-own-p (var)
  "Non-nil when VAR was declared with `drgnx-defsetting', with or without drgnx's keys."
  (and (memq var drgnx-setting--names) t))

(defun drgnx-setting-names ()
  "Every setting declared with `drgnx-defsetting', as a list of symbols."
  (copy-sequence drgnx-setting--names))

;;;; Inference (design 4.4)

(defun drgnx-setting--type-has-p (type words)
  "Non-nil when the widget TYPE is or contains one of the symbols WORDS."
  (cond ((symbolp type) (and (memq type words) t))
        ((consp type) (or (drgnx-setting--type-has-p (car type) words)
                          (let ((rest (cdr type)) found)
                            (while (and (consp rest) (not found))
                              (setq found (drgnx-setting--type-has-p (pop rest) words)))
                            found)))))

(defun drgnx-setting--global-mode-p (var)
  "Non-nil when VAR is the variable of a global minor mode."
  (or (eq (get var 'custom-set) 'custom-set-minor-mode)
      (let ((name (symbol-name var)))
        (and (string-suffix-p "-mode" name)
             (commandp (intern-soft name))
             (not (with-temp-buffer (local-variable-if-set-p var)))))))

(defun drgnx-setting--never-p (var)
  "Non-nil when VAR is on the deny-list of design 13 that names variables."
  (or (memq var drgnx-setting--never-names)
      (let ((name (symbol-name var)))
        (cl-some (lambda (prefix) (string-prefix-p prefix name)) drgnx-setting--never-prefixes))))

(defun drgnx-setting--code-p (var)
  "Non-nil when VAR is code by name or type (design 4.4)."
  (or (risky-local-variable-p var)
      (let ((name (symbol-name var)))
        (cl-some (lambda (suffix) (string-suffix-p suffix name)) drgnx-setting--code-suffixes))
      (drgnx-setting--type-has-p (get var 'custom-type) '(function hook))))

(defun drgnx-setting--infer (var)
  "The plist of all eight keys for VAR: declared, else inferred."
  (let* ((own (get var 'drgnx-setting))
         (workspace (cond ((plist-member own :workspace) (plist-get own :workspace))
                          ((drgnx-setting--never-p var) 'never)
                          ((drgnx-setting--code-p var) 'code)
                          (t 'data))))
    (list :scope (if (plist-member own :scope) (plist-get own :scope)
                   (if (drgnx-setting--global-mode-p var) 'global 'buffer))
          :workspace workspace
          :merge (if (plist-member own :merge) (plist-get own :merge) 'replace)
          :on-error (if (plist-member own :on-error) (plist-get own :on-error) 'last-good)
          :apply (plist-get own :apply)
          :runtime (plist-get own :runtime)
          :agents (if (plist-member own :agents) (plist-get own :agents)
                    (if (memq workspace '(code never)) 'never 'grantable))
          :schema (plist-get own :schema))))

(defun drgnx-setting--stamp (var)
  "What the metadata of VAR depends on; the cache entry is valid while every part is `eq'.
A new `defcustom' of VAR makes fresh `standard-value' and `custom-type' objects, which clears the cache entry."
  (list (get var 'standard-value) (get var 'custom-type) (get var 'drgnx-setting) (get var 'custom-set)
        (get var 'risky-local-variable) drgnx-setting-meta-functions))

(defun drgnx-setting--stamp-equal (a b)
  "Non-nil when the stamps A and B have `eq' parts."
  (and (eq (length a) (length b)) (cl-every #'eq a b)))

(defun drgnx-setting-meta (var)
  "The metadata of VAR as a plist with all of `drgnx-setting-keys'.
Declared keys win; the rest are inferred (design 4.4); then each of `drgnx-setting-meta-functions' may override.
`safe' for `:workspace' is never inferred: it is decided per value with `safe-local-variable-p'.  Cached per
symbol; a new declaration of VAR clears it."
  (let ((stamp (drgnx-setting--stamp var))
        (hit (gethash var drgnx-setting--cache)))
    (if (and hit (drgnx-setting--stamp-equal (car hit) stamp))
        (cdr hit)
      (let ((meta (drgnx-setting--infer var)))
        (dolist (fn drgnx-setting-meta-functions)
          (let ((over (funcall fn var meta)))
            (while over (setq meta (plist-put meta (pop over) (pop over))))))
        (puthash var (cons stamp meta) drgnx-setting--cache)
        meta))))

;;;; Checking

(defun drgnx-setting-check (var value)
  "Check VALUE for VAR: nil, or `(PATH . MESSAGE)' for the first problem.
A `:schema' goes to `drgnx-schema-check'; otherwise the `:type' of the `defcustom' must match."
  (if-let* ((schema (plist-get (drgnx-setting-meta var) :schema)))
      (drgnx-schema-check schema value)
    (when-let* ((type (get var 'custom-type)))
      (require 'wid-edit)
      (unless (widget-apply (widget-convert type) :match value)
        (cons nil (format "%S does not match the type %S" value type))))))

(provide 'drgnx-setting)
;;; drgnx-setting.el ends here
