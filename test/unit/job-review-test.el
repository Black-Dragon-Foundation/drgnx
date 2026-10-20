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

(defun drgnx-job-review-test--agent (id n)
  "A mock session of job ID working on task N in its worktree (made like the engine makes it), idle."
  (let* ((repo (drgnx-job--repo id)) (tree (drgnx-job--task-tree id n)))
    (unless (file-directory-p tree) (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-%d" id n) tree (concat "job/" id)))
    (let ((s (drgnx-agents-start "mock" tree (format "%s#%d" id n) id)))
      (drgnx-coord-force-status (format "%s#%d" id n) "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      s)))

(ert-deftest drgnx-job/in-review-agent-mid-turn-is-not-killed ()
  ;; complete_task puts the task in review while the agent is still in its turn: the review waits for the turn's end
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (tid (concat id "#1")) (reviews 0))
      (cl-letf (((symbol-function 'drgnx-job--start-review) (lambda (&rest _) (setq reviews (1+ reviews)))))
        (drgnx-job-approve id)
        (let ((s (drgnx-job-review-test--agent id 1)))
          (drgnx-agents-send s "slow")
          (should (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'busy))))
          (drgnx-coord-force-status tid "in-review" (drgnx-agent-session-id s))
          (drgnx-job-step id)
          (should (eq (drgnx-agent-session-status s) 'busy))              ; not killed mid-turn
          (should (= reviews 0))
          ;; its turn ends: now it ends and the review starts
          (should (drgnx-job-run-test--wait (lambda () (> reviews 0)) 20))
          (should (eq (drgnx-agent-session-status s) 'exited)))))))

(ert-deftest drgnx-job/a-failing-hook-merge-shows-git-output ()
  ;; a merge that fails without a conflict (a hook refuses it, twice: it goes once more): a card that says what git
  ;; said, and claims no conflict (its actions do not send an agent to resolve one)
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1"))
           (hook (concat repo ".git/hooks/pre-merge-commit")))
      (drgnx-job-approve id)
      (let ((tree (drgnx-job--task-tree id 1)))
        (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) tree (concat "job/" id))
        (write-region "work\n" nil (concat tree "w.txt") nil 'silent)
        (drgnx-job-run-test--git tree "add" "-A")
        (drgnx-job-run-test--git tree "commit" "-q" "-m" "work"))
      (write-region "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job--merge id (drgnx-coord-task tid))
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (c) (equal (plist-get c :kind) "merge-failed")) (drgnx-coord-cards id "open")))))
      (should-not (seq-find (lambda (c) (equal (plist-get c :kind) "merge-conflict")) (drgnx-coord-cards id "open")))
      (let ((card (car (seq-filter (lambda (c) (equal (plist-get c :kind) "merge-failed")) (drgnx-coord-cards id "open")))))
        (should card)
        (should (string-search "merge failed" (plist-get card :title)))
        (should (string-search "hook says no" (plist-get card :title)))
        (should-not (assoc "retry" (drgnx-job-card-actions card)))
        (should (assoc "merge" (drgnx-job-card-actions card))))
      (should-not (equal (drgnx-job-run-test--status id 1) "done")))))

(ert-deftest drgnx-job/a-slow-merge-does-not-block-the-hub ()
  ;; the merge runs in a git process of its own: the hub goes on, the task says "merging", then it is done
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1"))
           (hook (concat repo ".git/hooks/pre-merge-commit")))
      (drgnx-job-approve id)
      (let ((tree (drgnx-job--task-tree id 1)))
        (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) tree (concat "job/" id))
        (write-region "work\n" nil (concat tree "w.txt") nil 'silent)
        (drgnx-job-run-test--git tree "add" "-A")
        (drgnx-job-run-test--git tree "commit" "-q" "-m" "work"))
      (write-region "#!/bin/sh\nsleep 2\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job--merge id (drgnx-coord-task tid))                      ; returns while the 2 s hook runs: still "merging"
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "merging"))
      (drgnx-job--merge id (drgnx-coord-task tid))                      ; asked again meanwhile: one merge
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 15))
      (should (equal (plist-get (car (plist-get (drgnx-job-summary id) :tasks)) :status) "done"))
      (should (= 1 (length (split-string (drgnx-job-run-test--git repo "log" "--merges" "--format=%s" (concat "job/" id)) "\n" t)))))))

(defun drgnx-job-review-test--branches (repo id ns)
  "Task worktrees with one commit each for tasks NS of job ID in REPO, from the job's branch."
  (dolist (n ns)
    (let ((tree (drgnx-job--task-tree id n)))
      (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-%d" id n) tree (concat "job/" id))
      (write-region "work\n" nil (format "%sw%d.txt" tree n) nil 'silent)
      (drgnx-job-run-test--git tree "add" "-A")
      (drgnx-job-run-test--git tree "commit" "-q" "-m" (format "work %d" n)))))

(ert-deftest drgnx-job/two-tasks-passing-together-merge-one-after-the-other ()
  ;; macOS CI: tasks 1 and 2 passed review at once and two git merges ran in the job's worktree together — "cannot
  ;; lock ref 'HEAD'", a merge-conflict card, the job stuck.  One merge at a time in a job's worktree; the other waits.
  (drgnx-job-run-test--with "# Two\n\n### Task 1: one\n\n### Task 2: two\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan))
           (hook (concat repo ".git/hooks/pre-merge-commit")))
      (drgnx-job-approve id)
      (drgnx-job-review-test--branches repo id '(1 2))
      (write-region "#!/bin/sh\nsleep 1\n" nil hook nil 'silent)          ; the first merge is still running
      (set-file-modes hook #o755)
      (drgnx-job--merge id (drgnx-coord-task (concat id "#1")))
      (drgnx-job--merge id (drgnx-coord-task (concat id "#2")))
      (should (equal (mapcar (lambda (task) (plist-get task :status)) (plist-get (drgnx-job-summary id) :tasks))
                     '("merging" "queued")))
      (should (drgnx-job-run-test--wait (lambda () (and (equal (drgnx-job-run-test--status id 1) "done")
                                                        (equal (drgnx-job-run-test--status id 2) "done")))
                                        15))
      (should-not (drgnx-coord-cards id "open"))
      (should (= 2 (length (split-string (drgnx-job-run-test--git repo "log" "--merges" "--format=%s" (concat "job/" id)) "\n" t)))))))

(ert-deftest drgnx-job/a-merge-that-fails-once-without-a-conflict-goes-again ()
  ;; a merge git refused for something else (a lock another git held, a hook) is no conflict: it goes once more,
  ;; after what merges then; no card when that one works
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan))
           (hook (concat repo ".git/hooks/pre-merge-commit")) (once (concat repo "once")))
      (drgnx-job-approve id)
      (drgnx-job-review-test--branches repo id '(1))
      (write-region (format "#!/bin/sh\n[ -f %s ] && exit 0\ntouch %s\necho 'busy, try again' >&2\nexit 1\n" once once) nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job--merge id (drgnx-coord-task (concat id "#1")))
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 15))
      (should (file-exists-p once))
      (should-not (drgnx-coord-cards id "open")))))

(ert-deftest drgnx-job/a-merge-that-never-ends-is-a-card ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1"))
           (hook (concat repo ".git/hooks/pre-merge-commit")) (drgnx-job-git-timeout 0.5))
      (drgnx-job-approve id)
      (let ((tree (drgnx-job--task-tree id 1)))
        (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) tree (concat "job/" id))
        (write-region "work\n" nil (concat tree "w.txt") nil 'silent)
        (drgnx-job-run-test--git tree "add" "-A")
        (drgnx-job-run-test--git tree "commit" "-q" "-m" "work"))
      (write-region "#!/bin/sh\nsleep 20\n" nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job--merge id (drgnx-coord-task tid))
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (c) (equal (plist-get c :kind) "merge-failed")) (drgnx-coord-cards id "open"))) 15))
      (should (string-search "did not finish" (plist-get (car (drgnx-coord-cards id "open")) :title)))
      (should (equal (drgnx-job-run-test--git (drgnx-job--job-tree id) "status" "--porcelain") "")))))

(ert-deftest drgnx-job/verdict-is-the-last-line-only ()
  (let ((verdict (lambda (text) (drgnx-job--verdict (drgnx-agents--make :id "s-v" :entries (list (list :type 'agent :text text)))))))
    (should (eq (funcall verdict "Looked at it.\nVERDICT: pass") 'pass))
    (should (eq (funcall verdict "Looked at it.\nVERDICT: pass\n\n  ") 'pass))              ; trailing blanks
    (should (equal (funcall verdict "Looked at it.\nVERDICT: fail: rename foo") '(fail . "rename foo")))
    (should (eq (funcall verdict "Looked at it.\n**VERDICT: pass**") 'pass))                ; Markdown round the line
    (should (eq (funcall verdict "Looked at it.\n`VERDICT: pass`") 'pass))
    (should (equal (funcall verdict "> *VERDICT: fail: rename foo*") '(fail . "rename foo")))
    ;; a mention earlier in the text is not the verdict
    (should-not (funcall verdict "I would write VERDICT: pass if foo were renamed.\nBut it is not done."))
    (should (equal (funcall verdict "VERDICT: pass\nOn second thought, no.\nVERDICT: fail: broken") '(fail . "broken")))
    (should-not (funcall verdict "The format is VERDICT: pass or VERDICT: fail: why."))))

(ert-deftest drgnx-job/complete-with-no-commits-is-a-card ()
  ;; complete_task with nothing committed: no reviewer for an empty diff, the user decides
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (tid (concat id "#1")))
      (drgnx-job-approve id)
      (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) (drgnx-job--task-tree id 1) (concat "job/" id))
      (drgnx-coord-force-status tid "in-review" "s-gone")
      (drgnx-job-step id)
      (let ((card (car (seq-filter (lambda (c) (equal (plist-get c :kind) "review")) (drgnx-coord-cards id "open")))))
        (should card)
        (should (string-search "no commits" (plist-get card :title))))
      (should (equal (drgnx-job-run-test--status id 1) "needs-input"))
      (should-not (seq-find (lambda (s) (gethash (drgnx-agent-session-id s) drgnx-job--reviewers)) drgnx-agents--sessions)))))

(ert-deftest drgnx-job/a-stopped-tail-turn-does-not-hold-the-review ()
  ;; the user Stops the agent after complete_task: its turn is over (held by the Stop), the review goes on
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (tid (concat id "#1")) (reviews 0))
      (cl-letf (((symbol-function 'drgnx-job--start-review) (lambda (&rest _) (setq reviews (1+ reviews)))))
        (drgnx-job-approve id)
        (let ((s (drgnx-job-review-test--agent id 1)))
          (drgnx-agents-send s "slow")
          (should (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'busy))))
          (drgnx-coord-force-status tid "in-review" (drgnx-agent-session-id s))
          (drgnx-agents-stop s)
          (should (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'exited)) 20))
          (should (> reviews 0)))))))

;;; job-review-test.el ends here
