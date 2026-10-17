;;; drgnx-job-ui.el --- Jobs in the editor: the job window (tasks, what needs you, decisions), the Plan Job commands -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The job window is a job's control room — its own frame on a graphical display, so it can sit on another monitor:
;; left, the tasks, their agents and the budget; middle, what needs you (cards with their actions, messages agents
;; sent you); right, the decision log, newest first.  It talks to the hub only asynchronously: hub events schedule a
;; refresh (at most every 0.5 s per job) and only the areas whose part of the job changed are drawn again.  Closing
;; it stops nothing; it comes back after a restart (`drgnx-persist-restore').  See docs/guide/jobs.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-modules)
(require 'drgnx-registry)

(declare-function drgnx-hub-call "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")
(declare-function drgnx-hub-connect "drgnx-hub")
(declare-function drgnx-hub-ensure "drgnx-hub")
(declare-function drgnx-job-format "drgnx-job")
(declare-function drgnx-agents-mirror--find "drgnx-agents-mirror")
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")
(declare-function drgnx-agents-send "drgnx-agents")

(defun drgnx-job-ui--hub ()
  "The hub's client, loaded when it is not yet."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub)))

(defvar drgnx-job-ui--drawn (make-hash-table :test #'equal) "(JOB . PART) → the part of the job last drawn there.")
(defvar drgnx-job-ui--timers (make-hash-table :test #'equal) "Job → its scheduled refresh.")
(defvar drgnx-job-ui--retry nil "The timer that looks for a hub that was not there.")
(defvar-local drgnx-job-ui--job nil "The job this buffer shows.")
(defvar drgnx-job-ui-badge-mode)

(define-derived-mode drgnx-job-ui-mode special-mode "Job"
  "A part of the job window."
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-job-ui--refresh drgnx-job-ui--job))))
(define-derived-mode drgnx-job-tasks-mode drgnx-job-ui-mode "Job: tasks" "The job window's tasks, agents and budget.")
(define-derived-mode drgnx-job-cards-mode drgnx-job-ui-mode "Job: needs you" "What of the job needs you: cards and messages.")
(define-derived-mode drgnx-job-log-mode drgnx-job-ui-mode "Job: decisions" "The job's decision log, newest first.")

(defun drgnx-job-ui--v (x) (unless (memq x '(:null :false)) x))

(defun drgnx-job-ui--buffer-name (job part)
  (format "*job %s: %s*" job (pcase part ('tasks "tasks") ('cards "needs you") ('log "decisions"))))

(defun drgnx-job-ui--buffer (job part)
  "JOB's buffer for PART (`tasks', `cards' or `log'), made if needed."
  (let ((b (get-buffer-create (drgnx-job-ui--buffer-name job part))))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-job-ui-mode)
        (funcall (pcase part ('tasks #'drgnx-job-tasks-mode) ('cards #'drgnx-job-cards-mode) ('log #'drgnx-job-log-mode))))
      (setq drgnx-job-ui--job job))
    b))

(defun drgnx-job-ui--live-p (job) (get-buffer (drgnx-job-ui--buffer-name job 'cards)))

;;;; Drawing

(defun drgnx-job-ui--disputed (summary)
  "The decision numbers an open clash of SUMMARY is about."
  (seq-mapcat (lambda (c) (and (equal (plist-get c :kind) "clash")
                               (delq nil (mapcar (lambda (s) (drgnx-job-ui--v (plist-get s :decision)))
                                                 (drgnx-job-ui--v (plist-get (drgnx-job-ui--v (plist-get c :data)) :sides))))))
              (drgnx-job-ui--v (plist-get summary :cards))))

(defun drgnx-job-ui--part (summary part)
  "What area PART of the window shows of SUMMARY (drawn again only when it changed)."
  (pcase part
    ('tasks (mapcar (lambda (k) (plist-get summary k)) '(:title :status :repo :budget :spent :tasks :agents)))
    ('cards (mapcar (lambda (k) (plist-get summary k)) '(:status :cards :messages)))
    ('log (list (plist-get summary :decisions) (drgnx-job-ui--disputed summary)))))

(defun drgnx-job-ui--button (label action &rest props)
  (apply #'insert-text-button (format "[%s]" label) 'action (lambda (_) (funcall action)) 'follow-link t 'drgnx-label label props)
  (insert " "))

(defun drgnx-job-ui--insert-tasks (job s)
  (insert (propertize (format "%s  %s" job (or (drgnx-job-ui--v (plist-get s :title)) "")) 'face 'bold)
          (format "  [%s]\n" (plist-get s :status)))
  (let ((budget (drgnx-job-ui--v (plist-get s :budget))) (spent (or (drgnx-job-ui--v (plist-get s :spent)) 0)))
    (insert (if budget (format "spent %.2f of %.2f USD\n\n" spent budget) (format "spent %.2f USD (no budget)\n\n" spent))))
  (insert (propertize "Tasks\n" 'face 'bold))
  (dolist (task (drgnx-job-ui--v (plist-get s :tasks)))
    (insert (format "  Task %s: %s — %s" (plist-get task :n) (plist-get task :title)
                    (propertize (plist-get task :status) 'face (pcase (plist-get task :status)
                                                                 ((or "needs-input" "failed") 'warning) ("done" 'success) (_ 'default))))
            (format " · %s" (plist-get task :profile))
            (if-let* ((deps (drgnx-job-ui--v (plist-get task :deps)))) (format " · after %s" (mapconcat #'number-to-string deps ", ")) "")
            "\n"))
  (insert "\n" (propertize "Agents\n" 'face 'bold))
  (let ((agents (drgnx-job-ui--v (plist-get s :agents))))
    (unless agents (insert "  none working\n"))
    (dolist (a agents)
      (let ((id (plist-get a :id)))
        (insert (format "  %s  %s  %s  %s%s\n    " id (plist-get a :profile) (plist-get a :status)
                        (or (drgnx-job-ui--v (plist-get a :task)) "") (if (drgnx-job-ui--v (plist-get a :review)) "  (reviewer)" "")))
        (drgnx-job-ui--button "Transcript" (lambda () (drgnx-job-ui--transcript id)))
        (drgnx-job-ui--button "Message…" (lambda () (drgnx-job-ui--message id)))
        (insert "\n")))))

(defun drgnx-job-ui--insert-card (job c)
  (let ((d (drgnx-job-ui--v (plist-get c :data))))
    (insert (propertize (format "[%s] " (plist-get c :kind)) 'face 'warning)
            (if-let* ((task (drgnx-job-ui--v (plist-get c :task)))) (concat task ": ") "")
            (plist-get c :title) "\n")
    (when (equal (plist-get c :kind) "clash")
      (dolist (side (drgnx-job-ui--v (plist-get d :sides)))
        (insert (format "  %s: %s\n" (plist-get side :label) (plist-get side :text))))
      (let ((rec (drgnx-job-ui--v (plist-get d :recommendation))))
        (insert (cond ((null rec) "  The reviewer is reading both sides…\n")
                      (t (format "  The reviewer recommends %s: %s\n" (or (drgnx-job-ui--v (plist-get rec :side)) "neither")
                                 (plist-get rec :why)))))))
    (insert "  ")
    (dolist (a (drgnx-job-ui--v (plist-get c :actions)))
      (let ((action (car a)))
        (drgnx-job-ui--button (cadr a) (lambda () (drgnx-job-ui--act job c action)))))
    (insert "\n\n")))

(defun drgnx-job-ui--insert-cards (job s)
  (let ((cards (drgnx-job-ui--v (plist-get s :cards))) (messages (drgnx-job-ui--v (plist-get s :messages))))
    (insert (propertize "What needs you\n\n" 'face 'bold))
    (unless (or cards messages) (insert "Nothing needs you.\n"))
    (dolist (c cards) (drgnx-job-ui--insert-card job c))
    (when messages
      (insert (propertize "Messages\n" 'face 'bold))
      (dolist (m messages)
        (let ((id (plist-get m :id)))
          (insert (format "  from %s (%s): %s\n  " (plist-get m :sender) (plist-get m :state)
                          (replace-regexp-in-string "[\n\r]+" " ⏎ " (format "%s" (plist-get m :text)))))
          (drgnx-job-ui--button "Reply…" (lambda () (drgnx-job-ui--reply job id)))
          (insert "\n"))))))

(defun drgnx-job-ui--insert-log (_job s)
  (let ((disputed (drgnx-job-ui--disputed s)))
    (insert (propertize "Decisions\n\n" 'face 'bold))
    (let ((ds (drgnx-job-ui--v (plist-get s :decisions))))
      (unless ds (insert "None yet.\n"))
      (dolist (d ds)
        (insert (propertize (format "#%s %s: %s — %s [%s]%s\n" (plist-get d :n) (plist-get d :kind)
                                    (replace-regexp-in-string "[\n\r]+" " " (format "%s" (plist-get d :subject)))
                                    (plist-get d :author) (plist-get d :status)
                                    (if (and (memql (plist-get d :n) disputed) (not (equal (plist-get d :status) "replaced"))) "  (disputed)" ""))
                            'face (cond ((equal (plist-get d :status) "replaced") 'shadow)   ; replaced, even if a clash names it
                                        ((memql (plist-get d :n) disputed) 'warning)
                                        ((equal (plist-get d :status) "proposed") 'italic)
                                        (t 'default))))))))

(defun drgnx-job-ui--draw (job summary)
  "Draw JOB's SUMMARY (as `job/status' gives it): only the areas whose part changed."
  (add-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)       ; an open window follows the hub
  (add-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--hub-gone)
  (dolist (part '(tasks cards log))
    (let ((p (drgnx-job-ui--part summary part)))
      (unless (equal p (gethash (cons job part) drgnx-job-ui--drawn :none))
        (puthash (cons job part) p drgnx-job-ui--drawn)
        (with-current-buffer (drgnx-job-ui--buffer job part)
          (let ((inhibit-read-only t) (pt (point)))
            (erase-buffer)
            (funcall (pcase part ('tasks #'drgnx-job-ui--insert-tasks) ('cards #'drgnx-job-ui--insert-cards) ('log #'drgnx-job-ui--insert-log))
                     job summary)
            (goto-char (min pt (point-max)))))))))

(defun drgnx-job-ui--no-hub (job why)
  "The hub did not answer for JOB (WHY): the window says so, and looks again later."
  (remhash (cons job 'cards) drgnx-job-ui--drawn)
  (with-current-buffer (drgnx-job-ui--buffer job 'cards)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "No drgnx hub — the job's state appears when it runs (drgnx hub start).\n" (format "(%s)\n" why))))
  (unless (timerp drgnx-job-ui--retry)
    (setq drgnx-job-ui--retry (run-at-time 10 nil (lambda () (setq drgnx-job-ui--retry nil)
                                                    (dolist (j (drgnx-job-ui--jobs)) (drgnx-job-ui--refresh j)))))))

;;;; Talking to the hub (never waiting)

(defun drgnx-job-ui--jobs ()
  "The jobs whose window is open."
  (delete-dups (delq nil (mapcar (lambda (b) (with-current-buffer b (and (derived-mode-p 'drgnx-job-ui-mode) drgnx-job-ui--job)))
                                 (buffer-list)))))

(defun drgnx-job-ui--refresh (job)
  "Ask the hub for JOB (asynchronously); draw what changed."
  (when job
    (condition-case err
        (progn (drgnx-job-ui--hub)
               (drgnx-hub-call "job/status" (list :id job :decisions t)
                               (lambda (r e) (if (or e (not r)) (drgnx-job-ui--no-hub job (or e "no answer"))
                                               (drgnx-job-ui--draw job r)
                                               (ignore-errors (drgnx-hub-connect))))))   ; events again, after a hub came back
      (error (drgnx-job-ui--no-hub job (error-message-string err))))))

(defun drgnx-job-ui--hub-gone ()
  "`drgnx-hub-disconnect-functions': every open job window says the hub is gone (and looks for it again)."
  (dolist (j (drgnx-job-ui--jobs)) (drgnx-job-ui--no-hub j "the hub went away")))

(defun drgnx-job-ui--schedule (job)
  "Refresh JOB's window soon: at most one refresh per 0.5 s, however many events."
  (unless (gethash job drgnx-job-ui--timers)
    (puthash job (run-at-time 0.5 nil (lambda () (remhash job drgnx-job-ui--timers)
                                        (when (drgnx-job-ui--live-p job) (drgnx-job-ui--refresh job))))
             drgnx-job-ui--timers)))

(defun drgnx-job-ui--event (event data)
  "`drgnx-hub-event-functions': a job, a card, an agent or a lease changed — the open windows it concerns refresh."
  (when (member event '("job" "card"))                      ; the badge, and a notification for a new card
    (when (equal event "card") (drgnx-job-ui--notify data))
    (when drgnx-job-ui-badge-mode (drgnx-job-ui--schedule-recount)))
  (pcase event
    ("job" (when (drgnx-job-ui--live-p (plist-get data :id)) (drgnx-job-ui--schedule (plist-get data :id))))
    ((or "card" "lease-released") (when (drgnx-job-ui--live-p (plist-get data :job)) (drgnx-job-ui--schedule (plist-get data :job))))
    ((or "agent" "fallback") (mapc #'drgnx-job-ui--schedule (drgnx-job-ui--jobs)))))

(defun drgnx-job-ui--act (job card action)
  "The user's ACTION on CARD of JOB, through the hub (an argument asked first where the action needs one)."
  (if (equal action "open")
      (drgnx-job-ui--open-tree job)
    (let ((arg (pcase action
                 ("resume" (read-number "Budget for the whole job (USD): "))
                 ("discuss" (read-string "Ask the reviewer: ")))))
      (drgnx-job-ui--hub)
      (drgnx-hub-call "job/card" (list :card (plist-get card :id) :action action :arg arg)
                      (lambda (_r err) (when err (message "drgnx: %s" err)) (drgnx-job-ui--schedule job))))))

(defun drgnx-job-ui--reply (job message)
  (let ((text (read-string "Reply: ")))
    (drgnx-job-ui--hub)
    (drgnx-hub-call "job/reply" (list :message message :text text)
                    (lambda (_r err) (when err (message "drgnx: %s" err)) (drgnx-job-ui--schedule job)))))

(defun drgnx-job-ui--open-tree (job)
  "The job's worktree (its branch, job/JOB) in Dired."
  (let ((repo (nth 2 (gethash (cons job 'tasks) drgnx-job-ui--drawn))))
    (if (drgnx-job-ui--v repo) (dired (expand-file-name (format ".claude/worktrees/%s/" job) repo))
      (message "drgnx: the job's repository is not known yet"))))

(defun drgnx-job-ui--mirror (id)
  (require 'drgnx-agents-mirror)
  (or (drgnx-agents-mirror--find id) (user-error "Agent %s is not mirrored here (yet)" id)))

(defun drgnx-job-ui--transcript (id)
  (require 'drgnx-agents-ui nil t)
  (drgnx-agents-ui-transcript (drgnx-job-ui--mirror id)))

(defun drgnx-job-ui--message (id)
  (drgnx-agents-send (drgnx-job-ui--mirror id) (read-string (format "Message to %s: " id))))

;;;; The window

(defun drgnx-job-ui--frame (job)
  "JOB's window: its own frame on a graphical display (the one it has, if open), else the selected frame."
  (if (display-graphic-p)
      (or (seq-find (lambda (f) (equal (frame-parameter f 'drgnx-job) job)) (frame-list))
          (make-frame `((name . ,(format "drgnx job %s" job)) (drgnx-frame-role . job) (drgnx-job . ,job)
                        (drgnx-persist-restore . (drgnx-job-ui-show ,job)))))
    (selected-frame)))

(defun drgnx-job-ui--layout (job)
  "Three areas side by side in the selected frame: tasks (30%), what needs you, decisions (30%)."
  (delete-other-windows)
  (let ((left (selected-window)))
    (set-window-dedicated-p left nil)
    (condition-case nil
        (let* ((total (window-total-width left))
               (middle (split-window left (max 20 (floor (* total 0.3))) 'right))
               (right (split-window middle (max 20 (- (window-total-width middle) (floor (* total 0.3)))) 'right)))
          (set-window-buffer left (drgnx-job-ui--buffer job 'tasks))
          (set-window-buffer middle (drgnx-job-ui--buffer job 'cards))
          (set-window-buffer right (drgnx-job-ui--buffer job 'log))
          (dolist (w (list left middle right)) (set-window-dedicated-p w t))
          (select-window middle))
      (error (set-window-buffer left (drgnx-job-ui--buffer job 'cards))))))   ; too narrow: what needs you

(defun drgnx-job-ui--read (prompt statuses)
  "A job of the hub's (in STATUSES, or any)."
  (drgnx-job-ui--hub)
  (drgnx-hub-ensure)
  (completing-read prompt (mapcar (lambda (j) (plist-get j :id))
                                  (seq-filter (lambda (j) (or (null statuses) (member (plist-get j :status) statuses)))
                                              (plist-get (drgnx-hub-call-sync "job/status" nil) :jobs)))
                   nil t))

(defun drgnx-job-ui-show (id)
  "Show job ID's window: tasks and agents, what needs you, the decision log.  Closing it stops nothing."
  (interactive (list (drgnx-job-ui--read "Show job: " nil)))
  (let ((frame (drgnx-job-ui--frame id)))
    (with-selected-frame frame (drgnx-job-ui--layout id))
    (when (frame-live-p frame) (select-frame-set-input-focus frame))
    (add-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
    (add-hook 'drgnx-hub-disconnect-functions #'drgnx-job-ui--hub-gone)
    (condition-case nil (progn (drgnx-job-ui--hub) (drgnx-hub-connect)) (error nil))
    (drgnx-job-ui--refresh id)
    frame))

(defun drgnx-job-ui--frame-deleted (frame)
  "A job window closed: its buffers go; the job goes on."
  (when-let* ((job (frame-parameter frame 'drgnx-job)))
    (dolist (part '(tasks cards log))
      (when-let* ((b (get-buffer (drgnx-job-ui--buffer-name job part)))) (kill-buffer b))
      (remhash (cons job part) drgnx-job-ui--drawn))))

;;;; The badge and notifications: nobody has to watch the window

(defvar drgnx-job-ui-notify t "Non-nil: a new card is a desktop notification (else a message in the echo area).")
(defvar drgnx-job-ui--badge "" "The mode line's badge: \" ⚑N\" while N things of jobs need you, else empty.")
(defvar drgnx-job-ui--badge-job nil "The job with the newest card: the one the badge opens.")
(defvar drgnx-job-ui--notified (make-hash-table :test #'equal) "Card ids already notified.")
(defvar drgnx-job-ui--recount-timer nil)
(defvar drgnx-job-ui--desktop :unknown "Whether desktop notifications can be sent (asked once).")

(defvar drgnx-job-ui-badge-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] (lambda () (interactive) (when drgnx-job-ui--badge-job (drgnx-job-ui-show drgnx-job-ui--badge-job))))
    m)
  "A click on the badge opens the job with the newest card.")

(defun drgnx-job-ui--badge-segment ()
  (if (string-empty-p drgnx-job-ui--badge) ""
    (propertize drgnx-job-ui--badge 'face 'warning 'mouse-face 'mode-line-highlight 'local-map drgnx-job-ui-badge-map
                'help-echo "A job needs you: click to open its window")))

(defun drgnx-job-ui--count (jobs)
  "(N . JOB): what needs the user across JOBS (open cards, messages not acted on) — proposed, running and paused
jobs only — and the job with the newest card."
  (let ((n 0) (newest nil) (newest-id -1))
    (dolist (j jobs)
      (when (member (plist-get j :status) '("proposed" "running" "paused"))
        (dolist (c (drgnx-job-ui--v (plist-get j :cards)))
          (setq n (1+ n))
          (when (> (plist-get c :id) newest-id) (setq newest-id (plist-get c :id) newest (plist-get j :id))))
        (setq n (+ n (seq-count (lambda (m) (not (equal (plist-get m :state) "acted"))) (drgnx-job-ui--v (plist-get j :messages)))))))
    (cons n newest)))

(defun drgnx-job-ui--recount ()
  "Count again what needs the user (asynchronously): the badge."
  (condition-case nil
      (progn (drgnx-job-ui--hub)
             (drgnx-hub-call "job/status" nil
                             (lambda (r e)
                               (unless e
                                 (pcase-let ((`(,n . ,job) (drgnx-job-ui--count (drgnx-job-ui--v (plist-get r :jobs)))))
                                   (setq drgnx-job-ui--badge (if (> n 0) (format " ⚑%d" n) "") drgnx-job-ui--badge-job job)
                                   (force-mode-line-update t))))))
    (error nil)))

(defun drgnx-job-ui--schedule-recount ()
  "Count again within a second (once, however many events)."
  (unless (timerp drgnx-job-ui--recount-timer)
    (setq drgnx-job-ui--recount-timer (run-at-time 1 nil (lambda () (setq drgnx-job-ui--recount-timer nil) (drgnx-job-ui--recount))))))

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
        (run-at-time 0 nil (lambda ()
                             (if (drgnx-job-ui--desktop-p)
                                 (with-demoted-errors "drgnx: %S" (notifications-notify :title "drgnx: a job needs you" :body body))
                               (message "drgnx: a job needs you — %s" body))))))))

(declare-function notifications-notify "notifications")

(define-minor-mode drgnx-job-ui-badge-mode
  "A badge in the mode line while something of a job needs you (and a notification when it starts to)."
  :global t :group 'drgnx
  (if drgnx-job-ui-badge-mode
      (progn (add-to-list 'global-mode-string '(:eval (drgnx-job-ui--badge-segment)) t)
             (add-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)
             (when (featurep 'drgnx-hub) (drgnx-job-ui--schedule-recount)))   ; never loads the hub by itself
    (setq global-mode-string (delete '(:eval (drgnx-job-ui--badge-segment)) global-mode-string))
    (remove-hook 'drgnx-hub-event-functions #'drgnx-job-ui--event)))

;;;; The Plan Job commands (they may wait for the hub: the user asked)

(defun drgnx-job-ui-start (file)
  "Propose a job from the plan FILE: its window shows the proposal, to approve or reject."
  (interactive (list (read-file-name "Plan: " nil nil t)))
  (drgnx-job-ui--hub)
  (drgnx-hub-ensure)
  (drgnx-job-ui-show (plist-get (drgnx-hub-call-sync "job/propose" (list :plan (expand-file-name file)) 30) :id)))

(defun drgnx-job-ui-approve (id)
  "Start the proposed job ID."
  (interactive (list (drgnx-job-ui--read "Approve job: " '("proposed"))))
  (drgnx-hub-call-sync "job/approve" (list :id id) 30)
  (drgnx-job-ui-show id))

(defun drgnx-job-ui-status ()
  "Every job: its tasks, agents, spend and what waits for you; a button opens its window."
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
          (let ((id (plist-get j :id))) (drgnx-job-ui--button "Open its window" (lambda () (drgnx-job-ui-show id))))
          (insert "\n\n")))
      (pop-to-buffer (current-buffer)))))

(defun drgnx-job-ui-stop (id)
  "Stop job ID (a proposed one is rejected): its agents end; resume goes on."
  (interactive (list (drgnx-job-ui--read "Stop job: " '("proposed" "running" "paused"))))
  (drgnx-hub-call-sync "job/stop" (list :id id))
  (message "Job %s stopped" id))

(drgnx-module-define 'tools/jobs
                     :doc "Jobs: agents through a plan you approve — the job window (tasks, what needs you, decisions), cards, clashes."
                     :stage 'startup :requires '(tools/agents)
                     :setup
                     (lambda ()
                       (add-hook 'delete-frame-functions #'drgnx-job-ui--frame-deleted)
                       (drgnx-job-ui-badge-mode 1)
                       ;; counted again now and then once the hub's client is here (the Agents mirror loads it)
                       (run-with-idle-timer 60 t (lambda () (when (featurep 'drgnx-hub) (drgnx-job-ui--recount))))
                       (when (fboundp 'drgnx-wb-place) (drgnx-wb-place "\\`\\*plan jobs\\*\\'" 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((job-show "Show Job Window…" drgnx-job-ui-show "Tasks and agents, what needs you, the decision log")
                                        (job-start "Start Job from Plan…" drgnx-job-ui-start
                                                   "Agents work through a plan: its proposal first, to approve")
                                        (job-approve "Approve Plan Job…" drgnx-job-ui-approve "Start a proposed job")
                                        (job-status "Show Plan Jobs" drgnx-job-ui-status "Every job: tasks, agents, spend and what waits for you")
                                        (job-stop "Stop Plan Job…" drgnx-job-ui-stop "Its agents end; resume goes on")))
                         (drgnx-command-define id :category "Jobs" :title title :command fn :doc doc))))

(provide 'drgnx-job-ui)
;;; drgnx-job-ui.el ends here
