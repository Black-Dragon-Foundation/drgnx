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

(defvar drgnx-coord-writer 'refuse
  "Who writes work.db's coordination and job tables from this Emacs (one writer per table: Ratatoskr):
- `refuse' (the default: every editor, the CLI, a coordination server): every public writer signals \"coordination
  writes go through the drgnx hub (Ratatoskr)\" — an editor asks the hub (`drgnx-hub-call');
- `front' (the Lisp backend behind Ratatoskr, `drgnx-hub-main'): each writer is the front's method, called and waited
  for (`drgnx-hub-call-front'), and answers what it answered when it wrote here;
- `local' (the standalone Lisp hub: the v0 rows, its tests; unit tests that set up coordination data): written here.
`drgnx-coord--tx' signals unless it is `local', and so does `drgnx-work-db' (the read-write handle): every other
Emacs reads through `drgnx-work-db-read'.  See docs/develop/coordination.md, \"Who writes what\" and \"Who opens
work.db\".")

(declare-function drgnx-hub-call-front "drgnx-hub-client")

(defun drgnx-coord--writer ()
  "`drgnx-coord-writer' when it is `local' or `front'; for anything else an error: this Emacs writes nothing."
  (if (memq drgnx-coord-writer '(local front)) drgnx-coord-writer
    (error "coordination writes go through the drgnx hub (Ratatoskr)")))

(defun drgnx-coord--some (&rest plist)
  "PLIST without its nil values (an absent key: the front's params say none)."
  (cl-loop for (k v) on plist by #'cddr when v append (list k v)))

(defun drgnx-coord--front (method &rest params)
  "The front's METHOD with PARAMS (a plist; nil values left out), waited for (`drgnx-hub-call-front'): its result,
decoded.  The front's refusal is an `error' with its text, as the Lisp writer's was."
  (require 'drgnx-hub-client)
  (condition-case err (drgnx-hub-call-front method (apply #'drgnx-coord--some params))
    (drgnx-hub-front-error (error "%s" (plist-get (cdr err) :message)))))

(defun drgnx-coord--front-json (schema data)
  "DATA, a plist, as the JSON object record SCHEMA makes of it (`drgnx-coord--encode': checked here), for the front."
  (and data (json-parse-string (drgnx-coord--encode schema data) :object-type 'hash-table :null-object :null
                               :false-object :false)))

(defun drgnx-coord--front-held (r)
  "The front's held answer R as `drgnx-coord--held' has it: (:held t :version V :changes DECISIONS)."
  (list :held t :version (plist-get r :version)
        :changes (mapcar (lambda (d) (cl-loop for k in '(:n :kind :subject :task :paths :reason :author :status :job
                                                            :replaces :at :ver)
                                              append (list k (plist-get d k))))
                         (plist-get r :changes))))

(defun drgnx-coord--unserved (name)
  "NAME has no method on the front: behind it, an error (the coordination tools write it in Ratatoskr)."
  (error "%s has no front method: the coordination tools write it in Ratatoskr" name))

(defun drgnx-coord--tx (fn)
  "FN in one immediate transaction (the write lock first: read-check-write never interleaves).  Only where
`drgnx-coord-writer' is `local': anywhere else a local write would be a second writer."
  (unless (eq drgnx-coord-writer 'local) (error "coordination writes go through the drgnx hub (Ratatoskr)"))
  (let ((db (drgnx-work-db)))
    (sqlite-execute db "begin immediate")
    (condition-case err (prog1 (funcall fn db) (sqlite-execute db "commit"))
      (error (ignore-errors (sqlite-execute db "rollback")) (signal (car err) (cdr err))))))

(defun drgnx-coord--meta (db key) (caar (sqlite-select db "select value from meta where key = ?" (list key))))

(defun drgnx-coord-version ()
  "The decision log's version."
  (string-to-number (or (drgnx-coord--meta (drgnx-work-db-read) "log-version") "0")))

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
    "accept" "revert" "comment" "job" "task")
  "What an event can be.  `task' is the hub's tracker operations (schema 7).")

(defconst drgnx-coord--summary-max 200 "The longest event summary, in characters.")

(defconst drgnx-coord-control-chars (concat "\0-\37\177-" (string #x9f #x61c #x200e #x200f #x202a ?- #x202e #x2066 ?- #x2069
                                                                  #x2028 #x2029))
  "Characters an agent's text must not carry, as the inside of a regexp bracket: the C0 controls, DEL, the C1
controls, the BiDi controls (the Arabic letter mark, marks, embeddings, overrides, isolates) that make text
read other than it is, and the line and paragraph separators (U+2028, U+2029) that start a line a reader sees.")

(defun drgnx-coord--one-line (text)
  "TEXT as one line of at most `drgnx-coord--summary-max' characters (`drgnx-coord-control-chars' become spaces)."
  (let ((line (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]") " " (format "%s" (or text "")))))
    (if (> (length line) drgnx-coord--summary-max) (substring line 0 drgnx-coord--summary-max) line)))

(defconst drgnx-coord--data-max 4096 "The longest printed event data, in characters; more is stored as (:truncated t :size N).")

(defcustom drgnx-coord-event-retention-days 30
  "Days an event is kept; `drgnx-coord-events-prune' forgets older ones, except questions, answers and decisions."
  :type 'number :group 'drgnx)

(defcustom drgnx-coord-event-max-rows 100000
  "The most events the log keeps between its daily prunes: `drgnx-coord-events-prune-daily' (each hub housekeeping,
every minute) forgets the oldest past it, questions, answers and decisions apart."
  :type 'natnum :group 'drgnx)

(defun drgnx-coord--encode (schema data)
  "DATA, a plist, as JSON text for record SCHEMA.  A key given twice (a plist built by `append') keeps its first value,
as `plist-get' reads it."
  (let ((seen nil) (out nil))
    (cl-loop for (k v) on data by #'cddr
             unless (memq k seen) do (push k seen) (push k out) (push v out))
    (drgnx-records-encode schema (if (proper-list-p data) (nreverse out) data))))

(defun drgnx-coord--data-print (data)
  "DATA, a plist of strings, numbers, t and nested plists and lists of those (and the enum symbols of
`drgnx-records-event-data'), as JSON text; an error for anything else.  Over `drgnx-coord--data-max' characters it is
{\"truncated\":true,\"size\":N} instead."
  (unless (and (proper-list-p data) (cl-evenp (length data)) (cl-loop for (k) on data by #'cddr always (keywordp k)))
    (error "Event data must be a plist: %S" data))
  (let ((text (drgnx-coord--encode 'drgnx-records-event-data data)))
    (if (> (length text) drgnx-coord--data-max)
        (drgnx-records-encode 'drgnx-records-event-data (list :truncated t :size (length text)))
      text)))

(cl-defun drgnx-coord--event (db &key agent job task kind summary data at)
  "Insert one event through DB, inside the caller's transaction: its id.
DATA is checked and stored small, as JSON (read back by `drgnx-coord-events').  A turn's start and stop (DATA has
`:turn' t) set the `turn' column."
  (unless (member kind drgnx-coord-event-kinds) (error "Not an event kind: %S" kind))
  (sqlite-execute db "insert into event (at, agent, job, task, kind, summary, data, turn) values (?, ?, ?, ?, ?, ?, ?, ?)"
                  (list (float (or at (float-time))) agent job task kind (drgnx-coord--one-line summary)
                        (and data (drgnx-coord--data-print data))
                        (and (member kind '("start" "stop")) (eq (plist-get data :turn) t) 1)))
  (caar (sqlite-select db "select last_insert_rowid()")))

(defun drgnx-coord--busy-p (err)
  "Whether ERR is SQLite saying the database is locked or busy (another writer held it past the busy timeout)."
  (let ((conds (get (car err) 'error-conditions)))
    (or (memq 'sqlite-locked-error conds)
        (and (memq 'sqlite-error conds) (string-match-p "\\<\\(locked\\|busy\\)\\>" (error-message-string err))))))

(defun drgnx-coord--best-effort (thunk)
  "Call THUNK; nil, not an error, when the database stays locked or busy."
  (condition-case err (funcall thunk)
    (error (unless (drgnx-coord--busy-p err) (signal (car err) (cdr err))))))

(cl-defun drgnx-coord-event-add (&key agent job task kind summary data at)
  "Record an event of KIND (one of `drgnx-coord-event-kinds') by AGENT (JOB, TASK) at AT (now): its id.
SUMMARY is cut to one line of at most 200 characters.  DATA is small, readable data: a plist of strings, numbers,
nested plists and lists of those (a symbol only where `drgnx-records-event-data' has an enum; anything else is an
error), stored as JSON of at most 4096 characters (else (:truncated t :size N)).
A locked database signals (after the busy timeout); see `drgnx-coord-event-add-best-effort'.
Behind the front (`drgnx-coord-writer') it is `events/add', KIND and DATA checked here first; AT is the front's clock."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front-event nil agent job task kind summary data))
    (_ (drgnx-coord--tx
        (lambda (db) (drgnx-coord--event db :agent agent :job job :task task :kind kind :summary summary :data data :at at))))))

(cl-defun drgnx-coord-event-add-best-effort (&key agent job task kind summary data at)
  "As `drgnx-coord-event-add', but nil — not an error — when the database stays locked or busy: for telemetry (edits,
test runs) that must never fail the work it describes.  A bad KIND or DATA still signals."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front-event t agent job task kind summary data))
    (_ (drgnx-coord--best-effort
        (lambda () (drgnx-coord-event-add :agent agent :job job :task task :kind kind :summary summary :data data :at at))))))

(defun drgnx-coord--front-event (best-effort agent job task kind summary data)
  "`events/add' of an event checked here as `drgnx-coord--event' checks it: its id (nil when BEST-EFFORT met a busy
work.db).  The summary goes as its one line (the front cuts it the same way)."
  (unless (member kind drgnx-coord-event-kinds) (error "Not an event kind: %S" kind))
  (plist-get (drgnx-coord--front "events/add" :kind kind :agent agent :job job :task task
                                 :summary (and summary (drgnx-coord--one-line summary))
                                 :data (and data (json-parse-string (drgnx-coord--data-print data) :object-type 'hash-table
                                                                    :null-object :null :false-object :false))
                                 :best_effort (and best-effort t))
             :id))

(cl-defun drgnx-coord-events-prune (&key before)
  "Forget the events older than BEFORE (seconds since the epoch, as `float-time' gives; default
`drgnx-coord-event-retention-days' ago), except questions, answers and decisions: how many.  Behind the front there is
none: the front prunes daily (`drgnx-coord-events-prune-daily')."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--unserved "drgnx-coord-events-prune"))
    (_ (let ((cut (or before (- (float-time) (* 86400 drgnx-coord-event-retention-days)))))
         (drgnx-coord--tx
          (lambda (db)
            (sqlite-execute db "delete from event where at < ? and kind not in ('question', 'answer', 'decision')" (list (float cut)))))))))

(defun drgnx-coord--events-cap (db)
  "Forget the oldest events past `drgnx-coord-event-max-rows', questions, answers and decisions apart."
  (let ((n (caar (sqlite-select db "select count(*) from event"))))
    (when (> n drgnx-coord-event-max-rows)
      (sqlite-execute db "delete from event where id in (select id from event where kind not in ('question', 'answer', 'decision')
                                                        order by id limit ?)"
                      (list (- n drgnx-coord-event-max-rows))))))

(defun drgnx-coord-events-prune-daily ()
  "`drgnx-coord-events-prune' unless it ran in the last 24 hours: t when it ran.  On every call the log is held to
`drgnx-coord-event-max-rows' too, the oldest going first.  Never signals — a locked database waits for the next call,
any other error is a message — for a periodic tick (the hub's).  Behind the front it is `coord/prune'."
  (condition-case err
      (pcase (drgnx-coord--writer)
        ('front (plist-get (drgnx-coord--front "coord/prune") :pruned))
        (_ (prog1 (when (> (- (float-time) (string-to-number (or (drgnx-coord--meta (drgnx-work-db) "event-pruned") "0"))) 86400)
                    (drgnx-coord-events-prune)
                    (sqlite-execute (drgnx-work-db) "insert or replace into meta values ('event-pruned', ?)" (list (number-to-string (float-time))))
                    t)
             (drgnx-coord--tx #'drgnx-coord--events-cap))))
    (error (unless (drgnx-coord--busy-p err) (message "drgnx coord: pruning events: %s" (error-message-string err)))
           nil)))

(defconst drgnx-coord--event-cols "id, at, agent, job, task, kind, summary, data")

(defun drgnx-coord--event-plist (row)
  (pcase-let ((`(,id ,at ,agent ,job ,task ,kind ,summary ,data) row))
    (list :id id :at at :agent agent :job job :task task :kind kind :summary summary
          :data (drgnx-work-db-decode 'drgnx-records-event-data data))))

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
            (sqlite-select (drgnx-work-db-read)
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

(cl-defun drgnx-coord-agent-register (&key id kind name cwd worktree branch base plan task pid clear)
  "Note that agent ID works (again): what is given is stored, what is not given is kept, and when it started is kept.
CLEAR is a list of fields (:kind :name :cwd :worktree :branch :base :plan :task :pid) to set to NULL — nil, as an
omitted field, means \"keep\".  A nil ID is an error."
  (unless id (error "An agent needs an id"))
  (dolist (f clear)
    (unless (memq f '(:kind :name :cwd :worktree :branch :base :plan :task :pid)) (error "Cannot clear agent field %S" f)))
  (pcase (drgnx-coord--writer)
    ('front (plist-get (drgnx-coord--front "coord/agent"
                                           :register (drgnx-coord--some :id id :kind kind :name name :cwd cwd :worktree worktree
                                                                        :branch branch :base base :plan plan :task task :pid pid
                                                                        :clear (mapcar (lambda (f) (substring (symbol-name f) 1)) clear)))
                       :id))
    (_ (drgnx-coord--tx
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
            id))))))

(defun drgnx-coord--agent-plist (row)
  (cl-mapcan #'list '(:id :kind :name :cwd :worktree :branch :base :plan :task :pid :started :seen) row))

(defun drgnx-coord-agent (id)
  "Agent ID: (:id :kind :name :cwd :worktree :branch :base :plan :task :pid :started :seen), or nil."
  (when-let* ((row (car (sqlite-select (drgnx-work-db-read) (format "select %s from agent where id = ?" drgnx-coord--agent-cols)
                                       (list id)))))
    (drgnx-coord--agent-plist row)))

(defun drgnx-coord-agents ()
  "Every registered agent, the first to start first."
  (mapcar #'drgnx-coord--agent-plist
          (sqlite-select (drgnx-work-db-read) (format "select %s from agent order by started, id" drgnx-coord--agent-cols))))

(defun drgnx-coord-agent-seen (id)
  "Agent ID is alive now: stamp it (nil, and nothing written, when it was never registered).  The stamp.  Telemetry:
nil as well, never an error, when the database stays locked or busy."
  (pcase (drgnx-coord--writer)
    ('front (plist-get (drgnx-coord--front "coord/agent" :seen id) :seen))
    (_ (drgnx-coord--best-effort
        (lambda ()
          (let ((now (float-time)))
            (drgnx-coord--tx
             (lambda (db) (when (> (sqlite-execute db "update agent set seen = ? where id = ?" (list now id)) 0) now)))))))))

(defun drgnx-coord-review-mark (agent path state hash)
  "Mark AGENT's change to PATH, as it stood at HASH, STATE (\"accepted\" or \"pending\").
A review layer only: nothing in the files changes."
  (unless (member state '("accepted" "pending")) (error "Not a review state: %S" state))
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front "review/mark" :agent agent :path path :state state :hash hash))
    (_ (sqlite-execute (drgnx-work-db) "insert or replace into review_mark values (?, ?, ?, ?, ?)"
                       (list agent path state hash (float-time)))))
  t)

(defun drgnx-coord-review-marks (agent)
  "AGENT's review marks: an alist PATH → (:state :hash :at), by path."
  (mapcar (lambda (r) (cons (car r) (list :state (nth 1 r) :hash (nth 2 r) :at (nth 3 r))))
          (sqlite-select (drgnx-work-db-read) "select path, state, hash, at from review_mark where agent = ? order by path" (list agent))))

;;;; Jobs and tasks

(cl-defun drgnx-coord-job-create (&key id title plan repo tasks data)
  "Make job ID with TASKS ((:n :title :role :deps (N…))…): those without dependencies ready, the rest pending.  DATA:
a plist kept with it (`drgnx-coord-job')."
  (pcase (drgnx-coord--writer)
    ('front (plist-get (drgnx-coord--front "coord/job-create" :id id :title title :plan plan :repo repo
                                           :tasks (mapcar (lambda (task)
                                                            (drgnx-coord--some :n (plist-get task :n) :title (plist-get task :title)
                                                                               :role (plist-get task :role) :deps (plist-get task :deps)))
                                                          tasks)
                                           :data (drgnx-coord--front-json 'drgnx-records-job-data data))
                       :id))
    (_ (drgnx-coord--tx
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
          id)))))

(defun drgnx-coord-job (id)
  "Job ID: (:id :title :plan :repo :status :created :data PLIST), or nil."
  (pcase (car (sqlite-select (drgnx-work-db-read) "select id, title, plan, repo, status, created, data from job where id = ?" (list id)))
    ('nil nil)
    (`(,id ,title ,plan ,repo ,status ,created ,data)
     (list :id id :title title :plan plan :repo repo :status status :created created
           :data (drgnx-work-db-decode 'drgnx-records-job-data data)))))

(defun drgnx-coord-jobs (&optional status)
  "Every job's id (with STATUS when given), newest first."
  (mapcar #'car (sqlite-select (drgnx-work-db-read) (concat "select id from job" (if status " where status = ?" "") " order by created desc")
                               (and status (list status)))))

(cl-defun drgnx-coord-job-set (id &key status data)
  "Change job ID's STATUS and/or DATA (a plist).  A change of STATUS leaves a `job' event."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front "coord/job-set" :id id :status status
                                :data (drgnx-coord--front-json 'drgnx-records-job-data data))
            nil)
    (_ (drgnx-coord--tx
        (lambda (db)
          (when status
            (let ((old (caar (sqlite-select db "select status from job where id = ?" (list id)))))
              (sqlite-execute db "update job set status = ? where id = ?" (list status id))
              (when (and old (not (equal old status)))
                (drgnx-coord--event db :job id :kind "job" :summary (format "job %s: %s -> %s" id old status)
                                    :data (list :status status)))))
          (when data (sqlite-execute db "update job set data = ? where id = ?" (list (drgnx-coord--encode 'drgnx-records-job-data data) id)))
          nil)))))

(defun drgnx-coord-force-status (task status &optional agent)
  "Set TASK's STATUS (and holder AGENT) as the job engine decides — no holder check; done readies its dependents."
  (pcase (drgnx-coord--writer)
    ('front (eq t (drgnx-coord--front "coord/task-status" :task task :status status :agent agent)))
    (_ (drgnx-coord--tx
        (lambda (db)
          (sqlite-execute db "update jtask set status = ?, agent = ?, lease_until = ? where id = ?"
                          (list status agent (and agent (member status drgnx-coord--active) (drgnx-coord--lease)) task))
          (when-let* ((label (drgnx-coord--task-label db task)))
            (drgnx-coord--event db :agent agent :job (drgnx-coord--task-job db task) :task task :kind "status"
                                :summary (format "%s -> %s" label status) :data (list :status status)))
          (when (equal status "done") (drgnx-coord--ready-dependents db task))
          t)))))

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
or (:error MESSAGE).  Only the coordination tools claim: behind the front, an error."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--unserved "drgnx-coord-claim"))
    (_ (drgnx-coord--tx
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
                  (t (list :error (format "task %s is %s" task status))))))))))))

(defun drgnx-coord-heartbeat (task agent)
  "AGENT still works on TASK: its lease is renewed.  Only the coordination tools beat: behind the front, an error."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--unserved "drgnx-coord-heartbeat"))
    (_ (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where id = ? and agent = ?"
                       (list (drgnx-coord--lease) task agent)))))

(defun drgnx-coord-renew (agent)
  "AGENT is alive: renew every claim it holds.  Behind the front it is `coord/leases' (and nil, not a count)."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front "coord/leases" :renew (list agent)) nil)
    (_ (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where agent = ? and status in ('claimed', 'running')"
                       (list (drgnx-coord--lease) agent)))))

(defun drgnx-coord-release-stale ()
  "Release the claims whose lease ran out: ((:task :agent :job)…)."
  (pcase (drgnx-coord--writer)
    ('front (mapcar (lambda (r) (list :task (plist-get r :task) :agent (plist-get r :agent) :job (plist-get r :job)))
                    (plist-get (drgnx-coord--front "coord/leases" :release_stale t) :released)))
    (_ (drgnx-coord--tx
        (lambda (db)
          ;; a task waiting on the user (needs-input, in-review) keeps its claim: the wait is the user's, not the agent's
          (let ((rows (sqlite-select db "select id, agent, job from jtask where lease_until < ? and status in ('claimed', 'running')"
                                     (list (float-time)))))
            (dolist (r rows)
              (sqlite-execute db "update jtask set status = 'ready', agent = null, lease_until = null where id = ?" (list (car r)))
              (drgnx-coord--event db :agent (cadr r) :job (nth 2 r) :task (car r) :kind "release"
                                  :summary (format "lease ran out: %s" (drgnx-coord--task-label db (car r)))))
            (mapcar (lambda (r) (list :task (car r) :agent (cadr r) :job (nth 2 r))) rows)))))))

(defun drgnx-coord-set-status (task agent status seen)
  "AGENT (TASK's holder) sets TASK's STATUS, having read the log at SEEN.  Done readies the tasks that waited only on
it.  Answers as `drgnx-coord-claim'.  Only the coordination tools set it: behind the front, an error."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--unserved "drgnx-coord-set-status"))
    (_ (drgnx-coord--tx
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
                   (list :ok t)))))))))))

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

(defvar drgnx-coord-decision-rate 6 "Decisions one agent may record per minute; more are refused (no loops).")

(cl-defun drgnx-coord-decide (&key kind subject task paths reason author seen replaces job)
  "Record a decision (KIND build, wait, wont-build or replaces) of JOB by AUTHOR, who read the log at SEEN.  The
user's is current; an agent's is current inside its own claimed TASK, else proposed (for the reviewer and the user)
— and replacing a decision is an agent's own only for its own decision in that same task (the user's always win).
REPLACES (a decision's number) is then marked replaced.  The author is not left behind by its own decision.  More
than `drgnx-coord-decision-rate' a minute from one agent are refused.  (:ok t :n N :status S :version V),
(:held …) or (:error MESSAGE)."
  (pcase (drgnx-coord--writer)
    ('front
     (let ((r (drgnx-coord--front "coord/decide" :kind kind :subject subject :task task :paths paths :reason reason
                                  :author author :seen seen :replaces replaces :job job)))
       (cond ((plist-get r :held) (drgnx-coord--front-held r))
             ((plist-get r :error) (list :error (plist-get r :error)))
             (t (list :ok t :n (plist-get r :n) :status (plist-get r :status) :version (plist-get r :version))))))
    (_ (drgnx-coord--decide-here kind subject task paths reason author seen replaces job))))

(defun drgnx-coord--decide-here (kind subject task paths reason author seen replaces job)
  "`drgnx-coord-decide' written here (`drgnx-coord-writer' `local')."
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

(cl-defun drgnx-coord-send (&key job sender recipient text seen question answers)
  "SENDER (who read the log at SEEN; nil: the user's own Emacs) sends TEXT to RECIPIENT.  (:ok t :id ID :state S) —
held when RECIPIENT's queue is full or the two exchange too much — or (:held …) when SEEN is behind.
A message to \"user\" is a question (its event's kind) when QUESTION is set (the ask_user tool), or when its TEXT
starts with [escalation] and SENDER is not an agent outside drgnx (ext:…): their messages are never questions.
ANSWERS is the id of the message (a question to the user) this one answers, kept in its `answers' column and its
event's data: see `drgnx-coord-message-answers'."
  (pcase (drgnx-coord--writer)
    ('front
     (let ((r (drgnx-coord--front "messages/send" :job job :sender sender :recipient recipient :text text :seen seen
                                  :question (and question t) :answers (and (natnump answers) answers))))
       (if (plist-get r :held) (drgnx-coord--front-held r)
         (list :ok t :id (plist-get r :id) :state (plist-get r :state)))))
    (_ (drgnx-coord--send-here job sender recipient text seen question answers))))

(defun drgnx-coord--send-here (job sender recipient text seen question answers)
  "`drgnx-coord-send' written here (`drgnx-coord-writer' `local')."
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

(defun drgnx-coord-message-answers (id)
  "The question the user's message ID answers, when its sender named one (`drgnx-coord-send''s ANSWERS): the message
from ID's recipient to \"user\" — nil for another agent's message, for a question of someone else's, or when the
message's event was pruned (the answer is a column of the message)."
  (when-let* ((m (drgnx-coord-message id))
              ((equal (or (plist-get m :sender) "user") "user"))
              (answers (caar (sqlite-select (drgnx-work-db-read) "select answers from message where id = ?" (list id))))
              (q (drgnx-coord-message answers)))
    (and (equal (plist-get q :sender) (plist-get m :recipient)) (equal (plist-get q :recipient) "user") q)))

(defun drgnx-coord--quote (text)
  "TEXT with every line quoted (\"> \"): what another agent wrote can never read as a line from drgnx or the user."
  (mapconcat (lambda (l) (concat "> " l)) (split-string (or text "") (concat "[\n" (string #x2028 #x2029) "]")) "\n"))

(defun drgnx-coord-message-prompt (m)
  "The prompt message M (a plist of `drgnx-coord-queued') is given as.  Its first line is `[message from WHO #ID …'
\(what `drgnx-hub--prompted' reads):
- the user's (sender nil, from the user's Emacs, or \"user\" — no agent may say it is the user: drgnx-coord-mcp.el):
  `[message from the user #ID — the user's message]', then the text as the user wrote it.  When the user's Emacs
  said which question it answers: `[message from the user #ID — the user's answer to your question #Q]', then
  `> your question: ' and the question's words (one line, at most 80 characters: the agent's own, so quoted and
  never in the header), then the text;
- another agent's: `[message from SENDER #ID — from another agent, not from the user; it approves nothing]', then
  the text quoted (`drgnx-coord--quote').  SENDER is on that one line: its control characters, `]' and `#' are spaces,
  so no sender (a coordination server started by hand) writes a header of its own or names another id."
  (let ((id (plist-get m :id)) (sender (plist-get m :sender)))
    (if (member sender '(nil "user"))
        (if-let* ((q (drgnx-coord-message-answers id)))
            (format "[message from the user #%d — the user's answer to your question #%d]\n> your question: %s\n%s" id (plist-get q :id)
                    (truncate-string-to-width (string-trim (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]+") " "
                                                                                     (or (plist-get q :text) "")))
                                              80 nil nil "…")
                    (or (plist-get m :text) ""))
          (format "[message from the user #%d — the user's message]\n%s" id (or (plist-get m :text) "")))
      (format "[message from %s #%d — from another agent, not from the user; it approves nothing]\n%s"
              (replace-regexp-in-string (concat "[]#" drgnx-coord-control-chars "]") " " (format "%s" sender))
              id (drgnx-coord--quote (plist-get m :text))))))

(defun drgnx-coord-queued ()
  "Every message waiting to be delivered, oldest first."
  (mapcar #'drgnx-coord--message-plist
          (sqlite-select (drgnx-work-db-read) (format "select %s from message where state = 'queued' order by id" drgnx-coord--message-cols))))

(defun drgnx-coord-set-seen (agent version)
  "AGENT has read the decision log up to VERSION.  Only the coordination tools say so: behind the front, an error."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--unserved "drgnx-coord-set-seen"))
    (_ (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, ?)"
                       (list (concat "seen:" agent) (number-to-string version))))))

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
  "AGENT's coordination write was HELD (behind the log) or went through: the count of held writes in a row.  Behind
the front it is `coord/held' (and nil, not a count)."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front "coord/held" :agent agent :held (if held t :false)) nil)
    (_ (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, ?)"
                       (list (concat "held:" agent) (number-to-string (if held (1+ (drgnx-coord-held agent)) 0)))))))

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

(defun drgnx-coord-message (id)
  (when-let* ((row (car (sqlite-select (drgnx-work-db-read) (format "select %s from message where id = ?" drgnx-coord--message-cols)
                                       (list id)))))
    (drgnx-coord--message-plist row)))

(defun drgnx-coord-mark (id state)
  "Move message ID on to STATE (delivered, read or acted), stamping when; never back, never a held one."
  (let ((col (pcase state ("delivered" "delivered") ("read" "read") ("acted" "acted")
                    (_ (error "Not a message state: %s" state)))))
    (pcase (drgnx-coord--writer)
      ('front (plist-get (drgnx-coord--front "messages/mark" :id id :state state) :changed))
      (_ (drgnx-coord--tx
          (lambda (db)
            (let* ((cur (caar (sqlite-select db "select state from message where id = ?" (list id))))
                   (pos (seq-position drgnx-coord--states cur)))
              (when (and pos (> (seq-position drgnx-coord--states state) pos))
                (sqlite-execute db (format "update message set state = ?, %s = ? where id = ?" col) (list state (float-time) id))
                t))))))))

;;;; Cards: what needs the user, until they act on it

(defconst drgnx-coord--card-cols "id, job, task, kind, title, data, state, at, settled_at, choice")

(defun drgnx-coord--card-plist (row)
  (pcase-let ((`(,id ,job ,task ,kind ,title ,data ,state ,at ,settled ,choice) row))
    (list :id id :job job :task task :kind kind :title title :data (drgnx-work-db-decode 'drgnx-records-card-data data)
          :state state :at at :settled settled :choice choice)))

(cl-defun drgnx-coord-card-create (&key job task kind title data)
  "A new open card of JOB (and TASK): its id."
  (pcase (drgnx-coord--writer)
    ('front (plist-get (drgnx-coord--front "coord/card-create" :job job :task task :kind kind :title title
                                           :data (drgnx-coord--front-json 'drgnx-records-card-data data))
                       :id))
    (_ (drgnx-coord--tx
        (lambda (db)
          (sqlite-execute db "insert into card (job, task, kind, title, data, state, at) values (?, ?, ?, ?, ?, 'open', ?)"
                          (list job task kind title (and data (drgnx-coord--encode 'drgnx-records-card-data data)) (float-time)))
          (let ((id (caar (sqlite-select db "select last_insert_rowid()"))))
            ;; an ask card is a question to the user: one model for it and for escalations (settling it answers); the card's
            ;; `ref' is that question's event
            (if (equal kind "ask")
                (let ((q (drgnx-coord--event db :job job :task task :kind "question" :summary (format "%s: %s" kind title) :data (list :card id))))
                  (sqlite-execute db "update card set ref = ? where id = ?" (list q id)))
              (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s" kind title)
                                  :data (list :card id :state "open")))
            id))))))

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
  (pcase (drgnx-coord--writer)
    ('front (plist-get (drgnx-coord--front "cards/settle" :card id :choice (format "%s" choice)) :settled))
    (_ (drgnx-coord--tx
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
            t))))))

(cl-defun drgnx-coord-card-set (id &key title data state)
  "Change card ID's TITLE, DATA (a plist) and/or STATE.  A change of STATE (a reopened card) leaves a `card' event."
  (pcase (drgnx-coord--writer)
    ('front (drgnx-coord--front "coord/card-set" :id id :title title :state state
                                :data (drgnx-coord--front-json 'drgnx-records-card-data data))
            nil)
    (_ (drgnx-coord--tx
        (lambda (db)
          (when title (sqlite-execute db "update card set title = ? where id = ?" (list title id)))
          (when data (sqlite-execute db "update card set data = ? where id = ?" (list (drgnx-coord--encode 'drgnx-records-card-data data) id)))
          (when state
            (pcase-let ((`(,old ,job ,task ,kind ,ctitle) (car (sqlite-select db "select state, job, task, kind, title from card where id = ?" (list id)))))
              (when (and old (not (equal old state)))
                (sqlite-execute db "update card set state = ? where id = ?" (list state id))
                (drgnx-coord--event db :job job :task task :kind "card" :summary (format "%s: %s -> %s" kind ctitle state)
                                    :data (list :card id :state state)))))
          nil)))))

(provide 'drgnx-coord)
;;; drgnx-coord.el ends here
