;;; ai-gateway-test.el --- batch tests: the editor's AI goes through the hub's gateway with the editor token -*- lexical-binding: t -*-
;; Binary tests: the real Ratatoskr hub and its gateway (DRGNX_RATATOSKR_BIN) between the editor and `ratatoskr-mock llm',
;; which is the only stand-in here, for the outside provider.  The mock's log says what reached it (path, the key the
;; hub added); the editor's own side is recorded at `drgnx-ai--curl' (which address and which bearer token it sent).
;; Without the binary (or the mock beside it) these skip; test/no-skip.eld lists them.
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx)
(require 'drgnx-ai-client)
(require 'drgnx-ai-probe)
(require 'drgnx-hub-client)
(require 'drgnx-search-index)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-commit-message" drgnx-dir) nil t)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)
(declare-function gptel-request "gptel")

(unless (fboundp 'git-commit-mode)                         ; magit's commit buffer, when magit is not here
  (define-minor-mode git-commit-mode "A stand-in for magit's commit message mode."))

(defconst drgnx-ai-gateway-test--key "sk-gateway-test-key" "The key the hub holds for provider a (from the editor's A_KEY).")

(defun drgnx-ai-gateway-test--bin ()
  "Ratatoskr, when DRGNX_RATATOSKR_BIN is an absolute executable with `ratatoskr-mock' beside it, else nil."
  (let ((b (getenv "DRGNX_RATATOSKR_BIN")))
    (and b (file-name-absolute-p b) (file-executable-p b) (not (file-directory-p b))
         (file-executable-p (expand-file-name "ratatoskr-mock" (file-name-directory b)))
         b)))

(defun drgnx-ai-gateway-test--start-mock (root script)
  "Start `ratatoskr-mock llm' with SCRIPT (a list of answers, plists) logging to ROOT/mock.jsonl: the process, its :port set."
  (let* ((bin (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-ai-gateway-test--bin))))
         (file (concat root "mock.json")) (out "")
         (p (progn
              (with-temp-file file (insert (json-serialize (vconcat script))))
              (make-process :name "ratatoskr-mock" :noquery t :buffer nil :connection-type 'pipe
                            :filter (lambda (_p s) (setq out (concat out s)))
                            :command (list bin "llm" "--script" file "--log" (concat root "mock.jsonl")
                                           "--parent" (number-to-string (emacs-pid))))))
         (deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline) (process-live-p p) (not (string-match "MOCK-LLM-PORT \\([0-9]+\\)" out)))
      (accept-process-output p 0.05))
    (unless (string-match "MOCK-LLM-PORT \\([0-9]+\\)" out) (error "ratatoskr-mock did not start: %s" out))
    (process-put p :port (string-to-number (match-string 1 out)))
    p))

(defun drgnx-ai-gateway-test--requests (root)
  "What reached the mock, oldest first: plists (:method :path :headers :body)."
  (let ((f (concat root "mock.jsonl")))
    (when (file-exists-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (delq nil (mapcar (lambda (l) (plist-get (json-parse-string l :object-type 'plist :null-object nil :false-object nil) :request))
                          (split-string (buffer-string) "\n" t)))))))

(defun drgnx-ai-gateway-test--header (req name)
  (plist-get (plist-get req :headers) (intern (concat ":" name))))

(defvar drgnx-ai-gateway-test--sent nil "The editor's requests, newest first: (URL KEY) as `drgnx-ai--curl' got them.")

(defun drgnx-ai-gateway-test--record (fn url callback &rest args)
  (push (list url (plist-get args :key)) drgnx-ai-gateway-test--sent)
  (apply fn url callback args))

(defmacro drgnx-ai-gateway-test--with (script &rest body)
  "BODY with the real hub serving ROOT, `ratatoskr-mock llm' answering SCRIPT as the provider on PORT (providers `a'
\(openai, key in A_KEY, chat fim embed), `b' (openai, key B_KEY, none set) and `o' (ollama, keyless) point at it in
`drgnx-ai-providers', here and in settings.el for the hub),
this Emacs connected: it holds the editor token and the hub holds a's key.  Skipped without the binary."
  (declare (indent 1))
  `(let* ((bin (or (drgnx-ai-gateway-test--bin) (ert-skip "DRGNX_RATATOSKR_BIN (with ratatoskr-mock beside it) is not set")))
          (root (file-name-as-directory (make-temp-file "drgnx-ai-gw" t)))
          (mock nil) (port nil) (hub nil)
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" root "xdg-config")
                                             (concat "XDG_CACHE_HOME=" root "cache") (concat "HOME=" root "home")
                                             (concat "DRGNX_RATATOSKR_BIN=" bin) "DRGNX_JOBS_LAUNCHER=detached"
                                             (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)) "RATATOSKR_SUPERVISOR=none"
                                             (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory))
                                             (concat "A_KEY=" drgnx-ai-gateway-test--key) "B_KEY" "OPENROUTER_API_KEY"
                                             "DRGNX_AI_GATEWAY_URL" "DRGNX_NO_HUB_START"
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                                       process-environment))
          (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-ai-detected nil)
          (drgnx-ai-providers nil) (drgnx-ai-roles nil)
          (drgnx-ai-gateway-test--sent nil)
          (drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil)
          (drgnx-hub--pending (make-hash-table)) (drgnx-hub--last-hello nil) (drgnx-hub-client-proves t)
          (drgnx-hub--ensuring nil) (drgnx-hub--binary-version nil) (drgnx-hub--binary-reading nil)
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-hub-skew-functions nil)
          (drgnx-hub--editor nil) (drgnx-hub--keys-held :unknown) (drgnx-hub--keys-had nil))
     (dolist (d '("run" "home" "config" "data")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect
         (progn
           (setq mock (drgnx-ai-gateway-test--start-mock root ,script) port (process-get mock :port))
           (setq drgnx-ai-providers `((a :name "A" :kind openai :url ,(format "http://127.0.0.1:%d/v1" port) :key-env "A_KEY"
                                         :caps (chat fim embed))
                                      (b :name "B" :kind openai :url ,(format "http://127.0.0.1:%d/b" port) :key-env "B_KEY"
                                         :caps (chat))
                                      (o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat)))
                 drgnx-ai-roles '((chat (a . "m")) (embed (a . "e"))))
           (drgnx-test-write-settings (concat root "config/settings.el")
                                      'drgnx-ai-providers drgnx-ai-providers 'drgnx-ai-roles drgnx-ai-roles)
           (setq hub (make-process :name "ratatoskr" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *ratatoskr*")
                                   :sentinel (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                                   :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid)))))
           (drgnx-test-wait #'drgnx-hub-running-p :secs 30 :what "Ratatoskr answers a ping")
           (drgnx-hub-connect)
           (should (drgnx-hub-ensure))                         ; the table and the key, waited for
           (drgnx-test-wait (lambda () (and drgnx-hub--editor (listp (drgnx-hub-keys-held)) (member "a" (drgnx-hub-keys-held))))
                            :secs 30 :what "the editor token and the held keys")
           ;; the ensure's hand-over went on the call connection; the event connection subscribes on its own and hands
           ;; over again when it is done.  Events sent before that are missed, and that second keys-held answer would
           ;; overwrite what the body changes: the body starts when the subscription is in and nothing is pending
           (drgnx-test-wait (lambda () (and (process-live-p drgnx-hub--events) (zerop (hash-table-count drgnx-hub--pending))))
                            :secs 30 :what "the event connection subscribed and the hand-over answered")
           (advice-add 'drgnx-ai--curl :around #'drgnx-ai-gateway-test--record)
           ,@body)
       (advice-remove 'drgnx-ai--curl #'drgnx-ai-gateway-test--record)
       (drgnx-hub-disconnect)
       (when (process-live-p hub) (signal-process hub 'term))
       (when hub (ignore-errors (drgnx-test-wait (lambda () (process-get hub :done)) :secs 10 :what "Ratatoskr ends")))
       (when (process-live-p hub) (signal-process hub 'kill))
       (when (and hub (buffer-live-p (process-buffer hub))) (kill-buffer (process-buffer hub)))
       (when mock (delete-process mock))
       (delete-directory root t))))

(defun drgnx-ai-gateway-test--ask (kind payload &optional chain &rest keys)
  "Run a KIND request along CHAIN (a's step) and wait: (TEXT . INFO).  KEYS go to `drgnx-ai-request'."
  (let (result)
    (apply #'drgnx-ai-request 'chat kind payload (lambda (text info) (setq result (cons text info)))
           :chain (or chain '((a . "m"))) :timeout 10 keys)
    (let ((deadline (+ (float-time) 20)))
      (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.02)))
    result))

(defun drgnx-ai-gateway-test--through (root path)
  "What the editor and the mock saw for PATH (the upstream path): the editor asked the gateway at /p/a/… with its token and
no provider key; the mock got the hub's key and never the editor's token."
  (let* ((editor (car (last drgnx-ai-gateway-test--sent)))
         (reqs (drgnx-ai-gateway-test--requests root))
         (req (seq-find (lambda (r) (equal (plist-get r :path) path)) reqs))
         (token (car drgnx-hub--editor)))
    (should (string-prefix-p (concat (cdr drgnx-hub--editor) "/p/a/") (car editor)))   ; the gateway, not the provider
    (should (equal (cadr editor) token))                                               ; the editor token toward the gateway
    (should-not (seq-find (lambda (s) (equal (cadr s) drgnx-ai-gateway-test--key)) drgnx-ai-gateway-test--sent))
    (should req)                                                                       ; the mock saw the upstream path
    (should (equal (drgnx-ai-gateway-test--header req "authorization") (concat "Bearer " drgnx-ai-gateway-test--key)))
    (should-not (string-search token (prin1-to-string reqs)))                          ; the editor's token ends at the gateway
    req))

(defconst drgnx-ai-gateway-test--chat
  '((:path "/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}")))

(ert-deftest drgnx-ai-gateway/chat-goes-through-the-gateway ()
  (drgnx-ai-gateway-test--with drgnx-ai-gateway-test--chat
    (let ((r (drgnx-ai-gateway-test--ask 'chat '(:messages [(:role "user" :content "x")]))))
      (should (equal (car r) "hi"))
      (should (eq (plist-get (cdr r) :provider) 'a))
      (drgnx-ai-gateway-test--through root "/v1/chat/completions"))))

(ert-deftest drgnx-ai-gateway/fim-goes-through-the-gateway ()
  (drgnx-ai-gateway-test--with '((:path "/v1/completions" :body "{\"choices\":[{\"text\":\"middle\"}]}"))
    (should (equal (car (drgnx-ai-gateway-test--ask 'fim '(:prefix "a" :suffix "b"))) "middle"))
    (drgnx-ai-gateway-test--through root "/v1/completions")))

(ert-deftest drgnx-ai-gateway/embed-goes-through-the-gateway ()
  (drgnx-ai-gateway-test--with '((:path "/v1/embeddings" :body "{\"data\":[{\"index\":0,\"embedding\":[3,4]}]}"))
    (let ((v (drgnx-ai-embed-sync (vector "hello") :timeout 10 :chain '((a . "e")))))
      (should (= (length v) 1))
      (should (< (abs (- (aref (aref v 0) 0) 0.6)) 1e-9))          ; the unit vector of (3 4)
      (should (< (abs (- (aref (aref v 0) 1) 0.8)) 1e-9)))
    (drgnx-ai-gateway-test--through root "/v1/embeddings")))

(ert-deftest drgnx-ai-gateway/commit-message-goes-through-the-gateway ()
  (drgnx-ai-gateway-test--with drgnx-ai-gateway-test--chat
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.txt" "one\n")
      (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start the file")
      (drgnx-git-test-write repo "a.txt" "one\ntwo\n")
      (drgnx-git-test repo "add" "-A")
      (with-temp-buffer
        (setq default-directory repo)
        (insert "\n# Please enter the commit message\n")
        (git-commit-mode 1)
        (cl-letf (((symbol-function 'message) #'ignore))
          (drgnx-commit-message-generate)
          (drgnx-test-wait (lambda () (string-prefix-p "hi" (buffer-string))) :secs 20 :what "the message"))
        (should (string-prefix-p "hi" (buffer-string))))
      (should (string-search "+two" (plist-get (drgnx-ai-gateway-test--through root "/v1/chat/completions") :body))))))

(ert-deftest drgnx-ai-gateway/gptel-backend-points-at-the-gateway ()
  ;; the backend's address, protocol, endpoint and key (gptel's request itself is gptel's: the streaming test below)
  (drgnx-ai-gateway-test--with nil
    (let ((spec (drgnx-ai-gptel-spec 'a "m")) (u (url-generic-parse-url (cdr drgnx-hub--editor))))
      (should (eq (car spec) 'gptel-make-openai))
      (should (equal (plist-get (cddr spec) :host) (format "127.0.0.1:%d" (url-portspec u))))
      (should (equal (plist-get (cddr spec) :protocol) "http"))
      (should (equal (plist-get (cddr spec) :endpoint) "/p/a/chat/completions"))
      (should (equal (funcall (plist-get (cddr spec) :key)) (car drgnx-hub--editor))))
    ;; a keyless provider is gptel's direct backend, as before
    (let ((spec (drgnx-ai-gptel-spec 'o "m")))
      (should (eq (car spec) 'gptel-make-ollama))
      (should-not (plist-member (cddr spec) :key)))))

(ert-deftest drgnx-ai-gateway/gptel-streams-through-the-gateway ()
  ;; two chunks a second apart: the first reaches gptel's callback before the second is sent.  gptel comes from the
  ;; user's ELPA, read-only (DRGNX_USER_ELPA, else ~/.config/emacs/elpa), as mod-extras-teardown-test.el loads it
  (let* ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))
         (load-path (append load-path (and (file-directory-p elpa)
                                           (seq-filter #'file-directory-p (directory-files elpa t "\\`[^.]"))))))
    (skip-unless (locate-library "gptel"))
    (require 'gptel)
    (drgnx-ai-gateway-test--with
        (list (list :path "/v1/chat/completions" :content_type "text/event-stream"
                    :chunks (vector (vector 0 "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n")
                                    (vector 1000 "data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n")
                                    (vector 0 "data: [DONE]\n\n"))))
      (let* ((spec (drgnx-ai-gptel-spec 'a "m")) (gptel-backend (apply (car spec) (cdr spec))) (gptel-model 'm)
             (gptel-stream t) (seen nil))
        (gptel-request "hi" :stream t :callback (lambda (resp _info) (when (stringp resp) (push (cons (float-time) resp) seen))))
        (drgnx-test-wait (lambda () (>= (length seen) 2)) :secs 20 :what "both chunks")
        (let ((first (car (last seen))) (second (car (last seen 2))))
          (should (equal (cdr first) "one"))
          (should (>= (- (car second) (car first)) 0.5)))))))

(ert-deftest drgnx-ai-gateway/the-indexer-gets-no-url-and-no-key ()
  ;; no key, no token, and (review m4) no address either: the job's token brings the gateway's current one
  (drgnx-ai-gateway-test--with nil
    (let ((env (drgnx-search-index--job-env)))
      (should-not (seq-find (lambda (e) (string-search (cdr drgnx-hub--editor) e)) env))
      (should-not (seq-find (lambda (e) (string-match-p "_API_KEY=\\|\\`[AB]_KEY=" e)) env))
      (should-not (string-search drgnx-ai-gateway-test--key (prin1-to-string env)))
      (should-not (string-search (car drgnx-hub--editor) (prin1-to-string env))))))

(ert-deftest drgnx-ai-gateway/the-indexer-asks-for-a-token-of-its-own ()
  ;; a batch Emacs as the job is: no key, no token; it ensures the hub and takes a token of its own, and the hub's key
  ;; reaches the mock for it.  Review m4: a stale gateway address in its environment (a port the hub left after a
  ;; restart, which anyone may now hold) is never used — the address is the one that came with the token
  (drgnx-ai-gateway-test--with '((:path "/v1/embeddings" :body "{\"data\":[{\"index\":0,\"embedding\":[3,4]}]}"))
    (let* ((core (file-name-directory (locate-library "drgnx-ai-client")))
           (process-environment (append (list "DRGNX_AI_GATEWAY_URL=http://127.0.0.1:9" "A_KEY")
                                        process-environment))
           (out (with-temp-buffer
                  (list (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                      "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" core "-l" "drgnx-ai-client"
                                      ;; as the indexer's entry does: settings.el's providers and roles are the user's
                                      "-l" "drgnx-settings-defaults" "--eval" "(drgnx-settings-defaults-apply)"
                                      "--eval" "(princ (format \"DIMS %d\" (length (aref (drgnx-ai-embed-sync (vector \"x\") :timeout 10 :chain '((a . \"e\"))) 0))))")
                        (buffer-string)))))
      (should (string-search "DIMS 2" (cadr out)))
      (let ((req (seq-find (lambda (r) (equal (plist-get r :path) "/v1/embeddings")) (drgnx-ai-gateway-test--requests root))))
        (should req)
        (should (equal (drgnx-ai-gateway-test--header req "authorization") (concat "Bearer " drgnx-ai-gateway-test--key))))
      ;; the job's token is its own: this editor's still works
      (let ((v (drgnx-ai-embed-sync (vector "y") :timeout 10 :chain '((a . "e")))))
        (should (= (length v) 1))))))

(ert-deftest drgnx-ai-gateway/a-keyless-provider-goes-direct ()
  (drgnx-ai-gateway-test--with '((:path "/api/chat" :body "{\"message\":{\"content\":\"direct\"}}"))
    (let ((r (drgnx-ai-gateway-test--ask 'chat '(:messages [(:role "user" :content "x")]) '((o . "m")))))
      (should (equal (car r) "direct"))
      (should (equal (cadr (car drgnx-ai-gateway-test--sent)) nil))                 ; no token, no key
      (should-not (string-search "/p/" (car (car drgnx-ai-gateway-test--sent))))
      (let ((req (car (drgnx-ai-gateway-test--requests root))))
        (should (equal (plist-get req :path) "/api/chat"))
        (should-not (drgnx-ai-gateway-test--header req "authorization"))))))

(ert-deftest drgnx-ai-gateway/usable-comes-from-keys-held ()
  (drgnx-ai-gateway-test--with nil
    (should (drgnx-ai-usable-p 'a 'chat))                                ; the hub holds a's key
    (should-not (drgnx-ai-usable-p 'b 'chat))                            ; …and none for b
    ;; a key reaches the hub: keys-changed makes b usable, with nothing else done in this Emacs
    (drgnx-hub-call-sync "gateway/keys" '(:keys (:b "sk-b-key")))
    (drgnx-test-wait (lambda () (member "b" (drgnx-hub-keys-held))) :secs 10 :what "keys-changed")
    (should (drgnx-ai-usable-p 'b 'chat))
    ;; this Emacs having a key in its environment is not what decides
    (let ((process-environment (cons "B_KEY=sk-local-only" process-environment)) (drgnx-hub--keys-held nil))
      (should-not (drgnx-ai-usable-p 'b 'chat)))))

(ert-deftest drgnx-ai-gateway/a-key-found-by-a-command-goes-to-the-hub ()
  ;; b's key sits in a netrc (a store, not the environment): a command finds it and hands it to the hub once; the mock
  ;; sees it as the provider key, never the editor token
  (drgnx-ai-gateway-test--with '((:path "/b/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"))
    (let ((netrc (concat root "netrc")))
      (with-temp-file netrc (insert "machine 127.0.0.1 login drgnx password sk-from-the-store\n"))
      (set-file-modes netrc #o600)
      (let ((auth-sources (list netrc)) (r nil))
        (should-not (drgnx-ai-usable-p 'b 'chat))
        (should (drgnx-ai-usable-p 'b 'chat t))
        (setq r (drgnx-ai-gateway-test--ask 'chat '(:messages [(:role "user" :content "x")]) '((b . "m")) :interactive t))
        (should (equal (car r) "hi"))
        (let ((req (car (drgnx-ai-gateway-test--requests root))))
          (should (equal (plist-get req :path) "/b/chat/completions"))
          (should (equal (drgnx-ai-gateway-test--header req "authorization") "Bearer sk-from-the-store")))
        (should (member "b" (drgnx-hub-keys-held)))
        (should (equal (cadr (car drgnx-ai-gateway-test--sent)) (car drgnx-hub--editor)))))))

(ert-deftest drgnx-ai-gateway/a-daemon-path-never-waits-for-the-hub ()
  ;; no hub, no token (this test starts none; DRGNX_NO_HUB_START is set): a timer or hook asks and hears an error at once,
  ;; the provider's reason, and nothing waited for the hub
  (let ((drgnx-hub--editor nil) (drgnx-hub--keys-held :unknown) (inhibit-interaction t)
        (drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil) (drgnx-hub--ensuring nil)
        (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (waited nil) result
        (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" (make-temp-file "drgnx-ai-gw" t)) "DRGNX_NO_HUB_START=1"
                                           "A_KEY=sk-local" "XDG_RUNTIME_DIR=/nonexistent-drgnx-run")
                                     process-environment))
        (drgnx-ai-providers '((a :name "A" :kind openai :url "http://127.0.0.1:1/v1" :key-env "A_KEY" :caps (chat)))))
    (advice-add 'drgnx-hub-ensure :before (lambda (&rest _) (setq waited t)) '((name . gw-test-spy)))
    (unwind-protect
        (let ((t0 (float-time)))
          (drgnx-ai-request 'chat 'chat '(:messages [(:role "user" :content "x")]) (lambda (text info) (setq result (cons text info)))
                            :chain '((a . "m")) :timeout 5)
          (should result)                                           ; answered synchronously
          (should (< (- (float-time) t0) 1))
          (should-not (car result))
          (should (string-search "drgnx hub is starting; try again" (plist-get (cdr result) :error)))
          (should-not waited))
      (advice-remove 'drgnx-hub-ensure 'gw-test-spy)
      (delete-directory (getenv "DRGNX_CONFIG_DIR") t))))

(ert-deftest drgnx-ai-gateway/keys-changed-updates-what-is-usable ()
  (let ((drgnx-hub--keys-held :unknown) (drgnx-hub--event-conn (make-pipe-process :name "gw-test" :noquery t)))
    (unwind-protect
        (progn
          (process-put drgnx-hub--event-conn :drgnx-proven t)
          (drgnx-hub--keys-changed "gateway/keys-changed" '(:providers ["openrouter" "a"]))
          (should (equal (drgnx-hub-keys-held) '("openrouter" "a")))
          (drgnx-hub--keys-changed "gateway/keys-changed" '(:providers []))
          (should (equal (drgnx-hub-keys-held) nil))
          ;; a hub that did not prove itself is not believed
          (process-put drgnx-hub--event-conn :drgnx-proven nil)
          (drgnx-hub--keys-changed "gateway/keys-changed" '(:providers ["x"]))
          (should (equal (drgnx-hub-keys-held) nil)))
      (delete-process drgnx-hub--event-conn))))

(provide 'ai-gateway-test)
;;; ai-gateway-test.el ends here
