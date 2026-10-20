;;; drgnx-work-db.el --- The work tracker's store: specs, plans, tasks, TODOs, commits in SQLite -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One SQLite database (`drgnx-work-db-file', in drgnx's data dir) of nodes — spec, plan, task, step,
;; todo, ruling, commit, branch — and the edges between them.  Every node and edge carries the
;; source it came from (a file path, or "recorded"/"branch" for what drgnx noted itself): a rescan
;; of a file forgets exactly what that file gave, while recorded links stay.  Emacs's own SQLite (29+).
;; See docs/guide/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'sqlite)                   ; with-sqlite-transaction
(require 'drgnx-records)

(defconst drgnx-work-db--steps
  '((1 "create table if not exists node (id text primary key, kind text, title text, path text, line integer,
        status text, parent text, ord integer, source text, data text, updated real)"
       "create index if not exists node_parent on node(parent)"
       "create index if not exists node_source on node(source)"
       "create table if not exists edge (src text, dst text, kind text, origin text, source text,
        primary key (src, dst, kind))"
       "create index if not exists edge_dst on edge(dst, kind)"
       "create table if not exists file (path text primary key, mtime real)")
    ;; M9b: what the gateway carried, one row per request
    (2 "create table if not exists spend (at real, job text, task text, agent text, provider text, model text,
        input integer, output integer, cost real, status integer)"
       "create index if not exists spend_job on spend(job)")
    ;; M9b.2: agent coordination (core/drgnx-coord.el)
    (3 "create table if not exists job (id text primary key, title text, plan text, repo text, status text, created real, data text)"
       "create table if not exists jtask (id text primary key, job text, n integer, title text, role text, status text,
        agent text, lease_until real, data text)"
       "create index if not exists jtask_job on jtask(job)"
       "create table if not exists jdep (task text, dep text, primary key (task, dep))"
       "create table if not exists decision (n integer primary key, kind text, subject text, task text, paths text,
        reason text, author text, status text, replaces integer, at real, ver integer, job text)"
       "create table if not exists message (id integer primary key, job text, sender text, recipient text, text text,
        state text, reason text, at real, delivered real, read real, acted real)"
       "create index if not exists message_to on message(recipient, state)")
    ;; M9b.4: what needs the user, with its actions (core/drgnx-job.el)
    (4 "create table if not exists card (id integer primary key, job text, task text, kind text, title text, data text,
        state text, at real, settled_at real, choice text)"
       "create index if not exists card_job on card(job, state)")
    ;; M12f: what happened (the event log), who is working (the agent registry), what the user reviewed (core/drgnx-coord.el)
    (5 "create table if not exists event (id integer primary key autoincrement, at real, agent text, job text, task text, kind text,
        summary text, data text)"
       "create index if not exists event_at on event(at)"
       "create index if not exists event_agent on event(agent, id)"
       "create index if not exists event_job on event(job, id)"
       "create index if not exists event_kind on event(kind, id)"
       "create table if not exists agent (id text primary key, kind text, name text, cwd text, worktree text, branch text,
        base text, plan text, task text, pid integer, started real, seen real)"
       "create table if not exists review_mark (agent text, path text, state text, hash text, at real,
        primary key (agent, path))")
    ;; Ratatoskr: every data column is JSON (checked); turns, answers and ask cards are columns
    (6 . drgnx-work-db--migrate-6))
  "Migrations: (VERSION SQL…) or (VERSION . FUNCTION), applied in order to a database below VERSION.
FUNCTION gets the database inside the migration's transaction.")

(defconst drgnx-work-db-schema-version (car (car (last drgnx-work-db--steps))))

(defconst drgnx-work-db-compat-read 6
  "The schema level this drgnx's readers understand (`meta' `compat-read'): a read-only reader of a newer level refuses.")

(defvar drgnx-work-db--handles nil "Alist file → open database.")

(defun drgnx-work-db-file () (expand-file-name "work.db" (drgnx-data-dir)))

(defun drgnx-work-db-decode (schema text)
  "TEXT, a data column's JSON, as the record SCHEMA describes: nil for NULL or for text SCHEMA refuses."
  (and text (condition-case nil (drgnx-records-decode schema text) (drgnx-records-invalid nil))))

;;;; Schema 6: the data columns are JSON

(defun drgnx-work-db--column-p (db table column)
  (and (sqlite-select db "select 1 from pragma_table_info(?) where name = ?" (list table column)) t))

(defun drgnx-work-db--keep-schema-5 (db)
  "Before schema 6 rewrites the file: a copy of the pre-6 database as `work.db.schema5', never replaced.
It must run outside a transaction (`vacuum').  An older drgnx then refuses the migrated file (a newer schema);
docs/develop/coordination.md says how to move the copy back by hand."
  (let* ((file (nth 2 (car (sqlite-select db "pragma database_list"))))
         (have (and (sqlite-select db "select name from sqlite_master where name = 'meta'")
                    (string-to-number (or (caar (sqlite-select db "select value from meta where key = 'schema'")) "0")))))
    (when (and file (not (string-empty-p file)) have (<= 1 have 5))
      (let ((copy (concat file ".schema5")) (tmp (concat file ".schema5.tmp")))
        (unless (file-exists-p copy)
          (ignore-errors (delete-file tmp))
          (condition-case err
              (progn (sqlite-execute db "vacuum into ?" (list tmp))
                     (rename-file tmp copy))
            (error (ignore-errors (delete-file tmp))
                   (unless (file-exists-p copy) (signal (car err) (cdr err))))))))))

(defvar read-eval)                      ; so the let in the converter binds it dynamically in compiled code

(defun drgnx-work-db--6-convert(schema text)
  "TEXT, a printed plist, as (JSON . VALUE) for record SCHEMA; (nil) for NULL or nil; `bad' when it does not read
\(`read-eval' off) or SCHEMA refuses it."
  (if (null text) '(nil)
    (condition-case nil
        (let ((value (let ((read-eval nil)) (car (read-from-string text)))))
          (cons (and value (drgnx-records-encode schema value)) value))
      ((invalid-read-syntax end-of-file drgnx-records-invalid) 'bad))))

(defun drgnx-work-db--6-rebuild (db table ddl indexes schema &optional extra extra-fn)
  "Rebuild TABLE (created from DDL, with INDEXES) with its `data' converted to JSON for SCHEMA.
EXTRA names a column the rebuilt table adds, EXTRA-FN (ROW VALUE TEXT) its value.  Ids stay.  The number of rows
whose data could not be converted (stored as NULL)."
  (let* ((new (concat table "_new"))
         (cols (mapcar #'car (sqlite-select db "select name from pragma_table_info(?)" (list table))))
         (data-at (seq-position cols "data"))
         (all (append cols (and extra (list extra))))
         (insert (format "insert into %s (%s) values (%s)" new (string-join all ", ") (string-join (make-list (length all) "?") ", ")))
         (seq (and (equal table "event") (caar (sqlite-select db "select seq from sqlite_sequence where name = 'event'"))))
         (dropped 0))
    (sqlite-execute db (format "create table %s (%s)" new ddl))
    (dolist (row (sqlite-select db (format "select %s from %s" (string-join cols ", ") table)))
      (let* ((text (nth data-at row)) (r (drgnx-work-db--6-convert schema text))
             (data (if (eq r 'bad) (progn (cl-incf dropped) nil) (car r)))
             (new-row (append (seq-take row data-at) (list data) (nthcdr (1+ data-at) row))))
        (sqlite-execute db insert (append new-row (and extra (list (funcall extra-fn row (and (consp r) (cdr r)) text)))))))
    (sqlite-execute db (concat "drop table " table))
    (sqlite-execute db (format "alter table %s rename to %s" new table))
    (dolist (ix indexes) (sqlite-execute db ix))
    (when seq
      (sqlite-execute db "delete from sqlite_sequence where name = 'event'")
      (sqlite-execute db "insert into sqlite_sequence values ('event', ?)" (list seq)))
    dropped))

(defconst drgnx-work-db--json-data "data text check (data is null or json_valid(data))")

(defun drgnx-work-db--migrate-6 (db)
  "Schema 6, inside the migration's transaction: the data columns of node, job, jtask, card and event are JSON text
\(read with `read-eval' off, written by the record schemas); a row that cannot be converted gets NULL and is counted
in `meta' `migrate-6-dropped'.  New columns: event.turn, message.answers, card.ref.  Safe to run twice."
  (unless (drgnx-work-db--column-p db "message" "answers")
    (sqlite-execute db "alter table message add column answers integer"))
  (unless (drgnx-work-db--column-p db "event" "turn")
    (let ((refs (make-hash-table)) (dropped 0))
      (cl-incf dropped
               (drgnx-work-db--6-rebuild
                db "event"
                (concat "id integer primary key autoincrement, at real, agent text, job text, task text, kind text, summary text, "
                        drgnx-work-db--json-data ", turn integer")
                '("create index event_at on event(at)" "create index event_agent on event(agent, id)"
                  "create index event_job on event(job, id)" "create index event_kind on event(kind, id)")
                'drgnx-records-event-data "turn"
                (lambda (row value text)
                  (pcase-let ((`(,id ,_at ,agent ,_job ,_task ,kind ,_summary ,_data) row))
                    ;; what the text said becomes columns: an ask card's question, the message a reply answers
                    (when (and text (equal kind "question") (string-match "\\`(:card \\([0-9]+\\))\\'" text))
                      (puthash (string-to-number (match-string 1 text)) id refs))
                    (when (and (equal kind "message") (equal agent "user") (natnump (plist-get value :message))
                               (natnump (plist-get value :answers)))
                      (sqlite-execute db "update message set answers = ? where id = ?"
                                      (list (plist-get value :answers) (plist-get value :message))))
                    (and (member kind '("start" "stop")) text (string-prefix-p "(:turn t" text) 1)))))
      (cl-incf dropped
               (drgnx-work-db--6-rebuild
                db "card"
                (concat "id integer primary key, job text, task text, kind text, title text, " drgnx-work-db--json-data
                        ", state text, at real, settled_at real, choice text, ref integer")
                '("create index card_job on card(job, state)")
                'drgnx-records-card-data "ref"
                (lambda (row _value _text) (and (equal (nth 3 row) "ask") (gethash (car row) refs)))))
      (cl-incf dropped
               (drgnx-work-db--6-rebuild
                db "node"
                (concat "id text primary key, kind text, title text, path text, line integer, status text, parent text, ord integer, "
                        "source text, " drgnx-work-db--json-data ", updated real")
                '("create index node_parent on node(parent)" "create index node_source on node(source)")
                'drgnx-records-node-data))
      (cl-incf dropped
               (drgnx-work-db--6-rebuild
                db "job"
                (concat "id text primary key, title text, plan text, repo text, status text, created real, " drgnx-work-db--json-data)
                nil 'drgnx-records-job-data))
      (cl-incf dropped
               (drgnx-work-db--6-rebuild
                db "jtask"
                (concat "id text primary key, job text, n integer, title text, role text, status text, agent text, lease_until real, "
                        drgnx-work-db--json-data)
                '("create index jtask_job on jtask(job)") 'any))
      (sqlite-execute db "insert or replace into meta values ('migrate-6-dropped', ?)" (list (number-to-string dropped)))
      (when (> dropped 0)
        (message "drgnx: work.db schema 6: %d data value%s could not be converted and %s now empty (the schema-5 copy is work.db.schema5)"
                 dropped (if (= dropped 1) "" "s") (if (= dropped 1) "is" "are")))))
  (sqlite-execute db "insert or replace into meta values ('compat-read', ?)" (list (number-to-string drgnx-work-db-compat-read))))

(defun drgnx-work-db--migrate (db)
  (drgnx-work-db--keep-schema-5 db)
  ;; one writer at a time (immediate: the write lock first), the version read again under it — two
  ;; Emacsen opening a fresh work.db at once migrate it once; a migration cut short is finished
  (sqlite-execute db "begin immediate")
  (condition-case err
      (progn
        (sqlite-execute db "create table if not exists meta (key text primary key, value text)")
        (let ((have (string-to-number (or (caar (sqlite-select db "select value from meta where key = 'schema'")) "0"))))
          (when (> have drgnx-work-db-schema-version)
            (user-error "work.db is schema %d, newer than this drgnx (%d): update drgnx" have drgnx-work-db-schema-version))
          (pcase-dolist (`(,version . ,sqls) drgnx-work-db--steps)
            (when (> version have)
              (if (symbolp sqls) (funcall sqls db) (dolist (sql sqls) (sqlite-execute db sql)))))
          (sqlite-execute db "insert or replace into meta values ('schema', ?)"
                          (list (number-to-string drgnx-work-db-schema-version))))
        (sqlite-execute db "commit"))
    (error (ignore-errors (sqlite-execute db "rollback"))
           (signal (car err) (cdr err)))))

(defun drgnx-work-db ()
  "The open database (opened, created and migrated on first use)."
  (let ((file (drgnx-work-db-file)))
    (or (alist-get file drgnx-work-db--handles nil nil #'equal)
        (progn
          (make-directory (file-name-directory file) t)
          (let ((db (sqlite-open file)))
            (sqlite-pragma db "busy_timeout = 5000")    ; another Emacs writing: wait, never fail at once
            (sqlite-pragma db "journal_mode = WAL")
            (drgnx-work-db--migrate db)
            (push (cons file db) drgnx-work-db--handles)
            db)))))

(defun drgnx-work-db-close-all ()
  (dolist (h drgnx-work-db--handles) (ignore-errors (sqlite-close (cdr h))))
  (setq drgnx-work-db--handles nil))

(defun drgnx-work-db-version ()
  (string-to-number (caar (sqlite-select (drgnx-work-db) "select value from meta where key = 'schema'"))))

;;;; Nodes and edges

(defconst drgnx-work--columns '(:kind :title :path :line :status :parent :ord :source))

(defun drgnx-work-put-node (id &rest props)
  "Insert or replace node ID with PROPS (:kind :title :path :line :status :parent :ord :source and
any other keys, kept in its data)."
  (let ((data (cl-loop for (k v) on props by #'cddr unless (memq k drgnx-work--columns) append (list k v))))
    (sqlite-execute (drgnx-work-db)
                    "insert or replace into node values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    (list id (and (plist-get props :kind) (symbol-name (plist-get props :kind)))
                          (plist-get props :title) (plist-get props :path) (plist-get props :line)
                          (plist-get props :status) (plist-get props :parent) (plist-get props :ord)
                          (plist-get props :source)
                          (and data (drgnx-records-encode 'drgnx-records-node-data data)) (float-time)))))

(defun drgnx-work--row-node (row)
  (pcase-let ((`(,id ,kind ,title ,path ,line ,status ,parent ,ord ,source ,data) row))
    (append (list :id id :kind (and kind (intern kind)) :title title :path path :line line :status status
                  :parent parent :ord ord :source source)
            (drgnx-work-db-decode 'drgnx-records-node-data data))))

(defconst drgnx-work--select "select id, kind, title, path, line, status, parent, ord, source, data from node")

(defun drgnx-work-node (id)
  (when-let* ((row (car (sqlite-select (drgnx-work-db) (concat drgnx-work--select " where id = ?") (list id)))))
    (drgnx-work--row-node row)))

(defun drgnx-work-update-node (id &rest props)
  "Change PROPS of node ID (columns and data), keeping the rest."
  (when-let* ((n (drgnx-work-node id)))
    (cl-loop for (k v) on props by #'cddr do (setq n (plist-put n k v)))
    (apply #'drgnx-work-put-node id (cl-loop for (k v) on n by #'cddr unless (eq k :id) append (list k v)))))

(defun drgnx-work-put-edge (src dst kind origin &optional source)
  "The KIND edge SRC → DST, from ORIGIN (`parsed', `inferred', `recorded'): a recorded edge stays recorded."
  (sqlite-execute (drgnx-work-db) "insert into edge values (?, ?, ?, ?, ?) on conflict (src, dst, kind)
                                   do update set origin = excluded.origin, source = excluded.source where edge.origin <> 'recorded'"
                  (list src dst (symbol-name kind) (symbol-name origin) (or source (symbol-name origin)))))

(defun drgnx-work-edges-to (dst kind)
  "((SRC . ORIGIN)…) of the KIND edges into DST."
  (mapcar (lambda (r) (cons (car r) (intern (cadr r))))
          (sqlite-select (drgnx-work-db) "select src, origin from edge where dst = ? and kind = ? order by src" (list dst (symbol-name kind)))))

(defun drgnx-work-edges-from (src kind)
  "((DST . ORIGIN)…) of the KIND edges out of SRC."
  (mapcar (lambda (r) (cons (car r) (intern (cadr r))))
          (sqlite-select (drgnx-work-db) "select dst, origin from edge where src = ? and kind = ? order by dst" (list src (symbol-name kind)))))

(defun drgnx-work-forget-source (source)
  "Forget every node and edge SOURCE gave (before reading SOURCE again)."
  (sqlite-execute (drgnx-work-db) "delete from node where source = ?" (list source))
  (sqlite-execute (drgnx-work-db) "delete from edge where source = ?" (list source)))

(defun drgnx-work-children (id)
  "The tree children of ID: nodes whose parent it is (by order), then the plans that derive from it
and the commits that implement it (newest first)."
  (append
   (mapcar #'drgnx-work--row-node
           (sqlite-select (drgnx-work-db) (concat drgnx-work--select " where parent = ? order by ord, line, title") (list id)))
   (sort (delq nil (mapcar (lambda (e) (drgnx-work-node (car e)))
                           (append (drgnx-work-edges-to id 'derives) (drgnx-work-edges-to id 'implements))))
         (lambda (a b)
           (if (and (eq (plist-get a :kind) 'commit) (eq (plist-get b :kind) 'commit))
               (let ((da (or (plist-get a :date) 0)) (db (or (plist-get b :date) 0)))
                 (if (= da db) (< (or (plist-get a :seq) 0) (or (plist-get b :seq) 0)) (> da db)))
             (string< (or (plist-get a :title) "") (or (plist-get b :title) "")))))))

(defun drgnx-work-roots ()
  "The tree's roots: every spec, and the plans that name none."
  (let ((specs (mapcar #'drgnx-work--row-node (sqlite-select (drgnx-work-db) (concat drgnx-work--select " where kind = 'spec' order by title"))))
        (lone (mapcar #'drgnx-work--row-node
                      (sqlite-select (drgnx-work-db)
                                     (concat drgnx-work--select " where kind = 'plan' and id not in (select e.src from edge e join node s on s.id = e.dst where e.kind = 'derives') order by title")))))
    (append specs lone)))

(defun drgnx-work-nodes (kind)
  (mapcar #'drgnx-work--row-node (sqlite-select (drgnx-work-db) (concat drgnx-work--select " where kind = ?") (list (symbol-name kind)))))

(defun drgnx-work-nodes-of-kinds (kinds)
  "The nodes of any of KINDS (symbols), in one query, by kind, path and order."
  (when kinds
    (mapcar #'drgnx-work--row-node
            (sqlite-select (drgnx-work-db)
                           (format "%s where kind in (%s) order by kind, path, ord, line" drgnx-work--select
                                   (mapconcat (lambda (_) "?") kinds ", "))
                           (mapcar #'symbol-name kinds)))))

(defun drgnx-work-forget-orphan-commits ()
  "Forget the commits no edge links any more (commits belong to no file: several ledgers may name one)."
  (sqlite-execute (drgnx-work-db) "delete from node where kind = 'commit' and id not in (select src from edge)"))

;;;; Files seen

(defun drgnx-work-file-mtime (path) (caar (sqlite-select (drgnx-work-db) "select mtime from file where path = ?" (list path))))
(defun drgnx-work-set-file (path mtime) (sqlite-execute (drgnx-work-db) "insert or replace into file values (?, ?)" (list path mtime)))
(defun drgnx-work-files () (mapcar #'car (sqlite-select (drgnx-work-db) "select path from file")))
(defun drgnx-work-drop-file (path) (sqlite-execute (drgnx-work-db) "delete from file where path = ?" (list path)))

;;;; Spend (the gateway's requests)

(cl-defun drgnx-work-db-add-spend (&key job task agent provider model (input 0) (output 0) (cost 0.0) status)
  "Record one request the gateway carried."
  (sqlite-execute (drgnx-work-db)
                  "insert into spend values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                  (list (float-time) job task agent provider model input output (float cost) status)))

(cl-defun drgnx-work-db-spend (&key job task agent)
  "What the requests of JOB, TASK and/or AGENT came to: (:input N :output N :cost USD :requests N)."
  (let* ((where (delq nil (list (and job "job = ?") (and task "task = ?") (and agent "agent = ?"))))
         (row (car (sqlite-select (drgnx-work-db)
                                  (concat "select coalesce(sum(input), 0), coalesce(sum(output), 0), coalesce(sum(cost), 0.0), count(*)
                                           from spend" (if where (concat " where " (string-join where " and ")) ""))
                                  (delq nil (list job task agent))))))
    (list :input (nth 0 row) :output (nth 1 row) :cost (float (nth 2 row)) :requests (nth 3 row))))

(provide 'drgnx-work-db)
;;; drgnx-work-db.el ends here
