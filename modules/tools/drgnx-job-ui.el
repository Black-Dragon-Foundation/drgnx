;;; drgnx-job-ui.el --- Jobs in the editor: the Plan Job commands, the badge and notifications -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Plan Job commands, and what tells you a job needs you when you are not looking: a badge in the mode line (for
;; those without the status bar) and a notification per new card.  A job shows in the Work cockpit: Show Job in Work
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

(declare-function drgnx-hub-call "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")
(declare-function drgnx-hub-ensure "drgnx-hub")
(declare-function drgnx-job-format "drgnx-job")
(declare-function drgnx-cockpit-show-job "drgnx-cockpit-cards")
(declare-function drgnx-cockpit-show-jobs "drgnx-cockpit-cards")

(defun drgnx-job-ui--hub ()
  "The hub's client, loaded when it is not yet."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub)))

(defvar drgnx-job-ui-badge-mode)
(defvar drgnx-job-merge-gate)

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

;;;; The badge and notifications: nobody has to watch the cockpit

(defvar drgnx-job-ui-notify t "Non-nil: a new card is a desktop notification (else a message in the echo area).")
(defvar drgnx-job-ui--badge "" "The mode line's badge: \" ⚑N\" while N things of jobs need you, else empty.")
(defvar drgnx-job-ui--badge-job nil "The job with the newest card: the one the badge opens.")
(defvar drgnx-job-ui--notified (make-hash-table :test #'equal) "Card ids already notified.")
(defvar drgnx-job-ui--desktop :unknown "Whether desktop notifications can be sent (asked once).")

(defvar drgnx-job-ui-badge-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'drgnx-job-ui--badge-click)
    m)
  "A click on the badge opens the Work cockpit at the job with the newest card.")

(defun drgnx-job-ui--badge-click ()
  "The Work cockpit at the job with the newest card; every job's when only messages wait."
  (interactive)
  (cond (drgnx-job-ui--badge-job (drgnx-job-ui-show drgnx-job-ui--badge-job))
        ((fboundp 'drgnx-cockpit-show-jobs) (drgnx-cockpit-show-jobs))))

(defun drgnx-job-ui--badge-segment ()
  (if (string-empty-p drgnx-job-ui--badge) ""
    (propertize drgnx-job-ui--badge 'face 'warning 'mouse-face 'mode-line-highlight 'local-map drgnx-job-ui-badge-map
                'help-echo "A job needs you: click to see it in the Work cockpit")))

;;;; What needs you, counted once: the badge, the Work cockpit's What needs you, the status bar

(defvar drgnx-job-ui--needs-you nil
  "How many things of jobs need the user, as last counted (`drgnx-job-ui-note-jobs'); nil when not known.")

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

(defun drgnx-job-ui-needs-you-count (jobs)
  "(N . JOB): what needs the user across JOBS (summaries): open cards and messages not acted on, of proposed,
running and paused jobs — and the job with the newest card.  The one count: the badge and the cockpit use it."
  (let ((n 0) (newest nil) (newest-id -1))
    (dolist (j jobs)
      (setq n (+ n (length (drgnx-job-ui--open-items j))))
      (when (member (plist-get j :status) '("proposed" "running" "paused"))
        (dolist (c (drgnx-job-ui--v (plist-get j :cards)))
          (when (> (plist-get c :id) newest-id) (setq newest-id (plist-get c :id) newest (plist-get j :id))))))
    (cons n newest)))

(defun drgnx-job-ui-note-jobs (jobs)
  "Every job's summary (JOBS, as `job/status' lists them) was read: count what needs the user once — the badge and
`drgnx-job-ui-needs-you' follow.  The badge's own question and the cockpit's every-job pane call it."
  (pcase-let ((`(,n . ,job) (drgnx-job-ui-needs-you-count jobs)))
    (setq drgnx-job-ui--needs-you n drgnx-job-ui--badge (if (> n 0) (format " ⚑%d" n) "") drgnx-job-ui--badge-job job)
    (force-mode-line-update t)))

(defun drgnx-job-ui-needs-you ()
  "How many things of jobs need the user, as last counted; nil when not known (no hub, or it went away).  Cached:
for redisplay code (the status bar's jobs segment)."
  drgnx-job-ui--needs-you)

(defun drgnx-job-ui--badge-clear ()
  "Say nothing: a count that cannot be read again must not stay on screen as if it were current."
  (setq drgnx-job-ui--badge "" drgnx-job-ui--badge-job nil drgnx-job-ui--needs-you nil)
  (force-mode-line-update t))

(defun drgnx-job-ui--recount ()
  "Count again what needs the user (asynchronously): the badge.  A hub that does not answer clears it."
  (condition-case nil
      (progn (drgnx-job-ui--hub)
             (drgnx-hub-call "job/status" nil
                             (lambda (r e)
                               (if e (drgnx-job-ui--badge-clear)
                                 (drgnx-job-ui-note-jobs (drgnx-job-ui--v (plist-get r :jobs)))))))
    (error (drgnx-job-ui--badge-clear))))

(defun drgnx-job-ui--schedule-recount ()
  "Count again within a second (once, however many events)."
  (drgnx-timer-soon 'job-ui-recount 1 #'drgnx-job-ui--recount :owner 'tools/jobs))

(defun drgnx-job-ui--event (event data)
  "`drgnx-hub-event-functions' (while the badge is on): a job or a card changed — count again; a new card notifies."
  (when (member event '("job" "card"))
    (when (equal event "card") (drgnx-job-ui--notify data))
    (when drgnx-job-ui-badge-mode (drgnx-job-ui--schedule-recount))))

(defun drgnx-job-ui--desktop-p ()
  "Can a desktop notification be sent?  (D-Bus with a session bus: asked once.)"
  (when (eq drgnx-job-ui--desktop :unknown)
    (setq drgnx-job-ui--desktop (and (featurep 'dbusbind) (require 'notifications nil t) (getenv "DBUS_SESSION_BUS_ADDRESS") t)))
  drgnx-job-ui--desktop)

(defun drgnx-job-ui--notify (data)
  "A new card (DATA of its event): a desktop notification, once per card — or a message.  Never a prompt."
  (let ((id (plist-get data :id)))
    (when (and drgnx-job-ui-notify id (not (gethash id drgnx-job-ui--notified)) (not (equal (plist-get data :kind) "overlap")))
      (puthash id t drgnx-job-ui--notified)
      (let ((body (format "%s — %s" (plist-get data :job) (plist-get data :title))))
        ;; later, not in the hub's event handler: a D-Bus call that hangs must not hold the filter
        (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx: %S" (drgnx-job-ui--send "drgnx: a job needs you" body))))))))

(defun drgnx-job-ui--send (title body)
  "Tell the user TITLE and BODY where the platform has a notification: macOS through `osascript' (a process that
never waits; a fixed script, the text only as arguments to it: nothing of it is script, no shell), elsewhere D-Bus;
else a message.  A failed osascript says so once.  Never a prompt."
  (cond ((and (eq system-type 'darwin) (executable-find "osascript"))
         (make-process :name "drgnx-notify" :noquery t :connection-type 'pipe
                       :command (list "osascript" "-e" "on run argv"
                                      "-e" "display notification (item 1 of argv) with title (item 2 of argv)"
                                      "-e" "end run" "--"
                                      (replace-regexp-in-string "[\n\r]+" " " body) (replace-regexp-in-string "[\n\r]+" " " title))
                       :sentinel (lambda (p _event)
                                   (when (and (memq (process-status p) '(exit signal)) (/= 0 (process-exit-status p)))
                                     (message "drgnx: the macOS notification failed (%s — %s)" title body)))))
        ((and (not (memq system-type '(darwin windows-nt))) (drgnx-job-ui--desktop-p))
         (notifications-notify :title title :body body))
        (t (message "%s — %s" title body))))

(declare-function notifications-notify "notifications")

(define-minor-mode drgnx-job-ui-badge-mode
  "A badge in the mode line while something of a job needs you (and a notification when it starts to)."
  :global t :group 'drgnx
  (if drgnx-job-ui-badge-mode
      (progn (add-to-list 'global-mode-string '(:eval (drgnx-job-ui--badge-segment)) t)
             (add-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
             (add-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--badge-clear)
             (when (featurep 'drgnx-hub) (drgnx-job-ui--schedule-recount)))   ; never loads the hub by itself
    (setq global-mode-string (delete '(:eval (drgnx-job-ui--badge-segment)) global-mode-string))
    (remove-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
    (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--badge-clear)))

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
  (when (featurep 'drgnx-hub) (drgnx-job-ui--recount)))

(drgnx-module-define 'tools/jobs
                     :doc "Jobs: agents through a plan you approve — cards, clashes, the badge; shown in the Work cockpit."
                     :stage 'startup :requires '(tools/agents)
                     :setup
                     (lambda ()
                       (drgnx-job-ui-badge-mode 1)
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
