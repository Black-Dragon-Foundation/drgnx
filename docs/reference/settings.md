# Settings

The settings drgnx declares with `drgnx-defsetting`, and the keys that say where each may be set, whether a workspace may set it, how it merges and whether an agent may change it. Generated from the declarations: do not edit; see docs/develop/core.md for how to regenerate it, and [Declaring a setting](../develop/settings.md) for the keys.

## drgnx-agents-allow-unsandboxed

Non-nil: agents may run without the sandbox.  Off unless you turn it on; no workspace and no agent can.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"bool"` |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-agents-default

The profile New Agent Session offers on Return: a profile's name, or nil for claude.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "claude" nil) string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-agents-mcp

The MCP servers agents get: `coordination' and `search'.

| Key | Value |
| --- | --- |
| Default | `(coordination)` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of (enum coordination search))` |

## drgnx-agents-openrouter

Which providers OpenRouter may use for the agents' requests: a plist (:only SLUGS :ignore SLUGS
:data-collection deny|allow :zdr t), each key only when set.  A value that is not a restriction is refused, and
OpenRouter agents do not start until it is fixed.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"OpenRouterRestrictions"` |
| `:agents` | `never` |
| `:schema` | `(pred drgnx-agents--openrouter-ok-p "not an OpenRouter restriction (:only :ignore :data-collection :zdr)")` |

## drgnx-agents-own-env

Each agent's own credentials and switches: (AGENT NAME…).  A profile without an `:ai' route runs on the user's
own login, so the names of its agent (by its command: claude, codex, gemini) are exempt from
`drgnx-agents-scrubbed-env' for it, and only for it.  `AWS_*' and `GOOGLE_APPLICATION_CREDENTIALS' are not scrubbed
at all.

| Key | Value |
| --- | --- |
| Default | `((claude "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL" "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL" "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL" "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX") (codex "OPENAI_API_KEY" "OPENAI_BASE_URL") (gemini "GEMINI_API_KEY" "GOOGLE_API_KEY"))` |
| Type | `(alist :key-type symbol :value-type (repeat string))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-agents-profiles

Your agent profiles: an alist NAME → plist (:command LIST :env ("NAME=value"…) :mode queue|steer|interrupt
:ai PROVIDER-ENVIRONMENT :model MODEL :doc LINE).  The built-in ones need none; never holds secrets (keys come from
the environment).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<AgentProfile>"` |
| `:agents` | `never` |
| `:schema` | `(alist string (plist (:command (list-of string) "The program and its arguments" :required t) (:env (list-of string) "NAME=value pairs added to its environment") (:mode (enum queue steer interrupt) "What a message to a busy agent does") (:ai symbol "The provider environment it gets") (:model string "The model it asks for") (:doc string "One line")))` |

## drgnx-agents-routes

Which profiles do each job role: an alist ROLE → a profile's name, or a list of names.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<AgentRoute>"` |
| `:agents` | `never` |
| `:schema` | `(alist symbol (or string (list-of string)))` |

## drgnx-agents-scrubbed-env

Keys never inherited by agents: variables of Emacs's environment that an agent does not get.
MCP Test and Hook Test on the Agent Settings page unset the same list (drgnx-agent-check.el).
An agent gets the variables of its own route (the provider key or the gateway token, the model names) and
nothing else from this list, so a Kimi agent never sees your DeepSeek or OpenRouter key.  A profile without a
route (`:ai') is the user's own login and also keeps its own vendor's names (`drgnx-agents-own-env').  To pass
another one on, remove it from this list (or set it in the profile's `:env').

| Key | Value |
| --- | --- |
| Default | `("ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL" "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL" "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL" "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX" "OPENAI_API_KEY" "OPENAI_BASE_URL" "OPENROUTER_API_KEY" "MOONSHOT_API_KEY" "DEEPSEEK_API_KEY" "GEMINI_API_KEY" "GOOGLE_API_KEY")` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-ai-providers

Providers of your own, or presets moved: an alist ID → (:name :kind :url :key-env :caps :price :messages).
An entry replaces the preset with its id.  Never holds a key (:key-env names the variable that does).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | `"Vec<ProviderConfig>"` |
| `:agents` | `never` |
| `:schema` | `(alist symbol (plist (:name string "What the provider is called") (:kind (enum openai ollama llamacpp tei anthropic) "How to talk to it") (:url string "Its address") (:key-env string "The environment variable holding its key (never the key)") (:caps (list-of symbol) "What it does: chat, fim, embed") (:price (pred drgnx-ai--price-p "(IN . OUT) dollars per million tokens") "What the agent gateway counts its spend by") (:messages boolean "Whether it serves Anthropic's Messages API")))` |

## drgnx-ai-roles

Each role's chain of (PROVIDER . MODEL), tried in order: an alist ROLE → chain.  A MODEL is a name, or nil for
the provider's own.  A role you do not name has the shipped default chain.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | `"Vec<RoleChain>"` |
| `:agents` | `never` |
| `:schema` | `(alist symbol (alist symbol (or string null)))` |

