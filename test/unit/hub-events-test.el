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
      (should (drgnx-job-run-test--wait (lambda () (member "stop" (drgnx-hub-events-test--kinds id)))))
      (should (equal (drgnx-hub-events-test--kinds id) '("start" "edit" "stop")))
      (should (equal (plist-get (plist-get (car (drgnx-hub-events-test--of id "start")) :data) :head) head))
      (let ((edit (plist-get (car (drgnx-hub-events-test--of id "edit")) :data)))
        (should (equal (plist-get edit :paths) (list file))))
      ;; a rejected write is no edit
      (drgnx-agents-send s (concat "write " file))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-reviews s))))
      (drgnx-hub-call-sync "agents/do" (list :id id :op "review" :item (plist-get (car (drgnx-agent-session-reviews s)) :id) :reject t))
      (should (drgnx-job-run-test--wait (lambda () (= 2 (length (drgnx-hub-events-test--of id "stop"))))))
      (should (= 1 (length (drgnx-hub-events-test--of id "edit")))))))

(ert-deftest drgnx-hub-events/a-tool-call-that-wrote-files-is-an-edit ()
  ;; an agent that writes files itself reports a completed edit tool call with diffs: one event per call
  (drgnx-job-run-test--with "# P\n\n### Task 1: one\n"
    (let* ((s (drgnx-agents--make :id "s-t" :name "t" :cwd repo :status 'idle)))
      (drgnx-hub--session-events s)
      (setf (drgnx-agent-session-status s) 'busy)
      (drgnx-hub--session-events s)
      (setf (drgnx-agent-session-entries s)
            (list (list :type 'user :text "go")
                  (list :type 'tool :id "e1" :kind "edit" :status "in_progress" :title "Edit a.el"
                        :content (list (list :type "diff" :path (concat repo "a.el") :newText "x")))
                  (list :type 'tool :id "r1" :kind "read" :status "completed" :title "Read b.el")
                  (list :type 'tool :id "task" :kind "think" :status "completed"
                        :children (list (list :type 'tool :id "e2" :kind "edit" :status "completed" :title "Write c.el"
                                              :content (vector (list :type "diff" :path (concat repo "c.el") :newText "y")))))))
      (drgnx-hub--session-events s)
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :data) :paths)) (drgnx-hub-events-test--of "s-t" "edit"))
                     (list (list (concat repo "c.el")))))
      (plist-put (nth 1 (drgnx-agent-session-entries s)) :status "completed")
      (drgnx-hub--session-events s)
      (drgnx-hub--session-events s)                     ; once per tool call
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :data) :paths)) (drgnx-hub-events-test--of "s-t" "edit"))
                     (list (list (concat repo "c.el")) (list (concat repo "a.el")))))
      (setf (drgnx-agent-session-status s) 'idle)
      (drgnx-hub--session-events s)
      (should (equal (drgnx-hub-events-test--kinds "s-t") '("start" "edit" "edit" "stop"))))))

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
        (should (equal (plist-get (plist-get (car (drgnx-hub-events-test--of id "answer")) :data) :question) (plist-get q :id)))))))

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
    (let ((before (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0)))
      ;; 50 adds in 0.1 s, each followed by the notify a coordination server sends
      (dotimes (i 50)
        (drgnx-coord-event-add :agent "ext:t:1" :kind "test" :summary (format "run %d" i) :data (list :passed i :failed 0))
        (drgnx-hub-call "coord/notify" nil #'ignore)
        (when (zerop (% i 10)) (accept-process-output nil 0.02)))
      (drgnx-job-run-test--wait (lambda () nil) 0.05)     ; the notifies are served
      ;; one broadcast due, not one per add
      (should (<= (seq-count (lambda (tm) (eq (timer--function tm) #'drgnx-hub--events-send)) timer-list) 1))
      (should (drgnx-job-run-test--wait (lambda () (assoc "events" heard)) 3))
      (drgnx-job-run-test--wait (lambda () nil) 0.6)       ; a second batch would be here now
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

;;; hub-events-test.el ends here
