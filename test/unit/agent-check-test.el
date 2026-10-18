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

(defun drgnx-agent-check-test--fake-systemctl (body)
  "Put a `systemctl' that logs its arguments and then runs the shell command BODY first on the path."
  (let ((script (expand-file-name "systemctl" (expand-file-name "bin" drgnx-agent-config-test--dir))))
    (write-region (format "#!/bin/sh\necho \"$*\" >> '%s'\n%s\n"
                          (expand-file-name "systemctl.log" drgnx-agent-config-test--dir) body)
                  nil script nil 'silent)
    (set-file-modes script #o755)))

(defmacro drgnx-agent-check-test-env (&rest body)
  "BODY in the agent settings fixture (temp state dir), no systemd scope (the user's manager is not touched),
with the HTTP mock stopped afterwards."
  (declare (indent 0))
  `(let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=detached" process-environment)))
     (drgnx-agent-config-test-env
       (drgnx-agent-check-test--fake-systemctl "exit 1")
       (unwind-protect (progn ,@body) (drgnx-mock-mcp-http-stop)))))

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
  ;; three servers that never answer, tested at the same time
  (drgnx-agent-check-test-env
    (let* ((drgnx-agent-check-timeout 1)
           (markers (list (drgnx-agent-check-test--marker) (drgnx-agent-check-test--marker)))
           (port (drgnx-mock-mcp-http-start "hang"))
           (results (make-vector 3 nil))
           (items (list (drgnx-agent-check-test--stdio-item "hang" (nth 0 markers))
                        (drgnx-agent-check-test--stdio-item "fork-child" (nth 1 markers))
                        (drgnx-agent-check-test--http-item port)))
           (deadline (+ (float-time) 30)))
      (dotimes (i 3)
        (let ((i i)) (drgnx-agent-check-mcp (nth i items) root (lambda (r) (aset results i r)))))
      (while (and (cl-some #'null results) (< (float-time) deadline)) (accept-process-output nil 0.05))
      (dotimes (i 3)
        (should (eq (plist-get (aref results i) :status) 'timeout))
        (should (< (plist-get (aref results i) :time) 8)))
      (dolist (marker markers) (should (drgnx-agent-check-test--gone-p marker))))))

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
      ;; until both run (a loaded machine starts the child Emacs slowly)
      (let ((until (+ (float-time) 15)))
        (while (and (< (float-time) until)
                    (not (and (drgnx-agent-check-test--marked marker) (drgnx-agent-check-test--marked "sleep 3174"))))
          (accept-process-output nil 0.1)))
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
      (should (string-match "ppid=\\([0-9]+\\) cwd=.* parent=\\(.*\\)" stderr))
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

;;;; Fix round 1

(ert-deftest drgnx-agent-check/the-process-table-is-read-from-proc ()
  (skip-unless (file-readable-p "/proc/self/stat"))
  (let* ((rows (drgnx-agent-check--proc-rows))
         (mine (assq (emacs-pid) rows))
         (attrs (process-attributes (emacs-pid))))
    (should mine)
    (should (equal (nth 1 mine) (alist-get 'ppid attrs)))
    (should (equal (nth 2 mine) (alist-get 'pgrp attrs)))
    (should (equal (nth 3 mine) (alist-get 'sess attrs)))
    ;; a process called "a) S 1 2 3 (b" (sleep run through a symlink with that name) does not confuse the reader
    (let* ((dir (make-temp-file "drgnx-comm" t))
           (link (expand-file-name "a) S 1 2 3 (b" dir))
           (sleep (executable-find "sleep"))
           (proc nil))
      (unwind-protect
          (progn
            (make-symbolic-link sleep link)
            (setq proc (make-process :name "x" :command (list link "30") :noquery t))
            (sleep-for 0.2)
            (let ((raw (with-temp-buffer (insert-file-contents (format "/proc/%d/stat" (process-id proc))) (buffer-string)))
                  (row (assq (process-id proc) (drgnx-agent-check--proc-rows))))
              ;; the name is really in the file, and the numbers after it are still the right ones
              (should (string-search "(a) S 1 2 3 (b)" raw))
              (should (equal (nth 1 row) (emacs-pid)))
              (should (equal (nth 3 row) (process-id proc)))))
        (when proc (delete-process proc))
        (delete-directory dir t)))
    (should (memq (emacs-pid) (drgnx-agent-check--tree (emacs-pid))))))

(ert-deftest drgnx-agent-check/the-tree-includes-children-and-groups ()
  (let* ((proc (make-process :name "x" :command '("sh" "-c" "sleep 3175 & sleep 3175") :noquery t))
         (pid (process-id proc)))
    (unwind-protect
        (progn
          (sleep-for 0.5)
          (should (>= (length (drgnx-agent-check--tree pid)) 3))
          (drgnx-agent-check--kill-tree pid)
          (should (drgnx-agent-check-test--gone-p "sleep 3175")))
      (ignore-errors (delete-process proc)))))

(ert-deftest drgnx-agent-check/a-named-scope-where-systemd-is ()
  (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)))
    (should (member "--unit=drgnx-check-test" (drgnx-agent-check--wrap '("emacs") "drgnx-check-test")))
    (should (string-prefix-p "drgnx-check-" (drgnx-agent-check--unit)))
    (should-not (string= (drgnx-agent-check--unit) (drgnx-agent-check--unit))))
  (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=detached" process-environment)))
    (should-not (drgnx-agent-check--unit))))

(ert-deftest drgnx-agent-check/an-http-error-body-is-masked-before-it-is-cut ()
  (drgnx-agent-check-test-env
    ;; the token starts at offset 195 of the body, so cutting first would leave its first five characters
    (let* ((port (drgnx-mock-mcp-http-start "error-body"))
           (r (drgnx-agent-check-test--mcp
               (drgnx-agent-check-test--http-item port '(("Authorization" . "Bearer tok-abcdef123456"))) root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-search "HTTP 500" (plist-get r :error)))
      (should (string-search "••••" (plist-get r :error)))
      (should-not (string-search "tok-" (plist-get r :error)))
      (should-not (string-search "abcdef" (plist-get r :error))))))

(ert-deftest drgnx-agent-check/expansion-uses-the-environment-and-remembers-what-it-used ()
  (let ((process-environment (append '("MOCK_EXP_A=value-of-a" "MOCK_EXP_SHORT=ab" "MOCK_EXP_EMPTY=") process-environment))
        (drgnx-agent-check--expanded nil) (drgnx-agent-check--unset nil))
    (should (equal (drgnx-agent-check--expand "x-${MOCK_EXP_A}-y") "x-value-of-a-y"))
    (should (equal (drgnx-agent-check--expand "${MOCK_EXP_NOPE:-fallback}") "fallback"))
    (should (equal (drgnx-agent-check--expand "${MOCK_EXP_EMPTY:-fallback}") "fallback"))
    ;; no value, no default: left as written and named
    (should (equal (drgnx-agent-check--expand "${MOCK_EXP_NOPE}") "${MOCK_EXP_NOPE}"))
    (should (equal drgnx-agent-check--unset '("MOCK_EXP_NOPE")))
    ;; $VAR is Gemini's, not Claude Code's
    (should (equal (drgnx-agent-check--expand "$MOCK_EXP_A/x") "$MOCK_EXP_A/x"))
    (should (equal (drgnx-agent-check--expand "$MOCK_EXP_A/x" t) "value-of-a/x"))
    (should (equal (drgnx-agent-check--expand "${MOCK_EXP_A}" t) "value-of-a"))
    (should (equal (cdr (assoc "MOCK_EXP_A" drgnx-agent-check--expanded)) "value-of-a"))
    (should (equal (drgnx-agent-check--expand 'not-text) 'not-text))
    ;; the spec: Claude Code and Gemini expand, Codex does not
    (let ((spec (list :command "${MOCK_EXP_A}" :args ["--x=${MOCK_EXP_A}"] :url "http://h/${MOCK_EXP_A}"
                      :env '(("K" . "${MOCK_EXP_A}")) :headers '(("H" . "${MOCK_EXP_A}")))))
      (let ((e (drgnx-agent-check--expand-spec 'claude spec)))
        (should (equal (plist-get e :command) "value-of-a"))
        (should (equal (plist-get e :args) '("--x=value-of-a")))
        (should (equal (plist-get e :url) "http://h/value-of-a"))
        (should (equal (plist-get e :env) '(("K" . "value-of-a"))))
        (should (equal (plist-get e :headers) '(("H" . "value-of-a")))))
      (should (eq (drgnx-agent-check--expand-spec 'codex spec) spec)))))

(ert-deftest drgnx-agent-check/an-expanded-value-is-masked-in-a-plain-argument ()
  (drgnx-agent-check-test-env
    (let* ((process-environment (cons "MOCK_PLAIN=plainvalue12345" process-environment))
           (marker (drgnx-agent-check-test--marker))
           (item (drgnx-agent-check-test--stdio-item "echo-env" marker))
           (item (progn (plist-put (plist-get item :spec) :args
                                   (append (plist-get (plist-get item :spec) :args) (list "--plain=${MOCK_PLAIN}")))
                        item))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'ok))
      ;; the server got the value (it is in its command line) and the result does not show it
      (should (string-search "--plain=••••" (plist-get r :stderr)))
      (should-not (string-search "plainvalue12345" (prin1-to-string r))))))

(ert-deftest drgnx-agent-check/an-expanded-value-is-masked-in-the-url-path ()
  (drgnx-agent-check-test-env
    (let* ((process-environment (cons "MOCK_PATHVAL=pathvalue987" process-environment))
           (port (drgnx-mock-mcp-http-start "echo-path"))
           (item (list :kind 'claude :section 'mcp :name "remote" :file "/f"
                       :spec (list :type 'http :url (format "http://127.0.0.1:%d/mcp/${MOCK_PATHVAL}" port))))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-search "no such path: /mcp/••••" (plist-get r :error)))
      (should-not (string-search "pathvalue987" (prin1-to-string r))))))

(ert-deftest drgnx-agent-check/an-unset-variable-is-named-in-the-result ()
  (drgnx-agent-check-test-env
    (let* ((port (drgnx-mock-mcp-http-start "echo-path"))
           (item (list :kind 'gemini :section 'mcp :name "remote" :file "/f"
                       :spec (list :type 'http :url (format "http://127.0.0.1:%d/$MOCK_SURELY_UNSET/x" port))))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (equal (plist-get r :unset) '("MOCK_SURELY_UNSET")))
      (should (string-search "MOCK_SURELY_UNSET" (plist-get r :error))))))

(ert-deftest drgnx-agent-check/headers-from-environment-variables ()
  (drgnx-agent-check-test-env
    (let* ((process-environment (append '("MOCK_BEARER_VAR=bearer-value-777" "MOCK_HDR_VAR=header-value-888")
                                        process-environment))
           (port (drgnx-mock-mcp-http-start "ok"))
           (item (list :kind 'codex :section 'mcp :name "remote" :file "/f"
                       :spec (list :type 'http :url (format "http://127.0.0.1:%d/mcp" port)
                                   :bearer-env "MOCK_BEARER_VAR"
                                   :env-headers '("X-Mock" "X-Unset") :env-header-vars '("MOCK_HDR_VAR" "MOCK_NOT_SET"))))
           (r (drgnx-agent-check-test--mcp item root))
           (headers (plist-get (car (last drgnx-mock-mcp-http-requests)) :headers)))
      (should (eq (plist-get r :status) 'ok))
      (should (equal (cdr (assoc "authorization" headers)) "Bearer bearer-value-777"))
      (should (equal (cdr (assoc "x-mock" headers)) "header-value-888"))
      (should-not (assoc "x-unset" headers))
      (let ((sets (drgnx-agent-check--secret-sets item (list :headers '(("Authorization" . "Bearer bearer-value-777"))))))
        (should (member "bearer-value-777" (car sets)))))
    ;; Kimi: the variable of bearerTokenEnvVar; a header written out is not replaced
    (setq drgnx-mock-mcp-http-requests nil)
    (let* ((process-environment (cons "MOCK_KIMI_VAR=kimi-token-555" process-environment))
           (port (drgnx-mock-mcp-http-start "ok"))
           (item (list :kind 'kimi :section 'mcp :name "remote" :file "/f"
                       :spec (list :type 'http :url (format "http://127.0.0.1:%d/mcp" port)
                                   :bearer-env "MOCK_KIMI_VAR")))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'ok))
      (should (equal (cdr (assoc "authorization" (plist-get (car (last drgnx-mock-mcp-http-requests)) :headers)))
                     "Bearer kimi-token-555")))
    (let* ((process-environment (cons "MOCK_KIMI_VAR=kimi-token-555" process-environment))
           (port (drgnx-mock-mcp-http-start "ok"))
           (item (list :kind 'kimi :section 'mcp :name "remote" :file "/f"
                       :spec (list :type 'http :url (format "http://127.0.0.1:%d/mcp" port)
                                   :headers '(("authorization" . "Bearer written-out-1")) :bearer-env "MOCK_KIMI_VAR"))))
      (setq drgnx-mock-mcp-http-requests nil)
      (drgnx-agent-check-test--mcp item root)
      (should (equal (cdr (assoc "authorization" (plist-get (car (last drgnx-mock-mcp-http-requests)) :headers)))
                     "Bearer written-out-1")))))

(ert-deftest drgnx-agent-check/kimi-server-runs-in-its-own-directory ()
  (drgnx-agent-check-test-env
    (make-directory (expand-file-name "sub/dir" root) t)
    (let* ((marker (drgnx-agent-check-test--marker))
           (item (drgnx-agent-check-test--stdio-item "ok" marker nil 'kimi))
           (item (progn (plist-put (plist-get item :spec) :cwd "sub/dir") item))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'ok))
      (should (string-match "cwd=\\(.*\\) parent=" (plist-get r :stderr)))
      (should (equal (file-truename (match-string 1 (plist-get r :stderr)))
                     (file-name-as-directory (file-truename (expand-file-name "sub/dir" root))))))
    ;; one that does not exist is said so
    (let* ((item (drgnx-agent-check-test--stdio-item "ok" "m" nil 'kimi))
           (item (progn (plist-put (plist-get item :spec) :cwd "nowhere") item))
           (r (drgnx-agent-check-test--mcp item root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-search "does not exist" (plist-get r :error))))))

(ert-deftest drgnx-agent-check/a-hook-finds-the-project-directory-in-its-environment ()
  (drgnx-agent-check-test-env
    (dolist (case '((claude "$CLAUDE_PROJECT_DIR" nil) (kimi "$CLAUDE_PROJECT_DIR" nil)
                    (gemini "$GEMINI_PROJECT_DIR" "$CLAUDE_PROJECT_DIR") (codex "x" nil)))
      (let* ((item (list :kind (car case) :section 'hook :name "h" :file "/f"
                         :spec (list :event "Stop" :command (format "printf '%%s|%%s' \"%s\" \"%s\"" (nth 1 case) (or (nth 2 case) "")))))
             (r (drgnx-agent-check-test--wait (lambda (cb) (drgnx-agent-check-hook item root cb))))
             (dir (directory-file-name (expand-file-name root))))
        (pcase (car case)
          ((or 'claude 'kimi) (should (equal (plist-get r :stdout) (concat dir "|"))))
          ('gemini (should (equal (plist-get r :stdout) (concat dir "|" dir))))
          (_ (should (equal (plist-get r :stdout) "x|"))))))))

(ert-deftest drgnx-agent-check/an-sse-server-is-told-from-the-answer ()
  (drgnx-agent-check-test-env
    (let* ((port (drgnx-mock-mcp-http-start "legacy-sse"))
           (sse (drgnx-agent-check-test--mcp
                 (plist-put (drgnx-agent-check-test--http-item port) :spec
                            (list :type 'sse :url (format "http://127.0.0.1:%d/sse" port)))
                 root))
           (http (drgnx-agent-check-test--mcp (drgnx-agent-check-test--http-item port) root)))
      (should (eq (plist-get sse :status) 'failed))
      (should (string-search "HTTP 405" (plist-get sse :error)))
      (should (string-search "old-style SSE" (plist-get sse :error)))
      (should (string-search "HTTP 405" (plist-get http :error)))
      (should-not (string-search "old-style SSE" (plist-get http :error))))))

(ert-deftest drgnx-agent-check/a-remote-project-is-refused ()
  (let ((mcp nil) (hook nil))
    (should-not (drgnx-agent-check-mcp (drgnx-agent-check-test--stdio-item "ok" "m") "/ssh:nowhere:/srv/p/"
                                       (lambda (r) (setq mcp r))))
    (should-not (drgnx-agent-check-hook (list :kind 'claude :section 'hook :name "h" :file "/f"
                                              :spec (list :event "Stop" :command "true"))
                                        "/ssh:nowhere:/srv/p/" (lambda (r) (setq hook r))))
    (should (eq (plist-get mcp :status) 'failed))
    (should (string-search "remote" (plist-get mcp :error)))
    (should-not (plist-get hook :exit))
    (should (string-search "remote" (plist-get hook :error)))))

(ert-deftest drgnx-agent-check/a-refused-connection-is-told ()
  (drgnx-agent-check-test-env
    (let* ((port (drgnx-mock-mcp-http-start "ok")))
      (drgnx-mock-mcp-http-stop)
      (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--http-item port) root)))
        (should (eq (plist-get r :status) 'failed))
        (should (string-search "Cannot connect" (plist-get r :error)))))))

(ert-deftest drgnx-agent-check/a-long-error-from-the-server-is-cut ()
  (drgnx-agent-check-test-env
    (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "error" (drgnx-agent-check-test--marker)) root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-search "initialize: eee" (plist-get r :error)))
      (should (< (length (plist-get r :error)) 540)))))

(ert-deftest drgnx-agent-check/a-killed-server-says-it-was-killed ()
  (drgnx-agent-check-test-env
    (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "oom" (drgnx-agent-check-test--marker)) root)))
      (should (eq (plist-get r :status) 'failed))
      (should (string-search "signal 9" (plist-get r :error))))))

(ert-deftest drgnx-agent-check/masking-covers-overlaps-and-other-forms ()
  ;; two secrets that overlap are one range: no end of either stays
  (should (equal (drgnx-agent-config-mask-text "x abcdefghi y" '("abcdef" "defghi")) "x •••• y"))
  (should (equal (drgnx-agent-config-mask-text "abcdefghi" '("defghi" "abcdef")) "••••"))
  (should (equal (drgnx-agent-config-mask-text "a-secret-b-secret" '("secret")) "a-••••-b-••••"))
  (should (equal (drgnx-agent-config-mask-text "nothing" '("secret")) "nothing"))
  (should (equal (drgnx-agent-config-mask-text "keep" nil) "keep"))
  (should-not (drgnx-agent-config-mask-text nil '("secret")))
  ;; the forms of a secret
  (let ((forms (drgnx-agent-check--forms "pa ss/w\"rd&é")))
    (should (member "pa ss/w\"rd&é" forms))
    (should (member "pa%20ss%2Fw%22rd%26%C3%A9" forms))
    (should (member "pa ss/w\\\"rd&é" forms)))
  (should (member "pä ss" (drgnx-agent-check--forms "p%C3%A4%20ss")))
  (let ((sets (drgnx-agent-check--secret-sets
               (list :spec (list :env '(("API_KEY" . "a b/c-secret")))))))
    (should (member "a%20b%2Fc-secret" (car sets))))
  (should (equal (drgnx-agent-config-mask-text "q=a%20b%2Fc-secret" (car (drgnx-agent-check--secret-sets
                                                                          (list :spec (list :env '(("API_KEY" . "a b/c-secret")))))))
                 "q=••••")))

(ert-deftest drgnx-agent-check/only-text-of-a-server-is-masked ()
  (let ((r (drgnx-agent-check--mask-result '(:status failed :exit 4321 :error "failed 4321" :tools ("failed_tool")) '("failed" "4321"))))
    (should (eq (plist-get r :status) 'failed))
    (should (eql (plist-get r :exit) 4321))
    (should (equal (plist-get r :error) "•••• ••••"))
    (should (equal (plist-get r :tools) '("••••_tool"))))
  ;; the tool names are masked with the strong secrets only
  (let ((r (drgnx-agent-check--mask-result '(:error "prod_x" :tools ("prod_query")) '("prod") '("other-value"))))
    (should (equal (plist-get r :error) "••••_x"))
    (should (equal (plist-get r :tools) '("prod_query")))))

(ert-deftest drgnx-agent-check/short-plain-values-stay-in-tool-names ()
  (let* ((process-environment (append '("MOCK_TOKEN_ENV=tok-from-this-emacs-1" "XDG_SESSION_TYPE=wayland"
                                        "MOCK_DB_URL=postgres://dbuser:dbpassw0rd@host/db" "GITHUB_PAT=ghp-short"
                                        "PATH_OF_ALL=notasecretvalue")
                                      process-environment))
         (item (list :kind 'claude :section 'mcp :name "m" :file "/f"
                     :spec (list :env '(("MODE" . "prod") ("TARGET_NAME" . "staging-eu") ("API_KEY" . "abc")
                                        ("SHORT_TOKEN" . "tk12")))))
         (sets (drgnx-agent-check--secret-sets item)))
    ;; a plain name, a short value: hidden in errors and stderr, not in tool names
    (should (member "prod" (car sets)))
    (should-not (member "prod" (cdr sets)))
    ;; a long value, or a name that says secret: hidden everywhere
    (should (member "staging-eu" (cdr sets)))
    (should (member "tk12" (cdr sets)))
    ;; this Emacs's own environment: by name (pat, session…) and the userinfo of URLs
    (should (member "tok-from-this-emacs-1" (cdr sets)))
    (should (member "ghp-short" (cdr sets)))
    (should (member "dbpassw0rd" (car sets)))
    (should-not (member "notasecretvalue" (car sets)))
    ;; XDG_SESSION_TYPE matches the broad list by accident
    (should-not (member "wayland" (car sets)))))

(ert-deftest drgnx-agent-check/output-is-cleaned ()
  (should (equal (drgnx-agent-check--clean "a\e[31mred\e[0m b\e]0;title\a c\r\nd\re\001f\tg") "ared b c\nd\nef\tg"))
  (should (equal (drgnx-agent-check--clean (decode-coding-string "ok\xff\xfe!" 'utf-8-unix)) "ok��!"))
  (should (equal (drgnx-agent-check--clean nil) ""))
  ;; a secret cut in two by an escape sequence is found once the sequence is gone
  (should (equal (drgnx-agent-config-mask-text (drgnx-agent-check--clean "sec\e[0mret1") '("secret1")) "••••")))

;;;; Fix round 2

(defun drgnx-agent-check-test--systemctl-log ()
  "The lines the fake systemctl was called with."
  (let ((log (expand-file-name "systemctl.log" drgnx-agent-config-test--dir)))
    (and (file-exists-p log)
         (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))))

(defmacro drgnx-agent-check-test-with-fake-scope (systemctl-body &rest body)
  "BODY as if the check ran in a systemd scope called drgnx-check-fake, without making one: the wrapper adds
nothing and the fake `systemctl' (SYSTEMCTL-BODY, a shell command) is the only program that hears of the scope."
  (declare (indent 1))
  `(progn
     (drgnx-agent-check-test--fake-systemctl ,systemctl-body)
     (cl-letf (((symbol-function 'drgnx-agent-check--unit) (lambda () "drgnx-check-fake"))
               ((symbol-function 'drgnx-agent-check--wrap) (lambda (argv &optional _unit) argv)))
       ,@body)))

(defun drgnx-agent-check-test--start-hanging (marker callback)
  "Start a check of a hanging server (the child's own timeout is 3 s, this Emacs ends it after 1)."
  (drgnx-agent-check-mcp (drgnx-agent-check-test--stdio-item "fork-child" marker) default-directory callback))

(ert-deftest drgnx-agent-check/a-systemctl-that-hangs-does-not-hang-the-check ()
  (drgnx-agent-check-test-env
    (drgnx-agent-check-test-with-fake-scope "exec sleep 3176"
      (let* ((drgnx-agent-check-timeout 3) (drgnx-agent-check--grace -2)
             (marker (drgnx-agent-check-test--marker))
             (calls 0) (result nil) (t0 (float-time)))
        (drgnx-agent-check-test--start-hanging marker (lambda (r) (cl-incf calls) (setq result r)))
        (while (and (not result) (< (float-time) (+ t0 20))) (accept-process-output nil 0.05))
        (should (eq (plist-get result :status) 'timeout))
        ;; the backstop (3 s after the timer at 1 s), not the 20 s of waiting
        (should (< (- (float-time) t0) 8))
        (should (drgnx-agent-check-test--gone-p marker))
        ;; the hanging systemctl was deleted
        (should (drgnx-agent-check-test--gone-p "sleep 3176"))
        (sleep-for 0.5)
        (should (= calls 1))))))

(ert-deftest drgnx-agent-check/a-systemctl-that-cannot-be-started-falls-back-to-the-tree ()
  (drgnx-agent-check-test-env
    (drgnx-agent-check-test-with-fake-scope "exit 0"
      (let* ((drgnx-agent-check-timeout 3) (drgnx-agent-check--grace -2)
             (marker (drgnx-agent-check-test--marker))
             (orig (symbol-function 'make-process))
             (calls 0) (result nil) (t0 (float-time)))
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (if (equal (plist-get args :name) "drgnx-check-kill")
                         (error "no process for you")
                       (apply orig args)))))
          (drgnx-agent-check-test--start-hanging marker (lambda (r) (cl-incf calls) (setq result r)))
          (while (and (not result) (< (float-time) (+ t0 20))) (accept-process-output nil 0.05)))
        (should (eq (plist-get result :status) 'timeout))
        ;; at the timer's 1 s plus the child's start, long before the 3 s backstop
        (should (< (plist-get result :time) 2.8))
        (should (drgnx-agent-check-test--gone-p marker))
        (sleep-for 0.5)
        (should (= calls 1))))))

(ert-deftest drgnx-agent-check/a-timer-in-a-buffer-with-no-directory-still-ends-the-check ()
  (drgnx-agent-check-test-env
    ;; systemctl exits 1: the tree is ended in its sentinel, which is the path that needs a process to start first
    (drgnx-agent-check-test-with-fake-scope "exit 1"
      (let* ((drgnx-agent-check-timeout 3) (drgnx-agent-check--grace -2)
             (marker (drgnx-agent-check-test--marker))
             (gone (generate-new-buffer " *no directory*"))
             (calls 0) (result nil) (t0 (float-time)))
        (with-current-buffer gone (setq default-directory "/nowhere/at/all/"))
        (unwind-protect
            (progn
              (drgnx-agent-check-test--start-hanging marker (lambda (r) (cl-incf calls) (setq result r)))
              (with-current-buffer gone
                (while (and (not result) (< (float-time) (+ t0 20))) (accept-process-output nil 0.05))))
          (kill-buffer gone))
        (should (eq (plist-get result :status) 'timeout))
        (should (< (plist-get result :time) 2.8))
        (should (drgnx-agent-check-test--gone-p marker))
        (should (member "--user kill --signal=KILL drgnx-check-fake.scope" (drgnx-agent-check-test--systemctl-log)))
        (sleep-for 0.5)
        (should (= calls 1))))))

(ert-deftest drgnx-agent-check/a-finished-check-asks-systemd-to-clear-its-scope ()
  (drgnx-agent-check-test-env
    (drgnx-agent-check-test-with-fake-scope "exit 1"
      (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "ok" (drgnx-agent-check-test--marker)) root)))
        (should (eq (plist-get r :status) 'ok))
        (let ((until (+ (float-time) 3)))
          (while (and (not (drgnx-agent-check-test--systemctl-log)) (< (float-time) until)) (sleep-for 0.1)))
        (should (member "--user kill --signal=KILL drgnx-check-fake.scope" (drgnx-agent-check-test--systemctl-log)))))))

(ert-deftest drgnx-agent-check/scope-names-do-not-repeat-across-emacs-sessions ()
  (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment))
        (drgnx-agent-check--unit-counter 0))
    (let ((a (drgnx-agent-check--unit)))
      (setq drgnx-agent-check--unit-counter 0)
      (should-not (equal a (drgnx-agent-check--unit)))
      (should (string-match-p "\\`drgnx-check-[0-9]+-[0-9]+-[0-9a-f]+\\'" a)))))

(ert-deftest drgnx-agent-check/the-memory-limit-is-named-only-where-there-is-one ()
  (drgnx-agent-check-test-env
    ;; detached: no cap, so the message says nothing of it
    (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "oom" (drgnx-agent-check-test--marker)) root)))
      (should (string-search "signal 9" (plist-get r :error)))
      (should-not (string-search "memory" (plist-get r :error))))
    ;; in a scope: it does
    (drgnx-agent-check-test-with-fake-scope "exit 1"
      (let ((r (drgnx-agent-check-test--mcp (drgnx-agent-check-test--stdio-item "oom" (drgnx-agent-check-test--marker)) root)))
        (should (string-search "signal 9" (plist-get r :error)))
        (should (string-search "512M" (plist-get r :error)))))))

(ert-deftest drgnx-agent-check/names-from-this-emacs-that-are-not-secrets ()
  (let* ((process-environment
          (list "XDG_SESSION_CLASS=user" "XDG_SESSION_TYPE=wayland" "XDG_SESSION_ID=12345" "XDG_SESSION_DESKTOP=gnome"
                "XDG_SESSION_PATH=/org/freedesktop/DisplayManager/Session1" "DESKTOP_SESSION=gnome-xorg"
                "GDMSESSION=gnome-classic" "SESSION_MANAGER=local/host:@/tmp/.ICE-unix/1"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" "XAUTHORITY=/run/user/1000/.auth-file"
                "ICEAUTHORITY=/run/user/1000/.ICEauthority" "SSH_AUTH_SOCK=/run/user/1000/ssh-agent.sock"
                "GIT_ASKPASS=/usr/lib/git-core/askpass-helper" "SSH_ASKPASS=/usr/lib/ssh/x11-ssh-askpass"
                ;; the core list wins over every exclusion
                "GIT_ASKPASS_TOKEN=askpass-token-value" "XDG_SESSION_KEY=session-key-value"
                ;; broad names that are not excluded stay secrets
                "MY_SESSION_COOKIE_X=cookie-of-mine" "CI_AUTH_FILE=/var/ci/auth-file" "APP_PASSPHRASE=hunter2hunter2"))
         (all (car (drgnx-agent-check--secret-sets (list :spec nil)))))
    (dolist (plain '("user" "wayland" "12345" "gnome" "gnome-xorg" "gnome-classic" "/run/user/1000/bus"
                     "/run/user/1000/.auth-file" "/run/user/1000/.ICEauthority" "/run/user/1000/ssh-agent.sock"
                     "/usr/lib/git-core/askpass-helper" "/usr/lib/ssh/x11-ssh-askpass"))
      (should-not (cl-some (lambda (s) (string-search plain s)) all)))
    (dolist (secret '("askpass-token-value" "session-key-value" "cookie-of-mine" "/var/ci/auth-file" "hunter2hunter2"))
      (should (member secret all)))
    ;; so a plain word in the output stays readable
    (should (equal (drgnx-agent-config-mask-text "user wayland" all) "user wayland"))))

(ert-deftest drgnx-agent-check/a-spec-name-with-pass-or-auth-is-a-secret-name ()
  (let* ((item (list :kind 'claude :section 'mcp :name "m" :file "/f"
                     :spec (list :env '(("DB_PASS" . "abc123") ("AUTH_MODE" . "oidc5") ("MODE" . "prod5")))))
         (sets (drgnx-agent-check--secret-sets item)))
    ;; names with pass and auth in them: strong, hidden in tool names too; MODE is plain: weak
    (should (member "abc123" (cdr sets)))
    (should (member "oidc5" (cdr sets)))
    (should (member "prod5" (car sets)))
    (should-not (member "prod5" (cdr sets)))))

(ert-deftest drgnx-agent-check/a-secret-is-found-in-the-cleaned-output ()
  (should (member "ab\ncd" (drgnx-agent-check--forms "ab\rcd")))
  (should (member "ab\ncd" (drgnx-agent-check--forms "ab\r\ncd")))
  (should (member "ab�cd" (drgnx-agent-check--forms (decode-coding-string "ab\377cd" 'utf-8-unix))))
  (should (equal (drgnx-agent-config-mask-text (drgnx-agent-check--clean "x ab\rcd y") (drgnx-agent-check--forms "ab\rcd"))
                 "x •••• y")))

(provide 'agent-check-test)
;;; agent-check-test.el ends here
