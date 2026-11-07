;;; drgnx-agents-session.el --- Module tools/agents: the hub's sessions in this Emacs, and the commands that start them -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What the agent panel (tools/agent-panel) does not own: mirroring the hub's sessions once Emacs is idle (they outlive
;; this Emacs), starting a session (in this Emacs, or durable in the hub), answering what an agent asks, and a durable
;; job's log and stop.  The Agents list and every session's view are the panel's.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-agents)
(require 'drgnx-exec)

(declare-function drgnx-agents-mirror-sync "drgnx-agents-mirror")
(declare-function drgnx-agents-mirror-start "drgnx-agents-mirror")
(declare-function drgnx-agents-mirror-stop "drgnx-agents-mirror")
(declare-function drgnx-hub-socket "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-disconnect "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function project-root "project")
(defvar drgnx-hub--events)
(defvar drgnx-agents--attention-seen)

(defun drgnx-agents-session-pick (&optional prompt)
  "A live session: the only one, else the one chosen by name."
  (let ((live (drgnx-agents-sessions)))
    (cond ((null live) (user-error "No agent session (Agents: New Agent Session)"))
          ((null (cdr live)) (car live))
          (t (let ((name (completing-read (or prompt "Session: ") (mapcar #'drgnx-agent-session-name live) nil t)))
               (seq-find (lambda (s) (equal (drgnx-agent-session-name s) name)) live))))))

(defun drgnx-agents-session--cwd ()
  (or (when-let* ((p (and (fboundp 'project-current) (project-current)))) (project-root p)) default-directory))

(defun drgnx-agents-session--maybe-mirror ()
  "At idle: mirror the hub's agent sessions when a hub runs.  Never waits and never starts one: only a socket that
exists is connected to (asynchronously)."
  (require 'drgnx-hub-client)
  (when (and (file-exists-p (drgnx-hub-socket)) (not (process-live-p (bound-and-true-p drgnx-hub--events))))
    (require 'drgnx-agents-mirror)
    (with-demoted-errors "drgnx: the agent hub does not answer: %S" (drgnx-agents-mirror-sync))))

(defun drgnx-agents-session-new-durable (profile)
  "Start an agent session of PROFILE in this project, held by the hub: it keeps working when Emacs closes."
  (interactive (list (completing-read "Durable agent profile: " (drgnx-agents-profile-names) nil t nil nil (drgnx-agents-default-profile))))
  (require 'drgnx-agents-mirror)
  (drgnx-hub-ensure)
  (drgnx-agents-mirror-sync)
  (let ((r (drgnx-hub-call-sync "agents/start" (list :profile profile :cwd (drgnx-agents-session--cwd)))))
    (message "Agent %s started in the hub (it keeps working when Emacs closes)" (plist-get r :name))))

(defun drgnx-agents-session-new (profile)
  "Start an agent session of PROFILE in this project and open its panel."
  (interactive (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t nil nil (drgnx-agents-default-profile))))
  (require 'drgnx-agents-mirror)
  (let ((s (drgnx-agents-mirror-start profile (drgnx-agents-session--cwd))))
    (when-let* ((id (drgnx-agent-session-remote s))) (drgnx-agent-panel-open id))))

(defun drgnx-agents-session-answer ()
  "Answer what an agent asks (permission to run a tool)."
  (interactive)
  (let* ((s (drgnx-agents-session-pick)) (p (or (car (drgnx-agent-session-permissions s)) (user-error "Nothing to answer")))
         (choice (completing-read (format "%s: " (plist-get p :title)) (mapcar (lambda (o) (plist-get o :name)) (plist-get p :options)) nil t)))
    (drgnx-agents-answer-permission s p (plist-get (seq-find (lambda (o) (equal (plist-get o :name) choice)) (plist-get p :options)) :optionId))))

(defun drgnx-agents-session-job-log (id)
  "Show durable job ID's log."
  (interactive (list (completing-read "Job: " (mapcar (lambda (j) (plist-get j :id)) (drgnx-exec-list)) nil t)))
  (with-current-buffer (get-buffer-create (format "*job: %s*" id))
    (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-exec-log id 20000)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(defun drgnx-agents-session-job-stop (id)
  "Stop durable job ID."
  (interactive (list (completing-read "Stop job: " (mapcar (lambda (j) (plist-get j :id))
                                                           (seq-filter (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-exec-list)))
                                      nil t)))
  (drgnx-exec-stop id))

(defun drgnx-agents-session--teardown ()
  "Turned off: the hub's sessions are mirrored no more and the hub's event connection closes.  `agents' is a core
notice source, so its set is emptied: what waits there cannot be answered once the commands are gone."
  (when (featurep 'drgnx-agents-mirror) (drgnx-agents-mirror-stop))
  (when (featurep 'drgnx-hub-client) (drgnx-hub-disconnect))
  (setq drgnx-agents--attention-seen nil)
  (drgnx-notice-set 'agents nil))

(drgnx-module-define 'tools/agents
                     :doc "Agents: the hub's sessions in this Emacs, starting a session, answering, durable job logs."
                     :stage 'startup :requires '(core/workbench)
                     :teardown #'drgnx-agents-session--teardown
                     :setup
                     (lambda ()
                       ;; the hub's sessions (they outlive this Emacs), once Emacs is idle; again later, so a hub
                       ;; started (or restarted) since is picked up
                       (drgnx-timer-start 'agents-ui-mirror-first 3 #'drgnx-agents-session--maybe-mirror :idle t)
                       (drgnx-timer-start 'agents-ui-mirror 30 #'drgnx-agents-session--maybe-mirror :repeat t :idle t)
                       (when (fboundp 'drgnx-wb-place) (drgnx-wb-place "\\`\\*job: " 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((agents-new "New Agent Session…" drgnx-agents-session-new "Start an agent (a profile) in this project")
                                        (agents-new-durable "New Durable Agent Session…" drgnx-agents-session-new-durable
                                                            "An agent held by the hub: it keeps working when Emacs closes")
                                        (agents-answer "Answer Agent…" drgnx-agents-session-answer "Allow or reject what the agent asks")
                                        (jobs-log "Show Job Log…" drgnx-agents-session-job-log "A durable job's output")
                                        (jobs-stop "Stop Job…" drgnx-agents-session-job-stop "Stop a durable job")))
                         (drgnx-command-define id :category "Agents" :title title :command fn :doc doc))))

(provide 'drgnx-agents-session)
;;; drgnx-agents-session.el ends here
