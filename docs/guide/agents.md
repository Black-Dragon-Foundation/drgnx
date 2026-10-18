# Agents

drgnx runs coding agents inside Emacs over the **Agent Client Protocol** (ACP: JSON-RPC 2.0, one object per line
on the agent's stdin/stdout), lists them with long-running background **jobs** in the right dock's **Agents** tab,
and keeps plan checklists and board TODOs in step.

The rule that shapes everything: **sending a message never cancels the agent's work.** A message sent while the
agent is working is **queued** and delivered once, in order, when its turn ends — or **steers** the running turn,
when the profile asks for it and the agent supports it. Only **Stop** cancels.

## Sessions

Agents: New Agent Session… (palette) starts a **profile** in the current project; Show Agents (`C-k a`, ⌘K A on a
Mac) opens the Agents tab. Profiles live in
`~/.config/drgnx/agents.eld`:

```elisp
(:profiles (("claude" :command ("claude-agent-acp") :mode queue)
            ("local" :command ("my-acp-agent" "--model" "qwen") :mode steer)))
```

`:command` is the agent program; `:mode` is what a message to a busy agent does: `queue` (default), `steer` (when
the agent advertises steering — sent as `_session/steering`; if the agent refuses, the message is queued instead) or
`interrupt` (stop the turn, then send). A profile whose program is not installed gives a session that says so. Keys and tokens are
never written there — the agent reads them from its environment or its own login. The built-in `claude` profile
runs the unmodified `claude-agent-acp` (npm package `@zed-industries/claude-agent-acp`) when it is installed, with
your own Claude login. Onboarding's Agents step installs Claude Code, Node and that adapter if they are missing
(asked first), opens a terminal for the login and checks that the profile starts
([onboarding.md](onboarding.md#setting-claude-code-up)); to check it again later, run Onboarding: Agents.

A session's **transcript** (RET on its row; opens in the editor) shows:

- what you said (`▸`; a steering message `↪`), the agent's answer, its thinking (dimmed);
- tool calls with their status — a subagent's own tool calls indented under it;
- the agent's plan (`☑` done, `◐` in progress, `☐` pending);
- **what waits for you**: a permission request with its options as buttons; an edit to review;
- the agent's slash commands (`/compact`, …) at the top;
- "working…" with a **[Stop]** button, the queued messages (each with **[×]** to remove it; **[Deliver]** after a
  Stop), and how the agent exited if it did (with the end of its error output).

Agents: Send to Agent (RET in a transcript) sends; Stop Agent (`C-c C-c` in a transcript, or [Stop]) cancels the
running turn — it ends within a second, pending permission requests are answered "cancelled", pending edits
rejected, and queued messages wait (Deliver Queued Messages, `C-c C-d`, sends them; Edit Queued Message changes or
removes one before it is sent). If the agent answers the cancel late, its last words are dropped and nothing new
is sent until that answer came — never two turns at once. Answer Agent picks an option for a pending permission. Take Over Agent Session resumes a session by its id
(the agent replays it), when the agent can load sessions (otherwise the new session ends and says why). The **context** column shows how full the agent's
context is (from the agent's `usage_update`, or usage in its answer). The **Last** column shows how long ago the
agent last did something (`30s`, `5m`, `2h`, `3d`), as this Emacs saw it. While the list is on screen, it is redrawn every 30
seconds so the ages stay current, and the cursor stays on its row. When the list is not shown, nothing runs. The Agent layout ([layouts.md](layouts.md)) puts this list on the right and the chat of the agent that
acted last beside your file.

Nothing an agent asks is ever a question in the minibuffer: the agent waits, the Agents tab says "1 to answer",
and you answer when you look.

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
(never decompressed or decrypted in the hub), and a link that leads nowhere is "not a regular file".

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
timer, or at once when Emacs exits first): for callers in a timer that must not block, such as drgnx starting the local AI runner again. Sessions and jobs started on a task get it as `DRGNX_TASK`, and the commits they make are
recorded for it ([Work tracker](work.md)).

## The hub and the gateway

Agents on **OpenRouter, Ollama or your own Anthropic key** (profiles with `:ai claude-openrouter`, `claude-ollama`,
`claude-anthropic`) do not get your key: they talk to the **gateway**, a local HTTP server in drgnx's **hub**, with a
token of their own. The gateway checks the token, adds the real key, forwards each request and streams the answer
back as it comes (it adds well under 50 ms before the first token). For each answer it counts the tokens the
provider reports — spend per job, task and agent, kept in the work tracker's database — and when a provider fails
before answering (no answer, 429, 401/402, 5xx) it tries the next one the agent may use: role `agent`'s chain for
OpenRouter agents ([AI](ai.md)); when the last one refuses, its own status, `Retry-After` and message reach the agent. A job's budget, when it has one, stops new requests once it is spent.

**Subscription CLIs never go through it**: the plain `claude` profile (and any profile without `:ai`) uses the CLI's
own login, which drgnx only launches and never reads.

The **hub** is a background process (a durable job: it outlives the Emacs that started it, and a later Emacs finds
it again). The first agent that needs it starts it; `drgnx hub start|stop|status [--json]` manages it by hand. Keys
reach it over its private socket from the Emacs or `drgnx hub start` that starts or uses it (never through its
environment), from auth-source files that never ask, or from the command you ran (a key in `~/.authinfo.gpg` is read
then) — and stay in its memory (a restarted hub gets them again when Emacs reconnects to it); tokens are kept only as hashes, so a restarted hub still
takes them; an agent's token is revoked when it exits, or once the Emacs that started it is gone (a crash). The hub keeps the environment, `PATH` included, of the Emacs
that started it: when an agent's program was installed while a hub ran (onboarding's Agents step, say), run
`drgnx hub stop` (its durable sessions end), so the hub the next durable session starts finds the program.
With no hub to be had, an agent goes to its provider directly and says so. The Agents list's **Via**
column shows which.

## Durable sessions

**New Durable Agent Session…** (palette) starts an agent in the **hub** instead of this Emacs: it keeps working when
you close Emacs, and the next Emacs shows it again in the Agents tab — its whole transcript, pending permission
requests and edits to review — and drives it the same way (send, Stop, answer, review). Emacs mirrors the hub's
sessions when it is idle whenever a hub is running (and looks again every 30 s); it never starts a hub for that.
Durable sessions live as long as the hub: if the hub ends (`drgnx hub stop`, a crash), its sessions end too, and the
Agents tab shows them as exited. The next hub (the next durable session, an agent that needs the gateway, or `drgnx
hub start`) resumes them when their agent can load sessions: each comes back idle with its history,
though a turn that was running when the hub ended is lost; a job's agents are not resumed (the job starts their
tasks again).

## What agents get

Every agent drgnx starts gets MCP servers in its ACP `session/new`: the **coordination tools** (see below) by default,
and, when you ask for it, the **search tool** (`drgnx search mcp`, [search.md](search.md#the-mcp-tool)) for the project
the agent works in. `agents.eld` holds the choice, next to `:profiles`:

```elisp
(:default "claude"                   ; what New Agent Session… offers on Return
 :mcp (coordination search))         ; the servers; absent: coordination only; () gives none
```

Onboarding's Agents step asks for both and writes them without touching the rest of the file (comments stay); you can
edit them by hand too. The search tool lets an agent read the indexed code of any of your projects, so it is off until
you say yes.

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
never changes a setting. Two agents writing to each other too fast, or a full queue, holds the rest. Agents of a job
hear about that job's new decisions (once per change); a plain chat session is never woken for them. A task an
agent claimed is a lease, kept while the agent runs and while the task waits on you; if the agent is gone for 15
minutes the task is free again (the job window, M9b.4, will show it; messages and escalations to you wait there
too). **Jobs** put several agents to work through a plan you approve, each task in its own worktree, reviewed and
merged into the job's branch: [jobs.md](jobs.md). Developer details: [coordination.md](../develop/coordination.md).

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
- `test/unit/acp-test.el` — the transport against a mock agent: requests, notifications, the agent's own requests,
  split / malformed / 1 MB lines, the agent exiting with its error output.
- `test/unit/agents-test.el` — sessions: a turn's transcript, queueing during a turn (delivered in order, never
  cancelling), steering (and its fallback), Stop within a second, permissions, tool calls, plans and subagents, a
  dying agent, Take Over, `/compact`.
- `test/unit/jobs-test.el`, `test/unit/agents-ui-test.el` (the transcript, the list, hunk-by-hunk review),
  `test/unit/plans-sync-test.el`, `test/live/drgnx-agents-test.el` (queue, Stop and the dock in a GUI session).
- `test/unit/agents-parity-test.el` — slash commands, context %, `/compact` lowering it: against the mock, or against
  a real profile with `DRGNX_AGENT_PROFILE=NAME` (uses your subscription or key, and the network).

The mock agent (`test/fixtures/mock-acp.el`) is a batch Emacs whose turns are chosen by words in the prompt
(`slow`, `tool`, `plan`, `subagent`, `permission`, `write PATH`, `crash`, `/compact`).
