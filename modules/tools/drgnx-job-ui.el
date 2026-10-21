;;; drgnx-job-ui.el --- Jobs in the editor: the Plan Job commands and jobs as a source of what needs you -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Plan Job commands, and what tells you a job needs you when you are not looking: the open cards and the messages
;; to you of the jobs are the `jobs' source of the notice model (`drgnx-notice-set'), so they count in the one "needs
;; you" number and a new one reaches the desktop through the notice routes.  A job shows in the Work cockpit: Show Job in Work
;; filters it to the job — what needs you (cards with their actions, messages agents sent you, the job's tasks, agents
;; and spend) and the decision log are the cockpit's parts (drgnx-cockpit-cards.el; until M12f they were a frame of
;; their own, the job window).  See docs/guide/jobs.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-notice)
(require 'drgnx-notice-desktop)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-job-format "drgnx-job")
(declare-function drgnx-cockpit-show-job "drgnx-cockpit-cards")
(declare-function drgnx-cockpit-show-jobs "drgnx-cockpit-cards")

(defun drgnx-job-ui--hub ()
  "The hub's client, loaded when it is not yet."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client)))

(defvar drgnx-job-merge-gate)
(defvar drgnx-notice--sources)
(defvar drgnx-job-ui-attention-mode)

(defun drgnx-job-ui--v (x) (unless (memq x '(:null :false)) x))

(defun drgnx-job-ui--button (label action &rest props)
  (apply #'insert-text-button (format "[%s]" label) 'action (lambda (_) (funcall action)) 'follow-link t 'drgnx-label label props)
  (insert " "))

;;;; Showing a job: the Work cockpit

(defun drgnx-job-ui--read (prompt statuses)
  "A job of the hub's (in STATUSES, or any)."
  (drgnx-job-ui--hub)
  (drgnx-hub-ensure)
  (completing-read prompt (mapcar (lambda (j) (plist-get j :id))
                                  (seq-filter (lambda (j) (or (null statuses) (member (plist-get j :status) statuses)))
                                              (plist-get (drgnx-hub-call-sync "job/status" nil) :jobs)))
                   nil t))

(defun drgnx-job-ui-show (id)
  "Show job ID in the Work cockpit: the graph filtered to it, what needs you (its cards and messages, its tasks,
agents and spend) and its decision log.  Returns nil: no frame is made — a workbench saved with a job window of its
own (`(drgnx-job-ui-show ID)') restores as the cockpit filtered to that job."
  (interactive (list (drgnx-job-ui--read "Show job in Work: " nil)))
  (unless (fboundp 'drgnx-cockpit-show-job) (user-error "The Work cockpit is off (module tools/cockpit)"))
  (drgnx-cockpit-show-job id))

;;;; What needs you, counted once: the notice model's `jobs' source and the Work cockpit's What needs you

(define-obsolete-variable-alias 'drgnx-job-ui-notify 'drgnx-notice-desktop "drgnx M12f")

(defun drgnx-job-ui--open-items (job)
  "JOB's (a `job/status' summary) open cards and messages to the user not acted on, when the job is proposed,
running or paused; else nil."
  (when (member (plist-get job :status) '("proposed" "running" "paused"))
    (append (drgnx-job-ui--v (plist-get job :cards))
            (seq-remove (lambda (m) (equal (plist-get m :state) "acted")) (drgnx-job-ui--v (plist-get job :messages))))))

(defun drgnx-job-ui-waiting-p (job)
  "Whether JOB (a `job/status' summary) waits on the user: proposed, running or paused, with an open card or a
message to the user not acted on."
  (and (drgnx-job-ui--open-items job) t))

(defun drgnx-job-ui--source-p ()
  "Non-nil while the `jobs' notice source is defined: the module `tools/jobs' is on."
  (and (gethash 'jobs drgnx-notice--sources) t))

(defun drgnx-job-ui--line (text)
  "TEXT as one line of at most 100 characters."
  (truncate-string-to-width (string-join (split-string (format "%s" text) "[\n\r]+" t) " ") 100 nil nil "…"))

(defun drgnx-job-ui--items (jobs)
  "The notice items for JOBS (`job/status' summaries): each open card, each message to the user not acted on."
  (let ((items nil))
    (dolist (j jobs)
      (when (member (plist-get j :status) '("proposed" "running" "paused"))
        (let ((job (plist-get j :id)))
          (dolist (c (drgnx-job-ui--v (plist-get j :cards)))
            (push (nconc (list :id (cons 'card (plist-get c :id)) :text (format "%s — %s" job (plist-get c :title))
                               :command (list 'drgnx-job-ui-show job) :scope job)
                         ;; an overlap card is advice: it counts, it never interrupts
                         (when (equal (plist-get c :kind) "overlap") (list :echo nil)))
                  items))
          (dolist (m (drgnx-job-ui--v (plist-get j :messages)))
            (unless (equal (plist-get m :state) "acted")
              (push (list :id (cons 'message (plist-get m :id))
                          :text (drgnx-job-ui--line (format "%s — %s: %s" job (plist-get m :sender) (plist-get m :text)))
                          :command (list 'drgnx-job-ui-show job) :scope job)
                    items))))))
    (nreverse items)))

(defun drgnx-job-ui-note-jobs (jobs)
  "Every job's summary (JOBS, as `job/status' lists them) was read: they are the `jobs' set of the notice model, the
one \"needs you\" count's.  The recount and the cockpit's every-job pane call it; nothing happens while `tools/jobs'
is off (no source)."
  (when (drgnx-job-ui--source-p)
    (drgnx-notice-set 'jobs (drgnx-job-ui--items jobs))
    (force-mode-line-update t)))

(defun drgnx-job-ui--unknown (reason)
  "The jobs' count is not known (REASON says why): a count that cannot be read again must not stay as if current."
  (when (drgnx-job-ui--source-p)
    (drgnx-notice-set 'jobs :unknown :reason reason)
    (force-mode-line-update t)))

(defun drgnx-job-ui--unknown-gone ()
  "`drgnx-hub-disconnect-functions': the hub went away."
  (drgnx-job-ui--unknown "Jobs: not known — the hub went away"))

(defun drgnx-job-ui--recount ()
  "Count again what needs the user (asynchronously).  A hub that does not answer makes the count not known."
  (condition-case nil
      (progn (drgnx-job-ui--hub)
             (drgnx-hub-call "job/status" nil
                             (lambda (r e)
                               (if e (drgnx-job-ui--unknown "Jobs: not known — the hub did not answer")
                                 (drgnx-job-ui-note-jobs (drgnx-job-ui--v (plist-get r :jobs)))))))
    (error (drgnx-job-ui--unknown "Jobs: not known — the hub did not answer"))))

(defun drgnx-job-ui--schedule-recount ()
  "Count again within a second (once, however many events)."
  (drgnx-timer-soon 'job-ui-recount 1 #'drgnx-job-ui--recount :owner 'tools/jobs))

(defun drgnx-job-ui--event (event _data)
  "`drgnx-hub-event-functions' (while the attention mode is on): a job or a card changed — count again.  A new card
reaches the desktop through the set's `:added' ids (the notice routes), not from here."
  (when (and (member event '("job" "card")) drgnx-job-ui-attention-mode)
    (drgnx-job-ui--schedule-recount)))

(define-minor-mode drgnx-job-ui-attention-mode
  "Jobs as a source of what needs you: the hub's events recount their cards and messages; a lost hub makes
the count not known."
  :global t :group 'drgnx
  (if drgnx-job-ui-attention-mode
      (progn (add-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
             (add-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--unknown-gone)
             (when (featurep 'drgnx-hub-client) (drgnx-job-ui--schedule-recount)))   ; never loads the client by itself
    (remove-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
    (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--unknown-gone)))

(define-obsolete-function-alias 'drgnx-job-ui-badge-mode #'drgnx-job-ui-attention-mode "drgnx M12f")
(with-no-warnings   ; the mode's variable is declared at the top (used above the mode): the alias comes after it
  (define-obsolete-variable-alias 'drgnx-job-ui-badge-mode 'drgnx-job-ui-attention-mode "drgnx M12f"))

;;;; The Plan Job commands (they may wait for the hub: the user asked)

(defun drgnx-job-ui-start (file)
  "Propose a job from the plan FILE: the Work cockpit shows the proposal, to approve or reject."
  (interactive (list (read-file-name "Plan: " nil nil t)))
  (drgnx-job-ui--hub)
  (drgnx-hub-ensure)
  (drgnx-job-ui-show (plist-get (drgnx-hub-call-sync "job/propose" (list :plan (expand-file-name file)
                                                                         ;; the gate of this Emacs's option goes with the job
                                                                         :gate (and (boundp 'drgnx-job-merge-gate) (symbol-name drgnx-job-merge-gate)))
                                                     30)
                                :id)))

(defun drgnx-job-ui-approve (id)
  "Start the proposed job ID."
  (interactive (list (drgnx-job-ui--read "Approve job: " '("proposed"))))
  (drgnx-hub-call-sync "job/approve" (list :id id) 30)
  (drgnx-job-ui-show id))

(defun drgnx-job-ui-status ()
  "Every job: its tasks, agents, spend and what waits for you; a button shows it in the Work cockpit."
  (interactive)
  (drgnx-job-ui--hub)
  (drgnx-hub-ensure)
  (let ((jobs (plist-get (drgnx-hub-call-sync "job/status" nil) :jobs)))
    (with-current-buffer (get-buffer-create "*plan jobs*")
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless jobs (insert "No jobs.\n"))
        (dolist (j jobs)
          (insert (drgnx-job-format j) "  ")
          (let ((id (plist-get j :id))) (drgnx-job-ui--button "Show in Work" (lambda () (drgnx-job-ui-show id))))
          (insert "\n\n")))
      (pop-to-buffer (current-buffer)))))

(defun drgnx-job-ui-stop (id)
  "Stop job ID (a proposed one is rejected): its agents end; resume goes on."
  (interactive (list (drgnx-job-ui--read "Stop job: " '("proposed" "running" "paused"))))
  (drgnx-hub-call-sync "job/stop" (list :id id))
  (message "Job %s stopped" id))

(defun drgnx-job-ui--idle-recount ()
  "Count again, once the hub's client is loaded: the 60 s idle timer's function."
  (when (featurep 'drgnx-hub-client) (drgnx-job-ui--recount)))

(drgnx-module-define 'tools/jobs
                     :doc "Jobs: agents through a plan you approve — cards, clashes, what needs you; shown in the Work cockpit."
                     :stage 'startup :requires '(tools/agents)
                     :setup
                     (lambda ()
                       ;; the source, its set and the mode's hub hooks go with the module's cleanup stack
                       (drgnx-notice-define-source 'jobs :title "Jobs" :command 'cockpit-needs-you)
                       (drgnx-job-ui-attention-mode 1)
                       ;; counted again now and then once the hub's client is here (the Agents mirror loads it)
                       (drgnx-timer-start 'job-ui-recount-idle 60 #'drgnx-job-ui--idle-recount :repeat t :idle t)
                       (when (fboundp 'drgnx-wb-place) (drgnx-wb-place "\\`\\*plan jobs\\*\\'" 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((job-show "Show Job in Work…" drgnx-job-ui-show "The Work cockpit filtered to a job: what needs you, its tasks, its decisions")
                                        (job-start "Start Job from Plan…" drgnx-job-ui-start
                                                   "Agents work through a plan: its proposal first, to approve")
                                        (job-approve "Approve Plan Job…" drgnx-job-ui-approve "Start a proposed job")
                                        (job-status "Show Plan Jobs" drgnx-job-ui-status "Every job: tasks, agents, spend and what waits for you")
                                        (job-stop "Stop Plan Job…" drgnx-job-ui-stop "Its agents end; resume goes on")))
                         (drgnx-command-define id :category "Jobs" :title title :command fn :doc doc))))

(provide 'drgnx-job-ui)
;;; drgnx-job-ui.el ends here
