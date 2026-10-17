;;; job-liveness-test.el --- batch tests: a job never loops, forks or strands a task -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defconst drgnx-job-liveness-test--one "# One\n\n### Task 1: one\n")

(ert-deftest drgnx-job/an-agent-that-will-not-start-is-a-card ()
  ;; a profile whose command is missing: a few tries, then the user — never a storm of sessions
  (drgnx-job-run-test--with drgnx-job-liveness-test--one
    (let* ((drgnx-agents-profiles (cons '("broken" :command ("/nonexistent/agent-binary")) drgnx-agents-profiles))
           (drgnx-job-routes '((implement . "broken")))
           (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "needs-input")) 15))
      (let ((n (length drgnx-agents--sessions)))
        (should (<= n drgnx-job-start-tries))
        (drgnx-job-run-test--wait #'ignore 2.5)                                 ; a tick and more: nothing new
        (should (= (length drgnx-agents--sessions) n)))
      (should (seq-find (lambda (m) (string-prefix-p "[agent]" (plist-get m :text))) (drgnx-coord-inbox "user"))))))

(ert-deftest drgnx-job/answering-a-reviewer-keeps-the-task-in-review ()
  (drgnx-job-run-test--with drgnx-job-liveness-test--one
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid nil) (rev nil))
      (drgnx-job-approve id)
      (setq tid (concat id "#1") rev (drgnx-agents--make :id "s-rev" :name "r" :profile "mock" :cwd repo :task tid :job id))
      (drgnx-coord-force-status tid "in-review" "s-impl")
      (puthash "s-rev" tid drgnx-job--reviewers)
      (drgnx-job--card id tid "permission" "git diff" rev)
      (should (equal (drgnx-job-run-test--status id 1) "needs-input"))
      (drgnx-job--answered rev)
      (should (equal (drgnx-job-run-test--status id 1) "in-review"))
      (should (equal (plist-get (drgnx-coord-task tid) :agent) "s-impl"))
      (remhash "s-rev" drgnx-job--reviewers))))

(ert-deftest drgnx-job/a-request-of-a-gone-agent-is-released ()
  ;; the hub restarted while a permission waited: its agent is gone, the request with it
  (drgnx-job-run-test--with drgnx-job-liveness-test--one
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid nil))
      (drgnx-job-approve id)
      (setq tid (concat id "#1"))
      (let ((gone (drgnx-agents--make :id "s-gone" :name "g" :profile "mock" :cwd repo :task tid :job id)))
        (drgnx-coord-force-status tid "running" "s-gone")
        (drgnx-job--card id tid "permission" "curl x" gone)
        (drgnx-job-step id)
        (should (equal (drgnx-job-run-test--status id 1) "ready")))
      ;; a gone reviewer's: back to review, its implementer's work kept
      (let ((rev (drgnx-agents--make :id "s-rev2" :name "r" :profile "mock" :cwd repo :task tid :job id)))
        (drgnx-coord-force-status tid "in-review" "s-impl")
        (puthash "s-rev2" tid drgnx-job--reviewers)
        (drgnx-job--card id tid "permission" "git diff" rev)
        (drgnx-job-step id)
        (should (equal (drgnx-job-run-test--status id 1) "in-review"))
        (should (equal (plist-get (drgnx-coord-task tid) :agent) "s-impl"))
        (remhash "s-rev2" drgnx-job--reviewers))
      ;; a card for the user's decision stays the user's
      (drgnx-coord-force-status tid "running" "s-x")
      (drgnx-job--card id tid "merge-conflict" "a.txt")
      (drgnx-job-step id)
      (should (equal (drgnx-job-run-test--status id 1) "needs-input")))))

(ert-deftest drgnx-job/a-turn-without-complete-task-is-nudged-then-a-card ()
  (drgnx-job-run-test--with drgnx-job-liveness-test--one
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid nil))
      (drgnx-job-approve id)
      (setq tid (concat id "#1"))
      (let ((s (drgnx-agents-start "mock" repo tid id)))
        (drgnx-coord-force-status tid "running" (drgnx-agent-session-id s))
        (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
        (drgnx-agents-send s "hello")                                           ; a turn that ends with no complete_task
        (should (drgnx-job-run-test--wait (lambda () (string-search "call complete_task" (format "%S" (drgnx-agent-session-entries s)))) 10))
        (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "needs-input")) 10))
        (should (= 1 (cl-count-if (lambda (e) (and (eq (plist-get e :type) 'user) (string-search "call complete_task" (format "%s" (plist-get e :text)))))
                                  (drgnx-agent-session-entries s))))
        (should (seq-find (lambda (m) (string-prefix-p "[stalled]" (plist-get m :text))) (drgnx-coord-inbox "user")))))))

;;; job-liveness-test.el ends here
