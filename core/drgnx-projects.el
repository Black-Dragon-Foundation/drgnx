;;; drgnx-projects.el --- Projects: find git repositories, put them and their TODOs on the org board -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The board is an org file (board.org in `org-directory') with one top-level heading per project
;; carrying :PROJECT_ROOT: — gryphn's format, so gryphn's board works on it too.  Importing a project
;; adds its heading (once: projects are matched by root) and its open TODOs from TODO.md, TODO.org and
;; plan checklists under docs/ (once: each carries an :ONBOARD_ID:).  Nothing on the board is moved
;; or rewritten; a board with unsaved changes in Emacs is left alone.  Projects are also listed in
;; projects.eld (config dir) and remembered by project.el.  See docs/onboarding.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'org)
(require 'project)
(require 'drgnx-paths)

(defvar drgnx-projects-board-file nil "The board; nil means board.org in `org-directory'.")

(defvar drgnx-projects-gryphn-file (expand-file-name "~/.config/gryphn/projects.tsv")
  "gryphn's project list (NAME<TAB>ROOT lines), offered when importing.")

(defconst drgnx-projects-skip '("node_modules" "target" "build" "dist" "venv" "__pycache__")
  "Directory names the scan never enters (hidden directories are skipped too).")

(defvar project--list)

(defun drgnx-projects-board-file ()
  (expand-file-name (or drgnx-projects-board-file (expand-file-name "board.org" org-directory))))

;;;; Finding projects

(defun drgnx-projects-scan (roots &optional depth budget)
  "Git repositories under ROOTS, at most DEPTH (3) levels down, within BUDGET (5) seconds: never into a
repository, a hidden or symlinked directory, `drgnx-projects-skip' or an unreadable one.  Sorted."
  (let ((deadline (+ (float-time) (or budget 5))) (found nil)
        (queue (mapcar (lambda (r) (cons (file-name-as-directory (expand-file-name r)) 0)) roots)))
    (while (and queue (< (float-time) deadline))
      (pcase-let ((`(,dir . ,d) (pop queue)))
        (cond ((file-exists-p (expand-file-name ".git" dir)) (push dir found))
              ((< d (or depth 3))
               (dolist (sub (ignore-errors (directory-files dir t "\\`[^.]" t)))
                 (when (and (file-directory-p sub) (not (file-symlink-p sub)) (file-accessible-directory-p sub)
                            (not (member (file-name-nondirectory sub) drgnx-projects-skip)))
                   (setq queue (nconc queue (list (cons (file-name-as-directory sub) (1+ d)))))))))))
    (sort (delete-dups found) #'string<)))

(defun drgnx-projects-gryphn-roots ()
  "The roots in gryphn's projects.tsv (when there is one)."
  (when (file-readable-p drgnx-projects-gryphn-file)
    (delq nil (mapcar (lambda (line)
                        (let ((f (split-string line "\t")))
                          (and (= (length f) 2) (not (string-empty-p (cadr f))) (expand-file-name (cadr f)))))
                      (split-string (with-temp-buffer (insert-file-contents drgnx-projects-gryphn-file) (buffer-string))
                                    "\n" t)))))

(defun drgnx-projects--url (root)
  (with-temp-buffer
    (when (eql 0 (ignore-errors (call-process "git" nil t nil "-C" root "remote" "get-url" "origin")))
      (let ((u (string-trim (buffer-string)))) (unless (string-empty-p u) u)))))

;;;; TODOs in a project

(defun drgnx-projects--todos (root)
  "Open TODOs of ROOT: (TEXT . ID)…  From TODO.md / plan checklists (`- [ ] …') and TODO.org (`* TODO …')."
  (let ((files (append (seq-filter #'file-readable-p (mapcar (lambda (f) (expand-file-name f root)) '("TODO.md" "TODO.org")))
                       (let ((docs (expand-file-name "docs" root)))
                         (and (file-directory-p docs)
                              (seq-filter (lambda (f) (string-match-p "/plans/" f)) (directory-files-recursively docs "\\.md\\'"))))))
        out)
    (dolist (f files)
      (let ((rel (file-relative-name f root))
            (re (if (string-suffix-p ".org" f) "^\\*+ TODO \\(.+?\\)[ \t]*$" "^[ \t]*[-*] \\[ \\] \\(.+?\\)[ \t]*$")))
        (with-temp-buffer
          (insert-file-contents f)
          (goto-char (point-min))
          (while (re-search-forward re nil t)
            (let ((text (match-string 1)))
              (push (cons text (substring (secure-hash 'sha1 (concat rel "\0" text)) 0 12)) out))))))
    (seq-take (nreverse out) 200)))

;;;; The board

(defun drgnx-projects--board-update (fn)
  "Call FN in an org buffer holding the board; write the board back only when FN changed it."
  (let* ((file (drgnx-projects-board-file)) (visiting (find-buffer-visiting file)))
    (when (and visiting (buffer-modified-p visiting))
      (user-error "%s has unsaved changes in Emacs; save it and import again" file))
    (let* ((old (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))
           (new (with-temp-buffer
                  (insert old)
                  (let ((org-inhibit-startup t)) (delay-mode-hooks (org-mode)))
                  (funcall fn)
                  (buffer-string))))
      (unless (equal old new)
        (make-directory (file-name-directory file) t)
        (let ((tmp (make-temp-file (expand-file-name ".board-" (file-name-directory file)))))
          (with-temp-file tmp (insert new))
          (rename-file tmp file t))
        (when visiting (with-current-buffer visiting (revert-buffer t t t)))))))

(defun drgnx-projects--find (root)
  "Position of the board heading whose :PROJECT_ROOT: is ROOT, or nil."
  (let ((target (directory-file-name (expand-file-name root))) found)
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (re-search-forward "^\\* " nil t))
        (let ((r (org-entry-get (point) "PROJECT_ROOT")))
          (when (and r (equal (directory-file-name (expand-file-name r)) target))
            (setq found (line-beginning-position))))))
    found))

(defun drgnx-projects--add-heading (name root url)
  (goto-char (point-max))
  (when (= (point-min) (point-max)) (insert "#+TITLE: Board\n\n"))
  (unless (bolp) (insert "\n"))
  (insert (format "* %s\n:PROPERTIES:\n:PROJECT_ROOT: %s\n%s:END:\n" name root (if url (format ":REPO_URL: %s\n" url) ""))))

(defun drgnx-projects--add-todo (pos text id)
  "Add TEXT as a TODO at the end of the project at POS, unless ID is on the board.  Non-nil if added."
  (unless (save-excursion (goto-char (point-min)) (search-forward (concat ":ONBOARD_ID: " id) nil t))
    (goto-char pos)
    (org-end-of-subtree t t)
    (unless (bolp) (insert "\n"))
    (insert (format "** TODO %s\n:PROPERTIES:\n:ONBOARD_ID: %s\n:END:\n" text id))
    t))

;;;; projects.eld

(defun drgnx-projects-file () (expand-file-name "projects.eld" (drgnx-user-dir)))

(defun drgnx-projects-read ()
  "projects.eld: (:version 1 :projects ((:name :root :url)…))."
  (or (and (file-readable-p (drgnx-projects-file))
           (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-projects-file)) (read (current-buffer)))))
      (list :version 1 :projects nil)))

(defun drgnx-projects--remember (entries)
  (let* ((data (drgnx-projects-read))
         (known (mapcar (lambda (p) (plist-get p :root)) (plist-get data :projects)))
         (new (seq-remove (lambda (e) (member (plist-get e :root) known)) entries)))
    (when new
      (make-directory (file-name-directory (drgnx-projects-file)) t)
      (with-temp-file (drgnx-projects-file)
        (insert ";; drgnx projects (written by Onboarding: Import Projects)\n")
        (pp (list :version 1 :projects (append (plist-get data :projects) new)) (current-buffer))))
    ;; project.el's list, in drgnx's state dir (never another Emacs's)
    (let ((project-list-file (expand-file-name "projects" (drgnx-state-dir))) (project--list 'unset))
      (make-directory (drgnx-state-dir) t)
      (dolist (e entries)
        (when-let* ((p (ignore-errors (project-current nil (plist-get e :root)))))
          (project-remember-project p))))))

(defun drgnx-projects-import (roots &optional no-todos)
  "Put the git repositories ROOTS on the board (once each) with their open TODOs (once each, unless
NO-TODOS).  Returns (:added NAMES :todos N)."
  (let* ((roots (delete-dups (mapcar (lambda (r) (directory-file-name (expand-file-name r)))
                                     (seq-filter #'file-directory-p roots))))
         (entries (mapcar (lambda (r) (list :name (file-name-nondirectory r) :root r :url (drgnx-projects--url r))) roots))
         (added nil) (todos 0))
    (drgnx-projects--board-update
     (lambda ()
       (dolist (e entries)
         (unless (drgnx-projects--find (plist-get e :root))
           (drgnx-projects--add-heading (plist-get e :name) (plist-get e :root) (plist-get e :url))
           (push (plist-get e :name) added))
         (unless no-todos
           (pcase-dolist (`(,text . ,id) (drgnx-projects--todos (plist-get e :root)))
             (when (drgnx-projects--add-todo (drgnx-projects--find (plist-get e :root)) text id)
               (setq todos (1+ todos))))))))
    (drgnx-projects--remember entries)
    (list :added (nreverse added) :todos todos)))

(provide 'drgnx-projects)
;;; drgnx-projects.el ends here
