;;; acp-test.el --- batch tests: the ACP client against the mock agent -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-acp)
(require 'drgnx-paths)

(defconst drgnx-acp-test--mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))

(defun drgnx-acp-test--command ()
  (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-acp-test--mock))

(defun drgnx-acp-test--wait (pred &optional secs)
  "Run the event loop until PRED is non-nil (at most SECS, default 10); PRED's value."
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

(defmacro drgnx-acp-test--with (conn keys &rest body)
  (declare (indent 2))
  `(let ((,conn (apply #'drgnx-acp-start (drgnx-acp-test--command) ,keys)))
     (unwind-protect (progn ,@body) (drgnx-acp-stop ,conn))))

(defun drgnx-acp-test--call (conn method params)
  "METHOD's (RESULT . ERROR), waiting for it."
  (let (r)
    (drgnx-acp-request conn method params (lambda (res) (setq r res)))
    (drgnx-acp-test--wait (lambda () r))))

(ert-deftest drgnx-acp/the-agent-runs-with-sigpipe-ignored ()
  ;; the agent writes to pipes its own children may close: it must not die of the signal (Emacs resets it for children)
  (skip-unless (file-readable-p "/proc/self/status"))
  (let ((conn (drgnx-acp-start (list "sh" "-c" "grep SigIgn /proc/self/status >&2"))))
    (unwind-protect
        (let ((mask (and (drgnx-acp-test--wait
                          (lambda () (string-match "SigIgn:[ \t]*\\([0-9a-f]+\\)" (or (drgnx-acp-conn-stderr conn) ""))))
                         (string-to-number (match-string 1 (drgnx-acp-conn-stderr conn)) 16))))
          (should mask)
          (should-not (zerop (logand #x1000 mask))))
      (drgnx-acp-stop conn))))

(ert-deftest drgnx-acp/a-request-gets-its-result ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-acp-test--with c nil
    (let ((r (drgnx-acp-test--call c "initialize" '(:protocolVersion 1 :clientCapabilities (:fs (:readTextFile t :writeTextFile t))))))
      (should (eql (plist-get (car r) :protocolVersion) 1))
      (should-not (cdr r)))
    (let ((r (drgnx-acp-test--call c "no/such/method" nil)))
      (should-not (car r))
      (should (plist-get (cdr r) :message)))))

(ert-deftest drgnx-acp/notifications-reach-the-handler ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (let ((seen nil))
    (drgnx-acp-test--with c (list :on-notification (lambda (_c method params) (push (cons method params) seen)))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))
      (should (drgnx-acp-test--wait
               (lambda () (seq-find (lambda (n) (equal (plist-get (plist-get (cdr n) :update) :sessionUpdate)
                                                       "available_commands_update"))
                                    seen)))))))

(ert-deftest drgnx-acp/agent-requests-are-answered-by-the-handler ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (let ((asked nil) (chunks nil))
    (drgnx-acp-test--with c (list :on-request (lambda (_c method _params _id)
                                                (push method asked)
                                                '(:result (:outcome (:outcome "selected" :optionId "allow"))))
                                  :on-notification (lambda (_c _m params)
                                                     (when-let* ((text (plist-get (plist-get (plist-get params :update) :content) :text)))
                                                       (push text chunks))))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (let ((sid (plist-get (car (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))) :sessionId)))
        (drgnx-acp-test--call c "session/prompt" (list :sessionId sid :prompt (vector '(:type "text" :text "permission please")))))
      (should (member "session/request_permission" asked))
      (should (member "permission: allow" chunks)))))

(ert-deftest drgnx-acp/the-agent-exiting-is-reported-with-its-stderr ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (let (exit)
    (drgnx-acp-test--with c (list :on-exit (lambda (_c status stderr) (setq exit (list status stderr))))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (let* ((sid (plist-get (car (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))) :sessionId))
             (r (drgnx-acp-test--call c "session/prompt" (list :sessionId sid :prompt (vector '(:type "text" :text "crash now"))))))
        (should (cdr r)))                                     ; the pending prompt fails, not hangs
      (should (drgnx-acp-test--wait (lambda () exit)))
      (should (eql (car exit) 3))
      (should (string-match-p "mock crashed" (cadr exit)))
      ;; nothing left behind: the stderr pipe and the input buffer go with the agent
      (should-not (process-live-p (drgnx-acp-conn-stderr-process c)))
      (should-not (buffer-live-p (drgnx-acp-conn-input-buffer c))))))

(ert-deftest drgnx-acp/lines-are-framed-whatever-the-chunks ()
  ;; No process: the framing alone.  A line split across outputs, a malformed line (logged,
  ;; skipped), a 1 MB line, several lines in one output.
  (let* ((got nil)
         (c (drgnx-acp--make :on-notification (lambda (_c method params) (push (cons method params) got)))))
    (unwind-protect
        (progn
          (drgnx-acp--input c "{\"jsonrpc\":\"2.0\",\"method\":\"a\"")
          (should-not got)
          (drgnx-acp--input c ",\"params\":{\"n\":1}}\nnot json at all\n")
          (should (equal got '(("a" :n 1))))
          (should (string-match-p "not json" (car (drgnx-acp-conn-log c))))
          (let ((big (make-string 1000000 ?x)))
            (drgnx-acp--input c (concat "{\"jsonrpc\":\"2.0\",\"method\":\"big\",\"params\":{\"s\":\"" big "\"}}\n"
                                        "{\"jsonrpc\":\"2.0\",\"method\":\"c\",\"params\":{}}\n"))
            (should (equal (mapcar #'car got) '("c" "big" "a")))
            (should (= (length (plist-get (cdr (nth 1 got)) :s)) 1000000))))
      (drgnx-acp-stop c))))

;;; acp-test.el ends here
