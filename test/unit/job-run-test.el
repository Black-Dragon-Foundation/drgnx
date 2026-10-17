;;; job-run-test.el --- batch tests: approving a job; one agent per ready task in its worktree -*- lexical-binding: t -*-
;; The hub is served in this Emacs; the agents are the mock (test/fixtures/mock-acp.el): a task prompt makes it
;; commit and call complete_task through its coordination tools.
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-job)

(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)

(defconst drgnx-job-run-test--two "# Two\n\n### Task 1: one\n\n- [ ] a\n\n### Task 2: two\n\n- [ ] b\n\n### Task 3: three\n**Depends:** Task 1, Task 2\n")

(ert-deftest drgnx-job/nothing-starts-before-approval ()
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-step id)
      (should-not drgnx-agents--sessions)
      (should-not (file-exists-p (format "%s.claude/worktrees/%s-1" repo id)))
      (drgnx-job-approve id)
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (should (drgnx-job-run-test--wait (lambda () (= (length (drgnx-job-run-test--sessions id)) 2))))
      (dolist (n '(1 2))
        (let ((wt (format "%s.claude/worktrees/%s-%d/" repo id n)))
          (should (file-directory-p wt))
          (should (equal (drgnx-job-run-test--git wt "rev-parse" "--abbrev-ref" "HEAD") (format "job/%s-%d" id n)))))
      (should (equal (drgnx-job-run-test--git repo "rev-parse" "--abbrev-ref" "HEAD") "main"))     ; main untouched
      (should (equal (drgnx-job-run-test--status id 3) "pending")))))

(ert-deftest drgnx-job/with-automatic-start-on-it-starts-by-itself ()
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let* ((drgnx-job-auto-start t) (id (drgnx-job-propose plan)))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-run-test--sessions id)))))))

(ert-deftest drgnx-job/a-finished-task-goes-to-review-not-done ()
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let ((drgnx-job-review nil) (id (drgnx-job-propose plan)))   ; no reviewer: it waits in review
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (member (drgnx-job-run-test--status id 1) '("in-review" "done"))) 20))
      (should (equal (drgnx-job-run-test--status id 1) "in-review"))
      (should (string-search (format "work for %s#1" id)
                             (drgnx-job-run-test--git repo "log" "--format=%s" (format "job/%s-1" id)))))))

(ert-deftest drgnx-job/at-most-max-agents-at-once ()
  (drgnx-job-run-test--with "# Four\n\n### Task 1: a\n\n### Task 2: b\n\n### Task 3: c\n\n### Task 4: d\n"
    (let ((drgnx-job-max-agents 2) (id (drgnx-job-propose plan)) (most 0))
      (drgnx-job-approve id)
      (drgnx-job-run-test--wait (lambda () (setq most (max most (length (drgnx-job-run-test--sessions id))))
                                  (seq-every-p (lambda (n) (member (drgnx-job-run-test--status id n) '("in-review" "done" "needs-input"))) '(1 2 3 4)))
                                40)
      (should (seq-every-p (lambda (n) (member (drgnx-job-run-test--status id n) '("in-review" "done" "needs-input"))) '(1 2 3 4)))
      (should (= most 2)))))

(ert-deftest drgnx-job/an-agent-that-dies-gives-its-task-back ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: crash-once then work\n"
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "in-review")) 30))
      ;; two sessions worked on it, in the same worktree
      (should (= (length (seq-filter (lambda (s) (equal (drgnx-agent-session-task s) (format "%s#1" id))) drgnx-agents--sessions)) 2))
      (should (file-exists-p (format "%s.claude/worktrees/%s-1/.mock-crashed" repo id))))))

;;; job-run-test.el ends here
