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

A job on this machine runs on its tree as it is while it runs, so at its end the hub reads the tree's key again: when
it moved since the submit (a commit while the job waited or ran, or a file changed and left uncommitted), the facts go
(`facts.moved.json`) and the job is no one's evidence and never reused (unit tests
`a_job_whose_tree_moved_under_it_keeps_no_facts`, `an_edit_left_uncommitted_while_a_job_ran_moves_its_tree`). A run's
own new files count as well: in a session's tree the agent may write files while the job runs, and the two can't be
told apart. So the move is shown: the job keeps its tree as read at submit (`snap.json`), and its end names the files
that changed (`moved`, the first five and how many more) in its result, "its tree moved while it ran (FILES): no facts
kept; a file a run writes belongs in .gitignore" (unit test `a_moved_job_names_the_files_that_changed`). A gate's run
whose tree moved is recorded as a run without a test result (its `(job)` row, class `error`) on its submit facts, with
that line as its note, so the gate holds at once with it instead of starting the same run again
(`orch::evidence::moved_run`; row `runner/a-gate-run-that-moves-its-tree-holds-and-names-the-files`). The
hub's own writes are no move: a sandboxed job's launch makes the missing protected files (`.envrc`, `mise.toml`, the
agents' folders) empty to pin them read-only, notes them in the job's folder (`stubs`) first, and removes them at the
job's end, before the key is read, when still empty and not in git (`sandbox::note_missing`, `remove_made`; unit test
`a_job_removes_the_stubs_its_launch_made`; scenario `runner/a-gate-run-keeps-the-agents-sandbox`). A runner's job ran on
the inputs frozen at its submit. A job outside a git tree, and a user's server, has no facts and is never evidence. `Runner::start_or_reuse` answers the
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

**A run without a test result** (its only failing row is `(job)`: a non-zero exit with no failing test is `error`,
out of time `timeout`, the machine's `infra`) is neither red nor green to any gate (`vordr::evidence::no_result`):
red first, the author check, the groups and the push gate read it as no run. A gate that would start that run again
(`vordr::evidence::no_rerun`) holds instead on an `error` (the same command on the same tree fails the same way): "CMD
failed without a test result (error): the first lines of its output"; an `infra` or `timeout` end it starts once more,
and holds after the second ("ran twice without a test result"). A run with failing tests and a `timeout` `(job)` row
is a red. Row `vordr::redfirst::a_run_that_failed_without_a_test_result_is_no_run_anywhere`.
`orch/evidence {task}` (the user's connections) answers a task's records, oldest first.

## The rule pack

A rule pack (`vordr::pack::Pack`, Emacs Lisp data read by huginn, never evaluated) names the gates a job meets and
their parameters: `:rules` (each `:id`, one of `red-first`, `author-check`, `trailers`, `rule-tests`,
`affected-groups`, `merge-notes`, `flake-hold`, `push-gate`, `review`, and `:kind`: `enforced` and `checked` gate the
merge, `routing` and `advice` don't), `:test-globs` (test files; `*` matches across `/`), `:compile-fail-reds` (the
languages whose build reds count when they name a symbol the task adds), `:batch-size`, the `:author-check`,
`:rule-tests` and `:push-tiers` commands (`(:name N :dir D :run (ARG …))`), `:groups` (the command that lists the
groups a range affects; `%r` is the range), `:no-cache`, `:shared-paths` (clean merges there still need intent
notes), `:context-share`, `:procedures` (`(:name N :path P :roles (ROLE …))`, P relative to the pack's file) and
`:models` (`(:role R :paths (GLOB …) :profiles (PROFILE …))`).

**Procedures.** A procedure is a short provider-neutral write-up (executing a plan, red first, debugging, merging by
intent). Its text is read beside the pack when the plan is proposed (at most 8 KiB; a missing file refuses the
proposal) and frozen with the pack. Every agent has the tool `procedure_get {name?}` (norn `tools::procedure`): the
job's procedure by name, or their names. A brief's Gates part names them and carries in full those whose `:roles` hold
the task's role. drgnx-default has none.

**Routing by role.** A task runs on the first profile its job's pack routes its role to; a route with `:paths` wins for a
task whose body names a matching path (a backticked word with a `/`). A plan line `**Profile:** NAME` (or a graph
plan's task profile) narrows that: one outside the role's profiles refuses the proposal. A role the pack doesn't route
runs on the settings' route (`drgnx-agents-routes`), as before; a reassignment (`job/reassign`) still wins.

drgnx ships `etc/orch/drgnx-default.eld`: red first, the author check and affected groups, with no project's
commands (any project's: its author check is the task's own tests at the tip). The push gate needs a project's own
tiers, so a project's pack turns it on; a pack whose push gate names no `:push-tiers` doesn't read. A plan names another with a `**Pack:** FILE` line (relative to the plan);
a pack that doesn't read, or names a rule or kind the hub doesn't know, refuses the proposal. The proposal carries
the pack, so the user approves it with the plan, and the approval records it as the job's `rule_pack` entity
(`norn::write::evidence::rule_pack`); the gates read that record, never the file again.

## The gates before a merge

Once the merge gate allows a task, before the `BeforeCommit` hooks, `orch::gates::before_merge` reads the job's rule
pack and the task's evidence and runs, in order, on the tip the merge gate checked (`RunGit::checked_tip`, never the
branch read again); the queue places that tip and the merge takes it only when it is still the checked one (unit test
`the_merge_takes_only_the_tip_the_gates_judged`):

- **Trailers** (`trailers` on): no commit in base..tip has a `Co-authored-by` line, a "Generated with …" line, or a
  `…-by:` trailer naming a model or its maker (`vordr::gates::trailers`).
- **Red first** (below).
- **The author check** (`author-check` on): each of the pack's `:author-check` commands and `:rule-tests` (the rule
  tests alone when only `rule-tests` is on) passed at the tip's tree; its run is the newest job at the tip's tree key
  with the command's selector, made with this machine's env stamp and platform now (`vordr::gates::current`: an old
  green after a toolchain bump, or a runner's, is no run; unit test `only_runs_with_this_machines_stamp_and_platform_count`).

A run a gate needs that the hub can make, it starts through the queue and waits for (`orch::gates::Runs`): an author
check at the tip; for red first, the task's own test command (the newest job the task ran inside its tree: its folder,
command and image, and the test selector variables its selector names, so the rerun's selector is the job's:
`vordr::facts::selector_env`) at the test commit, or the red's command at the tip. Each runs in a detached worktree of
its commit beside the task's tree (uncommitted files in the task's tree are never part of it), which goes when the job
ends. A run is claimed in the same step as the check that none is in flight (`Runs::claim`), so two gates asking at
once (two pushes) start it once (unit test `a_run_is_claimed_once_until_it_ends`). The watcher that settles them
settles every ended run again when it falls behind the job events (`Runs::take_ended`).

**The hub's log** says what the gates decide of each task's merge, an info line each time it changes ("the gates
wait: …", "the gates hold the merge: …", "the gates pass the merge: …"; a failure to judge is a warning), and of
each run they start: "the gate runs CMD at COMMIT" with its job and tree (a start refused: a warning naming why),
then "the gate's run ended: red|green", or a warning when it ended as no evidence and why (`orch::evidence::settle`).

**Runs the gates start** are an agent's command, or the pack's over the tree an agent wrote, so they run as an agent's
job does, as a **sealed job** (`exec::start_sealed`, starter `Starter::Sealed`): in the session's launch shape, on
this machine, with the detached tree the only folder they can write, the network a session's job has (the provider
proxy, nothing else) and an agent's package rule; never with the user's environment. Its label is `sealed-gate-` and
the tree's folder name; a sealed job names no session in its meta, queue record or events, so it wakes no agent and
asks no matrix cell (the gate's run is the hub's decision). Other hub runs of untrusted commands (a bisect's
predicate) use the same starter. Unit test `a_sealed_job_names_no_session_and_stays_sealed_in_the_queue`. Row `runner/a-gate-run-keeps-the-agents-sandbox`. The job's end is the task's
evidence like any other; the next tick looks again. A hold is a `gate` card on the task (key `gates`, `tip` its tree
key) saying what is wrong; a red-first wait with no run of the task's tests to repeat is a hold too, but not while a
run in the task's tree has no result yet (a session's `exec/start` on its way, `exec::Runner::busy_in_tree`, which
looks the tree up by its true name as the jobs' folders are recorded, so a tree named through a link (macOS's `/var`
is `/private/var`) still matches; a job there
queued or running, or one that ended whose end the evidence watcher has not recorded yet, so a tick between a run's
end and its evidence never holds): red first then waits, and the next tick judges it with that run (a start that answered later
than the review came, as on the macOS lane; row `runner/a-gate-waits-for-a-run-still-starting`, whose hub answers
`exec/start` 30 s late with the test hook `RATATOSKR_TEST_EXEC_START_DELAY_MS`). Its actions:
**Check again**, **Tell the agent** (the task goes back to its agent with the card's words), **Waive once…** (with a
reason) and **Drop the task**.

**Waivers are the user's alone.** A waiver is `waiver` evidence (id `waiver:…`) at the tip's tree key, with its
reason; it passes red first and the author check for that tip only (a new tip needs a new waiver), never the
trailers. Like the matrix's `always_never`, this is a hard rule below every grant: the store's guard for kind
`evidence` (`norn::write::evidence::register`) takes a `waiver:` record only from the user's connection and every
other record only from the hub, so no cell, preset, manager grant or agent tool can write one. The same guard keeps
the other records the gates read from agents: a job's `rule_pack` is written with the user's approval or by the hub,
a `followup` by the hub (the user closes it) (unit test `no_agent_writes_a_rule_pack_or_a_followup`).

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
one at a time in readiness order, each `--no-ff`. A batch forms outside the queue's lock (its conflict check is git
per pair; unit test `a_batch_forms_without_holding_the_queues_lock`). A member whose merge onto the line would cleanly join shared files
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
  = `HEAD..COMBINED` (its `test/affected.eld`, never the batch's); listed once per tree. It runs as a gate run (an
  agent's sandbox, on this machine) in a time box of 300 s, its output to `.drgnx-groups.json` in that tree; the gate
  waits while it runs. A listing without groups is never red: a timeout or the machine's end (`timeout`, `infra`)
  lists once more and holds the second time; a non-zero exit or output that isn't the JSON (`error`) holds at once,
  with the run's first log lines. The user may waive the hold. Unit test
  `the_groups_listing_is_a_time_boxed_run_whose_timeout_is_no_red`.
- **Each group** runs at the combined commit as a gate run (a detached worktree that goes when the job ends); its end
  is evidence of `batch:JOB@TREE`.
- **Green:** every group's newest run at the tree (made with this machine's env stamp and platform now) passed, or failed only rows the base's `test/frozen.eld` lists.
  Any other red goes to the reruns (next section).

## Reruns, interaction reds, flakes

When a batch's groups are red, the red groups run again in parallel, once (never a bisection), at the line's HEAD
and at each member's tip merged alone onto it (`orch::groups`, judged by `vordr::reruns::verdict`). Each run is
evidence of `batch:JOB@TREE` for its own tree. A one-member batch's tip alone is the batch's own tree, so there its
red groups run once more (`vordr::gates::state_after` with two runs): a pass then is a flake (below: a hold, a
`followup` and the card), a second fail is the tip's red, so the tip goes back. The gate waits until every rerun is
in; then:

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
until each of the pack's `:push-tiers` has a green run on the tree of each commit the push sends, with the env stamp
the hub has now, on Linux (`vordr::push::judge`, `orch::push`). Runs on another tree, env stamp or platform never
count. The gate reads the command (`orch::push::parse`): `git` and its global options (`-C DIR`, `-c K=V`,
`--no-pager`, …), each push in a list of commands (`;`, `&&`, `|`), and the source of each refspec (`+SRC:DST`; none
named: `HEAD`). A command it can't read is refused, never let by: a shell or another program around the push (`sh -c`,
`env`, `xargs`), a substitution or quote, another repository (`--git-dir`), every branch at once (`--all`,
`--mirror`, `--tags`). The refusal names each ref with its commit and the missing tiers, which start through the
queue as evidence of `push:JOB@TREE`, or the red tiers with their rows; the agent asks again once they are green. A
job (`exec/start`, `job_start`) of a session, or a sealed job, never pushes: its start is refused (row
`exec/an-agent-job-never-pushes`). Unit tests `a_push_is_read_with_its_global_options_and_the_refs_it_sends`,
`the_refusal_names_the_refs_it_judged`. A push the gate lets through still meets the
matrix, so the push itself stays the user's. A pack whose push gate names no tiers doesn't read, and the gate refuses
every push of a job recorded with one.

## Red first

`vordr::redfirst::decide` over the task's commits base..tip (`orch::red_first::inputs`):

1. The **test commit** is the first commit. It may touch any file: an inline `#[cfg(test)] mod tests` is fine.
2. A hub job at the test commit's tree (its tree key) failed rows of class `assert`. A `build` row counts only when
   the pack's `:compile-fail-reds` has its language (cargo's `build` rows are Rust, an ERT row Emacs Lisp) and it
   names a symbol the task's non-test change adds (an item or field of a Rust file above its `#[cfg(test)]`, an Emacs
   Lisp definition). A `timeout`, `error` or `infra` row is not a red, and a run with no other failing row is no run
   ("Evidence"). A test commit whose tests pass at it (the implementation came with them) is held.
3. A job with the same selector and env stamp at the tip passed the same rows (for a build red: failed none).
4. The test commit's test lines (a test path's added lines, a Rust file's below its `#[cfg(test)]`) are still at the
   tip: a deleted one that isn't added back holds the task.

Any hub job counts (the evidence records, "Evidence"). A task whose body, as the user approved it, has a line
`**Red:** none (reason)` passes on it; the reason is required. A job approved without a rule pack, or one whose pack
doesn't name `red-first`, passes.

## Advice before the gate

An agent whose provider has a `before-tool` hook (our ACP forks' `_drgnx/before_tool`; Codex's managed hook, offered
when the session's hooks subscribe, which fails open on a timeout) gets a soft deny when it commits in its task's tree
while the task has no red evidence and the commit changes code: tracked changes against `HEAD` outside the pack's
test globs, under a pack that gates on `red-first` (`orch::advice`). The deny's words say the merge will hold it and to
commit and run the failing tests first; a commit of tests alone, a task with a red, or a pack without the rule pass.
It runs before the hooks, and anything it can't read lets the step through. The advised commit counts toward no
`repeat` in that turn, nor do its retries (`State::call_advised`): trying it again once the red is in is not a loop.
It is advice that saves wasted work: the
gate at the merge is the same for every provider, and a provider without hooks meets it there.

## Policy from the base

The gates' policy files, `test/affected.eld`, `test/frozen.eld` and `test/flaky.eld` (`vordr::pack::POLICY_PATHS`),
are read at the line's base commit (`orch::policy::Policy::at`), never at the tip: a tip can't change the rules it is
judged by. A tip that edits one is a `code.ci-config` change at its merge (`runner::git`), so the user answers it.

## The Flow lens

`work/flow/subscribe {view, map, job?}` opens the Work space's fourth lens view (`modules/tools/drgnx-work-flow.el`;
`F` from any lens view). It is a hub-fed view like the Board (`work::trail`): the hub reads the job (the named one,
else the newest running job), its tasks and their evidence, its rule pack, its merge queue (ready and batch) and its
open `gate` cards, and builds the model and the rows (`work::trail::flow`, pure):

- the run's line: its title, the plan run, the job and its pack, then chips: how many agents it runs at once ("one
  agent", with "· in order" when the user ordered its tasks), the tasks done, and its base (short). The job's first
  task start records `agents` and `base` in the job's data (`runner::tick::run_facts`; the base is that task's tree's);
  before then the run shows neither;
- a row per task, a column per gate: Brief, Red first, Build, Author check, Merge batch, Review, each heading with its
  Lucide icon. Each cell is a chip in its state's face (`drgnx-work-flow-chip-ok` passed, `-run` running, `-held`
  held, with a lock, `-err` failed, `-wait` waiting; drgnx-work-flow.el, the UI font over the theme's chips; under
  drgnx's themes, where boxes take Nidhogg's `:fit text`, a pill as the mockup's `.g`: padded 6 by 3 px in its own
  colour, fully rounded and as tall as its text, the fill confined to it on the 30 px rows), an empty
  ring where a gate has nothing yet, and the label face where the pack has no such gate or a gate waits on another
  ("waits red"). Red first is the oldest red run's failing rows ("N failed · base"; "no red · held" at review
  without one), Build the newest run, the author check its checks green at their newest runs (a check when all are),
  the merge column the queue's place or the open `gate` card's words, Review "at plan end" when the pack has a
  `review` rule that gates or routes (an `advice` one shows none). Text is in `drgnx-work-flow-text` (the caption
  role, the mockup's 12 px table), ids and agents in `-label`, headings in `-heading`, the chips a twelfth smaller
  (11 px). A task's row lights under the pointer (`mouse-face` `drgnx-hover`);
- the columns fit the window, titles before chips: each gate column wants its widest cell or heading in the table's
  font (the hub measures with the env's `caption` role), the agent's is its widest agent, and the task column wants its widest
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
  `drgnx-work-flow-card`. A machine's line names each check in the code face (`drgnx-work-flow-code`) with its tick
  after it; a member's line has its tip in the code face and what the queue said to it right-aligned; the batch ends
  with what a red does (each tip reruns alone). The rings and the rows' rules are Glitnir blocks (Nidhogg's `glitnir-blocks`): the hub
  marks them on the rows with the text property `drgnx-work-flow-block` (`["ring" ID X0 X1]` on a card's span of each
  of its rows, `["rule" KEY X0 X1]` on the headings and each task row, device px; on a GUI the column heads are 24
  logical px high and each task row 30, as in the mockup, by a 1 px space that high first on the row), and drgnx-work-flow.el turns the
  marks into the window parameter after each patch, only when they changed (ring radius 8 in `drgnx-border` over
  `default`, rules in `drgnx-border-subtle`; faces, so a theme change recolours them). The selected task's row (the
  row `task:ID`, not its chip in the strip) gets the mockup's accent, a `bar` block 2 logical px wide at its left edge
  in `drgnx-focus-line`, redrawn when a key moves the selection. A killed Flow takes its
  blocks off every window;
- the model: a `task` node per task with the `flow` form's links up and down and the gates' states as fields, the
  lists `tasks` and `held` (the needs-you chips; `Tab` walks them).

A held task is also a needs-you chip on the strip, the first row, above the run's line ("⚑ T5 held: …", carrying the task's id), and
its row carries its `gate` card's id (`drgnx-work-card`).

`e` asks `orch/evidence` for the selected task and lists each record (kind, job, tree, command, its failing rows or
its pass count, a waiver's reason). The view is read again after every write.

**The Rules tile.** `R` opens the run's rule pack in the bottom panel (pane kind `work-rules`): the Flow's `VIEW/rules`
subscribed with `rules: true`, rows alone. A row per rule: its words, its kind as a chip (enforced in the ok face with
a lock, checked and routing in the accent) and how the hub holds it. With `detail: TASK` too it ends in an "Evidence · TASK" tab
(the task's label), the selected task's evidence; the Flow subscribes it again when its selection moves. Both tiles
title themselves (the detail tile's first row is "Detail · TASK" after the panel icon), so their buffers set
`drgnx-area-own-title` and the area draws no tab row over them, however the tile reaches the window (the Flow
puts it in an area's window with `drgnx-wb-area-put-buffer`, which redraws the row for the buffer). `R` shows the Flow's own tile, even
where layout Work opened the pane's placeholder first. The detail head's agent is the map's agent on the task: its
card's task, else its session's own (a run's tasks are the job's, which no plan on the map holds); a map opened gets
the clock's minute at once, so the agent's minutes are right from the first draw. A long task title is cut before
the time, spend and context.

**The detail tile.** `work/flow/subscribe` with `detail: TASK` makes its view (the Flow's `VIEW/detail`) that task's
detail tile: rows alone, no model, read again after every write like the Flow. The Flow subscribes it again each
time its selection moves (`drgnx-view-selected-functions`, the Flow's own). Its head is the agent: an avatar (a 16
px circle in the agent's colour, `agent-N` of the env's palette by its place among the run's agents, its initial cut
out) and its name in bold (`drgnx-work-flow-agent`): the map's model, then the agent's own label on the map (its
session, "Sonnet · search-quick"), the held chip at the right; under it the task and the map's minutes, spend and
context of the agent ("41 min · ≈$0.90 · ctx 88%"), or the task's status when the map has no agent on it (`-label`). Its section heads are muted and semibold (`drgnx-work-flow-section`), its text `-detail-text` (the
mockup's 12.5 px). It goes on: for a held task why it is held (the card's words and each held gate) and what clears it; the commits the merge
checks (base .. tip, then each commit with its short sha, `tests` for red first's test commit or `code`, and its
subject: the job data's `commits`, which `orch::gates::before_merge` records each time it looks, and `bases`); the
evidence so far as a table, a label column (`brief`, `tests`, `green`, `red`, then any `waiver`) and each newest
record's job, machine and counts, "none recorded" in the attention face where there is none; and the actions as buttons (`drgnx-work-flow-button`, the controls' ring; the first `drgnx-work-flow-button-primary`,
filled; where boxes fit their text, padded 4 px above and below it, `:fit (text . 4)`, else text-height), each with
its key as a keycap inside it after a gap (`drgnx-work-flow-button-key`, the primary's `drgnx-work-flow-key-primary`: on
the button's background, padded by a space each side and 2 px above and below). On a graphical frame the tile draws
each key as a keycap image in that face's font and ring (`drgnx-work-flow--keycaps`, after every patch) and gives its
text the button's face, so the button's ring runs around the key as one box; a key with its own face box broke the
ring in two. Each row of buttons is 30 logical px
high (the mockup's 24 px buttons, 6 px apart), so a button's box has room for its pad. `r` (**Run the red** for a red-first hold, else **Check again**:
the card's `merge`), `s` (**Tell the agent**: `retry`) and `w` (**Waive once**: `waive`, asking for the reason) answer
the card with `job/card` as the user; the hub takes the waiver only from the user's connection. The tile shows in the
right dock where the map's side panel was, and the panel comes back when the lens leaves the Flow.
