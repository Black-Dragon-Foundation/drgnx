# Agent coordination: the store, the tools, delivery

User docs: [Agents → Working together](../guide/agents.md#working-together). The hub and its socket:
[hub.md](hub.md).

Several agents on one project share what they decide, not only what they edit. The problem drgnx solves first is
**stale beliefs**: one agent changes the picture (a decision, a moved file, a feature dropped) and the others keep
working from the old one. So the shared state is explicit, versioned, and **enforced**.

## The store (`core/drgnx-coord.el`, `work.db` schema 5)

| Table | What |
|---|---|
| `job` | id, title, plan, repo, status (`proposed` `running` `paused` `stopped` `done`), created, data (the proposal, budget, review notes: a printed plist) |
| `jtask` | id (`JOB#N`), job, n, title, role, status, agent, lease_until |
| `jdep` | task → the task it depends on |
| `decision` | n, kind (`build` `wait` `wont-build` `replaces`), subject, task, paths, reason, author, status (`current` `proposed` `replaced`), replaces, at, ver |
| `message` | id, job, sender, recipient, text, state (`queued` `delivered` `read` `acted` `held`), reason, at, delivered, read, acted |
| `card` | id, job, task, kind, title, data (a printed plist: the waiting session, the request, …), state (`open` `settled`), at, settled_at, choice (schema 4) |
| `event` | id, at, agent, job, task, kind (`drgnx-coord-event-kinds`), summary (one line, at most 200 characters), data (a printed plist) — what happened, oldest first (schema 5) |
| `agent` | id, kind, name, cwd, worktree, branch, base, plan, task, pid, started, seen — who works, and where (schema 5) |
| `review_mark` | agent, path, state (`accepted` `pending`), hash, at — the user's review marks on an agent's changes (schema 5) |
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
  since. A `seen` ahead of the log is an error ("seen_version … is from the future"), never a pass: nothing was read at
  a version that does not exist yet.
- **Messages:** states only move forward. A reply (the recipient writing back to the sender) marks what it answers
  `acted`. Limits against chatty loops: an agent's undelivered queue holds `drgnx-coord-queue-limit` (20); one
  agent sends another at most `drgnx-coord-pair-rate` (6) a minute. Beyond either a message is `held` with its
  reason (`queue full`, `too many between these two`); the user's own Emacs, which sends with no sender, counts as the sender
  `user` for both that limit and the replies it makes. Escalations to `user` are never held as a full queue.

### Events, the registry and review marks

- **Events:** `drgnx-coord-event-add` (`:agent :job :task :kind :summary :data :at`) and `drgnx-coord-events` (`:since :agent
  :job :task :kinds :limit`, oldest first, ids after `:since`: a viewer keeps the last id and asks for what is newer;
  indexed by `at`, `(agent, id)`, `(job, id)` and `(kind, id)`). The writers above add their event in the **same
  transaction** as the change, so the two are there together or not at all: claim (`claim`, only when the task
  was `ready`: a holder's renewal writes nothing), release-stale (`release`), set-status and force-status (`status`),
  decide (`decision`), send (`message`; to `user` with a text starting `[escalation]`, `question`), card-create and
  card-settle (`card`; an `ask` card is a `question`, see below), card-set (`card`, when its state changes: a reopened
  card shows) and job-set (`job`, when its status changes). A held write (behind the log) or a refused claim writes
  nothing. `edit`, `test`, `start`, `stop`, `review`, `accept`, `revert`, `answer` and `comment` are written by their
  own sources through `drgnx-coord-event-add`.
- **What `data` may hold:** small, readable data — a plist of strings, numbers, symbols and lists of those; anything
  else (a buffer, a function, a hash table) is an error. It is printed with `print-length` 100 and `print-level` 6;
  over 4096 characters only `(:truncated t :size N)` is kept. It is read back with `read-eval` off. An `edit` event
  carries a path, a hash and line counts — never file contents or environment values.
- **Questions:** one model for everything that waits on the user. A `question` event is an escalation (a message to
  `user` starting `[escalation]`; data `(:message ID …)`) or an `ask` card (data `(:card ID)`). An `answer` event closes
  it: its `data` holds `(:question EVENT-ID)`. Settling an `ask` card writes that answer itself (by `user`);
  `drgnx-coord-open-questions` lists the questions with no answer.
- **Retention:** `drgnx-coord-events-prune` (`:before`, default `drgnx-coord-event-retention-days`, 30) forgets older
  events except `question`, `answer` and `decision`. `drgnx-coord-events-prune-daily` runs it at most once in 24 hours
  (stamp in `meta` as `event-pruned`) and never signals: meant for a periodic tick.
- **Busy database:** `work.db` opens with a 5-second busy timeout, so a writer waits for another Emacs's write lock for up
  to 5 seconds. After that SQLite reports the database locked. Claims, cards, messages, decisions and
  `drgnx-coord-event-add` then signal (the change did not happen: say so). Telemetry — `drgnx-coord-agent-seen` and
  `drgnx-coord-event-add-best-effort`, for the edit and test writers — returns nil instead: losing a heartbeat or an
  edit note must not fail the work it describes. A bad kind or bad `data` still signals.
- **Registry:** `drgnx-coord-agent-register` (an id is required; what is not given is kept, and when the agent started;
  `:clear` lists fields to set to NULL), `drgnx-coord-agent`, `drgnx-coord-agents`, `drgnx-coord-agent-seen` (stamps an
  agent alive now and returns the stamp).
- **Review marks:** `drgnx-coord-review-mark AGENT PATH STATE HASH` and `drgnx-coord-review-marks AGENT` (alist
  path → `(:state :hash :at)`). Accepting or reverting is a review layer only: nothing in the files changes.

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
| `list_agents` | the job's agents and their tasks: the hub's sessions of the job (`agents/list`, when a hub runs), else the job's tasks that have an agent |
| `send_message {to, text, seen_version}` | queue a message (never interrupts); `to` must be `user`, an agent of the job's tasks or a session the hub runs (any job's; id or name — a name is stored as the session's id), else the tool errors and nothing is written |
| `read_inbox` | unread messages (they become read) |
| `ack {id}` | acted on (only a message addressed to the caller) |
| `read_decisions {since}` | the log since a version, and the current version (recorded as the agent's `seen`) |
| `record_decision {kind, subject, task?, paths?, reason, replaces?, seen_version}` | current inside its own task, else proposed |
| `claim_task`, `update_task`, `complete_task` `{task, …, seen_version}` | the lease and the status; `update_task` takes `running`, `needs-input`, `in-review` (and `failed` outside a job), nothing else |
| `task_status {job?}` | the job's tasks |
| `work_status` | the work tracker's plans, as `drgnx work status --json` gives them (UTF-8 JSON; counts as `[done, all]`) |
| `escalate {subject, text, seen_version}` | a message to `user`, queued (the job window, M9b.4, shows it; until then nothing does) |

A held write answers `HELD: the decision log moved on — read these changes, then retry with seen_version N.` and
the changes as JSON. After a write the server tells the hub (`coord/notify`, never waiting) so delivery is prompt.

## What this does not protect against

The same Unix user is no security boundary. Anything running as the user — an agent, a command an agent ran, a
process it started — can connect to the hub's socket and call `agents/permission` (the answer a permission request
waits for), open `work.db` and write to it directly, or start a coordination server with `DRGNX_AGENT=user` (or any
other agent's id) and write as that identity. The checks above — freshness, who may change a task, who may answer
what, the message limits — stop mistakes and runaway loops among cooperating agents; they do not stop an agent that
means to go around them. The real boundary is the sandbox an agent runs in — one that keeps it away from the hub's
socket and from the state and data directories — not drgnx's own access rules.

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
for an edit or a command (kinds `edit` `delete` `move` `execute`; reading — `read_decisions` included, which Claude
Code asks for as an `other` tool — is never held) is checked against the log first (`drgnx-job--gate`): behind it — decisions of its job
since its `seen` — the call is refused (its `reject_once` option) and, once per version, the changes go into the
running turn (`drgnx-agents-steer`, the notice of delivery: `drgnx-coord-notice`) with "Your last tool call was
refused because you had not read these." Its next request after `read_decisions` goes by the policy again. An agent
that can be steered is held this way (its snapshot says `:enforced t`); one that cannot gets the coordination-tool
hold and turn-end delivery only (`:enforced nil`, which the job window shows). Reviewers are never gated (they read).
A task's prompt asks for `read_decisions` first.

## Jobs

`core/drgnx-job.el` runs in the hub (user docs: [jobs.md](../guide/jobs.md)). `drgnx-job-propose` reads the plan
(snapshot and SHA-1 in the job's data) and makes the job and its tasks (a plan that numbers a task twice is refused;
with `drgnx-job-auto-start` the job is approved first and the proposal card is made only if it is still proposed — the
hub's `--auto` path still makes and settles the card); `drgnx-job-approve` adds the job's worktree
and runs `drgnx-job-step`, which the hub's tick repeats for every running job: tasks whose agent is not live are
released, `in-review` tasks get a reviewer once their agent's turn is over (idle, free or held by a Stop) or the agent
is gone — the agent is then ended; a task with no commits on its branch (`git rev-list --count job/ID..HEAD` is 0)
gets a `review` card, "finished with no commits", instead — ready tasks get agents (`drgnx-job--start-task`: a worktree, made by a git process of its own
(`drgnx-job--git-async`, a sentinel continues: the task shows `starting` meanwhile, counts against
`drgnx-job-max-agents`, and a worktree that cannot be made is an `agent` card), then a session
with `DRGNX_JOB` and `DRGNX_TASK`, the task prompt given once the session is free), and a job whose tasks are all
done is done, and every session of it still running ends (a clash reviewer too, even one the user is discussing with:
the clash is moot by then). Prompts of sessions that ended before they were free are dropped. The hub wires it to sessions with hooks:

| Hook | drgnx-job |
|---|---|
| `drgnx-agents-changed-functions` | `drgnx-job--session-changed`: prompts out, a reviewer's verdict in (the last non-empty line of its last answer, starting `VERDICT:`, Markdown emphasis round it ignored), a step after a session ends or a finished task's agent's turn is over |
| `drgnx-agents-request-functions` | `drgnx-job--request`: permissions by `drgnx-job-policy` (allowed but with no `allow_once` option: a card), writes inside the worktree (missing directories are made), else a card |
| `drgnx-agents-error-functions` | `drgnx-job--agent-error`: a provider at its limit → `drgnx-job--fall-back` to the next profile; a task's reviewer → `drgnx-job--review-fall-back`: the review starts again on the next profile of the `review` route (a `review` card when none is left); a clash reviewer is left alone |
| `drgnx-gateway-event-functions` | `drgnx-job--gateway-event`: `budget` → the job pauses, its agents stop |

`complete_task` from an agent of a job (`DRGNX_JOB` set) puts the task `in-review`, not `done`, and `update_task`
there takes only `running`, `needs-input` and `in-review`; the reviewer's verdict decides (`drgnx-job--reviewed`, `drgnx-job--merge`: the merge is a git process of its own, the task shows `merging` meanwhile
(`drgnx-job--busy`, in the hub's memory only: a restart finds the store's `in-review` and the "merged before" check);
a merge that fails with no unmerged files gets a `merge-conflict` card titled `merge failed: <git output>`;
`drgnx-job--git`, the short synchronous reads, returns stderr after stdout when git fails; the job's own worktree at
approval is still made synchronously, for the command that asked). A card (`drgnx-job--card`) is a `card` row — one open per task and kind, actions by
kind (`drgnx-job-card-actions`), acted on once through `job/card` (`drgnx-job-card-act`: settled first, so a second
action is refused; reopened if the action fails) — plus a message from `drgnx` to `user` with the job and task (one line, `acted` once settled), the task `needs-input`, and a `card` event (job, task, kind, title); a
card for an agent's pending request records it in the job's data (`:waiting`: the session, and the status to go back
to — `in-review` for a reviewer's, and for an agent of a task already in review whose turn went on), so an answer, or
the agent's end, puts the task back; the job's data also keeps, per task, how often its agent ended (`:exits`) and was
nudged (`:nudged`; cleared on review and on retry) and when a task in review began to wait for its agent's turn to end
(`:in-review-since`; after `drgnx-job-review-turn-limit` seconds, 600, a `stalled` card), so a hub restart does not
reset them; `fallback` events carry job,
task, agent, from, to, why, and the successor's handover names the decision log's version. The hub's `job/propose`, `job/approve`, `job/status`, `job/stop`,
`job/resume` ([hub.md](hub.md)) answer `drgnx-job-summary` (a task's `:profile` is its current agent's, else the route's first); `job/resume`
refuses a job with no job worktree (a rejected proposal); `bin/drgnx job` and the Plan Job commands use them
(`--json` gives empty list fields as `[]`, `drgnx-job--json-lists`; `--budget` must be a number). A proposal with a
budget lists in its data (`:unpriced-budget`) the profiles of its routes whose gateway chain has a provider without a
`:price`, and warns (the proposal card, `:warnings` in the summary): the gateway cannot count what they spend.
A notification to the hub (`coord/notify`) carries no id and gets no answer: the sender has hung up by then.

## Clashes (`core/drgnx-job-clash.el`)

Fixed rules, in the hub (its tick, and after `coord/notify`); a model's judgment only inside the reviewer:

| Rule | When | Result |
|---|---|---|
| `contradiction` | a `build` and a `wont-build` of one subject (lower case, spaces collapsed) among a job's current or proposed decisions | the user's side, if one is, wins at once (one user `replaces` of the other, however many of the user's decisions it contradicts — no card); agents' → a `clash` card |
| `proposed` | an agent's decision outside its own task (one in a contradiction has that card only) | a `clash` card: record it, or leave it out |
| `against-decision` | a task in review whose branch (`git diff job/ID...job/ID-N`) changes what a current won't-build's `paths` cover (a directory, a file, a `*` glob) | a `clash` card about the task; its review waits (`drgnx-job-before-review-functions`) |
| `stale` | an agent whose last two coordination writes were held (`held:AGENT` in `meta`, kept by the MCP server) | a `stalled` card |
| `overlap` | a task in review that changes files another open task changes | an `overlap` card, advisory (dismiss): the review goes on |

Each clash is carded once (its key in the job's data, `:clashes`); a card's data has the rule, the sides (label,
text, decision, agent, task), the subject and a size: `long` for work against a decision, a diff over
`drgnx-job-clash-long-lines` (200) lines, or a subject that clashed before, else `short`.

A clash card gets a **reviewer** (role `review`, or `review-long` for a long clash when it has a route) in the job's
worktree under the review policy: `[drgnx clash CARD]`, both sides with their reasons (a long review also the last
4000 characters each side's agent said), answered with a last line `RECOMMEND: A`, `B` or `neither: why`
(`drgnx-job-clash--recommendation`, onto the card's data as `(:side :why)`; an answer with no `RECOMMEND:` line sets
`:no-recommendation`, and the card's data names its reviewer's session as `:reviewer`, for its transcript). The card
offers **Accept** only when the recommendation has a side. It stays for **Discuss** (the user's
text, quoted, goes to it; a gone one is started again with it) and ends when the card is settled, or when the job is
done (even mid-discussion). A clash without a
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
