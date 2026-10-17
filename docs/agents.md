# Agents

drgnx runs coding agents inside Emacs over the **Agent Client Protocol** (ACP: JSON-RPC 2.0, one object per line
on the agent's stdin/stdout), lists them with long-running background **jobs** in the right dock's **Agents** tab,
and keeps plan checklists and board TODOs in step.

The rule that shapes everything: **sending a message never cancels the agent's work.** A message sent while the
agent is working is **queued** and delivered once, in order, when its turn ends — or **steers** the running turn,
when the profile asks for it and the agent supports it. Only **Stop** cancels.

## Sessions

Agents: New Agent Session… (palette) starts a **profile** in the current project. Profiles live in
`~/.config/drgnx/agents.eld`:

```elisp
(:profiles (("claude" :command ("claude-agent-acp") :mode queue)
            ("local" :command ("my-acp-agent" "--model" "qwen") :mode steer)))
```

`:command` is the agent program; `:mode` is what a message to a busy agent does: `queue` (default), `steer` (when
the agent advertises steering; otherwise it queues) or `interrupt` (stop the turn, then send). Keys and tokens are
never written there — the agent reads them from its environment or its own login. The built-in `claude` profile
runs the unmodified `claude-agent-acp` when it is installed.

A session's **transcript** (RET on its row; opens in the editor) shows:

- what you said (`▸`; a steering message `↪`), the agent's answer, its thinking (dimmed);
- tool calls with their status — a subagent's own tool calls indented under it;
- the agent's plan (`☑` done, `◐` in progress, `☐` pending);
- **what waits for you**: a permission request with its options as buttons; an edit to review;
- "working…", the queued messages, and how the agent exited if it did (with the end of its error output).

Agents: Send to Agent (RET in a transcript) sends; Stop Agent cancels the running turn — it ends within a second,
pending permission requests are answered "cancelled", and queued messages wait (Deliver Queued Messages sends
them). Answer Agent picks an option for a pending permission. Take Over Agent Session resumes a session by its id
(the agent replays it), when the agent can load sessions. The **context** column shows how full the agent's
context is (from the usage the agent reports); `/compact` and the agent's other slash commands are listed in the
session.

Nothing an agent asks is ever a question in the minibuffer: the agent waits, the Agents tab says "1 to answer",
and you answer when you look.

## Reviewing an agent's edits

When an agent writes a file (ACP `fs/write_text_file`), the file is not changed: the transcript offers **Review**,
which opens the proposed change as a diff. Apply the hunks you want (`C-c C-a` on a hunk — diff-mode), then
**Done** (`C-c C-c`): the hunks you applied are saved and the agent hears the edit was made; **Reject** (`C-c C-k`)
tells the agent it was refused. Reads (`fs/read_text_file`) get the file as it is in Emacs, unsaved edits included.

## Durable jobs

Background work that must survive a closed frame, a restart of Emacs or an interrupted chat runs as a **job**: a
systemd user unit (`systemd-run --user`) where systemd runs your session, else its own process group. Each job has
a directory under `~/.local/state/drgnx/jobs/` (its command, log, pid and exit code), so any Emacs lists it in the
Agents tab (running, exited N, stopped, gone), shows its log (Show Job Log) and stops it (Stop Job).

## Plans and the board

Imported plan checklists (Onboarding: Import Projects, with TODOs) remember where they came from (`:PLAN_FILE:`,
`:PLAN_TEXT:`). Projects: Sync Plans and Board TODOs makes them agree: a TODO marked DONE on the board ticks its
checkbox (`- [x]`) in the plan; a ticked checkbox marks its TODO DONE. It writes only what changed, and only when
you run it.

## Tests

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
