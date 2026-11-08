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
(require 'subr-x)
(require 'drgnx-memo)
(require 'drgnx-timer)
(require 'drgnx-notice)

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

(defconst drgnx-git-roots-max 16
  "How many repositories' status is kept.  A panel reads at most this many at a time (more would push out its own).")

;; Repository root → plist (:files HASH :folders HASH :branch PLIST :proc PROCESS :again BOOL), at most 16 roots (the
;; least recently read goes first; PERF-M5).  A root evicted while its status process runs is put back when the
;; process finishes; the process is not killed.  `drgnx-core/workbench' activates it (empties it on teardown).
(defconst drgnx-git-speedup-entries 50000
  "A repository whose index holds more entries than this is offered git's own speedups (see `drgnx-git--offer').")
(defvar drgnx-git--offered nil "Roots offered the speedups this session, newest first (at most 64); not saved.")
(drgnx-cache-define 'git-status :key 'string :cap drgnx-git-roots-max
                    :doc "Repository root → its status plist; capped at 16 roots, the least recently read evicted.")
(defvar drgnx-git--roots (make-hash-table :test #'equal) "Folder → its repository root, or `none'.")
(defvar drgnx-git-changed-functions nil "Called with a repository root after its status was read.")
(defcustom drgnx-git-ignored-limit 20000
  "Past this many ignored entries, ignored files are not dimmed (parsing them would pause Emacs)."
  :type 'integer :group 'drgnx)

(defun drgnx-git-root (path)
  "The repository root (with a trailing /) holding PATH, or nil (also for remote paths)."
  (unless (file-remote-p path)
    (let* ((dir (cond ((directory-name-p path) (expand-file-name path))   ; a folder (trailing /): itself
                      ;; a repository's own folder, named without a trailing / (the Explorer's root rows): once it
                      ;; is known as its own root, whether or not its status is in the cache now
                      ((let ((d (file-name-as-directory (expand-file-name path))))
                         (and (equal (gethash d drgnx-git--roots) d) d)))
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

;; The status parser is one record at a time (`drgnx-git--acc-feed'), so the same code reads the whole output
;; (`drgnx-git-parse') and the batches of Nidhogg's records framing as they arrive (`drgnx-git--batch').  A rename
;; (`2 …') is followed by its origin path as a record of its own, which may land in the next batch: ACC carries a
;; flag, SKIP, saying the next record is that origin.  No process, timer or clock here: the order of the records is
;; the only input.
(cl-defstruct (drgnx-git--acc (:constructor drgnx-git--acc-make) (:copier nil))
  "A status being read: FILES (path → status), IGNORED (the `! ' records, newest first), N (how many), SKIP (the
next record is a rename's origin path) and BRANCH (the `# ' records, newest first)."
  (files (make-hash-table :test #'equal)) ignored (n 0) skip branch)

(defun drgnx-git--acc-feed (acc e)
  "Read the record E (one NUL-separated entry, no separator) into ACC."
  (cond
   ((string-empty-p e))
   ((drgnx-git--acc-skip acc) (setf (drgnx-git--acc-skip acc) nil)) ; the original path of the rename
   (t
    (let ((h (drgnx-git--acc-files acc)))
      (pcase (aref e 0)
        (?1 (when (string-match "\\`1 \\(..\\) \\(?:[^ ]+ \\)\\{6\\}\\(.*\\)\\'" e)
              (puthash (match-string 2 e) (drgnx-git--xy (match-string 1 e)) h)))
        (?2 (when (string-match "\\`2 \\(..\\) \\(?:[^ ]+ \\)\\{7\\}\\(.*\\)\\'" e)
              (puthash (match-string 2 e) (drgnx-git--xy (match-string 1 e)) h))
            (setf (drgnx-git--acc-skip acc) t))
        (?u (when (string-match "\\`u .. \\(?:[^ ]+ \\)\\{8\\}\\(.*\\)\\'" e)
              (puthash (match-string 1 e) 'conflict h)))
        (?? (puthash (string-remove-suffix "/" (substring e 2)) 'untracked h))
        (?! (when (<= (cl-incf (drgnx-git--acc-n acc)) drgnx-git-ignored-limit) (push e (drgnx-git--acc-ignored acc))))
        (?# (push e (drgnx-git--acc-branch acc))))))))

(defun drgnx-git--acc-files-done (acc)
  "ACC's path → status hash, with the ignored entries put in unless there are too many.  Call it once, at the end."
  (let ((h (drgnx-git--acc-files acc)))
    (when (<= (drgnx-git--acc-n acc) drgnx-git-ignored-limit)
      (dolist (e (reverse (drgnx-git--acc-ignored acc)))
        (puthash (string-remove-suffix "/" (substring e 2)) 'ignored h)))
    h))

(defun drgnx-git--acc-branch-of (acc)
  "ACC's branch as `drgnx-git-parse-branch' reads it, or nil."
  (drgnx-git-parse-branch (mapconcat (lambda (e) (concat e "\0")) (reverse (drgnx-git--acc-branch acc)) "")))

(defun drgnx-git-parse (output)
  "Parse `git status --porcelain=v2 -z' OUTPUT into a hash: path (relative, no trailing /) → status."
  (let ((acc (drgnx-git--acc-make)))
    (dolist (e (split-string output "\0" t)) (drgnx-git--acc-feed acc e))
    (drgnx-git--acc-files-done acc)))

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
  (if-let* ((buf (drgnx-git--letters-buffer root)))
      (drgnx-git--letters-branch buf)
    (plist-get (drgnx-cache-get 'git-status root) :branch)))

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
ignored or untracked folder around it.
With the hub's letters (`drgnx-git-letters-active-p') the answers come from its rows."
  (if-let* ((root (drgnx-git-root path)) (buf (drgnx-git--letters-buffer root)))
      (drgnx-git--letters-status buf (string-remove-suffix "/" (file-relative-name (expand-file-name path) root)))
    (drgnx-git--status-cache path)))

(defun drgnx-git--status-cache (path)
  "`drgnx-git-status' from the status the last local run read."
  (when-let* ((root (drgnx-git-root path)) (repo (drgnx-cache-get 'git-status root)) (files (plist-get repo :files)))
    (let ((rel (string-remove-suffix "/" (file-relative-name (expand-file-name path) root))))
      (or (gethash rel files)
          (gethash rel (plist-get repo :folders))
          (let ((dir (file-name-directory rel)) found)
            (while (and dir (not found))
              (let ((s (gethash (directory-file-name dir) files)))
                (when (memq s '(ignored untracked)) (setq found s)))
              (setq dir (file-name-directory (directory-file-name dir))))
            found)))))

(defun drgnx-git-unread-p (path)
  "Non-nil when PATH is in a repository whose status is not in the cache: never read, or pushed out.
A peek: it keeps nothing from eviction."
  (when-let* ((root (drgnx-git-root path)))
    (and (not (drgnx-git--letters-buffer root)) (not (drgnx-cache-peek 'git-status root)))))

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

(defvar nidhogg-workers-framing)
(declare-function nidhogg-set-process-framing "nidhogg-io.c" (process framing &rest args))

(defun drgnx-git--batch (proc batch)
  "Read BATCH, a list of (RECORD RAW ERROR) from Nidhogg's records framing of PROC, into PROC's status.
The batches of a run all come before its sentinel, so before `drgnx-git--done' kills the process buffer (a batch
for a dead buffer would be dropped); the run's result is read from here, not from the buffer."
  (when-let* ((acc (process-get proc 'drgnx-git-acc)))
    (pcase-dolist (`(,record ,_raw ,err) batch)
      (when (and (stringp record) (not err)) (drgnx-git--acc-feed acc record)))))

(defun drgnx-git--frame (proc)
  "Have PROC's output delivered in records (see `drgnx-git--batch'); the accumulator they go into, or nil.
Only with Nidhogg's framing and its switch (`nidhogg-workers-framing') on; any refusal leaves PROC as it is (its
output goes to its buffer, read at the sentinel).  The caller puts the accumulator on PROC: no batch is delivered
before it does, because batches run only when Lisp waits for output."
  (when (and (fboundp 'nidhogg-set-process-framing) (bound-and-true-p nidhogg-workers-framing))
    (condition-case nil
        (progn (nidhogg-set-process-framing proc 'records :separator 0 :coding 'utf-8-unix
                                            :batch-function #'drgnx-git--batch)
               (drgnx-git--acc-make))
      (error nil))))

(defun drgnx-git--run-of (root)
  "ROOT's status run that is still going, or nil: found among the processes, for a ROOT the cache pushed out while
its run went on (the entry, and with it :proc, is gone)."
  (let ((procs (process-list)) found)
    (while (and procs (not found))
      (let ((p (car procs)))
        (when (and (equal (process-get p 'drgnx-git-root) root) (process-live-p p)) (setq found p)))
      (setq procs (cdr procs)))
    found))

(defun drgnx-git-refresh (path &optional wait)
  "Read the status of PATH's repository in the background (WAIT: until done, for tests): the hub's letters when the hub
is up (`git/letters', rows the editor reads), else a `git status' run of Emacs's own (`drgnx-git--refresh-local')."
  ;; Folders found outside any repository are looked at again: one may have been made since (git init).
  (maphash (lambda (dir root) (when (eq root 'none) (remhash dir drgnx-git--roots))) drgnx-git--roots)
  (let ((root (and (drgnx-git--hub-ready-p) (drgnx-git-root path))))
    (if root
        (drgnx-git--letters-refresh root wait)
      (when-let* ((r (drgnx-git-root path))) (drgnx-git--letters-drop r))
      (drgnx-git--refresh-local path wait))))

(defun drgnx-git--refresh-local (path &optional wait)
  "Read the status of PATH's repository in the background with a process of Emacs's own (WAIT: until done, for tests).
A refresh asked for while one runs is done once afterwards, also when the cache pushed the repository out meanwhile."
  (when-let* ((root (drgnx-git-root path)) ((executable-find "git")))
    (let* ((repo (drgnx-cache-get 'git-status root))
           (running (if repo (plist-get repo :proc) (drgnx-git--run-of root))))
      (if (process-live-p running)
          (drgnx-cache-put 'git-status root (plist-put (plist-put repo :proc running) :again t))
        (let* ((default-directory root)
               (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
               (buf (generate-new-buffer " *drgnx git*" t))
               ;; git's complaints: a bounded tail, and no "stderr finished" line per run (a buffer
               ;; given as :stderr gets the default sentinel, which writes one).
               (err (make-pipe-process :name "drgnx-git-stderr" :noquery t :sentinel #'ignore
                                       :filter #'drgnx-git--stderr))
               (proc (make-process
                      :name "drgnx-git" :buffer buf :noquery t :connection-type 'pipe :stderr err
                      ;; its own decoding, not the session's: Nidhogg frames only a process whose coding has no
                      ;; state, and a C locale's default (`undecided') has; the buffer path reads UTF-8 names too
                      :coding 'utf-8-unix
                      :command '("git" "--no-optional-locks" "status" "--porcelain=v2" "--branch" "-z"
                                 "--ignored=matching" "--untracked-files=normal")
                      :sentinel (lambda (p _event) (drgnx-git--done p root)))))
          (process-put proc 'drgnx-git-root root)
          (process-put proc 'drgnx-git-acc (drgnx-git--frame proc))
          (drgnx-cache-put 'git-status root (plist-put (copy-sequence repo) :proc proc))))
      (when wait
        ;; Until no run is left unread: the one running, and the one queued behind it.  A run is read
        ;; when `drgnx-git--done' clears :proc, not when git exits: on a loaded machine git can be gone
        ;; before the first look, its output still in the pipe and its sentinel not yet run.
        (let (p)
          (while (setq p (plist-get (drgnx-cache-get 'git-status root) :proc))
            (if (process-live-p p)
                (accept-process-output p 0.05)
              ;; Read what it left in the pipe (this runs its sentinel), then finish it if that did not.
              (while (accept-process-output p 0))
              (drgnx-git--done p root))))))))

(defun drgnx-git--done (proc root)
  "PROC (git status for ROOT) ended: keep its result, tell the panels, run a waiting refresh.
Only ROOT's current run counts: one already finished, or one a newer run replaced (it ended before its
sentinel ran, and a refresh started another), just gives its buffer back.  Its late sentinel must not
clear the newer run's :proc, or a wait on that run stops before it is read.  A ROOT the cache evicted while PROC
ran has no entry: PROC is still its run (unless it was read already), and its result puts the root back.
The look is a peek: a late sentinel is no use of ROOT, and a stamp would evict another root in its place."
  (let* ((buf (process-buffer proc)) (repo (drgnx-cache-peek 'git-status root)))
    (when (memq (process-status proc) '(exit signal))
      (if (if repo (not (eq proc (plist-get repo :proc))) (process-get proc 'drgnx-git-read))
          (when (buffer-live-p buf) (kill-buffer buf))
        (process-put proc 'drgnx-git-read t)
        (setq repo (plist-put repo :result (list (process-status proc) (process-exit-status proc)))) ; how the last run ended
        (when (and (eq (process-status proc) 'exit) (= (process-exit-status proc) 0))
          (let ((acc (process-get proc 'drgnx-git-acc)) files branch)
            (cond (acc (setq files (drgnx-git--acc-files-done acc) branch (drgnx-git--acc-branch-of acc)))
                  ((buffer-live-p buf)
                   (let ((output (with-current-buffer buf (buffer-string))))
                     (setq files (drgnx-git-parse output) branch (drgnx-git-parse-branch output)))))
            (when files
              (setq repo (plist-put (plist-put (plist-put repo :files files) :folders (drgnx-git--folders files))
                                    :branch branch)))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (let ((again (plist-get repo :again)))
          (drgnx-cache-put 'git-status root (plist-put (plist-put repo :proc nil) :again nil))
          (run-hook-with-args 'drgnx-git-changed-functions root)
          ;; The index header is read here (12 bytes, no process); the rest waits for idle.
          (when (and (not (member root drgnx-git--offered))
                     (> (or (drgnx-git--index-entries root) 0) drgnx-git-speedup-entries))
            (drgnx-timer-soon (cons 'git-speedups root) 1 #'drgnx-git--offer :args (list root) :idle t :owner :core))
          (when again (drgnx-git-refresh root)))))))

;;;; On the rows path: the hub's letters (Sjá)
;; With the hub up (and `drgnx-view-old-path' off, and Sjá in this Emacs) a repository's status is read by the hub
;; (`git/letters'), which sends a hub-fed view of its own per repository the rows `f:PATH' (a letter per changed
;; path, ignored ones included), `d:FOLDER' (a mark per shown folder holding a change; only the folders
;; `drgnx-git-shown-functions' name are worked out) and `branch'.  The view lives in a buffer no window shows (its env
;; is the selected window's class, `drgnx-view-env-register' HEADLESS) and is never drawn; `drgnx-git-status',
;; `drgnx-git-branch' and `drgnx-git-unread-p' read its rows, and `drgnx-git-changed-functions' run after each patch.
;; At most `drgnx-git-roots-max' repositories keep one (the least recently refreshed goes).

(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-patch-detach "drgnx-view")
(declare-function drgnx-view-patch-rows "drgnx-view")
(declare-function drgnx-view-patch-version "drgnx-view")
(declare-function drgnx-view-patch-view "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(declare-function drgnx-view-env-unregister "drgnx-view-env" (view))
(defvar drgnx-hub--events)
(defvar drgnx-hub-event-functions)
(defvar drgnx-view-old-path)
(defvar drgnx-view-patch)

(defvar drgnx-git-shown-functions nil
  "Functions of no argument, each returning the folders (absolute) whose changes are shown, for the hub's folder
marks (the Explorer's roots and open folders).")

(defvar drgnx-git--letters (make-hash-table :test #'equal)
  "Repository root → the buffer of its letters view, at most `drgnx-git-roots-max'.")
(defvar drgnx-git--letters-order nil "The roots in `drgnx-git--letters', the most recently refreshed first.")
(defvar drgnx-git--letters-views (make-hash-table :test #'equal) "View id → its root.")

(defun drgnx-git--hub-ready-p ()
  "Non-nil when the status is read by the hub: not `drgnx-view-old-path', Sjá in this Emacs, the hub connected."
  (and (not (bound-and-true-p drgnx-view-old-path)) (fboundp 'nidhogg-view--call)
       (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-git--letters-buffer (root)
  "ROOT's letters buffer, or nil: a cache read."
  (let ((b (gethash root drgnx-git--letters))) (and (buffer-live-p b) b)))

(defun drgnx-git-letters-active-p ()
  "Non-nil when some repository's status comes from the hub's letters."
  (> (hash-table-count drgnx-git--letters) 0))

(defun drgnx-git--letters-view (root)
  "The hub view id of ROOT's letters: 20 bytes, whatever the length of the path."
  (concat "git-" (substring (md5 root) 0 16)))

(defun drgnx-git--letters-rows (buf)
  (drgnx-view-patch-rows (buffer-local-value 'drgnx-view-patch buf)))

(defun drgnx-git--letters-kind (rows key)
  "The status symbol the row KEY of ROWS names, or nil."
  (when-let* ((row (gethash key rows))
              (p (seq-find (lambda (p) (equal (nth 2 p) "drgnx-git-status")) (plist-get row :props))))
    (intern (nth 3 p))))

(defun drgnx-git--letters-status (buf rel)
  "`drgnx-git-status' of the path REL (relative to the root, no trailing /) from the rows of BUF."
  (let ((rows (drgnx-git--letters-rows buf)))
    (or (drgnx-git--letters-kind rows (concat "f:" rel))
        (drgnx-git--letters-kind rows (concat "d:" rel))
        (let ((dir (file-name-directory rel)) found)
          (while (and dir (not found))
            (let ((s (drgnx-git--letters-kind rows (concat "f:" (directory-file-name dir)))))
              (when (memq s '(ignored untracked)) (setq found s)))
            (setq dir (file-name-directory (directory-file-name dir))))
          found))))

(defun drgnx-git--letters-branch (buf)
  "`drgnx-git-branch' from the branch row of BUF: (:head NAME :ahead A :behind B), or (:head nil :detached t)."
  (when-let* ((row (gethash "branch" (drgnx-git--letters-rows buf)))
              (v (nth 3 (car (plist-get row :props)))))
    (if (plist-get v :head) (list :head (plist-get v :head) :ahead (plist-get v :ahead) :behind (plist-get v :behind))
      (list :head nil :detached t))))

(defun drgnx-git--letters-drop (root)
  "Forget ROOT's letters: its buffer goes (the hub is not told: its rows for the view stop with the connection)."
  (when-let* ((b (gethash root drgnx-git--letters)))
    (remhash root drgnx-git--letters)
    (setq drgnx-git--letters-order (delete root drgnx-git--letters-order))
    (when (buffer-live-p b)
      (with-current-buffer b
        (when drgnx-view-patch
          (let ((view (drgnx-view-patch-view drgnx-view-patch)))
            (remhash view drgnx-git--letters-views)
            ;; the hub forgets the pair and the rows it believes this editor holds: a view made again gets them anew
            (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
              (ignore-errors (drgnx-hub--call-on drgnx-hub--events "view/close" (list :view view) #'ignore)))
            (drgnx-view-env-unregister view)
            (drgnx-view-patch-detach))))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
    (unless (drgnx-git-letters-active-p) (remove-hook 'drgnx-hub-event-functions #'drgnx-git--hub-event))))

(defun drgnx-git-letters-clear ()
  "Forget every repository's letters (the module's teardown, tests)."
  (dolist (root (hash-table-keys drgnx-git--letters)) (drgnx-git--letters-drop root)))

(defun drgnx-git--letters-attach (root)
  "ROOT's letters buffer, made (a hub-fed view no window shows) when it is not."
  (require 'drgnx-view)
  (or (drgnx-git--letters-buffer root)
      (let ((view (drgnx-git--letters-view root)))
        (while (>= (hash-table-count drgnx-git--letters) drgnx-git-roots-max)
          (drgnx-git--letters-drop (car (last drgnx-git--letters-order))))
        (with-current-buffer (generate-new-buffer (format " *drgnx git letters %s*" view) t)
          (buffer-disable-undo)
          (drgnx-view-patch-attach view "unshown")
          (require 'drgnx-view-env)
          (puthash root (current-buffer) drgnx-git--letters)
          (puthash view root drgnx-git--letters-views)
          (add-hook 'drgnx-hub-event-functions #'drgnx-git--hub-event 90)
          (drgnx-view-env-register view (current-buffer) #'drgnx-git--letters-resubscribe t)
          (current-buffer)))))

(defun drgnx-git--letters-shown (root)
  "The folders under ROOT that `drgnx-git-shown-functions' name, relative to it, without the root itself."
  (let (out)
    (dolist (f drgnx-git-shown-functions)
      (dolist (dir (funcall f))
        (let ((rel (string-remove-suffix "/" (file-relative-name (expand-file-name dir) root))))
          (unless (or (member rel '("." "")) (string-prefix-p ".." rel)) (cl-pushnew rel out :test #'equal)))))
    out))

(defun drgnx-git--letters-refresh (root &optional wait)
  "Ask the hub for ROOT's letters, without waiting (WAIT: until a patch arrives, for tests).  A call while one is
running is overtaken by the hub: the newer read wins."
  (let* ((buf (drgnx-git--letters-attach root)) (view (drgnx-git--letters-view root))
         (before (drgnx-view-patch-version (buffer-local-value 'drgnx-view-patch buf))))
    (setq drgnx-git--letters-order (cons root (delete root drgnx-git--letters-order)))
    (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
    (condition-case err
        ;; on the subscribed connection: the rows go to the connection that asks
        (drgnx-hub--call-on drgnx-hub--events "git/letters" (list :view view :root (directory-file-name root)
                                                                  :shown (vconcat (drgnx-git--letters-shown root)))
                            (lambda (_result error) (when error (drgnx-git--letters-failed root error))))
      (error (drgnx-git--letters-failed root (error-message-string err))))
    (when wait
      (let ((deadline (+ (float-time) 10)))
        (while (and (buffer-live-p buf) (< (float-time) deadline)
                    (equal before (drgnx-view-patch-version (buffer-local-value 'drgnx-view-patch buf))))
          (accept-process-output nil 0.05))))))

(defun drgnx-git--letters-resubscribe (view)
  "The hub is up again: its letters for VIEW were lost, ask again."
  (when-let* ((root (gethash view drgnx-git--letters-views))) (drgnx-git--letters-refresh root)))

(defun drgnx-git--letters-failed (root message)
  "ROOT's status could not be had from the hub (MESSAGE): a warning notice and a line in the errors buffer."
  (drgnx-git--stderr nil (format "%s: %s\n" root message))
  (drgnx-notify 'wb 'warn (format "git status of %s: %s" (abbreviate-file-name root) message)
                :id (list 'git-letters-error root)))

(defun drgnx-git--hub-event (event data)
  "`drgnx-hub-event-functions': after a patch of a letters view (the view's own handler ran first), the panels
read the status again."
  (when (equal event "git-letters-error")
    (when-let* ((root (gethash (plist-get data :view) drgnx-git--letters-views)))
      (drgnx-git--letters-failed root (plist-get data :error))))
  (when (equal event "view-patch")
    (when-let* ((root (gethash (plist-get data :view) drgnx-git--letters-views)))
      (run-hook-with-args 'drgnx-git-changed-functions root))))

;;;; The fsmonitor offer

(defun drgnx-git--git-dir (root)
  "The git directory of the repository at ROOT (its .git folder, or the one a .git file points at), or nil."
  (let ((dotgit (expand-file-name ".git" root)))
    (cond ((file-directory-p dotgit) dotgit)
          ((file-regular-p dotgit)
           (with-temp-buffer
             (insert-file-contents dotgit nil 0 1024)
             (when (looking-at "gitdir: \\(.+\\)")
               (expand-file-name (match-string 1) root)))))))

(defun drgnx-git--index-entries (root)
  "How many entries the index of the repository at ROOT holds, from its 12-byte header (\"DIRC\", version, count:
bytes 8 to 11, big-endian); nil when there is no readable index.  No process."
  (when-let* ((dir (drgnx-git--git-dir root)) (index (expand-file-name "index" dir)) ((file-readable-p index)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally index nil 0 12)
      (let ((s (buffer-string)))
        (when (and (= (length s) 12) (equal (substring s 0 4) "DIRC"))
          (+ (ash (aref s 8) 24) (ash (aref s 9) 16) (ash (aref s 10) 8) (aref s 11)))))))

(defun drgnx-git--config (root key)
  "The value git has for KEY in the repository at ROOT, or nil.  A short synchronous call, made once per large repository."
  (with-temp-buffer
    (when (eq 0 (call-process "git" nil (list t nil) nil "-C" root "config" "--get" key))
      (string-trim (buffer-string)))))

(defun drgnx-git--daemon-p (root)
  "Non-nil when this git has its built-in file system monitor: `git fsmonitor--daemon status' answers 0 (running) or
1 (not running); on a platform without the daemon it fails with 128."
  (memq (call-process "git" nil nil nil "-C" root "fsmonitor--daemon" "status") '(0 1)))

(defun drgnx-git--speedups (untracked fsmonitor daemon)
  "What to offer: `untracked-cache' unless UNTRACKED (its setting now) is on, `fsmonitor' unless FSMONITOR (its setting
now) is set to something but false, and only when DAEMON says git has the built-in monitor."
  (append (unless (member untracked '("true" "1" "yes" "on")) '(untracked-cache))
          (unless (or (not daemon) (and fsmonitor (not (equal fsmonitor "false")))) '(fsmonitor))))

(defun drgnx-git-enable-speedups (root untracked-cache fsmonitor)
  "Set `core.untrackedCache' (UNTRACKED-CACHE non-nil) and `core.fsmonitor' (FSMONITOR non-nil) to true in the
repository at ROOT.  The action of the notice `drgnx-git--offer' posts; nothing is remembered about the choice."
  (dolist (key (append (and untracked-cache '("core.untrackedCache")) (and fsmonitor '("core.fsmonitor"))))
    (call-process "git" nil nil nil "-C" root "config" key "true"))
  (drgnx-notify 'wb 'info (format "git: %s turned on in %s" (if fsmonitor "untracked cache and fsmonitor" "untracked cache")
                                  (abbreviate-file-name root))
                :id (list 'git-speedups root)))

(defun drgnx-git--offer (root)
  "Offer, once per session, git's untracked cache and file system monitor for the repository at ROOT when its index
has more than `drgnx-git-speedup-entries' entries: a notice with an action, never a prompt.  Choosing is not recorded,
and neither is not choosing."
  (when-let* (((not (member root drgnx-git--offered)))
              (n (drgnx-git--index-entries root)) ((> n drgnx-git-speedup-entries)))
    (setq drgnx-git--offered (seq-take (cons root drgnx-git--offered) 64))
    (let ((todo (drgnx-git--speedups (drgnx-git--config root "core.untrackedCache") (drgnx-git--config root "core.fsmonitor")
                                     (drgnx-git--daemon-p root))))
      (when todo
        (drgnx-notify 'wb 'info (format "%s tracks %d files: git status can be faster" (abbreviate-file-name root) n)
                      :id (list 'git-speedups root)
                      :fix (format "Turn on %s" (mapconcat (lambda (s) (if (eq s 'fsmonitor) "core.fsmonitor" "core.untrackedCache"))
                                                           todo " and "))
                      :command (list 'drgnx-git-enable-speedups root (and (memq 'untracked-cache todo) t)
                                     (and (memq 'fsmonitor todo) t)))))))

(provide 'drgnx-git)
;;; drgnx-git.el ends here
