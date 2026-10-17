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

## The Work tab

**Show Work** (module `tools/work`; VS Code `C-k t`, Vim `SPC a w`, Emacs: the palette) opens the right dock's
**Work** tab: each spec with the plans that came from it (plans that name no spec are roots of their own), and under
a plan its tasks, their steps, rulings and commits, and the board's TODOs.

```
▾ ◆ The Spec
  ▾ ▣ 1/2 Plan Alpha  steps 3/5 · todos 1/2 · 4 commits  [feature]
    ▾ ☑ Task 1: first
        ☑ Step 1: write the failing test
        ● 1a2b3c4 the change that made it pass
    ▸ ☐ Task 2: second
▸ ▣ 0/1 Plan Beta  0 commits  merged
```

A plan line starts with its tasks done of all (a narrow dock cuts the end of long titles), then its steps and
TODOs (when it has any), the commits linked, its branch and whether it is merged; a task whose recorded commits git
no longer has (rebased, squashed) is marked ⚠. Keys in the tab: `TAB` folds, `RET` opens the line's file at its
line (a commit: its diff in the editor), `g` scans again, `f` filters the plans by title or path, `m` hides the
merged ones (Vim: `R`, `F`, `M`). Opening the tab, and `g`, scan in a separate batch Emacs (`drgnx work scan`): this
Emacs never waits, and the tab redraws when the scan is done — and after each turn of an agent working on a task.

- **Start Agent on Task…** starts an agent on the task (or TODO, or plan) at point, in the plan's worktree (else
  its repository, else the plan's folder); its commits are recorded for that task.
- **Open Plan's Worktree** adds the plan's worktree to the Explorer.
- **Show Work as Graph** draws the specs, the plans shown (with their task and commit counts; merged ones dashed)
  and their branches with Graphviz (`dot`); without Graphviz it shows the DOT text.

`drgnx doctor` checks `work`: Emacs has SQLite (else the tracker is off), how many plans are tracked, and whether
Graphviz is there for the graph.

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
`test/unit/work-record-test.el` (recording for agents, jobs and the CLI; git notes; status), `test/unit/work-ui-test.el`
(the tab: tree, folding, opening, filter, refresh in another process, graph, agents on a task, doctor) — against
temporary git repositories and the mock agent — and `test/live/drgnx-work-test.el` (the tab in a GUI session).
