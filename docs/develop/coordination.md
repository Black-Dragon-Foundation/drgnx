# Agent coordination: the store, the tools, delivery

User docs: [Agents → Working together](../guide/agents.md#working-together). The hub and its socket:
[hub.md](hub.md).

Several agents on one project share what they decide, not only what they edit. The problem drgnx solves first is
**stale beliefs**: one agent changes the picture (a decision, a moved file, a feature dropped) and the others keep
working from the old one. So the shared state is explicit, versioned, and **enforced**.

## The store (`core/drgnx-coord.el`, `work.db` schema 6)

Schema 6 (Ratatoskr): every `data` column (`node`, `job`, `jtask`, `card`, `event`) is JSON text, checked by the
database (`check (data is null or json_valid(data))`), written and read through the record schemas of
`core/drgnx-records.el` (`drgnx-records-node-data`, `-job-data`, `-card-data`, `-event-data`). A nil value leaves its
key out, so a missing key and a nil are the same. Three facts that used to be matched in printed text are columns now:
`event.turn` (1 for a turn's `start` and `stop`), `message.answers` (the id of the question message it answers) and
`card.ref` (an `ask` card's question event). No SQL matches printed Lisp any more (`drgnx-work-db/no-sql-matches-printed-lisp`).
`meta` `compat-read` is `6`: the level a reader understands (`drgnx-work-db-compat-read`).

**The migration** (`drgnx-work-db--migrate-6`, one `begin immediate` transaction: all or nothing) rebuilds the five
tables, keeping ids, `sqlite_sequence` and indexes. Each old `data` is read with `read-eval` off and encoded with its
record schema; a row that does not read (cut short, `#<buffer>`), that no schema covers (a symbol in a key outside
the enums) or that anything else fails on (any error while it is read or encoded is that row's alone) gets NULL, is counted in `meta` `migrate-6-dropped` and is said once in one message. It is safe to run
twice: once the tables have their new columns it does nothing. Before the transaction a pre-6 file is copied with
`VACUUM INTO` to `work.db.schema5` (only when that file does not exist yet). An older drgnx refuses the migrated
file ("a newer schema"). **To go back by hand:** stop the hub, then `mv work.db.schema5 work.db` and remove
`work.db-wal` and `work.db-shm`; what was recorded after the migration is lost.

| Table | What |
|---|---|
| `job` | id, title, plan, repo, status (`proposed` `running` `paused` `stopped` `done`), created, data (the proposal, budget, review notes: JSON) |
| `jtask` | id (`JOB#N`), job, n, title, role, status, agent, lease_until |
| `jdep` | task → the task it depends on |
| `decision` | n, kind (`build` `wait` `wont-build` `replaces`), subject, task, paths, reason, author, status (`current` `proposed` `replaced`), replaces, at, ver |
| `message` | id, job, sender, recipient, text, state (`queued` `delivered` `read` `acted` `held`), reason, at, delivered, read, acted, answers (schema 6) |
| `card` | id, job, task, kind, title, data (JSON: the waiting session, the request, …), state (`open` `settled`), at, settled_at, choice (schema 4), ref (schema 6) |
| `event` | id, at, agent, job, task, kind (`drgnx-coord-event-kinds`), summary (one line, at most 200 characters), data (JSON), turn (schema 6) — what happened, oldest first (schema 5) |
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

### Reading work.db

Every function that only reads (outside a `drgnx-coord--tx` lambda) reads through `(drgnx-work-db-read)`: a
read-only handle (`sqlite-open` with the read-only flag, `busy_timeout` 5000), cached per file, that never migrates
and never writes. Closing it never checkpoints, so a reader that outlives the writer leaves the WAL as it is.
`drgnx-work-db-close-all` closes the readers first, then the writers.

- A missing file, or a schema below `drgnx-work-db-schema-version`, is first made or migrated by the writer
  (`(drgnx-work-db)`, once): until the hub is Rust, every drgnx Emacs is still a writer.
- A newer schema is read when its `meta` `compat-read` is at most `drgnx-work-db-compat-read`; otherwise
  `drgnx-work-db-too-new` is signalled ("work.db is schema N, which this drgnx cannot read: update drgnx").
- A select inside a transaction keeps the transaction's handle. A function that reads and then writes may read on the
  writer: it is named, with the reason, in `drgnx-work-db--writer-reads`. The test
  `drgnx-work-db/readers-use-the-read-only-path` walks the sources and fails on any other `sqlite-select` on
  `(drgnx-work-db)`, direct or through a `let`-bound handle.
- The cockpit's change stamps (`data_version`, `total_changes()`) run on the read handle: `data_version` moves when
  the writer in the same Emacs commits.

### Events, the registry and review marks

- **Events:** `drgnx-coord-event-add` (`:agent :job :task :kind :summary :data :at`) and `drgnx-coord-events` (`:since :agent
  :job :task :kinds :limit`, oldest first, ids after `:since`: a viewer keeps the last id and asks for what is newer;
  indexed by `at`, `(agent, id)`, `(job, id)` and `(kind, id)`). The writers above add their event in the **same
  transaction** as the change, so the two are there together or not at all: claim (`claim`, only when the task
  was `ready`: a holder's renewal writes nothing), release-stale (`release`), set-status and force-status (`status`),
  decide (`decision`), send (`message`; to `user`, `question` when asked with `:question`, as `ask_user` does, or —
  from drgnx's own agents, never from an `ext:` one — with a text starting `[escalation]`), card-create and
  card-settle (`card`; an `ask` card is a `question`, see below), card-set (`card`, when its state changes: a reopened
  card shows) and job-set (`job`, when its status changes). A held write (behind the log) or a refused claim writes
  nothing. `edit`, `test`, `start`, `stop`, `review`, `accept`, `revert`, `answer` and `comment` are written by their
  own sources through `drgnx-coord-event-add` — for the hub's sessions and jobs (turns, edits, permissions, verdicts,
  merges), the hub ([hub.md](hub.md#events)).
- **What `data` may hold:** small data — a plist of strings, numbers, `t`, nested plists and lists of those, and
  the enum symbols of `drgnx-records-event-data`; anything else (a buffer, a function, a hash table, a symbol no
  schema covers) is an error. It is stored as JSON; over 4096 characters only `{"truncated":true,"size":N}` is kept.
  It is parsed back by the schema; `read` is never called. A key given twice keeps its first value. An `edit` event
  carries a path, a hash and line counts — never file contents or environment values.
- **Questions:** one model for everything that waits on the user. A `question` event is a message to `user` that asks
  (`drgnx-coord-send` with `:question` — `ask_user` — or an escalation, a text starting `[escalation]`, from drgnx's own
  agents: an agent outside drgnx (`ext:…`) asks only through `ask_user`, so its messages are never questions, whatever
  they say; data `(:message ID …)`) or an `ask` card (data `(:card ID)`). An `answer` event closes
  it: its `data` holds `(:question EVENT-ID)`. Settling an `ask` card writes that answer itself (by `user`);
  `drgnx-coord-open-questions` lists the questions with no answer.
- **Retention:** `drgnx-coord-events-prune` (`:before`, seconds since the epoch; default
  `drgnx-coord-event-retention-days`, 30, ago) forgets older events except `question`, `answer` and `decision`.
  `drgnx-coord-events-prune-daily` runs it at most once in 24 hours (stamp in `meta` as `event-pruned`) and never
  signals (a locked database waits for the next call, any other error is a message): meant for a periodic tick. On
  every call it also holds the log to `drgnx-coord-event-max-rows` (100,000), the oldest going first (questions,
  answers and decisions apart), so a busy day is bounded before the next prune. Event ids are `autoincrement`: an id is
  never given twice, even after the newest rows were pruned.
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

## The writer (`runtime/crates/norn`, `runtime/crates/urdr`)

Ratatoskr writes the coordination tables through `norn`; the Lisp in `core/drgnx-coord.el` stays the oracle until it
is deleted. Rules:

- **Schema 6 only.** `urdr`'s `Mode::ReadWriteExisting { expect_schema, synchronous_full }` opens an existing file
  read-write. It never creates a file, never migrates and leaves the journal mode alone; `busy_timeout` is 5 s. A
  missing file is `Error::Missing`, a `meta.schema` other than the expected one is `Error::Schema { found }`, with
  nothing written. The Lisp side makes and migrates `work.db`.
- **One thread.** `norn::store::CoordDb` owns the connection on `urdr`'s store thread, so no statement runs on an async
  worker. `write` runs its closure inside `BEGIN IMMEDIATE` (committed on `Ok`, rolled back on `Err`); `read` runs
  outside a transaction. The closure gets `&Tx` (the connection, already in the transaction).
- **Not ready.** Below schema 6 (or missing) a write is `NotReady { schema }`: "work.db is not ready (schema N); the
  Lisp side makes it". A newer schema is opened read-only; a write is `ReadOnly { schema }`.
- **Follows the file.** The hub's 2 s schema tick calls `CoordDb::tick`: it opens when not open, and opens again when
  the file's `(dev, inode)` changed (a removed and re-made `work.db`, R-T14-2). A read or write that finds the file
  not open runs that open once itself first (on a blocking thread), so a `work.db` made after the hub started is used
  by the next call, the front's methods and the coordination tools alike, not 2 s later.
- **Events and meta.** `write::event` is `drgnx-coord--event`: the summary is one line of at most 200 characters
  (`runstav::text::one_line`), data over 4096 characters is stored as `{"truncated": true, "size": N}`, `turn` is 1
  for a `start`/`stop` whose data has `turn: true`, and the kind is one of the 17 of `drgnx-coord-event-kinds` (a test
  reads the Lisp list). `write::meta` keeps `log-version`, `seen:AGENT` and `held:AGENT`.
- **Messages, cards, review marks and agents.** `write::messages` (`send`, `mark`, `message_prompt`, `notice`),
  `write::cards`, `write::review` and `write::agents` are the Lisp writers of the same names, rule for rule: `send`
  is held by the log version (an answer with the versions, never a write; a version from the future is an error),
  holds a message for a full queue (20, never for `user`) or a chatty pair (6 a minute), closes what the other side
  sent, and writes its `question` or `message` event in the same transaction; `mark` goes forward only and never from
  `held`; a card is settled once and an `ask` card is a `question` event whose settling is an `answer`; a review
  mark takes an optional event of its own; `agent_register` keeps what is not given and `clear` nulls named fields.
  Every writer takes the caller's clock (`now`). The typed readers are in `read::{messages,cards,review,agents}`.
  `Held` carries the versions only: the caller adds `changes` from the decision reader.
- **Jobs, tasks, decisions, pruning.** `write::jobs` (`job_create`, `job_set`), `write::tasks` (`claim`,
  `set_status`, `force_status`, `heartbeat`, `renew`, `release_stale`; the lease is 15 minutes, only `claimed` and
  `running` claims go stale, so `needs-input` and `in-review` keep theirs), `write::decisions` (`held_check`,
  `decide`: the version check, 6 decisions a minute per agent, `current` versus `proposed`, `replaces`, the author's
  own `seen`) and `write::prune` (30 days and 100,000 rows; questions, answers and decisions are kept; the
  `event-pruned` meta key) port the Lisp of the same names. Each takes the time as an argument. The readers are
  `read::{jobs,tasks,decisions}`.
- **Parity.** `test/fixtures/coord-parity/CASE.input.json` (`setup`, `clock`, `calls`, optionally `tables`, the tables
  to compare besides `event` and `meta`) is run by `gen.el` against the real Lisp functions, which writes
  `CASE.expect.json` (results and tables); `norn/tests/parity.rs` replays each input against the Rust writers with the
  same clock. A call with `"now": T` sees T at every `float-time`; a refused call is `{"signal": MESSAGE}`. `test/fixtures/work-db-6.sql` is the schema every Rust test starts
  from. Run `gen.el` by hand in the build container (its header has the commands); the fixtures stay when the Lisp is
  deleted.

### Who writes what

Under Ratatoskr, work.db has one writer per table group while the job runner is still Lisp (hub.md, "Ratatoskr and
the Lisp backend"):

| Writes | Through | Who calls |
|---|---|---|
| a card settled, a message sent or marked, an event, a review mark and its event | the front's `cards/settle`, `messages/send`, `messages/mark`, `events/add`, `review/mark` (`drgnx-ratatoskr/src/coord.rs` on `norn::write`) | the editor (a user connection); the Lisp backend too |
| jobs, tasks, leases, decisions, agents, the job runner's cards, held counts, the daily prune | the seam's `coord/job-create`, `coord/job-set`, `coord/task-status`, `coord/leases`, `coord/decide`, `coord/agent`, `coord/card-create`, `coord/card-set`, `coord/held`, `coord/prune` | the Lisp job runner (the backend), until it moves to Rust (phase 6) |
| what the coordination tools write | `norn::tools` on the same `CoordDb` (`Front.tools`) | agents, through the MCP hosting |

The Lisp side writes none of these tables itself. `drgnx-coord-writer` decides what each public writer of
`core/drgnx-coord.el` does (a `pcase` in every one, including those that write with a direct `sqlite-execute`):
- `front` (the backend behind Ratatoskr: `drgnx-hub-main` with a serve socket) calls the front's method above through
  `drgnx-hub-call-front` (hub.md, "The backend writes through the front") and decodes its answer to the plist, id or
  t/nil the function returned before. A refusal of the front is an `error` with its message. `claim`,
  `set-status`, `heartbeat`, `set-seen` and `events-prune` have no front method (only the coordination tools,
  `norn::tools`, write them): behind the front they signal "NAME has no front method"; `events-prune-daily` is
  `coord/prune`, whose retention is the front's;
- `local` (the standalone Lisp hub without a serve socket, `lisp-hub.sh`, and the unit tests: `harness/run-ert.el`
  sets it, and a test's child Emacs that writes passes `--eval "(setq drgnx-coord-writer 'local)"`) writes work.db
  as before;
- `refuse`, the default, signals "coordination writes go through the drgnx hub (Ratatoskr)": an editor, the CLI and
  the Lisp coordination server (`drgnx-coord-mcp-main`, until agents use the Rust bridge) never write these tables.
  `drgnx-coord--tx` signals unless `local`.

The front's methods take the Lisp keywords as params (`messages/send` `{recipient, text, job?, sender?, seen?,
answers?, question?}`; only the backend may name a `sender`) and answer the Lisp results typed: `messages/send` is
`{ok, id, state}` or `{held, version, changes}` (the decisions after `seen`, newest first, as `decisions_since` reads
them), `coord/decide` `{ok, n, status, version}`, `{held, version, changes}` or `{error}`, `coord/leases`
`{released: [{task, agent, job}]}`. Each is one transaction; each committed one is counted in `status`'s
`store.writes`, sends its new events to subscribers and, unless the backend made it, tells the backend
(`coord/notify`, coalesced) so it delivers.

### The editor writes through the hub

The cockpit (`modules/tools/drgnx-cockpit*.el`) writes nothing to `work.db`; its five writes are hub calls
(`drgnx-hub-call`, asynchronous: a path the user did not wait on never waits):

| Where | Call |
|---|---|
| answering an ask card (`drgnx-cockpit-answer`) | `cards/settle`; `{settled: false}` says "That card was settled already" |
| an answer to a message, a message to an agent (feed, cards, edits) | `messages/send`; a held one says why |
| an answer closes its question | `events/add` (the `answer` event), then `messages/mark` `acted`, in that order |
| a comment or a revert request in the edits pane | `messages/send`, then `events/add` once it was sent |
| accepting a file | one `review/mark` with its `accept` event |

An error is said once as "drgnx hub: TEXT". The editor sends no `coord/notify` after a send: the front notifies
itself after a write. Reads stay on the read-only path. `drgnx-cockpit/no-writer-call-in-the-modules` walks the cockpit
modules and `core/drgnx-cockpit-model.el` for a `drgnx-coord-` writer or a `sqlite-execute`.

## The tools (`core/drgnx-mcp.el`, `core/drgnx-coord-mcp.el`)

`drgnx-mcp-serve NAME TOOLS` is a small MCP server (stdio, protocol 2025-06-18: initialize, ping, tools/list,
tools/call). A tool is `(NAME :description :schema :call FN)`; FN gets the arguments as a plist and returns a
string or a value (sent as JSON); its errors are `isError` results. `drgnx-mcp-schema` builds the input schema.

### How an agent reaches the tools

Every agent session gets the coordination tools in ACP's `mcpServers` (`drgnx-agents--mcp-servers`, from
`drgnx-coord-mcp-server-spec`) as Ratatoskr's bridge: `<data>/bin/ratatoskr mcp-bridge --socket PATH`, with an empty
environment. PATH is the `mcp.sock` of a session the hub minted for it (`mcp/session`, called by
`drgnx-hub-mcp-session` from `drgnx-agents--with-mcp` just before `session/new` or `session/load`): the socket is the
identity, and it names the session's **id** (`s-…` — a name like "claude · drgnx" repeats across hubs and editors),
its job and task. The owner is the Emacs that made it (`(emacs-pid)`): when it dies the hub closes the session, and a
session's end calls `mcp/session-close` (`drgnx-hub-mcp-session-close`). In the backend the call goes to the front
(`drgnx-hub-call-front`); in an editor a command waits at most 2 s; a timer or startup path asks without waiting and
the session start continues from the answer. When the session cannot be made (no binary, no hub) the agent starts
without the coordination tools and says why in its transcript. An agent outside drgnx runs `ratatoskr mcp-bridge
--outside --kind KIND` (or the old `bin/drgnx coord mcp --kind KIND`, which execs it) and gets an identity of its own
(below). Messages are addressed to a session's id (or its name). The Lisp server (`drgnx-coord-mcp-main`) stays on
disk, launched by nothing, until phase 7: a sandboxed session's hub-run coordination server is the same bridge
(`drgnx-sandbox-mcp.el`).

| Tool | Does |
|---|---|
| `list_agents` | the job's agents and their tasks: the hub's sessions of the job (`agents/list`, when a hub runs), else the job's tasks that have an agent |
| `send_message {to, text, seen_version}` | queue a message (never interrupts); `to` must be `user`, an agent of the job's tasks or a session the hub runs (any job's; id or name — a name is stored as the session's id), else the tool errors and nothing is written |
| `read_inbox` | unread messages (they become read) |
| `ack {id}` | acted on (only a message addressed to the caller); the hub is told only when the state moved |
| `read_decisions {since}` | the log since a version, and the current version (recorded as the agent's `seen`, written only when it moved) |
| `record_decision {kind, subject, task?, paths?, reason, replaces?, seen_version}` | current inside its own task, else proposed |
| `claim_task`, `update_task`, `complete_task` `{task, …, seen_version}` | the lease and the status; `update_task` takes `running`, `needs-input`, `in-review` (and `failed` outside a job), nothing else |
| `task_status {job?}` | the job's tasks |
| `work_status` | the work tracker's plans, as `drgnx work status --json` gives them (UTF-8 JSON; counts as `[done, all]`) |
| `escalate {subject, text, seen_version}` | a message to `user`, queued (the Work cockpit's What needs you shows it) |

A held write answers `HELD: the decision log moved on — read these changes, then retry with seen_version N.` and
the changes as JSON. After a write the server tells the hub (`coord/notify`, never waiting) so delivery is prompt.

### Reports, and agents outside drgnx

Every agent — drgnx's own and agents outside it (Claude Code in a terminal or Zed, Codex, gry workers, subagents) —
reports what it does with four more tools. Their events feed the Work cockpit:

| Tool | Does |
|---|---|
| `hello {name?, cwd?, branch?, plan?, task?}` | registers the agent (`drgnx-coord-agent-register`): kind, name, cwd, worktree (`git rev-parse --show-toplevel` of the cwd), branch (given, else the cwd's), plan, task, pid. `base` is `git rev-parse HEAD` of the cwd at its first hello, kept by later ones (taken again only when the agent shows up in another worktree). A first hello writes a `start` event. Answers `{agent, version, cwd, worktree, base}` (the identity and the decision log's version), and a `note` when the identity is a fallback |
| `report_edit {paths, summary?}` | an `edit` event, data `(:root ROOT :paths (RELATIVE…) [:more N])`. `paths` is best an array of strings. A string takes one path per line; only a string with no newline is split on commas (so a name with a comma needs the array or lines). At most 1,000 paths; more are refused before any is looked at. Each must lie inside the agent's worktree (else its cwd), or the whole report is refused and nothing is written |
| `report_test {command, passed?, failed?, summary?}` | a `test` event, data `(:command :passed :failed)`. The counts must be whole numbers, 0 or more. With no summary, the summary is `N passed, M failed: COMMAND` |
| `ask_user {question, options?, task?}` | a message to `user` starting `[escalation]`, sent with `:question t`, so its event is a `question` and `drgnx-coord-open-questions` lists it. Options are an array of strings (best; `items` declared) or one per line, at most 20; an option holding a `\|` (the separator drgnx writes them with) is refused. Any line of the question starting `Options:` is dropped: that line is drgnx's to write. For one of drgnx's agents, a task it holds (`task`, else `DRGNX_TASK`) goes to `needs-input`. The answer comes back as a message (`read_inbox`) |

**Identity.**
- **drgnx's own agents:** `DRGNX_AGENT`, trusted as before. drgnx sets it in the environment of the server it gives
  each session (the session's id, `s-XXXXXXXX`), and nothing checks who it is — only what it is. It is never
  `user` (in any case, spaces around it ignored): the hub gives `user`'s messages to agents as the user's, so a server
  with that identity refuses every tool (`"user" is the user`). And it is a plain ASCII id — letters, digits and
  `. _ : -`, not starting with one of those four, at most 64 characters (`drgnx-coord-mcp--id-regexp`) — else every
  tool is refused (`not a plain id`): a newline or `]` would break out of the hub's header, and a lookalike of `user`
  (a no-break or zero-width space, a Cyrillic `ѕ`) would read as the user. Binding it to a token, as the gateway binds an agent's key, is deferred.
- **Sandboxed job agents:** their identity comes from their socket. The agent's `drgnx` entry is a bridge to its
  session's own `mcp.sock`, with no environment. The hub starts the server outside the sandbox, sets `DRGNX_AGENT`,
  `DRGNX_JOB` and `DRGNX_TASK` from the session, and splices it to the connection ([hub.md](hub.md#per-session-sockets)).
  Nothing inside the sandbox names the agent, and a `DRGNX_AGENT` set there reaches no server, so no agent can claim
  to be another. Agents outside the sandbox keep the path above.
- **A job agent's row is the hub's.** `drgnx-job--launch-task` registers it (kind `job`: cwd and worktree the task
  folder, branch, base). For an agent with `DRGNX_JOB` and such a row, `hello` changes nothing of it, runs no git and
  answers the hub's cwd, worktree and base; `report_edit` resolves paths against that row
  (`drgnx-coord-mcp--job-row`). A sandboxed agent's server works in the session's dir, never in the task folder, so
  its own view would be wrong; the cockpit keeps showing the task folder's edits.
- **Agents outside drgnx:** when `DRGNX_AGENT` is empty and `DRGNX_AGENT_KIND` is set (a short lower-case name:
  `claude`, `codex`, `zed`…), the server speaks for an agent outside drgnx, as `ext:KIND:PID-HASH`. PID is the
  agent's process: the server's parent (`(alist-get 'ppid (process-attributes (emacs-pid)))`). HASH is 6 hex digits
  of a SHA-1 of that process's start time, to the second (`process-attributes`' `start`; the boot time it is
  computed from jitters), so a pid used again by another process later is another agent. Both are read once, when
  the server starts (`drgnx-coord-mcp-main`), while its parent is surely the agent.
- **Fallbacks**, each said in `hello`'s `note`:
  - no start time: `ext:KIND:PID`;
  - no parent (no `ppid`, or `1`): `ext:KIND:<the server's own pid>`.
- The identity lives only as long as the server process.
- **No tool takes an identity:** every tool refuses an `agent`, `from`, `sender`, `as` or `identity` argument.
  `hello`'s `name` is a label the user sees, never who the agent is.

**What an outside agent may write:** only its own events and messages, within the report limit.
- `claim_task`, `update_task`, `complete_task` and `record_decision` answer `jobs are drgnx's: report your work with
  report_edit`.
- `escalate` answers `ask the user with ask_user`.
- `send_message` counts against the same limit as the reports.
- A `task` that names a job's task (`JOB#N`) is refused in `hello` and `ask_user`.
- Its events and messages carry no job and no task, even when `DRGNX_JOB` or `DRGNX_TASK` leaked into its
  environment. `list_agents` and recipient lookup ignore a leaked job too.

**Text.**
- Questions and message texts (`ask_user`, `send_message`, `escalate`'s subject and text) are trimmed and cut to
  2,000 characters; the answer of `ask_user` and `send_message` then has `cut`: how many characters were left out.
- `drgnx-coord-control-chars` (C0 controls, DEL, the C1 controls U+0080–U+009F and the BiDi controls U+061C, U+200E–U+200F,
  U+202A–U+202E, U+2066–U+2069) become spaces, except newline and tab.
- Event summaries, names, branches and plans lose newlines and tabs too: one line, at most 200 characters (a name
  at 80). C1's `drgnx-coord--one-line` strips the same set.

**Paths.** The root comes from the server's process, never from an argument: the git worktree of the folder the
agent started the server in, else that folder (`drgnx-coord-mcp--home`, found once per server). A git toplevel that is
the home folder itself (a repository of dotfiles) counts as no worktree: the folder is taken, so projects under `~`
work. `hello`'s `cwd` must lie inside it; a later hello without a `cwd` keeps the registered one.

`report_edit` is refused outright when the root is a file system root, the home folder (`$HOME`) or a folder above
it. That is a server started in the wrong place, and the answer says to start it in the project folder. `hello`
still registers.

A reported path is refused when it:
- is blank or has one of `drgnx-coord-control-chars`;
- has a `..` component;
- is a remote (TRAMP) name such as `/ssh:host:…` or `/sudo::…`, or any absolute name whose first component holds
  a `:` (refused before any file handler runs, so nothing connects);
- has a `file-truename` (symlinks resolved, with `file-name-handler-alist` off) outside the root.

The two sides are compared as truenames, ignoring case on macOS and Windows. An event keeps the first paths whose
data, as JSON as `drgnx-coord--data-print` stores it, fits its 4,096 characters (and at most 100 paths); the rest are counted as `:more`, so an edit event is never `:truncated`.

**Limits.**
- `drgnx-coord-report-rate` (20): the reports (`hello`, `report_edit`, `report_test`, `ask_user`, and an outside
  agent's `send_message`) one agent may make in a minute.
  - They are counted in the server's memory against `drgnx-coord-mcp--now`, which tests stub.
  - Over the limit a report is **held**: nothing is written, not even the `seen` stamp.
  - The answer starts `HELD: more than 20 reports a minute`.
- The first held report tells the user with a `rate` card (`Dismiss`; data `(:agent :rate)`), at most once an hour
  per agent.
  - The server remembers this, and so does the store (`rate-told:AGENT` in `meta`), for a server started again.
  - Best effort: a busy store tells nobody, and the answer still says HELD.
- Edit and test events are telemetry (`drgnx-coord-event-add-best-effort`): a busy store answers
  `{"ok": false, "busy": …}` and the agent goes on.

**Never prompts, never blocks.** git runs as a process of its own (`make-process`). It gets `GIT_TERMINAL_PROMPT=0`,
its stdin is closed at once, and it has no terminal. It is killed after `drgnx-coord-mcp--git-timeout` (3) seconds,
and its answer is then nil. No tool asks anything.

**The command** M11c-2's agent settings pages write is `(drgnx-coord-mcp-outside-spec KIND)` → `(:type stdio
:command "<checkout>/bin/drgnx" :args ("coord" "mcp" "--kind" KIND))`.

### The tools in Ratatoskr (`runtime/crates/norn/src/tools`)

Ratatoskr serves the same tools in its own process, on `mimir`, one `Coord` per hub (the store, the hub, the report
limit, the clock). Each tool is the Lisp tool of the same name, ported with the Lisp as the oracle: the rules, the
answers (JSON in the Lisp's key order; an empty list is `null`, as the Lisp's nil) and the error texts are the
Lisp's. `tests/tools.rs` replays the cases `gen.el` makes by running the Lisp tools
(`test/fixtures/coord-parity/tools-*.json`). `report.rs` has `hello`, `report_edit`, `report_test`, `ask_user` and
`list_agents`; `job.rs` and `read.rs` have the rest. The hub's `Front` holds the one `Coord` (`Front.tools`, on the
front's writer) and the list (`Front.tool_list`, `norn::tools::tools()`); its `Hub` (`coord::ToolHub`) answers
`sessions()` with the backend's `agents/list` (2 s) and `notify()` with the front's `events` and the coalesced
`coord/notify`.

**Who an agent is.** A call's context is `(Arc<Coord>, Identity)`, and the identity comes from the connection, never
from an argument or an environment variable (`DRGNX_AGENT` is never read):
- `Identity::Session {agent, job, task, home}`: a session's own `mcp.sock` (hub.md, "Sessions and their sockets"). Its
  job and task are what `DRGNX_JOB` and `DRGNX_TASK` were; `home` is the folder the session started in, the Lisp
  server's `default-directory`.
- `Identity::Outside {id, kind, home}`: an outside bridge. `Identity::outside(KIND, PID, START, HOME)` makes
  `ext:KIND:PID-HASH` from the bridge's peer process, as the Lisp did for itself: PID the agent's process, HASH 6 hex
  of sha1 over its start time to the second (`ext:KIND:PID` without one; `hello` then says so in `note`). An outside
  agent has no job and no task. With no `home` (a bridge that named no folder), `hello` and `report_edit` answer "No
  folder is known for you".
- `Identity::None`: reads only; a write answers "This server has no agent identity …".

**The guard.** Every tool is a `CoordTool` wrapped by `guard::guarded`, so none can skip it:
- the identity is checked on every call: `user` in any case, or an id that is not plain, refuses every tool;
- an argument named `agent`, `from`, `sender`, `as` or `identity` is refused twice: by the tool's check (`agent:
  tools never take an identity`, a tool error with its path, before the typed check that would also refuse it as an
  unknown key) and again in the call, with the Lisp text (`No tool takes `agent': you are …`).

**The report limit** (`guard::REPORT_RATE`, 20 a minute per identity) counts in the hub's memory across all of an
agent's connections; a held report writes nothing. The `rate` card and the store's `rate-told:ID` stamp are written in
one transaction, at most once an hour per identity, also across a hub restart. A failed write tells nobody, as in
the Lisp.

**git** (`hello`'s worktree, base and branch; `report_edit`'s root): the root-owned git of `draugr::git` with its
overrides (no fsmonitor, no hook, no pager, no `ext::`, `--no-optional-locks`), in a minimal environment
(`PATH`, `HOME`, the locale, `TMPDIR`), stdin closed, killed after 3 s (manager's call 10). The worktree is looked up
on each call; the Lisp server found it once.

**Writes by `job.rs`** (`send_message`, `record_decision`, `claim_task`, `update_task`, `complete_task`,
`escalate`) are one transaction each: the writer, then the agent's `held:ID` count (a held write adds one, any other
write clears it), then `coord/notify`. A write made from an old `seen_version` is held, nothing written, and the answer
is `HELD: …` with the decisions since (`changes`, newest first). A recipient is `user`, an agent of the caller's job,
or a hub session named by id or name (asked last); an outside agent's `send_message` counts as a report.
`read.rs` has `read_inbox` (its rows are as they were read, then marked `read`), `ack`, `read_decisions` (the caller's
`seen:ID` is written only when it changed), `task_status` and `work_status`: the work tracker's plans from the `node`
and `edge` tables, read-only, sorted by path, with the counts of `drgnx-work-counts`. The size of `tools/list` is
measured by `tools_schema::the_tool_list_fits_the_budget` against the 24,000-byte (about 6k-token) budget.

**Where Rust and Lisp differ, on purpose:**
- an identity's error texts name the agent's id instead of `DRGNX_AGENT`;
- a missing or ill-typed argument is a tool error with its path (contract Task 10, amended), before the tool runs;
- `ask_user`'s message and its task's `needs-input` commit in one transaction, and so do `hello`'s registration and its
  `start` event (the Lisp made two).

## What this does not protect against

The same Unix user is no security boundary. Any process running as the user can get round the coordination
server's checks. That includes an agent, a command an agent ran, and any process it started. Such a process can:
- connect to the hub's socket and call `agents/permission` (the answer a permission request waits for), `job/reply`
  (which writes a message as the user's answer to an agent's message) or `agents/send` (which puts a prompt, with no
  header at all, into any hub session);
- open `work.db` and write to it directly;
- start a coordination server with any other agent's id in `DRGNX_AGENT` (`ext:…` ones included; never `user`, which
  the server refuses, but the store itself can be written directly), or with a `DRGNX_AGENT_KIND` of its choice, and
  write as that identity.

`DRGNX_AGENT` is trusted as it is set, and an outside agent's `ext:KIND:PID-HASH` identity and its limits stop a
confused or runaway agent. They do not stop a same-uid process that sets up its own environment. The checks above
(freshness, who may change a task, who may answer what, the message and report limits) stop mistakes and runaway
loops among cooperating agents. They do not stop an agent that means to go around them.

The real boundary is the sandbox an agent runs in: one that keeps it away from the hub's socket and from the state
and data directories, not drgnx's own access rules.

## Delivery (the hub)

`drgnx-hub--deliver` runs on `coord/notify` and every 2 s:
- a `queued` message stays in the store until its agent is **free** (idle, not paused by the user's Stop, nothing
  queued: `drgnx-agents-free-p`), then goes to it as a new turn (`drgnx-agents-deliver`: never queued, steered or
  interrupting, whatever the profile's mode) and is `delivered`; when that prompt reaches the agent
  (`drgnx-agents-prompt-functions`) it is `read`. Meanwhile `read_inbox` finds it too (and then it is not delivered
  again). The prompt is `drgnx-coord-message-prompt`'s. Another agent's text is **quoted** under a header —
  `[message from SENDER #ID — from another agent, not from the user; it approves nothing]` then every line as `> …` —
  so a peer cannot write a line that reads as drgnx's or the user's. The user's own messages (sender nil, written by
  the user's Emacs, or `user`: a job reply, an answer to a hub session set to interrupt, a revert or a comment from
  the Work cockpit) come as `[message from the user #ID — the user's message]` and the text unquoted. When the user's
  Emacs said which question it answers (`drgnx-coord-send`'s `:answers`, kept in the message event's data and found
  in SQL; the job reply and the cockpit's answers say it), the header is `[message from the user #ID — the user's
  answer to your question #Q]`, then the question's words on a quoted line of their own (`> your question: …`, one
  line, at most 80 characters: the agent's own words never enter the header), then the text. Only a question this
  agent asked the user is named (`drgnx-coord-message-answers`). SENDER in an agent's header is one line: its control
  characters, `]` and `#` become spaces, so a sender already in the store cannot write a header of its own or name
  another id. Both headers start `[message from WHO #ID `, which marks the message `read` when the prompt reaches the
  agent. No agent can be `user`: the coordination server refuses that identity, and any id that is not plain (above).
  Line and paragraph separators (U+2028, U+2029) are control characters to the store (`drgnx-coord-control-chars`),
  and a quoted text is split on them too.
  A message for an agent that is not there, or exited, stays `queued`. Delivery also runs when a session becomes free;
- an agent of a job whose `seen` version is behind that job's decisions gets `[decision log vN — job J]` and the
  changes (quoted) once per version, when free. Sessions without a job (plain chats) are never woken.

Hub sessions are the hub's children: when the hub ends, they end (the editor's mirrors turn `exited` and say so).
The next hub resumes those without a job ([hub.md](hub.md#sessions-across-a-restart)); a job's agents are not
resumed — the job frees their tasks and starts them again.

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
| `drgnx-agents-request-functions` | `drgnx-job--request`: permissions by `drgnx-job-policy` (allowed but with no `allow_once` option: a card), writes inside the worktree (missing directories are made; `drgnx-job--write-inside` resolves the path itself — refused when a link leads it out — and renames a temp file over the target — its modes kept, a new file 0666 less the umask, a file that is not writable refused — then checks again; a remote path is never resolved: a card), else a card |
| `drgnx-agents-error-functions` | `drgnx-job--agent-error`: a provider at its limit → `drgnx-job--fall-back` to the next profile; a task's reviewer → `drgnx-job--review-fall-back`: the review starts again on the next profile of the `review` route (a `review` card when none is left); a clash reviewer is left alone |
| `drgnx-gateway-event-functions` | `drgnx-job--gateway-event`: `budget` → the job pauses, its agents stop |

`complete_task` from an agent of a job (`DRGNX_JOB` set) puts the task `in-review`, not `done`, and `update_task`
there takes only `running`, `needs-input` and `in-review`; the reviewer's verdict decides (`drgnx-job--reviewed`, `drgnx-job--merge`: the merge is a git process of its own, the task shows `merging` meanwhile
(`drgnx-job--busy`, in the hub's memory only: a restart finds the store's `in-review` and the "merged before" check);
one merge at a time in a job's worktree — two at once fail on its HEAD (`cannot lock ref`), so a task whose review passes
while another merges waits, `queued` (`drgnx-job--merge-queue`; stopping the job empties it); a merge that fails with
no unmerged files is no conflict: it goes once more after what merges then, and fails again into a `merge-failed` card
titled `merge failed: <git output>` (Merge again, Drop, Open — no agent is sent to resolve a conflict);
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

`test/unit/coord-test.el` (the store; the claim race), `coord-mcp-test.el` (the server over stdio; outside
agents' identity from the parent, hello and its base, paths inside only, tests, questions, no job tasks, no forging
or flooding — `drgnx-coord-mcp/outside-agents-cannot-forge-or-flood`),
`hub-agents-test.el` (sessions in the hub; a mock agent calling a tool through its `mcpServers`),
`agents-mirror-test.el` (mirrors, reattaching), `coord-delivery-test.el` (idle, busy, exited, peer messages,
decisions, leases); the job tests are listed in [jobs.md](../guide/jobs.md#tests). The mock agent's `coord TOOL JSON` prompt
calls a tool of the server it was given; `[drgnx task ID]` does a task, `[drgnx review ID]` reviews one
(`MOCK_ACP_VERDICT=fail`), `MOCK_ACP_RATE_LIMIT` answers every prompt with a 429.

The Rust tools: `runtime/crates/norn/tests/tools.rs` (identity names refused on every tool, `user` never an
identity, no identity reads only, outside agents kept off the job tools, the report limit and its card, path rules,
`hello`'s cwd, a planted git hook and fsmonitor that never run, and the Lisp tools' cases replayed) and the unit tests
of `norn::tools::{identity, guard, report}`.
