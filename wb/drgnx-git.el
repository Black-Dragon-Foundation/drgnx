;;; drgnx-git.el --- Git status for the workbench, asynchronously -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One `git status --porcelain=v2' per repository, in the background (never one per folder),
;; with `--no-optional-locks' so it never holds the index lock while you use git.  The result
;; maps paths to a status (modified, added, deleted, renamed, untracked, conflict, ignored);
;; folders get the strongest status inside them, computed once per run.  Lookups are hash
;; lookups, made only for the rows on screen (the panels paint with jit-lock).  No git, a
;; remote folder or a failing git: nothing, silently.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defface drgnx-git-modified '((t :inherit vc-edited-state)) "A modified file, or a folder with changes." :group 'drgnx)
(defface drgnx-git-added '((t :inherit vc-locally-added-state)) "An added or untracked file." :group 'drgnx)
(defface drgnx-git-deleted '((t :inherit vc-removed-state)) "A deleted file." :group 'drgnx)
(defface drgnx-git-conflict '((t :inherit vc-conflict-state)) "A file with merge conflicts." :group 'drgnx)
(defface drgnx-git-ignored '((t :inherit (shadow italic))) "An ignored file or folder." :group 'drgnx)

(defconst drgnx-git--looks
  '((conflict "C" drgnx-git-conflict 6) (deleted "D" drgnx-git-deleted 5) (modified "M" drgnx-git-modified 4)
    (renamed "R" drgnx-git-modified 3) (added "A" drgnx-git-added 2) (untracked "U" drgnx-git-added 1)
    (ignored nil drgnx-git-ignored 0))
  "Status → (LETTER FACE RANK); folders take the highest-ranked status inside them.")

(defvar drgnx-git--repos (make-hash-table :test #'equal)
  "Repository root → plist (:files HASH :folders HASH :branch PLIST :proc PROCESS :again BOOL).")
(defvar drgnx-git--roots (make-hash-table :test #'equal) "Folder → its repository root, or `none'.")
(defvar drgnx-git-changed-functions nil "Called with a repository root after its status was read.")
(defcustom drgnx-git-ignored-limit 20000
  "Past this many ignored entries, ignored files are not dimmed (parsing them would pause Emacs)."
  :type 'integer :group 'drgnx)

(defun drgnx-git-root (path)
  "The repository root (with a trailing /) holding PATH, or nil (also for remote paths)."
  (unless (file-remote-p path)
    (let* ((dir (cond ((directory-name-p path) (expand-file-name path))   ; a folder (trailing /): itself
                      ;; a repository's own folder, named without a trailing / (the Explorer's root rows)
                      ((let ((d (file-name-as-directory (expand-file-name path)))) (and (gethash d drgnx-git--repos) d)))
                      (t (file-name-directory (directory-file-name (expand-file-name path))))))
           (hit (gethash dir drgnx-git--roots)))
      (unless hit
        (setq hit (if-let* ((r (locate-dominating-file dir ".git"))) (file-name-as-directory (expand-file-name r)) 'none))
        (puthash dir hit drgnx-git--roots))
      (and (stringp hit) hit))))

(defun drgnx-git-cached-root (path)
  "The repository root (with a trailing /) already found for PATH, or nil: reads the cache, never the file system.
For code that runs on redisplay; `drgnx-git-root' (which may look at the disk) fills the cache."
  (unless (file-remote-p path)
    (let ((hit (gethash (if (directory-name-p path)
                            (expand-file-name path)
                          (file-name-directory (directory-file-name (expand-file-name path))))
                        drgnx-git--roots)))
      (and (stringp hit) hit))))

(defun drgnx-git-roots-known ()
  "How many folders the root cache has an answer for: it changes when a folder's repository (or that it has none)
is found.  A count, no allocation: redisplay memos compare it to see that `drgnx-git-cached-root' may answer now."
  (hash-table-count drgnx-git--roots))

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

(defun drgnx-git-parse-branch (output)
  "The branch of `git status --branch --porcelain=v2 -z' OUTPUT: (:head NAME :ahead A :behind B), or nil without
branch lines.  A detached HEAD is (:head nil :detached t); a branch with no upstream has no counts."
  (let ((pos 0) (len (length output)) head detached ahead behind found)
    (while (and (< pos len) (eq (aref output pos) ?#))      ; the branch lines come first
      (let* ((end (or (string-search "\0" output pos) len)) (line (substring output pos end)))
        (cond ((string-match "\\`# branch\\.head \\(.+\\)\\'" line)
               (setq found t)
               (if (equal (match-string 1 line) "(detached)") (setq detached t) (setq head (match-string 1 line))))
              ((string-match "\\`# branch\\.ab \\+\\([0-9]+\\) -\\([0-9]+\\)\\'" line)
               (setq ahead (string-to-number (match-string 1 line)) behind (string-to-number (match-string 2 line)))))
        (setq pos (1+ end))))
    (when found
      (if detached (list :head nil :detached t) (list :head head :ahead ahead :behind behind)))))

(defun drgnx-git-branch (root)
  "The branch of the repository at ROOT as the last status run read it (see `drgnx-git-parse-branch'), or nil.
A cache read: it runs no git."
  (plist-get (gethash root drgnx-git--repos) :branch))

(defun drgnx-git--rank (status) (nth 2 (alist-get status drgnx-git--looks)))

(defun drgnx-git--folders (files)
  "Each folder (relative path; \".\" the repository's own) → the strongest non-ignored status inside
it, `added' for one holding untracked files (the folder itself is tracked: it shows ●, not U)."
  (let ((folders (make-hash-table :test #'equal)))
    (maphash (lambda (path status)
               (unless (eq status 'ignored)
                 (let ((dir (file-name-directory path)) (status (if (eq status 'untracked) 'added status)))
                   (cl-flet ((bump (d) (let ((have (gethash d folders)))
                                         (when (or (null have) (> (drgnx-git--rank status) (drgnx-git--rank have)))
                                           (puthash d status folders)))))
                     (bump ".")
                     (while dir
                       (bump (directory-file-name dir))
                       (setq dir (file-name-directory (directory-file-name dir))))))))
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

(defvar drgnx-git-errors-max 20000 "Characters of git's error output kept in ` *drgnx git errors*'.")

(defun drgnx-git--stderr (_proc text)
  "Append TEXT (git's error output) to ` *drgnx git errors*', keeping its last `drgnx-git-errors-max' characters."
  (with-current-buffer (get-buffer-create " *drgnx git errors*" t)
    (goto-char (point-max))
    (insert text)
    (when (> (buffer-size) drgnx-git-errors-max)
      (delete-region (point-min) (- (point-max) drgnx-git-errors-max)))))

(defun drgnx-git-refresh (path &optional wait)
  "Read the status of PATH's repository in the background (WAIT: until done, for tests).
A refresh asked for while one runs is done once afterwards."
  ;; Folders found outside any repository are looked at again: one may have been made since (git init).
  (maphash (lambda (dir root) (when (eq root 'none) (remhash dir drgnx-git--roots))) drgnx-git--roots)
  (when-let* ((root (drgnx-git-root path)) ((executable-find "git")))
    (let ((repo (gethash root drgnx-git--repos)))
      (if (process-live-p (plist-get repo :proc))
          (puthash root (plist-put repo :again t) drgnx-git--repos)
        (let* ((default-directory root)
               (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
               (buf (generate-new-buffer " *drgnx git*" t))
               ;; git's complaints: a bounded tail, and no "stderr finished" line per run (a buffer
               ;; given as :stderr gets the default sentinel, which writes one).
               (err (make-pipe-process :name "drgnx-git-stderr" :noquery t :sentinel #'ignore
                                       :filter #'drgnx-git--stderr))
               (proc (make-process
                      :name "drgnx-git" :buffer buf :noquery t :connection-type 'pipe :stderr err
                      :command '("git" "--no-optional-locks" "status" "--porcelain=v2" "--branch" "-z"
                                 "--ignored=matching" "--untracked-files=normal")
                      :sentinel (lambda (p _event) (drgnx-git--done p root)))))
          (puthash root (plist-put (copy-sequence repo) :proc proc) drgnx-git--repos)))
      (when wait
        ;; Until no run is left unread: the one running, and the one queued behind it.  A run is read
        ;; when `drgnx-git--done' clears :proc, not when git exits: on a loaded machine git can be gone
        ;; before the first look, its output still in the pipe and its sentinel not yet run.
        (let (p)
          (while (setq p (plist-get (gethash root drgnx-git--repos) :proc))
            (if (process-live-p p)
                (accept-process-output p 0.05)
              ;; Read what it left in the pipe (this runs its sentinel), then finish it if that did not.
              (while (accept-process-output p 0))
              (drgnx-git--done p root))))))))

(defun drgnx-git-refresh-tree (dirs &optional wait)
  "Refresh the repositories of DIRS and every repository already seen inside them (nested ones).
WAIT: until done, for tests."
  (let ((roots (mapcar (lambda (d) (file-name-as-directory (expand-file-name d))) dirs)) (nested nil))
    (maphash (lambda (_dir root)
               (when (and (stringp root) (not (member root nested))
                          (seq-some (lambda (d) (string-prefix-p d root)) roots))
                 (push root nested)))
             drgnx-git--roots)
    (dolist (r (delete-dups (append roots nested))) (drgnx-git-refresh r wait))))

(defun drgnx-git--done (proc root)
  "PROC (git status for ROOT) ended: keep its result, tell the panels, run a waiting refresh.
Only ROOT's current run counts: one already finished, or one a newer run replaced (it ended before its
sentinel ran, and a refresh started another), just gives its buffer back.  Its late sentinel must not
clear the newer run's :proc, or a wait on that run stops before it is read."
  (let ((buf (process-buffer proc)) (repo (gethash root drgnx-git--repos)))
    (when (memq (process-status proc) '(exit signal))
      (if (not (eq proc (plist-get repo :proc)))
          (when (buffer-live-p buf) (kill-buffer buf))
        (setq repo (plist-put repo :result (list (process-status proc) (process-exit-status proc)))) ; how the last run ended
        (when (and (eq (process-status proc) 'exit) (= (process-exit-status proc) 0) (buffer-live-p buf))
          (let* ((output (with-current-buffer buf (buffer-string))) (files (drgnx-git-parse output)))
            (setq repo (plist-put (plist-put (plist-put repo :files files) :folders (drgnx-git--folders files))
                                  :branch (drgnx-git-parse-branch output)))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (let ((again (plist-get repo :again)))
          (puthash root (plist-put (plist-put repo :proc nil) :again nil) drgnx-git--repos)
          (run-hook-with-args 'drgnx-git-changed-functions root)
          (when again (drgnx-git-refresh root)))))))

(provide 'drgnx-git)
;;; drgnx-git.el ends here
