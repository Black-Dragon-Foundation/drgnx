;;; drgnx-git.el --- Git status for the workbench, asynchronously -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One `git status --porcelain=v2' per repository, in the background (never one per folder),
;; with `--no-optional-locks' so it never holds the index lock while you use git.  The result
;; maps paths to a status (modified, added, deleted, renamed, untracked, conflict, ignored);
;; folders get the strongest status inside them, computed once per run.  Lookups are hash
;; lookups, made only for the rows on screen (the panels paint with jit-lock).  No git, a
;; remote folder or a failing git: nothing, silently.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defface drgnx-git-modified '((t :inherit vc-edited-state)) "A modified file, or a folder with changes." :group 'drgnx)
(defface drgnx-git-added '((t :inherit vc-locally-added-state)) "An added or untracked file." :group 'drgnx)
(defface drgnx-git-deleted '((t :inherit vc-removed-state)) "A deleted file." :group 'drgnx)
(defface drgnx-git-conflict '((t :inherit vc-conflict-state)) "A file with merge conflicts." :group 'drgnx)
(defface drgnx-git-ignored '((t :inherit shadow)) "An ignored file or folder." :group 'drgnx)

(defconst drgnx-git--looks
  '((conflict "C" drgnx-git-conflict 6) (deleted "D" drgnx-git-deleted 5) (modified "M" drgnx-git-modified 4)
    (renamed "R" drgnx-git-modified 3) (added "A" drgnx-git-added 2) (untracked "U" drgnx-git-added 1)
    (ignored nil drgnx-git-ignored 0))
  "Status → (LETTER FACE RANK); folders take the highest-ranked status inside them.")

(defvar drgnx-git--repos (make-hash-table :test #'equal)
  "Repository root → plist (:files HASH :folders HASH :proc PROCESS :again BOOL).")
(defvar drgnx-git--roots (make-hash-table :test #'equal) "Folder → its repository root, or `none'.")
(defvar drgnx-git-changed-functions nil "Called with a repository root after its status was read.")
(defcustom drgnx-git-ignored-limit 20000
  "Past this many ignored entries, ignored files are not dimmed (parsing them would pause Emacs)."
  :type 'integer :group 'drgnx)

(defun drgnx-git-root (path)
  "The repository root (with a trailing /) holding PATH, or nil (also for remote paths)."
  (unless (file-remote-p path)
    (let* ((dir (if (directory-name-p path) (expand-file-name path)   ; a folder (trailing /): itself
                  (file-name-directory (directory-file-name (expand-file-name path)))))
           (hit (gethash dir drgnx-git--roots)))
      (unless hit
        (setq hit (if-let* ((r (locate-dominating-file dir ".git"))) (file-name-as-directory (expand-file-name r)) 'none))
        (puthash dir hit drgnx-git--roots))
      (and (stringp hit) hit))))

(defun drgnx-git--xy (xy)
  "The status of a porcelain v2 ordinary or renamed entry from its XY field."
  (let ((x (aref xy 0)) (y (aref xy 1)))
    (cond ((or (eq x ?D) (eq y ?D)) 'deleted)
          ((eq x ?A) 'added)
          ((eq x ?R) 'renamed)
          (t 'modified))))

(defun drgnx-git-parse (output)
  "Parse `git status --porcelain=v2 -z' OUTPUT into a hash: path (relative, no trailing /) → status."
  (let ((h (make-hash-table :test #'equal)) (entries (split-string output "\0" t)) ignored (n 0))
    (while entries
      (let ((e (pop entries)))
        (pcase (aref e 0)
          (?1 (when (string-match "\\`1 \\(..\\) \\(?:[^ ]+ \\)\\{6\\}\\(.*\\)\\'" e)
                (puthash (match-string 2 e) (drgnx-git--xy (match-string 1 e)) h)))
          (?2 (when (string-match "\\`2 \\(..\\) \\(?:[^ ]+ \\)\\{7\\}\\(.*\\)\\'" e)
                (puthash (match-string 2 e) (drgnx-git--xy (match-string 1 e)) h))
              (pop entries))                    ; the original path of the rename
          (?u (when (string-match "\\`u .. \\(?:[^ ]+ \\)\\{8\\}\\(.*\\)\\'" e)
                (puthash (match-string 1 e) 'conflict h)))
          (?? (puthash (string-remove-suffix "/" (substring e 2)) 'untracked h))
          (?! (when (<= (setq n (1+ n)) drgnx-git-ignored-limit) (push e ignored))))))
    (when (<= n drgnx-git-ignored-limit)
      (dolist (e ignored) (puthash (string-remove-suffix "/" (substring e 2)) 'ignored h)))
    h))

(defun drgnx-git--rank (status) (nth 2 (alist-get status drgnx-git--looks)))

(defun drgnx-git--folders (files)
  "Each folder (relative path) → the strongest non-ignored status inside it."
  (let ((folders (make-hash-table :test #'equal)))
    (maphash (lambda (path status)
               (unless (eq status 'ignored)
                 (let ((dir (file-name-directory path)))
                   (while dir
                     (let* ((d (directory-file-name dir)) (have (gethash d folders)))
                       (when (or (null have) (> (drgnx-git--rank status) (drgnx-git--rank have)))
                         (puthash d status folders)))
                     (setq dir (file-name-directory (directory-file-name dir)))))))
             files)
    folders))

(defun drgnx-git-status (path)
  "PATH's git status, or nil: its own entry, else (a folder) the strongest inside it, else an
ignored or untracked folder around it."
  (when-let* ((root (drgnx-git-root path)) (repo (gethash root drgnx-git--repos)) (files (plist-get repo :files)))
    (let ((rel (string-remove-suffix "/" (file-relative-name (expand-file-name path) root))))
      (or (gethash rel files)
          (gethash rel (plist-get repo :folders))
          (let ((dir (file-name-directory rel)) found)
            (while (and dir (not found))
              (let ((s (gethash (directory-file-name dir) files)))
                (when (memq s '(ignored untracked)) (setq found s)))
              (setq dir (file-name-directory (directory-file-name dir))))
            found)))))

(defun drgnx-git-look (status)
  "(LETTER FACE) for STATUS."
  (let ((l (alist-get status drgnx-git--looks))) (list (car l) (cadr l))))

(defun drgnx-git-refresh (path &optional wait)
  "Read the status of PATH's repository in the background (WAIT: until done, for tests).
A refresh asked for while one runs is done once afterwards."
  (when-let* ((root (drgnx-git-root path)) ((executable-find "git")))
    (let ((repo (gethash root drgnx-git--repos)))
      (if (process-live-p (plist-get repo :proc))
          (puthash root (plist-put repo :again t) drgnx-git--repos)
        (let* ((default-directory root)
               (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
               (buf (generate-new-buffer " *drgnx git*" t))
               (proc (make-process
                      :name "drgnx-git" :buffer buf :noquery t :connection-type 'pipe
                      :stderr (get-buffer-create " *drgnx git errors*" t)
                      :command '("git" "--no-optional-locks" "status" "--porcelain=v2" "-z"
                                 "--ignored=matching" "--untracked-files=normal")
                      :sentinel (lambda (p _event) (drgnx-git--done p root)))))
          (puthash root (plist-put (copy-sequence repo) :proc proc) drgnx-git--repos)))
      (when wait
        ;; Until no run is left: the one running, and the one queued behind it.
        (let (p)
          (while (process-live-p (setq p (plist-get (gethash root drgnx-git--repos) :proc)))
            (accept-process-output p 0.05)
            (unless (process-live-p p) (drgnx-git--done p root))))))))

(defun drgnx-git--done (proc root)
  "PROC (git status for ROOT) ended: keep its result, tell the panels, run a waiting refresh."
  (let ((buf (process-buffer proc)))
    (when (and (memq (process-status proc) '(exit signal)) (buffer-live-p buf))
      (let ((repo (plist-put (gethash root drgnx-git--repos) :result      ; how the last run ended
                             (list (process-status proc) (process-exit-status proc)))))
        (when (and (eq (process-status proc) 'exit) (= (process-exit-status proc) 0))
          (let ((files (drgnx-git-parse (with-current-buffer buf (buffer-string)))))
            (setq repo (plist-put (plist-put repo :files files) :folders (drgnx-git--folders files)))))
        (kill-buffer buf)
        (let ((again (plist-get repo :again)))
          (puthash root (plist-put (plist-put repo :proc nil) :again nil) drgnx-git--repos)
          (run-hook-with-args 'drgnx-git-changed-functions root)
          (when again (drgnx-git-refresh root)))))))

(provide 'drgnx-git)
;;; drgnx-git.el ends here
