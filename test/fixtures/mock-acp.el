;;; mock-acp.el --- A mock ACP agent for tests: batch Emacs, JSON-RPC 2.0, one object per line -*- lexical-binding: t -*-
;; sh mock-acp-stdin.sh emacs --batch -Q -l mock-acp.el
;; Its stdin is read by a `cat', so messages (session/cancel) arrive while a turn streams: of the FIFO
;; in MOCK_ACP_IN (made by mock-acp-stdin.sh, which copies stdin into it: any POSIX system), else of
;; /proc/PID/fd/0 (Linux).  What a turn does depends on words in the prompt:
;;   slow        ten chunks, 0.3 s apart (a turn to send into, to stop)
;;   stream N    (the whole prompt) N chunks of 100 characters, 50 a second
;;   tool        a tool call, pending then completed
;;   plan        a plan with three entries
;;   subagent    a Task tool call with two child tool calls (_meta.parentToolCallId)
;;   permission  asks session/request_permission, then says which option it got
;;   write PATH  reads PATH (fs/read_text_file), proposes an edit (fs/write_text_file) inside an edit tool call
;;               with the diff (as claude-agent-acp's Write), says the answer
;;   crash       exits 3, "mock crashed" on stderr
;;   commit      commits in its directory: "agent work for $DRGNX_TASK"
;;   /compact    the context shrinks
;;   [drgnx task ID]  commits task.txt (legacy/a.txt when the prompt says legacy, ID.txt when it says own file), then read_decisions and
;;               complete_task through its MCP server
;;   [drgnx review ID]  says "VERDICT: pass" (or "VERDICT: fail: …" with MOCK_ACP_VERDICT=fail)
;;   [drgnx clash ID]  says "RECOMMEND: A because it was first" (MOCK_ACP_RECOMMEND=B: B; MOCK_ACP_CLASH_SLOW: 5 s later)
;;   crash-once  crashes when .mock-crashed is not in its directory (then makes it): the next agent works
;;   coord TOOL JSON  starts the first server of its mcpServers (session/new) and calls TOOL with the JSON arguments;
;;               says "coord: TEXT" (the tool's answer)
;;   meta        says "meta: JSON", the _meta its session/new or session/load got ("meta: none" without one)
;;   mode        says "mode: MODE", the mode session/set_mode last set ("mode: unset" before one)
;;   probe NAME…  tries each named escape and says "probe NAME: reached" or "probe NAME: blocked (WHY)", one line per
;;               name (a sandbox's tests: docs/develop/sandbox.md).  hub-socket hub-card hub-card-no-hello work-db
;;               coord-forged git-config git-hooks git-ref-main git-ref-job git-pointer git-objects-delete dot-env
;;               dirty-file emacs-server bus ssh-agent abstract-socket host-loopback ssh-key other-repo other-task env
;;               nested-git fsmonitor-plant, and connect HOST:PORT (through HTTPS_PROXY when set).  The paths are in
;;               MOCK_PROBE_* variables of its environment, which name paths and ids and never contents; a probe
;;               never says what it read (env says which variables are set, "reached (NAME,…)").  Writes open the file for appending nothing, so a file that exists is kept.
;;   anything else: "You said: …" in two chunks
;; Usage comes as a usage_update (:used :size 1000) at the end of each turn (claude-agent-acp's shape).
;; MOCK_ACP_NO_LOAD / MOCK_ACP_NO_STEER turn off session/load and steering; MOCK_ACP_STEER_FAILS
;; answers steering with an error; MOCK_ACP_LATE_CANCEL=SECS answers a cancel that late ("end_turn").
;; MOCK_ACP_LOG=FILE appends one line per session/new: "mcpServers " and the mcpServers it was given, as JSON.
;; MOCK_ACP_RATE_LIMIT answers every prompt with error 429 (a provider at its limit).
;; MOCK_ACP_SET_MODE_FAILS answers session/set_mode with an error; MOCK_ACP_SET_MODE_SLOW=SECS sets the mode and
;; answers that late.
(require 'cl-lib)
(require 'subr-x)

(defvar mock--next-id 100000)
(defvar mock--pending nil "Alist ID → callback for our requests to the client.")
(defvar mock--turns nil "Alist session → (:id PROMPT-ID :timers TIMERS).")
(defvar mock--history nil "Alist session → updates, oldest first (for session/load).")
(defvar mock--tokens nil "Alist session → tokens in context.")
(defvar mock--sessions 0)
(defvar mock--mcp nil "Alist session → the mcpServers it was given.")
(defvar mock--meta nil "Alist session → the _meta its session/new or session/load got, or `none'.")
(defvar mock--mode nil "Alist session → the mode session/set_mode set.")
(defvar mock--line nil "The JSON line being handled.")

(defun mock--line-meta ()
  "The _meta of the request being handled, its arrays kept (the line read again), or `none'."
  (let ((params (plist-get (json-parse-string mock--line :object-type 'plist :array-type 'array :null-object :null
                                              :false-object :false)
                           :params)))
    (if (plist-member params :_meta) (plist-get params :_meta) 'none)))

(defun mock--mcp-call (sid tool args)
  "Call TOOL with ARGS (JSON text) on SID's first MCP server; its answer's text, or nil."
  (let* ((spec (car (alist-get sid mock--mcp nil nil #'equal))) (out "") (done nil)
         (process-environment (append (mapcar (lambda (e) (concat (plist-get e :name) "=" (plist-get e :value))) (plist-get spec :env))
                                      process-environment))
         (p (and spec (make-process :name "mock-mcp" :command (cons (plist-get spec :command) (plist-get spec :args))
                                    :connection-type 'pipe :coding 'utf-8-unix :noquery t
                                    :filter (lambda (_p s) (setq out (concat out s)))))))
    (when p
      (process-send-string p "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n")
      (process-send-string p (format "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":%S,\"arguments\":%s}}\n"
                                     tool args))
      (let ((deadline (+ (float-time) 10)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output p 0.05)
          (dolist (line (split-string out "\n" t))
            (let ((j (ignore-errors (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object nil))))
              (when (equal (plist-get j :id) 2) (setq done (plist-get (car (plist-get (plist-get j :result) :content)) :text)))))))
      (delete-process p)
      done)))

(defun mock--task (sid task &optional text)
  "A job's task: commit a file for it (legacy/a.txt when TEXT, its prompt, says legacy; else task.txt), read the
decision log, complete the task; say what happened."
  (let ((file (cond ((and text (string-match-p "legacy" text)) "legacy/a.txt")
                    ((and text (string-match-p "own file" text)) (concat (replace-regexp-in-string "[^A-Za-z0-9-]" "-" task) ".txt"))
                    (t "task.txt"))))
    (call-process "sh" nil nil nil "-c" (format "mkdir -p %s && echo %s >> %s && git add %s && git commit -q -m %s"
                                                (shell-quote-argument (or (file-name-directory file) "."))
                                                (shell-quote-argument task) file file (shell-quote-argument (concat "work for " task)))))
  (let* ((d (mock--mcp-call sid "read_decisions" "{\"since\":0}"))
         (v (or (ignore-errors (plist-get (json-parse-string d :object-type 'plist) :version)) 0))
         (r (mock--mcp-call sid "complete_task" (format "{\"task\":%S,\"seen_version\":%d}" task v)))
         (tries 0))
    ;; like a real agent: a held write (the decision log moved on) is read and retried at the version it names, and so is
    ;; a call that got no answer in time — a task never ends open because a decision came in meanwhile
    (while (and (< (cl-incf tries) 4) (or (null r) (string-prefix-p "HELD:" r)))
      (let ((held (and r (string-match "seen_version \\([0-9]+\\)" r) (string-to-number (match-string 1 r)))))
        (setq r (mock--mcp-call sid "complete_task" (format "{\"task\":%S,\"seen_version\":%d}" task
                                                            (or held (ignore-errors (plist-get (json-parse-string (mock--mcp-call sid "read_decisions" "{\"since\":0}") :object-type 'plist) :version)) 0))))))
    (mock--steps sid (list (cons 0 (lambda () (mock--say sid (format "task done: %s" r))))))))

(defun mock--coord (sid tool args)
  "Start SID's first MCP server, call TOOL with ARGS (JSON text), say its answer; then end the turn."
  (let* ((spec (car (alist-get sid mock--mcp nil nil #'equal))) (out "") (done nil)
         (process-environment (append (mapcar (lambda (e) (concat (plist-get e :name) "=" (plist-get e :value))) (plist-get spec :env))
                                      process-environment))
         (p (and spec (make-process :name "mock-mcp" :command (cons (plist-get spec :command) (plist-get spec :args))
                                    :connection-type 'pipe :coding 'utf-8-unix :noquery t
                                    :filter (lambda (_p s) (setq out (concat out s)))))))
    (if (not p) (mock--steps sid (list (cons 0 (lambda () (mock--say sid "coord: no mcpServers")))))
      (process-send-string p "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n")
      (process-send-string p (format "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":%S,\"arguments\":%s}}\n"
                                     tool (if (string-empty-p args) "{}" args)))
      (let ((deadline (+ (float-time) 10)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output p 0.05)
          (dolist (line (split-string out "\n" t))
            (let ((j (ignore-errors (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object nil))))
              (when (equal (plist-get j :id) 2) (setq done (plist-get (car (plist-get (plist-get j :result) :content)) :text)))))))
      (delete-process p)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid (concat "coord: " (or done "no answer"))))))))))

;;;; Probes: `probe NAME…' tries each escape the sandbox must close and says "probe NAME: reached" or "probe NAME:
;;;; blocked (WHY)" per name.  The paths come from MOCK_PROBE_* variables; they name paths and ids, never contents, and a
;;;; probe never prints what it read.

(defun mock-probe--why (err)
  "The reason ERR (a signal) gives, as the system worded it (\"No such file or directory\")."
  (if (and (memq (car err) '(file-error file-missing permission-denied file-already-exists file-date-error))
           (stringp (nth 2 err)))
      (nth 2 err)
    (error-message-string err)))

(defun mock-probe--env (name) (let ((v (getenv name))) (and v (not (string-empty-p v)) v)))

(defun mock-probe--need (name)
  "The path in MOCK_PROBE_NAME, or a signal that the test did not give one."
  (or (mock-probe--env name) (error "%s is not set" name)))

(defun mock-probe--read (var)
  "Read one byte of the file VAR names."
  (with-temp-buffer (insert-file-contents-literally (mock-probe--need var) nil 0 1))
  t)

(defun mock-probe--open-for-write (var)
  "Open the file VAR names for writing, appending nothing (a file that exists is not changed)."
  (write-region "" nil (mock-probe--need var) t 'silent)
  t)

(defun mock-probe--connect-local (var)
  "Connect to the Unix socket VAR names (an abstract one starts with @)."
  (let* ((path (mock-probe--need var))
         (path (if (string-prefix-p "@" path) (concat "\0" (substring path 1)) path)))
    (delete-process (make-network-process :name "mock-probe" :family 'local :service path :noquery t))
    t))

(defun mock-probe--connect-tcp (host port)
  (delete-process (make-network-process :name "mock-probe" :host host :service port :noquery t))
  t)

(defun mock-probe--exchange (proc send done)
  "Send SEND to PROC and collect what comes back until DONE (a function of the text so far) holds, 5 s at most."
  (let ((out ""))
    (set-process-filter proc (lambda (_p s) (setq out (concat out s))))
    (process-send-string proc send)
    (let ((deadline (+ (float-time) 5)))
      (while (and (not (funcall done out)) (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.05)))
    (accept-process-output proc 0)
    out))

(defun mock-probe--hub (card hello)
  "Send the hub `job/card' dismiss for CARD (an id in an environment variable), after a `hello {cap}' when HELLO and
the cap file MOCK_PROBE_HUB_CAP names can be read.  t when the hub answers with a result; else a signal with its error."
  (let* ((proc (make-network-process :name "mock-probe" :family 'local :service (mock-probe--need "MOCK_PROBE_HUB_SOCKET")
                                     :noquery t :coding 'utf-8-unix))
         (cap (and hello (mock-probe--env "MOCK_PROBE_HUB_CAP") (file-readable-p (getenv "MOCK_PROBE_HUB_CAP"))
                   (with-temp-buffer (insert-file-contents (getenv "MOCK_PROBE_HUB_CAP")) (string-trim (buffer-string)))))
         (id (string-to-number (mock-probe--need card))))
    (unwind-protect
        (progn
          (when cap
            (mock-probe--exchange proc (concat (json-serialize (list :id 1 :method "hello" :params (list :cap cap))) "\n")
                                  (lambda (s) (string-match-p "\n" s))))
          (let* ((out (mock-probe--exchange proc (concat (json-serialize (list :id 2 :method "job/card"
                                                                               :params (list :card id :action "dismiss")))
                                                         "\n")
                                            (lambda (s) (string-match-p "\"id\":2" s))))
                 (line (seq-find (lambda (l) (string-match-p "\"id\":2" l)) (split-string out "\n" t)))
                 (reply (and line (json-parse-string line :object-type 'plist :null-object nil :false-object nil))))
            (cond ((null reply) (error "the hub did not answer"))
                  ((plist-get reply :error) (error "%s" (or (plist-get (plist-get reply :error) :message) "refused")))
                  (t t))))
      (delete-process proc))))

(defconst mock-probe--forged-inbox "probe-forged-inbox-for-OTHER"
  "The text the fixture leaves in the inbox of the agent `coord-forged' claims to be.")

(defun mock-probe--forged (sid)
  "Start the first of SID's MCP servers as another agent (DRGNX_AGENT=MOCK_PROBE_OTHER_AGENT), send \"user\" a message
with it and read its inbox.  t when the server answered as that agent, i.e. its inbox, which the fixture left a message in,
came back; a signal naming what happened otherwise (the call failed, or the server speaks as the session, whatever
the environment says: a bridge to the hub's server).  The verdict is the effect, never the spec's shape."
  (let* ((other (or (mock-probe--env "MOCK_PROBE_OTHER_AGENT") "OTHER"))
         (spec (car (alist-get sid mock--mcp nil nil #'equal)))
         (_ (unless spec (error "no mcpServers")))
         (env (append (plist-get spec :env) nil))
         (forged (plist-put (copy-sequence spec) :env
                            (vconcat (cons (list :name "DRGNX_AGENT" :value other)
                                           (seq-remove (lambda (e) (equal (plist-get e :name) "DRGNX_AGENT")) env)))))
         (mock--mcp (list (cons sid (list forged))))
         (sent (mock--mcp-call sid "send_message" (format "{\"to\":\"user\",\"text\":\"probe %d\",\"seen_version\":0}" (random 1000000))))
         (inbox (and sent (mock--mcp-call sid "read_inbox" "{}"))))
    (cond ((null sent) (error "the server gave no answer"))
          ((not (string-match-p "\"ok\" *: *true" sent)) (error "%s" (string-trim sent)))
          ((null inbox) (error "the server gave no inbox"))
          ((not (string-search mock-probe--forged-inbox inbox)) (error "the server did not speak as %s" other))
          (t t))))

(defun mock-probe--nested (var)
  "Plant a repository whose config runs a command of its own (touching MOCK_PROBE_FSMONITOR_CANARY) under the directory VAR names."
  (let ((git (expand-file-name ".git" (mock-probe--need var))))
    (make-directory git t)
    (write-region "ref: refs/heads/main\n" nil (expand-file-name "HEAD" git) nil 'silent)
    (write-region (format "[core]\n\tfsmonitor = touch %s\n" (shell-quote-argument (mock-probe--need "MOCK_PROBE_FSMONITOR_CANARY")))
                  nil (expand-file-name "config" git) nil 'silent)
    t))

(defun mock-probe--plant ()
  "Plant a `core.fsmonitor' and a post-merge hook that touch MOCK_PROBE_FSMONITOR_CANARY in the copy of .git MOCK_PROBE_OWN_GIT names."
  (let* ((git (mock-probe--need "MOCK_PROBE_OWN_GIT")) (canary (mock-probe--need "MOCK_PROBE_FSMONITOR_CANARY"))
         (hook (expand-file-name "hooks/post-merge" git)))
    (write-region (format "[core]\n\tfsmonitor = touch %s\n" (shell-quote-argument canary)) nil (expand-file-name "config" git) t 'silent)
    (make-directory (file-name-directory hook) t)
    (write-region (format "#!/bin/sh\ntouch %s\n" (shell-quote-argument canary)) nil hook nil 'silent)
    (set-file-modes hook #o755)
    t))

(defun mock-probe--env-names ()
  "The names of the variables a sandboxed agent must not have that are set here (a string), else a signal."
  (let ((found (seq-filter #'mock-probe--env
                           (append '("SSH_AUTH_SOCK" "DBUS_SESSION_BUS_ADDRESS" "XDG_RUNTIME_DIR" "DRGNX_DATA_DIR" "DISPLAY"
                                     "WAYLAND_DISPLAY" "OPENROUTER_API_KEY" "ANTHROPIC_API_KEY")
                                   (split-string (or (getenv "MOCK_PROBE_ENV_FORBIDDEN") "") "," t)))))
    (if found (string-join found ",") (error "none of them is set"))))

(defun mock-probe--connect (target)
  "Connect to TARGET (HOST:PORT) through HTTPS_PROXY when it is set (a CONNECT), else directly; t on success."
  (unless (string-match "\\`\\(.+\\):\\([0-9]+\\)\\'" target) (error "connect wants HOST:PORT"))
  (let ((host (match-string 1 target)) (port (string-to-number (match-string 2 target)))
        (proxy (or (mock-probe--env "HTTPS_PROXY") (mock-probe--env "https_proxy"))))
    (if (not proxy) (mock-probe--connect-tcp host port)
      (unless (string-match "\\`\\(?:[a-z]+://\\)?\\([^:/]+\\):\\([0-9]+\\)" proxy) (error "HTTPS_PROXY is not host:port"))
      (let* ((proc (make-network-process :name "mock-probe" :host (match-string 1 proxy) :service (string-to-number (match-string 2 proxy))
                                         :noquery t :coding 'utf-8-unix))
             (out (unwind-protect
                      (mock-probe--exchange proc (format "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" host port host port)
                                            (lambda (s) (string-match-p "\r?\n" s)))
                    (delete-process proc))))
        (if (string-match "\\`HTTP/[0-9.]+ \\(2[0-9][0-9]\\)" out) t
          (error "proxy said %s" (or (car (split-string out "\r?\n" t)) "nothing")))))))

(defun mock-probe--run (sid name arg)
  "Try the probe NAME (with ARG for connect); the line that reports it."
  (condition-case err
      (let ((done nil))
        (setq done
              (pcase name
                ("hub-socket" (mock-probe--connect-local "MOCK_PROBE_HUB_SOCKET"))
                ("hub-card" (mock-probe--hub "MOCK_PROBE_CARD" t))
                ("hub-card-no-hello" (mock-probe--hub "MOCK_PROBE_CARD_NO_HELLO" nil))
                ("work-db" (mock-probe--open-for-write "MOCK_PROBE_WORK_DB"))
                ("coord-forged" (mock-probe--forged sid))
                ("git-config" (mock-probe--open-for-write "MOCK_PROBE_GIT_CONFIG"))
                ("git-hooks" (mock-probe--open-for-write "MOCK_PROBE_GIT_HOOKS"))
                ("git-ref-main" (mock-probe--open-for-write "MOCK_PROBE_GIT_REF_MAIN"))
                ("git-ref-job" (mock-probe--open-for-write "MOCK_PROBE_GIT_REF_JOB"))
                ("git-pointer" (mock-probe--open-for-write "MOCK_PROBE_GIT_POINTER"))
                ("git-objects-delete" (delete-file (mock-probe--need "MOCK_PROBE_GIT_OBJECT")) t)
                ("dot-env" (mock-probe--read "MOCK_PROBE_DOT_ENV"))
                ("dirty-file" (mock-probe--read "MOCK_PROBE_DIRTY_FILE"))
                ("emacs-server" (mock-probe--connect-local "MOCK_PROBE_EMACS_SERVER"))
                ("bus" (mock-probe--connect-local "MOCK_PROBE_BUS"))
                ("ssh-agent" (mock-probe--connect-local "MOCK_PROBE_SSH_AGENT"))
                ("abstract-socket" (mock-probe--connect-local "MOCK_PROBE_ABSTRACT"))
                ("host-loopback" (let ((target (mock-probe--need "MOCK_PROBE_LOOPBACK")))
                                   (string-match "\\`\\(.+\\):\\([0-9]+\\)\\'" target)
                                   (mock-probe--connect-tcp (match-string 1 target) (string-to-number (match-string 2 target)))))
                ("ssh-key" (mock-probe--read "MOCK_PROBE_SSH_KEY"))
                ("other-repo" (mock-probe--read "MOCK_PROBE_OTHER_REPO"))
                ("other-task" (mock-probe--read "MOCK_PROBE_OTHER_TASK"))
                ("env" (mock-probe--env-names))
                ("nested-git" (mock-probe--nested "MOCK_PROBE_NESTED"))
                ("fsmonitor-plant" (mock-probe--plant))
                ("connect" (mock-probe--connect (or arg "")))
                (_ (error "no such probe"))))
        (format "probe %s: reached%s" name (if (stringp done) (format " (%s)" done) "")))
    (error (format "probe %s: blocked (%s)" name (mock-probe--why err)))))

(defun mock-probe--report (sid text)
  "The report for the prompt TEXT (`probe NAME…'): one line per name."
  (let ((words (cdr (split-string text "[ \t\n]+" t))) lines)
    (while words
      (let ((name (pop words)))
        (push (mock-probe--run sid name (and (equal name "connect") (pop words))) lines)))
    (string-join (nreverse lines) "\n")))

(defun mock--send (obj) (send-string-to-terminal (concat (json-serialize obj) "\n")))   ; flushed (princ is buffered)
(defun mock--respond (id result) (mock--send (list :jsonrpc "2.0" :id id :result (or result :null))))
(defun mock--error (id code msg) (mock--send (list :jsonrpc "2.0" :id id :error (list :code code :message msg))))

(defun mock--state-file (sid) (and (getenv "MOCK_ACP_STATE") (expand-file-name (concat sid ".eld") (getenv "MOCK_ACP_STATE"))))

(defun mock--update (sid update &optional no-history)
  (unless no-history
    (setf (alist-get sid mock--history nil nil #'equal) (append (alist-get sid mock--history nil nil #'equal) (list update)))
    (when-let* ((f (mock--state-file sid)))           ; for session/load from another process
      (with-temp-file f (prin1 (alist-get sid mock--history nil nil #'equal) (current-buffer)))))
  (mock--send (list :jsonrpc "2.0" :method "session/update" :params (list :sessionId sid :update update))))

(defun mock--say (sid text)
  (setf (alist-get sid mock--tokens 0 nil #'equal) (+ (alist-get sid mock--tokens 0 nil #'equal) (length text)))
  (mock--update sid (list :sessionUpdate "agent_message_chunk" :content (list :type "text" :text text))))

(defun mock--ask (method params cb)
  (let ((id (cl-incf mock--next-id)))
    (push (cons id cb) mock--pending)
    (mock--send (list :jsonrpc "2.0" :id id :method method :params params))))

(defun mock--finish (sid reason)
  (when-let* ((turn (alist-get sid mock--turns nil nil #'equal)))
    (mapc #'cancel-timer (plist-get turn :timers))
    (setf (alist-get sid mock--turns nil 'remove #'equal) nil)
    (mock--update sid (list :sessionUpdate "usage_update" :used (alist-get sid mock--tokens 0 nil #'equal) :size 1000) t)
    (mock--respond (plist-get turn :id) (list :stopReason reason))))

(defun mock--steps (sid steps)
  "Run STEPS: (DELAY . THUNK)…, delays cumulative; then end the turn."
  (let ((at 0) timers)
    (pcase-dolist (`(,delay . ,fn) steps)
      (setq at (+ at delay))
      (push (run-at-time at nil fn) timers))
    (push (run-at-time (+ at 0.01) nil (lambda () (mock--finish sid "end_turn"))) timers)
    (plist-put (alist-get sid mock--turns nil nil #'equal) :timers timers)))

(defun mock--prompt (id params)
  (when (alist-get (plist-get params :sessionId) mock--turns nil nil #'equal)   ; a prompt while one runs
    (mock--say (plist-get params :sessionId) "OVERLAPPING PROMPT "))
  (let* ((sid (plist-get params :sessionId))
         (text (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get params :prompt))) " ")))
    (setf (alist-get sid mock--turns nil nil #'equal) (list :id id))
    (setf (alist-get sid mock--tokens 0 nil #'equal) (+ (alist-get sid mock--tokens 0 nil #'equal) (length text)))
    (mock--update sid (list :sessionUpdate "user_message_chunk" :content (list :type "text" :text text)) )
    (cond
     ((getenv "MOCK_ACP_RATE_LIMIT")
      (setf (alist-get sid mock--turns nil 'remove #'equal) nil)
      (mock--error id 429 "rate limit exceeded (429): try again later"))
     ;; crash-once: the first agent in this directory crashes, the next one works
     ((and (string-match-p "crash-once" text) (not (file-exists-p ".mock-crashed")))
      (write-region "" nil ".mock-crashed" nil 'silent)
      (message "mock crashed") (sleep-for 0.1)
      (kill-emacs 3))
     ;; a reviewer: VERDICT: pass, or fail when MOCK_ACP_VERDICT=fail
     ((string-match-p "\\[drgnx review " text)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid (if (equal (getenv "MOCK_ACP_VERDICT") "fail")
                                                                   "Looked at it.\nVERDICT: fail: rename foo to bar"
                                                                 "Looked at it.\nVERDICT: pass")))))))
     ;; the user discusses a clash with its reviewer: it changes its mind to B
     ((string-prefix-p "The user asks:" text)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid "Fair point.\nRECOMMEND: B after your question"))))))
     ;; a clash reviewer: RECOMMEND: A (or MOCK_ACP_RECOMMEND's side)
     ((string-match-p "\\[drgnx clash " text)
      (mock--steps sid (list (cons (if (getenv "MOCK_ACP_CLASH_SLOW") 5 0)
                                   (lambda () (mock--say sid (format "Read both sides.\nRECOMMEND: %s because it was first"
                                                                     (or (getenv "MOCK_ACP_RECOMMEND") "A"))))))))
     ((string-match "\\[drgnx task \\([^] ]+\\)" text)
      (mock--task sid (match-string 1 text) text))
     ((string-match-p "\\`probe\\b" text)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid (mock-probe--report sid text)))))))
     ((string-match "\\`coord \\([a-z_]+\\) ?\\(.*\\)\\'" text)
      (mock--coord sid (match-string 1 text) (match-string 2 text)))
     ((string-match-p "\\`meta\\'" text)
      (let ((meta (alist-get sid mock--meta 'none nil #'equal)))
        (mock--steps sid (list (cons 0 (lambda () (mock--say sid (concat "meta: " (if (eq meta 'none) "none" (json-serialize meta))))))))))
     ((string-match-p "\\`mode\\'" text)
      (let ((mode (alist-get sid mock--mode "unset" nil #'equal)))
        (mock--steps sid (list (cons 0 (lambda () (mock--say sid (concat "mode: " mode))))))))
     ((string-match-p "crash" text)
      (message "mock crashed") (sleep-for 0.1)
      (kill-emacs 3))
     ((string-match-p "\\`commit" text)               ; a commit in its directory, naming the task it was given
      (call-process "sh" nil nil nil "-c" "echo x >> agent.txt && git add agent.txt && git commit -q -m \"agent work for $DRGNX_TASK\"")
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid "committed"))))))
     ((string-match "\\`stream \\([0-9]+\\)" text)    ; N chunks of 100 characters, 50 a second
      (mock--steps sid (cl-loop for i from 1 to (string-to-number (match-string 1 text))
                                collect (cons 0.02 (let ((i i))
                                                     (lambda () (mock--say sid (format "%-99s\n" (format "chunk %d" i)))))))))
     ((string-match-p "slow" text)
      (mock--steps sid (cl-loop for i from 1 to 10 collect (cons 0.3 (let ((i i)) (lambda () (mock--say sid (format "part %d " i))))))))
     ((string-match-p "\\`/compact" text)
      (setf (alist-get sid mock--tokens 0 nil #'equal) 50)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid "Compacted."))))))
     ((string-match-p "permission" text)
      (mock--ask "session/request_permission"
                 (list :sessionId sid
                       ;; "permission KIND :: TITLE [:: PATH]" chooses the tool; plain "permission" is rm -rf build
                       :toolCall (if (string-match "permission \\([a-z]+\\) :: \\([^:\n]*[^: \n]\\)\\(?: :: \\(.+\\)\\)?" text)
                                     (append (list :toolCallId "p1" :kind (match-string 1 text) :title (match-string 2 text))
                                             (and (match-string 3 text) (list :locations (vector (list :path (match-string 3 text))))))
                                   (list :toolCallId "p1" :title "Run rm -rf build" :kind "execute"))
                       :options (vector '(:optionId "allow" :name "Allow" :kind "allow_once")
                                        '(:optionId "reject" :name "Reject" :kind "reject_once")))
                 (lambda (res)
                   (let ((o (plist-get (car res) :outcome)))
                     (mock--steps sid (list (cons 0 (lambda () (mock--say sid (format "permission: %s"
                                                                                      (if (equal (plist-get o :outcome) "cancelled") "cancelled"
                                                                                        (plist-get o :optionId))))))))))))
     ((string-match "write \\([^ ]+\\)" text)
      (let ((path (match-string 1 text)))
        (mock--ask "fs/read_text_file" (list :sessionId sid :path path)
                   (lambda (res)
                     (let* ((lines (split-string (or (plist-get (car res) :content) "") "\n"))
                            (new (concat "CHANGED " (car lines) "\n" (string-join (cdr lines) "\n") "ADDED LINE\n")))
                       ;; as claude-agent-acp's Write does: an edit tool call with the diff, around the write request
                       (mock--update sid (list :sessionUpdate "tool_call" :toolCallId "w1" :title (concat "Write " path) :kind "edit"
                                               :status "pending" :content (vector (list :type "diff" :path path :newText new))))
                       (mock--ask "fs/write_text_file" (list :sessionId sid :path path :content new)
                                  (lambda (res2)
                                    (mock--update sid (list :sessionUpdate "tool_call_update" :toolCallId "w1"
                                                            :status (if (cdr res2) "failed" "completed")))
                                    (mock--steps sid (list (cons 0 (lambda () (mock--say sid (if (cdr res2) "write refused" "write done")))))))))))))
     (t
      (mock--steps
       sid
       (append
        (when (string-match-p "tool" text)
          (list (cons 0 (lambda () (mock--update sid '(:sessionUpdate "tool_call" :toolCallId "t1" :title "Read file" :kind "read" :status "pending"))))
                (cons 0.05 (lambda () (mock--update sid '(:sessionUpdate "tool_call_update" :toolCallId "t1" :status "completed"
                                                                         :content [(:type "content" :content (:type "text" :text "file contents"))]))))))
        (when (string-match-p "plan" text)
          (list (cons 0 (lambda () (mock--update sid '(:sessionUpdate "plan" :entries [(:content "Read" :priority "high" :status "completed")
                                                                                       (:content "Write" :priority "medium" :status "in_progress")
                                                                                       (:content "Test" :priority "low" :status "pending")]))))))
        (when (string-match-p "subagent" text)
          (list (cons 0 (lambda () (mock--update sid '(:sessionUpdate "tool_call" :toolCallId "task1" :title "Task: explore" :kind "think" :status "in_progress"))))
                (cons 0.02 (lambda () (mock--update sid '(:sessionUpdate "tool_call" :toolCallId "c1" :title "Grep" :kind "search" :status "completed" :_meta (:parentToolCallId "task1")))))
                (cons 0.02 (lambda () (mock--update sid '(:sessionUpdate "tool_call" :toolCallId "c2" :title "Read" :kind "read" :status "completed" :_meta (:parentToolCallId "task1")))))
                (cons 0.02 (lambda () (mock--update sid '(:sessionUpdate "tool_call_update" :toolCallId "task1" :status "completed"))))))
        (list (cons 0 (lambda () (mock--update sid '(:sessionUpdate "agent_thought_chunk" :content (:type "text" :text "thinking…")))))
              (cons 0.02 (lambda () (mock--say sid "You said: ")))
              (cons 0.02 (lambda () (mock--say sid text))))))))))

(defun mock--handle (msg)
  (let ((id (plist-get msg :id)) (method (plist-get msg :method)) (params (plist-get msg :params)))
    (cond
     ((and id (not method))
      (when-let* ((cb (alist-get id mock--pending)))
        (setf (alist-get id mock--pending nil 'remove) nil)
        (funcall cb (cons (plist-get msg :result) (plist-get msg :error)))))
     ((equal method "initialize")
      (mock--respond id (list :protocolVersion 1
                              :agentCapabilities (list :loadSession (if (getenv "MOCK_ACP_NO_LOAD") :false t)
                                                       :_meta (list :steering (if (getenv "MOCK_ACP_NO_STEER") :false t)))
                              :authMethods [])))
     ((equal method "session/new")
      (let ((sid (format "mock-%d-%d" (emacs-pid) (cl-incf mock--sessions))))
        (setf (alist-get sid mock--mcp nil nil #'equal) (plist-get params :mcpServers)
              (alist-get sid mock--meta nil nil #'equal) (mock--line-meta))
        (when-let* ((log (getenv "MOCK_ACP_LOG")))      ; what the session was given: the launch rows read it
          (write-region (concat "mcpServers "
                                (json-serialize (or (plist-get params :mcpServers) []) :null-object :null :false-object :false)
                                "\n")
                        nil log 'append 'silent))
        (mock--respond id (list :sessionId sid))
        (run-at-time 0.01 nil (lambda () (mock--update sid '(:sessionUpdate "available_commands_update"
                                                                            :availableCommands [(:name "compact" :description "Compact the context")
                                                                                                (:name "review" :description "Review the changes")])
                                                       t)))))
     ((equal method "session/load")
      (if (getenv "MOCK_ACP_NO_LOAD") (mock--error id -32601 "session/load is not supported")
        (let* ((sid (plist-get params :sessionId))
               (f (mock--state-file sid))
               (hist (or (alist-get sid mock--history nil nil #'equal)
                         (and f (file-readable-p f) (with-temp-buffer (insert-file-contents f) (read (current-buffer)))))))
          (setf (alist-get sid mock--history nil nil #'equal) hist
                (alist-get sid mock--meta nil nil #'equal) (mock--line-meta))
          (dolist (u hist) (mock--update sid u t))
          (mock--respond id nil))))
     ((equal method "session/prompt") (mock--prompt id params))
     ((equal method "session/cancel")
      (let ((sid (plist-get params :sessionId)) (late (getenv "MOCK_ACP_LATE_CANCEL")))
        (if late
            (let ((turn (alist-get sid mock--turns nil nil #'equal)))
              (when turn
                (mapc #'cancel-timer (plist-get turn :timers))
                (plist-put turn :timers (list (run-at-time (string-to-number late) nil (lambda () (mock--finish sid "end_turn")))))))
          (mock--finish sid "cancelled"))))
     ((equal method "_session/steering")
      (if (getenv "MOCK_ACP_STEER_FAILS") (when id (mock--error id -32601 "steering is not supported"))
        (let ((sid (plist-get params :sessionId))
              (text (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get params :prompt))) " ")))
          (mock--say sid (format "steered: %s " text))
          (when id (mock--respond id nil)))))
     ((equal method "session/set_mode")
      (let ((sid (plist-get params :sessionId)) (mode (plist-get params :modeId)) (slow (getenv "MOCK_ACP_SET_MODE_SLOW")))
        (cond ((getenv "MOCK_ACP_SET_MODE_FAILS") (mock--error id -32603 "setPermissionMode failed"))
              (slow (run-at-time (string-to-number slow) nil
                                 (lambda () (setf (alist-get sid mock--mode nil nil #'equal) mode) (mock--respond id nil))))
              (t (setf (alist-get sid mock--mode nil nil #'equal) mode) (mock--respond id nil)))))
     (id (mock--error id -32601 (format "%s: no such method" method))))))

(defvar mock--buf "")
(make-process :name "mock-in" :command (list "cat" (or (getenv "MOCK_ACP_IN") (format "/proc/%d/fd/0" (emacs-pid))))
              :connection-type 'pipe
              :coding 'utf-8-unix :noquery t
              :filter (lambda (_p s)
                        (setq mock--buf (concat mock--buf s))
                        (while (string-match "\n" mock--buf)
                          (let ((line (substring mock--buf 0 (match-beginning 0))))
                            (setq mock--buf (substring mock--buf (match-end 0)))
                            (unless (string-blank-p line)
                              (setq mock--line line)
                              (mock--handle (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object :false))))))
              :sentinel (lambda (_p _e) (kill-emacs 0)))
(while t (accept-process-output nil 0.05))
;;; mock-acp.el ends here
