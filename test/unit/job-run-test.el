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

(ert-deftest drgnx-job/auto-start-makes-no-proposal-card ()
  ;; nobody is asked to approve what starts at once: no card, no message
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let* ((drgnx-job-auto-start t) (drgnx-job-max-agents 0) (id (drgnx-job-propose plan)))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (should-not (drgnx-coord-cards id))
      (should-not (seq-find (lambda (m) (string-prefix-p "[proposal]" (plist-get m :text))) (drgnx-coord-inbox "user"))))))

(ert-deftest drgnx-job/a-finished-task-goes-to-review-not-done ()
  (drgnx-job-run-test--with drgnx-job-run-test--two
    (let ((drgnx-job-review nil) (id (drgnx-job-propose plan)))   ; no reviewer: it waits in review
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (member (drgnx-job-run-test--status id 1) '("in-review" "done"))) 20))
      (should (equal (drgnx-job-run-test--status id 1) "in-review"))
      (should (string-search (format "work for %s#1" id)
                             (drgnx-job-run-test--git repo "log" "--format=%s" (format "job/%s-1" id)))))))

(ert-deftest drgnx-job/a-slow-worktree-add-does-not-block-the-hub ()
  ;; `git worktree add' runs the post-checkout hook, however slow: the step goes on, the task says "starting"
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let ((id (drgnx-job-propose plan)) (hook (concat repo ".git/hooks/post-checkout")) (t0 nil))
      (write-region "#!/bin/sh\ncase \"$PWD\" in *-1) sleep 2;; esac\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (setq t0 (float-time))
      (drgnx-job-approve id)
      (should (< (- (float-time) t0) 1.5))
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "starting"))
      (should-not (drgnx-job-run-test--sessions id))
      (drgnx-job-step id)                                               ; asked again meanwhile: one worktree add
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-run-test--sessions id)) 15))
      (should (= 1 (length (drgnx-job-run-test--sessions id))))
      (should (file-directory-p (drgnx-job--task-tree id 1)))
      (should (member (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) '("claimed" "running" "in-review"))))))

(ert-deftest drgnx-job/a-task-whose-worktree-cannot-be-made-is-a-card ()
  ;; its branch is checked out somewhere else: neither way of making the worktree works
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let ((id (drgnx-job-propose plan)))
      (drgnx-job-run-test--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) (concat root "elsewhere"))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (c) (equal (plist-get c :kind) "agent")) (drgnx-coord-cards id "open"))) 15))
      (should (string-search "worktree" (plist-get (car (drgnx-coord-cards id "open")) :title)))
      (should-not (drgnx-job-run-test--sessions id)))))

(ert-deftest drgnx-job/a-worktree-add-that-never-ends-is-a-card ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let ((id (drgnx-job-propose plan)) (hook (concat repo ".git/hooks/post-checkout")) (drgnx-job-git-timeout 0.5))
      (write-region "#!/bin/sh\ncase \"$PWD\" in *-1) echo 'checking out' >&2; sleep 20;; esac\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job-approve id)
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "starting"))
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (c) (equal (plist-get c :kind) "agent")) (drgnx-coord-cards id "open"))) 15))
      (should (string-search "did not finish" (plist-get (car (drgnx-coord-cards id "open")) :title)))
      (should-not (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "starting")))))

(ert-deftest drgnx-job/stopping-a-job-ends-its-git-processes ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let ((id (drgnx-job-propose plan)) (hook (concat repo ".git/hooks/post-checkout")))
      (write-region "#!/bin/sh\ncase \"$PWD\" in *-1) sleep 20;; esac\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job-approve id)
      (let ((git (seq-find (lambda (p) (string-prefix-p "drgnx-git" (process-name p))) (process-list))))
        (should git)
        (drgnx-job-stop id)
        (should (drgnx-job-run-test--wait (lambda () (not (process-live-p git))) 5))
        (should (drgnx-job-run-test--wait (lambda () (not (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "starting"))) 5))
        (should-not (drgnx-coord-cards id "open"))))))

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
      ;; two agents worked on it, in the same worktree (its reviewer, which may have started by now, apart)
      (should (= (length (seq-filter (lambda (s) (and (equal (drgnx-agent-session-task s) (format "%s#1" id))
                                                      (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
                                     drgnx-agents--sessions))
                 2))
      (should (file-exists-p (format "%s.claude/worktrees/%s-1/.mock-crashed" repo id))))))

(ert-deftest drgnx-job/a-git-process-has-its-deadline-in-the-timer-layer ()
  ;; The deadline is a one-shot keyed by the process and owned by it; the sentinel ends it with the process.
  ;; git waits for a line on a FIFO: a git that has ended already has no deadline (its owner is gone)
  (let* ((dir (make-temp-file "drgnx-git-timer" t)) (done nil)
         (fifo (expand-file-name "go" dir))
         (_ (should (eql 0 (call-process "mkfifo" nil nil nil fifo))))
         (p (drgnx-job--git-async dir (list "-c" (concat "alias.wait-for-go=!read line < " (shell-quote-argument fifo))
                                            "wait-for-go")
                                  (lambda (r) (setq done r))))
         (key (cons 'job-git-timeout p)))
    (unwind-protect
        (progn
          (should (drgnx-timer-active-p key))
          (should (eq (cadr (assoc key (drgnx-timer-pending))) p))
          (write-region "go\n" nil fifo t 'silent)                ; git ends
          (let ((deadline (+ (float-time) 10)))
            (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.05)))
          (should (eql 0 (car done)))
          (should-not (drgnx-timer-active-p key)))
      (when (process-live-p p) (write-region "go\n" nil fifo t 'silent))   ; a failed check: git still ends
      (drgnx-timer-cancel key)
      (delete-directory dir t))))

;;; job-run-test.el ends here
