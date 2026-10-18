;;; job-cockpit-test.el --- batch tests: the Work cockpit writes back to jobs (reassign, block, order, Start as Job); the merge gate -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents
(require 'drgnx-cockpit-model)

(defconst drgnx-job-cockpit-test--three "# Three\n\n### Task 1: one\n\n### Task 2: two\n\n### Task 3: three\n")

(defconst drgnx-job-cockpit-test--five
  "# Five\n\n### Task 1: one\n\n### Task 2: two\n\n### Task 3: three\n**Depends:** Task 1\n\n### Task 4: four\n**Depends:** Task 3\n\n### Task 5: five\n**Depends:** Task 2\n")

(defun drgnx-job-cockpit-test--call (method &rest params)
  "METHOD of the hub with PARAMS, as a client's call reaches it: its result, or an error with the hub's message."
  (let ((r (drgnx-hub--method method params)))
    (when (and (consp r) (eq (car r) :error)) (error "%s" (cadr r)))
    r))

(defun drgnx-job-cockpit-test--summary-task (id n)
  (seq-find (lambda (task) (= (plist-get task :n) n)) (plist-get (drgnx-job-summary id) :tasks)))

(ert-deftest drgnx-job-cockpit/reassign-blocks-and-order ()
  (drgnx-job-run-test--with drgnx-job-cockpit-test--three
    (let* ((drgnx-agents-profiles (append drgnx-agents-profiles (list (cons "mock2" (cdr (assoc "mock" drgnx-agents-profiles))))))
           (drgnx-job-max-agents 0) (id (drgnx-job-propose plan)) (t1 (concat id "#1")) (t2 (concat id "#2")) (t3 (concat id "#3")))
      (drgnx-job-approve id)
      ;; block: in the job's data, in its summary, in the graph; unblock takes it back
      (drgnx-job-cockpit-test--call "job/block" :task t1 :reason "waits on the design")
      (should (equal (alist-get t1 (plist-get (plist-get (drgnx-coord-job id) :data) :blocked) nil nil #'equal) "waits on the design"))
      (should (equal (plist-get (drgnx-job-cockpit-test--summary-task id 1) :blocked) "waits on the design"))
      (let ((node (seq-find (lambda (n) (equal (plist-get n :jtask) t1)) (plist-get (drgnx-cockpit-model) :nodes))))
        (should (equal (plist-get node :state) "blocked"))
        (should (equal (plist-get node :blocked) "waits on the design")))
      ;; order: task 3 moves (no further than the first place), then one place back: after task 1, before task 2
      (drgnx-job-cockpit-test--call "job/order" :task t3 :delta -5)
      (should (equal (plist-get (plist-get (drgnx-coord-job id) :data) :order) (list t3 t1 t2)))
      (drgnx-job-cockpit-test--call "job/order" :task t3 :delta 1)
      (should (equal (plist-get (plist-get (drgnx-coord-job id) :data) :order) (list t1 t3 t2)))
      (should (equal (plist-get (drgnx-job-summary id) :order) '(1 3 2)))
      ;; reassign a task no agent works on yet: its next agent is of the new profile
      (drgnx-job-cockpit-test--call "job/reassign" :task t3 :profile "mock2")
      (should (equal (plist-get (drgnx-job-cockpit-test--summary-task id 3) :profile) "mock2"))
      (should-error (drgnx-job-cockpit-test--call "job/reassign" :task t3 :profile "no-such-profile"))
      ;; one agent at a time: task 1 is first but blocked, task 3 comes before task 2: task 3 starts
      (setq drgnx-job-max-agents 1)
      (drgnx-job-step id)
      (should (equal (gethash t3 drgnx-job--busy) "starting"))
      (should-not (gethash t1 drgnx-job--busy))
      (should (drgnx-job-run-test--wait
               (lambda () (seq-find (lambda (s) (and (equal (drgnx-agent-session-task s) t3) (equal (drgnx-agent-session-profile s) "mock2")))
                                    drgnx-agents--sessions))
               20))
      (drgnx-job-cockpit-test--call "job/unblock" :task t1)
      (should-not (plist-get (plist-get (drgnx-coord-job id) :data) :blocked))
      (should-not (plist-get (drgnx-job-cockpit-test--summary-task id 1) :blocked))
      ;; reassign a task that waits on the user: its card is settled, the task is ready again for a new agent
      (drgnx-coord-force-status t2 "needs-input" nil)
      (let ((cid (drgnx-job--card id t2 "agent" "its agent ended 3 times without finishing it")))
        (drgnx-job-cockpit-test--call "job/reassign" :task t2 :profile "mock2")
        (should (equal (plist-get (drgnx-coord-card cid) :state) "settled"))
        (should (equal (drgnx-job-run-test--status id 2) "ready"))
        (should (equal (alist-get t2 (plist-get (plist-get (drgnx-coord-job id) :data) :profiles) nil nil #'equal) "mock2")))
      ;; a task in review is not reassigned (its reviewer would answer for another agent's work), and a verdict for a
      ;; task no longer in review is ignored: nothing merges
      (drgnx-coord-force-status t2 "in-review" nil)
      (should-error (drgnx-job-cockpit-test--call "job/reassign" :task t2 :profile "mock2"))
      (drgnx-coord-force-status t2 "ready" nil)
      (drgnx-job--reviewed id t2 'pass)
      (should-not (gethash t2 drgnx-job--busy))
      (should (equal (drgnx-job-run-test--status id 2) "ready"))
      ;; a reason is bounded and cleaned: no control or bidi characters reach the store or the cockpit
      (drgnx-job-cockpit-test--call "job/block" :task t2 :reason (concat "a\e[31mb‮c\tz" (make-string 10000 ?x)))
      (let ((why (alist-get t2 (plist-get (plist-get (drgnx-coord-job id) :data) :blocked) nil nil #'equal)))
        (should (<= (length why) 500))
        (should (string-prefix-p "a [31mb c z" why))
        (should-not (string-match-p "[[:cntrl:]‪-‮⁦-⁩]" why)))
      ;; a finished task is not reassigned, blocked or moved
      (drgnx-coord-force-status t2 "done" nil)
      (should-error (drgnx-job-cockpit-test--call "job/reassign" :task t2 :profile "mock"))
      (should-error (drgnx-job-cockpit-test--call "job/block" :task t2 :reason "x"))
      (should-error (drgnx-job-cockpit-test--call "job/order" :task t2 :delta 1)))))

(ert-deftest drgnx-job-cockpit/start-as-job-proposes-one-task-and-its-needs ()
  (drgnx-job-run-test--with drgnx-job-cockpit-test--five
    (let* ((s (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 4))
           (id (plist-get s :id)))
      (should (equal (plist-get s :status) "proposed"))           ; nothing starts before approval
      (should (equal (mapcar (lambda (task) (plist-get task :n)) (drgnx-coord-tasks id)) '(1 3 4)))
      (should (equal (plist-get (drgnx-coord-task (concat id "#4")) :deps) (list (concat id "#3"))))
      (should (string-search "Task 4" (plist-get (drgnx-coord-job id) :title)))
      (should (seq-find (lambda (c) (equal (plist-get c :kind) "proposal")) (drgnx-coord-cards id "open")))
      (should-not (drgnx-job-run-test--sessions id))
      (should-not (file-directory-p (drgnx-job--job-tree id)))
      ;; a task with no needs is a job of one task; a number the plan does not have is an error
      (should (equal (mapcar (lambda (task) (plist-get task :n)) (drgnx-coord-tasks (plist-get (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 2) :id)))
                     '(2)))
      (should-error (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 9))
      ;; no task number (or not a whole one) is an error, never the whole plan
      (let ((jobs (length (drgnx-coord-jobs))))
        (should-error (drgnx-job-cockpit-test--call "job/start-task" :plan plan))
        (should-error (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 4.0))
        (should (= (length (drgnx-coord-jobs)) jobs))))))

(ert-deftest drgnx-job-cockpit/plan-files-are-never-written ()
  (drgnx-job-run-test--with drgnx-job-cockpit-test--five
    (set-file-times plan (time-subtract (current-time) 100))       ; an mtime a write would move
    (let* ((drgnx-agents-profiles (append drgnx-agents-profiles (list (cons "mock2" (cdr (assoc "mock" drgnx-agents-profiles))))))
           (drgnx-job-max-agents 0)
           (bytes (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally plan) (buffer-string)))
           (mtime (file-attribute-modification-time (file-attributes plan)))
           (id (plist-get (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 4) :id)))
      (drgnx-job-cockpit-test--call "job/approve" :id id)
      (drgnx-job-cockpit-test--call "job/block" :task (concat id "#1") :reason "later")
      (drgnx-job-cockpit-test--call "job/unblock" :task (concat id "#1"))
      (drgnx-job-cockpit-test--call "job/order" :task (concat id "#3") :delta -1)
      (drgnx-job-cockpit-test--call "job/order" :task (concat id "#3") :delta 1)
      (drgnx-job-cockpit-test--call "job/reassign" :task (concat id "#1") :profile "mock2")
      (drgnx-job-cockpit-test--call "job/start-task" :plan plan :n 5)
      (drgnx-job-cockpit-test--call "job/propose" :plan plan :gate "review+accept")
      (should (equal (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally plan) (buffer-string)) bytes))
      (should (equal (file-attribute-modification-time (file-attributes plan)) mtime))
      (should (equal (drgnx-job-run-test--git repo "status" "--porcelain" "--" "docs") "")))))

(ert-deftest drgnx-job-cockpit/gate-review-merges-as-today ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((id (plist-get (drgnx-job-cockpit-test--call "job/propose" :plan plan :gate "review") :id)))
      (should (eq (plist-get (plist-get (drgnx-coord-job id) :data) :gate) 'review))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 30))
      (should (string-search (format "Merge %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (concat "job/" id))))
      (should-not (seq-find (lambda (c) (plist-get (plist-get c :data) :gate)) (drgnx-coord-cards id))))))

(defun drgnx-job-cockpit-test--accept (agent file &optional hash)
  "Accept FILE of AGENT's edits as the Work cockpit's Accept does: a review mark with the hash of the diff its edits
show (`drgnx-cockpit-edit-source', `drgnx-cockpit-file-diff'), or HASH."
  (let ((diff nil))
    (unless hash
      (drgnx-cockpit-file-diff (drgnx-cockpit-edit-source agent) file (lambda (r) (setq diff r)))
      (should (drgnx-job-run-test--wait (lambda () diff) 10))
      (should (stringp diff))
      (should-not (string-empty-p diff)))
    (drgnx-coord-review-mark agent file "accepted" (or hash (secure-hash 'sha1 diff)))))

(defun drgnx-job-cockpit-test--gate-card (id)
  (seq-find (lambda (c) (plist-get (plist-get c :data) :gate)) (drgnx-coord-cards id "open")))

(ert-deftest drgnx-job-cockpit/gate-review-and-accept-waits-for-every-file ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-merge-gate 'review+accept)         ; the proposer's option goes with the job
           (id (plist-get (drgnx-job-cockpit-test--call "job/propose" :plan plan) :id))
           (tid (concat id "#1")) (tree nil) (agent nil))
      (should (eq (plist-get (plist-get (drgnx-coord-job id) :data) :gate) 'review+accept))
      (drgnx-job-approve id)
      ;; it passed review: it waits on you, nothing merged
      (should (drgnx-job-run-test--wait
               (lambda () (let ((c (drgnx-job-cockpit-test--gate-card id))) (and c (string-search "0 of 1" (plist-get c :title)))))
               40))
      (let ((card (drgnx-job-cockpit-test--gate-card id)))
        (should (equal (plist-get card :kind) "review"))
        (should (equal (plist-get card :title) "waiting on your review: 0 of 1 files accepted"))
        (should (equal (mapcar #'car (drgnx-job-card-actions card)) '("edits" "accept" "retry" "drop")))
        (should (member "edits" drgnx-job--showing-actions)))
      (should (equal (drgnx-job-run-test--status id 1) "needs-input"))
      (should-not (string-search "Merge" (drgnx-job-run-test--git repo "log" "--format=%s" (concat "job/" id))))
      (setq tree (drgnx-job--task-tree id 1) agent (plist-get (drgnx-coord-task tid) :agent))
      (should agent)
      ;; a second file in the task's branch: now two to accept
      (write-region "more\n" nil (concat tree "second.txt") nil 'silent)
      (drgnx-job-run-test--git tree "add" "second.txt")
      (drgnx-job-run-test--git tree "commit" "-q" "-m" "second")
      (should (drgnx-job-run-test--wait (lambda () (string-search "0 of 2" (plist-get (drgnx-job-cockpit-test--gate-card id) :title))) 15))
      ;; a mark whose hash is not the diff's (it changed since) does not count
      (drgnx-job-cockpit-test--accept agent "task.txt" "0000")
      (drgnx-job-cockpit-test--accept agent "second.txt")
      (should (drgnx-job-run-test--wait (lambda () (string-search "1 of 2" (plist-get (drgnx-job-cockpit-test--gate-card id) :title))) 15))
      (should-not (equal (drgnx-job-run-test--status id 1) "done"))
      ;; a rename and a delete: the old name goes, the new one and the deleted file are to accept
      (drgnx-job-run-test--git tree "mv" "second.txt" "renamed.txt")
      (drgnx-job-run-test--git tree "rm" "-q" "README")
      (drgnx-job-run-test--git tree "commit" "-q" "-m" "rename and delete")
      (should (drgnx-job-run-test--wait (lambda () (string-search "0 of 3" (plist-get (drgnx-job-cockpit-test--gate-card id) :title))) 15))
      (drgnx-job-cockpit-test--accept agent "renamed.txt")
      (drgnx-job-cockpit-test--accept agent "README")
      (should (drgnx-job-run-test--wait (lambda () (string-search "2 of 3" (plist-get (drgnx-job-cockpit-test--gate-card id) :title))) 15))
      ;; every file accepted, but the worktree has a change no commit holds: nothing merges
      (write-region "scratch\n" nil (concat tree "scratch.txt") nil 'silent)
      (drgnx-job-cockpit-test--accept agent "scratch.txt")
      (drgnx-job-cockpit-test--accept agent "task.txt")
      (should (drgnx-job-run-test--wait (lambda () (let ((title (plist-get (drgnx-job-cockpit-test--gate-card id) :title)))
                                                     (and (string-search "4 of 4" title) (string-search "uncommitted" title))))
                                        15))
      (should-not (equal (drgnx-job-run-test--status id 1) "done"))
      ;; the worktree clean again, every file accepted: it merges
      (delete-file (concat tree "scratch.txt"))
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 30))
      (should-not (drgnx-job-cockpit-test--gate-card id))
      (should (string-search (format "Merge %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (concat "job/" id)))))))

(ert-deftest drgnx-job-cockpit/gate-counts-every-agent-of-the-task ()
  ;; a second agent of the task (back to an agent, a fall-back, a reassign) is registered with the task's first base:
  ;; the gate counts every agent's commits; a file the edits cannot show counts and is never accepted
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((drgnx-job-max-agents 0)
           (id (plist-get (drgnx-job-cockpit-test--call "job/propose" :plan plan :gate "review+accept") :id))
           (tid (concat id "#1")) (tree nil) (base nil) (a nil) (b nil))
      (drgnx-job-approve id)
      (drgnx-coord-job-set id :status "paused")        ; its agents get no prompt: the test makes their commits
      (setq tree (drgnx-job--task-tree id 1))
      (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-1" id) tree (concat "job/" id))
      (setq base (drgnx-job-git-head tree))
      (drgnx-job--launch-task id (drgnx-coord-task tid))
      (setq a (plist-get (drgnx-coord-task tid) :agent))
      (should (equal (plist-get (drgnx-coord-agent a) :base) base))
      (write-region "a\n" nil (concat tree "a.txt") nil 'silent)
      (drgnx-job-run-test--git tree "add" "a.txt")
      (drgnx-job-run-test--git tree "commit" "-q" "-m" "a")
      (drgnx-job--launch-task id (drgnx-coord-task tid) "mock")
      (setq b (plist-get (drgnx-coord-task tid) :agent))
      (should-not (equal a b))
      (should (equal (plist-get (drgnx-coord-agent b) :base) base))   ; not the HEAD at its launch
      (write-region "b\n" nil (concat tree "b.txt") nil 'silent)
      (write-region "outside\n" nil (concat root "outside.txt") nil 'silent)
      (make-symbolic-link (concat root "outside.txt") (concat tree "key"))
      (drgnx-job-run-test--git tree "add" "b.txt" "key")
      (drgnx-job-run-test--git tree "commit" "-q" "-m" "b")
      (dolist (s drgnx-agents--sessions) (ignore-errors (drgnx-agents-kill s)))
      (drgnx-coord-job-set id :status "running")
      (let ((cid (drgnx-job--card id tid "review" "waiting on your review" nil (list :gate t :agent b))))
        (drgnx-job--gate-check id cid)
        (should (drgnx-job-run-test--wait (lambda () (string-search "0 of 3" (plist-get (drgnx-coord-card cid) :title))) 15))
        (drgnx-job-cockpit-test--accept b "a.txt")
        (drgnx-job-cockpit-test--accept b "b.txt")
        (should (drgnx-job-run-test--wait (lambda () (string-search "2 of 3" (plist-get (drgnx-coord-card cid) :title))) 15))
        (should (equal (plist-get (drgnx-coord-card cid) :state) "open"))
        (should-not (equal (drgnx-job-run-test--status id 1) "done"))))))

(ert-deftest drgnx-job-cockpit/gate-merge-as-it-is-stays-the-user-s ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: first\n"
    (let* ((id (plist-get (drgnx-job-cockpit-test--call "job/propose" :plan plan :gate "review+accept") :id)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-cockpit-test--gate-card id)) 40))
      (drgnx-job-card-act (plist-get (drgnx-job-cockpit-test--gate-card id) :id) "accept")
      (should (drgnx-job-run-test--wait (lambda () (equal (drgnx-job-run-test--status id 1) "done")) 20)))))

;;; job-cockpit-test.el ends here
