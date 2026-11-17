;;; drgnx-work.el --- The work tracker: recording the commits drgnx-started work makes; the CLI -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agent sessions and jobs started on a task (a node id of the tracker: "task:FILE#N", a TODO, a
;; plan) get it as DRGNX_TASK; drgnx notes the git HEAD they start at and records the commits made
;; since — after each agent turn, and once a job ended.  Commit messages stay untouched; the links
;; live in the tracker's database (and, when `drgnx-work-git-notes' is on, in git notes too).
;; `drgnx work record|scan|status' is the command line.  See docs/guide/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-db)
(require 'drgnx-projects)                 ; the board's projects
(require 'drgnx-deny)                     ; the personal-notes deny-list
(require 'drgnx-hub-client)               ; `drgnx-hub-call-sync'

(defvar drgnx-work-git-notes nil
  "Non-nil: every recorded link is also written as a git note (refs/notes/drgnx) on its commit,
so it travels with the repository.  The environment variable DRGNX_WORK_GIT_NOTES=1 does the same
for every Emacs drgnx starts (scans, `drgnx work record'); off by default: notes are shared state.")

(defvar drgnx-work-collect-max 100
  "More new commits than this after one agent turn or job are not its own work (a pull, a merge of
a long branch): nothing is recorded automatically then.")

(defvar drgnx-work-roots nil
  "Directories the tracker scans besides the projects' roots (projects.eld).")

(defvar drgnx-work--tasks nil "Alist agent session → its recording state (`drgnx-work-task-begin').")

(defvar drgnx-work-source-functions nil
  "Abnormal hook: each function gets an agent session and returns (:repo REPO :ref REF) or nil.  When one answers,
the session's own folder is not the place to look (a sandboxed task's `.git' is the agent's: no git of ours runs
there): `turn-end' collects nothing, and the job collects when it wants, with `drgnx-work-collect-now', from REPO
at REF (the user's main repository, trusted).  At the start REF is the commit the task forks from; at collect time,
the ref that holds the task's result.")

;;;; Git, the hub and the counts

(defun drgnx-work--org-p (dir)
  "Non-nil when DIR is inside ~/org with the user's opt-ins ignored (the hard tier, as the code indexer reads it):
no scan root there is read, and no git runs there."
  (drgnx-deny-path-p (directory-file-name (expand-file-name dir)) t))

(defun drgnx-work--git (dir &rest args)
  "git ARGS in DIR: its output (trimmed) or nil.  Nil too in a job's snapshot folder, where the VC guard refuses git
(`drgnx-sandbox-vc'): the tracker reads the main repository (`drgnx-work-source-functions'); and inside ~/org
\(`drgnx-work--org-p'), where git never runs."
  (when (and (not (drgnx-work--org-p dir)) (file-directory-p dir))
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory dir)))
        (condition-case nil
            (when (eql 0 (apply #'call-process "git" nil t nil args)) (string-trim (buffer-string)))
          (drgnx-sandbox-guarded nil))))))

(defun drgnx-work--main-repo (dir)
  "The repository DIR belongs to — its main checkout, never a linked worktree (which may go) — or nil."
  (when-let* ((common (drgnx-work--git dir "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (file-name-as-directory (if (equal (file-name-nondirectory (directory-file-name common)) ".git")
                                (file-name-directory (directory-file-name common))
                              common))))

(defun drgnx-work--log (repo &rest args)
  "The commits `git log ARGS' lists in REPO, newest first: ((SHA DATE SUBJECT)…)."
  (mapcar (lambda (l) (let ((p (split-string l "\t"))) (list (car p) (string-to-number (nth 1 p)) (or (nth 2 p) ""))))
          (split-string (or (apply #'drgnx-work--git repo "log" "--format=%H%x09%ct%x09%s" args) "") "\n" t)))

(defun drgnx-work--commit-seqs (repo infos)
  "The place of each of the commits INFOS (`drgnx-work--log', newest first) of REPO among its commits: older commits
have fewer ancestors (dates tie within a second) — one count for them all.  A list, as INFOS."
  (let ((depth (and infos (string-to-number (or (drgnx-work--git repo "rev-list" "--count" (caar infos)) "0")))))
    (seq-map-indexed (lambda (_c i) (- i depth)) infos)))

;;;; Counts and recorded links

(defun drgnx-work-counts (plan)
  "(:tasks (DONE . ALL) :steps (DONE . ALL) :todos (DONE . ALL) :commits N) of PLAN."
  (let* ((kids (drgnx-work-children plan))
         (tasks (seq-filter (lambda (n) (eq (plist-get n :kind) 'task)) kids))
         (todos (seq-filter (lambda (n) (eq (plist-get n :kind) 'todo)) kids))
         (task-kids (seq-mapcat (lambda (tk) (drgnx-work-children (plist-get tk :id))) tasks))
         (done-tasks (mapcar (lambda (tk) (plist-get tk :id)) (seq-filter (lambda (n) (equal (plist-get n :status) "done")) tasks)))
         ;; a step is done when ticked, or when its task is complete (ledgers rarely tick the plan)
         (steps (mapcar (lambda (n) (if (member (plist-get n :parent) done-tasks) (plist-put (copy-sequence n) :status "done") n))
                        (seq-filter (lambda (n) (eq (plist-get n :kind) 'step)) task-kids)))
         ;; the commits of its tasks, its TODOs and the plan itself
         (commits (delete-dups (mapcar (lambda (n) (plist-get n :id))
                                       (seq-filter (lambda (n) (eq (plist-get n :kind) 'commit))
                                                   (append kids task-kids (seq-mapcat (lambda (td) (drgnx-work-children (plist-get td :id))) todos))))))
         (done (lambda (l) (cons (seq-count (lambda (n) (equal (plist-get n :status) "done")) l) (length l)))))
    (list :tasks (funcall done tasks) :steps (funcall done steps) :todos (funcall done todos) :commits (length commits))))

(defvar drgnx-work--sync nil
  "Non-nil in the batch commands (`drgnx work record|scan'): a hub call waits for its answer (`drgnx-hub-call-sync'),
which a `--batch' Emacs needs.  Nil everywhere else, the editor's daemon paths above all: the call is asynchronous.")

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defun drgnx-work--hub-failed (text)
  "Tell the user once that a call to the hub failed (the notice replaces its predecessor: one at a time)."
  (require 'drgnx-notice)
  (drgnx-notify 'hub 'warn (format "drgnx hub: %s" text) :id 'work-record))

(defun drgnx-work--hub (method params &optional on-result)
  "Call the hub's METHOD with PARAMS (a plist).  In a batch command (`drgnx-work--sync') it waits and returns the
result (ON-RESULT, if given, turns it into the value); anywhere else it only asks, never waits and returns nil: an
error shows once as \"drgnx hub: TEXT\"."
  (if drgnx-work--sync
      (let ((r (drgnx-hub-call-sync method params 30))) (if on-result (funcall on-result r) r))
    (condition-case err
        (drgnx-hub-call method params
                        (lambda (r e)
                          (cond (e (drgnx-work--hub-failed e))
                                (on-result (funcall on-result r)))))
      (error (drgnx-work--hub-failed (error-message-string err))))
    nil))

(defun drgnx-work-record-commits (task repo infos &optional collected)
  "Record that the commits INFOS (`drgnx-work--log', newest first) of REPO did TASK (a node id) — kept across every
rescan — through the hub (`graph/record'; COLLECTED is the job collector's key, `job ID').  In a batch command their
ids; elsewhere nil (the call is asynchronous)."
  (let* ((repo (or (drgnx-work--main-repo repo) repo))
         (seqs (drgnx-work--commit-seqs repo infos))
         (params (append (list :task task :repo (directory-file-name repo)
                               :commits (vconcat (cl-mapcar (lambda (c sq) (list :sha (nth 0 c) :date (nth 1 c) :subject (nth 2 c) :seq sq))
                                                            infos seqs)))
                         (and collected (list :collected collected)))))
    (drgnx-work--hub "graph/record" params (lambda (r) (append (plist-get r :ids) nil)))))

(defun drgnx-work-record (task repo sha)
  "Record that commit SHA of REPO did TASK (a node id); in a batch command its node id, or nil when REPO has no SHA
\(elsewhere nil: the call is asynchronous)."
  (when-let* ((infos (drgnx-work--log repo "-1" sha)))
    (car (drgnx-work-record-commits task repo infos))))

;;;; Recording

(defun drgnx-work--head (dir &optional ref) (drgnx-work--git dir "rev-parse" (or ref "HEAD")))

(defun drgnx-work--source (s)
  "The (:repo REPO :ref REF) a `drgnx-work-source-functions' member names for session S, or nil."
  (run-hook-with-args-until-success 'drgnx-work-source-functions s))

(defun drgnx-work--notes-p () (or drgnx-work-git-notes (equal (getenv "DRGNX_WORK_GIT_NOTES") "1")))

(defun drgnx-work--note (repo sha task)
  "Note on commit SHA of REPO that it did TASK (once per task)."
  (let ((line (concat "drgnx task: " task)))
    (unless (member line (split-string (or (drgnx-work--git repo "notes" "--ref=drgnx" "show" sha) "") "\n"))
      (drgnx-work--git repo "notes" "--ref=drgnx" "append" "-m" line sha))))

(defun drgnx-work-record-commit (task repo sha)
  "`drgnx-work-record' TASK REPO SHA, mirrored to a git note when notes are on."
  (prog1 (drgnx-work-record task repo sha)
    (when (drgnx-work--notes-p) (drgnx-work--note repo sha task))))

(defun drgnx-work--new-commits (dir from to since)
  "The commits FROM..TO in DIR's repository on TO's own line (first parents), committed at SINCE or
later, newest first (`drgnx-work--log').  None when FROM is unknown, or TO does not descend from it
(a checkout, a rebase): what HEAD moved over then is not this work."
  (when (and from to (not (equal from to)) (drgnx-work--git dir "merge-base" "--is-ancestor" from to))
    (seq-filter (lambda (c) (>= (nth 1 c) (- since 2)))          ; a pull brings older commits
                (drgnx-work--log dir "--first-parent" (concat from ".." to)))))

(defun drgnx-work-task-begin (task dir &optional source)
  "Start recording for TASK the commits made in DIR's repository from now on: the state.
SOURCE (`drgnx-work-source-functions') names the repository and ref instead: nothing runs in DIR then, and
nothing is collected until `drgnx-work-collect-now'."
  (if source
      (let ((repo (plist-get source :repo)) (ref (plist-get source :ref)))
        (list :task task :dir repo :ref ref :head (drgnx-work--head repo ref) :repo repo :tree nil :source t
              :since (float-time) :busy nil :overlap nil))
    (list :task task :dir dir :head (drgnx-work--head dir) :repo (drgnx-work--main-repo dir)
          :tree (drgnx-work--git dir "rev-parse" "--show-toplevel")
          :since (float-time) :busy nil :overlap nil)))

(defun drgnx-work-task-collect (state &optional since overlap)
  "Record the commits made since STATE last looked (committed at SINCE or later, default when it
began); the SHAs recorded (none twice).  OVERLAP: another task session was busy in the same
checkout meanwhile — whose commits they are is unknown, so none is recorded (`drgnx work record')."
  (let* ((dir (plist-get state :dir)) (head (drgnx-work--head dir (plist-get state :ref))) (task (plist-get state :task))
         (new (drgnx-work--new-commits dir (plist-get state :head) head (or since (plist-get state :since)))))
    (plist-put state :head head)
    (cond ((null new) nil)
          (overlap (require 'drgnx-notice)
                   (drgnx-notify 'agents 'info
                                 (format "work: %d commit(s) not recorded for %s: another task session worked in %s too (drgnx work record)"
                                         (length new) task (plist-get state :tree)))
                   nil)
          ((> (length new) drgnx-work-collect-max)
           (require 'drgnx-notice)
           (drgnx-notify 'agents 'info
                         (format "work: %d new commits after one turn of %s: not recorded (drgnx work record)"
                                 (length new) task))
           nil)
          (t (drgnx-work-record-commits task dir new)
             (when (drgnx-work--notes-p) (dolist (c new) (drgnx-work--note dir (car c) task)))
             (mapcar #'car new)))))

(declare-function drgnx-agent-session-task "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")

(defun drgnx-work--collect-exit (s st)
  "Record, once, what exited session S (recording state ST) committed since its last turn ended — unless another
task session is busy in the same checkout (whose commits they are is unknown).  ST is `:done' then: later commits in
that checkout, the user's among them, are never the dead session's."
  (let ((overlap (seq-some (lambda (o) (and (not (eq (car o) s)) (plist-get (cdr o) :busy)
                                            (not (eq (drgnx-agent-session-status (car o)) 'exited))
                                            (equal (plist-get (cdr o) :tree) (plist-get st :tree))))
                           drgnx-work--tasks)))
    (plist-put st :busy nil) (plist-put st :overlap nil)
    (unless (plist-get st :source)                        ; a source session: the job collects, when it says so
      (with-demoted-errors "drgnx work: %S" (drgnx-work-task-collect st nil overlap)))))

(defun drgnx-work-collect-now (s)
  "Record, for session S that has a work source (`drgnx-work-source-functions'), the commits its task made: those
of the source's ref in its repository since the task began.  The SHAs recorded; none twice.  The job calls this
once the task's result is in the main repository; the session's own folder is never read."
  (when-let* ((st (alist-get s drgnx-work--tasks)) ((plist-get st :source)))
    (when-let* ((src (drgnx-work--source s)))
      (plist-put st :dir (plist-get src :repo)) (plist-put st :ref (plist-get src :ref)))
    (drgnx-work-task-collect st)))

(defun drgnx-work--agent-changed (s)
  "`drgnx-agents-changed-functions': the first time S is seen exited, its last commits are collected (on a timer,
never inside the process sentinel that saw the exit)."
  (let ((st (alist-get s drgnx-work--tasks)))
    (when (and st (not (plist-get st :done)) (eq (drgnx-agent-session-status s) 'exited))
      (plist-put st :done t)
      (run-at-time 0 nil (lambda () (drgnx-work--collect-exit s st))))))

(add-hook 'drgnx-agents-changed-functions #'drgnx-work--agent-changed)

(defun drgnx-work--agent-task (s event)
  "`drgnx-agents-task-functions': note where S's work starts; after each turn, record its commits —
on a timer, never inside the process filter that saw the turn end."
  (let ((st (alist-get s drgnx-work--tasks)))
    (pcase event
      ('start
       (setq drgnx-work--tasks (seq-remove (lambda (e) (eq (drgnx-agent-session-status (car e)) 'exited)) drgnx-work--tasks))
       (push (cons s (drgnx-work-task-begin (drgnx-agent-session-task s) (drgnx-agent-session-cwd s) (drgnx-work--source s)))
             drgnx-work--tasks))
      ('turn-start
       (when (and st (not (plist-get st :source)))
         (plist-put st :since (float-time)) (plist-put st :busy t)
         (dolist (o drgnx-work--tasks)                 ; two task sessions at work in one checkout
           (when (and (not (eq (car o) s)) (plist-get (cdr o) :busy)
                      (not (eq (drgnx-agent-session-status (car o)) 'exited))
                      (equal (plist-get (cdr o) :tree) (plist-get st :tree)))
             (plist-put (cdr o) :overlap t) (plist-put st :overlap t)))))
      ('turn-end
       (when (and st (not (plist-get st :source)))
         (let ((since (plist-get st :since)) (overlap (plist-get st :overlap)))
           (plist-put st :busy nil) (plist-put st :overlap nil)
           (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx work: %S" (drgnx-work-task-collect st since overlap))))))))))

(add-hook 'drgnx-agents-task-functions #'drgnx-work--agent-task)

(declare-function drgnx-exec-list "drgnx-exec")
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defvar drgnx-work--job-starts (make-hash-table :test #'equal)
  "Job id → (:head SHA :repo DIR :late BOOL): the commit HEAD pointed at, and the repository, when a job that works on
a task was first seen (the hub keeps neither), and whether it had ended by then (its HEAD then says nothing of where
it began).  Bounded: `drgnx-work-collect-jobs' drops the ids the hub no longer lists.")

(defun drgnx-work--job-start (job)
  "JOB's (:head :repo :late) as first seen (`drgnx-work--job-starts'), read from its folder now when that was not yet."
  (let ((id (plist-get job :id)))
    (or (gethash id drgnx-work--job-starts)
        (puthash id (list :head (drgnx-work--head (plist-get job :cwd)) :repo (drgnx-work--main-repo (plist-get job :cwd))
                          :late (and (memq (plist-get job :status) '(done failed stopped)) t))
                 drgnx-work--job-starts))))

(defun drgnx-work--commits-since (dir to since)
  "The commits on TO's own line (first parents) in DIR's repository committed at SINCE or later, newest first, at most
`drgnx-work-collect-max' and one more (so that too many can be told): for a job first seen after it ended, whose start
commit is unknown (`drgnx-work--new-commits' needs it)."
  (when to
    (seq-filter (lambda (c) (>= (nth 1 c) (- since 2)))
                (drgnx-work--log dir "--first-parent" "-n" (number-to-string (1+ drgnx-work-collect-max)) to))))

(defun drgnx-work-collect-jobs ()
  "Record the commits of the jobs that worked on a task and ended (each job once), in the repository
the job started in (its worktree may be gone by now).  A job's start commit is HEAD of its folder when this first saw
it (`drgnx-work--job-start'), its end commit HEAD of its folder (its own branch) now, or of the repository when the
folder is gone.  A job first seen after it ended has no known start: its commits are those on that line committed
since the job's start time (`drgnx-work--commits-since').  Through the hub: `graph/record' with the key
`job ID' (which the hub keeps, so a job is never collected twice), or the key alone (`graph/put-parsed') when there is
nothing to record."
  (require 'drgnx-exec)
  (let* ((jobs (drgnx-exec-list))
         (listed (mapcar (lambda (j) (plist-get j :id)) jobs))
         (gone nil))
    (maphash (lambda (id _) (unless (member id listed) (push id gone))) drgnx-work--job-starts)
    (dolist (id gone) (remhash id drgnx-work--job-starts))
    (dolist (job jobs)
      (when (plist-get job :task)
        (let* ((id (plist-get job :id)) (key (concat "job " id))
               (start (drgnx-work--job-start job)))
          (when (and (memq (plist-get job :status) '(done failed stopped))
                     (not (sqlite-select (drgnx-work-db-read) "select 1 from meta where key = ?" (list key))))
            (let* ((repo (plist-get start :repo))
                   (cwd (plist-get job :cwd))
                   ;; the job's own branch while its folder is there, else the repository's HEAD
                   (end (and repo (or (and cwd (file-directory-p cwd) (drgnx-work--head cwd))
                                      (drgnx-work--head repo)))))
              (when repo                               ; else: the repository may come back; try again later
                (let* ((since (if-let* ((s (plist-get job :started))) (float-time (date-to-time s)) 0))
                       (new (if (plist-get start :late)
                                (drgnx-work--commits-since repo end since)
                              (drgnx-work--new-commits repo (plist-get start :head) end since))))
                  (if (and new (<= (length new) drgnx-work-collect-max))
                      (progn (drgnx-work-record-commits (plist-get job :task) repo new key)
                             (when (drgnx-work--notes-p) (dolist (c new) (drgnx-work--note repo (car c) (plist-get job :task)))))
                    (drgnx-work--hub "graph/put-parsed" (list :collected (vector key)))))))))))))

;;;; Scanning what the user works on

(declare-function drgnx-projects-read "drgnx-projects")
(declare-function drgnx-projects-board-file "drgnx-projects")

(defun drgnx-work-default-roots ()
  "The roots of the projects drgnx knows (projects.eld) and `drgnx-work-roots'."
  (require 'drgnx-projects)
  (delete-dups (seq-filter #'file-directory-p
                           (mapcar #'expand-file-name
                                   (append drgnx-work-roots
                                           (delq nil (mapcar (lambda (p) (plist-get p :root)) (plist-get (drgnx-projects-read) :projects))))))))

(defun drgnx-work-refresh (&optional roots)
  "Have the hub read the records of ROOTS (default: `drgnx-work-default-roots') and of the board
\(`drgnx-projects-board-file', the one file of ~/org the product reads: `records/import' with only=board) — the importer
that adopts specs, plans, ledgers and the board's plan links — and collect ended jobs.  In a batch command
\(`drgnx-work--sync') it waits and answers (:files N :refused LIST): N the files the hub's imports list, LIST the roots
it refused (a project inside ~/org: the user's personal notes are never read), each (:source (:path ROOT) :why TEXT);
elsewhere the calls are asynchronous and it answers nil."
  (let ((files 0) (refused nil)
        (board (drgnx-projects-board-file)))
    (dolist (call (append (mapcar (lambda (r) (list :root (directory-file-name r))) (or roots (drgnx-work-default-roots)))
                          ;; the board last: its items link to the plans just read
                          (and (file-exists-p board)
                               (list (list :root (directory-file-name (file-name-directory board)) :only "board")))))
      (if drgnx-work--sync
          (condition-case err
              (cl-incf files (length (plist-get (drgnx-hub-call-sync "records/import" call 60) :files)))
            (error (push (list :source (list :path (plist-get call :root)) :why (error-message-string err)) refused)))
        (drgnx-work--hub "records/import" call)))
    (drgnx-work-collect-jobs)
    (and drgnx-work--sync (list :files files :refused (nreverse refused)))))

;;;; Command line

(defun drgnx-work--print (fmt &rest args) (princ (apply #'format fmt args)) (terpri))

(defun drgnx-work--status-rows ()
  "One row per plan: (:id :title :path :spec :branch :merged COUNTS…)."
  (mapcar (lambda (p)
            (append (list :id (plist-get p :id) :title (plist-get p :title) :path (plist-get p :path)
                          :spec (car (car (drgnx-work-edges-from (plist-get p :id) 'derives)))
                          :branch (plist-get p :branch) :merged (plist-get p :merged))
                    (drgnx-work-counts (plist-get p :id))))
          (sort (drgnx-work-nodes 'plan) (lambda (a b) (string< (plist-get a :path) (plist-get b :path))))))

(defun drgnx-work--json-row (row)
  (let ((pair (lambda (c) (vector (car c) (cdr c)))))
    (list :id (plist-get row :id) :title (plist-get row :title) :path (plist-get row :path)
          :spec (or (plist-get row :spec) :null) :branch (or (plist-get row :branch) :null)
          :merged (if (plist-get row :merged) t :false)
          :tasks (funcall pair (plist-get row :tasks)) :steps (funcall pair (plist-get row :steps))
          :todos (funcall pair (plist-get row :todos)) :commits (plist-get row :commits))))

(defun drgnx-work--ensure-hub ()
  "t when a hub serves (started if need be); else it says so and nil: the tracker updates only through the hub."
  (condition-case err
      (drgnx-hub-ensure)
    (error (drgnx-work--print "the work tracker updates through the drgnx hub (%s)" (error-message-string err))
           nil)))

(defun drgnx-work-cli-run (args)
  "Run `drgnx work' ARGS (strings); the exit code (2: a usage error).  `record' and `scan' go through the hub and
wait for it (`drgnx-work--sync'); with no hub they say so, write nothing and fail."
  (condition-case err
      (let ((drgnx-work--sync t))
        (pcase args
          (`("record" . ,rest)
           (let ((task (getenv "DRGNX_TASK")) shas)
             (while rest
               (let ((a (pop rest)))
                 (if (equal a "--task") (setq task (pop rest)) (push a shas))))
             (if (or (null task) (string-empty-p task))
                 (progn (drgnx-work--print "drgnx work record: which task? (--task ID, or DRGNX_TASK)") 2)
               (let ((repo (drgnx-work--git default-directory "rev-parse" "--show-toplevel")) (bad 0))
                 (cond
                  ((not repo) (drgnx-work--print "drgnx work record: not inside a git repository") 1)
                  ((not (drgnx-work--ensure-hub)) 1)
                  (t
                   (dolist (sha (or (nreverse shas) '("HEAD")))
                     (let ((full (drgnx-work--git repo "rev-parse" "--verify" "--quiet" (concat sha "^{commit}"))))
                       (if (and full (drgnx-work-record-commit task (file-name-as-directory repo) full))
                           (drgnx-work--print "%s → %s" (substring full 0 7) task)
                         (drgnx-work--print "drgnx work record: no commit %s here" sha)
                         (setq bad 1))))
                   bad))))))
          (`("scan" . ,rest)
           (if (not (drgnx-work--ensure-hub)) 1
             (let* ((t0 (float-time)) (r (drgnx-work-refresh (mapcar #'expand-file-name rest))))
               (dolist (x (plist-get r :refused))
                 (drgnx-work--print "refused: %s (%s)" (or (plist-get (plist-get x :source) :path) (plist-get x :id) "?") (plist-get x :why)))
               (drgnx-work--print "%d files read in %.2f s; %d plans, %d specs (%s)" (plist-get r :files) (- (float-time) t0)
                                  (length (drgnx-work-nodes 'plan)) (length (drgnx-work-nodes 'spec)) (drgnx-work-db-file))
               0)))
          (`("status" . ,flags)
           (let ((rows (drgnx-work--status-rows)))
             (if (member "--json" flags)
                 ;; json-serialize gives UTF-8 bytes (unibyte); decode them so the locale's encoding of stdout is
                 ;; not applied on top, and write UTF-8 whatever the locale says.
                 (let ((coding-system-for-write 'utf-8-unix))
                   (princ (decode-coding-string (json-serialize (vconcat (mapcar #'drgnx-work--json-row rows))) 'utf-8)))
               (if (null rows) (drgnx-work--print "no plans yet: drgnx work scan [DIR…]")
                 (dolist (r rows)
                   (let ((c (lambda (k) (format "%d/%d" (car (plist-get r k)) (cdr (plist-get r k))))))
                     (drgnx-work--print "%-9s tasks %-6s steps %-7s todos %-5s commits %-3d %s%s"
                                        (cond ((plist-get r :merged) "merged") ((plist-get r :branch) "branch") (t ""))
                                        (funcall c :tasks) (funcall c :steps) (funcall c :todos) (plist-get r :commits)
                                        (plist-get r :title) (if (plist-get r :branch) (format "  [%s]" (plist-get r :branch)) ""))))))
             0))
          (_ (drgnx-work--print "usage: drgnx work record [--task ID] [SHA…] | scan [DIR…] | status [--json]") 2)))
    (error (drgnx-work--print "drgnx work: %s" (error-message-string err)) 1)))

(defun drgnx-work-cli ()
  "bin/drgnx's work commands: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-work-cli-run args))))

(provide 'drgnx-work)
;;; drgnx-work.el ends here
