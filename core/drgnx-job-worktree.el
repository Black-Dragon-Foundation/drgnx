;;; drgnx-job-worktree.el --- Jobs: worktree mode — a task's linked worktree, and the least of .git it may write -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Worktree mode is opt-in; snapshot mode (drgnx-job-snapshot.el) is the default.  A task gets a classic linked
;; worktree, `git worktree add -b job/ID-N/work FOLDER BASE', that shares the repository's `.git'.  Its sandbox mounts
;; that `.git' read-only but for what one worktree's commits must write: `objects/', the task's own ref directory
;; `refs/heads/job/ID-N/' and its reflog, and the worktree's own directory `worktrees/NAME/'.  The pointers that tell
;; git where the repository is — `FOLDER/.git', and `commondir', `gitdir' and `config.worktree' in `worktrees/NAME/'
;; — are pinned read-only on top, so the agent cannot send git to a directory of its own.  `objects/' stays writable:
;; an agent can delete or overwrite the repository's objects.  `worktrees/NAME/' stays writable too, and the user's
;; git trusts what is in it (an operation in progress, links, HEAD): `drgnx-job-worktree-scrub' removes that state.  A
;; reftable repository keeps every ref in one directory and cannot be split this way: it is refused.  This file builds
;; data and runs git only in the main repository.  See docs/develop/sandbox.md ("Git: worktree mode").

;;; Code:
(require 'subr-x)
(require 'drgnx-timer)
(require 'drgnx-guard)
(require 'drgnx-job-snapshot)

(defcustom drgnx-job-worktree-timeout 300
  "Seconds one git of a task's worktree (its `worktree add', a step of its check) may take; then it is ended, and
that is a failure."
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

(defun drgnx-job-worktree--true (path)
  "PATH's true name, without a trailing slash."
  (let ((file-name-handler-alist nil)) (directory-file-name (file-truename (expand-file-name path)))))

(defun drgnx-job-worktree-name (repo folder)
  "The name git gave FOLDER's worktree in REPO — the directory `worktrees/NAME/' of REPO's `.git' — or nil.  Read from
FOLDER's `.git' file, and kept only when that worktree's `gitdir' leads back to it.  The hub reads it right after
`drgnx-job-worktree-add', before any agent: under the sandbox both files are pinned read-only."
  (let* ((file-name-handler-alist nil)
         (common (drgnx-job-snapshot-common-dir repo))
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
  (when-let* ((common (drgnx-job-snapshot-common-dir repo)))
    (when (equal (or (drgnx-job-worktree--show-ref-format repo) (drgnx-job-worktree--ref-storage common))
                 "reftable")
      drgnx-job-worktree--reftable)))

;;;; Making the worktree

(defun drgnx-job-worktree--timed-out (p)
  "The deadline of the git process P (`drgnx-job-worktree--run'): mark it timed out and end it."
  (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))

(defun drgnx-job-worktree--run (dir argv job done)
  "Run ARGV in DIR in a process of its own; DONE gets (EXIT . OUTPUT) once it ended (stderr in OUTPUT).  EXIT is
`:timeout' after `drgnx-job-worktree-timeout' (the timer layer's (job-worktree-timeout . PROCESS), owned by the
process).  Stopping JOB ends it, and DONE is not called."
  (let* ((out (generate-new-buffer " *drgnx-worktree*" t))
         (default-directory (file-name-as-directory dir))
         (process-environment (append drgnx-job-worktree--env process-environment))
         (p (condition-case e
                (make-process
                 :name "drgnx-worktree" :buffer out :noquery t :connection-type 'pipe :command argv
                 :sentinel (drgnx-guard-wrap
                            (lambda (p _event)
                              (unless (process-live-p p)
                                (drgnx-timer-cancel (cons 'job-worktree-timeout p))
                                (let ((text (string-trim (with-current-buffer out (buffer-string)))))
                                  (kill-buffer out)
                                  (unless (process-get p :stopped)
                                    (with-demoted-errors "drgnx worktree: %S"
                                      (funcall done (cons (if (process-get p :timed-out) :timeout (process-exit-status p))
                                                          text)))))))
                            "job worktree"))
              (error (kill-buffer out) (signal (car e) (cdr e))))))
    (when job (process-put p :job job))
    (drgnx-timer-start (cons 'job-worktree-timeout p) drgnx-job-worktree-timeout #'drgnx-job-worktree--timed-out
                       :args (list p) :owner p)
    (ignore-errors (process-send-eof p))
    p))

(defun drgnx-job-worktree--check-name (name)
  "Signal an error unless NAME can be a worktree's directory name: one component, not `.' or `..'."
  (unless (and (stringp name) (not (member name '("" "." ".."))) (not (string-match-p "[/\0\n]" name)))
    (error "Not a worktree name: %S" name)))

(defun drgnx-job-worktree-prepare (repo name id n)
  "Make what the binds of task N of job ID (its worktree NAME) need in REPO's `.git', where it is missing:
- `refs/heads/job/ID-N/' (`git pack-refs', which `git gc' runs, removes it with the loose ref);
- `logs/refs/heads/job/ID-N/' (missing where reflogs are off);
- an empty `worktrees/NAME/config.worktree' (a job stopped after `git worktree add' never made it; one that is there
  is kept).
Call it before each start of the task's agent.  Signals an error when one cannot be made (a ref job/ID-N in the
way)."
  (drgnx-job-worktree--check-task id n)
  (drgnx-job-worktree--check-name name)
  (let ((git (or (drgnx-job-snapshot-common-dir repo) (error "%s is not a git repository" repo)))
        (file-name-handler-alist nil))
    (dolist (dir '("refs/heads/job/" "logs/refs/heads/job/"))
      (make-directory (format "%s/%s%s-%d" git dir id n) t))
    (let ((cw (format "%s/worktrees/%s/config.worktree" git name)))
      (unless (file-attributes cw)            ; O_EXCL: a link is never followed
        (let ((coding-system-for-write 'utf-8-unix)) (write-region "" nil cw nil 'silent nil 'excl))))))

(defun drgnx-job-worktree--made (repo folder id n)
  "After `git worktree add': FOLDER's worktree NAME, and what its binds need made (`drgnx-job-worktree-prepare').
\(:name NAME) or (:error MSG)."
  (let ((name (drgnx-job-worktree-name repo folder)))
    (if (not name)
        (list :error (format "%s is not a worktree of %s" folder repo))
      (drgnx-job-worktree-prepare repo name id n)
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
                    ((not (drgnx-job-snapshot-common-dir repo)) (format "%s is not a git repository" repo))
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
  (drgnx-job-worktree--check-name name)
  (let* ((git (or (drgnx-job-snapshot-common-dir repo) (error "%s is not a git repository" repo)))
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

(defconst drgnx-job-worktree--kept
  '("HEAD" "index" "ORIG_HEAD" "COMMIT_EDITMSG" "commondir" "gitdir" "config.worktree")
  "What the scrub keeps in a task's `worktrees/NAME/', each only as a regular file: its HEAD (checked), index and
ORIG_HEAD, the three pins, and COMMIT_EDITMSG, which each commit writes (a link there is what is dangerous).  Besides
these, `logs/HEAD' (a regular file) and `refs/' (an empty directory, as `git worktree add' makes it).")

(define-error 'drgnx-job-worktree-scrub-failed "A task's worktree could not be scrubbed")

(defun drgnx-job-worktree--kind (file)
  "FILE's type, from lstat (a link is never followed): ?- a regular file, ?d a directory, ?l a link, another
character for a FIFO, socket or device; nil when there is nothing."
  (let ((a (file-attributes file))) (and a (aref (file-attribute-modes a) 0))))

(defun drgnx-job-worktree--device (file)
  "The device FILE is on, from lstat, or nil."
  (let ((a (file-attributes file))) (and a (file-attribute-device-number a))))

(defun drgnx-job-worktree-scrub (repo name id n)
  "Remove the git state task N of job ID left in its worktree NAME of REPO that the user's git would trust; the
relative names (to REPO's `.git') it removed or rewrote, or nil.  `worktrees/NAME/' is writable to the agent, so it
can leave an operation in progress there (a rebase whose todo `exec's as the user, a `head-name' of `main'), links in
place of files git writes by opening them (`COMMIT_EDITMSG' → the main config), or a HEAD naming another branch.
- In `worktrees/NAME/': only `drgnx-job-worktree--kept' stays, `logs/HEAD' and an empty `refs/'.  HEAD must be
  `ref: refs/heads/job/ID-N/work' or an object name; otherwise it is rewritten to the first.
- In `refs/heads/job/ID-N/' and `logs/refs/heads/job/ID-N/': only `work', a regular file.
It runs no git and follows no link: types come from lstat, and what goes is renamed — a link itself — into a
directory the agent cannot write (`.drgnx-scrub-*' in REPO's `.git'), which `rm -rf' (it never follows a link) then
removes in a process of its own, even when the scrub fails.  HEAD is read only once moved there and only when it
is a regular file: a FIFO in its place never blocks the hub.  An entry on another device than the trash (a btrfs
subvolume the agent made) is never renamed — `rename-file' would copy it, opening its files — and is left: after the
rest is done, the scrub signals `drgnx-job-worktree-scrub-failed' with (MESSAGE FAILED REMOVED), the names left and
those removed.  Called while the agent's sandbox lives, the agent can plant again after it; called after the sandbox
has exited, it leaves the state clean."
  (drgnx-job-worktree--check-task id n)
  (drgnx-job-worktree--check-name name)
  (let* ((file-name-handler-alist nil)
         (git (or (drgnx-job-snapshot-common-dir repo) (error "%s is not a git repository" repo)))
         (wt (format "worktrees/%s/" name))
         (head (concat "ref: refs/heads/" (drgnx-job-worktree-branch id n)))
         (trash nil) (count 0) (out nil) (failed nil)
         (kind (lambda (rel) (drgnx-job-worktree--kind (concat git "/" rel))))
         (entries (lambda (rel) (ignore-errors (directory-files (concat git "/" rel) nil
                                                                directory-files-no-dot-files-regexp t))))
         ;; PATH and its directory on the trash's device: a rename stays a rename (across devices, `rename-file'
         ;; would copy and delete, opening what it copies)
         (same-dev (lambda (path)
                     (let ((d (drgnx-job-worktree--device trash)))
                       (and d (equal (drgnx-job-worktree--device path) d)
                            (equal (drgnx-job-worktree--device (file-name-directory (directory-file-name path))) d)))))
         ;; REL renamed into the trash (never followed): its place there; nil, REL failed, when on another device
         (move (lambda (rel)
                 (unless trash (setq trash (make-temp-file (concat git "/.drgnx-scrub-") t)))
                 (let ((from (concat git "/" rel)))
                   (if (not (funcall same-dev from))
                       (progn (push rel failed) nil)
                     (let ((to (format "%s/%d" trash (setq count (1+ count)))))
                       (rename-file from to)
                       to)))))
         (drop (lambda (rel) (when (funcall move rel) (push rel out)))))
    (unwind-protect
        (progn
          (when (eq (funcall kind wt) ?d)
            (dolist (e (funcall entries wt))
              (let ((rel (concat wt e)))
                (cond ((equal e "HEAD"))
                      ((member e drgnx-job-worktree--kept) (unless (eq (funcall kind rel) ?-) (funcall drop rel)))
                      ((and (equal e "refs") (eq (funcall kind rel) ?d) (null (funcall entries rel))))
                      ((and (equal e "logs") (eq (funcall kind rel) ?d))
                       ;; never descend where the agent writes: the whole of logs/ goes, logs/HEAD comes back if regular
                       (when-let* ((moved (funcall move rel)))
                         (make-directory (concat git "/" rel))
                         (if (not (eq (drgnx-job-worktree--kind moved) ?d))
                             (push rel out)
                           (dolist (l (directory-files moved nil directory-files-no-dot-files-regexp t))
                             (let ((path (concat moved "/" l)) (r (concat rel "/" l)))
                               (cond ((not (funcall same-dev path)) (push r failed))
                                     ((and (equal l "HEAD") (eq (drgnx-job-worktree--kind path) ?-))
                                      (rename-file path (concat git "/" r)))
                                     (t (push r out))))))))
                      (t (funcall drop rel)))))
            ;; HEAD: moved out first, read there, written anew (O_EXCL: never through a link)
            (let* ((rel (concat wt "HEAD"))
                   (present (funcall kind rel))
                   (moved (and present (funcall move rel))))
              (unless (and present (not moved))         ; on another device: failed, left as it is
                (let* ((text (and moved (eq (drgnx-job-worktree--kind moved) ?-)
                                  (with-temp-buffer (insert-file-contents moved nil 0 256)
                                                    (string-trim (buffer-substring (point-min) (line-end-position))))))
                       (ok (and text (or (equal text head)
                                         (string-match-p "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'" text)))))
                  (unless ok (push rel out))
                  (let ((coding-system-for-write 'utf-8-unix))
                    (write-region (concat (if ok text head) "\n") nil (concat git "/" rel) nil 'silent nil 'excl))))))
          (dolist (dir (list (format "refs/heads/job/%s-%d/" id n) (format "logs/refs/heads/job/%s-%d/" id n)))
            (when (eq (funcall kind dir) ?d)
              (dolist (e (funcall entries dir))
                (unless (and (equal e "work") (eq (funcall kind (concat dir e)) ?-))
                  (funcall drop (concat dir e))))))
          (when failed
            (setq failed (sort failed #'string<))
            (signal 'drgnx-job-worktree-scrub-failed
                    (list (format "on another device, so not removed: %s" (string-join failed ", ")) failed
                          (nreverse out))))
          (nreverse out))
      ;; always: the trash never stays in the user's .git (but where rm cannot start)
      (when trash
        (condition-case nil (drgnx-job-worktree--run git (list "rm" "-rf" "--" trash) nil #'ignore)
          (error nil))))))

(defun drgnx-job-worktree-check (repo id n base done &optional job)
  "Does task N of job ID's branch still descend from BASE?  BASE is the task's start, the commit its worktree was
made at (40 or 64 hex digits, recorded by the hub), or a branch, whose tip moves as other tasks merge: check a
running task against its start.  Asynchronous: DONE is called with two arguments, RESULT and TIP:
  t, TIP     it does; TIP is the commit checked (40 or 64 hex digits): merge TIP, never the branch's name;
  nil, nil   it does not: rewound, replaced, a symbolic ref or a link, not an object name, or no branch;
  (:error MSG), nil   git failed or took longer than `drgnx-job-worktree-timeout': a failure, never a pass.
Two gits in the main repository REPO, whose config the agent cannot write, each with the deadline: `for-each-ref'
reads the branch (its `%(symref)' must be empty), then `merge-base --is-ancestor'.  The ref file and the objects are
the agent's: a FIFO planted among them blocks git, never the hub.  A guard against a rewound or replaced branch, not
against a hostile agent: in worktree mode the objects it reads are writable.  JOB: stopping it ends the gits, and DONE
is not called."
  (let* ((later (lambda (r) (run-at-time 0 nil done r nil)))
         (ref (and (drgnx-job-worktree--base-ok-p base)
                   (ignore-errors (concat "refs/heads/" (drgnx-job-worktree-branch id n)))))
         (git (and ref (drgnx-job-snapshot-common-dir repo)))
         (git-argv (lambda (&rest args) (append '("git") drgnx-job-worktree--overrides args)))
         (fail (lambda (r what)
                 (list :error (if (eq (car r) :timeout)
                                  (format "%s did not finish in %s s" what drgnx-job-worktree-timeout)
                                (format "%s: %s" what (if (string-empty-p (cdr r)) (format "exit %s" (car r)) (cdr r))))))))
    (cond
     ((not ref) (funcall later (list :error (format "not a branch name or task: %S %S %S" base id n))))
     ((not git) (funcall later (list :error (format "%s is not a git repository" repo))))
     ;; lstat only: a link in the agent's ref directory is no branch (git would follow it)
     ((eq (drgnx-job-worktree--kind (concat git "/" ref)) ?l) (funcall later nil))
     (t
      (condition-case e
          (drgnx-job-worktree--run
           repo (funcall git-argv "for-each-ref" "--format=%(objectname) %(symref)" ref) job
           (lambda (r)
             (cond
              ((not (eql 0 (car r))) (funcall done (funcall fail r "git for-each-ref") nil))
              ((not (string-match-p "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'" (cdr r))) (funcall done nil nil))
              (t
               (let ((tip (cdr r)))
                 (condition-case e
                     (drgnx-job-worktree--run
                      repo (funcall git-argv "merge-base" "--is-ancestor" (drgnx-job-snapshot--rev base) tip) job
                      (lambda (m)
                        (pcase (car m)
                          (0 (funcall done t tip))
                          (1 (funcall done nil nil))
                          (_ (funcall done (funcall fail m "git merge-base") nil)))))
                   (error (funcall done (list :error (error-message-string e)) nil))))))))
        (error (funcall later (list :error (error-message-string e)))))))))

(provide 'drgnx-job-worktree)
;;; drgnx-job-worktree.el ends here
