;;; agent-check-test.el --- batch tests: MCP Test and Hook Test (a separate Emacs, masked, capped in time) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config)
(require 'drgnx-agent-check)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-mcp" drgnx-dir) nil t)

(defvar drgnx-agent-check-test--counter 0)

(defun drgnx-agent-check-test--marker ()
  "A text no other process has on its command line."
  (format "drgnx-mark-%d-%d-%d" (emacs-pid) (cl-incf drgnx-agent-check-test--counter) (random 100000)))

(defun drgnx-agent-check-test--emacs ()
  (expand-file-name invocation-name invocation-directory))

(defun drgnx-agent-check-test--stdio-item (mode marker &optional env kind)
  "An MCP server item running the mock in MODE with MARKER on its command line."
  (list :kind (or kind 'claude) :section 'mcp :name "mock" :from 'project :file "/project/.mcp.json"
        :spec (list :type 'stdio :command (drgnx-agent-check-test--emacs)
                    :args (list "--batch" "-Q" "-l" (expand-file-name "test/fixtures/mock-mcp.el" drgnx-dir)
                                "-f" "drgnx-mock-mcp-main" mode marker)
                    :env env)))

(defun drgnx-agent-check-test--http-item (port &optional headers kind)
  (list :kind (or kind 'claude) :section 'mcp :name "remote" :from 'project :file "/project/.mcp.json"
        :spec (list :type 'http :url (format "http://127.0.0.1:%d/mcp" port) :headers headers)))

(defun drgnx-agent-check-test--wait (start)
  "Call START with a callback and wait (the mock HTTP server is served meanwhile) for the result."
  (let ((result nil) (deadline (+ (float-time) 40)))
    (funcall start (lambda (r) (setq result r)))
    (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.05))
    result))

(defun drgnx-agent-check-test--marked (marker)
  "The pids of processes that have MARKER on their command line."
  (cl-loop for pid in (list-system-processes)
           when (string-search marker (or (alist-get 'args (process-attributes pid)) ""))
           collect pid))

(defun drgnx-agent-check-test--descendants ()
  "The pids of the processes that descend from this Emacs."
  (let ((rows (mapcar (lambda (pid) (cons pid (alist-get 'ppid (ignore-errors (process-attributes pid)))))
                      (list-system-processes)))
        (set (list (emacs-pid))) (changed t))
    (while changed
      (setq changed nil)
      (dolist (r rows)
        (when (and (memq (cdr r) set) (not (memq (car r) set)))
          (push (car r) set)
          (setq changed t))))
    (delq (emacs-pid) set)))

(defun drgnx-agent-check-test--gone-p (marker)
  "Non-nil when no process with MARKER is left (after a short while for the kernel)."
  (let ((deadline (+ (float-time) 3)))
    (while (and (drgnx-agent-check-test--marked marker) (< (float-time) deadline)) (sleep-for 0.1))
    (null (drgnx-agent-check-test--marked marker))))

(defun drgnx-agent-check-test--mcp (item root)
  (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-mcp item root cb))))

(defmacro drgnx-agent-check-test-env (&rest body)
  "BODY in the agent settings fixture (temp state dir), with the HTTP mock stopped afterwards."
  (declare (indent 0))
  `(drgnx-agent-config-test-env
     (unwind-protect (progn ,@body) (drgnx-mock-mcp-http-stop))))

(ert-deftest drgnx-agent-check/mcp-ok-lists-tools ()
  (drgnx-agent-check-test-env
    (let* ((marker (drgnx-agent-check-test--marker))
           (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "ok" marker) root)))
      (should (eq (plist-get r :status) 'ok))
      (should (equal (plist-get r :tools) '("mock_echo" "mock_add")))
      (should (floatp (plist-get r :time)))
      (should (< (plist-get r :time) 20))
      (should (string-match-p "mock-mcp ready" (plist-get r :stderr)))
      (should-not (plist-get r :error))
      (should (drgnx-agent-check-test--gone-p marker)))))

(ert-deftest drgnx-agent-check/mcp-http-ok ()
  (drgnx-agent-check-test-env
    (let* ((port (drgnx-mock-mcp-http-start "ok"))
           (r (drgnx-agent-check-test--mcp
               (drgnx-agent-check-test--http-item port '(("Authorization" . "Bearer tok-abcdef123456"))) root))
           (reqs (reverse drgnx-mock-mcp-http-requests)))
      (should (eq (plist-get r :status) 'ok))
      (should (equal (plist-get r :tools) '("mock_echo" "mock_add")))
      (should (equal (mapcar (lambda (q) (plist-get (plist-get q :json) :method)) reqs)
                     '("initialize" "notifications/initialized" "tools/list")))
      ;; the configured header goes with every request, the session id with all after the first
      (should (cl-every (lambda (q) (equal (cdr (assoc "authorization" (plist-get q :headers))) "Bearer tok-abcdef123456")) reqs))
      (should-not (assoc "mcp-session-id" (plist-get (nth 0 reqs) :headers)))
      (should (cl-every (lambda (q) (equal (cdr (assoc "mcp-session-id" (plist-get q :headers))) "mock-session-1"))
                        (cdr reqs)))
      (should (stringp (plist-get (plist-get (plist-get (nth 0 reqs) :json) :params) :protocolVersion)))
      ;; the token is never in the result
      (should-not (string-search "tok-abcdef123456" (prin1-to-string r))))))

(ert-deftest drgnx-agent-check/mcp-needs-login-says-how ()
  (drgnx-agent-check-test-env
    (let ((port (drgnx-mock-mcp-http-start "needs-login")))
      (pcase-dolist (`(,kind . ,how) '((claude . "/mcp") (codex . "codex mcp login remote") (gemini . "/mcp auth remote")))
        (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--http-item port nil kind) root)))
          (should (eq (plist-get r :status) 'needs-login))
          (should (string-search how (plist-get r :error))))))))

(ert-deftest drgnx-agent-check/hanging-server-times-out ()
  (drgnx-agent-check-test-env
    (let ((drgnx-agent-check-timeout 2))
      (dolist (mode '("hang" "fork-child"))
        (let* ((marker (drgnx-agent-check-test--marker))
               (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item mode marker) root)))
          (should (eq (plist-get r :status) 'timeout))
          (should (< (plist-get r :time) 8))
          (should (drgnx-agent-check-test--gone-p marker))))
      ;; an HTTP server that never answers
      (let* ((port (drgnx-mock-mcp-http-start "hang"))
             (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--http-item port) root)))
        (should (eq (plist-get r :status) 'timeout))))))

(ert-deftest drgnx-agent-check/the-editing-emacs-ends-a-check-that-does-not-end ()
  ;; the child's own timeout is 3 s; the grace period is made negative so this Emacs ends it after 1 s
  (drgnx-agent-check-test-env
    (let ((drgnx-agent-check-timeout 3)
          (drgnx-agent-check--grace -2)
          (marker (drgnx-agent-check-test--marker)))
      (let* ((result nil)
             (proc (drgnx-agent-check-mcp (drgnx-agent-check-test--stdio-item "fork-child" marker) root
                                          (lambda (r) (setq result r))))
             (child (process-id proc))
             (deadline (+ (float-time) 20)))
        (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.05))
        (should (eq (plist-get result :status) 'timeout))
        (should (string-search "was stopped" (plist-get result :error)))
        (should (< (plist-get result :time) 3))
        ;; the child Emacs, the server and the server's own child are all gone
        (should (drgnx-agent-check-test--gone-p marker))
        (should-not (memq child (list-system-processes)))))))

(ert-deftest drgnx-agent-check/secrets-are-on-no-command-line ()
  (drgnx-agent-check-test-env
    (let* ((drgnx-agent-check-timeout 3)
           (marker (drgnx-agent-check-test--marker))
           (item (drgnx-agent-check-test--stdio-item "hang" marker '(("API_KEY" . "s3cret-value-xyz"))))
           (hook (list :kind 'claude :section 'hook :name "h" :file "/f"
                       :spec (list :event "Stop" :timeout 3 :command "sleep 3174; : Bearer abc123def456")))
           (result nil) (hook-result nil) (seen nil))
      (drgnx-agent-check-mcp item root (lambda (r) (setq result r)))
      (drgnx-agent-check-hook hook root (lambda (r) (setq hook-result r)))
      (let ((until (+ (float-time) 1.5)))
        (while (< (float-time) until) (accept-process-output nil 0.1)))
      ;; both are running now: look at the command line of everything this Emacs started
      (dolist (pid (drgnx-agent-check-test--descendants))
        (let ((args (or (alist-get 'args (ignore-errors (process-attributes pid))) "")))
          (when (or (string-search "s3cret-value-xyz" args) (string-search "abc123def456" args))
            (push args seen))))
      (should (drgnx-agent-check-test--marked marker))
      (should (drgnx-agent-check-test--marked "sleep 3174"))
      (should-not seen)
      (let ((deadline (+ (float-time) 20)))
        (while (and (not (and result hook-result)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
      (should (eq (plist-get result :status) 'timeout)))))

(ert-deftest drgnx-agent-check/a-check-that-cannot-start-says-so ()
  (drgnx-agent-check-test-env
    (let ((r (drgnx-agent-check-test--wait
              (lambda (cb) (drgnx-agent-check-hook
                            (list :kind 'claude :section 'hook :name "h" :file "/f" :spec (list :event "Stop" :command "true"))
                            (expand-file-name "no-such-dir/" root) cb)))))
      (should-not (plist-get r :exit))
      (should (string-search "could not be started" (plist-get r :error))))))

(ert-deftest drgnx-agent-check/crash-shows-stderr ()
  (drgnx-agent-check-test-env
    (let* ((marker (drgnx-agent-check-test--marker))
           (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "crash" marker) root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-match-p "exit" (plist-get r :error)))
      (should (string-match-p "3" (plist-get r :error)))
      (should (string-search "cannot open its database" (plist-get r :stderr))))))

(ert-deftest drgnx-agent-check/flood-is-capped ()
  (drgnx-agent-check-test-env
    (let* ((marker (drgnx-agent-check-test--marker))
           (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "flood" marker) root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-match-p "too much" (plist-get r :error)))
      (should (<= (length (plist-get r :stderr)) 8300))
      (should (< (length (prin1-to-string r)) 20000))
      (should (< (plist-get r :time) 20))
      (should (drgnx-agent-check-test--gone-p marker)))))

(ert-deftest drgnx-agent-check/secrets-masked-in-output ()
  (drgnx-agent-check-test-env
    (let* ((marker (drgnx-agent-check-test--marker))
           (item (drgnx-agent-check-test--stdio-item
                  "echo-env" marker '(("MOCK_SECRET_ONE" . "s3cret-value-xyz") ("API_KEY" . "other-secret-123"))))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'ok))
      (should (string-search "env: API_KEY=••••" (plist-get r :stderr)))
      (should (member "MOCK_SECRET_ONE=••••" (plist-get r :tools)))
      (drgnx-agent-check-remember item r)
      (let ((file (expand-file-name "agent-checks.eld" (drgnx-state-dir)))
            (texts (list (prin1-to-string r)
                         (with-current-buffer (messages-buffer) (buffer-string)))))
        (should (file-exists-p file))
        (push (with-temp-buffer (insert-file-contents file) (buffer-string)) texts)
        (should (string-search "••••" (car texts)))
        (dolist (text texts)
          (should-not (string-search "s3cret-value-xyz" text))
          (should-not (string-search "other-secret-123" text)))))))

(ert-deftest drgnx-agent-check/secrets-of-this-emacs-are-masked-too ()
  (drgnx-agent-check-test-env
    (let* ((process-environment (cons "MOCK_SECRET_TWO=emacs-own-secret-9" process-environment))
           (marker (drgnx-agent-check-test--marker))
           (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "echo-env" marker) root)))
      (should (eq (plist-get r :status) 'ok))
      (should-not (string-search "emacs-own-secret-9" (prin1-to-string r)))
      (should (member "MOCK_SECRET_TWO=••••" (plist-get r :tools))))))

(ert-deftest drgnx-agent-check/never-in-the-editing-emacs ()
  (drgnx-agent-check-test-env
    (let* ((marker (drgnx-agent-check-test--marker))
           (r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "ok" marker) root))
           (stderr (plist-get r :stderr)))
      (should (string-match "ppid=\\([0-9]+\\) parent=\\(.*\\)" stderr))
      (should-not (equal (string-to-number (match-string 1 stderr)) (emacs-pid)))
      (should (string-search "drgnx-agent-check-main" (match-string 2 stderr)))
      ;; this Emacs started nothing but the check's Emacs: the server is not its child
      (should-not (cl-some (lambda (pid) (and (equal (alist-get 'ppid (process-attributes pid)) (emacs-pid))
                                              (string-search marker (or (alist-get 'args (process-attributes pid)) ""))))
                           (list-system-processes))))))

(ert-deftest drgnx-agent-check/the-command-lines-have-no-secrets ()
  (let* ((item (drgnx-agent-check-test--stdio-item "ok" "m" '(("API_KEY" . "s3cret-value-xyz"))))
         (hook (list :kind 'claude :section 'hook :name "h" :file "/f"
                     :spec (list :event "PreToolUse" :command "curl -H 'Authorization: Bearer abc123def456' x")))
         (argv (append (drgnx-agent-check--mcp-argv) (drgnx-agent-check--hook-argv hook))))
    (ignore item)
    (should-not (string-search "s3cret" (string-join argv " ")))
    (should-not (string-search "abc123def456" (string-join argv " ")))
    (should (member "drgnx-agent-check-main" (drgnx-agent-check--mcp-argv)))))

(ert-deftest drgnx-agent-check/memory-cap-where-systemd-is ()
  (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)))
    (let ((argv (drgnx-agent-check--wrap '("emacs" "--batch"))))
      (should (equal (seq-take argv 4) '("systemd-run" "--user" "--scope" "-q")))
      (should (member "MemoryMax=512M" argv))
      (should (member "MemorySwapMax=0" argv))
      (should (equal (last argv 2) '("emacs" "--batch")))))
  (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=detached" process-environment)))
    (should (equal (drgnx-agent-check--wrap '("emacs" "--batch")) '("emacs" "--batch")))))

(ert-deftest drgnx-agent-check/hook-gets-the-sample-event-on-stdin ()
  (drgnx-agent-check-test-env
    (let* ((item (list :kind 'claude :section 'hook :name "PreToolUse Bash" :from 'project :file "/f"
                       :spec (list :event "PreToolUse" :matcher "Bash"
                                   :command "cat; echo oops >&2; exit 3")))
           (r (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-hook item root cb))))
           (event (json-parse-string (plist-get r :stdout) :object-type 'alist)))
      (should (eql (plist-get r :exit) 3))
      (should (equal (string-trim (plist-get r :stderr)) "oops"))
      (should (floatp (plist-get r :time)))
      (should (equal (alist-get 'hook_event_name event) "PreToolUse"))
      (should (equal (alist-get 'tool_name event) "Bash"))
      (should (equal (alist-get 'command (alist-get 'tool_input event)) "echo drgnx-hook-test"))
      (should (equal (alist-get 'cwd event) (directory-file-name root)))
      (should (stringp (alist-get 'session_id event)))
      (should (stringp (alist-get 'transcript_path event))))))

(ert-deftest drgnx-agent-check/hook-runs-in-the-project-and-keeps-its-env ()
  (drgnx-agent-check-test-env
    (let* ((item (list :kind 'claude :section 'hook :name "Stop" :from 'project :file "/f"
                       :spec (list :event "Stop" :command "pwd; echo \"[$0]\"")))
           (r (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-hook item root cb)))))
      (should (eql (plist-get r :exit) 0))
      (should (string-prefix-p (directory-file-name (file-truename root)) (string-trim (plist-get r :stdout)))))))

(ert-deftest drgnx-agent-check/hook-output-is-masked ()
  (drgnx-agent-check-test-env
    (let* ((item (list :kind 'claude :section 'hook :name "Stop" :from 'project :file "/f"
                       :spec (list :event "Stop" :command "echo \"token: Bearer abc123def456\"; echo abc123def456 >&2")))
           (r (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-hook item root cb)))))
      (should-not (string-search "abc123def456" (prin1-to-string r)))
      (should (string-search "••••" (plist-get r :stdout)))
      (should (string-search "••••" (plist-get r :stderr))))))

(ert-deftest drgnx-agent-check/hook-timeout ()
  (drgnx-agent-check-test-env
    (let* ((item (list :kind 'claude :section 'hook :name "Stop" :from 'project :file "/f"
                       :spec (list :event "Stop" :command "echo started; sleep 3171; echo never" :timeout 1)))
           (r (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-hook item root cb)))))
      (should-not (plist-get r :exit))
      (should (plist-get r :timeout))
      (should (string-search "started" (plist-get r :stdout)))
      (should-not (string-search "never" (plist-get r :stdout)))
      (should (< (plist-get r :time) 6))
      (should (drgnx-agent-check-test--gone-p "sleep 3171")))))

(ert-deftest drgnx-agent-check/hook-timeout-units ()
  (should (= (drgnx-agent-check--hook-timeout (list :spec (list :timeout 5))) 5))
  (should (= (drgnx-agent-check--hook-timeout (list :spec (list :timeout 5000 :timeout-unit 'ms))) 5))
  (should (= (drgnx-agent-check--hook-timeout (list :spec (list :event "Stop"))) 60)))

(ert-deftest drgnx-agent-check/sample-events-per-agent ()
  (let ((root "/project/"))
    ;; Claude and Kimi: the same shape
    (dolist (kind '(claude kimi))
      (let ((e (drgnx-agent-check-sample-event kind "PostToolUse" root)))
        (should (equal (alist-get 'hook_event_name e) "PostToolUse"))
        (should (equal (alist-get 'tool_name e) "Bash"))
        (should (alist-get 'tool_response e))
        (should (equal (alist-get 'cwd e) "/project")))
      (should (alist-get 'prompt (drgnx-agent-check-sample-event kind "UserPromptSubmit" root)))
      (should-not (alist-get 'tool_name (drgnx-agent-check-sample-event kind "SessionStart" root))))
    (let ((e (drgnx-agent-check-sample-event 'codex "PreToolUse" root)))
      (should (equal (alist-get 'tool_name e) "Bash"))
      (should (equal (alist-get 'command (alist-get 'tool_input e)) "echo drgnx-hook-test"))
      (should (alist-get 'turn_id e))
      (should (alist-get 'model e)))
    (let ((e (drgnx-agent-check-sample-event 'gemini "BeforeTool" root)))
      (should (equal (alist-get 'tool_name e) "run_shell_command"))
      (should (equal (alist-get 'command (alist-get 'tool_input e)) "echo drgnx-hook-test"))
      (should (equal (alist-get 'hook_event_name e) "BeforeTool"))
      (should (stringp (alist-get 'timestamp e))))
    (should (alist-get 'prompt (drgnx-agent-check-sample-event 'gemini "BeforeAgent" root)))
    ;; an event the table does not know still gets the common fields
    (let ((e (drgnx-agent-check-sample-event 'claude "SomethingNew" root)))
      (should (equal (alist-get 'hook_event_name e) "SomethingNew"))
      (should (stringp (alist-get 'session_id e))))))

(ert-deftest drgnx-agent-check/last-result-is-remembered ()
  (drgnx-agent-check-test-env
    (let ((a (list :kind 'claude :section 'mcp :name "a" :file "/f" :spec (list :env '(("API_KEY" . "s3cret-value-xyz")))))
          (b (list :kind 'claude :section 'mcp :name "b" :file "/f" :spec nil)))
      (should-not (drgnx-agent-check-last a))
      (drgnx-agent-check-remember a (list :status 'failed :error "boom s3cret-value-xyz" :time 0.5))
      (drgnx-agent-check-remember b (list :status 'ok :tools '("t") :time 0.1))
      (let ((last (drgnx-agent-check-last a)))
        (should (eq (plist-get last :status) 'failed))
        (should (equal (plist-get last :error) "boom ••••"))
        (should (numberp (plist-get last :at))))
      (should (equal (plist-get (drgnx-agent-check-last b) :tools) '("t")))
      ;; a later result replaces the earlier one, the other item stays
      (drgnx-agent-check-remember a (list :status 'ok :time 0.2))
      (should (eq (plist-get (drgnx-agent-check-last a) :status) 'ok))
      (should (eq (plist-get (drgnx-agent-check-last b) :status) 'ok))
      (should (= (length (car (read-from-string
                               (with-temp-buffer
                                 (insert-file-contents (expand-file-name "agent-checks.eld" (drgnx-state-dir)))
                                 (buffer-string)))))
                 2)))))

(provide 'agent-check-test)
;;; agent-check-test.el ends here
