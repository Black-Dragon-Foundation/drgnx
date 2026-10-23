;;; drgnx-ai.el --- The AI provider registry: providers, roles, keys, agent environments -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One registry for every AI feature — ghost text, inline edit, chat (gptel), embeddings, agents.  Providers are
;; presets for OpenRouter and the local runners, plus the user's (ai.eld in the config dir) and the project's
;; (.drgnx/ai.eld); roles (complete, edit, chat, embed, agent) are fallback chains of (PROVIDER . MODEL).  Both files
;; are config files (`drgnx-config': a mistake keeps the last good providers; a project's file is read-only, 64 KiB).
;; Keys come from where the user keeps them — the environment, then auth-source (the macOS Keychain and the Linux
;; keyring included, for commands the user ran) — when they are needed.  drgnx writes a key in one place only, that
;; Keychain or keyring, and only when the user asks (`drgnx-ai-store-key'); never in a command line, a log or a
;; file.  Subscription CLIs (Claude Code, Codex) are only launched: their logins are theirs.  See docs/guide/ai.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-timer)

(defconst drgnx-ai-presets
  '((openrouter :name "OpenRouter" :kind openai :url "https://openrouter.ai/api/v1" :key-env "OPENROUTER_API_KEY"
                :caps (chat fim embed) :messages t)
    (ollama     :name "Ollama" :kind ollama :url "http://127.0.0.1:11434" :caps (chat fim embed) :messages t)
    ;; the agent gateway only (Claude Code with your own Anthropic API key): no editor feature asks it
    (anthropic  :name "Anthropic API" :kind anthropic :url "https://api.anthropic.com/v1" :key-env "ANTHROPIC_API_KEY"
                :auth x-api-key :caps () :messages t)
    ;; Kimi and DeepSeek on their own Anthropic-compatible APIs (Claude Code agents only; Bearer through
    ;; ANTHROPIC_AUTH_TOKEN, as both vendors' Claude Code guides have it)
    (moonshot   :name "Moonshot (Kimi)" :kind anthropic :url "https://api.moonshot.ai/anthropic" :key-env "MOONSHOT_API_KEY"
                :caps () :messages t)
    (deepseek   :name "DeepSeek" :kind anthropic :url "https://api.deepseek.com/anthropic" :key-env "DEEPSEEK_API_KEY"
                :caps () :messages t)
    (lmstudio   :name "LM Studio" :kind openai :url "http://127.0.0.1:1234/v1" :caps (chat fim embed))
    (llamacpp   :name "llama.cpp server" :kind llamacpp :url "http://127.0.0.1:8012" :caps (chat fim embed))   ; its 8080 is TEI's
    (vllm       :name "vLLM" :kind openai :url "http://127.0.0.1:8000/v1" :caps (chat fim embed))
    (jan        :name "Jan" :kind openai :url "http://127.0.0.1:1337/v1" :caps (chat))
    (localai    :name "LocalAI" :kind openai :url "http://127.0.0.1:8090/v1" :caps (chat fim embed))
    (koboldcpp  :name "KoboldCpp" :kind openai :url "http://127.0.0.1:5001/v1" :caps (chat fim))
    (tabbyapi   :name "TabbyAPI / text-generation-webui" :kind openai :url "http://127.0.0.1:5000/v1" :caps (chat fim))
    (gpt4all    :name "GPT4All" :kind openai :url "http://127.0.0.1:4891/v1" :caps (chat))
    (lemonade   :name "Lemonade" :kind openai :url "http://127.0.0.1:13305/api/v1" :caps (chat fim embed))
    (llamafile  :name "llamafile" :kind openai :url "http://127.0.0.1:8081/v1" :caps (chat fim))       ; its 8080 is TEI's
    (tei        :name "Text Embeddings Inference" :kind tei :url "http://127.0.0.1:8080" :caps (embed)))
  "The providers drgnx knows without configuration: id → (:name :kind :url [:key-env] :caps [:messages] [:auth]).
:messages — it serves Anthropic's Messages API (URL without /v1, then the agent's path): the agent gateway can carry
it; :auth x-api-key — its key goes in that header (else `Authorization: Bearer').  A provider in ai.eld may add
:price (IN . OUT), USD per million tokens, for the gateway's spend.")

(defconst drgnx-ai-default-roles
  '((complete (ollama . "qwen2.5-coder:1.5b"))           ; fits next to TEI on a 6 GB GPU
    (edit (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
    (chat (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
    (embed (tei))
    (agent (openrouter)))                                ; the gateway's chain for agents; nil model: the agent's own
  "Each role's chain when neither the project nor the user names one.")

(defconst drgnx-ai-lmstudio-models
  '(("qwen2.5-coder:1.5b" "qwen2.5-coder-1.5b-instruct" "https://huggingface.co/lmstudio-community/Qwen2.5-Coder-1.5B-Instruct-GGUF")
    ("qwen2.5-coder:3b" "qwen2.5-coder-3b-instruct" "https://huggingface.co/lmstudio-community/Qwen2.5-Coder-3B-Instruct-GGUF")
    ("qwen2.5-coder:7b" "qwen2.5-coder-7b-instruct" "https://huggingface.co/lmstudio-community/Qwen2.5-Coder-7B-Instruct-GGUF")
    ("nomic-embed-text" "text-embedding-nomic-embed-text-v1.5" "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF"))
  "Ollama's model → (the name LM Studio serves it by, the name `lms get' downloads it by): the same GGUF models.")

(declare-function drgnx-ai-model-vram "drgnx-ai-probe")

(defun drgnx-ai-default-models (room &optional provider)
  "The models onboarding sets up for ROOM MiB of (GPU or unified) memory: ((complete . MODEL) (edit . MODEL)
\(chat . MODEL)).  Completion is always the 1.5B coder (it answers on every pause); edit and chat get the 7B next to
it when both fit, else the 3B, else the 1.5B too.  ROOM nil: as little as can be.  Ollama's names; PROVIDER
`lmstudio': LM Studio's (`drgnx-ai-lmstudio-models')."
  (require 'drgnx-ai-probe)
  (let* ((small "qwen2.5-coder:1.5b") (room (or room 0))
         (big (seq-find (lambda (m) (>= room (+ (drgnx-ai-model-vram small) (drgnx-ai-model-vram m))))
                        '("qwen2.5-coder:7b" "qwen2.5-coder:3b") small))
         (name (lambda (m) (if (eq provider 'lmstudio) (nth 1 (assoc m drgnx-ai-lmstudio-models)) m))))
    (list (cons 'complete (funcall name small)) (cons 'edit (funcall name big)) (cons 'chat (funcall name big)))))

(defvar drgnx-ai--keys (make-hash-table :test #'eq) "Keys found this session: provider → key (kept in memory only).")

;;;; Configuration

(defconst drgnx-ai--roles-schema '(alist symbol (alist symbol (or string null)))
  "A role → its chain: ((ROLE (PROVIDER . MODEL)…)…); a MODEL is a name, or nil for the provider's own.")

(defun drgnx-ai--price-p (price)
  "Non-nil when PRICE is (IN . OUT): two non-negative numbers."
  (and (consp price) (numberp (car price)) (numberp (cdr price)) (>= (car price) 0) (>= (cdr price) 0)))

(drgnx-config-define 'ai
                     :file "ai.eld" :shape 'plist :version 1 :reload 'mtime :last-good t
                     :schema `(plist (:providers (alist symbol
                                                        (plist (:name string "What the provider is called")
                                                               ;; anthropic: the presets that serve agents only
                                                               (:kind (enum openai ollama llamacpp tei anthropic) "How to talk to it")
                                                               (:url string "Its address")
                                                               (:key-env string "The environment variable holding its key (never the key)")
                                                               (:caps (list-of symbol) "What it does: chat, fim, embed")
                                                               (:price (pred drgnx-ai--price-p "(IN . OUT) dollars per million tokens")
                                                                       "What the agent gateway counts its spend by")
                                                               (:messages boolean "Whether it serves Anthropic's Messages API")))
                                                 "Providers of your own, or presets moved (an entry replaces the preset with its id)")
                                     (:roles ,drgnx-ai--roles-schema "Each role's chain of (PROVIDER . MODEL), tried in order"))
                     :default nil
                     :header ";; drgnx AI providers and roles (docs/guide/ai.md) — never a key here\n"
                     :doc "Your AI providers and each role's chain of providers and models; never a key.")

(drgnx-config-define 'ai-project
                     :dir 'project :file "ai.eld" :shape 'plist :version 1 :reload 'mtime
                     :schema `(plist (:roles ,drgnx-ai--roles-schema
                                             "The project's roles (a remote provider in a chain is asked about once)"))
                     :default nil
                     :doc "A project's roles, among the providers you have: never a provider or a key of its own.")

(defun drgnx-ai-file () (drgnx-config-file 'ai))

(defun drgnx-ai--project-file ()
  "The project's .drgnx/ai.eld; never looked for on a remote directory (a timer asks: no remote round-trips)."
  (unless (file-remote-p default-directory)
    (when-let* ((dir (locate-dominating-file default-directory ".drgnx/ai.eld")))
      (expand-file-name ".drgnx/ai.eld" dir))))

(defun drgnx-ai--project-roles ()
  "The roles in the project's .drgnx/ai.eld; none when it has a mistake or is over 64 KiB (one problem says so)."
  (when-let* ((file (drgnx-ai--project-file)))
    (drgnx-config-get 'ai-project :roles (file-name-directory (directory-file-name (file-name-directory file))))))

(defun drgnx-ai-providers ()
  "Every provider: the presets, then the user's ai.eld (an entry replaces a preset with its id).  A project's
ai.eld never adds or changes one: a cloned repository must not choose where your code and keys go."
  (let ((ps (copy-sequence drgnx-ai-presets)))
    (dolist (p (drgnx-config-get 'ai :providers))
      (setq ps (cons p (assq-delete-all (car p) ps))))
    ps))

(defun drgnx-ai-provider (id) (alist-get id (drgnx-ai-providers)))

(declare-function drgnx-hub-resend-providers "drgnx-hub-client")

(defun drgnx-ai--config-changed (name)
  "A listener on `drgnx-config-changed-functions': when ai.eld changed, the hub gets the provider table again
\(`drgnx-hub-resend-providers': only from an editor connected to it).  A key never goes with it."
  (when (and (eq name 'ai) (fboundp 'drgnx-hub-resend-providers))
    (drgnx-hub-resend-providers)))

(add-hook 'drgnx-config-changed-functions #'drgnx-ai--config-changed)

(defun drgnx-ai-unload-function ()
  "Remove the ai.eld listener (`unload-feature'); nil, so the feature unloads as usual."
  (remove-hook 'drgnx-config-changed-functions #'drgnx-ai--config-changed)
  nil)

;; A project's role may name a provider that is not on this machine (paid calls on every pause, your code sent
;; away).  The user confirms that once per project, from a command they ran; until then (and after a no) only the
;; local steps of the project's chain are used.
(defun drgnx-ai-remote-p (id)
  "Non-nil when provider ID is not on this machine: its address is not loopback.  A provider whose address has
no host, or does not parse, counts as remote (an unknown ID does not: nothing is asked of it)."
  (when-let* ((p (drgnx-ai-provider id)))
    (let ((host (ignore-errors (url-host (url-generic-parse-url (plist-get p :url))))))
      (or (not (stringp host)) (not (member (downcase host) '("localhost" "127.0.0.1" "::1" "[::1]")))))))

(defun drgnx-ai-routes-file ()
  "Where the answers about projects' remote routes are kept (drgnx state): :projects ((ROOT :allow BOOL :ids IDS)…)."
  (expand-file-name "ai-project-routes.eld" (drgnx-state-dir)))

(defun drgnx-ai--project-root ()
  "The real root (symlinks resolved: one repository, one answer; a link pointed at another repository gets its own)
of the project whose .drgnx/ai.eld applies here, or nil."
  (when-let* ((file (drgnx-ai--project-file)))
    (file-truename (file-name-directory (directory-file-name (file-name-directory file))))))

(defun drgnx-ai--chain-remote-ids (chain)
  (seq-filter #'drgnx-ai-remote-p (delete-dups (mapcar #'car chain))))

(defun drgnx-ai--project-remote-ids ()
  "The remote providers the project's roles name."
  (drgnx-ai--chain-remote-ids
   (apply #'append (mapcar #'cdr (drgnx-ai--project-roles)))))

(defun drgnx-ai--route-answer ()
  "This project's answer (:allow BOOL :ids IDS: the remote providers it was about), or nil; a routes file that does
not read has none (the user is asked again, and the file is copied aside before the answer is written)."
  (when-let* ((root (drgnx-ai--project-root)))
    (let ((data (plist-get (drgnx-file-read (drgnx-ai-routes-file)) :data)))
      (and (proper-list-p data) (cdr (assoc root (plist-get data :projects)))))))

(defun drgnx-ai--allowed-remote-ids ()
  "The remote providers the user allowed this project to use."
  (let ((a (drgnx-ai--route-answer))) (and (plist-get a :allow) (plist-get a :ids))))

(defun drgnx-ai-confirm-project-route ()
  "Make sure the user has been asked about the remote providers this project's .drgnx/ai.eld routes roles to: once
per project (again only for a remote provider they were not asked about), the answer kept per root in drgnx state.
Returns non-nil when the project's routes may be used.  Asks only when a command the user ran calls it (never in
batch); call it at the start of such a command, never from a timer, hook or process sentinel."
  (let ((ids (drgnx-ai--project-remote-ids)) (root (drgnx-ai--project-root)))
    (cond
     ((null ids) t)
     ((null (seq-difference ids (drgnx-ai--allowed-remote-ids))) t)
     ((or noninteractive (null root)) nil)
     ((null (seq-difference ids (plist-get (drgnx-ai--route-answer) :ids))) nil)   ; already told no
     (t (let* ((allow (y-or-n-p (format "%s routes AI roles to %s (remote: your code leaves this machine, and it may cost money).  Use that route in this project? "
                                        (abbreviate-file-name (drgnx-ai--project-file))
                                        (mapconcat #'symbol-name ids ", "))))
               (file (drgnx-ai-routes-file)))
          (drgnx-file-update
           file
           (lambda (conf)                       ; the other keys and projects stay; an unreadable file is copied aside
             (let ((conf (if (and (proper-list-p conf) (keywordp (car conf))) conf (list :version 1))))
               (plist-put conf :projects (cons (list root :allow (and allow t) :ids ids)
                                               (assoc-delete-all root (copy-sequence (plist-get conf :projects)))))))
           :on-unreadable 'backup :pretty t
           :header ";; drgnx: projects whose .drgnx/ai.eld routes a role to a remote provider, and your answer\n")
          allow)))))

(defun drgnx-ai-role (role)
  "ROLE's chain ((PROVIDER . MODEL)…): the project's, else the user's, else the default.  A project's steps
that name a remote provider count only once the user allowed it (`drgnx-ai-confirm-project-route'); this never asks."
  (let ((project (alist-get role (drgnx-ai--project-roles))))
    (when (seq-some (lambda (step) (drgnx-ai-remote-p (car step))) project)   ; the common case reads nothing more
      (let ((allowed (drgnx-ai--allowed-remote-ids)))
        (setq project (seq-remove (lambda (step) (and (drgnx-ai-remote-p (car step)) (not (memq (car step) allowed)))) project))))
    (or project
        (alist-get role (drgnx-config-get 'ai :roles))
        (alist-get role drgnx-ai-default-roles))))

(defun drgnx-ai-user-role (role)
  "ROLE's chain in the user's own configuration (their ai.eld, else the default), without any project's: what a
choice written back to ai.eld starts from, so one project's route never becomes global."
  (or (alist-get role (drgnx-config-get 'ai :roles))
      (alist-get role drgnx-ai-default-roles)))

;;;; Keys

(defun drgnx-ai--secret-source ()
  "The auth-source entry of the system's secret store: the macOS Keychain, else the Secret Service's default collection."
  (if (eq system-type 'darwin) 'macos-keychain-internet 'default))

(defun drgnx-ai--secret-source-p (s)
  "Non-nil when auth-source entry S is the macOS Keychain or the Secret Service (it may prompt or block): a symbol
or string naming one, or a plist entry whose `:source' is one (`(:source (:secrets \"Login\"))',
`(:source (:macos-keychain-internet default))')."
  (cond ((consp s)
         (let ((source (ignore-errors (plist-get s :source))))
           (or (memq (car-safe source) '(:secrets :macos-keychain-internet :macos-keychain-generic))
               (memq (car s) '(:secrets :macos-keychain-internet :macos-keychain-generic))
               (and source (drgnx-ai--secret-source-p source)))))
        (t (or (memq s '(macos-keychain-internet macos-keychain-generic default))
               (and (stringp s) (or (string-prefix-p "macos-keychain-" s) (string-prefix-p "secrets:" s)))))))

(defvar epa-file-name-regexp)

(defun drgnx-ai--quiet-sources (sources)
  "SOURCES that can be read without asking anything: plain file names, but not one epa decrypts (.gpg, and its
backups: `epa-file-name-regexp'), nor a .plist one (auth-source opens it as a plstore, whose secret part GnuPG
decrypts); the Keychain or a keyring may prompt; a plist entry is not known to be quiet, so it is left out."
  (require 'epa-hook)
  (seq-filter (lambda (s) (and (stringp s) (not (string-suffix-p ".gpg" s)) (not (string-match-p epa-file-name-regexp s))
                               (not (string-suffix-p ".plist" s)) (not (drgnx-ai--secret-source-p s))))
              sources))

(defvar auth-sources)
(defvar auth-source-do-cache)
(declare-function auth-source-search "auth-source")
(declare-function auth-source-forget+ "auth-source")

(defun drgnx-ai-key (id &optional interactive)
  "The key of provider ID, or nil: its environment variable, else auth-source (host of its URL).  Only when
INTERACTIVE (a command the user ran) are sources that may prompt (.gpg files, the Keychain, the keyring) consulted;
the Keychain and the keyring only in an interactive Emacs, and the keyring only when a session bus can be reached
and a Secret Service answers on it (`drgnx-ai--secret-service-p').  A batch Emacs never opens them, but a `.gpg'
file it is asked to read may still ask for its passphrase on standard input.  With `auth-sources' nil an
interactive command still gets the system's store (the Keychain, the keyring).
auth-source's own cache is not used: it is keyed by the search alone, so a miss from a source that was left
out would hide the key for hours."
  (let ((p (drgnx-ai-provider id)))
    (or (and (plist-get p :key-env) (let ((v (getenv (plist-get p :key-env)))) (and v (not (string-empty-p v)) v)))
        (gethash id drgnx-ai--keys)
        (when-let* (((plist-get p :key-env))                    ; local runners have no key
                    (host (url-host (url-generic-parse-url (plist-get p :url)))))
          (require 'auth-source)
          (let* ((auth-sources (cond ((not interactive) (drgnx-ai--quiet-sources auth-sources))
                                     (noninteractive (seq-remove #'drgnx-ai--secret-source-p auth-sources))
                                     ((member (drgnx-ai--secret-source) auth-sources) auth-sources)
                                     ;; the keyring lives on the session bus: without one `default' only logs an error
                                     ((not (or (eq system-type 'darwin) (drgnx-ai--secret-service-p))) auth-sources)
                                     (t (append auth-sources (list (drgnx-ai--secret-source))))))
                 (auth-source-do-cache nil)
                 (found (and auth-sources (car (auth-source-search :host host :max 1 :create nil))))
                 (secret (plist-get found :secret))
                 (key (if (functionp secret) (funcall secret) secret)))
            (when key (puthash id key drgnx-ai--keys))
            key)))))

;;;; The editor's requests go through the hub's gateway (design call 15)

(defvar drgnx-ai-via-gateway t
  "Non-nil: a request to a provider with a `:key-env' goes to the hub's gateway (`/p/PROVIDER/…') with the editor
token, and the hub adds the key.  Keyless providers (local runners) always go direct.  Tests that need no hub bind it
nil.")

(define-error 'drgnx-ai-gateway-unavailable "drgnx hub is starting; try again")

(declare-function drgnx-hub-editor-token "drgnx-hub-client")
(declare-function drgnx-hub-keys-held "drgnx-hub-client")
(declare-function drgnx-hub-give-key "drgnx-hub-client")

(defun drgnx-ai--waits-p (interactive &optional waits)
  "Whether a request may wait for the hub: a command the user ran (INTERACTIVE, or WAITS: a caller that waits for
the answer anyway), or a batch process, never a daemon path."
  (and (not inhibit-interaction) (or interactive waits noninteractive) t))

(defun drgnx-ai-gateway-p (id)
  "Whether requests to provider ID go through the gateway: it has a key and `drgnx-ai-via-gateway' is on."
  (and drgnx-ai-via-gateway (plist-get (drgnx-ai-provider id) :key-env) t))

(defun drgnx-ai-gateway-credentials (&optional interactive waits)
  "(URL . TOKEN) for the gateway: the base address and the editor token.  INTERACTIVE as for `drgnx-ai-request'; a
command or batch process waits for the hub, a daemon path never does.  Signals `drgnx-ai-gateway-unavailable' when
there is no token yet."
  (require 'drgnx-hub-client)
  (let* ((why nil)
         (tok (condition-case e (drgnx-hub-editor-token (drgnx-ai--waits-p interactive waits))
                (error (setq why (error-message-string e)) nil))))
    (if tok (cons (or (let ((u (getenv "DRGNX_AI_GATEWAY_URL"))) (and u (not (string-empty-p u)) u)) (cdr tok)) (car tok))
      ;; waited and failed: the hub's reason; else it is on its way
      (if (and why (drgnx-ai--waits-p interactive waits)) (signal 'drgnx-ai-gateway-unavailable (list why))
        (signal 'drgnx-ai-gateway-unavailable nil)))))

(defun drgnx-ai-key-held-p (id &optional interactive)
  "Whether the key of provider ID is there to use: the hub holds it (`gateway/keys-held', kept up to date by
`gateway/keys-changed'), and before the hub has said, one this Emacs finds (`drgnx-ai-key').  For INTERACTIVE a
key found here that the hub does not hold counts too: the request hands it over."
  (require 'drgnx-hub-client)
  (let ((held (drgnx-hub-keys-held)))
    (if (and (drgnx-ai-gateway-p id) (not (eq held :unknown)))
        (or (and (member (symbol-name id) held) t)
            (and interactive (drgnx-ai-key id t) t))
      (and (drgnx-ai-key id interactive) t))))

(defun drgnx-ai-route (id &optional interactive waits)
  "Where and how to ask provider ID: (:url BASE :key KEY) — BASE the address `drgnx-ai--endpoint' appends its path to
\(the gateway's `/p/ID' for a provider with a key, else the provider's own URL), KEY the bearer token (the editor token,
or nil for a keyless provider) — or nil when the provider needs a key nobody has.  Signals
`drgnx-ai-gateway-unavailable' when the gateway has no token yet."
  (let ((p (drgnx-ai-provider id)))
    (cond ((not (plist-get p :key-env)) (list :url (plist-get p :url)))
          ((not drgnx-ai-via-gateway)
           (when-let* ((key (drgnx-ai-key id interactive))) (list :url (plist-get p :url) :key key)))
          (t
           ;; the token first: waiting for the hub also brings the list of the keys it holds
           (let* ((cred (drgnx-ai-gateway-credentials interactive waits))
                  (held (drgnx-hub-keys-held))
                  (there (and (listp held) (member (symbol-name id) held))))
             (when (or there
                       ;; a key found only here (a store that asks, a command the user ran) goes to the hub, once
                       (and interactive (let ((key (drgnx-ai-key id t))) (and key (progn (drgnx-hub-give-key id key) t))))
                       ;; the hub has not said yet: the hand-over carried the keys this Emacs holds
                       (and (eq held :unknown) (drgnx-ai-key id nil)))
               (list :url (format "%s/p/%s" (string-remove-suffix "/" (car cred)) id) :key (cdr cred))))))))

(defun drgnx-ai-load-keys ()
  "Read the keys of the providers the roles name, as a command does — the Keychain or the keyring may be asked
\(`drgnx-ai-key' with INTERACTIVE) — and keep them in memory, for the features that never ask: ghost text, the hub,
agents.  Returns the ids that have a key."
  (interactive)
  (let* ((ids (delete-dups (mapcar #'car (apply #'append (mapcar (lambda (r) (drgnx-ai-role (car r))) drgnx-ai-default-roles)))))
         (keyed (seq-filter (lambda (id) (plist-get (drgnx-ai-provider id) :key-env)) ids))
         (found (seq-filter (lambda (id) (drgnx-ai-key id t)) keyed))
         (missing (seq-difference keyed found)))
    (when (called-interactively-p 'interactive)
      (message "%s" (cond ((null keyed) "AI: no provider in your roles needs a key")
                          (t (string-join (delq nil (list (and found (format "AI keys loaded: %s" (mapconcat #'symbol-name found ", ")))
                                                          (and missing (format "no key found for %s (docs/guide/ai.md#keys)"
                                                                               (mapconcat #'symbol-name missing ", ")))))
                                          "; ")))))
    found))

(defvar drgnx-ai--keys-loading nil "Non-nil once `drgnx open' had this daemon load the keys (`drgnx-ai-load-keys-soon').")

(defun drgnx-ai-load-keys-soon ()
  "`drgnx open' (a command the user ran) calls this: `drgnx-ai-load-keys' once per daemon, from a timer a moment
later — after the window it opened shows, never inside its emacsclient call.  Never in batch."
  (unless (or noninteractive drgnx-ai--keys-loading)
    (setq drgnx-ai--keys-loading t)
    ;; the daemon's own, once, with no module or process to own it
    (drgnx-timer-start 'ai-load-keys 0.5 #'drgnx-ai--load-keys-timer :owner :core))
  nil)

(defun drgnx-ai--load-keys-timer ()
  "The timer function of `drgnx-ai-load-keys-soon'."
  (with-demoted-errors "drgnx: AI keys not loaded: %S" (drgnx-ai-load-keys)))

(defun drgnx-ai--stored-key (host)
  "What the secret store alone holds for HOST (a string), or nil; auth-source's cache is forgotten and not used."
  (require 'auth-source)
  (auth-source-forget+ :host host)
  (let* ((auth-sources (list (drgnx-ai--secret-source)))
         (auth-source-do-cache nil)
         (secret (plist-get (car (auth-source-search :host host :max 1 :create nil)) :secret)))
    (if (functionp secret) (funcall secret) secret)))

(defun drgnx-ai--dbus-session-p ()
  "Non-nil when a D-Bus session bus can be reached (the Secret Service lives on it)."
  (or (not (string-empty-p (or (getenv "DBUS_SESSION_BUS_ADDRESS") "")))
      (let ((run (getenv "XDG_RUNTIME_DIR"))) (and run (file-exists-p (expand-file-name "bus" run))))))

(defun drgnx-ai--secrets-usable-p ()
  "Non-nil when Emacs can talk to a Secret Service: built with D-Bus, and secrets.el loads with `secrets-enabled'
\(it pings the service once, with a short timeout).  Without these auth-source's `default' only logs an error."
  (and (featurep 'dbusbind) (require 'secrets nil t) (bound-and-true-p secrets-enabled) t))

(defun drgnx-ai--secret-service-p ()
  "Non-nil when the keyring can be searched: a session bus can be reached and a Secret Service answers on it."
  (and (drgnx-ai--dbus-session-p) (drgnx-ai--secrets-usable-p)))

(defvar drgnx-ai--security-program "/usr/bin/security"
  "The macOS Keychain tool, by its absolute name: a `security' elsewhere on `exec-path' never gets a key.")

(defvar drgnx-ai--store-timeout 120
  "Seconds to wait for the Keychain or keyring program (an unlock dialog can take a while).")

(defun drgnx-ai--run-with-stdin (program args input)
  "Run PROGRAM with ARGS, INPUT on its stdin through a pipe; its exit status, or `timeout'.
INPUT is never put in a buffer or a file (`call-process-region' would hand the child a temp file as stdin) and
the program's output is discarded."
  (let ((coding-system-for-write 'utf-8-unix) proc)
    (unwind-protect
        (progn
          (setq proc (make-process :name "drgnx-secret" :command (cons program args) :buffer nil
                                   :connection-type 'pipe :noquery t :filter #'ignore :sentinel #'ignore))
          (ignore-errors                ; a program that exits before reading all of it: its status says why
            (process-send-string proc input)
            (process-send-eof proc))
          (let ((deadline (+ (float-time) drgnx-ai--store-timeout)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (if (process-live-p proc) 'timeout (process-exit-status proc)))
      (when (process-live-p proc) (delete-process proc)))))

(defun drgnx-ai--security-quote (s)
  "S as one word for `security -i' (it splits like a shell): in double quotes, \\ and \" escaped."
  (concat "\"" (replace-regexp-in-string "[\\\"]" "\\\\\\&" s) "\""))

(defun drgnx-ai--security-call (args)
  "Run `drgnx-ai--security-program' with ARGS and an empty stdin, waiting at most `drgnx-ai--store-timeout'
seconds (\\[keyboard-quit] stops it): (STATUS . OUTPUT), STATUS its exit status or `timeout', OUTPUT its standard
output, gathered in a string (never a buffer); its standard error is discarded."
  (let ((coding-system-for-read 'utf-8-unix) (chunks nil) (out nil) err proc)
    (unwind-protect
        (progn
          (setq err (make-pipe-process :name "drgnx-secret-err" :buffer nil :noquery t :filter #'ignore :sentinel #'ignore))
          (setq proc (make-process :name "drgnx-secret" :command (cons drgnx-ai--security-program args) :buffer nil
                                   :connection-type 'pipe :noquery t :stderr err :sentinel #'ignore
                                   :filter (lambda (_ s) (push s chunks))))
          (ignore-errors (process-send-eof proc))
          (let ((deadline (+ (float-time) drgnx-ai--store-timeout)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (if (process-live-p proc) (list 'timeout)
            (cons (process-exit-status proc) (setq out (apply #'concat (reverse chunks))))))
      (dolist (c chunks) (unless (eq c out) (clear-string c)))   ; the caller clears OUTPUT
      (when (process-live-p proc) (delete-process proc))
      (when err (delete-process err)))))

(defun drgnx-ai--keychain-verify (host key env)
  "Read drgnx's Keychain item for HOST back with the same `security' program and compare it with KEY, showing
neither: `security -i''s exit status does not say how it parsed the line.  On anything but KEY itself (another
value, no item, an error, no answer, \\[keyboard-quit]) the item is deleted and a `user-error' names ENV as the way
around (a quit is signalled again after the delete).  No message holds the key or what came back."
  (let* ((item (list "-a" "drgnx" "-s" host "-r" "htps"))
         (delete (lambda () (eql 0 (car (ignore-errors (drgnx-ai--security-call (cons "delete-internet-password" item)))))))
         (read (condition-case nil (drgnx-ai--security-call (append '("find-internet-password") item '("-w")))
                 (quit (funcall delete) (signal 'quit nil))))
         (status (car read)) (back (cdr read)) (n (length key)))
    (unwind-protect
        (unless (and (eql status 0) back (= (length back) (1+ n)) (eq (aref back n) ?\n)
                     (eq t (compare-strings back 0 n key 0 n)))
          (let ((removed (funcall delete)))
            (user-error "%s, so %s. Store it again, or set %s instead"
                        (pcase status
                          ('timeout (format "The Keychain did not answer within %s seconds when drgnx read the key back"
                                            drgnx-ai--store-timeout))
                          (44 (format "The Keychain holds no drgnx item for %s after storing the key" host))
                          (_ "The Keychain did not give the key back as it was given"))
                        (cond (removed "drgnx removed it")
                              ((eql status 44) "no key was kept")
                              (t (format "remove the drgnx item for %s in Keychain Access" host)))
                        env)))
      (when back (clear-string back)))))

(defun drgnx-ai-store-key (id key)
  "Store KEY for provider ID in the system's secret store — the macOS Keychain or the Linux keyring — and return
`keychain' or `keyring'.  Only for a command the user ran, after asking: nowhere else does drgnx write a key.
The key travels on stdin (a pipe), never in a command line or a file; a key with a NUL, CR or LF is refused first.
Afterwards the store alone is asked for the key and it must match, else a `user-error'; on a Mac `security' itself
reads it back, and a Keychain item that does not match is deleted (`drgnx-ai--keychain-verify')."
  (let* ((p (drgnx-ai-provider id))
         (env (plist-get p :key-env))
         (host (and env (url-host (url-generic-parse-url (plist-get p :url)))))
         (mac (eq system-type 'darwin))
         (store (if mac "Keychain" "keyring"))
         (advice (format "Unlock %s, or set %s instead." (if mac "it in Keychain Access" "your keyring") env)))
    (unless host (user-error "Provider %s has no key to store" id))
    (when (or (not (stringp key)) (string-empty-p key) (string-match-p "[\0\n\r]" key))
      (user-error "The key is empty, has more than one line or holds a NUL character"))
    (cond
     (mac (unless (file-executable-p drgnx-ai--security-program)
            (user-error "No `security' program found: the macOS Keychain is needed to store a key")))
     ((not (executable-find "secret-tool"))
      (user-error "No `secret-tool' found: install libsecret-tools (Debian, Ubuntu), libsecret (Fedora, Arch) to store a key in your keyring"))
     ((not (drgnx-ai--dbus-session-p))
      (user-error "No D-Bus session: the keyring is unreachable here; set %s instead" env)))
    (let ((status (if mac
                      (drgnx-ai--run-with-stdin
                       drgnx-ai--security-program '("-i")
                       (format "add-internet-password -U -a drgnx -s %s -r htps -w %s\n"
                               (drgnx-ai--security-quote host) (drgnx-ai--security-quote key)))
                    (drgnx-ai--run-with-stdin
                     "secret-tool" (list "store" (format "--label=drgnx: %s" host) "host" host "service" "drgnx") key))))
      (cond ((eq status 'timeout)
             (user-error "The %s did not answer within %s seconds. %s" store drgnx-ai--store-timeout advice))
            ((not (eql status 0))
             (user-error "The %s refused the key (exit %s). %s" store status advice))))
    (remhash id drgnx-ai--keys)
    (if mac (drgnx-ai--keychain-verify host key env)
      ;; the store alone must hold this very key: not the environment, not another source's older one
      (let ((back (condition-case err (drgnx-ai--stored-key host)
                    (error (user-error "The key was stored, but the %s could not be read (%s). %s" store (car err) advice)))))
        (unless (equal back key)
          (user-error "The key was stored, but the %s did not give it back. %s" store advice))))
    (puthash id key drgnx-ai--keys)
    (if mac 'keychain 'keyring)))

;;;; Agent environments (agent profiles; M9b adds more kinds)

(defconst drgnx-ai-gateway-kinds '(claude-openrouter claude-ollama claude-anthropic claude-moonshot claude-deepseek)
  "Agent profile kinds whose traffic the agent gateway may carry (drgnx-gateway.el).")

(defun drgnx-ai-agent-gateway-chain (kind &optional model)
  "The providers ((PROVIDER . MODEL)…) an agent of KIND may use through the gateway, in order.  MODEL (the
profile's) names the model of the one provider of `claude-moonshot', `claude-deepseek' and `claude-openrouter';
`claude-openrouter' without it follows the `agent' role."
  (pcase kind
    ('claude-openrouter (if model (list (cons 'openrouter model)) (drgnx-ai-role 'agent)))
    ('claude-ollama '((ollama)))
    ('claude-anthropic '((anthropic)))
    ('claude-moonshot (list (cons 'moonshot model)))
    ('claude-deepseek (list (cons 'deepseek model)))))

(defun drgnx-ai--agent-bearer-env (id name interactive)
  "The environment of an agent on provider ID's own Anthropic-compatible API: its URL and its key as the bearer
token (`ANTHROPIC_AUTH_TOKEN'), `ANTHROPIC_API_KEY' empty.  NAME is how the error calls the provider."
  (let* ((p (drgnx-ai-provider id))
         (key (or (drgnx-ai-key id interactive)
                  (user-error "No %s key: set %s, or add one to auth-source for %s" name (plist-get p :key-env)
                              (url-host (url-generic-parse-url (plist-get p :url)))))))
    (list (concat "ANTHROPIC_BASE_URL=" (plist-get p :url)) (concat "ANTHROPIC_AUTH_TOKEN=" key) "ANTHROPIC_API_KEY=")))

(defun drgnx-ai-check-agent-model (kind model)
  "Signal a `user-error' when an agent of KIND needs a MODEL and has none: the vendors' own APIs
\(`claude-moonshot', `claude-deepseek') do not know Claude Code's default model names."
  (when (and (memq kind '(claude-moonshot claude-deepseek)) (not (and (stringp model) (not (string-empty-p model)))))
    (user-error "The %s agent profile needs a :model (the vendor's model name)" kind)))

(defun drgnx-ai-agent-env (profile &optional interactive gateway)
  "The environment (\"NAME=value\"…) an agent of PROFILE (:kind …, :model …, :small-model …) starts with,
resolved now.  GATEWAY (:url :token): the agent talks to the gateway with its token, and never sees a key.  With a
:model every route also names it for Claude Code's main, Sonnet, Opus and subagent models, and :small-model (else the
:model) for the small background one: `ANTHROPIC_MODEL', `ANTHROPIC_DEFAULT_SONNET_MODEL',
`ANTHROPIC_DEFAULT_OPUS_MODEL', `CLAUDE_CODE_SUBAGENT_MODEL', `ANTHROPIC_DEFAULT_HAIKU_MODEL' (Claude Code's
current variable; `ANTHROPIC_SMALL_FAST_MODEL' is deprecated).  A subscription CLI gets nothing: it uses its own
login, which drgnx never reads."
  (drgnx-ai-check-agent-model (plist-get profile :kind) (plist-get profile :model))
  (let ((env (drgnx-ai--agent-route-env profile interactive gateway))
        (model (plist-get profile :model)))
    (if (and env (stringp model))
        (append env (mapcar (lambda (name) (concat name "=" model))
                            '("ANTHROPIC_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL"
                              "CLAUDE_CODE_SUBAGENT_MODEL"))
                (list (concat "ANTHROPIC_DEFAULT_HAIKU_MODEL=" (or (plist-get profile :small-model) model))))
      env)))

(defun drgnx-ai--agent-route-env (profile interactive gateway)
  "`drgnx-ai-agent-env' without the model variables."
  (pcase (plist-get profile :kind)
    ((and kind (guard gateway) (guard (memq kind drgnx-ai-gateway-kinds)))
     (list (concat "ANTHROPIC_BASE_URL=" (plist-get gateway :url)) (concat "ANTHROPIC_AUTH_TOKEN=" (plist-get gateway :token))
           "ANTHROPIC_API_KEY="))
    ('claude-anthropic
     (list (concat "ANTHROPIC_API_KEY="
                   (or (drgnx-ai-key 'anthropic interactive)
                       (user-error "No Anthropic API key: set ANTHROPIC_API_KEY, or add one to auth-source for api.anthropic.com")))))
    ('claude-openrouter
     (let ((key (or (drgnx-ai-key 'openrouter interactive)
                    (user-error "No OpenRouter key: set OPENROUTER_API_KEY, or add one to auth-source for openrouter.ai"))))
       (list "ANTHROPIC_BASE_URL=https://openrouter.ai/api" (concat "ANTHROPIC_AUTH_TOKEN=" key) "ANTHROPIC_API_KEY=")))
    ('claude-ollama
     (list (concat "ANTHROPIC_BASE_URL=" (plist-get (drgnx-ai-provider 'ollama) :url)) "ANTHROPIC_AUTH_TOKEN=ollama" "ANTHROPIC_API_KEY="))
    ('claude-moonshot (drgnx-ai--agent-bearer-env 'moonshot "Moonshot" interactive))
    ('claude-deepseek (drgnx-ai--agent-bearer-env 'deepseek "DeepSeek" interactive))
    (_ nil)))

;;;; Choosing (written to ai.eld: providers and models, never a key)

(defun drgnx-ai-set-role (role chain)
  "Make CHAIN ((PROVIDER . MODEL)…) ROLE's in the user's ai.eld; everything else in it stays.  An ai.eld that
has a mistake, or was written by a newer drgnx, is never replaced: the error (`drgnx-config-refused') says so."
  (drgnx-config-update 'ai
                       (lambda (conf)
                         (let ((roles (plist-get conf :roles)))
                           (setf (alist-get role roles) chain)
                           (plist-put conf :roles roles)))))

;;;; gptel (the chat UI) from the registry

(declare-function gptel-make-openai "gptel-openai")
(declare-function gptel-make-ollama "gptel-ollama")
(defvar gptel-backend)
(defvar gptel-model)

(defun drgnx-ai-gptel-spec (id model)
  "How to make provider ID's gptel backend for MODEL: (FUNCTION NAME . ARGS).  A key is a function asked
when gptel sends, never a stored string."
  (let* ((p (drgnx-ai-provider id))
         (gateway (and (drgnx-ai-gateway-p id) (drgnx-ai-gateway-credentials)))   ; signals when the hub has no token yet
         (u (url-generic-parse-url (if gateway (format "%s/p/%s" (string-remove-suffix "/" (car gateway)) id) (plist-get p :url))))
         (host (if (url-portspec u) (format "%s:%d" (url-host u) (url-portspec u)) (url-host u)))
         (path (string-remove-suffix "/" (or (url-filename u) "")))
         (name (or (plist-get p :name) (symbol-name id))))
    (pcase (plist-get p :kind)
      ('ollama (list 'gptel-make-ollama name :host host :protocol (url-type u) :models (list (intern model)) :stream t))
      (kind (append (list 'gptel-make-openai name :host host :protocol (url-type u)
                          :endpoint (concat (if (eq kind 'llamacpp) (concat path "/v1") path) "/chat/completions")
                          :models (list (intern model)) :stream t)
                    (cond (gateway (list :key (lambda () (cdr (drgnx-ai-gateway-credentials t)))))
                          ((plist-get p :key-env) (list :key (lambda () (drgnx-ai-key id t))))))))))

(defvar drgnx-ai--gptel-ours nil "The gptel backend drgnx made last.")
(defvar gptel--openai)
(defvar gptel-api-key)

(defun drgnx-ai-gptel-maybe-configure (usable-p)
  "Point gptel at the `chat' role's first provider USABLE-P accepts — unless the user chose a backend of their
own (only gptel's default, none, or the one drgnx made is replaced; gptel's default with a `gptel-api-key' the
user set is theirs).  Returns the step, or nil."
  (when (or (not (boundp 'gptel-backend)) (null gptel-backend) (eq gptel-backend drgnx-ai--gptel-ours)
            (and (boundp 'gptel--openai) (eq gptel-backend gptel--openai)
                 ;; gptel's own default for the key is a function that asks auth-source: nobody's choice
                 (or (not (boundp 'gptel-api-key)) (null gptel-api-key)
                     (eq gptel-api-key 'gptel-api-key-from-auth-source))))
    (when-let* ((step (drgnx-ai-gptel-configure usable-p)))
      (setq drgnx-ai--gptel-ours gptel-backend)
      step)))

(defun drgnx-ai-gptel-configure (usable-p)
  "Point gptel at the first provider of the `chat' role USABLE-P accepts.  Returns it, or nil."
  (when-let* ((step (seq-find (lambda (s) (funcall usable-p (car s))) (drgnx-ai-role 'chat)))
              ;; the gateway's address comes with the hub's token: not yet (nil), and gptel is set up when it arrives
              (spec (condition-case nil (drgnx-ai-gptel-spec (car step) (cdr step)) (drgnx-ai-gateway-unavailable nil))))
    ;; `gptel' alone does not load the backend makers (they are autoloads, absent without package.el)
    (unless (fboundp (car spec)) (require (if (eq (car spec) 'gptel-make-ollama) 'gptel-ollama 'gptel-openai)))
    (setq gptel-backend (apply (car spec) (cdr spec))
          gptel-model (intern (cdr step)))
    step))

(provide 'drgnx-ai)
;;; drgnx-ai.el ends here
