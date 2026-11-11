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
