;;; work-db-migrate-test.el --- batch tests: work.db migrations step by step; spend -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-work-db)

(defmacro drgnx-work-db-migrate-test--with (&rest body)
  "BODY with drgnx's data dir a fresh temp dir (`dir'), no database open."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-work-db" t)))
          (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
          (drgnx-work-db--handles nil))
     (unwind-protect (progn ,@body)
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(ert-deftest drgnx-work-db/a-version-1-db-migrates-to-2-keeping-its-nodes ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))          ; a work.db as M7b wrote it
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (sqlite-execute db "create table node (id text primary key, kind text, title text, path text, line integer,
                          status text, parent text, ord integer, source text, data text, updated real)")
      (sqlite-execute db "create table edge (src text, dst text, kind text, origin text, source text, primary key (src, dst, kind))")
      (sqlite-execute db "create table file (path text primary key, mtime real)")
      (sqlite-execute db "insert into node (id, kind, title) values ('plan:p', 'plan', 'P')")
      (sqlite-execute db "insert into meta values ('schema', '1')")
      (sqlite-close db))
    (should (= (drgnx-work-db-version) drgnx-work-db-schema-version))
    (should (equal (plist-get (drgnx-work-node "plan:p") :title) "P"))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'spend'"))))

(ert-deftest drgnx-work-db/a-fresh-db-is-version-2 ()
  (drgnx-work-db-migrate-test--with
    (should (= (drgnx-work-db-version) drgnx-work-db-schema-version))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'node'"))))

(ert-deftest drgnx-work-db/a-db-newer-than-the-code-is-left-alone ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (sqlite-execute db "insert into meta values ('schema', '99')")
      (sqlite-close db))
    (should-error (drgnx-work-db) :type 'user-error)
    (let ((db (sqlite-open (concat dir "work.db"))))
      (should (equal (caar (sqlite-select db "select value from meta where key = 'schema'")) "99"))
      (sqlite-close db))))

(ert-deftest drgnx-work-db/a-version-3-db-migrates-to-4-keeping-its-jobs ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))          ; a work.db as M9b.2 wrote it
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (pcase-dolist (`(,v . ,sqls) drgnx-work-db--steps) (when (<= v 3) (dolist (sql sqls) (sqlite-execute db sql))))
      (sqlite-execute db "insert into job values ('j', 'J', 'p.md', '/r/', 'running', 1.0, null)")
      (sqlite-execute db "insert into meta values ('schema', '3')")
      (sqlite-close db))
    (should (= (drgnx-work-db-version) drgnx-work-db-schema-version))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'card'"))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select status from job where id = 'j'")) "running"))))

(ert-deftest drgnx-work-db/spend-adds-up-per-job-task-and-agent ()
  (drgnx-work-db-migrate-test--with
    (drgnx-work-db-add-spend :job "j" :task "a" :agent "x" :provider "openrouter" :model "m" :input 10 :output 5 :cost 0.5 :status 200)
    (drgnx-work-db-add-spend :job "j" :task "b" :agent "y" :provider "ollama" :model "q" :input 1 :output 2 :cost 0.25 :status 200)
    (drgnx-work-db-add-spend :job "k" :task "c" :agent "z" :provider "ollama" :model "q" :input 100 :output 100 :cost 9.0 :status 200)
    (should (equal (drgnx-work-db-spend :job "j") '(:input 11 :output 7 :cost 0.75 :requests 2)))
    (should (equal (drgnx-work-db-spend :task "a") '(:input 10 :output 5 :cost 0.5 :requests 1)))
    (should (equal (drgnx-work-db-spend :agent "z") '(:input 100 :output 100 :cost 9.0 :requests 1)))
    (should (equal (drgnx-work-db-spend :job "none") '(:input 0 :output 0 :cost 0.0 :requests 0)))))

(ert-deftest drgnx-work-db/nodes-of-kinds-in-one-query ()
  (drgnx-work-db-migrate-test--with
    (drgnx-work-put-node "spec:s" :kind 'spec :title "S" :path "/s")
    (drgnx-work-put-node "plan:p" :kind 'plan :title "P" :path "/p")
    (drgnx-work-put-node "step:p#1.1" :kind 'step :title "do" :path "/p")
    (drgnx-work-put-node "task:p#1" :kind 'task :title "T" :path "/p" :ord 1 :stale t)
    (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-nodes-of-kinds '(spec plan task)))
                   '("plan:p" "spec:s" "task:p#1")))
    (should (eq (plist-get (car (drgnx-work-nodes-of-kinds '(task))) :stale) t))
    (should-not (drgnx-work-nodes-of-kinds nil))))

;;; work-db-migrate-test.el ends here
