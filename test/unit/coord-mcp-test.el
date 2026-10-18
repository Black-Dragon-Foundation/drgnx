;;; coord-mcp-test.el --- batch tests: the coordination MCP server -*- lexical-binding: t -*-
;; The server runs as a child batch Emacs, as an agent would start it; the test speaks JSON-RPC over its stdio.
(require 'ert)
(require 'drgnx-coord)
(require 'drgnx-coord-mcp)

(defvar drgnx-coord-mcp-test--out nil)

(defun drgnx-coord-mcp-test--start (env)
  "The server with ENV (\"NAME=value\"…) added; its process."
  (let ((process-environment (append env process-environment)))
    (setq drgnx-coord-mcp-test--out "")
    (make-process :name "coord-mcp" :noquery t :connection-type 'pipe :coding 'utf-8-unix
                  :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                 "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                                 "-l" "drgnx-coord-mcp" "-f" "drgnx-coord-mcp-main")
                  :filter (lambda (_p s) (setq drgnx-coord-mcp-test--out (concat drgnx-coord-mcp-test--out s))))))

(defvar drgnx-coord-mcp-test--id 0)

(defun drgnx-coord-mcp-test--rpc (proc method &optional params)
  "Send METHOD and wait for its answer (a plist)."
  (let ((id (cl-incf drgnx-coord-mcp-test--id)) (answer nil))
    (process-send-string proc (concat (json-serialize (list :jsonrpc "2.0" :id id :method method :params (or params (make-hash-table)))) "\n"))
    (let ((deadline (+ (float-time) 10)))
      (while (and (not answer) (< (float-time) deadline))
        (accept-process-output proc 0.05)
        (dolist (line (split-string drgnx-coord-mcp-test--out "\n" t))
          (let ((j (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil))))
            (when (equal (plist-get j :id) id) (setq answer j))))))
    answer))

(defun drgnx-coord-mcp-test--tool (proc name args)
  "Call tool NAME with ARGS: (TEXT . IS-ERROR)."
  (let* ((r (plist-get (drgnx-coord-mcp-test--rpc proc "tools/call" (list :name name :arguments (or args (make-hash-table)))) :result)))
    (cons (plist-get (aref (plist-get r :content) 0) :text) (plist-get r :isError))))

(defmacro drgnx-coord-mcp-test--with (env &rest body)
  "BODY with a store in a temp data dir (job j: tasks 1, 2), the server running as PROC with ENV."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-coord-mcp" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" dir) (concat "XDG_STATE_HOME=" dir "state")) process-environment))
          (drgnx-work-db--handles nil) (proc nil))
     (unwind-protect
         (progn
           (drgnx-coord-job-create :id "j" :tasks '((:n 1 :title "one") (:n 2 :title "two")))
           (setq proc (drgnx-coord-mcp-test--start ,env))
           (drgnx-coord-mcp-test--rpc proc "initialize" (list :protocolVersion "2025-06-18" :capabilities (make-hash-table)
                                                              :clientInfo (list :name "t" :version "1")))
           ,@body)
       (when (process-live-p proc) (delete-process proc))
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(ert-deftest drgnx-coord-mcp/tools-are-listed-and-a-claim-goes-through ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a" "DRGNX_JOB=j")
    (let ((tools (mapcar (lambda (x) (plist-get x :name)) (plist-get (plist-get (drgnx-coord-mcp-test--rpc proc "tools/list") :result) :tools))))
      (should (equal (sort (copy-sequence tools) #'string<)
                     '("ack" "claim_task" "complete_task" "escalate" "list_agents" "read_decisions" "read_inbox"
                       "record_decision" "send_message" "task_status" "update_task"))))
    (let ((r (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version (drgnx-coord-version)))))
      (should-not (cdr r))
      (should (string-search "\"ok\":true" (car r))))
    (should (string-search "\"agent\":\"a\"" (car (drgnx-coord-mcp-test--tool proc "task_status" nil))))))

(ert-deftest drgnx-coord-mcp/a-held-write-says-so-and-lists-the-changes ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a" "DRGNX_JOB=j")
    (drgnx-coord-decide :kind "wont-build" :subject "the legacy importer" :reason "dropped" :author "user" :seen 0)
    (drgnx-work-db-close-all)
    (let ((r (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version 0))))
      (should (string-prefix-p "HELD: the decision log moved on" (car r)))
      (should (string-search "the legacy importer" (car r))))
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "ready"))
    ;; read the decisions, then the claim goes through
    (let* ((d (car (drgnx-coord-mcp-test--tool proc "read_decisions" (list :since 0))))
           (v (plist-get (json-parse-string d :object-type 'plist) :version)))
      (should (= v 1))
      (should (string-search "\"ok\":true" (car (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version v))))))))

(ert-deftest drgnx-coord-mcp/inbox-read-and-ack-move-the-states ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a" "DRGNX_JOB=j")
    (let ((id (plist-get (drgnx-coord-send :job "j" :sender "b" :recipient "a" :text "the schema changed" :seen 0) :id)))
      (drgnx-work-db-close-all)
      (should (string-search "the schema changed" (car (drgnx-coord-mcp-test--tool proc "read_inbox" nil))))
      (should (equal (plist-get (drgnx-coord-message id) :state) "read"))
      (drgnx-coord-mcp-test--tool proc "ack" (list :id id))
      (drgnx-work-db-close-all)
      (should (equal (plist-get (drgnx-coord-message id) :state) "acted"))
      ;; sending: the message is in b's inbox, from a
      (drgnx-coord-mcp-test--tool proc "send_message" (list :to "b" :text "thanks" :seen_version (drgnx-coord-version)))
      (drgnx-work-db-close-all)
      (should (equal (plist-get (car (drgnx-coord-inbox "b")) :sender) "a")))))

(ert-deftest drgnx-coord-mcp/update-task-outside-a-job-takes-only-known-statuses ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a")           ; no DRGNX_JOB: a lone agent
    (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version (drgnx-coord-version)))
    (dolist (status '("done" "ready" "claimed" "bogus" ""))
      (should (cdr (drgnx-coord-mcp-test--tool proc "update_task" (list :task "j#1" :status status :seen_version (drgnx-coord-version))))))
    (drgnx-work-db-close-all)
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "claimed"))
    (dolist (status '("running" "needs-input" "in-review" "failed"))
      (should-not (cdr (drgnx-coord-mcp-test--tool proc "update_task" (list :task "j#1" :status status :seen_version (drgnx-coord-version))))))
    (drgnx-work-db-close-all)
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "failed"))))

(ert-deftest drgnx-coord-mcp/ack-only-your-own-messages ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a" "DRGNX_JOB=j")
    (let ((mine (plist-get (drgnx-coord-send :job "j" :sender "b" :recipient "a" :text "for a" :seen 0) :id))
          (theirs (plist-get (drgnx-coord-send :job "j" :sender "b" :recipient "c" :text "for c" :seen 0) :id)))
      (drgnx-coord-mark theirs "read")
      (drgnx-work-db-close-all)
      (should (cdr (drgnx-coord-mcp-test--tool proc "ack" (list :id theirs))))
      (should (cdr (drgnx-coord-mcp-test--tool proc "ack" (list :id 9999))))
      (drgnx-work-db-close-all)
      (should (equal (plist-get (drgnx-coord-message theirs) :state) "read"))
      (should-not (cdr (drgnx-coord-mcp-test--tool proc "ack" (list :id mine))))
      (drgnx-work-db-close-all)
      (should (equal (plist-get (drgnx-coord-message mine) :state) "acted")))))

(ert-deftest drgnx-coord-mcp/no-identity-no-writes ()
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT")
    (should (cdr (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version 0))))
    (should (cdr (drgnx-coord-mcp-test--tool proc "send_message" (list :to "b" :text "x" :seen_version 0))))
    (should-not (cdr (drgnx-coord-mcp-test--tool proc "read_decisions" (list :since 0))))))   ; reading is fine

(ert-deftest drgnx-coord-mcp/a-job-agent-cannot-skip-review ()
  ;; in a job, done comes from the review and the merge — never from the agent's update_task
  (drgnx-coord-mcp-test--with '("DRGNX_AGENT=a" "DRGNX_JOB=j")
    (drgnx-coord-mcp-test--tool proc "claim_task" (list :task "j#1" :seen_version (drgnx-coord-version)))
    (dolist (status '("done" "failed" "ready"))
      (should (cdr (drgnx-coord-mcp-test--tool proc "update_task" (list :task "j#1" :status status :seen_version (drgnx-coord-version))))))
    (drgnx-work-db-close-all)
    (should (equal (plist-get (drgnx-coord-task "j#1") :status) "claimed"))
    (should-not (cdr (drgnx-coord-mcp-test--tool proc "update_task" (list :task "j#1" :status "needs-input" :seen_version (drgnx-coord-version)))))))

(ert-deftest drgnx-coord-mcp/the-server-spec-for-acp ()
  (let* ((process-environment (append '("DRGNX_DATA_DIR=/d" "XDG_STATE_HOME=/s") process-environment))
         (spec (drgnx-coord-mcp-server-spec "agent one" :job "j" :task "j#1"))
         (env (mapcar (lambda (e) (cons (plist-get e :name) (plist-get e :value))) (plist-get spec :env))))
    (should (equal (plist-get spec :name) "drgnx"))
    (should (file-executable-p (plist-get spec :command)))
    (should (member "drgnx-coord-mcp-main" (append (plist-get spec :args) nil)))
    (should (equal (cdr (assoc "DRGNX_AGENT" env)) "agent one"))
    (should (equal (cdr (assoc "DRGNX_TASK" env)) "j#1"))
    (should (equal (cdr (assoc "DRGNX_DATA_DIR" env)) "/d"))))

;;; coord-mcp-test.el ends here
