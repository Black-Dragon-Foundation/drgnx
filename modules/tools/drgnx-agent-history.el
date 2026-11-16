;;; drgnx-agent-history.el --- past sessions of Claude Code, Gemini CLI and Codex: list, search, read, resume -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module tools/agent-panel.  Past Sessions lists the sessions your other agent CLIs left in their own folders
;; (Claude Code, Gemini CLI, Codex), this workspace's first.  The hub reads those files read-only and indexes them on
;; this machine (`agents/history/*'); the list and each transcript are hub-fed views, so this file only asks and
;; shows.  RET opens a session's transcript read-only; Resume Here continues it as a drgnx agent (on a copy of its file,
;; or writing that one original file: you choose each time); Resume in Terminal runs the CLI's own resume command in a
;; drgnx terminal.  Off with `drgnx-agents-history'.  See docs/guide/agents.md, "Past sessions".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)
(require 'drgnx-modules)
(require 'drgnx-notice)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(defvar drgnx-hub--events)
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-term-start "drgnx-term")
(declare-function drgnx-wb-area-show "drgnx-wb")
(declare-function project-root "project")
(defvar drgnx-agents-history-resume-writes-original)

(defconst drgnx-agent-history-buffer-name "*drgnx Past Sessions*")

(defconst drgnx-agent-history-view "agents-past"
  "The list's hub view (a transcript's is the `agent-history/PROVIDER:ID' that `agents/history/open' answers).")

(defconst drgnx-agent-history-section-view "agents-list-past"
  "The hub view of the Agents list's Past sessions section (`drgnx-agent-panel-list').")

(defvar-local drgnx-agent-history--view nil
  "In a buffer that shows past sessions as a hub view: that view (the list's, or the Agents list's section).")
(defvar-local drgnx-agent-history--limit nil "In a section of another list: how many sessions it shows.")
(defvar-local drgnx-agent-history--workspace nil "The folder whose sessions the list shows first.")
(defvar-local drgnx-agent-history--query nil "What the list is narrowed to, or nil.")
(defvar-local drgnx-agent-history--opened nil
  "In a transcript: `agents/history/open''s answer (:view :session :argv :resume_here).")

;;;; The list

(defvar drgnx-agent-history-mode-map (make-sparse-keymap) "Keys come from the key profiles (commands `sessions-*').")

(define-derived-mode drgnx-agent-history-mode special-mode "Past Sessions"
  "Your past Claude Code, Gemini CLI and Codex sessions, this workspace's first: RET opens one read-only."
  (setq-local truncate-lines t))

(defvar drgnx-agent-history-transcript-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-agent-history-mode-map) m)
  "The list's keys: on a transcript they act on its session.")

(define-derived-mode drgnx-agent-history-transcript-mode special-mode "Past Session"
  "A past session's transcript, read-only: Resume Here continues it as a drgnx agent, Resume in Terminal in its CLI."
  (setq-local truncate-lines nil))

(defun drgnx-agent-history--call (method params callback)
  "Ask the hub METHOD with PARAMS on this Emacs's subscribed connection: the hub sends a view's rows to the connection
that asked, the one its env went on.  Signals while that connection is down: the view asks again when it is up (its
env's resubscribe)."
  (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
  (unless (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (user-error "The drgnx hub is not connected"))
  (drgnx-hub--call-on drgnx-hub--events method params callback))

(defun drgnx-agent-history--asker (view)
  "The buffer that shows past sessions as hub VIEW (default: the Past Sessions list), or nil."
  (let ((view (or view drgnx-agent-history-view)))
    (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-agent-history--view b) view)) (buffer-list))))

(defun drgnx-agent-history--ask (&optional view)
  "Ask the hub for the rows of VIEW (default: the Past Sessions list), again after a reconnect: the env's
resubscribe."
  (when-let* ((b (drgnx-agent-history--asker view)))
    (with-current-buffer b
      (drgnx-agent-history--call "agents/history/subscribe"
                                 (append (list :view drgnx-agent-history--view)
                                         (and drgnx-agent-history--workspace (list :workspace drgnx-agent-history--workspace))
                                         (and drgnx-agent-history--query (list :query drgnx-agent-history--query))
                                         (and drgnx-agent-history--limit (list :limit drgnx-agent-history--limit)))
                                 #'drgnx-agent-history--asked))))

(defun drgnx-agent-history--asked (on error)
  "The hub's answer to the list's subscribe: ON nil means past sessions are off."
  (cond (error (drgnx-notify 'agents 'warn (format "Past sessions: %s" error) :id 'past-sessions))
        ((not on) (drgnx-notify 'agents 'info "Past sessions are off (drgnx-agents-history)" :id 'past-sessions
                                :life 'event))))

(defun drgnx-agent-history--twin (class)
  "The list's or a transcript's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-agent-history-")))

(defun drgnx-agent-history--attach (view resubscribe)
  "Make the current buffer the hub-fed VIEW; RESUBSCRIBE asks for it again after a reconnect."
  (drgnx-view-patch-attach view "unshown" :sja t)
  (setq-local drgnx-view-patch-twin-function #'drgnx-agent-history--twin)
  (require 'drgnx-view-env)
  (drgnx-view-env-register view (current-buffer) resubscribe))

(defun drgnx-agent-history--workspace-root ()
  "The folder of the current buffer's project, or its directory."
  (expand-file-name (or (and (require 'project nil t) (fboundp 'project-current)
                             (when-let* ((p (project-current))) (project-root p)))
                        default-directory)))

(defun drgnx-agent-history-buffer ()
  "The Past Sessions list, asked of the hub."
  (let ((workspace (drgnx-agent-history--workspace-root))
        (b (get-buffer-create drgnx-agent-history-buffer-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agent-history-mode)
        (drgnx-agent-history-mode)
        (setq drgnx-agent-history--view drgnx-agent-history-view)
        (drgnx-agent-history--attach drgnx-agent-history-view #'drgnx-agent-history--ask))
      (setq drgnx-agent-history--workspace (directory-file-name workspace)))
    (drgnx-agent-history--ask)
    b))

(defun drgnx-agent-history-section (limit)
  "Make the current buffer, which keeps a view of its own, also ask for the Past sessions section: at most LIMIT
sessions, the workspace's first (`agents/history/subscribe' with :limit).  The buffer places the hub's rows itself
\(`drgnx-view-patch-apply-function'); returns the section's view."
  (setq drgnx-agent-history--view drgnx-agent-history-section-view
        drgnx-agent-history--limit limit
        drgnx-agent-history--workspace (directory-file-name (drgnx-agent-history--workspace-root)))
  (drgnx-view-patch-attach drgnx-agent-history-section-view "unshown" :keep t)
  (require 'drgnx-view-env)
  (drgnx-view-env-register drgnx-agent-history-section-view (current-buffer) #'drgnx-agent-history--ask)
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-agent-history--ask drgnx-agent-history-section-view))
  drgnx-agent-history-section-view)

(defun drgnx-agent-history-show ()
  "Show your past Claude Code, Gemini CLI and Codex sessions in the right dock, this workspace's first."
  (interactive)
  (let ((b (drgnx-agent-history-buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'agents b) (pop-to-buffer b))))

(defun drgnx-agent-history-search (query)
  "Narrow the past sessions to those whose title or transcript holds every word of QUERY (empty: all of them): in
the Agents list its Past sessions section, elsewhere Past Sessions."
  (interactive (list (read-string "Search past sessions: "
                                  (let ((b (if (equal drgnx-agent-history--view drgnx-agent-history-section-view)
                                               (current-buffer)
                                             (get-buffer drgnx-agent-history-buffer-name))))
                                    (and b (buffer-local-value 'drgnx-agent-history--query b))))))
  (let* ((section (equal drgnx-agent-history--view drgnx-agent-history-section-view))
         (b (if section (current-buffer) (drgnx-agent-history-buffer))))
    (with-current-buffer b
      (setq drgnx-agent-history--query (and (not (string-blank-p query)) query))
      (drgnx-agent-history--ask drgnx-agent-history--view))
    (when (and (not section) (called-interactively-p 'any)) (drgnx-agent-history-show))))

(defun drgnx-agent-history--at-point ()
  "The past session at point, (:provider P :id ID), or in a transcript its own; else a `user-error'."
  (or (and drgnx-agent-history--opened
           (let ((s (plist-get drgnx-agent-history--opened :session)))
             (list :provider (plist-get s :provider) :id (plist-get s :id))))
      (get-text-property (line-beginning-position) 'drgnx-past)
      (get-text-property (point) 'drgnx-past)
      (user-error "No past session on this line")))

;;;; A transcript

(defun drgnx-agent-history--transcript-name (session)
  (format "*%s: %s*" (capitalize (plist-get session :provider)) (string-limit (plist-get session :title) 40)))

(defun drgnx-agent-history--opened (opened)
  "Show OPENED, `agents/history/open''s answer: the transcript's buffer, read-only, made when there is none."
  (let* ((view (plist-get opened :view))
         (b (or (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-agent-history--opened b) opened))
                          (buffer-list))
                (generate-new-buffer (drgnx-agent-history--transcript-name (plist-get opened :session))))))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agent-history-transcript-mode)
        (drgnx-agent-history-transcript-mode)
        (setq drgnx-agent-history--opened opened)
        (drgnx-agent-history--attach view #'drgnx-agent-history--reopen)))
    (pop-to-buffer b)
    b))

(defun drgnx-agent-history--reopen (_view)
  "A transcript's resubscribe: open it again (a new hub reads the file again)."
  (dolist (b (buffer-list))
    (when-let* ((o (buffer-local-value 'drgnx-agent-history--opened b)))
      (let ((s (plist-get o :session)))
        (drgnx-agent-history--call "agents/history/open" (list :provider (plist-get s :provider) :id (plist-get s :id)) #'ignore)))))

(defun drgnx-agent-history-open (&optional session)
  "Open SESSION (default: the one at point) read-only, as the agent panel shows a transcript."
  (interactive)
  (let ((s (or session (drgnx-agent-history--at-point))))
    (drgnx-agent-history--call "agents/history/open" (list :provider (plist-get s :provider) :id (plist-get s :id))
                               (lambda (opened error)
                                 (if error
                                     (drgnx-notify 'agents 'warn (format "Past session: %s" error) :id 'past-sessions
                                                   :life 'event)
                                   (drgnx-agent-history--opened opened))))))

;;;; Resuming

(defconst drgnx-agent-history-routes
  '(("On a copy (your CLI does not see the continuation)" . copy)
    ("Write the original (lets the jailed agent write this one CLI session file)" . original))
  "Resume Here's two ways in, as offered.")

(defun drgnx-agent-history-read-route ()
  "Ask which way Resume Here goes in; `drgnx-agents-history-resume-writes-original' picks the default."
  (let* ((default (car (rassq (if drgnx-agents-history-resume-writes-original 'original 'copy) drgnx-agent-history-routes)))
         (pick (completing-read (format "Resume here (default %s): " default)
                                (mapcar #'car drgnx-agent-history-routes) nil t nil nil default)))
    (cdr (assoc pick drgnx-agent-history-routes))))

(defun drgnx-agent-history-resume (route &optional session)
  "Continue SESSION (default: the one at point) as a drgnx agent in its folder, jailed, by ROUTE: `copy' (a copy of
its file in the jail) or `original' (the jail may write that one file, so your CLI sees the continuation)."
  (interactive (list (drgnx-agent-history-read-route)))
  (let ((s (or session (drgnx-agent-history--at-point))))
    (drgnx-hub-call "agents/history/resume"
                    (list :provider (plist-get s :provider) :id (plist-get s :id) :route (symbol-name route))
                    (lambda (resumed error)
                      (if error
                          (drgnx-notify 'agents 'warn (format "Resume: %s" error) :id 'past-sessions :life 'event)
                        (drgnx-agent-panel-open (plist-get resumed :session)))))))

(defun drgnx-agent-history-resume-command (opened)
  "The terminal's (DIRECTORY . ARGV) for OPENED (`agents/history/open''s answer), or a `user-error'."
  (let ((argv (append (plist-get opened :argv) nil))
        (cwd (plist-get (plist-get opened :session) :cwd)))
    (unless argv (user-error "That CLI has no resume command"))
    (cons (if (and cwd (file-directory-p cwd)) cwd (user-error "The session's folder is gone: %s" (or cwd "unknown")))
          argv)))

(defun drgnx-agent-history-resume-in-terminal (&optional session)
  "Run the CLI's own resume command for SESSION (default: the one at point) in a drgnx terminal in its folder,
outside the jail: the CLI continues its own file."
  (interactive)
  (unless (fboundp 'drgnx-term-start) (user-error "The terminal is not available (module tools/term is off)"))
  (let ((s (or session (drgnx-agent-history--at-point))))
    (drgnx-hub-call "agents/history/open" (list :provider (plist-get s :provider) :id (plist-get s :id))
                    (lambda (opened error)
                      (if error
                          (drgnx-notify 'agents 'warn (format "Past session: %s" error) :id 'past-sessions :life 'event)
                        (let ((c (drgnx-agent-history-resume-command opened)))
                          (drgnx-term-start (car c) (cdr c))))))))

(defun drgnx-agent-history-rescan ()
  "Read the CLIs' folders again now (the hub also does, every few seconds)."
  (interactive)
  (drgnx-hub-call "agents/history/rescan" nil
                  (lambda (r error)
                    (drgnx-notify 'agents (if error 'warn 'info)
                                  (if error (format "Rescan: %s" error)
                                    (format "Past sessions: %d indexed" (plist-get r :sessions)))
                                  :id 'past-sessions :life 'event))))

;;;; Setup

(defun drgnx-agent-history-setup ()
  "Called by tools/agent-panel's setup."
  (drgnx-command-define 'sessions-view :category "Agents" :title "Show Past Sessions" :command #'drgnx-agent-history-show
                        :doc "Your past Claude Code, Gemini CLI and Codex sessions, this workspace's first")
  (drgnx-command-define 'sessions-search :category "Agents" :title "Search Past Sessions…"
                        :command #'drgnx-agent-history-search :map 'drgnx-agent-history-mode-map
                        :doc "Narrow Past Sessions to those holding every word you type")
  (drgnx-command-define 'sessions-open :category "Agents" :title "Open Past Session" :command #'drgnx-agent-history-open
                        :map 'drgnx-agent-history-mode-map :doc "The transcript of the past session on this line, read-only")
  (drgnx-command-define 'sessions-resume :category "Agents" :title "Resume Past Session Here…"
                        :command #'drgnx-agent-history-resume :map 'drgnx-agent-history-mode-map
                        :doc "Continue the past session as a drgnx agent, on a copy of its file or writing the original")
  (drgnx-command-define 'sessions-resume-in-terminal :category "Agents" :title "Resume Past Session in Terminal"
                        :command #'drgnx-agent-history-resume-in-terminal :map 'drgnx-agent-history-mode-map
                        :doc "Run the CLI's own resume command for the past session in a terminal")
  (drgnx-command-define 'sessions-rescan :category "Agents" :title "Rescan Past Sessions"
                        :command #'drgnx-agent-history-rescan :map 'drgnx-agent-history-mode-map
                        :doc "Read the CLIs' session folders again now"))

(defun drgnx-agent-history-teardown ()
  "Called by tools/agent-panel's teardown: the list and the transcripts go."
  (dolist (b (buffer-list))
    (when (memq (buffer-local-value 'major-mode b) '(drgnx-agent-history-mode drgnx-agent-history-transcript-mode))
      (kill-buffer b))))

(provide 'drgnx-agent-history)
;;; drgnx-agent-history.el ends here
