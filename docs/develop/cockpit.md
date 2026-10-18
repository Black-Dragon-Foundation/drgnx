# The Work cockpit's model

`core/drgnx-cockpit-model.el` holds the data behind the Work cockpit: the graph, each agent's edits, "what happened",
questions and the timeline. The cockpit's panes only draw what it returns. It reads the live store:

- the work tracker's specs, plans, tasks and board TODOs ([work.md](../guide/work.md));
- the coordination store's jobs, tasks, cards, events and agent registry ([coordination.md](coordination.md));
- the hub's session snapshots (`agents/list`), which the caller passes in.

It is batch-safe. Nothing in it prompts. The model, the filter, "what happened", the timeline and the edit sources
are SQL reads that use the event indexes. Only git runs as a process, always asynchronously (`make-process` with a
sentinel). git never runs on a remote (TRAMP) folder: such a folder gets an error result, decided by its name alone.
A remote name is never expanded, made a folder name or resolved (`expand-file-name`, `file-truename`), so no file
handler runs on it. It comes back untouched, or is left out.

## The model

`(drgnx-cockpit-model &key sessions silent)` returns `(:nodes :edges :agents :questions)`.

- **Nodes** are plists `(:id :kind :title :state :waiting :readonly :path :line :job :agent :reporting …)`. The kinds
  are `spec`, `plan`, `task`, `todo`, `agent`, `job` and `review`.
- **Edges** are `(:from :to :kind)`:
  - `derives`: plan → spec.
  - `implements`: task, TODO or job → plan. A job task with no plan task points to its job.
  - `needs`: a job task → the task it depends on.
  - `blocks`: the reverse of `needs`, only while the dependency is not done.
  - `assigned`: task → agent.
  - `reviewed-by`: task → review.
- **Plan tasks are the skeleton.** A job's task is joined to its plan task `task:PLAN#N` (the job's `:plan`, the
  task's `:n`). That node then carries the job's state, holder and job. When two jobs run the same plan, the newest
  one shows.
- **Open jobs only, by default.** Done jobs are left out unless `drgnx-cockpit-include-closed-jobs` is set. The jobs,
  their tasks, their dependencies and the open ask cards come from four queries in all, whatever the number of jobs.
- **Read-only nodes.** A plan task that no job runs is `:readonly t`. The node offers "open in plan" and "start as
  job". Specs, plans and board TODOs are read-only too.
- **A plan the tracker never scanned** is read from its file: its `# ` title and `### Task N` headings with their
  lines. The parse is cached by modification time. Plan files are never written.
- **The board** is one more source, never the master. Its TODOs with `:PLAN_FILE:` come from the tracker's scan of
  the board file (`drgnx-projects-board-file`). The model reads only the store.
- **Agents.** A hub session with a job is `job`; any other session is `native`. A registered agent that is not a
  session (an `ext:` id, or one with a kind) is `outside`. A worktree found by `drgnx-cockpit-silent-worktrees` is
  `silent` ("not reporting").
  - An outside agent's task is a free label of its own (`:label`). It is never joined to a job or plan task. Its
    plan joins only when it names a scanned plan file exactly.
- **Waiting.** A node is `:waiting` while one of these is about it:
  - an open question (`drgnx-coord-open-questions`: escalations and ask cards);
  - an open ask card in `drgnx-coord-cards` (so a reopened card waits again);
  - a permission its session waits on.

  `:questions` lists the open questions, each with the `:node` it is about.
- **Extending it.** `drgnx-cockpit-node-functions` add nodes and edges (a new node kind needs only this and a face).
  `drgnx-cockpit-filter-functions` drop nodes.

`(drgnx-cockpit-filter MODEL FILTER)` keeps the nodes that match `(:milestone :agent :states)` and their ancestors.
Ancestors follow `derives` and `implements` up to `:to`, and `assigned` and `reviewed-by` up to `:from`. A milestone
matches a node whose title or path contains it, or one of its ancestors' (case is ignored).

## What happened, the timeline

- `(drgnx-cockpit-happened AGENT &optional LIMIT)` gives one line per event, newest last. It covers the agent's own
  events and the cards, questions and answers about the job tasks it holds. Each line is `(:at :kind :text :target)`.
  For example, "edited 2 files: a.el, b.el" or "tests 12/12 ✓ (make test)".
- `(drgnx-cockpit-timeline &key since)` gives chips `(:id :at :agent :kind :label :target)` after an event id, such as
  `T6 ✓`, `T7 review: fail` or `s-1 asks you`.
- A `:target` is `(:node ID :event ID)`. The node is the event's task node, else its agent's, else its job's.
- Glyphs come from `drgnx-face-glyph` when the face is loaded.
- The limits are `drgnx-cockpit-happened-limit` (50) and `drgnx-cockpit-timeline-limit` (300).

## Edits

`(drgnx-cockpit-edit-source AGENT &optional SESSIONS)` returns `(:dir :base :merge-base :paths :own-worktree
:stopped)`:

| Agent | `:dir` | `:base` |
|---|---|---|
| a job's | its task worktree (`.claude/worktrees/JOB-N/`) | its registry `base`, else `job/JOB` as a merge-base |
| native | its cwd | its registry `base`, else the `:head` its first event carries |
| outside | its registered worktree (or cwd), with `:paths` it reported, relative to it | its registry `base` |
| silent (`silent:DIR`) | the worktree | the main branch, as a merge-base |

A job agent's task comes from its session's `:task`, else the task it holds and works on.

**The exact bases** come from the hub ([hub.md](hub.md#events)): a job agent is registered with the commit its
worktree starts at as `base`, and a native session's first `start` event carries `:head`. Without them (an agent from
before, a folder whose HEAD could not be read), the job branch's fork point (`git diff --merge-base`) or HEAD is used.

`--merge-base` needs git 2.30 or later.

- **`drgnx-cockpit-changed-files`** runs `git diff -z --numstat --summary` against the base, then
  `git ls-files -z --others`, and answers `((:file :added :removed :status new|modified|deleted)…)`,
  `(:too-large BYTES)` or `(:error MSG)`.
  - It checks at most `drgnx-cockpit-changed-files-max` (500) files and lists those of them it may show, then
    `(:more N)` for the rest, so its sentinel stays bounded however many files are refused.
  - Each of git's two lists is capped at `drgnx-cockpit-diff-max-bytes` (1 MB) while git writes; past it the answer is
    `(:too-large BYTES)`. A silent worktree whose list is too large is still found, with `:changed` nil.
  - The names on `--summary` lines, which git C-quotes even under `-z` (a quote, a backslash, a control character),
    are unquoted before they are matched.
  - It counts untracked files' lines until `drgnx-cockpit-count-bytes-max` (1 MB) has been read. After that, `:added`
    is nil.
  - A source without a folder is an error answer, not a signal.
- **`drgnx-cockpit-file-diff`** gives one file's diff. An untracked file is diffed against `/dev/null`. It answers the
  text, `(:too-large BYTES)` or `(:error MSG)`.
  - The cap, `drgnx-cockpit-diff-max-bytes` (1 MB), is checked on the file's size before git runs, and then by the
    process filter while git writes. git is ended as soon as its output passes the cap, so a deleted 3 MB file costs
    one chunk past the cap, never the whole file.
- **Both read only regular files inside the folder.** They decide from `lstat` and link targets, opening nothing
  first. They never touch a device, FIFO or socket, or a link that leads out of the folder, so a reported path cannot
  make the cockpit read `/dev/zero` or a file in `~`.
- **How git runs:**
  - with `--literal-pathspecs` (a reported path is a name, never a pattern);
  - with `GIT_OPTIONAL_LOCKS=0`, so it never takes `index.lock` from an agent at work;
  - with `GIT_TERMINAL_PROMPT=0`;
  - ended after `drgnx-cockpit-git-timeout` (30 s).

`(drgnx-cockpit-silent-worktrees ROOTS CALLBACK &optional SESSIONS)` finds the linked worktrees of each root that
have changes against their merge-base with `drgnx-cockpit-main-branches`, leaving out:

- the main checkout;
- worktrees a registered agent or a session works in;
- every job's worktrees.

Each one found is an agent of `:reporting silent`, with the plan and ledger the tracker has for its branch. At most
three git processes run at a time (their stderr pipes aside); the rest wait in a queue that drains as each ends.

## Cost

Measured in batch on the fixture, plus 150 more jobs (6 tasks each, 140 of them done) and 2,000 events:

| | Time |
|---|---|
| The model, on the fixture alone | about 1 ms |
| The model, 151 jobs (11 open) | 4.3 ms |
| The model, closed jobs included (`drgnx-cockpit-include-closed-jobs`) | 15.7 ms |
| "What happened" for one agent | 1.7 ms |
| A 300-chip timeline | 4.4 ms |
| The `changed-files` sentinel on 1,002 files (500 listed, 1 MB of lines counted) | about 19 ms |

## Tests

`test/unit/cockpit-model-test.el` (prefix `drgnx-cockpit-model/`) runs on `test/fixtures/cockpit-fixture.el`. The
fixture is a temp project with:

- a spec, a plan of six tasks and a ledger;
- its own board file, never `~/org/board.org`;
- a job of three tasks;
- two worktrees: one with an outside agent registered in it, one silent;
- events.
