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
(require 'drgnx-timer)
(require 'drgnx-coord)
(require 'drgnx-agents)
(require 'drgnx-gateway)
(require 'drgnx-cockpit-model)                  ; the merge gate reads a task's edits as the Work cockpit shows them

(defvar drgnx-job-routes nil
  "Alist ROLE (a symbol: implement, test, review, docs) → agent profile name (or a list: fallbacks in order).  Read
from `drgnx-agents-routes' when nil.")

(defvar drgnx-job-default-profile "claude" "The profile a role without a route gets.")
(defvar drgnx-job-task-tokens '(150000 . 15000) "The estimate's tokens per task: (INPUT . OUTPUT).")
(defvar drgnx-job-auto-start nil "Non-nil: a proposed job starts at once, without waiting for approval.")
(defvar drgnx-job-max-agents 3 "Agents of one job working at once.")

(defcustom drgnx-job-merge-gate 'review
  "What a finished task of a job needs before it is merged into the job's branch.
`review': its reviewer's pass (as before).  `review+accept': the pass, then every file its agent changed accepted in
its edits (the Work cockpit's Accept: a review mark with the hash of the file's diff); until then a `review' card
says how many are, with Open its edits.  Accepting never merges by itself, and the card's Merge as it is stays
yours.  A job keeps the gate it was proposed with (the hub runs it): this option counts in the Emacs that proposes."
  :type '(choice (const :tag "The reviewer's pass" review) (const :tag "The pass, then every file accepted" review+accept))
  :group 'drgnx-cockpit)

(defun drgnx-job--gate-value (gate)
  "GATE (a symbol, or a string from JSON; nil: `drgnx-job-merge-gate') as a merge gate, or an error."
  (let ((g (cond ((stringp gate) (seq-find (lambda (s) (equal (symbol-name s) gate)) '(review review+accept)))   ; never interned
                 (gate) (t drgnx-job-merge-gate))))
    (unless (memq g '(review review+accept)) (user-error "No merge gate %s: review or review+accept" (or gate g)))
    g))

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
  "Refuse TASKS that number a task twice, whose dependencies name a task that is not there, or go round in a cycle."
  (let ((ns (mapcar (lambda (task) (plist-get task :n)) tasks)))
    (dolist (n ns)
      (when (> (cl-count n ns) 1) (user-error "Task %d appears twice in the plan" n)))
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
(declare-function drgnx-hub-note-permission-answer "drgnx-hub")
(defvar drgnx-ai-gateway-kinds)
(defvar drgnx-job-review)

(defun drgnx-job--routes ()
  (or drgnx-job-routes (default-value 'drgnx-agents-routes)))

(defun drgnx-job-route (role)
  "ROLE's profiles, in order (the first is used; the rest are its fallbacks)."
  (let ((r (alist-get role (drgnx-job--routes))))
    (cond ((null r) (list drgnx-job-default-profile)) ((listp r) r) (t (list r)))))

(defun drgnx-job-safe-p (profile)
  "May a job run an agent of PROFILE (a name)?  `drgnx-agents-job-safe-p', which `drgnx-agents-start' checks too;
the job checks first, so that it raises a card (`drgnx-job--refuse-unsafe') rather than start a session that ends."
  (drgnx-agents-job-safe-p profile))

(defun drgnx-job--refuse-unsafe (id task profile &optional data)
  "Non-nil when PROFILE is not job-safe (`drgnx-job-safe-p'): then TASK (an id) of job ID gets an `agent' card (with
DATA) that says why and which profiles may run it, and no agent starts.  Without TASK (a clash's reviewer) the card
is the job's, of kind `profile', which the user dismisses."
  (unless (drgnx-job-safe-p profile)
    (let ((p (cdr (ignore-errors (drgnx-agents-profile profile)))))
      (drgnx-job--card
       id task (if task "agent" "profile")
       (format "%s cannot run a job's agent: %s; use %s (drgnx-agents-routes)" profile
               (cond ((null p) "there is no such profile")
                     ((and (eq system-type 'darwin) (plist-get p :job-safe) (not (plist-get p :ai)))
                      "on macOS a job's Claude runs on a gateway profile (the subscription keeps its token in the Keychain)")
                     (t "this profile's agent can read a repository's own settings"))
               (mapconcat #'identity (seq-filter #'drgnx-job-safe-p (mapcar #'car drgnx-agents-builtin-profiles)) ", "))
       nil (append (list :profile profile) data)))
    t))

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

(defun drgnx-job--unpriced-chain (profiles)
  "The profiles among PROFILES (names) that go through the gateway with a provider that has no :price in their chain:
what they spend is not counted, so a budget cannot stop them."
  (seq-filter (lambda (profile)
                (when-let* ((kind (plist-get (cdr (drgnx-agents-profile profile)) :ai)))
                  (require 'drgnx-ai)
                  (and (memq kind drgnx-ai-gateway-kinds)
                       (seq-some (lambda (p) (null (plist-get (drgnx-ai-provider (car p)) :price))) (drgnx-ai-agent-gateway-chain kind)))))
              profiles))

(defun drgnx-job--budget-warning (unpriced)
  "What a budget over the UNPRICED profiles (`drgnx-job--unpriced-chain') comes to, or nil."
  (and unpriced (format "a budget is set, but %s has a provider without a price: what it spends is not counted"
                        (string-join unpriced ", "))))

(defun drgnx-job--new-id ()
  (let* ((base (format-time-string "job-%Y%m%d-%H%M%S")) (id base) (n 1))
    (while (drgnx-coord-job id) (setq n (1+ n) id (format "%s-%d" base n)))
    id))

(defun drgnx-job--needs (tasks n)
  "Task N of TASKS and every task it depends on, directly or not, in the plan's order (Start as Job)."
  (let ((want nil) (todo (list n)))
    (unless (natnump n) (user-error "Not a task number: %S" n))
    (while todo
      (let* ((k (pop todo)) (task (seq-find (lambda (x) (= (plist-get x :n) k)) tasks)))
        (unless task (user-error (if (= k n) "The plan has no Task %d" "A task depends on Task %d, which the plan does not have") k))
        (unless (memq k want)
          (push k want)
          (setq todo (append (plist-get task :deps) todo)))))
    (seq-filter (lambda (x) (memq (plist-get x :n) want)) tasks)))

(cl-defun drgnx-job-propose (file &key repo budget only gate)
  "Propose a job from the plan FILE (snapshotted now; the file is only read), in REPO (the plan's **Repo:** line, else
REPO, else the plan's own repository).  ONLY: a task's number — the job is that task and the tasks it needs (Start as
Job).  GATE: its merge gate (`drgnx-job-merge-gate' when nil).  Returns its id; nothing starts (unless
`drgnx-job-auto-start')."
  (let* ((plan (drgnx-job-read-plan file))
         (gate (drgnx-job--gate-value gate))
         (tasks (if only (drgnx-job--needs (plist-get plan :tasks) only) (plist-get plan :tasks)))
         (plan (if only (plist-put plan :title (format "%s — Task %d" (plist-get plan :title) only)) plan))
         (_ (progn (unless tasks (user-error "%s has no `### Task N:' headings" file)) (drgnx-job--check tasks)))
         (repo (or (plist-get plan :repo) (and repo (file-name-as-directory (expand-file-name repo)))
                   (locate-dominating-file file ".git")
                   (user-error "No repository for this job: give one, or a **Repo:** line in the plan")))
         (id (drgnx-job--new-id))
         (roles (delete-dups (mapcar (lambda (task) (intern (plist-get task :role))) tasks)))
         (proposal (list :plan (expand-file-name file) :sha (plist-get plan :sha) :repo repo :title (plist-get plan :title)
                         :tasks tasks :routes (mapcar (lambda (r) (cons r (car (drgnx-job-route r)))) roles)
                         :estimate (drgnx-job--estimate tasks) :budget budget :gate gate
                         :unpriced-budget (and budget   ; every profile a role may fall back to, the reviewers' too
                                               (drgnx-job--unpriced-chain
                                                (delete-dups (apply #'append (mapcar #'drgnx-job-route
                                                                                     (if drgnx-job-review
                                                                                         (append '(review) (and (alist-get 'review-long (drgnx-job--routes)) '(review-long)) roles)
                                                                                       roles)))))))))
    (drgnx-coord-job-create :id id :title (plist-get plan :title) :plan (expand-file-name file) :repo repo
                            :tasks (mapcar (lambda (task) (list :n (plist-get task :n) :title (plist-get task :title)
                                                                :role (plist-get task :role) :deps (plist-get task :deps)))
                                           tasks)
                            :data proposal)
    (dolist (d (plist-get plan :decisions))
      (drgnx-coord-decide :kind (plist-get d :kind) :subject (plist-get d :subject) :job id :author "user"
                          :reason "the plan says so" :seen (drgnx-coord-version)))
    ;; with automatic start the job is approved first: the proposal card is only for a job that still waits
    (unwind-protect (when (and drgnx-job-auto-start (fboundp 'drgnx-job-approve)) (drgnx-job-approve id))
      (when (equal (plist-get (drgnx-coord-job id) :status) "proposed")
        (drgnx-job--card id nil "proposal"
                         (format "%d tasks, about %.2f USD%s: approve to start%s" (length tasks) (plist-get (plist-get proposal :estimate) :usd)
                                 (if (plist-get (plist-get proposal :estimate) :unpriced) " (some unpriced)" "")
                                 (if-let* ((w (drgnx-job--budget-warning (plist-get proposal :unpriced-budget)))) (concat " (" w ")") "")))))
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

(defvar drgnx-job-review-turn-limit 600
  "Seconds the review of a finished task waits for its agent's turn to end; then the task is the user's.")

(defvar drgnx-job-start-tries 3 "Times a task's agent may end without finishing it before the user decides.")
(defvar drgnx-job--turns-seen (make-hash-table :test #'equal) "Session id → its ended turns already looked at.")
(defvar drgnx-job--step-pending (make-hash-table :test #'equal) "Job → t while a step is scheduled.")
(defcustom drgnx-job-git-timeout 300
  "Seconds a git process of a job (a worktree add, a merge) may take; then it is ended and the user gets a card."
  :type 'number :group 'drgnx)

(defvar drgnx-job--busy (make-hash-table :test #'equal)
  "Task id → \"starting\" while its worktree is being made, \"merging\" while its branch is merged: a git process of its
own does it, the hub goes on.  The summary shows it; a restart forgets it (the store still says ready / in-review).")

;; How often a task's agent ended without finishing it (:exits) and got a nudge (:nudged) is kept in the job's record,
;; like the failed reviews: the hub restarting does not reset it.
(defun drgnx-job--count (id key task)
  "Job ID's count KEY (:exits, :nudged) for TASK: 0 when there is none."
  (alist-get task (plist-get (plist-get (drgnx-coord-job id) :data) key) 0 nil #'equal))

(defun drgnx-job--set-count (id key task n)
  "Job ID's count KEY for TASK is N (nil: none)."
  (let ((data (plist-get (drgnx-coord-job id) :data)))
    (when (or n (alist-get task (plist-get data key) nil nil #'equal))
      (setf (alist-get task (plist-get data key) nil (null n) #'equal) n)
      (drgnx-coord-job-set id :data data))))

(defun drgnx-job--turn-over-p (s)
  "Is S's turn over — it is idle and free, or idle and held by a Stop (a Stop ends the turn, not the work)?"
  (and s (eq (drgnx-agent-session-status s) 'idle) (or (drgnx-agents-free-p s) (drgnx-agent-session-paused s)) t))

(defun drgnx-job--step-later (id)
  "Step job ID soon, outside the process filter — once, however many ask."
  (unless (gethash id drgnx-job--step-pending)
    (puthash id t drgnx-job--step-pending)
    (run-at-time 0 nil (lambda () (remhash id drgnx-job--step-pending) (with-demoted-errors "drgnx job: %S" (drgnx-job-step id))))))

(defun drgnx-job--git (dir &rest args)
  "Run git ARGS in DIR (short operations: reads, the job's worktree at approval, `merge --abort'): (EXIT . OUTPUT).
OUTPUT is git's stdout, and, when it
fails, its stderr after it (where a hook's refusal and `fatal:' are)."
  (let ((err (make-temp-file "drgnx-git-err")))
    (unwind-protect
        (with-temp-buffer
          (let* ((default-directory (file-name-as-directory dir))
                 (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment))   ; never a prompt in the hub
                 (exit (apply #'call-process "git" nil (list t err) nil args)))
            (unless (eql exit 0)
              (insert "\n" (with-temp-buffer (insert-file-contents err) (buffer-string))))
            (cons exit (string-trim (buffer-string)))))
      (delete-file err))))

(defun drgnx-job--git-timed-out (p)
  "The deadline of the git process P (`drgnx-job--git-async'): mark it timed out and end it."
  (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))

(defun drgnx-job--git-async (dir args done &optional job task)
  "Run git ARGS in DIR in a process of its own, never blocking the hub; DONE is called with (EXIT . OUTPUT), as
`drgnx-job--git' gives it (stderr mixed into OUTPUT), from the process's sentinel once git has ended.  A git that takes
more than `drgnx-job-git-timeout' seconds is ended: EXIT is then `:timeout'.  JOB and TASK: whose it is — stopping JOB
ends it (DONE is not called; TASK is no longer busy).  The process."
  (let* ((out (generate-new-buffer " *drgnx-git*" t))
         (default-directory (file-name-as-directory dir))
         (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment))   ; never a prompt in the hub
         (p (make-process :name "drgnx-git" :buffer out :noquery t :connection-type 'pipe :command (cons "git" args)
                          :sentinel (lambda (p _event)
                                      (unless (process-live-p p)
                                        (drgnx-timer-cancel (cons 'job-git-timeout p))
                                        (let ((exit (process-exit-status p))
                                              (text (string-trim (with-current-buffer out (buffer-string)))))
                                          (kill-buffer out)
                                          (cond ((process-get p :stopped) (when task (remhash task drgnx-job--busy)))
                                                (t (with-demoted-errors "drgnx job: %S"
                                                     (funcall done (if (process-get p :timed-out)
                                                                       (cons :timeout (format "git did not finish in %s s%s" drgnx-job-git-timeout
                                                                                              (if (string-empty-p text) "" (concat ": " text))))
                                                                     (cons exit text))))))))))))
    (process-put p :job job)
    (drgnx-timer-start (cons 'job-git-timeout p) drgnx-job-git-timeout #'drgnx-job--git-timed-out :args (list p) :owner p)
    (ignore-errors (process-send-eof p))               ; like call-process: git (a hook) reads nothing
    p))

(defun drgnx-job--first-line (file)
  "FILE's first line, trimmed, or nil when it cannot be read."
  (ignore-errors (with-temp-buffer (insert-file-contents file nil 0 4096)
                                   (string-trim (buffer-substring (point-min) (line-end-position))))))

(defun drgnx-job--gitdirs (dir)
  "(GITDIR . COMMONDIR) of DIR's git checkout, read from its files (a linked worktree's `.git' file and `commondir'
followed), or nil — also for a remote (TRAMP) name."
  (when-let* (((stringp dir)) ((not (string-match-p "\\`/[^/|:]+[:|]" dir)))   ; never a remote (TRAMP) name
              (top (locate-dominating-file dir ".git"))
              (dotgit (expand-file-name ".git" top))
              (gitdir (if (file-directory-p dotgit) dotgit
                        (let ((line (drgnx-job--first-line dotgit)))
                          (and line (string-match "\\`gitdir: *\\(.+\\)" line) (expand-file-name (match-string 1 line) top))))))
    (cons gitdir (let ((c (drgnx-job--first-line (expand-file-name "commondir" gitdir)))) (if c (expand-file-name c gitdir) gitdir)))))

(defun drgnx-job--ref-sha (dirs ref)
  "The commit REF (`refs/…') names in the checkout of DIRS (`drgnx-job--gitdirs'): loose refs, then `packed-refs';
nil when it cannot be found."
  (let ((sha (or (drgnx-job--first-line (expand-file-name ref (car dirs))) (drgnx-job--first-line (expand-file-name ref (cdr dirs)))
                 (ignore-errors
                   (with-temp-buffer
                     (insert-file-contents (expand-file-name "packed-refs" (cdr dirs)))
                     (and (re-search-forward (concat "^\\([0-9a-f]+\\) " (regexp-quote ref) "$") nil t) (match-string 1)))))))
    (and sha (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" sha) sha)))

(defun drgnx-job-git-head (dir)
  "The commit DIR's git checkout is at (HEAD), read from the repository's files — no git process, so it costs nothing
on an agent's change — or nil (not a checkout, a remote name, a ref it cannot find).  A linked worktree's `.git' file
and `commondir', loose refs and `packed-refs' are followed."
  (when-let* ((dirs (drgnx-job--gitdirs dir)) (head (drgnx-job--first-line (expand-file-name "HEAD" (car dirs)))))
    (if (string-match "\\`ref: *\\(refs/.+\\)" head) (drgnx-job--ref-sha dirs (match-string 1 head))
      (and (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" head) head))))

(defun drgnx-job--off-branch (id task)
  "Why TASK's worktree of job ID is not what a merge of its branch takes — its HEAD is not the tip of `job/ID-N' (an
agent checked something else out) — as a line for a card, or nil when it is.  Read from the repository's files."
  (let* ((tree (drgnx-job--task-tree id (plist-get task :n))) (branch (format "job/%s-%d" id (plist-get task :n)))
         (dirs (drgnx-job--gitdirs tree)) (head (drgnx-job-git-head tree))
         (tip (and dirs (drgnx-job--ref-sha dirs (concat "refs/heads/" branch)))))
    (unless (and head (equal head tip))
      (format "its worktree is not at the tip of its branch %s (HEAD %s, the branch %s): what was looked at is not what would merge"
              branch (if head (substring head 0 8) "unknown") (if tip (substring tip 0 8) "missing")))))

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
    (drgnx-job--settle-kind id "proposal" "approve")
    (drgnx-coord-job-set id :status "running" :data (plist-put (plist-get job :data) :budget (or budget (plist-get (plist-get job :data) :budget))))
    (drgnx-job-step id)
    id))

(defun drgnx-job--live (id)
  "Job ID's live sessions that work on its tasks (reviewers apart)."
  (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))
                               (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
              (drgnx-agents-sessions)))

(defun drgnx-job--session (sid) (and sid (drgnx-agents-get sid)))

(defun drgnx-job--data-of (id key task)
  "What job ID's data KEY (an alist by task id: :blocked, :profiles) says of TASK (its id), or nil."
  (alist-get task (plist-get (plist-get (drgnx-coord-job id) :data) key) nil nil #'equal))

(defun drgnx-job--profile (id task)
  "The profile TASK (a store plist) of job ID gets an agent of: the one it was reassigned to, else its role's first."
  (or (drgnx-job--data-of id :profiles (plist-get task :id))
      (car (drgnx-job-route (intern (or (plist-get task :role) "implement"))))))

(defun drgnx-job--ordered (id tasks)
  "TASKS of job ID in its run order: the task ids of its data's :order first, in that order, then the rest by number."
  (let ((order (plist-get (plist-get (drgnx-coord-job id) :data) :order)))
    (if (null order) tasks
      (let ((rank (lambda (task) (or (cl-position (plist-get task :id) order :test #'equal) (length order)))))
        (sort (copy-sequence tasks) (lambda (a b) (< (funcall rank a) (funcall rank b))))))))   ; stable: by number after

(defun drgnx-job--start-task (id task &optional profile handover)
  "Give TASK (a store plist) of job ID an agent (PROFILE, default its role's first) in its own worktree; HANDOVER:
what the agent before it left (`drgnx-job--fall-back').  The worktree, when it has to be made, is made by a git
process of its own: the agent starts when it is there."
  (let* ((n (plist-get task :n)) (tid (plist-get task :id)) (tree (drgnx-job--task-tree id n)) (repo (drgnx-job--repo id))
         (branch (format "job/%s-%d" id n)))
    (cond
     ((gethash tid drgnx-job--busy))                               ; being made
     ((file-directory-p tree) (drgnx-job--launch-task id task profile handover))
     (t (drgnx-job--git-async
         repo (list "worktree" "add" "-q" "-b" branch tree (concat "job/" id))
         (lambda (made)
           (cond
            ((eql 0 (car made)) (drgnx-job--worktree-made id task profile handover nil))
            ((eq (car made) :timeout) (drgnx-job--worktree-made id task profile handover (cdr made)))
            (t (condition-case err
                   (drgnx-job--git-async repo (list "worktree" "add" "-q" tree branch)       ; its branch from before
                                         (lambda (again)
                                           (drgnx-job--worktree-made id task profile handover (and (not (eql 0 (car again))) (cdr again))))
                                         id tid)
                 (error (drgnx-job--worktree-made id task profile handover (error-message-string err)))))))
         id tid)
        (puthash tid "starting" drgnx-job--busy)
        (drgnx-job--changed id)))))

(defun drgnx-job--worktree-made (id task profile handover failure)
  "TASK's worktree is made (FAILURE: git's message when it could not be): its agent starts, if the task still wants one."
  (remhash (plist-get task :id) drgnx-job--busy)
  (cond (failure (drgnx-job--card id (plist-get task :id) "agent" (format "no worktree for it: %s" failure)))
        ((and (equal (plist-get (drgnx-coord-job id) :status) "running")
              (equal (plist-get (drgnx-coord-task (plist-get task :id)) :status) "ready")
              (not (drgnx-job--data-of id :blocked (plist-get task :id))))   ; blocked meanwhile: not now
         (drgnx-job--launch-task id task profile handover)))
  (drgnx-job--changed id))

(defun drgnx-job--launch-task (id task &optional profile handover)
  "The agent of TASK of job ID, in its worktree (made) — none, and a card, for a profile that is not job-safe
\(`drgnx-job--refuse-unsafe')."
  (let ((profile (or profile (drgnx-job--profile id task))))
    (unless (drgnx-job--refuse-unsafe id (plist-get task :id) profile)
      (drgnx-job--launch-safe-task id task profile handover))))

(defun drgnx-job--launch-safe-task (id task profile handover)
  "The agent of TASK of job ID on PROFILE (job-safe), in its worktree (made)."
  (let* ((n (plist-get task :n)) (tree (drgnx-job--task-tree id n))
         (s (drgnx-agents-start profile tree (plist-get task :id) id))
         ;; its edits are against where the task's worktree started (the cockpit's diffs, the merge gate), not where the
         ;; job's branch is later — the task's first base, kept in the job's data: a later agent of the task (back to an
         ;; agent, a fall-back, a reassign) shows and is gated on every agent's commits, not only its own
         (base (or (drgnx-job--data-of id :bases (plist-get task :id))
                   (let ((head (drgnx-job-git-head tree)))
                     (when head (drgnx-job--set-data id :bases (plist-get task :id) head))
                     head)))
         (_ (with-demoted-errors "drgnx job: agent not registered: %S"
              (drgnx-coord-agent-register :id (drgnx-agent-session-id s) :kind "job" :name (drgnx-agent-session-name s) :cwd tree :worktree tree
                                          :branch (format "job/%s-%d" id n) :base base :task (plist-get task :id))))
         (body (plist-get (seq-find (lambda (x) (= (plist-get x :n) n)) (plist-get (plist-get (drgnx-coord-job id) :data) :tasks)) :body)))
    (drgnx-coord-force-status (plist-get task :id) "claimed" (drgnx-agent-session-id s))
    (puthash (drgnx-agent-session-id s)
             (format "[drgnx task %s] %s\n\n%s\n\n%s%sFirst call read_decisions (the job's decision log). Work only in this directory (a git worktree of your own). Commit your work. Then call complete_task."
                     (plist-get task :id) (plist-get task :title) (or body "") (or handover "")
                     (if-let* ((notes (alist-get (plist-get task :id) (plist-get (plist-get (drgnx-coord-job id) :data) :notes) nil nil #'equal)))
                         (format "The reviewer asked for changes:\n%s\n\n" (drgnx-job--quote notes))
                       ""))
             drgnx-job--prompts)
    (drgnx-job--session-changed s)))

(defun drgnx-job-step (id)
  "Move job ID on: tasks whose agent is gone are free again; finished agents end; ready tasks get agents (up to
`drgnx-job-max-agents'); the job is done when every task is."
  (when (equal (plist-get (drgnx-coord-job id) :status) "running")
    (maphash (lambda (sid _) (unless (drgnx-job--alive-p sid) (remhash sid drgnx-job--prompts))) drgnx-job--prompts)   ; ended before it was free
    (let ((live (mapcar #'drgnx-agent-session-id (drgnx-job--live id))))
      (dolist (task (drgnx-coord-tasks id))
        (let ((status (plist-get task :status)) (agent (plist-get task :agent)))
          (cond
           ((gethash (plist-get task :id) drgnx-job--busy))               ; its worktree is being made, or its branch merged
           ;; its agent died or the hub restarted: the task is free (its worktree stays) — a few times, then the user
           ((and (member status '("claimed" "running")) (not (member agent live)))
            (let ((n (1+ (drgnx-job--count id :exits (plist-get task :id)))))
              (drgnx-job--set-count id :exits (plist-get task :id) n)
              (if (< n drgnx-job-start-tries)
                  (drgnx-coord-force-status (plist-get task :id) "ready" nil)
                (let ((s (drgnx-job--session agent)))
                  (drgnx-job--card id (plist-get task :id) "agent"
                                   (format "its agent%s ended %d times without finishing it%s" (if s (format " (%s)" (drgnx-agent-session-profile s)) "")
                                           n (if-let* ((err (and s (drgnx-agent-session-stderr s)) ) ((not (string-empty-p (string-trim err)))))
                                                 (concat ": " (substring err (max 0 (- (length err) 300))))
                                               "")))))))
           ;; a request waited for the user, and its agent is gone (the hub restarted): the request went with it
           ((and (equal status "needs-input") (drgnx-job--waiting id (plist-get task :id))
                 (not (drgnx-job--alive-p (plist-get (drgnx-job--waiting id (plist-get task :id)) :sid))))
            (let ((back (plist-get (drgnx-job--waiting id (plist-get task :id)) :back)))
              (drgnx-job--set-waiting id (plist-get task :id) nil)
              (drgnx-coord-force-status (plist-get task :id) back (and (equal back "in-review") agent))))
           ;; its agent's turn ended and the task is not finished: a nudge, then the user
           ((and (member status '("claimed" "running")) (drgnx-job--stalled-p (drgnx-job--session agent)))
            (drgnx-job--nudge id task (drgnx-job--session agent)))
           ;; finished: its agent's work is done; a reviewer looks at it — once the agent's turn is over (complete_task
           ;; comes mid-turn; `drgnx-job--session-changed' steps again when it is free)
           ((and (equal status "in-review")
                 (or (not (member agent live)) (drgnx-job--turn-over-p (drgnx-job--session agent))))
            (drgnx-job--set-count id :exits (plist-get task :id) nil) (drgnx-job--set-count id :nudged (plist-get task :id) nil)
            (drgnx-job--set-count id :in-review-since (plist-get task :id) nil)
            (when (member agent live) (drgnx-agents-kill (drgnx-job--session agent)))
            (when (and (not (run-hook-with-args-until-success 'drgnx-job-before-review-functions id task))
                       drgnx-job-review (not (drgnx-job--reviewer-of (plist-get task :id))))
              (drgnx-job--start-review id task)))
           ;; finished, but its agent's turn goes on: the review waits for it — not for ever
           ((equal status "in-review") (drgnx-job--review-wait id task)))))
      (let ((count (+ (length (drgnx-job--live id))        ; the agents to be count too: their worktrees are being made
                      (seq-count (lambda (task) (equal (gethash (plist-get task :id) drgnx-job--busy) "starting")) (drgnx-coord-tasks id))))
            (blocked (plist-get (plist-get (drgnx-coord-job id) :data) :blocked)))   ; Mark Blocked (the Work graph)
        (dolist (task (drgnx-job--ordered id (drgnx-coord-tasks id)))   ; in the run order; a blocked task waits
          (when (and (equal (plist-get task :status) "ready") (not (gethash (plist-get task :id) drgnx-job--busy)) (< count drgnx-job-max-agents)
                     (not (assoc (plist-get task :id) blocked)))
            (drgnx-job--start-task id task)
            (setq count (1+ count)))))
      (let ((finished (mapcar (lambda (task) (plist-get task :id))
                              (seq-filter (lambda (task) (member (plist-get task :status) '("done" "dropped"))) (drgnx-coord-tasks id)))))
        (dolist (c (drgnx-coord-cards id "open"))       ; their question went with the task
          (when (and (member (plist-get c :task) finished) (drgnx-coord-card-settle (plist-get c :id) "resolved"))
            (when-let* ((m (plist-get (plist-get c :data) :message))) (drgnx-coord-mark m "acted")))))
      (when (seq-every-p (lambda (task) (member (plist-get task :status) '("done" "dropped"))) (drgnx-coord-tasks id))
        (drgnx-coord-job-set id :status "done")
        (drgnx-job--gate-forget id)
        (dolist (s (drgnx-agents-sessions))                ; nothing of a finished job stays: a clash reviewer neither
          (when (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited)))
            (drgnx-agents-kill s))))
      (drgnx-job--changed id))))

(defun drgnx-job--alive-p (sid)
  (when-let* ((s (and sid (drgnx-agents-get sid)))) (not (eq (drgnx-agent-session-status s) 'exited))))

(defun drgnx-job--waiting (id task) (alist-get task (plist-get (plist-get (drgnx-coord-job id) :data) :waiting) nil nil #'equal))

(defun drgnx-job--set-waiting (id task w)
  "TASK of job ID waits on the user for the request of W (:sid SID :back STATUS), or no longer (W nil)."
  (let ((data (plist-get (drgnx-coord-job id) :data)))
    (setf (alist-get task (plist-get data :waiting) nil 'remove #'equal) w)
    (drgnx-coord-job-set id :data data)))

(defun drgnx-job--turns (s) (cl-count-if (lambda (e) (eq (plist-get e :type) 'stop)) (drgnx-agent-session-entries s)))

(defun drgnx-job--stalled-p (s)
  "Has S, free now, ended a turn not looked at yet (its task still open)?"
  (and s (drgnx-agents-free-p s) (not (gethash (drgnx-agent-session-id s) drgnx-job--prompts))
       (> (drgnx-job--turns s) (gethash (drgnx-agent-session-id s) drgnx-job--turns-seen 0))))

(defun drgnx-job--review-wait (id task)
  "TASK of job ID is in review and its agent's turn goes on (that turn may hang): when it began to wait is in the
job's record; after `drgnx-job-review-turn-limit' seconds a card."
  (let ((since (drgnx-job--count id :in-review-since (plist-get task :id))))
    (cond ((zerop since) (drgnx-job--set-count id :in-review-since (plist-get task :id) (float-time)))
          ((> (- (float-time) since) drgnx-job-review-turn-limit)
           (drgnx-job--set-count id :in-review-since (plist-get task :id) nil)
           (drgnx-job--card id (plist-get task :id) "stalled"
                            (format "its agent's turn has not ended %d minutes after it finished the task" (round (/ drgnx-job-review-turn-limit 60)))
                            nil (list :review t))))))

(defun drgnx-job--nudge (id task s)
  "S's turn ended with TASK of job ID open: once a reminder, then a card."
  (puthash (drgnx-agent-session-id s) (drgnx-job--turns s) drgnx-job--turns-seen)
  (if (zerop (drgnx-job--count id :nudged (plist-get task :id)))
      (progn (drgnx-job--set-count id :nudged (plist-get task :id) 1)
             (drgnx-agents-deliver s (format "[drgnx] Your turn ended but task %s is not finished. Finish it and call complete_task; if something blocks you, say what and call update_task with needs-input."
                                             (plist-get task :id))))
    (drgnx-job--card id (plist-get task :id) "stalled" "its agent's turns end without complete_task")))

(defvar drgnx-job-before-review-functions nil
  "Called with (JOB TASK) before TASK (a store plist) in review gets a reviewer: the first non-nil holds it (a clash
about it is open: drgnx-job-clash.el).")

(defvar drgnx-job-tick-functions nil "Called with each running JOB on the hub's tick, after its step (clash rules).")

(defun drgnx-job-tick ()
  "Move every running job on (the hub's tick)."
  (dolist (id (drgnx-coord-jobs "running"))
    (with-demoted-errors "drgnx job: %S" (drgnx-job-step id))
    (with-demoted-errors "drgnx job: %S" (drgnx-job--gate-tick id))
    (with-demoted-errors "drgnx job: %S" (run-hook-with-args 'drgnx-job-tick-functions id))))

(defvar drgnx-job--reviewing)           ; defined with the review below

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
       ;; a clash reviewer's turn is over: its recommendation (it stays, for Discuss)
       ((and (consp reviewer) (gethash sid drgnx-job--reviewing) (drgnx-agents-free-p s))
        (remhash sid drgnx-job--reviewing)
        (run-hook-with-args 'drgnx-job-clash-answer-functions job reviewer s))
       ;; a reviewer's turn is over: its verdict
       ((and reviewer (gethash sid drgnx-job--reviewing) (drgnx-agents-free-p s))
        (remhash sid drgnx-job--reviewing)
        (let ((verdict (drgnx-job--verdict s)))
          (drgnx-agents-kill s)
          (drgnx-job--reviewed job reviewer verdict sid)))))
    (when (or (eq (drgnx-agent-session-status s) 'exited)
              (and (drgnx-job--turn-over-p s)
                   (equal (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :status) "in-review")))
      (drgnx-job--step-later job))))

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
  "A reviewer for TASK of job ID, in the task's worktree (the review policy: reads only) — or, when the task added no
commit to the job's branch, a card: there is nothing to review."
  (if (equal (cdr (drgnx-job--git (drgnx-job--task-tree id (plist-get task :n)) "rev-list" "--count" (format "job/%s..HEAD" id))) "0")
      (drgnx-job--card id (plist-get task :id) "review" "finished with no commits: nothing to review")
    (drgnx-job--start-review-agent id task)))

(defun drgnx-job--start-review-agent (id task &optional profile)
  "A reviewer agent for TASK of job ID, on PROFILE (default: the first of the review route) — none, and a card, for a
profile that is not job-safe (`drgnx-job--refuse-unsafe')."
  (let ((profile (or profile (car (drgnx-job-route 'review)))))
    (unless (drgnx-job--refuse-unsafe id (plist-get task :id) profile '(:review t))
      (let* ((s (drgnx-agents-start profile (drgnx-job--task-tree id (plist-get task :n)) (plist-get task :id) id))
             (sid (drgnx-agent-session-id s)))
        (puthash sid (plist-get task :id) drgnx-job--reviewers)
        (puthash sid (format "[drgnx review %s] %s\n\nReview the changes: git diff job/%s...HEAD.  Answer with a last line VERDICT: pass, or VERDICT: fail: what to change."
                             (plist-get task :id) (plist-get task :title) id)
                 drgnx-job--prompts)
        (drgnx-job--session-changed s)))))

(defun drgnx-job--verdict (s)
  "Reviewer S's verdict, from the last non-empty line of its last words: `pass', (fail . REASONS), or nil."
  (let* ((last (car (last (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)))))
         (text (and last (drgnx-agents-entry-text last)))
         ;; the last non-empty line, without the Markdown emphasis, quote or code marks a model puts round it
         (line (car (last (split-string (or text "") "\n" t "[ \t\r]+"))))
         (line (and line (string-trim line "[*_`> \t]+" "[*_`> \t]+"))))
    (cond ((null line) nil)
          ((string-match "\\`VERDICT: *pass" line) 'pass)
          ((string-match "\\`VERDICT: *fail:? *\\(.*\\)" line) (cons 'fail (string-trim (match-string 1 line)))))))

(defun drgnx-job--reviewed (id task-id verdict &optional reviewer)
  "TASK-ID of job ID was reviewed (by session REVIEWER): pass → merged; fail → back to an agent with the reasons (the
user after `drgnx-job-review-tries'); no verdict → the user.  Each is a `review' event (:verdict pass or fail; no
data without a verdict).  A verdict for a task no longer in review (taken from it meanwhile) is ignored: it is about
work that is no longer the task's."
  (if (not (equal (plist-get (drgnx-coord-task task-id) :status) "in-review"))
      (drgnx-job--step-later id)
    (drgnx-job--reviewed-1 id task-id verdict reviewer)))

(defun drgnx-job--reviewed-1 (id task-id verdict reviewer)
  "`drgnx-job--reviewed' for a task in review."
  (drgnx-coord-event-add-best-effort
   :agent reviewer :job id :task task-id :kind "review"
   :summary (pcase verdict ('pass "pass") (`(fail . ,reasons) (format "fail: %s" reasons)) (_ "the reviewer gave no verdict"))
   :data (pcase verdict ('pass (list :verdict 'pass)) (`(fail . ,_) (list :verdict 'fail))))
  (let* ((job (drgnx-coord-job id)) (data (plist-get job :data)) (task (drgnx-coord-task task-id)))
    (pcase verdict
      ('pass (cond
              ;; the reviewer read the worktree; the merge takes the branch: they must be the same commit
              ((drgnx-job--off-branch id task)
               (drgnx-job--card id task-id "review" (format "passed review, but %s: Merge as it is merges the branch"
                                                            (drgnx-job--off-branch id task))))
              ((eq (plist-get data :gate) 'review+accept) (drgnx-job--accept-gate id task))
              (t (drgnx-job--merge id task))))
      (`(fail . ,reasons)
       (let ((fails (1+ (alist-get task-id (plist-get data :fails) 0 nil #'equal))))
         (setf (alist-get task-id (plist-get data :fails) nil nil #'equal) fails)
         (setf (alist-get task-id (plist-get data :notes) nil nil #'equal) reasons)
         (drgnx-coord-job-set id :data data)
         (if (>= fails drgnx-job-review-tries)
             (drgnx-job--card id task-id "review" (format "failed review %d times: %s" fails reasons))
           (drgnx-coord-force-status task-id "ready" nil))))
      (_ (drgnx-job--card id task-id "review" "the reviewer gave no verdict")))
    (drgnx-job--step-later id)))

(defun drgnx-job--merge (id task)
  "Merge TASK's branch into job ID's branch (once): done, and its dependents may start; a conflict is aborted and
goes to the user.  The merge itself is a git process of its own (a hook may be slow): the task says \"merging\"."
  (let* ((tree (drgnx-job--job-tree id)) (tid (plist-get task :id)) (branch (format "job/%s-%d" id (plist-get task :n))))
    (cond
     ((equal (plist-get task :status) "done"))
     ((gethash tid drgnx-job--busy))                                  ; being merged
     ((eql 0 (car (drgnx-job--git tree "merge-base" "--is-ancestor" branch "HEAD")))   ; merged before
      (drgnx-coord-force-status tid "done" (plist-get task :agent)))
     ((drgnx-job--merging-p id) (drgnx-job--merge-later id tid) (drgnx-job--changed id))   ; one merge at a time
     (t (drgnx-job--git-async tree (list "merge" "--no-ff" "-q" "-m" (format "Merge %s: %s" tid (plist-get task :title)) branch)
                              (lambda (merged) (drgnx-job--merged id task merged)) id tid)
        (puthash tid "merging" drgnx-job--busy)
        (drgnx-job--changed id)))))

(defvar drgnx-job--merge-queue (make-hash-table :test #'equal)
  "Job id → its task ids whose merge waits (busy \"queued\"), in order: one git merge at a time in a job's worktree —
two at once fail on its HEAD (\"cannot lock ref\").")
(defvar drgnx-job--merge-retried (make-hash-table :test #'equal)
  "Task id → t once its merge failed without a conflict and was queued again.")

(defun drgnx-job--merging-p (id)
  "Does a git merge run in job ID's worktree?"
  (seq-some (lambda (task) (equal (gethash (plist-get task :id) drgnx-job--busy) "merging")) (drgnx-coord-tasks id)))

(defun drgnx-job--merge-later (id tid)
  "Merge TID into job ID's branch after the merges before it (`drgnx-job--merge-next')."
  (puthash tid "queued" drgnx-job--busy)
  (unless (member tid (gethash id drgnx-job--merge-queue))
    (puthash id (append (gethash id drgnx-job--merge-queue) (list tid)) drgnx-job--merge-queue)))

(defun drgnx-job--merge-next (id)
  "Start the merge that waits first in job ID's queue, unless one runs."
  (unless (drgnx-job--merging-p id)
    (when-let* ((tid (pop (gethash id drgnx-job--merge-queue))))
      (remhash tid drgnx-job--busy)
      (drgnx-job--merge id (drgnx-coord-task tid)))))

(defun drgnx-job--merged (id task merged)
  "TASK of job ID was merged by git (MERGED: (EXIT . OUTPUT)): done; or, aborted, the user's."
  (let ((tree (drgnx-job--job-tree id)) (tid (plist-get task :id)))
    (remhash tid drgnx-job--busy)
    (if (eql 0 (car merged))
        (progn (drgnx-coord-force-status tid "done" (plist-get task :agent))
               (drgnx-coord-event-add-best-effort :agent (plist-get task :agent) :job id :task tid :kind "status"
                                                  :summary (format "%s merged into job/%s" tid id)
                                                  :data (list :status "merged" :into (concat "job/" id))))
      (let ((files (split-string (cdr (drgnx-job--git tree "diff" "--name-only" "--diff-filter=U")) "\n" t)))
        (unless (eql 0 (car (drgnx-job--git tree "merge" "--abort")))
          (drgnx-job--git tree "reset" "--merge"))             ; no merge to abort (git was cut off before it began one)
        (cond (files (drgnx-job--card id tid "merge-conflict"
                                      (format "merging into job/%s conflicts in: %s" id (string-join files ", "))))
              ;; no conflict (a lock another git held, a hook): once more, after what merges now — then the user
              ((and (integerp (car merged)) (not (gethash tid drgnx-job--merge-retried)))
               (puthash tid t drgnx-job--merge-retried)
               (drgnx-job--merge-later id tid))
              (t (remhash tid drgnx-job--merge-retried)
                 (drgnx-job--card id tid "merge-failed" (format "merge failed: %s" (cdr merged)))))))
    (drgnx-job--merge-next id)
    (drgnx-job--step-later id)
    (drgnx-job--changed id)))

;;;; The merge gate: every file accepted (`drgnx-job-merge-gate' review+accept)

(defvar drgnx-job--gate-checks (make-hash-table :test #'equal)
  "Gate card id → (JOB . STARTED) while a look at its task's files runs: one look at a time.  The look's callback
removes it; so do stopping and finishing the job; one older than four `drgnx-cockpit-git-timeout's (a callback lost
to an error) no longer counts.")

(defun drgnx-job--gate-busy-p (cid)
  "Does a look at gate card CID run (`drgnx-job--gate-checks')?"
  (when-let* ((e (gethash cid drgnx-job--gate-checks)))
    (< (- (float-time) (cdr e)) (* 4 drgnx-cockpit-git-timeout))))

(defvar drgnx-job--gate-looked (make-hash-table :test #'equal)
  "Gate card id → (JOB STATE AT DIRTY): its last look — what it depended on (`drgnx-job--gate-state'), when it began,
whether the worktree was not clean.  In the hub's memory, not the card's data, so a look that finds nothing new
writes nothing and sends no event; a hub that restarts looks again.  Forgotten with its card or its job.")

(defun drgnx-job--gate-forget (id)
  "Job ID ended (stopped or done): its looks no longer count."
  (dolist (table (list drgnx-job--gate-checks drgnx-job--gate-looked))
    (let ((gone nil))
      (maphash (lambda (cid e) (when (equal (car e) id) (push cid gone))) table)
      (dolist (cid gone) (remhash cid table)))))

(defun drgnx-job--accept-gate (id task)
  "TASK of job ID passed review under the gate review+accept: a `review' card says it waits on you (it does until
every file its agent changed is accepted and its worktree is clean, `drgnx-job--gate-check'), with Open its edits;
Merge as it is stays yours."
  (let ((cid (drgnx-job--card id (plist-get task :id) "review" "waiting on your review: looking at its files"
                              nil (list :gate t :agent (plist-get task :agent)))))
    (drgnx-job--gate-check id cid)))

(defun drgnx-job--gate-source (id task agent)
  "Where TASK of job ID has its edits, as the Work cockpit's edits of its AGENT show them
\(`drgnx-cockpit-edit-source'): its worktree, against the base the agent was registered with — the task's first base,
whichever agent it is (`drgnx-job--launch-task') — else where it forked from the job's branch."
  (let ((base (and agent (plist-get (drgnx-coord-agent agent) :base))))
    (list :dir (drgnx-job--task-tree id (plist-get task :n)) :base (or base (concat "job/" id)) :merge-base (not base) :paths nil)))

(defun drgnx-job--mtime (file) (file-attribute-modification-time (file-attributes file)))

(defun drgnx-job--gate-state (id task agent)
  "What the gate's answer for TASK of job ID depends on, as a hash: AGENT's review marks, the commit the task's
worktree is at and its branch's tip (`drgnx-job--off-branch'), and its working tree as far as reading two dates shows
it — the index's (a revert in the edits rewrites it) and the worktree folder's (a file made or deleted there)."
  (let* ((tree (drgnx-job--task-tree id (plist-get task :n))) (gitdir (car (drgnx-job--gitdirs tree))))
    (secure-hash 'sha1 (prin1-to-string (list (and agent (drgnx-coord-review-marks agent)) (drgnx-job-git-head tree)
                                              (drgnx-job--off-branch id task)
                                              (and gitdir (drgnx-job--mtime (expand-file-name "index" gitdir)))
                                              (drgnx-job--mtime tree))))))

(defconst drgnx-job--gate-dirty-again 5
  "Seconds between two looks at a gate card's task whose worktree was not clean: a change inside a folder of it is
seen by no date `drgnx-job--gate-state' reads.")

(defun drgnx-job--gate-check (id cid &optional again)
  "Look (git, asynchronously) at whether every file of gate card CID's task is accepted and its worktree clean and at
its branch's tip, unless a look runs or — AGAIN, the hub's tick — nothing it depends on changed since the last
\(`drgnx-job--gate-state'; a worktree that was not clean: every `drgnx-job--gate-dirty-again' s).  A worktree that is
not at its branch's tip (`drgnx-job--off-branch') is not looked at: what it shows is not what would merge.  Then
`drgnx-job--gate-answer'."
  (when-let* ((card (drgnx-coord-card cid)) ((equal (plist-get card :state) "open")) ((not (drgnx-job--gate-busy-p cid)))
              (task (drgnx-coord-task (plist-get card :task))))
    (let* ((agent (plist-get (plist-get card :data) :agent)) (state (drgnx-job--gate-state id task agent))
           (last (gethash cid drgnx-job--gate-looked)))
      (when (or (not again) (not (equal state (nth 1 last)))
                (and (nth 3 last) (>= (- (float-time) (nth 2 last)) drgnx-job--gate-dirty-again)))
        (puthash cid (list id state (float-time) (nth 3 last)) drgnx-job--gate-looked)
        (puthash cid (cons id (float-time)) drgnx-job--gate-checks)
        (let ((answer (lambda (r) (remhash cid drgnx-job--gate-checks)
                        (with-demoted-errors "drgnx job: %S" (drgnx-job--gate-answer id cid r state)))))
          (condition-case err
              (if-let* ((off (drgnx-job--off-branch id task))) (funcall answer (list :off off))
                (drgnx-job--accepted (drgnx-job--gate-source id task agent) agent answer))
            (error (funcall answer (list :error (error-message-string err))))))))))

(defun drgnx-job--accepted (source agent done)
  "How many of the files SOURCE changed (`drgnx-cockpit-changed-files') AGENT's review marks accept — a mark
\"accepted\" whose hash is that of the file's diff now, as the cockpit's edits hash it (`drgnx-cockpit-file-diff') —
and whether its worktree is clean (`git status'), asked of git asynchronously.  Files past the listing's cap and those
the edits refuse to show (a link out of the worktree, a submodule…) count, and are never accepted.  DONE gets
\(:accepted N :files M :dirty BOOL), or (:error MESSAGE) — also when something on the way signals."
  (let ((marks (and agent (drgnx-coord-review-marks agent))) (dir (plist-get source :dir)))
    (cl-flet ((guarded (fn) (lambda (r) (condition-case err (funcall fn r) (error (funcall done (list :error (error-message-string err))))))))
      (drgnx-cockpit-changed-files
       source
       (guarded
        (lambda (files)
          (if (keywordp (car files))
              (funcall done (list :error (if (plist-get files :too-large) "too many changed files to list" (plist-get files :error))))
            (let* ((unseen (apply #'+ (mapcar (lambda (f) (+ (or (plist-get f :more) 0) (or (plist-get f :refused) 0))) files)))
                   (names (delq nil (mapcar (lambda (f) (plist-get f :file)) files)))
                   (marked (seq-filter (lambda (f) (equal (plist-get (cdr (assoc f marks)) :state) "accepted")) names))
                   (total (+ unseen (length names))) (accepted 0) (next nil))
              ;; only a marked file's diff is asked for, one at a time; then whether the worktree is clean
              (setq next (lambda ()
                           (if (null marked)
                               (drgnx-cockpit--git dir '("status" "--porcelain" "--untracked-files=all")
                                                   (guarded (lambda (st)
                                                              (funcall done (list :accepted accepted :files total
                                                                                  :dirty (not (and (eql 0 (plist-get st :exit))
                                                                                                   (string-empty-p (string-trim (plist-get st :out)))))))))
                                                   drgnx-cockpit-diff-max-bytes)
                             (let ((f (pop marked)))
                               (drgnx-cockpit-file-diff source f
                                                        (guarded
                                                         (lambda (r)
                                                           (cond ((equal r "") (setq total (1- total)))   ; no change after all
                                                                 ((and (stringp r) (equal (secure-hash 'sha1 r) (plist-get (cdr (assoc f marks)) :hash)))
                                                                  (setq accepted (1+ accepted))))
                                                           (funcall next))))))))
              (funcall next)))))))))

(defun drgnx-job--gate-answer (id cid r state)
  "The look at gate card CID's task came back (R: `drgnx-job--accepted''s answer; STATE: `drgnx-job--gate-state' when
it started).  Every file accepted, at least one, and the worktree clean: the card is settled and the task merged —
unless something changed since the look began, then it looks again.  Else the card says what it waits for.  A card
settled meanwhile (Merge as it is, Back to an agent, Drop) or a job no longer running: nothing."
  (when-let* ((card (drgnx-coord-card cid)) ((equal (plist-get card :state) "open"))
              ((equal (plist-get (drgnx-coord-job id) :status) "running"))
              (task (drgnx-coord-task (plist-get card :task))))
    (let* ((data (plist-get card :data)) (err (or (plist-get r :error) (plist-get r :off)))
           (n (plist-get r :accepted)) (m (plist-get r :files))
           (title (cond ((plist-get r :off)
                         (format "waiting on your review: %s (check out its branch again, or Merge as it is merges the branch)"
                                 (plist-get r :off)))
                        (err (format "waiting on your review: its files cannot be listed (%s)" err))
                        ((eql m 0) "waiting on your review: no changed file to accept (Merge as it is, or Back to an agent)")
                        ((plist-get r :dirty)
                         (format "waiting on your review: %d of %d files accepted; its worktree has uncommitted changes (commit or discard them, or Merge as it is)" n m))
                        (t (format "waiting on your review: %d of %d files accepted" n m)))))
      (cond
       ((and (not err) (> m 0) (>= n m) (not (plist-get r :dirty))
             (not (equal state (drgnx-job--gate-state id task (plist-get data :agent)))))
        (drgnx-job--gate-check id cid))                       ; changed while it looked: look again, never merge on it
       ((and (not err) (> m 0) (>= n m) (not (plist-get r :dirty)))
        (when (drgnx-coord-card-settle cid "accepted")
          (remhash cid drgnx-job--gate-looked)
          (when-let* ((msg (plist-get data :message))) (drgnx-coord-mark msg "acted"))
          (drgnx-job--merge id task)))
       (t
        (when-let* ((last (gethash cid drgnx-job--gate-looked)))   ; in the hub's memory: the card's data stays as it is
          (setf (nth 3 last) (and (plist-get r :dirty) t)))
        (unless (equal title (plist-get card :title))
          (drgnx-coord-card-set cid :title title)
          (drgnx-job--broadcast 'card (list :id cid :job id :task (plist-get task :id) :kind "review" :title title)))))
      (drgnx-job--changed id))))

(defun drgnx-job--gate-tick (id)
  "On the hub's tick (`drgnx-job-tick'): job ID's open gate cards look again when what they depend on changed."
  (dolist (c (drgnx-coord-cards id "open"))
    (when (plist-get (plist-get c :data) :gate) (drgnx-job--gate-check id (plist-get c :id) t))))

;;;; The budget, a failing provider

(defun drgnx-job-budget (id) "Job ID's budget in USD, or nil." (and id (plist-get (plist-get (drgnx-coord-job id) :data) :budget)))

(defvar drgnx-hub--behind-front)
(declare-function drgnx-hub-call-front "drgnx-hub-client")

(defun drgnx-job--gateway-event (event data)
  "`drgnx-gateway-event-functions', and behind Ratatoskr the front's `budget' notification (drgnx-hub.el): a running
job whose budget is spent pauses — its agents stop, the user decides."
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
    (unless (file-directory-p (drgnx-job--job-tree id))      ; a rejected proposal: it never got a job branch
      (user-error "Job %s has no job worktree (it was never approved, or the worktree was removed): propose the plan again" id))
    (when budget
      (drgnx-coord-job-set id :data (plist-put (plist-get job :data) :budget budget))
      ;; behind Ratatoskr the gateway is the front's
      (if (bound-and-true-p drgnx-hub--behind-front) (drgnx-hub-call-front "gateway/set-budget" (list :job id :budget budget))
        (drgnx-gateway-set-budget id budget)))
    (drgnx-coord-job-set id :status "running")
    (dolist (task (drgnx-coord-tasks id)) (drgnx-job--set-count id :in-review-since (plist-get task :id) nil))   ; the pause was no wait
    (dolist (s (drgnx-agents-sessions))
      (when (and (equal (drgnx-agent-session-job s) id) (eq (drgnx-agent-session-status s) 'idle) (drgnx-agent-session-paused s))
        (setf (drgnx-agent-session-paused s) nil)
        (drgnx-agents-deliver s "The job goes on: continue where you stopped.")))
    ;; the others, free at the pause, may hold a prompt not given yet
    (dolist (s (drgnx-agents-sessions))
      (when (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited)))
        (drgnx-job--session-changed s)))
    (drgnx-job-step id)
    id))

(defconst drgnx-job--provider-limit "\\(?:^\\|[^0-9]\\)429\\(?:[^0-9]\\|$\\)\\|rate.?limit\\|overloaded\\|quota\\|too many requests"
  "What a provider at its limit says (case ignored).")

(defun drgnx-job--error-data-text (data)
  "The text of a JSON-RPC error's DATA, where an agent may put the provider's own error: DATA itself when it is a
string; of an object, its message, details and reason."
  (cond ((stringp data) data)
        ((and (consp data) (keywordp (car data)))
         (mapconcat (lambda (k) (let ((v (plist-get data k))) (if v (format "%s" v) ""))) '(:message :details :reason) "\n"))
        (t "")))

(defun drgnx-job--provider-limit-p (s err)
  "Does ERR (a turn's error) of S — its message or data, or S's stderr, when the agent died of it — say its provider
is at its limit?"
  (or (eql (plist-get err :code) 429)
      (let ((case-fold-search t))
        (string-match-p drgnx-job--provider-limit
                        (concat (format "%s" (plist-get err :message)) "\n"
                                (drgnx-job--error-data-text (plist-get err :data)) "\n"
                                (and (eq (drgnx-agent-session-status s) 'exited) (or (drgnx-agent-session-stderr s) "")))))))

(defun drgnx-job--agent-error (s err)
  "`drgnx-agents-error-functions': the task of a job agent whose provider is at its limit goes to the next profile;
a task's reviewer starts again on the next profile of the review route (a clash reviewer is left alone)."
  (let ((reviewer (gethash (drgnx-agent-session-id s) drgnx-job--reviewers)))
    (when (and (drgnx-agent-session-job s) (not (consp reviewer)) (drgnx-job--provider-limit-p s err))
      (puthash (drgnx-agent-session-id s) (drgnx-job--turns s) drgnx-job--turns-seen)   ; no nudge for this turn
      (when reviewer (remhash (drgnx-agent-session-id s) drgnx-job--reviewing))   ; its turn's end is no verdict
      (let ((job (drgnx-agent-session-job s)))
        (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S"
                                        (if reviewer (drgnx-job--review-fall-back job s reviewer err) (drgnx-job--fall-back job s err)))))))))

(defun drgnx-job--review-fall-back (id s task-id err)
  "Reviewer S of TASK-ID (job ID) is at its provider's limit (ERR): the review starts again on the next profile of the
review route; with none left, a card."
  (let* ((from (drgnx-agent-session-profile s)) (live (drgnx-job--reviewer-of task-id))
         (to (cadr (member from (drgnx-job-route 'review)))))
    (when (and (equal (plist-get (drgnx-coord-job id) :status) "running") (equal (plist-get (drgnx-coord-task task-id) :status) "in-review")
               (or (null live) (eq live s)))
      (remhash (drgnx-agent-session-id s) drgnx-job--reviewing)
      (unless (eq (drgnx-agent-session-status s) 'exited) (drgnx-agents-kill s))
      (if to
          (drgnx-job--start-review-agent id (drgnx-coord-task task-id) to)
        (drgnx-job--card id task-id "review" (format "the reviewer (%s) failed (%s); no other review profile on the route"
                                                     from (plist-get err :message)))))))

(defun drgnx-job--handover (id s)
  "What agent S of job ID leaves its successor: its last commit and its last words."
  (let* ((commit (pcase (drgnx-job--git (drgnx-agent-session-cwd s) "log" "-1" "--format=%h %s" (format "job/%s..HEAD" id))
                   (`(0 . ,out) out)
                   (_ "")))                                  ; git failed: no commit to name, never its error
         (said (mapconcat (lambda (e) (or (drgnx-agents-entry-text e) ""))
                          (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)) ""))
         (said (substring said (max 0 (- (length said) 2000)))))
    (format "You are continuing this task: an agent began it here and stopped (its provider failed).  Its last commit: %s.  The decision log was at version %d then.%s\n\n"
            (if (string-empty-p commit) "none" commit) (drgnx-coord-version)
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
  (let ((words '("curl" "wget" "ssh" "scp" "sftp" "rsync" "nc" "ncat" "telnet" "ftp" "gh" "npx" "bunx" "dnf" "yum" "apt"
                 "apt-get" "brew" "pacman" "docker" "npm +\\(?:install\\|i\\|ci\\|add\\|exec\\)" "pnpm +\\(?:install\\|i\\|add\\|dlx\\)"
                 "yarn +\\(?:install\\|add\\|dlx\\)" "bun +\\(?:install\\|i\\|add\\|x\\)" "pip3? +install" "pipx +\\(?:install\\|run\\)"
                 "uv +\\(?:pip +install\\|add\\|tool\\)" "cargo +\\(?:install\\|add\\)" "go +\\(?:get\\|install\\)" "gem +install"
                 "podman +\\(?:pull\\|push\\|run\\)"
                 ;; git and its global options (-C DIR, -c K=V) before the command
                 "git\\(?: +-[^[:space:]]+\\(?: +[^-[:space:]][^[:space:]]*\\)?\\)* +\\(?:push\\|fetch\\|pull\\|clone\\|ls-remote\\|submodule\\)")))
    (concat "\\(?:^\\|[[:space:];&|(`'\"/=]\\)\\(?:"
            (mapconcat (lambda (w) (replace-regexp-in-string " \\+" "[[:space:]]+" w t t)) words "\\|")
            "\\)\\(?:[[:space:];&|)`'\"]\\|$\\)"))
  "Commands that reach the network or install something, wherever they are in a command line (a path before them,
a shell around them): a job agent asks the user for them.  Best effort, not a sandbox: an interpreter (`python -c')
reaches the network unseen.")

(defconst drgnx-job--read-only-git
  "\\`git[[:space:]]+\\(?:diff\\|log\\|show\\|status\\)\\(?:[[:space:]]+[^;&|`$<>()\\\n]*\\)?\\'"
  "A git command a reviewer runs without asking: it reads, nothing else on the line.")

(defun drgnx-job--command (tool)
  "The command line of the ACP TOOL call: its raw input's when it has one, else its title."
  (let ((raw (plist-get (plist-get tool :rawInput) :command)))
    (if (stringp raw) raw (or (plist-get tool :title) ""))))

(defvar drgnx-job-policies
  '((review :allow (read search think))
    (t :allow (read edit delete move search think execute other)))
  "Per role: the tool kinds allowed without asking (paths inside the worktree, no outward command).  `t': any other
role.  Everything else — network (fetch), outward commands, paths outside the worktree, tools of MCP servers other
than drgnx's own — goes to the user.")

(defconst drgnx-job--own-mcp-servers drgnx-agents-own-mcp-servers
  "drgnx's own MCP servers, the ones drgnx gives an agent's session: the coordination tools (drgnx-coord-mcp.el) and
the search tool (drgnx-search-mcp.el).")

(defconst drgnx-job--own-mcp-tool
  (concat "\\`mcp__\\(" (regexp-opt drgnx-job--own-mcp-servers) "\\)__[a-z]+\\(?:_[a-z]+\\)*\\'")
  "The name of a tool of one of drgnx's own MCP servers (group 1: the server): no `__' after the server's name, so a
server whose name only starts with drgnx's (`drgnx__x') is not taken for it.")

(defconst drgnx-job--resource-tools '("ReadMcpResourceTool" "ListMcpResourcesTool")
  "Claude Code's tools that read an MCP server's resources: the server is their input's `server' (none: every server).")

(defun drgnx-job--other-server-resources-p (tool)
  "Does the ACP TOOL call read the resources of an MCP server other than drgnx's own: one of
`drgnx-job--resource-tools' by its name in `_meta.claudeCode.toolName' or its title, whose input's `server' is not
one of `drgnx-job--own-mcp-servers' (or is missing)?"
  (and (seq-some (lambda (n) (member n drgnx-job--resource-tools))
                 (list (plist-get tool :title) (plist-get (plist-get (plist-get tool :_meta) :claudeCode) :toolName)))
       (not (member (plist-get (plist-get tool :rawInput) :server) drgnx-job--own-mcp-servers))))

(defconst drgnx-job--unnamed-tool-titles '("" "Use tool?" "Unknown Tool")
  "Titles claude-agent-acp gives a tool call whose name it cannot show: what the tool is is unknown.")

(defun drgnx-job--mcp-tool (tool)
  "Whose MCP tool the ACP TOOL call is: nil when it is none (no name `mcp__…' in `_meta.claudeCode.toolName' or the
title, no `_meta.claudeCode.mcpServer'); `drgnx' when it is a tool of one of drgnx's own servers — every name it has
is one of the same server, and the server, when named, is that one as drgnx gave it to the session (source `dynamic';
a server of the user's configuration says `user', `project', `local', `plugin'…; the adapter drgnx installs names
none, only the tool); `user' otherwise, for the user's servers and anything that cannot be told apart from one."
  (let* ((cc (plist-get (plist-get tool :_meta) :claudeCode))
         (server (plist-get cc :mcpServer))
         (names (seq-filter #'stringp (list (plist-get cc :toolName) (plist-get tool :title))))
         (case-fold-search nil)
         (owners (mapcar (lambda (n) (and (string-match drgnx-job--own-mcp-tool n) (match-string 1 n))) names)))
    (cond ((and (null server) (not (seq-some (lambda (n) (string-prefix-p "mcp__" n)) names))) nil)
          ((and (car owners) (seq-every-p (lambda (o) (equal o (car owners))) owners)
                (or (null server) (and (equal (plist-get server :name) (car owners)) (equal (plist-get server :source) "dynamic"))))
           'drgnx)
          (t 'user))))

(defun drgnx-job--agent-config-p (path tree)
  "Does PATH, inside TREE, configure the agents that work in TREE — a `.claude' directory or anything in it, at any
depth (settings: a permission mode, allow rules, hooks; skills), or a `.mcp.json' anywhere in TREE?  Once `//', `..'
and symlinks are resolved, with no file name handler; case ignored, for a file system that ignores it.  A PATH that
cannot be placed inside TREE counts as one (fail closed)."
  (let* ((file-name-handler-alist nil)                ; the agent's name: resolved with no handler (`drgnx-file-truename')
         (true (drgnx-file-truename (replace-regexp-in-string "\\`//+" "/" (expand-file-name path tree))))
         (top (drgnx-file-truename tree))
         (rel (and true top (file-relative-name true top)))
         (case-fold-search t))
    (or (null rel) (file-name-absolute-p rel) (string-match-p "\\`\\.\\.\\(?:/\\|\\'\\)" rel)
        (string-match-p "\\(?:\\`\\|/\\)\\.claude\\(?:/\\|\\'\\)\\|\\(?:\\`\\|/\\)\\.mcp\\.json\\'" rel))))

(defun drgnx-job--names-agent-config-p (line tree)
  "Does command LINE name the agents' configuration: a `.mcp.json', or a `.claude' (`.claude/', `.claude.json'…) that
is not just part of the path of TREE itself (the worktree, `…/.claude/worktrees/NAME', with no `..' and no other
`.claude' after it)?  Case ignored.  Best effort, like `drgnx-job--outward-commands': a shell can build a name unseen."
  (let ((case-fold-search t) (start 0) (found nil)
        (own (delete-dups (list (directory-file-name (expand-file-name tree)) (directory-file-name (file-truename tree))))))
    (if (string-match-p "\\.mcp\\.json" line) t
      (while (and (not found) (string-match "\\.claude\\(?:[^[:alnum:]_-]\\|\\'\\)" line start))
        (let ((b (match-beginning 0)))
          (setq start (1+ b))
          (unless (seq-some
                   (lambda (o)                      ; B is in an occurrence of TREE's path that ends there
                     (let ((p (string-search o line (max 0 (- b (length o))))))
                       (and p (<= p b) (< b (+ p (length o)))
                            ;; the path goes on (group 1) to where the word ends
                            (eq (string-match (concat (regexp-quote o) "\\(/[^[:space:];&|()<>`'\"]*\\)?"
                                                      "\\(?:[[:space:];&|()<>`'\"]\\|\\'\\)")
                                              line p)
                                p)
                            (let ((rest (or (match-string 1 line) "")))
                              (not (or (string-search ".." rest) (string-match-p "\\.claude" rest)))))))
                   own)
            (setq found t))))
      found)))

(defun drgnx-job--inside-p (path tree)
  "Is PATH inside TREE, once `..' and symlinks are resolved?  With no file name handler (`drgnx-file-inside-p'): a
remote name, or a link to one, is outside — never Tramp, a connection (a prompt) from the hub."
  (drgnx-file-inside-p path tree))

(defun drgnx-job-policy (role tool tree)
  "`allow' or `ask': the policy of ROLE (a string) for the ACP TOOL call (its :kind, :title, :locations, :_meta) of an
agent working in TREE.  A tool of an MCP server other than drgnx's own asks, whatever its kind: the user's servers can
reach anything (mail, a database).  So does reading another server's resources
\(`drgnx-job--other-server-resources-p'), an `other' call whose tool cannot be named, a kind that is not a string,
and a change to the agents' own configuration in TREE (`.claude/', `.mcp.json'): a permission mode set there would
hold for every agent that works in TREE after it."
  (let* ((kind (let ((k (plist-get tool :kind))) (cond ((null k) 'other) ((stringp k) (intern k)))))
         (allowed (plist-get (cdr (or (assq (intern (or role "implement")) drgnx-job-policies) (assq t drgnx-job-policies))) :allow))
         (paths (delq nil (mapcar (lambda (l) (plist-get l :path)) (append (plist-get tool :locations) nil))))
         (case-fold-search nil))
    (cond
     ((null kind) 'ask)
     ((not (seq-every-p (lambda (p) (drgnx-job--inside-p p tree)) paths)) 'ask)
     ((and (not (memq kind '(read search))) (seq-some (lambda (p) (drgnx-job--agent-config-p p tree)) paths)) 'ask)
     ;; a file Emacs keeps encrypted or compressed (`.gpg', `.gz'): the agent's plain text would land in it as it is
     ((and (not (memq kind '(read search))) (seq-some (lambda (p) (drgnx-file-sealed-p p tree)) paths)) 'ask)
     ((eq (drgnx-job--mcp-tool tool) 'user) 'ask)
     ((drgnx-job--other-server-resources-p tool) 'ask)
     ((and (eq kind 'other)
           (not (seq-some (lambda (n) (and (stringp n) (not (member n drgnx-job--unnamed-tool-titles))))
                          (list (plist-get tool :title) (plist-get (plist-get (plist-get tool :_meta) :claudeCode) :toolName)))))
      'ask)
     ((and (eq kind 'execute)
           (let ((line (concat (or (plist-get tool :title) "") "\n" (drgnx-job--command tool))))
             (or (string-match-p drgnx-job--outward-commands line) (drgnx-job--names-agent-config-p line tree))))
      'ask)
     ((memq kind allowed) 'allow)
     ;; a reviewer reads the diff
     ((and (eq kind 'execute) (equal role "review") (string-match-p drgnx-job--read-only-git (drgnx-job--command tool))
           (not (string-match-p "--output\\|--ext-diff" (drgnx-job--command tool))))
      'allow)
     (t 'ask))))

(defun drgnx-job--role (s)
  (if (gethash (drgnx-agent-session-id s) drgnx-job--reviewers) "review"
    (plist-get (drgnx-coord-task (drgnx-agent-session-task s)) :role)))

(defconst drgnx-job--advisory-kinds '("proposal" "overlap" "clash")
  "Card kinds that leave their task's status alone (the job decides when it waits).")

(defun drgnx-job--broadcast (event data) (when (fboundp 'drgnx-hub--broadcast) (drgnx-hub--broadcast event data)))

(defvar drgnx-job--signatures (make-hash-table :test #'equal) "Job → what its last `job' event showed.")

(defun drgnx-job--changed (id)
  "Tell the hub's subscribers (a `job' event) when job ID's status, its tasks (what is blocked, the run order, the
profiles they were reassigned to too) or its open cards changed."
  (let* ((job (drgnx-coord-job id))
         (sig (list (plist-get job :status)
                    (mapcar (lambda (k) (plist-get (plist-get job :data) k)) '(:blocked :order :profiles))
                    (mapcar (lambda (task) (list (plist-get task :status) (plist-get task :agent) (gethash (plist-get task :id) drgnx-job--busy)))
                            (drgnx-coord-tasks id))
                    (mapcar (lambda (c) (list (plist-get c :id) (plist-get c :title) (plist-get c :data))) (drgnx-coord-cards id "open")))))
    (unless (equal sig (gethash id drgnx-job--signatures))
      (puthash id sig drgnx-job--signatures)
      (drgnx-job--broadcast 'job (list :id id)))))

(defun drgnx-job--card (job task kind title &optional s data)
  "Something of JOB's TASK needs the user: a card (one open per task and kind: a second updates it) with DATA; the
task waits (needs-input, unless KIND is advisory), the user gets a message and the hub's subscribers a `card' event.
S: the session whose request waits (it goes back to work once answered, or, gone, the task is released).  The card's id."
  (setq title (replace-regexp-in-string "[\n\r]+" " " (format "%s" title)))   ; one line: no forged card lines
  (when task
    (when s
      (drgnx-job--set-waiting job task (list :sid (drgnx-agent-session-id s)
                                             ;; a reviewer's request, or an agent's that finished (its turn goes on): back to review
                                             :back (if (or (gethash (drgnx-agent-session-id s) drgnx-job--reviewers)
                                                           (equal (plist-get (drgnx-coord-task task) :status) "in-review"))
                                                       "in-review" "ready"))))
    (unless (member kind drgnx-job--advisory-kinds)
      (drgnx-job--set-count job :in-review-since task nil)          ; back in review later, the wait for the turn starts again
      (drgnx-coord-force-status task "needs-input" (plist-get (drgnx-coord-task task) :agent))))
  (let* ((data (append (and s (list :sid (drgnx-agent-session-id s))) data))
         (old (seq-find (lambda (c) (and (equal (plist-get c :task) task) (equal (plist-get c :kind) kind)
                                         (equal (plist-get (plist-get c :data) :key) (plist-get data :key))))   ; clashes: one per key
                        (drgnx-coord-cards job "open")))
         (cid (if old
                  (progn (drgnx-coord-card-set (plist-get old :id) :title title :data (append data (plist-get old :data)))
                         (plist-get old :id))
                (let ((m (drgnx-coord-send :job job :sender "drgnx" :recipient "user" :text (format "[%s] %s: %s" kind (or task job) title))))
                  (drgnx-coord-card-create :job job :task task :kind kind :title title :data (append data (list :message (plist-get m :id))))))))
    (drgnx-job--broadcast 'card (list :id cid :job job :task task :kind kind :title title))
    (drgnx-job--changed job)
    cid))

(defvar drgnx-job-clash-answer-functions nil
  "Called with (JOB REVIEWER SESSION) when a clash reviewer's turn ends (REVIEWER: (:clash CARD)): drgnx-job-clash.el.")

(defvar drgnx-job-card-action-functions nil
  "Called with (CARD ACTION ARG) for actions drgnx-job.el does not know (a clash's): the first non-nil did it.")

(defconst drgnx-job--showing-actions '("open" "discuss" "edits")
  "Actions that leave their card open (Open, Open its edits: the editor shows something).")

(defun drgnx-job-card-actions (card)
  "CARD's actions: ((ACTION LABEL)…)."
  (pcase (plist-get card :kind)
    ("proposal" '(("approve" "Approve") ("reject" "Reject")))
    ("permission" '(("allow" "Allow") ("reject" "Reject")))
    ("write" '(("reject" "Reject")))
    ("merge-conflict" '(("retry" "Let the agent resolve it") ("merge" "Merge again (I resolved it)") ("drop" "Drop the task")
                        ("open" "Open the job's worktree")))
    ("merge-failed" '(("merge" "Merge again") ("drop" "Drop the task") ("open" "Open the job's worktree")))   ; no conflict
    ("review" (append (and (plist-get (plist-get card :data) :gate) '(("edits" "Open its edits")))   ; the merge gate's
                      '(("accept" "Merge as it is") ("retry" "Back to an agent") ("drop" "Drop the task"))))
    ((or "fallback" "agent" "stalled") (append (and (plist-get (plist-get card :data) :review) '(("review" "Review now")))   ; a finished task
                                               '(("retry" "Retry") ("drop" "Drop the task"))))
    ("budget" '(("resume" "Resume with a budget…") ("stop" "Stop the job")))
    ("clash" (append (and (plist-get (plist-get (plist-get card :data) :recommendation) :side) '(("accept" "Accept the reviewer")))   ; a side to accept
                     '(("pick-a" "Pick A") ("pick-b" "Pick B") ("discuss" "Discuss with the reviewer…"))))
    (_ '(("dismiss" "Dismiss")))))

(defun drgnx-job--retry (job task &optional note)
  "TASK of JOB goes back to a new agent, its counts reset (NOTE: what it is told)."
  (let ((data (plist-get (drgnx-coord-job job) :data)))
    (setf (alist-get task (plist-get data :fails) nil 'remove #'equal) nil)
    (setf (alist-get task (plist-get data :exits) nil 'remove #'equal) nil)
    (setf (alist-get task (plist-get data :nudged) nil 'remove #'equal) nil)
    (setf (alist-get task (plist-get data :in-review-since) nil 'remove #'equal) nil)
    (when note (setf (alist-get task (plist-get data :notes) nil nil #'equal) note))
    (drgnx-coord-job-set job :data data))
  (when-let* ((s (drgnx-job--session (plist-get (drgnx-coord-task task) :agent))))   ; a new agent: the old one ends
    (unless (eq (drgnx-agent-session-status s) 'exited) (drgnx-agents-kill s)))
  (drgnx-job--set-waiting job task nil)
  (drgnx-coord-force-status task "ready" nil))

;;;; Writing back from the Work graph: reassign, block, the run order (the user's, through the hub)

(defun drgnx-job--open-task (tid)
  "Task TID (a store plist) when it is not done or dropped, else a `user-error'."
  (let ((task (or (drgnx-coord-task tid) (user-error "No task %s" tid))))
    (when (member (plist-get task :status) '("done" "dropped")) (user-error "Task %s is %s already" tid (plist-get task :status)))
    task))

(defun drgnx-job--job-of (task)
  "The job of TASK (a store plist)."
  (drgnx-coord--task-job (drgnx-work-db-read) (plist-get task :id)))

(defun drgnx-job--set-data (job key task value)
  "Job JOB's data KEY (an alist by task id) says VALUE of TASK (its id; nil: nothing); its subscribers hear of it."
  (let ((data (plist-get (drgnx-coord-job job) :data)))
    (setf (alist-get task (plist-get data key) nil 'remove #'equal) value)
    (drgnx-coord-job-set job :data data)
    (drgnx-job--changed job)))

(defun drgnx-job-reassign (tid profile)
  "Task TID goes to an agent of PROFILE: from now on its agents are of PROFILE.  One working on it now (or a card it
waits on) ends: the task is ready for a new agent, as a card's Retry does.  A task in review is refused: its reviewer
would answer about the next agent's work.  The job's summary."
  (let* ((task (drgnx-job--open-task tid)) (job (drgnx-job--job-of task)))
    (drgnx-agents-profile profile)                        ; a profile the hub does not know: an error now, not at start
    (when (gethash tid drgnx-job--busy) (user-error "Task %s is %s: try again in a moment" tid (gethash tid drgnx-job--busy)))
    (when (equal (plist-get task :status) "in-review")
      (user-error "Task %s is in review: reassign it once its review is over (from its card, or here)" tid))
    (drgnx-job--set-data job :profiles tid profile)
    (unless (member (plist-get task :status) '("pending" "ready"))   ; it had an agent: a new one
      (dolist (c (drgnx-coord-cards job "open"))
        (when (and (equal (plist-get c :task) tid) (not (member (plist-get c :kind) drgnx-job--advisory-kinds))
                   (drgnx-coord-card-settle (plist-get c :id) "reassign"))
          (when-let* ((m (plist-get (plist-get c :data) :message))) (drgnx-coord-mark m "acted"))))
      (drgnx-job--retry job tid)
      (drgnx-job--step-later job))
    (drgnx-job--changed job)
    (drgnx-job-summary job)))

(defconst drgnx-job-block-reason-max 500 "The most characters of a blocked task's reason that are kept.")

(defun drgnx-job-block (tid reason)
  "Mark task TID blocked for REASON (a text): no agent starts on it (one working on it goes on) until it is unblocked.
The reason is kept as one line of at most `drgnx-job-block-reason-max' characters, control and bidi-control characters
replaced by spaces.  The job's summary."
  (let ((job (drgnx-job--job-of (drgnx-job--open-task tid)))
        (why (and (stringp reason)
                  (replace-regexp-in-string "[[:cntrl:]\u0080-\u009f؜‎‏ -‮⁦-⁩]" " " reason t t))))
    (drgnx-job--set-data job :blocked tid (if (and why (not (string-blank-p why)))
                                              (substring why 0 (min (length why) drgnx-job-block-reason-max))
                                            "blocked"))
    (drgnx-job-summary job)))

(defun drgnx-job-unblock (tid)
  "Task TID is no longer blocked: its job may start it.  The job's summary."
  (let ((job (drgnx-job--job-of (or (drgnx-coord-task tid) (user-error "No task %s" tid)))))
    (drgnx-job--set-data job :blocked tid nil)
    (drgnx-job--step-later job)
    (drgnx-job-summary job)))

(defun drgnx-job-order (tid delta)
  "Move task TID DELTA places in its job's run order (negative: earlier), among the tasks not done or dropped: the
order ready tasks get agents in (`drgnx-job--ordered').  The job's summary."
  (let* ((job (drgnx-job--job-of (drgnx-job--open-task tid)))
         (all (mapcar (lambda (task) (plist-get task :id)) (drgnx-job--ordered job (drgnx-coord-tasks job))))
         (open (mapcar (lambda (task) (plist-get task :id))
                       (seq-remove (lambda (task) (member (plist-get task :status) '("done" "dropped")))
                                   (drgnx-job--ordered job (drgnx-coord-tasks job)))))
         (to (max 0 (min (1- (length open)) (+ (cl-position tid open :test #'equal) (if (integerp delta) delta 0)))))
         (moved (let ((rest (remove tid open))) (append (seq-take rest to) (list tid) (seq-drop rest to))))
         (data (plist-get (drgnx-coord-job job) :data)))
    ;; the open tasks take their new order in the places open tasks had; finished ones keep theirs
    (setq data (plist-put data :order (mapcar (lambda (id) (if (member id open) (pop moved) id)) all)))
    (drgnx-coord-job-set job :data data)
    (drgnx-job--changed job)
    (drgnx-job-summary job)))

(defun drgnx-job--answer-request (card allow)
  "Answer the pending request CARD is about: ALLOW (its allow_once option) or reject."
  (let* ((data (plist-get card :data)) (s (or (drgnx-agents-get (plist-get data :sid)) (user-error "The agent is gone")))
         (req (plist-get data :request)))
    (if-let* ((p (seq-find (lambda (p) (equal (plist-get p :id) req)) (drgnx-agent-session-permissions s))))
        (let ((option (plist-get (seq-find (lambda (o) (equal (plist-get o :kind) (if allow "allow_once" "reject_once")))
                                           (append (plist-get p :options) nil))
                                 :optionId)))
          ;; the user's answer, through the card: the hub's `answer' event says so
          (when (fboundp 'drgnx-hub-note-permission-answer) (drgnx-hub-note-permission-answer s req option "user"))
          (drgnx-agents-answer-permission s p option))
      (if-let* ((r (seq-find (lambda (r) (equal (plist-get r :id) req)) (drgnx-agent-session-reviews s))))
          (drgnx-agents-finish-review s r t)
        (user-error "The request was answered already")))
    (drgnx-job--answered s)))

(defun drgnx-job-card-act (cid action &optional arg)
  "The user's ACTION (with ARG) on card CID: done once — a card acted on before signals.  The job's summary."
  (let* ((card (or (drgnx-coord-card cid) (user-error "No card %s" cid)))
         (job (plist-get card :job)) (task (plist-get card :task)))
    (unless (assoc action (drgnx-job-card-actions card)) (user-error "Card %s has no action %s" cid action))
    (unless (equal (plist-get card :state) "open") (user-error "Card %s is already settled" cid))
    (when (and task (member action '("retry" "drop" "merge" "accept"))
               (member (plist-get (drgnx-coord-task task) :status) '("done" "dropped")))
      (user-error "Task %s is %s already" task (plist-get (drgnx-coord-task task) :status)))
    (when (member action drgnx-job--showing-actions)               ; these show or ask: the card stays
      (run-hook-with-args-until-success 'drgnx-job-card-action-functions card action arg))
    (unless (member action drgnx-job--showing-actions)
      (unless (drgnx-coord-card-settle cid action) (user-error "Card %s is already settled" cid))
      (condition-case err
          (pcase (if (equal (plist-get card :kind) "clash") 'clash action)   ; a clash's actions are drgnx-job-clash.el's
            ('clash (unless (run-hook-with-args-until-success 'drgnx-job-card-action-functions card action arg)
                      (user-error "Nothing does %s" action)))
            ("approve" (drgnx-job-approve job :budget arg))
            ("reject" (if (member (plist-get card :kind) '("permission" "write")) (drgnx-job--answer-request card nil)
                        (drgnx-job-stop job)))                     ; the proposal
            ("allow" (drgnx-job--answer-request card t))
            ("retry" (drgnx-job--retry job task (and (equal (plist-get card :kind) "merge-conflict")
                                                     (format "Merging your branch into job/%s conflicted (%s). Merge job/%s into your branch, resolve the conflicts, commit, then call complete_task."
                                                             job (plist-get card :title) job))))
            ((or "merge" "accept") (drgnx-job--merge job (drgnx-coord-task task)))
            ("review" (when-let* ((s (drgnx-job--session (plist-get (drgnx-coord-task task) :agent))))   ; as if its turn had ended
                        (unless (eq (drgnx-agent-session-status s) 'exited) (drgnx-agents-kill s)))
             (drgnx-coord-force-status task "in-review" (plist-get (drgnx-coord-task task) :agent)))
            ("drop" (when-let* ((s (drgnx-job--session (plist-get (drgnx-coord-task task) :agent)))) (drgnx-agents-kill s))
             (drgnx-coord-force-status task "dropped" nil))
            ("resume" (drgnx-job-resume job :budget (and arg (if (numberp arg) arg (string-to-number (format "%s" arg))))))
            ("stop" (drgnx-job-stop job)))
        (error (drgnx-coord-card-set cid :state "open")            ; it did not happen: still the user's
               (signal (car err) (cdr err))))
      (when-let* ((m (plist-get (plist-get card :data) :message))) (drgnx-coord-mark m "acted"))
      (drgnx-job--step-later job))
    (drgnx-job--changed job)
    (drgnx-job-summary job)))

(defun drgnx-job--settle-kind (job kind choice)
  "JOB's open cards of KIND are settled with CHOICE (their question is answered elsewhere)."
  (dolist (c (drgnx-coord-cards job "open"))
    (when (and (equal (plist-get c :kind) kind) (drgnx-coord-card-settle (plist-get c :id) choice))
      (when-let* ((m (plist-get (plist-get c :data) :message))) (drgnx-coord-mark m "acted")))))

(defun drgnx-job--settle-requests (job s)
  "Session S's permission and write cards are answered (in the transcript): settled."
  (dolist (c (drgnx-coord-cards job "open"))
    (when (and (equal (plist-get (plist-get c :data) :sid) (drgnx-agent-session-id s)) (member (plist-get c :kind) '("permission" "write"))
               (drgnx-coord-card-settle (plist-get c :id) "answered"))
      (when-let* ((m (plist-get (plist-get c :data) :message))) (drgnx-coord-mark m "acted"))))
  (drgnx-job--changed job))

(defun drgnx-job-reply (mid text)
  "The user answers message MID (from an agent) with TEXT; MID is acted on."
  (let ((m (or (drgnx-coord-message mid) (user-error "No message %s" mid))))
    (drgnx-coord-send :job (plist-get m :job) :recipient (plist-get m :sender) :text text :seen (drgnx-coord-version)
                      :answers mid)
    (drgnx-coord-mark mid "acted")
    (drgnx-job--changed (plist-get m :job))
    t))

(defun drgnx-job-dismiss (mid)
  "The user dismisses message MID — a message that needs no answer: it is acted on, nothing is sent back.  Only a
job's own message to the user can be dismissed: an agent's message to another agent must still be delivered."
  (let ((m (or (drgnx-coord-message mid) (user-error "No message %s" mid))))
    (unless (and (equal (plist-get m :recipient) "user") (plist-get m :job))
      (user-error "Not a message of a job to the user"))
    (drgnx-coord-mark mid "acted")
    (drgnx-job--changed (plist-get m :job))
    t))

(defvar drgnx-job--gated (make-hash-table :test #'equal) "Session id → the log version it was last told of at the gate.")

(defun drgnx-job-enforced-p (s)
  "Does the gate hold S — a job's agent (not a reviewer) that can be steered — while it is behind the log?"
  (and (drgnx-agent-session-job s) (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))
       (drgnx-agents--steerable-p s) t))

(defun drgnx-job--gate (s job params)
  "The gate: job agent S asks a permission (PARAMS) while behind JOB's decision log — the call is refused (its
reject_once option) and, once per version, the changes are put into its turn.  Edits and commands only: reading —
`read_decisions' too, which an agent asks for as an `other' tool — is never held.  nil when S is not behind (or a
reviewer, or the request has no reject option)."
  (let* ((sid (drgnx-agent-session-id s)) (seen (drgnx-coord-seen sid))
         (changes (and (not (gethash sid drgnx-job--reviewers))
                       (member (plist-get (plist-get params :toolCall) :kind) '("edit" "delete" "move" "execute"))
                       (drgnx-coord-decisions-since seen job)))
         (reject (seq-find (lambda (o) (equal (plist-get o :kind) "reject_once")) (append (plist-get params :options) nil))))
    (when (and changes reject)
      (let ((v (drgnx-coord-version)))
        (unless (eql (gethash sid drgnx-job--gated) v)
          (puthash sid v drgnx-job--gated)
          (drgnx-agents-steer s (concat (drgnx-coord-notice v job changes seen)
                                        "\nYour last tool call was refused because you had not read these."))))
      (list :result (list :outcome (list :outcome "selected" :optionId (plist-get reject :optionId)))))))

(defun drgnx-job--write-inside (path content tree)
  "Write CONTENT (UTF-8) to PATH in the worktree TREE without the race of a check, then a write.  PATH is resolved
here — every link, the last one too — and refused (an error) when that is outside TREE: a link swapped in after the
policy's check — and when the file exists but is not writable (the rename would replace it anyway).  CONTENT goes
into a temp file made in that directory, renamed over the file: it keeps its modes, a new file gets 0666 less the
umask (as `write-region' gives), and a reader never sees half of it.  Checked again after the rename: a directory
swapped meanwhile is an error (Emacs has no openat, so that window stays open).  No file name handlers."
  (let* ((file-name-handler-alist nil)
         (target (file-truename (expand-file-name path tree))))
    (unless (file-in-directory-p target (file-truename tree))
      (error "%s leads out of the worktree (%s)" path target))
    (when (and (file-exists-p target) (not (file-writable-p target)))
      (error "%s is not writable" path))
    (let* ((modes (or (file-modes target) (logand #o666 (default-file-modes))))
           (tmp (let ((coding-system-for-write 'utf-8-unix))
                  (make-temp-file (expand-file-name ".drgnx-write-" (file-name-directory target)) nil nil content))))
      (condition-case err
          (progn (set-file-modes tmp modes)
                 (rename-file tmp target t))
        (error (ignore-errors (delete-file tmp)) (signal (car err) (cdr err)))))
    (unless (equal (file-truename target) target)
      (error "%s: a directory on its way changed while it was written (now %s)" path (file-truename target)))))

(defun drgnx-job--request (s method params id)
  "A job agent's request (`drgnx-agents-request-functions'): routine ones answered by its role's policy, writes in
its worktree done at once; anything else waits for the user as a card (nil: the session keeps it pending)."
  (when-let* ((job (drgnx-agent-session-job s)))
    (let ((tree (drgnx-agent-session-cwd s)) (task (drgnx-agent-session-task s)))
      (pcase method
        ("session/request_permission"
         (let ((tool (plist-get params :toolCall))
               (opt (seq-find (lambda (o) (equal (plist-get o :kind) "allow_once")) (append (plist-get params :options) nil))))
           (cond
            ((drgnx-job--gate s job params))                        ; behind the decision log: refused, told
            ((and opt (eq (drgnx-job-policy (drgnx-job--role s) tool tree) 'allow))   ; no allow_once option: the user
             (list :result (list :outcome (list :outcome "selected" :optionId (plist-get opt :optionId)))))
            (t (drgnx-job--card job task "permission" (or (plist-get tool :title) "a permission") s (list :request id))
               nil))))
        ("fs/write_text_file"
         ;; an absolute path only: the check and the write must mean the same file; the agent's name, used with no
         ;; file name handler (`drgnx-file-truename')
         (let ((path (plist-get params :path)) (content (plist-get params :content)) (file-name-handler-alist nil))
           (cond
            ((drgnx-file-sealed-p path tree)   ; never written: plain text into a `.gpg' or `.gz' file (`drgnx-file-sealed-p')
             (list :error (list :code -32002 :message (format "%s is a file Emacs keeps encrypted or compressed: an agent never writes it; ask the user to" path))))
            ((and (stringp content) (drgnx-agents--path-ok-p path) (drgnx-job--inside-p path tree)
                  (not (drgnx-job--agent-config-p path tree)) (not (equal (drgnx-job--role s) "review")))
             (make-directory (file-name-directory path) t)
             (drgnx-job--write-inside path content tree)
             (drgnx-coord-event-add-best-effort :agent (drgnx-agent-session-id s) :job job :task task :kind "edit"
                                                :summary (format "wrote %s" (file-name-nondirectory path))
                                                :data (list :root tree :paths (list path)))
             (list :result nil))
            (t (drgnx-job--card job task "write" (format "write %s" path) s (list :request id))
               nil))))))))

(defun drgnx-job--answered (s)
  "The user answered S's request: its task goes on (when nothing else waits) — a reviewer's, or a finished agent's,
back in review, with the work of the agent that did it."
  (let ((task (drgnx-coord-task (drgnx-agent-session-task s))))
    (when (and (drgnx-agent-session-job s) (null (drgnx-agent-session-permissions s)) (null (drgnx-agent-session-reviews s)))
      (drgnx-job--settle-requests (drgnx-agent-session-job s) s))
    (when (and (drgnx-agent-session-job s) (null (drgnx-agent-session-permissions s)) (null (drgnx-agent-session-reviews s))
               (equal (plist-get task :status) "needs-input"))
      (let ((back (plist-get (drgnx-job--waiting (drgnx-agent-session-job s) (plist-get task :id)) :back)))
        (drgnx-job--set-waiting (drgnx-agent-session-job s) (plist-get task :id) nil)
        (if (or (equal back "in-review") (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))
            (drgnx-coord-force-status (plist-get task :id) "in-review" (plist-get task :agent))
          (drgnx-coord-force-status (plist-get task :id) "running" (drgnx-agent-session-id s)))))))

;;;; Stopping, what a job looks like, `drgnx job'

(defun drgnx-job-stop (id)
  "Stop job ID: its agents end (their worktrees stay); `drgnx-job-resume' starts its open tasks again."
  (unless (drgnx-coord-job id) (user-error "No job %s" id))
  (drgnx-job--settle-kind id "proposal" "reject")
  (drgnx-coord-job-set id :status "stopped")
  (drgnx-job--gate-forget id)
  (drgnx-job--changed id)
  (dolist (p (process-list))                       ; its worktree adds and merges end too; resume starts them again
    (when (and (process-get p :job) (equal (process-get p :job) id) (process-live-p p))
      (process-put p :stopped t) (delete-process p)))
  (dolist (tid (gethash id drgnx-job--merge-queue)) (remhash tid drgnx-job--busy))   ; the merges that waited too
  (remhash id drgnx-job--merge-queue)
  (dolist (s (drgnx-agents-sessions))
    (when (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited)))
      (drgnx-agents-kill s)))
  id)

(defun drgnx-job-summary (id &optional decisions)
  "Job ID for the user (and JSON): status, budget and spend, tasks with their profiles, agents, cards, pending
permissions — and, with DECISIONS, its decision log (newest first)."
  (when-let* ((job (drgnx-coord-job id)))
    (let* ((data (plist-get job :data))
           (sessions (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))))
                                 (drgnx-agents-sessions))))
      (list :id id :title (plist-get job :title) :status (plist-get job :status) :repo (plist-get job :repo)
            :plan (plist-get job :plan) :budget (plist-get data :budget)
            :warnings (delq nil (list (drgnx-job--budget-warning (plist-get data :unpriced-budget))))
            :spent (plist-get (drgnx-work-db-spend :job id) :cost) :estimate (plist-get data :estimate)
            :tasks (mapcar (lambda (task)
                             (list :n (plist-get task :n) :title (plist-get task :title) :role (plist-get task :role)
                                   :profile (if-let* ((s (drgnx-job--session (plist-get task :agent))))   ; after a fall-back: its agent's
                                                (drgnx-agent-session-profile s)
                                              (drgnx-job--profile id task))   ; else the one it was reassigned to, its route's
                                   :blocked (alist-get (plist-get task :id) (plist-get data :blocked) nil nil #'equal)
                                   :status (or (gethash (plist-get task :id) drgnx-job--busy) (plist-get task :status))   ; starting, merging
                                   :agent (plist-get task :agent) :deps (plist-get task :deps)))
                           (drgnx-coord-tasks id))
            :order (mapcar (lambda (task) (plist-get task :n)) (drgnx-job--ordered id (drgnx-coord-tasks id)))   ; the run order
            :agents (mapcar (lambda (s) (list :id (drgnx-agent-session-id s) :profile (drgnx-agent-session-profile s)
                                              :task (drgnx-agent-session-task s) :status (drgnx-agent-session-status s)
                                              :review (and (gethash (drgnx-agent-session-id s) drgnx-job--reviewers) t)))
                            sessions)
            :cards (mapcar (lambda (c) (list :id (plist-get c :id) :kind (plist-get c :kind) :task (plist-get c :task)
                                             :title (plist-get c :title) :actions (drgnx-job-card-actions c) :data (plist-get c :data)))
                           (drgnx-coord-cards id "open"))
            :messages (mapcar (lambda (m) (list :id (plist-get m :id) :sender (plist-get m :sender) :text (plist-get m :text)
                                                :state (plist-get m :state)))
                              (seq-filter (lambda (m) (and (equal (plist-get m :job) id) (not (equal (plist-get m :sender) "drgnx"))))
                                          (drgnx-coord-inbox "user")))
            :decisions (and decisions
                            (mapcar (lambda (d) (list :n (plist-get d :n) :kind (plist-get d :kind) :subject (plist-get d :subject)
                                                      :author (plist-get d :author) :status (plist-get d :status)))
                                    (drgnx-coord-decisions-since 0 id)))
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
     (mapconcat (lambda (w) (format "  warning: %s\n" w)) (funcall v (plist-get job :warnings)) "")
     (mapconcat (lambda (a) (format "  agent %s (%s) %s on %s\n" (plist-get a :id) (plist-get a :profile) (plist-get a :status)
                                    (plist-get a :task)))
                (funcall v (plist-get job :agents)) "")
     (mapconcat (lambda (p) (format "  asks: %s (%s)\n" (plist-get p :title) (plist-get p :agent))) (funcall v (plist-get job :permissions)) "")
     (mapconcat (lambda (c) (format "  card #%s [%s] %s%s\n" (plist-get c :id) (plist-get c :kind) (if-let* ((task (funcall v (plist-get c :task)))) (concat task ": ") "")
                                    (plist-get c :title)))
                (funcall v (plist-get job :cards)) "")
     (mapconcat (lambda (m) (format "  message #%s from %s: %s\n" (plist-get m :id) (plist-get m :sender) (plist-get m :text)))
                (funcall v (plist-get job :messages)) ""))))

(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-hub--jsonable "drgnx-hub-client")

(defconst drgnx-job--json-lists '(:tasks :agents :cards :messages :permissions :decisions :deps :jobs :unpriced :warnings :order)
  "Keys of a job's JSON that are lists: with nothing in them they are `[]', not null.")

(defun drgnx-job--json (v)
  "V as `drgnx-hub--jsonable' has it, with an empty list under `drgnx-job--json-lists' an empty array, not null."
  (let ((fix nil))
    (setq fix (lambda (x)
                (cond ((and (consp x) (keywordp (car x)))
                       (cl-loop for (k y) on x by #'cddr
                                append (list k (if (and (eq y :null) (memq k drgnx-job--json-lists)) [] (funcall fix y)))))
                      ((vectorp x) (vconcat (mapcar fix x)))
                      (t x))))
    (funcall fix (drgnx-hub--jsonable v))))

(defun drgnx-job--number (text)
  "TEXT (a `--budget') as a number; a user-error when it is none."
  (if (and text (string-match-p "\\`\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\'" text)) (string-to-number text)
    (user-error "--budget wants a number of USD%s" (if text (format ", not %s" text) ""))))

(defun drgnx-job-cli ()
  "`drgnx job propose PLAN [--repo DIR] [--budget USD] [--auto] | approve ID [--budget USD] | status [ID] [--json] |
stop ID | resume ID [--budget USD]', through the hub."
  (require 'drgnx-hub)
  (let* ((args (prog1 (cdr (member "--" command-line-args-left)) (setq command-line-args-left nil)))
         (opt (lambda (name) (cadr (member name args))))
         (budget nil)                                      ; --budget, checked in the condition-case
         (json (member "--json" args))
         (pos (let (out skip) (dolist (a (cdr args) (nreverse out))
                                (cond (skip (setq skip nil)) ((member a '("--repo" "--budget")) (setq skip t))
                                      ((not (string-prefix-p "--" a)) (push a out))))))
         (call (lambda (method params) (drgnx-hub-ensure) (drgnx-hub-call-sync method params 30)))
         (show (lambda (job) (princ (if json (concat (json-serialize (drgnx-job--json job)) "\n") (drgnx-job-format job))) 0)))
    (kill-emacs
     (condition-case err
         (pcase (progn (setq budget (and (member "--budget" args) (drgnx-job--number (funcall opt "--budget")))) (car args))
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
                    (json (princ (concat (json-serialize (drgnx-job--json r)) "\n")) 0)
                    ((null (plist-get r :jobs)) (princ "No jobs.\n") 0)
                    (t (dolist (job (plist-get r :jobs)) (princ (drgnx-job-format job))) 0))))
           (_ (princ "usage: drgnx job propose PLAN [--repo DIR] [--budget USD] [--auto] | approve ID [--budget USD]\n                 | status [ID] [--json] | stop ID | resume ID [--budget USD]\n"
                     #'external-debugging-output)
              2))
       (error (princ (format "drgnx job: %s\n" (error-message-string err)) #'external-debugging-output) 1)))))

(provide 'drgnx-job)
;;; drgnx-job.el ends here
