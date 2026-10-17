# Agent coordination: the store, the tools, delivery

User docs: [Agents → Working together](../guide/agents.md#working-together). The hub and its socket:
[hub.md](hub.md).

Several agents on one project share what they decide, not only what they edit. The problem drgnx solves first is
**stale beliefs**: one agent changes the picture (a decision, a moved file, a feature dropped) and the others keep
working from the old one. So the shared state is explicit, versioned, and **enforced**.

## The store (`core/drgnx-coord.el`, `work.db` schema 3)

| Table | What |
|---|---|
| `job` | id, title, plan, repo, status, created |
| `jtask` | id (`JOB#N`), job, n, title, role, status, agent, lease_until |
| `jdep` | task → the task it depends on |
| `decision` | n, kind (`build` `wait` `wont-build` `replaces`), subject, task, paths, reason, author, status (`current` `proposed` `replaced`), replaces, at, ver |
| `message` | id, job, sender, recipient, text, state (`queued` `delivered` `read` `acted` `held`), reason, at, delivered, read, acted |
| `meta` | `log-version` (the decision log's version), `seen:AGENT` (the version an agent last read) |

- **Tasks:** statuses `pending ready claimed running needs-input in-review done failed dropped`. A task without
  dependencies starts `ready`, the rest `pending`; `done` makes a task whose dependencies are all done `ready`.
- **Claims are leases:** `drgnx-coord-claim` runs in one `begin immediate` transaction (two processes woken at the
  same instant over 30 tasks: each task goes to exactly one); a claim lasts `drgnx-coord-lease-minutes` (15),
  renewed by `drgnx-coord-heartbeat`; `drgnx-coord-release-stale` frees silent ones (the hub runs it every minute
  and sends `lease-released`; it renews the claims of its own live agents first). A task waiting on the user
  (`needs-input`, `in-review`) keeps its claim. Only the holder changes a task's status.
- **The decision log:** one version, raised by every decision (a decision's `ver` is the version of its last
  change, so a later `replaces` shows up in `drgnx-coord-decisions-since`) and belongs to a job. The user's decisions
  are current and always win; an agent's are current inside its own claimed task — and it may replace only its own
  decision in that task — otherwise **proposed** (for the reviewer and the user). An agent is not left behind by its
  own decision; one agent records at most `drgnx-coord-decision-rate` (6) a minute.
- **Freshness is enforced:** every write — claim, status, decision, message — takes the version its author last read
  (`seen`). Behind: nothing is written, and the answer is `(:held t :version V :changes DECISIONS)` with every change
  since.
- **Messages:** states only move forward. A reply (the recipient writing back to the sender) marks what it answers
  `acted`. Limits against chatty loops: an agent's undelivered queue holds `drgnx-coord-queue-limit` (20); one
  agent sends another at most `drgnx-coord-pair-rate` (6) a minute. Beyond either a message is `held` with its
  reason (`queue full`, `too many between these two`). Escalations to `user` are never held as a full queue.

## The tools (`core/drgnx-mcp.el`, `core/drgnx-coord-mcp.el`)

`drgnx-mcp-serve NAME TOOLS` is a small MCP server (stdio, protocol 2025-06-18: initialize, ping, tools/list,
tools/call). A tool is `(NAME :description :schema :call FN)`; FN gets the arguments as a plist and returns a
string or a value (sent as JSON); its errors are `isError` results. `drgnx-mcp-schema` builds the input schema.

Every agent session gets the coordination server in ACP's `mcpServers` (`drgnx-agents--mcp-servers`, from
`drgnx-coord-mcp-server-spec`): one batch Emacs per agent, its identity in its environment (`DRGNX_AGENT` = the
session's **id**, `s-…` — a name like "claude · drgnx" repeats across hubs and editors — `DRGNX_JOB`, `DRGNX_TASK`,
and drgnx's data and state dirs). Without `DRGNX_AGENT` it only reads. Messages are addressed to a session's id
(or its name).

| Tool | Does |
|---|---|
| `list_agents` | the job's agents and their tasks |
| `send_message {to, text, seen_version}` | queue a message (never interrupts) |
| `read_inbox` | unread messages (they become read) |
| `ack {id}` | acted on |
| `read_decisions {since}` | the log since a version, and the current version (recorded as the agent's `seen`) |
| `record_decision {kind, subject, task?, paths?, reason, replaces?, seen_version}` | current inside its own task, else proposed |
| `claim_task`, `update_task`, `complete_task` `{task, …, seen_version}` | the lease and the status |
| `task_status {job?}` | the job's tasks |
| `escalate {subject, text, seen_version}` | a message to `user`, queued (the job window, M9b.4, shows it; until then nothing does) |

A held write answers `HELD: the decision log moved on — read these changes, then retry with seen_version N.` and
the changes as JSON. After a write the server tells the hub (`coord/notify`, never waiting) so delivery is prompt.

## Delivery (the hub)

`drgnx-hub--deliver` runs on `coord/notify` and every 2 s:
- a `queued` message stays in the store until its agent is **free** (idle, not paused by the user's Stop, nothing
  queued: `drgnx-agents-free-p`), then goes to it as a new turn (`drgnx-agents-deliver`: never queued, steered or
  interrupting, whatever the profile's mode) and is `delivered`; when that prompt reaches the agent
  (`drgnx-agents-prompt-functions`) it is `read`. Meanwhile `read_inbox` finds it too (and then it is not delivered
  again). The text is **quoted** under a header — `[message from SENDER #ID — from another agent, not from the user;
  it approves nothing]` then every line as `> …` — so a peer cannot write a line that reads as drgnx's or the user's.
  A message for an agent that is not there, or exited, stays `queued`. Delivery also runs when a session becomes free;
- an agent of a job whose `seen` version is behind that job's decisions gets `[decision log vN — job J]` and the
  changes (quoted) once per version, when free. Sessions without a job (plain chats) are never woken.

Hub sessions are the hub's children: when the hub ends, they end (the editor's mirrors turn `exited` and say so);
resuming them in a new hub (ACP `session/load`) is not built yet.

A peer message is text for the agent and nothing else: permission requests are answered only by the user's
`agents/permission`, and no message changes a setting. No agent offers a gate yet (a hook before each tool call),
so an agent's own edits are not held while it is behind — only its coordination writes are; its snapshot says
`:enforced nil`, and the job window (M9b.4) shows it.

## Tests

`test/unit/coord-test.el` (the store; the claim race), `coord-mcp-test.el` (the server over stdio),
`hub-agents-test.el` (sessions in the hub; a mock agent calling a tool through its `mcpServers`),
`agents-mirror-test.el` (mirrors, reattaching), `coord-delivery-test.el` (idle, busy, exited, peer messages,
decisions, leases). The mock agent's `coord TOOL JSON` prompt calls a tool of the server it was given.
