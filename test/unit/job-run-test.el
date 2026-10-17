;;; job-run-test.el --- batch tests: approving a job; one agent per ready task in its worktree -*- lexical-binding: t -*-
;; The hub is served in this Emacs; the agents are the mock (test/fixtures/mock-acp.el): a task prompt makes it
;; commit and call complete_task through its coordination tools.
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-job)

(defun drgnx-job-run-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro drgnx-job-run-test--with (plan-text &rest body)
  "BODY with drgnx's dirs in ROOT, a git repo REPO (one commit), PLAN-TEXT as PLAN in it, the hub served here and the
profile \"mock\" on every route."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-job-run" t)))
          (repo (concat root "repo/")) (plan (concat repo "docs/plans/p.md"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START"
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                             "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-agents--sessions nil) (drgnx-hub--exit-function #'drgnx-hub-stop)
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-agents-profiles
           (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                             "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
          (drgnx-job-routes '((implement . "mock") (test . "mock") (docs . "mock") (review . "mock")))
          (drgnx-job-auto-start nil) (drgnx-job-max-agents 3))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t) (make-directory (concat repo "docs/plans") t)
           (write-region "x\n" nil (concat repo "README") nil 'silent)
           (write-region ,plan-text nil plan nil 'silent)
           (drgnx-job-run-test--git repo "init" "-q" "-b" "main")
           (drgnx-job-run-test--git repo "add" "-A")
           (drgnx-job-run-test--git repo "commit" "-q" "-m" "start")
           (drgnx-hub-serve (drgnx-hub-socket))
           ,@body)
       (dolist (s drgnx-agents--sessions) (ignore-errors (drgnx-agents-kill s)))
       (drgnx-hub-disconnect)
       (drgnx-hub-stop)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-job-run-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-job-run-test--status (job n)
  (plist-get (seq-find (lambda (task) (= (plist-get task :n) n)) (drgnx-coord-tasks job)) :status))

(defun drgnx-job-run-test--sessions (job)
  (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) job) (not (eq (drgnx-agent-session-status s) 'exited))))
              drgnx-agents--sessions))

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
    (let ((id (drgnx-job-propose plan)))
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
                                  (seq-every-p (lambda (n) (equal (drgnx-job-run-test--status id n) "in-review")) '(1 2 3 4)))
                                40)
      (should (seq-every-p (lambda (n) (equal (drgnx-job-run-test--status id n) "in-review")) '(1 2 3 4)))
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
