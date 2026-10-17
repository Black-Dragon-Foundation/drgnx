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
       "create index if not exists spend_job on spend(job)"))
  "Migrations: (VERSION SQL…), applied in order to a database below VERSION.")

(defconst drgnx-work-db-schema-version (car (car (last drgnx-work-db--steps))))

(defvar drgnx-work-db--handles nil "Alist file → open database.")

(defun drgnx-work-db-file () (expand-file-name "work.db" (drgnx-data-dir)))

(defun drgnx-work-db--migrate (db)
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
            (when (> version have) (dolist (sql sqls) (sqlite-execute db sql))))
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
                          (plist-get props :source) (prin1-to-string data) (float-time)))))

(defun drgnx-work--row-node (row)
  (pcase-let ((`(,id ,kind ,title ,path ,line ,status ,parent ,ord ,source ,data) row))
    (append (list :id id :kind (and kind (intern kind)) :title title :path path :line line :status status
                  :parent parent :ord ord :source source)
            (and data (ignore-errors (car (read-from-string data)))))))

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
