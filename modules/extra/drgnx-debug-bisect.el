;;; drgnx-debug-bisect.el --- Which change broke it: bisect over the edit history -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of bisect over the edit history (docs/guide/debugging.md, "Which change broke it";
;; docs/develop/debugging.md).  The user picks a good state (a commit, a recorded run's launch, a save or an agent's
;; step) and a command that fails now; the hub runs it over the states in between, a few at once, and names the first
;; bad one with who made it.  The card is the hub's rows (`debug-bisect' events, docs/develop/hub.md "Rows"); this file
;; only inserts them and runs the card's actions: Show Step (the change, as a diff), Revert Step (the revert card of the
;; step before it: nothing changes until its Apply), Ask the Agent (a message to the session that made it), Narrow
;; (the hunks that make it fail) and Cancel.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-faces)
(require 'drgnx-timer)
(require 'drgnx-debug-launch (expand-file-name "drgnx-debug-launch" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(declare-function drgnx-history-revert-to-here "drgnx-history-revert" (&optional session seq))
(declare-function drgnx-agents-get "drgnx-agents" (id))
(declare-function drgnx-agents-send "drgnx-agents" (s text))
(defvar drgnx-hub-event-functions)

(defface drgnx-debug-bisect-good '((t :inherit drgnx-status-ok)) "A state the predicate passed." :group 'drgnx)
(defface drgnx-debug-bisect-bad '((t :inherit drgnx-status-fail)) "A state the predicate failed." :group 'drgnx)
(defface drgnx-debug-bisect-skip '((t :inherit drgnx-text-muted)) "A state that could not be judged." :group 'drgnx)

(defconst drgnx-debug-bisect-buffer "*drgnx-debug bisect*" "The bisect's card.")
(defconst drgnx-debug-bisect-step-buffer "*drgnx-debug bisect step*" "The first bad state's change.")

(defvar drgnx-debug-bisect--id nil "The bisect the card follows (its id).")
(defvar drgnx-debug-bisect--argv nil "Its predicate's command, for the agent's message.")
(defvar drgnx-debug-bisect--rows nil "The card's newest rows (the hub's), drawn soon.")
(defvar drgnx-debug-bisect--result nil "Its result, once found (`debug-bisect''s `result').")

(defvar drgnx-debug-bisect-card-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-debug-bisect-click)
    m)
  "The card's mouse: a click on an action runs it.  Its keys come from the key profiles (`:map
drgnx-debug-bisect-card-mode-map').")

(define-derived-mode drgnx-debug-bisect-card-mode special-mode "Bisect"
  "The card of a bisect over the edit history."
  :group 'drgnx
  (setq-local truncate-lines t)
  (buffer-disable-undo))

(defun drgnx-debug-bisect--good-of (id)
  "The good state (`debug/bisect''s `good') a state ID names, or nil (now is never good)."
  (cond ((string-prefix-p "commit-" id) (list :kind "commit" :id (substring id 7)))
        ((string-prefix-p "run-" id) (list :kind "run" :id (substring id 4)))
        ((string-prefix-p "record-" id) (list :kind "record" :id (substring id 7)))))

(defun drgnx-debug-bisect--ask ()
  "Read a good state and a failing command: `drgnx-debug-bisect''s arguments."
  (let* ((root (drgnx-debug-launch-root))
         (states (plist-get (drgnx-hub-call-sync "debug/bisect/states" (list :root root) 15) :states))
         (choices (seq-keep (lambda (s)
                              (when (drgnx-debug-bisect--good-of (plist-get s :id))
                                (cons (format "%s · %s · %s" (plist-get s :label)
                                              (string-replace "_" " " (plist-get s :kind))
                                              (format-time-string "%F %R" (plist-get s :at)))
                                      (plist-get s :id))))
                            (reverse (append states nil)))))
    (unless choices (user-error "Nothing to bisect: no commit, run, save or agent step in %s" root))
    (let* ((pick (completing-read "Good state (it worked here): " choices nil t))
           (cmd (read-shell-command "Fails now (exit 0 good, 125 skip, 1–127 bad): ")))
      (list (drgnx-debug-bisect--good-of (cdr (assoc pick choices))) (split-string-and-unquote cmd)))))

(defun drgnx-debug-bisect (good argv)
  "Which change broke it: run ARGV (it fails now) over the project's states after GOOD.
GOOD is a commit, a recorded run's launch, a save or an agent's step (`(:kind KIND :id ID)'); the hub re-checks it,
then finds the first state where ARGV fails, a few at once, and names who made it."
  (interactive (drgnx-debug-bisect--ask))
  (drgnx-hub-call "debug/bisect" (list :root (drgnx-debug-launch-root) :good good
                                       :predicate (list :kind "test" :argv (vconcat argv)))
                  (lambda (result error)
                    (if error (message "Bisect: %s" (or (plist-get error :message) error))
                      (let ((est (plist-get result :estimate)))
                        (setq drgnx-debug-bisect--id (plist-get result :bisect) drgnx-debug-bisect--argv argv
                              drgnx-debug-bisect--result nil
                              drgnx-debug-bisect--rows
                              (vector (list :key "head"
                                            :text (format "Bisect · %d states · about %d runs in %d slots · starting"
                                                          (plist-get est :states) (plist-get est :runs)
                                                          (plist-get est :slots)))))
                        (drgnx-debug-bisect--render)
                        (display-buffer drgnx-debug-bisect-buffer))))))

(defun drgnx-debug-bisect--render ()
  "Insert the card's rows (`drgnx-debug-bisect--rows') in its buffer."
  (with-current-buffer (get-buffer-create drgnx-debug-bisect-buffer)
    (unless (derived-mode-p 'drgnx-debug-bisect-card-mode) (drgnx-debug-bisect-card-mode))
    (let ((inhibit-read-only t) (at (point)))
      (erase-buffer)
      (seq-doseq (row drgnx-debug-bisect--rows)
        (insert (drgnx-debug-timeline--row-string row) "\n"))
      (goto-char (min at (point-max))))))

(defun drgnx-debug-bisect--event (event data)
  "`drgnx-hub-event-functions': the bisect the card follows moved on (`debug-bisect')."
  (when (and (equal event "debug-bisect") drgnx-debug-bisect--id
             (equal (plist-get data :bisect) drgnx-debug-bisect--id))
    (when-let* ((r (plist-get data :result))) (setq drgnx-debug-bisect--result r))
    (when-let* ((rows (plist-get data :rows))) (setq drgnx-debug-bisect--rows rows))
    (drgnx-timer-soon 'debug-bisect 0.05 #'drgnx-debug-bisect--render :min-interval 0.1)))

;;;; The card's actions

(defun drgnx-debug-bisect--bad ()
  "The first bad state, or a user error."
  (or (plist-get drgnx-debug-bisect--result :first_bad) (user-error "The bisect has not found the change yet")))

(defun drgnx-debug-bisect-show-step ()
  "Show the change the first bad state made, as a diff."
  (interactive)
  (drgnx-debug-bisect--bad)
  (with-current-buffer (get-buffer-create drgnx-debug-bisect-step-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (or (plist-get drgnx-debug-bisect--result :diff) "")))
    (diff-mode)
    (setq buffer-read-only t)
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(defun drgnx-debug-bisect--agent-step ()
  "The first bad state's session and step number, or a user error (it is not an agent's step)."
  (let* ((bad (drgnx-debug-bisect--bad)) (s (plist-get bad :session)) (step (plist-get bad :step)))
    (unless (and s step) (user-error "The change is not an agent's step"))
    (list s (string-to-number step))))

(defun drgnx-debug-bisect-revert-step ()
  "Open the revert card of the step that broke it (the work back to the step before); nothing changes until Apply."
  (interactive)
  (pcase-let ((`(,s ,n) (drgnx-debug-bisect--agent-step)))
    (require 'drgnx-history-revert)
    (drgnx-history-revert-to-here s (1- n))))

(defun drgnx-debug-bisect-ask-agent ()
  "Tell the agent that made the breaking step what broke (queued if it is busy)."
  (interactive)
  (pcase-let* ((`(,id ,n) (drgnx-debug-bisect--agent-step))
               (s (and (fboundp 'drgnx-agents-get) (drgnx-agents-get id))))
    (unless s (user-error "The session that made it is not running"))
    (drgnx-agents-send s (format "A bisect found that your step %d (%s) broke it: `%s' passes before it and fails from it. \
Please look at that change." n (plist-get (drgnx-debug-bisect--bad) :label)
(mapconcat #'shell-quote-argument drgnx-debug-bisect--argv " ")))
    (message "Asked the agent")))

(defun drgnx-debug-bisect-narrow ()
  "Narrow the breaking change to the hunks that make it fail."
  (interactive)
  (drgnx-debug-bisect--bad)
  (drgnx-hub-call "debug/bisect/narrow" (list :bisect drgnx-debug-bisect--id)
                  (lambda (_ error) (when error (message "Narrow: %s" (or (plist-get error :message) error))))))

(defun drgnx-debug-bisect-cancel ()
  "Stop the bisect and its runs."
  (interactive)
  (unless drgnx-debug-bisect--id (user-error "No bisect"))
  (drgnx-hub-call "debug/bisect/cancel" (list :bisect drgnx-debug-bisect--id) #'ignore))

(defun drgnx-debug-bisect-act ()
  "Run the card's action at point."
  (interactive)
  (pcase (get-text-property (point) 'drgnx-debug-bisect-action)
    ("show" (drgnx-debug-bisect-show-step))
    ("revert" (drgnx-debug-bisect-revert-step))
    ("ask" (drgnx-debug-bisect-ask-agent))
    ("narrow" (drgnx-debug-bisect-narrow))
    ("cancel" (drgnx-debug-bisect-cancel))
    (_ (user-error "No action here"))))

(defun drgnx-debug-bisect-click (event)
  "Run the card's action under EVENT."
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    (when pos (goto-char pos) (drgnx-debug-bisect-act))))

;;;; On and off

(define-minor-mode drgnx-debug-bisect-events-mode
  "Bisect over the edit history in the editor: the hub's `debug-bisect' events draw the card."
  :global t :group 'drgnx
  (if drgnx-debug-bisect-events-mode
      (add-hook 'drgnx-hub-event-functions #'drgnx-debug-bisect--event)
    (remove-hook 'drgnx-hub-event-functions #'drgnx-debug-bisect--event)
    (drgnx-timer-cancel 'debug-bisect)
    (dolist (name (list drgnx-debug-bisect-buffer drgnx-debug-bisect-step-buffer))
      (when-let* ((b (get-buffer name))) (kill-buffer b)))
    (setq drgnx-debug-bisect--id nil drgnx-debug-bisect--argv nil drgnx-debug-bisect--rows nil
          drgnx-debug-bisect--result nil)))

(defconst drgnx-debug-bisect-commands
  '((debug-bisect "Find the Change That Broke It…" drgnx-debug-bisect "Run a failing command over the edit history to name the first bad state")
    (debug-bisect-act "Run Bisect Action" drgnx-debug-bisect-act "Run the bisect card's action at point")
    (debug-bisect-show-step "Show the Breaking Change" drgnx-debug-bisect-show-step "The change the first bad state made, as a diff")
    (debug-bisect-revert-step "Revert the Breaking Step…" drgnx-debug-bisect-revert-step "Open the revert card of the agent's step that broke it")
    (debug-bisect-ask-agent "Ask the Agent About the Breaking Step" drgnx-debug-bisect-ask-agent "Tell the agent which step broke it")
    (debug-bisect-narrow "Narrow the Breaking Change" drgnx-debug-bisect-narrow "The hunks of the change that make it fail")
    (debug-bisect-cancel "Cancel Bisect" drgnx-debug-bisect-cancel "Stop the bisect and its runs"))
  "The commands of bisect over the edit history: (ID TITLE FUNCTION DOC).")

(provide 'drgnx-debug-bisect)
;;; drgnx-debug-bisect.el ends here
