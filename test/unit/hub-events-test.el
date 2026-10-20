;;; hub-events-test.el --- batch tests: the hub turns agent turns, edits, permissions, reviews and merges into events -*- lexical-binding: t -*-
;; The hub is served in this Emacs (test/fixtures/job-fixture.el: a git repo, the mock ACP agent on every route).
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defmacro drgnx-hub-events-test--with (plan-text &rest body)
  "BODY in the job fixture (PLAN-TEXT), subscribed to the hub: HEARD holds the events it sent, newest first."
  (declare (indent 1))
  `(drgnx-job-run-test--with ,plan-text
     (let* ((heard nil) (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) heard)))))
       (drgnx-hub-connect)
       (drgnx-job-run-test--wait (lambda () (process-live-p drgnx-hub--events)) 5)
       ,@body)))

(defun drgnx-hub-events-test--kinds (agent)
  (mapcar (lambda (e) (plist-get e :kind)) (drgnx-coord-events :agent agent)))

(defun drgnx-hub-events-test--of (agent kind)
  (seq-filter (lambda (e) (equal (plist-get e :kind) kind)) (drgnx-coord-events :agent agent)))

(defun drgnx-hub-events-test--turns (agent kind)
  "AGENT's turn events of KIND (`start' or `stop' with :turn t)."
  (seq-filter (lambda (e) (eq (plist-get (plist-get e :data) :turn) t)) (drgnx-hub-events-test--of agent kind)))

(defun drgnx-hub-events-test--session (cwd)
  "A mock session the hub holds, in CWD, idle."
  (let ((s (drgnx-agents-start "mock" cwd)))
    (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
    s))

(ert-deftest drgnx-hub-events/a-native-turn-is-start-edit-stop ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let* ((s (drgnx-hub-events-test--session repo)) (id (drgnx-agent-session-id s))
           (file (expand-file-name "README" repo)) (head (drgnx-job-run-test--git repo "rev-parse" "HEAD")))
      (drgnx-agents-send s (concat "write " file))
      ;; the write waits for the user's review; the user accepts it (from their Emacs, through the hub)
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-reviews s))))
      (drgnx-hub-call-sync "agents/do" (list :id id :op "review" :item (plist-get (car (drgnx-agent-session-reviews s)) :id)))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-hub-events-test--turns id "stop"))))
      ;; the session's life (start, with the HEAD of its folder), then the turn: one edit, though the agent also reported
      ;; the write as an edit tool call
      (should (equal (drgnx-hub-events-test--kinds id) '("start" "start" "edit" "stop")))
      (let ((life (car (drgnx-hub-events-test--of id "start"))) (turn (cadr (drgnx-hub-events-test--of id "start"))))
        (should (equal (plist-get (plist-get life :data) :head) head))
        (should-not (plist-get (plist-get life :data) :turn))
        (should (eq (plist-get (plist-get turn :data) :turn) t)))
      (should (eq (plist-get (plist-get (car (drgnx-hub-events-test--of id "stop")) :data) :turn) t))
      (should (seq-find (lambda (e) (equal (plist-get e :kind) "edit")) (drgnx-agent-session-entries s)))   ; the mock did report it
      (let ((edit (plist-get (car (drgnx-hub-events-test--of id "edit")) :data)))
        (should (equal (plist-get edit :paths) (list file))))
      ;; a rejected write is no edit
      (drgnx-agents-send s (concat "write " file))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-reviews s))))
      (drgnx-hub-call-sync "agents/do" (list :id id :op "review" :item (plist-get (car (drgnx-agent-session-reviews s)) :id) :reject t))
      (should (drgnx-job-run-test--wait (lambda () (= 2 (length (drgnx-hub-events-test--turns id "stop"))))))
      (should (= 1 (length (drgnx-hub-events-test--of id "edit"))))
      ;; the session ends: the stop of its life
      (drgnx-agents-kill s)
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (e) (not (plist-get (plist-get e :data) :turn)))
                                                             (drgnx-hub-events-test--of id "stop"))))))))

(ert-deftest drgnx-hub-events/a-tool-call-that-wrote-files-is-an-edit ()
  ;; an agent that writes files itself reports a completed edit tool call with diffs: one event per call, without the
  ;; paths a write request of the same turn recorded already
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let* ((s (drgnx-agents--make :id "s-t" :name "t" :cwd repo :status 'idle)))
      (drgnx-hub--session-events s)
      (setf (drgnx-agent-session-status s) 'busy)
      (drgnx-hub--session-events s)
      (drgnx-hub--review-edit s (list :path (concat repo "d.el")))      ; a write request the user accepted
      (setf (drgnx-agent-session-entries s)
            (list (list :type 'user :text "go")
                  (list :type 'tool :id "e1" :kind "edit" :status "in_progress" :title "Edit a.el"
                        :content (list (list :type "diff" :path (concat repo "a.el") :newText "x")))
                  (list :type 'tool :id "r1" :kind "read" :status "completed" :title "Read b.el")
                  (list :type 'tool :id "task" :kind "think" :status "completed"
                        :children (list (list :type 'tool :id "e2" :kind "edit" :status "completed" :title "Write c.el"
                                              :content (vector (list :type "diff" :path (concat repo "c.el") :newText "y")
                                                               (list :type "diff" :path (concat repo "d.el") :newText "z")))))
                  (list :type 'tool :id "e3" :kind "edit" :status "completed" :title "Write d.el"
                        :content (list (list :type "diff" :path (concat repo "d.el") :newText "z")))))
      (drgnx-hub--session-events s)
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :data) :paths)) (drgnx-hub-events-test--of "s-t" "edit"))
                     (list (list (concat repo "d.el")) (list (concat repo "c.el")))))   ; d.el once; e3 covered whole
      (plist-put (nth 1 (drgnx-agent-session-entries s)) :status "completed")
      (drgnx-hub--session-events s)
      (drgnx-hub--session-events s)                     ; once per tool call
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :data) :paths)) (drgnx-hub-events-test--of "s-t" "edit"))
                     (list (list (concat repo "d.el")) (list (concat repo "c.el")) (list (concat repo "a.el")))))
      ;; the scan starts at the first tool call not yet complete: nothing before it is walked again
      (should (= (plist-get (gethash "s-t" drgnx-hub--event-state) :from) 5))
      (setf (drgnx-agent-session-status s) 'idle)
      (drgnx-hub--session-events s)
      (should (equal (drgnx-hub-events-test--kinds "s-t") '("start" "start" "edit" "edit" "edit" "stop"))))))

(ert-deftest drgnx-hub-events/a-permission-is-a-question-until-answered ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let* ((s (drgnx-hub-events-test--session repo)) (id (drgnx-agent-session-id s)))
      (drgnx-agents-send s "permission")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (let* ((p (car (drgnx-agent-session-permissions s))) (q (car (drgnx-coord-open-questions id))))
        (should q)
        (should (equal (plist-get (plist-get q :data) :permission) (plist-get p :id)))
        (should (string-search "rm -rf build" (plist-get q :summary)))
        (drgnx-hub-call-sync "agents/permission" (list :id id :request (plist-get p :id) :option "allow"))
        (should (drgnx-job-run-test--wait (lambda () (null (drgnx-coord-open-questions id)))))
        ;; who answered, and how: the user, allow
        (let ((a (car (drgnx-coord-events :kinds '("answer")))))
          (should (equal (plist-get a :agent) "user"))
          (should (equal (plist-get (plist-get a :data) :question) (plist-get q :id)))
          (should (equal (plist-get (plist-get a :data) :by) "user"))
          (should (equal (plist-get (plist-get a :data) :option) "allow"))))
      ;; Stop cancels a pending one; an agent that ends drops it: answered by drgnx, no option
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) (quote idle))))
      (drgnx-agents-send s "permission")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-agents-stop s)
      (should (drgnx-job-run-test--wait (lambda () (null (drgnx-coord-open-questions id)))))
      (let ((a (car (last (drgnx-coord-events :kinds '("answer"))))))
        (should (equal (plist-get (plist-get a :data) :by) "drgnx"))
        (should-not (plist-get (plist-get a :data) :option))
        (should (string-search "cancelled" (plist-get a :summary))))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) (quote idle))))
      (drgnx-agents-send s "permission")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-agents-kill s)
      (should (drgnx-job-run-test--wait (lambda () (null (drgnx-coord-open-questions id)))))
      (should (string-search "dropped" (plist-get (car (last (drgnx-coord-events :kinds '("answer")))) :summary))))))
(ert-deftest drgnx-hub-events/review-verdicts-are-events ()
  (drgnx-hub-events-test--with "# One\n\n### Task 1: first\n"
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 30))
      (let ((review (car (drgnx-coord-events :job id :kinds '("review"))))
            (merged (seq-find (lambda (e) (equal (plist-get (plist-get e :data) :status) "merged"))
                              (drgnx-coord-events :job id :kinds '("status")))))
        (should (eq (plist-get (plist-get review :data) :verdict) 'pass))
        (should (equal (plist-get review :task) (format "%s#1" id)))
        (should (plist-get review :agent))              ; the reviewer
        (should merged)
        (should (equal (plist-get merged :task) (format "%s#1" id))))
      ;; the task's agent was registered with the HEAD its worktree started from: its diffs are against that
      (let ((row (seq-find (lambda (r) (equal (plist-get r :branch) (format "job/%s-1" id))) (drgnx-coord-agents))))
        (should row)
        (should (equal (plist-get row :base) (drgnx-job-run-test--git repo "rev-parse" "main")))
        (should (equal (plist-get row :task) (format "%s#1" id))))))
  ;; a failed review: verdict fail, with the reasons
  (drgnx-hub-events-test--with "# One\n\n### Task 1: first\n"
    (let ((process-environment (cons "MOCK_ACP_VERDICT=fail" process-environment)) (id nil))
      (setq id (drgnx-job-propose plan))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (drgnx-coord-events :job id :kinds '("review"))) 30))
      (let ((review (car (drgnx-coord-events :job id :kinds '("review")))))
        (should (eq (plist-get (plist-get review :data) :verdict) 'fail))
        (should (string-search "rename foo to bar" (plist-get review :summary))))
      (drgnx-job-stop id))))

(ert-deftest drgnx-hub-events/broadcast-is-batched ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let ((before (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0))
          (drgnx-hub-events-interval 1.0))               ; wide: a loaded machine's 50 adds still fit in one window
      ;; 50 adds in 0.1 s, each followed by the notify a coordination server sends
      (dotimes (i 50)
        (drgnx-coord-event-add :agent "ext:t:1" :kind "test" :summary (format "run %d" i) :data (list :passed i :failed 0))
        (drgnx-hub-call "coord/notify" nil #'ignore)
        (when (zerop (% i 10)) (accept-process-output nil 0.02)))
      ;; the notifies are served once a broadcast is pending (the timer layer holds one per key, the timer is its own)
      (should (drgnx-test-wait (lambda () (gethash 'hub-events drgnx-timer--table)) :what "the first broadcast armed"))
      (should (drgnx-job-run-test--wait (lambda () (assoc "events" heard)) 3))
      (drgnx-test-pause 1.2)       ; a second batch would be here now
      (let ((batches (seq-filter (lambda (h) (equal (car h) "events")) heard)))
        (should (= (length batches) 1))
        (let ((d (cdar batches)))
          (should (eql (plist-get d :since) before))
          (should (= (length (plist-get d :events)) 50))
          (should (equal (plist-get (car (plist-get d :events)) :summary) "run 0"))
          ;; data comes as Lisp text, read back whole
          (should (equal (car (read-from-string (plist-get (car (last (plist-get d :events))) :data))) '(:passed 49 :failed 0))))))))

(ert-deftest drgnx-hub-events/test-events-reach-the-status-bar ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let ((noted nil))
      (cl-letf (((symbol-function 'drgnx-statusbar-note-tests) (lambda (&rest args) (push args noted))))
        (drgnx-coord-event-add :agent "ext:t:1" :kind "test" :summary "12 passed" :data '(:passed 12 :failed 1))
        (drgnx-coord-event-add :agent "ext:t:1" :kind "edit" :summary "1 file" :data '(:paths ("a")))
        (drgnx-hub-call "coord/notify" nil #'ignore)
        (should (drgnx-job-run-test--wait (lambda () noted) 3)))
      (should (equal noted '((12 1 "ext:t:1")))))))

(ert-deftest drgnx-hub-events/events-since-catches-up ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let ((before (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0)))
      (dotimes (i 5) (drgnx-coord-event-add :agent "a" :kind "decision" :summary (format "d%d" i)))
      (let* ((r (drgnx-hub-call-sync "events/since" (list :since before :limit 3)))
             (got (plist-get r :events)))
        (should (equal (mapcar (lambda (e) (plist-get e :summary)) got) '("d0" "d1" "d2")))
        (should (eql (plist-get r :last) (plist-get (car (last got)) :id)))
        (let ((rest (drgnx-hub-call-sync "events/since" (list :since (plist-get r :last)))))
          (should (equal (mapcar (lambda (e) (plist-get e :summary)) (plist-get rest :events)) '("d3" "d4"))))))))

(ert-deftest drgnx-hub-events/head-is-read-from-the-repository-files ()
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let ((head (drgnx-job-run-test--git repo "rev-parse" "HEAD")) (wt (concat root "wt/")))
      (should (equal (drgnx-job-git-head (concat repo "docs/plans/")) head))   ; from a folder inside
      (drgnx-job-run-test--git repo "worktree" "add" "-q" "-b" "side" wt "main")
      (drgnx-job-run-test--git repo "pack-refs" "--all")                         ; refs only in packed-refs now
      (should (equal (drgnx-job-git-head wt) head))
      (should (equal (drgnx-job-git-head repo) head))
      (drgnx-job-run-test--git wt "checkout" "-q" "--detach")
      (should (equal (drgnx-job-git-head wt) head))
      (should-not (drgnx-job-git-head root))
      (should-not (drgnx-job-git-head "/ssh:somehost:/x/")))))

(ert-deftest drgnx-hub-events/housekeeping-prunes-events-daily ()
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let ((pruned 0))
      (cl-letf (((symbol-function 'drgnx-coord-events-prune-daily) (lambda () (cl-incf pruned) nil)))
        (drgnx-hub--housekeeping))
      (should (= pruned 1)))))

(ert-deftest drgnx-hub-events/two-broadcasts-are-an-interval-apart ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let ((drgnx-hub-events-interval 0.3) (at nil))
      (push (lambda (e _d) (when (equal e "events") (push (float-time) at))) drgnx-hub-event-functions)
      (drgnx-coord-event-add :agent "a" :kind "decision" :summary "one")
      (drgnx-hub-call "coord/notify" nil #'ignore)
      (should (drgnx-job-run-test--wait (lambda () at) 3))
      (drgnx-coord-event-add :agent "a" :kind "decision" :summary "two")   ; at once after the first went out
      (drgnx-hub-call "coord/notify" nil #'ignore)
      (should (drgnx-job-run-test--wait (lambda () (cdr at)) 3))
      (should (>= (- (car at) (cadr at)) 0.25)))))

(ert-deftest drgnx-hub-events/stopping-the-hub-drops-its-event-state-and-timer ()
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let ((s (drgnx-agents--make :id "s-x" :name "x" :cwd repo :status 'busy)))
      (drgnx-hub--session-events s)
      (should (gethash "s-x" drgnx-hub--event-state))
      (should (drgnx-timer-active-p 'hub-events))
      (drgnx-hub-stop)
      (should (zerop (hash-table-count drgnx-hub--event-state)))
      (should-not (drgnx-timer-active-p 'hub-events)))))

(ert-deftest drgnx-hub-events/a-job-agent-s-allowed-write-is-an-edit ()
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let* ((tree (file-name-as-directory (concat repo "tree")))
           (s (drgnx-agents--make :id "s-j" :name "j" :cwd tree :status 'busy :job "jz" :task "jz#1"))
           (path (concat tree "out.txt")))
      (make-directory tree t)
      (should (equal (drgnx-job--request s "fs/write_text_file" (list :path path :content "hi\n") 7) '(:result nil)))
      (let ((e (car (drgnx-coord-events :agent "s-j" :kinds '("edit")))))
        (should e)
        (should (equal (plist-get e :task) "jz#1"))
        (should (equal (plist-get (plist-get e :data) :paths) (list path)))))))

(ert-deftest drgnx-hub-events/events-since-caps-its-limit-and-reads-a-bad-since-as-0 ()
  (drgnx-hub-events-test--with "# P\n\n### Task 1: one\n"
    (let ((db (drgnx-work-db)))
      (sqlite-transaction db)
      (dotimes (i 1005) (sqlite-execute db "insert into event (at, agent, kind, summary) values (?, 'a', 'decision', ?)"
                                        (list (float-time) (format "d%d" i))))
      (sqlite-commit db))
    (should (= (length (plist-get (drgnx-hub-call-sync "events/since" (list :since 0 :limit 5000)) :events)) 1000))
    (should (= (length (plist-get (drgnx-hub-call-sync "events/since" (list :since 0)) :events)) 200))
    (let ((r (drgnx-hub-call-sync "events/since" (list :since "abc" :limit -3))))
      (should (eql (plist-get r :since) 0))
      (should (= (length (plist-get r :events)) 200)))))

(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-hub/events-dispatch-through-the-guard ()
  ;; An event or disconnect function that fails or asks is recorded by the guard; the next one still runs.
  (drgnx-notice-test-with-model
    (let* ((filter nil) (heard nil) (was drgnx-guard-mode)
           (conn (make-pipe-process :name "drgnx-hub-guard-test" :noquery t))
           (drgnx-hub--events nil) (drgnx-hub--subscribing nil)
           (drgnx-hub-event-functions (list (lambda (_e _d) (error "Boom")) (lambda (e d) (push (cons e d) heard))))
           (drgnx-hub-disconnect-functions (list (lambda () (y-or-n-p "Restart? ")) (lambda () (push 'gone heard)))))
      (drgnx-guard-mode 1)
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-hub--connect-socket) (lambda (f) (setq filter f) conn))
                    ((symbol-function 'drgnx-hub--send) #'ignore)
                    ((symbol-function 'drgnx-hub--send-keys) #'ignore))
            (drgnx-hub-connect)
            (funcall filter conn "{\"event\":\"x\",\"data\":{\"a\":1}}\n{\"event\":\"y\",\"data\":{}}\n")
            (should (equal heard '(("y") ("x" :a 1))))         ; both lines, past the failing function
            (let ((sentinel (process-sentinel conn)))
              (set-process-sentinel conn #'ignore)
              (delete-process conn)
              (funcall sentinel conn "deleted\n"))
            (should (eq (car heard) 'gone))
            (let ((by (lambda (prefix)
                        (seq-filter (lambda (n) (string-prefix-p prefix (plist-get n :id))) (drgnx-notices :source 'guard)))))
              (should (equal (mapcar (lambda (n) (plist-get n :severity)) (funcall by "drgnx-hub-event-functions "))
                             '(warn)))
              (should (= (plist-get (car (funcall by "drgnx-hub-event-functions ")) :count) 2))
              (should (equal (mapcar (lambda (n) (plist-get n :severity)) (funcall by "drgnx-hub-disconnect-functions "))
                             '(fail)))))
        (unless was (drgnx-guard-mode -1))
        (when (process-live-p conn) (delete-process conn))))))

;;; hub-events-test.el ends here
