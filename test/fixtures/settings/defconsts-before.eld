;; The three defconsts of drgnx-ai.el and drgnx-agents.el as they were before agents.eld and ai.eld folded into
;; settings (Task 15): ((NAME . VALUE)…).  test/unit/settings-defaults-test.el compares them with
;; settings/runtime-defaults.el.
((drgnx-ai-presets
  (openrouter :name "OpenRouter" :kind openai :url
	      "https://openrouter.ai/api/v1" :key-env
	      "OPENROUTER_API_KEY" :caps (chat fim embed) :messages t)
  (ollama :name "Ollama" :kind ollama :url "http://127.0.0.1:11434"
	  :caps (chat fim embed) :messages t)
  (anthropic :name "Anthropic API" :kind anthropic :url
	     "https://api.anthropic.com/v1" :key-env
	     "ANTHROPIC_API_KEY" :auth x-api-key :caps nil :messages t)
  (moonshot :name "Moonshot (Kimi)" :kind anthropic :url
	    "https://api.moonshot.ai/anthropic" :key-env
	    "MOONSHOT_API_KEY" :caps nil :messages t)
  (deepseek :name "DeepSeek" :kind anthropic :url
	    "https://api.deepseek.com/anthropic" :key-env
	    "DEEPSEEK_API_KEY" :caps nil :messages t)
  (lmstudio :name "LM Studio" :kind openai :url
	    "http://127.0.0.1:1234/v1" :caps (chat fim embed))
  (llamacpp :name "llama.cpp server" :kind llamacpp :url
	    "http://127.0.0.1:8012" :caps (chat fim embed))
  (vllm :name "vLLM" :kind openai :url "http://127.0.0.1:8000/v1"
	:caps (chat fim embed))
  (jan :name "Jan" :kind openai :url "http://127.0.0.1:1337/v1" :caps
       (chat))
  (localai :name "LocalAI" :kind openai :url
	   "http://127.0.0.1:8090/v1" :caps (chat fim embed))
  (koboldcpp :name "KoboldCpp" :kind openai :url
	     "http://127.0.0.1:5001/v1" :caps (chat fim))
  (tabbyapi :name "TabbyAPI / text-generation-webui" :kind openai :url
	    "http://127.0.0.1:5000/v1" :caps (chat fim))
  (gpt4all :name "GPT4All" :kind openai :url
	   "http://127.0.0.1:4891/v1" :caps (chat))
  (lemonade :name "Lemonade" :kind openai :url
	    "http://127.0.0.1:13305/api/v1" :caps (chat fim embed))
  (llamafile :name "llamafile" :kind openai :url
	     "http://127.0.0.1:8081/v1" :caps (chat fim))
  (tei :name "Text Embeddings Inference" :kind tei :url
       "http://127.0.0.1:8080" :caps (embed)))
 (drgnx-ai-default-roles (complete (ollama . "qwen2.5-coder:1.5b"))
			 (edit (openrouter . "openrouter/auto")
			       (ollama . "qwen2.5-coder:7b"))
			 (chat (openrouter . "openrouter/auto")
			       (ollama . "qwen2.5-coder:7b"))
			 (embed (tei)) (agent (openrouter)))
 (drgnx-agents-builtin-profiles
  ("claude" :command ("claude-agent-acp") :mode queue :job-safe t :doc
   "Claude through the unmodified agent (subscription or API key)")
  ("claude (OpenRouter)" :command ("claude-agent-acp") :mode queue
   :job-safe t :ai claude-openrouter :doc
   "Claude Code on OpenRouter (your OpenRouter key, from the environment or auth-source)")
  ("claude (Ollama)" :command ("claude-agent-acp") :mode queue
   :job-safe t :ai claude-ollama :doc
   "Claude Code on a local Ollama model")
  ("claude (Kimi)" :command ("claude-agent-acp") :mode queue :job-safe
   t :ai claude-moonshot :model "kimi-k3" :doc
   "Claude Code on Kimi through Moonshot's own API (MOONSHOT_API_KEY or auth-source for api.moonshot.ai; billed per token by Moonshot)")
  ("claude (DeepSeek)" :command ("claude-agent-acp") :mode queue
   :job-safe t :ai claude-deepseek :model "deepseek-v4-pro" :doc
   "Claude Code on DeepSeek through its own API (DEEPSEEK_API_KEY or auth-source for api.deepseek.com; billed per token by DeepSeek)")
  ("claude (Kimi via OpenRouter)" :command ("claude-agent-acp") :mode
   queue :job-safe t :ai claude-openrouter :model "moonshotai/kimi-k3"
   :doc
   "Claude Code on Kimi through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)")
  ("claude (DeepSeek via OpenRouter)" :command ("claude-agent-acp")
   :mode queue :job-safe t :ai claude-openrouter :model
   "deepseek/deepseek-v4-pro" :doc
   "Claude Code on DeepSeek through OpenRouter (OPENROUTER_API_KEY or auth-source for openrouter.ai; billed by OpenRouter)")))
