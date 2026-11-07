# The Work space: how the map is built

The Work space's map shows every live piece of a workspace's agent work in six fixed layers: you asked, specs, plans,
agents, branches, files and machines. This page is for contributors. It describes the parts behind the map, from the
hub's facts to the drawing.

## The map core: `vegvisir`

`runtime/crates/vegvisir` is a pure crate: no I/O, no clock, no threads, and no dependency beyond `serde`. The hub
turns each of its sources into a typed `vegvisir::Event` and steps a `vegvisir::Core` with it. The core keeps the
map's model and each view's state, and returns effects for the hub to send.

```rust
let mut core = vegvisir::Core::new();
let effects = core.step(vegvisir::Event::Session(fact));   // Vec<Effect>
let chain = core.model().chain(&vegvisir::ItemId("agent:S1".into()));
```

### Events

| Event | Source | Meaning |
|---|---|---|
| `Graph(GraphFact)` | Urdr | an ask, spec, plan or task record, or an `asked` or `derives` link; idempotent, so an import that runs again changes nothing |
| `Session(SessionFact)` | hub sessions | a session's (or a Claude Code subagent's, `SID/TOOLID`) snapshot: state, task, branch, worktree, recorded base, machine, spend; it replaces the last one |
| `Step(StepFact)` | timeline steps | a closed step: its class and a conclusion recorded there; the latest by step number wins |
| `Changed { worktree, base, files }` | the edit history | a worktree's changed files (`REPO/PATH` → `(plus, minus)`), measured against `base`, untracked files included |
| `Presence(PresenceFact)` | the presence model | one file's entries now: who reads or edits it |
| `Machines(Vec<MachineFact>)` | the machine registry | every machine, whole |
| `Card(CardFact)` | part 1's cards | a needs-you card opened, changed or settled; a clash card names two agents |
| `Refs(Vec<RefFact>)` | git | every branch's base branch and merge state, whole |
| `Tick { minute }` | the hub clock | time fields are minutes, so one delta a minute |
| `View(ViewOp)` | the editor | a view opened, changed (filters, width, collapsed layers), shown, hidden or closed |

Each source sends the latest value per key (a session, a worktree, a file, a card), and the model keeps only that.
So the model is the same whatever order the sources' events interleave in.

### The model

Everything the map shows is **derived** from the facts after each event:

- **Items and their ids.** `ask:KEY`, `spec:ID`, `plan:ID`, `agent:SID` (a subagent is `agent:SID/TOOLID`),
  `branch:REPO/NAME`, `file:REPO/PATH`, `machine:NAME`. The prefix fixes the kind, and the kind fixes the layer.
- **Edges exist only while both ends do.** A link that arrives before its items waits in the facts. No edge ever
  dangles.
- **What is live.** An agent is live unless it finished and either its branch merged or its task is done. A branch is
  live while a live agent is on it, or a live branch was cut from it. A file is live while a live branch changes it or
  a live agent reads or edits it. Plans, specs and asks are live while a live agent is under them, and plans and
  specs also while a live ask links them. A view with "show finished" also shows the items that are not live.
- **Blocks.** An agent's block is its task's plan; a subagent sits in its parent's block. A branch takes its first
  agent's block (by start order). A branch that is only a base takes the block of the first branch cut from it.
- **The chain** of an item is everything reachable from it along "came from" edges up and "touches" edges down
  (came from, edits, reads, runs on). `Chain.gaps` names the layers above it with nothing on the chain, so the side
  panel can say "no spec recorded".
- **Overlaps.** Two live agents on different branches whose changes touch the same file. Each branch's changed set
  is its worktree's `Changed`, used only when its `base` is the base recorded for that worktree, plus the edits in
  flight from the presence model. Untracked new files count, even at `+0 −0`. A subagent and its parent, or two
  siblings, editing the same file overlap within their one branch. An open clash card is an overlap with `clash`
  set. Both sides of every overlap carry the ⚠ flag, and every shared file is marked `shared`.
- **Needs-you** is the open cards, and each item a card is about is flagged.

Inside the model, ids are interned to numbers, and the derivation runs once per event over them. The public reads
(`items`, `item`, `edges`, `overlaps`, `needs_you`, `chain`) are keyed by `ItemId` and sorted, so two runs that
reach the same facts compare equal.

### Effects

| Effect | When |
|---|---|
| `Delta { view, delta }` | a fact changed what a **shown** view shows: the ids changed and removed (removed: gone, or finished without "show finished"), and whether the edges, the structure (an item came, went, or changed block or parent) or the needs-you strip changed |
| `Stale { view }` | the same for a **hidden** view, once, until it is shown again |
| `Relayout { view }` | the user opened, changed or showed the view: lay it out and send a full frame |

Live events never return `Relayout`: the hub's coalescing decides when accumulated structural changes reflow
(design §11.3). Deltas carry ids only; the hub reads the items from `Core::model()`.

### Tests

- `tests/orders.rs` runs the core in every order of a scenario's sources with `skuld::every_order` (graph records
  and an import again, three sessions with steps, an end, a subagent, a late changed set, presence, a ref move that
  merges a branch, machines, the clock, a card opened and settled, a shown and a hidden view). After every event it
  checks: no dangling edge, overlaps symmetric, chains equal to a breadth-first search over the edge list, a hidden
  view gets no delta, an item's layer never changes, and live events never relayout. Every order must reach the same
  final model.
- The same file holds the rules on single scenarios: the chain's gaps, an untracked file counting, overlaps measured
  against each base and not `main`, siblings in one worktree, a finished agent leaving when its branch merges.
- `tests/timing.rs` holds the budget, `core_step_within_50_us` (p95 over the 30-agent fixture's live traffic), run
  by the timing lane on the optimized build.

## The layout

`vegvisir::layout::layout(model, view_state, prev) -> Layout` lays one view out. It runs in the hub when the
structure changes (the user's filters, a collapse, a resize, a reflow), never per frame. It works in **units of
4 px** (the look's grid) and never in font metrics: every card and chip has a fixed width per kind and form, and the
editor truncates labels to it by pixel width. `ViewState.width_units` is the drawing width, without the 84 px layer
labels' margin; a 1000 px tile is 226 units (1000 − 84 − 12 px of padding).

### Sizes (comfortable density)

| Thing | Units | px |
|---|---|---|
| rich agent card | 58 × 25 (5 lines) | 232 × 100 |
| compact agent card | 42 × 10 (2 lines) | 168 × 40 |
| chip row (asks, specs, plans, branches, files, machines) | 7 high | 28 |
| chip widths: ask, spec, plan, branch, file, machine | 48, 44, 44, 40, 36, 32 | 192 … 128 |
| gap between cards | 3 | 12 |
| band between rows | 8 | 32 |
| band between an agent sub-row and its branches' sub-row | 3 | 12 |
| gap between blocks | 6 | 24 |
| a collapsed layer's row | 5 | 20 |

The look's 19 px card lines round to 20 px on the grid. Compact and roomy densities scale these (`Metrics::of`).

### The steps

1. **The layer is the kind's.** Rows go: you asked, specs, plans, then the agents and branches by block line, then
   files and machines.
2. **Blocks by plan.** Agents and branches sit in one block per plan, in plan order, with "No plan" last. Inside a
   block, agents wrap into sub-rows, and each agent sub-row is followed by its branches' sub-row, each branch under
   its agent. So plan → agent → branch edges stay short. Whole blocks wrap into block lines. A block's agents go
   compact rather than take a second sub-row, except agents that need you or are on the focused chain. Subagents are
   compact and follow their parent. A branch that is only a base sits after its block's branches.
3. **Order.** Inside a block, agents keep the previous layout's order (a new one goes at the end), else their start
   order. Plans keep plan order. Specs, asks, files and machines are ordered by their targets, then adjacent swaps
   that cut crossings by more than the stability penalty (1).
4. **x.** A plan's target is its block's centre; a spec's, an ask's, a file's or a machine's is the mean centre of
   what it links to. An item keeps its previous target while the new one stays within 32 units of it (hysteresis),
   so a new card does not shift the others. The target kept is the one before it is pulled inside the width, so a
   card held against the right edge returns to its old place when what moved it goes. Overlaps resolve left to right
   with the gaps, then back from the right edge.
5. **Lanes.** An edge longer than one row takes a lane in each row it crosses, a 2 px segment at a free slot of the
   nearest gap. A gap of `g` units holds `g − 1` lanes (`floor((gap − 4 px) / 4 px)`: 2 in a 12 px gap). Edges from
   one source (a plan to its agents, an ask to what it led to) or to one target (agents to a machine, branches to a
   file or to the branch they were cut from) share one lane, a trunk. The row's right end is a gap like the others,
   so a full row's lanes spread into its slack; cards never move for a lane. A row with no free slot left bundles the edge into a **port** on its target
   ("↑ N"; the side panel names the parents).
6. **Bands.** The band above each row holds its curves (12 px under an agent sub-row, where only its branches'
   short edges run; 32 px elsewhere): from a card's bottom centre to a lane, lane to lane, a lane
   to a card's top centre. Same-row arcs (overlaps, "based on", a manager) go in the band above their row.
   `crossings` counts crossing curve pairs per band. "Runs on" and "based on" edges are drawn on the focused chain
   only: a machine's chip shows its load and a branch's caption its base, and the side panel names both.
7. **Fits.** The map fits at 120 units (480 px) or wider, with no lane overflow (no port) and every card inside the
   width. Otherwise `fits` is false and the editor shows the outline form. **The height is not part of the rule:**
   the map scrolls vertically (the 30-agent fixture is about 1750 px tall at 1000 px wide), the needs-you strip
   stays pinned as the header line, and navigation scrolls the selection into view. The view wave builds the
   scrolling.

Filters: `focus` keeps the item's chain, with the bases its branches were cut from, and draws its reads, slots and
bases; `overlaps` keeps the flagged agents and branches, what
they came from, every file they edit and the machines they run on, and draws read-versus-edit lines; `finished`
brings back what is not live. Otherwise a file is a node only while it is shared (an overlap). A collapsed layer is
one thin row; edges through it join the items on either side.

### Layout tests

`tests/layout.rs` checks properties over generated workspaces (`proptest`, 128 cases each): no two cards overlap,
layers never move, blocks and siblings are contiguous, the same input gives the same output, adding an agent leaves
the blocks before it in place and moves the blocks after it only as a whole, removing it again restores the
previous layout, the width is respected, every long edge has a lane in every row it crosses or a port, and no lane
leaves its gap or shares a slot with another bundle. Single cases pin the rules: runs-on and based-on edges only on
the focused chain, a block compacting before its second sub-row, and the fit rule (width and lanes, never the
height). Three goldens (`tests/golden/`) hold the prototype's data at
226 units and the 30-agent fixture at 226 and 576 units (2400 px); `UPDATE_VEGVISIR_GOLDEN=1` rewrites them, and
refuses one whose crossings are above the golden it replaces. `tests/timing.rs` holds `layout_200_items_within_2_ms`.

### The 30-agent fixture

`test/fixtures/work-space/thirty.json` is one description of a busy workspace: 6 asks, 3 specs, 4 plans with their
tasks, 26 sessions and 4 subagents, 30 branches over three repositories (26 agents' branches and 4 bases), 120 edited
files with three shared ones, an untracked empty file, two subagents editing one file, three machines (one reported
by `machines/report`), four cards (one a clash). `test/fixtures/work-space/prototype.json` is the brainstorm
prototype's own data. `vegvisir::fixture::thirty()` and `prototype()` (feature `fixture`, tests only) turn a
description into the events a hub would feed.

Into a real hub: `test/fixtures/work-space-thirty-fixture.el` builds the description into three git repositories and 30
mock agents, all sessions (the four subagent entries are sessions of their own, each with its parent's repository),
every one streaming; `drgnx-work-thirty-premise` signals when that does not hold. The perf workloads
(`docs/develop/perf.md`, "The Work space's workloads") and the GUI scenes (`drgnx-work-gui/thirty-agent-scenes`: dark,
light and high contrast, one shot each at the session's scale) both use it. What the hub derives from the mock agents'
files, edits and prompts (plans, specs, shared files, machines) is what the map shows; the description's cards and
machines are not injected.

## The hub's facts

The hub's code for the Work space lives in `runtime/crates/drgnx-ratatoskr/src/work/`. The pure parts take no clock and
no I/O, so tests run them in every order or directly.

### Worktree bases

`work::bases` records, in `worktree_base` (written by the hub as `("hub", System)`, never by an agent), where each
worktree the hub makes branched from: its repository, the branch, the commit, and a tree of the new worktree.

- `HubGit` (`runner/git.rs`) tells a sink after it makes a tree (`with_bases`); the server's sink writes the row.
  `bases::row_for` finds the branch by git in the trusted repository: the branch the base names, or the one local
  branch that points at the commit, or, among several, the run's own `job/<run>` for a tree `job/<run>-<task>`. It never
  defaults to `main`, and when it cannot tell the branch is empty.
- The tree is `timeline::snapshot::take_base`: the worktree as it is when made, kept as `refs/drgnx/base/<hash>` in its
  shadow repository (a prune leaves it). `snapshot::numstat(root, worktree, from_tree, to_tree)` counts the lines
  between two trees there, and marks a file not in the first as new (`untracked`); it runs git in the shadow
  repository only, so it works with the worktree gone and never runs git in an agent's tree.
- A session in a folder the hub made no tree for (a docs agent in the org folder) gets a row at its start, from the
  folder's head (`bases::session_started`); folders under `<state>/hub/runs` record their own.
- `bases::ancestry_of(rows, roots)` and `bases::ancestry(front, workspace)` answer "based on" pairs of
  `BranchRef {repo, branch}` for the workspace's roots, computed from the rows when asked.

### Edited files, counts and hunks (interim)

`work::edits` answers three user methods from snapshots alone, until the edit history serves them (their shapes stay):

- `work/files {session} -> {files: [{path, plus, minus, untracked, read_at?}]}`: the session's newest step snapshot
  tree against the worktree's `base_tree`, through `snapshot::numstat`. Step snapshots are written with `add -A`, so a
  file the agent created is in the tree and comes back `untracked: true`. No snapshot yet: an empty list. `read_at` is
  not filled yet.
- `work/hunks {session, path} -> {diff}`: the unified diff of one path between the same two trees
  (`snapshot::patch`), empty before the first snapshot.
- `work/file-at {session, path, seq} -> {bytes, seq}`: the file's bytes (base64) in the newest snapshot at or before
  step `seq`; `seq` is the step that snapshot belongs to. A missing path or a path leaving the worktree is
  `invalid-params`.

Only sessions the hub holds are served. `edits::changed(front, session)` gives the same counts to the map's `Changed`
fact, after every step that took a snapshot (`Map::edited`, from the step-close path). Git runs in the shadow repository only, never in an agent's tree.

### Live specs

`work::specs` stores a spec an agent's edit step wrote: a Markdown file under `docs/specs/` (a path tail from
`DEFAULT_DIRS`) is read after the step is written, its title is the first `# ` heading (the file's name if none), and
it goes in through `graph/put-parsed` as `spec:<path>`, as a scanned spec does, and links `asked` to the writer's
current ask (below). A spec written by a shell command is not seen here (the scan finds it).

### Asks

`work::asks` links the work a session does to the user's words behind it: an `ask` entity (`{text, at, by: user,
channel, session, message_id?}`) and `asked` links from it to specs, plans, tasks and sessions, written by the hub as
`("hub", System)` (`norn::write::work::{new_ask, link_asked}`).

- **The current ask** of a session is its latest user message, from the moment its turn's prompt goes to the agent,
  until the next one. A steer is current from its delivery. Every spec, plan or task the session writes, in that turn
  or any later one (a turn the hub woke on a job, a batched wake), and every agent it starts, links to it. A worker
  inherits its starter's current ask at its start: the manager that started it (`parent`), or the session whose
  transaction made its plan run (`job.tx`). The channel is `manager` for a manager, `brainstorm` for a session with a
  design document, else `chat`.
- **Lazily made:** the ask entity is made at its first link, so a message that leads to no work leaves nothing. Writes
  the hub did not see a session make (an import, the scan, the user's own) get no ask.
- `AskCore` is pure (`step(AskEv) -> Vec<AskOut>`, events `UserMessage`, `SteerDelivered`, `GraphWrite`, `AgentStart`,
  `SessionGone`). The shell, `work::asks::run` (task `asks:run`), takes its inputs in order on one channel: a session's
  turn sends the user message just before its prompt, `agents/start` the start, `agents/stop` and `agents/kill` the end.
  Before each input it reads the spec, plan and task versions written since the last look from the store's `tx` log
  (the entity scan runs only when a session wrote), so a write is always seen before the message after it.
- A session's tool call answers only after its writes are linked: every tool on a session's socket is wrapped
  (`sessions::AfterTool`) to call `norn::tools::Hub::after_tool`, which waits for the shell to read the log. A live
  spec (`work::specs`) goes in as the scan, so its write is sent to the shell directly.
- Current asks are kept in memory: after a hub restart a session has none until its next user message.
- Tests: `work::asks::tests` (`every_order_links_every_write`, pattern A over a manager, its worker, a chat and the
  ends; the rest pattern D) and conformance `work/a-managers-later-turns-link-to-the-ask` (pattern B).

### Conclusions

`work::conclusions` stamps each conclusion (a `record_decision` decision, a `note_add` finding) with the timeline step
it was recorded in, and computes the steps it rests on. `work/conclusions {session}` answers them.

- **The stamp.** The step is the session's tool step of that MCP call; the agent's own `step` argument is ignored (not
  kept). The MCP call and the ACP `tool_call` arrive in either order, so `StampCore` (pure; events `McpCall`,
  `ToolStep`, `StepClosed`, `TurnEnd`) pairs them per session and tool, first with first, and stamps once the step is
  written. A call with no tool step by its turn's end is "step unknown" (`step` absent): an adapter that reports no
  MCP calls, or the fenced `drgnx-conclusion` block (origin `from-text`), which has no call at all.
- **Where the events come from.** A session's reader sends `ToolStep` when a tool step of `record_decision` or
  `note_add` begins (Claude `mcp__drgnx__…`, Codex `drgnx.…`, Gemini `… (drgnx MCP Server)`, by tool name, else title);
  its step writer sends `StepClosed` with the step's id once the row is written, and `TurnEnd` after the turn's last
  step. The asks shell (above) reads the decisions and findings a session's transaction made from the log at the end
  of every tool call and sends `McpCall`: before the call answers, so before the agent can report the step complete.
  The hub writes the stamp as `("hub", System)` (`norn::write::work::stamp_step`, `data.step`).
- **The links** (`links(c, prev, steps)`, computed, never inferred): each `{path, lines}` source matches the
  session's latest read step of that path, up to the conclusion, whose lines overlap (a read with no end covers the
  rest of the file; paths match when one is the other's tail at a `/`); each `{url}` its latest fetch (`named`). The
  reads, searches, pages and thoughts after the previous conclusion are `since_last`. A source no step matches is
  kept in `unmatched` ("named, not read in this session"). A conclusion whose step is unknown is placed by its time.
- `work/conclusions {session} -> {conclusions: [{n, id, kind, text, sources, step?, at, origin, links: {named,
  since_last, unmatched}}]}` (user connections), in the order they were recorded, numbered from 1.
- Tests: `work::conclusions::tests` (`both_arrival_orders_stamp_the_same_step`, pattern A over two sessions; the
  rest pattern D) and norn's `the_agents_step_argument_is_ignored` (D).

### Subagents

`work::subagents` groups a Claude Code session's subagents under it. Each nested update of a subagent carries
`_meta.claudeCode.parentToolUseId`, the id of the parent's `Task` tool call; the hub keeps it beside the entries
(`tool_meta`) and on each of the subagent's steps (`step_detail.parent_tool`, `detail.parent_tool` on `agent-step` and
`timeline/get`).

- `group(session, calls) -> Vec<Child {parent_session, parent_tool, name, description, steps}>` (pure): one child per
  `Task` call that has nested calls, named by the call's `rawInput.subagent_type` (else `subagent`) and described by
  its `description`, its steps the nested calls in order. `Child::item_id()` is `agent:SID/TOOLID`, the map's
  `Kind::Subagent` item; it shares the parent's worktree and its spend is the parent's. `Session::subagents()` groups a
  live session's tool calls.
- Without a parent id (another adapter, or none sent) there is no child: the steps stay the parent's, and the trail
  says "subagent steps not separated". The hub does not advertise `capabilities.subagents` (that form makes child
  sessions the hub did not start).
- Tests: `work::subagents::tests` (pattern D) and conformance `work/claude-subagent-is-a-child` (pattern B; the mock's
  `provider:task`).

### Presence

`work::presence` is the hub's presence model; its contract is in `docs/develop/hub.md`, "The presence model".

- `Presence` is pure: `apply(PresenceEv) -> Vec<PresenceOut>` (events `Step {session, step, at, files}` and
  `SessionEnd`; outs `Changed {file}`, every file whose "now" may read differently, including the file a session's
  latest entry left), `now(file, at)`, `files_under(root, at)`, `rebuild(steps, details)`.
- The session's step writer feeds it after each step is written, before `agent-step` goes out: the files of the step's
  detail (`touches_of_detail`) and, for a shell step (ACP kind `execute` or Claude's `Bash`), of its command
  (`touches_of_step`: `shell_read::parse` and `resolve` with the session's folder as the only root, off the async
  threads). `Live` holds the model, the subscriptions by connection and the files waiting for the next flush.
- Tests: `work::presence::tests` (`every_order_same_now_set`, pattern A over two sessions, a third that only listed a
  file long ago and an end, checking after every event that each file whose "now" changed was named; the rest
  pattern D) and conformance `work/presence-goes-only-to-subscribers`, `work/presence-coalesces-per-file` (pattern B,
  virtual clock).

### Machines

`work::machines` keeps the list `machines/list` and the event `machines-changed` carry (types in
`runstav/src/methods/work.rs`).

- `Registry` is pure: `report(r, now)`, `expire(now) -> names`, `set_local(slots)`, `list()`; `local` is always first
  and never expires. `Machines` holds one behind a lock in `Core`.
- The map hears the list with each runner's fact (`MachineFact.runner`: trust, state, jobs, icon, cost; `slots` and
  `used` are the runner's cores and jobs), from `Registry::map_facts` (`feed_map`, on every change of the runners, every
  report and every sweep; the model drops a list that did not change). A runner's state and jobs are read from the
  queue at that moment. The machine item's fields carry `runner`, and the strip's chips carry `cost` when there is one.
- A session's running or waiting job (`SessionFact.job`: id, name, machine, state, start, time box in minutes, names of
  the keys sent, from the job tracker, the job row and the key audit) is fed by the same sweep (`Map::jobs`); the
  session's `machine` is the job's machine, so the "runs on" edge points at the runner. The agent item carries `job`;
  the Lisp card turns it into `job · MACHINE · M:SS/Nm`, and the side panel of a machine lists the jobs on it
  (`drgnx-work-detail--machine-queue`), `l` (`work-job-log`) calling `exec/log` for the row's job.
- `machines/report` takes user connections only (`classes: [User]`, in `test/conformance/class-matrix.json`); a report
  for `local`, a ttl outside 0..86400, more than 256 slots or a slot without id and kind is `invalid-params`.
- The local pool is read from the job runner (`exec::Runner::slot_counts`, the queue's `local_slots`): one `local-N`
  slot per job this machine takes at once (an admission by count: the count; live: the workstation profile's threads,
  the usable CPUs less the user's four; never fewer than the queue's jobs running here), the busy ones held by `job`
  (the pool does not say which job). The hub refreshes it, and drops expired reports, on every
  `machines/report` and `machines/list`, and every 2 s (`work::machines::run`, which waits on the clock only, a task named
  `machines:run` on the hub's clock, so `__test_advance` moves it). `machines-changed` carries the whole list, and only
  when it changed. The start seeds the local slots (`work::machines::seed`, once the job runner is open and before
  anything is served), so the slots a hub starts with are its first list, not a change: a quiet hub sends none.
- The CLI is `ratatoskr machines report --machine M --ttl S [--json FILE|-]` (`machines_cli`): exit 0, 1 on a hub
  error, 2 on bad arguments. jobq calls it; its side is jobq's plan.
- Tests: `registry::*` (pattern D), `machines_cli::parses_and_reports` (D), conformance
  `work/machines-report-from-a-user`, `work/machines-report-from-an-agent-is-refused`,
  `work/machines-expire-after-ttl` and `work/machines-changed-only-on-a-change` (virtual clock) and
  `cli/machines-report` (the CLI as a child, exit read).

### Shell reads

Layer 1 of "reads through shell commands" (the files a command names; labelled "from the command") is
`work::shell_read`.

- `parse(cmd) -> Parsed` reads the text of a shell step and sorts the words that name files into `reads`, `writes`,
  `listed` (a directory listing or a recursive search without a path: `ls`, `find`, `fd`, `tree`, `rg foo`), `scripts`
  (`./x.sh`, `python y.py`, `source z`) and `cds`. It is table-driven over the heads `cat head tail less more wc cut
  sort diff jq grep rg ag ack sed awk find fd ls tree tee` and the interpreters and shells. It understands pipes,
  `&& || ; &`, redirections (`< f` read, `> f` `>> f` `&> f` write, `2>&1` nothing), quotes, `cd X &&` prefixes,
  leading `VAR=x`, `env`, `time`, `timeout`, `nice` and a `bash -c '…'` string parsed once.
- What it cannot know is left out and named in `skipped`, never guessed: `$(…)`, backticks, variables, `xargs` and
  `find -exec` input, a `bash -c` inside a `bash -c`, a heredoc, a subshell, `for`/`case`, a `cd` to an unknown place.
- `resolve(parsed, cwd, roots, glob_cap) -> Resolved` places the words: `~`, the `cd`s in order, simple globs (`*` `?`
  `[…]`, at most `glob_cap` matches per step, 200 in the hub; a glob over the cap, with no match, or with braces or
  `**` goes to `patterns`). Paths are made canonical (symlinks followed, `..` applied, also for a file that does not
  exist yet) and **only paths under the roots are kept**: a `..`, a symlink or a `cd` that leaves the workspace is
  dropped. A read of something missing is not a read, and a read of a directory is a listing.
- Tests: `work::shell_read::tests` (class `det`, pattern D, with a property test over the corpus and random words),
  the corpus in `src/work/shell_read/corpus.txt`, and the timing row `shell_parse_within_200_us`
  (`tests/work_timing.rs`, listed in `test/timing-rust.txt`, 200 µs at p95).

Layer 2 (the files a command's processes opened; labelled "seen open") is Gleipnir's tracer
([sandbox.md](sandbox.md#seeing-the-files-a-shell-step-opens)) and the hub's supervisor, `work::trace`:

- **Who is traced** (`TraceMode::of`, at the session's start): `drgnx-agents-trace-opens` lists providers, `("claude")`
  by default. Claude Code is traced per step: its spec gets `trace: per_step` and `CLAUDE_CODE_SHELL_PREFIX` (the
  wrapper); Codex and Gemini, when listed, over their whole tree (`trace: tree`). Not listed, or on macOS, the session
  is `Off` with a label. The socket is `trace.sock` in the session dir (`runstav::paths::SESSION_TRACE_SOCKET`),
  served from before the spawn (`Traces::open`) until the session ends (`Traces::end`). A test hub's unsandboxed
  launch links the hub binary as `gleipnir-trace` in the session dir and sets the same variables.
- **Offers** (`shell.rs`, off the async threads): a per-step offer is skipped when another shell step is open (a hook
  or a status line through the prefix); when no step is open yet (the hub may not have read the tool call) it is
  traced as given. A command whose head is on the skip list (`SKIP_HEADS`: the design's list plus `emacs`, `nidhogg`,
  every `bin/drgnx` subcommand; `go` only to build or test) or on the worktree's learned list is skipped and its step
  labelled "opens not traced for this build". A whole-tree offer is traced with the CLI's own thread group ignored
  (its peer pid).
- **Opens** come from Gleipnir's channel: a system or toolchain path is dropped at once, a read of a missing file is a
  failed probe (dropped, and remembered for the step); the rest goes into the pure `Core` as `Opened`. The budget is
  checked on each: the answering thread's time plus 6 µs per notification against max(5 %, 50 ms) of the step so far,
  at most 250 ms (`over_budget`). Over it, reading stops for the rest of the step (`Listener::set_reading(false)`),
  what it saw is dropped, the step is labelled, and its heads join the worktree's learned list (in memory).
- **`Core`** (pure) ties traces to steps: a step's close takes the oldest trace whose command matches its own (as
  given, or inside what the CLI wrapped around it, `command_matches`), and the step goes out once both its close and
  its listener's end have come, in either order. In whole-tree mode an open goes to the shell step open when it
  arrives (one per session as the hub sees it), and an open while N run is labelled "one of N parallel commands".
- **What goes out** (`touches`): each path by its true name, under the session's folder (as layer 1's), never under
  the system's or the home's toolchain and cache dirs, not git-ignored (`git check-ignore`, cached per path); a write
  is looked at now, at its step's close. The files go to the presence model as `opened` on the step, and the files
  that changed there go on to the Work map as `Presence` facts, like any other read (when they land after the step's
  close, they reach the map then); a label goes to the step's detail (origin `opened`, the label as `title`) when the
  step has no detail of its own, and so does an `Off` session's label on each of its shell steps.
- **Not kept:** a step's opens are not stored (like layer 1's, they come back only with the session's next steps after
  a restart); the learned skip list is lost with the hub; whole-tree mode has no budget of its own (it is opt-in).
- Tests: `work::trace::tests` (pattern A: a step's close before or after its listener's last notifications; pattern
  D: the rules through a fake probe, the budget, the skip list, the labels), and the rows
  `trace/claude-bash-reads-are-seen-open` (the mock's `provider:bash` through the wrapper),
  `trace/a-file-seen-open-shows-on-the-map` (a read only the tracer sees, counted on the agent's card) and
  `trace/macos-says-not-traced` (`DRGNX_TEST_TRACE_PLATFORM=macos`, test hubs only), in the sandbox container. The
  first two need the tracer, which is Linux's alone (macOS has none to offer: no seccomp notification), so they
  require `linux` and a macOS run lists them as skipped; the third is what macOS shows instead.

## The editor's side

Module `tools/work-space` (`modules/tools/drgnx-work-space.el`; the buffer's mode, view type and rows are in
`drgnx-work-map.el`, a library of the module; the map client is `core/drgnx-work-client.el`).

### The map client

`core/drgnx-work-client.el` has a pure core and a shell.

- **The core.** `drgnx-work-client-init FRAME` makes a state from `work/map/subscribe`'s answer (items by id, edges,
  the layout with `:at` and `:form` as hash tables by item id, the needs-you strip, the chips).
  `drgnx-work-client-step STATE EVENT` takes one `work-map` event and returns `(NEW-STATE . MARKS)`:
  - an event whose version is not newer than the frame's is dropped, and so is every event while the state is not live
    (before a frame, after `drgnx-work-client-lost`);
  - a full event replaces the frame (every row, the layout, the edges and the strip are marked);
  - an event whose `base` is the frame's version is applied: changed items put, removed ones taken out, the places the
    arrivals took put (a place no row holds gets a row of its own, block line 1000 and up), edges, layout, strip and
    chips replaced when the event carries them; then any held event it unblocks;
  - any other event is held, and the marks say `:resync t`: the shell subscribes again, and the full frame it gets
    replaces the state and drops what was held.
  The marks are a plist: `:rows` (row keys `(:row LAYER BLOCK-LINE SUB)` to draw again, or `t`), `:items`, `:removed`,
  `:keys` (the list of rows changed), `:edges`, `:layout`, `:strip`, `:resync`; each only when it applies. The core
  calls no process, timer or clock, so its tests run it in every order its events can arrive in.
- **The shell.** One view per map buffer, keyed by the workspace id. `drgnx-work-client-open` subscribes;
  `-set` sends `work/map/set` (hidden or shown, filters, collapsed layers, width, density, the selection); `-close`
  sends `work/map/close`. Events come from `drgnx-hub-event-functions`; a view re-subscribes from
  `drgnx-hub-connected-functions` (the hub client core's own reconnection), and `drgnx-hub-disconnect-functions` makes
  every view keep its frame and say "reconnecting". Each view counts its events, deltas and frames
  (`drgnx-work-client-counter`), which the hidden-map test reads: a hidden map receives one stale mark and nothing else.
  The change and status hooks (`drgnx-work-client-change-functions`, `-status-functions`) are how the buffer hears.
- **Tests.** `test/unit/work-client-test.el` (class `det`, every order), `test/unit/work-space-test.el` (class
  `cond`, gated: a real hub, real mock agents), `test/unit/work-rows-test.el` (`det`). The frame in
  `test/fixtures/work-space/frame.json` is what the wire decodes to.

### The rows

`modules/tools/drgnx-work-map.el`. A view row is a sub-row of the layout, keyed `(:row LAYER BLOCK-LINE SUB)`, or the
band above it, `(:band LAYER BLOCK-LINE SUB)`, in the order of their y. A row's text is `drgnx-work-map-row-text
STATE KEY`, a function of the cached frame and the display scale (`drgnx-work-map-scale`, the frame's by default).

- **Geometry.** The layout's units are 4 logical pixels; a row's pixel height is its units × 4 × scale, split evenly
  over its lines (five for a rich agent row, two for a compact one, else one). Each line ends in a newline carrying
  `line-height` `(N)` (the spike showed `(N)` gives N+1 pixels, never `(N . t)`), so a row's height is the layout's whatever
  its text holds. A band is a blank line in a small face (`drgnx-work-band`) of its height; the edge tiles draw into it.
- **Cards.** A card's line is placed by pixel `:align-to` from the layout's x, in the decoration faces
  (`drgnx-card-top`, `-mid`, `-bottom`, `-single`: PD's open boxes under Glitnir), its text cut to the card's width by
  `string-pixel-width` (memoised in `drgnx-work-map--fit-memo`, bounded). Every card character carries the text
  property `drgnx-work-id`. The layer label stands in the 84 px margin on a layer's first row.
- **Index.** `drgnx-work-map--index` (weak on the layout) maps a row key to its items left to right and to its layout
  row, built once per frame.
- **Outline.** `drgnx-work-map-outline STATE COLUMNS` and the rows `(:outline AGENT-ID)`; used in a terminal frame,
  when the layout's `fits` is false (with a `(:notice)` row first) and when `O` asks. Blocks are ordered by plan, then
  start order; each line is cut to the window's width.
- **Redraws.** The client's marks reach the view in `drgnx-work-map--changed`: a changed item dirties its rows
  (`drgnx-view-dirty`), a relayout or a changed list of rows touches the view (SYNC diffs the keys with a signature of
  each row's items and rectangles), so a field change draws one row.

### The edges

`modules/tools/drgnx-work-edges.el`, pure: a function of the layout's geometry, the chain and the colours. The
fixture's bands carry real curves, so the screenshot set shows them.

- **Tiles.** A band is cut into tiles 192 logical pixels wide (device pixels at the display scale: an SVG stays the size
  it is written at on the native shell). `drgnx-work-edges-tile BAND I GEOMETRY COLOURS` is the image of tile I, or nil
  when no curve and no port crosses it. `drgnx-work-edges-tile-svg` is its text, built as a string (no DOM): a cubic
  from the band's top to its bottom for a straight segment, an arch rising from the bottom for a same-row arc, the
  chain's curves last so they draw on top. The image cache is keyed on the SVG text and the alternative text, so a tile
  whose strokes did not change is the very same object, a theme change makes new tiles by itself, and the cache holds
  600 entries at most. The alternative text names the tile's edges ("hub rows → rp-df-hub (came from)").
- **Strokes** (design §5.2 as amended): came from 1 px solid; edits 2 px solid, neutral off the chain; reads 1.5 px
  dotted in the agent's colour; runs on 1 px dash-dot; based on 1 px short dashes; overlap 2 px dashed in the warning
  colour; read versus edit 1 px dotted. No two kinds share a width and a dash. On the selection's chain an edge takes the
  accent colour (an edit: its agent's colour) and is 1 px wider.
- **Colours** come from the `drgnx-work-*` faces whenever a tile is made (`drgnx-work-edges-colours`); the module holds
  none. A theme change draws every map again (`drgnx-work-map-theme-changed`).
- **A chain change** (`drgnx-work-map--edges-update`, on `drgnx-work-map-edges-functions`, one frame after the
  selection): the edges that joined or left the chain name the bands and lanes to draw again; the images the redraw
  replaces are flushed (`image-flush`), the unchanged tiles are not touched.
- **Lanes.** An edge that skips a card row is a 2 px wide image at the lane's x in each text line of that row, as high as
  the text, with the row's ascent in percent (`drgnx-work-edges-row-metrics`: the font's ascent over ascent plus
  descent), so the row keeps its height.
- **Ports.** Edges bundled for want of lanes end in a chip "↑ N" on the bottom edge of the band above their target,
  drawn into the tile that holds its column.

### Selection, the chain and the side panel

`modules/tools/drgnx-work-detail.el` holds the pure part; the buffer's state (`drgnx-work-map--selection`, the cached
chain, the edge selection, the item that finished) and the commands are in `drgnx-work-map.el`.

- A selection is `(KIND . ID)`. `drgnx-work-nav-chain STATE SEL` is `(UP DOWN EDGES)`: UP is every item reachable
  backwards over the edges the chain follows (came from, edits, reads, runs on), DOWN forwards, EDGES the ones between
  them. Overlap and based-on edges are not on the chain. The edge lists' adjacency is cached per frame (weak on the
  list).
- `drgnx-work-nav-move STATE SEL DIR`: `left` and `right` walk the layer in reading order and stop at its ends; `up`
  and `down` take the nearest direct neighbour over the chain's edges (least vertical, then horizontal, distance), and
  `up` falls back to the nearest ancestor on the lowest layer above when a level is missing. `drgnx-work-nav-agent`
  walks the team order, wrapping. `drgnx-work-nav-resolve OLD NEW SEL` gives `(SELECTION . FINISHED-ID)` when the frame
  changed.
- **Dimming is text properties.** `drgnx-work-map--class` reads the cached selection (and the search text) when a card
  line is drawn and prepends `drgnx-work-selected` or `drgnx-work-dim` to its faces, so a row that is deleted and
  inserted again has them; there are no overlays.
- **A selection move** (`drgnx-work-map-select`) works out which items changed class, draws the visible rows among
  them in the command's own redisplay (`drgnx-view-draw-now VIEW KEYS`), puts point on the card, runs
  `drgnx-work-map-select-functions` (the side panel) and arms `drgnx-timer-soon` keyed `(work-edges . VIEW)`: one frame
  later it runs `drgnx-work-map-edges-functions` with the final selection, so a held arrow key never pays for tiles it
  has left.
- **The side panel** is the buffer `*drgnx work detail: NAME*` in `drgnx-work-detail-mode`, a `drgnx-view` of type
  `work-detail` with one row per section (`:head :why :touches :conclusions :actions`); its text is
  `drgnx-work-detail-sections`. The pane kind `work-detail` (home right) shows it.

### The strip, the lens, the filters, search and Esc

- `header-line-format` is `("" drgnx-work-map--strip)` and `tab-line-format` `("" drgnx-work-map--lens)`: variables
  holding strings, made by `drgnx-work-map--refresh-strip` when the client marks the strip (a frame or a delta with
  `needs_you` or `chips`). There is no `:eval` and so no work in redisplay. The entries are the hub's needs-you cards
  and the agents in the needs-you state that no card is about.
- `g 1` to `g 9`, `n`, `N` and the global `work-needs-you-next` select the item a chip is about
  (`drgnx-work-map-needs-you`); the module calls no method that settles a card (a test records the client's calls).
  The mode-local `n`/`N` are the commands `work-needs-you-here-next` and `-previous`, because a command has one keymap
  and `work-needs-you-next` is the global one.
- Filters are buffer-local (`drgnx-work-map--filters`, `--collapsed`) and sent with `work/map/set` (`f`, `o`, `.`, `1`
  to `6`, `0`); the hub answers with a full frame. The selection and the arrow keys never send those fields. Sending
  them is a layout the user asked for, which moves (next section).

### Motion: the capture protocol

A layout the user asks for moves in the compositor, through Glitnir's layout leg (Nidhogg; Work space design §12.4).
The map's side is in `drgnx-work-map.el` ("Motion"); nothing runs in redisplay.

1. **Capture.** `drgnx-work-map--send-filters` calls `drgnx-work-map--motion-begin` before it sends. Each window
   showing the map gets a new value of the window parameter `glitnir-layout-capture` (a fresh list, so not `eq` to the
   last) and the map keeps, in `drgnx-work-map--motion`, the frame it shows and its cards' rectangles in that window.
   The redisplay after the key hands the capture to the presenter, which copies the window's text area while it still
   shows the old layout.
2. **Acknowledgement.** When the hub's frame comes with a new layout (`:layout` in the marks) and a capture waits,
   `drgnx-work-map--changed` calls `drgnx-work-map--motion-frame` instead of touching the view. If
   `glitnir-layout-captured-p` holds for every window, the new layout is drawn at once; otherwise a `drgnx-timer-poll`
   keyed `(work-motion . VIEW)`, owned by the buffer, gives it one period (1/60 s) and then draws anyway.
3. **Draw and move.** `drgnx-work-map--motion-draw` draws the whole view now (`drgnx-view-draw-now`) and, before the
   redisplay that shows it, sets `glitnir-layout-motion` on each window whose picture is held: `:moves` `(ID OLD NEW)`,
   `:enters` `(ID NEW)` (items new in the frame), `:exits` `(ID OLD)` (items the frame dropped), `:background 'default`,
   `:duration` 0.16, `:curve 'ease-out`. A window whose picture is not held drops its capture, and the layout jumps
   there; `drgnx-work-map-motion-stats` counts it under `:skipped` (`:legs` counts the layouts that moved).
4. **End.** A `drgnx-timer-start` keyed `(work-motion-end . VIEW)` takes both parameters off 0.1 s after the leg's
   duration, so the window is an ordinary one again (Glitnir demotes a window while it holds a capture). A capture whose
   frame never comes (no hub, nothing changed) goes after a second (`(work-motion-expire . VIEW)`). A new layout during
   a leg cancels the end and asks for a new capture: Glitnir retargets from the sampled rectangles.

The rectangles are `(X Y W H)` in pixels of the window's text area (`drgnx-work-map--item-rects`): x and w from the
layout (the margin plus the item's units, as the cards' `:align-to`), y and h from the rows as the display engine lays
them out. `drgnx-work-map--drawn-rows` measures each row from the one the window starts at with
`window-text-pixel-size`, which needs no redisplay, so the new layout's rows are measured right after they are drawn
into the buffer and before the redisplay that shows them. (The drawn rows are not the layout's heights: a card line is
as tall as its text, and an emoji or a larger fallback font makes a row taller.) At capture time
`drgnx-work-map--checked-rows` checks the old layout's measured tops against `window-line-height`; from a row that
differs, cards are left out of the old rectangles and cross-fade with the rest. A window that starts inside a row,
scrolls sideways or was not drawn yet asks for no capture.

**No motion** where `drgnx-work-map--motion-p` is nil: a terminal, a frame Glitnir does not draw, a Nidhogg without the
layout leg (macOS for now), reduced motion (`glitnir--reduced-motion-p`, the desktop's setting through Glitnir, or
`drgnx-look-motion` `reduced`). There the frame is drawn as before and nothing is said or counted. Live deltas never
move the map: only a frame with a new layout while a capture waits does. The teardown and a map buffer's
`kill-buffer-hook` call `drgnx-work-map-motion-clear`, which stops the timers and takes the parameters off every
window the map set them on (`drgnx-work-map--motion-windows`).

Tests: `test/ui/work-space-gui-test.el`, the rows `drgnx-work-gui/relayout-moves-with-motion` (dark and light, with
screenshots), `-no-ack-is-a-jump` (the text area moves after the capture, so the presenter drops it),
`-reduced-motion-sends-no-capture`, `-a-live-arrival-never-moves-the-map`, and the timing row
`-keys-stay-fast-during-a-leg` (40 keys during a 3 s leg, p95 under 16 ms). They need a Nidhogg with the layout leg;
on one without it the first two and the timing row skip.
- Search is a local class: `drgnx-work-map--class` dims what the text does not match, with the same text properties
  the selection uses.
- A conclusion that differs from the frame before (`:old` in the marks) puts its id in `drgnx-work-map--new`; one
  `drgnx-timer-start` keyed `(work-new . VIEW)` clears it after 4 s and draws those cards again.
- The client calls the hub on the subscribed connection (`drgnx-work-client--call`): the hub sends a view's events to
  the connection that subscribed it, and only that connection's events reach `drgnx-hub-event-functions`.

### The lens, and the Board

`drgnx-work-lens-map` is the keymap every Work view shares (the parent of the map's, the Board's and the Timeline's);
the movement and opening commands (`work-left` and so on), `work-view-map` and `work-view-board` are bound in it. They
act through `drgnx-work-lens-nav` (buffer-local): a view that is not the map sets it to a function of one direction, and
`drgnx-work-map--move` and its siblings call it first. The selection always lives in the map buffer
(`drgnx-work-lens--map` names it from the other views); `drgnx-work-lens-switch` carries it across.

`modules/tools/drgnx-work-board.el` is the Board: a `work-board` view (rows `(:head)` and `(:cards I)`, three lines a
card, the bar a 4 px `display` space). Its tasks come from `tasks/find` (every task, up to four pages) or `plans/get`
(a plan's tasks with their steps, for the progress bar), asked again 0.3 s after the map's frame changes
(`drgnx-timer-soon` keyed `(work-board . VIEW)`). `drgnx-work-board-column` is the Lisp copy of
`norn::tracker::board_column` (a test pins every status). `drgnx-work-board-for-selection` and
`drgnx-work-board-to-selection` are the design's table 8.2, pure functions of the cached frame and the cards; an agent
works on a card when its `task` field names the card's id.

### The Timeline and the trail

`modules/tools/drgnx-work-trail.el` holds both, and the steering commands. A step is the hub's `timeline/get` row;
`drgnx-work-trail-kind` takes its kind from its class and `detail.kind` (never its prose), `drgnx-work-trail-title` its
title, and `drgnx-work-trail-row-text` its row (the gap before the time is a `display` space, `(- right 14)`).

- **The trail** is a `work-trail` view (`:follow-tail`): row keys `(:step ID)`, `(:conc N)` (a conclusion card, after
  the step the hub stamped it on, else at the end) and `(:note N)` ("paused by you", "resumed by you", added when the
  command ran). It opens with `timeline/get {limit drgnx-work-trail-first-page}`, asks `work/conclusions`, and a
  `post-command-hook` function asks `{before SEQ, limit drgnx-work-trail-page}` when point is within about 30 rows of
  the top (`drgnx-work-trail-page-back`; `drgnx-work-trail--more` falls when a page comes back short). Older steps go in
  with `drgnx-view-insert :after nil`, new ones with `drgnx-view-append`; no step is held twice (a hash by id). Live
  steps come from `agent-step` events (`drgnx-work-trail-event`): the trail asks `{since LAST-SEQ}` rather than trusting
  the event's body, and asks the conclusions again half a second later (`drgnx-timer-soon`).
- **Conclusions** link to steps through the hub's `links` (named, since the last one); `drgnx-work-trail-conclusion-steps`
  and `-step-conclusions` are the two directions, `drgnx-work-trail-lit-steps` lights them (`drgnx-work-trail--lit`).
- **Opening a step** (`drgnx-work-trail-open-step`): a read opens the file at its lines (relative paths against the
  mirrored session's `cwd`; only a plain local file inside that folder, by its true name: `drgnx-work-code-local-file`);
  AS-READ calls `work/file-at {session path seq}` (the mode is chosen from the path with no file name handler); a search
  runs `project-find-regexp` again in the agent's folder (not when that folder is remote); a page `browse-url`; an edit
  shows `work/hunks` in `drgnx-work-hunk-mode`; a thought opens the agent's transcript (the step has no text of its own).
- **The Timeline** is a `work-timeline` view (rows `(:axis)` and `(:lane AGENT-ID)`), a lane per agent in team order,
  `timeline/get {limit 200}` each, asked again 0.3 s after an `agent-step` of its session. `drgnx-work-timeline-spans`
  (pure) puts steps at their time on the lane's pixel width, at least 2 px; faces `drgnx-work-seg-*` use
  `:inverse-video` over the stock colour faces, so a segment's colour is the face's foreground.
- **Steering** (`drgnx-work-trail-steer`, `-pause`, `-resume`, `-stop`) lives on the lens map and finds its agent per
  view (`drgnx-work-trail--agent-sid`): the trail's session, the Timeline's lane, the Board's card, the map's selection.
  Pause is `agents/pause`; resume is `agents/send` with `drgnx-work-resume-text`; stop asks `y-or-n-p` and is not
  bound to anything automatic.

### The review view and the second reviewer

`modules/tools/drgnx-work-review.el`. `drgnx-work-review-open` asks `work/conclusions`, then `decisions/effects` for each
decision (alist `drgnx-work-review--effects`), `work/files` and `work/hunks` for each file; every answer draws the view
again with `drgnx-work-review-install`. Row keys: `(:decisions)`, `(:decision N)` (origin order: from the brief, own,
needs you), `(:summary)`, `(:files)`, `(:file PATH)`, `(:hunk PATH I)`; `drgnx-work-review-parse-hunks` splits a
unified diff at its `@@` lines. `a` is a `review/mark` `accepted` with the sha1 of the file's whole diff (what the merge
gate compares); `D` is a `review/mark` `pending` and an `agents/send` naming the hunk (the hub has no hunk revert until
the edit history lands; nothing here writes into the agent's folder). `V` writes a plan
(`<state>/work-space/reviews/SESSION-TIME.md`, **Role:** review, the files changed, no conclusions) and calls
`job/propose`; it never calls `agents/start`. The path and the hunk's header in `D`'s message, and the session, folder
and file names in `V`'s plan, are the agent's words: `drgnx-work-code-one-line` keeps each on one line, so a file named
with a forged "[message from the user …]" header or a `### Task` line adds neither.

The merge queue is not inferred: a branch item's `queue` (`[N, M]`) and `conflicts` fields are drawn when the hub sends
them (`drgnx-work-map--chip-line`, a `:queue` section of the side panel). The hub sends none yet, so no chip shows.

### Live agents' files

`drgnx-work-live-file-mode` (in `drgnx-work-space.el`) is turned on by the module's `find-file-hook` function in a file
under the `cwd` of a mirrored hub session that is not `exited` and whose `cwd` is a linked worktree (its `.git` is a
file, not a directory: the user's own checkout has a directory). It sets `view-mode`, keeps the buffer's old read-only
state, and shows " live · NAME" (`drgnx-work-live-file--lighter`). `drgnx-work-take-wheel` (`W`, and the remaps of
`read-only-mode` and `View-exit`) is an alias of `drgnx-agents-take-wheel` (module tools/agents-in-editor, the hub's
wheel protocol, docs/develop/agents-editor.md); without that module it says so. The interim `agents/pause` and its
`after-save-hook` are gone. The module's `:teardown` turns the mode off in every buffer, restoring the
read-only state each had.

### Into the code (`drgnx-work-code.el`)

The hub keys presence by the path in the agent's own folder, and a map file item is `file:REPO/REL`, so every question is
asked for REL in each candidate folder: the worktree (`cwd` of the mirrored session whose hub id is the agent's) of each
agent on the selection's chain (`drgnx-work-code--chain-sids`, from `drgnx-work-nav-chain`), then the root of the
workspace named REPO. `drgnx-work-code--presence` asks `agents/presence/get` for each path and gathers the entries;
`drgnx-work-code--pick` chooses: the newest entry of the chain's agents that has a line, else the newest with a line of
any agent, else the newest without one (the buffer opens at the top and `drgnx-work-code--file-only` is set). An
answer arrives after the keypress; the file opens when it does, and a hub that is not there opens the first path that
exists at the top. `drgnx-work-code-open-file` is the entry point (the `file` row of `work-open`).

Every name here is the hub's, so an agent's (docs/develop/core.md, "Names an agent gave"): a session's `cwd` counts only
when it is local (`drgnx-work-code-local-dir`), the candidate paths are made with no file name handler, an entry's file
counts only when it is one of the paths asked about, and a file opens only by the true name
`drgnx-work-code-local-file` gives: a plain regular file inside the agents' worktrees or the workspace's roots, never a
remote or quoted name, a link out or into a loop, a device, a FIFO, a folder or a name a handler would read. An entry
naming anything else is passed over. `test/unit/work-names-test.el` holds these cases.

`work-files` (`e`) calls `work/files {session}` for the agent the selection stands for (an agent, a subagent's parent,
or the first agent a branch came from) and fills a `drgnx-work-files-mode` buffer, placed in the popup lane. Its hint keys
come from `drgnx-work-code-hint-keys`. The list is the edited files only: `work/files` has no read list yet (its
`read_at` is filled when the edit history lands). `work-who-is-here` asks for the visited file in the user's checkout and
in every mirrored worktree of the same repository (found from the `.git` file), keeps each agent's newest entry, selects
`file:REPO/REL` when the cached frame holds it and echoes the agents. A file the frame shows only as a count chip is not
given a node: the hub has no way to add one for a selection yet.

`work-diffs` (`d`, `drgnx-work-code-diffs`) asks `work/files {session}`, then `work/hunks {session, path}` for each file: the
hub's diff against the worktree's recorded base (the interim source, the base snapshot; part 4's edit history replaces
it behind the same methods). Each answer becomes a `drgnx-work-diff-mode` buffer, killed and made again each time. It
derives from `drgnx-work-hunk-mode` (also a trail step's hunk): a read-only `special-mode` coloured from its text with
`diff-mode`'s faces, standing in `/`. It is no `diff-mode` buffer on purpose: `diff-mode` reads the file names in the
diff with file name handlers on (syntax colouring, which-func), and its keys, VC and ediff open, apply or revert the files
they name, in a live agent's worktree or in the folder the buffer stands in. `drgnx-work-code--diff-layout` saves `current-window-configuration` in
`drgnx-work-code--saved-windows` unless one is already saved, then splits the window into at most three side by side;
files from the third on are the third window's tabs: the window parameter `drgnx-work-diff-tabs` holds them and each
buffer's `tab-line-tabs-function` reads it. `work-diff-quit` (`q`) restores the saved configuration and kills the
diff buffers; the module's teardown does the same without restoring. `a` and `D` are registered so the keys are
reserved for hunks, and say the review view decides them (no review view exists in this phase).

### The view core

`drgnx-view-draw-now VIEW &optional KEYS` draws only the rows named by KEYS (the keypress's own redisplay for a
selection move); the marks of other rows stay for the view's own draw. `(drgnx-view-stats)` gains `:draw-ms`, the
milliseconds spent drawing (`work-live-draw` reads it).

### The workspace

`drgnx-work-space-workspace` is the frame's selected window's project (`project-current`; none for a remote folder, a
folder outside git or a scratch buffer, which opens an empty map). Its roots are `drgnx-work-space-roots` or the
default (the project's repository, and an enclosing repository with the repositories directly in it); its id is `workspace:` and 12 hex digits of the 64-bit FNV-1a hash over the sorted
roots' first root commits (the path where git does not answer).
