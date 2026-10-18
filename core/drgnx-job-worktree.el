;;; drgnx-job-worktree.el --- Jobs: worktree mode — a task's linked worktree, and the least of .git it may write -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Worktree mode is opt-in; snapshot mode (drgnx-job-snapshot.el) is the default.  A task gets a classic linked
;; worktree, `git worktree add -b job/ID-N/work FOLDER BASE', that shares the repository's `.git'.  Its sandbox mounts
;; that `.git' read-only but for what one worktree's commits must write: `objects/', the task's own ref directory
;; `refs/heads/job/ID-N/' and its reflog, and the worktree's own directory `worktrees/NAME/'.  The pointers that tell
;; git where the repository is — `FOLDER/.git', and `commondir', `gitdir' and `config.worktree' in `worktrees/NAME/'
;; — are pinned read-only on top, so the agent cannot send git to a directory of its own.  `objects/' stays writable:
;; an agent can delete or overwrite the repository's objects.  A reftable repository keeps every ref in one directory
;; and cannot be split this way: it is refused.  This file builds data and runs git only in the main repository.  See
;; docs/develop/sandbox.md ("Git: worktree mode").

;;; Code:
(require 'subr-x)

(defcustom drgnx-job-worktree-timeout 300
  "Seconds a task's `git worktree add' may take; then it is ended and the task gets the failure."
  :type 'number :group 'drgnx)

(defconst drgnx-job-worktree--reftable
  "this repository keeps its refs in reftable: worktree mode cannot limit the agent to its own branch; use snapshot mode"
  "Why worktree mode refuses a reftable repository.")

(defconst drgnx-job-worktree--overrides '("-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false")
  "Given to every git the hub runs here: no hook and no fsmonitor program runs in the hub.")

(defconst drgnx-job-worktree--env
  '("GIT_TERMINAL_PROMPT=0" "GIT_DIR" "GIT_WORK_TREE" "GIT_INDEX_FILE" "GIT_COMMON_DIR" "GIT_OBJECT_DIRECTORY"
    "GIT_ALTERNATE_OBJECT_DIRECTORIES")
  "Prepended to `process-environment' for the hub's git here: never a prompt, and no variable sends git to another
repository.")

;;;; Names

(defun drgnx-job-worktree--check-task (id n)
  "Signal an error unless ID is a job id (a name of letters, digits, `.', `_', `-', not first a `.' or `-', no `..',
not ending in `.lock') and N a task number (a positive integer): they become a ref directory and a mount."
  (unless (and (stringp id) (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9._-]*\\'" id) (< (length id) 200)
               (not (string-search ".." id)) (not (string-suffix-p ".lock" id)) (not (string-suffix-p "." id)))
    (error "Not a job id: %S" id))
  (unless (and (natnump n) (> n 0)) (error "Not a task number: %S" n)))

(defun drgnx-job-worktree-branch (id n)
  "The branch of task N of job ID in worktree mode: `job/ID-N/work', the one file of its own ref directory
`refs/heads/job/ID-N/'."
  (drgnx-job-worktree--check-task id n)
  (format "job/%s-%d/work" id n))

(defun drgnx-job-worktree--base-ok-p (base)
  "Is BASE a branch name the hub may pass to git (no option, no revision syntax)?"
  (and (stringp base) (< 0 (length base) 256) (not (string-prefix-p "-" base))
       (not (string-match-p "[[:space:][:cntrl:]~^:?*\\[\\\\]\\|\\.\\.\\|//\\|/\\'\\|\\.lock\\'\\|@{" base))))

(defun drgnx-job-worktree--line (file)
  "FILE's first line, trimmed, when FILE is a regular file and not a link; else nil."
  (and (file-regular-p file) (not (file-symlink-p file))
       (ignore-errors (with-temp-buffer (insert-file-contents file nil 0 4096)
                                        (string-trim (buffer-substring (point-min) (line-end-position)))))))

(defun drgnx-job-worktree--common-dir (repo)
  "REPO's common git directory, its true name without a trailing slash, or nil.  A `.git' file (REPO a linked
worktree or a submodule) is followed to its git directory and that one's `commondir'.  Read from the files: no
process."
  (let ((file-name-handler-alist nil) (dotgit (expand-file-name ".git" repo)))
    (cond ((file-directory-p dotgit) (directory-file-name (file-truename dotgit)))
          ((file-regular-p dotgit)
           (let* ((line (drgnx-job-worktree--line dotgit))
                  (gitdir (and line (string-match "\\`gitdir: *\\(.+\\)" line)
                               (expand-file-name (match-string 1 line) repo)))
                  (common (and gitdir (drgnx-job-worktree--line (expand-file-name "commondir" gitdir)))))
             (and gitdir (file-directory-p gitdir)
                  (directory-file-name (file-truename (if common (expand-file-name common gitdir) gitdir)))))))))

(defun drgnx-job-worktree--true (path)
  "PATH's true name, without a trailing slash."
  (let ((file-name-handler-alist nil)) (directory-file-name (file-truename (expand-file-name path)))))

(defun drgnx-job-worktree-name (repo folder)
  "The name git gave FOLDER's worktree in REPO — the directory `worktrees/NAME/' of REPO's `.git' — or nil.  Read from
FOLDER's `.git' file, and kept only when that worktree's `gitdir' leads back to it.  The hub reads it right after
`drgnx-job-worktree-add', before any agent: under the sandbox both files are pinned read-only."
  (let* ((file-name-handler-alist nil)
         (common (drgnx-job-worktree--common-dir repo))
         (dotgit (expand-file-name ".git" folder))
         (line (drgnx-job-worktree--line dotgit))
         (admin (and common line (string-match "\\`gitdir: *\\(.+\\)" line)
                     (drgnx-job-worktree--true (expand-file-name (match-string 1 line) folder))))
         (name (and admin (file-name-nondirectory admin)))
         (back (and admin (drgnx-job-worktree--line (expand-file-name "gitdir" admin)))))
    (and name (equal admin (concat common "/worktrees/" name))
         back (equal (drgnx-job-worktree--true (expand-file-name back admin)) (drgnx-job-worktree--true dotgit))
         name)))

;;;; Refused: reftable

(defun drgnx-job-worktree--show-ref-format (repo)
  "What `git rev-parse --show-ref-format' says in REPO (git 2.45 or later), or nil."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory repo))
          (process-environment (append drgnx-job-worktree--env process-environment)))
      (and (eql 0 (ignore-errors (apply #'call-process "git" nil (list t nil) nil
                                        (append drgnx-job-worktree--overrides '("rev-parse" "--show-ref-format")))))
           (string-trim (buffer-string))))))

(defun drgnx-job-worktree--ref-storage (common)
  "The `extensions.refStorage' of the repository whose common directory is COMMON, from its config file, or nil."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory common))
          (process-environment (append drgnx-job-worktree--env process-environment)))
      (and (eql 0 (ignore-errors (call-process "git" nil (list t nil) nil "config" "--file"
                                               (expand-file-name "config" common) "--get" "extensions.refstorage")))
           (downcase (string-trim (buffer-string)))))))

(defun drgnx-job-worktree-refusal (repo)
  "Why worktree mode cannot be used in REPO, or nil: a repository on the reftable backend keeps every ref in one
`reftable/' directory, which cannot be split into the task's own branch and the rest.  From `git rev-parse
--show-ref-format', or `extensions.refStorage' in the repository's config where git cannot say.  Synchronous: one
short git, in the main repository."
  (when-let* ((common (drgnx-job-worktree--common-dir repo)))
    (when (equal (or (drgnx-job-worktree--show-ref-format repo) (drgnx-job-worktree--ref-storage common))
                 "reftable")
      drgnx-job-worktree--reftable)))

;;;; Making the worktree

(defun drgnx-job-worktree--run (dir argv job done)
  "Run ARGV in DIR in a process of its own; DONE gets (EXIT . OUTPUT) once it ended (stderr in OUTPUT).  EXIT is
`:timeout' after `drgnx-job-worktree-timeout'.  Stopping JOB ends it, and DONE is not called."
  (let* ((out (generate-new-buffer " *drgnx-worktree*" t))
         (default-directory (file-name-as-directory dir))
         (process-environment (append drgnx-job-worktree--env process-environment))
         (timer nil)
         (p (condition-case e
                (make-process
                 :name "drgnx-worktree" :buffer out :noquery t :connection-type 'pipe :command argv
                 :sentinel (lambda (p _event)
                             (unless (process-live-p p)
                               (when timer (cancel-timer timer))
                               (let ((text (string-trim (with-current-buffer out (buffer-string)))))
                                 (kill-buffer out)
                                 (unless (process-get p :stopped)
                                   (with-demoted-errors "drgnx worktree: %S"
                                     (funcall done (cons (if (process-get p :timed-out) :timeout (process-exit-status p))
                                                         text))))))))
              (error (kill-buffer out) (signal (car e) (cdr e))))))
    (when job (process-put p :job job))
    (setq timer (run-at-time drgnx-job-worktree-timeout nil
                             (lambda () (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))))
    (ignore-errors (process-send-eof p))
    p))

(defun drgnx-job-worktree-prepare (repo id n)
  "Make the task's two ref directories in REPO's `.git' where they are missing, so that they can be bound:
`refs/heads/job/ID-N/' (`git pack-refs', which `git gc' runs, removes it with the loose ref) and
`logs/refs/heads/job/ID-N/' (missing where reflogs are off).  Call it before each start of the task's agent.
Signals an error when one cannot be made (a ref job/ID-N in the way)."
  (drgnx-job-worktree--check-task id n)
  (let ((git (or (drgnx-job-worktree--common-dir repo) (error "%s is not a git repository" repo))))
    (dolist (dir '("refs/heads/job/" "logs/refs/heads/job/"))
      (make-directory (format "%s/%s%s-%d" git dir id n) t))))

(defun drgnx-job-worktree--made (repo folder id n)
  "After `git worktree add': FOLDER's worktree NAME, its empty `config.worktree' made (a file git copied there from
the user's own is kept) and the task's ref directories there (`drgnx-job-worktree-prepare'), so each can be bound.
\(:name NAME) or (:error MSG)."
  (let* ((common (drgnx-job-worktree--common-dir repo))
         (name (drgnx-job-worktree-name repo folder)))
    (if (not name)
        (list :error (format "%s is not a worktree of %s" folder repo))
      (let ((cw (format "%s/worktrees/%s/config.worktree" common name)))
        (unless (file-exists-p cw)
          (let ((coding-system-for-write 'utf-8-unix)) (write-region "" nil cw nil 'silent nil 'excl))))
      (drgnx-job-worktree-prepare repo id n)
      (list :name name))))

(defun drgnx-job-worktree-add (repo folder id n base done &optional job)
  "Make FOLDER (missing) a linked worktree of REPO for task N of job ID: `git worktree add -q -b job/ID-N/work FOLDER
BASE' (BASE a branch of REPO), then an empty `worktrees/NAME/config.worktree', so that it can be pinned.
Asynchronous: DONE is called later with (:name NAME), the worktree's name for `drgnx-job-worktree-binds', or (:error
MSG) — a reftable repository (`drgnx-job-worktree-refusal'), a bad id or base, FOLDER there already, git's failure.
JOB: stopping it ends git, and DONE is not called.  Git runs in REPO with no hooks and no fsmonitor."
  (let* ((folder (directory-file-name (expand-file-name folder)))
         (later (lambda (result) (run-at-time 0 nil done result)))
         (why (cond ((not (drgnx-job-worktree--base-ok-p base)) (format "not a branch name: %S" base))
                    ((condition-case e (progn (drgnx-job-worktree--check-task id n) nil)
                       (error (error-message-string e))))
                    ((not (drgnx-job-worktree--common-dir repo)) (format "%s is not a git repository" repo))
                    ((drgnx-job-worktree-refusal repo))
                    ((file-exists-p folder) (format "%s exists already" folder)))))
    (if why
        (funcall later (list :error why))
      (condition-case e
          (drgnx-job-worktree--run
           repo (append '("git") drgnx-job-worktree--overrides
                        (list "worktree" "add" "-q" "-b" (drgnx-job-worktree-branch id n) folder
                              (concat "refs/heads/" base)))
           job
           (lambda (r)
             (funcall done
                      (cond ((eql 0 (car r))
                             (condition-case e (drgnx-job-worktree--made repo folder id n)
                               (error (list :error (error-message-string e)))))
                            ((eq (car r) :timeout)
                             (list :error (format "git worktree add did not finish in %s s" drgnx-job-worktree-timeout)))
                            (t (list :error (if (string-empty-p (cdr r)) (format "exit %s" (car r)) (cdr r))))))))
        (error (funcall later (list :error (error-message-string e))))))))

;;;; The binds

(defun drgnx-job-worktree-binds (repo folder name id n &optional read-only)
  "The `:binds' of the sandbox spec for task N of job ID in its worktree FOLDER of REPO, named NAME in REPO's `.git'
\(`drgnx-job-worktree-add' gives it), in the order bubblewrap must apply them — a pin after the writable directory it
sits in:
  (ro GIT)                                  config, hooks/, info/, packed-refs, other refs and worktrees: read-only
  (rw GIT/objects)                          new objects (commits need it)
  (rw GIT/refs/heads/job/ID-N)              its own branch job/ID-N/work, and nothing else among the refs
  (rw GIT/logs/refs/heads/job/ID-N)         that branch's reflog
  (rw GIT/worktrees/NAME)                   its HEAD, index, logs/HEAD
  (ro GIT/worktrees/NAME/commondir)         pinned: where its repository is
  (ro GIT/worktrees/NAME/gitdir)            pinned
  (ro GIT/worktrees/NAME/config.worktree)   pinned
  (rw FOLDER)                               the working tree
  (ro FOLDER/.git)                          pinned: the `gitdir:' pointer
GIT is REPO's common git directory.  Each bind is (MODE OUTSIDE INSIDE), both the same true name.  READ-ONLY (the
reviewer): every one read-only.  Signals an error on an id, number or name that is not one, or when REPO is no
repository.  Data only: nothing is made or checked on disk."
  (drgnx-job-worktree--check-task id n)
  (unless (and (stringp name) (not (member name '("" "." ".."))) (not (string-match-p "[/\0\n]" name)))
    (error "Not a worktree name: %S" name))
  (let* ((git (or (drgnx-job-worktree--common-dir repo) (error "%s is not a git repository" repo)))
         (folder (drgnx-job-worktree--true folder))
         (wt (concat git "/worktrees/" name))
         (task (format "%s-%d" id n))
         (rw (if read-only 'ro 'rw)))
    (mapcar (lambda (b) (list (car b) (cdr b) (cdr b)))
            `((ro . ,git)
              (,rw . ,(concat git "/objects"))
              (,rw . ,(concat git "/refs/heads/job/" task))
              (,rw . ,(concat git "/logs/refs/heads/job/" task))
              (,rw . ,wt)
              (ro . ,(concat wt "/commondir"))
              (ro . ,(concat wt "/gitdir"))
              (ro . ,(concat wt "/config.worktree"))
              (,rw . ,folder)
              (ro . ,(concat folder "/.git"))))))

;;;; After each turn

(defun drgnx-job-worktree-tip (repo id n)
  "The commit task N of job ID's branch is at, 40 or 64 hex digits, or nil.  The loose ref file is the agent's: it
counts only as a regular file, not a link, holding an object name (a symbolic ref is nil).  Without one, the line of
`packed-refs', which only the user's git writes."
  (drgnx-job-worktree--check-task id n)
  (when-let* ((git (drgnx-job-worktree--common-dir repo)))
    (let* ((ref (concat "refs/heads/" (drgnx-job-worktree-branch id n)))
           (loose (expand-file-name ref git))
           (sha (if (file-attributes loose)
                    (drgnx-job-worktree--line loose)
                  (ignore-errors
                    (with-temp-buffer
                      (insert-file-contents (expand-file-name "packed-refs" git))
                      (and (re-search-forward (concat "^\\([0-9a-f]+\\) " (regexp-quote ref) "$") nil t)
                           (match-string 1)))))))
      (and sha (string-match-p "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'" sha) sha))))

(defun drgnx-job-worktree-check (repo id n base)
  "Non-nil (t) when task N of job ID's branch still descends from BASE (a branch): `git merge-base --is-ancestor' on
its commit (`drgnx-job-worktree-tip'), run in the main repository REPO, whose config the agent cannot write.
Synchronous: one short git.  A guard against a rewound or replaced branch, not against a hostile agent: the objects
it reads are writable in worktree mode."
  (when-let* (((drgnx-job-worktree--base-ok-p base))
              (tip (drgnx-job-worktree-tip repo id n)))
    (let ((default-directory (file-name-as-directory repo))
          (process-environment (append drgnx-job-worktree--env process-environment)))
      (eql 0 (ignore-errors (apply #'call-process "git" nil nil nil
                                   (append drgnx-job-worktree--overrides
                                           (list "merge-base" "--is-ancestor" (concat "refs/heads/" base) tip))))))))

(provide 'drgnx-job-worktree)
;;; drgnx-job-worktree.el ends here
