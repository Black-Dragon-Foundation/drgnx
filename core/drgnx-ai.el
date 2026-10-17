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
                :caps (chat fim embed))
    (ollama     :name "Ollama" :kind ollama :url "http://localhost:11434" :caps (chat fim embed))
    (lmstudio   :name "LM Studio" :kind openai :url "http://localhost:1234/v1" :caps (chat fim embed))
    (llamacpp   :name "llama.cpp server" :kind llamacpp :url "http://localhost:8012" :caps (chat fim embed))   ; its 8080 is TEI's
    (vllm       :name "vLLM" :kind openai :url "http://localhost:8000/v1" :caps (chat fim embed))
    (jan        :name "Jan" :kind openai :url "http://localhost:1337/v1" :caps (chat))
    (localai    :name "LocalAI" :kind openai :url "http://localhost:8090/v1" :caps (chat fim embed))
    (koboldcpp  :name "KoboldCpp" :kind openai :url "http://localhost:5001/v1" :caps (chat fim))
    (tabbyapi   :name "TabbyAPI / text-generation-webui" :kind openai :url "http://localhost:5000/v1" :caps (chat fim))
    (gpt4all    :name "GPT4All" :kind openai :url "http://localhost:4891/v1" :caps (chat))
    (lemonade   :name "Lemonade" :kind openai :url "http://localhost:13305/api/v1" :caps (chat fim embed))
    (llamafile  :name "llamafile" :kind openai :url "http://localhost:8081/v1" :caps (chat fim))       ; its 8080 is TEI's
    (tei        :name "Text Embeddings Inference" :kind tei :url "http://localhost:8080" :caps (embed)))
  "The providers drgnx knows without configuration: id → (:name :kind :url [:key-env] :caps).")

(defconst drgnx-ai-default-roles
  '((complete (ollama . "qwen2.5-coder:1.5b"))           ; fits next to TEI on a 6 GB GPU
    (edit (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
    (chat (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
    (embed (tei)))
  "Each role's chain when neither the project nor the user names one.")

(defvar drgnx-ai--keys (make-hash-table :test #'eq) "Keys found this session: provider → key (never written).")

;;;; Configuration

(defun drgnx-ai-file () (expand-file-name "ai.eld" (drgnx-user-dir)))

(defun drgnx-ai--read (file)
  (and file (file-readable-p file)
       (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun drgnx-ai--project-file ()
  (when-let* ((dir (locate-dominating-file default-directory ".drgnx/ai.eld")))
    (expand-file-name ".drgnx/ai.eld" dir)))

(defun drgnx-ai--configs ()
  "The user's and the project's ai.eld (project last: it wins)."
  (delq nil (list (drgnx-ai--read (drgnx-ai-file)) (drgnx-ai--read (drgnx-ai--project-file)))))

(defun drgnx-ai-providers ()
  "Every provider: the presets, then the user's and the project's (a later entry replaces one with its id)."
  (let ((ps (copy-sequence drgnx-ai-presets)))
    (dolist (c (drgnx-ai--configs))
      (dolist (p (plist-get c :providers))
        (setq ps (cons p (assq-delete-all (car p) ps)))))
    ps))

(defun drgnx-ai-provider (id) (alist-get id (drgnx-ai-providers)))

(defun drgnx-ai-role (role)
  "ROLE's chain ((PROVIDER . MODEL)…): the project's, else the user's, else the default."
  (or (seq-some (lambda (c) (alist-get role (plist-get c :roles))) (reverse (drgnx-ai--configs)))
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

(defun drgnx-ai-agent-env (profile &optional interactive)
  "The environment (\"NAME=value\"…) an agent of PROFILE (:kind …) starts with, resolved now.  A subscription
CLI gets nothing: it uses its own login, which drgnx never reads."
  (pcase (plist-get profile :kind)
    ('claude-openrouter
     (let ((key (or (drgnx-ai-key 'openrouter interactive)
                    (user-error "No OpenRouter key: set OPENROUTER_API_KEY, or add one to auth-source for openrouter.ai"))))
       (list "ANTHROPIC_BASE_URL=https://openrouter.ai/api" (concat "ANTHROPIC_AUTH_TOKEN=" key) "ANTHROPIC_API_KEY=")))
    ('claude-ollama
     (list (concat "ANTHROPIC_BASE_URL=" (plist-get (drgnx-ai-provider 'ollama) :url)) "ANTHROPIC_AUTH_TOKEN=ollama" "ANTHROPIC_API_KEY="))
    (_ nil)))

;;;; Choosing (written to ai.eld: providers and models, never a key)

(defun drgnx-ai-set-role (role chain)
  "Make CHAIN ((PROVIDER . MODEL)…) ROLE's in the user's ai.eld; everything else in it stays."
  (let* ((file (drgnx-ai-file))
         (conf (or (drgnx-ai--read file) (list :version 1)))
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
      (setq gptel-backend (apply (car spec) (cdr spec))
            gptel-model (intern (cdr step)))
      step)))

(provide 'drgnx-ai)
;;; drgnx-ai.el ends here
