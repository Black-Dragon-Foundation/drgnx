;; drgnx AI providers and roles (docs/guide/ai.md) — never a key here
(:version 1
 ;; a local runner on the desktop
 :providers ((desk :name "Desk" :kind ollama :url "http://desk:11434" :caps (chat fim)))
 :roles ((complete (desk . "qwen-coder")) (chat (desk))))
