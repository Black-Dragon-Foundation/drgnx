;;; drgnx-job.el --- Jobs: a plan in, a job out — proposal, approval, agents per task, review, merge -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The user hands drgnx a plan.  drgnx reads it (the work tracker's grammar: `### Task N:', plus `**Depends:**',
;; `**Role:**', `**Repo:**', `**Won't build:**' lines), snapshots it and proposes a job: the tasks, what depends on
;; what, the agent profile for each role, the run order and an estimate.  Nothing starts before the user approves
;; (or automatic start is on).  Then the hub runs one agent per ready task in its own worktree, answers routine
;; permission requests by a policy per role, has a reviewer check each finished task, merges what passes into the
;; job's branch, pauses the job at its budget and moves an agent to its next profile when its provider fails.
;; Nothing reaches the main branch without the user.  See docs/guide/jobs.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-coord)
(require 'drgnx-agents)
(require 'drgnx-gateway)

(defvar drgnx-job-routes nil
  "Alist ROLE (a symbol: implement, test, review, docs) → agent profile name (or a list: fallbacks in order).  Read
from agents.eld's :routes when nil.")

(defvar drgnx-job-default-profile "claude" "The profile a role without a route gets.")
(defvar drgnx-job-task-tokens '(150000 . 15000) "The estimate's tokens per task: (INPUT . OUTPUT).")
(defvar drgnx-job-auto-start nil "Non-nil: a proposed job starts at once, without waiting for approval.")
(defvar drgnx-job-max-agents 3 "Agents of one job working at once.")

;;;; Reading a plan

(defun drgnx-job--lines (text regexp)
  "Every first group of REGEXP in TEXT."
  (let (out (start 0))
    (while (string-match regexp text start)
      (push (string-trim (match-string 1 text)) out)
      (setq start (match-end 0)))
    (nreverse out)))

(defun drgnx-job-read-plan (file)
  "FILE read as a job: (:title :repo :tasks ((:n :title :role :deps :body)…) :decisions ((:kind :subject)…) :sha)."
  (let* ((text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (dir (file-name-directory (expand-file-name file)))
         (title (car (drgnx-job--lines text "^# \\(.+\\)$")))
         (repo (car (drgnx-job--lines text "^\\*\\*Repo:\\*\\* *\\(.+\\)$")))
         (heads nil) (start 0))
    (while (string-match "^### Task \\([0-9]+\\)[:.]? *\\(.*\\)$" text start)
      (push (list (string-to-number (match-string 1 text)) (string-trim (match-string 2 text)) (match-end 0) (match-beginning 0)) heads)
      (setq start (match-end 0)))
    (setq heads (nreverse heads))
    (list :title (or title (file-name-base file))
          :repo (and repo (file-name-as-directory (expand-file-name repo dir)))
          :tasks (cl-loop for (n ttl body-start) in heads
                          for body-end = (or (and (string-match "^##" text body-start) (match-beginning 0)) (length text))
                          for body = (substring text body-start body-end)
                          collect (list :n n :title ttl
                                        :role (or (car (drgnx-job--lines body "^\\*\\*Role:\\*\\* *\\([a-z-]+\\)")) "implement")
                                        :deps (mapcar #'string-to-number
                                                      (drgnx-job--lines (or (car (drgnx-job--lines body "^\\*\\*Depends:\\*\\* *\\(.*\\)$")) "")
                                                                        "Task \\([0-9]+\\)"))
                                        :body (string-trim body)))
          :decisions (mapcar (lambda (s) (list :kind "wont-build" :subject s))
                             (drgnx-job--lines text "^\\*\\*Won't build:\\*\\* *\\(.+\\)$"))
          :sha (secure-hash 'sha1 text))))

(defun drgnx-job--check (tasks)
  "Refuse TASKS whose dependencies name a task that is not there, or go round in a cycle."
  (let ((ns (mapcar (lambda (task) (plist-get task :n)) tasks)))
    (dolist (task tasks)
      (dolist (d (plist-get task :deps))
        (unless (memq d ns) (user-error "Task %d depends on Task %d, which the plan does not have" (plist-get task :n) d))))
    (let ((state (make-hash-table)))                 ; n → visiting | done
      (cl-labels ((visit (n path)
                    (pcase (gethash n state)
                      ('done nil)
                      ('visiting (user-error "The plan's dependencies go round in a cycle: %s"
                                             (mapconcat (lambda (x) (format "Task %d" x)) (reverse (cons n path)) " → ")))
                      (_ (puthash n 'visiting state)
                         (dolist (d (plist-get (seq-find (lambda (task) (= (plist-get task :n) n)) tasks) :deps))
                           (visit d (cons n path)))
                         (puthash n 'done state)))))
        (dolist (n ns) (visit n nil))))))

;;;; Proposing

(declare-function drgnx-ai-agent-gateway-chain "drgnx-ai")
(declare-function drgnx-ai-provider "drgnx-ai")
(defvar drgnx-ai-gateway-kinds)

(defun drgnx-job--routes ()
  (or drgnx-job-routes (plist-get (drgnx-agents--read-file) :routes)))

(defun drgnx-job-route (role)
  "ROLE's profiles, in order (the first is used; the rest are its fallbacks)."
  (let ((r (alist-get role (drgnx-job--routes))))
    (cond ((null r) (list drgnx-job-default-profile)) ((listp r) r) (t (list r)))))

(defun drgnx-job--price (profile)
  "PROFILE's price (IN . OUT) per million tokens when its traffic goes through the gateway, else nil."
  (when-let* ((kind (plist-get (cdr (drgnx-agents-profile profile)) :ai)))
    (require 'drgnx-ai)
    (when (memq kind drgnx-ai-gateway-kinds)
      (plist-get (drgnx-ai-provider (car (car (drgnx-ai-agent-gateway-chain kind)))) :price))))

(defun drgnx-job--estimate (tasks)
  "(:usd N :tokens N :unpriced (PROFILE…)) for TASKS on their routes."
  (let ((usd 0.0) (unpriced nil) (in (car drgnx-job-task-tokens)) (out (cdr drgnx-job-task-tokens)))
    (dolist (task tasks)
      (let* ((profile (car (drgnx-job-route (intern (plist-get task :role))))) (price (drgnx-job--price profile)))
        (if price (setq usd (+ usd (/ (+ (* in (car price)) (* out (cdr price))) 1e6)))
          (cl-pushnew profile unpriced :test #'equal))))
    (list :usd usd :tokens (* (length tasks) (+ in out)) :unpriced (nreverse unpriced))))

(defun drgnx-job--new-id ()
  (let* ((base (format-time-string "job-%Y%m%d-%H%M%S")) (id base) (n 1))
    (while (drgnx-coord-job id) (setq n (1+ n) id (format "%s-%d" base n)))
    id))

(cl-defun drgnx-job-propose (file &key repo budget)
  "Propose a job from the plan FILE (snapshotted now), in REPO (the plan's **Repo:** line, else REPO, else the plan's
own repository).  Returns its id; nothing starts (unless `drgnx-job-auto-start')."
  (let* ((plan (drgnx-job-read-plan file))
         (tasks (plist-get plan :tasks))
         (_ (progn (unless tasks (user-error "%s has no `### Task N:' headings" file)) (drgnx-job--check tasks)))
         (repo (or (plist-get plan :repo) (and repo (file-name-as-directory (expand-file-name repo)))
                   (locate-dominating-file file ".git")
                   (user-error "No repository for this job: give one, or a **Repo:** line in the plan")))
         (id (drgnx-job--new-id))
         (roles (delete-dups (mapcar (lambda (task) (intern (plist-get task :role))) tasks)))
         (proposal (list :plan (expand-file-name file) :sha (plist-get plan :sha) :repo repo :title (plist-get plan :title)
                         :tasks tasks :routes (mapcar (lambda (r) (cons r (car (drgnx-job-route r)))) roles)
                         :estimate (drgnx-job--estimate tasks) :budget budget)))
    (drgnx-coord-job-create :id id :title (plist-get plan :title) :plan (expand-file-name file) :repo repo
                            :tasks (mapcar (lambda (task) (list :n (plist-get task :n) :title (plist-get task :title)
                                                                :role (plist-get task :role) :deps (plist-get task :deps)))
                                           tasks)
                            :data proposal)
    (dolist (d (plist-get plan :decisions))
      (drgnx-coord-decide :kind (plist-get d :kind) :subject (plist-get d :subject) :job id :author "user"
                          :reason "the plan says so" :seen (drgnx-coord-version)))
    (when (and drgnx-job-auto-start (fboundp 'drgnx-job-approve)) (drgnx-job-approve id))
    id))

(defun drgnx-job-get (id)
  "Job ID as the store has it, its proposal under :proposal."
  (when-let* ((job (drgnx-coord-job id)))
    (append (list :proposal (plist-get job :data)) job)))

(defun drgnx-job-plan-changed-p (id)
  "Has job ID's plan file changed since it was proposed?  (The job never follows it by itself.)"
  (let* ((prop (plist-get (drgnx-job-get id) :proposal)) (file (plist-get prop :plan)))
    (not (and file (file-readable-p file)
              (equal (secure-hash 'sha1 (with-temp-buffer (insert-file-contents file) (buffer-string))) (plist-get prop :sha))))))

;;;; Running (in the hub)

(defvar drgnx-job--prompts (make-hash-table :test #'equal) "Session id → its task prompt, given once it is free.")
(defvar drgnx-job--reviewers (make-hash-table :test #'equal) "Session id → the task it reviews.")

(defun drgnx-job--git (dir &rest args)
  "Run git ARGS in DIR (short operations: worktrees, merges): (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (cons (apply #'call-process "git" nil t nil args) (string-trim (buffer-string))))))

(defun drgnx-job--repo (job) (plist-get (drgnx-coord-job job) :repo))
(defun drgnx-job--job-tree (job) (expand-file-name (format ".claude/worktrees/%s/" job) (drgnx-job--repo job)))
(defun drgnx-job--task-tree (job n) (expand-file-name (format ".claude/worktrees/%s-%d/" job n) (drgnx-job--repo job)))

(cl-defun drgnx-job-approve (id &key budget)
  "Start job ID: its branch job/ID from the repository's HEAD (in a worktree of its own), then its ready tasks."
  (let ((job (drgnx-coord-job id)))
    (unless job (user-error "No job %s" id))
    (unless (equal (plist-get job :status) "proposed") (user-error "Job %s is %s, not proposed" id (plist-get job :status)))
    (let ((tree (drgnx-job--job-tree id)))
      (unless (file-directory-p tree)
        (make-directory (file-name-directory (directory-file-name tree)) t)
        (pcase (drgnx-job--git (plist-get job :repo) "worktree" "add" "-q" "-b" (concat "job/" id) tree "HEAD")
          (`(0 . ,_))
          (`(,_ . ,err) (user-error "Job %s: no job branch: %s" id err)))))
    (drgnx-coord-job-set id :status "running" :data (plist-put (plist-get job :data) :budget (or budget (plist-get (plist-get job :data) :budget))))
    (drgnx-job-step id)
    id))

(defun drgnx-job--live (id)
  "Job ID's live sessions that work on its tasks (reviewers apart)."
  (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))
                               (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
              (drgnx-agents-sessions)))

(defun drgnx-job--session (sid) (and sid (drgnx-agents-get sid)))

(defun drgnx-job--start-task (id task &optional profile handover)
  "Give TASK (a store plist) of job ID an agent (PROFILE, default its role's first) in its own worktree; HANDOVER:
what the agent before it left (`drgnx-job--fall-back')."
  (let* ((n (plist-get task :n)) (tree (drgnx-job--task-tree id n)) (repo (drgnx-job--repo id)))
    (unless (file-directory-p tree)
      (or (eql 0 (car (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-%d" id n) tree (concat "job/" id))))
          (eql 0 (car (drgnx-job--git repo "worktree" "add" "-q" tree (format "job/%s-%d" id n))))   ; its branch from before
          (error "No worktree for %s" (plist-get task :id))))
    (let* ((profile (or profile (car (drgnx-job-route (intern (or (plist-get task :role) "implement"))))))
           (s (drgnx-agents-start profile tree (plist-get task :id) id))
           (body (plist-get (seq-find (lambda (x) (= (plist-get x :n) n)) (plist-get (plist-get (drgnx-coord-job id) :data) :tasks)) :body)))
      (drgnx-coord-force-status (plist-get task :id) "claimed" (drgnx-agent-session-id s))
      (puthash (drgnx-agent-session-id s)
               (format "[drgnx task %s] %s\n\n%s\n\n%s%sWork only in this directory (a git worktree of your own). Commit your work. Then call complete_task."
                       (plist-get task :id) (plist-get task :title) (or body "") (or handover "")
                       (if-let* ((notes (alist-get (plist-get task :id) (plist-get (plist-get (drgnx-coord-job id) :data) :notes) nil nil #'equal)))
                           (format "The reviewer asked for changes:\n%s\n\n" (drgnx-job--quote notes))
                         ""))
               drgnx-job--prompts)
      (drgnx-job--session-changed s))))

(defun drgnx-job-step (id)
  "Move job ID on: tasks whose agent is gone are free again; finished agents end; ready tasks get agents (up to
`drgnx-job-max-agents'); the job is done when every task is."
  (when (equal (plist-get (drgnx-coord-job id) :status) "running")
    (let ((live (mapcar #'drgnx-agent-session-id (drgnx-job--live id))))
      (dolist (task (drgnx-coord-tasks id))
        (let ((status (plist-get task :status)) (agent (plist-get task :agent)))
          (cond
           ;; its agent died or the hub restarted: the task is free (its worktree stays)
           ((and (member status '("claimed" "running")) (not (member agent live)))
            (drgnx-coord-force-status (plist-get task :id) "ready" nil))
           ;; finished: its agent's work is done; a reviewer looks at it
           ((equal status "in-review")
            (when (member agent live) (drgnx-agents-kill (drgnx-job--session agent)))
            (when (and drgnx-job-review (not (drgnx-job--reviewer-of (plist-get task :id))))
              (drgnx-job--start-review id task))))))
      (let ((count (length (drgnx-job--live id))))
        (dolist (task (drgnx-coord-tasks id))
          (when (and (equal (plist-get task :status) "ready") (< count drgnx-job-max-agents))
            (drgnx-job--start-task id task)
            (setq count (1+ count)))))
      (when (seq-every-p (lambda (task) (member (plist-get task :status) '("done" "dropped"))) (drgnx-coord-tasks id))
        (drgnx-coord-job-set id :status "done")))))

(defun drgnx-job-tick ()
  "Move every running job on (the hub's tick)."
  (dolist (id (drgnx-coord-jobs "running")) (with-demoted-errors "drgnx job: %S" (drgnx-job-step id))))

(defun drgnx-job--session-changed (s)
  "A job session changed (`drgnx-agents-changed-functions'): a free one gets its task prompt; an ended one moves its
job on."
  (when-let* ((job (drgnx-agent-session-job s)))
    (let* ((sid (drgnx-agent-session-id s)) (prompt (gethash sid drgnx-job--prompts))
           (reviewer (gethash sid drgnx-job--reviewers)))
      (cond
       ((and prompt (drgnx-agents-free-p s) (equal (plist-get (drgnx-coord-job job) :status) "running"))
        (remhash sid drgnx-job--prompts)
        (drgnx-agents-deliver s prompt)
        (if reviewer (puthash sid t drgnx-job--reviewing)
          (drgnx-coord-force-status (drgnx-agent-session-task s) "running" sid)))
       ;; a reviewer's turn is over: its verdict
       ((and reviewer (gethash sid drgnx-job--reviewing) (drgnx-agents-free-p s))
        (remhash sid drgnx-job--reviewing)
        (let ((verdict (drgnx-job--verdict s)))
          (drgnx-agents-kill s)
          (drgnx-job--reviewed job reviewer verdict)))))
    (when (or (eq (drgnx-agent-session-status s) 'exited)
              (and (drgnx-agents-free-p s)
                   (equal (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :status) "in-review")))
      (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S" (drgnx-job-step job)))))))

;;;; Review and merge

(defvar drgnx-job-review t
  "Non-nil: a finished task is reviewed by an agent (role `review') and merged when it passes.  nil: it waits in
review for the user.")
(defvar drgnx-job-review-tries 3 "Failed reviews after which the user decides.")
(defvar drgnx-job--reviewing (make-hash-table :test #'equal) "Reviewer session id → t once its prompt went out.")

(defun drgnx-job--quote (text)
  (mapconcat (lambda (l) (concat "> " l)) (split-string (or text "") "\n") "\n"))

(defun drgnx-job--reviewer-of (task)
  "The live reviewer session of TASK, or nil."
  (seq-find (lambda (s) (and (equal (gethash (drgnx-agent-session-id s) drgnx-job--reviewers) task)
                             (not (eq (drgnx-agent-session-status s) 'exited))))
            (drgnx-agents-sessions)))

(defun drgnx-job--start-review (id task)
  "A reviewer for TASK of job ID, in the task's worktree (the review policy: reads only)."
  (let* ((s (drgnx-agents-start (car (drgnx-job-route 'review)) (drgnx-job--task-tree id (plist-get task :n)) (plist-get task :id) id))
         (sid (drgnx-agent-session-id s)))
    (puthash sid (plist-get task :id) drgnx-job--reviewers)
    (puthash sid (format "[drgnx review %s] %s\n\nReview the changes: git diff job/%s...HEAD.  Answer with a last line VERDICT: pass, or VERDICT: fail: what to change."
                         (plist-get task :id) (plist-get task :title) id)
             drgnx-job--prompts)
    (drgnx-job--session-changed s)))

(defun drgnx-job--verdict (s)
  "Reviewer S's verdict from its last words: `pass', (fail . REASONS), or nil."
  (let ((text (plist-get (car (last (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)))) :text)))
    (cond ((null text) nil)
          ((string-match "VERDICT: *pass" text) 'pass)
          ((string-match "VERDICT: *fail:? *\\(.*\\)" text) (cons 'fail (string-trim (match-string 1 text)))))))

(defun drgnx-job--reviewed (id task-id verdict)
  "TASK-ID of job ID was reviewed: pass → merged; fail → back to an agent with the reasons (the user after
`drgnx-job-review-tries'); no verdict → the user."
  (let* ((job (drgnx-coord-job id)) (data (plist-get job :data)) (task (drgnx-coord-task task-id)))
    (pcase verdict
      ('pass (drgnx-job--merge id task))
      (`(fail . ,reasons)
       (let ((fails (1+ (alist-get task-id (plist-get data :fails) 0 nil #'equal))))
         (setf (alist-get task-id (plist-get data :fails) nil nil #'equal) fails)
         (setf (alist-get task-id (plist-get data :notes) nil nil #'equal) reasons)
         (drgnx-coord-job-set id :data data)
         (if (>= fails drgnx-job-review-tries)
             (drgnx-job--card id task-id "review" (format "failed review %d times: %s" fails reasons))
           (drgnx-coord-force-status task-id "ready" nil))))
      (_ (drgnx-job--card id task-id "review" "the reviewer gave no verdict")))
    (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S" (drgnx-job-step id))))))

(defun drgnx-job--merge (id task)
  "Merge TASK's branch into job ID's branch (once): done, and its dependents may start; a conflict is aborted and
goes to the user."
  (let* ((tree (drgnx-job--job-tree id)) (branch (format "job/%s-%d" id (plist-get task :n))))
    (cond
     ((equal (plist-get task :status) "done"))
     ((eql 0 (car (drgnx-job--git tree "merge-base" "--is-ancestor" branch "HEAD")))   ; merged before
      (drgnx-coord-force-status (plist-get task :id) "done" (plist-get task :agent)))
     ((eql 0 (car (drgnx-job--git tree "merge" "--no-ff" "-q" "-m" (format "Merge %s: %s" (plist-get task :id) (plist-get task :title)) branch)))
      (drgnx-coord-force-status (plist-get task :id) "done" (plist-get task :agent)))
     (t
      (let ((files (cdr (drgnx-job--git tree "diff" "--name-only" "--diff-filter=U"))))
        (drgnx-job--git tree "merge" "--abort")
        (drgnx-job--card id (plist-get task :id) "merge-conflict"
                         (format "merging into job/%s conflicts in: %s" id (string-join (split-string files "\n" t) ", "))))))))

;;;; The budget, a failing provider

(defun drgnx-job-budget (id) "Job ID's budget in USD, or nil." (and id (plist-get (plist-get (drgnx-coord-job id) :data) :budget)))

(defun drgnx-job--gateway-event (event data)
  "`drgnx-gateway-event-functions': a running job whose budget is spent pauses — its agents stop, the user decides."
  (when-let* (((eq event 'budget)) (id (plist-get data :job))
              ((equal (plist-get (drgnx-coord-job id) :status) "running")))
    (drgnx-coord-job-set id :status "paused")
    (dolist (s (drgnx-agents-sessions))
      (when (and (equal (drgnx-agent-session-job s) id) (eq (drgnx-agent-session-status s) 'busy))
        (drgnx-agents-stop s)))
    (drgnx-job--card id nil "budget" (format "spent %s of %s USD: paused" (plist-get data :spent) (plist-get data :budget)))))

(cl-defun drgnx-job-resume (id &key budget)
  "Go on with paused or stopped job ID — with BUDGET USD for the whole job, if given: its stopped agents continue."
  (let ((job (drgnx-coord-job id)))
    (unless job (user-error "No job %s" id))
    (unless (member (plist-get job :status) '("paused" "stopped")) (user-error "Job %s is %s, not paused" id (plist-get job :status)))
    (when budget
      (drgnx-coord-job-set id :data (plist-put (plist-get job :data) :budget budget))
      (drgnx-gateway-set-budget id budget))
    (drgnx-coord-job-set id :status "running")
    (dolist (s (drgnx-agents-sessions))
      (when (and (equal (drgnx-agent-session-job s) id) (eq (drgnx-agent-session-status s) 'idle) (drgnx-agent-session-paused s))
        (setf (drgnx-agent-session-paused s) nil)
        (drgnx-agents-deliver s "The job goes on: continue where you stopped.")))
    (drgnx-job-step id)
    id))

(defconst drgnx-job--provider-limit "\\_<429\\_>\\|rate.?limit\\|overloaded\\|quota\\|too many requests"
  "What a provider at its limit says (case ignored).")

(defun drgnx-job--agent-error (s err)
  "`drgnx-agents-error-functions': the task of a job agent whose provider is at its limit goes to the next profile."
  (when (and (drgnx-agent-session-job s) (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))
             (or (eql (plist-get err :code) 429)
                 (let ((case-fold-search t)) (string-match-p drgnx-job--provider-limit (format "%s" (plist-get err :message))))))
    (let ((job (drgnx-agent-session-job s)))
      (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S" (drgnx-job--fall-back job s err)))))))

(defun drgnx-job--handover (id s)
  "What agent S of job ID leaves its successor: its last commit and its last words."
  (let* ((commit (cdr (drgnx-job--git (drgnx-agent-session-cwd s) "log" "-1" "--format=%h %s" (format "job/%s..HEAD" id))))
         (said (mapconcat (lambda (e) (or (plist-get e :text) ""))
                          (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)) ""))
         (said (substring said (max 0 (- (length said) 2000)))))
    (format "You are continuing this task: an agent began it here and stopped (its provider failed).  Its last commit: %s.%s\n\n"
            (if (string-empty-p commit) "none" commit)
            (if (string-empty-p (string-trim said)) "" (format "  Its last words:\n%s" (drgnx-job--quote said))))))

(defun drgnx-job--fall-back (id s err)
  "Agent S's provider failed (ERR): its task goes to the next profile on its role's route, in the same worktree; with
none left, to the user."
  (let* ((task (drgnx-coord-task (drgnx-agent-session-task s)))
         (from (drgnx-agent-session-profile s))
         (to (cadr (member from (drgnx-job-route (intern (or (plist-get task :role) "implement"))))))
         (why (format "%s" (plist-get err :message))))
    (when (and (equal (plist-get (drgnx-coord-job id) :status) "running")
               (equal (plist-get task :agent) (drgnx-agent-session-id s)))
      (if (not to)
          (drgnx-job--card id (plist-get task :id) "fallback" (format "%s failed (%s); no other profile on the route" from why))
        (drgnx-job--start-task id task to (drgnx-job--handover id s))   ; claims the task before S goes
        (drgnx-agents-kill s)
        (when (fboundp 'drgnx-hub--broadcast)
          (drgnx-hub--broadcast 'fallback (list :job id :task (plist-get task :id) :agent (drgnx-agent-session-name s)
                                                :from from :to to :why why)))))))

;;;; Autonomy: the permission policy per role, writes in the worktree

(defconst drgnx-job--outward-commands
  (concat "\\_<\\(?:curl\\|wget\\|ssh\\|scp\\|rsync\\|git push\\|git fetch\\|git pull\\|npm \\(?:install\\|i\\|add\\)\\|pnpm \\(?:install\\|add\\)"
          "\\|yarn \\(?:install\\|add\\)\\|pip3? install\\|uv \\(?:pip install\\|add\\)\\|cargo \\(?:install\\|add\\)\\|go get\\|gem install"
          "\\|dnf\\|yum\\|apt\\(?:-get\\)?\\|brew\\|pacman\\|podman \\(?:pull\\|push\\)\\|docker\\)\\_>")
  "Commands that reach the network or install something: a job agent asks the user for them.")

(defvar drgnx-job-policies
  '((review :allow (read search think))
    (t :allow (read edit delete move search think execute other)))
  "Per role: the tool kinds allowed without asking (paths inside the worktree, no outward command).  `t': any other
role.  Everything else — network (fetch), outward commands, paths outside the worktree — goes to the user.")

(defun drgnx-job--inside-p (path tree)
  "Is PATH inside TREE, once `..' and symlinks are resolved?"
  (and (stringp path) (file-in-directory-p (file-truename (expand-file-name path tree)) (file-truename tree))))

(defun drgnx-job-policy (role tool tree)
  "`allow' or `ask': the policy of ROLE (a string) for the ACP TOOL call (its :kind, :title, :locations) of an agent
working in TREE."
  (let* ((kind (intern (or (plist-get tool :kind) "other")))
         (allowed (plist-get (cdr (or (assq (intern (or role "implement")) drgnx-job-policies) (assq t drgnx-job-policies))) :allow))
         (paths (delq nil (mapcar (lambda (l) (plist-get l :path)) (append (plist-get tool :locations) nil)))))
    (if (and (memq kind allowed)
             (seq-every-p (lambda (p) (drgnx-job--inside-p p tree)) paths)
             (not (and (eq kind 'execute) (string-match-p drgnx-job--outward-commands (or (plist-get tool :title) "")))))
        'allow 'ask)))

(defun drgnx-job--role (s)
  (if (gethash (drgnx-agent-session-id s) drgnx-job--reviewers) "review"
    (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :role)))

(defun drgnx-job--card (job task kind title)
  "Something of JOB's TASK needs the user: the task waits (needs-input), the user gets a message and the hub's
subscribers a `card' event."
  (when task
    (drgnx-coord-force-status task "needs-input" (plist-get (drgnx-coord-task task) :agent)))
  (drgnx-coord-send :job job :sender "drgnx" :recipient "user" :text (format "[%s] %s: %s" kind (or task job) title))
  (when (fboundp 'drgnx-hub--broadcast) (drgnx-hub--broadcast 'card (list :job job :task task :kind kind :title title))))

(defun drgnx-job--request (s method params _id)
  "A job agent's request (`drgnx-agents-request-functions'): routine ones answered by its role's policy, writes in
its worktree done at once; anything else waits for the user as a card (nil: the session keeps it pending)."
  (when-let* ((job (drgnx-agent-session-job s)))
    (let ((tree (drgnx-agent-session-cwd s)) (task (drgnx-agent-session-task s)))
      (pcase method
        ("session/request_permission"
         (let ((tool (plist-get params :toolCall)))
           (if (eq (drgnx-job-policy (drgnx-job--role s) tool tree) 'allow)
               (let ((opt (seq-find (lambda (o) (equal (plist-get o :kind) "allow_once")) (append (plist-get params :options) nil))))
                 (list :result (list :outcome (list :outcome "selected" :optionId (plist-get opt :optionId)))))
             (drgnx-job--card job task "permission" (or (plist-get tool :title) "a permission"))
             nil)))
        ("fs/write_text_file"
         (let ((path (plist-get params :path)) (content (plist-get params :content)))
           (if (and (stringp content) (drgnx-job--inside-p path tree) (not (equal (drgnx-job--role s) "review")))
               (progn (let ((coding-system-for-write 'utf-8-unix)) (write-region content nil path nil 'silent))
                      (list :result nil))
             (drgnx-job--card job task "write" (format "write %s" path))
             nil)))))))

(defun drgnx-job--answered (s)
  "The user answered S's request: its task works again (when nothing else waits)."
  (when (and (drgnx-agent-session-job s) (null (drgnx-agent-session-permissions s)) (null (drgnx-agent-session-reviews s))
             (equal (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :status) "needs-input"))
    (drgnx-coord-force-status (drgnx-agent-session-task s) "running" (drgnx-agent-session-id s))))

;;;; Stopping, what a job looks like, `drgnx job'

(defun drgnx-job-stop (id)
  "Stop job ID: its agents end (their worktrees stay); `drgnx-job-resume' starts its open tasks again."
  (unless (drgnx-coord-job id) (user-error "No job %s" id))
  (drgnx-coord-job-set id :status "stopped")
  (dolist (s (drgnx-agents-sessions))
    (when (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited)))
      (drgnx-agents-kill s)))
  id)

(defun drgnx-job-summary (id)
  "Job ID for the user (and JSON): status, budget and spend, tasks with their profiles, agents, cards, pending
permissions."
  (when-let* ((job (drgnx-coord-job id)))
    (let* ((data (plist-get job :data))
           (sessions (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))))
                                 (drgnx-agents-sessions))))
      (list :id id :title (plist-get job :title) :status (plist-get job :status) :repo (plist-get job :repo)
            :plan (plist-get job :plan) :budget (plist-get data :budget)
            :spent (plist-get (drgnx-work-db-spend :job id) :cost) :estimate (plist-get data :estimate)
            :tasks (mapcar (lambda (task)
                             (list :n (plist-get task :n) :title (plist-get task :title) :role (plist-get task :role)
                                   :profile (car (drgnx-job-route (intern (or (plist-get task :role) "implement"))))
                                   :status (plist-get task :status) :agent (plist-get task :agent) :deps (plist-get task :deps)))
                           (drgnx-coord-tasks id))
            :agents (mapcar (lambda (s) (list :id (drgnx-agent-session-id s) :profile (drgnx-agent-session-profile s)
                                              :task (drgnx-agent-session-task s) :status (drgnx-agent-session-status s)
                                              :review (and (gethash (drgnx-agent-session-id s) drgnx-job--reviewers) t)))
                            sessions)
            :cards (mapcar (lambda (m) (list :text (plist-get m :text) :state (plist-get m :state)))
                           (seq-filter (lambda (m) (equal (plist-get m :job) id)) (drgnx-coord-inbox "user")))
            :permissions (mapcan (lambda (s) (mapcar (lambda (p) (list :agent (drgnx-agent-session-id s) :title (plist-get p :title)))
                                                     (drgnx-agent-session-permissions s)))
                                 sessions)))))

(defun drgnx-job-format (job)
  "JOB (a `drgnx-job-summary', also as JSON gives it back) as text."
  (let ((v (lambda (x) (and x (not (eq x :null)) x))))
    (concat
     (format "%s  %s  [%s]\n" (plist-get job :id) (plist-get job :title) (plist-get job :status))
     (format "  repository %s\n" (plist-get job :repo))
     (mapconcat (lambda (task)
                  (format "  Task %s: %s  — %s on %s, %s%s\n" (plist-get task :n) (plist-get task :title) (plist-get task :role)
                          (plist-get task :profile) (plist-get task :status)
                          (if-let* ((deps (funcall v (plist-get task :deps))))
                              (format ", after %s" (mapconcat (lambda (d) (format "Task %s" d)) deps ", "))
                            "")))
                (funcall v (plist-get job :tasks)) "")
     (let ((e (plist-get job :estimate)))
       (format "  estimate ~%.2f USD, %s tokens%s\n" (or (funcall v (plist-get e :usd)) 0) (plist-get e :tokens)
               (if-let* ((u (funcall v (plist-get e :unpriced)))) (format " (unpriced: %s)" (string-join u ", ")) "")))
     (format "  budget %s, spent %.2f USD\n" (if-let* ((b (funcall v (plist-get job :budget)))) (format "%s USD" b) "none")
             (or (funcall v (plist-get job :spent)) 0))
     (mapconcat (lambda (a) (format "  agent %s (%s) %s on %s\n" (plist-get a :id) (plist-get a :profile) (plist-get a :status)
                                    (plist-get a :task)))
                (funcall v (plist-get job :agents)) "")
     (mapconcat (lambda (p) (format "  asks: %s (%s)\n" (plist-get p :title) (plist-get p :agent))) (funcall v (plist-get job :permissions)) "")
     (mapconcat (lambda (c) (format "  card: %s\n" (plist-get c :text))) (funcall v (plist-get job :cards)) ""))))

(declare-function drgnx-hub-ensure "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")
(declare-function drgnx-hub--jsonable "drgnx-hub")

(defun drgnx-job-cli ()
  "`drgnx job propose PLAN [--repo DIR] [--budget USD] [--auto] | approve ID [--budget USD] | status [ID] [--json] |
stop ID | resume ID [--budget USD]', through the hub."
  (require 'drgnx-hub)
  (let* ((args (prog1 (cdr (member "--" command-line-args-left)) (setq command-line-args-left nil)))
         (opt (lambda (name) (cadr (member name args))))
         (budget (and (funcall opt "--budget") (string-to-number (funcall opt "--budget"))))
         (json (member "--json" args))
         (pos (let (out skip) (dolist (a (cdr args) (nreverse out))
                                (cond (skip (setq skip nil)) ((member a '("--repo" "--budget")) (setq skip t))
                                      ((not (string-prefix-p "--" a)) (push a out))))))
         (call (lambda (method params) (drgnx-hub-ensure) (drgnx-hub-call-sync method params 30)))
         (show (lambda (job) (princ (if json (concat (json-serialize (drgnx-hub--jsonable job)) "\n") (drgnx-job-format job))) 0)))
    (kill-emacs
     (condition-case err
         (pcase (car args)
           ("propose"
            (unless (car pos) (user-error "Which plan?"))
            (let ((job (funcall call "job/propose" (list :plan (expand-file-name (car pos))
                                                         :repo (and (funcall opt "--repo") (expand-file-name (funcall opt "--repo")))
                                                         :budget budget :auto (and (member "--auto" args) t)))))
              (funcall show job)
              (unless (or json (not (equal (plist-get job :status) "proposed")))
                (princ (format "Approve with: drgnx job approve %s\n" (plist-get job :id))))
              0))
           ((and cmd (or "approve" "stop" "resume"))
            (unless (car pos) (user-error "Which job?"))
            (funcall show (funcall call (concat "job/" cmd) (list :id (car pos) :budget budget))))
           ("status"
            (let ((r (funcall call "job/status" (list :id (car pos)))))
              (cond ((car pos) (funcall show r))
                    (json (princ (concat (json-serialize (drgnx-hub--jsonable r)) "\n")) 0)
                    ((null (plist-get r :jobs)) (princ "No jobs.\n") 0)
                    (t (dolist (job (plist-get r :jobs)) (princ (drgnx-job-format job))) 0))))
           (_ (princ "usage: drgnx job propose PLAN [--repo DIR] [--budget USD] [--auto] | approve ID [--budget USD]\n                 | status [ID] [--json] | stop ID | resume ID [--budget USD]\n"
                     #'external-debugging-output)
              2))
       (error (princ (format "drgnx job: %s\n" (error-message-string err)) #'external-debugging-output) 1)))))

(provide 'drgnx-job)
;;; drgnx-job.el ends here
