# Agent coordination: the store, the tools, delivery

User docs: [Agents → Working together](../guide/agents.md#working-together). The hub and its socket:
[hub.md](hub.md).

Several agents on one project share what they decide, not only what they edit. The problem drgnx solves first is
**stale beliefs**: one agent changes the picture (a decision, a moved file, a feature dropped) and the others keep
working from the old one. So the shared state is explicit, versioned, and **enforced**.

## The store (`core/drgnx-coord.el`, `work.db` schema 3)

| Table | What |
|---|---|
| `job` | id, title, plan, repo, status (`proposed` `running` `paused` `stopped` `done`), created, data (the proposal, budget, review notes: a printed plist) |
| `jtask` | id (`JOB#N`), job, n, title, role, status, agent, lease_until |
| `jdep` | task → the task it depends on |
| `decision` | n, kind (`build` `wait` `wont-build` `replaces`), subject, task, paths, reason, author, status (`current` `proposed` `replaced`), replaces, at, ver |
| `message` | id, job, sender, recipient, text, state (`queued` `delivered` `read` `acted` `held`), reason, at, delivered, read, acted |
| `card` | id, job, task, kind, title, data (a printed plist: the waiting session, the request, …), state (`open` `settled`), at, settled_at, choice (schema 4) |
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
`agents/permission`, and no message changes a setting. **The gate:** a job agent's permission request
(edits and commands ask one) is checked against the log first (`drgnx-job--gate`): behind it — decisions of its job
since its `seen` — the call is refused (its `reject_once` option) and, once per version, the changes go into the
running turn (`drgnx-agents-steer`, the notice of delivery: `drgnx-coord-notice`) with "Your last tool call was
refused because you had not read these." Its next request after `read_decisions` goes by the policy again. An agent
that can be steered is held this way (its snapshot says `:enforced t`); one that cannot gets the coordination-tool
hold and turn-end delivery only (`:enforced nil`, which the job window shows). Reviewers are never gated (they read).
A task's prompt asks for `read_decisions` first.

## Jobs

`core/drgnx-job.el` runs in the hub (user docs: [jobs.md](../guide/jobs.md)). `drgnx-job-propose` reads the plan
(snapshot and SHA-1 in the job's data) and makes the job and its tasks; `drgnx-job-approve` adds the job's worktree
and runs `drgnx-job-step`, which the hub's tick repeats for every running job: tasks whose agent is not live are
released, `in-review` tasks get a reviewer, ready tasks get agents (`drgnx-job--start-task`: a worktree, a session
with `DRGNX_JOB` and `DRGNX_TASK`, the task prompt given once the session is free), and a job whose tasks are all
done is done. The hub wires it to sessions with hooks:

| Hook | drgnx-job |
|---|---|
| `drgnx-agents-changed-functions` | `drgnx-job--session-changed`: prompts out, a reviewer's verdict in, a step after a session ends |
| `drgnx-agents-request-functions` | `drgnx-job--request`: permissions by `drgnx-job-policy`, writes inside the worktree, else a card |
| `drgnx-agents-error-functions` | `drgnx-job--agent-error`: a provider at its limit → `drgnx-job--fall-back` to the next profile |
| `drgnx-gateway-event-functions` | `drgnx-job--gateway-event`: `budget` → the job pauses, its agents stop |

`complete_task` from an agent of a job (`DRGNX_JOB` set) puts the task `in-review`, not `done`, and `update_task`
there takes only `running`, `needs-input` and `in-review`; the reviewer's verdict decides (`drgnx-job--reviewed`, `drgnx-job--merge`). A card (`drgnx-job--card`) is a `card` row — one open per task and kind, actions by
kind (`drgnx-job-card-actions`), acted on once through `job/card` (`drgnx-job-card-act`: settled first, so a second
action is refused; reopened if the action fails) — plus a message from `drgnx` to `user` with the job and task (one line, `acted` once settled), the task `needs-input`, and a `card` event (job, task, kind, title); a
card for an agent's pending request records it in the job's data (`:waiting`: the session, and the status to go back
to — `in-review` for a reviewer's), so an answer, or the agent's end, puts the task back; `fallback`
events carry job, task, agent, from, to, why. The hub's `job/propose`, `job/approve`, `job/status`, `job/stop`,
`job/resume` ([hub.md](hub.md)) answer `drgnx-job-summary`; `bin/drgnx job` and the Plan Job commands use them.
A notification to the hub (`coord/notify`) carries no id and gets no answer: the sender has hung up by then.

## Clashes (`core/drgnx-job-clash.el`)

Fixed rules, in the hub (its tick, and after `coord/notify`); a model's judgment only inside the reviewer:

| Rule | When | Result |
|---|---|---|
| `contradiction` | a `build` and a `wont-build` of one subject (lower case, spaces collapsed) among a job's current or proposed decisions | the user's side, if one is, wins at once (a user `replaces` of the other — no card); agents' → a `clash` card |
| `proposed` | an agent's decision outside its own task | a `clash` card: record it, or leave it out |
| `against-decision` | a task in review whose branch (`git diff job/ID...job/ID-N`) changes what a current won't-build's `paths` cover (a directory, a file, a `*` glob) | a `clash` card about the task; its review waits (`drgnx-job-before-review-functions`) |
| `stale` | an agent whose last two coordination writes were held (`held:AGENT` in `meta`, kept by the MCP server) | a `stalled` card |
| `overlap` | a task in review that changes files another open task changes | an `overlap` card, advisory (dismiss): the review goes on |

Each clash is carded once (its key in the job's data, `:clashes`); a card's data has the rule, the sides (label,
text, decision, agent, task), the subject and a size: `long` for work against a decision, a diff over
`drgnx-job-clash-long-lines` (200) lines, or a subject that clashed before, else `short`.

A clash card gets a **reviewer** (role `review`, or `review-long` for a long clash when it has a route) in the job's
worktree under the review policy: `[drgnx clash CARD]`, both sides with their reasons (a long review also the last
4000 characters each side's agent said), answered with a last line `RECOMMEND: A`, `B` or `neither: why`
(`drgnx-job-clash--recommendation`, onto the card's data as `(:side :why)`). It stays for **Discuss** (the user's
text, quoted, goes to it; a gone one is started again with it) and ends when the card is settled. A clash without a
recommendation whose reviewer is gone gets one more (at most two per hub run). The user's choice is a decision of
the user's — a `replaces` of the other side for a contradiction; the proposal recorded (or replaced) for a proposed
decision; for work against a decision, the task back to an agent told which files to revert (A), or the decision
replaced and the review going on (B) — and the log's delivery tells every agent of the job.
`drgnx-job-clash-auto-accept` (nil): a short clash's recommendation accepted without the user.

## Tests

`test/unit/coord-test.el` (the store; the claim race), `coord-mcp-test.el` (the server over stdio),
`hub-agents-test.el` (sessions in the hub; a mock agent calling a tool through its `mcpServers`),
`agents-mirror-test.el` (mirrors, reattaching), `coord-delivery-test.el` (idle, busy, exited, peer messages,
decisions, leases); the job tests are listed in [jobs.md](../guide/jobs.md#tests). The mock agent's `coord TOOL JSON` prompt
calls a tool of the server it was given; `[drgnx task ID]` does a task, `[drgnx review ID]` reviews one
(`MOCK_ACP_VERDICT=fail`), `MOCK_ACP_RATE_LIMIT` answers every prompt with a 429.
