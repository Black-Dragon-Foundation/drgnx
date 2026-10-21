;;; drgnx-owner.el --- Who owns a Lisp file: a package, an Emacs library or a drgnx module -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-owner-of-file' names who a Lisp file belongs to, so measurements can be told by owner: the heap audit
;; (core/drgnx-heap.el) and, later, the stall watchdog's package functions.  A file is a package's when it lies in that
;; package's directory (from `package-alist', or, in a session started from the quickstart file, which leaves
;; `package-alist' empty, from the directory's name under `package-user-dir' and `package-directory-list'); Emacs's
;; when it lies under `lisp-directory'; drgnx's when it lies in drgnx's tree (a module's file names the module).
;; Names are compared as text: nothing here reads the disk or follows a link.  See docs/guide/speed.md.

;;; Code:
(require 'seq)
(require 'drgnx-paths)

(defvar package-alist)
(defvar package-user-dir)
(defvar package-directory-list)
(defvar drgnx-modules--table)
(declare-function package-desc-dir "package-activate")

(defvar drgnx-owner--package-dirs (cons nil nil)
  "(KEY . DIRS): DIRS, a list of (DIRECTORY . PACKAGE-NAME) longest first, built from `package-alist' when it was KEY,
a cons (ALIST . LENGTH).  A package upgraded in place keeps the key; its new directory is still named by the
directory rule of `drgnx-owner--package-from-dir'.")

(defun drgnx-owner--package-dirs ()
  "(DIRECTORY . PACKAGE-NAME) for each package of `package-alist', longest first; rebuilt when `package-alist' changes."
  (let* ((alist (bound-and-true-p package-alist))
         (key (and alist (cons alist (length alist)))))
    (unless (equal key (car drgnx-owner--package-dirs))
      (let (dirs)
        (dolist (entry alist)
          (dolist (desc (cdr entry))
            (let ((dir (ignore-errors (package-desc-dir desc))))
              (when (stringp dir)                ; a built-in package's is the symbol `builtin'
                (push (cons (file-name-as-directory (drgnx-owner--expand dir)) (symbol-name (car entry))) dirs)))))
        (setq drgnx-owner--package-dirs
              (cons key (sort dirs (lambda (a b) (> (length (car a)) (length (car b)))))))))
    (cdr drgnx-owner--package-dirs)))

(defun drgnx-owner--expand (file)
  "FILE expanded locally: no file name handler, a relative name taken from `lisp-directory' (the names
`load-history' keeps for the files dumped into Emacs are relative to it)."
  (let ((file-name-handler-alist nil) (default-directory "/"))
    (expand-file-name file (and (not (file-name-absolute-p file)) lisp-directory))))

(defun drgnx-owner--library (file)
  "FILE's library name: its base name without .el, .elc, .eln or .gz."
  (let ((base (file-name-nondirectory file)))
    (while (string-match "\\.\\(?:elc\\|el\\|eln\\|gz\\)\\'" base)
      (setq base (substring base 0 (match-beginning 0))))
    base))

(defun drgnx-owner--sans-suffix (file)
  "FILE without .el, .elc, .eln or .gz at its end."
  (concat (file-name-directory file) (drgnx-owner--library file)))

(defconst drgnx-owner--version-re "\\`\\(.+\\)-[0-9][0-9.]*\\(?:[a-z]+[0-9.]*\\)?\\'"
  "A package directory's name, NAME-VERSION (1.0, 20240101.1234, 0.3pre …); group 1 is NAME.")

(defun drgnx-owner--package-from-dir (file)
  "The package FILE belongs to by its directory: the first directory below `package-user-dir' or one of
`package-directory-list', its version taken off; nil for a file at their top (a quickstart file) or elsewhere."
  (catch 'found
    (dolist (root (cons (bound-and-true-p package-user-dir) (bound-and-true-p package-directory-list)))
      (when (stringp root)
        (let ((root (file-name-as-directory (drgnx-owner--expand root))))
          (when (string-prefix-p root file)
            (let* ((rest (substring file (length root)))
                   (slash (string-search "/" rest)))
              (when (and slash (> slash 0))
                (let ((dir (substring rest 0 slash)))
                  (throw 'found (if (string-match drgnx-owner--version-re dir) (match-string 1 dir) dir)))))))))))

(defun drgnx-owner--drgnx-detail (file)
  "The drgnx detail of FILE, a name in drgnx's tree: the module whose file it is (\"tools/agents\"), else its path in
the tree without the suffix (\"core/drgnx-gc\")."
  (let ((stem (drgnx-owner--sans-suffix file)))
    (or (catch 'module
          (dolist (m (bound-and-true-p drgnx-modules--table))
            (let ((f (plist-get (cdr m) :file)))
              (when (and (stringp f) (equal (drgnx-owner--sans-suffix (drgnx-owner--expand f)) stem))
                (throw 'module (symbol-name (car m)))))))
        (file-relative-name stem drgnx-dir))))

(defun drgnx-owner-of-file (file)
  "Who owns the Lisp FILE (a name as `load-history' keeps it): (\"PACKAGE\" . LIBRARY) for a file in a package's
directory, (\"emacs\" . LIBRARY) under `lisp-directory', (\"drgnx\" . MODULE) in drgnx's tree (the module whose file
it is, else the file's path in the tree), else nil.  Packages are looked at first: a package directory never lies in
the other two.  Only names are compared; nothing is read from the disk."
  (when (stringp file)
    (let ((name (drgnx-owner--expand file)))
      (cond ((let ((hit (seq-find (lambda (d) (string-prefix-p (car d) name)) (drgnx-owner--package-dirs))))
               (and hit (cons (cdr hit) (drgnx-owner--library name)))))
            ((let ((pkg (drgnx-owner--package-from-dir name)))
               (and pkg (cons pkg (drgnx-owner--library name)))))
            ((string-prefix-p (file-name-as-directory (drgnx-owner--expand drgnx-dir)) name)
             (cons "drgnx" (drgnx-owner--drgnx-detail name)))
            ((and lisp-directory (string-prefix-p (file-name-as-directory (drgnx-owner--expand lisp-directory)) name))
             (cons "emacs" (drgnx-owner--library name)))))))

(defun drgnx-owner-module-for-package (package)
  "The drgnx module (a symbol) that enables PACKAGE (a symbol or a string): the first whose `:packages' name it."
  (let ((sym (if (stringp package) (intern package) package)))
    (car (seq-find (lambda (m) (memq sym (plist-get (cdr m) :packages))) (bound-and-true-p drgnx-modules--table)))))

(provide 'drgnx-owner)
;;; drgnx-owner.el ends here
