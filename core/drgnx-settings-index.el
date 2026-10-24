;;; drgnx-settings-index.el --- Settings: every package's defcustoms, read without loading -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx sync' reads every installed package's and Emacs's own `.el' files as text and writes
;; `<cache>/settings-index.eld' (design 10.1): the `defgroup's and `defcustom's with symbol, group, package, file,
;; line, the `:type' when it is literal, the documentation, `:safe' and `:risky'.  Nothing is loaded or evaluated:
;; the files are only `read' (with `read-eval' off).  The Settings page shows the entries of packages that are not
;; loaded yet; a computed `:type' has none here, so the Lisp editor serves until the package loads.
;; The Workspace group's "Other tools" (design 10.3) is the list of other tools' files in a folder.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)

(defvar read-eval)
(defvar read-circle)
(defvar drgnx-settings-index--cache nil "(FILE STAMP . TABLES) of the index last read; see `drgnx-settings-index--tables'.")

(defconst drgnx-settings-index-head'drgnx-settings-index "The head of the index file's one data form.")

(defconst drgnx-settings-index-other-tools
  '(".editorconfig" ".prettierrc" ".prettierrc.json" ".prettierrc.yml" ".prettierrc.yaml" ".prettierrc.js"
    ".prettierrc.toml" "pyproject.toml" ".clang-format" ".clangd" "rust-analyzer.toml" "tsconfig.json"
    ".eslintrc" ".eslintrc.json" ".eslintrc.js" ".eslintrc.yml" ".eslintrc.yaml" "biome.json" ".golangci.yml"
    ".golangci.yaml" ".ruff.toml" "ruff.toml")
  "Other tools' files that sit in a workspace (design 10.3): listed with [Open], never imported or written.")

;;;; Reading the sources

(defun drgnx-settings-index--literal (form)
  "The value of the literal FORM (`'X' or `#'X'), else the symbol `computed'."
  (if (and (consp form) (memq (car form) '(quote function)) (consp (cdr form)))
      (cadr form)
    (if (or (keywordp form) (null form) (eq form t) (stringp form) (numberp form)) form 'computed)))

(defun drgnx-settings-index--args (rest)
  "The keyword arguments of a `defcustom'/`defgroup' form after its documentation: REST as a plist."
  (let (out)
    (while (and (consp rest) (keywordp (car rest)) (consp (cdr rest)))
      (setq out (plist-put out (car rest) (cadr rest)) rest (cddr rest)))
    out))

(defun drgnx-settings-index--entry (form package file line)
  "The index entry of FORM (a `defcustom' or `defgroup' read from FILE at LINE of PACKAGE), or nil."
  (pcase form
    (`(defcustom ,(and var (pred symbolp)) ,_ ,(and doc (pred stringp)) . ,rest)
     (let* ((a (drgnx-settings-index--args rest))
            (type (drgnx-settings-index--literal (plist-get a :type)))
            (safe (drgnx-settings-index--literal (plist-get a :safe)))
            (risky (drgnx-settings-index--literal (plist-get a :risky)))
            (group (drgnx-settings-index--literal (plist-get a :group))))
       (append (list :var var :package package :file file :line line :doc doc)
               (and (symbolp group) (not (eq group 'computed)) group (list :group group))
               (if (or (eq type 'computed) (null type)) (list :computed t) (list :type type))
               (and (plist-member a :safe) (not (eq safe 'computed)) (list :safe safe))
               (and (plist-member a :risky) (not (eq risky 'computed)) (list :risky risky)))))
    (`(defgroup ,(and group (pred symbolp)) ,_ ,(and doc (pred stringp)) . ,rest)
     (let ((parent (drgnx-settings-index--literal (plist-get (drgnx-settings-index--args rest) :group))))
       (append (list :defgroup group :package package :file file :line line :doc doc)
               (and (symbolp parent) (not (eq parent 'computed)) parent (list :group parent)))))))

(defun drgnx-settings-index-scan-file (file package &optional name)
  "The entries of the `defgroup' and `defcustom' forms in FILE, owned by PACKAGE (a string).
Top-level forms and the bodies of `progn' and `eval-and-compile' are read; nothing is evaluated.  NAME is the file name
recorded (default FILE's base name).  A file that cannot be read gives what was read before the problem."
  (let ((name (or name (file-name-nondirectory file))) out
        (read-eval nil) (read-circle nil))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (goto-char (point-min))
      (condition-case nil
          (while (progn (forward-comment (buffer-size)) (not (eobp)))
            (let* ((line (line-number-at-pos))
                   (form (read (current-buffer))))
              (cl-labels ((walk (f)
                            (if (memq (car-safe f) '(progn eval-and-compile))
                                (mapc #'walk (cdr f))
                              (when-let* ((e (drgnx-settings-index--entry f package name line)))
                                (push e out)))))
                (walk form))))
        (error nil)))
    (nreverse out)))

(defun drgnx-settings-index--package-name (dir)
  "The package a directory DIR of the packages directory holds: its name without the version."
  (let ((base (file-name-nondirectory (directory-file-name dir))))
    (if (string-match "\\`\\(.+?\\)-[0-9][0-9.]*\\(?:pre\\|snapshot\\|beta\\|rc\\|-.*\\)?\\'" base)
        (match-string 1 base)
      base)))

(defun drgnx-settings-index--files (dir)
  "The settings-bearing `.el' files under DIR, sorted: autoloads, package descriptors, loaddefs and tests left out."
  (cl-remove-if (lambda (f) (string-match-p "\\(?:-autoloads\\|-pkg\\|loaddefs\\|-tests?\\|/tests?/\\|/\\.\\)" f))
                (directory-files-recursively dir "\\.el\\'")))

(defun drgnx-settings-index--scan-tree (dir package)
  "The entries of every file under DIR, owned by PACKAGE, with file names relative to DIR."
  (cl-loop for f in (drgnx-settings-index--files dir)
           append (drgnx-settings-index-scan-file f package (file-relative-name f dir))))

(defun drgnx-settings-index-sources ()
  "The (DIR . PACKAGE) pairs the index reads: each installed package and Emacs's own Lisp."
  (append
   (let ((elpa (drgnx-elpa-dir)))
     (and (file-directory-p elpa)
          (cl-loop for d in (directory-files elpa t "\\`[^.]")
                   when (file-directory-p d)
                   collect (cons d (drgnx-settings-index--package-name d)))))
   (let ((lisp (and (boundp 'lisp-directory) (stringp lisp-directory) lisp-directory)))
     (and lisp (file-directory-p lisp) (list (cons lisp "Emacs"))))))

;;;; Writing and reading the index

(defun drgnx-settings-index-file ()
  "Where the index is: `settings-index.eld' in the cache directory."
  (expand-file-name "settings-index.eld" (drgnx-cache-dir)))

(defun drgnx-settings-index-build (&optional sources file)
  "Write the settings index of SOURCES (default `drgnx-settings-index-sources') to FILE (default
`drgnx-settings-index-file'), atomically; the number of entries.  Reads files as text, loads nothing."
  (let* ((file (or file (drgnx-settings-index-file)))
         (entries (cl-loop for (dir . package) in (or sources (drgnx-settings-index-sources))
                           append (drgnx-settings-index--scan-tree dir package))))
    ;; the reader's limit (`drgnx-settings-index--tables')
    (drgnx-file-write file (cons drgnx-settings-index-head (cons :version (cons 1 entries)))
                      :header ";; Written by `drgnx sync': the settings of every installed package, read without loading them."
                      :max-bytes (* 64 1024 1024))
    (setq drgnx-settings-index--cache nil)
    (length entries)))

(defun drgnx-settings-index--tables ()
  "The index as (VARS . GROUPS): hash tables var -> entry and group -> entry; read again when the file changed."
  (let* ((file (drgnx-settings-index-file))
         (stamp (ignore-errors (file-attributes file))))
    (if (and drgnx-settings-index--cache (equal (car drgnx-settings-index--cache) file)
             (equal (cadr drgnx-settings-index--cache) stamp))
        (cddr drgnx-settings-index--cache)
      (let ((vars (make-hash-table :test 'eq)) (groups (make-hash-table :test 'eq))
            (r (and stamp (drgnx-file-read file :max-bytes (* 64 1024 1024)))))
        (when (eq (plist-get r :status) 'ok)
          (let ((data (plist-get r :data)))
            (when (eq (car-safe data) drgnx-settings-index-head)
              (dolist (e (cdddr data))
                (cond ((plist-get e :var) (unless (gethash (plist-get e :var) vars)
                                            (puthash (plist-get e :var) e vars)))
                      ((plist-get e :defgroup) (unless (gethash (plist-get e :defgroup) groups)
                                                 (puthash (plist-get e :defgroup) e groups))))))))
        (setq drgnx-settings-index--cache (cons file (cons stamp (cons vars groups))))
        (cons vars groups)))))

(defun drgnx-settings-index-entry (var)
  "VAR's index entry (a plist), or nil."
  (gethash var (car (drgnx-settings-index--tables))))

(defun drgnx-settings-index-type (var)
  "The literal `:type' the index holds for VAR, or nil (not indexed, or computed: the Lisp editor serves)."
  (plist-get (drgnx-settings-index-entry var) :type))

(defun drgnx-settings-index-doc (var)
  "VAR's documentation from the index, or nil."
  (plist-get (drgnx-settings-index-entry var) :doc))

(defun drgnx-settings-index-unloaded-p (var)
  "Non-nil when VAR is in the index and its package has not defined it yet."
  (and (not (get var 'standard-value)) (drgnx-settings-index-entry var) t))

(defun drgnx-settings-index-group-members (group)
  "The indexed variables of the `defgroup' GROUP and of its subgroups that are not defined yet, sorted by name."
  (let* ((tables (drgnx-settings-index--tables)) (seen (make-hash-table :test 'eq)) out)
    (cl-labels ((in-group (g)
                  (unless (gethash g seen)
                    (puthash g t seen)
                    (maphash (lambda (v e) (when (and (eq (plist-get e :group) g) (not (get v 'standard-value)))
                                             (push v out)))
                             (car tables))
                    (maphash (lambda (sub e) (when (eq (plist-get e :group) g) (in-group sub))) (cdr tables)))))
      (in-group group))
    (sort (delete-dups out) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun drgnx-settings-index-top-groups (builtin)
  "The indexed top-level groups (no parent group) with a variable not defined yet: Emacs's own when BUILTIN, else
the packages'."
  (let* ((tables (drgnx-settings-index--tables)) out)
    (maphash (lambda (g e)
               (when (and (null (plist-get e :group))
                          (eq (and builtin t) (equal (plist-get e :package) "Emacs"))
                          (drgnx-settings-index-group-members g))
                 (push g out)))
             (cdr tables))
    out))

;;;; Other tools' files (design 10.3)

(defun drgnx-settings-index-other-tools-in (root)
  "The other tools' files that exist in ROOT, as absolute names (see `drgnx-settings-index-other-tools')."
  (when (and root (file-directory-p root))
    (cl-loop for name in drgnx-settings-index-other-tools
             for f = (expand-file-name name root)
             when (file-regular-p f) collect f)))

(provide 'drgnx-settings-index)
;;; drgnx-settings-index.el ends here
