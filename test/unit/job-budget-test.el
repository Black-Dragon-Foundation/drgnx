;;; job-budget-test.el --- batch tests: the budget pauses a job; a failing provider moves the task on -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defun drgnx-job-budget-test--agent (id n)
  "A mock session of job ID working on task N in its worktree (made like the engine makes it), idle."
  (let* ((repo (drgnx-job--repo id)) (tree (drgnx-job--task-tree id n)))
    (unless (file-directory-p tree) (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-%d" id n) tree (concat "job/" id)))
    (let ((s (drgnx-agents-start "mock" tree (format "%s#%d" id n) id)))
      (drgnx-coord-force-status (format "%s#%d" id n) "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      s)))

(defun drgnx-job-budget-test--registered (id)
  "The budgets of job ID's gateway registrations."
  (delq nil (mapcar (lambda (r) (and (equal (plist-get (cdr r) :job) id) (plist-get (cdr r) :budget))) (drgnx-gateway-registrations))))

(ert-deftest drgnx-job/the-budget-pauses-the-job ()
  (drgnx-job-run-test--with "# Two\n\n### Task 1: one\n\n### Task 2: two\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan :budget 1.0)) (events nil)
           (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) events)))))
      (drgnx-hub-connect)
      (drgnx-job-approve id :budget 1.0)
      (drgnx-hub-register (list :job id :task (concat id "#1") :agent "a" :chain nil))   ; an agent on the gateway
      (should (equal (drgnx-job-budget-test--registered id) '(1.0)))
      (let ((a (drgnx-job-budget-test--agent id 1)) (b (drgnx-job-budget-test--agent id 2)))
        (drgnx-agents-send a "slow") (drgnx-agents-send b "slow")
        (drgnx-job-run-test--wait (lambda () (and (eq (drgnx-agent-session-status a) 'busy) (eq (drgnx-agent-session-status b) 'busy))))
        (drgnx-job--gateway-event 'budget (list :job id :spent 1.2 :budget 1.0))         ; what the gateway says at the limit
        (should (drgnx-job-run-test--wait (lambda () (and (not (eq (drgnx-agent-session-status a) 'busy)) (not (eq (drgnx-agent-session-status b) 'busy)))) 3))
        (should (equal (plist-get (drgnx-coord-job id) :status) "paused"))
        (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (e) (and (equal (car e) "card") (equal (plist-get (cdr e) :kind) "budget"))) events))))
        (let ((drgnx-job-max-agents 3)) (drgnx-job-step id))
        (should-not (seq-find (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (memq s (list a b))))) drgnx-agents--sessions))
        ;; resumed with more: it goes on where it stopped
        (drgnx-job-resume id :budget 10.0)
        (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
        (should (equal (plist-get (plist-get (drgnx-coord-job id) :data) :budget) 10.0))
        (should (equal (drgnx-job-budget-test--registered id) '(10.0)))
        (should (drgnx-job-run-test--wait
                 (lambda () (seq-every-p (lambda (s) (string-search "The job goes on" (format "%S" (drgnx-agent-session-entries s)))) (list a b)))))))))

(ert-deftest drgnx-job/a-session-free-at-the-pause-gets-its-prompt-on-resume ()
  ;; not busy when the budget ran out (its prompt not given yet): resuming gives it
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan :budget 1.0)))
      (drgnx-job-approve id)
      (let* ((a (drgnx-job-budget-test--agent id 1)) (sid (drgnx-agent-session-id a)))
        (drgnx-job--gateway-event 'budget (list :job id :spent 1.2 :budget 1.0))
        (puthash sid (format "[drgnx task %s#1] one" id) drgnx-job--prompts)    ; as a start leaves it
        (drgnx-job--session-changed a)
        (should (gethash sid drgnx-job--prompts))                                ; paused: not given
        (drgnx-job-resume id :budget 5.0)
        (should (drgnx-job-run-test--wait (lambda () (string-search (format "[drgnx task %s#1]" id) (format "%S" (drgnx-agent-session-entries a))))))))))

(ert-deftest drgnx-job/a-rate-limit-moves-the-task-to-the-next-profile ()
  :tags '(:frozen)
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((mock (plist-get (cdr (assoc "mock" drgnx-agents-profiles)) :command))
           (drgnx-agents-profiles (append (list (list "mock-a" :command mock :env '("MOCK_ACP_RATE_LIMIT=1"))
                                                (list "mock-b" :command mock))
                                          drgnx-agents-profiles))
           (drgnx-job-routes '((implement "mock-a" "mock-b") (review . "mock")))
           (drgnx-job-review nil) (events nil)
           (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) events))))
           (id (drgnx-job-propose plan)))
      (drgnx-hub-connect)
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "in-review")) 30))
      (let ((b (seq-find (lambda (s) (equal (drgnx-agent-session-profile s) "mock-b")) drgnx-agents--sessions)))
        (should b)
        (should (equal (drgnx-agent-session-cwd b) (drgnx-job--task-tree id 1)))           ; the same worktree
        (should (string-search "continuing" (format "%S" (drgnx-agent-session-entries b)))))
      (should (seq-find (lambda (e) (and (equal (car e) "fallback") (equal (plist-get (cdr e) :to) "mock-b"))) events)))))

(ert-deftest drgnx-job/a-reviewer-at-its-limit-moves-to-the-next-review-profile ()
  :tags '(:frozen)
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((mock (plist-get (cdr (assoc "mock" drgnx-agents-profiles)) :command))
           (drgnx-agents-profiles (append (list (list "rev-a" :command mock :env '("MOCK_ACP_RATE_LIMIT=1"))
                                                (list "rev-b" :command mock))
                                          drgnx-agents-profiles))
           (drgnx-job-routes '((implement . "mock") (review "rev-a" "rev-b")))
           (id (drgnx-job-propose plan)) (second nil))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait
               (lambda () (when (seq-find (lambda (s) (and (equal (drgnx-agent-session-profile s) "rev-b")
                                                           (gethash (drgnx-agent-session-id s) drgnx-job--reviewers)))
                                          drgnx-agents--sessions)
                            (setq second t))
                 (equal (drgnx-job-run-test--status id 1) "done"))
               40))
      (should second))))                                                            ; reviewed by the second, merged

(ert-deftest drgnx-job/a-reviewer-at-its-limit-with-no-profile-left-is-a-card ()
  :tags '(:frozen)
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((mock (plist-get (cdr (assoc "mock" drgnx-agents-profiles)) :command))
           (drgnx-agents-profiles (cons (list "rev-a" :command mock :env '("MOCK_ACP_RATE_LIMIT=1")) drgnx-agents-profiles))
           (drgnx-job-routes '((implement . "mock") (review . "rev-a")))
           (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "needs-input")) 30))
      (let ((card (seq-find (lambda (c) (equal (plist-get c :kind) "review")) (drgnx-coord-cards id "open"))))
        (should card)
        (should (string-search "rev-a" (plist-get card :title)))))))

(ert-deftest drgnx-job/no-next-profile-is-a-card ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((mock (plist-get (cdr (assoc "mock" drgnx-agents-profiles)) :command))
           (drgnx-agents-profiles (cons (list "mock-a" :command mock :env '("MOCK_ACP_RATE_LIMIT=1")) drgnx-agents-profiles))
           (drgnx-job-routes '((implement . "mock-a")))
           (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "needs-input")) 20))
      (should (seq-find (lambda (m) (string-prefix-p "[fallback]" (plist-get m :text))) (drgnx-coord-inbox "user"))))))

(ert-deftest drgnx-job/an-agent-that-died-of-a-rate-limit-counts-as-one ()
  ;; it exited: the error says only that; its stderr says why
  (let ((s (drgnx-agents--make :id "s-x" :status 'exited :stderr "Error: 429 Too Many Requests")))
    (should (drgnx-job--provider-limit-p s '(:code -32000 :message "the agent exited")))
    (should-not (drgnx-job--provider-limit-p (drgnx-agents--make :id "s-y" :status 'exited :stderr "segfault")
                                             '(:code -32000 :message "the agent exited")))
    (should (drgnx-job--provider-limit-p (drgnx-agents--make :id "s-z" :status 'idle) '(:code 429 :message "x")))))

(ert-deftest drgnx-job/after-a-fallback-the-summary-shows-the-new-profile ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (tid (concat id "#1")))
      (drgnx-job-approve id)
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :profile) "mock"))                                   ; no agent yet: the route's first
      (push (drgnx-agents--make :id "s-b" :name "b" :profile "mock-b" :cwd repo :task tid :job id :status 'idle) drgnx-agents--sessions)
      (drgnx-coord-force-status tid "running" "s-b")
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :profile) "mock-b")))))

(ert-deftest drgnx-job/handover-names-log-version ()
  ;; the successor is told how far the decision log was when the agent before it stopped
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (drgnx-coord-decide :kind "build" :subject "the CSV export" :author "user" :job id :reason "asked" :seen (drgnx-coord-version))
      (let ((s (drgnx-agents--make :id "s-h" :name "h" :profile "mock" :cwd repo :task (concat id "#1") :job id)))
        (should (> (drgnx-coord-version) 0))
        (should (string-search (format "version %d" (drgnx-coord-version)) (drgnx-job--handover id s)))))))

(ert-deftest drgnx-job/handover-never-quotes-a-git-failure ()
  ;; git cannot log there (not a repository): the successor is told "none", not git's error
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (let* ((s (drgnx-agents--make :id "s-h" :name "h" :profile "mock" :cwd root :task (concat id "#1") :job id))
             (text (drgnx-job--handover id s)))
        (should (string-search "Its last commit: none" text))
        (should-not (string-search "fatal" text))))))

;;; job-budget-test.el ends here
