;;; drgnx-cockpit-cards.el --- Module tools/cockpit: what needs you and the decision log — the job window's parts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The job window's parts, in the Work cockpit (before M12f a job had a frame of its own): `needs-you' — the cards
;; with their actions and the messages agents sent you, of every job, or of the job the cockpit is filtered to (then
;; with its tasks, agents and spend below) — and `decisions', that job's decision log, newest first.  Both are pane
;; kinds of home `right', stacked with `happened'.  The filter is the graph's (`drgnx-cockpit-graph-current-filter')
;; with a `:job': the graph then shows that job's nodes and their ancestors.  The parts talk to the hub only
;; asynchronously, as the job window did: hub events schedule a refresh (at most one per 0.5 s), only while a part
;; shows (hidden, it refreshes when one shows), and a part is drawn again only when what it shows changed.  The
;; filter is kept with the saved workbench (`:cockpit-filter'); a workbench saved with a job window restores it as
;; the cockpit filtered to that job.  See docs/guide/jobs.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-registry)
(require 'drgnx-panes)
;; the jobs module's count of what needs you (the badge's), beside this file
(unless (featurep 'drgnx-job-ui)
  (load (expand-file-name "drgnx-job-ui" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-job-ui-waiting-p "drgnx-job-ui")
(declare-function drgnx-job-ui-needs-you-count "drgnx-job-ui")
(declare-function drgnx-job-ui-note-jobs "drgnx-job-ui")

(declare-function drgnx-hub-call "drgnx-hub")
(declare-function drgnx-hub-connect "drgnx-hub")
(declare-function drgnx-agents-mirror--find "drgnx-agents-mirror")
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function drgnx-job-ui--schedule-recount "drgnx-job-ui")
(declare-function drgnx-layouts-apply "drgnx-layouts")
(declare-function drgnx-layouts-names "drgnx-layouts")
(declare-function drgnx-cockpit-schedule "drgnx-cockpit")
(declare-function evil-set-initial-state "evil-core")
(defvar drgnx-cockpit-graph-current-filter)
(defvar drgnx-hub-event-functions)
(defvar drgnx-hub-disconnect-functions)
(defvar drgnx-persist-restoring)

(defconst drgnx-cockpit-cards-buffer-name "*Needs You*")
(defconst drgnx-cockpit-decisions-buffer-name "*Decisions*")

(defvar drgnx-cockpit-cards--timer nil "The refresh on its way: one at a time.")
(defvar drgnx-cockpit-cards--retry nil "The look, 10 s on, for a hub that was not there.")
(defvar drgnx-cockpit-cards--stale nil "Something changed while no part showed: they refresh when one shows.")
(defvar-local drgnx-cockpit-cards--shown :none "What this part shows, as last drawn: the same again draws nothing.")

(defun drgnx-cockpit-cards--v (x) (unless (memq x '(:null :false)) x))

(defun drgnx-cockpit-cards--hub ()
  "The hub's client, loaded when it is not yet."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub)))

(defun drgnx-cockpit-cards-job ()
  "The job the cockpit is filtered to (`:job' of `drgnx-cockpit-graph-current-filter'), or nil: every job."
  (plist-get drgnx-cockpit-graph-current-filter :job))

;;;; The buffers

(define-derived-mode drgnx-cockpit-cards-mode special-mode "Needs you"
  "What needs you: the cards and the messages agents sent you (docs/guide/jobs.md)."
  (drgnx-cockpit-cards--setup-buffer))

(define-derived-mode drgnx-cockpit-decisions-mode special-mode "Decisions"
  "A job's decision log, newest first (docs/guide/jobs.md)."
  (drgnx-cockpit-cards--setup-buffer))

(with-eval-after-load 'evil                     ; buttons and g, also in the Vim profile
  (when (fboundp 'evil-set-initial-state)
    (dolist (m '(drgnx-cockpit-cards-mode drgnx-cockpit-decisions-mode)) (evil-set-initial-state m 'emacs))))

(defun drgnx-cockpit-cards--setup-buffer ()
  "What both parts do: a generated, read-only buffer that owns the parts' hooks while it lives; long lines wrap at
spaces (a dock is narrow: a button is never cut in two)."
  (buffer-disable-undo)
  (setq-local word-wrap t)
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-cockpit-cards-refresh)))
  (add-hook 'kill-buffer-hook #'drgnx-cockpit-cards--unwatch nil t)
  (drgnx-cockpit-cards--watch))

(defun drgnx-cockpit-cards--buffer (part)
  "PART's buffer (`cards': what needs you, `log': the decisions), made the first time; it then follows the hub."
  (let ((name (if (eq part 'cards) drgnx-cockpit-cards-buffer-name drgnx-cockpit-decisions-buffer-name)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (if (eq part 'cards) (drgnx-cockpit-cards-mode) (drgnx-cockpit-decisions-mode))
          (setq drgnx-cockpit-cards--stale t)
          (current-buffer)))))

(defun drgnx-cockpit-cards-buffer () "What needs you's buffer." (drgnx-cockpit-cards--buffer 'cards))
(defun drgnx-cockpit-decisions-buffer () "The decision log's buffer." (drgnx-cockpit-cards--buffer 'log))

(defun drgnx-cockpit-cards--buffers ()
  "The parts' live buffers."
  (delq nil (list (get-buffer drgnx-cockpit-cards-buffer-name) (get-buffer drgnx-cockpit-decisions-buffer-name))))

;;;; Drawing (the job window's, moved)

(defun drgnx-cockpit-cards--disputed (summary)
  "The decision numbers an open clash of SUMMARY is about."
  (seq-mapcat (lambda (c) (and (equal (plist-get c :kind) "clash")
                               (delq nil (mapcar (lambda (s) (drgnx-cockpit-cards--v (plist-get s :decision)))
                                                 (drgnx-cockpit-cards--v (plist-get (drgnx-cockpit-cards--v (plist-get c :data)) :sides))))))
              (drgnx-cockpit-cards--v (plist-get summary :cards))))

(defun drgnx-cockpit-cards--part (summary part)
  "What PART of the job shows of SUMMARY (drawn again only when it changed)."
  (pcase part
    ('tasks (mapcar (lambda (k) (plist-get summary k)) '(:title :status :repo :budget :spent :tasks :agents)))
    ('cards (mapcar (lambda (k) (plist-get summary k)) '(:status :cards :messages)))
    ('log (list (plist-get summary :decisions) (drgnx-cockpit-cards--disputed summary)))))

(defun drgnx-cockpit-cards--button (label action &rest props)
  (apply #'insert-text-button (format "[%s]" label) 'action (lambda (_) (funcall action)) 'follow-link t 'drgnx-label label props)
  (insert " "))

(defun drgnx-cockpit-cards--insert-tasks (job s)
  (insert (propertize (format "%s  %s" job (or (drgnx-cockpit-cards--v (plist-get s :title)) "")) 'face 'bold)
          (format "  [%s]\n" (plist-get s :status)))
  (let ((budget (drgnx-cockpit-cards--v (plist-get s :budget))) (spent (or (drgnx-cockpit-cards--v (plist-get s :spent)) 0)))
    (insert (if budget (format "spent %.2f of %.2f USD\n\n" spent budget) (format "spent %.2f USD (no budget)\n\n" spent))))
  (insert (propertize "Tasks\n" 'face 'bold))
  (dolist (task (drgnx-cockpit-cards--v (plist-get s :tasks)))
    (insert (format "  Task %s: %s — %s" (plist-get task :n) (plist-get task :title)
                    (propertize (plist-get task :status) 'face (pcase (plist-get task :status)
                                                                 ((or "needs-input" "failed") 'warning) ("done" 'success) (_ 'default))))
            (format " · %s" (plist-get task :profile))
            (if-let* ((deps (drgnx-cockpit-cards--v (plist-get task :deps)))) (format " · after %s" (mapconcat #'number-to-string deps ", ")) "")
            "\n"))
  (insert "\n" (propertize "Agents\n" 'face 'bold))
  (let ((agents (drgnx-cockpit-cards--v (plist-get s :agents))))
    (unless agents (insert "  none working\n"))
    (dolist (a agents)
      (let ((id (plist-get a :id)))
        (insert (format "  %s  %s  %s  %s%s\n    " id (plist-get a :profile) (plist-get a :status)
                        (or (drgnx-cockpit-cards--v (plist-get a :task)) "") (if (drgnx-cockpit-cards--v (plist-get a :review)) "  (reviewer)" "")))
        (drgnx-cockpit-cards--button "Transcript" (lambda () (drgnx-cockpit-cards--transcript id)))
        (drgnx-cockpit-cards--button "Message…" (lambda () (drgnx-cockpit-cards--message id)))
        (insert "\n")))))

(defun drgnx-cockpit-cards--insert-card (job c &optional repo)
  "Card C of JOB with its actions (REPO: the job's repository, for Open)."
  (let ((d (drgnx-cockpit-cards--v (plist-get c :data))))
    (insert (propertize (format "[%s] " (plist-get c :kind)) 'face 'warning)
            (if-let* ((task (drgnx-cockpit-cards--v (plist-get c :task)))) (concat task ": ") "")
            (plist-get c :title) "\n")
    (when (equal (plist-get c :kind) "clash")
      (dolist (side (drgnx-cockpit-cards--v (plist-get d :sides)))
        (insert (format "  %s: %s\n" (plist-get side :label) (plist-get side :text))))
      (let ((rec (drgnx-cockpit-cards--v (plist-get d :recommendation))))
        (insert (cond ((and (null rec) (drgnx-cockpit-cards--v (plist-get d :reviewer-gone)))
                       "  No reviewer is coming — pick a side yourself, or Discuss to start one again.\n")
                      ((and (null rec) (drgnx-cockpit-cards--v (plist-get d :no-recommendation)))
                       "  The reviewer gave no recommendation — pick a side yourself, or Discuss.\n")
                      ((null rec) "  The reviewer is reading both sides…\n")
                      (t (format "  The reviewer recommends %s: %s\n" (or (drgnx-cockpit-cards--v (plist-get rec :side)) "neither")
                                 (plist-get rec :why)))))))
    (insert "  ")
    (dolist (a (drgnx-cockpit-cards--v (plist-get c :actions)))
      (let ((action (car a)))
        (drgnx-cockpit-cards--button (cadr a) (lambda () (drgnx-cockpit-cards--act job c action repo)))))
    (insert "\n\n")))

(defun drgnx-cockpit-cards--insert-items (job s)
  "JOB's cards, then the messages agents sent you, from its summary S."
  (let ((messages (drgnx-cockpit-cards--v (plist-get s :messages))))
    (dolist (c (drgnx-cockpit-cards--v (plist-get s :cards))) (drgnx-cockpit-cards--insert-card job c (drgnx-cockpit-cards--v (plist-get s :repo))))
    (when messages
      (insert (propertize "Messages\n" 'face 'bold))
      (dolist (m messages)
        (let ((id (plist-get m :id)))
          (insert (format "  from %s (%s): %s\n  " (plist-get m :sender) (plist-get m :state)
                          (replace-regexp-in-string "[\n\r]+" " ⏎ " (format "%s" (plist-get m :text)))))
          (unless (equal (plist-get m :state) "acted")      ; dismissed or answered: nothing more to do
            (drgnx-cockpit-cards--button "Reply…" (lambda () (drgnx-cockpit-cards--reply id)))
            (drgnx-cockpit-cards--button "Dismiss" (lambda () (drgnx-cockpit-cards--dismiss id))))
          (insert "\n"))))))

(defun drgnx-cockpit-cards--insert-cards (job s)
  (insert (propertize (format "What needs you: %d\n\n" (car (drgnx-job-ui-needs-you-count (list s)))) 'face 'bold))
  (unless (or (drgnx-cockpit-cards--v (plist-get s :cards)) (drgnx-cockpit-cards--v (plist-get s :messages)))
    (insert "Nothing needs you.\n"))
  (drgnx-cockpit-cards--insert-items job s))

(defun drgnx-cockpit-cards--insert-log (_job s)
  (let ((disputed (drgnx-cockpit-cards--disputed s)))
    (insert (propertize "Decisions\n\n" 'face 'bold))
    (let ((ds (drgnx-cockpit-cards--v (plist-get s :decisions))))
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

(defun drgnx-cockpit-cards--insert-all (jobs n)
  "What needs you of every job of JOBS (summaries), each under its name — a button that filters the cockpit to it;
N things in all."
  (insert (propertize (format "What needs you — every job: %d\n\n" n) 'face 'bold))
  (unless jobs (insert "Nothing needs you.\n"))
  (dolist (j jobs)
    (let ((id (plist-get j :id)))
      (unless (looking-back "\n\n" 2) (insert "\n"))  ; a blank line between jobs
      (drgnx-cockpit-cards--button id (lambda () (drgnx-cockpit-show-job id)) 'help-echo "This job alone, in the Work cockpit")
      (insert (propertize (format "%s  [%s]\n" (or (drgnx-cockpit-cards--v (plist-get j :title)) "") (plist-get j :status)) 'face 'bold))
      (drgnx-cockpit-cards--insert-items id j))))

(defun drgnx-cockpit-cards--insert-no-log ()
  (insert (propertize "Decisions\n\n" 'face 'bold)
          "Each job keeps its own decision log: Show Job in Work… (job-show), or a job's name in What needs you.\n"))

(defun drgnx-cockpit-cards--put (part shown draw)
  "Draw PART with DRAW (a function inserting at point) unless it shows SHOWN already.  Its windows keep their start
and point where the text still reaches."
  (with-current-buffer (drgnx-cockpit-cards--buffer part)
    (unless (equal shown drgnx-cockpit-cards--shown)
      (setq drgnx-cockpit-cards--shown shown)
      (let* ((inhibit-read-only t) (pt (point))
             (windows (get-buffer-window-list (current-buffer) nil t))
             (keep (mapcar (lambda (w) (list w (window-start w) (window-point w))) windows)))
        (erase-buffer)
        (funcall draw)
        (goto-char (min pt (point-max)))
        (drgnx-wb-with-owned-windows windows
          (pcase-dolist (`(,w ,s ,p) keep)
            (set-window-start w (min s (point-max)) t)
            (set-window-point w (min p (point-max)))))
        (set-buffer-modified-p nil)))))

(defun drgnx-cockpit-cards--draw (job summary)
  "Draw JOB's SUMMARY (as `job/status' gives it): what needs you — its cards and messages, then its tasks, agents
and spend — and its decision log, each only when its part of the job changed."
  (drgnx-cockpit-cards--put 'cards (list job (drgnx-cockpit-cards--part summary 'cards) (drgnx-cockpit-cards--part summary 'tasks))
                            (lambda ()
                              (drgnx-cockpit-cards--insert-cards job summary)
                              (insert "\n")
                              (drgnx-cockpit-cards--insert-tasks job summary)))
  (drgnx-cockpit-cards--put 'log (list job (drgnx-cockpit-cards--part summary 'log))
                            (lambda () (drgnx-cockpit-cards--insert-log job summary))))

(defun drgnx-cockpit-cards--draw-all (jobs)
  "Draw what needs you of every job of JOBS (as `job/status' lists them) that waits on the user
(`drgnx-job-ui-waiting-p'), and tell the badge the count (`drgnx-job-ui-note-jobs': one count, no second question);
the decision log says it is per job."
  (drgnx-job-ui-note-jobs jobs)
  (let ((open (seq-filter #'drgnx-job-ui-waiting-p jobs)) (n (car (drgnx-job-ui-needs-you-count jobs))))
    (drgnx-cockpit-cards--put 'cards (cons n (mapcar (lambda (j) (list (plist-get j :id) (plist-get j :title) (plist-get j :repo)
                                                                       (drgnx-cockpit-cards--part j 'cards)))
                                                     open))
                              (lambda () (drgnx-cockpit-cards--insert-all open n)))
    (drgnx-cockpit-cards--put 'log :all #'drgnx-cockpit-cards--insert-no-log)))

(defun drgnx-cockpit-cards--no-hub (why)
  "The hub did not answer (WHY): what needs you says so, and the parts look again 10 s on."
  (drgnx-cockpit-cards--put 'cards (list :no-hub why)
                            (lambda () (insert "No drgnx hub — what jobs need of you appears when it runs (drgnx hub start).\n"
                                               (format "(%s)\n" why))))
  (unless (timerp drgnx-cockpit-cards--retry)
    (setq drgnx-cockpit-cards--retry (run-at-time 10 nil #'drgnx-cockpit-cards--look-again))))

(defun drgnx-cockpit-cards--look-again ()
  "The retry of `drgnx-cockpit-cards--no-hub' (a timer)."
  (setq drgnx-cockpit-cards--retry nil)
  (drgnx-cockpit-cards--schedule 0))

;;;; Talking to the hub (never waiting)

(defun drgnx-cockpit-cards-refresh ()
  "Ask the hub (asynchronously) for what the parts show — the job the cockpit is filtered to, else every job — and
draw what changed."
  (let ((job (drgnx-cockpit-cards-job)))
    (condition-case err
        (progn (drgnx-cockpit-cards--hub)
               (drgnx-hub-call "job/status" (and job (list :id job :decisions t))
                               (lambda (r e) (drgnx-cockpit-cards--answer job r e))))
      (error (drgnx-cockpit-cards--no-hub (error-message-string err))))))

(defun drgnx-cockpit-cards--answer (job r e)
  "The hub's answer R (or error E) about JOB (nil: every job).  A filter that changed meanwhile asked again."
  (when (and (equal job (drgnx-cockpit-cards-job)) (drgnx-cockpit-cards--buffers))
    (cond
     ;; "No job ID": the hub's own error text for an unknown job (job/status in core/drgnx-hub.el); change both together
     ((and job (stringp e) (string-prefix-p "No job " e)) (drgnx-cockpit-cards--gone job))
     ((or e (not r)) (drgnx-cockpit-cards--no-hub (or e "no answer")))
     (t (if job (drgnx-cockpit-cards--draw job r)
          (drgnx-cockpit-cards--draw-all (drgnx-cockpit-cards--v (plist-get r :jobs))))
        (ignore-errors (drgnx-hub-connect))))))      ; events again, after a hub came back

(defun drgnx-cockpit-cards--gone (job)
  "The hub does not know JOB (it was deleted, or a saved filter outlived it): the cockpit shows every job again."
  (message "drgnx: job %s is gone; the Work cockpit shows every job" job)
  (drgnx-cockpit-cards--set-job nil))

(defun drgnx-cockpit-cards--hub-gone ()
  "`drgnx-hub-disconnect-functions': what needs you says the hub is gone (and looks for it again)."
  (drgnx-cockpit-cards--no-hub "the hub went away"))

(defun drgnx-cockpit-cards--watch ()
  "Follow the hub while a part's buffer lives (idempotent)."
  (add-hook 'drgnx-hub-event-functions #'drgnx-cockpit-cards--hub-event)
  (add-hook 'drgnx-hub-disconnect-functions #'drgnx-cockpit-cards--hub-gone))

(defun drgnx-cockpit-cards--unwatch ()
  "A part's buffer is killed (its `kill-buffer-hook'): with the last one, stop following the hub."
  (unless (delq (current-buffer) (drgnx-cockpit-cards--buffers))
    (remove-hook 'drgnx-hub-event-functions #'drgnx-cockpit-cards--hub-event)
    (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-cockpit-cards--hub-gone)
    (dolist (tm (list drgnx-cockpit-cards--timer drgnx-cockpit-cards--retry)) (when (timerp tm) (cancel-timer tm)))
    (setq drgnx-cockpit-cards--timer nil drgnx-cockpit-cards--retry nil)))

(defun drgnx-cockpit-cards--visible-p ()
  "Whether a part shows in a window of a visible frame."
  (seq-some (lambda (b) (get-buffer-window b 'visible)) (drgnx-cockpit-cards--buffers)))

(defun drgnx-cockpit-cards--schedule (&optional delay)
  "Refresh the parts within DELAY seconds (0.5): one refresh however many calls come meanwhile, only while a part
shows (hidden, they refresh when one shows).  Cheap: called from every event."
  (when (drgnx-cockpit-cards--buffers)
    (cond ((not (drgnx-cockpit-cards--visible-p)) (setq drgnx-cockpit-cards--stale t))
          ((not (timerp drgnx-cockpit-cards--timer))
           (setq drgnx-cockpit-cards--timer (run-at-time (or delay 0.5) nil #'drgnx-cockpit-cards--tick))))))

(defun drgnx-cockpit-cards--tick ()
  "The scheduled refresh (a timer).  Parts hidden since it was scheduled only note they are stale."
  (setq drgnx-cockpit-cards--timer nil)
  (if (drgnx-cockpit-cards--visible-p)
      (progn (setq drgnx-cockpit-cards--stale nil) (drgnx-cockpit-cards-refresh))
    (setq drgnx-cockpit-cards--stale t)))

(defun drgnx-cockpit-cards--on-show (_window)
  "A part shows: catch up with what changed while none showed (soon, never while showing it)."
  (when drgnx-cockpit-cards--stale (drgnx-cockpit-cards--schedule 0)))

(defun drgnx-cockpit-cards--hub-event (event data)
  "`drgnx-hub-event-functions': a job, a card, an agent or a lease changed — the parts refresh soon when it concerns
the job they show (any job, when they show every job)."
  (let ((job (drgnx-cockpit-cards-job)))
    (when (pcase event
            ("job" (or (null job) (equal job (plist-get data :id))))
            ((or "card" "lease-released") (or (null job) (equal job (plist-get data :job))))
            ((or "agent" "fallback") t))
      (drgnx-cockpit-cards--schedule))))

;;;; Acting on a card or a message (the user's buttons: they may ask)

(defun drgnx-cockpit-cards--changed ()
  "An action went through: the parts and the badge count again — once: every job's pane, when it shows, counts
for the badge (`drgnx-cockpit-cards--draw-all')."
  (drgnx-cockpit-cards--schedule)
  (unless (and (null (drgnx-cockpit-cards-job)) (drgnx-cockpit-cards--visible-p))
    (drgnx-job-ui--schedule-recount)))

(defun drgnx-cockpit-cards--act (job card action &optional repo)
  "The user's ACTION on CARD of JOB, through the hub (an argument asked first where the action needs one); REPO, the
job's repository, for Open."
  (if (equal action "open")
      (drgnx-cockpit-cards--open-tree job repo)
    (let ((arg (pcase action
                 ("resume" (read-number "Budget for the whole job (USD): "))
                 ("discuss" (read-string "Ask the reviewer: ")))))
      (drgnx-cockpit-cards--hub)
      (drgnx-hub-call "job/card" (list :card (plist-get card :id) :action action :arg arg)
                      (lambda (_r err)
                        (when err (message "drgnx: %s" err))
                        (drgnx-cockpit-cards--changed)
                        (when (and (not err) (equal action "discuss")) (drgnx-cockpit-cards--show-reviewer job (plist-get card :id))))))))

(defun drgnx-cockpit-cards--show-reviewer (job card)
  "Open the transcript of the reviewer on CARD of JOB (the hub says which session: the card's data)."
  (drgnx-hub-call "job/status" (list :id job)
                  (lambda (r err)
                    (let* ((c (seq-find (lambda (c) (equal (plist-get c :id) card)) (drgnx-cockpit-cards--v (plist-get r :cards))))
                           (sid (drgnx-cockpit-cards--v (plist-get (drgnx-cockpit-cards--v (plist-get c :data)) :reviewer))))
                      (cond (err (message "drgnx: %s" err))
                            (sid (drgnx-cockpit-cards--open-transcript sid t)))))))

(defun drgnx-cockpit-cards--open-transcript (id retry)
  "Show agent ID's transcript; one that is not mirrored here yet (a reviewer just started) is tried again once (RETRY)."
  (condition-case err (drgnx-cockpit-cards--transcript id)
    (user-error (if retry (run-at-time 1 nil #'drgnx-cockpit-cards--open-transcript id nil)
                  (message "drgnx: %s" (error-message-string err))))))

(defun drgnx-cockpit-cards--reply (message)
  (let ((text (read-string "Reply: ")))
    (drgnx-cockpit-cards--hub)
    (drgnx-hub-call "job/reply" (list :message message :text text)
                    (lambda (_r err) (when err (message "drgnx: %s" err)) (drgnx-cockpit-cards--changed)))))

(defun drgnx-cockpit-cards--dismiss (message)
  "MESSAGE needs no answer: acted on, so the parts and the badge stop showing it."
  (drgnx-cockpit-cards--hub)
  (drgnx-hub-call "job/dismiss" (list :message message)
                  (lambda (_r err)
                    (when err (message "drgnx: %s" err))
                    (drgnx-cockpit-cards--changed))))

(defun drgnx-cockpit-cards--open-tree (job repo)
  "JOB's worktree (its branch, job/JOB) of REPO in Dired."
  (if repo (dired (expand-file-name (format ".claude/worktrees/%s/" job) repo))
    (message "drgnx: the job's repository is not known yet")))

(defun drgnx-cockpit-cards--mirror (id)
  (require 'drgnx-agents-mirror)
  (or (drgnx-agents-mirror--find id) (user-error "Agent %s is not mirrored here (yet)" id)))

(defun drgnx-cockpit-cards--transcript (id)
  (require 'drgnx-agents-ui nil t)
  (drgnx-agents-ui-transcript (drgnx-cockpit-cards--mirror id)))

(defun drgnx-cockpit-cards--message (id)
  (drgnx-agents-send (drgnx-cockpit-cards--mirror id) (read-string (format "Message to %s: " id))))

;;;; The filter and showing the parts

(defun drgnx-cockpit-cards--set-job (job)
  "Filter the Work cockpit to JOB (nil: every job — the graph's other filter keys stay); the graph and the parts
follow."
  (setq drgnx-cockpit-graph-current-filter
        (if job (list :job job)
          (cl-loop for (k v) on drgnx-cockpit-graph-current-filter by #'cddr unless (eq k :job) append (list k v))))
  (when (fboundp 'drgnx-cockpit-schedule) (drgnx-cockpit-schedule 0))
  (drgnx-cockpit-cards--schedule 0))

(defun drgnx-cockpit-cards--job-node-p (node filter)
  "`drgnx-cockpit-filter-functions': with a `:job' in FILTER, only that job's nodes (their ancestors stay)."
  (let ((job (plist-get filter :job))) (or (null job) (equal (plist-get node :job) job))))

(defun drgnx-cockpit-cards--focus ()
  "Show what needs you and focus it (its pane, else any window); the hub's events wanted."
  (condition-case nil (progn (drgnx-cockpit-cards--hub) (drgnx-hub-connect)) (error nil))
  (if (drgnx-pane-kind 'needs-you) (drgnx-pane-focus 'needs-you) (pop-to-buffer (drgnx-cockpit-cards-buffer)))
  (drgnx-cockpit-cards--schedule 0))

(defun drgnx-cockpit-show-job (id)
  "Show the Work cockpit filtered to job ID: the Work layout when there is one, else the Work graph, and what needs
you, focused.  No frame is made: nil.  While a saved workbench is restored (`drgnx-persist-restoring': a job window
saved before M12f) only the filter is set — the restored panes, sizes and focus stay."
  (drgnx-cockpit-cards--set-job id)
  (unless (bound-and-true-p drgnx-persist-restoring)
    (if (and (fboundp 'drgnx-layouts-names) (memq 'work (drgnx-layouts-names)))
        (drgnx-layouts-apply 'work)
      (when (drgnx-pane-kind 'work-graph) (drgnx-pane-show 'work-graph)))
    (drgnx-cockpit-cards--focus))
  nil)

(defun drgnx-cockpit-show-jobs ()
  "Show what needs you of every job (the cockpit's job filter goes), and focus it.  The status bar's jobs segment."
  (interactive)
  (drgnx-cockpit-cards--set-job nil)
  (drgnx-cockpit-cards--focus)
  nil)

(defun drgnx-cockpit-decisions-show ()
  "Show the decision log of the job the Work cockpit is filtered to, and focus it."
  (interactive)
  (if (drgnx-pane-kind 'decisions) (drgnx-pane-focus 'decisions) (pop-to-buffer (drgnx-cockpit-decisions-buffer)))
  (drgnx-cockpit-cards--schedule 0))

;;;; The saved workbench

(defun drgnx-cockpit-cards--persist-state ()
  "`drgnx-persist-state-functions': the cockpit's filter (`:cockpit-filter'), kept with the saved workbench."
  (list :cockpit-filter drgnx-cockpit-graph-current-filter))

(defun drgnx-cockpit-cards--filter-p (f)
  "Whether F is a filter a saved workbench may set: a plist of :milestone, :agent and :job (strings) and :states (a
list of strings) — a state file can hold anything."
  (and (proper-list-p f) (cl-evenp (length f))
       (cl-loop for (k v) on f by #'cddr
                always (pcase k
                         ((or :milestone :agent :job) (or (null v) (stringp v)))
                         (:states (and (proper-list-p v) (seq-every-p #'stringp v)))))))

(defun drgnx-cockpit-cards--adopt (frame)
  "`drgnx-persist-after-restore-functions': the filter saved with FRAME's workbench comes back.  A workbench saved
without one (before M12f) leaves the filter as it is: a job window of that workbench may just have set it."
  (let ((extra (frame-parameter frame 'drgnx-persist-extra)))
    (when (and (proper-list-p extra) (cl-evenp (length extra)) (plist-member extra :cockpit-filter))
      (let ((f (plist-get extra :cockpit-filter)))
        (when (drgnx-cockpit-cards--filter-p f)
          (setq drgnx-cockpit-graph-current-filter f)
          (when (fboundp 'drgnx-cockpit-schedule) (drgnx-cockpit-schedule 0))
          (drgnx-cockpit-cards--schedule 0))))))

;;;; The module's part

(defun drgnx-cockpit-cards--setup ()
  "tools/cockpit's setup, the cards' part: the `needs-you' and `decisions' pane kinds, their commands, the job
filter of the graph, the filter in the saved workbench."
  (drgnx-pane-define-kind 'needs-you :title " NEEDS YOU" :home 'right :stack 'happened
                          :buffer #'drgnx-cockpit-cards-buffer :on-show #'drgnx-cockpit-cards--on-show)
  (drgnx-pane-define-kind 'decisions :title " DECISIONS" :home 'right :stack 'happened
                          :buffer #'drgnx-cockpit-decisions-buffer :on-show #'drgnx-cockpit-cards--on-show)
  (drgnx-command-define 'cockpit-needs-you :category "Work" :title "Show What Needs You" :command #'drgnx-cockpit-show-jobs
                        :doc "Every job's cards and messages to you, with their actions")
  (drgnx-command-define 'cockpit-decisions :category "Work" :title "Show Decisions" :command #'drgnx-cockpit-decisions-show
                        :doc "The decision log of the job the cockpit is filtered to")
  (add-hook 'drgnx-cockpit-filter-functions #'drgnx-cockpit-cards--job-node-p)
  (add-hook 'drgnx-persist-state-functions #'drgnx-cockpit-cards--persist-state)
  (add-hook 'drgnx-persist-after-restore-functions #'drgnx-cockpit-cards--adopt))

(defun drgnx-cockpit-cards--teardown ()
  "Undo the cards' part of the module: take out the three global hook functions `drgnx-cockpit-cards--setup' added,
kill both parts (the last one's `kill-buffer-hook' takes out the hub hooks and cancels the timers; done here too, in
case no part lives) and forget nothing else — the filter is the graph's.  Idempotent."
  (remove-hook 'drgnx-cockpit-filter-functions #'drgnx-cockpit-cards--job-node-p)
  (remove-hook 'drgnx-persist-state-functions #'drgnx-cockpit-cards--persist-state)
  (remove-hook 'drgnx-persist-after-restore-functions #'drgnx-cockpit-cards--adopt)
  (mapc #'kill-buffer (drgnx-cockpit-cards--buffers))
  (remove-hook 'drgnx-hub-event-functions #'drgnx-cockpit-cards--hub-event)
  (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-cockpit-cards--hub-gone)
  (dolist (tm (list drgnx-cockpit-cards--timer drgnx-cockpit-cards--retry)) (when (timerp tm) (cancel-timer tm)))
  (setq drgnx-cockpit-cards--timer nil drgnx-cockpit-cards--retry nil drgnx-cockpit-cards--stale nil))

(provide 'drgnx-cockpit-cards)
;;; drgnx-cockpit-cards.el ends here
