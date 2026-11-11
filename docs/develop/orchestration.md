# Orchestration in the hub

The hub enforces a project's working rules (red first, an author check, affected groups before a merge, a full run
before a push) as gates on the plan runner, on facts it recorded itself: the jobs it ran, the trees it hashed and the
rows it parsed. An agent's report is never evidence, and a gate reads its policy from the line's base, never from the
tip it judges.

The pure parts live in the `vordr` crate (no I/O, `serde` only); the hub's side is in `drgnx-ratatoskr`.

## Rows and failure classes

Every job the hub runs keeps its rows in `result.json` (`docs/develop/hub.md`, "Jobs"): `vordr::rows` reads cargo test,
ERT and domr lines from the whole log, whatever the job's kind, as `{name, verdict, class?, symbols?}`:

| Class | Means | Read from |
|---|---|---|
| `assert` | an assertion or a panic in the test | `test X ... FAILED`; an ERT `(ert-test-failed …)` condition; domr `FAIL` |
| `build` | the test didn't build; `symbols` names what the errors say is missing | rustc's `error[E0425]`-style errors and `could not compile`; ERT `(void-function S)` / `(void-variable S)`; `FAILED  load FILE` |
| `error` | any other error | another ERT condition; a job that failed with no failing row |
| `timeout` | the job ran out of time | the job's end |
| `infra` | the machine, not the test | a lost job, an `infra` end |

The job's own row is named `(job)`. A name seen twice keeps its worst verdict.

## Facts and the green cache

At submit the hub records what a job runs on in its folder's `facts.json` (`vordr::facts::Facts`, `exec::facts_of`):

- **tree key:** the commit's tree id from the hardened capture (`sleipnir::sync::capture`: no hook, fsmonitor or outside
  config runs), plus `+` and the first 16 hex digits of the overlay's input key when anything is uncommitted;
- **env stamp:** this machine's `emacs`, `rustc` and `cargo` `--version` lines (as `core/drgnx-affected.el`'s stamp),
  with a container job's image; a job a runner took reads `runner NAME`;
- **platform:** `OS-ARCH/local`, or `runner/NAME`;
- **selector:** the folder relative to the tree's top, the command, and `DRGNX_TEST_SELECTOR` / `DRGNX_TEST_ONLY` when
  the job sets them.

A job outside a git tree, and a user's server, has no facts and is never evidence. `Runner::start_or_reuse` answers the
newest **green** job with equal facts instead of running again (exit 0, no failed row, not on a `shared` runner); a red
is never reused, and a selector holding one of the rule pack's `no-cache` words (`Runner::set_no_cache`) always runs.

## Evidence

An `evidence` entity (`norn::write::evidence`, its data a `vordr::evidence::Evidence`) is one fact a gate reads: its
kind, the task, the hub job, the job's facts, its rows (at most 5000, every failed row kept; `truncated` says rows were
left out), when, and a gate's note. Kinds: `red` and `green` (a task's own job as it ended: failed rows or a non-zero
exit, or none), and the gates' own `author-check`, `group`, `full-run`, `review`, `merge-notes` and `waiver`.

The hub task `orch::evidence::run` records every job that ends whose session works on a task (the session's
snapshot names it) as that task's `red` or `green`. A job without facts, or one a `shared` runner ran, is never
evidence. Any matching job counts: a gate never asks for a second run of a tree it has a record for.
`orch/evidence {task}` (the user's connections) answers a task's records, oldest first.

## The rule pack

A rule pack (`vordr::pack::Pack`, Emacs Lisp data read by huginn, never evaluated) names the gates a job meets and
their parameters: `:rules` (each `:id`, one of `red-first`, `author-check`, `trailers`, `rule-tests`,
`affected-groups`, `merge-notes`, `flake-hold`, `push-gate`, `review`, and `:kind`: `enforced` and `checked` gate the
merge, `routing` and `advice` don't), `:test-globs` (test files; `*` matches across `/`), `:compile-fail-reds` (the
languages whose build reds count when they name a symbol the task adds), `:batch-size`, the `:author-check`,
`:rule-tests` and `:push-tiers` commands (`(:name N :dir D :run (ARG …))`), `:groups` (the command that lists the
groups a range affects; `%r` is the range), `:no-cache`, `:shared-paths` (clean merges there still need intent
notes) and `:context-share`.

drgnx ships `etc/orch/drgnx-default.eld`: red first, the author check and affected groups, with no project's
commands (any project's: its author check is the task's own tests at the tip). The push gate needs a project's own
tiers, so a project's pack turns it on; a pack whose push gate names no `:push-tiers` doesn't read. A plan names another with a `**Pack:** FILE` line (relative to the plan);
a pack that doesn't read, or names a rule or kind the hub doesn't know, refuses the proposal. The proposal carries
the pack, so the user approves it with the plan, and the approval records it as the job's `rule_pack` entity
(`norn::write::evidence::rule_pack`); the gates read that record, never the file again.

## The gates before a merge

Once the merge gate allows a task, before the `BeforeCommit` hooks, `orch::gates::before_merge` reads the job's rule
pack and the task's evidence and runs, in order:

- **Trailers** (`trailers` on): no commit in base..tip has a `Co-authored-by` line, a "Generated with …" line, or a
  `…-by:` trailer naming a model or its maker (`vordr::gates::trailers`).
- **Red first** (below).
- **The author check** (`author-check` on): each of the pack's `:author-check` commands and `:rule-tests` (the rule
  tests alone when only `rule-tests` is on) passed at the tip's tree; its run is the newest job at the tip's tree key
  with the command's selector (`vordr::gates::state`).

A run a gate needs that the hub can make, it starts through the queue as the user's job and waits for
(`orch::gates::Runs`): an author check at the tip; for red first, the task's own test command (the newest job the
task ran inside its tree: its folder, command and image) at the test commit, or the red's command at the tip. Each
runs in a detached worktree of its commit beside the task's tree (uncommitted files in the task's tree are never part
of it), which goes when the job ends. The job's end is the task's
evidence like any other; the next tick looks again. A hold is a `gate` card on the task (key `gates`, `tip` its tree
key) saying what is wrong; a red-first wait with no run of the task's tests to repeat is a hold too. Its actions:
**Check again**, **Tell the agent** (the task goes back to its agent with the card's words), **Waive once…** (with a
reason) and **Drop the task**.

**Waivers are the user's alone.** A waiver is `waiver` evidence (id `waiver:…`) at the tip's tree key, with its
reason; it passes red first and the author check for that tip only (a new tip needs a new waiver), never the
trailers. Like the matrix's `always_never`, this is a hard rule below every grant: the store's guard for kind
`evidence` (`norn::write::evidence::register`) takes a `waiver:` record only from the user's connection and every
other record only from the hub, so no cell, preset, manager grant or agent tool can write one.

**`gate-wait`.** While a task has a gate's run in flight (`Runs::waiting`) the supervisor's `silent` and `lease`
rules don't hold for its session: the hub is working, not the agent. (The gates run while the task is `in-review`,
which the lease reaper leaves alone, so nothing needs renewing.)

**Context rotation for workflow tasks.** A task whose job has a rule pack rotates its agent past the pack's
`:context-share` tokens (the supervisor's `context` rule; 120 000 in `drgnx-default`, 0 turns it off): the same
path as a manager's rotation (when its turn ends, a fresh session in the same worktree), told its task's brief and to
read the tree's log and status first.

## Merge notes

With `merge-notes` on (the org's pack), every two-parent merge in a task's base..tip is resolved by both sides'
intent and says so. For a merge of the line (theirs) into the task's branch (ours), `orch::notes` diffs both sides
from their merge base and needs a note for:

- each **hunk both sides changed**, as `PATH:FIRST-LAST` in the base's lines (ranges that overlap or touch, joined:
  git conflicts on neighbouring lines too; `vordr::notes::conflicts`);
- each **shared file** (the pack's `:shared-paths`) both sides changed apart, as `PATH`: a clean merge there is
  still audited.

A note is a line of the merge commit's message:

```text
Merge-note: core/x.el:12-18 ours=1a2b3c4 theirs=5d6e7f8 resolution=both | the new key and the renamed one both stay
```

`resolution` is `ours`, `theirs`, `both` or `new`; the reason after `|` is required. Each cited commit (7 characters
or more) must have touched its hunk on its side: `git log -L FIRST,LAST:PATH base..side` over the hunk's lines on that
side, or `git log base..side -- PATH` for a shared file. A merge with a hunk uncovered, a citation that didn't touch it
or a note without a reason holds the task's merge (a `gate` card naming each); like the trailers, no waiver passes it.

## The merge queue

A task whose gates passed is **ready** (`orch::queue`, in memory: after a restart tasks are ready again as their
gates pass again). The next **batch** is the earliest ready tasks, up to the pack's `:batch-size`, leaving out a task
whose tip conflicts with an earlier member's (`git merge-tree`): it waits for the next batch, after the earlier one
merged. A batch stays until its members merged or left the job's review (dropped, sent back, a card); members merge
one at a time in readiness order, each `--no-ff`. A member whose merge onto the line would cleanly join shared files
both sides changed since they parted goes back to its agent, told to merge the line in with a note per file. A job
with no rule pack merges as before, each task as it passes.

## Affected groups

With `affected-groups` on and a `:groups` command in the pack (`drgnx-org`: `bin/drgnx test --affected %r --json`;
`drgnx-default` names none, so it runs no groups), the batch's first member merges only when the batch's groups are
green (`orch::groups`, `vordr::groups`):

- **The combined commit:** the line's HEAD with each member's tip merged in order (`git merge-tree`, `git
  commit-tree`: no worktree, no ref moves). Its tree key is the batch's: the same members in any order give the same
  tree, and so do the later members once the first merged, so their turn reuses the runs.
- **The groups** come from the base's own tool: the command runs in a detached worktree of the line's HEAD with `%r`
  = `HEAD..COMBINED` (its `test/affected.eld`, never the batch's); listed once per tree.
- **Each group** runs at the combined commit through the queue as the user's job (a detached worktree that goes when
  the job ends); its end is evidence of `batch:JOB@TREE`.
- **Green:** every group's newest run at the tree passed, or failed only rows the base's `test/frozen.eld` lists.
  Any other red goes to the reruns (next section).

## Reruns, interaction reds, flakes

When a batch's groups are red, the red groups run again in parallel, once (never a bisection), at the line's HEAD
and at each member's tip merged alone onto it (`orch::groups`, judged by `vordr::reruns::verdict`). Each run is
evidence of `batch:JOB@TREE` for its own tree. The gate waits until every rerun is in; then:

- **The line itself is red:** no tip is blamed. The batch is held on a `gate` card and a `followup` entity (one open
  per title) records the line's failing rows.
- **Some tips are red alone:** exactly those go back to their agents, with the rows; the others form the next batch.
- **Every tip is green alone:** an interaction red. The later tip in readiness order goes back, told which tips it
  fails together with; it merges the line once they are in.

A **flake** is a row that failed in one run and passed in a later run of the same selector on the same tree, env stamp
and platform (`vordr::gates::flaky`). Under a pack with `flake-hold` on, it holds the batch on a `gate` card and opens a `followup`; flakes are fixed at
the cause, never listed. A held batch's card offers `Waive once…`, which the gate honours for that tree.

## The push gate

Under a pack with `push-gate` on, a job's agent asking to push (the matrix's `push.ci` or `push.main`) is refused
until each of the pack's `:push-tiers` has a green run on the exact commit's tree (the agent's `HEAD`) with the env
stamp the hub has now, on Linux (`vordr::push::judge`, `orch::push`). Runs on another tree, env stamp or platform
never count. The refusal names the missing tiers, which start through the queue as evidence of `push:JOB@TREE`, or the
red tiers with their rows; the agent asks again once they are green. A push the gate lets through still meets the
matrix, so the push itself stays the user's. A pack whose push gate names no tiers doesn't read, and the gate refuses
every push of a job recorded with one.

## Red first

`vordr::redfirst::decide` over the task's commits base..tip (`orch::red_first::inputs`):

1. The **test commit** is the first commit. It may touch any file: an inline `#[cfg(test)] mod tests` is fine.
2. A hub job at the test commit's tree (its tree key) failed rows of class `assert`. A `build` row counts only when
   the pack's `:compile-fail-reds` has its language (cargo's `build` rows are Rust, an ERT row Emacs Lisp) and it
   names a symbol the task's non-test change adds (an item or field of a Rust file above its `#[cfg(test)]`, an Emacs
   Lisp definition). A `timeout`, `error` or `infra` row is not a red. A test commit whose tests pass at it (the
   implementation came with them) is held.
3. A job with the same selector and env stamp at the tip passed the same rows (for a build red: failed none).
4. The test commit's test lines (a test path's added lines, a Rust file's below its `#[cfg(test)]`) are still at the
   tip: a deleted one that isn't added back holds the task.

Any hub job counts (the evidence records, "Evidence"). A task whose body, as the user approved it, has a line
`**Red:** none (reason)` passes on it; the reason is required. A job approved without a rule pack, or one whose pack
doesn't name `red-first`, passes.

## Policy from the base

The gates' policy files, `test/affected.eld`, `test/frozen.eld` and `test/flaky.eld` (`vordr::pack::POLICY_PATHS`),
are read at the line's base commit (`orch::policy::Policy::at`), never at the tip: a tip can't change the rules it is
judged by. A tip that edits one is a `code.ci-config` change at its merge (`runner::git`), so the user answers it.

## The Flow lens

`work/flow/subscribe {view, map, job?}` opens the Work space's fourth lens view (`modules/tools/drgnx-work-flow.el`;
`F` from any lens view). It is a hub-fed view like the Board (`work::trail`): the hub reads the job (the named one,
else the newest running job), its tasks and their evidence, its rule pack, its merge queue (ready and batch) and its
open `gate` cards, and builds the model and the rows (`work::trail::flow`, pure):

- a row per task, a column per gate: Brief, Red first, Build, Author check, Merge batch, Review, each heading with its
  Lucide icon. Each cell is a chip in its state's face (`drgnx-work-flow-chip-ok` passed, `-run` running, `-held`
  held, with a lock, `-err` failed, `-wait` waiting; drgnx-work-flow.el, the UI font over the theme's chips), an empty
  ring where a gate has nothing yet, and the label face where the pack has no such gate or a gate waits on another
  ("waits red"). Red first is the oldest red run's failing rows ("N failed · base"; "no red · held" at review
  without one), Build the newest run, the author check its checks green at their newest runs (a check when all are),
  the merge column the queue's place or the open `gate` card's words. Text is in `drgnx-work-flow-text`, ids and
  agents in `-label`, headings in `-heading`;
- the columns fit the window, titles before chips: each gate column wants its widest cell or heading in the UI font
  (the hub measures with the env's fonts), the agent's is its widest agent, and the task column wants its widest
  title, up to a third of the window. When both don't fit, the widest gate columns give way first (their cells and
  headings cut with an ellipsis, down to 44 px a column), and only then the titles (down to 96 px);
- under them the batch being checked: its heading with an "affected groups g/n" chip (the groups the groups gate
  listed at the combined tree, green of them, red in the error face), a row per member (its title, its tip, what the
  queue said to it last: "trial merge clean", or why it waits, the job's tasks named by their labels; then what the
  merge-notes check found on it, for a pack with shared paths: "shared paths audited" or "N hunks by intent · notes")
  and a row per machine with each group's tick or cross;
- the line gate, when the pack runs the push gate: its heading with the tiers' chip at the tree the push gate judged
  last ("green on …", "g/n at …", "N red at …"; "no push asked yet" before one), a row per machine, and the note that
  the push stays the user's. The queue keeps what it said and the trees its gates judged in memory (`orch::queue`,
  `Seen`), so after a restart they show again once the gates run again;
- the two cards side by side on shared rows (`cards:N`), the batch on the left half and the line gate on the right
  (the batch's across the table without a push gate), each row of a card filled to its edge in
  `drgnx-work-flow-card`. The rings and the rows' rules are Glitnir blocks (Nidhogg's `glitnir-blocks`): the hub
  marks them on the rows with the text property `drgnx-work-flow-block` (`["ring" ID X0 X1]` on a card's span of each
  of its rows, `["rule" KEY X0 X1]` on the headings and each task row, device px), and drgnx-work-flow.el turns the
  marks into the window parameter after each patch, only when they changed (ring radius 8 in `drgnx-border` over
  `default`, rules in `drgnx-border-subtle`; faces, so a theme change recolours them). A killed Flow takes its
  blocks off every window;
- the model: a `task` node per task with the `flow` form's links up and down and the gates' states as fields, the
  lists `tasks` and `held` (the needs-you chips; `Tab` walks them).

A held task is also a needs-you chip on the row under the run's line ("⚑ T5 held: …", carrying the task's id), and
its row carries its `gate` card's id (`drgnx-work-card`).

`e` asks `orch/evidence` for the selected task and lists each record (kind, job, tree, command, its failing rows or
its pass count, a waiver's reason). The view is read again after every write.

**The Rules tile.** `R` opens the run's rule pack in the bottom panel (pane kind `work-rules`): the Flow's `VIEW/rules`
subscribed with `rules: true`, rows alone. A row per rule: its words, its kind as a chip (enforced in the ok face with
a lock, checked and routing in the accent) and how the hub holds it.

**The detail tile.** `work/flow/subscribe` with `detail: TASK` makes its view (the Flow's `VIEW/detail`) that task's
detail tile: rows alone, no model, read again after every write like the Flow. The Flow subscribes it again each
time its selection moves (`drgnx-view-selected-functions`, the Flow's own). It says what the task is and who works on
it; for a held task why it is held (the card's words and each held gate) and what clears it; the evidence so far, one
line per record; and the actions with their keys. `r` (**Run the red** for a red-first hold, else **Check again**:
the card's `merge`), `s` (**Tell the agent**: `retry`) and `w` (**Waive once**: `waive`, asking for the reason) answer
the card with `job/card` as the user; the hub takes the waiver only from the user's connection. The tile shows in the
right dock where the map's side panel was, and the panel comes back when the lens leaves the Flow.
