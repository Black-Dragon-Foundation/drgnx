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
(require 'url-parse)
(require 'drgnx-guard)
(require 'drgnx-http)
(require 'drgnx-ai)
(require 'drgnx-timer)
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
  "Let an agent use the gateway: REGISTRATION (:job :task :agent :chain ((PROVIDER . MODEL)…) :budget USD
:openrouter RESTRICTIONS — `drgnx-gateway-restrictions': sent to OpenRouter steps only).  Returns
its token (shown once: only its hash is kept)."
  (let ((token (drgnx-gateway--random-token)))
    (puthash (drgnx-gateway--hash token) registration drgnx-gateway--registrations)
    token))

(defun drgnx-gateway-set-budget (job budget)
  "Every registration of JOB gets BUDGET (USD)."
  (maphash (lambda (k reg) (when (equal (plist-get reg :job) job) (puthash k (plist-put reg :budget budget) drgnx-gateway--registrations)))
           drgnx-gateway--registrations))

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
                              :filter (drgnx-guard-wrap #'drgnx-gateway--filter "gateway client")
                              :sentinel (drgnx-guard-wrap #'drgnx-gateway--client-sentinel "gateway client")))
  (drgnx-gateway-port))

(defvar drgnx-gateway--sockets)         ; Per-session sockets, below

(defun drgnx-gateway-stop ()
  (when drgnx-gateway--server (delete-process drgnx-gateway--server) (setq drgnx-gateway--server nil))
  (dolist (p (process-list))
    (when (string-prefix-p "drgnx-gw-" (process-name p)) (delete-process p)))
  (mapc #'drgnx-gateway-close-socket (hash-table-keys drgnx-gateway--sockets)))

;;;; Per-session sockets

(defvar drgnx-gateway--sockets (make-hash-table :test #'equal)
  "Socket path → the listening process.  Its accepted connections carry the path as `:gateway-socket'.")

(defun drgnx-gateway-listen-socket (path)
  "Also listen on the Unix socket PATH (mode 0600; its directory is the session's private one): the way an agent
without the host's loopback reaches the gateway.  The same filter, path allowlist and token check as the TCP
listener.  A stale file at PATH is replaced.  Return PATH."
  (drgnx-gateway-close-socket path)
  (when (and (file-exists-p path) (not (file-directory-p path))) (delete-file path))
  (let ((server (with-file-modes #o600
                  (make-network-process :name (concat "drgnx-gw-sock " path) :server t :family 'local :service path
                                        :coding 'binary :noquery t
                                        :filter (drgnx-guard-wrap #'drgnx-gateway--filter "gateway client")
                                        :sentinel (drgnx-guard-wrap #'drgnx-gateway--client-sentinel "gateway client")))))
    (process-put server :gateway-socket path)
    (puthash path server drgnx-gateway--sockets)
    path))

(defun drgnx-gateway-close-socket (path)
  "Stop listening on PATH, cut its connections (and so their upstream requests), remove the file."
  (when-let* ((server (gethash path drgnx-gateway--sockets)))
    (remhash path drgnx-gateway--sockets)
    (dolist (p (process-list))
      (when (equal (process-get p :gateway-socket) path) (delete-process p)))
    (ignore-errors (delete-process server)))
  (when (and (file-exists-p path) (not (file-directory-p path)) (not (file-symlink-p path)))
    (ignore-errors (delete-file path))))

(defun drgnx-gateway--emit (event &rest data) (run-hook-with-args 'drgnx-gateway-event-functions event data))

(defun drgnx-gateway--write (conn bytes)
  "Send BYTES to the agent's connection CONN — unless it is gone (an agent that hung up): then CONN goes (and with
it, through its sentinel, the request upstream), never an error in a filter."
  (when (process-live-p conn)
    (condition-case nil (process-send-string conn bytes)
      (error (ignore-errors (delete-process conn))))))

(defun drgnx-gateway--respond (conn status type message)
  "Answer CONN with STATUS and an Anthropic-shaped error (TYPE, MESSAGE), then close it."
  (when (process-live-p conn)
    (let ((body (encode-coding-string (json-serialize (list :type "error" :error (list :type type :message message))) 'utf-8)))
      (drgnx-gateway--write conn (format "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                                         status type (length body)))
      (drgnx-gateway--write conn body)
      (drgnx-gateway--close conn))))

(defun drgnx-gateway--close (conn)
  "Close CONN once what was sent has gone."
  (when (process-live-p conn)
    (process-put conn :done t)
    (ignore-errors (process-send-eof conn))
    (drgnx-timer-start (cons 'gateway-close conn) 0.05 #'drgnx-gateway--hang-up :args (list conn) :owner conn)))

(defun drgnx-gateway--hang-up (conn)
  "The timer function of `drgnx-gateway--close': what was sent has gone, delete CONN."
  (when (process-live-p conn) (delete-process conn)))

(defun drgnx-gateway--filter (conn bytes)
  "Take BYTES of CONN's request.  Once its head is whole a token that is no registration is refused at once, before
the body (up to 32 MB) is waited for; the body's pieces are kept in a list and joined when the last one came."
  (unless (process-get conn :request)
    (if-let* ((need (process-get conn :need)))
        (progn (process-put conn :chunks (cons bytes (process-get conn :chunks)))
               (process-put conn :size (+ (process-get conn :size) (length bytes)))
               (when (>= (process-get conn :size) need) (drgnx-gateway--request-whole conn)))
      (let* ((buf (concat (or (process-get conn :buf) "") bytes))
             (head (drgnx-http-parse-head buf)))
        (cond ((null head) (process-put conn :buf buf))
              ((plist-get head :error)
               (process-put conn :request head)
               (drgnx-gateway--respond conn (plist-get head :error) "invalid_request_error" "the request cannot be taken"))
              ((not (drgnx-gateway--registration head))
               (process-put conn :request head)
               (drgnx-gateway--respond conn 401 "authentication_error" "not a drgnx gateway token"))
              (t (process-put conn :buf nil)
                 (process-put conn :need (+ (plist-get head :body-start) (plist-get head :length)))
                 (process-put conn :chunks (list buf))
                 (process-put conn :size (length buf))
                 (when (>= (length buf) (process-get conn :need)) (drgnx-gateway--request-whole conn))))))))

(defun drgnx-gateway--request-whole (conn)
  "All of CONN's request came: parse it and handle it."
  (let ((req (drgnx-http-parse-request (apply #'concat (nreverse (process-get conn :chunks))))))
    (process-put conn :chunks nil)
    (process-put conn :request req)
    (drgnx-gateway--guarded conn (lambda () (drgnx-gateway--handle conn req)))))

(defun drgnx-gateway--guarded (conn fn)
  "Run FN; an error answers CONN 500 and closes it (never an agent left waiting)."
  (condition-case err (funcall fn)
    (error (drgnx-gateway--respond conn 500 "api_error" (format "the gateway failed: %s" (error-message-string err))))))

(defconst drgnx-gateway--paths
  "\\`/v1/\\(?:messages\\(?:/count_tokens\\)?\\|models\\(?:/[A-Za-z0-9._:-]+\\)?\\)\\(?:\\?[^#]*\\)?\\'"
  "The request paths the gateway forwards: Anthropic's Messages API (and its token count and model list).")

(defun drgnx-gateway--path-ok-p (path)
  (and (string-match-p drgnx-gateway--paths path) (not (string-search ".." path))
       (not (string-match-p "[\000-\040\177]" path))))

(defun drgnx-gateway--client-sentinel (conn _event)
  ;; the agent hung up: its upstream request goes too
  (unless (process-live-p conn)
    (when-let* ((curl (process-get conn :curl)))
      (when (process-live-p curl) (process-put curl :client-gone t) (delete-process curl)))))

(defun drgnx-gateway--token (req)
  (let ((auth (drgnx-http-header req "authorization")))
    (or (and auth (string-match "\\`Bearer +\\(.+\\)\\'" auth) (match-string 1 auth))
        (drgnx-http-header req "x-api-key"))))

(defun drgnx-gateway--registration (req)
  "The registration REQ's token belongs to, or nil."
  (when-let* ((token (drgnx-gateway--token req)))
    (gethash (drgnx-gateway--hash token) drgnx-gateway--registrations)))

(defun drgnx-gateway--handle (conn req)
  (let ((reg (drgnx-gateway--registration req)))
    (cond
     ((not reg) (drgnx-gateway--respond conn 401 "authentication_error" "not a drgnx gateway token"))
     ;; the path is appended to the provider's URL: nothing that could change where the key goes
     ((not (drgnx-gateway--path-ok-p (plist-get req :path)))
      (drgnx-gateway--respond conn 404 "not_found_error" "the gateway forwards Anthropic's Messages API only"))
     ((and (plist-get reg :budget) (plist-get reg :job)
           (>= (plist-get (drgnx-work-db-spend :job (plist-get reg :job)) :cost) (plist-get reg :budget)))
      (drgnx-gateway--emit 'budget :job (plist-get reg :job)
                           :spent (plist-get (drgnx-work-db-spend :job (plist-get reg :job)) :cost) :budget (plist-get reg :budget))
      (drgnx-gateway--respond conn 429 "budget_exceeded" (format "the job's budget (%s USD) is spent" (plist-get reg :budget))))
     (t (drgnx-gateway--try conn req reg (plist-get reg :chain) nil)))))

;;;; Forwarding

(defun drgnx-gateway--clean (bytes)
  "BYTES without control characters (a header value or name must not carry a line break into curl's config)."
  (replace-regexp-in-string "[\000-\037\177]" "" bytes t t))

(defun drgnx-gateway--quote (bytes)
  "BYTES as a curl config string."
  (concat "\"" (replace-regexp-in-string
                "[\\\"\n\r\t]" (lambda (c) (pcase c ("\\" "\\\\") ("\"" "\\\"") ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")))
                bytes t t)
          "\""))

(defun drgnx-gateway--slugs (value)
  "The provider slugs in VALUE (a list or a vector): the strings that are plain slugs (letters, digits, . _ / -)."
  (and (or (listp value) (vectorp value))
       (cl-loop for s in (append value nil)
                when (and (stringp s) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._/-]*\\'" s)) collect s)))

(defun drgnx-gateway--restrictions-check (raw)
  "Signal a `user-error' naming the first part of RAW (an `:openrouter' value) that is not a restriction: RAW not a
plist, a key other than :only :ignore :data-collection :zdr, a list of slugs that is not one, a :data-collection
other than deny or allow, a :zdr other than t or false.  Empty values (nil, [], JSON false or null) are no
restriction."
  (unless (and (proper-list-p raw) (cl-evenp (length raw)))
    (user-error "OpenRouter restrictions: :openrouter is %S, not a list of keys and values" raw))
  (cl-loop for (key value) on raw by #'cddr
           do (pcase key
                ((or :only :ignore)
                 (unless (and (or (listp value) (vectorp value))
                              (cl-every (lambda (s) (and (stringp s) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._/-]*\\'" s)))
                                        (append value nil)))
                   (user-error "OpenRouter restrictions: %s is %S, not a list of provider slugs (like (\"anthropic\"))"
                               key value)))
                (:data-collection
                 (unless (member value '(nil :null deny allow "deny" "allow"))
                   (user-error "OpenRouter restrictions: :data-collection is %S, not deny or allow" value)))
                (:zdr
                 (unless (memq value '(nil t :false :null))
                   (user-error "OpenRouter restrictions: :zdr is %S, not t or nil" value)))
                (_ (user-error "OpenRouter restrictions: %S is not one of :only :ignore :data-collection :zdr" key)))))

(defun drgnx-gateway-restrictions (raw &optional strict)
  "RAW (agents.eld's `:openrouter', or what a hub call carried: lists or vectors, strings for symbols) as the
restrictions a registration keeps: (:only SLUGS :ignore SLUGS :data-collection deny|allow :zdr t), each only when
set; nil when none is.  STRICT: anything in RAW that is not a restriction is a `user-error' naming it
\(`drgnx-gateway--restrictions-check'), never \"no restriction\" — an agent's start and the hub's registration use it."
  (when strict (drgnx-gateway--restrictions-check raw))
  (when (proper-list-p raw)
    (let* ((only (drgnx-gateway--slugs (plist-get raw :only)))
           (ignore (drgnx-gateway--slugs (plist-get raw :ignore)))
           (dc (let ((v (plist-get raw :data-collection))) (if (stringp v) (intern v) v)))
           (out nil))
      (when (eq (plist-get raw :zdr) t) (setq out (list :zdr t)))
      (when (memq dc '(deny allow)) (setq out (nconc (list :data-collection dc) out)))
      (when ignore (setq out (nconc (list :ignore ignore) out)))
      (when only (setq out (nconc (list :only only) out)))
      out)))

(defun drgnx-gateway--provider-object (restrictions)
  "The \"provider\" object for OpenRouter's request body from RESTRICTIONS (`drgnx-gateway-restrictions'), or nil.
`allow' is OpenRouter's default and your account's settings stay in force, so it is not sent."
  (let ((only (plist-get restrictions :only)) (ignore (plist-get restrictions :ignore)) out)
    (when (plist-get restrictions :zdr) (setq out (list :zdr t)))
    (when (eq (plist-get restrictions :data-collection) 'deny) (setq out (nconc (list :data_collection "deny") out)))
    (when ignore (setq out (nconc (list :ignore (vconcat ignore)) out)))
    (when only (setq out (nconc (list :only (vconcat only)) out)))
    out))

(define-error 'drgnx-gateway-bad-request "The request cannot be forwarded" 'error)

(defun drgnx-gateway--client-slugs (value what)
  "The strings in the client's provider.WHAT VALUE (a vector of strings), or a `drgnx-gateway-bad-request'."
  (unless (and (vectorp value) (cl-every #'stringp value))
    (signal 'drgnx-gateway-bad-request (list (format "provider.%s must be a list of provider slugs" what))))
  (append value nil))

(defun drgnx-gateway--merge-provider (client object)
  "The \"provider\" object the client sent (CLIENT: a plist, nil when it sent none) with drgnx's OBJECT merged in, the
stricter value winning: `only' is the intersection (when both ask), `ignore' the union, `data_collection' deny, `zdr'
true if either.  Every other key of CLIENT stays.  An `only' that leaves no provider is a `drgnx-gateway-bad-request'."
  (unless (and (proper-list-p client) (cl-evenp (length client)) (cl-loop for k in client by #'cddr always (keywordp k)))
    (signal 'drgnx-gateway-bad-request (list "provider must be an object")))
  (let ((out (copy-sequence client)))
    (when-let* ((mine (plist-get object :only)))
      (let ((mine (append mine nil)))
        (if (not (plist-member client :only))
            (setq out (plist-put out :only (vconcat mine)))
          (let ((common (seq-filter (lambda (s) (member s (drgnx-gateway--client-slugs (plist-get client :only) "only"))) mine)))
            (unless common
              (signal 'drgnx-gateway-bad-request
                      (list (format "no provider in common between the request's provider.only and drgnx's OpenRouter restrictions (%s)"
                                    (string-join mine ", ")))))
            (setq out (plist-put out :only (vconcat common)))))))
    (when-let* ((mine (plist-get object :ignore)))
      (let ((theirs (and (plist-member client :ignore) (drgnx-gateway--client-slugs (plist-get client :ignore) "ignore"))))
        (setq out (plist-put out :ignore (vconcat (delete-dups (append theirs (append mine nil))))))))
    (when (plist-get object :data_collection) (setq out (plist-put out :data_collection "deny")))
    (when (plist-get object :zdr) (setq out (plist-put out :zdr t)))
    out))

(defun drgnx-gateway--body (req model &optional provider)
  "REQ's body, its top-level \"model\" replaced by MODEL when MODEL is non-nil and, for PROVIDER (OpenRouter's
restrictions, `drgnx-gateway-restrictions') when it asks for any, the top-level \"provider\" object merged with the
one the client sent (`drgnx-gateway--merge-provider').  With restrictions a body that cannot be read as a JSON object
signals `drgnx-gateway-bad-request': nothing is sent that might not honour them."
  (let ((body (plist-get req :body)) (object (drgnx-gateway--provider-object provider)))
    (if (or (and (null model) (null object)) (string-empty-p body)) body
      (let ((json (condition-case nil (json-parse-string (decode-coding-string body 'utf-8) :object-type 'plist)
                    (error :unreadable))))
        (cond
         ((and object (not (proper-list-p json)))
          (signal 'drgnx-gateway-bad-request (list "the request body is not a JSON object, so drgnx's OpenRouter restrictions cannot be applied")))
         ((not (proper-list-p json)) body)
         (t (when model (setq json (plist-put json :model model)))
            (when object
              (setq json (plist-put json :provider
                                    (drgnx-gateway--merge-provider
                                     (let ((c (plist-get json :provider))) (if (eq c :null) nil c))
                                     object))))
            (encode-coding-string (json-serialize json) 'utf-8)))))))

(defconst drgnx-gateway--messages-path "\\`/v1/messages\\(?:\\?[^#]*\\)?\\'"
  "The one path that takes OpenRouter's \"provider\" object: a Messages request.  The token count and the model list
route to no provider.")

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
        (condition-case err (drgnx-gateway--forward conn req reg steps reasons id model p key)
          ;; a request the restrictions cannot be applied to: refused, not passed to this or another provider
          (drgnx-gateway-bad-request
           (drgnx-gateway--respond conn 400 "invalid_request_error" (error-message-string err)))
          ;; no curl, a body that cannot be written: a reason, and the next provider
          (error (drgnx-gateway--next conn req reg steps reasons id (format "cannot send (%s)" (error-message-string err))))))))))

(defun drgnx-gateway--body-dir ()
  "Where request bodies wait for curl (mode 0700; each file 0600, gone when its request ends)."
  (let ((dir (expand-file-name "hub/bodies" (drgnx-state-dir))))
    (unless (file-directory-p dir) (make-directory dir t))
    (set-file-modes dir #o700)
    dir))

(defun drgnx-gateway--write-body (body)
  "BODY in a fresh private file (curl takes no config line over ~10 MB); its name."
  (let* ((dir (drgnx-gateway--body-dir))             ; outside 0600: directories need their x bit
         (file (with-file-modes #o600 (make-temp-file (expand-file-name "b" dir)))))
    (let ((coding-system-for-write 'binary)) (write-region body nil file nil 'silent))
    file))

(defun drgnx-gateway--next (conn req reg steps reasons id why)
  (when (cdr steps)
    (drgnx-gateway--emit 'fallback :agent (plist-get reg :agent) :from id :to (car (cadr steps)) :why why))
  (drgnx-gateway--try conn req reg (cdr steps) (cons (cons id why) reasons)))

(defun drgnx-gateway--forward (conn req reg steps reasons id model p key)
  (let* ((url (concat (replace-regexp-in-string "/v1/?\\'" "" (plist-get p :url)) (plist-get req :path)))
         (_ (unless (equal (url-host (url-generic-parse-url url)) (url-host (url-generic-parse-url (plist-get p :url))))
              (error "the request would leave %s" (plist-get p :url))))
         (body (drgnx-gateway--body req model (and (eq id 'openrouter) (string-match-p drgnx-gateway--messages-path (plist-get req :path))
                                                   (plist-get reg :openrouter))))
         (body-file (and (not (string-empty-p body)) (drgnx-gateway--write-body body)))
         (header (lambda (name value)
                   (concat "header = " (drgnx-gateway--quote (concat (drgnx-gateway--clean name) ": " (drgnx-gateway--clean value))) "\n")))
         (config (concat "url = " (drgnx-gateway--quote url) "\n"
                         "request = " (drgnx-gateway--quote (plist-get req :method)) "\n"
                         "no-buffer\ninclude\nsilent\nshow-error\nsuppress-connect-headers\nconnect-timeout = 10\n"
                         (mapconcat (lambda (h) (if-let* ((v (drgnx-http-header req h))) (funcall header h v) ""))
                                    '("content-type" "accept" "anthropic-version" "anthropic-beta") "")
                         (cond ((null key) "")
                               ((eq (plist-get p :auth) 'x-api-key) (funcall header "x-api-key" key))
                               (t (funcall header "Authorization" (concat "Bearer " key))))
                         (if body-file (concat "data-binary = " (drgnx-gateway--quote (concat "@" body-file)) "\n") "")))
         (scan (drgnx-http-usage-scanner))
         (err (generate-new-buffer " *drgnx-gw-err*" t))
         (curl (condition-case e
                   (make-process
                    :name "drgnx-gw-curl" :command '("curl" "-K" "-") :connection-type 'pipe :coding 'binary :noquery t
                    :buffer nil :stderr err
                    :filter (drgnx-guard-wrap
                             (lambda (proc bytes) (drgnx-gateway--upstream-bytes proc conn bytes scan (null (cdr steps))))
                             "gateway upstream")
                    :sentinel (drgnx-guard-wrap
                               (lambda (proc _e)
                                 (unless (process-live-p proc)
                                   (when (buffer-live-p err) (kill-buffer err))
                                   (when body-file (ignore-errors (delete-file body-file)))
                                   (drgnx-gateway--guarded
                                    conn (lambda () (drgnx-gateway--upstream-done proc conn req reg steps reasons id model p scan)))))
                               "gateway upstream"))
                 (error (kill-buffer err) (when body-file (ignore-errors (delete-file body-file)))
                        (signal (car e) (cdr e))))))
    (process-put conn :curl curl)
    (ignore-errors (process-send-string curl config) (process-send-eof curl))))

(defun drgnx-gateway--upstream-bytes (curl conn bytes scan last)
  "CURL's output so far: hold it until the head is whole, then (unless it calls for the next provider) pass the
head and every later byte to CONN.  LAST: no provider is left, so the provider's own refusal (its status, its
retry-after) is the answer."
  (if (process-get curl :started)
      (progn (funcall scan bytes) (when (process-live-p conn) (drgnx-gateway--write conn bytes)))
    (let ((buf (concat (or (process-get curl :buf) "") bytes)) (go t))
      (while (and go (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)[^\r\n]*\r\n" buf))
        (let ((status (string-to-number (match-string 1 buf))) (end (string-search "\r\n\r\n" buf)))
          (cond
           ((null end) (setq go nil))
           ((< status 200) (setq buf (substring buf (+ end 4))))   ; 100 Continue: the real head follows
           (t
            (setq go nil)
            (process-put curl :status status)
            (if (and (not last) (or (>= status 500) (memq status drgnx-gateway--retry-statuses)))
                (progn (process-put curl :retry t) (delete-process curl))
              (let* ((head (substring buf 0 end)) (rest (substring buf (+ end 4)))
                     (ctype (and (string-match "^[Cc]ontent-[Tt]ype: *\\([^\r\n]+\\)" head) (match-string 1 head)))
                     (retry-after (and (string-match "^[Rr]etry-[Aa]fter: *\\([^\r\n]+\\)" head) (match-string 1 head))))
                (process-put curl :started t)
                (when (process-live-p conn)
                  (drgnx-gateway--write conn (format "HTTP/1.1 %d OK\r\nContent-Type: %s\r\n%sConnection: close\r\n\r\n"
                                                     status (drgnx-gateway--clean (or ctype "application/json"))
                                                     (if retry-after (format "Retry-After: %s\r\n" (drgnx-gateway--clean retry-after)) "")))
                  (unless (string-empty-p rest) (funcall scan rest) (drgnx-gateway--write conn rest))))
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
    (with-demoted-errors "drgnx gateway: spend not recorded: %S" (apply #'drgnx-work-db-add-spend row))
    (apply #'drgnx-gateway--emit 'request row)
    ;; the request that spends the budget ends the job's work now, not at the next refusal
    (when-let* ((budget (plist-get reg :budget)) (job (plist-get reg :job))
                (spent (ignore-errors (plist-get (drgnx-work-db-spend :job job) :cost)))
                ((>= spent budget)))
      (drgnx-gateway--emit 'budget :job job :spent spent :budget budget))))

(provide 'drgnx-gateway)
;;; drgnx-gateway.el ends here
