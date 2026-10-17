;;; mock-acp.el --- A mock ACP agent for tests: batch Emacs, JSON-RPC 2.0, one object per line -*- lexical-binding: t -*-
;; emacs --batch -Q -l mock-acp.el
;; Its stdin is read by a `cat' of /proc/PID/fd/0, so messages (session/cancel) arrive while a turn
;; streams (Linux).  What a turn does depends on words in the prompt:
;;   slow        ten chunks, 0.3 s apart (a turn to send into, to stop)
;;   tool        a tool call, pending then completed
;;   plan        a plan with three entries
;;   subagent    a Task tool call with two child tool calls (_meta.parentToolCallId)
;;   permission  asks session/request_permission, then says which option it got
;;   write PATH  reads PATH (fs/read_text_file), proposes an edit (fs/write_text_file), says the answer
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
;;   anything else: "You said: …" in two chunks
;; Usage comes as a usage_update (:used :size 1000) at the end of each turn (claude-agent-acp's shape).
;; MOCK_ACP_NO_LOAD / MOCK_ACP_NO_STEER turn off session/load and steering; MOCK_ACP_STEER_FAILS
;; answers steering with an error; MOCK_ACP_LATE_CANCEL=SECS answers a cancel that late ("end_turn").
;; MOCK_ACP_RATE_LIMIT answers every prompt with error 429 (a provider at its limit).
(require 'cl-lib)
(require 'subr-x)

(defvar mock--next-id 100000)
(defvar mock--pending nil "Alist ID → callback for our requests to the client.")
(defvar mock--turns nil "Alist session → (:id PROMPT-ID :timers TIMERS).")
(defvar mock--history nil "Alist session → updates, oldest first (for session/load).")
(defvar mock--tokens nil "Alist session → tokens in context.")
(defvar mock--sessions 0)
(defvar mock--mcp nil "Alist session → the mcpServers it was given.")

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
         (r (mock--mcp-call sid "complete_task" (format "{\"task\":%S,\"seen_version\":%d}" task v))))
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
     ((string-match "\\`coord \\([a-z_]+\\) ?\\(.*\\)\\'" text)
      (mock--coord sid (match-string 1 text) (match-string 2 text)))
     ((string-match-p "crash" text)
      (message "mock crashed") (sleep-for 0.1)
      (kill-emacs 3))
     ((string-match-p "\\`commit" text)               ; a commit in its directory, naming the task it was given
      (call-process "sh" nil nil nil "-c" "echo x >> agent.txt && git add agent.txt && git commit -q -m \"agent work for $DRGNX_TASK\"")
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid "committed"))))))
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
                       (mock--ask "fs/write_text_file" (list :sessionId sid :path path :content new)
                                  (lambda (res2)
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
        (setf (alist-get sid mock--mcp nil nil #'equal) (plist-get params :mcpServers))
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
          (setf (alist-get sid mock--history nil nil #'equal) hist)
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
     (id (mock--error id -32601 (format "%s: no such method" method))))))

(defvar mock--buf "")
(make-process :name "mock-in" :command (list "cat" (format "/proc/%d/fd/0" (emacs-pid))) :connection-type 'pipe
              :coding 'utf-8-unix :noquery t
              :filter (lambda (_p s)
                        (setq mock--buf (concat mock--buf s))
                        (while (string-match "\n" mock--buf)
                          (let ((line (substring mock--buf 0 (match-beginning 0))))
                            (setq mock--buf (substring mock--buf (match-end 0)))
                            (unless (string-blank-p line)
                              (mock--handle (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object :false))))))
              :sentinel (lambda (_p _e) (kill-emacs 0)))
(while t (accept-process-output nil 0.05))
;;; mock-acp.el ends here
