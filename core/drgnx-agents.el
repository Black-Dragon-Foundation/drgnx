;;; drgnx-agents.el --- Agent sessions over ACP: transcript, input that queues, Stop, permissions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A session is one ACP agent process (a profile: command and environment) working in a directory.
;; Its transcript is a list of entries — user, agent, thought, tool (with children: subagents), plan —
;; built from the agent's updates.  Sending never cancels: to a busy session a message is queued
;; (delivered once, in order, when the turn ends), or steers the running turn when the profile says
;; `steer' and the agent supports it; only Stop cancels (the turn ends within a second; pending
;; permission requests are answered "cancelled"; the queue waits).  An agent's questions — may I run
;; this? may I write that file? — become pending items for the viewer: nothing here ever asks.
;; See docs/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-acp)

(cl-defstruct (drgnx-agent-session (:constructor drgnx-agents--make) (:copier nil))
  name profile cwd conn acp-id (status 'starting) entries queue (mode 'queue) capabilities usage commands
  permissions reviews stderr exit stopping paused)

(defvar drgnx-agents-profiles nil
  "Alist NAME → plist (:command LIST :env (\"NAME=value\"…) :mode queue|steer|interrupt).  Read from
agents.eld (config dir) and the built-in ones; never holds secrets (keys come from the environment).")

(defvar drgnx-agents--sessions nil "Live and finished sessions, newest first.")

(defvar drgnx-agents-changed-functions nil
  "Called with a session whenever it changes (status, transcript, queue, pending items).")

(defconst drgnx-agents-builtin-profiles
  '(("claude" :command ("claude-agent-acp") :mode queue :doc "Claude through the unmodified agent (subscription or API key)")))

(defun drgnx-agents-profile (name)
  (or (assoc name drgnx-agents-profiles)
      (assoc name (plist-get (drgnx-agents--read-file) :profiles))
      (assoc name drgnx-agents-builtin-profiles)
      (user-error "No agent profile %s" name)))

(defun drgnx-agents--read-file ()
  (let ((f (expand-file-name "agents.eld" (drgnx-user-dir))))
    (and (file-readable-p f) (ignore-errors (with-temp-buffer (insert-file-contents f) (read (current-buffer)))))))

(defun drgnx-agents-profile-names ()
  (delete-dups (mapcar #'car (append drgnx-agents-profiles (plist-get (drgnx-agents--read-file) :profiles)
                                     drgnx-agents-builtin-profiles))))

(defun drgnx-agents--changed (s) (run-hook-with-args 'drgnx-agents-changed-functions s))

;;;; Transcript

(defun drgnx-agents--add (s entry)
  (setf (drgnx-agent-session-entries s) (append (drgnx-agent-session-entries s) (list entry))))

(defun drgnx-agents--append-text (s type text)
  "Add TEXT to the last entry when it is of TYPE (a streamed chunk), else start an entry."
  (let ((last (car (last (drgnx-agent-session-entries s)))))
    (if (and last (eq (plist-get last :type) type) (not (plist-get last :done)))
        (plist-put last :text (concat (plist-get last :text) text))
      (drgnx-agents--add s (list :type type :text text)))))

(defun drgnx-agents--find-tool (s id)
  (let (found)
    (cl-labels ((walk (es) (dolist (e es)
                             (when (and (eq (plist-get e :type) 'tool) (equal (plist-get e :id) id)) (setq found e))
                             (walk (plist-get e :children)))))
      (walk (drgnx-agent-session-entries s)))
    found))

(defun drgnx-agents--update (s u)
  (pcase (plist-get u :sessionUpdate)
    ("agent_message_chunk" (drgnx-agents--append-text s 'agent (or (plist-get (plist-get u :content) :text) "")))
    ("agent_thought_chunk" (drgnx-agents--append-text s 'thought (or (plist-get (plist-get u :content) :text) "")))
    ("user_message_chunk"
     ;; during a turn: our own prompt echoed (already in the transcript); otherwise a replayed session
     (unless (eq (drgnx-agent-session-status s) 'busy)
       (drgnx-agents--add s (list :type 'user :text (or (plist-get (plist-get u :content) :text) "")))))
    ("tool_call"
     (let ((e (list :type 'tool :id (plist-get u :toolCallId) :title (plist-get u :title) :kind (plist-get u :kind)
                    :status (plist-get u :status) :content (plist-get u :content)))
           (parent (plist-get (plist-get u :_meta) :parentToolCallId)))
       (if-let* ((p (and parent (drgnx-agents--find-tool s parent))))
           (plist-put p :children (append (plist-get p :children) (list e)))
         (drgnx-agents--add s e))))
    ("tool_call_update"
     (when-let* ((e (drgnx-agents--find-tool s (plist-get u :toolCallId))))
       (dolist (k '(:status :title :content)) (when (plist-member u k) (plist-put e k (plist-get u k))))))
    ("plan"
     (let ((last (seq-find (lambda (e) (eq (plist-get e :type) 'plan)) (reverse (drgnx-agent-session-entries s)))))
       (if (and last (not (plist-get last :done))) (plist-put last :entries (plist-get u :entries))
         (drgnx-agents--add s (list :type 'plan :entries (plist-get u :entries))))))
    ("available_commands_update" (setf (drgnx-agent-session-commands s) (plist-get u :availableCommands))))
  (drgnx-agents--changed s))

(defun drgnx-agents-context-percent (s)
  "How full the agent's context is, in percent (from the last turn's usage), or nil."
  (let* ((u (drgnx-agent-session-usage s))
         (used (or (plist-get u :inputTokens) (plist-get u :totalTokens)))
         (window (plist-get u :contextWindow)))
    (and (numberp used) (numberp window) (> window 0) (min 100 (round (* 100.0 used) window)))))

;;;; The agent's requests

(defun drgnx-agents--on-request (s method params id)
  (pcase method
    ("session/request_permission"
     (setf (drgnx-agent-session-permissions s)
           (append (drgnx-agent-session-permissions s)
                   (list (list :id id :title (plist-get (plist-get params :toolCall) :title)
                               :tool (plist-get params :toolCall) :options (plist-get params :options)))))
     (drgnx-agents--changed s)
     :deferred)
    ("fs/read_text_file"
     (let* ((path (plist-get params :path)) (buf (and path (find-buffer-visiting path))))
       (cond ((not (and path (file-name-absolute-p path))) (list :error '(:code -32602 :message "an absolute path is needed")))
             (buf (list :result (list :content (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max))))))
             ((file-readable-p path) (list :result (list :content (with-temp-buffer (insert-file-contents path) (buffer-string)))))
             (t (list :error (list :code -32002 :message (format "%s is not readable" path)))))))
    ("fs/write_text_file"
     ;; never written behind the user's back: a review item (accept hunks, then Done answers)
     (setf (drgnx-agent-session-reviews s)
           (append (drgnx-agent-session-reviews s)
                   (list (list :id id :path (plist-get params :path) :content (plist-get params :content)))))
     (drgnx-agents--changed s)
     :deferred)
    (_ (list :error (list :code -32601 :message (format "%s is not supported" method))))))

(defun drgnx-agents-answer-permission (s item option-id)
  "Answer the pending permission ITEM of session S with OPTION-ID (nil: cancelled)."
  (setf (drgnx-agent-session-permissions s) (delq item (drgnx-agent-session-permissions s)))
  (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id)
                     (list :outcome (if option-id (list :outcome "selected" :optionId option-id) (list :outcome "cancelled"))))
  (drgnx-agents--changed s))

(defun drgnx-agents-finish-review (s item &optional reject)
  "Answer the agent's write request ITEM: done (the user applied what they accepted) or REJECT."
  (setf (drgnx-agent-session-reviews s) (delq item (drgnx-agent-session-reviews s)))
  (if reject
      (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id) nil '(:code -32003 :message "the user rejected the change"))
    (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id) nil))
  (drgnx-agents--changed s))

;;;; Starting, prompting, stopping

(defun drgnx-agents--connect (s on-ready)
  "Start S's agent and initialize it; then ON-READY."
  (let* ((profile (cdr (drgnx-agents-profile (drgnx-agent-session-profile s))))
         (conn (drgnx-acp-start (plist-get profile :command) :cwd (drgnx-agent-session-cwd s) :env (plist-get profile :env)
                                :on-notification (lambda (_c method params)
                                                   (when (equal method "session/update")
                                                     (drgnx-agents--update s (plist-get params :update))))
                                :on-request (lambda (_c method params id) (drgnx-agents--on-request s method params id))
                                :on-exit (lambda (_c status stderr)
                                           (setf (drgnx-agent-session-status s) 'exited
                                                 (drgnx-agent-session-exit s) status
                                                 (drgnx-agent-session-stderr s) stderr)
                                           (drgnx-agents--changed s)))))
    (setf (drgnx-agent-session-conn s) conn (drgnx-agent-session-mode s) (or (plist-get profile :mode) 'queue))
    (drgnx-acp-request conn "initialize"
                       '(:protocolVersion 1 :clientCapabilities (:fs (:readTextFile t :writeTextFile t) :terminal :false))
                       (lambda (r)
                         (if (cdr r) (drgnx-agents--failed s (cdr r))
                           (setf (drgnx-agent-session-capabilities s) (plist-get (car r) :agentCapabilities))
                           (funcall on-ready))))))

(defun drgnx-agents--failed (s err)
  (drgnx-agents--add s (list :type 'error :text (format "%s" (or (plist-get err :message) err))))
  (unless (eq (drgnx-agent-session-status s) 'exited) (setf (drgnx-agent-session-status s) 'idle))
  (drgnx-agents--changed s))

(defun drgnx-agents--new (profile cwd)
  (let ((s (drgnx-agents--make :name (format "%s · %s" profile (file-name-nondirectory (directory-file-name (expand-file-name cwd))))
                               :profile profile :cwd (expand-file-name cwd))))
    (push s drgnx-agents--sessions)
    s))

(defun drgnx-agents-start (profile cwd)
  "Start a session of PROFILE in CWD; it is idle once the agent made it.  Returns the session."
  (let ((s (drgnx-agents--new profile cwd)))
    (drgnx-agents--connect
     s (lambda ()
         (drgnx-acp-request (drgnx-agent-session-conn s) "session/new" (list :cwd (drgnx-agent-session-cwd s) :mcpServers [])
                            (lambda (r)
                              (if (cdr r) (drgnx-agents--failed s (cdr r))
                                (setf (drgnx-agent-session-acp-id s) (plist-get (car r) :sessionId)
                                      (drgnx-agent-session-status s) 'idle)
                                (drgnx-agents--changed s))))))
    s))

(defun drgnx-agents-take-over (profile cwd session-id)
  "Resume the agent session SESSION-ID (from another client, or one that ended) with PROFILE in CWD:
its history is replayed into the transcript.  Needs an agent that can load sessions."
  (let ((s (drgnx-agents--new profile cwd)))
    (setf (drgnx-agent-session-acp-id s) session-id)
    (drgnx-agents--connect
     s (lambda ()
         (if (memq (plist-get (drgnx-agent-session-capabilities s) :loadSession) '(nil :false))
             (drgnx-agents--failed s "this agent cannot resume sessions (no session/load)")
           (drgnx-acp-request (drgnx-agent-session-conn s) "session/load"
                              (list :sessionId session-id :cwd (drgnx-agent-session-cwd s) :mcpServers [])
                              (lambda (r)
                                (if (cdr r) (drgnx-agents--failed s (cdr r))
                                  (setf (drgnx-agent-session-status s) 'idle)
                                  (drgnx-agents--changed s)))))))
    s))

(defun drgnx-agents--prompt (s text)
  (drgnx-agents--add s (list :type 'user :text text))
  (setf (drgnx-agent-session-status s) 'busy (drgnx-agent-session-stopping s) nil (drgnx-agent-session-paused s) nil)
  (drgnx-agents--changed s)
  (drgnx-acp-request (drgnx-agent-session-conn s) "session/prompt"
                     (list :sessionId (drgnx-agent-session-acp-id s) :prompt (vector (list :type "text" :text text)))
                     (lambda (r) (drgnx-agents--turn-ended s r))))

(defun drgnx-agents--turn-ended (s r)
  (when (eq (drgnx-agent-session-status s) 'busy)       ; not already ended by Stop's deadline
    (let ((reason (or (plist-get (car r) :stopReason) (and (cdr r) "error"))))
      (when-let* ((u (or (plist-get (car r) :usage) (plist-get (plist-get (car r) :_meta) :usage))))
        (setf (drgnx-agent-session-usage s) u))
      (dolist (e (drgnx-agent-session-entries s)) (plist-put e :done t))
      (when (cdr r) (drgnx-agents--add s (list :type 'error :text (format "%s" (plist-get (cdr r) :message)))))
      (drgnx-agents--add s (list :type 'stop :stop reason :done t))
      (unless (eq (drgnx-agent-session-status s) 'exited) (setf (drgnx-agent-session-status s) 'idle))
      (when (equal reason "cancelled") (setf (drgnx-agent-session-paused s) t))
      (unless (drgnx-acp-live-p (drgnx-agent-session-conn s))   ; the agent died: the queue waits
        (setf (drgnx-agent-session-status s) 'exited))
      (drgnx-agents--changed s)
      (drgnx-agents--next s))))

(defun drgnx-agents--next (s)
  "Deliver the next queued message when S is idle and its queue is not paused by a Stop."
  (when (and (eq (drgnx-agent-session-status s) 'idle) (drgnx-agent-session-queue s) (not (drgnx-agent-session-paused s)))
    (drgnx-agents--prompt s (pop (drgnx-agent-session-queue s)))))

(defun drgnx-agents--steerable-p (s)
  (let ((m (plist-get (drgnx-agent-session-capabilities s) :_meta)))
    (and (plist-get m :steering) (not (eq (plist-get m :steering) :false)))))

(defun drgnx-agents-send (s text)
  "Send TEXT to session S: now when idle; when busy, queued (default), steering the turn (mode `steer',
when the agent can), or — only in mode `interrupt' — after cancelling the turn."
  (pcase (drgnx-agent-session-status s)
    ('idle (if (drgnx-agent-session-queue s)
               (progn (setf (drgnx-agent-session-queue s) (append (drgnx-agent-session-queue s) (list text))
                            (drgnx-agent-session-paused s) nil)
                      (drgnx-agents--next s))
             (drgnx-agents--prompt s text)))
    ('busy
     (cond ((and (eq (drgnx-agent-session-mode s) 'steer) (drgnx-agents--steerable-p s))
            (drgnx-agents--add s (list :type 'user :text text :steer t))
            (drgnx-acp-notify (drgnx-agent-session-conn s) "_session/steer"
                              (list :sessionId (drgnx-agent-session-acp-id s) :prompt (vector (list :type "text" :text text)))))
           ((eq (drgnx-agent-session-mode s) 'interrupt)
            (setf (drgnx-agent-session-queue s) (cons text (drgnx-agent-session-queue s)))
            (drgnx-agents-stop s)
            (setf (drgnx-agent-session-paused s) nil))
           (t (setf (drgnx-agent-session-queue s) (append (drgnx-agent-session-queue s) (list text))))))
    (_ (setf (drgnx-agent-session-queue s) (append (drgnx-agent-session-queue s) (list text)))))
  (drgnx-agents--changed s))

(defun drgnx-agents-deliver-queue (s)
  "Send the queued messages a Stop held back."
  (setf (drgnx-agent-session-paused s) nil)
  (drgnx-agents--next s))

(defun drgnx-agents-stop (s)
  "Cancel S's running turn: it ends within a second; pending permission requests are answered
cancelled; queued messages wait (`drgnx-agents-deliver-queue')."
  (when (eq (drgnx-agent-session-status s) 'busy)
    (dolist (p (drgnx-agent-session-permissions s)) (drgnx-agents-answer-permission s p nil))
    (setf (drgnx-agent-session-stopping s) t)
    (drgnx-acp-notify (drgnx-agent-session-conn s) "session/cancel" (list :sessionId (drgnx-agent-session-acp-id s)))
    ;; an agent that does not answer the cancel in time: the turn ends here anyway
    (run-at-time 0.9 nil (lambda ()
                           (when (and (eq (drgnx-agent-session-status s) 'busy) (drgnx-agent-session-stopping s))
                             (drgnx-agents--turn-ended s '((:stopReason "cancelled"))))))))

(defun drgnx-agents-kill (s)
  "End session S's agent process."
  (when-let* ((c (drgnx-agent-session-conn s))) (drgnx-acp-stop c))
  (setf (drgnx-agent-session-status s) 'exited)
  (drgnx-agents--changed s))

(defun drgnx-agents-sessions () drgnx-agents--sessions)

(provide 'drgnx-agents)
;;; drgnx-agents.el ends here
