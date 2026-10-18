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
;; See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-acp)

(cl-defstruct (drgnx-agent-session (:constructor drgnx-agents--make) (:copier nil))
  name profile cwd conn acp-id (status 'starting) entries queue (mode 'queue) capabilities usage commands
  permissions reviews stderr exit stopping paused turn draining task via gateway id job remote)

(defvar drgnx-agents-profiles nil
  "Alist NAME → plist (:command LIST :env (\"NAME=value\"…) :mode queue|steer|interrupt).  Read from
agents.eld (config dir) and the built-in ones; never holds secrets (keys come from the environment).")

(defvar drgnx-agents--sessions nil "Live and finished sessions, newest first.")

(defvar drgnx-agents-changed-functions nil
  "Called with a session whenever it changes (status, transcript, queue, pending items).")

(defvar drgnx-agents-task-functions nil
  "Called with a session working on a task (see `drgnx-agents-start's TASK) and `start', `turn-start' or
`turn-end': the work tracker records the commits each turn made (docs/guide/work.md).")

(defconst drgnx-agents-builtin-profiles
  '(("claude" :command ("claude-agent-acp") :mode queue :doc "Claude through the unmodified agent (subscription or API key)")
    ("claude (OpenRouter)" :command ("claude-agent-acp") :mode queue :ai claude-openrouter
     :doc "Claude Code on OpenRouter (your OpenRouter key, from the environment or auth-source)")
    ("claude (Ollama)" :command ("claude-agent-acp") :mode queue :ai claude-ollama :doc "Claude Code on a local Ollama model")
    ("claude (Kimi)" :command ("claude-agent-acp") :mode queue :ai claude-moonshot :model "kimi-k3"
     :doc "Claude Code on Kimi through Moonshot's own API (MOONSHOT_API_KEY or auth-source for api.moonshot.ai; billed per token by Moonshot)")
    ("claude (DeepSeek)" :command ("claude-agent-acp") :mode queue :ai claude-deepseek :model "deepseek-v4-pro"
     :doc "Claude Code on DeepSeek through its own API (DEEPSEEK_API_KEY or auth-source for api.deepseek.com; billed per token by DeepSeek)")
    ("claude (Kimi via OpenRouter)" :command ("claude-agent-acp") :mode queue :ai claude-openrouter :model "moonshotai/kimi-k3"
     :doc "Claude Code on Kimi through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)")
    ("claude (DeepSeek via OpenRouter)" :command ("claude-agent-acp") :mode queue :ai claude-openrouter
     :model "deepseek/deepseek-v4-pro"
     :doc "Claude Code on DeepSeek through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)"))
  "Profiles drgnx offers without setup; :ai names the provider environment the agent gets when it starts
(`drgnx-ai-agent-env').")

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

(defun drgnx-agents-default-profile ()
  "The profile New Agent Session offers on Return: agents.eld's `:default' when it names a profile, else claude."
  (let ((d (plist-get (drgnx-agents--read-file) :default)))
    (if (and (stringp d) (member d (drgnx-agents-profile-names))) d "claude")))

(defun drgnx-agents-mcp-names ()
  "The MCP servers agents get, from agents.eld's `:mcp' (`coordination', `search'): the coordination tools alone
until it says otherwise."
  (let ((file (drgnx-agents--read-file)))
    (if (plist-member file :mcp) (plist-get file :mcp) '(coordination))))

(declare-function drgnx-keys--save-key "drgnx-keys")

(defun drgnx-agents-set-setting (key value)
  "Save VALUE as KEY (`:default', `:mcp') in agents.eld: only that value changes, comments and the rest stay.  A file
that cannot be read is a `user-error' and is not changed."
  (require 'drgnx-keys)
  (drgnx-keys--save-key key value (expand-file-name "agents.eld" (drgnx-user-dir)) ";; drgnx agents (docs/guide/agents.md)\n"))

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

(defun drgnx-agents--raw-url (u)
  "The url in update U's raw tool input (a string), or nil.  Only the url is kept: a Write's input is the whole file."
  (let ((url (plist-get (plist-get u :rawInput) :url))) (and (stringp url) url)))

(defun drgnx-agents--update (s u)
  (pcase (plist-get u :sessionUpdate)
    ;; chunks of a turn that Stop's deadline already ended are dropped
    ((and (or "agent_message_chunk" "agent_thought_chunk") (guard (drgnx-agent-session-draining s))) nil)
    ("agent_message_chunk" (drgnx-agents--append-text s 'agent (or (plist-get (plist-get u :content) :text) "")))
    ("agent_thought_chunk" (drgnx-agents--append-text s 'thought (or (plist-get (plist-get u :content) :text) "")))
    ("usage_update" (setf (drgnx-agent-session-usage s) (list :used (plist-get u :used) :size (plist-get u :size)
                                                              :cost (plist-get u :cost))))
    ("user_message_chunk"
     ;; during a turn: our own prompt echoed (already in the transcript); otherwise a replayed session
     (unless (eq (drgnx-agent-session-status s) 'busy)
       (drgnx-agents--add s (list :type 'user :text (or (plist-get (plist-get u :content) :text) "")))))
    ("tool_call"
     (let ((e (list :type 'tool :id (plist-get u :toolCallId) :title (plist-get u :title) :kind (plist-get u :kind)
                    :status (plist-get u :status) :content (plist-get u :content) :url (drgnx-agents--raw-url u)))
           (parent (plist-get (plist-get u :_meta) :parentToolCallId)))
       (if-let* ((p (and parent (drgnx-agents--find-tool s parent))))
           (plist-put p :children (append (plist-get p :children) (list e)))
         (drgnx-agents--add s e))))
    ("tool_call_update"
     (when-let* ((e (drgnx-agents--find-tool s (plist-get u :toolCallId))))
       (dolist (k '(:status :title :content)) (when (plist-member u k) (plist-put e k (plist-get u k))))
       (when-let* ((url (drgnx-agents--raw-url u))) (plist-put e :url url))))
    ("plan"
     (let ((last (seq-find (lambda (e) (eq (plist-get e :type) 'plan)) (reverse (drgnx-agent-session-entries s)))))
       (if (and last (not (plist-get last :done))) (plist-put last :entries (plist-get u :entries))
         (drgnx-agents--add s (list :type 'plan :entries (plist-get u :entries))))))
    ("available_commands_update" (setf (drgnx-agent-session-commands s) (plist-get u :availableCommands))))
  (drgnx-agents--changed s))

(defun drgnx-agents-context-percent (s)
  "How full the agent's context is, in percent (from the last turn's usage), or nil."
  (let* ((u (drgnx-agent-session-usage s))
         (used (or (plist-get u :used) (plist-get u :inputTokens) (plist-get u :totalTokens)))
         (window (or (plist-get u :size) (plist-get u :contextWindow))))
    (and (numberp used) (numberp window) (> window 0) (min 100 (round (* 100.0 used) window)))))

;;;; The agent's requests

(defun drgnx-agents--path-ok-p (path)
  "PATH is a real absolute path (not ~, not relative)."
  (and (stringp path) (file-name-absolute-p path) (not (string-prefix-p "~" path))))

(defun drgnx-agents--lines (text line limit)
  "TEXT from LINE (1-based) for LIMIT lines (both optional: ACP's ranged read)."
  (if (not (or line limit)) text
    (let* ((lines (split-string text "\n"))
           (from (max 0 (1- (or line 1))))
           (part (seq-take (nthcdr from lines) (or limit (length lines)))))
      (concat (string-join part "\n") (if (and part (< (+ from (length part)) (length lines))) "\n" "")))))

(defvar drgnx-agents-request-functions nil
  "Functions called with (SESSION METHOD PARAMS ID) when an agent asks drgnx something (a permission, a file): the
first non-nil answer is used — (:result R), (:error E) or `:deferred'; nil lets the session's own handling run.
Jobs answer routine requests by a policy here (drgnx-job.el).")

(defvar drgnx-agents-error-functions nil
  "Functions called with (SESSION ERROR) when a turn ends in an error (ERROR the agent's (:code :message)): jobs move
a task whose provider failed to the next profile (drgnx-job.el).  Called in the process filter: only schedule work.")

(defun drgnx-agents--on-request (s method params id)
  (or (run-hook-with-args-until-success 'drgnx-agents-request-functions s method params id)
      (drgnx-agents--on-request-1 s method params id)))

(defun drgnx-agents--on-request-1 (s method params id)
  (pcase method
    ("session/request_permission"
     (setf (drgnx-agent-session-permissions s)
           (append (drgnx-agent-session-permissions s)
                   (list (list :id id :title (plist-get (plist-get params :toolCall) :title)
                               :tool (plist-get params :toolCall) :options (plist-get params :options)))))
     (drgnx-agents--changed s)
     :deferred)
    ("fs/read_text_file"
     (let* ((path (plist-get params :path)) (buf (and (drgnx-agents--path-ok-p path) (find-buffer-visiting path))))
       (cond ((not (drgnx-agents--path-ok-p path)) (list :error '(:code -32602 :message "an absolute path is needed")))
             ((or buf (file-readable-p path))
              (list :result (list :content (drgnx-agents--lines (if buf (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))
                                                                  (with-temp-buffer (insert-file-contents path) (buffer-string)))
                                                                (plist-get params :line) (plist-get params :limit)))))
             (t (list :error (list :code -32002 :message (format "%s is not readable" path)))))))
    ((and "fs/write_text_file" (guard (not (and (drgnx-agents--path-ok-p (plist-get params :path)) (stringp (plist-get params :content))))))
     (list :error '(:code -32602 :message "an absolute path and the content are needed")))
    ("fs/write_text_file"
     ;; never written behind the user's back: a review item (accept hunks, then Done answers)
     (setf (drgnx-agent-session-reviews s)
           (append (drgnx-agent-session-reviews s)
                   (list (list :id id :path (plist-get params :path) :content (plist-get params :content)))))
     (drgnx-agents--changed s)
     :deferred)
    (_ (list :error (list :code -32601 :message (format "%s is not supported" method))))))

(cl-defun drgnx-agents-answer-permission (s item option-id)
  "Answer the pending permission ITEM of session S with OPTION-ID (nil: cancelled)."
  (when (drgnx-agent-session-remote s)
    (setf (drgnx-agent-session-permissions s) (delq item (drgnx-agent-session-permissions s)))
    (drgnx-agents--remote s "agents/permission" (list :request (plist-get item :id) :option option-id))
    (cl-return-from drgnx-agents-answer-permission))
  (setf (drgnx-agent-session-permissions s) (delq item (drgnx-agent-session-permissions s)))
  (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id)
                     (list :outcome (if option-id (list :outcome "selected" :optionId option-id) (list :outcome "cancelled"))))
  (drgnx-agents--changed s))

(cl-defun drgnx-agents-finish-review (s item &optional reject)
  "Answer the agent's write request ITEM: done (the user applied what they accepted) or REJECT."
  (when (drgnx-agent-session-remote s)
    (setf (drgnx-agent-session-reviews s) (delq item (drgnx-agent-session-reviews s)))
    (drgnx-agents--remote s "agents/do" (list :op "review" :item (plist-get item :id) :reject (and reject t)))
    (cl-return-from drgnx-agents-finish-review))
  (setf (drgnx-agent-session-reviews s) (delq item (drgnx-agent-session-reviews s)))
  (if reject
      (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id) nil '(:code -32003 :message "the user rejected the change"))
    (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get item :id) nil))
  (drgnx-agents--changed s))

;;;; Starting, prompting, stopping

(defun drgnx-agents--connect (s on-ready)
  "Start S's agent and initialize it; then ON-READY."
  (let* ((profile (cdr (drgnx-agents-profile (drgnx-agent-session-profile s))))
         (conn (drgnx-acp-start (plist-get profile :command) :cwd (drgnx-agent-session-cwd s) :env (drgnx-agents--env s)
                                :on-notification (lambda (_c method params)
                                                   (when (equal method "session/update")
                                                     (drgnx-agents--update s (plist-get params :update))))
                                :on-request (lambda (_c method params id) (drgnx-agents--on-request s method params id))
                                :on-exit (lambda (_c status stderr)
                                           (setf (drgnx-agent-session-status s) 'exited
                                                 (drgnx-agent-session-exit s) status
                                                 (drgnx-agent-session-stderr s) stderr)
                                           (drgnx-agents--release-gateway s)
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

(declare-function drgnx-ai-agent-env "drgnx-ai")
(declare-function drgnx-ai-agent-gateway-chain "drgnx-ai")
(declare-function drgnx-ai-provider "drgnx-ai")
(declare-function drgnx-ai-key "drgnx-ai")
(declare-function drgnx-hub-ensure "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")
(declare-function drgnx-hub-serving-p "drgnx-hub")
(declare-function drgnx-hub-register "drgnx-hub")
(defvar drgnx-ai-gateway-kinds)

(defvar drgnx-agents-use-gateway t
  "Non-nil: agents on OpenRouter, Ollama or Anthropic profiles talk to the hub's gateway (a token, never a key);
without a hub they go to the provider directly.")

(defun drgnx-agents--in-hub-p ()
  "Is this Emacs the hub?  A daemon: it never looks a key up where that may ask."
  (and (fboundp 'drgnx-hub-serving-p) (drgnx-hub-serving-p)))

(defun drgnx-agents--gateway (s kind &optional model)
  "Register S's agent (profile KIND, with the profile's MODEL) with the hub's gateway: (:url :token), or nil when
no hub can be had (S then goes direct, and says so).  In the hub, keys are only those editors handed over (and the
environment, quiet auth-source files): with none for any provider of the chain, a `user-error' says how one comes."
  (when (drgnx-agents--in-hub-p)
    (let ((chain (drgnx-ai-agent-gateway-chain kind model)))
      (unless (seq-some (lambda (st) (or (not (plist-get (drgnx-ai-provider (car st)) :key-env)) (drgnx-ai-key (car st))))
                        chain)
        (user-error "No key for %s in the drgnx hub: an editor hands its keys over when it connects (or run `drgnx hub start' where the key is set)"
                    (mapconcat (lambda (st) (symbol-name (car st))) chain ", ")))))
  (condition-case err
      (progn
        (require 'drgnx-hub)
        (unless (drgnx-hub-serving-p) (drgnx-hub-ensure))
        (let* ((chain (drgnx-ai-agent-gateway-chain kind model))
               ;; keys this command can read (also from sources that ask) travel to the hub's memory — never in the
               ;; hub, which has what editors gave it
               (keys (unless (drgnx-agents--in-hub-p)
                       (cl-loop for (id . _) in chain
                                for key = (and (plist-get (drgnx-ai-provider id) :key-env) (drgnx-ai-key id t))
                                when key append (list (intern (concat ":" (symbol-name id))) key))))
               (params (list :task (drgnx-agent-session-task s) :job (drgnx-agent-session-job s)
                             :agent (drgnx-agent-session-name s)
                             :owner (emacs-pid)   ; its agent is this Emacs's child: gone with it, its token goes too
                             :chain (mapcar (lambda (st) (list (symbol-name (car st)) (cdr st))) chain)
                             :keys keys))
               (r (if (drgnx-hub-serving-p) (drgnx-hub-register params)
                    (drgnx-hub-call-sync "gateway/register"
                                         (plist-put (plist-put (copy-sequence params) :chain (vconcat (mapcar #'vconcat (plist-get params :chain))))
                                                    :keys (or keys (make-hash-table)))))))
          (setf (drgnx-agent-session-via s) 'gateway (drgnx-agent-session-gateway s) (plist-get r :token))
          r))
    (error (setf (drgnx-agent-session-via s) 'direct)
           (message "drgnx: no agent hub (%s); %s goes to its provider directly" (error-message-string err)
                    (drgnx-agent-session-name s))
           nil)))

(declare-function drgnx-hub-call "drgnx-hub")

(defun drgnx-agents--release-gateway (s)
  "S's agent is gone: its gateway token goes too (asynchronously; never waits — an exit runs from a timer)."
  (when-let* ((token (drgnx-agent-session-gateway s)))
    (setf (drgnx-agent-session-gateway s) nil)
    (ignore-errors (drgnx-hub-call "gateway/unregister" (list :token token) #'ignore))))

(defvar drgnx-agents-env-functions nil
  "Called with a session as its agent starts; each returns extra \"NAME=value\" strings for the agent's environment
(the Live browser's endpoint, docs/guide/live.md).  One that fails is reported and skipped, and so is anything
returned that is not a string.")

(defun drgnx-agents--env (s)
  "The environment S's agent gets: its profile's, its provider's — the gateway's address and a token when the hub
can carry it, else the provider's (keys resolved now, never kept) — DRGNX_TASK when S works on a task, and what
`drgnx-agents-env-functions' add."
  (append (plist-get (cdr (drgnx-agents-profile (drgnx-agent-session-profile s))) :env)
          (when-let* ((profile (cdr (drgnx-agents-profile (drgnx-agent-session-profile s))))
                      (kind (plist-get profile :ai)))
            (require 'drgnx-ai)
            (drgnx-ai-agent-env (list :kind kind :model (plist-get profile :model)) (not (drgnx-agents--in-hub-p))
                                (and drgnx-agents-use-gateway (memq kind drgnx-ai-gateway-kinds)
                                     (drgnx-agents--gateway s kind (plist-get profile :model)))))
          (and (drgnx-agent-session-task s) (list (concat "DRGNX_TASK=" (drgnx-agent-session-task s))))
          (and (drgnx-agent-session-job s) (list (concat "DRGNX_JOB=" (drgnx-agent-session-job s))))
          (let (extra)
            (run-hook-wrapped 'drgnx-agents-env-functions
                              (lambda (f)
                                (let ((r (with-demoted-errors "drgnx agents: %S" (funcall f s))))
                                  (if (not (proper-list-p r))
                                      (message "drgnx agents: an environment function returned %S, not a list of NAME=value strings; ignored" r)
                                    (dolist (e r)
                                      (if (stringp e) (setq extra (append extra (list e)))
                                        (message "drgnx agents: an environment function returned %S, not a NAME=value string; ignored" e)))))
                                nil))
            extra)))

(defvar drgnx-agents-coordination t
  "Non-nil: every agent gets drgnx's coordination tools (an MCP server, docs/develop/coordination.md).")

(declare-function drgnx-coord-mcp-server-spec "drgnx-coord-mcp")

(declare-function drgnx-search-mcp-server-spec "drgnx-search-mcp")

(defun drgnx-agents--mcp-servers (s)
  "The `mcpServers' S's agent gets: the coordination tools, as S's name, and the search tool for S's project when
agents.eld asks for it (`drgnx-agents-mcp-names')."
  (let ((names (drgnx-agents-mcp-names)))
    (vconcat
     (and drgnx-agents-coordination (memq 'coordination names)
          (progn (require 'drgnx-coord-mcp)
                 ;; its identity is its id: a name (\"profile · dir\") repeats across hubs and editors
                 (list (drgnx-coord-mcp-server-spec (drgnx-agent-session-id s) :job (drgnx-agent-session-job s)
                                                    :task (drgnx-agent-session-task s)))))
     (and (memq 'search names)
          (with-demoted-errors "drgnx agents: the search tool: %S"
            (require 'drgnx-search-mcp)
            (list (drgnx-search-mcp-server-spec (drgnx-agent-session-cwd s))))))))

(defun drgnx-agents-get (id) (seq-find (lambda (s) (equal (drgnx-agent-session-id s) id)) drgnx-agents--sessions))

(declare-function drgnx-hub-call "drgnx-hub")

(defun drgnx-agents--remote (s method params)
  "Ask the hub to do METHOD (with PARAMS) on mirror S's session; asynchronous, never waits."
  (require 'drgnx-hub)
  (drgnx-hub-call method (append (list :id (drgnx-agent-session-remote s)) params)
                  (lambda (_r err) (when err (message "drgnx agent %s: %s" (drgnx-agent-session-name s) err)))))

(defun drgnx-agents--new (profile cwd &optional task job)
  (let* ((base (format "%s · %s" profile (file-name-nondirectory (directory-file-name (expand-file-name cwd)))))
         (name base) (n 1))
    (while (seq-find (lambda (x) (equal (drgnx-agent-session-name x) name)) drgnx-agents--sessions)
      (setq n (1+ n) name (format "%s <%d>" base n)))
    (let ((s (drgnx-agents--make :name name :profile profile :cwd (expand-file-name cwd) :task task :job job
                                 :id (concat "s-" (substring (secure-hash 'sha1 (format "%s %s %s %s" name (float-time) (random) (emacs-pid))) 0 8)))))
      (push s drgnx-agents--sessions)
      (when task
        (require 'drgnx-work)                    ; the tracker notes where the work starts
        (run-hook-with-args 'drgnx-agents-task-functions s 'start))
      s)))

(defun drgnx-agents--start-safely (s fn)
  "Run FN (starting S's agent); an agent that cannot start makes S an exited session that says why."
  (condition-case err (funcall fn)
    (error (setf (drgnx-agent-session-status s) 'exited)
           (drgnx-agents--add s (list :type 'error :text (format "the agent did not start: %s" (error-message-string err))))
           (drgnx-agents--changed s))))

(defun drgnx-agents-start (profile cwd &optional task job)
  "Start a session of PROFILE in CWD; it is idle once the agent made it.  Returns the session.
TASK (a work-tracker node id) is what the session works on: the agent gets it as DRGNX_TASK, and
the commits each turn makes are recorded for it.  JOB: the coordination job it belongs to."
  (let ((s (drgnx-agents--new profile cwd task job)))
    (drgnx-agents--start-safely
     s (lambda ()
         (drgnx-agents--connect
          s (lambda ()
              (drgnx-acp-request (drgnx-agent-session-conn s) "session/new" (list :cwd (drgnx-agent-session-cwd s) :mcpServers (drgnx-agents--mcp-servers s))
                                 (lambda (r)
                                   (if (cdr r) (drgnx-agents--failed s (cdr r))
                                     (setf (drgnx-agent-session-acp-id s) (plist-get (car r) :sessionId)
                                           (drgnx-agent-session-status s) 'idle)
                                     (drgnx-agents--changed s)
                                     (drgnx-agents--next s))))))))
    s))

(defun drgnx-agents-take-over (profile cwd session-id &optional task id name)
  "Resume the agent session SESSION-ID (from another client, or one that ended) with PROFILE in CWD:
its history is replayed into the transcript.  Needs an agent that can load sessions: when it cannot, the session
ends and says why.  TASK as in `drgnx-agents-start'; ID and NAME, the session's own when it keeps them (a hub
resuming its sessions: messages and spend follow them)."
  (let ((s (drgnx-agents--new profile cwd task)))
    (when id (setf (drgnx-agent-session-id s) id))
    (when (stringp name) (setf (drgnx-agent-session-name s) name))
    (setf (drgnx-agent-session-acp-id s) session-id)
    (drgnx-agents--start-safely
     s (lambda ()
         (drgnx-agents--connect
          s (lambda ()
              (if (memq (plist-get (drgnx-agent-session-capabilities s) :loadSession) '(nil :false))
                  (progn (drgnx-agents--failed s "this agent cannot resume sessions (no session/load)") (drgnx-agents-kill s))
                (drgnx-acp-request (drgnx-agent-session-conn s) "session/load"
                                   (list :sessionId session-id :cwd (drgnx-agent-session-cwd s) :mcpServers (drgnx-agents--mcp-servers s))
                                   (lambda (r)
                                     (if (cdr r) (progn (drgnx-agents--failed s (cdr r)) (drgnx-agents-kill s))
                                       (setf (drgnx-agent-session-status s) 'idle)
                                       (drgnx-agents--changed s)
                                       (drgnx-agents--next s)))))))))
    s))

(defun drgnx-agents-free-p (s)
  "Can S take a new turn now (idle, not paused by a Stop, nothing queued)?"
  (and (eq (drgnx-agent-session-status s) 'idle) (not (drgnx-agent-session-paused s)) (null (drgnx-agent-session-queue s))
       (drgnx-agent-session-conn s) t))

(defun drgnx-agents-deliver (s text)
  "Give TEXT to S as a new turn if it is free (`drgnx-agents-free-p'); t when it did.  Never queues, never steers,
never interrupts, whatever S's mode — for drgnx's own deliveries (messages, decision notices)."
  (when (drgnx-agents-free-p s) (drgnx-agents--prompt s text) t))

(defvar drgnx-agents-prompt-functions nil
  "Called with (SESSION TEXT) when TEXT goes to the agent as a prompt (the hub marks delivered messages read).")

(defun drgnx-agents--prompt (s text)
  (run-hook-with-args 'drgnx-agents-prompt-functions s text)
  (drgnx-agents--add s (list :type 'user :text text))
  (setf (drgnx-agent-session-status s) 'busy (drgnx-agent-session-stopping s) nil (drgnx-agent-session-paused s) nil)
  (when (drgnx-agent-session-task s) (with-demoted-errors "drgnx work: %S" (run-hook-with-args 'drgnx-agents-task-functions s 'turn-start)))
  (drgnx-agents--changed s)
  (let (id)
    (setq id (drgnx-acp-request (drgnx-agent-session-conn s) "session/prompt"
                                (list :sessionId (drgnx-agent-session-acp-id s) :prompt (vector (list :type "text" :text text)))
                                (lambda (r) (drgnx-agents--turn-ended s r id))))
    (setf (drgnx-agent-session-turn s) id)))

(defun drgnx-agents--turn-ended (s r id)
  "The answer R to prompt ID: it ends the turn only if ID is the turn running.  The late answer of a
turn Stop's deadline ended lets the held messages go."
  (cond
   ((and id (eql id (drgnx-agent-session-draining s)))
    (setf (drgnx-agent-session-draining s) nil)
    (drgnx-agents--changed s)
    (drgnx-agents--next s))
   ((and (eq (drgnx-agent-session-status s) 'busy) (eql id (drgnx-agent-session-turn s)))
    (let ((reason (or (plist-get (car r) :stopReason) (and (cdr r) "error")))
          (interrupt (eq (drgnx-agent-session-stopping s) 'interrupt)))
      (when-let* ((u (or (plist-get (car r) :usage) (plist-get (plist-get (car r) :_meta) :usage))))
        (setf (drgnx-agent-session-usage s) u))
      (dolist (e (drgnx-agent-session-entries s)) (plist-put e :done t))
      (when (cdr r) (drgnx-agents--add s (list :type 'error :text (format "%s" (plist-get (cdr r) :message)))))
      (drgnx-agents--add s (list :type 'stop :stop reason :done t))
      (setf (drgnx-agent-session-turn s) nil (drgnx-agent-session-stopping s) nil)
      (unless (eq (drgnx-agent-session-status s) 'exited) (setf (drgnx-agent-session-status s) 'idle))
      (when (and (equal reason "cancelled") (not interrupt)) (setf (drgnx-agent-session-paused s) t))
      (when (drgnx-agent-session-task s) (with-demoted-errors "drgnx work: %S" (run-hook-with-args 'drgnx-agents-task-functions s 'turn-end)))
      (unless (drgnx-acp-live-p (drgnx-agent-session-conn s))   ; the agent died: the queue waits
        (setf (drgnx-agent-session-status s) 'exited
              (drgnx-agent-session-stderr s) (drgnx-acp-conn-stderr (drgnx-agent-session-conn s))))
      (when (cdr r) (with-demoted-errors "drgnx agents: %S" (run-hook-with-args 'drgnx-agents-error-functions s (cdr r))))
      (drgnx-agents--changed s)
      (drgnx-agents--next s)))))

(defun drgnx-agents--ready-p (s)
  "S can take a prompt: idle, made by the agent, not waiting for a stopped turn's last answer."
  (and (eq (drgnx-agent-session-status s) 'idle) (drgnx-agent-session-acp-id s) (not (drgnx-agent-session-draining s))))

(defun drgnx-agents--next (s)
  "Deliver the next queued message when S is ready and its queue is not paused by a Stop."
  (when (and (drgnx-agents--ready-p s) (drgnx-agent-session-queue s) (not (drgnx-agent-session-paused s)))
    (drgnx-agents--prompt s (pop (drgnx-agent-session-queue s)))))

(defun drgnx-agents--steerable-p (s)
  (let ((m (plist-get (drgnx-agent-session-capabilities s) :_meta)))
    (and (plist-get m :steering) (not (eq (plist-get m :steering) :false)))))

(defun drgnx-agents--enqueue (s text) (setf (drgnx-agent-session-queue s) (append (drgnx-agent-session-queue s) (list text))))

(defun drgnx-agents-steer (s text)
  "Put TEXT into S's running turn when it can be steered (t); else queue it for the turn's end (nil).  A refused
steer waits for the turn too."
  (if (not (and (eq (drgnx-agent-session-status s) 'busy) (drgnx-agents--steerable-p s)))
      (progn (drgnx-agents--enqueue s text) nil)
    (let ((entry (list :type 'user :text text :steer t)))
      (drgnx-agents--add s entry)
      (drgnx-acp-request (drgnx-agent-session-conn s) "_session/steering"
                         (list :sessionId (drgnx-agent-session-acp-id s) :prompt (vector (list :type "text" :text text)))
                         (lambda (r)
                           (when (cdr r)            ; refused: the message waits for the turn instead
                             (setf (drgnx-agent-session-entries s) (delq entry (drgnx-agent-session-entries s)))
                             (drgnx-agents--enqueue s text)
                             (drgnx-agents--changed s))))
      t)))

(cl-defun drgnx-agents-send (s text)
  "Send TEXT to session S: now when ready; when busy, queued (default), steering the turn (mode
`steer', when the agent can; queued if it refuses), or — only in mode `interrupt' — after cancelling
the turn."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/send" (list :text text)) (cl-return-from drgnx-agents-send))
  (pcase (drgnx-agent-session-status s)
    ((guard (drgnx-agents--ready-p s))
     (if (drgnx-agent-session-queue s)
         (progn (drgnx-agents--enqueue s text) (setf (drgnx-agent-session-paused s) nil) (drgnx-agents--next s))
       (drgnx-agents--prompt s text)))
    ('busy
     (cond ((eq (drgnx-agent-session-mode s) 'steer) (drgnx-agents-steer s text))
           ((eq (drgnx-agent-session-mode s) 'interrupt)
            (setf (drgnx-agent-session-queue s) (cons text (drgnx-agent-session-queue s)))
            (drgnx-agents-stop s 'interrupt))
           (t (drgnx-agents--enqueue s text))))
    ('idle (drgnx-agents--enqueue s text)              ; not ready yet (a stopped turn drains): it goes next
           (setf (drgnx-agent-session-paused s) nil))
    (_ (drgnx-agents--enqueue s text)))
  (drgnx-agents--changed s))

(cl-defun drgnx-agents-deliver-queue (s)
  "Send the queued messages a Stop held back."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "deliver-queue")) (cl-return-from drgnx-agents-deliver-queue))
  (setf (drgnx-agent-session-paused s) nil)
  (drgnx-agents--next s))

(cl-defun drgnx-agents-unqueue (s n)
  "Remove the Nth queued message of S (before it is sent)."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "unqueue" :n n)) (cl-return-from drgnx-agents-unqueue))
  (setf (drgnx-agent-session-queue s) (append (seq-take (drgnx-agent-session-queue s) n) (nthcdr (1+ n) (drgnx-agent-session-queue s))))
  (drgnx-agents--changed s))

(cl-defun drgnx-agents-requeue (s n text)
  "Replace the Nth queued message of S with TEXT (empty: remove it)."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "requeue" :n n :text text)) (cl-return-from drgnx-agents-requeue))
  (if (string-empty-p (string-trim text)) (drgnx-agents-unqueue s n)
    (setf (nth n (drgnx-agent-session-queue s)) text)
    (drgnx-agents--changed s)))

(cl-defun drgnx-agents-stop (s &optional why)
  "Cancel S's running turn: it ends within a second; pending permission requests are answered
cancelled and pending edits rejected; queued messages wait (`drgnx-agents-deliver-queue') unless WHY
is `interrupt'."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/stop" nil) (cl-return-from drgnx-agents-stop))
  (when (eq (drgnx-agent-session-status s) 'busy)
    (dolist (p (drgnx-agent-session-permissions s)) (drgnx-agents-answer-permission s p nil))
    (dolist (r (drgnx-agent-session-reviews s))
      (setf (drgnx-agent-session-reviews s) (delq r (drgnx-agent-session-reviews s)))
      (drgnx-acp-respond (drgnx-agent-session-conn s) (plist-get r :id) nil '(:code -32003 :message "the turn was stopped")))
    (setf (drgnx-agent-session-stopping s) (or why t))
    (drgnx-acp-notify (drgnx-agent-session-conn s) "session/cancel" (list :sessionId (drgnx-agent-session-acp-id s)))
    ;; an agent that does not answer the cancel in time: this turn ends here anyway; its late answer
    ;; (and chunks) are then dropped, and nothing new is sent until it came (or 10 s passed)
    (let ((turn (drgnx-agent-session-turn s)))
      (run-at-time 0.9 nil
                   (lambda ()
                     (when (and (eq (drgnx-agent-session-status s) 'busy) (eql (drgnx-agent-session-turn s) turn))
                       (drgnx-agents--turn-ended s '((:stopReason "cancelled")) turn)
                       (setf (drgnx-agent-session-draining s) turn)
                       (run-at-time 10 nil (lambda ()
                                             (when (eql (drgnx-agent-session-draining s) turn)
                                               (setf (drgnx-agent-session-draining s) nil)
                                               (drgnx-agents--next s))))))))))

(cl-defun drgnx-agents-kill (s)
  "End session S's agent process."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/kill" nil) (cl-return-from drgnx-agents-kill))
  (when-let* ((c (drgnx-agent-session-conn s))) (drgnx-acp-stop c))
  (drgnx-agents--release-gateway s)
  (setf (drgnx-agent-session-status s) 'exited)
  (drgnx-agents--changed s))

(defun drgnx-agents-sessions () drgnx-agents--sessions)

(provide 'drgnx-agents)
;;; drgnx-agents.el ends here
