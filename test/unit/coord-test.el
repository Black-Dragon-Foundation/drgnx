;;; coord-test.el --- batch tests: the coordination store (jobs, tasks, leases, decisions, messages) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-coord)

(defmacro drgnx-coord-test--with (&rest body)
  "BODY with drgnx's data dir a fresh temp dir and a job \"j\": tasks 1, 2 (no deps), 3 (on 1 and 2), 4 (on 3)."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-coord" t)))
          (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
          (drgnx-work-db--handles nil))
     (unwind-protect
         (progn
           (drgnx-coord-job-create :id "j" :title "J" :plan "p.md" :repo "/r"
                                   :tasks '((:n 1 :title "one" :role "implement") (:n 2 :title "two" :role "implement")
                                            (:n 3 :title "three" :role "test" :deps (1 2)) (:n 4 :title "four" :role "docs" :deps (3))))
           ,@body)
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(defun drgnx-coord-test--status (n) (plist-get (seq-find (lambda (x) (= (plist-get x :n) n)) (drgnx-coord-tasks "j")) :status))
(defun drgnx-coord-test--id (n) (plist-get (seq-find (lambda (x) (= (plist-get x :n) n)) (drgnx-coord-tasks "j")) :id))

(ert-deftest drgnx-coord/a-job-s-tasks-start-ready-or-pending-by-their-dependencies ()
  (drgnx-coord-test--with
    (should (equal (mapcar #'drgnx-coord-test--status '(1 2 3 4)) '("ready" "ready" "pending" "pending")))
    (should (equal (plist-get (seq-find (lambda (x) (= (plist-get x :n) 3)) (drgnx-coord-tasks "j")) :deps)
                   (list (drgnx-coord-test--id 1) (drgnx-coord-test--id 2))))))

(ert-deftest drgnx-coord/one-claim-wins ()
  ;; two processes woken at the same instant race through 30 ready tasks: each task goes to exactly one of them
  (drgnx-coord-test--with
    (drgnx-coord-job-create :id "race" :tasks (mapcar (lambda (n) (list :n n :title "t")) (number-sequence 1 30)))
    (drgnx-work-db-close-all)
    (let* ((at (+ (float-time) 3)) (outs nil)
           (start (lambda (agent)
                    (let ((b (generate-new-buffer " *claim*" t)))
                      (push b outs)
                      (make-process :name agent :buffer b :noquery t
                                    :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                   "--eval" "(setq load-prefer-newer t)"
                                                   "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-coord"
                                                   "--eval" "(setq drgnx-coord-writer 'local)"   ; a test's own writer
                                                   "--eval" (format "(progn (drgnx-coord-version) (sleep-for (max 0 (- %f (float-time))))
                                                                       (dotimes (i 30)
                                                                         (princ (format \"RESULT:%%S\\n\" (drgnx-coord-claim (format \"race#%%d\" (1+ i)) %S (drgnx-coord-version))))))"
                                                                    at agent))))))
           (procs (list (funcall start "a") (funcall start "b"))))
      (let ((deadline (+ (float-time) 30))) (while (and (seq-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05)))
      (let ((answers (apply #'append
                            (mapcar (lambda (b) (with-current-buffer b
                                                  (goto-char (point-min))
                                                  (let (l) (while (re-search-forward "^RESULT:\\(.*\\)$" nil t)
                                                             (push (car (read-from-string (match-string 1))) l))
                                                       l)))
                                    outs))))
        (should (= (length answers) 60))                                       ; nobody failed on the way
        (should (= (length (seq-filter (lambda (a) (plist-get a :ok)) answers)) 30))
        (should (= (length (seq-filter (lambda (a) (plist-get a :taken)) answers)) 30))
        (should (seq-every-p (lambda (task) (member (plist-get task :agent) '("a" "b"))) (drgnx-coord-tasks "race"))))
      (mapc #'kill-buffer outs))))

(ert-deftest drgnx-coord/concurrent-held-writes-and-hub-writes ()
  ;; two Emacs processes write the held-count (read, then write) in a loop while this one writes decisions: the work
  ;; database waits for its lock (busy_timeout) — nobody fails with "database is locked". The overlap is made, not hoped
  ;; for: each child reports STARTED after its first write and keeps writing until this test creates the stop file (bounded
  ;; by a time cap so a child can never hang; it ends with DONE and the number of writes it made); the decisions are written only while both children are writing.
  (drgnx-coord-test--with
    (drgnx-coord-version)                                                      ; this Emacs has the database open (WAL)
    (let* ((outs nil) (procs nil) (written 0)
           (stop (expand-file-name "stop-held-writers" dir))
           (start (lambda (agent)
                    (let ((b (generate-new-buffer " *held*" t)))
                      (push b outs)
                      (make-process :name agent :buffer b :noquery t
                                    :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                   "--eval" "(setq load-prefer-newer t)"
                                                   "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-coord"
                                                   "--eval" "(setq drgnx-coord-writer 'local)"   ; a test's own writer
                                                   "--eval" (format "(let ((i 0) (cap (+ (float-time) 20)))
                                                                      (princ (condition-case e
                                                                                 (progn
                                                                                   (while (and (< (float-time) cap) (not (file-exists-p %S)))
                                                                                     (drgnx-coord-note-held %S (= 0 (%% i 2)))
                                                                                     (setq i (1+ i))
                                                                                     (when (= i 1) (princ \"STARTED\\n\")))
                                                                                   (format \"DONE %%d\\n\" i))
                                                                               (error (format \"ERR:%%S\\n\" e)))))"
                                                                    stop agent))))))
           (wait (lambda (done seconds)
                   (let ((deadline (+ (float-time) seconds)))
                     (while (and (not (funcall done)) (< (float-time) deadline)) (accept-process-output nil 0.01))))))
      (unwind-protect
          (progn
            (setq procs (list (funcall start "a") (funcall start "b")))
            (funcall wait (lambda () (seq-every-p (lambda (b) (with-current-buffer b (string-match-p "STARTED" (buffer-string)))) outs)) 30)
            (dolist (b outs)
              (should (string-match-p "STARTED" (with-current-buffer b (buffer-string)))))
            (dotimes (_ 30)                                                    ; the children are writing the whole time
              (drgnx-coord-decide :kind "build" :subject (format "s%d" written) :reason "r" :author "user" :seen (drgnx-coord-version))
              (setq written (1+ written))
              (accept-process-output nil 0.005))
            (unless (seq-every-p #'process-live-p procs)                       ; the writes did overlap the children's
              (accept-process-output nil 0.1)
              (ert-fail (list "a writer ended before the decisions were written" :written written
                              :outs (mapcar (lambda (b) (with-current-buffer b (buffer-string))) (reverse outs)))))
            (write-region "" nil stop nil 'silent)
            (funcall wait (lambda () (not (seq-some #'process-live-p procs))) 30)
            (should-not (seq-some #'process-live-p procs))
            (accept-process-output nil 0.1)
            (dolist (b outs)
              (let ((out (with-current-buffer b (buffer-string))))
                (should-not (string-match-p "ERR" out))
                (should (string-match-p "^DONE [0-9]+$" out))))
            (should (= written (length (drgnx-coord-decisions-since 0)))))
        (dolist (p procs) (when (process-live-p p) (kill-process p)))
        (mapc #'kill-buffer outs)))))

(ert-deftest drgnx-coord/a-stale-version-is-held-with-every-change ()
  (drgnx-coord-test--with
    (let ((v0 (drgnx-coord-version)))
      (drgnx-coord-decide :kind "wont-build" :subject "the old parser" :reason "replaced by tree-sitter" :author "user" :seen v0)
      (drgnx-coord-decide :kind "build" :subject "the new parser" :task (drgnx-coord-test--id 2) :reason "x" :author "user"
                          :seen (drgnx-coord-version))
      (let ((r (drgnx-coord-claim (drgnx-coord-test--id 1) "a" v0)))
        (should (plist-get r :held))
        (should (equal (sort (mapcar (lambda (d) (plist-get d :subject)) (plist-get r :changes)) #'string<)
                       '("the new parser" "the old parser"))))
      (should (equal (drgnx-coord-test--status 1) "ready"))
      (should (plist-get (drgnx-coord-claim (drgnx-coord-test--id 1) "a" (drgnx-coord-version)) :ok))
      (should (equal (drgnx-coord-test--status 1) "claimed")))))

(ert-deftest drgnx-coord/seen-version-ahead-rejected ()
  ;; a seen_version the log has not reached is no claim to have read it: nothing is written
  (drgnx-coord-test--with
    (let ((ahead (+ (drgnx-coord-version) 5)))
      (should-error (drgnx-coord-claim (drgnx-coord-test--id 1) "a" ahead))
      (should-error (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "x" :seen ahead))
      (should-error (drgnx-coord-decide :kind "build" :subject "z" :reason "r" :author "a" :seen ahead))
      (should-error (drgnx-coord-set-status (drgnx-coord-test--id 1) "a" "running" ahead))
      (should (equal (drgnx-coord-test--status 1) "ready"))
      (should-not (drgnx-coord-inbox "b"))
      (should (= (drgnx-coord-version) 0)))))

(ert-deftest drgnx-coord/done-readies-the-dependents ()
  (drgnx-coord-test--with
    (let ((t1 (drgnx-coord-test--id 1)) (t2 (drgnx-coord-test--id 2)))
      (drgnx-coord-claim t1 "a" (drgnx-coord-version))
      (drgnx-coord-claim t2 "b" (drgnx-coord-version))
      (should (plist-get (drgnx-coord-set-status t1 "a" "done" (drgnx-coord-version)) :ok))
      (should (equal (drgnx-coord-test--status 3) "pending"))
      (drgnx-coord-set-status t2 "b" "done" (drgnx-coord-version))
      (should (equal (drgnx-coord-test--status 3) "ready"))
      (should (equal (drgnx-coord-test--status 4) "pending"))
      ;; only the holder changes a task's status
      (should-not (plist-get (drgnx-coord-set-status (drgnx-coord-test--id 3) "z" "done" (drgnx-coord-version)) :ok))
      (should (equal (drgnx-coord-test--status 3) "ready"))
      (drgnx-coord-claim (drgnx-coord-test--id 3) "c" (drgnx-coord-version))
      (should (equal (plist-get (drgnx-coord-set-status (drgnx-coord-test--id 3) "z" "done" (drgnx-coord-version)) :taken) "c")))))

(ert-deftest drgnx-coord/a-claim-waits-for-the-dependencies ()
  (drgnx-coord-test--with
    (let ((r (drgnx-coord-claim (drgnx-coord-test--id 3) "a" (drgnx-coord-version))))
      (should (equal (plist-get r :not-ready) (list (drgnx-coord-test--id 1) (drgnx-coord-test--id 2)))))))

(ert-deftest drgnx-coord/a-decision-outside-its-own-task-is-proposed ()
  (drgnx-coord-test--with
    (let ((t1 (drgnx-coord-test--id 1)) (t2 (drgnx-coord-test--id 2)))
      (drgnx-coord-claim t1 "a" (drgnx-coord-version))
      (should (equal (plist-get (drgnx-coord-decide :kind "build" :subject "x" :task t1 :reason "r" :author "a" :seen (drgnx-coord-version)) :status)
                     "current"))
      (should (equal (plist-get (drgnx-coord-decide :kind "wont-build" :subject "y" :task t2 :reason "r" :author "a" :seen (drgnx-coord-version)) :status)
                     "proposed"))
      (let ((n (plist-get (drgnx-coord-decide :kind "build" :subject "y" :task t2 :reason "r" :author "user" :seen (drgnx-coord-version)) :n)))
        (should n)
        (let* ((before (drgnx-coord-version))
               (r (drgnx-coord-decide :kind "replaces" :subject "y, differently" :task t2 :reason "r" :author "user"
                                      :replaces n :seen before)))
          (should (equal (plist-get r :status) "current"))
          (let ((since (drgnx-coord-decisions-since (1- before))))
            (should (seq-find (lambda (d) (and (= (plist-get d :n) n) (equal (plist-get d :status) "replaced"))) since))
            (should (seq-find (lambda (d) (= (plist-get d :n) (plist-get r :n))) since))))))))

(ert-deftest drgnx-coord/an-agent-never-replaces-the-user-s-decision ()
  ;; "the user's decisions always win": an agent replacing one only proposes
  (drgnx-coord-test--with
    (let* ((t1 (drgnx-coord-test--id 1))
           (users (plist-get (drgnx-coord-decide :kind "wont-build" :subject "XML export" :reason "r" :author "user" :seen 0) :n)))
      (drgnx-coord-claim t1 "a" (drgnx-coord-version))
      (let ((r (drgnx-coord-decide :kind "replaces" :subject "XML export after all" :task t1 :reason "r" :author "a"
                                   :replaces users :seen (drgnx-coord-version))))
        (should (equal (plist-get r :status) "proposed")))
      (should (equal (plist-get (seq-find (lambda (d) (equal (plist-get d :n) users)) (drgnx-coord-decisions-since 0)) :status)
                     "current"))
      ;; its own decision in its own task it may replace
      (let* ((own (plist-get (drgnx-coord-decide :kind "build" :subject "a parser" :task t1 :reason "r" :author "a" :seen (drgnx-coord-version)) :n))
             (r (drgnx-coord-decide :kind "replaces" :subject "a better parser" :task t1 :reason "r" :author "a" :replaces own
                                    :seen (drgnx-coord-version))))
        (should (equal (plist-get r :status) "current"))
        (should (equal (plist-get (seq-find (lambda (d) (equal (plist-get d :n) own)) (drgnx-coord-decisions-since 0)) :status)
                       "replaced"))))))

(ert-deftest drgnx-coord/an-agent-s-own-decision-keeps-it-current-and-decisions-are-rate-limited ()
  (drgnx-coord-test--with
    (drgnx-coord-claim (drgnx-coord-test--id 1) "a" 0)
    (drgnx-coord-decide :kind "build" :subject "x" :task (drgnx-coord-test--id 1) :reason "r" :author "a" :seen 0)
    (should (= (drgnx-coord-seen "a") (drgnx-coord-version)))         ; not behind its own decision
    (dotimes (i 5) (drgnx-coord-decide :kind "build" :subject (format "y%d" i) :reason "r" :author "a" :seen (drgnx-coord-version)))
    (let ((r (drgnx-coord-decide :kind "build" :subject "the 7th" :reason "r" :author "a" :seen (drgnx-coord-version))))
      (should-not (plist-get r :ok))
      (should (string-search "too many decisions" (plist-get r :error))))))

(ert-deftest drgnx-coord/decisions-belong-to-their-job ()
  (drgnx-coord-test--with
    (drgnx-coord-decide :kind "build" :subject "for j" :job "j" :reason "r" :author "user" :seen 0)
    (drgnx-coord-decide :kind "build" :subject "for k" :job "k" :reason "r" :author "user" :seen (drgnx-coord-version))
    (should (equal (mapcar (lambda (d) (plist-get d :subject)) (drgnx-coord-decisions-since 0 "j")) '("for j")))
    (should (= (length (drgnx-coord-decisions-since 0)) 2))))

(ert-deftest drgnx-coord/a-task-waiting-on-the-user-keeps-its-claim ()
  (drgnx-coord-test--with
    (let ((t1 (drgnx-coord-test--id 1)))
      (drgnx-coord-claim t1 "a" 0)
      (drgnx-coord-set-status t1 "a" "in-review" 0)
      (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where id = ?" (list (- (float-time) 1) t1))
      (should-not (drgnx-coord-release-stale))
      (should (equal (drgnx-coord-test--status 1) "in-review")))))

(ert-deftest drgnx-coord/escalations-to-the-user-are-never-held-as-a-full-queue ()
  (drgnx-coord-test--with
    (dotimes (i 25) (drgnx-coord-send :sender (format "s%d" i) :recipient "user" :text "decide" :seen 0))
    (should-not (seq-find (lambda (m) (equal (plist-get m :state) "held")) (drgnx-coord-inbox "user")))))

(ert-deftest drgnx-coord/a-silent-lease-is-released ()
  (drgnx-coord-test--with
    (let ((t1 (drgnx-coord-test--id 1)))
      (drgnx-coord-claim t1 "a" (drgnx-coord-version))
      (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where id = ?" (list (- (float-time) 1) t1))
      (should (equal (drgnx-coord-release-stale) (list (list :task t1 :agent "a" :job "j"))))
      (should (equal (drgnx-coord-test--status 1) "ready"))
      (should-not (plist-get (seq-find (lambda (x) (= (plist-get x :n) 1)) (drgnx-coord-tasks "j")) :agent)))))

(ert-deftest drgnx-coord/messages-never-go-backwards-and-loops-are-held ()
  (drgnx-coord-test--with
    (let* ((id (plist-get (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "hi" :seen (drgnx-coord-version)) :id)))
      (drgnx-coord-mark id "delivered") (drgnx-coord-mark id "read") (drgnx-coord-mark id "acted")
      (drgnx-coord-mark id "delivered")
      (should (equal (plist-get (drgnx-coord-message id) :state) "acted"))
      (should (plist-get (drgnx-coord-message id) :acted)))
    (dotimes (_ 5) (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "again" :seen (drgnx-coord-version)))
    (let ((r (drgnx-coord-send :job "j" :sender "a" :recipient "b" :text "7th" :seen (drgnx-coord-version))))
      (should (equal (plist-get r :state) "held"))
      (should (equal (plist-get (drgnx-coord-message (plist-get r :id)) :reason) "too many between these two")))
    (dotimes (i 20) (drgnx-coord-send :job "j" :sender (format "s%d" i) :recipient "c" :text "x" :seen (drgnx-coord-version)))
    (let ((r (drgnx-coord-send :job "j" :sender "s99" :recipient "c" :text "21st" :seen (drgnx-coord-version))))
      (should (equal (plist-get r :state) "held"))
      (should (equal (plist-get (drgnx-coord-message (plist-get r :id)) :reason) "queue full")))
    ;; a stale sender is held too, and nothing is written
    (let ((count (length (drgnx-coord-inbox "d"))))
      (drgnx-coord-decide :kind "build" :subject "z" :reason "r" :author "user" :seen (drgnx-coord-version))
      (should (plist-get (drgnx-coord-send :job "j" :sender "a" :recipient "d" :text "late" :seen 0) :held))
      (should (= (length (drgnx-coord-inbox "d")) count)))))

(ert-deftest drgnx-coord/the-user-s-own-messages-count-towards-the-pair-rate-and-answer-agents ()
  ;; the user's Emacs sends with no sender: still one sender for the loop limit, and a reply to an agent
  (drgnx-coord-test--with
    (let ((id (plist-get (drgnx-coord-send :job "j" :sender "a" :recipient "user" :text "question" :seen 0) :id)))
      (drgnx-coord-mark id "delivered") (drgnx-coord-mark id "read")
      (drgnx-coord-send :job "j" :sender nil :recipient "a" :text "answer" :seen 0)
      (should (equal (plist-get (drgnx-coord-message id) :state) "acted")))
    (dotimes (_ 4) (drgnx-coord-send :job "j" :sender nil :recipient "a" :text "more" :seen 0))   ; 5 sent so far
    (should (equal (plist-get (drgnx-coord-send :job "j" :sender nil :recipient "a" :text "6th" :seen 0) :state) "queued"))
    (should (equal (plist-get (drgnx-coord-send :job "j" :sender nil :recipient "a" :text "7th" :seen 0) :state) "held"))))

;;; coord-test.el ends here
