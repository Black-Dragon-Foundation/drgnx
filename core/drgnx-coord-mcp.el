;;; drgnx-coord-mcp.el --- The coordination tools every agent gets (an MCP server) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One server process per agent, started by the agent from the `mcpServers' entry drgnx gives it in ACP's
;; session/new (`drgnx-coord-mcp-server-spec').  Its identity comes from its environment: DRGNX_AGENT (required to
;; write), DRGNX_JOB, DRGNX_TASK.  The tools read and write the coordination store (drgnx-coord.el); every write
;; carries the decision-log version the agent last read, and a write made from an old version is held — nothing
;; written, the changes returned.  After a write the server tells the hub, so messages go out at once.  See
;; docs/develop/coordination.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-mcp)
(require 'drgnx-coord)
(require 'drgnx-work)
(require 'drgnx-paths)

(declare-function drgnx-hub-socket "drgnx-hub")

(defun drgnx-coord-mcp--me ()
  (let ((a (getenv "DRGNX_AGENT")))
    (if (and a (not (string-empty-p a))) a (error "This server has no agent identity (DRGNX_AGENT): it can only read"))))

(defun drgnx-coord-mcp--jsonable (v)
  (cond ((null v) :null) ((eq v t) t)
        ((and (consp v) (keywordp (car v))) (cl-loop for (k x) on v by #'cddr append (list k (drgnx-coord-mcp--jsonable x))))
        ((consp v) (vconcat (mapcar #'drgnx-coord-mcp--jsonable v)))
        ((and (symbolp v) (not (keywordp v))) (symbol-name v))
        (t v)))

(defun drgnx-coord-mcp--answer (r)
  "The store's answer R as the tool's text: a held write says so first, with the changes."
  (if (plist-get r :held)
      (concat "HELD: the decision log moved on — read these changes, then retry with seen_version "
              (number-to-string (plist-get r :version)) ".\n"
              (drgnx-mcp--json (drgnx-coord-mcp--jsonable (list :version (plist-get r :version) :changes (plist-get r :changes)))))
    (drgnx-mcp--json (drgnx-coord-mcp--jsonable r))))

(defun drgnx-coord-mcp--notify-hub ()
  "Tell the hub something was written (it delivers at once); never waits, never fails."
  (ignore-errors
    (require 'drgnx-hub)
    (let ((socket (drgnx-hub-socket)))
      (when (file-exists-p socket)
        (let ((c (make-network-process :name "drgnx-coord-notify" :family 'local :service socket :noquery t)))
          (process-send-string c "{\"method\":\"coord/notify\"}\n")   ; a notification: no answer to wait for
          (delete-process c))))))

(defmacro drgnx-coord-mcp--write (&rest body)
  "BODY (a store write): its answer as text, the hub told."
  `(let ((r (progn ,@body)))
     (ignore-errors (drgnx-coord-note-held (drgnx-coord-mcp--me) (and (consp r) (plist-get r :held))))   ; stale twice: a card
     (prog1 (drgnx-coord-mcp--answer r) (drgnx-coord-mcp--notify-hub))))

(declare-function drgnx-hub-running-p "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")

(defun drgnx-coord-mcp--hub-agents ()
  "The sessions the hub runs, ((:id :name :job :task …)…) — or `none' when no hub answers."
  (condition-case nil
      (progn
        (require 'drgnx-hub)
        (if (not (drgnx-hub-running-p)) 'none
          (let ((read-eval nil))
            (mapcar (lambda (lisp) (car (read-from-string lisp)))
                    (plist-get (drgnx-hub-call-sync "agents/list" nil 2) :sessions)))))
    (error 'none)))

(defun drgnx-coord-mcp--agents ()
  "The agents of this job (every agent when the caller has no job), ((:agent ID :task TASK :name NAME)…): the hub's
sessions when it runs, else the job's tasks that have an agent."
  (let ((job (getenv "DRGNX_JOB")) (sessions (drgnx-coord-mcp--hub-agents)))
    (if (listp sessions)
        (delq nil (mapcar (lambda (s) (and (or (null job) (equal (plist-get s :job) job))
                                           (list :agent (plist-get s :id) :task (plist-get s :task) :name (plist-get s :name))))
                          sessions))
      (delq nil (mapcar (lambda (task) (and (plist-get task :agent) (list :agent (plist-get task :agent) :task (plist-get task :id))))
                        (drgnx-coord-tasks job))))))

(defun drgnx-coord-mcp--resolve-recipient (to)
  "The identity a message to TO is stored under: \"user\", an agent of this job's tasks, or the id of the hub session
TO names (by id or name; an agent's identity is its session id, so inbox, ack and replies find the message).  Else an
error, nothing is sent.  The hub is asked only when the cheap checks fail."
  (or (and (equal to "user") to)
      (and (seq-some (lambda (task) (equal to (plist-get task :agent))) (drgnx-coord-tasks (getenv "DRGNX_JOB"))) to)
      (let ((sessions (drgnx-coord-mcp--hub-agents)))
        (or (and (listp sessions)
                 (plist-get (seq-find (lambda (s) (member to (list (plist-get s :id) (plist-get s :name)))) sessions) :id))
            (error "No agent \"%s\" (list_agents names them; \"user\" is the user)%s" to
                   (if (listp sessions) "" " - no hub answered, so only the job's task agents are known"))))))

(defun drgnx-coord-mcp--seen (args)
  (or (plist-get args :seen_version) (error "seen_version is required: call read_decisions first")))

(defun drgnx-coord-mcp-tools ()
  "The coordination tools: ((NAME :description :schema :call)…)."
  (let ((s #'drgnx-mcp-schema) (seen '("seen_version" "integer" "The decision-log version you last read (read_decisions)")))
    `(("list_agents" :description "The agents working on this job, with their tasks"
       :schema ,(funcall s nil)
       :call ,(lambda (_a) (drgnx-coord-mcp--jsonable (drgnx-coord-mcp--agents))))
      ("send_message" :description "Send a message to another agent (or \"user\"); it is queued and never interrupts them"
       :schema ,(funcall s `(("to" "string" "The recipient") ("text" "string" "The message") ,seen) '("to" "text" "seen_version"))
       :call ,(lambda (a)
                (let ((to (drgnx-coord-mcp--resolve-recipient (plist-get a :to))))
                  (drgnx-coord-mcp--write
                   (drgnx-coord-send :job (getenv "DRGNX_JOB") :sender (drgnx-coord-mcp--me) :recipient to
                                     :text (plist-get a :text) :seen (drgnx-coord-mcp--seen a))))))
      ("read_inbox" :description "Messages to you not read yet (they become read)"
       :schema ,(funcall s nil)
       :call ,(lambda (_a) (let ((msgs (drgnx-coord-inbox (drgnx-coord-mcp--me) '("queued" "delivered"))))
                             (dolist (m msgs) (drgnx-coord-mark (plist-get m :id) "read"))
                             (drgnx-coord-mcp--jsonable msgs))))
      ("ack" :description "Say you acted on a message"
       :schema ,(funcall s '(("id" "integer" "The message's id")) '("id"))
       :call ,(lambda (a)
                (let ((m (drgnx-coord-message (plist-get a :id))))
                  (unless (and m (equal (plist-get m :recipient) (drgnx-coord-mcp--me)))
                    (error "No message %s for you" (plist-get a :id))))
                (drgnx-coord-mark (plist-get a :id) "acted") (drgnx-coord-mcp--notify-hub) "acted"))
      ("read_decisions" :description "The decision log since a version (0: all), and the current version"
       :schema ,(funcall s '(("since" "integer" "The last version you read (0 for all)")))
       :call ,(lambda (a)
                (let ((v (drgnx-coord-version)) (me (getenv "DRGNX_AGENT")))
                  (when (and me (not (string-empty-p me))) (drgnx-coord-set-seen me v))   ; the hub stops telling it
                  (drgnx-coord-mcp--jsonable (list :version v :decisions (drgnx-coord-decisions-since (or (plist-get a :since) 0)))))))
      ("record_decision"
       :description "Record a decision: build, wait, wont-build or replaces.  Inside your own task it is current; about anything else it is proposed (the reviewer and the user decide)"
       :schema ,(funcall s `(("kind" "string" "build, wait, wont-build or replaces") ("subject" "string" "What it is about")
                             ("task" "string" "The task it concerns") ("paths" "string" "Files or paths it covers")
                             ("reason" "string" "Why") ("replaces" "integer" "The decision it replaces") ,seen)
                         '("kind" "subject" "reason" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--write
                           (drgnx-coord-decide :kind (plist-get a :kind) :subject (plist-get a :subject) :task (plist-get a :task)
                                               :paths (plist-get a :paths) :reason (plist-get a :reason)
                                               :author (drgnx-coord-mcp--me) :replaces (plist-get a :replaces)
                                               :job (getenv "DRGNX_JOB") :seen (drgnx-coord-mcp--seen a)))))
      ("claim_task" :description "Claim a ready task (a lease, kept while you work on it)"
       :schema ,(funcall s `(("task" "string" "The task's id") ,seen) '("task" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--write
                           (drgnx-coord-claim (plist-get a :task) (drgnx-coord-mcp--me) (drgnx-coord-mcp--seen a)))))
      ("update_task" :description "Set your task's status: running, needs-input, in-review or failed (in a job: running, needs-input or in-review)"
       :schema ,(funcall s `(("task" "string" "The task's id") ("status" "string" "The new status") ,seen)
                         '("task" "status" "seen_version"))
       :call ,(lambda (a)
                ;; in a job, a task is done when its review passed and it is merged: never by its agent's word; outside
                ;; one an agent may also fail it, and complete_task finishes it
                (let ((job (getenv "DRGNX_JOB")))
                  (unless (member (plist-get a :status) (append '("running" "needs-input" "in-review") (and (not job) '("failed"))))
                    (error (if job "In a job, a task's status is running, needs-input or in-review (complete_task); review and merge make it done"
                             "A task's status is running, needs-input, in-review or failed (complete_task finishes it)"))))
                (drgnx-coord-mcp--write
                 (drgnx-coord-set-status (plist-get a :task) (drgnx-coord-mcp--me) (plist-get a :status)
                                         (drgnx-coord-mcp--seen a)))))
      ("complete_task" :description "Your task is done (in a job: it goes to review, then is merged)"
       :schema ,(funcall s `(("task" "string" "The task's id") ,seen) '("task" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--write
                           (drgnx-coord-set-status (plist-get a :task) (drgnx-coord-mcp--me)
                                                   (if (getenv "DRGNX_JOB") "in-review" "done") (drgnx-coord-mcp--seen a)))))
      ("task_status" :description "The job's tasks: status, agent, dependencies"
       :schema ,(funcall s '(("job" "string" "The job (default: yours)")))
       :call ,(lambda (a) (drgnx-coord-mcp--jsonable (drgnx-coord-tasks (or (plist-get a :job) (getenv "DRGNX_JOB"))))))
      ("work_status" :description "The work tracker's plans: what `drgnx work status --json' gives, one object per plan (tasks, steps, todos as [done, all], commits, branch, merged)"
       :schema ,(funcall s nil)
       ;; drgnx-mcp--json decodes json-serialize's UTF-8 bytes, so a non-ASCII title reaches the agent intact
       :call ,(lambda (_a) (vconcat (mapcar #'drgnx-work--json-row (drgnx-work--status-rows)))))
      ("escalate" :description "Ask the user to decide something (a clash, a question): queued for them (the job window shows it); go on with what does not depend on it"
       :schema ,(funcall s `(("subject" "string" "What it is about") ("text" "string" "What needs deciding") ,seen)
                         '("subject" "text" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--write
                           (drgnx-coord-send :job (getenv "DRGNX_JOB") :sender (drgnx-coord-mcp--me) :recipient "user"
                                             :text (format "[escalation] %s: %s" (plist-get a :subject) (plist-get a :text))
                                             :seen (drgnx-coord-mcp--seen a))))))))

(defun drgnx-coord-mcp-main ()
  "Batch entry: serve the coordination tools on stdin/stdout."
  (drgnx-mcp-serve "drgnx" (drgnx-coord-mcp-tools)))

(defun drgnx-coord-mcp-server-spec (agent &rest props)
  "The ACP `mcpServers' entry that gives AGENT (its session's name) the coordination tools.  PROPS: :job, :task."
  ;; the agent starts this with the default SIGPIPE (libuv resets it): the command ignores it itself
  (let ((command (drgnx-command-ignoring-sigpipe
                  (list (expand-file-name invocation-name invocation-directory)
                        "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                        "-l" "drgnx-coord-mcp" "-f" "drgnx-coord-mcp-main"))))
    (list :name "drgnx"
          :command (car command) :args (vconcat (cdr command))
          :env (vconcat (delq nil (append (list (list :name "DRGNX_AGENT" :value agent)
                                                (and (plist-get props :job) (list :name "DRGNX_JOB" :value (plist-get props :job)))
                                                (and (plist-get props :task) (list :name "DRGNX_TASK" :value (plist-get props :task))))
                                          (mapcar (lambda (n) (let ((v (getenv n))) (and v (list :name n :value v))))
                                                  '("DRGNX_DATA_DIR" "XDG_STATE_HOME" "XDG_DATA_HOME" "XDG_RUNTIME_DIR"))))))))

(provide 'drgnx-coord-mcp)
;;; drgnx-coord-mcp.el ends here
