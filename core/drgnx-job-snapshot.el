;;; drgnx-job-snapshot.el --- Jobs: a task's snapshot — a copy of .git, prepared while it is still trusted -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; In snapshot mode each task of a job gets a `.git' of its own in its folder `<repo>/.claude/worktrees/ID-N/': a
;; copy-on-write copy of the repository's `.git' (reflink on btrfs and XFS, clonefile on APFS), or, where the
;; filesystem has no copy-on-write, a shared clone (objects through alternates, the main objects read-only).  Only
;; `.git' is copied: the agent never sees the user's uncommitted changes or untracked files (`.env', keys).
;;
;; The copy is prepared before any agent sees it, while it holds only the user's content: the user's per-checkout
;; state (index, stash, reflogs, linked worktrees, FETCH_HEAD, merge and rebase state) and stale locks are removed, the
;; base commit is checked, the remotes and every credential-bearing key are dropped, `gc.auto' is 0.  Every git run
;; here has the user's hooks and fsmonitor off.  After DONE is called, nothing outside the sandbox runs git in the
;; folder again: its `.git' is the agent's.  Everything runs as asynchronous processes: the hub never waits.
;; See docs/develop/sandbox.md ("Git: snapshot mode").

;;; Code:
(require 'subr-x)

(defcustom drgnx-job-snapshot-timeout 300
  "Seconds one step of a task's snapshot (the copy, the clone, a git of the preparation) may take; then it fails."
  :type 'number :group 'drgnx)

(defvar drgnx-job-snapshot-copy-on-write 'auto
  "Non-nil: a task's snapshot is a copy-on-write copy of `.git' where the repository's filesystem has it
(`drgnx-job-snapshot-cow-p'), else a shared clone.  nil: always the shared clone.")

(defvar drgnx-job-snapshot--cow (make-hash-table :test #'equal)
  "Filesystem (the device number of a repository's .claude/worktrees/) → `yes' or `no', its copy-on-write probe's
answer.  Bounded by the filesystems mounted; never evicted.")

(defconst drgnx-job-snapshot--overrides '("-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false")
  "Given to every git run on a copy: none of the user's hooks (`remote remove' and `update-ref' would run
reference-transaction) and no fsmonitor program runs in the hub.")

(defconst drgnx-job-snapshot--env
  '("GIT_TERMINAL_PROMPT=0" "GIT_DIR" "GIT_WORK_TREE" "GIT_INDEX_FILE" "GIT_COMMON_DIR" "GIT_OBJECT_DIRECTORY"
    "GIT_ALTERNATE_OBJECT_DIRECTORIES")
  "Prepended to `process-environment' for the steps: never a prompt; no variable sends git to another repository.")

(defconst drgnx-job-snapshot--keep
  '("HEAD" "config" "description" "hooks" "info" "objects" "refs" "packed-refs" "shallow" "reftable" "lfs")
  "The entries of a copied `.git' that stay.  Everything else is the user's checkout's state: the index (staged
changes), reflogs (`logs/', the stash's list), linked worktrees, `modules/', FETCH_HEAD (remote URLs), merge, rebase
and sequencer state, `config.worktree', legacy `remotes/' and `branches/' (URLs).")

(defconst drgnx-job-snapshot--strip
  (concat "\\`\\(?:credential\\.\\|url\\.\\|include\\.\\|includeif\\.\\|remote\\.[^.]+\\'"
          "\\|core\\.\\(?:fsmonitor\\|worktree\\|sshcommand\\|askpass\\|gitproxy\\|alternaterefscommand\\)\\'"
          "\\|http\\..*\\.?proxy\\'\\)"
          "\\|\\.\\(?:extraheader\\|[a-z]*\\(?:token\\|pass\\|password\\|secret\\)\\)\\'")
  "Config names (as `git config --name-only --list' prints them) unset in a copy: credentials and what may carry
one (URL rewrites, extra HTTP headers, proxies, keys named like a token or password), includes of files outside, and
the core keys that name a program on the user's machine or the user's checkout (`core.worktree').  Remotes go with
`remote remove'.")

;;;; Where the copy comes from

(defun drgnx-job-snapshot-common-dir (repo)
  "REPO's common git directory (what `git rev-parse --git-common-dir' prints), absolute and resolved, or nil.  A
`.git' file (a linked worktree, a submodule) is followed to its git directory and its `commondir'.  Read from the
files, as git itself does: no process."
  (let ((dotgit (expand-file-name ".git" repo)))
    (cond ((file-directory-p dotgit) (directory-file-name (file-truename dotgit)))
          ((file-regular-p dotgit)
           (let* ((text (with-temp-buffer (insert-file-contents dotgit nil 0 4096) (buffer-string)))
                  (gitdir (and (string-match "\\`gitdir: *\\(.+?\\)[ \t\r\n]*\\'" text)
                               (expand-file-name (match-string 1 text) repo)))
                  (common (and gitdir (expand-file-name "commondir" gitdir))))
             (when (and gitdir (file-directory-p gitdir))
               (directory-file-name
                (file-truename
                 (if (file-regular-p common)
                     (expand-file-name (string-trim (with-temp-buffer (insert-file-contents common nil 0 4096) (buffer-string)))
                                       gitdir)
                   gitdir)))))))))

(defun drgnx-job-snapshot--alternates-of (objects &optional depth)
  "The object directories OBJECTS borrows from (its `info/alternates', followed as git does, 5 deep): resolved."
  (let ((file (expand-file-name "info/alternates" objects)) out)
    (when (and (< (or depth 0) 5) (file-regular-p file))
      (dolist (line (split-string (with-temp-buffer (insert-file-contents file nil 0 65536) (buffer-string)) "\n" t "[ \t\r]+"))
        (let ((dir (and (not (string-prefix-p "#" line)) (expand-file-name line objects))))
          (when (and dir (file-directory-p dir))
            (dolist (d (cons (directory-file-name (file-truename dir)) (drgnx-job-snapshot--alternates-of dir (1+ (or depth 0)))))
              (unless (member d out) (push d out)))))))
    (nreverse out)))

(defun drgnx-job-snapshot-alternates (folder)
  "The object directories FOLDER's repository reads through alternates, which the sandbox must mount read-only:
the main repository's for a shared clone, nil for a copy-on-write copy (unless the repository itself borrows).
`drgnx-job-snapshot-make' gives this as `:read' before any agent starts.  Once an agent has had FOLDER, its alternates
file is the agent's: use the value `drgnx-job-snapshot-make' gave, never this."
  (drgnx-job-snapshot--alternates-of (expand-file-name ".git/objects" folder)))

;;;; Copy-on-write: probed once per filesystem

(defun drgnx-job-snapshot--copy-argv (from to)
  "The command that copies FROM to TO with copy-on-write, or fails."
  (if (eq system-type 'darwin)
      (list "cp" "-c" "-a" from to)
    (list "cp" "-a" "--reflink=always" from to)))

(defun drgnx-job-snapshot--fs (repo)
  "REPO's filesystem: the device number of its .claude/worktrees/ (made when missing)."
  (let ((dir (expand-file-name ".claude/worktrees/" repo)))
    (make-directory dir t)
    (file-attribute-device-number (file-attributes dir))))

(defun drgnx-job-snapshot--remember (repo yes)
  "Remember YES (copy-on-write works) for REPO's filesystem: YES."
  (puthash (drgnx-job-snapshot--fs repo) (if yes 'yes 'no) drgnx-job-snapshot--cow)
  yes)

(defun drgnx-job-snapshot--probe-files (repo)
  "A small file under REPO's .claude/worktrees/ — never in `.git' — and the name of its copy: (FROM . TO)."
  (let ((from (make-temp-file (expand-file-name ".claude/worktrees/.drgnx-cow-probe-" repo) nil nil "probe\n")))
    (cons from (concat from "-copy"))))

(defun drgnx-job-snapshot--probe-clean (files)
  (dolist (f (list (car files) (cdr files))) (ignore-errors (delete-file f))))

(defun drgnx-job-snapshot-cow-p (repo)
  "Non-nil when REPO's filesystem copies with copy-on-write (`cp --reflink=always' on Linux, `cp -c' on macOS).
Probed with one small file under REPO/.claude/worktrees/, once per filesystem.  Synchronous (one tiny `cp'): the hub
uses the asynchronous probe of `drgnx-job-snapshot-make'."
  (pcase (gethash (drgnx-job-snapshot--fs repo) drgnx-job-snapshot--cow)
    ('yes t)
    ('no nil)
    (_ (let ((files (drgnx-job-snapshot--probe-files repo)))
         (unwind-protect
             (let ((argv (drgnx-job-snapshot--copy-argv (car files) (cdr files))))
               (drgnx-job-snapshot--remember repo (eql 0 (apply #'call-process (car argv) nil nil nil (cdr argv)))))
           (drgnx-job-snapshot--probe-clean files))))))

;;;; Steps: asynchronous processes

(defun drgnx-job-snapshot--run (dir argv job done)
  "Run ARGV in DIR in a process of its own; DONE gets (EXIT . OUTPUT) once it ended (stderr in OUTPUT; EXIT
`:timeout' after `drgnx-job-snapshot-timeout').  JOB: stopping that job ends it, and DONE is not called."
  (let* ((out (generate-new-buffer " *drgnx-snapshot*" t))
         (default-directory (file-name-as-directory dir))
         (process-environment (append drgnx-job-snapshot--env process-environment))
         (timer nil)
         (p (make-process
             :name "drgnx-snapshot" :buffer out :noquery t :connection-type 'pipe :command argv
             :sentinel (lambda (p _event)
                         (unless (process-live-p p)
                           (when timer (cancel-timer timer))
                           (let ((text (string-trim (with-current-buffer out (buffer-string)))))
                             (kill-buffer out)
                             (unless (process-get p :stopped)
                               (with-demoted-errors "drgnx snapshot: %S"
                                 (funcall done (cons (if (process-get p :timed-out) :timeout (process-exit-status p)) text))))))))))
    (when job (process-put p :job job))
    (setq timer (run-at-time drgnx-job-snapshot-timeout nil
                             (lambda () (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))))
    (ignore-errors (process-send-eof p))
    p))

(defun drgnx-job-snapshot--git (argv)
  "The command line of git ARGV on a copy: with `drgnx-job-snapshot--overrides'."
  (append '("git") drgnx-job-snapshot--overrides argv))

(defun drgnx-job-snapshot--git-all (folder argvs job done)
  "Run the git ARGVS in FOLDER one after another; DONE gets nil when all succeeded, else (ARGV EXIT . OUTPUT) of the
first that failed."
  (if (null argvs)
      (funcall done nil)
    (drgnx-job-snapshot--run folder (drgnx-job-snapshot--git (car argvs)) job
                             (lambda (r)
                               (if (eql 0 (car r))
                                   (drgnx-job-snapshot--git-all folder (cdr argvs) job done)
                                 (funcall done (cons (car argvs) r)))))))

;;;; Preparation

(defun drgnx-job-snapshot--prepare-argvs (folder base &optional keys)
  "The git argvs that prepare FOLDER's copy, whose config holds the names KEYS (`git config --name-only --list'):
check BASE is there, drop the stash, unset each key `drgnx-job-snapshot--strip' matches, remove every remote, set
`gc.auto' 0 (a repack would un-share the copied blocks), prune worktrees.  Run with `drgnx-job-snapshot--git'."
  (let ((config (expand-file-name ".git/config" folder)) remotes strip)
    (dolist (k keys)
      (cond ((string-match "\\`remote\\.\\(.+\\)\\.[^.]+\\'" k)
             (unless (member (match-string 1 k) remotes) (push (match-string 1 k) remotes)))
            ((string-match-p drgnx-job-snapshot--strip k)
             (unless (member k strip) (push k strip)))))
    (append `(("cat-file" "-e" ,(concat base "^{commit}"))
              ("update-ref" "-d" "refs/stash"))
            (mapcar (lambda (k) (list "config" "--file" config "--unset-all" k)) (nreverse strip))
            (mapcar (lambda (r) (list "remote" "remove" "--" r)) (nreverse remotes))
            `(("config" "--file" ,config "gc.auto" "0")
              ("worktree" "prune")))))

(defun drgnx-job-snapshot--tidy (git)
  "Remove from the copied GIT directory what is the user's checkout's state (`drgnx-job-snapshot--keep') and every
lock a concurrent git of the user's left (`*.lock'), loose objects apart.  Plain file operations: no git runs."
  (dolist (f (directory-files git nil directory-files-no-dot-files-regexp t))
    (unless (member f drgnx-job-snapshot--keep)
      (let ((p (expand-file-name f git)))
        (if (and (file-directory-p p) (not (file-symlink-p p))) (delete-directory p t) (delete-file p)))))
  (dolist (lock (directory-files-recursively
                 git "\\.lock\\'" nil (lambda (d) (not (string-match-p "/objects/[0-9a-f][0-9a-f]\\'\\|/lfs/objects\\'" d)))))
    (delete-file lock)))

(defun drgnx-job-snapshot--carry-alternates (common git)
  "When the repository at COMMON borrows objects, write the directories absolute into the copy at GIT (a relative
entry would point elsewhere from the copy)."
  (when-let* ((alternates (drgnx-job-snapshot--alternates-of (expand-file-name "objects" common))))
    (write-region (concat (string-join alternates "\n") "\n") nil (expand-file-name "objects/info/alternates" git) nil 'silent)))

(defun drgnx-job-snapshot--prepare (folder base job done)
  "Prepare FOLDER's copy (its `.git' tidied already): DONE gets nil, or why it failed (`:base' when BASE is missing)."
  (drgnx-job-snapshot--run
   folder (drgnx-job-snapshot--git (list "config" "--file" (expand-file-name ".git/config" folder) "--no-includes"
                                         "--name-only" "--list" "--null"))
   job
   (lambda (r)
     (if (not (eql 0 (car r)))
         (funcall done (format "reading the copy's config failed: %s" (cdr r)))
       (drgnx-job-snapshot--git-all
        folder (drgnx-job-snapshot--prepare-argvs folder base (split-string (cdr r) "\0" t "[\n]+")) job
        (lambda (failed)
          (funcall done (cond ((null failed) nil)
                              ((equal (caar failed) "cat-file") :base)
                              (t (format "git %s: %s" (string-join (car failed) " ") (cddr failed)))))))))))

;;;; Making a task's snapshot

(defun drgnx-job-snapshot--later (done result)
  "Call DONE with RESULT from a timer: DONE always comes after `drgnx-job-snapshot-make' returned."
  (run-at-time 0 nil done result))

(defun drgnx-job-snapshot--base-ok-p (base)
  (and (stringp base) (< 0 (length base) 256) (not (string-prefix-p "-" base))
       (not (string-match-p "[[:space:][:cntrl:]~^:?*\\[\\\\]\\|\\.\\." base))))

(defun drgnx-job-snapshot--choose (repo job done)
  "DONE gets t when REPO's snapshot is a copy-on-write copy, nil when a shared clone; the first time on a filesystem
it is probed by a process of its own."
  (let ((known (and drgnx-job-snapshot-copy-on-write (gethash (drgnx-job-snapshot--fs repo) drgnx-job-snapshot--cow))))
    (cond ((not drgnx-job-snapshot-copy-on-write) (funcall done nil))
          (known (funcall done (eq known 'yes)))
          (t (let ((files (drgnx-job-snapshot--probe-files repo)))
               (drgnx-job-snapshot--run repo (drgnx-job-snapshot--copy-argv (car files) (cdr files)) job
                                        (lambda (r)
                                          (drgnx-job-snapshot--probe-clean files)
                                          (funcall done (drgnx-job-snapshot--remember repo (eql 0 (car r)))))))))))

(defun drgnx-job-snapshot--attempt (repo common folder base cow job tries done)
  "Make FOLDER's snapshot (COW: a copy of COMMON, else a shared clone of REPO) and prepare it; on a failure remove it
and, while TRIES is above 1, make it again."
  (let ((git (expand-file-name ".git" folder))
        (fail (lambda (why)
                (drgnx-job-snapshot--run
                 repo (list "rm" "-rf" "--" (directory-file-name folder)) job
                 (lambda (_)
                   (if (> tries 1)
                       (drgnx-job-snapshot--attempt repo common folder base cow job (1- tries) done)
                     (funcall done (list :error (if (eq why :base) (format "the base %s is not in the repository" base) why)))))))))
    (condition-case err
        (progn
          (make-directory (if cow folder (file-name-directory (directory-file-name folder))) t)
          (drgnx-job-snapshot--run
           repo (if cow
                    (drgnx-job-snapshot--copy-argv common git)
                  (drgnx-job-snapshot--git (list "clone" "-q" "--shared" "--no-checkout" "--branch" base "--"
                                                 (directory-file-name (expand-file-name repo)) (directory-file-name folder))))
           job
           (lambda (r)
             (if (not (eql 0 (car r)))
                 (funcall fail (format "%s failed: %s" (if cow "the copy" "the clone") (cdr r)))
               (condition-case err
                   (progn
                     (when cow (drgnx-job-snapshot--carry-alternates common git))
                     (drgnx-job-snapshot--tidy git)
                     (drgnx-job-snapshot--prepare
                      folder base job
                      (lambda (why)
                        (if why
                            (funcall fail why)
                          (funcall done (list :mode (if cow 'snapshot 'clone) :read (drgnx-job-snapshot-alternates folder)))))))
                 (error (funcall fail (error-message-string err))))))))
      (error (funcall fail (error-message-string err))))))

(defun drgnx-job-snapshot-make (repo folder base done &optional job)
  "Give the task folder FOLDER (empty or missing) a `.git' of its own from REPO, prepared, with BASE (a branch) in it.
Asynchronous: DONE is called later with (:mode snapshot :read DIRS) — a copy-on-write copy of REPO's common dir —,
\(:mode clone :read DIRS) — a shared clone, without copy-on-write —, or (:error MSG).  DIRS: the object directories
the sandbox must mount read-only (`drgnx-job-snapshot-alternates'), to keep with the task.  A copy without BASE (a git
of the user's was writing) is removed and made once more.  JOB: stopping it ends the steps (DONE is not called).
Nothing is checked out: the sandbox does it.  From DONE on, run no git in FOLDER outside the sandbox."
  (let ((folder (file-name-as-directory (expand-file-name folder)))
        (common (drgnx-job-snapshot-common-dir repo)))
    (cond ((not (drgnx-job-snapshot--base-ok-p base))
           (drgnx-job-snapshot--later done (list :error (format "not a branch name: %S" base))))
          ((not common)
           (drgnx-job-snapshot--later done (list :error (format "%s is not a git repository" repo))))
          ((and (file-exists-p folder) (not (and (file-directory-p folder) (directory-empty-p folder))))
           (drgnx-job-snapshot--later done (list :error (format "%s exists and is not empty" folder))))
          (t (drgnx-job-snapshot--choose
              repo job (lambda (cow) (drgnx-job-snapshot--attempt repo common folder base cow job 2 done)))))))

;;;; Bounded: what a snapshot takes, and its removal

(defun drgnx-job-snapshot-disk-usage (folder done)
  "What task folder FOLDER takes on disk, asynchronously: DONE gets (:bytes N :exclusive M) — N from `du', which
counts blocks shared with the repository in full; M the data not shared with anything (btrfs only, nil elsewhere) —
or (:error MSG)."
  (let* ((dir (directory-file-name (expand-file-name folder)))
         (parent (file-name-directory dir)))
    (drgnx-job-snapshot--run
     parent (list "du" "-sk" dir) nil
     (lambda (r)
       (if (not (and (eql 0 (car r)) (string-match "\\`\\([0-9]+\\)" (cdr r))))
           (funcall done (list :error (cdr r)))
         (let ((bytes (* 1024 (string-to-number (match-string 1 (cdr r))))))
           (if (not (and (eq system-type 'gnu/linux) (executable-find "btrfs")))
               (funcall done (list :bytes bytes :exclusive nil))
             (drgnx-job-snapshot--run
              parent (list "btrfs" "filesystem" "du" "-s" "--raw" dir) nil
              (lambda (b)
                (funcall done (list :bytes bytes
                                    :exclusive (and (eql 0 (car b)) (string-match "^ *[0-9]+ +\\([0-9]+\\) +[0-9]+ +/" (cdr b))
                                                    (string-to-number (match-string 1 (cdr b)))))))))))))))

(defun drgnx-job-snapshot-remove (folder done &optional job)
  "Remove task folder FOLDER, its snapshot with it, asynchronously (`rm -rf': links are removed, never followed).
Only a folder `.claude/worktrees/NAME/' that is not itself a link.  DONE gets t or (:error MSG)."
  (let ((dir (directory-file-name (expand-file-name folder))))
    (if (or (not (string-match-p "/\\.claude/worktrees/[^/]+\\'" dir)) (file-symlink-p dir))
        (drgnx-job-snapshot--later done (list :error (format "not a task folder: %s" dir)))
      (drgnx-job-snapshot--run (file-name-directory dir) (list "rm" "-rf" "--" dir) job
                               (lambda (r) (funcall done (if (eql 0 (car r)) t (list :error (cdr r)))))))))

(provide 'drgnx-job-snapshot)
;;; drgnx-job-snapshot.el ends here
