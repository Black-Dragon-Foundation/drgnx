;;; job-review-test.el --- batch tests: a reviewer per finished task; merges into the job branch -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defconst drgnx-job-run-test--two "# Two\n\n### Task 1: one\n\n- [ ] a\n\n### Task 2: two\n\n- [ ] b\n\n### Task 3: three\n**Depends:** Task 1, Task 2\n")

(defconst drgnx-job-review-test--chain "# Chain\n\n### Task 1: first\n\n### Task 2: second\n**Depends:** Task 1\n")

(ert-deftest drgnx-job/a-passed-task-is-merged-and-its-dependent-starts-from-it ()
  (drgnx-job-run-test--with drgnx-job-review-test--chain
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 30))
      (should (string-search (format "work for %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (concat "job/" id))))
      ;; task 2 started from the job branch that has task 1
      (should (drgnx-job-run-test--wait (lambda () (file-directory-p (format "%s.claude/worktrees/%s-2" repo id))) 15))
      (should (string-search (format "work for %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (format "job/%s-2" id)))))))

(ert-deftest drgnx-job/a-failed-review-goes-back-to-an-agent ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let ((process-environment (cons "MOCK_ACP_VERDICT=fail" process-environment)) (id nil))
      (setq id (drgnx-job-propose plan))
      (drgnx-job-approve id)
      ;; an agent is given the reviewer's reasons, in the same worktree
      (should (drgnx-job-run-test--wait
               (lambda () (seq-find (lambda (s) (and (equal (drgnx-agent-session-task s) (format "%s#1" id))
                                                     (string-search "rename foo to bar" (format "%S" (drgnx-agent-session-entries s)))
                                                     (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
                                    drgnx-agents--sessions))
               30))
      ;; after the third failed review, the user decides
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "needs-input")) 60))
      (should (seq-find (lambda (m) (string-prefix-p "[review]" (plist-get m :text))) (drgnx-coord-inbox "user"))))))

(ert-deftest drgnx-job/a-merge-conflict-is-the-user-s ()
  ;; both tasks append to task.txt from the same start: the second merge conflicts
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait
               (lambda () (let ((s (list (drgnx-job-run-test--status id 1) (drgnx-job-run-test--status id 2))))
                            (and (member "done" s) (member "needs-input" s))))
               40))
      (should (seq-find (lambda (m) (string-prefix-p "[merge-conflict]" (plist-get m :text))) (drgnx-coord-inbox "user")))
      (should (equal (drgnx-job-run-test--git (drgnx-job--job-tree id) "status" "--porcelain") ""))   ; aborted, clean
      (should (equal (drgnx-job-run-test--status id 3) "pending")))))                               ; waits

(ert-deftest drgnx-job/nothing-merges-twice ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 30))
      (let ((before (drgnx-job-run-test--git repo "rev-parse" (concat "job/" id))))
        (drgnx-job--merge id (drgnx-coord-task (format "%s#1" id)))
        (should (equal (drgnx-job-run-test--git repo "rev-parse" (concat "job/" id)) before))))))

(ert-deftest drgnx-job/the-job-is-done-when-every-task-is ()
  (drgnx-job-run-test--with drgnx-job-review-test--chain
    (let ((id (drgnx-job-propose plan)) (main (drgnx-job-run-test--git repo "rev-parse" "main")))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (plist-get (drgnx-coord-job id) :status) "done")) 60))
      (should (equal (drgnx-job-run-test--git repo "rev-parse" "main") main)))))          ; nothing reached main

;;; job-review-test.el ends here
