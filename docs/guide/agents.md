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
`~/.config/drgnx/settings.el` ([settings.md](settings.md)); this file used to be `agents.eld`, and drgnx moved its
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
`interrupt` (stop the turn, then send). A profile whose program is not installed gives a session that says so.
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

A session's **transcript** (RET on its row; opens in the editor) shows:

- what you said (`▸`; a steering message `↪`), the agent's answer, its thinking (dimmed);
- tool calls with their status — a subagent's own tool calls indented under it;
- the agent's plan (`☑` done, `◐` in progress, `☐` pending);
- **what waits for you**: a permission request with its options as buttons; an edit to review;
- the agent's slash commands (`/compact`, …) at the top;
- "working…" with a **[Stop]** button, the queued messages (each with **[×]** to remove it; **[Deliver]** after a
  Stop), and how the agent exited if it did (with the end of its error output).

A transcript is drawn only while a window shows it, at most ten times a second: what the agent streams is added at
the end of its answer, and only a part that changed (a tool call's status, a permission answered) is drawn again, so a
long transcript costs no more to follow than a short one. A transcript you are not looking at draws nothing; when it
shows again it catches up at once. Scrolled to the end, it follows what comes in; scrolled up to read, it keeps your
place while the agent streams. `g` redraws it at once.

Agents: Send to Agent (RET in a transcript) sends; Stop Agent (`C-c C-c` in a transcript, or [Stop]) cancels the
running turn — it ends within a second, pending permission requests are answered "cancelled", pending edits
rejected, and queued messages wait (Deliver Queued Messages, `C-c C-d`, sends them; Edit Queued Message changes or
removes one before it is sent). If the agent answers the cancel late, its last words are dropped and nothing new
is sent until that answer came — never two turns at once. Answer Agent picks an option for a pending permission. Take Over Agent Session resumes a session by its id
(the agent replays it), when the agent can load sessions (otherwise the new session ends and says why). The **context** column shows how full the agent's
context is (from the agent's `usage_update`, or usage in its answer). The **Last** column shows how long ago the
agent last did something (`30s`, `5m`, `2h`, `3d`), as this Emacs saw it. The list updates in place: when an agent changes, or every 30
seconds for the ages, only the lines that differ are rewritten, and each window (and the cursor) stays on its
session even when lines move. While the list is not shown nothing is printed; it is brought up to date when you show
it again; the 30 second timer itself runs only while the list shows. The dock's tab strip uses the header line, so the
column titles (Name, Status, Last, …) are the list's first line, in the theme's header face. With no sessions the list
says how to start one (*New Agent Session…*, with its key when your key profile has one, or from the palette) and, when
the default profile is claude and its adapter is missing or too old, what Claude needs. The Agent layout
([layouts.md](layouts.md)) puts this list on the right and the chat of the agent that
acted last beside your file.

Nothing an agent asks is ever a question in the minibuffer: the agent waits, the Agents tab says "1 to answer",
and you answer when you look.

Each pending permission ("NAME asks: TITLE", opens Answer Agent) and each edit to review ("NAME wants to write FILE",
opens Show Agents) is also one item of the one "needs you" count ([notices](../develop/core.md#notices-drgnx-noticeel)): source
`agents`, scoped to the session's job, for sessions this Emacs runs and the hub's sessions it mirrors alike. It leaves
the count when you answer it, when the turn is stopped, or when the session ends. Noting it costs nothing while an
agent streams: the set is rebuilt only when a session's permissions or edits to review change.

Each agent's own settings (its routes and billing, MCP servers, hooks and skills) are on its settings page: `,` on a session's row, or Agents: Settings ([agent-settings.md](agent-settings.md)).

## Reviewing an agent's edits

When an agent writes a file (ACP `fs/write_text_file`), the file is not changed: the transcript offers **Review**,
which opens the proposed change as a diff against a copy of the file (the header says if the file is outside the
session's project). Apply the hunks you want (`C-c C-a` on a hunk — diff-mode; they go to the copy), then **Done**
(`C-c C-c`) writes the copy to the file — a new file is created — and the agent hears the edit was made. **Reject**
(`C-c C-k`), or closing the diff, writes nothing and tells the agent it was refused. Done refuses while the file has
unsaved changes in Emacs. Reads (`fs/read_text_file`, also a range of lines) get the file as it is in Emacs, unsaved
edits included; both need absolute paths. A read is served only for a local path (never a remote, TRAMP one) and,
when no buffer visits it, only for a regular file of at most 10 MiB (`drgnx-agents-read-max`): a FIFO or a device is
refused, never opened. The file is read with no file name handlers: a `.gz` or `.gpg` file comes back as its bytes
(never decompressed or decrypted in the hub), and a link that leads nowhere is "not a regular file". An agent never
gets a file bigger than 10 MiB, open or not: a buffer over that size, or a large file drgnx holds in chunks, lean or
raw, is not served, and the file on disk is read instead, under the same limit.

## Durable jobs

Background work that must survive a closed frame, a restart of Emacs or an interrupted chat runs as a **job**: a
systemd user unit (`systemd-run --user`) where systemd runs your session, else its own process group (the detached
launcher: `setsid`, or on macOS, which has no `setsid`, the perl every Mac has; with neither, starting a job says
"Detached jobs need setsid or perl" and creates nothing). Each job has
a directory under `~/.local/state/drgnx/jobs/` (its command, log, pid and exit code), so any Emacs lists it in the
Agents tab (running, exited N, stopped, gone), shows its log (Show Job Log) and stops it (Stop Job: under systemd it returns once the job's unit is down, but after
`drgnx-jobs-stop-wait` seconds, 3 by default, at the latest; a job that ignores TERM is left to systemd, which kills it
after 90 s). A job's pid is
trusted only within the boot that started it and for the process it started (a pid reused after a reboot is "gone",
never signalled). Under systemd the job's wrapper line passes through the unit's ExecStart, which reads `$$` as `$`, so drgnx doubles
every `$` in it: the `pid` file holds the job shell's real pid, and the job reads as running and can be stopped. A job can be memory-capped (`:memory-max "1G"` in `drgnx-jobs-start`: systemd's `MemoryMax`, no swap;
`:nice 10` lowers its priority (`Nice=`); the detached launcher can do neither and ignores both). `:no-wait t`
returns without waiting for the job's pid (the boot and start time that make it trustworthy are stamped from a short
poll that gives up after 2 s, or at once when Emacs exits first): for callers in a timer that must not block, such as drgnx starting the local AI runner again. A job's `job.eld` is written atomically and stamped without waiting; a `job.eld` drgnx cannot read is never overwritten, and that job does not show in the list. Sessions and jobs started on a task get it as `DRGNX_TASK`, and the commits they make are
recorded for it ([Work tracker](work.md)).

## The job sandbox

The agents of a [job](jobs.md) run in a sandbox: bubblewrap (`bwrap`) on Linux, `sandbox-exec` on macOS. Inside,
they see the system, your toolchains read-only, their task's folder and a private home, and nothing else of yours
(how it works: [the job sandbox](../develop/sandbox.md)). `drgnx doctor` says whether it works here, in the Agents
group:

```
OK    job-sandbox          bwrap 0.12.0 ok; memory cap 4G per agent by default (drgnx-sandbox-memory-max)
```

or a warning with the reason and the fix. (`drgnx doctor` runs without your configuration, so it shows the cap's
default; the doctor of the Welcome's Finish step shows yours.) Without a working sandbox, jobs do not start. What to install:

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

Claude Code also runs on Kimi and DeepSeek, with the same agent and the same tools; only the model behind it changes.
Four built-in profiles (listed in New Agent Session… and on the Claude page of Agent Settings, with how each is
billed):

| Profile | Goes to | Key | Billed by |
|---|---|---|---|
| `claude (Kimi)` | Moonshot's own API | `MOONSHOT_API_KEY` | Moonshot, per token |
| `claude (DeepSeek)` | DeepSeek's own API | `DEEPSEEK_API_KEY` | DeepSeek, per token |
| `claude (Kimi via OpenRouter)` | OpenRouter | `OPENROUTER_API_KEY` | OpenRouter |
| `claude (DeepSeek via OpenRouter)` | OpenRouter | `OPENROUTER_API_KEY` | OpenRouter |

Like the other provider profiles they go through the gateway when a hub is available: the agent holds a token, never
the key. Without a key the session does not start and the message names the variable and the keyring host to put it
under. Each session gets its route in its own environment (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, the model
names); drgnx writes nothing to `~/.claude/settings.json`, so the plain `claude` profile keeps using your login. No
agent inherits the other vendors' keys from Emacs's environment (`drgnx-agents-scrubbed-env`; the plain `claude`
profile keeps Claude Code's own variables). The API keys are billed
per token; Kimi's coding membership is a different endpoint these profiles do not use. Moonshot and DeepSeek have no
`:price`, so the gateway counts their spend as zero. Details and the model names: [AI](ai.md#agents).

## Durable sessions

**New Durable Agent Session…** (palette) starts an agent in the **hub** instead of this Emacs: it keeps working when
you close Emacs, and the next Emacs shows it again in the Agents tab — its whole transcript, pending permission
requests and edits to review — and drives it the same way (send, Stop, answer, review). Emacs mirrors the hub's
sessions when it is idle whenever a hub is running (and looks again every 30 s of idleness); it never starts a hub for that.
Turning `tools/agents` off (Preferences: Modules) stops the mirroring and closes this Emacs's connection to the hub;
the hub and its sessions go on.
Durable sessions live as long as the hub: if the hub ends (`drgnx hub stop`, a crash), its sessions end too, and the
Agents tab shows them as exited. The next hub (the next durable session, an agent that needs the gateway, or `drgnx
hub start`) resumes them when their agent can load sessions: each comes back idle with its history,
though a turn that was running when the hub ended is lost; a job's agents are not resumed (the job starts their
tasks again).

## What agents get

Every agent drgnx starts gets MCP servers in its ACP `session/new`: the **coordination tools** (see below) by default,
and, when you ask for it, the **search tool** (`drgnx search mcp`, [search.md](search.md#the-mcp-tool)) for the project
the agent works in. `settings.el` holds the choice, next to `drgnx-agents-profiles`:

```elisp
(drgnx-agents-default "claude")                   ; what New Agent Session… offers on Return
(drgnx-agents-mcp (coordination search))          ; the servers; absent: coordination only; () gives none
```

Onboarding's Agents step asks for both and writes them without touching the rest of the file (comments stay); you can
edit them by hand too. The search tool lets an agent read the indexed code of any of your projects, so it is off until
you say yes.

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

Your own sessions (New Agent Session…, Take Over) and agents other than Claude get none of this. Other agents
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
never changes a setting. Your own answers and messages (a reply to a job's agent, an answer from the Work cockpit)
reach it as yours, unquoted: `[message from the user #N — the user's message]`, or `[message from the user #N — the
user's answer to your question #Q]` and the question's words on a quoted line when drgnx knows which question it
answers. No agent can send as the user. Two agents writing to each other too fast, or a full queue, holds the rest. Agents of a job
hear about that job's new decisions (once per change); a plain chat session is never woken for them. A task an
agent claimed is a lease, kept while the agent runs and while the task waits on you; if the agent is gone for 15
minutes the task is free again (the Work cockpit's What needs you shows it; messages and escalations to you wait
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
Work cockpit): for every agent in a project, for one profile, or for one session, until you revoke it or it expires.
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

The editor tells the hub when you are **away**: after `drgnx-agents-away-after` seconds (600) without input it sends
`presence/set`, and again on your next input. The time presets follow from the next action. An agent never sends it.

Only you set these: they are `:workspace never` (a repository's `.drgnx/settings.el` and `.dir-locals.el` are refused
with the line) and `:agents never` (the `settings_change` tool refuses them). They are `drgnx-agents-matrix`,
`-away-after`, `-wait-refusals` (3), `-close-idle-after` (1800 s), `-checkpoint-cap` (2 GiB), `-job-memory` ("4G"),
`-job-cpus` (2), `-container-images` (name → digest-pinned image), and the supervisor's `-silent-after`
(task 600 s, brainstorm 1800 s), `-repeat-limit` (3), `-no-progress-tokens` (20000) and `-manager-context` (0.7).
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
cockpit is where they will show. **Coming with the Work cockpit** (later in this milestone): each reporting agent
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

**Coming with the Work cockpit:** an agent that does not report — no drgnx server in its config, or it never says
hello — will still show there when it works in a git worktree, with the worktree's changes and its ledger, marked
**not reporting**.

## Plans and the board

Imported plan checklists (Onboarding: Import Projects, with TODOs) remember where they came from (`:PLAN_FILE:`,
`:PLAN_TEXT:`, and `:PLAN_N:` for a repeated line; `:PLAN_FILE:` is relative to the `:PROJECT_ROOT:` of the project heading the
TODO is under, wherever it was refiled). Projects: Sync Plans and Board TODOs makes them agree: a TODO marked DONE on the board ticks its
checkbox (`- [x]`) in the plan; a ticked checkbox marks its TODO DONE. It writes only what changed, only when you
run it, with the plan's own encoding and line endings — and leaves alone a plan open in Emacs with unsaved edits.

## Tests

- `test/unit/coord-test.el`, `coord-mcp-test.el`, `hub-agents-test.el`, `agents-mirror-test.el`, `coord-delivery-test.el`
  — coordination: the store, the tools, durable sessions, mirrors, delivery ([coordination.md](../develop/coordination.md)).
- `test/unit/gateway-test.el`, `test/unit/hub-test.el`, `test/unit/http-test.el`, `test/unit/agents-gateway-test.el`
  — the gateway against mock providers (streaming, tokens, keys, spend, budget, fallback, a hang-up, a 1 MB body),
  the hub (socket, events, restart, one hub, outliving its starter, the CLI), agents' environments.
- `test/unit/agents-profiles-test.el` — the Kimi and DeepSeek profiles ([above](#kimi-and-deepseek)).
- `test/unit/acp-test.el` — the transport against a mock agent: requests, notifications, the agent's own requests,
  split / malformed / 1 MB lines, the agent exiting with its error output.
- `test/unit/agents-test.el` — sessions: a turn's transcript, queueing during a turn (delivered in order, never
  cancelling), steering (and its fallback), Stop within a second, permissions, tool calls, plans and subagents, a
  dying agent, Take Over, `/compact`; what waits on you as the `agents` set of the "needs you" count (a mirror's
  too, scoped by job, gone once answered or ended, and no allocation for a session that did not change).
- `test/unit/agents-claude-options-test.el` — a job session's Claude cannot be pre-allowed
  ([above](#jobs-and-your-claude-settings)).
- `test/unit/agents-adapter-test.el` — which adapter runs, from fake npm prefixes with `package.json` files only (no
  npm, no agent): the maintained package wins wherever it is on the `PATH`, the deprecated one still runs and says so
  once with its fix, an old version, a copy instead of a link, a program of no known package, other commands left
  alone, sessions and jobs starting the chosen program, and the doctor's fact.
- `test/unit/jobs-test.el`, `test/unit/agents-ui-test.el` (the transcript, the list, hunk-by-hunk review; the
  transcript's view: a thousand chunks grow one row, a grow costs the same on a 4 kB and a 400 kB answer, a hidden
  transcript draws nothing, a tool's status or a permission draws one row, the tail is followed and a reader scrolled up
  stays put), `test/ui/view-ui-test.el` (typing beside a streaming transcript: no jank),
  `test/unit/plans-sync-test.el`, `test/live/drgnx-agents-test.el` (queue, Stop and the dock in a GUI session).
- `test/unit/agents-parity-test.el` — slash commands, context %, `/compact` lowering it: against the mock, or against
  a real profile with `DRGNX_AGENT_PROFILE=NAME` (uses your subscription or key, and the network).

The mock agent (`test/fixtures/mock-acp.el`) is a batch Emacs whose turns are chosen by words in the prompt
(`slow`, `stream N`, `tool`, `plan`, `subagent`, `permission`, `write PATH`, `crash`, `/compact`, `meta`: the `_meta`
its `session/new` or `session/load` got, `mode`: the mode `session/set_mode` set; `MOCK_ACP_SET_MODE_FAILS` and
`MOCK_ACP_SET_MODE_SLOW=SECS` make it refuse or answer late). Tests start it through
`test/fixtures/mock-acp-stdin.sh` (`sh mock-acp-stdin.sh emacs --batch -Q -l mock-acp.el`), which copies its stdin into
a FIFO the mock reads while a turn streams; without the wrapper it reads `/proc/PID/fd/0`, which only Linux has.
