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

(provide 'drgnx-job)
;;; drgnx-job.el ends here
