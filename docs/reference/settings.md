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

## drgnx-keys-bind

Command id -> keys, entries (ID KEY… [:map MAP]) that win over every layer.  Keyboard Shortcuts writes them.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of (pred drgnx-keys--bind-entry-p "(ID KEY… [:map MAP])"))` |

## drgnx-keys-layers

The key-profile stack: (PROFILE SCOPE…), later layers win.  Settings: Keyboard Profile sets it.

| Key | Value |
| --- | --- |
| Default | `((vscode app editing window))` |
| Type | `(repeat (cons symbol (repeat symbol)))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--layers-settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(pred drgnx-keys--layers-ok-p "a profile stack such as ((emacs editing) (vscode app window))")` |

## drgnx-keys-mac-option

What the left Option key does on a Mac with VS Code's keys: `characters' (it types @ # { [) or `meta'; nil: Meta.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "Meta" nil) (const characters) (const meta))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null (pred drgnx-keys--mac-option-p "characters or meta"))` |

## drgnx-keys-pending-layers

A stack waiting for its modal engine to be installed (drgnx sync); nil when none waits.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat (cons symbol (repeat symbol)))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null (pred drgnx-keys--layers-ok-p "a profile stack such as ((vim app editing window))"))` |

## drgnx-keys-tty-fallback

Chord -> another Alt key for it, in a legacy terminal: (("C-S-p" . "M-Z")).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type string :value-type string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `any` |

## drgnx-keys-unbind

Command ids that get no key, whatever the layers say.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-large-files-ask-above

Above this size (MiB) a file opens in chunks, lean or raw (a command asks once); nil: never.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `50` |
| Type | `(choice (const :tag "Never" nil) number)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `lower-only` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))` |

## drgnx-large-files-chunk-size

How much of the file (MiB) a chunk holds.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `1` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(pred drgnx-large-files--mib-p "a size in MiB above 0")` |

## drgnx-large-files-chunks-above

Above this size (MiB) the question's default is chunks, else lean.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `500` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `lower-only` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(pred drgnx-large-files--mib-p "a size in MiB above 0")` |

## drgnx-look-theme

The colour theme ui/look loads at start (Color Theme picks it); nil: the theme Emacs starts with.  A change
switches the theme at once while the module runs.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "Emacs's own" nil) symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null symbol)` |

## drgnx-modules-disabled

Modules you turned off.  Preferences: Modules writes this; a change turns the module off or on at once.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-modules-enabled

Modules that are off until chosen, chosen on.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-modules-external

External modules, each (:name NAME :path DIR :features (FEATURE…)); each is checked when it loads.
They run code from DIR, so no workspace may set this and no agent may change it.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of any)` |

## drgnx-modules-flags

Module flags: ((MODULE FLAG…)…).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type symbol :value-type (repeat symbol))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(alist symbol (list-of symbol))` |

## drgnx-sandbox-memory-max

The memory cap of each sandboxed agent, the `:memory-max' of a spec that does not give one: a systemd size (4G,
512M, 50%) or nil for none.  It applies where a systemd user manager answers (`drgnx-sandbox-memory-prefix').  An
operational guard, so that one agent's build cannot run the session out of memory; not a security boundary.

| Key | Value |
| --- | --- |
| Default | `"4G"` |
| Type | `(choice (const :tag "No cap" nil) string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-sandbox-proxy-pinned-addresses

Names the job proxies resolve to a fixed address instead of asking DNS: ((NAME . ADDRESS)…), ADDRESS an IPv4 or
IPv6 literal.  A pinned name may lead to a private or loopback address (a registry on the company's network, a
test's local upstream); a name resolved through DNS never does.  Pinning only resolves: the name must still be on the
job's allowlist.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type string :value-type string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-sandbox-secret-files

Where package managers keep tokens, relative to a toolchain root: each that exists inside a root of
`drgnx-sandbox-toolchain-roots' is hidden in the sandbox (`drgnx-sandbox-toolchain-hide').  npm's global config is
PREFIX/etc/npmrc.

| Key | Value |
| --- | --- |
| Default | `(".npmrc" "etc/npmrc" ".yarnrc" ".yarnrc.yml" ".pypirc" ".netrc" ".git-credentials" ".env" "credentials" "credentials.toml" "credentials.json" "auth.json")` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-search-exclude

Files matching one of these globs are not indexed; a workspace's are added to yours (see `drgnx-search-config').

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `append` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | - |

## drgnx-search-include

Only files matching one of these globs are indexed (nil: all); see `drgnx-search-config'.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | - |

## drgnx-search-off

Non-nil turns a project's semantic search off; see `drgnx-search-config'.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | - |

## drgnx-session-keep-running

Non-nil: drgnx keeps running in the background when its last window closes (reopening is instant).
nil: closing the last window quits drgnx (after asking to save changed files).  Set it with
Preferences: Keep drgnx Running in the Background, which remembers it in settings.el.  Read when a window closes.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-trust-parents

Folders whose projects are trusted for data: their workspace settings apply, and their code waits for Review
and Allow.  Each entry is ("DIR/") or ("DIR/" :code t); :code t trusts everything below DIR, code included, with
no review (and puts DIR into `trusted-content').  A remote folder, your home folder, `/', the temp folders and their
ancestors are never trusted.  Agents can never change it, and no workspace sets it.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat (cons (directory :tag "Folder") (plist :tag "Options" :options ((:code boolean)))))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | `drgnx-settings-trust--parents-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

