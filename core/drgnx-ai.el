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

(provide 'drgnx-ai)
;;; drgnx-ai.el ends here
