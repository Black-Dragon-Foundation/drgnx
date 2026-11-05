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

### The 30-agent fixture

`test/fixtures/work-space/thirty.json` is one description of a busy workspace: 6 asks, 3 specs, 4 plans with their
tasks, 26 sessions and 4 subagents, 30 branches over three repositories (26 agents' branches and 4 bases), 120 edited
files with three shared ones, an untracked empty file, two subagents editing one file, three machines (one reported
by `machines/report`), four cards (one a clash). `test/fixtures/work-space/prototype.json` is the brainstorm
prototype's own data. `vegvisir::fixture::thirty()` and `prototype()` (feature `fixture`, tests only) turn a
description into the events a hub would feed.
