# Work tracker

Where did this plan come from, how far is it, and which commits did it? The work tracker answers that across
every project drgnx knows: **spec › plan › task › step / TODO › commit**, with the branch and worktree each plan
is built on. It reads what is already there (spec and plan files, execution ledgers, the board) and records the
commits of the work drgnx starts. Commit messages are never changed.

## What it reads

`drgnx work scan [DIR…]` (no DIR: the roots in `projects.eld` and `drgnx-work-roots`) walks each root seven levels
down (not into `.git`, `node_modules`, `eln-cache`, `elpa`, `target`, `dist`, `build`, `.claude/tmp`):

- **specs:** Markdown under a `specs/` directory; the title is the first `# ` heading.
- **plans:** Markdown under a `plans/` directory with `### Task N:` headings. Each task's `- [ ]` / `- [x]` lines
  are its steps; a task with every step ticked is done. A `**Spec:** \`path\`` line links the plan to its spec
  (resolved against the plan's directory, the roots, the repositories under them and the nearest `docs/`).
- **ledgers:** `*.ledger.md` and `.superpowers/sdd/*/progress.md`, whose first line is `# SDD ledger — plan: PATH`.
  `Task N: complete (commits A..B …)` or `(commit SHA …)` marks the task done and links those commits
  (a range git cannot resolve marks the task *stale*); `Ruling:` lines become rulings under their task.
  A ledger inside a linked git worktree gives its plan that worktree and branch.
- **the board:** TODOs with a `:PLAN_FILE:` property (onboarding's import) appear under their plan.

A plan is *merged* when all its tasks are done and its branch is in `main`/`master` (or gone). Only files that
changed since the last scan are read again (a rescan of 30 files takes well under a second).

## Recording commits

Agent sessions and jobs can work on a task — any tracker node id, such as `task:/path/plan.md#3`:

- `drgnx-agents-start PROFILE CWD TASK`: the agent gets `DRGNX_TASK`, and after each turn the commits made in
  CWD's repository since the last turn are recorded for the task.
- `drgnx-jobs-start NAME COMMAND :cwd DIR :task TASK`: the job gets `DRGNX_TASK`; the git HEADs it started and
  ended at are kept with the job, and its commits are recorded once it ended (on the next scan or refresh) —
  commits made after it ended are not its.
- By hand, or from any agent: `drgnx work record [--task ID] [SHA…]` links the commits (default `HEAD`) of the
  current repository to the task (default `$DRGNX_TASK`).

Recorded links live in the tracker's database and survive every rescan. With `drgnx-work-git-notes` set, each
link is also written as a git note (`refs/notes/drgnx`: `drgnx task: ID`) so it travels with the repository; it
is off by default because notes are shared state.

## Status

`drgnx work status` prints one line per plan: merged or on a branch, tasks, steps and TODOs done of all, commits
linked, title and branch. `--json` gives the same as an array of objects (`id title path spec branch merged
tasks steps todos commits`, counts as `[done, all]`).

## Storage

One SQLite database, `work.db` in drgnx's data directory (Emacs's built-in SQLite; WAL, a 5 s busy timeout so
several Emacs can share it). Every node and edge carries the source it came from — a file, `recorded`, `branch` —
so reading a file again replaces exactly what that file gave.

## Tests

`test/unit/work-test.el` (the scan: specs, plans, ledgers, branches, merges, renames, the board) and
`test/unit/work-record-test.el` (recording for agents, jobs and the CLI; git notes; status), against temporary
git repositories and the mock agent.
