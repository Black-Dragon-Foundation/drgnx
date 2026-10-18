;;; coord-events-test.el --- batch tests: the event log, the agent registry, review marks (work.db schema 5) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-coord)

(defmacro drgnx-coord-events-test--with (&rest body)
  "BODY with drgnx's data dir a fresh temp dir (`dir') and a job \"j\" of tasks 1 and 2 (no deps)."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-coord-events" t)))
          (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
          (drgnx-work-db--handles nil))
     (unwind-protect
         (progn
           (drgnx-coord-job-create :id "j" :title "J" :plan "p.md" :repo "/r"
                                   :tasks '((:n 1 :title "one" :role "implement") (:n 2 :title "two" :role "implement")))
           ,@body)
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(defun drgnx-coord-events-test--tables ()
  (sort (mapcar #'car (sqlite-select (drgnx-work-db) "select name from sqlite_master where type = 'table'")) #'string<))

(ert-deftest drgnx-coord-events/schema-5-migrates-a-schema-4-db ()
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-coord-events" t)))
         (old (concat dir "old/")) (new (concat dir "new/"))
         (process-environment (cons (concat "DRGNX_DATA_DIR=" new) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (make-directory old t) (make-directory new t)
          (let ((db (sqlite-open (concat old "work.db"))))   ; a work.db as M9b.4 left it
            (sqlite-execute db "create table meta (key text primary key, value text)")
            (pcase-dolist (`(,v . ,sqls) drgnx-work-db--steps) (when (<= v 4) (dolist (sql sqls) (sqlite-execute db sql))))
            (sqlite-execute db "insert into job values ('j', 'J', 'p.md', '/r/', 'running', 1.0, null)")
            (sqlite-execute db "insert into card (job, kind, title, state, at) values ('j', 'ask', 'Q?', 'open', 2.0)")
            (sqlite-execute db "insert into meta values ('schema', '4')")
            (sqlite-close db))
          (copy-file (concat old "work.db") (concat new "work.db"))   ; migrate a copy, as a user's file would be
          (should (= (drgnx-work-db-version) 5))
          (dolist (tb '("event" "agent" "review_mark")) (should (member tb (drgnx-coord-events-test--tables))))
          (should (equal (caar (sqlite-select (drgnx-work-db) "select status from job where id = 'j'")) "running"))
          (should (equal (caar (sqlite-select (drgnx-work-db) "select title from card")) "Q?"))
          (should (= (length (sqlite-select (drgnx-work-db) "select name from sqlite_master where type = 'index' and tbl_name = 'event' and name not like 'sqlite_%'")) 2))
          ;; idempotent: the version row lost (a migration cut short), every step runs again over its own tables
          (sqlite-execute (drgnx-work-db) "update meta set value = '4' where key = 'schema'")
          (drgnx-work-db-close-all)
          (should (= (drgnx-work-db-version) 5))
          (should (equal (caar (sqlite-select (drgnx-work-db) "select title from card")) "Q?")))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))

(ert-deftest drgnx-coord-events/every-writer-leaves-an-event ()
  (drgnx-coord-events-test--with
    (let ((t1 "j#1") (t2 "j#2"))
      (should (plist-get (drgnx-coord-claim t1 "a" 0) :ok))
      (let ((e (car (drgnx-coord-events :kinds '("claim")))))
        (should (equal (list (plist-get e :agent) (plist-get e :job) (plist-get e :task)) (list "a" "j" t1))))
      (should (plist-get (drgnx-coord-set-status t1 "a" "running" 0) :ok))
      (should (= (length (drgnx-coord-events :kinds '("status"))) 1))
      (drgnx-coord-force-status t2 "in-review" "b")
      (should (= (length (drgnx-coord-events :kinds '("status"))) 2))
      (should (plist-get (drgnx-coord-decide :kind "build" :subject "the thing" :task t1 :author "a" :seen 0 :job "j") :ok))
      (let ((e (car (drgnx-coord-events :kinds '("decision")))))
        (should (equal (plist-get e :agent) "a"))
        (should (equal (plist-get e :job) "j"))
        (should (string-match-p "the thing" (plist-get e :summary))))
      (should (plist-get (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "hello" :seen (drgnx-coord-version)) :ok))
      (should (= (length (drgnx-coord-events :kinds '("message"))) 1))
      (let ((id (drgnx-coord-card-create :job "j" :task t1 :kind "ask" :title "Which?")))
        (should (= (length (drgnx-coord-events :kinds '("card"))) 1))
        (should (drgnx-coord-card-settle id "yes"))
        (should (= (length (drgnx-coord-events :kinds '("card"))) 2))
        (should-not (drgnx-coord-card-settle id "again"))      ; nothing happened: no event
        (should (= (length (drgnx-coord-events :kinds '("card"))) 2)))
      ;; a claim that did not happen leaves no event
      (should (plist-get (drgnx-coord-claim t2 "c" (drgnx-coord-version)) :taken))
      (should (= (length (drgnx-coord-events :kinds '("claim"))) 1))
      ;; a lease that ran out
      (sqlite-execute (drgnx-work-db) "update jtask set lease_until = 1.0 where id = ?" (list t1))
      (sqlite-execute (drgnx-work-db) "update jtask set status = 'running' where id = ?" (list t1))
      (should (= (length (drgnx-coord-release-stale)) 1))
      (let ((e (car (drgnx-coord-events :kinds '("release")))))
        (should (equal (list (plist-get e :agent) (plist-get e :task)) (list "a" t1)))))))

(ert-deftest drgnx-coord-events/an-event-and-its-writer-commit-or-roll-back-together ()
  (drgnx-coord-events-test--with
    (cl-letf (((symbol-function 'drgnx-coord--event) (lambda (&rest _) (error "forced"))))
      (should-error (drgnx-coord-claim "j#1" "a" 0))
      (should-error (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "x" :seen 0))
      (should-error (drgnx-coord-card-create :job "j" :kind "ask" :title "T")))
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "ready"))
    (should-not (drgnx-coord-inbox "b"))
    (should-not (drgnx-coord-cards "j"))
    (should-not (drgnx-coord-events))
    ;; and the other way: the event's own failure inside a transaction takes the write with it
    (should-error (drgnx-coord--tx (lambda (db)
                                     (sqlite-execute db "update jtask set status = 'failed' where id = 'j#1'")
                                     (drgnx-coord--event db :kind "status" :summary "x")
                                     (error "forced"))))
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "ready"))
    (should-not (drgnx-coord-events))))

(ert-deftest drgnx-coord-events/summaries-are-one-short-line ()
  (drgnx-coord-events-test--with
    (drgnx-coord-event-add :agent "a" :kind "status" :summary "one\ntwo\r\n\tthree\e[0m")
    (drgnx-coord-event-add :agent "a" :kind "status" :summary (make-string 500 ?x))
    (let ((es (drgnx-coord-events)))
      (should-not (string-match-p "[[:cntrl:]]" (plist-get (car es) :summary)))
      (should (string-prefix-p "one two" (plist-get (car es) :summary)))
      (should (= (length (plist-get (cadr es) :summary)) 200)))
    (should-error (drgnx-coord-event-add :agent "a" :kind "bogus" :summary "x"))
    (should (= (length (drgnx-coord-events)) 2))))

(ert-deftest drgnx-coord-events/events-since-and-filters ()
  (drgnx-coord-events-test--with
    (let* ((a (drgnx-coord-event-add :agent "a" :job "j" :task "j#1" :kind "start" :summary "s1" :at 10.0))
           (b (drgnx-coord-event-add :agent "b" :job "j" :task "j#2" :kind "edit" :summary "s2" :at 20.0 :data '(:path "x.el")))
           (c (drgnx-coord-event-add :agent "a" :job "k" :kind "test" :summary "s3" :at 30.0)))
      (should (< a b c))
      (should (equal (mapcar (lambda (e) (plist-get e :summary)) (drgnx-coord-events)) '("s1" "s2" "s3")))   ; oldest first
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :since a)) (list b c)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :agent "a")) (list a c)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :job "j")) (list a b)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :task "j#2")) (list b)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :kinds '("start" "test"))) (list a c)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-events :since a :limit 1)) (list b)))
      (should (equal (plist-get (cadr (drgnx-coord-events)) :data) '(:path "x.el")))
      (should (= (plist-get (car (drgnx-coord-events)) :at) 10.0))
      (should-not (drgnx-coord-events :agent "nobody")))))

(ert-deftest drgnx-coord-events/escalation-is-a-question ()
  (drgnx-coord-events-test--with
    (drgnx-coord-send :job "j" :sender "a" :recipient "user" :text "[escalation] should I drop the table?" :seen 0)
    (drgnx-coord-send :job "j" :sender "a" :recipient "user" :text "just so you know" :seen 0)
    (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "[escalation] not for the user" :seen 0)
    (should (= (length (drgnx-coord-events :kinds '("question"))) 1))
    (should (= (length (drgnx-coord-events :kinds '("message"))) 2))
    (let ((q (car (drgnx-coord-events :kinds '("question")))))
      (should (equal (plist-get q :agent) "a"))
      (should (string-match-p "drop the table" (plist-get q :summary))))
    (should (= (length (drgnx-coord-open-questions)) 1))))

(ert-deftest drgnx-coord-events/an-answer-closes-its-question ()
  (drgnx-coord-events-test--with
    (let ((q1 (drgnx-coord-event-add :agent "a" :kind "question" :summary "one?"))
          (q2 (drgnx-coord-event-add :agent "b" :kind "question" :summary "two?")))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-open-questions)) (list q1 q2)))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-open-questions "b")) (list q2)))
      (drgnx-coord-event-add :agent "user" :kind "answer" :summary "yes" :data (list :question q1))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-open-questions)) (list q2)))
      ;; an answer to no question, or one that names another, closes nothing
      (drgnx-coord-event-add :agent "user" :kind "answer" :summary "stray")
      (drgnx-coord-event-add :agent "user" :kind "answer" :summary "other" :data (list :question 9999))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (drgnx-coord-open-questions)) (list q2)))
      (drgnx-coord-event-add :agent "user" :kind "answer" :summary "no" :data (list :question q2))
      (should-not (drgnx-coord-open-questions)))))

(ert-deftest drgnx-coord-events/registry-round-trip ()
  (drgnx-coord-events-test--with
    (should-not (drgnx-coord-agents))
    (should-not (drgnx-coord-agent "s-1"))
    (drgnx-coord-agent-register :id "s-1" :kind "claude" :name "claude · drgnx" :cwd "/r" :worktree "/r/.claude/worktrees/w"
                                :branch "w" :base "main" :plan "p.md" :task "j#1" :pid 4242)
    (let ((a (drgnx-coord-agent "s-1")))
      (dolist (kv '((:kind "claude") (:name "claude · drgnx") (:cwd "/r") (:worktree "/r/.claude/worktrees/w") (:branch "w")
                    (:base "main") (:plan "p.md") (:task "j#1") (:pid 4242)))
        (should (equal (plist-get a (car kv)) (cadr kv))))
      (should (floatp (plist-get a :started)))
      (should (floatp (plist-get a :seen))))
    (drgnx-coord-agent-register :id "s-2" :kind "codex")
    (should (equal (mapcar (lambda (a) (plist-get a :id)) (drgnx-coord-agents)) '("s-1" "s-2")))
    ;; registering again updates what is given, keeps the rest and when it started
    (let ((started (plist-get (drgnx-coord-agent "s-1") :started)))
      (drgnx-coord-agent-register :id "s-1" :task "j#2")
      (let ((a (drgnx-coord-agent "s-1")))
        (should (equal (plist-get a :task) "j#2"))
        (should (equal (plist-get a :branch) "w"))
        (should (= (plist-get a :started) started))))
    (sqlite-execute (drgnx-work-db) "update agent set seen = 1.0 where id = 's-1'")
    (should (> (drgnx-coord-agent-seen "s-1") 1.0))
    (should (> (plist-get (drgnx-coord-agent "s-1") :seen) 1.0))
    (should-not (drgnx-coord-agent-seen "nobody"))
    (should-not (drgnx-coord-agent "nobody"))))

(ert-deftest drgnx-coord-events/marks-round-trip ()
  (drgnx-coord-events-test--with
    (should-not (drgnx-coord-review-marks "a"))
    (drgnx-coord-review-mark "a" "x.el" "accepted" "h1")
    (drgnx-coord-review-mark "a" "y.el" "pending" "h2")
    (drgnx-coord-review-mark "b" "x.el" "pending" "h3")
    (let ((m (drgnx-coord-review-marks "a")))
      (should (equal (mapcar #'car m) '("x.el" "y.el")))
      (should (equal (plist-get (cdr (assoc "x.el" m)) :state) "accepted"))
      (should (equal (plist-get (cdr (assoc "x.el" m)) :hash) "h1"))
      (should (floatp (plist-get (cdr (assoc "x.el" m)) :at))))
    ;; the same file again: replaced, not added
    (drgnx-coord-review-mark "a" "x.el" "pending" "h9")
    (should (= (length (drgnx-coord-review-marks "a")) 2))
    (should (equal (plist-get (cdr (assoc "x.el" (drgnx-coord-review-marks "a"))) :state) "pending"))
    (should (equal (plist-get (cdr (assoc "x.el" (drgnx-coord-review-marks "a"))) :hash) "h9"))
    (should (equal (plist-get (cdr (assoc "x.el" (drgnx-coord-review-marks "b"))) :hash) "h3"))
    (should-error (drgnx-coord-review-mark "a" "z.el" "approved" "h"))))

;;; coord-events-test.el ends here
