;;; drgnx-settings-described.el --- Settings: descriptions of other packages' variables -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A plain `defvar' is a setting only when a description names it (design 10.2).  Descriptions are data,
;; `(VARIABLE :type TYPE :doc "…" :group GROUP :scope … :workspace … :merge …)', in one form
;; `(drgnx-described DESCRIPTION…)' per file: the checkout's `settings/described/*.eld' and the user's
;; `<config>/described.el'.  They are read as data, never loaded; the user's wins.  A description also refines a
;; `defcustom': it marks program-holding settings `:workspace code' and the alists modules extend `:merge alist'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-setting)

(defvar drgnx-dir)

(defconst drgnx-settings-described-keys '(:scope :workspace :merge)
  "The drgnx keys a description may override on a setting (the rest of its keys describe the variable).")

(defvar drgnx-settings-described--cache nil "(STAMPS . TABLE) of the descriptions last read.")

(defun drgnx-settings-described-files ()
  "The files descriptions come from, the shipped ones first, the user's `described.el' last."
  (append (and (boundp 'drgnx-dir) drgnx-dir
               (directory-files (expand-file-name "settings/described" drgnx-dir) t "\\.eld\\'"))
          (list (expand-file-name "described.el" (drgnx-user-dir)))))

(defun drgnx-settings-described--table ()
  "Variable -> description plist, from every file; read again when a file's stamp changed."
  (let* ((files (drgnx-settings-described-files))
         (stamps (mapcar (lambda (f) (cons f (ignore-errors (file-attributes f)))) files)))
    (if (and drgnx-settings-described--cache (equal (car drgnx-settings-described--cache) stamps))
        (cdr drgnx-settings-described--cache)
      (let ((table (make-hash-table :test 'eq)))
        (dolist (f files)
          (let ((r (drgnx-file-read f)))
            (when (and (eq (plist-get r :status) 'ok) (eq (car-safe (plist-get r :data)) 'drgnx-described))
              (dolist (d (cdr (plist-get r :data)))
                (when (and (consp d) (symbolp (car d)) (car d)) (puthash (car d) (cdr d) table))))))
        (setq drgnx-settings-described--cache (cons stamps table))
        table))))

(defun drgnx-settings-described (var)
  "VAR's description (a plist of :type :doc :group :scope :workspace :merge), or nil."
  (gethash var (drgnx-settings-described--table)))

(defun drgnx-settings-described-defvar-p (var)
  "Non-nil when VAR is a plain `defvar' (no `defcustom') that a description names: a setting like any other."
  (and (not (get var 'standard-value)) (drgnx-settings-described var) (boundp var) t))

(defun drgnx-settings-described-type (var)
  "The `:type' a description gives VAR, or nil."
  (plist-get (drgnx-settings-described var) :type))

(defun drgnx-settings-described-vars ()
  "The described plain `defvar's that are bound now, sorted by name."
  (let (out)
    (maphash (lambda (v _) (when (drgnx-settings-described-defvar-p v) (push v out)))
             (drgnx-settings-described--table))
    (sort out (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun drgnx-settings-described-group-vars (group)
  "The described `defvar's whose description names GROUP."
  (cl-remove-if-not (lambda (v) (eq (plist-get (drgnx-settings-described v) :group) group))
                    (drgnx-settings-described-vars)))

(defun drgnx-settings-described-meta (var _meta)
  "A `drgnx-setting-meta-functions' member: the keys VAR's description sets."
  (let (out)
    (dolist (k drgnx-settings-described-keys)
      (when-let* ((d (drgnx-settings-described var)))
        (when (plist-member d k) (setq out (plist-put out k (plist-get d k))))))
    out))

(add-hook 'drgnx-setting-meta-functions #'drgnx-settings-described-meta)

(provide 'drgnx-settings-described)
;;; drgnx-settings-described.el ends here
