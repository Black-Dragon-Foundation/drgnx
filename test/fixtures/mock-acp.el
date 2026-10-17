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
;;   /compact    the context shrinks
;;   anything else: "You said: …" in two chunks
;; Usage comes in the prompt result (:usage :inputTokens :outputTokens :contextWindow 1000).
;; MOCK_ACP_NO_LOAD / MOCK_ACP_NO_STEER turn off session/load and steering.
(require 'cl-lib)
(require 'subr-x)

(defvar mock--next-id 100000)
(defvar mock--pending nil "Alist ID → callback for our requests to the client.")
(defvar mock--turns nil "Alist session → (:id PROMPT-ID :timers TIMERS).")
(defvar mock--history nil "Alist session → updates, oldest first (for session/load).")
(defvar mock--tokens nil "Alist session → tokens in context.")
(defvar mock--sessions 0)

(defun mock--send (obj) (send-string-to-terminal (concat (json-serialize obj) "\n")))   ; flushed (princ is buffered)
(defun mock--respond (id result) (mock--send (list :jsonrpc "2.0" :id id :result (or result :null))))
(defun mock--error (id code msg) (mock--send (list :jsonrpc "2.0" :id id :error (list :code code :message msg))))

(defun mock--update (sid update &optional no-history)
  (unless no-history (setf (alist-get sid mock--history nil nil #'equal) (append (alist-get sid mock--history nil nil #'equal) (list update))))
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
    (mock--respond (plist-get turn :id)
                   (list :stopReason reason
                         :usage (list :inputTokens (alist-get sid mock--tokens 0 nil #'equal) :outputTokens 10 :contextWindow 1000)))))

(defun mock--steps (sid steps)
  "Run STEPS: (DELAY . THUNK)…, delays cumulative; then end the turn."
  (let ((at 0) timers)
    (pcase-dolist (`(,delay . ,fn) steps)
      (setq at (+ at delay))
      (push (run-at-time at nil fn) timers))
    (push (run-at-time (+ at 0.01) nil (lambda () (mock--finish sid "end_turn"))) timers)
    (plist-put (alist-get sid mock--turns nil nil #'equal) :timers timers)))

(defun mock--prompt (id params)
  (let* ((sid (plist-get params :sessionId))
         (text (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get params :prompt))) " ")))
    (setf (alist-get sid mock--turns nil nil #'equal) (list :id id))
    (setf (alist-get sid mock--tokens 0 nil #'equal) (+ (alist-get sid mock--tokens 0 nil #'equal) (length text)))
    (mock--update sid (list :sessionUpdate "user_message_chunk" :content (list :type "text" :text text)) )
    (cond
     ((string-match-p "crash" text)
      (message "mock crashed") (sleep-for 0.1)
      (kill-emacs 3))
     ((string-match-p "slow" text)
      (mock--steps sid (cl-loop for i from 1 to 10 collect (cons 0.3 (let ((i i)) (lambda () (mock--say sid (format "part %d " i))))))))
     ((string-match-p "\\`/compact" text)
      (setf (alist-get sid mock--tokens 0 nil #'equal) 50)
      (mock--steps sid (list (cons 0 (lambda () (mock--say sid "Compacted."))))))
     ((string-match-p "permission" text)
      (mock--ask "session/request_permission"
                 (list :sessionId sid :toolCall (list :toolCallId "p1" :title "Run rm -rf build" :kind "execute")
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
        (mock--respond id (list :sessionId sid))
        (run-at-time 0.01 nil (lambda () (mock--update sid '(:sessionUpdate "available_commands_update"
                                                              :availableCommands [(:name "compact" :description "Compact the context")
                                                                                  (:name "review" :description "Review the changes")])
                                                        t)))))
     ((equal method "session/load")
      (if (getenv "MOCK_ACP_NO_LOAD") (mock--error id -32601 "session/load is not supported")
        (let ((sid (plist-get params :sessionId)))
          (dolist (u (alist-get sid mock--history nil nil #'equal)) (mock--update sid u t))
          (mock--respond id nil))))
     ((equal method "session/prompt") (mock--prompt id params))
     ((equal method "session/cancel")
      (let ((sid (plist-get params :sessionId)))
        (mock--finish sid "cancelled")))
     ((equal method "_session/steer")
      (let ((sid (plist-get params :sessionId))
            (text (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get params :prompt))) " ")))
        (mock--say sid (format "steered: %s " text))
        (when id (mock--respond id nil))))
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
