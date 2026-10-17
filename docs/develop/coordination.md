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
  and sends `lease-released`). Only the holder changes a task's status.
- **The decision log:** one version, raised by every decision (a decision's `ver` is the version of its last
  change, so a later `replaces` shows up in `drgnx-coord-decisions-since`). The user's decisions are current; an
  agent's are current inside its own claimed task, otherwise **proposed** (for the reviewer and the user).
- **Freshness is enforced:** every write — claim, status, decision, message — takes the version its author last read
  (`seen`). Behind: nothing is written, and the answer is `(:held t :version V :changes DECISIONS)` with every change
  since.
- **Messages:** states only move forward. A reply (the recipient writing back to the sender) marks what it answers
  `acted`. Limits against chatty loops: an agent's undelivered queue holds `drgnx-coord-queue-limit` (20); one
  agent sends another at most `drgnx-coord-pair-rate` (6) a minute. Beyond either a message is `held` with its
  reason (`queue full`, `too many between these two`).

## The tools (`core/drgnx-mcp.el`, `core/drgnx-coord-mcp.el`)

`drgnx-mcp-serve NAME TOOLS` is a small MCP server (stdio, protocol 2025-06-18: initialize, ping, tools/list,
tools/call). A tool is `(NAME :description :schema :call FN)`; FN gets the arguments as a plist and returns a
string or a value (sent as JSON); its errors are `isError` results. `drgnx-mcp-schema` builds the input schema.

Every agent session gets the coordination server in ACP's `mcpServers` (`drgnx-agents--mcp-servers`, from
`drgnx-coord-mcp-server-spec`): one batch Emacs per agent, its identity in its environment (`DRGNX_AGENT` = the
session's name, `DRGNX_JOB`, `DRGNX_TASK`, and drgnx's data and state dirs). Without `DRGNX_AGENT` it only reads.

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
| `escalate {subject, text, seen_version}` | a message to `user` (a card in the job window, M9b.4) |

A held write answers `HELD: the decision log moved on — read these changes, then retry with seen_version N.` and
the changes as JSON. After a write the server tells the hub (`coord/notify`, never waiting) so delivery is prompt.

## Delivery (the hub)

`drgnx-hub--deliver` runs on `coord/notify` and every 2 s:
- a `queued` message for a hub session of that name goes to the agent as `[message from SENDER #ID] TEXT` —
  idle: a new turn; busy: queued for its turn's end (M7's queue; never cancelling) — and is `delivered`; when that
  prompt reaches the agent (`drgnx-agents-prompt-functions`) it is `read`. A message for an agent that is not there,
  or exited, stays `queued`;
- an agent whose `seen` version is behind the log gets `[decision log vN] …changes… — call read_decisions` once per
  version.

A peer message is text for the agent and nothing else: permission requests are answered only by the user's
`agents/permission`, and no message changes a setting. No agent offers a gate yet (a hook before each tool call),
so an agent's own edits are not held while it is behind — only its coordination writes are; its snapshot says
`:enforced nil`, and the job window (M9b.4) shows it.

## Tests

`test/unit/coord-test.el` (the store; the claim race), `coord-mcp-test.el` (the server over stdio),
`hub-agents-test.el` (sessions in the hub; a mock agent calling a tool through its `mcpServers`),
`agents-mirror-test.el` (mirrors, reattaching), `coord-delivery-test.el` (idle, busy, exited, peer messages,
decisions, leases). The mock agent's `coord TOOL JSON` prompt calls a tool of the server it was given.
