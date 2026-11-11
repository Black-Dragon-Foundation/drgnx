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

drgnx ships `etc/orch/drgnx-default.eld`: red first, the author check, affected groups and the push gate, with no
project's commands (any project's: its author check is the task's own tests at the tip). A plan names another with a `**Pack:** FILE` line (relative to the plan);
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
  Any other red holds the batch: a `gate` card on its first member (key `groups`, `tip` the combined tree), whose
  `Waive once…` the gate honours for that tree.

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
