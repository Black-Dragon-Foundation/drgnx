;;; drgnx-agent-check.el --- MCP Test and Hook Test: run an agent's server or hook in its own process, masked -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The checks of the agent settings pages (docs/develop/core.md).  Both run the user's configured command, so they
;; run only when the user asks (Test, Test all), never from a timer or a hook, and never in the editing Emacs:
;;
;; - `drgnx-agent-check-mcp' starts a batch Emacs (`drgnx-agent-check-main', in a systemd scope with a memory cap
;;   where systemd runs the session) and hands it the server's spec as JSON on its stdin: the environment values and
;;   headers never reach a command line or a file.  The child starts the server (or POSTs to its URL), does the MCP
;;   `initialize' / `notifications/initialized' / `tools/list' round and prints one JSON result.  It ends at
;;   `drgnx-agent-check-timeout' and takes the server's whole process tree with it; this Emacs ends the child 5
;;   seconds later if it did not.
;; - `drgnx-agent-check-hook' runs the hook's command with `sh -c' in the project, the sample event of its kind on
;;   stdin, for the hook's own timeout (60 s without one), in the same memory cap.
;;
;; Every string handed back (and kept in agent-checks.eld) is masked with the item's secrets, with the secret-looking
;; variables of this Emacs's own environment (a server may print its environment), and with the `${VAR}' values the
;; agent would have expanded.  The files this writes: the last results, `(drgnx-state-dir)/agent-checks.eld'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url-parse)
(require 'drgnx-agent-config)
(require 'drgnx-paths)
(require 'drgnx-jobs)

(defvar drgnx-agent-check-timeout 20
  "Seconds an MCP Test may take before the server and the check's Emacs are ended.")

(defconst drgnx-agent-check--dir (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The directory of this file (the child Emacs loads it from there).")

(defconst drgnx-agent-check--protocol "2025-06-18"
  "The MCP revision the check speaks.")

(defconst drgnx-agent-check--memory "512M" "The memory cap of a check in a systemd scope.")
(defconst drgnx-agent-check--stderr-limit 8192 "Characters of a server's stderr kept in a result.")
(defconst drgnx-agent-check--stderr-capture 65536
  "Characters of a server's stderr read, to be masked before they are cut to the limit.")
(defconst drgnx-agent-check--hook-limit 16384 "Characters of a hook's stdout, and of its stderr, kept in a result.")
(defconst drgnx-agent-check--junk-limit 262144 "Bytes a server may print that are not JSON-RPC before the check gives up.")
(defconst drgnx-agent-check--message-limit 4194304 "Bytes of one message of a server, or of an HTTP answer.")
(defconst drgnx-agent-check--capture-limit 1048576 "Bytes of a child's output this Emacs keeps.")
(defconst drgnx-agent-check--grace 5 "Seconds this Emacs waits for the child Emacs after the timeout.")

(define-error 'drgnx-agent-check-failure "MCP check failed")

;;;; Process trees

(defun drgnx-agent-check--tree (pid)
  "PID and every process that belongs to it: its descendants and the members of the groups and sessions it leads."
  (let ((rows nil) (set (list pid)) (changed t))
    (dolist (p (list-system-processes))
      (when-let* ((a (ignore-errors (process-attributes p))))
        (push (list p (alist-get 'ppid a) (alist-get 'pgrp a) (alist-get 'sess a)) rows)))
    (while changed
      (setq changed nil)
      (dolist (r rows)
        (when (and (not (memq (car r) set)) (not (eq (car r) (emacs-pid)))
                   (or (memq (nth 1 r) set) (memq (nth 2 r) set) (memq (nth 3 r) set)))
          (push (car r) set)
          (setq changed t))))
    set))

(defun drgnx-agent-check--kill-tree (pid)
  "End PID and all that belongs to it: stop them first, so nothing forks while the tree is found again, then kill."
  (when (and (integerp pid) (> pid 1) (not (eq pid (emacs-pid))))
    (let ((tree (drgnx-agent-check--tree pid)) (again 0))
      (while (< (cl-incf again) 5)
        (dolist (p tree) (ignore-errors (signal-process p 'SIGSTOP)))
        (let ((now (drgnx-agent-check--tree pid)))
          (if (equal (sort (copy-sequence now) #'<) (sort (copy-sequence tree) #'<))
              (setq again 99)
            (setq tree now))))
      (dolist (p tree) (ignore-errors (signal-process p 'SIGKILL))))))

;;;; Masking, results, the last results

(defun drgnx-agent-check--environment-secrets ()
  "The values of the variables of this Emacs's environment that look like secrets."
  (cl-loop for entry in process-environment
           when (and (string-match "\\`\\([^=]+\\)=\\(.\\{4,\\}\\)\\'" entry)
                     (string-match-p "token\\|secret\\|key\\|password\\|passwd\\|authorization"
                                     (downcase (match-string 1 entry))))
           collect (match-string 2 entry)))

(defun drgnx-agent-check--secrets (item)
  "Every string to hide in the output of checking ITEM."
  (delete-dups (append (ignore-errors (drgnx-agent-config-secrets (plist-get item :spec)))
                       (drgnx-agent-check--environment-secrets))))

(defun drgnx-agent-check--mask-result (result secrets)
  "RESULT (a plist) with every string in it masked with SECRETS."
  (cl-loop for (key value) on result by #'cddr
           append (list key (cond ((stringp value) (drgnx-agent-config-mask-text value secrets))
                                  ((and (consp value) (cl-every #'stringp value))
                                   (mapcar (lambda (s) (drgnx-agent-config-mask-text s secrets)) value))
                                  (t value)))))

(defun drgnx-agent-check--cut (text limit)
  "TEXT at most LIMIT characters, with a note when it was cut."
  (if (> (length text) limit)
      (concat (substring text 0 limit) "\n… (more output was cut)")
    text))

(defun drgnx-agent-check-login-hint (kind name)
  "How to log in to the MCP server NAME of agent KIND."
  (pcase kind
    ('claude (format "Run /mcp in a Claude Code session and choose %s to log in." name))
    ('codex (format "Run: codex mcp login %s" name))
    ('gemini (format "In a Gemini session run: /mcp auth %s" name))
    (_ (format "Log in to %s from a session of the agent." name))))

(defun drgnx-agent-check--file ()
  (expand-file-name "agent-checks.eld" (drgnx-state-dir)))

(defun drgnx-agent-check--key (item)
  (list (plist-get item :kind) (plist-get item :section) (plist-get item :name) (plist-get item :file)))

(defun drgnx-agent-check--read-all ()
  "The remembered results: an alist (KEY . RESULT)."
  (let ((file (drgnx-agent-check--file)))
    (or (and (file-readable-p file)
             (let ((data (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))
               (and (listp data) (cl-every #'consp data) data)))
        nil)))

(defun drgnx-agent-check-last (item)
  "The last remembered result of checking ITEM, or nil."
  (cdr (assoc (drgnx-agent-check--key item) (drgnx-agent-check--read-all))))

(defun drgnx-agent-check-remember (item result)
  "Keep RESULT as the last result of checking ITEM, masked, with the time (`:at')."
  (let* ((masked (drgnx-agent-check--mask-result result (drgnx-agent-check--secrets item)))
         (masked (if (plist-member masked :at) masked (append masked (list :at (float-time)))))
         (key (drgnx-agent-check--key item))
         (all (cons (cons key masked) (assoc-delete-all key (drgnx-agent-check--read-all))))
         (file (drgnx-agent-check--file))
         (dir (file-name-directory file))
         (temp nil))
    (make-directory dir t)
    (set-file-modes dir #o700)
    (unwind-protect
        (progn
          (setq temp (make-temp-file (expand-file-name ".agent-checks-" dir)))
          (with-temp-file temp
            (let ((print-length nil) (print-level nil) (print-circle nil) (print-escape-newlines t))
              (prin1 (reverse all) (current-buffer))))
          (set-file-modes temp #o600)
          (rename-file temp file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp)) (delete-file temp)))
    masked))

;;;; The child Emacs's side: one MCP server, tested

(defvar drgnx-agent-check--deadline nil "Child: `float-time' at which the check is over.")
(defvar drgnx-agent-check--limit 20 "Child: the timeout in seconds.")
(defvar drgnx-agent-check--tail "" "Child: the unfinished line of the server's stdout.")
(defvar drgnx-agent-check--messages nil "Child: parsed JSON-RPC messages from the server, oldest first.")
(defvar drgnx-agent-check--junk 0 "Child: bytes of the server's stdout that were not JSON-RPC.")
(defvar drgnx-agent-check--overflow nil "Child: non-nil once the server printed too much.")
(defvar drgnx-agent-check--stderr "" "Child: the server's stderr (the first part).")
(defvar drgnx-agent-check--next-id 0 "Child: the last request id.")

(defun drgnx-agent-check--fail (status format-string &rest args)
  "End the check with STATUS and the message FORMAT-STRING."
  (signal 'drgnx-agent-check-failure (list status (apply #'format format-string args))))

(defun drgnx-agent-check--parse (text)
  "TEXT as a JSON-RPC message (a plist), or nil."
  (ignore-errors (json-parse-string text :object-type 'plist :array-type 'list :null-object nil :false-object nil)))

(defun drgnx-agent-check--check-deadline ()
  (when (> (float-time) drgnx-agent-check--deadline)
    (drgnx-agent-check--fail 'timeout "No answer within %s seconds." drgnx-agent-check--limit)))

(defun drgnx-agent-check--stdout-filter (_proc string)
  "Collect the server's stdout as lines; JSON objects are messages, anything else counts against the junk limit."
  (setq drgnx-agent-check--tail (concat drgnx-agent-check--tail string))
  (while (string-match "\n" drgnx-agent-check--tail)
    (let ((line (substring drgnx-agent-check--tail 0 (match-beginning 0))))
      (setq drgnx-agent-check--tail (substring drgnx-agent-check--tail (match-end 0)))
      (let ((msg (and (string-prefix-p "{" (string-trim-left line)) (drgnx-agent-check--parse line))))
        (if msg
            (setq drgnx-agent-check--messages (nconc drgnx-agent-check--messages (list msg)))
          (cl-incf drgnx-agent-check--junk (1+ (length line)))))))
  (when (or (> drgnx-agent-check--junk drgnx-agent-check--junk-limit)
            (> (length drgnx-agent-check--tail) drgnx-agent-check--message-limit))
    (setq drgnx-agent-check--overflow t
          drgnx-agent-check--tail "")))

(defun drgnx-agent-check--stderr-filter (_proc string)
  "Keep the first `drgnx-agent-check--stderr-capture' characters of the server's stderr (masked, then cut later)."
  (let ((room (- drgnx-agent-check--stderr-capture (length drgnx-agent-check--stderr))))
    (setq drgnx-agent-check--stderr
          (concat drgnx-agent-check--stderr (if (<= (length string) room) string (substring string 0 (max room 0)))))))

(defun drgnx-agent-check--drain ()
  "Read what the server's processes still have to say."
  (dotimes (_ 3) (accept-process-output nil 0.03)))

(defun drgnx-agent-check--send (proc object)
  "Send the JSON-RPC OBJECT to PROC as a line."
  (condition-case nil
      (process-send-string proc (concat (decode-coding-string (json-serialize object) 'utf-8) "\n"))
    (error nil)))

(defun drgnx-agent-check--await (proc id)
  "The message with ID that PROC's stdout delivers; fails when the server ends, floods or does not answer."
  (let (found)
    (while (not found)
      (setq found (cl-find id drgnx-agent-check--messages :key (lambda (m) (plist-get m :id)) :test #'equal))
      (unless found
        (cond
         (drgnx-agent-check--overflow
          (drgnx-agent-check--fail 'failed "The server printed too much that is not MCP (more than %d KB) and no answer."
                                   (/ drgnx-agent-check--junk-limit 1024)))
         ((not (process-live-p proc))
          (drgnx-agent-check--drain)
          (unless (cl-find id drgnx-agent-check--messages :key (lambda (m) (plist-get m :id)) :test #'equal)
            (drgnx-agent-check--fail 'failed "The server ended (%s) before it answered."
                                     (if (eq (process-status proc) 'signal)
                                         (format "killed by signal %d" (process-exit-status proc))
                                       (format "exit code %d" (process-exit-status proc))))))
         (t (drgnx-agent-check--check-deadline)
            (accept-process-output nil 0.05)))))
    (setq drgnx-agent-check--messages (delq found drgnx-agent-check--messages))
    found))

(defun drgnx-agent-check--result-of (message what)
  "The `result' of the JSON-RPC MESSAGE, or a failure naming WHAT when it is an error."
  (if-let* ((err (plist-get message :error)))
      (drgnx-agent-check--fail 'failed "%s: %s%s" what (or (plist-get err :message) "error")
                               (if (plist-get err :code) (format " (code %s)" (plist-get err :code)) ""))
    (plist-get message :result)))

(defun drgnx-agent-check--session (request notify protocol)
  "Do the MCP round through REQUEST (METHOD PARAMS → result) and NOTIFY (METHOD); the tool names."
  (let* ((init (funcall request "initialize"
                        (list :protocolVersion protocol :capabilities (make-hash-table)
                              :clientInfo (list :name "drgnx" :version "1"))))
         (tools nil) (cursor nil) (pages 0))
    (funcall notify "notifications/initialized")
    (when (plist-member (plist-get init :capabilities) :tools)
      (while (and (< (cl-incf pages) 20)
                  (let ((result (funcall request "tools/list" (if cursor (list :cursor cursor) (make-hash-table)))))
                    (dolist (tool (plist-get result :tools)) (push (plist-get tool :name) tools))
                    (setq cursor (plist-get result :nextCursor))
                    cursor))))
    (nreverse (delq nil tools))))

;;;;; stdio

(defun drgnx-agent-check--stdio (spec)
  "Start the server of SPEC (an alist), test it, end its whole tree; the tool names."
  (let* ((command (alist-get 'command spec))
         (args (alist-get 'args spec))
         (root (file-name-as-directory (expand-file-name (or (alist-get 'root spec) default-directory))))
         (default-directory root)
         (process-environment (append (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c))) (alist-get 'env spec))
                                      process-environment))
         (err (make-pipe-process :name "drgnx-check-stderr" :noquery t :coding 'utf-8-unix
                                 :filter #'drgnx-agent-check--stderr-filter))
         proc)
    (unwind-protect
        (progn
          (unless (and (stringp command) (not (string-empty-p command)))
            (drgnx-agent-check--fail 'failed "The server has no command."))
          (setq proc (condition-case nil
                         (make-process :name "drgnx-check-server" :command (cons command args) :connection-type 'pipe
                                       :noquery t :coding 'utf-8-unix :stderr err
                                       :filter #'drgnx-agent-check--stdout-filter :sentinel #'ignore)
                       (file-missing (drgnx-agent-check--fail 'failed "The command %s was not found." command))
                       (file-error (drgnx-agent-check--fail 'failed "The command %s cannot be run." command))))
          (drgnx-agent-check--session
           (lambda (method params)
             (let ((id (cl-incf drgnx-agent-check--next-id)))
               (drgnx-agent-check--send proc (list :jsonrpc "2.0" :id id :method method :params params))
               (drgnx-agent-check--result-of (drgnx-agent-check--await proc id) method)))
           (lambda (method) (drgnx-agent-check--send proc (list :jsonrpc "2.0" :method method)))
           (or (alist-get 'protocol spec) drgnx-agent-check--protocol)))
      (when proc
        (drgnx-agent-check--drain)
        (drgnx-agent-check--kill-tree (process-id proc))
        (ignore-errors (delete-process proc)))
      (drgnx-agent-check--drain)
      (ignore-errors (delete-process err)))))

;;;;; HTTP

(defun drgnx-agent-check--dechunk (body)
  "BODY with its chunked framing removed (as far as the chunks are complete)."
  (let ((pos 0) (out nil))
    (catch 'done
      (while (string-match "\\`\\([0-9A-Fa-f]+\\)[^\r\n]*\r\n" (substring body pos))
        (let* ((size (string-to-number (match-string 1 (substring body pos)) 16))
               (start (+ pos (match-end 0))))
          (when (= size 0) (throw 'done nil))
          (when (> (+ start size) (length body))
            (push (substring body start) out)
            (throw 'done nil))
          (push (substring body start (+ start size)) out)
          (setq pos (+ start size 2))
          (when (> pos (length body)) (throw 'done nil)))))
    (apply #'concat (nreverse out))))

(defun drgnx-agent-check--sse-messages (text)
  "The JSON-RPC messages in the server-sent events TEXT."
  (let (out)
    (dolist (event (split-string (replace-regexp-in-string "\r\n" "\n" text) "\n\n"))
      (let ((data (mapconcat (lambda (l) (string-trim-left (substring l 5)))
                             (cl-remove-if-not (lambda (l) (string-prefix-p "data:" l)) (split-string event "\n"))
                             "\n")))
        (when-let* ((msg (and (not (string-empty-p data)) (drgnx-agent-check--parse data))))
          (push msg out))))
    (nreverse out)))

(defun drgnx-agent-check--http-parse (raw id closed)
  "What the HTTP answer RAW (bytes so far) says, or nil when it is not complete enough: a plist (:status :reason
:headers :text :message).  ID: the request id to find (nil: the status is the whole answer).  CLOSED: no more bytes."
  (when (string-match "\r\n\r\n" raw)
    (let* ((head (substring raw 0 (match-beginning 0)))
           (body (substring raw (match-end 0)))
           (lines (split-string head "\r\n"))
           (headers (delq nil (mapcar (lambda (l) (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" l)
                                                    (cons (downcase (match-string 1 l)) (match-string 2 l))))
                                      (cdr lines)))))
      (unless (string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\) *\\(.*\\)\\'" (car lines))
        (drgnx-agent-check--fail 'failed "The server did not answer in HTTP."))
      (let* ((status (string-to-number (match-string 1 (car lines))))
             (reason (match-string 2 (car lines)))
             (body (if (string-match-p "chunked" (or (cdr (assoc "transfer-encoding" headers)) ""))
                       (drgnx-agent-check--dechunk body)
                     body))
             (text (decode-coding-string body 'utf-8 t))
             (result (list :status status :reason reason :headers headers :text text)))
        (cond
         ((not (<= 200 status 299)) result)
         ((null id) result)
         (t
          (let* ((type (or (cdr (assoc "content-type" headers)) ""))
                 (messages (if (string-match-p "text/event-stream" type)
                               (drgnx-agent-check--sse-messages text)
                             (let ((m (drgnx-agent-check--parse text))) (and m (list m)))))
                 (message (cl-find id messages :key (lambda (m) (plist-get m :id)) :test #'equal)))
            (cond (message (append result (list :message message)))
                  (closed result)))))))))

(defun drgnx-agent-check--http-target (url)
  "URL as a plist: :tls :host :port :path."
  (let* ((u (url-generic-parse-url url))
         (tls (equal (url-type u) "https")))
    (unless (and (member (url-type u) '("http" "https")) (url-host u))
      (drgnx-agent-check--fail 'failed "The server's address is not an http or https URL."))
    (list :tls tls :host (url-host u) :port (or (url-portspec u) (if tls 443 80))
          :path (let ((f (url-filename u))) (if (string-empty-p f) "/" f)))))

(defun drgnx-agent-check--http-post (target headers object id)
  "POST the JSON-RPC OBJECT to TARGET with HEADERS ((NAME . VALUE)…); the parsed answer (see `-http-parse')."
  (let* ((body (json-serialize object))
         (default-port (if (plist-get target :tls) 443 80))
         (request (concat
                   (format "POST %s HTTP/1.1\r\nHost: %s%s\r\n" (plist-get target :path) (plist-get target :host)
                           (if (eql (plist-get target :port) default-port) "" (format ":%d" (plist-get target :port))))
                   "Accept: application/json, text/event-stream\r\nContent-Type: application/json\r\n"
                   (format "Content-Length: %d\r\nConnection: close\r\n" (length body))
                   (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                   "\r\n"))
         (raw "") (answer nil)
         (proc (condition-case err
                   (open-network-stream "drgnx-check-http" nil (plist-get target :host) (plist-get target :port)
                                        :type (if (plist-get target :tls) 'tls 'plain) :coding 'binary)
                 (error (drgnx-agent-check--fail 'failed "Cannot connect: %s" (error-message-string err))))))
    (unless (processp proc)
      (drgnx-agent-check--fail 'failed "Cannot connect%s."
                               (if (plist-get target :tls) " (a TLS certificate that cannot be checked is refused)" "")))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-query-on-exit-flag proc nil)
    (set-process-filter proc (lambda (_p s) (when (< (length raw) drgnx-agent-check--message-limit)
                                              (setq raw (concat raw s)))))
    (set-process-sentinel proc #'ignore)
    (unwind-protect
        (progn
          (process-send-string proc (concat (encode-coding-string request 'utf-8) body))
          (while (not answer)
            (setq answer (drgnx-agent-check--http-parse raw id (not (process-live-p proc))))
            (unless answer
              (when (>= (length raw) drgnx-agent-check--message-limit)
                (drgnx-agent-check--fail 'failed "The server's answer is too much (more than %d MB)."
                                         (/ drgnx-agent-check--message-limit 1048576)))
              (if (process-live-p proc)
                  (progn (drgnx-agent-check--check-deadline) (accept-process-output nil 0.05))
                (drgnx-agent-check--drain)
                (setq answer (or (drgnx-agent-check--http-parse raw id t)
                                 (drgnx-agent-check--fail 'failed "The server closed the connection without an answer."))))))
          answer)
      (ignore-errors (delete-process proc)))))

(defun drgnx-agent-check--http (spec)
  "Connect to the server of SPEC (an alist), test it; the tool names."
  (let* ((target (drgnx-agent-check--http-target (alist-get 'url spec)))
         (type (alist-get 'type spec))
         (headers (mapcar (lambda (c) (cons (format "%s" (car c)) (cdr c))) (alist-get 'headers spec)))
         (session nil) (version nil))
    (dolist (h headers)
      (when (string-match-p "[\r\n]" (format "%s%s" (car h) (cdr h)))
        (drgnx-agent-check--fail 'failed "A header of the server has a line break in it.")))
    (let ((post
           (lambda (object id what)
             (let* ((extra (append headers
                                   (and version (list (cons "MCP-Protocol-Version" version)))
                                   (and session (list (cons "Mcp-Session-Id" session)))))
                    (answer (drgnx-agent-check--http-post target extra object id))
                    (status (plist-get answer :status))
                    (reply-headers (plist-get answer :headers)))
               (cond
                ((and (eql status 401) (assoc "www-authenticate" reply-headers))
                 (drgnx-agent-check--fail 'needs-login "The server asks for a login."))
                ((not (<= 200 status 299))
                 (drgnx-agent-check--fail
                  'failed "%s: HTTP %d %s%s%s" what status (plist-get answer :reason)
                  (let ((text (string-trim (plist-get answer :text))))
                    (if (string-empty-p text) "" (concat ": " (substring text 0 (min 200 (length text))))))
                  (if (and (eq type 'sse) (memq status '(404 405)))
                      " (this looks like an old-style SSE server; the check speaks Streamable HTTP only)" "")))
                (t
                 (when-let* ((s (cdr (assoc "mcp-session-id" reply-headers)))) (setq session s))
                 (if id
                     (if-let* ((message (plist-get answer :message)))
                         (drgnx-agent-check--result-of message what)
                       (drgnx-agent-check--fail 'failed "%s: the answer has no MCP message." what))
                   t)))))))
      (let ((next-id 0))
        (drgnx-agent-check--session
         (lambda (method params)
           (let* ((id (cl-incf next-id))
                  (result (funcall post (list :jsonrpc "2.0" :id id :method method :params params) id method)))
             (when (equal method "initialize")
               (setq version (or (plist-get result :protocolVersion) drgnx-agent-check--protocol)))
             result))
         (lambda (method) (funcall post (list :jsonrpc "2.0" :method method) nil method))
         (or (alist-get 'protocol spec) drgnx-agent-check--protocol))))))

;;;;; the entry point

(defun drgnx-agent-check-main ()
  "The child Emacs's entry point: the spec as a line of JSON on stdin, one line of JSON result on stdout."
  (set-language-environment "UTF-8")
  (setq locale-coding-system 'utf-8-unix)
  (let* ((start (float-time))
         (spec (ignore-errors (json-parse-string (read-from-minibuffer "") :object-type 'alist :array-type 'list
                                                 :null-object nil :false-object nil)))
         (secrets (alist-get 'secrets spec))
         (drgnx-agent-check--limit (or (alist-get 'timeout spec) drgnx-agent-check-timeout))
         (drgnx-agent-check--deadline (+ start drgnx-agent-check--limit))
         (result
          (condition-case err
              (progn
                (unless spec (drgnx-agent-check--fail 'failed "The check got no usable description of the server."))
                (list :status 'ok
                      :tools (if (member (alist-get 'type spec) '("http" "sse"))
                                 (drgnx-agent-check--http spec)
                               (drgnx-agent-check--stdio spec))))
            (drgnx-agent-check-failure (list :status (cadr err) :error (nth 2 err)))
            (error (list :status 'failed :error (error-message-string err))))))
    (let ((masked (drgnx-agent-check--mask-result
                   (append (list :status (symbol-name (plist-get result :status)))
                           (and (plist-get result :tools) (list :tools (plist-get result :tools)))
                           (and (plist-get result :error) (list :error (plist-get result :error)))
                           (list :stderr drgnx-agent-check--stderr :time (- (float-time) start)))
                   secrets)))
      ;; cut after masking: a secret must not be cut in two and half of it shown
      (plist-put masked :stderr (drgnx-agent-check--cut (plist-get masked :stderr) drgnx-agent-check--stderr-limit))
      (princ (decode-coding-string
              (json-serialize (cl-loop for (k v) on masked by #'cddr
                                       append (list k (if (eq k :tools) (vconcat v) v))))
              'utf-8))
      (terpri)
      (kill-emacs 0))))

;;;; The editing Emacs's side

(defun drgnx-agent-check--wrap (argv)
  "ARGV, run in a systemd scope with a memory cap where systemd runs the session."
  (if (eq (drgnx-jobs-launcher) 'systemd)
      (append (list "systemd-run" "--user" "--scope" "-q" "-p" (concat "MemoryMax=" drgnx-agent-check--memory)
                    "-p" "MemorySwapMax=0" "--")
              argv)
    argv))

(defun drgnx-agent-check--mcp-argv ()
  "The command line of the child Emacs of an MCP Test: nothing of the server is on it."
  (drgnx-agent-check--wrap
   (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-L" drgnx-agent-check--dir
         "--eval" "(setq load-prefer-newer t)" "-l" "drgnx-agent-check" "-f" "drgnx-agent-check-main")))

(defun drgnx-agent-check--expand (text)
  "TEXT with the `${VAR}' and `${VAR:-default}' references the agent expands replaced."
  (if (stringp text)
      (replace-regexp-in-string
       "\\${\\([A-Za-z_][A-Za-z0-9_]*\\)\\(?::-\\([^}]*\\)\\)?}"
       (lambda (m) (or (getenv (match-string 1 m)) (match-string 2 m) m))
       text t t)
    text))

(defun drgnx-agent-check--expand-spec (kind spec)
  "SPEC with `${VAR}' expanded in the places Claude Code and Gemini expand it; other agents' SPEC as it is."
  (if (not (memq kind '(claude gemini)))
      spec
    (let ((pairs (lambda (alist) (mapcar (lambda (p) (cons (car p) (drgnx-agent-check--expand (cdr p)))) alist))))
      (list :command (drgnx-agent-check--expand (plist-get spec :command))
            :args (mapcar #'drgnx-agent-check--expand (append (plist-get spec :args) nil))
            :env (funcall pairs (plist-get spec :env))
            :url (drgnx-agent-check--expand (plist-get spec :url))
            :headers (funcall pairs (plist-get spec :headers))
            :type (plist-get spec :type)))))

(defun drgnx-agent-check--object (alist)
  "ALIST ((NAME . VALUE)…) as a hash table for JSON."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (p alist table)
      (puthash (drgnx-agent-config-json-keystr (car p)) (format "%s" (cdr p)) table))))

(defun drgnx-agent-check--finish (callback result secrets)
  "Call CALLBACK with RESULT masked with SECRETS; a failure in it never reaches the caller."
  (condition-case err
      (funcall callback (drgnx-agent-check--mask-result result secrets))
    (error (ignore-errors (message "Agent check: %s" (drgnx-agent-config-mask-text (error-message-string err) secrets))))))

(cl-defun drgnx-agent-check--start (argv &key input dir env limit done)
  "Run ARGV (a list) with INPUT on its stdin, in DIR with ENV added, ended after LIMIT seconds.  DONE is called once
with the process, the output, the errors, `timed-out' (non-nil when LIMIT ended it) and the time.  The process."
  (let* ((start (float-time)) (out "") (err "") (timed-out nil) (finished nil)
         (default-directory (file-name-as-directory (expand-file-name (or dir default-directory))))
         (process-environment (append env process-environment))
         (err-proc (make-pipe-process
                    :name "drgnx-check-stderr" :noquery t :coding 'utf-8-unix
                    :filter (lambda (_p s) (when (< (length err) drgnx-agent-check--capture-limit)
                                             (setq err (concat err s))))))
         timer proc)
    (let ((finish (lambda ()
                    (unless finished
                      (setq finished t)
                      (when timer (cancel-timer timer))
                      (ignore-errors (delete-process err-proc))
                      (funcall done proc out err timed-out (- (float-time) start))))))
      (setq proc (make-process
                  :name "drgnx-check" :command argv :connection-type 'pipe :noquery t :coding 'utf-8-unix
                  :stderr err-proc
                  :filter (lambda (_p s) (when (< (length out) drgnx-agent-check--capture-limit)
                                           (setq out (concat out s))))
                  :sentinel (lambda (p _e)
                              (unless (process-live-p p) (run-at-time 0.1 nil finish)))))
      (setq timer (run-at-time limit nil
                               (lambda ()
                                 (unless finished
                                   (setq timed-out t)
                                   (drgnx-agent-check--kill-tree (process-id proc))
                                   ;; the sentinel finishes; this is for a process that is already gone
                                   (unless (process-live-p proc) (funcall finish))))))
      (when input
        (ignore-errors (process-send-string proc input))
        (ignore-errors (process-send-eof proc)))
      proc)))

(defun drgnx-agent-check--mcp-result (out err timed-out time limit kind name secrets)
  "The result of an MCP Test from what the child Emacs printed (OUT), said (ERR) and did (TIMED-OUT, TIME in
seconds): the child's own result when it printed one, else what is known without it.  ERR is masked with SECRETS
before it is cut."
  (let* ((parsed (when-let* ((line (car (last (split-string out "\n" t "[ \t\r]+")))))
                   (and (string-prefix-p "{" line) (drgnx-agent-check--parse line))))
         (status (and parsed (intern (or (plist-get parsed :status) "failed"))))
         (stderr (drgnx-agent-check--cut (drgnx-agent-config-mask-text (string-trim err) secrets)
                                         drgnx-agent-check--stderr-limit))
         (result
          (cond
           ((memq status '(ok failed needs-login timeout))
            (list :status status
                  :tools (plist-get parsed :tools)
                  :error (if (eq status 'needs-login)
                             (concat "The server needs a login. " (drgnx-agent-check-login-hint kind name))
                           (plist-get parsed :error))
                  :stderr (drgnx-agent-check--cut (or (plist-get parsed :stderr) "") drgnx-agent-check--stderr-limit)
                  :time (or (plist-get parsed :time) time)))
           (timed-out
            (list :status 'timeout :error (format "No answer within %s seconds; the check was stopped." limit)
                  :stderr stderr :time time))
           (t (list :status 'failed :error "The check ended without a result." :stderr stderr :time time)))))
    (cl-loop for (k v) on result by #'cddr unless (null v) append (list k v))))

(defun drgnx-agent-check-mcp (item root callback)
  "Test the MCP server ITEM in a separate Emacs; the process.  ROOT is the project (the server's working directory).
CALLBACK gets (:status ok|failed|needs-login|timeout :tools NAMES :error STRING :stderr STRING :time FLOAT), masked."
  (let* ((kind (plist-get item :kind))
         (spec (plist-get item :spec))
         (expanded (drgnx-agent-check--expand-spec kind spec))
         (secrets (delete-dups (append (drgnx-agent-check--secrets item)
                                       (drgnx-agent-check--secrets (list :spec expanded)))))
         (type (or (plist-get spec :type)
                   (cond ((plist-get spec :command) 'stdio) ((plist-get spec :url) 'http))))
         (limit drgnx-agent-check-timeout)
         (input (decode-coding-string
                 (json-serialize
                  (append (list :type (symbol-name (or type 'stdio))
                                :root (expand-file-name (or root default-directory))
                                :timeout limit
                                :protocol drgnx-agent-check--protocol
                                :secrets (vconcat secrets)
                                :env (drgnx-agent-check--object (plist-get expanded :env))
                                :headers (drgnx-agent-check--object (plist-get expanded :headers))
                                :args (vconcat (mapcar (lambda (a) (format "%s" a)) (plist-get expanded :args))))
                          (and (plist-get expanded :command) (list :command (plist-get expanded :command)))
                          (and (plist-get expanded :url) (list :url (plist-get expanded :url)))))
                 'utf-8))
         (name (plist-get item :name)))
    (condition-case failure
        (drgnx-agent-check--start
         (drgnx-agent-check--mcp-argv)
         :input (concat input "\n") :dir root :limit (+ limit drgnx-agent-check--grace)
         :done
         (lambda (_proc out err timed-out time)
           (drgnx-agent-check--finish
            callback (drgnx-agent-check--mcp-result out err timed-out time limit kind name secrets) secrets)))
      (error (drgnx-agent-check--finish
              callback (list :status 'failed :error (concat "The check could not start: " (error-message-string failure)))
              secrets)
             nil))))

;;;; Hooks

(defun drgnx-agent-check-sample-event (kind event root)
  "The JSON object (an alist) the agent KIND sends to a hook of EVENT, with ROOT as the project.
Claude Code and Kimi Code send the same shape; Codex adds a model and a turn; Gemini has its own events and
fields.  The tool is always a Bash command that echoes `drgnx-hook-test'."
  (let* ((cwd (directory-file-name (expand-file-name (or root default-directory))))
         (transcript (expand-file-name "drgnx-hook-test/transcript.jsonl" temporary-file-directory))
         (command '((command . "echo drgnx-hook-test")))
         (base `((session_id . "drgnx-hook-test") (transcript_path . ,transcript) (cwd . ,cwd)
                 (hook_event_name . ,event))))
    (append
     base
     (pcase kind
       ('gemini
        (append `((timestamp . ,(format-time-string "%FT%T.000Z" nil t)))
                (pcase event
                  ("BeforeTool" `((tool_name . "run_shell_command") (tool_input . ,command)))
                  ("AfterTool" `((tool_name . "run_shell_command") (tool_input . ,command)
                                 (tool_response . ((llmContent . "drgnx-hook-test") (returnDisplay . "drgnx-hook-test")))))
                  ("BeforeAgent" '((prompt . "drgnx hook test")))
                  ("AfterAgent" '((prompt . "drgnx hook test") (prompt_response . "drgnx hook test") (stop_hook_active . :false)))
                  ("Notification" '((notification_type . "ToolPermission") (message . "drgnx hook test") (details . ((tool . "run_shell_command")))))
                  ("SessionStart" '((source . "startup")))
                  ("SessionEnd" '((reason . "exit")))
                  ("PreCompress" '((trigger . "manual")))
                  ((or "BeforeModel" "BeforeToolSelection")
                   '((llm_request . ((model . "drgnx-test") (messages . [((role . "user") (content . "drgnx hook test"))])))))
                  ("AfterModel"
                   '((llm_request . ((model . "drgnx-test") (messages . [((role . "user") (content . "drgnx hook test"))])))
                     (llm_response . ((text . "drgnx hook test"))))))))
       (_
        (append (and (eq kind 'codex) '((model . "drgnx-test") (turn_id . "drgnx-hook-test-turn")))
                (pcase event
                  ((or "PreToolUse" "PermissionRequest")
                   `((tool_name . "Bash") (tool_input . ,command) (tool_use_id . "drgnx-hook-test-tool")))
                  ("PostToolUse"
                   `((tool_name . "Bash") (tool_input . ,command) (tool_use_id . "drgnx-hook-test-tool")
                     (tool_response . ((stdout . "drgnx-hook-test") (stderr . "") (interrupted . :false)))))
                  ("PostToolUseFailure"
                   `((tool_name . "Bash") (tool_input . ,command) (tool_use_id . "drgnx-hook-test-tool")
                     (error . "drgnx hook test") (is_interrupt . :false)))
                  ("UserPromptSubmit" '((prompt . "drgnx hook test")))
                  ((or "Stop" "SubagentStop") '((stop_hook_active . :false)))
                  ("SessionStart" '((source . "startup")))
                  ("SessionEnd" '((reason . "other")))
                  ("Notification" '((message . "drgnx hook test") (notification_type . "permission_prompt")))
                  ((or "PreCompact" "PostCompact") '((trigger . "manual") (custom_instructions . ""))))))))))

(defun drgnx-agent-check--hook-timeout (item)
  "Seconds ITEM's hook may run: its own timeout (Gemini keeps milliseconds), 60 without one."
  (let* ((spec (plist-get item :spec))
         (timeout (plist-get spec :timeout)))
    (cond ((not (and (numberp timeout) (> timeout 0))) 60)
          ((eq (plist-get spec :timeout-unit) 'ms) (/ timeout 1000.0))
          (t timeout))))

(defun drgnx-agent-check--hook-argv (_item)
  "The command line of a hook run: the hook's command travels in the environment, not in the command line."
  (drgnx-agent-check--wrap
   (list "sh" "-c" "c=$DRGNX_HOOK_COMMAND; unset DRGNX_HOOK_COMMAND; eval \"$c\"")))

(defun drgnx-agent-check-hook (item root callback)
  "Run the hook ITEM for real, in ROOT, with the sample event on stdin; the process.
CALLBACK gets (:exit N :stdout S :stderr S :time F), masked; a hook that ran out of time has :exit nil and :timeout t."
  (let* ((spec (plist-get item :spec))
         (kind (plist-get item :kind))
         (secrets (drgnx-agent-check--secrets item))
         (limit (drgnx-agent-check--hook-timeout item))
         (event (json-serialize (drgnx-agent-check-sample-event kind (plist-get spec :event) root)
                                :false-object :false)))
    (condition-case failure
        (drgnx-agent-check--start
         (drgnx-agent-check--hook-argv item)
         :input (concat (decode-coding-string event 'utf-8) "\n") :dir root :limit limit
         :env (list (concat "DRGNX_HOOK_COMMAND=" (or (plist-get spec :command) "")))
         :done
         (lambda (proc out err timed-out time)
           (let* ((masked-out (drgnx-agent-config-mask-text out secrets))
                  (masked-err (drgnx-agent-config-mask-text err secrets))
                  (status (process-status proc))
                  (code (process-exit-status proc))
                  (exit (cond (timed-out nil) ((eq status 'signal) (+ 128 code)) (t code))))
             (drgnx-agent-check--finish
              callback
              (append (list :exit exit
                            :stdout (drgnx-agent-check--cut masked-out drgnx-agent-check--hook-limit)
                            :stderr (drgnx-agent-check--cut masked-err drgnx-agent-check--hook-limit)
                            :time time)
                      (and timed-out (list :timeout t)))
              secrets))))
      (error (drgnx-agent-check--finish
              callback (list :exit nil :error (concat "The hook could not be started: " (error-message-string failure)))
              secrets)
             nil))))

(provide 'drgnx-agent-check)
;;; drgnx-agent-check.el ends here
