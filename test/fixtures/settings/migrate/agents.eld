;; drgnx agents (docs/guide/agents.md)
(:version 1
 ;; the review profile reads every project
 :profiles (("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews"))
 :default "review"                      ; New Agent Session offers it
 :mcp (coordination search)
 :openrouter (:only ("anthropic") :zdr t)
 :routes ((review . "review") (implement "claude" "review")))
