;;; agents-profiles-test.el --- batch tests: Kimi and DeepSeek on their own agents, or in Claude Code through OpenRouter -*- lexical-binding: t -*-
;; Keys here are fakes in a let-bound environment; no assertion prints one (booleans are asserted, not values).
;; The profiles and their provider environment are the editor's; the hub (Ratatoskr) starts the agents and registers
;; them with its gateway, so the gateway's address and token are a fake one here.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-agents)
(require 'drgnx-ai)
(require 'drgnx-agent-config-claude)

(defmacro drgnx-agents-profiles-test--with (&rest body)
  "BODY with drgnx's dirs, HOME and CLAUDE_CONFIG_DIR under a temp ROOT, fake provider keys, and GW a fake gateway
registration (:url :token)."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-agents-prof" t)))
          (process-environment
           (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                         (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                         (concat "CLAUDE_CONFIG_DIR=" root "claude")
                         "MOONSHOT_API_KEY=fake-moon-key" "DEEPSEEK_API_KEY=fake-deep-key"
                         "OPENROUTER_API_KEY=fake-or-key" "ANTHROPIC_API_KEY")
                   process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil)
          (drgnx-agents-env-functions nil) (drgnx-agents-profiles nil)
          (gw (list :url "http://127.0.0.1:1" :token (make-string 64 ?a))))
     (ignore gw)
     (unwind-protect
         (progn (make-directory (concat root "config") t) (make-directory (concat root "claude") t) ,@body)
       (delete-directory root t))))

(defun drgnx-agents-profiles-test--env (name gw)
  "The provider environment the profile NAME's agent gets through the gateway GW."
  (let ((profile (cdr (drgnx-agents-profile name))))
    (drgnx-ai-check-agent-model (plist-get profile :ai) (plist-get profile :model))
    (drgnx-ai-agent-env (list :kind (plist-get profile :ai) :model (plist-get profile :model)
                              :small-model (plist-get profile :small-model))
                        gw)))

(defun drgnx-agents-profiles-test--var (env name)
  "The value of NAME in ENV (\"NAME=value\" strings), or `absent'."
  (let ((e (seq-find (lambda (s) (string-prefix-p (concat name "=") s)) env)))
    (if e (substring e (1+ (length name))) 'absent)))

(defun drgnx-agents-profiles-test--model (profile)
  (plist-get (cdr (drgnx-agents-profile profile)) :model))

(defun drgnx-agents-profiles-test--leaks (env key)
  "Non-nil when any entry of ENV contains KEY."
  (and (seq-find (lambda (s) (string-search key s)) env) t))

(ert-deftest drgnx-agents-profiles/kimi-and-deepseek-env ()
  ;; through the hub's gateway: its address and a token, never the provider's URL or key; the model for every tier
  (drgnx-agents-profiles-test--with
    (dolist (c '(("kimi" "https://api.moonshot.ai/anthropic" "fake-moon-key")
                 ("deepseek" "https://api.deepseek.com/anthropic" "fake-deep-key")))
      (let* ((env (drgnx-agents-profiles-test--env (car c) gw))
             (model (drgnx-agents-profiles-test--model (car c)))
             (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") (plist-get gw :url)))
             (token-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") (plist-get gw :token)))
             (leaked (drgnx-agents-profiles-test--leaks env (nth 2 c)))
             (api-key-empty (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_API_KEY") ""))
             (model-ok (and (stringp model) (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") model)))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") model))
             (tiers-ok (cl-every (lambda (n) (equal (drgnx-agents-profiles-test--var env n) model))
                                 '("ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL"))))
        (should url-ok) (should token-ok) (should-not leaked) (should api-key-empty) (should model-ok) (should small-ok)
        (should tiers-ok)))))

(ert-deftest drgnx-agents-profiles/small-model-defaults-to-model-and-a-model-is-required ()
  (drgnx-agents-profiles-test--with
    (let ((drgnx-agents-profiles
           '(("k" :command ("claude-agent-acp") :ai claude-deepseek :model "big" :small-model "tiny")
             ("nomodel" :command ("claude-agent-acp") :ai claude-moonshot)
             ("nomodel2" :command ("claude-agent-acp") :ai claude-deepseek))))
      (let* ((env (drgnx-agents-profiles-test--env "k" gw))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") "tiny"))
             (main-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") "big")))
        (should small-ok) (should main-ok))
      (dolist (name '("nomodel" "nomodel2"))
        (let ((err (should-error (drgnx-agents-profiles-test--env name gw) :type 'user-error)))
          (should (string-search ":model" (error-message-string err))))))))

(ert-deftest drgnx-agents-profiles/through-the-gateway-a-token-only ()
  ;; with the gateway the agent holds a token and the gateway's address, never the provider's key
  (drgnx-agents-profiles-test--with
    (dolist (c '(("kimi" . "fake-moon-key") ("deepseek" . "fake-deep-key")
                 ("claude (Kimi via OpenRouter)" . "fake-or-key")))
      (let* ((profile (cdr (drgnx-agents-profile (car c))))
             (env (drgnx-ai-agent-env (list :kind (plist-get profile :ai) :model (plist-get profile :model)) gw))
             (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") (plist-get gw :url)))
             (token-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") (plist-get gw :token)))
             (empty-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_API_KEY") ""))
             (model-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") (plist-get profile :model)))
             (leaked (drgnx-agents-profiles-test--leaks env (cdr c))))
        (should url-ok) (should token-ok) (should empty-ok) (should model-ok) (should-not leaked)))
    ;; both are gateway kinds, and the gateway chain is the one provider with the profile's model
    (should (memq 'kimi-moonshot drgnx-ai-gateway-kinds))
    (should (memq 'dsh-deepseek drgnx-ai-gateway-kinds))))

(ert-deftest drgnx-agents-profiles/openrouter-with-a-model-chain ()
  (should (equal (drgnx-ai-agent-gateway-chain 'kimi-moonshot "m1") '((moonshot . "m1"))))
  (should (equal (drgnx-ai-agent-gateway-chain 'dsh-deepseek "m2") '((deepseek . "m2"))))
  (should (equal (drgnx-ai-agent-gateway-chain 'claude-moonshot "m1") '((moonshot . "m1"))))
  (should (equal (drgnx-ai-agent-gateway-chain 'claude-openrouter "vendor/m3") '((openrouter . "vendor/m3"))))
  ;; without a model, OpenRouter keeps the `agent' role as before
  (let ((drgnx-ai-default-roles '((agent (openrouter . "role-model")))) (auth-sources nil))
    (cl-letf (((symbol-function 'drgnx-config-get) (lambda (&rest _) nil)))    ; no ai.eld
      (should (equal (drgnx-ai-agent-gateway-chain 'claude-openrouter) '((openrouter . "role-model"))))))
  (drgnx-agents-profiles-test--with
    (dolist (name '("claude (Kimi via OpenRouter)" "claude (DeepSeek via OpenRouter)"))
      (let* ((env (drgnx-agents-profiles-test--env name gw))
             (model (drgnx-agents-profiles-test--model name))
             (url-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_BASE_URL") (plist-get gw :url)))
             (model-ok (and (stringp model) (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") model)))
             (small-ok (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") model)))
        (should url-ok) (should model-ok) (should small-ok)))
    ;; the plain OpenRouter profile has no model of its own: no model variables
    (let ((env (drgnx-agents-profiles-test--env "claude (OpenRouter)" gw)))
      (should (eq (drgnx-agents-profiles-test--var env "ANTHROPIC_MODEL") 'absent))
      (should (eq (drgnx-agents-profiles-test--var env "ANTHROPIC_DEFAULT_HAIKU_MODEL") 'absent)))))

(ert-deftest drgnx-agents-profiles/page-lists-the-new-routes ()
  (drgnx-agents-profiles-test--with
    (let ((routes (drgnx-agent-config-claude-routes nil)))
      (dolist (c '(("claude (Kimi via OpenRouter)" openrouter "OpenRouter")
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

;; [D] pure: a vendor with an agent of its own runs it: the built-ins have Kimi Code and DeepSeek Harness, never
;; Claude Code on a vendor's own endpoint, and Claude Code on a model that is not Claude has no tool search.
(ert-deftest drgnx-agents-profiles/builtins-have-kimi-and-deepseek-not-claude-on-vendor-endpoints ()
  (drgnx-agents-profiles-test--with
    (let ((names (drgnx-agents-profile-names)))
      (should-not (member "claude (Kimi)" names))
      (should-not (member "claude (DeepSeek)" names))
      (dolist (c '(("kimi" ("kimi" "acp") kimi kimi-moonshot)
                   ("deepseek" ("dsh" "--profile" "acp") deepseek dsh-deepseek)))
        (let* ((p (cdr (drgnx-agents-profile (car c))))
               (command-ok (equal (plist-get p :command) (nth 1 c)))
               (provider-ok (eq (plist-get p :provider) (nth 2 c)))
               (ai-ok (eq (plist-get p :ai) (nth 3 c)))
               (doc-ok (stringp (plist-get p :doc))))
          (should command-ok) (should provider-ok) (should ai-ok) (should doc-ok)))
      (dolist (name '("claude (Kimi via OpenRouter)" "claude (DeepSeek via OpenRouter)" "claude (Ollama)"))
        (should (member "ENABLE_TOOL_SEARCH=false" (plist-get (cdr (drgnx-agents-profile name)) :env)))))))

;; [D] pure: a user profile that still names a retired kind starts, and one status line per Emacs session names the
;; built-in profile that replaces it.
(ert-deftest drgnx-ai-test-retired-kind-names-its-replacement ()
  (let ((drgnx-ai--retired-noted nil))
    (let ((first (drgnx-ai-retired-kind-note 'claude-moonshot)))
      (should (stringp first))
      (should (string-search "\"kimi\"" first)))
    (should-not (drgnx-ai-retired-kind-note 'claude-moonshot))
    (should (string-search "\"deepseek\"" (drgnx-ai-retired-kind-note 'claude-deepseek)))
    (should-not (drgnx-ai-retired-kind-note 'kimi-moonshot))
    (should-not (drgnx-ai-retired-kind-note 'claude-openrouter))
    (drgnx-agents-profiles-test--with
      (let ((env (drgnx-ai-agent-env (list :kind 'claude-moonshot :model "kimi-k3") gw)))
        (should (equal (drgnx-agents-profiles-test--var env "ANTHROPIC_AUTH_TOKEN") (plist-get gw :token)))))))

;;; agents-profiles-test.el ends here
