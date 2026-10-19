;; the exit test's provider: its key travels in secrets.age, never here
(:providers ((openrouter :name "OpenRouter" :kind openai :url "https://openrouter.ai/api/v1"
                         :key-env "OPENROUTER_API_KEY" :caps (chat fim embed) :messages t)))
