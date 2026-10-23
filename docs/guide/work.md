# Work tracker

Where did this plan come from, how far is it, and which commits did it? The work tracker answers that across
every project drgnx knows: **spec › plan › task › step / TODO › commit**, with the branch and worktree each plan
is built on. It reads what is already there (spec and plan files, execution ledgers, the board) and records the
commits of the work drgnx starts. Commit messages are never changed.

## What it reads

`drgnx work scan [DIR…]` (no DIR: the roots in `projects.eld` and `drgnx-work-roots`) walks each root seven levels
down (not into `.git`, `node_modules`, `eln-cache`, `elpa`, `target`, `dist`, `build`, `.claude/tmp`):

- **specs:** Markdown under a `specs/` directory inside the root (directories above the root do not count); the title is the first `# ` heading.
- **plans:** Markdown under a `plans/` directory inside the root, with `### Task N:` headings. Each task's `- [ ]` / `- [x]` lines
  are its steps; a task with every step ticked is done. A `**Spec:** \`path\`` line links the plan to its spec
  (resolved against the plan's directory, the roots, the repositories under them and the nearest `docs/`); a spec
  outside `specs/` is read again when it changes and is kept only while a plan names it.
- **ledgers:** `*.ledger.md` and `.superpowers/sdd/*/progress.md`, whose first line is `# SDD ledger — plan: PATH`
  (PATH absolute, or relative to a root, a repository under it or the ledger's directory).
  `Task N: complete (commits A..B …)` or `(commit SHA …)` marks the task done and links those commits
  (a range git cannot resolve marks the task *stale*); `Ruling:` lines become rulings under their task.
  A ledger inside a linked git worktree gives its plan that worktree and branch. A worktree's other files are
  copies of its repository's and are not read; when a worktree is removed its ledger goes with it and the plan is
  read again from what is left — keep a copy (`docs/plans/<plan>.ledger.md`) to keep that history.
- **the board:** TODOs with a `:PLAN_FILE:` property (onboarding's import) appear under their plan; a relative path
  is resolved against the `:PROJECT_ROOT:` of the project heading the TODO is under (none there: not shown).

A plan is *merged* when all its tasks are done and its branch is in `main`/`master` (or gone). Only files that
changed since the last scan are read again (a rescan of 30 files takes well under a second). Every scan also
checks that each linked commit is still on a branch, tag or HEAD: commits a rebase, squash or amend left behind
are marked ⚠ (and their task *stale*) until they are reachable again.

## Recording commits

Agent sessions and jobs can work on a task — any tracker node id, such as `task:/path/plan.md#3`:

- `drgnx-agents-start PROFILE CWD TASK`: the agent gets `DRGNX_TASK`, and after each turn the commits made in
  CWD's repository during it are recorded for the task (just after the turn, never while Emacs handles the agent's
  output). When the session exits, whatever it committed after its last turn ended is recorded once, at the exit; commits made
  in that checkout afterwards are never the dead session's.
- `drgnx-jobs-start NAME COMMAND :cwd DIR :task TASK`: the job gets `DRGNX_TASK`; the git HEADs it started and
  ended at are kept with the job, and its commits are recorded once it ended (on the next scan or refresh) —
  commits made after it ended are not its.
- By hand, or from any agent: `drgnx work record [--task ID] [SHA…]` links the commits (default `HEAD`) of the
  current repository to the task (default `$DRGNX_TASK`).

What counts as a turn's or a job's commits: those on HEAD's own line (first parents) since it began, committed
after it began. A pull or merge brings no one else's commits in (only the merge commit itself); a checkout or
rebase that leaves HEAD on another line records nothing; more than 100 new commits (`drgnx-work-collect-max`)
record nothing; and while two task sessions are busy in one repository at the same time, whose commit is whose
is unknown, so neither records automatically — the agents can say it with `drgnx work record`. A job's commits
are collected in its repository even after its worktree was removed.

Recorded links live in the tracker's database and survive every rescan (a ledger naming the same commit never
turns them into guesses). With `DRGNX_WORK_GIT_NOTES=1` in the environment (or `drgnx-work-git-notes` set in
Emacs, which passes it to the scans it starts), each link is also written as a git note (`refs/notes/drgnx`:
`drgnx task: ID`, once per task) so it travels with the repository; it is off by default because notes are shared
state.

## The Work tab

**Show Work** (module `tools/work`; VS Code `C-k t`, Vim `SPC a w`, Emacs: the palette) opens the right dock's
**Work** tab: each spec with the plans that came from it (plans that name no spec are roots of their own), and under
a plan its tasks, their steps, rulings and commits, and the board's TODOs (with the commits recorded for them).
A plan whose spec was deleted becomes a root. The bottom panel has a **Work** tab as well, with the same tree, for
when the right dock holds something else (the Agent layout, [layouts.md](layouts.md)).

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
The tab is a view (`docs/develop/core.md`, "Views"): a scan, a fold or a filter changes only the rows whose task
changed (or that came or went), and your place stays on the same task through every one of them. A tab nobody is
looking at draws nothing; it catches up when you show it.

- **Start Agent on Task…** starts an agent on the task (or TODO, or plan) at point, in the plan's worktree (else
  its repository, else the plan's folder); its commits are recorded for that task.
- **Open Plan's Worktree** adds the plan's worktree to the Explorer.
- **Show Work as Graph** opens the Work cockpit's graph — specs, plans, tasks, agents, jobs and reviews, who is on
  what and what waits on you ([cockpit.md](cockpit.md)) — when the `tools/cockpit` module runs. Without it, it draws
  the older graph described here: the specs, the plans shown (the tab's filter and hide-merged apply; each with its tasks
  done and commits; merged ones dashed) and their branches, in three columns, with Emacs's own `svg.el` — no other
  program. Every box is a hot spot: click a spec or plan to open its file, a branch to add its worktree to the
  Explorer (a double click opens it once; the file opens from the graph's window, even when another was selected);
  hovering shows the full title and counts. Its colours come from your theme through the faces
  `drgnx-work-ui-graph-spec`, `-plan`, `-merged`, `-branch` and `-edge` (customise them, or let the theme), so the
  next graph follows a theme switch (`g` in the graph draws it again). The graph scrolls like text, down and
  sideways; a big one is drawn as bands of images one below the other (Emacs refuses a single image taller than
  `max-image-size`), which you do not see. It needs a graphical frame of an Emacs with SVG support (librsvg; every
  graphical build drgnx installs has it) — in a terminal frame it says so. 300 plans: 0.8 s to draw on screen.

`drgnx doctor` checks `work`: Emacs has SQLite (else the tracker is off), how many plans are tracked, and whether
this Emacs can show SVG (else there is no graph; the tab shows the same tree).

## Status

`drgnx work status` prints one line per plan: merged or on a branch, tasks, steps and TODOs done of all, commits
linked, title and branch. `--json` gives the same as an array of objects (`id title path spec branch merged
tasks steps todos commits`, counts as `[done, all]`), always UTF-8 whatever the locale. Agents read the same rows through the coordination server's `work_status` tool.

## Storage

One SQLite database, `work.db` in drgnx's data directory (Emacs's built-in SQLite; WAL, a 5 s busy timeout so
several Emacs can share it). Every node and edge carries the source it came from — a file, `recorded`, `branch` —
so reading a file again replaces exactly what that file gave. The database migrates itself step by step when drgnx
updates it (a `work.db` from a newer drgnx is left alone, with an error saying so); since schema 2 it also keeps what
the agent gateway carried, one row per request (`spend`: job, task, agent, provider, model, tokens, cost).

## Backups and exports

The store keeps dated copies of `work.db` (`backup/work-YYYYMMDD.db`: the last 7 days and the last 4 Sundays; each
copy is checked and a bad one is deleted, so the previous good one stays). `work-pre7-*.db`, made before the move to
the new store, is only ever removed by you.

### The move to the new store

The first time the new hub starts it moves your `work.db` to the new store (schema 7) before it answers anything:
it first copies the file to `backup/work-pre7-<time>.db` and checks the copy, then moves everything in one step, so
an interruption leaves the old file as it was. What it reads from your personal notes folder (`~/org`, the board
aside) is not moved; the doctor says which copies still hold it, so you can remove them.

### If the migration fails

The hub keeps running without writing: the doctor says why (`ratatoskr doctor`, `store.failed`), and it does not
try again until it restarts. Your file is unchanged. To go back to the previous drgnx:

1. `drgnx hub stop`
2. `ratatoskr store restore-pre7 --yes`: the newest checked `work-pre7-*.db` becomes `work.db` again; the new file
   is kept beside it as `work.db.schema7-<time>` (with its `-wal` and `-shm`). Without `--yes` it only says what it
   would do.
3. Install the drgnx from before the move, and start the hub.

An export is a folder of plain JSONL files: `entities.jsonl` and `links.jsonl` (what you and your agents wrote, one
item per line, sorted so a change touches only its lines), `tx.jsonl` (who changed what), and on request
`history.jsonl` and the activity (sessions, what they touched). Notes you keep outside the store's reach never
appear in it. Importing a folder is safe to repeat: items that are already there at that version or later are
skipped.

## Tests

`test/unit/work-test.el` (the scan: specs, plans, ledgers, branches, merges, renames, the board) and
`test/unit/work-record-test.el` (recording for agents, jobs and the CLI; git notes; status), `test/unit/work-ui-test.el`
(the tab: tree, folding, opening, filter, refresh in another process, graph, agents on a task, doctor) — against
temporary git repositories and the mock agent — and `test/live/drgnx-work-test.el` (the tab in a GUI session).
