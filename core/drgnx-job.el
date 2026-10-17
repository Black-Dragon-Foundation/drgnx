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
    (unless (equal (plist-get job :status) "proposed") (user-error "Job %s is %s, not proposed" id (plist-get job :status)))
    (let ((tree (drgnx-job--job-tree id)))
      (unless (file-directory-p tree)
        (make-directory (file-name-directory (directory-file-name tree)) t)
        (pcase (drgnx-job--git (plist-get job :repo) "worktree" "add" "-q" "-b" (concat "job/" id) tree "HEAD")
          (`(0 . ,_))
          (`(,_ . ,err) (user-error "Job %s: no job branch: %s" id err)))))
    (drgnx-coord-job-set id :status "running" :data (plist-put (plist-get job :data) :budget budget))
    (drgnx-job-step id)
    id))

(defun drgnx-job--live (id)
  "Job ID's live sessions that work on its tasks (reviewers apart)."
  (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))
                               (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
              (drgnx-agents-sessions)))

(defun drgnx-job--session (sid) (and sid (drgnx-agents-get sid)))

(defun drgnx-job--start-task (id task)
  "Give TASK (a store plist) of job ID an agent in its own worktree."
  (let* ((n (plist-get task :n)) (tree (drgnx-job--task-tree id n)) (repo (drgnx-job--repo id)))
    (unless (file-directory-p tree)
      (or (eql 0 (car (drgnx-job--git repo "worktree" "add" "-q" "-b" (format "job/%s-%d" id n) tree (concat "job/" id))))
          (eql 0 (car (drgnx-job--git repo "worktree" "add" "-q" tree (format "job/%s-%d" id n))))   ; its branch from before
          (error "No worktree for %s" (plist-get task :id))))
    (let* ((profile (car (drgnx-job-route (intern (or (plist-get task :role) "implement")))))
           (s (drgnx-agents-start profile tree (plist-get task :id) id))
           (body (plist-get (seq-find (lambda (x) (= (plist-get x :n) n)) (plist-get (plist-get (drgnx-coord-job id) :data) :tasks)) :body)))
      (drgnx-coord-force-status (plist-get task :id) "claimed" (drgnx-agent-session-id s))
      (puthash (drgnx-agent-session-id s)
               (format "[drgnx task %s] %s\n\n%s\n\nWork only in this directory (a git worktree of your own). Commit your work. Then call complete_task."
                       (plist-get task :id) (plist-get task :title) (or body ""))
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
           ;; finished: its agent's work is done
           ((and (equal status "in-review") (member agent live))
            (drgnx-agents-kill (drgnx-job--session agent))))))
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
    (let* ((sid (drgnx-agent-session-id s)) (prompt (gethash sid drgnx-job--prompts)))
      (when (and prompt (drgnx-agents-free-p s))
        (remhash sid drgnx-job--prompts)
        (drgnx-agents-deliver s prompt)
        (drgnx-coord-force-status (drgnx-agent-session-task s) "running" sid)))
    (when (or (eq (drgnx-agent-session-status s) 'exited)
              (and (drgnx-agents-free-p s)
                   (equal (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :status) "in-review")))
      (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S" (drgnx-job-step job)))))))

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

(provide 'drgnx-job)
;;; drgnx-job.el ends here
