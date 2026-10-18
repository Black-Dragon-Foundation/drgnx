;;; drgnx-coord.el --- Agent coordination: jobs, tasks and leases, the decision log, messages -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What several agents working on one project share, kept in work.db (schema 5) so every process sees the same:
;; - jobs and their tasks: statuses (pending ready claimed running needs-input in-review done failed dropped),
;;   dependencies, claims that are leases (atomic, renewed by a heartbeat, released when silent);
;; - the decision log: build / wait / wont-build / replaces, numbered, with one version that every change raises;
;; - messages between agents and the user, with states queued → delivered → read → acted (or held, with why).
;; - an event log (what happened, written by the writers above in their own transaction), a registry of agents and the
;;   user's review marks.
;; Freshness is enforced, not advised: every write carries the log version its author last read; when the log
;; moved on, nothing is written and the answer lists what changed.  Used by the coordination MCP server
;; (drgnx-coord-mcp.el), the hub and the CLI.  See docs/develop/coordination.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-db)

(defvar drgnx-coord-lease-minutes 15 "A claim not renewed for this long is released.")
(defvar drgnx-coord-queue-limit 20 "Undelivered messages an agent may have waiting; more are held.")
(defvar drgnx-coord-pair-rate 6 "Messages from one agent to another per minute; more are held (no chatty loops).")

(defconst drgnx-coord--states '("queued" "delivered" "read" "acted") "Message states, in order (held stands apart).")
(defconst drgnx-coord--active '("claimed" "running" "needs-input" "in-review") "Task statuses that belong to an agent.")

(defun drgnx-coord--tx (fn)
  "FN in one immediate transaction (the write lock first: read-check-write never interleaves)."
  (let ((db (drgnx-work-db)))
    (sqlite-execute db "begin immediate")
    (condition-case err (prog1 (funcall fn db) (sqlite-execute db "commit"))
      (error (ignore-errors (sqlite-execute db "rollback")) (signal (car err) (cdr err))))))

(defun drgnx-coord--meta (db key) (caar (sqlite-select db "select value from meta where key = ?" (list key))))

(defun drgnx-coord-version ()
  "The decision log's version."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db) "log-version") "0")))

(defun drgnx-coord--bump (db)
  (let ((v (1+ (string-to-number (or (drgnx-coord--meta db "log-version") "0")))))
    (sqlite-execute db "insert or replace into meta values ('log-version', ?)" (list (number-to-string v)))
    v))

(defun drgnx-coord--held (db seen)
  "nil when SEEN is the current version; else (:held t :version V :changes DECISIONS).  A SEEN the log has not reached
is an error: nothing was read at a version that does not exist."
  (let ((v (string-to-number (or (drgnx-coord--meta db "log-version") "0"))))
    (when (and seen (> seen v))
      (error "seen_version %d is from the future: the decision log is at %d (call read_decisions)" seen v))
    (when (and seen (> v seen))
      (list :held t :version v :changes (drgnx-coord--decisions-since db seen)))))

;;;; Events: what happened, in the order it happened (schema 5)

(defconst drgnx-coord-event-kinds
  '("start" "stop" "claim" "release" "status" "decision" "edit" "test" "question" "answer" "review" "message" "card"
    "accept" "revert" "comment")
  "What an event can be.")

(defconst drgnx-coord--summary-max 200 "The longest event summary, in characters.")

(defun drgnx-coord--one-line (text)
  "TEXT as one line of at most `drgnx-coord--summary-max' characters (control characters become spaces)."
  (let ((line (replace-regexp-in-string "[[:cntrl:]]" " " (format "%s" (or text "")))))
    (if (> (length line) drgnx-coord--summary-max) (substring line 0 drgnx-coord--summary-max) line)))

(cl-defun drgnx-coord--event (db &key agent job task kind summary data at)
  "Insert one event through DB, inside the caller's transaction: its id.
DATA is printed (read back by `drgnx-coord-events')."
  (unless (member kind drgnx-coord-event-kinds) (error "Not an event kind: %S" kind))
  (sqlite-execute db "insert into event (at, agent, job, task, kind, summary, data) values (?, ?, ?, ?, ?, ?, ?)"
                  (list (float (or at (float-time))) agent job task kind (drgnx-coord--one-line summary)
                        (and data (drgnx-coord--print data))))
  (caar (sqlite-select db "select last_insert_rowid()")))

(cl-defun drgnx-coord-event-add (&key agent job task kind summary data at)
  "Record an event of KIND (one of `drgnx-coord-event-kinds') by AGENT (JOB, TASK) at AT (now): its id.
SUMMARY is cut to one line of at most 200 characters; DATA is a plist kept with it."
  (drgnx-coord--tx
   (lambda (db) (drgnx-coord--event db :agent agent :job job :task task :kind kind :summary summary :data data :at at))))

(defconst drgnx-coord--event-cols "id, at, agent, job, task, kind, summary, data")

(defun drgnx-coord--event-plist (row)
  (pcase-let ((`(,id ,at ,agent ,job ,task ,kind ,summary ,data) row))
    (list :id id :at at :agent agent :job job :task task :kind kind :summary summary
          :data (and data (ignore-errors (car (read-from-string data)))))))

(cl-defun drgnx-coord-events (&key since agent job task kinds limit)
  "The events after id SINCE (all when nil) — of AGENT, JOB, TASK and/or one of KINDS — oldest first, at most LIMIT:
(:id :at :agent :job :task :kind :summary :data)."
  (let* ((conds nil) (args nil))
    (cl-flet ((add (cond &rest vals) (push cond conds) (setq args (append args vals))))
      (when since (add "id > ?" since))
      (when agent (add "agent = ?" agent))
      (when job (add "job = ?" job))
      (when task (add "task = ?" task))
      (when kinds (apply #'add (format "kind in (%s)" (mapconcat (lambda (_) "?") kinds ", ")) kinds)))
    (mapcar #'drgnx-coord--event-plist
            (sqlite-select (drgnx-work-db)
                           (format "select %s from event%s order by id%s" drgnx-coord--event-cols
                                   (if conds (concat " where " (string-join (nreverse conds) " and ")) "")
                                   (if limit (format " limit %d" limit) ""))
                           args))))

(defun drgnx-coord-open-questions (&optional agent)
  "The question events (AGENT's, when given) that no later answer event names
(its `data' has `:question' ID), oldest first."
  (let ((answered (delq nil (mapcar (lambda (e) (plist-get (plist-get e :data) :question))
                                    (drgnx-coord-events :kinds '("answer"))))))
    (seq-remove (lambda (q) (memql (plist-get q :id) answered))
                (drgnx-coord-events :kinds '("question") :agent agent))))

(defun drgnx-coord--task-label (db task)
  "TASK as `JOB#N title', or nil when there is no such task."
  (when-let* ((row (drgnx-coord--task-row db task))) (format "%s %s" (car row) (nth 2 row))))

(defun drgnx-coord--task-job (db task) (caar (sqlite-select db "select job from jtask where id = ?" (list task))))

;;;; The registry of agents and the user's review marks (schema 5)

(defconst drgnx-coord--agent-cols "id, kind, name, cwd, worktree, branch, base, plan, task, pid, started, seen")

(cl-defun drgnx-coord-agent-register (&key id kind name cwd worktree branch base plan task pid)
  "Note that agent ID works (again): what is given is stored, what is not given is kept, and when it started is kept."
  (drgnx-coord--tx
   (lambda (db)
     (let ((now (float-time)))
       (sqlite-execute db (format "insert into agent (%s) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                   on conflict (id) do update set kind = coalesce(excluded.kind, kind),
                                   name = coalesce(excluded.name, name), cwd = coalesce(excluded.cwd, cwd),
                                   worktree = coalesce(excluded.worktree, worktree), branch = coalesce(excluded.branch, branch),
                                   base = coalesce(excluded.base, base), plan = coalesce(excluded.plan, plan),
                                   task = coalesce(excluded.task, task), pid = coalesce(excluded.pid, pid), seen = excluded.seen"
                                  drgnx-coord--agent-cols)
                       (list id kind name cwd worktree branch base plan task pid now now))
       id))))

(defun drgnx-coord--agent-plist (row)
  (cl-mapcan #'list '(:id :kind :name :cwd :worktree :branch :base :plan :task :pid :started :seen) row))

(defun drgnx-coord-agent (id)
  "Agent ID: (:id :kind :name :cwd :worktree :branch :base :plan :task :pid :started :seen), or nil."
  (when-let* ((row (car (sqlite-select (drgnx-work-db) (format "select %s from agent where id = ?" drgnx-coord--agent-cols)
                                       (list id)))))
    (drgnx-coord--agent-plist row)))

(defun drgnx-coord-agents ()
  "Every registered agent, the first to start first."
  (mapcar #'drgnx-coord--agent-plist
          (sqlite-select (drgnx-work-db) (format "select %s from agent order by started, id" drgnx-coord--agent-cols))))

(defun drgnx-coord-agent-seen (id)
  "Agent ID is alive now: stamp it (nil, and nothing written, when it was never registered).  The stamp."
  (let ((now (float-time)))
    (when (> (sqlite-execute (drgnx-work-db) "update agent set seen = ? where id = ?" (list now id)) 0) now)))

(defun drgnx-coord-review-mark (agent path state hash)
  "Mark AGENT's change to PATH, as it stood at HASH, STATE (\"accepted\" or \"pending\").
A review layer only: nothing in the files changes."
  (unless (member state '("accepted" "pending")) (error "Not a review state: %S" state))
  (sqlite-execute (drgnx-work-db) "insert or replace into review_mark values (?, ?, ?, ?, ?)"
                  (list agent path state hash (float-time)))
  t)

(defun drgnx-coord-review-marks (agent)
  "AGENT's review marks: an alist PATH → (:state :hash :at), by path."
  (mapcar (lambda (r) (cons (car r) (list :state (nth 1 r) :hash (nth 2 r) :at (nth 3 r))))
          (sqlite-select (drgnx-work-db) "select path, state, hash, at from review_mark where agent = ? order by path" (list agent))))

;;;; Jobs and tasks

(cl-defun drgnx-coord-job-create (&key id title plan repo tasks data)
  "Make job ID with TASKS ((:n :title :role :deps (N…))…): those without dependencies ready, the rest pending.  DATA:
a plist kept with it (`drgnx-coord-job')."
  (drgnx-coord--tx
   (lambda (db)
     (sqlite-execute db "insert into job values (?, ?, ?, ?, 'proposed', ?, ?)"
                     (list id title plan repo (float-time) (and data (prin1-to-string data))))
     (dolist (task tasks)
       (let ((tid (format "%s#%d" id (plist-get task :n))))
         (sqlite-execute db "insert into jtask (id, job, n, title, role, status) values (?, ?, ?, ?, ?, ?)"
                         (list tid id (plist-get task :n) (plist-get task :title) (plist-get task :role)
                               (if (plist-get task :deps) "pending" "ready")))
         (dolist (d (plist-get task :deps))
           (sqlite-execute db "insert into jdep values (?, ?)" (list tid (format "%s#%d" id d))))))
     id)))

(defun drgnx-coord-job (id)
  "Job ID: (:id :title :plan :repo :status :created :data PLIST), or nil."
  (pcase (car (sqlite-select (drgnx-work-db) "select id, title, plan, repo, status, created, data from job where id = ?" (list id)))
    ('nil nil)
    (`(,id ,title ,plan ,repo ,status ,created ,data)
     (list :id id :title title :plan plan :repo repo :status status :created created
           :data (and data (car (read-from-string data)))))))

(defun drgnx-coord-jobs (&optional status)
  "Every job's id (with STATUS when given), newest first."
  (mapcar #'car (sqlite-select (drgnx-work-db) (concat "select id from job" (if status " where status = ?" "") " order by created desc")
                               (and status (list status)))))

(cl-defun drgnx-coord-job-set (id &key status data)
  "Change job ID's STATUS and/or DATA (a plist)."
  (when status (sqlite-execute (drgnx-work-db) "update job set status = ? where id = ?" (list status id)))
  (when data (sqlite-execute (drgnx-work-db) "update job set data = ? where id = ?" (list (prin1-to-string data) id))))

(defun drgnx-coord-force-status (task status &optional agent)
  "Set TASK's STATUS (and holder AGENT) as the job engine decides — no holder check; done readies its dependents."
  (drgnx-coord--tx
   (lambda (db)
     (sqlite-execute db "update jtask set status = ?, agent = ?, lease_until = ? where id = ?"
                     (list status agent (and agent (member status drgnx-coord--active) (drgnx-coord--lease)) task))
     (when-let* ((label (drgnx-coord--task-label db task)))
       (drgnx-coord--event db :agent agent :job (drgnx-coord--task-job db task) :task task :kind "status"
                           :summary (format "%s -> %s" label status) :data (list :status status)))
     (when (equal status "done") (drgnx-coord--ready-dependents db task))
     t)))

(defun drgnx-coord--ready-dependents (db task)
  (dolist (waiting (mapcar #'car (sqlite-select db "select task from jdep where dep = ?" (list task))))
    (when (and (equal (nth 4 (drgnx-coord--task-row db waiting)) "pending")
               (seq-every-p (lambda (d) (equal (nth 4 (drgnx-coord--task-row db d)) "done")) (drgnx-coord--deps db waiting)))
      (sqlite-execute db "update jtask set status = 'ready' where id = ?" (list waiting)))))

(defun drgnx-coord--deps (db task)
  (mapcar #'car (sqlite-select db "select dep from jdep where task = ? order by dep" (list task))))

(defun drgnx-coord--task-row (db task)
  (car (sqlite-select db "select id, n, title, role, status, agent, lease_until from jtask where id = ?" (list task))))

(defun drgnx-coord--task-plist (db row)
  (pcase-let ((`(,id ,n ,title ,role ,status ,agent ,lease) row))
    (list :id id :n n :title title :role role :status status :agent agent :lease_until lease
          :deps (drgnx-coord--deps db id))))

(defun drgnx-coord-tasks (job)
  "JOB's tasks, in order: (:id :n :title :role :status :agent :lease_until :deps)."
  (let ((db (drgnx-work-db)))
    (mapcar (lambda (row) (drgnx-coord--task-plist db row))
            (sqlite-select db "select id, n, title, role, status, agent, lease_until from jtask where job = ? order by n"
                           (list job)))))

(defun drgnx-coord-task (task)
  (let ((db (drgnx-work-db))) (when-let* ((row (drgnx-coord--task-row db task))) (drgnx-coord--task-plist db row))))

(defun drgnx-coord--lease () (+ (float-time) (* 60 drgnx-coord-lease-minutes)))

(defun drgnx-coord-claim (task agent seen)
  "AGENT claims TASK, having read the log at version SEEN: (:ok t), (:held …), (:taken AGENT2), (:not-ready DEPS)
or (:error MESSAGE)."
  (drgnx-coord--tx
   (lambda (db)
     (or (drgnx-coord--held db seen)
         (pcase (drgnx-coord--task-row db task)
           ('nil (list :error (format "no task %s" task)))
           (`(,_ ,_ ,_ ,_ ,status ,holder . ,_)
            (cond
             ((and holder (member status drgnx-coord--active) (not (equal holder agent))) (list :taken holder))
             ((equal status "pending")
              (list :not-ready (seq-remove (lambda (d) (equal (nth 4 (drgnx-coord--task-row db d)) "done"))
                                           (drgnx-coord--deps db task))))
             ((or (equal status "ready") (equal holder agent))
              (sqlite-execute db "update jtask set status = (case when status = 'ready' then 'claimed' else status end),
                                    agent = ?, lease_until = ? where id = ?"
                              (list agent (drgnx-coord--lease) task))
              (drgnx-coord--event db :agent agent :job (drgnx-coord--task-job db task) :task task :kind "claim"
                                  :summary (format "claimed %s" (drgnx-coord--task-label db task)))
              (list :ok t))
             (t (list :error (format "task %s is %s" task status))))))))))

(defun drgnx-coord-heartbeat (task agent)
  "AGENT still works on TASK: its lease is renewed."
  (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where id = ? and agent = ?"
                  (list (drgnx-coord--lease) task agent)))

(defun drgnx-coord-renew (agent)
  "AGENT is alive: renew every claim it holds."
  (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where agent = ? and status in ('claimed', 'running')"
                  (list (drgnx-coord--lease) agent)))

(defun drgnx-coord-release-stale ()
  "Release the claims whose lease ran out: ((:task :agent :job)…)."
  (drgnx-coord--tx
   (lambda (db)
     ;; a task waiting on the user (needs-input, in-review) keeps its claim: the wait is the user's, not the agent's
     (let ((rows (sqlite-select db "select id, agent, job from jtask where lease_until < ? and status in ('claimed', 'running')"
                                (list (float-time)))))
       (dolist (r rows)
         (sqlite-execute db "update jtask set status = 'ready', agent = null, lease_until = null where id = ?" (list (car r)))
         (drgnx-coord--event db :agent (cadr r) :job (nth 2 r) :task (car r) :kind "release"
                             :summary (format "lease ran out: %s" (drgnx-coord--task-label db (car r)))))
       (mapcar (lambda (r) (list :task (car r) :agent (cadr r) :job (nth 2 r))) rows)))))

(defun drgnx-coord-set-status (task agent status seen)
  "AGENT (TASK's holder) sets TASK's STATUS, having read the log at SEEN.  Done readies the tasks that waited only on
it.  Answers as `drgnx-coord-claim'."
  (drgnx-coord--tx
   (lambda (db)
     (or (drgnx-coord--held db seen)
         (pcase (drgnx-coord--task-row db task)
           ('nil (list :error (format "no task %s" task)))
           (`(,_ ,_ ,_ ,_ ,_ ,holder . ,_)
            (cond
             ((null holder) (list :error (format "task %s is not claimed (claim it first)" task)))
             ((not (equal holder agent)) (list :taken holder))
             (t
              (sqlite-execute db "update jtask set status = ?, lease_until = ? where id = ?"
                              (list status (and (member status drgnx-coord--active) (drgnx-coord--lease)) task))
              (drgnx-coord--event db :agent agent :job (drgnx-coord--task-job db task) :task task :kind "status"
                                  :summary (format "%s -> %s" (drgnx-coord--task-label db task) status) :data (list :status status))
              (when (equal status "done")
                (dolist (waiting (mapcar #'car (sqlite-select db "select task from jdep where dep = ?" (list task))))
                  (when (and (equal (nth 4 (drgnx-coord--task-row db waiting)) "pending")
                             (seq-every-p (lambda (d) (equal (nth 4 (drgnx-coord--task-row db d)) "done"))
                                          (drgnx-coord--deps db waiting)))
                    (sqlite-execute db "update jtask set status = 'ready' where id = ?" (list waiting)))))
              (list :ok t)))))))))

;;;; The decision log

(defconst drgnx-coord--decision-cols "n, kind, subject, task, paths, reason, author, status, replaces, at, ver, job")

(defun drgnx-coord--decision-plist (row)
  (pcase-let ((`(,n ,kind ,subject ,task ,paths ,reason ,author ,status ,replaces ,at ,ver ,job) row))
    (list :n n :kind kind :subject subject :task task :paths paths :reason reason :author author :status status :job job
          :replaces replaces :at at :ver ver)))

(defun drgnx-coord--decisions-since (db n &optional job)
  (mapcar #'drgnx-coord--decision-plist
          (sqlite-select db (format "select %s from decision where ver > ?%s order by n desc" drgnx-coord--decision-cols
                                    (if job " and job = ?" ""))
                         (if job (list n job) (list n)))))

(defun drgnx-coord-decisions-since (n &optional job)
  "Decisions recorded, or whose status changed, after version N (newest first); JOB's only, when given."
  (drgnx-coord--decisions-since (drgnx-work-db) n job))

(defvar drgnx-coord-decision-rate 6 "Decisions one agent may record per minute; more are refused (no loops).")

(cl-defun drgnx-coord-decide (&key kind subject task paths reason author seen replaces job)
  "Record a decision (KIND build, wait, wont-build or replaces) of JOB by AUTHOR, who read the log at SEEN.  The
user's is current; an agent's is current inside its own claimed TASK, else proposed (for the reviewer and the user)
— and replacing a decision is an agent's own only for its own decision in that same task (the user's always win).
REPLACES (a decision's number) is then marked replaced.  The author is not left behind by its own decision.  More
than `drgnx-coord-decision-rate' a minute from one agent are refused.  (:ok t :n N :status S :version V),
(:held …) or (:error MESSAGE)."
  (drgnx-coord--tx
   (lambda (db)
     (or (drgnx-coord--held db seen)
         (and (not (equal author "user"))
              (>= (caar (sqlite-select db "select count(*) from decision where author = ? and at > ?" (list author (- (float-time) 60))))
                  drgnx-coord-decision-rate)
              (list :error (format "too many decisions in a minute (%d): wait, or ask the user" drgnx-coord-decision-rate)))
         (let* ((own (and task (not (equal author "user"))
                          (pcase (drgnx-coord--task-row db task)
                            (`(,_ ,_ ,_ ,_ ,status ,holder . ,_) (and (equal holder author) (member status drgnx-coord--active))))))
                (replaced (and replaces (car (sqlite-select db "select author, task from decision where n = ?" (list replaces)))))
                (own-replace (or (null replaces) (and replaced (equal (car replaced) author) (equal (cadr replaced) task))))
                (status (if (or (equal author "user") (and own own-replace)) "current" "proposed"))
                (v (drgnx-coord--bump db)))
           (sqlite-execute db "insert into decision (kind, subject, task, paths, reason, author, status, replaces, at, ver, job)
                               values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                           (list kind subject task paths reason author status replaces (float-time) v job))
           (let ((n (caar (sqlite-select db "select last_insert_rowid()"))))   ; before any other insert
             (drgnx-coord--event db :agent author :job job :task task :kind "decision"
                                 :summary (format "#%s %s: %s (%s)" n kind subject status)
                                 :data (list :n n :kind kind :status status :version v))
             (when (and replaces (equal status "current"))
               (sqlite-execute db "update decision set status = 'replaced', ver = ? where n = ?" (list v replaces)))
             ;; its author knows it: not told of it as news (it read the log at SEEN, the one before)
             (when (and author (not (equal author "user")) seen (= seen (1- v)))
               (sqlite-execute db "insert or replace into meta values (?, ?)" (list (concat "seen:" author) (number-to-string v))))
             (list :ok t :n n :status status :version v)))))))

;;;; Messages

(defconst drgnx-coord--message-cols "id, job, sender, recipient, text, state, reason, at, delivered, read, acted")

(defun drgnx-coord--message-plist (row)
  (pcase-let ((`(,id ,job ,sender ,recipient ,text ,state ,reason ,at ,delivered ,read ,acted) row))
    (list :id id :job job :sender sender :recipient recipient :text text :state state :reason reason :at at
          :delivered delivered :read read :acted acted)))

(cl-defun drgnx-coord-send (&key job sender recipient text seen)
  "SENDER (who read the log at SEEN; nil: the user's own Emacs) sends TEXT to RECIPIENT.  (:ok t :id ID :state S) —
held when RECIPIENT's queue is full or the two exchange too much — or (:held …) when SEEN is behind."
  (drgnx-coord--tx
   (lambda (db)
     (or (drgnx-coord--held db seen)
         (let* ((waiting (caar (sqlite-select db "select count(*) from message where recipient = ? and state = 'queued'"
                                              (list recipient))))
                (recent (caar (sqlite-select db "select count(*) from message where coalesce(sender, 'user') = ? and recipient = ? and at > ?"
                                             (list (or sender "user") recipient (- (float-time) 60)))))
                (reason (cond ((and (>= waiting drgnx-coord-queue-limit) (not (equal recipient "user"))) "queue full")
                              ((>= recent drgnx-coord-pair-rate) "too many between these two")))
                (state (if reason "held" "queued")))
           (sqlite-execute db "insert into message (job, sender, recipient, text, state, reason, at) values (?, ?, ?, ?, ?, ?, ?)"
                           (list job sender recipient text state reason (float-time)))
           ;; a reply: what the other side sent this sender is acted on
           (sqlite-execute db "update message set state = 'acted', acted = ? where sender = ? and coalesce(recipient, 'user') = ?
                               and state in ('delivered', 'read')"
                           (list (float-time) recipient (or sender "user")))
           (let ((id (caar (sqlite-select db "select last_insert_rowid()"))))   ; before any other insert
             (drgnx-coord--event db :agent (or sender "user") :job job
                                 :kind (if (and (equal recipient "user") (string-prefix-p "[escalation]" (or text ""))) "question" "message")
                                 :summary (if (equal recipient "user") text (format "to %s: %s" recipient text))
                                 :data (list :message id :to recipient :state state))
             (list :ok t :id id :state state)))))))

(defun drgnx-coord-queued ()
  "Every message waiting to be delivered, oldest first."
  (mapcar #'drgnx-coord--message-plist
          (sqlite-select (drgnx-work-db) (format "select %s from message where state = 'queued' order by id" drgnx-coord--message-cols))))

(defun drgnx-coord-set-seen (agent version)
  "AGENT has read the decision log up to VERSION."
  (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, ?)"
                  (list (concat "seen:" agent) (number-to-string version))))

(defun drgnx-coord-notice (v job changes seen)
  "What an agent of JOB that read the log at SEEN is told of CHANGES (decisions, newest first) — the log at V: the
first five, quoted (an agent's subject never reads as a line from drgnx)."
  (format "[decision log v%d — job %s]\n%s\nCall read_decisions (since %d) before you go on."
          v job (mapconcat (lambda (d) (concat "> " (replace-regexp-in-string "\n" "\n> "
                                                                              (format "#%s %s: %s (%s)" (plist-get d :n) (plist-get d :kind)
                                                                                      (plist-get d :subject) (plist-get d :status)))))
                           (seq-take changes 5) "\n")
          seen))

(defun drgnx-coord-note-held (agent held)
  "AGENT's coordination write was HELD (behind the log) or went through: the count of held writes in a row."
  (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, ?)"
                  (list (concat "held:" agent) (number-to-string (if held (1+ (drgnx-coord-held agent)) 0)))))

(defun drgnx-coord-held (agent)
  "AGENT's coordination writes held in a row (0 when its last went through)."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db) (concat "held:" agent)) "0")))

(defun drgnx-coord-seen (agent)
  "The decision-log version AGENT last read (0 when never)."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db) (concat "seen:" agent)) "0")))

(defun drgnx-coord-inbox (recipient &optional states)
  "RECIPIENT's messages (in STATES when given), oldest first."
  (mapcar #'drgnx-coord--message-plist
          (sqlite-select (drgnx-work-db)
                         (format "select %s from message where recipient = ?%s order by id" drgnx-coord--message-cols
                                 (if states (format " and state in (%s)" (mapconcat (lambda (_) "?") states ", ")) ""))
                         (cons recipient states))))

(defun drgnx-coord-message (id)
  (when-let* ((row (car (sqlite-select (drgnx-work-db) (format "select %s from message where id = ?" drgnx-coord--message-cols)
                                       (list id)))))
    (drgnx-coord--message-plist row)))

(defun drgnx-coord-mark (id state)
  "Move message ID on to STATE (delivered, read or acted), stamping when; never back, never a held one."
  (let ((col (pcase state ("delivered" "delivered") ("read" "read") ("acted" "acted")
                    (_ (error "Not a message state: %s" state)))))
    (drgnx-coord--tx
     (lambda (db)
       (let* ((cur (caar (sqlite-select db "select state from message where id = ?" (list id))))
              (pos (seq-position drgnx-coord--states cur)))
         (when (and pos (> (seq-position drgnx-coord--states state) pos))
           (sqlite-execute db (format "update message set state = ?, %s = ? where id = ?" col) (list state (float-time) id))
           t))))))

;;;; Cards: what needs the user, until they act on it

(defconst drgnx-coord--card-cols "id, job, task, kind, title, data, state, at, settled_at, choice")

(defun drgnx-coord--card-plist (row)
  (pcase-let ((`(,id ,job ,task ,kind ,title ,data ,state ,at ,settled ,choice) row))
    (list :id id :job job :task task :kind kind :title title :data (and data (car (read-from-string data)))
          :state state :at at :settled settled :choice choice)))

(defun drgnx-coord--print (v) (let ((print-length nil) (print-level nil)) (prin1-to-string v)))

(cl-defun drgnx-coord-card-create (&key job task kind title data)
  "A new open card of JOB (and TASK): its id."
  (drgnx-coord--tx
   (lambda (db)
     (sqlite-execute db "insert into card (job, task, kind, title, data, state, at) values (?, ?, ?, ?, ?, 'open', ?)"
                     (list job task kind title (and data (drgnx-coord--print data)) (float-time)))
     (let ((id (caar (sqlite-select db "select last_insert_rowid()"))))
       (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s" kind title)
                           :data (list :card id :state "open"))
       id))))

(defun drgnx-coord-cards (job &optional state)
  "JOB's cards (in STATE when given), newest first."
  (mapcar #'drgnx-coord--card-plist
          (sqlite-select (drgnx-work-db) (format "select %s from card where job = ?%s order by id desc" drgnx-coord--card-cols
                                                 (if state " and state = ?" ""))
                         (if state (list job state) (list job)))))

(defun drgnx-coord-card (id)
  (when-let* ((row (car (sqlite-select (drgnx-work-db) (format "select %s from card where id = ?" drgnx-coord--card-cols) (list id)))))
    (drgnx-coord--card-plist row)))

(defun drgnx-coord-card-settle (id choice)
  "Settle open card ID with CHOICE: t, or nil when it was not open (acted on already: nothing happens twice)."
  (drgnx-coord--tx
   (lambda (db)
     (when (> (sqlite-execute db "update card set state = 'settled', settled_at = ?, choice = ? where id = ? and state = 'open'"
                              (list (float-time) choice id))
              0)
       (pcase-let ((`(,job ,task ,kind ,title) (car (sqlite-select db "select job, task, kind, title from card where id = ?" (list id)))))
         (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s -> %s" kind title choice)
                             :data (list :card id :state "settled" :choice choice)))
       t))))

(cl-defun drgnx-coord-card-set (id &key title data state)
  "Change card ID's TITLE, DATA (a plist) and/or STATE."
  (let ((db (drgnx-work-db)))
    (when title (sqlite-execute db "update card set title = ? where id = ?" (list title id)))
    (when data (sqlite-execute db "update card set data = ? where id = ?" (list (drgnx-coord--print data) id)))
    (when state (sqlite-execute db "update card set state = ? where id = ?" (list state id)))))

(provide 'drgnx-coord)
;;; drgnx-coord.el ends here
