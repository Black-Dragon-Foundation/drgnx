;;; drgnx-job-snapshot.el --- Jobs: a task's snapshot — a copy of the job's clean store, made while trusted -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; In snapshot mode each task of a job gets a `.git' of its own in its folder `<repo>/.claude/worktrees/ID-N/'.  It
;; is never a copy of the user's `.git': that holds what the agent must not see (unreachable objects from staged then
;; unstaged files, dropped stashes, amended commits; other branches; reflogs; the index; config with tokens).
;;
;; Instead, each job has a clean store, `<repo>/.claude/worktrees/<BASE>.base.git' (BASE's `/' as `~'): a bare
;; clone of BASE alone (`clone --no-local --bare --single-branch --no-tags', so only objects reachable from BASE come
;; through git's own pack transfer) whose config the hub writes from a whitelist.  It is hub-only: no agent mounts
;; it writable, and nothing of the agent's ever reaches it.  When BASE moves (a task merged), BASE is fetched into it.
;; Each task then gets a copy-on-write copy of the store (reflink, clonefile) or, without copy-on-write, a shared
;; clone that borrows from the store alone.  Nothing is checked out: the sandbox does it.
;;
;; Every step is an asynchronous process with a deadline: the hub never waits.  Every git here runs with no hooks
;; and no fsmonitor, no templates and only the file protocol.  After DONE is called, nothing outside the sandbox runs
;; git in the folder again: its `.git' is the agent's.  See docs/develop/sandbox.md ("Git: snapshot mode").

;;; Code:
(require 'subr-x)
(require 'drgnx-timer)

(defcustom drgnx-job-snapshot-timeout 300
  "Seconds one step of a task's snapshot (the store's clone or fetch, the copy, the clone) may take; then it fails."
  :type 'number :group 'drgnx)

(defvar drgnx-job-snapshot-copy-on-write 'auto
  "Non-nil: a task's snapshot is a copy-on-write copy of its job's store where the repository's filesystem has it
(`drgnx-job-snapshot-cow-p'), else a shared clone of the store.  nil: always the shared clone.")

(defvar drgnx-job-snapshot--cow (make-hash-table :test #'equal)
  "Filesystem (the device number of a repository's .claude/worktrees/) → `yes' or `no', its copy-on-write probe's
answer.  Bounded by the filesystems mounted; never evicted.")

(defvar drgnx-job-snapshot--busy (make-hash-table :test #'equal)
  "Store directory → (t . WAITING): its steps run one at a time (a fetch into it while a copy reads it would give the
copy a ref without its objects); WAITING are the functions queued.  An entry lives only while its store is in use.")

(defconst drgnx-job-snapshot--overrides '("-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false")
  "Given to every git the hub runs here: no hook and no fsmonitor program runs in the hub.")

(defconst drgnx-job-snapshot--env
  '("GIT_TERMINAL_PROMPT=0" "GIT_ALLOW_PROTOCOL=file" "GIT_DIR" "GIT_WORK_TREE" "GIT_INDEX_FILE" "GIT_COMMON_DIR"
    "GIT_OBJECT_DIRECTORY" "GIT_ALTERNATE_OBJECT_DIRECTORIES")
  "Prepended to `process-environment' for the steps: never a prompt, only the file protocol, and no variable sends
git to another repository.")

(defconst drgnx-job-snapshot--from-clone
  "\\`\\(?:core\\.\\(?:repositoryformatversion\\|filemode\\|ignorecase\\|symlinks\\|precomposeunicode\\)\\|extensions\\.[^.]+\\)\\'"
  "Config names kept from the store's own fresh clone: what git needs to read the repository.")

(defconst drgnx-job-snapshot--from-user
  "\\`\\(?:core\\.\\(?:hookspath\\|autocrlf\\|eol\\|safecrlf\\)\\|filter\\.lfs\\.\\(?:clean\\|smudge\\|process\\|required\\)\\)\\'"
  "Config names carried from the user's repository: line endings, the project's own (relative) hooks path, Git LFS's
filter.  Nothing else of the user's config reaches a task.")

;;;; Where things are

(defun drgnx-job-snapshot-common-dir (repo)
  "REPO's common git directory (what `git rev-parse --git-common-dir' prints), absolute and resolved, or nil.  REPO
is the top level of a checkout.  A `.git' file (a linked worktree, a submodule) is followed to its git directory and
its `commondir'.  Read from the files, as git itself does: no process."
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

(defun drgnx-job-snapshot-store-dir (repo base)
  "The clean store of REPO's job whose base branch is BASE: `<repo>/.claude/worktrees/<BASE, / as ~>.base.git/'
\(`~' is never in a branch name, so two bases never share one)."
  (file-name-as-directory
   (expand-file-name (concat ".claude/worktrees/" (string-replace "/" "~" base) ".base.git") (file-truename repo))))

(defun drgnx-job-snapshot-read-dirs (repo base)
  "The directories a task of REPO at BASE may have mounted read-only for its objects: its job's store's objects.
Derived from REPO and BASE, never from a task folder: check the `:read' a task keeps against it."
  (list (directory-file-name (expand-file-name "objects" (drgnx-job-snapshot-store-dir repo base)))))

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

(defun drgnx-job-snapshot--alternates (folder)
  "The object directories FOLDER's repository borrows from.  Only for tests: once an agent has had FOLDER, its
alternates file is the agent's, so the hub never derives anything from it (`drgnx-job-snapshot-read-dirs')."
  (drgnx-job-snapshot--alternates-of (expand-file-name ".git/objects" folder)))

;;;; The config: a whitelist the hub writes

(defun drgnx-job-snapshot--entries (text)
  "Config entries ((NAME . VALUE) …) from TEXT, the stdout of `git config --list --null'."
  (mapcar (lambda (rec)
            (let ((nl (string-search "\n" rec)))
              (if nl (cons (substring rec 0 nl) (substring rec (1+ nl))) (cons rec nil))))
          (split-string text "\0" t)))

(defun drgnx-job-snapshot--carried-p (entry)
  "Is the user's config ENTRY carried: whitelisted, its value no URL with credentials, a hooks path inside the checkout?"
  (let ((name (car entry)) (value (or (cdr entry) "")))
    (and (string-match-p drgnx-job-snapshot--from-user name)
         (not (string-match-p "://[^/@[:space:]]*@" value))
         (or (not (equal name "core.hookspath"))
             (not (or (string-empty-p value) (file-name-absolute-p value) (member ".." (split-string value "[/\\]"))))))))

(defun drgnx-job-snapshot--quote (s)
  (replace-regexp-in-string "[\\\"\n\t]" (lambda (c) (pcase c ("\\" "\\\\") ("\"" "\\\"") ("\n" "\\n") (_ "\\t"))) s t t))

(defun drgnx-job-snapshot--config-text (clone user bare)
  "A config file's text: the entries of CLONE (a fresh clone's config) `drgnx-job-snapshot--from-clone' keeps,
`core.bare' BARE, the entries of USER (the user's config) `drgnx-job-snapshot--carried-p' accepts, `gc.auto' 0 (a
repack would un-share copied blocks, or drop objects a clone borrows)."
  (let ((entries (append (seq-filter (lambda (e) (string-match-p drgnx-job-snapshot--from-clone (car e))) clone)
                         (list (cons "core.bare" (if bare "true" "false")))
                         (seq-filter #'drgnx-job-snapshot--carried-p user)
                         (list (cons "gc.auto" "0"))))
        sections)
    (dolist (e entries)
      (let* ((name (car e)) (first (string-search "." name)) (last (string-match "\\.[^.]*\\'" name))
             (head (cons (substring name 0 first) (and (< first last) (substring name (1+ first) last))))
             (line (cons (substring name (1+ last)) (or (cdr e) "true")))
             (cell (assoc head sections)))
        (if cell (setcdr cell (append (cdr cell) (list line))) (setq sections (append sections (list (list head line)))))))
    (mapconcat (lambda (s)
                 (concat (if (cdar s) (format "[%s \"%s\"]\n" (caar s) (drgnx-job-snapshot--quote (cdar s))) (format "[%s]\n" (caar s)))
                         (mapconcat (lambda (kv) (format "\t%s = \"%s\"\n" (car kv) (drgnx-job-snapshot--quote (cdr kv)))) (cdr s) "")))
               sections "")))

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

(defun drgnx-job-snapshot--timed-out (p)
  "The deadline of the step process P (`drgnx-job-snapshot--run'): mark it timed out and end it."
  (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))

(defun drgnx-job-snapshot--run (dir argv job done)
  "Run ARGV in DIR in a process of its own; DONE gets (EXIT STDOUT . STDERR) once it ended.  EXIT is its status,
`:timeout' after `drgnx-job-snapshot-timeout', or `:stopped' when stopping JOB ended it.  When the process cannot
start, this signals, and leaves no process or buffer behind."
  (let* ((out (generate-new-buffer " *drgnx-snapshot*" t))
         (err (generate-new-buffer " *drgnx-snapshot-err*" t))
         (default-directory (file-name-as-directory dir))
         (process-environment (append drgnx-job-snapshot--env process-environment))
         (errp nil)
         (p nil))
    (condition-case e
        (setq errp (make-pipe-process :name "drgnx-snapshot-err" :buffer err :noquery t :sentinel #'ignore)
              p (make-process
                 :name "drgnx-snapshot" :buffer out :stderr errp :noquery t :connection-type 'pipe :command argv
                 :sentinel (lambda (p _event)
                             (unless (process-live-p p)
                               (drgnx-timer-cancel (cons 'job-snapshot-timeout p))
                               ;; what is still in the stderr pipe: read without waiting, so no message is cut short
                               (while (and (process-live-p errp) (accept-process-output errp 0 nil 1)))   ; 1: no timers run here
                               (let ((stdout (with-current-buffer out (buffer-string)))
                                     (stderr (string-trim (with-current-buffer err (buffer-string)))))
                                 (delete-process errp)
                                 (kill-buffer out)
                                 (kill-buffer err)
                                 (with-demoted-errors "drgnx snapshot: %S"
                                   (funcall done (cons (cond ((process-get p :stopped) :stopped)
                                                             ((process-get p :timed-out) :timeout)
                                                             (t (process-exit-status p)))
                                                       (cons stdout stderr)))))))))
      (error (when errp (delete-process errp))
             (kill-buffer out)
             (kill-buffer err)
             (signal (car e) (cdr e))))
    (when job (process-put p :job job))
    (drgnx-timer-start (cons 'job-snapshot-timeout p) drgnx-job-snapshot-timeout #'drgnx-job-snapshot--timed-out
                       :args (list p) :owner p)
    (ignore-errors (process-send-eof p))
    p))

(defun drgnx-job-snapshot--git (argv &optional git-dir)
  "The command line of git ARGV run by the hub: with `drgnx-job-snapshot--overrides', and on GIT-DIR named
explicitly (a bare store is never found by discovery: `safe.bareRepository=explicit' refuses that)."
  (append '("git") (and git-dir (list (concat "--git-dir=" git-dir))) drgnx-job-snapshot--overrides argv))

(defun drgnx-job-snapshot--then (fail ok)
  "A DONE for `drgnx-job-snapshot--run': exit 0 calls OK with STDOUT; anything else FAIL with `:stopped' or why.
An error OK signals goes to FAIL too: a sentinel would swallow it, and the steps after would never run."
  (lambda (r)
    (cond ((eq (car r) :stopped) (funcall fail :stopped))
          ((eql 0 (car r)) (condition-case e (funcall ok (cadr r)) (error (funcall fail (error-message-string e)))))
          ((eq (car r) :timeout) (funcall fail (format "timed out after %s s" drgnx-job-snapshot-timeout)))
          (t (funcall fail (let ((e (cddr r))) (if (string-empty-p e) (format "exit %s" (car r)) e)))))))

(defun drgnx-job-snapshot--rm (dir job then)
  "Remove DIR (`rm -rf', in a process), then call THEN — also when `rm' cannot start (DIR then stays): a failure path
always completes."
  (condition-case nil
      (drgnx-job-snapshot--run (file-name-directory (directory-file-name dir)) (list "rm" "-rf" "--" (directory-file-name dir)) job
                               (lambda (_) (funcall then)))
    (error (funcall then))))

(defun drgnx-job-snapshot--with-store (store fn)
  "Call FN with a function that ends its turn, once no other step uses STORE: one at a time, in order."
  (let ((turn (lambda () (funcall fn (lambda () (drgnx-job-snapshot--next store))))))
    (if (gethash store drgnx-job-snapshot--busy)
        (puthash store (append (gethash store drgnx-job-snapshot--busy) (list turn)) drgnx-job-snapshot--busy)
      (puthash store (list t) drgnx-job-snapshot--busy)
      (funcall turn))))

(defun drgnx-job-snapshot--next (store)
  (let ((waiting (cdr (gethash store drgnx-job-snapshot--busy))))
    (if (null waiting)
        (remhash store drgnx-job-snapshot--busy)
      (puthash store (cons t (cdr waiting)) drgnx-job-snapshot--busy)
      (funcall (car waiting)))))

;;;; The job's store

(defun drgnx-job-snapshot--refresh-store (repo base store job done)
  "Make STORE, the clean store of REPO at BASE, or fetch BASE into it when it is there.  A store is built as
STORE.part and renamed to STORE only once its config is written: a half-made one (a stopped job, a crash) is never
taken, and its leftover is removed before the next build.  DONE gets nil, `:stopped', or why it failed."
  (let* ((store (directory-file-name store))
         (part (concat store ".part"))
         (parent (file-name-directory store))
         (source (directory-file-name (file-truename repo)))
         (common (drgnx-job-snapshot-common-dir repo)))
    (if (file-directory-p store)
        (drgnx-job-snapshot--run
         parent (drgnx-job-snapshot--git (list "fetch" "-q" "--no-tags" "--no-write-fetch-head" source
                                               (format "+refs/heads/%s:refs/heads/%s" base base))
                                         store)
         job (drgnx-job-snapshot--then done (lambda (_) (funcall done nil))))
      (let ((fail (lambda (why) (drgnx-job-snapshot--rm part job (lambda () (funcall done why))))))
        (make-directory parent t)
        (drgnx-job-snapshot--rm
         part job
         (lambda ()
           (drgnx-job-snapshot--run
            parent
            (drgnx-job-snapshot--git (list "clone" "-q" "--no-local" "--bare" "--single-branch" "--no-tags" "--template="
                                           "--branch" base "--" source part))
            job
            (drgnx-job-snapshot--then
             fail
             (lambda (_)
               (drgnx-job-snapshot--run
                parent (drgnx-job-snapshot--git (list "config" "--file" (expand-file-name "config" part) "--list" "--null")) job
                (drgnx-job-snapshot--then
                 fail
                 (lambda (clone)
                   (drgnx-job-snapshot--run
                    parent (drgnx-job-snapshot--git (list "config" "--file" (expand-file-name "config" common) "--no-includes" "--list" "--null"))
                    job
                    (drgnx-job-snapshot--then
                     fail
                     (lambda (user)
                       (write-region (drgnx-job-snapshot--config-text (drgnx-job-snapshot--entries clone)
                                                                      (drgnx-job-snapshot--entries user) t)
                                     nil (expand-file-name "config" part) nil 'silent)
                       (rename-file part store)
                       (funcall done nil))))))))))))))))

;;;; The task's copy

(defun drgnx-job-snapshot--task-copy (store folder base cow job done)
  "Give FOLDER a `.git' from STORE: a copy-on-write copy (COW), else a shared clone borrowing from STORE alone; its
config the store's whitelist, not bare; BASE checked.  DONE gets the result plist, `:stopped', or (:error MSG)."
  (let* ((git (expand-file-name ".git" folder))
         (store (directory-file-name store))
         (fail (lambda (why)
                 (drgnx-job-snapshot--rm folder job (lambda () (funcall done (if (eq why :stopped) :stopped (list :error why))))))))
    (condition-case e
        (progn
          (make-directory (if cow folder (file-name-directory (directory-file-name folder))) t)
          (drgnx-job-snapshot--run
           (file-name-directory store)
           (if cow
               (drgnx-job-snapshot--copy-argv store git)
             (drgnx-job-snapshot--git (list "clone" "-q" "--shared" "--no-checkout" "--single-branch" "--no-tags" "--template="
                                            "--branch" base "--" store (directory-file-name folder))))
           job
           (drgnx-job-snapshot--then
            fail
            (lambda (_)
              (drgnx-job-snapshot--run
               (file-name-directory store)
               (drgnx-job-snapshot--git (list "config" "--file" (expand-file-name "config" store) "--list" "--null")) job
               (drgnx-job-snapshot--then
                fail
                (lambda (text)
                  (let ((entries (drgnx-job-snapshot--entries text)))
                    ;; the store's config is the hub's own whitelist: both halves pass through it again
                    (write-region (drgnx-job-snapshot--config-text entries entries nil) nil
                                  (expand-file-name "config" git) nil 'silent)
                    (drgnx-job-snapshot--run
                     folder (drgnx-job-snapshot--git (list "cat-file" "-e" (format "refs/heads/%s^{commit}" base))) job
                     (drgnx-job-snapshot--then
                      (lambda (why) (funcall fail (if (eq why :stopped) why (format "the base %s is not in the copy" base))))
                      (lambda (_)
                        (funcall done (list :mode (if cow 'snapshot 'clone)
                                            :read (and (not cow) (list (expand-file-name "objects" store))))))))))))))))
      (error (funcall fail (error-message-string e))))))

;;;; Making a task's snapshot

(defun drgnx-job-snapshot--later (done result)
  "Call DONE with RESULT from a timer: DONE always comes after `drgnx-job-snapshot-make' returned."
  (run-at-time 0 nil done result))

(defun drgnx-job-snapshot--base-ok-p (base)
  (and (stringp base) (< 0 (length base) 256) (not (string-prefix-p "-" base))
       (not (string-match-p "[[:space:][:cntrl:]~^:?*\\[\\\\]\\|\\.\\.\\|//\\|/\\'\\|\\.lock\\'" base))))

(defun drgnx-job-snapshot--choose (repo job done)
  "DONE gets t when REPO's snapshots are copy-on-write copies, nil when shared clones, `:stopped' when JOB was
stopped; the first time on a filesystem it is probed by a process of its own."
  (let ((known (and drgnx-job-snapshot-copy-on-write (gethash (drgnx-job-snapshot--fs repo) drgnx-job-snapshot--cow))))
    (cond ((not drgnx-job-snapshot-copy-on-write) (funcall done nil))
          (known (funcall done (eq known 'yes)))
          (t (let ((files (drgnx-job-snapshot--probe-files repo)))
               (drgnx-job-snapshot--run repo (drgnx-job-snapshot--copy-argv (car files) (cdr files)) job
                                        (lambda (r)
                                          (drgnx-job-snapshot--probe-clean files)
                                          (funcall done (cond ((eq (car r) :stopped) :stopped)
                                                              ((condition-case nil (drgnx-job-snapshot--remember repo (eql 0 (car r)))
                                                                 (error nil))))))))))))

(defun drgnx-job-snapshot-make (repo folder base done &optional job)
  "Give the task folder FOLDER (empty or missing) a `.git' of its own, holding BASE (a branch of REPO) and what it
reaches, nothing else.  Asynchronous: DONE is called later with
  (:mode snapshot :read nil)   a copy-on-write copy of the job's store (`drgnx-job-snapshot-store-dir'),
  (:mode clone :read DIRS)     a shared clone of the store, without copy-on-write; DIRS (the store's objects) must be
                               mounted read-only,
  (:error MSG).
The store is made, or BASE fetched into it, first; a failure there is tried once more (a git of the user's may have
been writing BASE).  Keep the result with the task, and check DIRS against `drgnx-job-snapshot-read-dirs'.  JOB:
stopping it ends the steps, and DONE is not called.  Nothing is checked out: the sandbox does it.  From DONE on, run
no git in FOLDER outside the sandbox."
  (let ((folder (file-name-as-directory (expand-file-name folder))))
    (cond ((not (drgnx-job-snapshot--base-ok-p base))
           (drgnx-job-snapshot--later done (list :error (format "not a branch name: %S" base))))
          ((not (drgnx-job-snapshot-common-dir repo))
           (drgnx-job-snapshot--later done (list :error (format "%s is not a git repository" repo))))
          ((and (file-exists-p folder) (not (and (file-directory-p folder) (directory-empty-p folder))))
           (drgnx-job-snapshot--later done (list :error (format "%s exists and is not empty" folder))))
          (t
           (let ((store (drgnx-job-snapshot-store-dir repo base)))
             (drgnx-job-snapshot--with-store
              store
              (lambda (release)
                (let* ((over nil)
                       ;; once: free the store for the next turn, then DONE from a timer (never before make returned)
                       (finish (lambda (result)
                                 (unless over
                                   (setq over t)
                                   (funcall release)
                                   (unless (eq result :stopped) (drgnx-job-snapshot--later done result)))))
                       ;; FN, but an error it signals ends the turn with (:error MSG) instead of locking the store
                       (guard (lambda (fn)
                                (lambda (&rest args)
                                  (condition-case e (apply fn args)
                                    (error (funcall finish (list :error (error-message-string e))))))))
                       (attempt nil))
                  (setq attempt
                        (lambda (cow tries)
                          (drgnx-job-snapshot--refresh-store
                           repo base store job
                           (funcall guard
                                    (lambda (why)
                                      (cond ((eq why :stopped) (funcall finish :stopped))
                                            ((and why (> tries 1)) (funcall attempt cow (1- tries)))
                                            (why (funcall finish (list :error (format "the store of %s: %s" base why))))
                                            (t (drgnx-job-snapshot--task-copy store folder base cow job finish))))))))
                  (funcall (funcall guard
                                    (lambda ()
                                      (drgnx-job-snapshot--choose
                                       repo job
                                       (funcall guard
                                                (lambda (cow)
                                                  (if (eq cow :stopped)
                                                      (funcall finish :stopped)
                                                    (funcall attempt cow 2))))))))))))))))

;;;; Bounded: what a snapshot takes, and its removal

(defun drgnx-job-snapshot-disk-usage (folder done)
  "What FOLDER (a task folder or a store) takes on disk, asynchronously: DONE gets (:bytes N :exclusive M) — N from
`du', which counts blocks shared with the store in full; M the data not shared with anything (btrfs only, nil
elsewhere) — or (:error MSG)."
  (let* ((dir (directory-file-name (expand-file-name folder)))
         (parent (file-name-directory dir)))
    (drgnx-job-snapshot--run
     parent (list "du" "-sk" dir) nil
     (lambda (r)
       (if (not (and (eql 0 (car r)) (string-match "\\`\\([0-9]+\\)" (cadr r))))
           (funcall done (list :error (cddr r)))
         (let ((bytes (* 1024 (string-to-number (match-string 1 (cadr r))))))
           (if (not (and (eq system-type 'gnu/linux) (executable-find "btrfs")))
               (funcall done (list :bytes bytes :exclusive nil))
             (drgnx-job-snapshot--run
              parent (list "btrfs" "filesystem" "du" "-s" "--raw" dir) nil
              (lambda (b)
                (funcall done (list :bytes bytes
                                    :exclusive (and (eql 0 (car b)) (string-match "^ *[0-9]+ +\\([0-9]+\\) +[0-9]+ +/" (cadr b))
                                                    (string-to-number (match-string 1 (cadr b)))))))))))))))

(defun drgnx-job-snapshot--own-p (dir)
  "Is DIR one of this file's folders: a task folder `.claude/worktrees/ID-N' (or `ID-N-review') with a `.git'
directory, or a store `.claude/worktrees/NAME.base.git'?  Nothing from the repository down may be a link: not
`.claude', not `worktrees', not DIR (the repository's own path is the user's)."
  (and (string-match "\\`\\(.*\\)/\\.claude/worktrees/\\([^/]+\\)\\'" dir)
       (let ((root (match-string 1 dir)) (name (match-string 2 dir)))
         (equal (file-truename dir) (concat (directory-file-name (file-truename root)) "/.claude/worktrees/" name)))
       (let ((name (file-name-nondirectory dir)) (git (expand-file-name ".git" dir)))
         (if (string-suffix-p ".base.git" name)
             (and (file-regular-p (expand-file-name "HEAD" dir)) (file-directory-p (expand-file-name "objects" dir)))
           (and (string-match-p "-[0-9]+\\(?:-review\\)?\\'" name) (file-directory-p git) (not (file-symlink-p git)))))))

(defun drgnx-job-snapshot-remove (folder done &optional job)
  "Remove FOLDER — a task folder with its snapshot, or a job's store once no task borrows from it — asynchronously
\(`rm -rf': links are removed, never followed).  Only this file's own folders (`drgnx-job-snapshot--own-p').  DONE
gets t or (:error MSG)."
  (let ((dir (directory-file-name (expand-file-name folder))))
    (if (not (drgnx-job-snapshot--own-p dir))
        (drgnx-job-snapshot--later done (list :error (format "not a task folder or a job's store: %s" dir)))
      (drgnx-job-snapshot--run (file-name-directory dir) (list "rm" "-rf" "--" dir) job
                               (lambda (r) (funcall done (if (eql 0 (car r)) t (list :error (cddr r)))))))))

(provide 'drgnx-job-snapshot)
;;; drgnx-job-snapshot.el ends here
