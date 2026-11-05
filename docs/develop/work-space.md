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
   so a new card does not shift the others. Overlaps resolve left to right with the gaps, then back from the right
   edge.
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
- `machines/report` takes user connections only (`classes: [User]`, in `test/conformance/class-matrix.json`); a report
  for `local`, a ttl outside 0..86400, more than 256 slots or a slot without id and kind is `invalid-params`.
- The local pool is read from the job runner (`exec::Runner::slot_counts`): one `local-N` slot per agent-job slot, the
  busy ones held by `job` (the pool does not say which job). The hub refreshes it, and drops expired reports, on every
  `machines/report` and `machines/list`, and every 2 s (`work::machines::run`, which waits on the clock only, a task named
  `machines:run` on the hub's clock, so `__test_advance` moves it). `machines-changed` carries the whole list, and only
  when it changed.
- The CLI is `ratatoskr machines report --machine M --ttl S [--json FILE|-]` (`machines_cli`): exit 0, 1 on a hub
  error, 2 on bad arguments. jobq calls it; its side is jobq's plan.
- Tests: `registry::*` (pattern D), `machines_cli::parses_and_reports` (D), conformance
  `work/machines-report-from-a-user`, `work/machines-report-from-an-agent-is-refused`,
  `work/machines-expire-after-ttl` (virtual clock) and `cli/machines-report` (the CLI as a child, exit read).

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
