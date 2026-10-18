;;; mock-mcp.el --- A mock MCP server for tests: stdio in batch Emacs, and an HTTP one in the test Emacs -*- lexical-binding: t -*-
;; Stdio:  emacs --batch -Q -l mock-mcp.el -f drgnx-mock-mcp-main MODE [MARKER]
;; MARKER is any text: it is on the command line, so a test finds the process (and its children) by it.  MODE:
;;   ok          answers initialize and tools/list (the tools mock_echo and mock_add); tells on stderr who it is
;;               ("mock-mcp ready pid=N ppid=N parent=ARGS")
;;   hang        reads and never answers
;;   crash       says "mock-mcp: fatal: cannot open its database" on stderr and exits 3 before reading
;;   flood       never answers: fills stdout and stderr with junk, forever
;;   echo-env    answers like ok, prints its whole environment on stderr and names a tool NAME=VALUE for every
;;               variable called MOCK_SECRET*
;;   fork-child  starts a second mock (hang, same MARKER) and then hangs
;; HTTP:  (drgnx-mock-mcp-http-start MODE) -> PORT, served by the Emacs that calls it (the test), on 127.0.0.1.
;;   ok          Streamable HTTP: initialize answers JSON with Mcp-Session-Id; notifications answer 202; tools/list
;;               answers an SSE stream (chunked) that is left open; a request without the session id gets 400
;;   needs-login 401 with WWW-Authenticate for everything
;;   hang        accepts and never answers
;; `drgnx-mock-mcp-http-requests' keeps what the server received (newest first); `drgnx-mock-mcp-http-stop' ends it.
(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defconst drgnx-mock-mcp--file (or load-file-name buffer-file-name) "This file.")

(defconst drgnx-mock-mcp--tools
  '("mock_echo" "mock_add")
  "The tools the mock offers.")

(defun drgnx-mock-mcp--json (value)
  "VALUE as JSON text."
  (decode-coding-string (json-serialize value) 'utf-8))

(defun drgnx-mock-mcp--result (id result)
  "The JSON-RPC reply to ID with RESULT."
  (list :jsonrpc "2.0" :id id :result result))

(defun drgnx-mock-mcp--answer (msg tools)
  "The reply (a plist) to the JSON-RPC MSG, or nil for a notification; TOOLS the names tools/list gives."
  (let ((id (plist-get msg :id)) (params (plist-get msg :params)))
    (when id
      (pcase (plist-get msg :method)
        ("initialize"
         (if (not (stringp (plist-get params :protocolVersion)))
             (list :jsonrpc "2.0" :id id :error (list :code -32602 :message "protocolVersion is required"))
           (drgnx-mock-mcp--result
            id (list :protocolVersion (plist-get params :protocolVersion)
                     :capabilities (list :tools (make-hash-table))
                     :serverInfo (list :name "mock-mcp" :version "1")))))
        ("tools/list"
         (drgnx-mock-mcp--result
          id (list :tools (vconcat (mapcar (lambda (n) (list :name n :description (concat "the " n " tool")
                                                             :inputSchema (list :type "object")))
                                           tools)))))
        (m (list :jsonrpc "2.0" :id id :error (list :code -32601 :message (format "method not found: %s" m))))))))

;;;; Stdio

(defun drgnx-mock-mcp--serve (mode)
  "Answer JSON lines on stdin as MODE (ok or echo-env) until the end of input."
  (let* ((ppid (alist-get 'ppid (process-attributes (emacs-pid))))
         (tools (if (equal mode "echo-env")
                    (append (cl-loop for e in process-environment
                                     when (string-prefix-p "MOCK_SECRET" e) collect e)
                            drgnx-mock-mcp--tools)
                  drgnx-mock-mcp--tools)))
    (message "mock-mcp ready pid=%d ppid=%s parent=%s" (emacs-pid) ppid
             (alist-get 'args (and ppid (process-attributes ppid))))
    (when (equal mode "echo-env")
      (dolist (e process-environment) (message "env: %s" e)))
    (condition-case nil
        (while t
          (let* ((line (read-from-minibuffer ""))
                 (msg (and (not (string-blank-p line))
                           (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil))))
                 (reply (and msg (drgnx-mock-mcp--answer msg tools))))
            (when reply
              (princ (drgnx-mock-mcp--json reply))
              (terpri))))
      (end-of-file nil))
    (kill-emacs 0)))

(defun drgnx-mock-mcp-main ()
  "Run the mock as the mode and marker that follow on the command line."
  (let ((mode (pop command-line-args-left)) (marker (pop command-line-args-left)))
    (setq command-line-args-left nil)
    (set-language-environment "UTF-8")
    (setq locale-coding-system 'utf-8-unix)
    (pcase mode
      ("crash" (message "mock-mcp: fatal: cannot open its database") (kill-emacs 3))
      ("flood" (let ((junk (make-string 4096 ?x)))
                 (while t (princ junk) (terpri) (message "%s" junk))))
      ("hang" (while t (sleep-for 1)))
      ("fork-child"
       (start-process "mock-mcp-child" nil (expand-file-name invocation-name invocation-directory)
                      "--batch" "-Q" "-l" drgnx-mock-mcp--file "-f" "drgnx-mock-mcp-main" "hang" (or marker ""))
       (while t (sleep-for 1)))
      ((or "ok" "echo-env") (drgnx-mock-mcp--serve mode))
      (_ (message "mock-mcp: no such mode: %s" mode) (kill-emacs 2)))))

;;;; HTTP

(defvar drgnx-mock-mcp-http-requests nil
  "What the HTTP mock received, newest first: plists (:mode :method :path :headers :json); header names lower case.")

(defconst drgnx-mock-mcp-http--session "mock-session-1" "The session id the HTTP mock hands out.")

(defun drgnx-mock-mcp-http--send (proc status headers body &optional chunked keep-open)
  "Answer on PROC: STATUS (\"200 OK\"), HEADERS ((NAME . VALUE)…), BODY text.  CHUNKED: as one chunk of a chunked
reply; KEEP-OPEN: leave the connection open."
  (let* ((bytes (encode-coding-string (or body "") 'utf-8))
         (head (concat "HTTP/1.1 " status "\r\n"
                       (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                       (if chunked "Transfer-Encoding: chunked\r\n" (format "Content-Length: %d\r\n" (length bytes)))
                       "\r\n")))
    (process-send-string proc (concat head (if chunked (format "%x\r\n%s\r\n" (length bytes) bytes) bytes)))
    (unless keep-open (delete-process proc))))

(defun drgnx-mock-mcp-http--handle (proc method path headers body)
  "Serve one request on PROC."
  (let* ((mode (process-get proc :mode))
         (json (and (not (string-empty-p body))
                    (ignore-errors (json-parse-string body :object-type 'plist :null-object nil :false-object nil)))))
    (push (list :mode mode :method method :path path :headers headers :json json) drgnx-mock-mcp-http-requests)
    (pcase mode
      ("hang" nil)
      ("needs-login"
       (drgnx-mock-mcp-http--send
        proc "401 Unauthorized"
        '(("WWW-Authenticate" . "Bearer realm=\"mock\", resource_metadata=\"http://127.0.0.1/.well-known/oauth-protected-resource\"")
          ("Content-Type" . "text/plain"))
        "login first"))
      (_
       (let* ((init (equal (plist-get json :method) "initialize"))
              (reply (and json (drgnx-mock-mcp--answer json drgnx-mock-mcp--tools))))
         (cond
          ((not (equal method "POST")) (drgnx-mock-mcp-http--send proc "405 Method Not Allowed" nil ""))
          ((and (not init) (not (equal (cdr (assoc "mcp-session-id" headers)) drgnx-mock-mcp-http--session)))
           (drgnx-mock-mcp-http--send proc "400 Bad Request" nil "missing session"))
          ((null reply) (drgnx-mock-mcp-http--send proc "202 Accepted" nil ""))
          (init (drgnx-mock-mcp-http--send proc "200 OK"
                                           `(("Content-Type" . "application/json")
                                             ("Mcp-Session-Id" . ,drgnx-mock-mcp-http--session))
                                           (drgnx-mock-mcp--json reply)))
          (t (drgnx-mock-mcp-http--send proc "200 OK" '(("Content-Type" . "text/event-stream"))
                                        (format "event: message\ndata: %s\n\n" (drgnx-mock-mcp--json reply))
                                        t t))))))))

(defun drgnx-mock-mcp-http--filter (proc string)
  "Collect the request on PROC; serve it when it is complete."
  (let ((data (concat (process-get proc :buffer) string)))
    (process-put proc :buffer data)
    (when (and (not (process-get proc :served)) (string-match "\r\n\r\n" data))
      (let* ((head (substring data 0 (match-beginning 0)))
             (rest (substring data (match-end 0)))
             (lines (split-string head "\r\n"))
             (request (split-string (car lines) " "))
             (headers (mapcar (lambda (l) (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" l)
                                            (cons (downcase (match-string 1 l)) (match-string 2 l))))
                              (cdr lines)))
             (length (string-to-number (or (cdr (assoc "content-length" headers)) "0"))))
        (when (>= (length rest) length)
          (process-put proc :served t)
          (drgnx-mock-mcp-http--handle proc (nth 0 request) (nth 1 request) (delq nil headers)
                                       (decode-coding-string (substring rest 0 length) 'utf-8)))))))

(defun drgnx-mock-mcp-http-start (mode)
  "Start the HTTP mock in MODE (\"ok\", \"needs-login\" or \"hang\") on 127.0.0.1; its port."
  (let ((server (make-network-process
                 :name (format "mock-mcp-http-%s" mode) :server t :host "127.0.0.1" :service t :family 'ipv4
                 :noquery t :coding 'binary :filter #'drgnx-mock-mcp-http--filter
                 :log (lambda (server conn _msg) (process-put conn :mode (process-get server :mode))))))
    (process-put server :mode mode)
    (process-put server :mock-mcp t)
    (process-contact server :service)))

(defun drgnx-mock-mcp-http-stop ()
  "End every HTTP mock and its connections, and forget the requests."
  (dolist (p (process-list))
    (when (or (process-get p :mock-mcp) (process-get p :mode))
      (delete-process p)))
  (setq drgnx-mock-mcp-http-requests nil))

(provide 'mock-mcp)
;;; mock-mcp.el ends here
