;;; providers-settings.el --- a settings.el both sides read: the provider table conformance  -*- mode: lisp-data -*-
;; The hub's table (runtime/crates/drgnx-ratatoskr/src/settings/conformance.rs) must equal the editor's
;; (`drgnx-settings-dump--providers-table' with this `drgnx-ai-providers'), which dump.el writes to lisp-dump.json.
(drgnx-settings
 :version 1
 (drgnx-ai-providers
  ;; a preset replaced: another address, its caps given twice and one the hub does not know
  ((ollama :name "My Ollama" :kind ollama :url "http://10.0.0.5:11434" :caps (chat chat fim nonsense) :messages t)
   ;; one of my own, keyed, priced
   (work :name "Work" :kind openai :url "https://llm.example/v1" :key-env "WORK_KEY" :caps (chat embed)
         :price (0.5 . 15))
   ;; an Anthropic-style key header
   (claude-direct :kind anthropic :url "https://api.anthropic.com/v1" :key-env "MY_ANTHROPIC_KEY" :auth x-api-key
                  :caps () :messages t)
   ;; no URL: no provider on either side
   (half :kind openai :caps (chat))))
 (fill-column 100))
