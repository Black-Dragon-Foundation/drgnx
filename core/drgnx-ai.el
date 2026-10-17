;;; drgnx-ai.el --- The AI provider registry: providers, roles, keys, agent environments -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One registry for every AI feature — ghost text, inline edit, chat (gptel), embeddings, agents.  Providers are
;; presets for OpenRouter and the local runners, plus the user's (ai.eld in the config dir) and the project's
;; (.drgnx/ai.eld); roles (complete, edit, chat, embed, agent) are fallback chains of (PROVIDER . MODEL).
;; Keys come from where the user keeps them — the environment, then auth-source — when they are needed; drgnx
;; never writes one, never puts one in a command line, a log or a file.  Subscription CLIs (Claude Code, Codex)
;; are only launched: their logins are theirs.  See docs/guide/ai.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'drgnx-paths)

(defconst drgnx-ai-presets
  '((openrouter :name "OpenRouter" :kind openai :url "https://openrouter.ai/api/v1" :key-env "OPENROUTER_API_KEY"
                :caps (chat fim embed) :messages t)
    (ollama     :name "Ollama" :kind ollama :url "http://127.0.0.1:11434" :caps (chat fim embed) :messages t)
    ;; the agent gateway only (Claude Code with your own Anthropic API key): no editor feature asks it
    (anthropic  :name "Anthropic API" :kind anthropic :url "https://api.anthropic.com/v1" :key-env "ANTHROPIC_API_KEY"
                :auth x-api-key :caps () :messages t)
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

(defvar drgnx-ai--keys (make-hash-table :test #'eq) "Keys found this session: provider → key (never written).")

;;;; Configuration

(defun drgnx-ai-file () (expand-file-name "ai.eld" (drgnx-user-dir)))

(defvar drgnx-ai--read-cache (make-hash-table :test #'equal)
  "FILE → (MTIME . FORM): ai.eld files are read again only when they change (ghost text asks on every pause).")

(defun drgnx-ai--read (file)
  "FILE's form, or nil when FILE is missing; `drgnx-ai-unreadable' when it exists but does not read."
  (let* ((attrs (and file (file-attributes file)))
         (mtime (and attrs (list (file-attribute-modification-time attrs) (file-attribute-size attrs)))))
    (if (not mtime) (progn (remhash file drgnx-ai--read-cache) nil)
      (let ((hit (gethash file drgnx-ai--read-cache)))
        (if (and hit (equal (car hit) mtime)) (cdr hit)
          (let ((form (condition-case nil
                          (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
                        (error 'drgnx-ai-unreadable))))
            (puthash file (cons mtime form) drgnx-ai--read-cache)
            form))))))

(defun drgnx-ai--config (file)
  "FILE's configuration plist, nil when it is missing or does not read."
  (let ((c (drgnx-ai--read file))) (and (consp c) c)))

(defun drgnx-ai--project-file ()
  "The project's .drgnx/ai.eld; never looked for on a remote directory (a timer asks: no remote round-trips)."
  (unless (file-remote-p default-directory)
    (when-let* ((dir (locate-dominating-file default-directory ".drgnx/ai.eld")))
      (expand-file-name ".drgnx/ai.eld" dir))))

(defun drgnx-ai-providers ()
  "Every provider: the presets, then the user's ai.eld (an entry replaces a preset with its id).  A project's
ai.eld never adds or changes one: a cloned repository must not choose where your code and keys go."
  (let ((ps (copy-sequence drgnx-ai-presets)))
    (dolist (p (plist-get (drgnx-ai--config (drgnx-ai-file)) :providers))
      (setq ps (cons p (assq-delete-all (car p) ps))))
    ps))

(defun drgnx-ai-provider (id) (alist-get id (drgnx-ai-providers)))

(defun drgnx-ai-role (role)
  "ROLE's chain ((PROVIDER . MODEL)…): the project's, else the user's, else the default."
  (or (alist-get role (plist-get (drgnx-ai--config (drgnx-ai--project-file)) :roles))
      (alist-get role (plist-get (drgnx-ai--config (drgnx-ai-file)) :roles))
      (alist-get role drgnx-ai-default-roles)))

;;;; Keys

(defun drgnx-ai--quiet-sources (sources)
  "SOURCES that can be read without asking anything: plain files (a .gpg file or a keyring may prompt)."
  (seq-filter (lambda (s) (and (stringp s) (not (string-suffix-p ".gpg" s)))) sources))

(defvar auth-sources)
(declare-function auth-source-search "auth-source")

(defun drgnx-ai-key (id &optional interactive)
  "The key of provider ID, or nil: its environment variable, else auth-source (host of its URL).  Only when
INTERACTIVE (a command the user ran) are sources that may prompt (.gpg files, keyrings) consulted."
  (let ((p (drgnx-ai-provider id)))
    (or (and (plist-get p :key-env) (let ((v (getenv (plist-get p :key-env)))) (and v (not (string-empty-p v)) v)))
        (gethash id drgnx-ai--keys)
        (when-let* (((plist-get p :key-env))                    ; local runners have no key
                    (host (url-host (url-generic-parse-url (plist-get p :url)))))
          (require 'auth-source)
          (let* ((auth-sources (if interactive auth-sources (drgnx-ai--quiet-sources auth-sources)))
                 (found (and auth-sources (car (auth-source-search :host host :max 1 :create nil))))
                 (secret (plist-get found :secret))
                 (key (if (functionp secret) (funcall secret) secret)))
            (when key (puthash id key drgnx-ai--keys))
            key)))))

;;;; Agent environments (agent profiles; M9b adds more kinds)

(defconst drgnx-ai-gateway-kinds '(claude-openrouter claude-ollama claude-anthropic)
  "Agent profile kinds whose traffic the agent gateway may carry (drgnx-gateway.el).")

(defun drgnx-ai-agent-gateway-chain (kind)
  "The providers ((PROVIDER . MODEL)…) an agent of KIND may use through the gateway, in order."
  (pcase kind
    ('claude-openrouter (drgnx-ai-role 'agent))
    ('claude-ollama '((ollama)))
    ('claude-anthropic '((anthropic)))))

(defun drgnx-ai-agent-env (profile &optional interactive gateway)
  "The environment (\"NAME=value\"…) an agent of PROFILE (:kind …) starts with, resolved now.  GATEWAY (:url :token):
the agent talks to the gateway with its token, and never sees a key.  A subscription CLI gets nothing: it uses its
own login, which drgnx never reads."
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
    (_ nil)))

;;;; Choosing (written to ai.eld: providers and models, never a key)

(defun drgnx-ai-set-role (role chain)
  "Make CHAIN ((PROVIDER . MODEL)…) ROLE's in the user's ai.eld; everything else in it stays.  An ai.eld that
does not read is never replaced: the error says so."
  (let* ((file (drgnx-ai-file))
         (read (drgnx-ai--read file))
         (conf (cond ((eq read 'drgnx-ai-unreadable)
                      (user-error "%s does not read: fix it first (nothing was written)" (abbreviate-file-name file)))
                     ((consp read) read)
                     (t (list :version 1))))
         (roles (plist-get conf :roles)))
    (setf (alist-get role roles) chain)
    (setq conf (plist-put conf :roles roles))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; drgnx AI providers and roles (docs/guide/ai.md) — never a key here\n")
      (let ((print-length nil) (print-level nil)) (pp conf (current-buffer))))))

;;;; gptel (the chat UI) from the registry

(declare-function gptel-make-openai "gptel-openai")
(declare-function gptel-make-ollama "gptel-ollama")
(defvar gptel-backend)
(defvar gptel-model)

(defun drgnx-ai-gptel-spec (id model)
  "How to make provider ID's gptel backend for MODEL: (FUNCTION NAME . ARGS).  A key is a function asked
when gptel sends, never a stored string."
  (let* ((p (drgnx-ai-provider id))
         (u (url-generic-parse-url (plist-get p :url)))
         (host (if (url-portspec u) (format "%s:%d" (url-host u) (url-portspec u)) (url-host u)))
         (path (string-remove-suffix "/" (or (url-filename u) "")))
         (name (or (plist-get p :name) (symbol-name id))))
    (pcase (plist-get p :kind)
      ('ollama (list 'gptel-make-ollama name :host host :protocol (url-type u) :models (list (intern model)) :stream t))
      (kind (append (list 'gptel-make-openai name :host host :protocol (url-type u)
                          :endpoint (concat (if (eq kind 'llamacpp) (concat path "/v1") path) "/chat/completions")
                          :models (list (intern model)) :stream t)
                    (and (plist-get p :key-env) (list :key (lambda () (drgnx-ai-key id t)))))))))

(defvar drgnx-ai--gptel-ours nil "The gptel backend drgnx made last.")
(defvar gptel--openai)

(defun drgnx-ai-gptel-maybe-configure (usable-p)
  "Point gptel at the `chat' role's first provider USABLE-P accepts — unless the user chose a backend of their
own (only gptel's default, none, or the one drgnx made is replaced).  Returns the step, or nil."
  (when (or (not (boundp 'gptel-backend)) (null gptel-backend) (eq gptel-backend drgnx-ai--gptel-ours)
            (and (boundp 'gptel--openai) (eq gptel-backend gptel--openai)))
    (when-let* ((step (drgnx-ai-gptel-configure usable-p)))
      (setq drgnx-ai--gptel-ours gptel-backend)
      step)))

(defun drgnx-ai-gptel-configure (usable-p)
  "Point gptel at the first provider of the `chat' role USABLE-P accepts.  Returns it, or nil."
  (when-let* ((step (seq-find (lambda (s) (funcall usable-p (car s))) (drgnx-ai-role 'chat))))
    (let ((spec (drgnx-ai-gptel-spec (car step) (cdr step))))
      ;; `gptel' alone does not load the backend makers (they are autoloads, absent without package.el)
      (unless (fboundp (car spec)) (require (if (eq (car spec) 'gptel-make-ollama) 'gptel-ollama 'gptel-openai)))
      (setq gptel-backend (apply (car spec) (cdr spec))
            gptel-model (intern (cdr step)))
      step)))

(provide 'drgnx-ai)
;;; drgnx-ai.el ends here
