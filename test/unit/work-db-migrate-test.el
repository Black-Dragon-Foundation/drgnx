;;; work-db-migrate-test.el --- batch tests: work.db migrations step by step; spend -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/support/work-db-gate" drgnx-dir) nil t)   ; the tests below are of the `local' writer
(require 'drgnx-work-db)
(require 'drgnx-notice)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)

(defun drgnx-work-db-migrate-test--version ()
  "The schema number after the local writer opened (and so migrated) the file: a reader never migrates."
  (drgnx-work-db)
  (drgnx-work-db-version))

(defmacro drgnx-work-db-migrate-test--with (&rest body)
  "BODY with drgnx's data dir a fresh temp dir (`dir'), no database open."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-work-db" t)))
          (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
          (drgnx-work-db--handles nil))
     (unwind-protect (progn ,@body)
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(drgnx-work-db-writer-deftest drgnx-work-db/a-version-1-db-migrates-to-2-keeping-its-nodes ()
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
    (should (= (drgnx-work-db-migrate-test--version) drgnx-work-db-schema-version))
    (should (equal (plist-get (drgnx-work-node "plan:p") :title) "P"))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'spend'"))))

(drgnx-work-db-writer-deftest drgnx-work-db/a-fresh-db-is-version-2 ()
  (drgnx-work-db-migrate-test--with
    (should (= (drgnx-work-db-migrate-test--version) drgnx-work-db-schema-version))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'node'"))))

(drgnx-work-db-writer-deftest drgnx-work-db/a-db-newer-than-the-code-is-left-alone ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (sqlite-execute db "insert into meta values ('schema', '99')")
      (sqlite-close db))
    (should-error (drgnx-work-db) :type 'user-error)
    (let ((db (sqlite-open (concat dir "work.db"))))
      (should (equal (caar (sqlite-select db "select value from meta where key = 'schema'")) "99"))
      (sqlite-close db))))

(drgnx-work-db-writer-deftest drgnx-work-db/a-version-3-db-migrates-to-4-keeping-its-jobs ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))          ; a work.db as M9b.2 wrote it
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (pcase-dolist (`(,v . ,sqls) drgnx-work-db--steps) (when (<= v 3) (dolist (sql sqls) (sqlite-execute db sql))))
      (sqlite-execute db "insert into job values ('j', 'J', 'p.md', '/r/', 'running', 1.0, null)")
      (sqlite-execute db "insert into meta values ('schema', '3')")
      (sqlite-close db))
    (should (= (drgnx-work-db-migrate-test--version) drgnx-work-db-schema-version))
    (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where name = 'card'"))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select status from job where id = 'j'")) "running"))))

(drgnx-work-db-writer-deftest drgnx-work-db/spend-adds-up-per-job-task-and-agent ()
  (drgnx-work-db-migrate-test--with
    (drgnx-work-db-add-spend :job "j" :task "a" :agent "x" :provider "openrouter" :model "m" :input 10 :output 5 :cost 0.5 :status 200)
    (drgnx-work-db-add-spend :job "j" :task "b" :agent "y" :provider "ollama" :model "q" :input 1 :output 2 :cost 0.25 :status 200)
    (drgnx-work-db-add-spend :job "k" :task "c" :agent "z" :provider "ollama" :model "q" :input 100 :output 100 :cost 9.0 :status 200)
    (should (equal (drgnx-work-db-spend :job "j") '(:input 11 :output 7 :cost 0.75 :requests 2)))
    (should (equal (drgnx-work-db-spend :task "a") '(:input 10 :output 5 :cost 0.5 :requests 1)))
    (should (equal (drgnx-work-db-spend :agent "z") '(:input 100 :output 100 :cost 9.0 :requests 1)))
    (should (equal (drgnx-work-db-spend :job "none") '(:input 0 :output 0 :cost 0.0 :requests 0)))))

(drgnx-work-db-writer-deftest drgnx-work-db/nodes-of-kinds-in-one-query ()
  (drgnx-work-db-migrate-test--with
    (drgnx-work-fixture-put-node "spec:s" :kind 'spec :title "S" :path "/s")
    (drgnx-work-fixture-put-node "plan:p" :kind 'plan :title "P" :path "/p")
    (drgnx-work-fixture-put-node "step:p#1.1" :kind 'step :title "do" :path "/p")
    (drgnx-work-fixture-put-node "task:p#1" :kind 'task :title "T" :path "/p" :ord 1 :stale t)
    (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-nodes-of-kinds '(spec plan task)))
                   '("plan:p" "spec:s" "task:p#1")))
    (should (eq (plist-get (car (drgnx-work-nodes-of-kinds '(task))) :stale) t))
    (should-not (drgnx-work-nodes-of-kinds nil))))

;;;; Schema 6: the data columns are JSON

(require 'drgnx-records)
(require 'drgnx-coord)

(defun drgnx-work-db-migrate-test--load-5 (file &optional extra)
  "Make FILE a schema-5 work.db from test/fixtures/work-db-5.sql (and the SQL statements EXTRA), in WAL mode as
drgnx leaves it."
  (let ((db (sqlite-open file)))
    (sqlite-pragma db "journal_mode = WAL")
    (with-temp-buffer
      (insert-file-contents (expand-file-name "test/fixtures/work-db-5.sql" drgnx-dir))
      (dolist (stmt (append (split-string (buffer-string) ";\n" t) extra))
        (let ((sql (string-trim (replace-regexp-in-string "^--.*\n" "" stmt))))
          (unless (string-empty-p sql) (sqlite-execute db sql)))))
    (sqlite-close db)))

(defmacro drgnx-work-db-migrate-test--with-5 (&rest body)
  "BODY with a temp data dir (`dir') whose work.db is the schema-5 fixture, not yet opened by drgnx."
  (declare (indent 0))
  `(drgnx-work-db-migrate-test--with
     (drgnx-work-db-migrate-test--load-5 (concat dir "work.db"))
     ,@body))

(defun drgnx-work-db-migrate-test--norm (x)
  "X without the nil-valued keys of its plists (the records codec leaves them out)."
  (cond ((and (consp x) (keywordp (car x)) (proper-list-p x) (cl-evenp (length x)))
         (cl-loop for (k v) on x by #'cddr when v append (list k (drgnx-work-db-migrate-test--norm v))))
        ((consp x) (cons (drgnx-work-db-migrate-test--norm (car x)) (drgnx-work-db-migrate-test--norm (cdr x))))
        (t x)))

(defun drgnx-work-db-migrate-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (secure-hash 'sha256 (current-buffer))))

(defconst drgnx-work-db-migrate-test--tables
  '(("node" "id" drgnx-records-node-data) ("job" "id" drgnx-records-job-data) ("card" "id" drgnx-records-card-data)
    ("event" "id" drgnx-records-event-data) ("jtask" "id" any)))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-converts-every-kind ()
  (drgnx-work-db-migrate-test--with-5
    (should (= (drgnx-work-db-migrate-test--version) 6))
    (should (= drgnx-work-db-schema-version 6))
    (should (= drgnx-work-db-compat-read 6))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select value from meta where key = 'compat-read'")) "6"))
    (let ((old (sqlite-open (concat dir "work.db.schema5") t)) (checked 0))
      (pcase-dolist (`(,table ,key ,schema) drgnx-work-db-migrate-test--tables)
        ;; the column holds JSON and nothing else
        (should (zerop (caar (sqlite-select (drgnx-work-db) (format "select count(*) from %s where data is not null and not json_valid(data)" table)))))
        (pcase-dolist (`(,k ,was) (sqlite-select old (format "select %s, data from %s" key table)))
          (let ((now (caar (sqlite-select (drgnx-work-db) (format "select data from %s where %s = ?" table key) (list k)))))
            (cond ((null was) (should (null now)))
                  ((null now))               ; a bad row: the next test
                  (t (cl-incf checked)
                     (should (equal (drgnx-records-decode schema now)
                                    (drgnx-work-db-migrate-test--norm (let ((read-eval nil)) (car (read-from-string was)))))))))))
      (sqlite-close old)
      (should (>= checked 20)))
    ;; ids, the autoincrement counter, the other tables and the indexes are kept
    (should (equal (caar (sqlite-select (drgnx-work-db) "select seq from sqlite_sequence where name = 'event'")) 20))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select count(*) from event")) 16))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select count(*) from card")) 6))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select count(*) from node")) 7))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select count(*) from spend")) 1))
    (dolist (ix '("node_parent" "node_source" "jtask_job" "card_job" "event_at" "event_agent" "event_job" "event_kind"))
      (should (sqlite-select (drgnx-work-db) "select name from sqlite_master where type = 'index' and name = ?" (list ix))))
    ;; the new columns
    (should (equal (sqlite-select (drgnx-work-db) "select id from event where turn = 1 order by id") '((2) (3))))
    (should (equal (sqlite-select (drgnx-work-db) "select id, answers from message where answers is not null") '((3 2))))
    (should (equal (sqlite-select (drgnx-work-db) "select id, ref from card where ref is not null order by id") '((1 7) (5 15))))
    ;; the readers see the old values
    (should (equal (plist-get (drgnx-work-node "commit:4f9a1c0") :sha) "4f9a1c0e"))
    (should (eq (plist-get (drgnx-work-node "task:p#1") :stale) t))
    (should (equal (plist-get (plist-get (drgnx-coord-job "job-1") :data) :blocked) '(("job-1#2" . "blocked"))))
    (should (eq (plist-get (plist-get (drgnx-coord-job "job-1") :data) :gate) 'review+accept))
    (should (equal (plist-get (plist-get (drgnx-coord-card 3) :data) :key) "against-decision:1"))
    (should (equal (plist-get (nth 9 (drgnx-coord-events)) :data) '(:root "/work/repo/" :paths ("a.el" "b.el"))))))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-survives-unreadable-rows ()
  ;; Review Focus 2: an unreadable object, text cut short, a symbol no schema covers
  (drgnx-work-db-migrate-test--with-5
    (let ((said nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
                ((symbol-function 'drgnx-notify) (lambda (_s _v text &rest _) (push text said) nil)))   ; a notice, Task 20
        (should (= (drgnx-work-db-migrate-test--version) 6)))
      (should (= (length said) 1))
      (should (string-match-p "\\<3\\>" (car said))))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select value from meta where key = 'migrate-6-dropped'")) "3"))
    (should-not (caar (sqlite-select (drgnx-work-db) "select data from event where id = 16")))
    (should-not (caar (sqlite-select (drgnx-work-db) "select data from card where id = 6")))
    (should-not (caar (sqlite-select (drgnx-work-db) "select data from node where id = 'step:p#1.1'")))
    ;; the rows themselves stay
    (should (equal (caar (sqlite-select (drgnx-work-db) "select summary from event where id = 16")) "edited"))
    (should (equal (plist-get (drgnx-work-node "step:p#1.1") :title) "Do it"))
    ;; opened again, nothing is said or counted twice
    (drgnx-work-db-close-all)
    (let ((said nil))
      (cl-letf (((symbol-function 'message) (lambda (&rest args) (push args said))))
        (drgnx-work-db))
      (should-not said))
    (should (equal (caar (sqlite-select (drgnx-work-db) "select value from meta where key = 'migrate-6-dropped'")) "3"))))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-drops-a-row-any-error-fails-on ()
  ;; review S3: not only reader and schema errors: whatever fails on one row (here the schema check signalling
  ;; wrong-type-argument on an odd value) drops that row alone, and the migration finishes
  (drgnx-work-db-migrate-test--with-5
    (let ((orig (symbol-function 'drgnx-records-encode)) (good 0))
      (cl-letf (((symbol-function 'drgnx-records-encode)
                 ;; the first row that would convert fails instead (a row the schema refuses still refuses)
                 (lambda (&rest args)
                   (let ((json (apply orig args)))
                     (if (= (cl-incf good) 1) (signal 'wrong-type-argument '(listp 1)) json))))
                ((symbol-function 'message) #'ignore))
        (should (= (drgnx-work-db-migrate-test--version) 6))))
    ;; the fixture's 3 unreadable rows and this one
    (should (equal (caar (sqlite-select (drgnx-work-db) "select value from meta where key = 'migrate-6-dropped'")) "4"))))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-is-all-or-nothing ()
  ;; a failure outside a row's conversion (a write: a full disk, say) rolls the whole migration back
  (drgnx-work-db-migrate-test--with-5
    (let ((file (concat dir "work.db")) (calls 0) (orig (symbol-function 'sqlite-execute)))
      (let ((before (drgnx-work-db-migrate-test--bytes file)))
        (cl-letf (((symbol-function 'sqlite-execute)
                   (lambda (db sql &rest args)
                     (if (and (string-prefix-p "insert into " sql) (string-search "_new " sql) (> (cl-incf calls) 5))
                         (error "forced halfway")
                       (apply orig db sql args)))))
          (should-error (drgnx-work-db) :type 'error))
        (should (> calls 5))
        (drgnx-work-db-close-all)
        (should (equal (drgnx-work-db-migrate-test--bytes file) before)))
      (let ((db (sqlite-open file t)))
        (should (equal (caar (sqlite-select db "select value from meta where key = 'schema'")) "5"))
        (should-not (sqlite-select db "select name from pragma_table_info('event') where name = 'turn'"))
        (should-not (sqlite-select db "select name from sqlite_master where name like '%_new'"))
        (sqlite-close db))
      ;; and the next open (nothing forced) finishes the job
      (should (= (drgnx-work-db-migrate-test--version) 6)))))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-keeps-a-schema-5-copy ()
  (drgnx-work-db-migrate-test--with-5
    (should (= (drgnx-work-db-migrate-test--version) 6))
    (let ((copy (concat dir "work.db.schema5")))
      (should (file-exists-p copy))
      (let ((db (sqlite-open copy t)))
        (should (equal (caar (sqlite-select db "select value from meta where key = 'schema'")) "5"))
        (should (equal (caar (sqlite-select db "select count(*) from event")) 16))
        (should (equal (caar (sqlite-select db "select count(*) from node")) 7))
        (should (equal (caar (sqlite-select db "select count(*) from card")) 6))
        (should (equal (caar (sqlite-select db "select data from card where id = 6")) "(:agent \"agent-2\" :files (\"a.el\""))
        (sqlite-close db))
      ;; a second schema-5 file in its place is migrated too, and the first copy is not overwritten
      (let ((hash (drgnx-work-db-migrate-test--bytes copy)))
        (drgnx-work-db-close-all)
        (dolist (f (list "work.db" "work.db-wal" "work.db-shm")) (ignore-errors (delete-file (concat dir f))))
        (drgnx-work-db-migrate-test--load-5 (concat dir "work.db") '("insert into job values ('job-9', 'Late', NULL, '/r/', 'proposed', 1.0, NULL)"))
        (should (= (drgnx-work-db-migrate-test--version) 6))
        (should (equal (drgnx-work-db-migrate-test--bytes copy) hash))
        (should (equal (caar (sqlite-select (drgnx-work-db) "select title from job where id = 'job-9'")) "Late"))))))

(drgnx-work-db-writer-deftest drgnx-work-db/migration-6-is-safe-to-run-twice ()
  (drgnx-work-db-migrate-test--with-5
    (should (= (drgnx-work-db-migrate-test--version) 6))
    (let ((rows (lambda () (list (sqlite-select (drgnx-work-db) "select id, data from event order by id")
                                 (sqlite-select (drgnx-work-db) "select id, data, ref from card order by id")
                                 (sqlite-select (drgnx-work-db) "select id, answers from message order by id")
                                 (sqlite-select (drgnx-work-db) "select * from meta order by key")))))
      (let ((once (funcall rows)))
        ;; the version row lost (a migration cut short elsewhere): every step runs again
        (sqlite-execute (drgnx-work-db) "delete from meta where key = 'schema'")
        (drgnx-work-db-close-all)
        (should (= (drgnx-work-db-migrate-test--version) 6))
        (should (equal (funcall rows) once))))))

(drgnx-work-db-writer-deftest drgnx-work-db/a-newer-schema-is-refused-by-the-writer ()
  (drgnx-work-db-migrate-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))
      (sqlite-execute db "create table meta (key text primary key, value text)")
      (sqlite-execute db "insert into meta values ('schema', '7')")
      (sqlite-close db))
    (let ((err (should-error (drgnx-work-db) :type 'user-error)))
      (should (string-match-p "newer" (cadr err))))))

(drgnx-work-db-writer-deftest drgnx-work-db/no-sql-matches-printed-lisp ()
  ;; the columns say what the SQL asks for; nothing matches the printed text of a plist any more
  (let ((bad nil))
    (dolist (dir '("core" "wb" "modules"))
      (dolist (file (directory-files-recursively (expand-file-name dir drgnx-dir) "\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "like '(:\\|\\(where\\|and\\) [^\"]*data = \\?\\|instr([a-z.]*data, *':" nil t)
            (push (format "%s:%d" (file-name-nondirectory file) (line-number-at-pos)) bad)))))
    (should-not bad)))

;;; work-db-migrate-test.el ends here
