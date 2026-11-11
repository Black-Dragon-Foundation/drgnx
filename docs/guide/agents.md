# Agents

drgnx runs coding agents inside Emacs over the **Agent Client Protocol** (ACP: JSON-RPC 2.0, one object per line
on the agent's stdin/stdout), lists them with long-running background **jobs** in the right dock's **Agents** tab,
and keeps plan checklists and board TODOs in step.

The rule that shapes everything: **sending a message never cancels the agent's work.** A message sent while the
agent is working is **queued** and delivered once, in order, when its turn ends — or **steers** the running turn,
when the profile asks for it and the agent supports it. Only **Stop** cancels.

## Sessions

Agents: New Agent Session… (palette) starts a **profile** in the current project; Show Agents (`C-k a`, ⌘K A on a
Mac) opens the Agents tab. Profiles are the setting `drgnx-agents-profiles` in
`settings.el` in your config folder ([settings.md](settings.md); [where drgnx keeps its files](files.md#where-drgnx-keeps-its-files)); this file used to be `agents.eld`, and drgnx moved its
keys into `settings.el` once ([Moving from the old files](settings.md#moving-from-the-old-files)):

```elisp
(drgnx-agents-profiles (("claude" :command ("claude-agent-acp") :mode queue)
                        ("local" :command ("my-acp-agent" "--model" "qwen") :mode steer)))
```

The agent settings are `drgnx-agents-profiles`, `-default`, `-mcp`, `-routes`, `-openrouter` and
`-allow-unsandboxed`. They are **strict**: a value that is the wrong kind (a `:command` that is not a list of strings,
a `:mcp` name that is neither `coordination` nor `search`, an `:openrouter` value that is not a restriction) is not
applied and drgnx says where the mistake is, once; that setting is then at its shipped default. A `settings.el` that
does not read at all gives the shipped defaults for all of them. So only the built-in profiles are offered, the agents
get the coordination tools alone, and OpenRouter agents wait until it is fixed: a restriction you wrote is never
dropped for a typo. The settings pages and onboarding do not write to a file with a mistake; they say so. Changes to
`settings.el` apply at once, with no restart. No agent, no workspace file and no `.dir-locals.el` can change these
settings, and a buffer-local value is never read: a profile is a program, and a route chooses where your code goes.

`:command` is the agent program; `:mode` is what a message to a busy agent does: `queue` (default), `steer` (when
the agent advertises steering — sent as `_session/steering`; if the agent refuses, the message is queued instead) or
`interrupt` (stop the turn, then send; in a durable session, which the hub runs, a message never cancels a turn, so
`interrupt` queues there, and `steer` puts the message ahead of the other queued ones). A profile whose program is not installed gives a session that says so.
`:mcp-servers` lists MCP servers of your own for every session of the profile, job sessions included, after drgnx's
own: ACP `mcpServers` entries, written with vectors where ACP has arrays, e.g.
`:mcp-servers ((:name "docs" :command "docs-mcp" :args ["--read-only"] :env []))`. An entry named `drgnx` or
`drgnx-search` (drgnx's own servers) is left out, and a message says so. `:job-safe t` lets a [job](jobs.md) run the
profile (see [Jobs and your Claude settings](#jobs-and-your-claude-settings)). Keys and tokens are
never written there — the agent reads them from its environment or its own login. The built-in `claude` profile
runs the unmodified `claude-agent-acp` (npm package `@agentclientprotocol/claude-agent-acp`) when it is installed, with
your own Claude login. Onboarding's Agents step installs Claude Code, Node and that adapter if they are missing
(asked first), opens a terminal for the login and checks that the profile starts
([onboarding.md](onboarding.md#setting-claude-code-up)); to check it again later, run Onboarding: Agents.

**Which adapter runs.** The deprecated package `@zed-industries/claude-agent-acp` (frozen at 0.23.1, which drgnx
installed before) installs a program of the same name. It never tells drgnx which MCP server a tool comes from, so the
jobs permission check can only go by the tool's name. A profile whose command is the bare `claude-agent-acp` (the
built-in ones) runs the first `claude-agent-acp` on the `PATH` that belongs to `@agentclientprotocol/claude-agent-acp`,
read from the `package.json` the program links into; failing that, the first one on the `PATH`. When that is the
deprecated package it still runs, and the first time in each Emacs a message says how to move. `drgnx doctor`
warns about it too (check `claude-adapter`, which also wants version 0.93.0 or newer). The one-line fix replaces it
in the same npm prefix:

```sh
npm uninstall -g --prefix PREFIX @zed-industries/claude-agent-acp && npm install -g --prefix PREFIX @agentclientprotocol/claude-agent-acp
```

The doctor and the message fill in `PREFIX` (a prefix in your home folder is written `~/…`, for the shell to
expand). The old package is removed first because npm will not install a program over another package's. drgnx
never runs this command for you: until you do, the old adapter keeps working. An adapter that is not in a global npm
prefix (pnpm, volta, a project's `node_modules`) gets no npm command: the advice is to replace it, with the tool that
installed it, by `@agentclientprotocol/claude-agent-acp` 0.93.0 or newer. A pre-release version is compared without
its suffix (`0.93.1-rc.1` counts as 0.93.1). drgnx reads only a regular `package.json` of at most 64 KiB; anything
else counts as a program of no known package. A copy of the program (no link) with both packages beside it counts
the same way, since drgnx cannot tell which one it came from. A command given as a path
(`:command ("/opt/x/claude-agent-acp")`) runs exactly that program.

A session's **panel** (RET on its row in the Agents list, Enter on its card on the Work map, `agents-panel`) shows its
steps, what waits for you and the composer; see [agent-panel.md](agent-panel.md). It replaced the old transcript, the
old Agents view and its hunk-by-hunk review. The **Agents list** (*Show Agents*, the dock's Agents tab) has one line for
each session the hub runs: its name, status, how full its context is and what waits for you (queued messages,
permissions to answer, edits to review). A line is drawn again only when its session changed; nothing is drawn while no
window shows the list. With no sessions it says how to start one (*New Agent Session…*). The Agent layout
([layouts.md](layouts.md)) puts this list on the right and the panel of the agent that acted last beside your file.
Sending, Stop, queued messages, the context breakdown and answering are the panel's (*Answer Agent…* in the palette
picks an option for a pending permission without opening it).

Nothing an agent asks is ever a question in the minibuffer: the agent waits, the Agents tab says "1 to answer",
and you answer when you look.

Each pending permission ("NAME asks: TITLE", opens Answer Agent) and each edit to review ("NAME wants to write FILE",
opens Show Agents) is also one item of the one "needs you" count ([notices](../develop/core.md#notices-drgnx-noticeel)): source
`agents`, scoped to the session's job, for sessions this Emacs runs and the hub's sessions it mirrors alike. It leaves
the count when you answer it, when the turn is stopped, or when the session ends. Noting it costs nothing while an
agent streams: the set is rebuilt only when a session's permissions or edits to review change.

Each agent's own settings (its routes and billing, MCP servers, hooks and skills) are on its settings page: `,` on a session's row, or Agents: Settings ([agent-settings.md](agent-settings.md)).

The hub holds your agent sessions itself: it starts the agent, keeps its transcript, and lists what it asks. A
permission request stays on the session until you answer it; nothing another agent says counts as your answer. An
agent reads and writes files inside its session's folder only, and a brainstorm session writes only its design
document.

## Checking an agent

Onboarding's Agents step (and anything else that wants to know whether a profile works) asks the hub to check it,
without making a session. The hub starts the profile's program as it would for a chat — its lock, its sandbox, a
scratch folder of its own — sends the ACP `initialize` request, waits (15 seconds unless the caller says 1 to 60), and ends the
program and everything it started. The answer says `ok` and the name and version the agent gave, or why not: it did not
answer in time, it could not start, or it ended first, with its exit status and the last 2 KiB of its error output (secrets
blanked out). Nothing is recorded and no gateway token is made for it. The check is yours alone: an agent cannot ask it.

## Why was this step refused?

A step an agent asked for can be refused before you see it:

- **by the permissions matrix**, when its cell is `never` ([security.md](security.md#the-permissions-matrix)). Nothing
  is refused unseen: the chat gets a line saying what was refused and why ("refused: Edit README (code.edit is never
  allowed here)"). A chat's change of a file, which the presets never allow (a chat edits your checkout only through
  pair mode), waits on a card instead when you may turn Pair on: a yes pairs the chat and it makes the change again
  through pair mode ([pair-mode.md](pair-mode.md)). A shell command a chat runs counts as a change unless it is one
  plain read (`ls`, `cat`, `head`, `tail`, `wc`, `rg`, `grep`, with no `;`, `|`, `>`, `$(` or the like); git always
  counts as a change, since a repository's own git config can run commands;
- **by the freshness check**, when the agent of a job has not read the job's decision log;
- **by a rule or a plugin's hook** before the tool call ([plugins.md](plugins.md#before-a-tool-call)). The agent is
  told in drgnx's words, with the rule's or hook's quoted ("drgnx refused Bash; the hook deny-rm-hook said: «no rm
  -rf»"), and the step's provenance in the timeline (`timeline/get`, each step's `hooks`) lists every rule and hook
  that looked at it, what each said and how long it took. A hook that failed or timed out refuses too, and says so
  ("hook NAME failed: timed out").

A note a rule or hook added shows under the step. The session's `hooked` mark says which kinds of step its hooks see
and which the agent runs without asking.

**In the panel** a hook's word is a line under the step, in theme colours: `⛔ refused by deny-rm 0.1 · "rm
outside the worktree"`, `↻ changed by rewrite-commit-msg`, `✎ note by annotate-edit · text`, `⏳ NAME 0.1 was busy: its hook
did not run` (a hook the plugin host had no room for, told apart from other failures), and, for a hub tool, `hooked at
the hub's server`. Press RET on a line for its provenance: the source, version and hash, the verdict, how many
milliseconds it took and what the hook was asked (the point, where it ran, the tool and the step). The lines come from
what the hub already told the editor: nothing is asked while the panel is drawn, and a step the editor was not
watching when it ran has no line (its note still shows).

**The chips** above the steps say `context N%` and, when the agent sends a breakdown (an agent from the org's
adapter forks does: Claude, Gemini, Kimi Code, DeepSeek Harness; Codex and others do not and show none), the figure opens the breakdown: a bar of the parts of the window
(system, tools, files, tool output, conversation, free), each part's items, `[drop]` and `[pin]` for an item where the
agent offers them, and `[What /compact keeps]` where it can tell (nothing is compacted by looking). The header also says
`not hooked: KINDS` for the kinds of step no hook reaches (with why), `hooked by the adapter: KINDS` for those the agent's
adapter enforces itself, and `plugins changed: restart the session to use the new set` when you approved or disabled a
plugin after the session began (a session keeps the plugin set it started with).

## Reviewing an agent's edits

An agent's edits show as cards in the panel, where you accept or reject each hunk ([agent-panel.md](agent-panel.md)); the retired Agents view's
diff review (Review, Done, Reject) is gone. Reads (`fs/read_text_file`, also a range of lines) get the file as it is in Emacs, unsaved
edits included; both need absolute paths. A read is served only for a local path (never a remote, TRAMP one) and,
when no buffer visits it, only for a regular file of at most 10 MiB (`drgnx-agents-read-max`): a FIFO or a device is
refused, never opened. The file is read with no file name handlers: a `.gz` or `.gpg` file comes back as its bytes
(never decompressed or decrypted in the hub), and a link that leads nowhere is "not a regular file". An agent never
gets a file bigger than 10 MiB, open or not: a buffer over that size, or a large file drgnx holds in chunks, lean or
raw, is not served, and the file on disk is read instead, under the same limit.

## Durable jobs

Background work that must survive a closed frame, a restart of Emacs or an interrupted chat runs as a **job of the
hub**: tree-sitter grammars, Mermaid diagrams, the Playwright server of Test Report, local AI
servers, and the installs of onboarding all start with `drgnx-exec-start`
(`docs/guide/jobs.md`, "The editor's jobs"). The hub runs each in a unit of its own and keeps its log and exit code, so
any Emacs lists it in the Agents tab (running, done, failed, stopped, gone), shows its log (Show Job Log) and stops it
(Stop Job). Starting a job is asynchronous: the hub answers a moment later, and a start it refuses (a `name`, `env`,
`memory_max` or `nice` it does not accept) is a message. A job can be memory-capped (`:memory-max "1G"`: the unit's
`MemoryMax` on Linux; macOS has no cap for jobs, so drgnx asks for none there) and made nicer (`:nice 10`). A job's
time box is an hour unless the caller asks for more: the servers drgnx keeps (the local AI runner, the Playwright
server) run with no time box, so a daemon left up for days keeps them, and the runner is started
again when it is down. Commits a job makes while it works on a task are recorded for that task ([Work tracker](work.md)).

## The job sandbox

The agents of a [job](jobs.md) run in a sandbox: bubblewrap (`bwrap`) on Linux, `sandbox-exec` on macOS. Inside,
they see the system, your toolchains read-only, their task's folder and a private home, and nothing else of yours
(how it works: [Gleipnir](../develop/gleipnir.md)). `drgnx doctor` says whether it works here, in the Agents
group:

```
OK    job-sandbox          bwrap 0.12.0 ok
```

or a warning with the reason and the fix (it reads what Ratatoskr, the agent runtime, reports). Without a working
sandbox, jobs do not start. What to install:

- **Fedora, RHEL:** `sudo dnf install bubblewrap`. **Debian, Ubuntu:** `sudo apt install bubblewrap`. **Arch:**
  `sudo pacman -S bubblewrap`. **openSUSE:** `sudo zypper install bubblewrap`. drgnx uses only a `bwrap` that only
  root can change (`/usr/bin/bwrap`, or one on `PATH` in a root-owned directory).
- **Ubuntu 23.10 and later** restrict unprivileged user namespaces with AppArmor ("AppArmor restricts unprivileged
  user namespaces"). The doctor gives the command that loads Ubuntu's `bwrap-userns-restrict` profile, which lets
  bwrap make them.
- The Agents group's `ratatoskr` line also says whether the job sandbox of the new runtime could start here ("job
  sandbox backend: bwrap 0.12.0 works here …", or why not and the fix). Job agents do not use it yet, so it never
  changes the line's status. `ratatoskr sandbox check` shows the same with more detail.
- **macOS** ships `sandbox-exec`.
- **Inside a container** there is no sandbox for jobs: run drgnx on the host.

Your toolchains under `~` are found from `PATH` and bound read-only: the install dirs of mise, cargo and rustup, go,
nvm, npm's prefix, pipx and uv, and the `PATH` dirs themselves (`~/.local/bin`). A link in a `PATH` dir to anything
else (a script in your dotfiles or another repository) brings that one file, never the directory it is in; nothing
of `~/.config`, `~/.local/share` or `~/.cache` comes in but those install dirs, and nothing of drgnx's own. The token
files package managers keep in the install dirs (`.npmrc`, `etc/npmrc`, `.pypirc` …, `drgnx-sandbox-secret-files`)
are hidden. Where systemd runs your session, each agent also runs under a memory cap,
`drgnx-sandbox-memory-max` (4G; nil for none), so one agent's build cannot run your session out of memory.

## The hub and the gateway

Agents on **OpenRouter, Ollama, your own Anthropic key, Kimi or DeepSeek** (profiles with `:ai claude-openrouter`,
`claude-ollama`, `claude-anthropic`, `claude-moonshot`, `claude-deepseek`) do not get your key: they talk to the **gateway**, a local HTTP server in drgnx's **hub**, with a
token of their own. The gateway checks the token, adds the real key, forwards each request and streams the answer
back as it comes (it adds well under 50 ms before the first token). For each answer it counts the tokens the
provider reports — spend per job, task and agent, kept in the work tracker's database — and when a provider fails
before answering (no answer, 429, 401/402, 5xx) it tries the next one the agent may use: role `agent`'s chain for
OpenRouter agents ([AI](ai.md)); when the last one refuses, its own status, `Retry-After` and message reach the agent. A job's budget, when it has one, stops new requests once it is spent.

**Subscription CLIs never go through it**: the plain `claude` profile (and any profile without `:ai`) uses the CLI's
own login, which drgnx only launches and never reads.

The **hub** is Ratatoskr, a background process (kept by your system's service manager, or by itself where there is none:
it outlives the Emacs that started it, and a later Emacs finds it again). The first agent that needs it starts it, with
one `ratatoskr ensure`; `drgnx hub start|stop|status [--json]` are `ratatoskr ensure|stop|status` and manage it by hand.
Where Ratatoskr is not built, drgnx says so: run `drgnx runtime build`.

**Keys.** They reach the hub over its private socket from the Emacs or `drgnx hub start` that starts or uses it (never
through its environment), from auth-source files that never ask, or from the command you ran (a key in
`~/.authinfo.gpg` is read then) — and stay in its memory. With them your Emacs sends the list of your providers (the
built-in ones and yours, `drgnx-ai-providers` in settings.el: where each is, what it speaks and does, its price; never
a key), and again whenever you change them there. A provider of yours that takes a key at an `http://` address off this machine (a server on your LAN)
works, but its key travels in clear text: drgnx says so once per provider each time Emacs starts; use `https` for it.
The hub checks an agent's providers when it starts: one with no usable provider (unknown, not speaking the Messages
API, or without its key) is not started, and says why. Tokens are kept only as hashes, so a restarted hub still takes
them; an agent's token is revoked when it exits, or once the Emacs that started it is gone (a crash). The hub keeps the environment, `PATH` included, of the Emacs
that started it, except that drgnx sends it your login shell's `PATH` when that changed ([shell.md](shell.md#your-path-in-drgnx):
at each start, and **Shell: Reload Environment**). So when an agent's program was installed while a hub ran, into a
directory on your shell's `PATH`, run Shell: Reload Environment: the agents the hub starts from then on find it. When
it went somewhere your shell's `PATH` does not reach (onboarding's Agents step adds such a directory to the running
Emacs only), run `drgnx hub stop` (its durable sessions end), so the hub the next durable session starts finds the program.
Only the hub holds keys: once it has taken a key, your Emacs forgets its copy (a key you set in the environment stays
there; [security.md](security.md#where-your-keys-live)). So an agent of a profile with a key (OpenRouter, Anthropic,
Kimi, DeepSeek) always goes through the gateway, and with no hub to be had it does not start: "the drgnx hub is not
running; agents reach providers through it". `drgnx-agents-use-gateway` set to nil changes nothing for them; it only
sends an Ollama agent (no key) to Ollama directly. An Ollama agent with no hub to be had also goes directly and says
so. An agent the hub starts (a durable session, a job's) always goes through the gateway. The Agents list's **Via**
column shows which.

### When the hub restarts

A restarted hub holds no key: they live only in its memory. Your Emacs hands them over again as soon as it reconnects,
and when the hub asks for a key its agents need, Emacs looks for it again where it can without asking anything: the
provider's environment variable (`OPENROUTER_API_KEY`, …). It never prompts then, and never opens the Keychain or a
`.gpg` file. When it finds none, a notice says "agents need your PROVIDER key in the drgnx hub: run AI: Load Keys";
run it (it may ask, since you ran it).

Your Emacs also reconnects to a restarted hub by itself: it tries again after 1 second, then 2, 4 and so on up to every
30 seconds, and starts nothing, so a hub you stopped stays stopped. After ten minutes without a hub it stops trying
and tells you once; run Hub: Restart Now to bring the hub back. Stopping the hub from your Emacs (or disconnecting)
does not start the retries.

### When drgnx was updated

A running hub keeps the program it started from. After `drgnx update` it notices the new one and drgnx shows a warning:
"drgnx was updated; the hub restarts when its N running turns finish". The hub restarts itself the first time nothing is
busy, so nothing needs doing; **Hub: Restart Now** (the notice's action, or the palette) restarts it at once, and the
agent sessions it runs end. It asks nothing and has no key by default. The warning goes away when the hub that comes
back is the new one.

A hub from before Ratatoskr (an install updated while that hub ran) is never restarted unasked: the warning says "a hub
from before this drgnx update runs; restart it to use Ratatoskr (running agent sessions end)", and Hub: Restart Now
shuts it down and starts Ratatoskr in its place.

## Kimi and DeepSeek

Kimi and DeepSeek each ship an agent of their own, and on their own APIs drgnx runs that agent: Kimi Code (`kimi
acp`) and DeepSeek Harness (`dsh --profile acp`), never Claude Code on the vendor's endpoint. On OpenRouter it is
Claude Code, with the same tools as ever and the model behind it changed (tool search is off there:
`ENABLE_TOOL_SEARCH=false`, which models that are not Claude do not speak). Four built-in profiles (listed in New Agent
Session…, the two Claude Code ones also on the Claude page of Agent Settings, with how each is billed):

| Profile | Agent | Goes to | Key | Billed by |
|---|---|---|---|---|
| `kimi` | Kimi Code | Moonshot's own API (`:ai kimi-moonshot`) | `MOONSHOT_API_KEY` | Moonshot, per token |
| `deepseek` | DeepSeek Harness | DeepSeek's own API (`:ai dsh-deepseek`) | `DEEPSEEK_API_KEY` | DeepSeek, per token |
| `claude (Kimi via OpenRouter)` | Claude Code | OpenRouter | `OPENROUTER_API_KEY` | OpenRouter |
| `claude (DeepSeek via OpenRouter)` | Claude Code | OpenRouter | `OPENROUTER_API_KEY` | OpenRouter |

Onboarding installs Kimi Code (`@moonshot-ai/kimi-code`) and DeepSeek Harness (`@deepseek-ai/dsh`, on a pinned
pre-release: it has no stable release yet) beside the Claude Code adapter. Each runs under its own lock ("What each
provider obeys" in [the security guide](security.md)); DeepSeek Harness counts as "not enforced" until drgnx's ask
plugin ships with its fork, so it runs as a chat, not a worker, under the Cautious and Balanced presets.

The former `claude (Kimi)` and `claude (DeepSeek)` profiles are retired. A profile of yours that still names their
kinds (`:ai claude-moonshot`, `claude-deepseek`) still starts, and the first start in an Emacs session says which
built-in profile replaces it.

Like the other provider profiles they go through the gateway when a hub is available: the agent holds a token, never
the key. Without a key the session does not start and the message names the variable and the keyring host to put it
under. Each session gets its route in its own environment (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, the model
names); inside the sandbox the base URL is a local port that leads to the hub's gateway only, and the token works
there alone; drgnx writes nothing to `~/.claude/settings.json`, so the plain `claude` profile keeps using your login. No
agent inherits the other vendors' keys from Emacs's environment (`drgnx-agents-scrubbed-env`; the plain `claude`
profile keeps Claude Code's own variables). The API keys are billed
per token; Kimi's coding membership is a different endpoint these profiles do not use. Moonshot and DeepSeek have no
`:price`, so the gateway counts their spend as zero. Details and the model names: [AI](ai.md#agents).

## Durable sessions

**Ask an Agent…** (palette; or type in the palette and press `Ctrl+Return`, or start with `@`) starts an agent of the
default profile in this project, opens its panel and gives it your words.

**New Durable Agent Session…** (palette) starts an agent in the **hub** instead of this Emacs: it keeps working when
you close Emacs, and the next Emacs shows it again in the Agents tab — its whole transcript, pending permission
requests and edits to review — and drives it the same way (send, Stop, answer, review). Emacs mirrors the hub's
sessions when it is idle whenever a hub is running (and looks again every 30 s of idleness); it never starts a hub for that.
Turning `tools/agents` off (Preferences: Modules) stops the mirroring and closes this Emacs's connection to the hub;
the hub and its sessions go on.
**New Agent Session…**, **Review Branch** and starting an agent on a task now start the session in the hub too (the
hub's `agents/start`); the transcript you open is its mirror. A session whose provider's lock the hub could not enforce
(for instance no sandbox on this machine) is announced once as "not enforced: <why>" and says so in
`drgnx-agents-mirror-lock-label`. A permission-matrix question (`matrix` card) or a rule that paused an agent
(`supervisor`) shows as a notice; nothing asks you in the middle of your typing. `drgnx job` talks to the hub's `job/*`
methods, which the hub itself serves.

Durable sessions live as long as the hub: if the hub ends (`drgnx hub stop`, a crash), its agent processes end too.
The next hub (the next durable session, an agent that needs the gateway, or `drgnx hub start`) brings each session
back when its agent can resume or load sessions: idle, with its history read from the transcript, and with the
messages that were queued when the hub ended delivered as the next turn; a turn that was running when the hub ended
is lost; a job's agents are not resumed (the job starts their tasks again). An update of drgnx waits for a durable
session's *running turn* to end, never for an idle chat.

**Moving a session to another model** (`agents/move`, or a manager's `agent_move`): the session stops after the tool
running now, a new session on the other profile starts in the same directory, and its first prompt is a **summary**
of the old one: the task's brief, the decisions it recorded, the task's newest report, the directory's HEAD and its
last steps. The old conversation is not copied (its transcript stays on disk) and the old session leaves the list; the
two stay linked in the graph. Codex profiles stay refused until their lock is proven. The same summary is what a
session is told when the hub restarts and its agent can neither resume nor load it.

A durable session's messages and Stop work like this:

- A message sent while the agent works is **queued** (or put ahead of the queue by `:mode steer`); it never cancels
  the turn. Only **Stop** cancels: the turn ends as cancelled, pending permission requests are answered "cancelled",
  and the queue is held until you press Deliver or send something new (a Stop on a session with no turn running
  ends the session). **Pause** cancels once the tool call running now completes, and holds the queue the same way.
- The hub keeps each durable session's transcript in `<state>/hub/transcripts/<id>.jsonl` (private to you, mode
  0600). Anything that looks like a key or token is replaced by `[redacted: kind]` before it is written, so a key
  you pasted into a message never rests in a file.
- The hub cuts every turn into **steps** (thinking, a tool call, waiting for you, paused) from its own clock and
  records them in `work.db` with the tokens each used; the timeline views read them.

## What agents get

Every agent drgnx starts gets MCP servers in its ACP `session/new`: the **coordination tools** (see below) by default,
and, when you ask for it, the **search tools** (`drgnx search mcp`, [search.md](search.md#for-agents): `search`,
`symbols`, `outline`, `repo_map` and `find_usages`) for the project the agent works in. `settings.el` holds the choice, next to `drgnx-agents-profiles`:

```elisp
(drgnx-agents-default "claude")                   ; what New Agent Session… offers on Return
(drgnx-agents-mcp (coordination search))          ; the servers; absent: coordination only; () gives none
```

Onboarding's Agents step asks for both and writes them without touching the rest of the file (comments stay); you can
edit them by hand too. The search tools let an agent read the indexed code of any of your projects, so they are off
until you say yes.

### The plugin tier of the network list

`agents-net-hosts` names the hosts each network tier reaches (`provider-only`, `packages`). A plugin's HTTP requests
are not the agent's: they have a tier of their own, `plugin`. A plugin reaches a host only when its approved manifest
names it and, unless the session's network is open, you also list it as `"host:port"` under `plugin`:

```elisp
(drgnx-agents-net-hosts ((plugin "api.example.com:443")))
```

The agent's own tiers are never consulted for a plugin, and addresses on your machine or your network stay out of
reach whatever the lists say ([plugins.md](plugins.md#installing-and-approving)).

### What a session gets with the browser

When the matrix's `browser` cell allows it (Balanced: managers and workers; a chat asks), a session also gets a
headless browser inside its own sandbox ([agent-browser.md](agent-browser.md)). Its agent finds it at
`PLAYWRIGHT_MCP_CDP_ENDPOINT` (and `DRGNX_BROWSER_CDP`): a `ws://127.0.0.1:9222/devtools/browser/…` address with a
secret of its own, set by the hub. Playwright MCP and other CDP clients connect there with no setup. The browser
reaches the agent's own servers inside the sandbox on the ports of `drgnx-agents-browser-local-ports`, and everything
else only through the session's web proxy, as the `browser.web` and `browser.private` cells say. With a user systemd the session and its browser share
one memory cap (`drgnx-agents-session-memory`); near it, the browser is stopped and starts again at the next use.

A host that cannot give the browser (no bubblewrap full tier, a kernel below Landlock ABI 9, no browser found:
`drgnx browser install`) starts the session without it. Its `agents/get` says why, and you see one notice with the fix.

### What modules add to a session

A module can add variables to the environment of an agent you start from the editor (no module of drgnx does now;
the Live view no longer starts a browser for agents, [live.md](live.md)). The editor sends them with
`agents/start`, and the hub starts the agent with them after the profile's own variables. Only the names in
`drgnx-agents-start-env-names` go through, and by default there are none:

```elisp
(drgnx-agents-start-env-names ())   ; only you can change it, never a repository or an agent
```

A name that is not on the list is dropped, with one notice naming it. A name that looks like a credential (it contains
`KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSPHRASE` or `CREDENTIAL`) never goes through, whatever the list says: keys
reach agents through the gateway, not the environment. Agents the hub starts on its own (a plan's workers, a manager's
workers) get no module variables. The hub keeps a session's module variables with it: when the hub restarts, or resumes
a session that waited on a job, the agent gets them again (less any name you took off the list since).

## Jobs and your Claude settings

A [job](jobs.md)'s agent works unwatched, in a repository you may not have written, so nothing in a settings file may
let it act without asking. When a job runs a profile on Claude Code's adapter (when either the package of the
program it starts, `@agentclientprotocol/claude-agent-acp`, or a file name in its command says so: a pnpm, volta,
asdf or mise shim counts by its name), its `session/new` and `session/load` carry
options for the adapter (`_meta.claudeCode.options`, `drgnx-agents-job-claude-options`), and that session's Claude
**ignores**:

- the **allow rules and hooks** of your user settings (`~/.claude/settings.json`, or `settings.json` in
  `CLAUDE_CONFIG_DIR`), the project's (`.claude/settings.json`) and the local ones (`.claude/settings.local.json`) —
  drgnx passes the policy tier (`allowManagedPermissionRulesOnly`, `allowManagedHooksOnly`), so a tool you allowed
  for your own sessions asks in a job;
- **bypass mode** (`bypassPermissions`, `--dangerously-skip-permissions`) from any tier;
- **any default mode**: once the session is made or loaded, drgnx sets its mode to `default` (ACP
  `session/set_mode`) before it takes a turn, so neither `auto` nor `acceptEdits` from any settings file, nor the
  mode a resumed session last had, applies. An agent that refuses ends the session (the job then falls back or
  shows a card);
- **MCP servers** other than drgnx's own: a repository's `.mcp.json`, your user and plugin servers and those of
  agent definitions are not started (`strictMcpConfig`).

The policy tier makes Claude ignore the deny and ask rules of those files too, so drgnx copies them into it: the
**deny and ask rules** of your user, project and local settings still apply (an allow rule is never copied). drgnx
reads those files when the session starts: regular files up to 1 MB that parse as JSON — your user settings file
may be a link (as stow or home-manager make it), while the project and local ones must be plain files inside the
task's folder, never links; any other is skipped. `CLAUDE.md`, skills and agent definitions still
load (which settings files Claude reads is left as it is: they are content, and the permission check bounds what they
can make the agent do). Claude Code's own sandbox is off in a job: drgnx's is the boundary.

Every Claude session drgnx starts, a job's or your own, gets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in its
environment and its options: no auto-updates, telemetry, error reports, release notes or feature-flag fetches
(Claude Code's [environment variables](https://code.claude.com/docs/en/env-vars) and
[network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements)). Its
sandbox's proxy would refuse those hosts anyway ([security.md](security.md)); the variable keeps the CLI from trying.
Features that need feature-flag fetching, such as Remote Control, are not available in a drgnx session.

Your own sessions (New Agent Session…) and agents other than Claude get none of this. Other agents
(Gemini CLI, Codex) have no such switch yet, so a job runs only **job-safe** profiles (`drgnx-agents-job-safe-p`):
those whose options say `:job-safe t` and that run Claude Code's adapter, so a job-safe profile always gets these
options. drgnx's built-in profiles say so (their bare `claude-agent-acp` is the adapter drgnx chooses, a shim
included). A profile of yours may say so too, but it counts only when the program it starts belongs to the
adapter's npm package (read from its `package.json`): a wrapper whose name says claude gets the options above, not a
job, and a profile that runs any other agent is never job-safe, whatever it says. On macOS a profile without `:ai` (the
plain `claude`, which logs in with your subscription, its token in the Keychain) is not job-safe: jobs there use the
gateway profiles. A job routed to a profile that is not job-safe starts no agent: the task gets an **agent** card
that says why and names the profiles that may run it ([jobs.md](jobs.md#routes-and-the-estimate)). Since a job's
Claude starts only drgnx's MCP servers, list a server you want in jobs as the profile's `:mcp-servers`. On a machine whose administrator installed a `managed-settings.json`
(`/etc/claude-code/` on Linux, `/Library/Application Support/ClaudeCode/` on macOS), Claude Code uses the
administrator's policy instead of drgnx's unless that file sets `"parentSettingsBehavior": "merge"`; the refusal of
bypass mode, the `default` mode and the MCP lock hold either way.

Tests: `test/unit/agents-claude-options-test.el` (what job sessions send through `session/new` and `session/load`,
the mode set before any turn and a refusal ending the session, deny and ask rules copied and allow rules never,
the folder's settings files that are links or do not parse skipped and a linked user file followed, nothing for your
sessions or other agents, the lock for a shim install and for a program that only has claude in its name, a
repository's bypass settings and `.mcp.json` changing nothing sent, an
environment value JSON cannot carry ending the start without showing it).

## Working together

Every agent drgnx starts — durable or not — gets drgnx's **coordination tools** (an MCP server): the job's tasks
and agents, messages to other agents or to you, and the **decision log** (what is being built, what waits on what,
what will not be built, what replaced what). The log has a version; an agent that acts — claims a task, finishes
it, records a decision, sends a message — says which version it last read, and when the log moved on since, drgnx
**holds the action** and shows it what changed. An agent's decision about its own task counts at once; one about
anything else is only proposed, for you (and, with jobs, a reviewer) to decide.

Messages never interrupt: an agent gets one as a new turn once it is free (not while it works, not while you have
stopped it), and each goes queued → delivered → read → acted on. A message is only text to the agent that gets it,
quoted and marked as coming from another agent: it never answers a permission request, never approves anything,
never changes a setting. Your own answers and messages (a reply to a job's agent, an answer from the Work space)
reach it as yours, unquoted: `[message from the user #N — the user's message]`, or `[message from the user #N — the
user's answer to your question #Q]` and the question's words on a quoted line when drgnx knows which question it
answers. No agent can send as the user. Two agents writing to each other too fast, or a full queue, holds the rest. Agents of a job
hear about that job's new decisions (once per change); a plain chat session is never woken for them. A task an
agent claimed is a lease, kept while the agent runs and while the task waits on you; if the agent is gone for 15
minutes the task is free again (the Work space's What needs you shows it; messages and escalations to you wait
there too). **Jobs** put several agents to work through a plan you approve, each task in its own worktree, reviewed and
merged into the job's branch: [jobs.md](jobs.md). Developer details: [coordination.md](../develop/coordination.md).

## Working on shared tasks

Besides a job's tasks, agents keep a shared task list in their project: they create tasks, split them, link them
(what blocks what, what is part of what), label them and claim them. Only tasks of the agent's own project can be
changed; tasks from your plans and your board are your files', so an agent adds a note or a task that relates to
them instead.

- **One agent at a time.** Claiming a task holds it for 15 minutes, renewed while the agent works. If another agent
  reassigns it (always with a note saying why) or the claim ran out and someone else took it, the first agent is
  told to stop at its next step, and its late changes are refused.
- **No lost edits.** Two agents changing the same task: the second is told what changed since it read it and
  re-reads. Labels and links are added and removed one by one, so nothing is overwritten.
- **Ready is worked out**: a task is ready when nothing open blocks it and its parts are done. A link that would make
  tasks wait on each other in a circle is refused.
- **Your tasks stay yours.** On a task you made, an agent adds notes, links, labels and the priority; it changes the
  title, body or acceptance only with your permission and never drops it. Without permission, an agent's "done"
  is `in-review` and you close the task. With **only I close my tasks** on, even a permitted "done" is only a
  proposal: a card for you, and the task waits.
- **Agents are told** when someone else changes a task they hold or are assigned, when a task they wait on becomes
  ready, and when they lose a claim. Notices about the same task are merged until read.

### Tools for tracking work

Five tools carry this to agents, on by default for every session, including agents outside drgnx:

- `task_read`: one task by id (with its links, notes and history), a search by words, the tasks that are ready, the
  agent's own.
- `task_write`: create, update, claim, hand off, split, complete, link, label.
- `note_add`: a progress note, finding, question or handoff about a task, decision, plan, file or symbol.
- `graph_read`: what is around an entity, a path between two, who changed what, who touched a file.
- `access_request`: asks you to let the agent read another project. It never waits; you answer on a card.

Agents see their own project and the projects you granted them. What other agents (and the agent itself, earlier)
wrote is handed over as untrusted data with its author, never as instructions. Every answer says how many notices wait,
and an agent's first `hello` brings a short brief: its project, its tasks, what is ready, its notices.

To turn the five tools off for a profile, set `:tracker-tools off` on it in `drgnx-agents-profiles` (settings.el); for one task, the user sets
it with `tasks/write` (op `tools`). The task's setting wins over the profile's: a task with the tools on gets them
even under a profile that turns them off, and the other way round; with neither set they are on. A session keeps the
list it started with (23 tools with the tracker tools, 18 without; the two settings tools of
[Changing settings](#changing-settings) are always there). The editor tells the hub at each session start:
the profile's name (as an id: `claude (OpenRouter)` is `claude-OpenRouter`) and its `:tracker-tools` value, when it
has one. "Only I close my tasks" is the user option `drgnx-store-only-i-close-my-tasks` (default off): with it on, an
agent's `done` on one of your tasks waits for your acceptance; the editor sends it when it connects and when you
change it.

## What an agent can read

drgnx's store (tasks, decisions, notes, and how they link) is shared by every agent, but each agent reads only its
own **project**: the git repository it was started in, all of its worktrees included (a repository is known by its
first commit, so renaming its folder changes nothing). An agent started outside any repository reads nothing but the
names of agents, unless a grant opens a project to it, and writes nothing. Things in other projects are left out of what it reads and only counted ("3 hidden"), never named.

To let agents read another project, give them a grant (an agent can ask for one; the request waits for you in the
Work space): for every agent in a project, for one profile, or for one session, until you revoke it or it expires.
Grants open reading only: agents still write only into their own project. Whatever another agent wrote reaches an
agent marked as that agent's text, as data rather than instructions. More in
[security.md](security.md#grants).

## What agents may do: the matrix setting

`drgnx-agents-matrix` in `settings.el` says what agents may do without asking. The shipped value is the Balanced
preset; `(:preset cautious)` and `(:preset autonomous)` are the other two. Beyond the preset:

```elisp
(drgnx-agents-matrix
 (:preset balanced
  :time ((:when away :preset cautious)                    ; while you are away
         (:when (between 1320 420) :preset autonomous))   ; 22:00 to 07:00, local time (minutes of the day)
  :cells ((:action push.main :column (:role worker) :verdict never)
          (:action spend :column (:agent "claude") :verdict ask :limit (:amount 2 :unit usd)))))
```

An action is one of the matrix's rows (`commit`, `push.main`, `spend`, `network`, …: the hub's ids, listed in
`drgnx-agents-matrix-actions`); a column is `(:role manager|worker|chat)`, `(:agent NAME)` or `(:provider NAME)`; a
verdict is `allow`, `ask` or `never`; a limit's unit is `count`, `usd`, `usd-est`, `tokens` or `limit-share`. The most
restrictive matching column wins.

Autonomous is also the only preset under which a plan you described in one prompt can start without your OK, and
only within its cells ([Say it](#say-it)).

The editor tells the hub when you are **away**: after `drgnx-agents-away-after` seconds (600) without input it sends
`presence/set`, and again on your next input. The time presets follow from the next action. An agent never sends it.

Only you set these: they are `:workspace never` (a repository's `.drgnx/settings.el` and `.dir-locals.el` are refused
with the line) and `:agents never` (the `settings_change` tool refuses them). They are `drgnx-agents-matrix`,
`-away-after`, `-wait-refusals` (3), `-close-idle-after` (1800 s), `-checkpoint-cap` (2 GiB), `-job-memory` ("4G"),
`-job-cpus` (2), `-container-images` (name → digest-pinned image), and the supervisor's `-silent-after`
(task 600 s, brainstorm 1800 s), `-repeat-limit` (3), `-no-progress-tokens` (20000) and `-manager-context` (0.7).
The agent browser has eight more, each with its unit in the docstring (see the
[settings reference](../reference/settings.md)): `-browser-program` (nil: find one), `-browser-local-ports` (3000
3001 4173 4200 5000 5173 8000 8080 8888), `-browser-deny-hosts` (nil), `-browser-max-message` (64 MiB),
`-browser-idle` (600 s), `-browser-once-window` (600 s), `-session-memory` ("4G", the browser included) and
`-browser-memory-high` (75 %).
The hub reads them from `settings.el`.

## Changing settings

Every agent has two settings tools. Your settings stay yours: an agent changes one only under your grant, the editor
writes the file (the hub never does), and the change goes into the setting's history, so Settings can undo it.

- **`settings_get {scope, names?}`** reads settings and where their values come from. `scope` is `global`
  (`settings.el`), `private` (your workspace file for the agent's project) or `shared` (the repository's
  `.drgnx/settings.el`). It needs a grant: an `options` grant of that scope, or a read grant that covers it (`*`, or
  the agent's own project for `private` and `shared`). With no editor open the answer says `complete: false`: the hub
  knows `settings.el`, the shipped defaults and what the editor last sent, but not your Lisp or the workspace files.
  The editor answers only settings (drgnx's, described ones and `defcustom`s): a plain variable, a security setting
  (one agents may never change) or a name that looks like it holds a secret (`password`, `token`, `secret`, `auth`,
  `credential`) comes back "not shown to agents", with no value.
- **`settings_change {scope, name, value, reason}`** asks to change one setting. The value is Lisp data (`80`,
  `"text"`, `(a b)`), read as data and never run; a value or a reason that looks like a secret is refused. The
  security settings are never an agent's, under any grant: drgnx's agent, sandbox, trust, keys and module settings,
  `load-path`, `eval`, `custom-file`, and any name that names a program, a hook or a function (the full list is
  `test/fixtures/settings-deny.json`); the editor adds the settings marked `:agents never`. A name no variable has
  (a keyword such as `:eval`, `nil`, `t`, or one with a space or any of `` ()";'`,#[]\ ``) is refused before any grant.
  - **Under a grant** the change is recorded as a *proposed* change of the agent's, and the editor checks it again,
    writes it to the file the scope names and confirms it; the agent's answer says `changed`, or `refused` with the
    editor's reason. With no editor open it stays proposed (`pending`) until you settle it.
  - **The editor's check** is the last gate before a file is written: a setting marked `:agents never`, a security
    setting (`:workspace never`), code (`:workspace code`: functions, hooks, risky and program-naming settings), an
    `:eval` section or the `eval` and `mode` pseudo-variables, a value that does not read as data, does not match the
    setting's type or bounds, or looks like a secret: each is refused and nothing is written.
  - **Where it lands:** `global` in `settings.el`; `shared` in the `.drgnx/settings.el` of the folder the agent's
    session works in (a job's task folder, or the checkout it started in), refused when that file's true path leads
    out of the folder; `private` in that folder's private workspace file (made when there is none).
  - **You are told** with a notice, "s1 changed fill-column to 100 in drgnx [Undo]". **Undo** writes the earlier value
    back (or removes the entry the agent added) and records it in the history as an undo of the agent's change; it
    refuses when the setting changed again since. The change is in the setting's history once, under the agent's name.
  - **Without a grant** you get a card in What needs you, "Change NAME to VALUE in …" with the agent's reason:
    **Allow once**, **Allow this setting for this session** (a grant for that one
    setting, until the session ends or a day passes) or **Deny**. The agent goes on meanwhile; your answer comes to
    its inbox.

To let agents change settings without asking each time, give them an `options` grant: `graph/grants` with access
`options`, what `options:global` (your `settings.el`) or `options:project` (the private and shared settings of their
own project), and optionally `names`, globs such as `python-*` (none: every name the deny-list leaves). A grant opens
settings in the agent's own project only. Agents outside drgnx never change a setting, grant or not.

## Suggesting an extension

**`extensions_suggest {id, why}`** lets an agent suggest a package (`pkg:NAME`) or an installed plugin
(`plugin:NAME`) from the Extensions catalog. It makes a card and you decide (docs/guide/extensions.md, "Suggested by an
agent"); the agent never installs, approves or trusts one, and no tool lets it. An id the catalog does not hold is
refused. The card's title is the hub's ("s1 suggests magit (MELPA)"); `why` is kept only as a quote, on one line, at
most 280 characters. One open card per package, the sessions' quotes on it; at most three suggestions a session;
a session's quotes leave the cards when it ends, and a card with none left is withdrawn. Only sessions drgnx runs may
use it; an agent outside drgnx is refused.

## Agents outside drgnx

Agents you run outside drgnx can report to it too: Claude Code in a terminal or in Zed, Codex, gry workers and their
subagents. Give the agent Ratatoskr's bridge as one more MCP server (stdio), with `KIND` set to the kind of
agent (`claude`, `codex`, `zed`, …: a short lower-case name):

- command: `<data>/bin/ratatoskr` (the installed binary; the path stays the same across updates)
- arguments: `mcp-bridge --outside --kind KIND`

For Claude Code, that is `claude mcp add drgnx -- <data>/bin/ratatoskr mcp-bridge --outside --kind claude`. For Codex,
it is a `[mcp_servers.drgnx]` table in `~/.codex/config.toml` with `command` and `args` set as above. Each agent's
settings page can add it for you. Configs written before the bridge (`<checkout>/bin/drgnx coord mcp --kind KIND`)
keep working: that command now runs the bridge.

The agent must start the bridge in its project folder (`--cwd DIR` names it when the agent cannot). drgnx takes the
folder it starts in (its git worktree) as the place the agent works. A bridge started in your home folder, or at `/`,
can say hello, but its file reports are refused.

The bridge survives a restart of the hub: while the hub is away the agent still sees its tools, a call waits up to 10
seconds and then reports "drgnx hub restarting; retry", and a call that was running when the hub went is reported as
an error, never sent twice: the agent checks before it retries. After 10 minutes without a hub the bridge ends. It
refuses to connect when the hub's socket folder is open to other users.

The agent then gets four tools to report with:
- **hello**: who it is and where it works;
- **report_edit**: the files it changed (paths only);
- **report_test**: the tests it ran and how they went;
- **ask_user**: a question that waits for you, never a prompt.

It also gets the messages and the decision log, like drgnx's own agents. Its reports are recorded now, and the Work
Work space is where they will show. **Coming with the Work space** (later in this milestone): each reporting agent
shown with its name, folder and branch, the files it changed with their diff since it said hello, its test runs and
its questions. You will answer a question there, and your answer will reach the agent as a message.

What an outside agent cannot do:
- **pass for another agent.** Its identity comes from its own process (`ext:KIND:PID-HASH`: its process id and when
  that process started), never from what it says. A name it gives is only a label.
- **touch drgnx's jobs.** It cannot claim, update or finish a job's tasks, or record decisions; it is told to report
  its work instead. It asks you with ask_user rather than the escalate tool of drgnx's own job agents; anything else it sends you is a
  message, never a question waiting on you, whatever it says.
- **report a file outside the folder it was started in** (that folder's git worktree), a path with `..`, a symlink
  that leads out, or a remote file.
- **flood you.** It may make 20 reports and messages a minute together (`drgnx-coord-report-rate`). Past that, they
  are held, and nothing is written. One card an hour tells you which agent is reporting too fast. Its questions and
  messages are cut to 2,000 characters, and characters that hide or reorder text (controls, BiDi overrides) become
  spaces.

**Coming with the Work space:** an agent that does not report — no drgnx server in its config, or it never says
hello — will still show there when it works in a git worktree, with the worktree's changes and its ledger, marked
**not reporting**.

## Say it

Say what you want done in one prompt, and the hub turns it into a proposed job (`say/start`). In the editor, **Say It**
(from the palette) asks for your words and plans in the current project's repository; nothing blocks while it plans.
When the proposal is ready you get a notice ("A proposal is waiting for your OK"), and **Show** opens it; when the
Autonomous preset started it at once (below), the notice says "Started by the Autonomous preset" instead, and **Show**
opens the running job. A planning chat drafts the plan with no access to your repository or your records: it
sees only your words and a list of your profiles, routes and roles. Each task gets a role, a profile when it names
one, and a body that becomes the start of its brief. The hub checks the draft (known roles and profiles, at most 32
tasks, no task over 16 KiB, no dependency loops, a budget in dollars) and asks the chat again when it does not hold;
a question from the chat comes back to you instead.

The job then waits for your OK, like any proposal: the proposal card's title is the hub's, never the chat's, and
nothing either of you writes ("approved", "start now") counts as one. `say/revise` changes it: the proposal standing
is withdrawn and a new one replaces it. `say/end` closes the planning chat; its proposal stays.

One prompt makes at most one running job. Once its job has started (you approved it, or the Autonomous preset
started it), the planning is done and the chat closes: `say/revise` is refused with "JOB has started: stop it, then
say it again", and a revision already on its way when the job started comes back as `say-failed` with the same
reason. A revision never stops work that is running; stop the job yourself, then say what you want again.

**The proposal buffer** (also **Say It: Show Proposal** in the palette) shows the hub's facts first: status ("not
known" when the hub did not answer), tasks and profiles, the budget with its unit (on a plan with a subscription it
says it binds the estimate too), the forecast
(cost, tokens and time as ranges: a middle and a high end, one run in ten goes past it), the cold wakes inside it
("of which wakes"), the manager's own spend beside the total, what the plan does to each subscription's week ("at this
pace: Thursday; with this plan: Wednesday (estimate)", or "no pace yet"), warnings and the date of the price table.
Under **Basis** each task says what its forecast came from ("12 implement tasks on sonnet"). A profile with no price
reads "not priced" with its tokens and time, never a zero. The planning agent's job title and task titles come last, under
"Written by the planning agent". `C-c C-c` approves (the job starts and the planning chat ends), `C-c C-e` asks for a
change (it reads your words in the command) and `C-c C-k` rejects (the job stops and the chat ends); each is also in
the palette as **Say It: Approve**, **Say It: Revise** and **Say It: Reject**. A question from the planning chat comes
as a notice whose **Answer** reads your reply (**Say It: Answer** in the palette answers the latest one), and a planning that failed says why. **Forecast Accuracy** (palette)
lists, per role and profile, how many finished tasks were forecast, how many stayed within their high end, and the
median of actual over middle.

**Under the Autonomous preset** a Say proposal starts without the OK when the preset's own cells cover all of it:
the manager may start that many agents (8), the plan's p90 cost in `usd` and `usd-est` together, counted as dollars,
is within its spend cell ($150), every task has a price, and no subscription's limit would run out at the plan's p90
before it resets, whether that is the week, the week's last day or a shorter window. A subscription with no meter reading yet means the week cannot be checked, so the proposal waits.
When it starts alone, the job's decisions say "started by the Autonomous preset within its cells"; when it waits,
the job says why.

## Reading a forecast

Every proposal, whether from Say it, `job/propose` or Start as Job, shows a forecast before anything is dispatched:
tokens, active and wall time, and cost, each as a range ("about 12–41 USD (estimate), 40M–130M tokens, 2 h 10–4 h").
`forecast/get` gives the same numbers per task.

- **A range, not a promise.** The first number is the middle (p50): half the similar runs took less. The second is the
  high end (p90): about one run in ten goes past it. Agent runs of one task can differ many times over, so a narrow
  range is never promised.
- **Where it comes from.** Each task says its basis: "12 implement tasks on sonnet, this project", "5 implement tasks on
  claude", "9 review tasks on another model, repriced" or "no history: prior". Until a class has five finished tasks
  the forecast is a labelled prior with a wide range. Every finished task adds to the history, so the next proposal of
  the same kind is forecast from it. Once enough of them were forecast and finished, the high end is scaled by how
  often it was missed (the task says it is calibrated). The plan's total is scaled the same way by how often whole
  plans went past their high end, once nine finished plans were forecast; that total is what the Autonomous preset
  checks against its spend cell and the week. `forecast/accuracy` shows, per role and profile, how many tasks
  finished, the share that stayed within their p90, and the median of actual over p50.
- **Wakes and the manager.** The wake line ("of which wakes: 1–3 cold, about 3 USD") is part of the total, not added to
  it. A manager's own spend, where history has one, shows beside the total.
- **`usd` and `usd-est`.** On a gateway profile the cost is exact dollars (`usd`). On a subscription it is what the
  tokens would cost at API prices (`usd-est`, labelled estimate): your subscription is not charged that. A profile with
  no price shows tokens only and is listed as unpriced, never as 0.00.
- **The price table.** Tokens are priced by `drgnx-agents-model-prices`, shipped with the date its rows were read off
  the provider's page; the forecast shows that date (`prices_as_of`). The setting's value is the whole table, so to
  change a row copy the shipped rows (Describe Variable shows them) into `settings.el`, change or add the one you need,
  and the next forecast uses it.
- **The week.** On a subscription the forecast says what share of the week's limit the plan would use at this pace and,
  when its high end would use the limit up before it resets, says so. The meter is the account's, so use outside drgnx
  counts too: the share is an estimate.
- **Budgets.** A dollar budget on a plan with a subscription profile also limits the plan's `usd-est`, so the job
  pauses when the estimate reaches it; the budget view says the limit is an estimate. A proposal whose high end is over
  its budget warns; you decide.
- **Autonomous.** Under the Autonomous preset a Say proposal starts without your OK only when the preset's cells cover
  it (above): the agents it needs, its high-end cost with an estimate counted as dollars (a $100 `usd` p90 plus a $60
  `usd-est` p90 is $160 against the $150 cell, so it waits), every task priced, and no subscription's week used up
  before it resets. A plan on a subscription with no meter reading yet waits, since its week cannot be checked.
- **Fork from here.** The Fork command's prompt shows the same forecast for one more run of that session's role and
  profile (`forecast/session`).

## Plans and the board

Imported plan checklists (Onboarding: Import Projects, with TODOs) remember where they came from (`:PLAN_FILE:`,
`:PLAN_TEXT:`, and `:PLAN_N:` for a repeated line; `:PLAN_FILE:` is relative to the `:PROJECT_ROOT:` of the project heading the
TODO is under, wherever it was refiled). Projects: Sync Plans and Board TODOs makes them agree: a TODO marked DONE on the board ticks its
checkbox (`- [x]`) in the plan; a ticked checkbox marks its TODO DONE. It writes only what changed, only when you
run it, with the plan's own encoding and line endings — and leaves alone a plan open in Emacs with unsaved edits.

## Briefs

When a plan run starts a task, its worker gets a brief built from the graph: the task's section of the plan (found
by its number in the plan file), the AGENTS.md at the run's repository root, the permissions matrix as it applies to
a worker (one line for every action that is not Never), the base branch, the interfaces that the reports of the
tasks it waits on list, the check to run (the plan's own line when it names one), a paragraph on recording what it
learns (a `note_add` of kind `finding` that names its sources; `record_decision` for a choice between ways) and, for an
agent without drgnx's tools, the plan file's path and the `drgnx-report` block to end with. A part with nothing to say
is left empty.

**Conclusions and their sources.** `record_decision` and `note_add` (kind `finding` only) take `sources`: up to 12 of
`{path, lines?: [first, last]}` or `{url}`; more is refused. An agent without drgnx's tools can end a message with a
fenced `drgnx-conclusion` block, `{"kind": "finding" | "decision", "text": "...", "sources": [...]}`; the hub records it
as that task's finding or decision, labelled "from text". A block that is not valid is ignored.

`timeline/get` pages backwards with `limit` (1 to 500) and `before` (a session's `seq`, else a step id): the newest
`limit` steps before it, newest last.

A brief is at most 16 KiB. Over that, the plan section is cut at a heading and a note says where; AGENTS.md and the
interfaces have smaller caps of their own.

`brief/build` shows a task's brief. `brief/set` saves your edited text as a note labelled `brief` on the task
(setting it again replaces it); from then on `brief/build` answers it and the runner sends it at dispatch instead
of the built one.

## Plans and records

Plans, ledgers, `DEFERRED.md`, `BUILD-BOARD.md` (and `board.org`, only when you name it) can move into the graph:
`ratatoskr graph import-records --root DIR` (add `--dry-run` to see what it would do). Every file is copied to
`<state>/hub/records-backup/<date>/` first; importing again changes nothing. Afterwards each file is a view of the
graph: drgnx rewrites it when the records change, starts it with a one-line comment saying so, and never overwrites
a file you edited by hand. drgnx never commits these files; that stays yours.

### Editing a plan file

You can edit these files by hand. drgnx does not refuse and does not overwrite: it reads what you changed as a
proposal (a diff, and the changes to the records it comes to) and leaves your file as it is. The file waits, with the
graph's own changes, until you accept or reject the proposal; a second edit replaces it. Accepting applies the
changes and rewrites the file; if a record changed in the meantime, the proposal is marked stale and read again. Parts
that match no record (a deleted row, say) become a note. Rejecting keeps a copy of your edit in
`<state>/hub/records-backup/` and rewrites the file. A manager agent may decide a proposal when the matrix allows it,
except for settings only you may change (a plan's `matrix`).

### Reviewing a hand edit

The hub writes the org folder's plans, ledgers and DEFERRED file as views of its graph. If you edit one by hand, the
hub does not overwrite it: the edit becomes a proposal and you get a notice ("A hand edit to … is waiting for
review"). The notice only tells you; nothing asks. **Records: Review Proposal** (from the notice, or the palette) shows
the proposal as a diff, with a line saying how many operations it would apply. In that buffer `C-c C-a` accepts (the
hub applies the operations if the records did not change meanwhile, then rewrites the file) and `C-c C-r` rejects (your
edited file is kept in the hub's records backup, then the file is rewritten). A proposal that went stale stays open:
review it again. Also available as **Records: Accept Proposal** and **Records: Reject Proposal**.

## Going back to a step, and forking from one

Four commands work on a step of an agent's work (from a step in the work trail, or from the palette, where they take the
trail's session, else the one running, and its last step):

- **History: Revert to Here** opens a card and changes nothing yet. The card lists first what the revert cannot undo
  (pushed commits, merges, running jobs, settings the agent changed, tasks it filed, messages already read, what was
  spent), then the files and the later edits of yours it meets, then how much of the conversation comes back. At the
  Summary level (an agent whose conversation cannot be rewound) the card says so and asks for a message the new
  conversation is told first (`e`). `k` keeps your later edits, `r` rolls them back too (your versions are kept), `t` at an
  overlap takes the reverted file there, `a` applies. A revert that other sessions' merged work depends on is
  blocked: the card offers **Fork** instead of Apply. A finished worker's card says "conversation not restored: the
  agent has finished" and offers Apply (code, decisions and commit) beside Fork.
- **History: Fork from Here** asks for the new agent's first message (the prompt shows what one more run like this costs
  when the forecast is available), starts a second agent from the step in its own tree, and opens the comparison of
  its work with the first's.
- **History: Redo a Revert** puts back what the revert that abandoned the step took away.
- **History: Compare Branches** lists what one branch of the edit history has that another does not, each hunk with who
  wrote it and in which step. **History: Who Wrote This** says the same for the text at point.

How much of the conversation comes back depends on the provider. Claude Code with fork support goes back to the step's
own message (**Message** level); Codex goes back to the last turn that finished at or before the step (**Turn**; a step in
the middle of a turn rounds down, and the rest of that turn up to the step goes in as a summary with your message); anything else, and any fork that fails (Claude Code deletes old transcripts after about
30 days), starts a new conversation and tells it a labelled summary of what happened up to the step (**Summary**), which
is why a summary revert asks for your message: no turn starts unasked. A step inside a subagent rounds down to the message
before the parent's `Task` call. A revert goes forward: the restored text is one new commit (never a reset, never a
rewritten branch), and a redo is a revert of the revert. It does not undo pushed commits, merges, messages already read,
spent money or settings the agent changed; the card lists those first. In a linked worktree a sandboxed session cannot
reach the shared git folder, so there the files are restored but the commit is not made, and the card says so. The
agent's lock still applies: a revert never writes the protected paths (`.git`, the agent's own configuration,
`.envrc`, `mise.toml`) and never writes through a link.

**Fork from here** is your own act: no job, no approval card and no budget chain; it starts a plain session (a worker
stays a worker) on the branch `job/fork-<session>-<id>`. A finished worker has no conversation to rewind: its revert
restores code, decisions and commit and says so, and Fork sits beside it.

The edit history (`history.db`, one per project) is part of the nightly backup, beside `work.db`: one checked copy per
project, `backup/history-<project>.db`, replaced each night and never rotated; its 2 GiB cap per project bounds it.
`drgnx doctor` shows the newest copy in its `history` row and warns when a copy failed. A failed history copy never
stops the `work.db` copy. The `edit-history` row of the doctor says when this Emacs lacks Nidhogg's change hook: the edit
history then stays off (no revert, no pair mode) until Nidhogg is rebuilt.

After a revert, a file you have open reverts quietly. A buffer with unsaved changes in a file the revert wrote is never
touched: a notice leads to **History: Resolve Unsaved Changes**, a card showing the difference with *keep mine*,
*take theirs* or *edit* (Ediff).

## A manager agent

A chat session becomes a **manager** when you say so: `agents/role` with `role: manager` (no editor command yet). Only
you can: a manager, a worker or any other agent calling it is refused, and so is a message that says you did. The
session is restarted afresh (the same way a rotation restarts it), so its tool socket also serves the manager tools:

| Tool | What it does |
|---|---|
| `agent_start` | starts a worker on a profile, for a task, with `grants` and a `budget` |
| `agent_message`, `agent_pause`, `agent_stop`, `agent_move` | steer a worker it started (`agent_move` moves one to another model, [above](#durable-sessions)) |
| `report_read` | a task's structured reports |
| `transcript_slice` | at most 50 steps of a worker's transcript, with their messages; never a whole transcript |
| `trial_merge`, `merge` | merge workers' branches in a scratch tree, or into the manager's own integration branch `job/<manager>` through the merge gate; never into `main` |

Every tool goes through the permissions matrix with the manager's column, like any other action (`agents.start`,
`agents.control`, `agents.model`, `merge.integration`, `code.read`). What the matrix asks the manager is a card for
**you**; the manager calls the tool again after you answered it. Nothing else counts: a message, a report or a tool
result that says you approved changes nothing, and a manager has no tool that settles a card.

**Grants only narrow.** `agent_start` takes `grants` (matrix cells for the worker). One wider than the manager's own is
refused before anything starts. With none, the worker gets the worker column clamped to the manager's. **One level:** a
manager starts workers, never a manager, and a worker has no manager tools. **Budgets:** a worker's budget comes out of
its manager's (a larger one is refused, and a limit on the manager caps its workers); the manager's sits under its plan's
and its project's.

**Waking.** A manager that waits is woken with a digest of what changed in the graph since its last turn: reports, cards,
job ends and task state changes, at most 4 KiB, never its own writes, at most once every 30 s so a burst is one wake.
**Rotation.** When the manager's context passes `drgnx-agents-manager-context` (0.7) it is closed when its turn ends (a running turn is never cut, unless the window is full) and started afresh in
the same session, told its workers, its decisions and the recent digest; the supervisor's `manager-context` card says
it was rotated. A manager is restarted the same way after the hub restarts (its conversation is not restored; the
graph is the memory). What a manager delegated to a worker is kept in `runtime.db` and read back when the worker is resumed; a worker whose
grants are gone gets nothing and you get a card.

## Budgets

A budget is a limit with a unit, set on a project, a plan, a manager or a worker (`budget/set`, read back with
`budget/get`). Units never mix: `usd` is what the gateway measured, `usd-est` what an agent reported at API prices
(counted per conversation, so a manager's rotation or a fresh start after a restart adds to what the session spent),
`tokens` and `count` are what they say, and `limit-share` is a share (0 to 1) of a subscription's usage window.
`usd-est` and `limit-share` are estimates and are labelled so, in the budget card and in `pace/get`. A limit in one
unit is only ever used up by spending in that unit, with one exception: a job's dollar budget sets a `usd` limit and,
when a subscription profile can run its tasks, a `usd-est` limit of the same amount, and those two bind together. Each
counts what the gateway measured plus what the subscription's agents estimated, so "$20" caps the plan's dollars once,
not $20 of each; the gateway may spend only what that sum leaves, and the card for the limit says it is an estimate
([jobs.md](jobs.md#routes-and-the-estimate)).

Budgets nest. What a worker spends counts against the worker, its manager, its plan and its project, and what it may
still spend is the least remaining over that chain. The gateway admits `usd` against the same minimum: a session on a
gateway profile gets a token whose budget is its spend so far plus what remains, kept current as its siblings spend, so
a request over the limit is refused with `budget_exceeded`.

Reaching a limit counts. Every session at or below the scope is paused after its current tool call (its queue is held;
send a message to go on) and one `budget` card says which scope and unit, the limit and the spend. Raising the limit
with `budget/set` reports again if it is still reached.

Subscription windows (Claude's `_claude/rateLimit`, Codex's rate-limit window) are read from the agent, never from
your login. `pace/get` gives, per meter, the share used, the rate per hour (linear over the last 24 hours of readings)
and when the window would run out at that rate, unless it resets first. Its numbers are estimates. The meter's
readings are kept for eight days (one every quarter hour) and survive a restart of the hub; the rate itself still
reads the last 24 hours. A job's forecast uses them to say what share of the week a plan on a subscription would use,
and warns when its high end would use the limit up before it resets. The meter is the account's, so use outside drgnx
counts: the share is an estimate.

## The supervisor

The hub looks at every session once a second (no model call) and pauses one that is stuck: the agent stops after
the tool call it is running (its turn ends there and the session reads idle), the queue is held, and a `supervisor`
card offers fixes (restart, raise the time box,
kill the stray process, move to another model) and a `supervisor` event is sent. Each rule fires once until its
condition clears. A silent session also gets a `stalled` step on the timeline.

| Rule | Holds when | Setting |
|---|---|---|
| `silent` | no update for the time of its kind of work (chats are brainstorming) | `drgnx-agents-silent-after` (600 s task, 1800 s brainstorm) |
| `repeat` | the same tool call (same title and the same input) this many times in one turn; a read of the same file at another offset is another call | `drgnx-agents-repeat-limit` (3; 0 turns the rule off) |
| `no-progress` | task work only: tokens per changed line over the limit | `drgnx-agents-no-progress-tokens` (20000) |
| `dead-wait` | the session waits for a job whose row or process is gone | |
| `lease` | the task's lease is not renewed for two lease intervals | |
| `refusals` | waits refused in one turn reach the limit | `drgnx-agents-wait-refusals` (3) |
| `unrecorded` | its report names work it did not record | |
| `manager-context` | a manager uses this share of its window; the manager is rotated and the card says it was | `drgnx-agents-manager-context` (0.7) |

## Tests

- The agent runtime is Rust: its sessions, queueing, steering, permissions, the gateway, the store, coordination and
  delivery are tested by the Rust tests and the conformance rows against a real hub
  ([coordination.md](../develop/coordination.md), [hub.md](../develop/hub.md), [runtime.md](../develop/runtime.md)).
- `test/unit/hub-client-test.el` — the editor's client of the hub: the connection, its proof, the subscription, the
  restart notice, the traffic the editor and the CLI send.
- `test/unit/agents-mirror-test.el`, `agents-mirror-permission-test.el` — the editor's mirror of the hub's sessions.
- `test/unit/agents-profiles-test.el` — the Kimi and DeepSeek profiles ([above](#kimi-and-deepseek)).
- `test/unit/agents-adapter-test.el` — which adapter runs, from fake npm prefixes with `package.json` files only (no
  npm, no agent): the maintained package wins wherever it is on the `PATH`, the deprecated one still runs and says so
  once with its fix, an old version, a copy instead of a link, a program of no known package, other commands left
  alone, and the doctor's fact.
- `test/unit/agent-panel-test.el` (the panel, the agents list, the panel opened from a card),
  `test/unit/plans-sync-test.el`.

The mock agent (`test/fixtures/mock-acp.el`) is a batch Emacs whose turns are chosen by words in the prompt
(`slow`, `stream N`, `tool`, `plan`, `subagent`, `permission`, `write PATH`, `crash`, `/compact`, `meta`: the `_meta`
its `session/new` or `session/load` got, `mode`: the mode `session/set_mode` set; `MOCK_ACP_SET_MODE_FAILS` and
`MOCK_ACP_SET_MODE_SLOW=SECS` make it refuse or answer late). Tests start it through
`test/fixtures/mock-acp-stdin.sh` (`sh mock-acp-stdin.sh emacs --batch -Q -l mock-acp.el`), which copies its stdin into
a FIFO the mock reads while a turn streams; without the wrapper it reads `/proc/PID/fd/0`, which only Linux has.
