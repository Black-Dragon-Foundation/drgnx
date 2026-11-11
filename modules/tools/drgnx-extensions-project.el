;;; drgnx-extensions-project.el --- Extensions: a package's file modes and buffer modes off in one project -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-packages-off' names, per project, the packages whose file modes and buffer minor modes are off there.  Only
;; a package the modes index (core/drgnx-extensions-index.el) calls `narrow' can be: one with global effects is "On in
;; every project: it changes Emacs as a whole" and has no toggle.  While some package is off in some project:
;; - a named `:around' advice on `major-mode-remap' gives a file buffer of such a project, asked for one of the
;;   package's modes, the mode the file would get with the package's entries taken out of the mode alists;
;; - a named function on `after-change-major-mode-hook' (depth 100) turns the package's buffer minor modes off in such
;;   a file buffer.
;; Neither is installed while nothing is off anywhere.  The value is read by root (`drgnx-setting-for-root'): a
;; buffer's project values may not be applied yet when its mode is chosen.  See docs/guide/extensions.md, "In one
;; project".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-setting)
(require 'drgnx-settings-workspace)
(require 'drgnx-extensions-index)

(defvar drgnx-settings-changed-functions)
(declare-function drgnx-settings-editors-commit "drgnx-settings-editors" (var tab root value))

(drgnx-defsetting drgnx-packages-off nil
  "Packages whose file modes and buffer modes are off in this project (Extensions, a package's page).  A package
that changes Emacs as a whole cannot be off in one project."
  :type '(repeat symbol) :group 'drgnx :scope 'project :workspace 'data :agents 'never :schema '(list-of symbol))

(defconst drgnx-extensions-project-global-text "On in every project: it changes Emacs as a whole")

(defvar drgnx-extensions-project--modes nil "Major modes of the packages off in some project: ((MODE . PKG)…).")

(defvar drgnx-extensions-project--minors nil "Buffer minor modes of the packages off in some project: ((MODE . PKG)…).")

(defvar drgnx-extensions-project--index nil
  "The modes index as the last refresh read it, or nil before one: the mode paths read it, never the file.")

(defvar drgnx-extensions-project--roots (make-hash-table :test #'equal)
  "Directory → its project root, or `none': the mode paths never walk the file system twice for one directory.
Emptied when settings change (`drgnx-settings-changed-functions') and by each refresh; bounded by the directories of
the files visited in between.")

(defvar drgnx-extensions-project--off (make-hash-table :test #'equal)
  "Project root → the packages off there (those that can be).  Emptied by each refresh.")

;;;; Reading

(defun drgnx-extensions-project--index ()
  (or drgnx-extensions-project--index (drgnx-extensions-index-read)))

(defun drgnx-extensions-project-scope (pkg)
  "PKG's scope by the modes index: `narrow', `global' or `none'; nil when the index does not know it."
  (plist-get (alist-get pkg (drgnx-extensions-index-read)) :scope))

(defun drgnx-extensions-project--narrow (pkgs)
  "Those of PKGS (a value of the setting) that can be off in a project, by the index the last refresh read."
  (let ((index (drgnx-extensions-project--index)))
    (seq-filter (lambda (p) (and (symbolp p) (eq (plist-get (alist-get p index) :scope) 'narrow))) (ensure-list pkgs))))

(defun drgnx-extensions-project--root (file)
  "The project root FILE is in, as workspace settings know roots: its private file's root, else the folder of the
nearest .drgnx/settings.el; nil outside a project.  Remembered by directory."
  (unless (file-remote-p file)
    (let* ((dir (drgnx-settings-workspace--norm (file-name-directory file)))
           (root (or (gethash dir drgnx-extensions-project--roots)
                     (puthash dir (or (cdr (drgnx-settings-workspace--private-for dir))
                                      (cdr (drgnx-settings-workspace--shared-for dir))
                                      'none)
                              drgnx-extensions-project--roots))))
      (and (not (eq root 'none)) root))))

(defun drgnx-extensions-project--off-at (root)
  "The packages off in the project at ROOT (those that can be).  Remembered by root until the next refresh."
  (when root
    (let ((off (gethash root drgnx-extensions-project--off 'unknown)))
      (if (eq off 'unknown)
          (puthash root (drgnx-extensions-project--narrow (drgnx-setting-for-root 'drgnx-packages-off root))
                   drgnx-extensions-project--off)
        off))))

(defun drgnx-extensions-project-off-p (pkg root)
  "Non-nil when PKG's file modes and buffer modes are off in the project at ROOT."
  (and (memq pkg (drgnx-extensions-project--off-at (drgnx-settings-workspace--norm root))) t))

(defun drgnx-extensions-project--entry-in (file)
  "The value of the top-level `drgnx-packages-off' entry of the workspace FILE, or nil."
  (when-let* ((e (seq-find (lambda (e) (and (eq (drgnx-settings-entry-var e) 'drgnx-packages-off)
                                            (null (drgnx-settings-entry-scope e))))
                           (car (ignore-errors (drgnx-settings-workspace--usable file))))))
    (seq-filter #'symbolp (ensure-list (drgnx-settings-entry-value e)))))

(defun drgnx-extensions-project--off-anywhere ()
  "The packages off in some project: by your value, your private workspace files and the shared ones drgnx read."
  (let ((out (seq-filter #'symbolp (ensure-list (default-value 'drgnx-packages-off)))))
    (dolist (file (delete-dups (append (drgnx-settings-workspace--private-files) (drgnx-settings-workspace-files))))
      (dolist (p (drgnx-extensions-project--entry-in file)) (cl-pushnew p out)))
    (drgnx-extensions-project--narrow (nreverse out))))

(defun drgnx-extensions-project-describe (pkg root)
  "What PKG's row says for the project at ROOT."
  (pcase (drgnx-extensions-project-scope pkg)
    ('global drgnx-extensions-project-global-text)
    ('narrow (let* ((root (drgnx-settings-workspace--norm root)) (private (drgnx-settings-workspace-file root)))
               (cond ((not (drgnx-extensions-project-off-p pkg root)) "On in this project")
                     ((and (not (and private (memq pkg (drgnx-extensions-project--entry-in private))))
                           (memq pkg (drgnx-extensions-project--entry-in
                                      (expand-file-name drgnx-settings-workspace-shared-file root))))
                      "Off in this project by the project's shared settings")
                     (t "Off in this project"))))
    (_ "It adds no file modes or buffer modes")))

;;;; The mode a file gets without some packages

(defun drgnx-extensions-project--mode-of (value)
  "The mode of a mode alist's VALUE: MODE, or (MODE t)."
  (if (consp value) (car value) value))

(defun drgnx-extensions-project--magic (alist)
  "The mode the current buffer's beginning gets from the magic ALIST, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (narrow-to-region (point-min) (min (point-max) (+ (point-min) magic-mode-regexp-match-limit)))
      (goto-char (point-min))
      (assoc-default nil alist (lambda (re _) (cond ((functionp re) (funcall re))
                                                    ((stringp re) (let ((case-fold-search nil)) (looking-at re)))))))))

(defun drgnx-extensions-project--fallback (pkgs)
  "The mode the current buffer's file gets with the modes of PKGS taken out of the mode alists, chosen as
`set-auto-mode' chooses: interpreter, magic, file name, magic fallback; else `fundamental-mode'."
  (let* ((index (drgnx-extensions-project--index))
         (gone (seq-mapcat (lambda (p) (drgnx-extensions-index-modes (alist-get p index))) pkgs))
         (keep (lambda (alist)
                 (seq-remove (lambda (e) (memq (drgnx-extensions-project--mode-of (cdr-safe e)) gone)) alist)))
         (name (file-name-sans-versions buffer-file-name)))
    (when-let* ((remote (file-remote-p name))) (setq name (substring name (length remote))))
    (or (when-let* ((interp (save-excursion
                              (save-restriction
                                (widen) (goto-char (point-min))
                                (and (looking-at auto-mode-interpreter-regexp) (match-string 2))))))
          (assoc-default (file-name-nondirectory interp)
                         (mapcar (lambda (e) (cons (format "\\`%s\\'" (car e)) (cdr e)))
                                 (funcall keep interpreter-mode-alist))
                         #'string-match-p))
        (drgnx-extensions-project--magic (funcall keep magic-mode-alist))
        (drgnx-extensions-project--mode-of
         (or (let ((case-fold-search nil)) (assoc-default name (funcall keep auto-mode-alist) #'string-match))
             (and auto-mode-case-fold
                  (let ((case-fold-search t)) (assoc-default name (funcall keep auto-mode-alist) #'string-match)))))
        (drgnx-extensions-project--magic (funcall keep magic-fallback-mode-alist))
        'fundamental-mode)))

(defun drgnx-extensions-project--remap (orig mode)
  "Around `major-mode-remap' (ORIG), while a package is off somewhere: in a file buffer of a project where the
package of MODE is off, ORIG's answer for the mode the file gets without it.  Every other call gets ORIG's answer."
  (if-let* (((stringp buffer-file-name))
            (pkg (alist-get mode drgnx-extensions-project--modes))
            (off (drgnx-extensions-project--off-at (drgnx-extensions-project--root buffer-file-name)))
            ((memq pkg off)))
      (funcall orig (drgnx-extensions-project--fallback off))
    (funcall orig mode)))

(defun drgnx-extensions-project--minor-off ()
  "On `after-change-major-mode-hook' (depth 100): in a file buffer, turn off the buffer minor modes of the packages
off in its project."
  (when-let* (((stringp buffer-file-name))
              (on (seq-filter (lambda (c) (and (boundp (car c)) (symbol-value (car c)))) drgnx-extensions-project--minors))
              (off (drgnx-extensions-project--off-at (drgnx-extensions-project--root buffer-file-name))))
    (pcase-dolist (`(,mode . ,pkg) on)
      (when (memq pkg off)
        (condition-case nil (funcall mode -1) (error nil))))))

;;;; What is installed

(defun drgnx-extensions-project--install (on)
  "Install the advice and the hook when ON, else remove them."
  (if on
      (progn (advice-add 'major-mode-remap :around #'drgnx-extensions-project--remap)
             (add-hook 'after-change-major-mode-hook #'drgnx-extensions-project--minor-off 100))
    (advice-remove 'major-mode-remap #'drgnx-extensions-project--remap)
    (remove-hook 'after-change-major-mode-hook #'drgnx-extensions-project--minor-off)))

(defun drgnx-extensions-project-refresh ()
  "Read again which packages are off in some project, the modes index and the projects' values; install the advice
and the hook while one is, else remove them.  Never prompts."
  (clrhash drgnx-extensions-project--roots)
  (clrhash drgnx-extensions-project--off)
  (setq drgnx-extensions-project--index (drgnx-extensions-index-read))
  (let ((index drgnx-extensions-project--index) (off (drgnx-extensions-project--off-anywhere)) (modes nil) (minors nil))
    (dolist (p off)
      (let ((e (alist-get p index)))
        (dolist (m (drgnx-extensions-index-modes e)) (push (cons m p) modes))
        (dolist (m (plist-get e :minor)) (push (cons m p) minors))))
    (setq drgnx-extensions-project--modes (nreverse modes) drgnx-extensions-project--minors (nreverse minors))
    (drgnx-extensions-project--install off)))

(defun drgnx-extensions-project--changed (_file changes)
  "On `drgnx-settings-changed-functions': forget the roots (a workspace file may have come or gone), and refresh when
CHANGES touch `drgnx-packages-off'."
  (clrhash drgnx-extensions-project--roots)
  (clrhash drgnx-extensions-project--off)
  (when (seq-some (lambda (c) (eq (nth 1 c) 'drgnx-packages-off)) changes)
    (drgnx-extensions-project-refresh)))

(defun drgnx-extensions-project--job-done (_job _result)
  "On `drgnx-extensions-jobs-done-functions': a job may have changed the packages and so the modes index."
  (drgnx-extensions-project-refresh))

(defun drgnx-extensions-project-misses ()
  "The file buffers where a package's mode is on though the package is off in their project:
\((BUFFER-NAME PKG MODE)…).  For `drgnx doctor'."
  (let (out)
    (when (or drgnx-extensions-project--modes drgnx-extensions-project--minors)
      (dolist (b (buffer-list))
        (with-current-buffer b
          (when-let* (((stringp buffer-file-name))
                      (off (drgnx-extensions-project--off-at (drgnx-extensions-project--root buffer-file-name))))
            (pcase-dolist (`(,mode . ,pkg) (append drgnx-extensions-project--modes drgnx-extensions-project--minors))
              (when (and (memq pkg off)
                         (if (assq mode drgnx-extensions-project--modes) (eq major-mode mode)
                           (and (boundp mode) (symbol-value mode))))
                (push (list (buffer-name) pkg mode) out)))))))
    (nreverse out)))

;;;; Changing it

(defun drgnx-extensions-project-set (pkg root off)
  "Turn PKG's file modes and buffer modes OFF (non-nil) or back on in the project at ROOT: written to your private
workspace file (`drgnx-settings-editors-commit', never the shared one) and applied at once to ROOT's open file
buffers.  A package that cannot be off in one project is a `user-error' saying why.  The new value."
  (let ((scope (drgnx-extensions-project-scope pkg)))
    (unless (eq scope 'narrow)
      (user-error "%s: %s" pkg (if (eq scope 'global) drgnx-extensions-project-global-text
                                 "it adds no file modes or buffer modes to turn off"))))
  (require 'drgnx-settings-page)
  (let* ((root (drgnx-settings-workspace--norm root))
         (now (seq-filter #'symbolp (ensure-list (drgnx-setting-for-root 'drgnx-packages-off root))))
         (new (if off (if (memq pkg now) now (append now (list pkg))) (remq pkg now))))
    (drgnx-settings-workspace-file root t)
    (drgnx-settings-editors-commit 'drgnx-packages-off 'workspace root new)
    (drgnx-extensions-project-refresh)
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and buffer-file-name
                   (string-prefix-p root (drgnx-settings-workspace--norm (file-name-directory buffer-file-name)))
                   (drgnx-extensions-project--belongs-p pkg))
          (let ((enable-local-variables :safe) (inhibit-interaction t))
            (condition-case nil (normal-mode) (error nil))))))
    new))

(defun drgnx-extensions-project--belongs-p (pkg)
  "Non-nil when the current file buffer has to do with PKG: its major mode or an active minor mode is PKG's, or the
file's name would pick one of PKG's major modes.  Only those buffers are set up again by a toggle (M6): another
buffer's local state is none of its business."
  (or (eq (cdr (assq major-mode drgnx-extensions-project--modes)) pkg)
      (seq-some (lambda (cell) (and (eq (cdr cell) pkg) (boundp (car cell)) (symbol-value (car cell))))
                drgnx-extensions-project--minors)
      (let ((chosen (assoc-default buffer-file-name auto-mode-alist #'string-match)))
        (and (symbolp chosen) chosen (eq (cdr (assq chosen drgnx-extensions-project--modes)) pkg)))))

(defun drgnx-extensions-project-toggle (pkg root)
  "Turn PKG off in the project at ROOT, or back on.  A package that changes Emacs as a whole is a `user-error'
saying so."
  (drgnx-extensions-project-set pkg root (not (drgnx-extensions-project-off-p pkg root))))

;;;; Setup

(defun drgnx-extensions-project-setup ()
  "For the Extensions module's setup: follow changes of the setting and the ends of jobs, and install what is needed
now."
  (add-hook 'drgnx-settings-changed-functions #'drgnx-extensions-project--changed)
  (add-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-project--job-done)
  (drgnx-extensions-project-refresh))

(defun drgnx-extensions-project-teardown ()
  "For the Extensions module's teardown: the advice, the hooks and what it remembered go."
  (drgnx-extensions-project--install nil)
  (remove-hook 'drgnx-settings-changed-functions #'drgnx-extensions-project--changed)
  (remove-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-project--job-done)
  (clrhash drgnx-extensions-project--roots)
  (clrhash drgnx-extensions-project--off)
  (setq drgnx-extensions-project--modes nil drgnx-extensions-project--minors nil drgnx-extensions-project--index nil))

(provide 'drgnx-extensions-project)
;;; drgnx-extensions-project.el ends here
