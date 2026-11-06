;;; drgnx-extensions-recommend.el --- What a project recommends, and what agents suggest -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Recommended (docs/guide/extensions.md): what the project you work in recommends, in this order and each once —
;; its own `drgnx-extensions-recommended' list, then the packages Emacs's autosuggest database (data-directory's
;; package-autosuggest.eld, read as data) names for the files the Explorer has already listed there (its cache only:
;; nothing here reads a folder), then the packages a module that is on still waits for.  A recommendation is a row
;; with your Install button and nothing more; the first file you open in a project that recommends something posts one
;; notice, whose command shows them.
;;
;; Suggested by an agent: `extensions_suggest' makes a card in the hub, and the hub client posts it as a notice whose
;; command opens the package's page (`drgnx-extensions-show-suggestion').  Nothing on it installs: the page's own
;; Install button is yours, and goes through the trust card like any other.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-file)
(require 'drgnx-modules)
(require 'drgnx-notice)

(declare-function drgnx-setting-for-root "drgnx-settings-workspace" (var root))
(declare-function drgnx-cache-get "drgnx-memo" (name k))
(declare-function drgnx-extensions-project--root "drgnx-extensions-project" (file))
(declare-function drgnx-extensions-details-open "drgnx-extensions-details" (id &optional pin))
(declare-function drgnx-extensions-open "drgnx-extensions-list" ())
(declare-function drgnx-extensions-list--apply-query "drgnx-extensions-list" (text))
(defvar drgnx-extensions-recommended)

(defconst drgnx-extensions-recommend--max-dirs 64 "The most cached folders one look at a project walks.")
(defconst drgnx-extensions-recommend--max-files 400 "The most file names one look matches against the database.")

(defvar drgnx-extensions-recommend--root nil
  "The project the Recommended section is for: the last one you opened a file in, or the one a notice showed.")
(defvar drgnx-extensions-recommend--noticed nil "The project roots whose notice was considered this session.")
(defvar drgnx-extensions-recommend--database 'unread
  "Emacs's autosuggest rows as ((PACKAGE . REGEXP)…), read once; nil when the file cannot be read.")

;;;; What a project recommends

(defun drgnx-extensions-recommend--database ()
  "The `auto-mode-alist' rows of data-directory's package-autosuggest.eld, read once as data (never evaluated)."
  (when (eq drgnx-extensions-recommend--database 'unread)
    (setq drgnx-extensions-recommend--database
          (let ((r (drgnx-file-read (expand-file-name "package-autosuggest.eld" data-directory))) rows)
            (when (eq (plist-get r :status) 'ok)
              (dolist (e (plist-get r :data))
                (pcase e
                  (`(,(and pkg (pred symbolp)) auto-mode-alist ,(and re (pred stringp)) . ,_) (push (cons pkg re) rows)))))
            (nreverse rows))))
  drgnx-extensions-recommend--database)

(defun drgnx-extensions-recommend--files (root)
  "The file names under ROOT the Explorer's cache already lists, breadth first, within the caps; nil without it."
  (let ((queue (list (file-name-as-directory root))) (dirs 0) files)
    (while (and queue (< dirs drgnx-extensions-recommend--max-dirs) (< (length files) drgnx-extensions-recommend--max-files))
      (let* ((dir (pop queue))
             (hit (condition-case nil (drgnx-cache-get 'explorer-listing dir) (error nil))))
        (cl-incf dirs)
        (dolist (entry (cdr hit))
          (if (cdr entry)
              (setq queue (nconc queue (list (file-name-as-directory (expand-file-name (car entry) dir)))))
            (push (car entry) files)))))
    (seq-take (nreverse files) drgnx-extensions-recommend--max-files)))

(defun drgnx-extensions-recommend--by-files (root)
  "((FILE . PACKAGE)…): for each file listed under ROOT, the first package the database names for it."
  (let ((rows (and root (drgnx-extensions-recommend--files root))) (case-fold-search nil) out)
    (when rows
      (let ((db (drgnx-extensions-recommend--database)))
        (dolist (file rows)
          (when-let* ((hit (cl-find-if (lambda (r) (string-match-p (cdr r) file)) db)))
            (unless (rassq (car hit) out) (push (cons file (car hit)) out))))))
    (nreverse out)))

(defun drgnx-extensions-recommend--waiting ()
  "((MODULE . PACKAGE)…): the packages a module that is on waits for, as the modules' report says."
  (let (out)
    (pcase-dolist (`(,module . ,r) (bound-and-true-p drgnx-modules--report))
      (when (and (eq (plist-get r :status) 'missing-packages) (not (drgnx-module-disabled-p module)))
        (dolist (pkg (plist-get r :missing))
          (when (symbolp pkg) (push (cons module pkg) out)))))
    (nreverse out)))

(defun drgnx-extensions-recommended (root)
  "What the project at ROOT recommends, as ((ID . WHY)…), in order and each once: its `drgnx-extensions-recommended',
the packages Emacs suggests for the files the Explorer listed there, the packages a module waits for.  ROOT nil: the
global list and the modules only.  Reads no folder and changes nothing."
  (let (out)
    (cl-flet ((add (pkg why) (let ((id (format "pkg:%s" pkg))) (unless (assoc id out) (push (cons id why) out)))))
      (dolist (pkg (ensure-list (if root (drgnx-setting-for-root 'drgnx-extensions-recommended root)
                                  (bound-and-true-p drgnx-extensions-recommended))))
        (when (and pkg (symbolp pkg)) (add pkg "this project recommends it")))
      (pcase-dolist (`(,file . ,pkg) (drgnx-extensions-recommend--by-files root))
        (add pkg (format "Emacs suggests it for %s here" file)))
      (pcase-dolist (`(,module . ,pkg) (drgnx-extensions-recommend--waiting))
        (add pkg (format "the module %s waits for it" module))))
    (nreverse out)))

(defun drgnx-extensions-recommend-ids ()
  "The ids the Recommended section lists: what `drgnx-extensions-recommend--root' recommends."
  (mapcar #'car (drgnx-extensions-recommended drgnx-extensions-recommend--root)))

(defun drgnx-extensions-recommend-notice (root)
  "The first look at the project at ROOT this session: one notice when it recommends anything, with a command that
shows them.  Non-nil when it posted one.  Installs, queues and asks nothing."
  (let ((root (file-name-as-directory root)))
    (unless (member root drgnx-extensions-recommend--noticed)
      (push root drgnx-extensions-recommend--noticed)
      (when-let* ((rec (drgnx-extensions-recommended root)))
        (drgnx-notify 'config 'info (format "This project recommends %d extension%s" (length rec)
                                            (if (= (length rec) 1) "" "s"))
                      :id (intern (concat "extensions-recommended:" root))
                      :detail (mapconcat (lambda (r) (format "%s: %s" (substring (car r) 4) (cdr r))) rec "; ")
                      :command (list 'drgnx-extensions-show-recommended root))
        t))))

(defun drgnx-extensions-recommend--visited ()
  "On `find-file-hook': the file's project is the one Recommended is for; its first file posts the notice."
  (when-let* ((file buffer-file-name) ((fboundp 'drgnx-extensions-project--root))
              (root (drgnx-extensions-project--root file)))
    (setq drgnx-extensions-recommend--root (file-name-as-directory root))
    (drgnx-extensions-recommend-notice root)))

;;;; The commands

(defun drgnx-extensions-show-recommended (&optional root)
  "Show what the project at ROOT (this buffer's project when called) recommends: the Extensions list's Recommended."
  (interactive)
  (let ((root (or root (and buffer-file-name (fboundp 'drgnx-extensions-project--root)
                            (drgnx-extensions-project--root buffer-file-name))
                  drgnx-extensions-recommend--root)))
    (setq drgnx-extensions-recommend--root (and root (file-name-as-directory root)))
    (drgnx-extensions-open)
    (drgnx-extensions-list--apply-query "@recommended")))

(defun drgnx-extensions-recommend--suggested ()
  "The ids the agents' open suggestion notices name, newest first."
  (delete-dups (delq nil (mapcar (lambda (n) (pcase (plist-get n :command)
                                               (`(drgnx-extensions-show-suggestion ,(and id (pred stringp))) id)))
                                 (drgnx-notices :source 'hub)))))

(defun drgnx-extensions-show-suggestion (id)
  "Open the page of the extension ID an agent suggested.  Its Install button is yours; nothing here installs."
  (interactive (list (pcase (drgnx-extensions-recommend--suggested)
                       ('nil (user-error "No agent suggestion is open"))
                       (`(,only) only)
                       (ids (completing-read "Suggested extension: " ids nil t)))))
  (unless (and (stringp id) (string-match-p "\\`\\(?:pkg\\|plugin\\):[^[:space:][:cntrl:]]+\\'" id))
    (user-error "%S is not an extension id" id))
  (pop-to-buffer (drgnx-extensions-details-open id t)))

;;;; Setup

(defun drgnx-extensions-recommend-setup ()
  (add-hook 'find-file-hook #'drgnx-extensions-recommend--visited))

(defun drgnx-extensions-recommend-teardown ()
  "Forget the projects and the database; let go of the hook."
  (remove-hook 'find-file-hook #'drgnx-extensions-recommend--visited)
  (setq drgnx-extensions-recommend--root nil drgnx-extensions-recommend--noticed nil
        drgnx-extensions-recommend--database 'unread))

(provide 'drgnx-extensions-recommend)
;;; drgnx-extensions-recommend.el ends here
