# Settings

The settings drgnx declares with `drgnx-defsetting`, and the keys that say where each may be set, whether a workspace may set it, how it merges and whether an agent may change it. Generated from the declarations: do not edit; see docs/develop/core.md for how to regenerate it, and [Declaring a setting](../develop/settings.md) for the keys.

## drgnx-agent-panel-disclosure

The step types whose detail a new agent panel opens: thinking, read, search, edit, execute, fetch, other.
A failed step opens whatever this says.  `M' in a panel makes its current choice the default.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(set (const thinking) (const read) (const search) (const edit) (const execute) (const fetch) (const other))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of (enum thinking read search edit execute fetch other))` |

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

## drgnx-agents-away-after

Seconds without input after which the editor tells the hub you are away (the time presets of the matrix follow).

| Key | Value |
| --- | --- |
| Default | `600` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-browser-deny-hosts

Host names (like "example.com") a session's browser never reaches, whatever you grant: a list of strings.
Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-agents-browser-idle

Seconds without a command after which a session's browser is stopped; the next command starts it again.
Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `600` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-browser-local-ports

The TCP ports on the sandbox's own loopback that a session with the browser lets its agent and browser
connect to, for the servers the agent starts there (a list of port numbers, 1 to 65535).  Servers on this machine are
reached only as host.drgnx.internal:PORT, through a grant.  Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `(3000 3001 4173 4200 5000 5173 8000 8080 8888)` |
| Type | `(repeat integer)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<u16>"` |
| `:agents` | `never` |
| `:schema` | `(list-of (integer :min 1 :max 65535))` |

## drgnx-agents-browser-max-message

The largest message, in bytes, that passes between an agent and its session's browser (64 MiB).
Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `67108864` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `(integer :min 1)` |

## drgnx-agents-browser-memory-high

The share of the session's memory cap (1 to 99, a percent) at which its browser is stopped.
Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `75` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u32"` |
| `:agents` | `never` |
| `:schema` | `(integer :min 1 :max 99)` |

## drgnx-agents-browser-once-window

Seconds a one-time browser grant lasts after you give it.  Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `600` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-browser-program

The browser an agent session gets: the absolute path of a Chromium, Chrome or headless shell, or nil to find one
(a distro package first, then the one `drgnx browser install' downloaded).  Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "find one" nil) file)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null (string :match "\\`/"))` |

## drgnx-agents-checkpoint-cap

Bytes of checkpoints kept per project (the shadow repos of all its sessions together); the oldest of finished
tasks go first.

| Key | Value |
| --- | --- |
| Default | `2147483648` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-close-idle-after

Seconds a session may sit idle on a running job before it is closed and resumed at the job's wake.

| Key | Value |
| --- | --- |
| Default | `1800` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-container-images

The images container jobs may run: an alist NAME → image reference pinned by digest ("registry/name@sha256:…").
The hub pulls them; a job names one of them and nothing else.  Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<ContainerImage>"` |
| `:agents` | `never` |
| `:schema` | `(alist string (string :match "@sha256:[0-9a-f]\\{64\\}\\'"))` |

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

## drgnx-agents-hook-rules

Rules the hub checks at the hook points, before any plugin: each is a plist with :point, :verdict (deny or annotate)
and :reason, and optionally :id, :tool-kinds, :paths and :command, which all have to match.  A rule only narrows what
the permissions matrix allows; it is a guardrail, not a boundary.  In one project the project's rules are added to
these.  Only you can set it, never a repository or an agent.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `append` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<HookRule>"` |
| `:agents` | `never` |
| `:schema` | `(list-of (plist (:id string "A name to switch the rule off in one project: 1 to 32 lowercase letters, digits and `-'") (:point (enum before-tool after-edit before-commit at-review) "Where the rule looks" :required t) (:tool-kinds (list-of string) "ACP tool kinds (read, edit, delete, move, search, execute, think, fetch, switch_mode, other), or drgnx for the hub's own tools") (:paths (list-of string) "Path globs: * within one segment, ** across segments, ? one character") (:command string "A regular expression the tool's command text must match") (:verdict (enum deny annotate) "What the rule says; a rule never changes anything" :required t) (:reason string "Shown with the refusal or the note" :required t)))` |

## drgnx-agents-hook-rules-off

The ids of hook rules that are switched off in this project (a list of strings).  Only a rule with an :id can be
switched off.  Only you can set it, in your private workspace file.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-agents-identity-walk

How agents are given a colour and a mark: `diagonal' (the look's six colours each with its own mark, then the
rest) or `colour-first' (every colour with the circle first, marks from the agent after the last colour).  A change
applies to the agents shown from then on.

| Key | Value |
| --- | --- |
| Default | `diagonal` |
| Type | `(choice (const :tag "Diagonal" diagonal) (const :tag "Colour first" colour-first))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-agent-identity-clear` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum diagonal colour-first)` |

## drgnx-agents-job-cpus

How many CPUs one job may use.

| Key | Value |
| --- | --- |
| Default | `2` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u32"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-agents-job-memory

The memory cap of one job (systemd's MemoryMax, podman's --memory), like "4G" or "512M".

| Key | Value |
| --- | --- |
| Default | `"4G"` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"String"` |
| `:agents` | `never` |
| `:schema` | `(string :match "\\`[1-9][0-9]*[KMGT]?\\'")` |

## drgnx-agents-manager-context

The share of its context window (0 to 1) at which a manager is rotated.

| Key | Value |
| --- | --- |
| Default | `0.7` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"f64"` |
| `:agents` | `never` |
| `:schema` | `number` |

## drgnx-agents-matrix

What agents may do without asking: a plist (:preset cautious|balanced|autonomous :time TIME-PRESETS :cells CELLS).
Balanced is the shipped preset.  A time preset replaces the base one while you are away (`drgnx-agents-away-after')
or between two minutes of the day.  A cell sets one action for a role, an agent or a provider; the most restrictive
column that matches wins.  Set it in Settings → User; no workspace and no agent can.

| Key | Value |
| --- | --- |
| Default | `(:preset balanced)` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"AgentsMatrix"` |
| `:agents` | `never` |
| `:schema` | `(plist (:preset (enum cautious balanced autonomous) "The base preset; absent: balanced") (:time (list-of (plist (:when (or (enum away) (pred drgnx-agents-matrix--between-p "(between FROM TO), minutes of the day")) "While you are away, or between two minutes of the day (local time)" :required t) (:preset (enum cautious balanced autonomous) "The preset that applies then" :required t))) "Presets that replace the base one at some times") (:cells (list-of (plist (:action (enum agents.start agents.model agents.control graph.change task.done spend spend.over code.read code.edit commit merge.integration push.ci push.main code.ci-config machines job.container job.keys network browser browser.web browser.private unsandboxed settings.change user.private user.emacs chat.project-read plugin.abilities chat.project-edit huddles) "What the agent does" :required t) (:column (pred drgnx-agents-matrix--column-p "(:role manager\|worker\|chat), (:agent NAME) or (:provider NAME)") "Whose cell" :required t) (:verdict (enum allow ask never) "What happens" :required t) (:limit (plist (:amount number "How much" :required t) (:unit (enum count usd usd-est tokens limit-share) "Of what" :required t)) "An amount over which the cell is decided by spend.over"))) "Cell overrides"))` |

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

## drgnx-agents-model-prices

What a model costs, for the forecasts: an alist KEY → (:in :out :cache-read :write-5m :write-1h :as-of), US dollars per
million tokens.  KEY is a model id prefix (the longest match wins) or a provider name; `claude' is a Claude profile with
no model set.  A cache price left out is the input price.  :as-of is the date the row was read off the provider's page;
the forecast shows the oldest.  The shipped rows are Anthropic's pricing page of 2026-11-01; Haiku's is the tier above
100,000 tokens (a request below it costs a fifth), because agent work runs past it.  A subscription's model is the CLI's
choice, so a subscription's cost is an estimate.  A model with no row (every Codex and Gemini model until you add one)
is unpriced; a gateway provider's `:price' in `drgnx-ai-providers' serves when no row matches.  Add a row for your
own model, or change one when prices move.  Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `(("claude-fable-5-1" :in 10 :out 50 :cache-read 0.25 :write-5m 12.5 :write-1h 20 :as-of "2026-11-01") ("claude-opus-5-5" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01") ("claude-sonnet-5-5" :in 2 :out 10 :cache-read 0.1 :write-5m 2.5 :write-1h 4 :as-of "2026-11-01") ("claude-haiku-5-5" :in 0.5 :out 2.5 :cache-read 0.05 :write-5m 0.625 :write-1h 1 :as-of "2026-11-01") ("claude" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01"))` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<ModelPrice>"` |
| `:agents` | `never` |
| `:schema` | `(alist string (plist (:in number) (:out number) (:cache-read number) (:write-5m number) (:write-1h number) (:as-of string)))` |

## drgnx-agents-net-hosts

The hosts a job that was granted network may reach, per tier: an alist TIER → list of "host:port" strings.
`packages' (the tier of a granted network) is the package registries of crates.io, npm and PyPI; `provider-only'
reaches nothing unless you list hosts.  A tier you leave out reaches nothing.  A sandboxed agent session's proxy
allows its tier's hosts (`provider-only') beside its provider's and its CLI's own.  `plugin' is the tier of the
plugins' HTTP requests (never the agent's): a host the plugin's approved manifest names, where the session's network
is not open, must also be listed there.  Only you can set it, never a
repository.

| Key | Value |
| --- | --- |
| Default | `((packages "crates.io:443" "index.crates.io:443" "static.crates.io:443" "registry.npmjs.org:443" "pypi.org:443" "files.pythonhosted.org:443"))` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"NetHosts"` |
| `:agents` | `never` |
| `:schema` | `(alist symbol (list-of (string :match ":[0-9]+\\'")))` |

## drgnx-agents-no-progress-tokens

Tokens per changed line of task work over which the supervisor pauses the session.

| Key | Value |
| --- | --- |
| Default | `20000` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u64"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

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

## drgnx-agents-plugins

The plugins that run, in hook order: a list of plugin names.  A plugin runs only when it is listed here and you
approved it (Extensions, or Settings → Plugins).  In one project the list is the project's own and replaces this one
(Workspace tab).  Only you can set it, never a repository or an agent.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-agents-profiles

Your agent profiles: an alist NAME → plist (:command LIST :env ("NAME=value"…) :mode queue|steer|interrupt
:ai PROVIDER-ENVIRONMENT :model MODEL :tracker-tools on|off :doc LINE).  The built-in ones need none; never holds
secrets (keys come from the environment).

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
| `:schema` | `(alist string (plist (:command (list-of string) "The program and its arguments" :required t) (:env (list-of string) "NAME=value pairs added to its environment") (:mode (enum queue steer interrupt) "What a message to a busy agent does") (:ai symbol "The provider environment it gets") (:model string "The model it asks for") (:tracker-tools (enum on off) "The five tracker tools; on by default") (:doc string "One line")))` |

## drgnx-agents-repeat-limit

How many times the same command may run in one turn before the supervisor pauses the session.

| Key | Value |
| --- | --- |
| Default | `3` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u32"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

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

## drgnx-agents-session-memory

The memory cap of one agent session with its browser, like "4G" or "512M".
Only you can set it, never a repository.

| Key | Value |
| --- | --- |
| Default | `"4G"` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"String"` |
| `:agents` | `never` |
| `:schema` | `(string :match "\\`[1-9][0-9]*[KMGT]?\\'")` |

## drgnx-agents-silent-after

Seconds without an update after which the supervisor pauses a session, per kind of work.

| Key | Value |
| --- | --- |
| Default | `((task . 600) (brainstorm . 1800))` |
| Type | `sexp` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"SilentAfter"` |
| `:agents` | `never` |
| `:schema` | `(alist symbol natnum)` |

## drgnx-agents-start-env-names

The environment variables an editor module may add to an agent the hub starts (`drgnx-agents-env-functions'), by
name.  The hub drops any other name, and any name that looks like a credential (it contains KEY, TOKEN, SECRET,
PASSWORD, PASSPHRASE or CREDENTIAL), whatever this lists.  Only you can set it, never a repository or an agent.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-agents-tags

When an agent's name tag shows beside its cursor: `activity' (for 2 s after it moves), `always' or `never'.
Two agents of one colour, and the agent you follow, keep their tags on whatever this says (except `never').

| Key | Value |
| --- | --- |
| Default | `activity` |
| Type | `(choice (const :tag "After a move" activity) (const :tag "Always" always) (const :tag "Never" never))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-agents-editor-draw--tags-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum activity always never)` |

## drgnx-agents-trace-opens

The agents whose shell commands' opens the hub sees on Linux ("seen open" in the Work space), by provider:
"claude", "codex", "gemini", "kimi" (Kimi Code), "deepseek" (DeepSeek Harness).  Claude Code is traced per
shell step; the others over their whole process tree, which costs every command they run (a test suite run as one
command: about a third longer), so they are off unless listed.  An agent not listed shows only the files its
commands name.  Read when a session starts.

| Key | Value |
| --- | --- |
| Default | `("claude")` |
| Type | `(repeat (choice (const "claude") (const "codex") (const "gemini") (const "kimi") (const "deepseek")))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-agents-wait-refusals

How many times an agent may try to wait on a job (sleep, tail -f, polling) before its turn is cancelled.

| Key | Value |
| --- | --- |
| Default | `3` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"u32"` |
| `:agents` | `never` |
| `:schema` | `natnum` |

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

## drgnx-extensions-check-updates

How the Extensions view learns of updates: `daily' reads the archives in the background once a day, `manual' only
when you ask (the Refresh command).

| Key | Value |
| --- | --- |
| Default | `daily` |
| Type | `(choice (const daily) (const manual))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-extensions--check-updates-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum daily manual)` |

## drgnx-extensions-recommended

Packages this project recommends: the Extensions view lists them under Recommended, with an Install button.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-extensions-review

Packages and archives ("melpa") whose updates you review before they install.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of (or symbol string))` |

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

## drgnx-look-accent

Where the accent colour comes from: `system' (the desktop's accent colour, as text for the theme's variant) or
`theme' (the theme's own).  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `system` |
| Type | `(choice (const :tag "The desktop's" system) (const :tag "The theme's" theme))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-follow-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum system theme)` |

## drgnx-look-density

How much room the look gives: `compact', `comfortable' or `roomy' (the line, row, tab, bar and gap sizes).  A
change applies at once.

| Key | Value |
| --- | --- |
| Default | `comfortable` |
| Type | `(choice (const compact) (const comfortable) (const roomy))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-density--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum compact comfortable roomy)` |

## drgnx-look-echo-row

Where a graphical frame's echo area lives.  `float': no row at the bottom; a prompt floats in a box at the top
centre, in the palette's look, and hides when nothing asks; messages and the keys of a prefix show in the status bar.
`classic': the row at the bottom, as in stock Emacs.  A terminal frame keeps its row either way.  A change applies at
once: each graphical frame is swapped for a new one with the same windows, buffers, size and place.

| Key | Value |
| --- | --- |
| Default | `float` |
| Type | `(choice (const float) (const classic))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-echo--apply-setting` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum float classic)` |

## drgnx-look-font-agent

The font of the agent panel's prose.  `:family ui' is the UI font.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family ui)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-code

The code font: family, fallback list, size (a ratio to the code size, 13.5 px), weight, line height in pixels and
ligatures.  A change applies at once.  `(:mode MODE ...)' sections give one mode another font.

| Key | Value |
| --- | --- |
| Default | `(:family "JetBrains Mono" :fallback ("Adwaita Mono" "monospace") :size 1.0 :weight regular :line-height 21 :ligatures nil)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-code-small

The font of diffs and output inside cards.  `:family code' is the code font.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family code :size 0.889 :line-height 19)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-terminal

The font of the terminal's text.  `:family code' is the code font.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family code)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-title

The font of the start page's and the reviews' headings.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family ui :size 1.259 :weight semibold)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-ui

The user interface font (tabs, status bar, lists, palette, notices): family, fallback list, size (a ratio to the
code size) and weight.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family "Adwaita Sans" :fallback ("Inter" "sans-serif") :size 0.963 :weight regular)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-ui-caption

The font of the status bar, meta text and the tree's end column.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family ui :size 0.889)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-font-ui-heading

The font of panel titles and section heads.  `:family ui' is the UI font.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `(:family ui :size 0.963 :weight semibold)` |
| Type | `(choice (const :tag "Follow the desktop's font" follow-desktop) (plist :tag "Font" :key-type symbol :value-type sexp))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-fonts--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (enum follow-desktop) (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role") (:fallback (list-of string) "Families to try when the family is not installed") (:size number "A ratio to the code size (1.0 is the code size)") (:weight symbol "regular, semibold, bold, ...") (:line-height integer "Pixels per line (logical)") (:ligatures boolean "Ligatures on")))` |

## drgnx-look-icons

How the look draws its icons: `svg' (Lucide line icons in the text colour, on graphical frames) or `glyphs' (the
characters of `drgnx-face-glyphs').  Terminal frames always show glyphs.  A change applies to the icons drawn from
then on.

| Key | Value |
| --- | --- |
| Default | `svg` |
| Type | `(choice (const :tag "Line icons" svg) (const :tag "Glyphs" glyphs))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-icons-clear` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum svg glyphs)` |

## drgnx-look-motion

Motion of popups, the palette and notices under Glitnir: `auto' follows the desktop's reduced-motion
preference, `full' always moves, `reduced' never does (no transitions; blur and shadows stay).
A change applies at once.

| Key | Value |
| --- | --- |
| Default | `auto` |
| Type | `(choice (const auto) (const full) (const reduced))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look--motion-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum auto full reduced)` |

## drgnx-look-scale

The UI scale in percent: every size of the look and every font, on top of the display's own scale.  100 to 200 in
steps of 5; Zoom In and Zoom Out step 10.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `100` |
| Type | `integer` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-scale--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(pred drgnx-look-scale-percent-p "a percent from 100 to 200 in steps of 5")` |

## drgnx-look-scale-monitors

The UI scale of particular monitors, in percent: an alist from a monitor's name (as `frame-monitor-attributes'
gives it, "eDP-1") to a percent, 100 to 200 in steps of 5.  A frame on a monitor named here takes its percent
instead of `drgnx-look-scale', and changes when it moves to another monitor.  A change applies at once.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type string :value-type integer)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look-scale--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(alist string (pred drgnx-look-scale-percent-p "a percent from 100 to 200 in steps of 5"))` |

## drgnx-look-theme

The colour theme ui/look loads at start (Color Theme picks it); `auto': drgnx Dark, Light or High Contrast as
the desktop says, until a theme of yours is loaded; nil: the theme Emacs starts with.  A change switches the theme
at once while the module runs.

| Key | Value |
| --- | --- |
| Default | `auto` |
| Type | `(choice (const :tag "Follow the desktop" auto) (const :tag "Emacs's own" nil) symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null symbol)` |

## drgnx-look-themes-notice

Whether the one-time notice that drgnx now has its own themes was shown.  drgnx sets it; there is no reason to.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

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

## drgnx-notice-style

Where a notice that interrupts shows: `float' (a toast over the editor on any graphical frame, without Glitnir's
corners and shadow where it does not draw), `echo' (a line in the echo area) or `auto' (`float' while Glitnir draws,
else `echo').  A terminal frame always echoes.  A change applies to the next notice.

| Key | Value |
| --- | --- |
| Default | `auto` |
| Type | `(choice (const auto) (const echo) (const float))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum auto echo float)` |

## drgnx-packages-off

Packages whose file modes and buffer modes are off in this project (Extensions, a package's page).  A package
that changes Emacs as a whole cannot be off in one project.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-popup-style

How the popup lane shows: `window' (the panel's window, or one under the editors), `float' (one child frame
over the editor, bottom-centre) or `auto': `float' under Glitnir, `window' without it.

| Key | Value |
| --- | --- |
| Default | `auto` |
| Type | `(choice (const auto) (const window) (const float))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or (const auto) (const window) (const float))` |

## drgnx-runners-heavy

Suite or command patterns whose jobs are heavy in this project (a job is heavy only when marked so).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-runners-image

The image a runner runs the project's command jobs in, pinned by digest ("registry/name@sha256:…"), or nil.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-runners-job-keys

The keys the project's jobs may name, by name ("CRATES_IO_TOKEN"): a job naming any other is refused.
Names only, never a value: the values stay in your key store and reach a job's own process only.  Never set by a
repository's own files.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of (string :match "\\`[A-Za-z_][A-Za-z0-9_]*\\'"))` |

## drgnx-runners-key-host

The host a job key is filed under in your key store (auth-source): a key named CRATES_IO_TOKEN is the entry with this
host and that user.  Read only by the commands you run (Runners: Load Keys), never by the editor on its own.

| Key | Value |
| --- | --- |
| Default | `"drgnx-runner-keys"` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-runners-mac-tools

The Homebrew packages the project's Mac jobs need, by name ("cmake", "gnutls").
A Mac job waits for a Mac runner that has each one, and its row names the `brew install' line to run in your own
account: the runner never installs into Homebrew.  Never set by a repository's own files.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of (string :match "\\`[a-z0-9][-a-z0-9+_.@/]*\\'"))` |

## drgnx-runners-origin-key

The name of the project's read-only deploy key or token for its private origin, or nil.
Your own runners fetch the project from its origin with it instead of being sent a bundle.  A name only: the value
stays in your key store.  Never set by a repository's own files.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) string)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null (string :match "\\`[A-Za-z_][A-Za-z0-9_]*\\'"))` |

## drgnx-runners-project-visibility

"public" or "private": a public project's job whose commit the public origin has may run on a shared runner.

| Key | Value |
| --- | --- |
| Default | `"private"` |
| Type | `(choice (const "public") (const "private"))` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"String"` |
| `:agents` | `never` |
| `:schema` | `(string :match "\\`\\(?:public\\\|private\\)\\'")` |

## drgnx-runners-send

Which of the project's jobs may leave this machine for a runner: "all", "heavy" (only jobs marked heavy) or
"none".

| Key | Value |
| --- | --- |
| Default | `"heavy"` |
| Type | `(choice (const "all") (const "heavy") (const "none"))` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"String"` |
| `:agents` | `never` |
| `:schema` | `(string :match "\\`\\(?:all\\\|heavy\\\|none\\)\\'")` |

## drgnx-runners-shared-overlay

Non-nil lets a shared runner have a project's uncommitted files, once each passes the secret scan.
Off, a job with uncommitted changes never runs on a shared runner.  Never set by a repository's own files.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"bool"` |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-runners-weight

The project's weight when projects share the machines within a priority (2: twice the share of a project at 1).

| Key | Value |
| --- | --- |
| Default | `1.0` |
| Type | `number` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"f64"` |
| `:agents` | `never` |
| `:schema` | `number` |

## drgnx-sandbox-memory-max

The memory cap of each sandboxed agent, the `:memory-max' of a spec that does not give one: a systemd size (4G,
512M, 50%) or nil for none.  It applies where a systemd user manager answers.  An
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

Names the agents' proxies resolve to a fixed address instead of asking DNS: ((NAME . ADDRESS)…), ADDRESS an IPv4
or IPv6 literal.  A pinned name may lead to a private or loopback address (a registry on the company's network, a
test's local upstream); a name resolved through DNS never does.  Pinning only resolves: the name must still be on the
allowlist.  The hub pins them in each session's provider proxy and each container job's proxy.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type string :value-type string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | `"ProxyPins"` |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-sandbox-secret-files

Where package managers keep tokens, relative to a toolchain root: each that exists inside a toolchain root is
hidden in the sandbox.  npm's global config is PREFIX/etc/npmrc.

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

## drgnx-search-base

The checkout a project's search index is built from (its base); nil: the main checkout.
Every other worktree is an overlay of what differs from it, so a base on the line most worktrees branch from keeps
the overlays small.  Changing it builds the base again.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "The main checkout" nil) directory)` |
| `:scope` | `project` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-search-builtin

Non-nil: the built-in embedding model indexes every project's code and your tasks and notes, whatever servers are
running.  Nil: only a running server (TEI, Ollama) makes vectors, and with none, search is keyword and symbol only.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"bool"` |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-search-context

Non-nil: the Search view shows a dim label row (the definition's name) above the first match of each definition.

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

## drgnx-search-exclude

Files matching one of these globs are not indexed; a workspace's are added to yours.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `append` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-search-ignore-rules

Which files Quick Open, Find and the text search list: "index" leaves out dot paths and secret-looking names, as
the index does; "real" lists them, leaving out only what .gitignore files and the search globs name.

| Key | Value |
| --- | --- |
| Default | `"index"` |
| Type | `(choice (const "index") (const "real"))` |
| `:scope` | `buffer` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"String"` |
| `:agents` | `never` |
| `:schema` | `(string :match "\\`\\(?:index\\\|real\\)\\'")` |

## drgnx-search-include

Only files matching one of these globs are indexed (nil: all).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Vec<String>"` |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-search-model-mirror

Where embedding models are downloaded from: a URL laid out as the Hugging Face host, or nil for that host.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "Hugging Face" nil) string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"Option<String>"` |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-search-off

Non-nil turns a project's semantic search off.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `project` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `strict` |
| `:apply` | - |
| `:runtime` | `"bool"` |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-search-preview-threshold

Replace All with at least this many ticked matches first shows the Replace All sheet (every file's changes, then
Replace or Cancel); 0 never shows it.  `C-u' Replace All skips it once.

| Key | Value |
| --- | --- |
| Default | `1` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `natnum` |

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

## drgnx-speed-gc-census

Non-nil: record every garbage collection's pause, origin and live heap (Help → GC Census shows them).
Read at every start; a change turns the census on or off at once.  `drgnx-gc-census-mode' does it for this session.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-gc-census--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-speed-watchdog

Non-nil: run Nidhogg's stall watchdog (Help → Show Freezes) when this Emacs has it.
Read at every start; a change turns it on or off at once.  Without a watchdog in Emacs it does nothing.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-watchdog--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

## drgnx-term-abnormal-command-exit-runtime

Milliseconds: a terminal whose program fails (a code other than 0, or a signal) sooner than this after it started
keeps its buffer open with the status, even a shell's, so the error can be read.

| Key | Value |
| --- | --- |
| Default | `250` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-term-clipboard-codepoint-map

Characters replaced in text copied from a terminal: a list of (FROM TO REPLACEMENT), each character from FROM to
TO (code points) becoming the string REPLACEMENT; e.g. box-drawing lines as plain dashes.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat (list (character :tag "From") (character :tag "To") (string :tag "Replacement")))` |
| `:scope` | `global` |
| `:workspace` | `code` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of (list-of any))` |

## drgnx-term-clipboard-paste-bracketed-safe

Whether a paste into a program that asked for bracketed paste is safe whatever it holds (but the end of a
bracketed paste itself).  Off: `drgnx-term-clipboard-paste-protection' asks about every multi-line paste.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-clipboard-paste-protection

Whether Paste asks first when the text could run commands: it holds a line break, or the end of a bracketed paste,
and the program did not ask for bracketed paste (or `drgnx-term-clipboard-paste-bracketed-safe' is off).

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-clipboard-trim-trailing-spaces

Whether text copied from a terminal loses the spaces at the end of each line.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-clipboard-write

Whether a program in a terminal may write the clipboard (OSC 52): what it writes goes to the kill ring.  A
program never reads the clipboard: a terminal refuses every read.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-clipboard` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-command

The program a new terminal runs, with its arguments; nil: your shell (`drgnx-terminal-shell').  Applies to new
terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `code` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-term-confirm-close-surface

Whether closing a terminal asks first: t when a program runs in it (not a shell at its prompt), `always', or nil
(never).  Only a command you run asks; quitting drgnx asks once for every terminal.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `(choice (const :tag "When a program runs" t) (const always) (const :tag "Never" nil))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or boolean (enum always))` |

## drgnx-term-copy-on-select

Whether selecting a terminal's text with the mouse copies it at once (to the kill ring and the clipboard).
Applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-local` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-cursor-style

The cursor a terminal shows until its program chooses one: "block", "block_hollow", "bar" or "underline".
A change applies to every terminal at once (a program's own choice is reset).

| Key | Value |
| --- | --- |
| Default | `"block"` |
| Type | `(choice (const "block") (const "block_hollow") (const "bar") (const "underline"))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum "block" "block_hollow" "bar" "underline")` |

## drgnx-term-desktop-notifications

Whether a program's notification (OSC 9, OSC 777) becomes a drgnx notice.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-detached-keep

Hours a terminal no drgnx shows keeps running before its program is ended (SIGHUP); 0: until it ends by itself or
the machine restarts.  The terminal's own worker counts the time, so no drgnx needs to run.  A change applies to
every terminal at once.

| Key | Value |
| --- | --- |
| Default | `24` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-term-enquiry-response

What a terminal answers a program that sends ENQ (0x05); empty: nothing.  Applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `""` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `string` |

## drgnx-term-env

Environment entries of new terminals' programs, "NAME=VALUE" each, over drgnx's own; "NAME" alone unsets it.
Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-term-grapheme-width-method

How wide a terminal counts a grapheme cluster (an emoji sequence, a letter with accents): "unicode" (as Unicode
says, one width for the cluster) or "legacy" (each code point its own width, as older programs expect).  A program
can still switch it (mode 2027).  Applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `"unicode"` |
| Type | `(choice (const "unicode") (const "legacy"))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum "unicode" "legacy")` |

## drgnx-term-input

Text typed into a new terminal as soon as it starts, as if from the keyboard; nil: none.  Applies to new
terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) string)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-term-linux-cgroup-memory-limit

The most memory a new terminal (its program and all it starts) may use, in systemd's form ("4G", "512M"); nil:
no limit.  Needs a user systemd.  Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) string)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null (string :match "\\`[0-9]+[KMGT]?\\'"))` |

## drgnx-term-linux-cgroup-processes-limit

The most processes a new terminal (its program and all it starts) may run; nil: no limit.  Needs a user systemd.
Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) natnum)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null natnum)` |

## drgnx-term-mouse-reporting

Whether a program that asks for the mouse gets it.  Off: clicks and the wheel in a terminal are always drgnx's.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-mouse-shift-capture

Whether a program that tracks the mouse also gets clicks with Shift held.  Off: a Shift-click is drgnx's, to
select text in a program that takes the mouse.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-notify-on-command-finish

When a command that ran a long time ending in a terminal is told (`drgnx-term-notify-on-command-finish-action'):
`never', `unfocused' (when its terminal is not the selected window) or `always'.  It needs the shell's integration,
which marks where a command starts and ends.

| Key | Value |
| --- | --- |
| Default | `never` |
| Type | `(choice (const never) (const unfocused) (const always))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum never unfocused always)` |

## drgnx-term-notify-on-command-finish-action

How a finished command is told: `bell' rings the bell, `notify' adds a drgnx notice.

| Key | Value |
| --- | --- |
| Default | `(bell)` |
| Type | `(set (const bell) (const notify))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-term-notify-on-command-finish-after

How many seconds a command must run before its end is told.

| Key | Value |
| --- | --- |
| Default | `5` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `number` |

## drgnx-term-on-quit

What quitting drgnx does with its terminals: `ask' (when a program runs in one, the quit question offers Keep
Running, Close Them and Cancel; Keep Running keeps those terminals and closes idle shells), `keep' (every terminal
keeps running, for the next drgnx to reattach) or `close' (they close, after the usual question about running
programs).  A quit that cannot ask (a daemon's shutdown, `kill-emacs' from a script) keeps the terminals whose program
runs; a crash keeps them all.

| Key | Value |
| --- | --- |
| Default | `ask` |
| Type | `(choice (const ask) (const keep) (const close))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum ask keep close)` |

## drgnx-term-progress-style

Whether a program's progress (OSC 9;4) shows on its terminal's tab.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-reattach

What drgnx does with the terminals an earlier drgnx left running (kept at its quit, or after its crash): `ask' (a
notice offers them: Reattach All, Choose… or Close Them), `always' (they open here at once) or `never' (only
Reattach Terminal shows them).  A terminal another running drgnx shows is never offered.

| Key | Value |
| --- | --- |
| Default | `ask` |
| Type | `(choice (const ask) (const always) (const never))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum ask always never)` |

## drgnx-term-scroll-to-bottom

When a terminal scrolled back to earlier output goes back to its cursor: on a keystroke (`keystroke'), on new
output (`output'), both, or never (nil).

| Key | Value |
| --- | --- |
| Default | `(keystroke)` |
| Type | `(set (const keystroke) (const output))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-term-scrollback-bytes

The most bytes of scrollback a terminal remembers (Find in Terminal and copy reach that far), whatever
`drgnx-term-scrollback-lines' keeps in its buffer.  A change applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `67108864` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-term-scrollback-lines

How many rows a terminal's buffer keeps above its screen.  A change trims or fills every terminal at once.  The
terminal itself remembers at least 10,000 lines whatever this says, so Find in Terminal and copy reach further.

| Key | Value |
| --- | --- |
| Default | `10000` |
| Type | `natnum` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-scrollback` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `natnum` |

## drgnx-term-selection-clear-on-copy

Whether Copy in a terminal deselects the text it copied.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-selection-clear-on-typing

Whether typing into a terminal deselects its text.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-selection-word-chars

The characters that end a word when a double click selects one in a terminal; every other character (a slash, a
dot, a dash) is part of the word, so a path or an address is selected whole.  Applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `" '\"│`\|:;,()[]{}<>$"` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-local` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `string` |

## drgnx-term-shell-integration

Which shell integration a new terminal loads: `detect' (from the shell's name: bash, zsh, fish, elvish), one of
those, or `none'.  It marks prompts and commands, reports the folder and sets the title.  Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `detect` |
| Type | `(choice (const detect) (const none) (const bash) (const zsh) (const fish) (const elvish))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum detect none bash zsh fish elvish)` |

## drgnx-term-shell-integration-features

The features of the shell integration a new terminal turns on (Ghostty's names: "cursor", "title", "sudo",
"path").  Ghostty's ssh features are `drgnx-term-ssh-terminfo'.  Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `("cursor" "title" "sudo")` |
| Type | `(repeat string)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of string)` |

## drgnx-term-ssh-terminfo

What `ssh' typed in a terminal does about TERM (with drgnx's shell file sourced): `fallback', ssh says
"xterm-256color", which every host knows; `install', the first ssh to a host installs Ghostty's entry there with the
host's tic, once, and later ones keep "xterm-ghostty".  Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `fallback` |
| Type | `(choice (const fallback) (const install))` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(enum fallback install)` |

## drgnx-term-term

The TERM a new terminal's program sees.  "xterm-ghostty" (Ghostty's entry, which `drgnx build' compiles into
<data>/terminfo; TERMINFO then names that folder) falls back to "xterm-256color" while the entry is not there.
Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `"xterm-ghostty"` |
| Type | `string` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `string` |

## drgnx-term-title

A fixed title for every terminal's tab; nil: the title the program sets.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) string)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null string)` |

## drgnx-term-title-report

Whether a program may read a terminal's title back (CSI 21 t).  Off by default: a program can set a title and read
it back as typed input, which can carry commands.  Applies to every terminal at once.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-term--apply-config` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-wait-after-command

Whether every terminal's buffer stays open after its program ended, with the status.  Off: a shell's buffer
closes, and a command's stays (what it printed can be read).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `code` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `boolean` |

## drgnx-term-working-directory

Where New Terminal starts: nil, the folder of what you are looking at; `home', your home folder; or a folder.
Applies to new terminals.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const nil) (const home) directory)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null symbol string)` |

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

## drgnx-user-lisp-files

Your own Lisp files, loaded in this order after config.el: ((FILE :on BOOL [:early t] [:emacs-dir DIR])…).
FILE is relative to your config folder or absolute.  `:on' (default t) says whether it loads: turning one on loads it
now, turning one off takes effect at the next start (code that already ran cannot be unloaded).  `:early t' loads it
at the end of early-init.el, before drgnx starts.  `:emacs-dir DIR' binds `user-emacs-directory' to DIR while this one
file loads: a `setq' of it in the file is undone afterwards, and what loads later sees drgnx's folder, so use it only
for an init.el that expects its own.  config.el and custom.el may be listed too, only for their `:on' switch.
Settings: Lisp Files shows the files; Settings: Add Lisp File… adds one.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat (cons :tag "Lisp file" (file) (plist :key-type symbol :value-type sexp)))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-user-lisp--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of any)` |

