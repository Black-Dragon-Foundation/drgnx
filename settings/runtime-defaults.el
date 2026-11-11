;;; runtime-defaults.el --- what drgnx ships for the runtime settings  -*- lexical-binding: t; mode: lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Data, in the settings format.  Never `load'ed: Lisp reads it with the data reader (`drgnx-settings-defaults-value'),
;; and the hub embeds the same file.  It holds:
;; - `drgnx-ai-presets', `drgnx-ai-default-roles' and `drgnx-agents-builtin-profiles', which the three constants of
;;   the same names take their values from;
;; - the strict default of every `:on-error strict' setting: what the runtime uses when settings.el does not read.
;; Change a value here, not in the Lisp (docs/develop/settings.md, "Declaring a setting").
(drgnx-settings
 :version 1

 ;; Providers drgnx knows without configuration: id → (:name :kind :url [:key-env] :caps [:messages] [:auth]).
 ;; :messages — it serves Anthropic's Messages API (URL without /v1, then the agent's path): the agent gateway can
 ;; carry it; :auth x-api-key — its key goes in that header (else `Authorization: Bearer').  A provider in the
 ;; user's `drgnx-ai-providers' may add :price (IN . OUT), USD per million tokens, for the gateway's spend.
 (drgnx-ai-presets
  ((openrouter :name "OpenRouter" :kind openai :url "https://openrouter.ai/api/v1" :key-env "OPENROUTER_API_KEY"
               :caps (chat fim embed) :messages t)
   (ollama :name "Ollama" :kind ollama :url "http://127.0.0.1:11434" :caps (chat fim embed) :messages t)
   ;; the agent gateway only (Claude Code with your own Anthropic API key): no editor feature asks it
   (anthropic :name "Anthropic API" :kind anthropic :url "https://api.anthropic.com/v1" :key-env "ANTHROPIC_API_KEY"
              :auth x-api-key :caps () :messages t)
   ;; Kimi and DeepSeek on their own Anthropic-compatible APIs, for their own agents (Kimi Code, DeepSeek Harness)
   ;; through the gateway; Bearer, as both vendors' guides have it
   (moonshot :name "Moonshot (Kimi)" :kind anthropic :url "https://api.moonshot.ai/anthropic" :key-env "MOONSHOT_API_KEY"
             :caps () :messages t)
   (deepseek :name "DeepSeek" :kind anthropic :url "https://api.deepseek.com/anthropic" :key-env "DEEPSEEK_API_KEY"
             :caps () :messages t)
   (lmstudio :name "LM Studio" :kind openai :url "http://127.0.0.1:1234/v1" :caps (chat fim embed))
   (llamacpp :name "llama.cpp server" :kind llamacpp :url "http://127.0.0.1:8012" :caps (chat fim embed)) ; its 8080 is TEI's
   (vllm :name "vLLM" :kind openai :url "http://127.0.0.1:8000/v1" :caps (chat fim embed))
   (jan :name "Jan" :kind openai :url "http://127.0.0.1:1337/v1" :caps (chat))
   (localai :name "LocalAI" :kind openai :url "http://127.0.0.1:8090/v1" :caps (chat fim embed))
   (koboldcpp :name "KoboldCpp" :kind openai :url "http://127.0.0.1:5001/v1" :caps (chat fim))
   (tabbyapi :name "TabbyAPI / text-generation-webui" :kind openai :url "http://127.0.0.1:5000/v1" :caps (chat fim))
   (gpt4all :name "GPT4All" :kind openai :url "http://127.0.0.1:4891/v1" :caps (chat))
   (lemonade :name "Lemonade" :kind openai :url "http://127.0.0.1:13305/api/v1" :caps (chat fim embed))
   (llamafile :name "llamafile" :kind openai :url "http://127.0.0.1:8081/v1" :caps (chat fim)) ; its 8080 is TEI's
   (tei :name "Text Embeddings Inference" :kind tei :url "http://127.0.0.1:8080" :caps (embed))))

 ;; Each role's chain when neither the project nor the user names one.
 (drgnx-ai-default-roles
  ((complete (ollama . "qwen2.5-coder:1.5b")) ; fits next to TEI on a 6 GB GPU
   (edit (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
   (chat (openrouter . "openrouter/auto") (ollama . "qwen2.5-coder:7b"))
   (embed (tei))
   (agent (openrouter)))) ; the gateway's chain for agents; nil model: the agent's own

 ;; Profiles drgnx offers without setup; :ai names the provider environment the agent gets when it starts
 ;; (`drgnx-ai-agent-env'); :job-safe, that a job may run it (`drgnx-job-safe-p': Claude Code, whose job sessions
 ;; ignore a repository's own settings).  A vendor with an agent of its own runs that agent (Kimi Code, DeepSeek
 ;; Harness), never Claude Code on the vendor's endpoint; Claude Code on a model that is not Claude gets no tool search,
 ;; which such models do not speak.
 (drgnx-agents-builtin-profiles
  (("claude" :command ("claude-agent-acp") :mode queue :job-safe t
    :doc "Claude through the unmodified agent (subscription or API key)")
   ("claude (OpenRouter)" :command ("claude-agent-acp") :mode queue :job-safe t :ai claude-openrouter
    :doc "Claude Code on OpenRouter (your OpenRouter key, from the environment or auth-source)")
   ("claude (Ollama)" :command ("claude-agent-acp") :env ("ENABLE_TOOL_SEARCH=false") :mode queue :job-safe t
    :ai claude-ollama
    :doc "Claude Code on a local Ollama model")
   ("kimi" :command ("kimi" "acp") :mode queue :provider kimi :ai kimi-moonshot :model "kimi-k3"
    :doc "Kimi Code, Moonshot's own agent, on Kimi through Moonshot's API (MOONSHOT_API_KEY or auth-source for api.moonshot.ai; billed per token by Moonshot)")
   ("deepseek" :command ("dsh" "--profile" "acp") :mode queue :provider deepseek :ai dsh-deepseek
    :model "deepseek-v4-pro"
    :doc "DeepSeek Harness, DeepSeek's own agent, on DeepSeek through its API (DEEPSEEK_API_KEY or auth-source for api.deepseek.com; billed per token by DeepSeek)")
   ("claude (Kimi via OpenRouter)" :command ("claude-agent-acp") :env ("ENABLE_TOOL_SEARCH=false") :mode queue
    :job-safe t :ai claude-openrouter :model "moonshotai/kimi-k3"
    :doc "Claude Code on Kimi through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)")
   ("claude (DeepSeek via OpenRouter)" :command ("claude-agent-acp") :env ("ENABLE_TOOL_SEARCH=false") :mode queue
    :job-safe t :ai claude-openrouter :model "deepseek/deepseek-v4-pro"
    :doc "Claude Code on DeepSeek through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)")))

 ;; The strict defaults: every `:on-error strict' setting, the value the runtime uses when settings.el does not read.
 (drgnx-agents-profiles nil)
 (drgnx-agents-default nil)
 (drgnx-agents-mcp (coordination))
 (drgnx-agents-routes nil)
 (drgnx-agents-openrouter nil)
 (drgnx-agents-allow-unsandboxed nil)
 (drgnx-agents-start-env-names nil)
 (drgnx-agents-trace-opens ("claude"))
 (drgnx-agents-matrix (:preset balanced))
 (drgnx-agents-away-after 600)
 (drgnx-agents-wait-refusals 3)
 (drgnx-agents-close-idle-after 1800)
 (drgnx-agents-checkpoint-cap 2147483648)
 (drgnx-agents-job-memory "4G")
 (drgnx-agents-job-cpus 2)
 (drgnx-agents-net-hosts ((packages "crates.io:443" "index.crates.io:443" "static.crates.io:443"
                                    "registry.npmjs.org:443" "pypi.org:443" "files.pythonhosted.org:443")))
 (drgnx-agents-container-images nil)
 (drgnx-agents-silent-after ((task . 600) (brainstorm . 1800)))
 (drgnx-agents-repeat-limit 3)
 (drgnx-agents-no-progress-tokens 20000)
 (drgnx-agents-manager-context 0.7)
 (drgnx-agents-model-prices
  (("claude-fable-5-1" :in 10 :out 50 :cache-read 0.25 :write-5m 12.5 :write-1h 20 :as-of "2026-11-01")
   ("claude-opus-5-5" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01")
   ("claude-sonnet-5-5" :in 2 :out 10 :cache-read 0.1 :write-5m 2.5 :write-1h 4 :as-of "2026-11-01")
   ("claude-haiku-5-5" :in 0.5 :out 2.5 :cache-read 0.05 :write-5m 0.625 :write-1h 1 :as-of "2026-11-01")
   ("claude" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01")))
 (drgnx-agents-browser-program nil)
 (drgnx-agents-browser-local-ports (3000 3001 4173 4200 5000 5173 8000 8080 8888))
 (drgnx-agents-browser-deny-hosts nil)
 (drgnx-agents-browser-max-message 67108864)
 (drgnx-agents-browser-idle 600)
 (drgnx-agents-browser-once-window 600)
 (drgnx-agents-session-memory "4G")
 (drgnx-agents-browser-memory-high 75)
 (drgnx-runners-send "heavy")
 (drgnx-runners-heavy nil)
 (drgnx-runners-image nil)
 (drgnx-runners-weight 1.0)
 (drgnx-runners-project-visibility "private")
 (drgnx-runners-shared-overlay nil)
 (drgnx-runners-job-keys nil)
 (drgnx-runners-mac-tools nil)
 (drgnx-runners-mac-toolchains nil)
 (drgnx-runners-origin-key nil)
 (drgnx-search-model-mirror nil)
 (drgnx-search-builtin t)
 (drgnx-search-include nil)
 (drgnx-search-exclude nil)
 (drgnx-search-off nil)
 (drgnx-search-base nil)
 (drgnx-search-ignore-rules "index")
 (drgnx-agents-plugins nil)
 (drgnx-agents-hook-rules nil)
 (drgnx-agents-hook-rules-off nil))
