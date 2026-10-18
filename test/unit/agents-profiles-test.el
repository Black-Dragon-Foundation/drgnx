;;; agents-profiles-test.el --- batch tests: Kimi and DeepSeek in Claude Code, on their own APIs or through OpenRouter -*- lexical-binding: t -*-
;; Keys here are fakes in a let-bound environment; no assertion prints one (booleans are asserted, not values).
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-agents)
(require 'drgnx-ai)
(require 'drgnx-agent-config-claude)

(defmacro drgnx-agents-profiles-test--with (&rest body)
  "BODY with drgnx's dirs, HOME and CLAUDE_CONFIG_DIR under a temp ROOT, fake provider keys, no gateway."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-agents-prof" t)))
          (process-environment
           (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                         (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                         (concat "CLAUDE_CONFIG_DIR=" root "claude")
                         "MOONSHOT_API_KEY=fake-moon-key" "DEEPSEEK_API_KEY=fake-deep-key"
                         "OPENROUTER_API_KEY=fake-or-key" "ANTHROPIC_API_KEY")
                   ;; …and every other variable agents must not inherit, with a recognisable fake value
                   (mapcar (lambda (n) (concat n "=fake-inherited"))
                           (seq-difference drgnx-agents-scrubbed-env
                                           '("MOONSHOT_API_KEY" "DEEPSEEK_API_KEY" "OPENROUTER_API_KEY" "ANTHROPIC_API_KEY")))
                   process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil)
          (drgnx-agents-use-gateway nil) (drgnx-agents-env-functions nil) (drgnx-agents-profiles nil))
     (unwind-protect
         (progn (make-directory (concat root "config") t) (make-directory (concat root "claude") t) ,@body)
       (delete-directory root t))))

(defun drgnx-agents-profiles-test--env (profile)
  (drgnx-agents--env (drgnx-agents--make :name "t" :profile profile :cwd temporary-file-directory)))

(defun drgnx-agents-profiles-test--var (env name)
  "The value of NAME in ENV (\"NAME=value\" strings), or `absent'."
  (let ((e (seq-find (lambda (s) (string-prefix-p (concat name "=") s)) env)))
    (if e (substring e (1+ (length name))) 'absent)))

(defun drgnx-agents-profiles-test--model (profile)
  (plist-get (cdr (drgnx-agents-profile profile)) :model))

(defun drgnx-agents-profiles-test--leaks (env key)
  "Non-nil when any entry of ENV contains KEY."
  (and (seq-find (lambda (s) (string-search key s)) env) t))

(ert-deftest drgnx-agents-profiles/kimi-and-deepseek-direct-env ()
  (drgnx-agents-profiles-test--with
    (dolist (c '(("claude (Kimi)" "https://api.moonshot.ai/anthropic" "fake-moon-key")
                 ("claude (DeepSeek)" "https://api.deepseek.com/anthropic" "fake-deep-key")))
      (let* ((env (drgnx-agents-profiles-test--env (car c)))
             (model (drgnx-agents-profiles-test--model (car c)))
             (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") (nth 1 c)))
             (token-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") (nth 2 c)))
             (api-key-empty (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_API_KEY") ""))
             (model-ok (and (stringp model) (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") model)))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") model))
             (tiers-ok (cl-every (lambda (n) (equal (drgnx-agents-profiles-test--var env n) model))
                                 '("ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL"))))
        (should url-ok) (should token-ok) (should api-key-empty) (should model-ok) (should small-ok) (should tiers-ok)))))

(ert-deftest drgnx-agents-profiles/small-model-defaults-to-model-and-a-model-is-required ()
  (drgnx-agents-profiles-test--with
    (let ((drgnx-agents-profiles
           '(("k" :command ("claude-agent-acp") :ai claude-deepseek :model "big" :small-model "tiny")
             ("nomodel" :command ("claude-agent-acp") :ai claude-moonshot)
             ("nomodel2" :command ("claude-agent-acp") :ai claude-deepseek))))
      (let* ((env (drgnx-agents-profiles-test--env "k"))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") "tiny"))
             (main-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") "big")))
        (should small-ok) (should main-ok))
      (dolist (name '("nomodel" "nomodel2"))
        (let ((err (should-error (drgnx-agents-profiles-test--env name) :type 'user-error)))
          (should (string-search ":model" (error-message-string err))))))))

(ert-deftest drgnx-agents-profiles/through-the-gateway-a-token-only ()
  ;; with the gateway the agent holds a token and the gateway's address, never the provider's key
  (drgnx-agents-profiles-test--with
    (let ((gw (list :url "http://127.0.0.1:1" :token (make-string 64 ?a))))
      (dolist (c '(("claude (Kimi)" . "fake-moon-key") ("claude (DeepSeek)" . "fake-deep-key")
                   ("claude (Kimi via OpenRouter)" . "fake-or-key")))
        (let* ((profile (cdr (drgnx-agents-profile (car c))))
               (env (drgnx-ai-agent-env (list :kind (plist-get profile :ai) :model (plist-get profile :model)) nil gw))
               (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") (plist-get gw :url)))
               (token-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") (plist-get gw :token)))
               (empty-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_API_KEY") ""))
               (model-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") (plist-get profile :model)))
               (leaked (drgnx-agents-profiles-test--leaks env (cdr c))))
          (should url-ok) (should token-ok) (should empty-ok) (should model-ok) (should-not leaked))))
    ;; both are gateway kinds, and the gateway chain is the one provider with the profile's model
    (should (memq 'claude-moonshot drgnx-ai-gateway-kinds))
    (should (memq 'claude-deepseek drgnx-ai-gateway-kinds))))

(ert-deftest drgnx-agents-profiles/openrouter-with-a-model-chain ()
  (should (equal (drgnx-ai-agent-gateway-chain 'claude-moonshot "m1") '((moonshot . "m1"))))
  (should (equal (drgnx-ai-agent-gateway-chain 'claude-deepseek "m2") '((deepseek . "m2"))))
  (should (equal (drgnx-ai-agent-gateway-chain 'claude-openrouter "vendor/m3") '((openrouter . "vendor/m3"))))
  ;; without a model, OpenRouter keeps the `agent' role as before
  (let ((drgnx-ai-default-roles '((agent (openrouter . "role-model")))) (auth-sources nil))
    (cl-letf (((symbol-function 'drgnx-ai--config) (lambda (&rest _) nil)))
      (should (equal (drgnx-ai-agent-gateway-chain 'claude-openrouter) '((openrouter . "role-model"))))))
  (drgnx-agents-profiles-test--with
    (dolist (name '("claude (Kimi via OpenRouter)" "claude (DeepSeek via OpenRouter)"))
      (let* ((env (drgnx-agents-profiles-test--env name))
             (model (drgnx-agents-profiles-test--model name))
             (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") "https://openrouter.ai/api"))
             (token-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") "fake-or-key"))
             (model-ok (and (stringp model) (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") model)))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") model)))
        (should url-ok) (should token-ok) (should model-ok) (should small-ok)))
    ;; the plain OpenRouter profile has no model of its own: no model variables
    (let ((env (drgnx-agents-profiles-test--env "claude (OpenRouter)")))
      (should (eq (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") 'absent))
      (should (eq (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") 'absent)))))

(ert-deftest drgnx-agents-profiles/no-key-says-where ()
  (drgnx-agents-profiles-test--with
    (dolist (c '(("claude (Kimi)" "MOONSHOT_API_KEY" "api.moonshot.ai")
                 ("claude (DeepSeek)" "DEEPSEEK_API_KEY" "api.deepseek.com")
                 ("claude (Kimi via OpenRouter)" "OPENROUTER_API_KEY" "openrouter.ai")))
      (let ((process-environment (cons (nth 1 c) process-environment))   ; a bare name unsets it
            (drgnx-ai--keys (make-hash-table :test #'eq)))
        (let ((err (should-error (drgnx-agents-profiles-test--env (car c)) :type 'user-error)))
          (let ((names-var (string-search (nth 1 c) (error-message-string err)))
                (names-host (string-search (nth 2 c) (error-message-string err))))
            (should names-var) (should names-host)))))))

(defun drgnx-agents-profiles-test--snapshot (dir)
  "DIR's files and their contents, as a sorted alist."
  (sort (mapcar (lambda (f) (cons f (if (file-directory-p f) 'dir
                                      (with-temp-buffer (insert-file-contents-literally f) (buffer-string)))))
                (directory-files-recursively dir "" t))
        (lambda (a b) (string< (car a) (car b)))))

(ert-deftest drgnx-agents-profiles/two-profiles-share-claude-dir-not-routes ()
  (drgnx-agents-profiles-test--with
    (with-temp-file (concat root "claude/settings.json") (insert "{\"theme\":\"dark\"}\n"))
    (let* ((before (drgnx-agents-profiles-test--snapshot root))
           (a (drgnx-agents-profiles-test--env "claude (Kimi)"))
           (b (drgnx-agents-profiles-test--env "claude (DeepSeek)"))
           (route-vars '("ANTHROPIC_BASE_URL" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_MODEL" "ANTHROPIC_DEFAULT_HAIKU_MODEL"
                         "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL"))
           (names (lambda (env) (mapcar (lambda (s) (car (split-string s "="))) env)))
           (outside (lambda (env) (seq-remove (lambda (s) (member (car (split-string s "=")) route-vars)) env))))
      ;; the same variables, and apart from the route's own, the same values
      (should (equal (sort (funcall names a) #'string<) (sort (funcall names b) #'string<)))
      (should (equal (funcall outside a) (funcall outside b)))
      (should-not (equal (drgnx-agents-profiles-test--var a "ANTHROPIC_BASE_URL")
                         (drgnx-agents-profiles-test--var b "ANTHROPIC_BASE_URL")))
      ;; neither the config directory nor anything else changed: the route lives in the environment only
      (should (equal (drgnx-agents-profiles-test--snapshot root) before))
      (should-not (file-exists-p (concat root "home/.claude/settings.json"))))))

(ert-deftest drgnx-agents-profiles/page-lists-the-new-routes ()
  (drgnx-agents-profiles-test--with
    (let ((routes (drgnx-agent-config-claude-routes nil)))
      (dolist (c '(("claude (Kimi)" per-token "Moonshot (Kimi)")
                   ("claude (DeepSeek)" per-token "DeepSeek")
                   ("claude (Kimi via OpenRouter)" openrouter "OpenRouter")
                   ("claude (DeepSeek via OpenRouter)" openrouter "OpenRouter")))
        (let* ((r (seq-find (lambda (r) (equal (plist-get r :profile) (car c))) routes))
               (billing-ok (and r (eq (plist-get r :billing) (nth 1 c))))
               (vendor-ok (and r (equal (plist-get r :vendor) (nth 2 c))))
               (model-ok (and r (equal (plist-get r :model) (drgnx-agents-profiles-test--model (car c)))))
               (key-ok (and r (stringp (plist-get r :key-where)))))
          (should r) (should billing-ok) (should vendor-ok) (should model-ok) (should key-ok))))))

(ert-deftest drgnx-agents-profiles/runner-unsets-the-new-keys ()
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v (append drgnx-agents-scrubbed-env '("CLAUDE_CONFIG_DIR" "CODEX_HOME" "KIMI_CODE_HOME")))
    (should-not (getenv v))))

(defun drgnx-agents-profiles-test--inherited (env)
  "The names of the variables a child started with ENV in front of `process-environment' would see with a fake
value (a recognisable prefix; the values themselves are never shown)."
  (let ((process-environment (append env process-environment)) names)
    (dolist (e process-environment)
      (let ((n (car (split-string e "="))) (v nil))
        (setq v (getenv n))
        (when (and v (string-prefix-p "fake-" v)) (cl-pushnew n names :test #'equal))))
    (sort names #'string<)))

(ert-deftest drgnx-agents-profiles/agents-see-only-their-own-routes-key ()
  (drgnx-agents-profiles-test--with
    (let ((expected '(("claude") ("claude (Kimi)" "ANTHROPIC_AUTH_TOKEN") ("claude (DeepSeek)" "ANTHROPIC_AUTH_TOKEN")
                      ("claude (Kimi via OpenRouter)" "ANTHROPIC_AUTH_TOKEN")
                      ("claude (DeepSeek via OpenRouter)" "ANTHROPIC_AUTH_TOKEN")
                      ("claude (OpenRouter)" "ANTHROPIC_AUTH_TOKEN") ("claude (Ollama)"))))
      (dolist (x expected)
        (let* ((env (drgnx-agents-profiles-test--env (car x)))
               (seen (drgnx-agents-profiles-test--inherited env))
               (ok (equal seen (cdr x))))
          (should ok)))
      ;; …and the one it sees is its own: Kimi's token is the Moonshot key, nothing else's
      (let* ((env (drgnx-agents-profiles-test--env "claude (Kimi)"))
             (own (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") "fake-moon-key")))
        (should own)))))

(ert-deftest drgnx-agents-profiles/a-variable-taken-off-the-list-is-passed-on ()
  (drgnx-agents-profiles-test--with
    (let ((drgnx-agents-scrubbed-env (remove "OPENAI_API_KEY" drgnx-agents-scrubbed-env)))
      (let ((seen (drgnx-agents-profiles-test--inherited (drgnx-agents-profiles-test--env "claude"))))
        (should (equal seen '("OPENAI_API_KEY")))))))

(ert-deftest drgnx-agents-profiles/the-hub-registers-the-profiles-provider-and-model ()
  ;; a started agent on a Kimi profile is registered with the gateway as one provider and the profile's model
  (require 'drgnx-hub)
  (require 'drgnx-gateway)
  (drgnx-agents-profiles-test--with
    (let ((drgnx-agents-use-gateway t) (drgnx-work-db--handles nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq))
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-hub--exit-function #'drgnx-hub-stop))
      (unwind-protect
          (progn
            (drgnx-hub-serve (drgnx-hub-socket))
            (let* ((s (drgnx-agents--make :name "t" :profile "claude (Kimi)" :cwd temporary-file-directory))
                   (env (drgnx-agents--env s))
                   (model (drgnx-agents-profiles-test--model "claude (Kimi)"))
                   (reg (cdar (drgnx-gateway-registrations)))
                   (chain (plist-get reg :chain))
                   (chain-ok (and (= (length chain) 1) (eq (caar chain) 'moonshot)
                                  (equal (or (cdar chain) (cadar chain)) model)))
                   (token-ok (string-match-p "\\`[0-9a-f]\\{64\\}\\'"
                                             (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN")))
                   (leaked (drgnx-agents-profiles-test--leaks env "fake-moon-key")))
              (should chain-ok) (should token-ok) (should-not leaked)
              ;; a gateway agent inherits no key at all, not even its own provider's
              (should (equal (drgnx-agents-profiles-test--inherited env) nil))
              (should (eq (drgnx-agent-session-via s) 'gateway))))
        (drgnx-hub-disconnect)
        (drgnx-hub-stop)
        (drgnx-work-db-close-all)))))

;;; agents-profiles-test.el ends here
