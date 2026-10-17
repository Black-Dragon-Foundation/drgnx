;;; job-cards-test.el --- batch tests: cards are records with actions; the user acts on them through the hub -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defconst drgnx-job-cards-test--one "# One\n\n### Task 1: one\n")

(defun drgnx-job-cards-test--open (id kind)
  (seq-filter (lambda (c) (equal (plist-get c :kind) kind)) (drgnx-coord-cards id "open")))

(defmacro drgnx-job-cards-test--running (&rest body)
  "BODY with a running one-task job ID (task TID), nothing started by itself."
  (declare (indent 0))
  `(drgnx-job-run-test--with drgnx-job-cards-test--one
     (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1")))
       (drgnx-job-approve id)
       ,@body)))

(ert-deftest drgnx-job-cards/a-card-is-a-record-with-actions ()
  (drgnx-job-cards-test--running
    (let ((cid (drgnx-job--card id tid "merge-conflict" "conflicts in: a.txt")))
      (should (integerp cid))
      (let ((card (car (drgnx-job-cards-test--open id "merge-conflict"))))
        (should (equal (plist-get card :id) cid))
        (should (equal (plist-get card :task) tid))
        (should (equal (mapcar #'car (drgnx-job-card-actions card)) '("retry" "merge" "drop" "open"))))
      (let ((c (seq-find (lambda (c) (equal (plist-get c :id) cid)) (plist-get (drgnx-job-summary id) :cards))))
        (should c)
        (should (assoc "retry" (plist-get c :actions)))))))

(ert-deftest drgnx-job-cards/one-open-card-per-task-and-kind ()
  (drgnx-job-cards-test--running
    (let ((a (drgnx-job--card id tid "stalled" "first")) (b (drgnx-job--card id tid "stalled" "second")))
      (should (equal a b))
      (should (= 1 (length (drgnx-job-cards-test--open id "stalled"))))
      (should (equal (plist-get (car (drgnx-job-cards-test--open id "stalled")) :title) "second")))))

(ert-deftest drgnx-job-cards/retry-frees-the-task-and-settles-the-card ()
  (drgnx-job-cards-test--running
    (drgnx-coord-force-status tid "running" "s-gone")
    (puthash tid 3 drgnx-job--exits)
    (let ((cid (drgnx-job--card id tid "agent" "its agent ended 3 times")))
      (drgnx-job-card-act cid "retry")
      (should (equal (drgnx-job-run-test--status id 1) "ready"))
      (should-not (gethash tid drgnx-job--exits))
      (let ((card (drgnx-coord-card cid)))
        (should (equal (plist-get card :state) "settled"))
        (should (equal (plist-get card :choice) "retry")))
      (should (equal (plist-get (seq-find (lambda (m) (string-prefix-p "[agent]" (plist-get m :text))) (drgnx-coord-inbox "user")) :state)
                     "acted")))))

(ert-deftest drgnx-job-cards/acting-twice-does-nothing-twice ()
  (drgnx-job-run-test--with drgnx-job-cards-test--one
    (let* ((drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1")))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "in-review")) 30))
      (let ((cid (drgnx-job--card id tid "review" "the reviewer gave no verdict")))
        (drgnx-job-card-act cid "accept")
        (should (equal (drgnx-job-run-test--status id 1) "done"))
        (let ((head (drgnx-job-run-test--git repo "rev-parse" (concat "job/" id))))
          (should-error (drgnx-job-card-act cid "accept"))
          (should (equal (drgnx-job-run-test--git repo "rev-parse" (concat "job/" id)) head)))))))

(ert-deftest drgnx-job-cards/permission-cards-answer-the-agent ()
  (drgnx-job-cards-test--running
    (let ((s (drgnx-agents-start "mock" repo tid id)))
      (drgnx-coord-force-status tid "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "permission execute :: npm install left-pad")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-cards-test--open id "permission"))))
      (let ((cid (plist-get (car (drgnx-job-cards-test--open id "permission")) :id)))
        (drgnx-job-card-act cid "allow")
        (should (drgnx-job-run-test--wait (lambda () (string-search "permission: allow" (format "%S" (drgnx-agent-session-entries s))))))
        (should (equal (drgnx-job-run-test--status id 1) "running"))
        (should (equal (plist-get (drgnx-coord-card cid) :state) "settled"))))))

(ert-deftest drgnx-job-cards/answering-in-the-transcript-settles-the-card ()
  (drgnx-job-cards-test--running
    (let ((s (drgnx-agents-start "mock" repo tid id)))
      (drgnx-coord-force-status tid "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "permission execute :: npm install left-pad")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-hub-call-sync "agents/permission" (list :id (drgnx-agent-session-id s) :request (plist-get (car (drgnx-agent-session-permissions s)) :id)
                                                     :option "allow"))
      (should-not (drgnx-job-cards-test--open id "permission")))))

(ert-deftest drgnx-job-cards/the-proposal-is-a-card ()
  (drgnx-job-run-test--with drgnx-job-cards-test--one
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (card (car (drgnx-job-cards-test--open id "proposal"))))
      (should card)
      (should (equal (mapcar #'car (drgnx-job-card-actions card)) '("approve" "reject")))
      (drgnx-hub-call-sync "job/card" (list :card (plist-get card :id) :action "approve"))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (should-not (drgnx-job-cards-test--open id "proposal")))))

(ert-deftest drgnx-job-cards/messages-to-the-user-are-listed-with-a-reply ()
  (drgnx-job-cards-test--running
    (let ((mid (plist-get (drgnx-coord-send :job id :sender "s-a" :recipient "user" :text "[escalation] db: which one?"
                                            :seen (drgnx-coord-version))
                          :id)))
      (should (seq-find (lambda (m) (equal (plist-get m :id) mid)) (plist-get (drgnx-job-summary id) :messages)))
      ;; drgnx's own card copies are not messages
      (drgnx-job--card id tid "stalled" "x")
      (should-not (seq-find (lambda (m) (string-prefix-p "[stalled]" (plist-get m :text))) (plist-get (drgnx-job-summary id) :messages)))
      (drgnx-hub-call-sync "job/reply" (list :message mid :text "the second"))
      (should (equal (plist-get (car (drgnx-coord-inbox "s-a")) :text) "the second"))
      (should (equal (plist-get (drgnx-coord-message mid) :state) "acted")))))

(ert-deftest drgnx-job-cards/a-change-is-a-job-event ()
  (drgnx-job-cards-test--running
    (let ((events nil))
      (let ((drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) events)))))
        (drgnx-hub-connect)
        (drgnx-job-run-test--wait (lambda () (process-live-p drgnx-hub--events)))   ; subscribed
        (drgnx-job--card id tid "stalled" "x")
        (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (e) (and (equal (car e) "job") (equal (plist-get (cdr e) :id) id))) events))))))))


(ert-deftest drgnx-job-cards/rejecting-a-task-less-request-answers-it-not-the-job ()
  ;; a clash reviewer has no task: its permission card's Reject answers the request; the job goes on
  (drgnx-job-cards-test--running
    (let ((s (drgnx-agents-start "mock" repo nil id)))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "permission execute :: npm install left-pad")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-cards-test--open id "permission"))))
      (drgnx-job-card-act (plist-get (car (drgnx-job-cards-test--open id "permission")) :id) "reject")
      (should (drgnx-job-run-test--wait (lambda () (string-search "permission: reject" (format "%S" (drgnx-agent-session-entries s))))))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (should-not (eq (drgnx-agent-session-status s) 'exited)))))

(ert-deftest drgnx-job-cards/a-task-less-request-answered-in-the-transcript-settles-its-card ()
  (drgnx-job-cards-test--running
    (let ((s (drgnx-agents-start "mock" repo nil id)))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "permission execute :: npm install left-pad")
      (should (drgnx-job-run-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-hub-call-sync "agents/permission" (list :id (drgnx-agent-session-id s) :request (plist-get (car (drgnx-agent-session-permissions s)) :id)
                                                     :option "allow"))
      (should-not (drgnx-job-cards-test--open id "permission")))))

(ert-deftest drgnx-job-cards/retry-ends-the-task-s-agent ()
  (drgnx-job-cards-test--running
    (let ((s (drgnx-agents-start "mock" repo tid id)))
      (drgnx-coord-force-status tid "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-job-card-act (drgnx-job--card id tid "stalled" "held twice") "retry")
      (should (eq (drgnx-agent-session-status s) 'exited))
      (should (equal (drgnx-job-run-test--status id 1) "ready")))))

(ert-deftest drgnx-job-cards/a-finished-task-s-cards-settle-and-cannot-undo-it ()
  (drgnx-job-cards-test--running
    (let ((cid (drgnx-job--card id tid "stalled" "held twice")))
      (drgnx-coord-force-status tid "done" "s-x")
      (should-error (drgnx-job-card-act cid "drop"))                       ; merged work is not dropped
      (should (equal (drgnx-job-run-test--status id 1) "done"))
      (drgnx-job-step id)
      (should (equal (plist-get (drgnx-coord-card cid) :state) "settled")))))

;;; job-cards-test.el ends here
