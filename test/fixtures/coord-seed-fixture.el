;;; coord-seed-fixture.el --- test tooling: seed work.db's coordination rows as the hub writes them -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The coordination writers' local path, kept for tests only: it seeds work.db with the rows the hub writes (jobs and
;; their tasks, the decision log, messages, cards, events, the agent registry, review marks) and reads back what the
;; seeding changed (inbox, queued, tasks, cards, ...).  The product's writer is Ratatoskr; the readers the product uses
;; are in core/drgnx-coord-read.el.
;;
;; Every write goes through the read-write handle `drgnx-work-db', which opens only where
;; `drgnx-work-db-gate-hub-standin' is bound: run the writers inside `drgnx-work-fixture-as-hub'
;; (test/fixtures/work-fixture.el).  Nothing here is product code, and no product code may call it.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-db)
(require 'drgnx-coord-read)

(defvar drgnx-coord-lease-minutes 15 "A claim not renewed for this long is released.")
(defvar drgnx-coord-queue-limit 20 "Undelivered messages an agent may have waiting; more are held.")
(defvar drgnx-coord-pair-rate 6 "Messages from one agent to another per minute; more are held (no chatty loops).")
(defvar drgnx-coord-decision-rate 6 "Decisions one agent may record per minute; more are refused (no loops).")

(defconst drgnx-coord--states '("queued" "delivered" "read" "acted") "Message states, in order (held stands apart).")
(defconst drgnx-coord--active '("claimed" "running" "needs-input" "in-review") "Task statuses that belong to an agent.")

(defconst drgnx-coord-event-kinds
  '("start" "stop" "claim" "release" "status" "decision" "edit" "test" "question" "answer" "review" "message" "card"
    "accept" "revert" "comment" "job" "task")
  "What an event can be.")

(defconst drgnx-coord--summary-max 200 "The longest event summary, in characters.")
(defconst drgnx-coord--data-max 4096 "The longest printed event data, in characters; more is stored as (:truncated t :size N).")

(defun drgnx-coord--tx (fn)
  "FN in one immediate transaction on the read-write handle (which only the hub's stand-in may open)."
  (let ((db (drgnx-work-db)))
    (sqlite-execute db "begin immediate")
    (condition-case err (prog1 (funcall fn db) (sqlite-execute db "commit"))
      (error (ignore-errors (sqlite-execute db "rollback")) (signal (car err) (cdr err))))))

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

;;;; Events

(defun drgnx-coord--one-line (text)
  "TEXT as one line of at most `drgnx-coord--summary-max' characters (`drgnx-coord-control-chars' become spaces)."
  (let ((line (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]") " " (format "%s" (or text "")))))
    (if (> (length line) drgnx-coord--summary-max) (substring line 0 drgnx-coord--summary-max) line)))

(defun drgnx-coord--encode (schema data)
  "DATA, a plist, as JSON text for record SCHEMA.  A key given twice (a plist built by `append') keeps its first value,
as `plist-get' reads it."
  (let ((seen nil) (out nil))
    (cl-loop for (k v) on data by #'cddr
             unless (memq k seen) do (push k seen) (push k out) (push v out))
    (drgnx-records-encode schema (if (proper-list-p data) (nreverse out) data))))

(defun drgnx-coord--data-print (data)
  "DATA, a plist, as JSON text; over `drgnx-coord--data-max' characters it is {\"truncated\":true,\"size\":N} instead."
  (unless (and (proper-list-p data) (cl-evenp (length data)) (cl-loop for (k) on data by #'cddr always (keywordp k)))
    (error "Event data must be a plist: %S" data))
  (let ((text (drgnx-coord--encode 'drgnx-records-event-data data)))
    (if (> (length text) drgnx-coord--data-max)
        (drgnx-records-encode 'drgnx-records-event-data (list :truncated t :size (length text)))
      text)))

(cl-defun drgnx-coord--event (db &key agent job task kind summary data at)
  "Insert one event through DB, inside the caller's transaction: its id."
  (unless (member kind drgnx-coord-event-kinds) (error "Not an event kind: %S" kind))
  (sqlite-execute db "insert into event (at, agent, job, task, kind, summary, data, turn) values (?, ?, ?, ?, ?, ?, ?, ?)"
                  (list (float (or at (float-time))) agent job task kind (drgnx-coord--one-line summary)
                        (and data (drgnx-coord--data-print data))
                        (and (member kind '("start" "stop")) (eq (plist-get data :turn) t) 1)))
  (caar (sqlite-select db "select last_insert_rowid()")))

(cl-defun drgnx-coord-event-add (&key agent job task kind summary data at)
  "Record an event of KIND (one of `drgnx-coord-event-kinds') by AGENT (JOB, TASK) at AT (now): its id."
  (drgnx-coord--tx
   (lambda (db) (drgnx-coord--event db :agent agent :job job :task task :kind kind :summary summary :data data :at at))))

(defun drgnx-coord--task-label (db task)
  "TASK as `JOB#N title', or nil when there is no such task."
  (when-let* ((row (drgnx-coord--task-row db task))) (format "%s %s" (car row) (nth 2 row))))

(defun drgnx-coord--task-job (db task) (caar (sqlite-select db "select job from jtask where id = ?" (list task))))

;;;; The registry of agents and the user's review marks

(cl-defun drgnx-coord-agent-register (&key id kind name cwd worktree branch base plan task pid clear)
  "Note that agent ID works (again): what is given is stored, what is not given is kept, and when it started is kept.
CLEAR is a list of fields (:kind :name :cwd :worktree :branch :base :plan :task :pid) to set to NULL."
  (unless id (error "An agent needs an id"))
  (dolist (f clear)
    (unless (memq f '(:kind :name :cwd :worktree :branch :base :plan :task :pid)) (error "Cannot clear agent field %S" f)))
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
       (dolist (f clear)
         (sqlite-execute db (format "update agent set %s = null where id = ?" (substring (symbol-name f) 1)) (list id)))
       id))))

(defun drgnx-coord-review-mark (agent path state hash)
  "Mark AGENT's change to PATH, as it stood at HASH, STATE (\"accepted\" or \"pending\")."
  (unless (member state '("accepted" "pending")) (error "Not a review state: %S" state))
  (sqlite-execute (drgnx-work-db) "insert or replace into review_mark values (?, ?, ?, ?, ?)"
                  (list agent path state hash (float-time)))
  t)

;;;; Jobs and tasks

(cl-defun drgnx-coord-job-create (&key id title plan repo tasks data)
  "Make job ID with TASKS ((:n :title :role :deps (N…))…): those without dependencies ready, the rest pending.  DATA:
a plist kept with it (`drgnx-coord-job')."
  (drgnx-coord--tx
   (lambda (db)
     (sqlite-execute db "insert into job values (?, ?, ?, ?, 'proposed', ?, ?)"
                     (list id title plan repo (float-time) (and data (drgnx-coord--encode 'drgnx-records-job-data data))))
     (dolist (task tasks)
       (let ((tid (format "%s#%d" id (plist-get task :n))))
         (sqlite-execute db "insert into jtask (id, job, n, title, role, status) values (?, ?, ?, ?, ?, ?)"
                         (list tid id (plist-get task :n) (plist-get task :title) (plist-get task :role)
                               (if (plist-get task :deps) "pending" "ready")))
         (dolist (d (plist-get task :deps))
           (sqlite-execute db "insert into jdep values (?, ?)" (list tid (format "%s#%d" id d))))))
     id)))

(defun drgnx-coord-jobs (&optional status)
  "Every job's id (with STATUS when given), newest first."
  (mapcar #'car (sqlite-select (drgnx-work-db-read) (concat "select id from job" (if status " where status = ?" "") " order by created desc")
                               (and status (list status)))))

(cl-defun drgnx-coord-job-set (id &key status data)
  "Change job ID's STATUS and/or DATA (a plist).  A change of STATUS leaves a `job' event."
  (drgnx-coord--tx
   (lambda (db)
     (when status
       (let ((old (caar (sqlite-select db "select status from job where id = ?" (list id)))))
         (sqlite-execute db "update job set status = ? where id = ?" (list status id))
         (when (and old (not (equal old status)))
           (drgnx-coord--event db :job id :kind "job" :summary (format "job %s: %s -> %s" id old status)
                               :data (list :status status)))))
     (when data (sqlite-execute db "update job set data = ? where id = ?" (list (drgnx-coord--encode 'drgnx-records-job-data data) id)))
     nil)))

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
  (let ((db (drgnx-work-db-read)))
    (mapcar (lambda (row) (drgnx-coord--task-plist db row))
            (sqlite-select db "select id, n, title, role, status, agent, lease_until from jtask where job = ? order by n"
                           (list job)))))

(defun drgnx-coord-task (task)
  (let ((db (drgnx-work-db-read))) (when-let* ((row (drgnx-coord--task-row db task))) (drgnx-coord--task-plist db row))))

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
              (when (equal status "ready")          ; a renewal by the holder changes nothing: no event
                (drgnx-coord--event db :agent agent :job (drgnx-coord--task-job db task) :task task :kind "claim"
                                    :summary (format "claimed %s" (drgnx-coord--task-label db task))))
              (list :ok t))
             (t (list :error (format "task %s is %s" task status))))))))))

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
              (when (equal status "done") (drgnx-coord--ready-dependents db task))
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
  (drgnx-coord--decisions-since (drgnx-work-db-read) n job))

(cl-defun drgnx-coord-decide (&key kind subject task paths reason author seen replaces job)
  "Record a decision (KIND build, wait, wont-build or replaces) of JOB by AUTHOR, who read the log at SEEN.  The
user's is current; an agent's is current inside its own claimed TASK, else proposed.  REPLACES (a decision's number)
is then marked replaced.  (:ok t :n N :status S :version V), (:held …) or (:error MESSAGE)."
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

(cl-defun drgnx-coord-send (&key job sender recipient text seen question answers)
  "SENDER (who read the log at SEEN; nil: the user's own Emacs) sends TEXT to RECIPIENT.  (:ok t :id ID :state S) —
held when RECIPIENT's queue is full or the two exchange too much — or (:held …) when SEEN is behind.
A message to \"user\" is a question (its event's kind) when QUESTION is set, or when its TEXT starts with [escalation]
and SENDER is not an agent outside drgnx (ext:…).  ANSWERS is the id of the message this one answers."
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
           (sqlite-execute db "insert into message (job, sender, recipient, text, state, reason, at, answers) values (?, ?, ?, ?, ?, ?, ?, ?)"
                           (list job sender recipient text state reason (float-time) (and (natnump answers) answers)))
           ;; a reply: what the other side sent this sender is acted on
           (sqlite-execute db "update message set state = 'acted', acted = ? where sender = ? and coalesce(recipient, 'user') = ?
                               and state in ('delivered', 'read')"
                           (list (float-time) recipient (or sender "user")))
           (let ((id (caar (sqlite-select db "select last_insert_rowid()"))))   ; before any other insert
             (drgnx-coord--event db :agent (or sender "user") :job job
                                 :kind (if (and (equal recipient "user")
                                                (or question (and (not (string-prefix-p "ext:" (or sender "")))
                                                                  (string-prefix-p "[escalation]" (or text "")))))
                                           "question" "message")
                                 :summary (if (equal recipient "user") text (format "to %s: %s" recipient text))
                                 :data (append (list :message id :to recipient :state state)
                                               (and (natnump answers) (list :answers answers))))
             (list :ok t :id id :state state)))))))

(defun drgnx-coord-queued ()
  "Every message waiting to be delivered, oldest first."
  (mapcar #'drgnx-coord--message-plist
          (sqlite-select (drgnx-work-db-read) (format "select %s from message where state = 'queued' order by id" drgnx-coord--message-cols))))

(defun drgnx-coord-held (agent)
  "AGENT's coordination writes held in a row (0 when its last went through)."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db-read) (concat "held:" agent)) "0")))

(defun drgnx-coord-seen (agent)
  "The decision-log version AGENT last read (0 when never)."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db-read) (concat "seen:" agent)) "0")))

(defun drgnx-coord-inbox (recipient &optional states)
  "RECIPIENT's messages (in STATES when given), oldest first."
  (mapcar #'drgnx-coord--message-plist
          (sqlite-select (drgnx-work-db-read)
                         (format "select %s from message where recipient = ?%s order by id" drgnx-coord--message-cols
                                 (if states (format " and state in (%s)" (mapconcat (lambda (_) "?") states ", ")) ""))
                         (cons recipient states))))

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
    (list :id id :job job :task task :kind kind :title title :data (drgnx-work-db-decode 'drgnx-records-card-data data)
          :state state :at at :settled settled :choice choice)))

(cl-defun drgnx-coord-card-create (&key job task kind title data)
  "A new open card of JOB (and TASK): its id."
  (drgnx-coord--tx
   (lambda (db)
     (sqlite-execute db "insert into card (job, task, kind, title, data, state, at) values (?, ?, ?, ?, ?, 'open', ?)"
                     (list job task kind title (and data (drgnx-coord--encode 'drgnx-records-card-data data)) (float-time)))
     (let ((id (caar (sqlite-select db "select last_insert_rowid()"))))
       ;; an ask card is a question to the user: settling it answers; the card's `ref' is that question's event
       (if (equal kind "ask")
           (let ((q (drgnx-coord--event db :job job :task task :kind "question" :summary (format "%s: %s" kind title) :data (list :card id))))
             (sqlite-execute db "update card set ref = ? where id = ?" (list q id)))
         (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s" kind title)
                             :data (list :card id :state "open")))
       id))))

(defun drgnx-coord-cards (job &optional state)
  "JOB's cards (in STATE when given), newest first."
  (mapcar #'drgnx-coord--card-plist
          (sqlite-select (drgnx-work-db-read) (format "select %s from card where job = ?%s order by id desc" drgnx-coord--card-cols
                                                      (if state " and state = ?" ""))
                         (if state (list job state) (list job)))))

(defun drgnx-coord-card (id)
  (when-let* ((row (car (sqlite-select (drgnx-work-db-read) (format "select %s from card where id = ?" drgnx-coord--card-cols) (list id)))))
    (drgnx-coord--card-plist row)))

(defun drgnx-coord-card-settle (id choice)
  "Settle open card ID with CHOICE: t, or nil when it was not open (acted on already: nothing happens twice)."
  (drgnx-coord--tx
   (lambda (db)
     (when (> (sqlite-execute db "update card set state = 'settled', settled_at = ?, choice = ? where id = ? and state = 'open'"
                              (list (float-time) choice id))
              0)
       (pcase-let ((`(,job ,task ,kind ,title) (car (sqlite-select db "select job, task, kind, title from card where id = ?" (list id)))))
         (if-let* ((q (and (equal kind "ask") (caar (sqlite-select db "select ref from card where id = ?" (list id))))))
             (drgnx-coord--event db :agent "user" :job job :task task :kind "answer" :summary (format "%s: %s -> %s" kind title choice)
                                 :data (list :question q))
           (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s -> %s" kind title choice)
                               :data (list :card id :state "settled" :choice (format "%s" choice)))))
       t))))

(cl-defun drgnx-coord-card-set (id &key title data state)
  "Change card ID's TITLE, DATA (a plist) and/or STATE.  A change of STATE (a reopened card) leaves a `card' event."
  (drgnx-coord--tx
   (lambda (db)
     (when title (sqlite-execute db "update card set title = ? where id = ?" (list title id)))
     (when data (sqlite-execute db "update card set data = ? where id = ?" (list (drgnx-coord--encode 'drgnx-records-card-data data) id)))
     (when state
       (pcase-let ((`(,old ,job ,task ,kind ,ctitle) (car (sqlite-select db "select state, job, task, kind, title from card where id = ?" (list id)))))
         (when (and old (not (equal old state)))
           (sqlite-execute db "update card set state = ? where id = ?" (list state id))
           (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s -> %s" kind ctitle state)
                               :data (list :card id :state state)))))
     nil)))

(provide 'coord-seed-fixture)
;;; coord-seed-fixture.el ends here
