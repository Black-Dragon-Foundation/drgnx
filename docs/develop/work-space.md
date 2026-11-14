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
| `Delta { view, delta }` | a fact changed what a **shown** view shows: the ids changed and removed (removed: gone, or finished without "show finished"), and whether the edges, the structure (an item came, went, or changed block or parent) or the needs-you strip changed; a **hidden** view gets none |
| `Relayout { view }` | the user opened, changed or showed the view: lay it out and draw it anew |

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
| rich agent card | 54 × 25 (5 lines) | 216 × 100 |
| compact agent card | 42 × 10 (2 lines) | 168 × 40 |
| chip row (asks, specs, plans, branches, files, machines) | 7 high | 28 |
| chip widths: ask, spec, plan, branch, file, machine | 58, 44, 54, 42, 52, 36 | 232 … 144 |
| gap between cards | 3 | 12 |
| band between rows | 8 | 32 |
| band between an agent sub-row and its branches' sub-row | 3 | 12 |
| gap between blocks | 6 | 24 |
| a collapsed layer's row | 5 | 20 |

The look's 19 px card lines round to 20 px on the grid. Compact and roomy densities scale these (`Metrics::of`). The
chips are as wide as the mockup's text needs in the UI font (an ask holds "fix deferred testing rows", a plan its title
and its "3/6"), at most 58 units, so two fit at the narrowest width the map fits (120 units); a branch is at most as
wide as a compact agent card (42), since a branch sits under its agent and the sub-row packs at the card's pitch. Four
rich cards and their gaps fit a 1000 px tile in one row.

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
refuses one whose crossings are above the golden it replaces (`UPDATE_VEGVISIR_GOLDEN=metrics` does not: a card or chip
width moved on purpose; the 2026-11-13 widths moved the 1000 px golden from 393 to 412 crossings and the two larger ones
down, 169 to 157 and 129 to 126). `tests/timing.rs` holds `layout_200_items_within_2_ms`.

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

### The rows (`vegvisir::render`)

The map's rows are built in the hub (`docs/develop/hub.md`, "Rows") from a layout, the items and edges it shows, the
view's env and a `drgnx_rows::fit::Measure`; no I/O, no clock (a job chip's elapsed time takes `Scene::now`).
`render::Index::of` sorts once per layout (each row's items by x, the rows by y with each band above its row, each
layer's first row, each layer's count); `render::rows` only reads it. One row per text line:

- `row:LAYER:BLOCK-LINE:SUB:LINE`: a layout row's line N (five for a rich agent row, two for a compact one, else one),
  its height the row's px over its lines, minus one. The layer's name starts its first row's first line (a collapsed
  layer's: "Name · count"), fitted to the margin less 8 px. Each card's line is a stop at the card's left, its text
  fitted to the card's width less 10 px, and a stop at its right; the card's box face (`drgnx-card-*`) is a run under
  the text's own faces, and `drgnx-work-id` names the item over the text and the right stop.
- `band:LAYER:BLOCK-LINE:SUB`: the band above that row, as high as the band: each 192 px tile (at the scale) that a
  curve or a port chip crosses is an image at its column, else the row is blank.
- Lanes: each line of a card row carries the row's lanes as images among its cards, by column; lanes at one x are one
  image (the widest stroke's: the chain's when one is on it) whose words name them all, so an image never takes the
  gap and pushes the next card right.
- `strip` (`render::strip`, the header line): a chip with its jump key per needs-you entry (the cards, then the agents
  that need you with no card), the first nine and `+N`, then a stop that puts the machines' load at the view's right
  edge.

Edge strokes are a width or a dash per kind, never colour alone (design §5.2 as amended): came from 1 px solid; edits
2 px solid, neutral off the chain; reads 1.5 px dotted in the agent's colour; runs on 1 px dash-dot; based on 1 px short
dashes; overlap 2 px dashed in the warning colour; read versus edit 1 px dotted. The selection's
chain (`Scene::chain`) draws in the accent, an edit on it in its agent's colour, one px wider and on top. The SVG comes
from `drgnx_rows::svg` in palette roles only (`edge`, `edit`, `accent`, `warn`, `chip-bg`, `chip-fg`, `agent-1..6`);
an image's id is its content hash and the env epoch, so the same strokes are the same image across draws (sent once)
and a theme change draws them all again.
- On a terminal, a layout that does not fit, or the user's `O`: `notice` (the layout did not fit), then
  `outline:ID:LINE` per agent in plan order (its line, why, touches and conclusion, each within the columns), or
  `outline-none`.

The rows of the fixture frame equal `test/fixtures/work-space/rows-golden.eld` under a fixed 8 px advance
(`tests/render.rs`), recorded from the editor's own drawing before the hub took it over. Selection, dimming and search
are the model's classes in Sjá, put over the rows by `drgnx-work-id`. The runner icons are the default
glyphs of `drgnx-face-glyphs`.

### Keys and the native view model (`vegvisir::nav`)

The editor answers the map's keys from a replica of the map's model (Sjá, in Nidhogg), never from the hub. The hub
sends, with each shown item, where each arrow goes from it; `vegvisir::nav` computes those links over the frame (the
items a view shows, their places in its layout, and the chain edges among them), with the rules the editor's own
navigation had:

- `left`/`right`: the neighbours along the item's layer in reading order (by top, then left), stopping at its ends.
- `up`: the nearest (least vertical, then horizontal distance from the card's centre, then id) of what it came from
  above it; when none of those has a place (a missing level, or a collapsed layer), the nearest of its ancestors on the
  lowest layer above. `down`: the nearest of what it touches below it.
- `then`: where the selection goes when the item goes: the last of everything it came from, by layer then id.
- The lists the walking keys follow: `outline` (the agents by plan rank, start order, id), `team` (the outline with each
  agent's subagents after it, in start order), `needs-you` (each strip entry's first shown item: the cards by id, then
  the agents that need you with no card).

The replica's chain is checked against the hub's: `work::map::tests::chain_golden_matches_vegvisir` writes
`test/fixtures/work-space/model-thirty.json` (the map's model of the 30-agent fixture at 1600 px and
`vegvisir::Model::chain` of every item; `UPDATE_VEGVISIR_GOLDEN=1`), and `test/unit/view-model-chain-test.el`, in the
Nidhogg image, selects each item in Sjá and checks that the nodes it classes `chain` are exactly that chain.

An item without a place has no arrows. `tests/nav.rs` checks every link of the 30-agent fixture at 1600 px against
`tests/golden/nav-thirty-1600.json`, recorded once from the editor's navigation (now frozen) over the frame in
`tests/golden/nav-thirty-1600-frame.json`; `UPDATE_VEGVISIR_GOLDEN=1` writes the frame again and, since the editor's
navigation is gone, the links from this crate (a layout metric moved); a frame that moved fails until they are written.

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
  shadow repository (a prune leaves it). The edited-file counts no longer read it: they come from the edit history (below).
- A session in a folder the hub made no tree for (a docs agent in the org folder) gets a row at its start, from the
  folder's head (`bases::session_started`); folders under `<state>/hub/runs` record their own.
- `bases::ancestry_of(rows, roots)` and `bases::ancestry(front, workspace)` answer "based on" pairs of
  `BranchRef {repo, branch}` for the workspace's roots, computed from the rows when asked.

### Edited files, counts and hunks

`work::edits` answers three user methods from the edit history (`history::views`): the worktree's branch `wt/<id>` in
the project's `history.db`, its documents against the branch's base commit (`History::hunks` from record 0, each
document as first stored). The agent's folder is never asked.

- `work/files {session} -> {files: [{path, plus, minus, untracked, read_at?}]}`: per changed file the lines added and
  removed (`Hub::edits_against_base`); `untracked` is a file the base commit lacks. No branch yet: an empty list.
  `read_at` is not filled yet. Text files only: binary, large, generated and lock files are whole-file versions the
  document store does not hold, so they are not listed.
- `work/hunks {session, path} -> {diff}`: the unified diff of one path, base text to current (`Hub::diff_against_base`),
  empty when it changed nothing.
- `work/file-at {session, path, seq} -> {bytes, seq}`: the file's bytes (base64) after the session's newest record at or
  before step `seq` (`Hub::file_at_step`, which reads the records' cause); a file the session never touched is the base
  commit's. `seq` is that record's step, 0 before the session's first. A missing path or a path leaving the worktree is
  `invalid-params`.

Only sessions the hub holds are served. `edits::changed(front, session)` gives the same counts to the map's `Changed`
fact, after every step that took a snapshot (`Map::edited`, from the step-close path). The buffer view's gutter
(`changed_lines`) and the three-way projection (`base_of`) still read the step snapshots.

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
  design document, else `chat`. The turn's first step is out before that moment (the snapshot of the tree comes
  between, and the turn's user entry step is closed by then too), so a test waits for the agent's answer, not for a
  step; a test-hooks hub started with
  `RATATOSKR_TEST_ASK_DELAY_MS=N` waits N ms there, which makes a test that waits too early fail every time.
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
- Huddles on the map: the hub makes each open huddle a needs-you card of every map, `huddle: CLASH` about its two
  agents (on the strip and in the `needs-you` list; docs/develop/hub.md, the Work map's model). On an agent whose
  card overlaps another (the model's `overlaps` field), `H` (`work-huddle`, `drgnx-work-huddle-overlap`) starts a
  huddle with that agent through `agents/huddle/start` (a choice by label when there are several; row
  `drgnx-work-map-rows/h-huddles-the-agents-the-model-says-overlap`). In the editor, a `conflict` gutter range of an agent
  in an open huddle reads "huddle open · o opens it" on hover, and `o` in the follow view opens the thread.
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

Module `tools/work-space` (`modules/tools/drgnx-work-space.el`; the map buffer's mode, keys and motion are in
`drgnx-work-map.el`, a library of the module; the map client is `core/drgnx-work-client.el`).

### The map client

`core/drgnx-work-client.el` keeps the map views this Emacs subscribed to and calls the hub for them; it draws nothing
and keeps no copy of the map. The map's rows come as `view-patch` events and its model goes to Sjá (the hub builds both:
"The rows (`vegvisir::render`)", above).

- One view per map buffer, keyed by the map view's id. `drgnx-work-client-open` subscribes (`work/map/subscribe`);
  `-set` sends `work/map/set` (hidden or shown, filters, collapsed layers, width, density, the selection, the outline)
  and keeps every field but `shown` for the next subscription; `-set-then` takes a callback for the hub's answer, which
  comes after the patches the change made (one connection, in order); `-close` sends `work/map/close`. Every call goes on
  the subscribed connection (`drgnx-work-client--call`): the hub sends a view's patches to the connection that
  subscribed it.
- A view subscribes again from `drgnx-hub-connected-functions`; `drgnx-hub-disconnect-functions` makes it keep what it
  shows and say "reconnecting". An answer counts only for the subscription it was asked in (a later one, or a close,
  makes it stale). `drgnx-work-client-status-functions` is how the buffer hears.
- Tests: `test/unit/work-client-test.el` (class `det`).

### The rows

`modules/tools/drgnx-work-map.el` holds the map's buffer, its keys and its motion; it draws nothing of the map. The hub
lays the map out and draws every row, the strip, the bands' edge tiles, the lanes and the outline ("The rows
(`vegvisir::render`)", above), and sends the map's model to Sjá. The buffer is the hub-fed view of the map view's id
(`drgnx-work-map-rows-attach`: `drgnx-view-patch-attach`, its env registered while a window shows it); the rows name
faces only, so the editor keeps defining them. A card line's runs come in the order card box, then its text's own
faces; each is appended below those before it (`drgnx-view-patch--dress`), so the text's faces (a state dot, an overlap
mark) show and the card's box and `drgnx-work-card` (the UI font) are under them. The hub names `drgnx-work-title` on
an agent's name (heading weight), `drgnx-work-meta` on its line of minutes and spend (the code font, no box: it
would take the box off the run) and `drgnx-chip` under the strip's chips. The themes give the card faces a ring in the
strong border with an explicit colour (a ring with none takes each run's foreground and the card breaks into boxes
where the faces change). A class (the selection's tint, the dimming of the cards off its chain) goes through the
cards' boxes (`drgnx-view-nav-through-faces`, set by `drgnx-work-map-rows-attach`); a chip elsewhere keeps its own
face under a class. The faces: `drgnx-work-band`, the decoration faces (`drgnx-card-top`, `-mid`,
`-bottom`, `-single`, loaded from `modules/ui/drgnx-decor.el`), `drgnx-runners-*`, `drgnx-work-seg-*`,
`drgnx-work-agent-1` to `-6` and `drgnx-work-chain`, `-chip`, `-dim`, `-label`, `-needs-you`, `-new` and `-overlap`.

- **Without Sjá** (`drgnx-work-map-rows-p` is false: an Emacs that is not Nidhogg) there is nothing to draw the map
  with: the map shows `drgnx-work-map-no-sja` through the minimal view type `work-map` and subscribes to nothing; its
  side panel, Board, Flow, trails and Timeline show the same notice, and a key that needs the model says it
  (`drgnx-work-map--require-sja`). The old Lisp drawing of the map, its edge tiles and its client-side frame went with
  render offload Task 34; there is no switch back to it.
- **Text and icons.** The cards' text is the UI font, so the hub measures and fits it in the font role `text` (the face
  `drgnx-ui-text`; `drgnx-view-env-roles`), not `ui` (the buffer's default, the code font). A chip's glyph is a Lucide
  icon (`etc/icons`, read into `vegvisir::icons`, drawn at 1.6 stroke in the palette's `chip-fg`) in an image of its own,
  one placeholder character at the line's start (its glyph on a terminal), 16 px; the trail's step kinds and its
  conclusion cards use the same. The selected card is the hub's: `Scene::selected` draws its lines in
  `drgnx-card-sel-top/-mid/-bottom/-single` (a 2 px accent ring, the themes give it), so a selection move is a redraw of
  two cards, not an overlay; the class step only dims the cards off the chain. The strip carries, left of the machines',
  the forecast and cost chips (`wk 41 % ▲ Thu`, `$31 / $40`); only a test hub's scene gives them yet
  (`Map::scene_strip`; the real feed is DEFERRED MAP-STRIP-WK-COST-1).
- **What is lit and what is dim.** With a selection, every item off its chain (neither it nor an end of an edge on its
  chain) carries `drgnx-work-dim` in the hub's rows; the editor's class step dims nothing on the map. A machine on a chip is
  its short name ("desk" for "desktop"); a branch's chip shows a tag, the machine its agent runs on and the slot it holds
  (`Fields::tag`, from `SessionFact::machine` and `::slot`: "desk 3"; a hub session has no slot yet, so its tag is the
  machine alone), in place of its edits count. A machine's chip on the strip starts with its Lucide monitor
  (a laptop for "laptop"), an image in the strip's row that `render::strip` returns beside the row.
- **The Detail head and the trail's numbers.** An agent's Detail starts with its badge, its name and its state as a chip
  at the right edge, then the subtitle (task, "running N min", "≈$1.20 (API prices)"); `detail::rows` takes the tile's
  width and the UI font's measure, and the subtitle never wraps (a wrapped line shows a continuation glyph): it drops
  "(API prices)", then its parts from the end, then is cut with an ellipsis. A trail's step that a conclusion rests on
  starts with the conclusion's number in a filled accent circle (`drgnx-work-step-number`, the solid chip
  `drgnx-chip-solid` in the badge's pill), the
  others keep the room; the newest conclusion's card says `new` while it is stamped on one of the last three steps.
- **Cards, Detail and trail as the mockup draws them.** The Work layout's trail tile is 250 logical px tall (the mockup's), the lens switch is a rail with the shown lens raised on it (`drgnx-work-lens-rail`). A card line is as tall as its layout row says (a row's
  `height` unit, px: `drgnx-view-patch` sets `line-height` from it; a row with no unit is that many default lines).
  An agent's initial is a filled circle of its colour (`drgnx-work-who-N`), the going line is the UI font with its
  numbers in the code font, the flag line carries the branch's totals (`edits N (+P −M)`, `Fields::edits` of an
  agent). A file's chip is its name and its change (`session.rs +40 −3`), a machine's chip its own name; only the
  strip abbreviates ("desk"). The Detail head's subtitle wraps by word into rows of its own (`head/1`, `head/1.1`);
  its sections are "Why ↑", "Touches ↓" and "Conclusions" (no heading for the actions), an agent's Touches in the
  order branch, machine ("desktop · slot 3"), edits (the file its branch changed most), reads, then the rest. A trail
  step keeps its verb (`read PATH`, `web TITLE — HOST`, `edit PATH +P −M`, `job PATH · WHERE`), paths in the link
  colour, a thought's text muted and italic; durations read `0.3 s`; a finding's card keeps its keys line.
- **The lens bar's right** (`drgnx-work-lens--controls`): the grip (drawn; the tile layout's drag is not wired), maximise
  (`drgnx-work-lens-maximize`: hides the Detail island and the trail, again shows them) and ⋯ (shown while the bar is hovered; its menu is the four lenses and the keys sheet). The lens
  shown is a pill in a ring (the themes give `drgnx-work-lens-current` its box).
- **The Work layout** (`drgnx-layouts`' `work`): the map full width, the Detail island at its right (340 logical px) and
  the trail under the map. The Detail tile and the trail tile draw their own title row in the area's row
  (`drgnx-area-own-title` as a string, with the area's close): "Detail", and "Trail · AGENT | Agent · AGENT | following ▾".
  The trail follows the map's selection (`drgnx-work-space--follow-trail`: the trail of the selected agent, made when
  there is none, shown in the panel under layout Work); the Flow still shows its Rules tile on demand. The lens bar is
  pills and keycaps: the lens shown is `drgnx-pill-on`, the map's own keys (focus f, overlaps o) are `drgnx-pill` with a
  `drgnx-keycap`.
- **A hub restart:** the patches dim the view, the client subscribes again on the new connection, and the new hub's
  reset redraws it.
- Tests: `test/unit/work-map-rows-test.el`, `test/unit/work-space-test.el`; the view rules on the 30-agent map and a
  trail (a new class after `text-scale`, a second frame at twice the font, a theme change mid-stream, a face override)
  in `test/ui/work-map-rows-gui-test.el`, and the map in a terminal class in `test/tty/work-map-test.el`.

### Selection, the chain and the side panel

The selection, the keys and the commands are in `drgnx-work-map.el`; the side panel's buffer is in
`drgnx-work-detail.el`.

- **Keys answer from the model in Sjá.** Every key is one line through `drgnx-view-nav` (docs/develop/core.md, "Keys
  through the model"): the hub sends, with each item, where each arrow goes from it (`vegvisir::nav`, above), and the
  model's classes (`selected`, `match`, `chain`, `dim`) restyle the rows by their `drgnx-work-id` spans.
  `drgnx-work-map--nav` keeps `drgnx-work-map--selection` as `(KIND . ID)` (the kind read from the model with the
  selection) and runs `drgnx-work-map-select-functions` when it moved. Left, right, why and touches follow the `left`
  `right` `up` `down` links (from nothing, the team's first);
  next and previous agent walk `team`; `g N` walks to entry N of `needs-you` and `n`/`N` cycle it (the list is the
  strip's chips in order, `vegvisir::nav::strip_entries`: the cards, the agents that need you with no card, the open
  huddles; an entry about nothing shown holds its card's id, no node, and `g N` there says nothing needs you); search sets the
  model's search (non-matches dim on their spans) and selects the first matching agent of `outline`; Esc clears it;
  `O` sets the model's form, so up and down walk `outline`, and asks the hub to draw that form (`work/map/set
  {outline: on|off}`, kept for the next subscription; row `drgnx-work-map-rows/the-outline-key-asks-the-hub-for-its-form`). Back and forward follow Sjá's reserved links `back` and `forward` (the instance's
  history; Nidhogg's `nidhogg/sja/README.md`, "History"): in the map through `drgnx-work-map--nav`, in a view of it
  through `drgnx-view-nav`. Open reads the label once; a file opens at the team's
  agents on its chain. Motion capture's card rects (`drgnx-work-map--item-rects`) take x and w from the model's fields. The trailing notice is `work/map/set {view, selected}` (or `{view, clear}`). Tests:
  `test/unit/work-map-nav-test.el`.
- **The side panel** is the buffer `*drgnx work detail: NAME*` in `drgnx-work-detail-mode`; the pane kind
  `work-detail` (home right) shows it. `drgnx-work-detail-buffer` attaches it as the hub-fed view `VIEW/detail` in the
  map view's class and registers its env. The hub (`work/map/detail.rs`) builds its rows from the map's model and the
  view's selection (head, why, touches, conclusions, a machine's queue, actions; one row per line, keyed `SECTION/N`, a
  job's line carrying `drgnx-work-job` for `l`) whenever it publishes the map, and when the panel's env arrives. The
  tile is the mockup's `.det`: the rows are in the UI font (`drgnx-work-card`), the head and the section names in the
  heading face, a `KEY\tVALUE` line (the why-chain's you, spec, plan and task, a touch's branch, machine, edits, reads
  and overlap) a muted key and its value in a column (`detail::rows` takes the display scale for the column), the
  why-chain's values in the accent, an overlap in the warning colour, and the actions as buttons with their keycaps
  (an agent's: Open, Files, Diffs, Trail, Steer, Pause, Review, in the default profile's keys); the
  selection reaches the hub as the map's `work/map/set`. Without Sjá the panel shows the map's notice. Tests:
  `detail_rows_say_the_edges` (Rust), `drgnx-work-detail/rows-follow-the-selection`.

### The strip, the lens, the filters, search and Esc

- The strip is the hub's first row (`render::strip`): a chip per needs-you entry (the cards, then the agents that need
  you with no card), the open huddles, and the machines' load at the right. `tab-line-format` is `(""
  drgnx-work-map--lens)`, a variable holding a string, so nothing runs in redisplay.
- `g 1` to `g 9`, `n`, `N` and the global `work-needs-you-next` select the item a chip is about, entry N of the model's
  list `needs-you` (`drgnx-work-map-needs-you`); the module calls no method that settles a card (a test records the
  client's calls).
  The mode-local `n`/`N` are the commands `work-needs-you-here-next` and `-previous`, because a command has one keymap
  and `work-needs-you-next` is the global one.
- Filters are buffer-local (`drgnx-work-map--filters`, `--collapsed`) and sent with `work/map/set` (`f`, `o`, `.`, `1`
  to `6`, `0`). The selection and the arrow keys never send those fields. Sending them is a layout the user asked for,
  which moves (next section). The hub sends the layout's row patches, then answers the `work/map/set` (one connection,
  in order), and the answer
  (`drgnx-work-client-set-then`'s callback, `drgnx-work-map--answered`) hurries the map's view, so the new layout is
  drawn at the next timer pass instead of after the 0.1 s throttle the live patches keep it on (work-relayout: p95
  229 ms to 22 ms). Test: `drgnx-work-map-rows/asked-layout-draws-at-the-answer`.

### Motion: the capture protocol

A layout the user asks for moves in the compositor, through Glitnir's layout leg (Nidhogg; Work space design §12.4).
The map's side is in `drgnx-work-map.el` ("Motion"); nothing runs in redisplay. Where the map cannot move, the frame
of a layout the user asked for (`drgnx-work-map--asked`, set by `drgnx-work-map--send-filters`) is drawn at the next
timer pass (`drgnx-view-hurry`), not after the view's 0.1 s throttle: that throttle was most of the relayout time
(command to frame about 11 ms at p95, frame to drawn 100 ms). Live frames keep the throttle.

1. **Capture.** `drgnx-work-map--send-filters` calls `drgnx-work-map--motion-begin` before it sends. Each window
   showing the map gets a new value of the window parameter `glitnir-layout-capture` (a fresh list, so not `eq` to the
   last) and the map keeps, in `drgnx-work-map--motion`, the cards the buffer draws (`drgnx-work-map--drawn-ids`)
   and their rectangles in that window. The redisplay after the key hands the capture to the presenter, which copies
   the window's text area while it still shows the old layout.
2. **Acknowledgement.** The hub's patches for the new layout come before its answer to `work/map/set`, on the same
   connection. When the answer comes and a capture waits, `drgnx-work-map--answered` calls
   `drgnx-work-map--motion-frame` instead of hurrying the view (live patches never reach it). If
   `glitnir-layout-captured-p` holds for every window, the new layout is drawn at once; otherwise a `drgnx-timer-poll`
   keyed `(work-motion . VIEW)`, owned by the buffer, gives it one period (1/60 s) and then draws anyway.
3. **Draw and move.** `drgnx-work-map--motion-draw` draws the whole view now (`drgnx-view-draw-now`) and, before the
   redisplay that shows it, sets `glitnir-layout-motion` on each window whose picture is held: `:moves` `(ID OLD NEW)`,
   `:enters` `(ID NEW)` (cards the buffer did not draw before), `:exits` `(ID OLD)` (cards it no longer draws), `:background 'default`,
   `:duration` 0.16, `:curve 'ease-out`. A window whose picture is not held drops its capture, and the layout jumps
   there; `drgnx-work-map-motion-stats` counts it under `:skipped` (`:legs` counts the layouts that moved).
4. **End.** A `drgnx-timer-start` keyed `(work-motion-end . VIEW)` takes both parameters off 0.1 s after the leg's
   duration, so the window is an ordinary one again (Glitnir demotes a window while it holds a capture). A capture whose
   answer never comes (no hub) goes after a second (`(work-motion-expire . VIEW)`). A new layout during
   a leg cancels the end and asks for a new capture: Glitnir retargets from the sampled rectangles.

The rectangles are `(X Y W H)` in pixels of the window's text area (`drgnx-work-map--item-rects`): x and w from the
model's fields `x` and `w` (the margin plus the item's units, as the cards' `:align-to`), y and h from the card's lines
as the display engine lays them out: each line's height is `window-text-pixel-size` of that line alone, added up from
the window's first line down to its bottom, so y is the sum above the card's first line and h its lines' sum. The
measure of a line runs to the end of the next line with that line left out (`IGNORE-LINE-AT-END`): one that stops at
the next line's start stops before a display property there and leaves out the newline's height, which is a band
line's whole height. One line's layout each, so the cost grows with the lines shown (`pos-visible-in-window-p` per
line laid the window out from its start each time: half the CPU of work-relayout). No redisplay is needed, so the new
layout is measured right after its patches are drawn into the buffer and before the redisplay that shows it. (The drawn lines are not the layout's heights: a card line is as
tall as its text, and an emoji or a larger fallback font makes a line taller.) Only the hub's card rows (keys `row:…`)
count: the outline has no rectangles, so it asks for no capture, and neither does a window that scrolls sideways.

**No motion** where `drgnx-work-map--motion-p` is nil: a terminal, a frame Glitnir does not draw, a Nidhogg without the
layout leg (macOS for now), reduced motion (`glitnir--reduced-motion-p`, the desktop's setting through Glitnir, or
`drgnx-look-motion` `reduced`). There the new layout is drawn as before and nothing is said or counted. Live patches
never move the map (an agent arriving adds its card with no capture): only the hub's answer to a layout the user asked
for, while a capture waits, does. The teardown and a map buffer's
`kill-buffer-hook` call `drgnx-work-map-motion-clear`, which stops the timers and takes the parameters off every
window the map set them on (`drgnx-work-map--motion-windows`).

Tests: `test/ui/work-space-gui-test.el`, the rows `drgnx-work-gui/relayout-moves-with-motion` (dark and light, with
screenshots), `-no-ack-is-a-jump` (the text area moves after the capture, so the presenter drops it),
`-reduced-motion-sends-no-capture`, `-a-live-arrival-never-moves-the-map`, and the timing row
`-keys-stay-fast-during-a-leg` (40 keys before, during and after a 3 s leg: the leg's p95 within 8 ms, half a 60 Hz
frame, of the larger p95 without it; the GUI tier is a loaded machine with live patches landing in the keys'
redisplays, so the absolute key budget is the pinned island's, `harness/drgnx-perf-work.el`), on the 30-agent map of a real hub with
mock agents streaming (`test/fixtures/work-space-thirty-fixture.el`): all 30 below scale 2, the first four at scale
2, where 30 do not fit (that map is the outline, which never moves). They need Sjá, and the first two and the timing
row a Nidhogg with the layout leg. Unit: `drgnx-work-map-nav/motion-reads-the-card-rows`.
- Search is the model's: `drgnx-work-map-search` sets Sjá's search, which dims the non-matches on their spans.
- A conclusion that changes marks its card new for 4 s of the hub's clock (the hub's set, drawn in `drgnx-work-new`).

### The lens, and the Board

`drgnx-work-lens-map` is the keymap every Work view shares (the parent of the map's, the Board's and the Timeline's);
the movement and opening commands (`work-left` and so on), `work-view-map` and `work-view-board` are bound in it. They
act through `drgnx-work-lens-nav` (buffer-local): a view that is not the map sets it to a function of one direction, and
`drgnx-work-map--move` and its siblings call it first. The selection always lives in the map buffer
(`drgnx-work-lens--map` names it from the other views); `drgnx-work-lens-switch` carries it across.

`modules/tools/drgnx-work-board.el` is the Board, drawn only from the hub's rows. Beside a map that is a hub-fed view
`VIEW` it is the hub-fed view `VIEW/board` in the map's class: `drgnx-work-board-refresh` asks
`work/board/subscribe {view, map, plans}` (docs/develop/hub.md, "The Board") on the subscribed connection, as the map does
(`drgnx-work-client--call`: the hub sends a view's rows to the connection that asked and finds the map there), and the
hub sends its model and rows (the columns, three rows a card, the bar a row `spaces` entry) and reads it again after
each write. `drgnx-work-board-plans-for` is the design's table 8.2 from the map to the
Board, read from the map's model in Sjá: a plan scopes it to itself, a spec or an ask to the plans of the model's list
`plans` on its chain (class `chain`); anything else to every task (row
`drgnx-work-map-rows/the-board-is-scoped-by-the-models-plans`). Beside a map without Sjá the Board shows the map's
notice and asks for nothing; its old Lisp drawing went in plan sja-complete B2. Its keys
answer from its own model (`drgnx-work-board--nav`: the `board` form's links, `team` for the agent keys, the card's
`agent` field to open). Its selection is its own: it
neither follows the map's nor moves it, and switching back to the map selects nothing there (a decision of 2026-11-08:
the map's model holds no tracker tasks, so the Board is not an instance in the map's selection group).

### The Timeline and the trail

`modules/tools/drgnx-work-trail.el` holds both, and the steering commands. The hub builds both (`work::trail`): their
rows, and a model of their own in Sjá. A step's kind (`drgnx-work-trail-kind`) comes from its class and `detail.kind`,
never its prose.

- **A trail** is the hub-fed view `trail/SESSION` (`drgnx-work-trail-open`), with or without a map beside it; **the
  Timeline** of a map is `timeline/MAP-VIEW` (`drgnx-work-timeline-open`), whose lanes are the map model's agents of
  `team` with their `label`, so it needs its map on the hub's rows. Each is asked for with `work/trail/subscribe`
  (`{view, session}`; `{view, lanes}`), again after a reconnect (its env's RESUBSCRIBE), and ended with
  `work/trail/close` when its buffer goes. Without Sjá both show the map's notice and ask for nothing. The segments of
  the Timeline's lanes are in the faces `drgnx-work-seg-*` (`:inverse-video` over the stock colour faces, so a
  segment's colour is the face's foreground). A pause is in the trail as the hub saw it: the step `paused` at the time
  the turn ended paused (`agents/pause`, a Stop, the budget or the supervisor), and, once it ended, a note row
  `resumed` at that time (`vegvisir::trail::trail_rows`; no node); resume also says "Work: Resumed".
- **Conclusions** rest on steps (the model's chain kind `rests-on`): a selected conclusion lights the steps it rests on
  and a selected step the conclusions resting on it, in the class `chain`. `l` (`drgnx-work-trail-show-steps`, on a
  conclusion) moves point through the lit steps, cycling; `L` (`drgnx-work-trail-show-conclusions`, on a step) selects
  the first lit conclusion.
- **Opening a step** (`drgnx-work-trail-open-step`): a read opens the file at its lines (relative paths against the
  mirrored session's `cwd`; only a plain local file inside that folder, by its true name: `drgnx-work-code-local-file`);
  AS-READ calls `work/file-at {session path seq}` (the mode is chosen from the path with no file name handler); a search
  runs `project-find-regexp` again in the agent's folder (not when that folder is remote); a page `browse-url`; an edit
  shows `work/hunks` in `drgnx-work-hunk-mode`; a thought opens the agent's transcript (the step has no text of its own).
- **Keys** go through the replica (`drgnx-work-trail--rows-nav`): a move follows the selection's link of that name
  (`next-agent`/`previous-agent` are `down`/`up`; the trail ignores them), open reads the selected node's fields once
  (`drgnx-work-trail--model-step`: a step as `drgnx-work-trail-open-step` takes it; a conclusion's `n`,
  `conclusion-kind` and `label`). `drgnx-work-timeline-rows-attached` makes
  the Timeline's lit lanes the model's list `near` (in `drgnx-work-chain`); the hub sends that list again when the map's
  selection moves, and the queue's timer applies it and runs the class step (`drgnx-view-model--reclass`). Steering
  reads the selected step's `session`. A key past the trail's 500-step window (the model's `steps` list answers `more`)
  asks the hub for the window half a window further with `view/window` and runs when it comes (row
  `drgnx-work-trail-nav/a-long-trail-pages-at-its-edge`). Tests: `test/unit/work-trail-nav-test.el`, Rust
  `trail_model_windows_past_500`, `timeline_model_links_lanes`, `near_is_the_selections_agents`.
- **Steering** (`drgnx-work-trail-steer`, `-pause`, `-resume`, `-stop`) lives on the lens map and finds its agent per
  view (`drgnx-work-trail--agent-sid`): the trail's session, the Timeline's lane, the Board's card, the map's selection.
  Pause is `agents/pause`; resume is `agents/send` with `drgnx-work-resume-text`; stop asks `y-or-n-p` and is not
  bound to anything automatic.

### The review view and the second reviewer

`modules/tools/drgnx-work-review.el`. `drgnx-work-review-open` asks `work/conclusions`, then `decisions/effects` for each
decision (alist `drgnx-work-review--effects`), `work/files` and `work/hunks` for each file; every answer draws the view
again with `drgnx-work-review-install`. Row keys: `(:decisions)`, `(:decision N)` (origin order: from the brief, own,
needs you), `(:summary)` (the agent's card in the map's model: its fields `done` `steps` `edit_*` `reads`
`conclusion` `spend` `minutes`; row `drgnx-work-map-rows/the-review-summary-reads-the-agents-card`), `(:files)`, `(:file PATH)`, `(:hunk PATH I)`; `drgnx-work-review-parse-hunks` splits a
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
agent on the selection's chain (`drgnx-work-map-chain-agents`: the team's agents the model in Sjá classes `chain`), then
the root of the
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
`file:REPO/REL` when the map's model in Sjá holds it and echoes the agents. A file the map shows only as a count chip is
not given a node: the hub has no way to add one for a selection yet. The three take the selection and its chain's agents
from the model (`test/unit/work-map-rows-test.el`, `-files-and-diffs-take-the-selection`, `-who-is-here-selects-the-file`).

`work-diffs` (`d`, `drgnx-work-code-diffs`) asks `work/files {session}`, then `work/hunks {session, path}` for each file: the
hub's diff against the worktree's recorded base (the edit history's branch against its base). Each answer becomes a `drgnx-work-diff-mode` buffer, killed and made again each time. It
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
