;;; gateway-test.el --- batch tests: the agent traffic gateway -*- lexical-binding: t -*-
;; The gateway runs in the test's Emacs; mock providers (test/fixtures/mock-llm.el) stand in for OpenRouter and
;; Ollama; the test's client is an asynchronous network connection.
(require 'ert)
(require 'drgnx-gateway)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defconst drgnx-gw-test--sse
  (concat "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\n"
          "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"
          "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n"))

(defmacro drgnx-gw-test--with (or-script ol-script &rest body)
  "BODY with the gateway on PORT, mock OpenRouter (OR-SCRIPT, log OR-LOG) and Ollama (OL-SCRIPT, log OL-LOG) as the
`openrouter' and `ollama' providers, OPENROUTER_API_KEY=sk-or-test, the data and state dirs in ROOT, EVENTS what
the gateway told."
  (declare (indent 2))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-gw" t)))
          (or-port nil) (ol-port nil)
          (or-log (concat root "or.log")) (ol-log (concat root "ol.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "OPENROUTER_API_KEY=sk-or-test")
                                       process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil)
          (drgnx-ai-providers nil) (drgnx-ai-roles nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-work-db--handles nil) (events nil) (mocks nil) (port nil)
          (drgnx-gateway-event-functions (list (lambda (e d) (push (cons e d) events)))))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file (concat root "or.eld") (prin1 ,or-script (current-buffer)))
           (with-temp-file (concat root "ol.eld") (prin1 ,ol-script (current-buffer)))
           (push (drgnx-ai-test-mock-llm nil (concat root "or.eld") or-log) mocks)
           (push (drgnx-ai-test-mock-llm nil (concat root "ol.eld") ol-log) mocks)
           (setq or-port (process-get (cadr mocks) :port) ol-port (process-get (car mocks) :port))
           (setq drgnx-ai-providers `((openrouter :name "OpenRouter" :kind openai :url ,(format "http://127.0.0.1:%d/api/v1" or-port)
                                                  :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t :price (3.0 . 15.0))
                                      (ollama :name "Ollama" :kind ollama :url ,(format "http://127.0.0.1:%d" ol-port) :caps (chat) :messages t)))
           (setq port (drgnx-gateway-start))
           ,@body)
       (drgnx-gateway-stop)
       (mapc #'delete-process mocks)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(cl-defun drgnx-gw-test--request (port &key token (body "{\"model\":\"claude-x\",\"stream\":true}") (path "/v1/messages")
                                       hang-up-after (wait 8) extra)
  "Send a request to the gateway; (:status N :head S :body S :first SECS :first-body S :closed BOOL) once it closed (or WAIT s).
FIRST-BODY is the body as it was when the first of it arrived."
  (let* ((got "") (first nil) (first-body nil) (t0 (float-time)) (closed nil)
         (c (if (stringp port)          ; a socket path: the per-session Unix socket
                (make-network-process :name "gw-test" :family 'local :service port :coding 'binary :noquery t)
              (open-network-stream "gw-test" nil "127.0.0.1" port :coding 'binary)))
         (bytes (if (multibyte-string-p body) (encode-coding-string body 'utf-8) body)))
    (set-process-sentinel c (lambda (_p _e) (setq closed t)))
    (set-process-filter c (lambda (p s)
                            (setq got (concat got s))
                            (when (and (not first) (string-search "\r\n\r\n" got)
                                       (> (length got) (+ 4 (string-search "\r\n\r\n" got))))
                              (setq first (- (float-time) t0)
                                    first-body (substring got (+ 4 (string-search "\r\n\r\n" got)))))
                            (when (and hang-up-after first) (delete-process p) (setq closed t))))
    (process-send-string c (concat (format "POST %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" path)
                                   (if token (format "Authorization: Bearer %s\r\n" token) "")
                                   (or extra "")
                                   (format "Content-Length: %d\r\n\r\n" (length bytes))
                                   bytes))
    (let ((deadline (+ (float-time) wait))) (while (and (not closed) (< (float-time) deadline)) (accept-process-output nil 0.01)))
    (let ((h (string-search "\r\n\r\n" got)))
      (list :status (and (string-match "\\`HTTP/1\\.[01] \\([0-9]+\\)" got) (string-to-number (match-string 1 got)))
            :head (and h (substring got 0 h)) :body (and h (substring got (+ h 4))) :first first :first-body first-body :closed closed))))

(defun drgnx-gw-test--log (file) (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defun drgnx-gw-test--settle (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the gateway's condition"))

(ert-deftest drgnx-gateway/a-closed-connection-goes-50-ms-later-and-its-timer-goes-with-it ()
  (let ((conn (make-pipe-process :name "drgnx-gw-test" :noquery t))
        (other (make-pipe-process :name "drgnx-gw-test2" :noquery t)))
    (unwind-protect
        (drgnx-test-with-clock ()
          (drgnx-gateway--close conn)
          (drgnx-gateway--close other)
          (should (drgnx-timer-active-p (cons 'gateway-close conn)))
          (should (process-live-p conn))                              ; what was sent goes first
          (delete-process other)                                      ; it hung up by itself: its timer finds it gone
          (drgnx-test-advance 0.05)
          (should-not (drgnx-timer-active-p (cons 'gateway-close other)))
          (should-not (process-live-p conn))
          (should-not (drgnx-timer-active-p (cons 'gateway-close conn))))
      (ignore-errors (delete-process conn))
      (ignore-errors (delete-process other)))))

(ert-deftest drgnx-gateway/no-token-no-service ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (should (= (plist-get (drgnx-gw-test--request port) :status) 401))
    (should (= (plist-get (drgnx-gw-test--request port :token "not-registered") :status) 401))
    (should (equal (drgnx-gw-test--log or-log) ""))))

(ert-deftest drgnx-gateway/a-stream-passes-through-with-the-real-key ()
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let* ((token (drgnx-gateway-register '(:job "j" :task "t1" :agent "a1" :chain ((openrouter . "m1")))))
           (r (drgnx-gw-test--request port :token token)))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" token))
      (should (= (plist-get r :status) 200))
      (should (string-match-p "^Content-Type: text/event-stream" (plist-get r :head)))
      (should (equal (plist-get r :body) drgnx-gw-test--sse))
      (let ((sent (drgnx-gw-test--log or-log)))
        (should (string-search "Authorization: Bearer sk-or-test" sent))
        (should (string-search "\"model\":\"m1\"" sent))
        (should-not (string-search token sent))))))

(ert-deftest drgnx-gateway/no-key-in-curl-s-command-line ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :chunks ((0 . "data: {}\n\n") (1 . "data: {}\n\n")))) '()
    (let ((token (drgnx-gateway-register '(:chain ((openrouter . nil))))) (seen nil))
      (let ((c (open-network-stream "gw-test" nil "127.0.0.1" port :coding 'binary)))
        (process-send-string c (format "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\n\r\n{}" token))
        (drgnx-gw-test--settle (lambda () (setq seen (seq-find (lambda (p) (string-prefix-p "drgnx-gw-curl" (process-name p))) (process-list)))))
        (should seen)
        (should-not (seq-find (lambda (a) (string-search "sk-or" a)) (process-command seen)))
        (delete-process c)))))

(ert-deftest drgnx-gateway/the-first-chunk-goes-on-without-waiting-for-the-rest ()
  ;; The gateway streams: the client has the first chunk while the provider's second (0.3 s later) is not sent yet,
  ;; as it has it straight from the provider.
  (drgnx-gw-test--with '((:path "/api/v1/messages" :chunks ((0 . "data: {\"x\":1}\n\n") (0.3 . "data: {}\n\n")))) '()
    (let ((token (drgnx-gateway-register '(:chain ((openrouter . nil))))))
      (should (equal (plist-get (drgnx-gw-test--request or-port :path "/api/v1/messages") :first-body) "data: {\"x\":1}\n\n"))
      (let ((r (drgnx-gw-test--request port :token token)))
        (should (equal (plist-get r :first-body) "data: {\"x\":1}\n\n"))
        (should (equal (plist-get r :body) "data: {\"x\":1}\n\ndata: {}\n\n"))))))

(ert-deftest drgnx-gateway/spend-is-recorded-per-agent-and-task ()
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let ((token (drgnx-gateway-register '(:job "j" :task "t1" :agent "a1" :chain ((openrouter . "m1"))))))
      (drgnx-gw-test--request port :token token)
      (should (drgnx-gw-test--settle (lambda () (assq 'request events))))
      (let ((s (drgnx-work-db-spend :task "t1")))
        (should (equal (list (plist-get s :input) (plist-get s :output) (plist-get s :requests)) '(12 7 1)))
        (should (< (abs (- (plist-get s :cost) (+ (* 12 3e-6) (* 7 15e-6)))) 1e-9)))
      (should (equal (plist-get (cdr (assq 'request events)) :agent) "a1")))))

(ert-deftest drgnx-gateway/a-rate-limit-moves-to-the-next-provider ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :status 429 :body "{\"error\":\"slow down\"}"))
      '((:path "/v1/messages" :body "{\"content\":\"from ollama\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"))
    (let* ((token (drgnx-gateway-register '(:agent "a1" :chain ((openrouter . "m1") (ollama . "q")))))
           (r (drgnx-gw-test--request port :token token :body "{\"model\":\"claude-x\"}")))
      (should (= (plist-get r :status) 200))
      (should (string-search "from ollama" (plist-get r :body)))
      (should (string-search "\"model\":\"q\"" (drgnx-gw-test--log ol-log)))
      (should (equal (plist-get (cdr (assq 'fallback events)) :why) "HTTP 429")))))

(ert-deftest drgnx-gateway/last-provider-429-passed-through-with-retry-after ()
  ;; the last provider's own refusal is the answer: its status, its retry-after and its body, not a 502
  (drgnx-gw-test--with '((:path "/api/v1/messages" :status 429 :headers (("Retry-After" . "17")) :body "{\"error\":\"slow down\"}")) '()
    (let* ((token (drgnx-gateway-register '(:agent "a1" :chain ((openrouter . "m1")))))
           (r (drgnx-gw-test--request port :token token)))
      (should (= (plist-get r :status) 429))
      (should (string-match-p "^Retry-After: 17\r?$" (plist-get r :head)))
      (should (string-search "slow down" (plist-get r :body)))
      (should-not (assq 'fallback events))
      (should (drgnx-gw-test--settle (lambda () (assq 'request events))))
      (should (= (plist-get (cdr (assq 'request events)) :status) 429)))
    ;; earlier ones still pass the agent on to the next provider
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil) (lmstudio . nil)))))
           (r (drgnx-gw-test--request port :token token)))
      (should (= (plist-get r :status) 502)))))

(ert-deftest drgnx-gateway/a-dead-or-failing-provider-moves-on-too ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :status 503 :body "{}"))
      '((:path "/v1/messages" :body "{\"ok\":1}"))
    (let ((token (drgnx-gateway-register '(:chain ((openrouter . nil) (ollama . nil))))))
      (should (= (plist-get (drgnx-gw-test--request port :token token) :status) 200))
      (should (equal (plist-get (cdr (assq 'fallback events)) :why) "HTTP 503"))
      ;; nothing listening
      (setq drgnx-ai-providers `((openrouter :kind openai :url "http://127.0.0.1:9/api/v1" :key-env "OPENROUTER_API_KEY" :messages t)
                                 (ollama :kind ollama :url ,(format "http://127.0.0.1:%d" ol-port) :messages t)))
      (setq events nil)
      (should (= (plist-get (drgnx-gw-test--request port :token token) :status) 200))
      (should (equal (plist-get (cdr (assq 'fallback events)) :why) "no answer")))))

(ert-deftest drgnx-gateway/when-every-provider-fails-the-agent-hears-why ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :status 429 :body "{}")) '()
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil) (lmstudio . nil)))))
           (r (drgnx-gw-test--request port :token token)))
      (should (= (plist-get r :status) 502))
      (should (string-search "HTTP 429" (plist-get r :body)))
      (should (string-search "the gateway cannot carry it" (plist-get r :body))))))

(ert-deftest drgnx-gateway/no-fallback-once-the-answer-started ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :chunks ((0 . "data: {\"a\":1}\n\n")) :no-end t))
      '((:path "/v1/messages" :body "{}"))
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil) (ollama . nil)))))
           (r (drgnx-gw-test--request port :token token)))
      (should (= (plist-get r :status) 200))
      (should (equal (plist-get r :body) "data: {\"a\":1}\n\n"))
      (should (plist-get r :closed))
      (should (equal (drgnx-gw-test--log ol-log) "")))))

(ert-deftest drgnx-gateway/the-budget-stops-new-requests ()
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let ((token (drgnx-gateway-register '(:job "j" :chain ((openrouter . nil)) :budget 0.0001)))
          (other (drgnx-gateway-register '(:job "k" :chain ((openrouter . nil)) :budget 1.0))))
      (should (= (plist-get (drgnx-gw-test--request port :token token) :status) 200))   ; 0.000141 spent
      (drgnx-gw-test--settle (lambda () (assq 'request events)))
      (let ((r (drgnx-gw-test--request port :token token)))
        (should (= (plist-get r :status) 429))
        (should (string-search "budget_exceeded" (plist-get r :body))))
      (should (equal (plist-get (cdr (assq 'budget events)) :job) "j"))
      (should (= (plist-get (drgnx-gw-test--request port :token other) :status) 200)))))

(ert-deftest drgnx-gateway/budget-event-fires-when-spend-crosses-the-budget ()
  ;; the request that spends the budget pauses the job at once, not when the next request is refused
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let ((token (drgnx-gateway-register '(:job "j" :chain ((openrouter . nil)) :budget 0.0001)))
          (other (drgnx-gateway-register '(:job "k" :chain ((openrouter . nil)) :budget 1.0))))
      (drgnx-gw-test--request port :token other)
      (drgnx-gw-test--settle (lambda () (assq 'request events)))
      (should-not (assq 'budget events))                  ; spent less than its budget
      (should (= (plist-get (drgnx-gw-test--request port :token token) :status) 200))   ; 0.000141 spent
      (should (drgnx-gw-test--settle (lambda () (assq 'budget events))))
      (let ((e (cdr (assq 'budget events))))
        (should (equal (plist-get e :job) "j"))
        (should (< (abs (- (plist-get e :spent) (+ (* 12 3e-6) (* 7 15e-6)))) 1e-9))
        (should (= (plist-get e :budget) 0.0001))))))

(ert-deftest drgnx-gateway/a-client-that-hangs-up-stops-the-upstream ()
  ;; the upstream's last chunk comes long after any wait below: only the hang-up can end curl while the test waits
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse) (1 . "data: {}\n\n") (600 . "data: {}\n\n")))) '()
    (let ((token (drgnx-gateway-register '(:task "t9" :chain ((openrouter . nil))))))
      (drgnx-gw-test--request port :token token :hang-up-after t)
      (should (drgnx-gw-test--settle (lambda () (not (seq-find (lambda (p) (string-prefix-p "drgnx-gw-curl" (process-name p))) (process-list)))) 1.5))
      (should (drgnx-gw-test--settle (lambda () (= (plist-get (drgnx-work-db-spend :task "t9") :requests) 1))))
      (should (= (plist-get (drgnx-work-db-spend :task "t9") :input) 12))
      (should-not (seq-find (lambda (b) (string-prefix-p " *drgnx-gw" (buffer-name b))) (buffer-list))))))

(ert-deftest drgnx-gateway/a-large-body-is-byte-exact ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil)))))
           (text (concat "{\"messages\":\"" (apply #'concat (make-list 40000 "é—𝄞 tab\t \\\" ")) "\"}"))
           (r (drgnx-gw-test--request port :token token :body text :wait 15)))
      (should (= (plist-get r :status) 200))
      (should (string-search text (drgnx-gw-test--log or-log))))))

(ert-deftest drgnx-gateway/only-the-messages-api-paths-reach-a-provider ()
  ;; a path that would change the provider's host (".evil/…", "@evil/…") must never carry the key anywhere
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let ((token (drgnx-gateway-register '(:chain ((openrouter . nil))))))
      (dolist (path '(".attacker.example/v1/messages" "@attacker.example/v1/messages" "/v1/../x" "/v2/messages"
                      "/v1/messages/../../admin" "//attacker.example/v1/messages" "/v1/models/../messages"
                      "/v1/messages?a=\001b" "/v1/messages?a=\177"))
        (should (memq (plist-get (drgnx-gw-test--request port :token token :path path) :status) '(400 404))))
      (should (equal (drgnx-gw-test--log or-log) ""))
      (dolist (path '("/v1/messages" "/v1/messages?beta=true" "/v1/messages/count_tokens"))
        (should (= (plist-get (drgnx-gw-test--request port :token token :path path) :status) 200))))))

(ert-deftest drgnx-gateway/a-body-over-curl-s-config-limit-passes ()
  ;; curl refuses a config line over ~10 MB: the body goes in a private file instead
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil)))))
           (text (concat "{\"x\":\"" (make-string (* 12 1024 1024) ?a) "\"}"))
           (r (drgnx-gw-test--request port :token token :body text :wait 30)))
      (should (= (plist-get r :status) 200))
      (should (> (file-attribute-size (file-attributes or-log)) (* 12 1024 1024)))
      (should-not (directory-files (drgnx-gateway--body-dir) nil "\\`[^.]")))))      ; the body file is gone

(ert-deftest drgnx-gateway/an-error-on-the-way-answers-and-closes ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let ((token (drgnx-gateway-register '(:job "j" :chain ((openrouter . nil)) :budget 1.0))))
      (cl-letf (((symbol-function 'drgnx-work-db-spend) (lambda (&rest _) (error "database is locked"))))
        (let ((r (drgnx-gw-test--request port :token token :wait 3)))
          (should (= (plist-get r :status) 500))
          (should (string-search "api_error" (plist-get r :body)))
          (should (plist-get r :closed)))))))

(ert-deftest drgnx-gateway/a-key-from-the-socket-wins-and-is-never-written ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let ((token (drgnx-gateway-register '(:job "j" :chain ((openrouter . nil))))))
      (drgnx-gateway-set-key 'openrouter "sk-mem-only")
      (drgnx-gw-test--request port :token token)
      (should (string-search "Bearer sk-mem-only" (drgnx-gw-test--log or-log)))
      (drgnx-work-db-close-all)
      (dolist (f (directory-files-recursively root "" nil))
        (unless (member (file-name-nondirectory f) '("or.log"))
          (should-not (string-search "sk-mem-only" (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally f) (buffer-string)))))))))

(ert-deftest drgnx-gateway/bad-token-refused-before-body ()
  ;; the head says 5 MB follow; the token is wrong: the answer comes at once, not after (or without) the body
  (drgnx-gw-test--with '((:path "/api/v1/messages" :body "{}")) '()
    (let* ((got "") (c (open-network-stream "gw-test" nil "127.0.0.1" port :coding 'binary)))
      (set-process-filter c (lambda (_p s) (setq got (concat got s))))
      (process-send-string c "POST /v1/messages HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer nope\r\nContent-Length: 5000000\r\n\r\n{")
      (should (drgnx-gw-test--settle (lambda () (string-prefix-p "HTTP/1.1 401" got)) 3))
      (delete-process c))
    (should (equal (drgnx-gw-test--log or-log) ""))
    ;; a good token still waits for its whole body, which may come in pieces
    (let* ((token (drgnx-gateway-register '(:chain ((openrouter . nil)))))
           (got "") (c (open-network-stream "gw-test" nil "127.0.0.1" port :coding 'binary)))
      (set-process-filter c (lambda (_p s) (setq got (concat got s))))
      (process-send-string c (format "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 10\r\n\r\n01234" token))
      (drgnx-test-pause 0.3)                                   ; half a body is not an answer
      (should (equal got ""))
      (process-send-string c "56789")
      (should (drgnx-gw-test--settle (lambda () (string-prefix-p "HTTP/1.1 200" got)) 5))
      (should (string-search "0123456789" (drgnx-gw-test--log or-log)))
      (delete-process c))))

(defun drgnx-gw-test--fake-curl (root)
  "A `curl' that only keeps its stdin (the config) in ROOT/curl.config; the directory to put first on `exec-path'."
  (let ((dir (concat root "fakebin/")) (file (concat root "fakebin/curl")))
    (make-directory dir t)
    (with-temp-file file (insert "#!/bin/sh\ncat > \"" root "curl.config\"\n"))
    (set-file-modes file #o755)
    dir))

(defun drgnx-gw-test--config (root)
  "What the gateway gave the fake curl, once it came."
  (let ((file (concat root "curl.config")))
    (drgnx-gw-test--settle (lambda () (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 0))))
    (drgnx-gw-test--log file)))

(ert-deftest drgnx-gateway/config-suppresses-proxy-connect-head ()
  ;; behind an https proxy curl's `include' would also print the proxy's CONNECT head: the gateway would take it for
  ;; the provider's answer
  (drgnx-gw-test--with '() '()
    (let ((exec-path (cons (drgnx-gw-test--fake-curl root) exec-path))
          (token (drgnx-gateway-register '(:chain ((openrouter . nil))))))
      (drgnx-gw-test--request port :token token :wait 1)
      (should (string-match-p "^suppress-connect-headers$" (drgnx-gw-test--config root))))))

(ert-deftest drgnx-gateway/header-control-chars-stripped ()
  ;; a CR or other control character in a forwarded header must not reach curl's config (its \r escape would end
  ;; the header line upstream and let the agent add headers)
  (drgnx-gw-test--with '() '()
    (let ((exec-path (cons (drgnx-gw-test--fake-curl root) exec-path))
          (token (drgnx-gateway-register '(:chain ((openrouter . nil))))))
      (drgnx-gw-test--request port :token token :wait 1
                              :extra "Accept: a\rX-Evil: 1\001b\177c\td\r\n")
      (let ((config (drgnx-gw-test--config root)))
        (should (string-match-p "^header = \"accept: aX-Evil: 1bcd\"$" config))
        (should-not (string-match-p "[\000-\011\013-\037\177]" config))))))

;;;; The per-session Unix socket

(defun drgnx-gw-test--sock (root) (concat root "gw.sock"))

(ert-deftest drgnx-gateway-socket/token-checked ()
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let ((sock (drgnx-gw-test--sock root)) (token (drgnx-gateway-register '(:chain ((openrouter . "m1"))))))
      (drgnx-gateway-listen-socket sock)
      (should (= (plist-get (drgnx-gw-test--request sock) :status) 401))
      (should (= (plist-get (drgnx-gw-test--request sock :token "not-a-token") :status) 401))
      (should-not (string-search "sk-or-test" (drgnx-gw-test--log or-log)))
      (let ((r (drgnx-gw-test--request sock :token token)))
        (should (= (plist-get r :status) 200))
        (should (equal (plist-get r :body) drgnx-gw-test--sse)))
      ;; an unregistered token stops working at once
      (drgnx-gateway-unregister token)
      (should (= (plist-get (drgnx-gw-test--request sock :token token) :status) 401))
      ;; and the socket is private
      (should (= (logand #o777 (file-modes sock)) #o600)))))

(ert-deftest drgnx-gateway-socket/path-allowlist-applies ()
  (drgnx-gw-test--with '() '()
    (let ((sock (drgnx-gw-test--sock root)) (token (drgnx-gateway-register '(:chain ((openrouter . nil))))))
      (drgnx-gateway-listen-socket sock)
      (dolist (path '("/v1/chat/completions" "/v1/messages/../../etc" "/admin"))
        (should (= (plist-get (drgnx-gw-test--request sock :token token :path path) :status) 404)))
      (should-not (string-search "sk-or-test" (drgnx-gw-test--log or-log))))))

(ert-deftest drgnx-gateway-socket/same-answers-as-tcp ()
  (drgnx-gw-test--with `((:path "/api/v1/messages" :chunks ((0 . ,drgnx-gw-test--sse)))) '()
    (let ((sock (drgnx-gw-test--sock root)) (token (drgnx-gateway-register '(:chain ((openrouter . "m1"))))))
      (drgnx-gateway-listen-socket sock)
      (dolist (args `((:token ,token) (:token "bad") nil (:token ,token :path "/nope")))
        (let ((tcp (apply #'drgnx-gw-test--request port args)) (unix (apply #'drgnx-gw-test--request sock args)))
          (should (equal (plist-get tcp :status) (plist-get unix :status)))
          (should (equal (plist-get tcp :body) (plist-get unix :body))))))))

(ert-deftest drgnx-gateway-socket/closed-with-the-session ()
  (drgnx-gw-test--with '((:path "/api/v1/messages" :chunks ((0 . "data: {}\n\n") (5 . "data: {}\n\n")))) '()
    (let* ((sock (drgnx-gw-test--sock root)) (other (concat root "gw2.sock"))
           (token (drgnx-gateway-register '(:chain ((openrouter . "m1"))))) (closed nil))
      (drgnx-gateway-listen-socket sock)
      (drgnx-gateway-listen-socket other)
      ;; a request in flight when the session ends is cut
      (let ((c (make-network-process :name "gw-test" :family 'local :service sock :coding 'binary :noquery t
                                     :sentinel (lambda (_p _e) (setq closed t)))))
        (process-send-string c (format "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\n\r\n{}" token))
        (drgnx-gw-test--settle (lambda () (seq-find (lambda (p) (string-prefix-p "drgnx-gw-curl" (process-name p))) (process-list))))
        (drgnx-gateway-close-socket sock)
        (should (drgnx-gw-test--settle (lambda () closed)))
        (should-not (seq-find (lambda (p) (string-prefix-p "drgnx-gw-curl" (process-name p))) (process-list))))
      (should-not (file-exists-p sock))
      (should-error (make-network-process :name "gw-test" :family 'local :service sock :noquery t))
      ;; closing a socket twice is harmless; the other session's socket is untouched
      (drgnx-gateway-close-socket sock)
      (should (= (plist-get (drgnx-gw-test--request other :token "bad") :status) 401))
      ;; stopping the gateway closes what is left
      (drgnx-gateway-stop)
      (should-not (file-exists-p other)))))

;;; gateway-test.el ends here
