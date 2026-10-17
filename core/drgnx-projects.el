;;; drgnx-projects.el --- Projects: find git repositories, put them and their TODOs on the org board -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The board is an org file (board.org in `org-directory') with a heading per project carrying
;; :PROJECT_ROOT: — gryphn's format, so gryphn's board works on it too.  Importing a project adds its
;; heading (once: projects are matched by root, at any heading level, through symlinks) and, when
;; asked, its open TODOs from TODO.md, TODO.org and plan checklists under docs/ (once each: an
;; :ONBOARD_ID: per TODO, and a record of what was imported, so a TODO archived or deleted is not
;; imported again).  The board is edited as text — no org-mode, no #+SETUPFILE — and written back
;; with its encoding, line endings, modes and symlink kept; nothing on it is moved or rewritten.  A
;; board with unsaved changes (in this Emacs, or locked by another) is left alone.  Projects are also
;; listed in projects.eld (config dir) and remembered by project.el.  See docs/onboarding.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'drgnx-paths)

(defvar org-directory)
(defvar project--list)

(defvar drgnx-projects-board-file nil "The board; nil means board.org in `org-directory'.")

(defvar drgnx-projects-gryphn-file (expand-file-name "~/.config/gryphn/projects.tsv")
  "gryphn's project list (NAME<TAB>ROOT lines), offered when importing.")

(defconst drgnx-projects-skip '("node_modules" "target" "build" "dist" "venv" "__pycache__")
  "Directory names a scan never enters (hidden directories are skipped too).")

(defvar drgnx-projects-scan-budget 5 "Seconds a scan for repositories may take.")

(defvar drgnx-projects-scan-truncated nil
  "After `drgnx-projects-scan': the first directory it did not get to when its time ran out, else nil.")

(defconst drgnx-projects-todo-cap 200 "At most this many TODOs per project and import.")

(defun drgnx-projects-board-file ()
  (expand-file-name (or drgnx-projects-board-file
                        (expand-file-name "board.org" (if (boundp 'org-directory) org-directory "~/org")))))

(defun drgnx-projects--norm (dir) (directory-file-name (file-truename (expand-file-name dir))))

;;;; Finding projects

(defun drgnx-projects-scan (roots &optional depth budget)
  "Git repositories under ROOTS, at most DEPTH (3) levels down, within BUDGET seconds
(`drgnx-projects-scan-budget'): never into a repository, a hidden or symlinked directory,
`drgnx-projects-skip' or an unreadable one.  Sorted.  Sets `drgnx-projects-scan-truncated'."
  (let ((deadline (+ (float-time) (or budget drgnx-projects-scan-budget))) (found nil)
        (queue (mapcar (lambda (r) (cons (file-name-as-directory (expand-file-name r)) 0)) roots)))
    (setq drgnx-projects-scan-truncated nil)
    (while queue
      (if (>= (float-time) deadline)
          (setq drgnx-projects-scan-truncated (car (car queue)) queue nil)
        (pcase-let ((`(,dir . ,d) (pop queue)))
          (cond ((file-exists-p (expand-file-name ".git" dir)) (push dir found))
                ((< d (or depth 3))
                 (dolist (sub (ignore-errors (directory-files dir t "\\`[^.]" t)))
                   (when (and (file-directory-p sub) (not (file-symlink-p sub)) (file-accessible-directory-p sub)
                              (not (member (file-name-nondirectory sub) drgnx-projects-skip)))
                     (setq queue (nconc queue (list (cons (file-name-as-directory sub) (1+ d))))))))))))
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

(defun drgnx-projects--plan-files (root)
  "Markdown files in a plans/ directory under ROOT's docs/ (at most 4 levels; no hidden dirs or skips)."
  (let ((out nil) (queue (list (cons (expand-file-name "docs" root) 0))))
    (while queue
      (pcase-let ((`(,dir . ,d) (pop queue)))
        (dolist (f (ignore-errors (directory-files dir t "\\`[^.]")))
          (cond ((and (file-directory-p f) (not (file-symlink-p f)) (< d 4)
                      (not (member (file-name-nondirectory f) drgnx-projects-skip)))
                 (push (cons f (1+ d)) queue))
                ((and (string-suffix-p ".md" f)
                      (member "plans" (split-string (file-relative-name (file-name-directory f) root) "/" t)))
                 (push f out))))))
    (sort out #'string<)))

(defun drgnx-projects--todos (root)
  "Open TODOs of ROOT: (TEXT . ID)…  From TODO.md and plan checklists (`- [ ] …') and TODO.org
\(`* TODO …').  The id hashes the file and the text (and which repeat of that text it is)."
  (let ((files (append (seq-filter #'file-readable-p (mapcar (lambda (f) (expand-file-name f root)) '("TODO.md" "TODO.org")))
                       (drgnx-projects--plan-files root)))
        out)
    (dolist (f files)
      (let ((rel (file-relative-name f root)) (seen (make-hash-table :test #'equal))
            (re (if (string-suffix-p ".org" f) "^\\*+ TODO \\(.+?\\)[ \t]*$" "^[ \t]*[-*] \\[ \\] \\(.+?\\)[ \t]*$")))
        (with-temp-buffer
          (insert-file-contents f)
          (goto-char (point-min))
          (while (re-search-forward re nil t)
            (let* ((text (match-string 1)) (n (gethash text seen 0)))
              (puthash text (1+ n) seen)
              (push (cons text (substring (secure-hash 'sha1 (if (zerop n) (concat rel "\0" text) (format "%s\0%s\0%d" rel text n)))
                                          0 12))
                    out))))))
    (nreverse out)))

(defun drgnx-projects--heading-text (text)
  "TEXT safe as an org heading: never tags, a property drawer or a COMMENT keyword."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " text)))
    (if (or (string-match-p "\\`\\(:\\|COMMENT\\b\\)" text) (string-match-p "[ \t]:[^ \t\n]+:[ \t]*\\'" text))
        (concat "=" (replace-regexp-in-string "=" "" text) "=")
      text)))

;;;; The board, as text

(defun drgnx-projects--board-update (fn)
  "Call FN in a buffer holding the board text; write the board back only when FN changed it — with
its encoding and line endings, its modes, through its symlink."
  (let* ((file (drgnx-projects-board-file)) (visiting (find-buffer-visiting file))
         (lock (and (file-exists-p file) (file-locked-p file))))
    (when (and visiting (buffer-modified-p visiting))
      (user-error "%s has unsaved changes in Emacs; save it and import again" file))
    (when (stringp lock)
      (user-error "%s is being edited by %s; save it there and import again" file lock))
    (let* ((coding nil)
           (old (if (file-exists-p file)
                    (with-temp-buffer (insert-file-contents file) (setq coding last-coding-system-used) (buffer-string))
                  ""))
           (new (with-temp-buffer (insert old) (goto-char (point-min)) (funcall fn) (buffer-string))))
      (unless (equal old new)
        (let* ((target (file-truename file))
               (modes (and (file-exists-p target) (file-modes target))))
          (make-directory (file-name-directory target) t)
          (let ((tmp (make-temp-file (expand-file-name ".board-" (file-name-directory target)))))
            (condition-case err
                (progn
                  (let ((coding-system-for-write (or coding 'utf-8-unix))) (write-region new nil tmp nil 'silent))
                  (when modes (set-file-modes tmp modes))
                  (rename-file tmp target t))
              (error (ignore-errors (delete-file tmp)) (signal (car err) (cdr err))))))
        (when visiting (with-current-buffer visiting (revert-buffer t t t)))))))

(defun drgnx-projects--find (root)
  "Position of the board heading (any level) whose :PROJECT_ROOT: is ROOT, or nil."
  (let ((target (drgnx-projects--norm root)) found)
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (re-search-forward "^[ \t]*:PROJECT_ROOT:[ \t]*\\(.+?\\)[ \t]*$" nil t))
        (when (equal (drgnx-projects--norm (match-string 1)) target)
          (save-excursion (when (re-search-backward "^\\*+ " nil t) (setq found (point)))))))
    found))

(defun drgnx-projects--subtree-end (pos)
  "End of the subtree whose heading is at POS."
  (save-excursion
    (goto-char pos)
    (let ((level (progn (looking-at "\\*+") (length (match-string 0)))))
      (forward-line 1)
      (if (re-search-forward (format "^\\*\\{1,%d\\} " level) nil t) (line-beginning-position) (point-max)))))

(defun drgnx-projects--add-heading (name root url)
  (goto-char (point-max))
  (when (= (point-min) (point-max)) (insert "#+TITLE: Board\n\n"))
  (unless (bolp) (insert "\n"))
  (insert (format "* %s\n:PROPERTIES:\n:PROJECT_ROOT: %s\n%s:END:\n" name root (if url (format ":REPO_URL: %s\n" url) ""))))

(defun drgnx-projects--add-todo (pos text id)
  "Add TEXT as a TODO at the end of the project at POS unless ID is in it.  Non-nil if added."
  (let ((end (drgnx-projects--subtree-end pos)))
    (unless (save-excursion (goto-char pos) (search-forward (concat ":ONBOARD_ID: " id) end t))
      (let ((level (save-excursion (goto-char pos) (looking-at "\\*+") (length (match-string 0)))))
        (goto-char end)
        (unless (bolp) (insert "\n"))
        (insert (format "%s TODO %s\n:PROPERTIES:\n:ONBOARD_ID: %s\n:END:\n"
                        (make-string (1+ level) ?*) (drgnx-projects--heading-text text) id))
        t))))

;;;; What was imported (so a TODO removed from the board stays removed)

(defun drgnx-projects--imported-file () (expand-file-name "projects-imported.eld" (drgnx-state-dir)))

(defun drgnx-projects--imported ()
  (let ((h (make-hash-table :test #'equal)))
    (dolist (k (and (file-readable-p (drgnx-projects--imported-file))
                    (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-projects--imported-file)) (read (current-buffer))))))
      (puthash k t h))
    h))

(defun drgnx-projects--save-imported (h)
  (let ((keys nil) (file (drgnx-projects--imported-file)))
    (maphash (lambda (k _) (push k keys)) h)
    (make-directory (file-name-directory file) t)
    (let ((tmp (make-temp-file (expand-file-name ".imported-" (file-name-directory file)))))
      (with-temp-file tmp (prin1 (sort keys #'string<) (current-buffer)))
      (rename-file tmp file t))))

;;;; projects.eld, project.el

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
    ;; project.el's list in drgnx's state dir: the session's own list when it already uses that file
    ;; (so it learns them too), else a fresh read of that file (the command line).
    (let ((ours (expand-file-name "projects" (drgnx-state-dir))))
      (make-directory (drgnx-state-dir) t)
      (cl-flet ((remember ()
                  (dolist (e entries)
                    (when-let* ((p (ignore-errors (project-current nil (plist-get e :root)))))
                      (project-remember-project p)))))
        (if (equal (expand-file-name project-list-file) ours)
            (remember)
          (let ((project-list-file ours) (project--list 'unset)) (remember)))))))

(cl-defun drgnx-projects-import (roots &key (todos t))
  "Put the git repositories ROOTS on the board (once each); TODOS: t for every root's open TODOs, a
list of roots for theirs, nil for none (each TODO once, and never again once removed from the
board).  Returns (:added NAMES :todos N :capped NAMES)."
  (let* ((roots (delete-dups (mapcar (lambda (r) (directory-file-name (expand-file-name r)))
                                     (seq-filter #'file-directory-p roots))))
         (todo-roots (cond ((eq todos t) roots)
                           ((listp todos) (mapcar (lambda (r) (directory-file-name (expand-file-name r))) todos))))
         (entries (mapcar (lambda (r) (list :name (file-name-nondirectory r) :root r :url (drgnx-projects--url r))) roots))
         (imported (drgnx-projects--imported))
         (added nil) (count 0) (capped nil))
    (drgnx-projects--board-update
     (lambda ()
       (dolist (e entries)
         (let ((root (plist-get e :root)))
           (unless (drgnx-projects--find root)
             (drgnx-projects--add-heading (plist-get e :name) root (plist-get e :url))
             (push (plist-get e :name) added))
           (when (member root todo-roots)
             (let ((n 0))
               (pcase-dolist (`(,text . ,id) (drgnx-projects--todos root))
                 (let ((key (concat (drgnx-projects--norm root) "\0" id)))
                   (unless (gethash key imported)
                     (if (>= n drgnx-projects-todo-cap)
                         (cl-pushnew (plist-get e :name) capped :test #'equal)
                       (when (drgnx-projects--add-todo (drgnx-projects--find root) text id)
                         (setq n (1+ n) count (1+ count)))
                       (puthash key t imported)))))))))))
    (drgnx-projects--save-imported imported)
    (drgnx-projects--remember entries)
    (list :added (nreverse added) :todos count :capped (nreverse capped))))

(provide 'drgnx-projects)
;;; drgnx-projects.el ends here
