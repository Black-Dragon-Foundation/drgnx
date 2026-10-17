;;; drgnx-gateway.el --- The agent traffic gateway: streamed, token-only, spend, budget, fallback -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A local HTTP server (127.0.0.1) for the traffic drgnx may route: agents on OpenRouter, Ollama or the user's own
;; Anthropic key talk to it instead of the provider.  Each agent gets a token (`drgnx-gateway-register'), never a
;; key: the gateway checks the token, adds the provider's real key, forwards the request with curl (its config on
;; stdin) and streams the answer back as it comes.  It counts the tokens each answer reports — spend per job, task
;; and agent in work.db — refuses new requests once a job's budget is spent, and when a provider fails before
;; answering (no answer, 429, 401/402, 5xx) tries the next one the registration allows.  Subscription CLIs never
;; come here.  It runs in the hub process (drgnx-hub.el), never in the editing Emacs.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-http)
(require 'drgnx-ai)
(require 'drgnx-work-db)

(defvar drgnx-gateway-event-functions nil
  "Functions called with (EVENT DATA): `request' (:job :task :agent :provider :model :status :input :output :cost),
`fallback' (:agent :from :to :why), `budget' (:job :spent :budget).")

(defvar drgnx-gateway--server nil)
(defvar drgnx-gateway--registrations (make-hash-table :test #'equal) "SHA-256 of a token → its registration.")
(defvar drgnx-gateway--keys (make-hash-table :test #'eq) "Provider → key given over the hub's socket (memory only).")

(defconst drgnx-gateway--retry-statuses '(401 402 408 409 429)
  "Statuses (besides 5xx) after which the next provider is tried.")

;;;; Registrations

(defun drgnx-gateway--hash (token) (secure-hash 'sha256 token))

(defun drgnx-gateway--random-token ()
  "64 hex characters from the system's random source."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (unless (and (eql 0 (call-process "head" nil t nil "-c" "32" "/dev/urandom")) (= (buffer-size) 32))
        (error "No random bytes for a gateway token")))
    (mapconcat (lambda (b) (format "%02x" b)) (buffer-string) "")))

(defun drgnx-gateway-register (registration)
  "Let an agent use the gateway: REGISTRATION (:job :task :agent :chain ((PROVIDER . MODEL)…) :budget USD).  Returns
its token (shown once: only its hash is kept)."
  (let ((token (drgnx-gateway--random-token)))
    (puthash (drgnx-gateway--hash token) registration drgnx-gateway--registrations)
    token))

(defun drgnx-gateway-unregister (token)
  (remhash (drgnx-gateway--hash token) drgnx-gateway--registrations))

(defun drgnx-gateway-registrations ()
  "((SHA256 . REGISTRATION)…): what a restarted hub needs (never a token)."
  (let (out) (maphash (lambda (k v) (push (cons k v) out)) drgnx-gateway--registrations) out))

(defun drgnx-gateway-load-registrations (alist)
  "Take ALIST from `drgnx-gateway-registrations' (a hub restarting)."
  (pcase-dolist (`(,hash . ,reg) alist) (puthash hash reg drgnx-gateway--registrations)))

(defun drgnx-gateway-set-key (provider key)
  "Use KEY for PROVIDER (held in memory, from a command the user ran)."
  (puthash provider key drgnx-gateway--keys))

;;;; Server

(defun drgnx-gateway-port () (and drgnx-gateway--server (process-contact drgnx-gateway--server :service)))

(defun drgnx-gateway-start (&optional port)
  "Listen on 127.0.0.1 (PORT, else one free); return the port."
  (drgnx-gateway-stop)
  (setq drgnx-gateway--server
        (make-network-process :name "drgnx-gateway" :server t :host "127.0.0.1" :service (or port t)
                              :family 'ipv4 :coding 'binary :noquery t
                              :filter #'drgnx-gateway--filter :sentinel #'drgnx-gateway--client-sentinel))
  (drgnx-gateway-port))

(defun drgnx-gateway-stop ()
  (when drgnx-gateway--server (delete-process drgnx-gateway--server) (setq drgnx-gateway--server nil))
  (dolist (p (process-list))
    (when (string-prefix-p "drgnx-gw-" (process-name p)) (delete-process p))))

(defun drgnx-gateway--emit (event &rest data) (run-hook-with-args 'drgnx-gateway-event-functions event data))

(defun drgnx-gateway--respond (conn status type message)
  "Answer CONN with STATUS and an Anthropic-shaped error (TYPE, MESSAGE), then close it."
  (when (process-live-p conn)
    (let ((body (encode-coding-string (json-serialize (list :type "error" :error (list :type type :message message))) 'utf-8)))
      (process-send-string conn (format "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                                        status type (length body)))
      (process-send-string conn body)
      (drgnx-gateway--close conn))))

(defun drgnx-gateway--close (conn)
  "Close CONN once what was sent has gone."
  (when (process-live-p conn)
    (process-put conn :done t)
    (ignore-errors (process-send-eof conn))
    (run-at-time 0.05 nil (lambda () (when (process-live-p conn) (delete-process conn))))))

(defun drgnx-gateway--filter (conn bytes)
  (unless (process-get conn :request)
    (let* ((buf (concat (or (process-get conn :buf) "") bytes))
           (req (drgnx-http-parse-request buf)))
      (process-put conn :buf buf)
      (cond ((null req))
            ((plist-get req :error)
             (process-put conn :request req)
             (drgnx-gateway--respond conn (plist-get req :error) "invalid_request_error" "the request cannot be taken"))
            (t (process-put conn :request req) (process-put conn :buf nil)
               (drgnx-gateway--handle conn req))))))

(defun drgnx-gateway--client-sentinel (conn _event)
  ;; the agent hung up: its upstream request goes too
  (unless (process-live-p conn)
    (when-let* ((curl (process-get conn :curl)))
      (when (process-live-p curl) (process-put curl :client-gone t) (delete-process curl)))))

(defun drgnx-gateway--token (req)
  (let ((auth (drgnx-http-header req "authorization")))
    (or (and auth (string-match "\\`Bearer +\\(.+\\)\\'" auth) (match-string 1 auth))
        (drgnx-http-header req "x-api-key"))))

(defun drgnx-gateway--handle (conn req)
  (let* ((token (drgnx-gateway--token req))
         (reg (and token (gethash (drgnx-gateway--hash token) drgnx-gateway--registrations))))
    (cond
     ((not reg) (drgnx-gateway--respond conn 401 "authentication_error" "not a drgnx gateway token"))
     ((and (plist-get reg :budget) (plist-get reg :job)
           (>= (plist-get (drgnx-work-db-spend :job (plist-get reg :job)) :cost) (plist-get reg :budget)))
      (drgnx-gateway--emit 'budget :job (plist-get reg :job)
                           :spent (plist-get (drgnx-work-db-spend :job (plist-get reg :job)) :cost) :budget (plist-get reg :budget))
      (drgnx-gateway--respond conn 429 "budget_exceeded" (format "the job's budget (%s USD) is spent" (plist-get reg :budget))))
     (t (drgnx-gateway--try conn req reg (plist-get reg :chain) nil)))))

;;;; Forwarding

(defun drgnx-gateway--quote (bytes)
  "BYTES as a curl config string."
  (concat "\"" (replace-regexp-in-string
                "[\\\"\n\r\t]" (lambda (c) (pcase c ("\\" "\\\\") ("\"" "\\\"") ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")))
                bytes t t)
          "\""))

(defun drgnx-gateway--body (req model)
  "REQ's body, its top-level \"model\" replaced by MODEL when MODEL is non-nil."
  (let ((body (plist-get req :body)))
    (if (or (null model) (string-empty-p body)) body
      (let ((json (ignore-errors (json-parse-string (decode-coding-string body 'utf-8) :object-type 'plist))))
        (if (not json) body
          (encode-coding-string (json-serialize (plist-put json :model model)) 'utf-8))))))

(defun drgnx-gateway--price-cost (p input output)
  (let ((price (plist-get p :price)))
    (if (consp price) (+ (* input (car price) 1e-6) (* output (cdr price) 1e-6)) 0.0)))

(defun drgnx-gateway--try (conn req reg steps reasons)
  "Forward REQ along STEPS; REASONS: why earlier ones were passed over ((PROVIDER . WHY)…)."
  (cond
   ((not (process-live-p conn)))
   ((null steps)
    (drgnx-gateway--respond conn 502 "api_error"
                            (concat "no provider answered: "
                                    (mapconcat (lambda (r) (format "%s: %s" (car r) (cdr r))) (reverse reasons) "; "))))
   (t
    (let* ((id (car (car steps))) (model (cdr (car steps))) (p (drgnx-ai-provider id))
           (key (and p (plist-get p :key-env) (or (gethash id drgnx-gateway--keys) (drgnx-ai-key id))))
           (skip (cond ((null p) "not configured")
                       ((not (plist-get p :messages)) "the gateway cannot carry it")
                       ((and (plist-get p :key-env) (not key)) "no key"))))
      (if skip
          (drgnx-gateway--next conn req reg steps reasons id skip)
        (drgnx-gateway--forward conn req reg steps reasons id model p key))))))

(defun drgnx-gateway--next (conn req reg steps reasons id why)
  (when (cdr steps)
    (drgnx-gateway--emit 'fallback :agent (plist-get reg :agent) :from id :to (car (cadr steps)) :why why))
  (drgnx-gateway--try conn req reg (cdr steps) (cons (cons id why) reasons)))

(defun drgnx-gateway--forward (conn req reg steps reasons id model p key)
  (let* ((url (concat (replace-regexp-in-string "/v1/?\\'" "" (plist-get p :url)) (plist-get req :path)))
         (body (drgnx-gateway--body req model))
         (header (lambda (name value) (concat "header = " (drgnx-gateway--quote (concat name ": " value)) "\n")))
         (config (concat "url = " (drgnx-gateway--quote url) "\n"
                         "request = " (drgnx-gateway--quote (plist-get req :method)) "\n"
                         "no-buffer\ninclude\nsilent\nshow-error\nconnect-timeout = 10\n"
                         (mapconcat (lambda (h) (if-let* ((v (drgnx-http-header req h))) (funcall header h v) ""))
                                    '("content-type" "accept" "anthropic-version" "anthropic-beta") "")
                         (cond ((null key) "")
                               ((eq (plist-get p :auth) 'x-api-key) (funcall header "x-api-key" key))
                               (t (funcall header "Authorization" (concat "Bearer " key))))
                         (if (string-empty-p body) "" (concat "data-binary = " (drgnx-gateway--quote body) "\n"))))
         (scan (drgnx-http-usage-scanner))
         (err (generate-new-buffer " *drgnx-gw-err*" t))
         (curl (make-process
                :name "drgnx-gw-curl" :command '("curl" "-K" "-") :connection-type 'pipe :coding 'binary :noquery t
                :buffer nil :stderr err
                :filter (lambda (proc bytes) (drgnx-gateway--upstream-bytes proc conn bytes scan))
                :sentinel (lambda (proc _e)
                            (unless (process-live-p proc)
                              (when (buffer-live-p err) (kill-buffer err))
                              (drgnx-gateway--upstream-done proc conn req reg steps reasons id model p scan))))))
    (process-put conn :curl curl)
    (process-send-string curl config)
    (process-send-eof curl)))

(defun drgnx-gateway--upstream-bytes (curl conn bytes scan)
  "CURL's output so far: hold it until the head is whole, then (unless it calls for the next provider) pass the
head and every later byte to CONN."
  (if (process-get curl :started)
      (progn (funcall scan bytes) (when (process-live-p conn) (process-send-string conn bytes)))
    (let ((buf (concat (or (process-get curl :buf) "") bytes)) (go t))
      (while (and go (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)[^\r\n]*\r\n" buf))
        (let ((status (string-to-number (match-string 1 buf))) (end (string-search "\r\n\r\n" buf)))
          (cond
           ((null end) (setq go nil))
           ((< status 200) (setq buf (substring buf (+ end 4))))   ; 100 Continue: the real head follows
           (t
            (setq go nil)
            (process-put curl :status status)
            (if (or (>= status 500) (memq status drgnx-gateway--retry-statuses))
                (progn (process-put curl :retry t) (delete-process curl))
              (let* ((head (substring buf 0 end)) (rest (substring buf (+ end 4)))
                     (ctype (and (string-match "^[Cc]ontent-[Tt]ype: *\\([^\r\n]+\\)" head) (match-string 1 head))))
                (process-put curl :started t)
                (when (process-live-p conn)
                  (process-send-string conn (format "HTTP/1.1 %d OK\r\nContent-Type: %s\r\nConnection: close\r\n\r\n"
                                                    status (or ctype "application/json")))
                  (unless (string-empty-p rest) (funcall scan rest) (process-send-string conn rest))))
              (setq buf ""))))))
      (process-put curl :buf buf))))

(defun drgnx-gateway--upstream-done (curl conn req reg steps reasons id model p scan)
  (let ((status (process-get curl :status)))
    (cond
     ((process-get curl :client-gone)
      (drgnx-gateway--spend reg id model p scan (or status 0)))
     ((process-get curl :started)
      (drgnx-gateway--close conn)
      (drgnx-gateway--spend reg id model p scan status))
     (t (drgnx-gateway--next conn req reg steps reasons id
                             (if (and status (process-get curl :retry)) (format "HTTP %d" status) "no answer"))))))

(defun drgnx-gateway--spend (reg id model p scan status)
  (let* ((u (funcall scan ""))
         (input (or (plist-get u :input) 0)) (output (or (plist-get u :output) 0))
         (cost (or (plist-get u :cost) (drgnx-gateway--price-cost p input output)))
         (row (list :job (plist-get reg :job) :task (plist-get reg :task) :agent (plist-get reg :agent)
                    :provider (symbol-name id) :model model :input input :output output :cost cost :status status)))
    (apply #'drgnx-work-db-add-spend row)
    (apply #'drgnx-gateway--emit 'request row)))

(provide 'drgnx-gateway)
;;; drgnx-gateway.el ends here
