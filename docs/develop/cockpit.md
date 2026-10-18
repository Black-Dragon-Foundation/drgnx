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

**Two exact bases are still to come.** A job agent's registry `base` should be the task's HEAD at its start, and a
native session's `start` event should carry `:head`. Until their writers record them (the hub, C3), the job
branch's fork point (`git diff --merge-base`) or HEAD is used.

`--merge-base` needs git 2.30 or later.

- **`drgnx-cockpit-changed-files`** runs `git diff -z --numstat --summary` against the base, then
  `git ls-files -z --others`, and answers `((:file :added :removed :status new|modified|deleted)…)` or
  `(:error MSG)`.
  - It lists at most `drgnx-cockpit-changed-files-max` (500) files, then `(:more N)` for the rest.
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
three git processes run at a time.

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

## What happened, the timeline, answers (module `tools/cockpit`)

`modules/tools/drgnx-cockpit-feed.el`, loaded by `drgnx-cockpit.el`. The user's side is in
[cockpit.md](../guide/cockpit.md#what-happened-the-timeline-questions).

- **Panes:** kinds `happened` (home `right`; a placeholder until an agent is picked) and `timeline` (home
  `bottom`). Their modes, `drgnx-cockpit-happened-mode` and `drgnx-cockpit-timeline-mode`, and the graph's share
  `drgnx-cockpit-map`, where `cockpit-answer` (`A`) is bound.
- **Updates:** the feed's buffers own their hooks: `drgnx-hub-event-functions` (named), a repeating check every
  `drgnx-cockpit-check-interval` and one one-shot timer. The last buffer killed removes them and releases What
  happened's end marker. `drgnx-cockpit-feed-schedule` works like the graph's: one update per
  `drgnx-cockpit-redraw-delay`, only while a feed buffer shows, a hidden one marked stale and caught up by its
  `:on-show`. An update first compares `(data_version total_changes())` with the buffer's.
  - **Point stays on the head line** of both, which every change is below. So an update never moves a window's
    point or start: typing elsewhere sees no window move (the jank report's collateral stays 0).
  - **What happened** appends the lines of events newer than its last one, before a marker that ends them. It
    rewrites only the lines of questions answered since (the mark goes), and its last lines when the transcript
    appears or goes. It holds as many lines as its tallest window shows (less its head and last lines; at most
    `drgnx-cockpit-happened-limit`), so the newest is in view without scrolling. Past that, its oldest lines go.
    A window of another height that would show other lines, or more new events than the limit, draws it anew.
    Its head line carries the agent's oldest open question (`drgnx-coord-open-questions AGENT`), patched like a
    row.
  - **The timeline** reads `drgnx-cockpit-timeline :since` its last chip. It rewrites only the lines of the rows
    those reach, the rows that marked a question answered since, and its head. A new agent is a new line at the end.
    A row shows its newest chips that fit its window (its widest, else 80 columns, less one). Chip widths are
    measured then, never on redisplay. A width change refits every row. Windows on a rewritten line keep their
    column.
- **`(drgnx-cockpit-waiting-count)`**: the open questions (escalations, `ask_user`) and the open ask cards not asked
  again, the model's `:questions` without permissions. Cached as `(STORE-KEY . N)`: one query when nothing changed.
  It is meant for the status bar's `drgnx-statusbar-waiting-functions`.
- **`(drgnx-cockpit-answer QUESTION TEXT)`**: QUESTION is one of `drgnx-cockpit-feed--questions` (the model's
  `:questions`, then each session's permissions as `(:kind "permission" :agent :permission :summary :node)`).
  - An ask card: `drgnx-coord-card-settle`, which writes the `answer` event.
  - A message of a job (`:data (:message M)`, the message's job): the hub's `job/reply`.
  - Otherwise `drgnx-cockpit-feed--queue`: a session here (not exited or failed, mode not `interrupt`) takes it,
    a mirror through the hub's `agents/send`, a session of this Emacs through `drgnx-agents-send`. Anything else
    gets `drgnx-coord-send` to the agent, and the hub is told (`coord/notify`).
  - Then `drgnx-coord-event-add` of an `answer` `(:question ID)` by `user`, and the message is marked `acted`.
    When the hub answers asynchronously, this happens in its callback, so a refused reply leaves the question open.
  - A permission opens the transcript, and nothing is written.
  - Nothing here calls `agents/stop`, `agents/kill` or a cancel.

### Cost

Batch, drgnx's steady GC settings, on the fixture plus 2,000 events, What happened and the timeline both shown, p50
of 100 runs:

| | Time |
|---|---|
| An update when nothing changed | 0.022 ms |
| An update after one new event (both panes: a line appended, a row rewritten) | 1.7 ms, about 6,700 conses |
| `drgnx-cockpit-waiting-count`, the store changed | 0.12 ms |
| `drgnx-cockpit-waiting-count`, cached | 0.018 ms |

### Tests

`test/unit/mod-cockpit-feed-test.el` (prefix `drgnx-cockpit-feed/`) runs on the cockpit fixture, with the hub
stubbed. It covers:
- What happened's lines and their targets, the transcript link, the reply, and appends that change nothing above;
- the five ways an answer goes, by what asked;
- that an answer never stops, kills, cancels, prompts or steers;
- the timeline's rows and chips in time order, a new chip changing only its row, rows that fit with the older
  chips one click away;
- a question in the graph, `drgnx-cockpit-waiting-count` and the timeline, then calm once answered;
- `A` from a chip and from the graph;
- the ASCII form, hidden panes catching up, the buffers owning their hooks and markers;
- the commands and keys in every profile.

## The Work graph (module `tools/cockpit`)

`modules/tools/drgnx-cockpit-graph.el` holds the layout, the drawing (SVG text, every colour from a face) and the
outline. `modules/tools/drgnx-cockpit.el` holds the pane, the redraws and the commands. The user's side is in
[cockpit.md](../guide/cockpit.md).

### Redraws

`drgnx-cockpit-schedule` keeps one owned one-shot timer, and only while the graph is visible. A tick that finds
the graph hidden only marks it stale; `:on-show` catches up. `drgnx-cockpit-graph-redraw` works in four steps:

1. **The key** (about 20 µs, one query):
   - `PRAGMA data_version` (moves when another connection commits) and `total_changes()` (this Emacs's writes);
   - what the model reads of this Emacs's sessions: `(ID STATUS TASK JOB NAME CWD PERMISSIONS-P)` each. A
     transcript's chunk changes none of it, so an agent that streams builds no model: 0.023 ms and 1 KB a tick at
     293 nodes, where a counter of session changes cost 2.1 ms and 500 KB;
   - counters bumped by tracker scans and new silent worktrees, and `drgnx-cockpit-include-closed-jobs`;
   - the filter, the options' generation, the font's metrics, the widest window, ASCII or not.

   The same key: return.
2. **The model**, built only when the store part, the filter or the generation changed.
3. **The layout**, cached by `(model metrics generation)`.
4. **The signature**: the model, the mode and the metrics. It decides whether anything is drawn.

How the views change:
- The outline is patched line by line.
- The drawing redraws in place while its frame (head lines, bands, every box's place) is the same: only the bands
  whose SVG changed get it, through `image-property`, with `image-flush` on the old pixels first.
- Otherwise the buffer is rebuilt, and the old band images are flushed except one equal to a new one (the image
  cache serves it).
- TAB re-renders only the bands the old and the new focus stroke reach.

Owners:
- The buffer owns its hooks (hub events, agent changes, tracker scans, `enable-theme-functions`; all named) and
  the repeating `drgnx-cockpit--check` timer. Its `kill-buffer-hook` removes them and flushes its images.
- `drgnx-cockpit-graph--encoded` (the SVG form of a text) is emptied at 4,096 texts.

### Cost

Batch, drgnx's steady GC settings (64 MB, 0.1); per redraw over 100 runs, p50, with the allocation per draw from
`memory-use-counts`. One garbage collection (about 28 ms) lands in about one redraw in 20 at 300 nodes.

| Store | Nodes | Nothing changed | A change shown (drawing) | Forced, outline | Forced, drawing | TAB |
|---|---|---|---|---|---|---|
| The cockpit fixture | 13 | 0.022 ms, 1 KB | 1.2 ms, 159 KB | 0.71 ms, 131 KB | 0.79 ms, 125 KB | 0.05 ms |
| 151 jobs (11 open), 2,000 events | 83 | 0.023 ms, 1 KB | 3.3 ms, 751 KB | 1.7 ms, 465 KB | 2.5 ms, 608 KB | 0.23 ms |
| 41 open jobs | 293 | 0.022 ms, 1 KB | 10.6 ms, 2.5 MB | 4.4 ms, 1.4 MB | 7.8 ms, 2.0 MB | 0.84 ms |

In a GUI session (harness, 1600×900), a change shown at 294 nodes is measured as the redraw plus `(redisplay t)`,
which is when librsvg renders the changed band. It takes 27.5 ms p50: 11.8 ms redraw and 14.6 ms render. 28 of 30
changes take 29 ms or less; the other two each contain a GC (61 ms).

Each changed band costs about 15 ms to render, whatever its height between 250 and 1,000 px. That fixed cost is
why a change touches as few bands as it can.

### Tests

`test/unit/mod-cockpit-graph-test.el` (prefix `drgnx-cockpit-graph/`) runs on the cockpit fixture. It covers:
- the columns and edges (no link drawn across a column);
- the waiting mark (outline, drawing, ASCII, hover text);
- that every colour in the drawing comes from a face;
- the outline in terminals and small windows;
- clicks and `RET`, keyboard selection in column order;
- one redraw per burst of events, none when nothing changed and no model built then, none while hidden (a pending
  timer included);
- options and fonts reaching the drawing, old band images flushed (and kept when drawn the same);
- writes of another connection caught by the check;
- an agent that streams builds no model (a status change does, and so does showing done jobs);
- a theme redraws; the drawing's hover text tells the open question; TAB draws only the bands its stroke reaches;
  the selection survives a model change; the focus stroke stands out (3:1);
- silent worktrees as agents "not reporting", each once (a remote repository or agent folder never asked about);
- the keys in every profile.
