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

(ert-deftest drgnx-coord/a-silent-lease-is-released ()
  (drgnx-coord-test--with
    (let ((t1 (drgnx-coord-test--id 1)))
      (drgnx-coord-claim t1 "a" (drgnx-coord-version))
      (sqlite-execute (drgnx-work-db) "update jtask set lease_until = ? where id = ?" (list (- (float-time) 1) t1))
      (should (equal (drgnx-coord-release-stale) (list (list :task t1 :agent "a"))))
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

;;; coord-test.el ends here
