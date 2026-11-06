;;; drgnx-extensions-jobs.el --- The Extensions view's jobs: the queue of clicks, progress files, results -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every install, update, removal, rollback and catalog refresh the Extensions view asks for is a hub job running a
;; batch command (`drgnx sync --pending --wait', `drgnx upgrade', `drgnx extensions refresh', …).  This file starts
;; those jobs, follows their progress files and keeps what they ended with, for the rows to read.  Nothing here waits
;; or prompts: a job starts asynchronously (`drgnx-exec-start'), its progress is read when a file-notify watch on the
;; progress directory says it changed (coalesced: at most four reads a second, the last change always read), its end
;; is the hub's `exec-done' event, and `drgnx-extensions-jobs-state' is a cache read.
;;
;; A click is a ticket in pending.eld (core/drgnx-pkg-wants.el).  A job running `drgnx sync --pending' takes the whole
;; queue once it holds the sync lock, and its `start' step says which tickets it took.  So a click joins the job that
;; is still waiting (started, its `start' step not seen yet); and at every first step seen and every end the layer
;; compares the queue with what the jobs took, so a ticket clicked after a job took the queue gets one new job.
;;
;; The Extensions module's setup calls `drgnx-extensions-jobs-setup', its teardown `drgnx-extensions-jobs-teardown'.
;; See docs/develop/extensions.md, "Jobs".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'filenotify)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-guard)
(require 'drgnx-timer)
(require 'drgnx-exec)
(require 'drgnx-pkg-wants)

(declare-function drgnx-pkg-archives "drgnx-pkg" ())
(declare-function drgnx-modules--owner "drgnx-modules-record" ())

(defvar drgnx-extensions-jobs-changed-functions nil
  "Called with IDS, the packages (symbols) and tickets (integers) whose `drgnx-extensions-jobs-state' changed.")

(defvar drgnx-extensions-jobs-plan-functions nil
  "Called with PLAN once for each new swap plan of any Extensions job, whichever drgnx session started it (the state
directory is shared): the plan step's plist (:seq N :generation G :replaces DIRS :removes DIRS :adds DIRS) and :file,
DIRS being package directory names (\"magit-4.1\") and generation G holding the copies of those the swap takes away.")

(defvar drgnx-extensions-jobs-done-functions nil
  "Called with (JOB RESULT) when an Extensions job this session follows has ended: JOB its id, RESULT a plist
\(:status S :error TEXT :warnings LINES :missing ((NAME . WHY)…) :partly ((NAME FILE…)…) :kind KIND :plan FILE), S
`done', `failed' or `stopped', FILE the job's plan file (gone by then; the :file its plan hook had).")

(defvar drgnx-extensions-jobs-before-functions nil
  "Called with (NAMES PLAN) before this session asks the hub to start a job that may swap packages, or adds a click
to a queue run that has not taken the queue yet: NAMES the packages (symbols) it changes, or t for any (an update of
every package, a rollback); PLAN the plan file that job will write (the :file of its plan hook and the :plan of its
result).")

(defvar drgnx-extensions-jobs-plan-gone-functions nil
  "Called with FILE when the plan file of a job this session does not follow is gone: another session's job ended
\(its session deleted the file).")

(defconst drgnx-extensions-jobs-timebox 7200 "Seconds an Extensions job may run.")

(defconst drgnx-extensions-jobs--keep (* 24 3600)
  "Seconds a progress file no result read is kept (a job's time box is two hours).")

(defvar drgnx-extensions-jobs--named nil
  "The progress files the change events since the last read named, or t when one named none (then a read reads the
whole directory).")

(defvar drgnx-extensions-jobs--jobs (make-hash-table :test #'equal)
  "Token → the plist of a job this session follows: (:token :kind :id :status :since :start-seen :tickets :ids :step
:pkg :i :n :adds :callback).  A job leaves when its result is read.")

(defvar drgnx-extensions-jobs--ids (make-hash-table :test #'equal) "Job id → its token.")

(defvar drgnx-extensions-jobs--tickets (make-hash-table)
  "Ticket → the click: (:entry ENTRY :pkg NAME :latest V :since TIME :job TOKEN :taken BOOL :done JOB-ID :error TEXT).")

(defvar drgnx-extensions-jobs--state (make-hash-table)
  "Package (a symbol) or ticket (an integer) → its state, as `drgnx-extensions-jobs-state' returns it.")

(defvar drgnx-extensions-jobs--plans (make-hash-table :test #'equal) "Plan file → the last `seq' the plan hook ran for.")

(defvar drgnx-extensions-jobs--watch nil "The file-notify watch on the progress directory; nil without a backend.")

(defvar drgnx-extensions-jobs--on nil "Non-nil between `drgnx-extensions-jobs-setup' and its teardown.")

(defvar drgnx-extensions-jobs--listed nil "Non-nil once the hub's job list has answered since the setup.")

(defvar drgnx-extensions-jobs--owner :core "Who owns the layer's read timer: the module whose setup started it.")

(defvar drgnx-extensions-jobs--count 0 "Progress file tokens made by this session.")

;;;; Places and files

(defun drgnx-extensions-jobs-dir ()
  "The progress directory every drgnx session shares: <state>/extensions/progress/."
  (file-name-as-directory (expand-file-name "extensions/progress" (drgnx-state-dir))))

(defun drgnx-extensions-jobs--file (token) (expand-file-name (concat token ".json") (drgnx-extensions-jobs-dir)))

(defun drgnx-extensions-jobs--plan-file (token) (concat (drgnx-extensions-jobs--file token) ".plan.json"))

(defun drgnx-extensions-jobs--before (names token)
  "Tell `drgnx-extensions-jobs-before-functions' that job TOKEN will change NAMES (a list, or t)."
  (when names (drgnx-guard-run-hook 'drgnx-extensions-jobs-before-functions names (drgnx-extensions-jobs--plan-file token))))

(defun drgnx-extensions-jobs--token ()
  "A new progress file name, made before the job starts: this session's pid, a count and a random part."
  (format "%d-%d-%06x" (emacs-pid) (cl-incf drgnx-extensions-jobs--count) (random #x1000000)))

(defun drgnx-extensions-jobs--json (file)
  "FILE's JSON object as a plist (arrays as lists), or nil when it is not there or not whole.  A file of one line per
step (the catalog refresh's) gives (:step LAST-LINE)."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (skip-chars-forward " \t\n")
        (if (eq (char-after) ?{)
            (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil)
          (let ((lines (split-string (buffer-string) "\n" t "[ \t]+")))
            (and lines (list :step (car (last lines)))))))
    (error nil)))

(defun drgnx-extensions-jobs--pending ()
  "The entries of the queue file, (:ticket N …)…; nil when there are none or it does not read."
  (let ((data (plist-get (ignore-errors (drgnx-file-read (drgnx-pkg-pending-file))) :data)))
    (and (consp data) (seq-filter (lambda (e) (natnump (plist-get e :ticket))) (plist-get data :entries)))))

(defun drgnx-extensions-jobs--queued-tickets () (mapcar (lambda (e) (plist-get e :ticket)) (drgnx-extensions-jobs--pending)))

(defun drgnx-extensions-jobs--name (x) "Package X as a symbol." (if (stringp x) (intern x) x))

(defun drgnx-extensions-jobs--entry-pkg (entry)
  (drgnx-extensions-jobs--name (or (plist-get entry :add) (plist-get entry :remove))))

;;;; States

(defun drgnx-extensions-jobs-state (id)
  "The state of ID, a package (a symbol or a name) or a ticket, or nil: (:status S :step STEP :pkg P :i I :n N :since
TIME :error TEXT :warnings LIST :job JOB :tickets LIST), S `queued', `busy', `done', `failed' or `stopped'.  STEP is
the job's last step seen (`download', `native', …), P, I and N the package and count it is at, TIME when the status
began (`drgnx-timer-now'), JOB the job's id.  A cache read: never calls the hub, never reads a file."
  (gethash (drgnx-extensions-jobs--name id) drgnx-extensions-jobs--state))

(defun drgnx-extensions-jobs--put (ids state)
  "Make STATE the state of each of IDS (nil ones skipped); IDS."
  (dolist (id ids) (when id (puthash id state drgnx-extensions-jobs--state)))
  ids)

(defun drgnx-extensions-jobs--changed (ids)
  "Tell `drgnx-extensions-jobs-changed-functions' that IDS changed, each once."
  (when-let* ((ids (delete-dups (delq nil (copy-sequence ids)))))
    (drgnx-guard-run-hook 'drgnx-extensions-jobs-changed-functions ids)))

(defun drgnx-extensions-jobs--job (token) (and token (gethash token drgnx-extensions-jobs--jobs)))

(defun drgnx-extensions-jobs--job-put (token &rest kvs)
  "Set KVS (KEY VALUE…) on job TOKEN."
  (let ((job (gethash token drgnx-extensions-jobs--jobs)))
    (while kvs (setq job (plist-put job (pop kvs) (pop kvs))))
    (puthash token job drgnx-extensions-jobs--jobs)))

(defun drgnx-extensions-jobs--ticket-put (ticket &rest kvs)
  "Set KVS (KEY VALUE…) on the click TICKET."
  (let ((rec (gethash ticket drgnx-extensions-jobs--tickets)))
    (while kvs (setq rec (plist-put rec (pop kvs) (pop kvs))))
    (puthash ticket rec drgnx-extensions-jobs--tickets)))

(defun drgnx-extensions-jobs--waiting-p (job)
  "Non-nil when JOB is a queue run that, as far as this session saw, has not taken the queue: started, no step seen."
  (and job (eq (plist-get job :kind) 'sync) (eq (plist-get job :status) 'running) (not (plist-get job :start-seen))))

(defun drgnx-extensions-jobs--waiting ()
  "The token of a waiting queue run, or nil."
  (let (found)
    (maphash (lambda (token job) (when (and (not found) (drgnx-extensions-jobs--waiting-p job)) (setq found token)))
             drgnx-extensions-jobs--jobs)
    found))

(defun drgnx-extensions-jobs--busy-state (job)
  (list :status 'busy :step (plist-get job :step) :pkg (plist-get job :pkg) :i (plist-get job :i) :n (plist-get job :n)
        :since (plist-get job :since) :job (plist-get job :id) :tickets (plist-get job :tickets)))

(defun drgnx-extensions-jobs--ticket-state (ticket)
  "Make the state of the click TICKET (and of its package) what its job says; the two ids.  A ticket its job took is
`busy'; without a file-notify backend no step is seen, so one whose job has started is `busy' with its elapsed time
only."
  (let* ((rec (gethash ticket drgnx-extensions-jobs--tickets))
         (job (drgnx-extensions-jobs--job (plist-get rec :job))))
    (drgnx-extensions-jobs--put
     (list ticket (plist-get rec :pkg))
     (if (and job (or (plist-get rec :taken) (and (not drgnx-extensions-jobs--watch) (plist-get job :id))))
         (drgnx-extensions-jobs--busy-state job)
       (list :status 'queued :since (plist-get rec :since) :job (plist-get job :id) :error (plist-get rec :error)
             :tickets (list ticket))))))

(defun drgnx-extensions-jobs--refresh-job (token)
  "Make the rows of job TOKEN what it says now; their ids."
  (let ((job (drgnx-extensions-jobs--job token)) ids)
    (if (eq (plist-get job :kind) 'sync)
        (let (mine)
          (maphash (lambda (tk rec) (when (equal (plist-get rec :job) token) (push tk mine))) drgnx-extensions-jobs--tickets)
          (dolist (tk mine) (setq ids (append (drgnx-extensions-jobs--ticket-state tk) ids))))
      (setq ids (drgnx-extensions-jobs--put (plist-get job :ids) (drgnx-extensions-jobs--busy-state job))))
    ids))

;;;; Starting jobs

(defun drgnx-extensions-jobs--start (kind name args ids &optional callback names)
  "Start the job \"Extensions: NAME\" of KIND running bin/drgnx ARGS, for the rows IDS; its token.  The symbol
`progress' in ARGS becomes --progress and the job's progress file.  CALLBACK gets (ID WHY) when the hub answers.
NAMES (a list of packages, or t): what the job may swap, told to `drgnx-extensions-jobs-before-functions' before the
hub is asked."
  (let* ((token (drgnx-extensions-jobs--token)) (file (drgnx-extensions-jobs--file token))
         (argv (cons (expand-file-name "bin/drgnx" drgnx-dir)
                     (mapcan (lambda (a) (if (eq a 'progress) (list "--progress" file) (list a))) args))))
    (puthash token (list :token token :kind kind :status 'running :since (drgnx-timer-now) :ids ids :callback callback)
             drgnx-extensions-jobs--jobs)
    (drgnx-extensions-jobs--before names token)
    (drgnx-exec-start (concat "Extensions: " name) argv :cwd drgnx-dir :machine "local" :local-only t
                      :timebox drgnx-extensions-jobs-timebox
                      :callback (lambda (id why) (drgnx-extensions-jobs--started token id why)))
    token))

(defun drgnx-extensions-jobs--started (token id why)
  "The hub answered job TOKEN's start: its ID, or nil and WHY it did not start."
  (when-let* ((job (drgnx-extensions-jobs--job token)))
    (if (not id)
        (drgnx-extensions-jobs--not-started token why)
      (puthash id token drgnx-extensions-jobs--ids)
      (drgnx-extensions-jobs--job-put token :id id)
      (drgnx-extensions-jobs--changed (drgnx-extensions-jobs--refresh-job token))
      (when-let* ((callback (plist-get job :callback))) (drgnx-guard--call callback "extensions job" (list id nil)))
      ;; an end the hub told before it answered the start is in the job cache
      (let ((cached (drgnx-exec-get id)))
        (when (and cached (not (eq (plist-get cached :status) 'running)))
          (drgnx-extensions-jobs--ended token (plist-get cached :status) (plist-get cached :summary)))))))

(defun drgnx-extensions-jobs--not-started (token why)
  "Job TOKEN did not start, for WHY: a queue run's clicks stay queued with the reason (the next click, start or end
gives them a job); another job's rows fail with it."
  (let ((job (drgnx-extensions-jobs--job token)) ids)
    (remhash token drgnx-extensions-jobs--jobs)
    (if (eq (plist-get job :kind) 'sync)
        (let (mine)
          (maphash (lambda (tk rec) (when (equal (plist-get rec :job) token) (push tk mine))) drgnx-extensions-jobs--tickets)
          (dolist (tk mine)
            (drgnx-extensions-jobs--ticket-put tk :job nil :error why)
            (setq ids (append (drgnx-extensions-jobs--ticket-state tk) ids))))
      (setq ids (drgnx-extensions-jobs--put (plist-get job :ids)
                                            (list :status 'failed :error why :since (drgnx-timer-now)))))
    (when-let* ((callback (plist-get job :callback))) (drgnx-guard--call callback "extensions job" (list nil why)))
    (drgnx-extensions-jobs--changed ids)))

(defun drgnx-extensions-jobs--sync-name (tickets)
  "What a queue run started for TICKETS does: \"install magit, corfu; remove eat\"."
  (let (add remove)
    (dolist (tk tickets)
      (let ((e (plist-get (gethash tk drgnx-extensions-jobs--tickets) :entry)))
        (if (plist-get e :add) (push (format "%s" (plist-get e :add)) add) (push (format "%s" (plist-get e :remove)) remove))))
    (string-join (delq nil (list (and add (concat "install " (string-join (nreverse add) ", ")))
                                 (and remove (concat "remove " (string-join (nreverse remove) ", ")))))
                 "; ")))

(defun drgnx-extensions-jobs--reconcile ()
  "Give each ticket left in the queue a job: the waiting queue run, else one new one.  Only once the hub's job list
has answered (a run an earlier session started may be waiting for the sync lock).  The ids that changed."
  (when drgnx-extensions-jobs--listed
    (let (left)
      (dolist (e (drgnx-extensions-jobs--pending))
        (let ((tk (plist-get e :ticket)))
          (unless (gethash tk drgnx-extensions-jobs--tickets)  ; a click of another session, or of an earlier one
            (puthash tk (list :entry (cddr e) :pkg (drgnx-extensions-jobs--entry-pkg e) :since (drgnx-timer-now))
                     drgnx-extensions-jobs--tickets))
          (unless (drgnx-extensions-jobs--waiting-p
                   (drgnx-extensions-jobs--job (plist-get (gethash tk drgnx-extensions-jobs--tickets) :job)))
            (push tk left))))
      (when left
        (setq left (nreverse left))
        (let* ((names (delete-dups (delq nil (mapcar (lambda (tk) (plist-get (gethash tk drgnx-extensions-jobs--tickets) :pkg))
                                                     left))))
               (waiting (drgnx-extensions-jobs--waiting))
               (token (or waiting
                          (drgnx-extensions-jobs--start 'sync (drgnx-extensions-jobs--sync-name left)
                                                        '("sync" "--pending" "--wait" progress) nil nil names))))
          (when waiting (drgnx-extensions-jobs--before names waiting))   ; it has not taken the queue: before it does
          (dolist (tk left) (drgnx-extensions-jobs--ticket-put tk :job token :taken nil :error nil))
          (apply #'append (mapcar #'drgnx-extensions-jobs--ticket-state left)))))))

(defun drgnx-extensions-jobs-queue (entry)
  "Queue the click ENTRY — (:add NAME [:version V] [:latest V]) or (:remove NAME) — and give it a job; its ticket.
:latest is the version the page showed (the row says so when another one is installed); it stays in this session,
not in the queue file.  The click joins the queue run that is waiting, else starts one.  When another drgnx holds the
queue file the click is not queued: nil, and the package's row is `refused' with the :error \"busy, try again\" (a
refusal for now: neither a running job nor `failed'; the next click replaces it).  Never waits."
  (let* ((pkg (drgnx-extensions-jobs--entry-pkg entry))
         (add (plist-get entry :add))
         (queued (if add
                     (append (list :add pkg) (and (plist-get entry :version) (list :version (plist-get entry :version))))
                   (list :remove pkg)))
         (ticket (condition-case nil (drgnx-pkg-pending-add queued)
                   (drgnx-file-busy
                    ;; a refusal for now, neither running nor failed: the row says so with the hint
                    (drgnx-extensions-jobs--put (list pkg) (list :status 'refused :error "busy, try again"
                                                                 :since (drgnx-timer-now)))
                    (drgnx-extensions-jobs--changed (list pkg))
                    nil))))
    (when ticket
      (puthash ticket (list :entry queued :pkg pkg :latest (plist-get entry :latest) :since (drgnx-timer-now))
               drgnx-extensions-jobs--tickets)
      (drgnx-extensions-jobs--changed (append (drgnx-extensions-jobs--ticket-state ticket)
                                              (drgnx-extensions-jobs--reconcile))))
    ticket))

(defun drgnx-extensions-jobs--command (kind args)
  "(NAME ARGS IDS SWAPS) of the job KIND with ARGS (`drgnx-extensions-jobs-run'); SWAPS what it may swap (a list of
packages, t for any, nil for none)."
  (let ((text (lambda (x) (format "%s" x))))
    (pcase kind
      ('upgrade
       (cl-destructuring-bind (names &key stage staged &allow-other-keys) args
         (let* ((names (mapcar #'drgnx-extensions-jobs--name names)) (said (mapconcat #'symbol-name names ", ")))
           (list (cond (stage (concat "download the update of " said))
                       (staged (concat "install the reviewed update of " said))
                       (t (concat "update " said)))
                 ;; --staged goes alone: it installs exactly the entries --stage listed, hashes checked
                 (if staged '("upgrade" "--staged" progress)
                   (append '("upgrade" "--only") (mapcar #'symbol-name names) (and stage '("--stage")) '(progress)))
                 names
                 (and (not stage) (if staged t names))))))   ; a staged update may bring what NAMES need
      ('upgrade-all (list "update every package" '("upgrade" progress) nil t))
      ('rollback
       (let ((n (and (integerp (car args)) (car args))))
         (list (if n (format "roll back to generation %d" n) "roll back")
               (append '("rollback") (and n (list (number-to-string n))) '(progress)) nil t)))
      ('refresh (list "refresh the catalog" '("extensions" "refresh" progress) nil))
      ('fetch-readme
       (let ((archive (nth 0 args)) (name (nth 1 args)))
         (list (format "the readme of %s" name) (list "extensions" "fetch-readme" (funcall text archive) (funcall text name)) nil)))
      ('plugin-install
       (cl-destructuring-bind (path &key replace &allow-other-keys) args
         (list (format "install the plugin at %s" (abbreviate-file-name path))
               (append (list "plugins" "install" (expand-file-name path)) (and replace '("--replace"))) nil)))
      ('plugin-remove
       (let ((name (car args)))
         (list (format "remove the plugin %s" name) (list "plugins" "remove" (funcall text name)) nil)))
      (_ (error "No Extensions job %S" kind)))))

(defun drgnx-extensions-jobs-run (kind &rest args)
  "Start the Extensions job KIND with ARGS; its token.  The job's id comes to the :callback in ARGS, called with (ID
WHY) once the hub answers (ID nil: it did not start, for WHY).  KIND and ARGS:
  upgrade NAMES [:stage t | :staged t]  update NAMES; :stage downloads and checks only, :staged installs what was
                                        staged (`drgnx upgrade --only NAMES …')
  upgrade-all                           update every package
  rollback N                            back to generation N (nil: the one before)
  refresh                               refresh the catalog
  fetch-readme ARCHIVE NAME             cache a package's readme
  plugin-install PATH [:replace t]      install the plugin at PATH, replacing one of its name with :replace
  plugin-remove NAME                    remove a plugin
The rows of NAMES are `busy' while it runs."
  (pcase-let* ((`(,name ,argv ,ids ,swaps) (drgnx-extensions-jobs--command kind args))
               (callback (plist-get (seq-drop-while (lambda (a) (not (keywordp a))) args) :callback))
               (token (drgnx-extensions-jobs--start kind name argv ids callback swaps)))
    (when (drgnx-extensions-jobs--job token)
      (drgnx-extensions-jobs--changed (drgnx-extensions-jobs--refresh-job token)))
    token))

(defun drgnx-extensions-jobs-cancel (id-or-ticket)
  "Cancel: a ticket still queued leaves the queue file (t; nil when a run took it already, or the file is busy), a
job id is stopped (`drgnx-exec-stop').  Never waits."
  (if (not (integerp id-or-ticket))
      (progn (drgnx-exec-stop id-or-ticket) t)
    (let ((pkg (plist-get (gethash id-or-ticket drgnx-extensions-jobs--tickets) :pkg)))
      (when (condition-case nil (drgnx-pkg-pending-cancel id-or-ticket) (drgnx-file-busy nil))
        (remhash id-or-ticket drgnx-extensions-jobs--tickets)
        (dolist (id (list id-or-ticket pkg)) (when id (remhash id drgnx-extensions-jobs--state)))
        (drgnx-extensions-jobs--changed (list id-or-ticket pkg))
        t))))

(defun drgnx-extensions-jobs-retry (id)
  "The Retry of the failed row ID (a package or ticket): every click that failed in the same job is queued again.
The new tickets."
  (let* ((state (drgnx-extensions-jobs-state id)) (job (plist-get state :job)) again)
    (when (and job (eq (plist-get state :status) 'failed))
      (maphash (lambda (tk rec) (when (equal (plist-get rec :done) job) (push tk again))) drgnx-extensions-jobs--tickets)
      (mapcar (lambda (tk)
                (let ((rec (gethash tk drgnx-extensions-jobs--tickets)))
                  (drgnx-extensions-jobs--ticket-put tk :done nil)
                  (drgnx-extensions-jobs-queue (append (plist-get rec :entry)
                                                       (and (plist-get rec :latest) (list :latest (plist-get rec :latest)))))))
              (sort again #'<)))))

;;;; Progress

(defun drgnx-extensions-jobs--notify (event)
  "The progress directory changed (EVENT, a file-notify event): note the files it names and read them soon, at most
four times a second; the last change is always read."
  (when drgnx-extensions-jobs--on
    (let ((files (seq-filter #'stringp (list (nth 2 event) (nth 3 event)))))
      (unless (eq drgnx-extensions-jobs--named t)
        (setq drgnx-extensions-jobs--named
              (if files (seq-union files drgnx-extensions-jobs--named) t))))
    (drgnx-timer-soon 'extensions-jobs-read 0.1 #'drgnx-extensions-jobs--read :min-interval 0.25
                      :owner drgnx-extensions-jobs--owner)))

(defun drgnx-extensions-jobs--read ()
  "Read the progress files the change events named (the whole directory when one named none): the steps of the jobs
this session follows, every new plan of any job, and the plans that went."
  (when drgnx-extensions-jobs--on
    (let* ((dir (drgnx-extensions-jobs-dir)) (named drgnx-extensions-jobs--named) (ids nil)
           (all (and (file-directory-p dir) (directory-files dir t "\\.json\\'")))
           (files (if (eq named t) all
                    (seq-filter (lambda (f) (and (string-suffix-p ".json" f) (member f all)))
                                (mapcar #'expand-file-name named)))))
      (setq drgnx-extensions-jobs--named nil)
      (dolist (f files)
        (if (string-suffix-p ".plan.json" f)
            (drgnx-extensions-jobs--read-plan f)
          (setq ids (append (drgnx-extensions-jobs--read-step (file-name-base f) f) ids))))
      (let (gone)
        (maphash (lambda (f _) (unless (member f all) (push f gone))) drgnx-extensions-jobs--plans)
        (dolist (f gone) (drgnx-extensions-jobs--plan-gone f)))
      (drgnx-extensions-jobs--changed ids))))

(defun drgnx-extensions-jobs--plan-gone (file)
  "The plan FILE a read saw before is gone: forget it, and when no job of this session wrote it (another session's
job ended), tell `drgnx-extensions-jobs-plan-gone-functions'.  A job of this session says so at its own end."
  (remhash file drgnx-extensions-jobs--plans)
  (unless (drgnx-extensions-jobs--job (string-remove-suffix ".json.plan.json" (file-name-nondirectory file)))
    (drgnx-guard-run-hook 'drgnx-extensions-jobs-plan-gone-functions file)))

(defun drgnx-extensions-jobs--read-step (token file)
  "Read FILE, job TOKEN's progress, when this session follows that job; the ids that changed."
  (when-let* ((job (drgnx-extensions-jobs--job token))
              ((eq (plist-get job :status) 'running))
              (step (drgnx-extensions-jobs--json file)))
    (let* ((name (plist-get step :step))
           (s (if (and (stringp name) (string-match-p "\\`[a-z]+\\'" name)) (intern name) name)))
      (drgnx-extensions-jobs--job-put token :step s :pkg (plist-get step :pkg) :i (plist-get step :i) :n (plist-get step :n))
      (if (and (eq (plist-get job :kind) 'sync) (not (plist-get job :start-seen)))
          (drgnx-extensions-jobs--took token (if (and (eq s 'start) (plist-member step :tickets)) (plist-get step :tickets) t))
        (drgnx-extensions-jobs--refresh-job token)))))

(defun drgnx-extensions-jobs--took (token tickets)
  "The queue run TOKEN took the queue: TICKETS, or t when its start step was missed (then its clicks no longer in the
queue are the ones it took).  Its clicks still queued get a job of their own; the ids that changed."
  (let ((queued (drgnx-extensions-jobs--queued-tickets)) mine)
    (maphash (lambda (tk rec) (when (equal (plist-get rec :job) token) (push tk mine))) drgnx-extensions-jobs--tickets)
    (when (eq tickets t) (setq tickets (sort (seq-remove (lambda (tk) (memq tk queued)) mine) #'<)))
    (drgnx-extensions-jobs--job-put token :start-seen t :tickets tickets)
    (dolist (tk tickets)
      (unless (gethash tk drgnx-extensions-jobs--tickets)
        (puthash tk (list :since (drgnx-timer-now)) drgnx-extensions-jobs--tickets))
      (drgnx-extensions-jobs--ticket-put tk :job token :taken t))
    (append (drgnx-extensions-jobs--refresh-job token) (drgnx-extensions-jobs--reconcile))))

(defun drgnx-extensions-jobs--read-plan (file)
  "Run `drgnx-extensions-jobs-plan-functions' for plan FILE when its `seq' is new; a plan of a job this session follows
also keeps the package directories it adds."
  (when-let* ((plan (drgnx-extensions-jobs--json file))
              (seq (plist-get plan :seq))
              ((natnump seq))
              ((> seq (gethash file drgnx-extensions-jobs--plans 0))))
    (puthash file seq drgnx-extensions-jobs--plans)
    (let ((token (string-remove-suffix ".json.plan.json" (file-name-nondirectory file))))
      (when-let* ((job (drgnx-extensions-jobs--job token)))
        (drgnx-extensions-jobs--job-put token :adds (append (plist-get plan :adds) (plist-get job :adds)))))
    (drgnx-guard-run-hook 'drgnx-extensions-jobs-plan-functions (append plan (list :file file)))))

;;;; Results

(defun drgnx-extensions-jobs--archive-names ()
  "The names of the archives packages.eld uses, or nil when it does not read."
  (require 'drgnx-pkg)
  (ignore-errors (mapcar #'car (drgnx-pkg-archives))))

(defun drgnx-extensions-jobs--missing-why (why)
  "The row's words for sync's MISSING reason WHY: a package no archive has says where it looked."
  (if (string-search "is unavailable" why)
      (let ((names (drgnx-extensions-jobs--archive-names)))
        (if names (concat "not in any archive you use: " (string-join names ", ")) "not in any archive you use"))
    why))

(defun drgnx-extensions-jobs--result (status summary)
  "What a job that ended with STATUS says in its SUMMARY's lines: (:status S :error TEXT :warnings LINES :missing
\((NAME . WHY)…) :partly ((NAME FILE…)…)).  The error is the last `drgnx:' line, for a job that did not end well; a
file that does not byte-compile is a warning, never a failure."
  (let (error missing partly warnings)
    (dolist (line (append (plist-get summary :lines) nil))
      (when (stringp line)
        (cond ((string-match "\\`\\(?:drgnx: \\)?MISSING \\([^ :]+\\): \\(.*\\)\\'" line)
               (let ((name (intern (match-string 1 line))) (why (match-string 2 line)))
                 (unless (assq name missing) (push (cons name (drgnx-extensions-jobs--missing-why why)) missing)))
               (when (string-prefix-p "drgnx: " line) (setq error (substring line 7))))
              ((string-match "\\`WARNING \\([^ :]+\\): \\(.+\\) does not byte-compile" line)
               (let* ((name (intern (match-string 1 line))) (file (match-string 2 line)) (cell (assq name partly)))
                 (if cell (setcdr cell (append (cdr cell) (list file))) (push (list name file) partly))))
              ((string-prefix-p "WARNING " line) (push (substring line 8) warnings))
              ((string-prefix-p "drgnx: " line) (setq error (substring line 7))))))
    (list :status status :error (and (not (eq status 'done)) error) :warnings (nreverse warnings)
          :missing (nreverse missing) :partly (nreverse partly))))

(defun drgnx-extensions-jobs--version (pkg adds)
  "The version of PKG among the package directories ADDS (\"magit-4.3\"), or nil."
  (seq-some (lambda (d) (and (string-match "\\`\\(.+\\)-\\([0-9][^-]*\\)\\'" d)
                             (equal (match-string 1 d) (symbol-name pkg)) (match-string 2 d)))
            adds))

(defun drgnx-extensions-jobs--final (result pkg latest job)
  "The state a row of PKG keeps after JOB ended with RESULT; LATEST the version its page showed."
  (let* ((status (plist-get result :status))
         (partly (and pkg (alist-get pkg (plist-get result :partly))))
         (version (and pkg latest (eq status 'done) (drgnx-extensions-jobs--version pkg (plist-get job :adds)))))
    (list :status status
          :error (and (not (eq status 'done)) (or (and pkg (alist-get pkg (plist-get result :missing))) (plist-get result :error)))
          :warnings (append (and partly (list (concat "partly compiled: " (string-join partly ", "))))
                            (and version (not (equal version latest))
                                 (list (format "installed %s, not the %s the page showed" version latest))))
          :since (drgnx-timer-now) :job (plist-get job :id) :tickets (plist-get job :tickets))))

(defun drgnx-extensions-jobs--exit-status (status exit)
  "The status of a job the hub says ended with STATUS (a string) and EXIT."
  (pcase status
    ("done" (if (memq exit '(nil 0)) 'done 'failed))
    ("stopped" 'stopped)
    (_ 'failed)))

(defun drgnx-extensions-jobs--ended (token status summary)
  "Job TOKEN ended with STATUS (`done', `failed', `stopped' or `gone') and SUMMARY: its rows keep the result, its files
are deleted, the done hook runs, and a click left in the queue gets a job."
  (when-let* ((job (drgnx-extensions-jobs--job token)))
    (let ((file (drgnx-extensions-jobs--file token)) (ids nil))
      (when (file-exists-p (concat file ".plan.json"))  ; a plan no read saw: its hook still runs, once
        (drgnx-extensions-jobs--read-plan (concat file ".plan.json")))
      (let* ((job (drgnx-extensions-jobs--job token))
             (status (if (memq status '(done failed stopped)) status 'failed))
             (result (drgnx-extensions-jobs--result status summary)))
        (remhash token drgnx-extensions-jobs--jobs)
        (remhash (plist-get job :id) drgnx-extensions-jobs--ids)
        (if (eq (plist-get job :kind) 'sync)
            (let ((queued (drgnx-extensions-jobs--queued-tickets)) mine)
              (maphash (lambda (tk rec) (when (equal (plist-get rec :job) token) (push tk mine))) drgnx-extensions-jobs--tickets)
              (unless (plist-get job :start-seen)
                (setq job (plist-put job :tickets (sort (seq-remove (lambda (tk) (memq tk queued)) (copy-sequence mine)) #'<))))
              (dolist (tk mine)
                (let ((rec (gethash tk drgnx-extensions-jobs--tickets)))
                  (if (memq tk queued)              ; not taken: it gets a job below
                      (progn (drgnx-extensions-jobs--ticket-put tk :job nil :taken nil)
                             (setq ids (append (drgnx-extensions-jobs--ticket-state tk) ids)))
                    (drgnx-extensions-jobs--ticket-put tk :job nil :taken nil :done (plist-get job :id))
                    (setq ids (append (drgnx-extensions-jobs--put
                                       (list tk (plist-get rec :pkg))
                                       (drgnx-extensions-jobs--final result (plist-get rec :pkg) (plist-get rec :latest) job))
                                      ids))))))
          (dolist (pkg (plist-get job :ids))
            (setq ids (append (drgnx-extensions-jobs--put (list pkg) (drgnx-extensions-jobs--final result pkg nil job)) ids))))
        (dolist (f (list file (concat file ".plan.json"))) (ignore-errors (delete-file f)))
        (remhash (concat file ".plan.json") drgnx-extensions-jobs--plans)
        (drgnx-guard-run-hook 'drgnx-extensions-jobs-done-functions (plist-get job :id)
                              (append result (list :kind (plist-get job :kind) :plan (concat file ".plan.json"))))
        (drgnx-extensions-jobs--changed (append ids (drgnx-extensions-jobs--reconcile)))))))

(defun drgnx-extensions-jobs--event (event data)
  "An event from the hub (`drgnx-hub-event-functions'): an Extensions job this session follows ended."
  (when (and drgnx-extensions-jobs--on (equal event "exec-done"))
    (when-let* ((token (gethash (plist-get data :id) drgnx-extensions-jobs--ids)))
      (drgnx-extensions-jobs--ended token (drgnx-extensions-jobs--exit-status (plist-get data :status) (plist-get data :exit))
                                    (plist-get data :summary)))))

;;;; Setup

(defun drgnx-extensions-jobs--adopt ()
  "Follow the Extensions jobs the hub lists that write into the progress directory and that no job of this session
is (an earlier session started them): a running one as if started here, one that ended has its result read."
  (let ((dir (drgnx-extensions-jobs-dir)) ended)
    (dolist (row (drgnx-exec-list))
      (let* ((argv (plist-get row :argv)) (file (cadr (member "--progress" argv))) (id (plist-get row :id))
             (running (eq (plist-get row :status) 'running)))
        (when (and (stringp (plist-get row :name)) (string-prefix-p "Extensions: " (plist-get row :name))
                   (stringp file) (equal (file-name-directory file) dir) id
                   (not (gethash id drgnx-extensions-jobs--ids)) (or running (file-exists-p file)))
          (let ((token (file-name-base file)))
            (puthash token (list :token token :id id :kind (if (member "--pending" argv) 'sync 'other) :status 'running
                                 :since (drgnx-timer-now))
                     drgnx-extensions-jobs--jobs)
            (puthash id token drgnx-extensions-jobs--ids)
            (if running
                (drgnx-extensions-jobs--read-step token file)
              (push (list token (plist-get row :status) (plist-get row :summary)) ended))))))
    (pcase-dolist (`(,token ,status ,summary) ended)
      (drgnx-extensions-jobs--ended token status summary))))

(defun drgnx-extensions-jobs--listed ()
  "The hub's job list answered (`drgnx-exec-listed-hook'): follow the Extensions jobs it has, then give a job to any
click left in the queue."
  (when drgnx-extensions-jobs--on
    (setq drgnx-extensions-jobs--listed t)
    (drgnx-extensions-jobs--adopt)
    (drgnx-extensions-jobs--changed (drgnx-extensions-jobs--reconcile))))

(defun drgnx-extensions-jobs--sweep ()
  "Delete the progress files older than a day: no session read their jobs' results."
  (let ((dir (drgnx-extensions-jobs-dir)) (old (- (drgnx-timer-now) drgnx-extensions-jobs--keep)))
    (dolist (f (and (file-directory-p dir) (directory-files dir t "\\.json\\'")))
      (when-let* ((attrs (file-attributes f)))
        (when (< (float-time (file-attribute-modification-time attrs)) old)
          (ignore-errors (delete-file f)))))))

(defun drgnx-extensions-jobs-setup ()
  "Start the job layer (the Extensions module's setup calls it): watch the progress directory, follow the hub's job
events and, once its job list has answered, give a job to any click left in the queue.  Never waits; idempotent."
  (unless drgnx-extensions-jobs--on
    (setq drgnx-extensions-jobs--on t drgnx-extensions-jobs--listed nil
          drgnx-extensions-jobs--owner (or (and (fboundp 'drgnx-modules--owner) (car (drgnx-modules--owner))) :core))
    (make-directory (drgnx-extensions-jobs-dir) t)
    (drgnx-extensions-jobs--sweep)
    (setq drgnx-extensions-jobs--watch
          (condition-case nil
              (file-notify-add-watch (drgnx-extensions-jobs-dir) '(change) #'drgnx-extensions-jobs--notify)
            (error nil)))                       ; no backend: rows show the elapsed time, the end comes from the hub
    (add-hook 'drgnx-hub-event-functions #'drgnx-extensions-jobs--event)
    (add-hook 'drgnx-exec-listed-hook #'drgnx-extensions-jobs--listed)
    (drgnx-exec-sync)))

(defun drgnx-extensions-jobs-teardown ()
  "Stop the job layer: the watch, the read timer and the hooks go, and what it knew is forgotten.  The jobs keep
running in the hub; the next setup follows them again."
  (when drgnx-extensions-jobs--watch (ignore-errors (file-notify-rm-watch drgnx-extensions-jobs--watch)))
  (drgnx-timer-cancel 'extensions-jobs-read)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-extensions-jobs--event)
  (remove-hook 'drgnx-exec-listed-hook #'drgnx-extensions-jobs--listed)
  (setq drgnx-extensions-jobs--on nil drgnx-extensions-jobs--listed nil drgnx-extensions-jobs--watch nil
        drgnx-extensions-jobs--owner :core drgnx-extensions-jobs--named nil)
  (dolist (table (list drgnx-extensions-jobs--jobs drgnx-extensions-jobs--ids drgnx-extensions-jobs--tickets
                       drgnx-extensions-jobs--state drgnx-extensions-jobs--plans))
    (clrhash table)))

(provide 'drgnx-extensions-jobs)
;;; drgnx-extensions-jobs.el ends here
