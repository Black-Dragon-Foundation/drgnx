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
evidence like any other; the next tick looks again. A hold is a `gate` card on the task (key `gates`) saying what is
wrong; a red-first wait with no run of the task's tests to repeat is a hold too.

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
