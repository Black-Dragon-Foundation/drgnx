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

`(drgnx-cockpit-edit-source AGENT &optional SESSIONS)` returns `(:kind :dir :base :merge-base :paths :own-worktree
:stopped …)`, `:kind` being `job`, `native`, `outside` or `silent`:

| Agent | `:dir` | `:base` |
|---|---|---|
| a job's | its task worktree (`.claude/worktrees/JOB-N/`) | its registry `base`, else `job/JOB` as a merge-base |
| native | its cwd | its registry `base`, else the `:head` its first event carries |
| outside | its registered worktree (or cwd), with `:paths` it reported, relative to it | its registry `base` |
| silent (`silent:DIR`) | the worktree | the main branch, as a merge-base |

A job agent's task comes from its session's `:task`, else the task it holds and works on. Its source also has `:job`,
`:task` (the jtask id) and `:job-worktree t` when `:dir` is the `.claude/worktrees/JOB-N/` that drgnx makes for that
task (from the job's repository and a jtask row), not a session's cwd. `:stopped` is a hint for display (an agent missing from
SESSIONS counts as stopped); anything that acts on it needs positive evidence (see the edits' direct revert).

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
- **Updates:** the feed's buffers own their hooks: `drgnx-hub-event-functions` and
  `drgnx-agents-changed-functions` (named), a repeating check every `drgnx-cockpit-check-interval` and one one-shot
  timer. The last buffer killed removes them and releases What
  happened's end marker. `drgnx-cockpit-feed-schedule` works like the graph's: one update per
  `drgnx-cockpit-redraw-delay`, only while a feed buffer shows, a hidden one marked stale and caught up by its
  `:on-show`. An update first compares its key with the buffer's: `drgnx-cockpit--db-key` (`(data_version
  total_changes())`, one query, shared with the graph's key and the waiting count) and the ids of the sessions in this
  Emacs (their transcript links). The key is stored only after a successful update, so a failed one is tried again;
  one buffer's error leaves the other's update.
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
    It reads at most `drgnx-cockpit-timeline-limit` events past its last chip per update; more in between (over 600
    a second) are left out of the rows until it is drawn anew. An open question whose event is older than every
    chip it holds is read back (one `id in (…)` query, only when one is missing) and pinned in its agent's row.
    A row's waiting chips — its open questions, and in the `jobs` row the open ask cards no open question names
    (`drgnx-cockpit-feed--open-cards`, one query) — are pinned: drawn first, after the name or `‹ N`, whatever their
    age, and newer chips go to make room. `‹ N ◐` means a hidden chip waits. A chip shows a failure (in
    `drgnx-cockpit-blocked`) by its event's kind: tests with failures (`3/4 ⚠`, `2 failed`), a failing review
    verdict, a failed status. One update reads the open questions once, for every buffer and the waiting count.
    A row shows its newest chips that fit its window (its widest, else 80 columns, less one). Chip widths are
    measured then, never on redisplay. A width change refits every row. Windows on a rewritten line keep their
    column.
- **`(drgnx-cockpit-waiting-count)`**: the open questions (escalations, `ask_user`) and the open ask cards not asked
  again, the model's `:questions` without permissions. Cached as `(STORE-KEY . N)`: one query when nothing changed.
  Its key also holds `drgnx-cockpit-include-closed-jobs`. It is meant for the status bar's
  `drgnx-statusbar-waiting-functions`.
- **`(drgnx-cockpit-feed-tell-statusbar)`**: calls `drgnx-statusbar-refresh` (when it is loaded) when the waiting count
  changed since the bar was last told (it counts as told once the refresh returned). The graph's check and the feed's check call it every
  `drgnx-cockpit-check-interval` while their buffers live, so the bar moves when another process asks, without a hub
  event.
- **`(drgnx-cockpit-answer QUESTION TEXT)`**: QUESTION is one of `drgnx-cockpit-feed--questions` (the model's
  `:questions`, then each session's permissions as `(:kind "permission" :agent :permission :summary :node)`).
  - An ask card: `drgnx-coord-card-settle`, which writes the `answer` event.
  - A message of a job (`:data (:message M)`, the message's job): the hub's `job/reply`.
  - Otherwise `drgnx-cockpit-feed--queue`:
    - a live session of this Emacs: `drgnx-agents-send`, with its mode bound to `queue` when it is `interrupt`
      (`cl-letf`), so it starts a turn when free and waits in the queue when busy, never cancelling;
    - a live mirror whose mode is not `interrupt`: the hub's `agents/send`;
    - anything else (a mirror in `interrupt` mode, an exited or failed session, an outside or absent agent):
      `drgnx-coord-send` to the agent, naming the question's message (`:answers`, so the hub's header names the
      question: [coordination.md](coordination.md#delivery-the-hub)), and the hub is told (`coord/notify`). A held
      message is said, returns nil and closes nothing (and "Answer queued" is not said).
  - Then `drgnx-coord-event-add` of an `answer` `(:question ID)` by `user`, and the message is marked `acted`.
    When the hub answers asynchronously, this happens in its callback, so a refused reply leaves the question open.
  - A permission opens the transcript, and nothing is written.
  - Nothing here calls `agents/stop`, `agents/kill` or a cancel.
  - The questions whose answer is on its way to the hub (`drgnx-cockpit-feed--in-flight`, `(QUESTION . SENT-AT)`)
    refuse a second answer until the hub answers, the call fails, or `drgnx-cockpit-feed-in-flight-timeout` (30 s)
    passes: older entries are dropped whenever one is added, so a hub that went away blocks nothing for long. The
    echo area says "sent to the hub" for these routes, "queued" for the others.

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
- the five ways an answer goes, by what asked; a held answer not said to be queued; a second answer refused
  while the first is on its way;
- that an answer never stops, kills, cancels or steers (a session of this Emacs in `interrupt` mode queues it,
  or starts a turn when idle);
- the timeline's rows and chips in time order, a new chip changing only its row, rows that fit with the older
  chips one click away; waiting chips (questions, open ask cards) pinned past 80 newer chips, `‹ N ◐`;
- a question in the graph, `drgnx-cockpit-waiting-count` and the timeline, then calm once answered; the
  status bar told by the feed's and the graph's checks when the count changes;
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

## An agent's edits (`drgnx-cockpit-edits.el`)

`modules/tools/drgnx-cockpit-edits.el` draws one agent's edits as a live diff: pane kind `agent-edits` (home
`editor`), buffer `*edits: ID*` in `drgnx-cockpit-edits-mode` (text in diff-mode's colours, not a diff-mode
buffer). The graph's openers for tasks and agents (`drgnx-cockpit-edits-open-task`, `drgnx-cockpit-edits-open-agent`
in `drgnx-cockpit-open-functions`) pass the model's agent plist, so a silent worktree keeps its folder and base. The
user's side is in [cockpit.md](../guide/cockpit.md#an-agents-edits).

### The buffer

- **Sections.** Each file is one section: its header line, its diff and a blank line. The whole section carries the
  text property `drgnx-cockpit-edits-file`, whose value is the file's string from `drgnx-cockpit-edits--files` (the
  same object for the whole section, so a section ends where the property changes).
- **Finding a section** walks the property changes, one step per section.
- **Text, not a diff-mode buffer.** `drgnx-cockpit-edits-mode` derives from `special-mode`. Guarding diff-mode command
  by command left ways in: menus, `M-x`, VC reading the buffer as a patch, `ediff-patch-file`. So none of diff-mode's
  code, commands or maps is in it:
  - Only diff-mode's *faces* are used (`diff-header`, `diff-file-header`, `diff-hunk-header`, `diff-added`,
    `diff-removed`), through a few font-lock keywords of the pane's own (`drgnx-cockpit-edits--font-lock-keywords`).
  - The header's parts carry `drgnx-cockpit-edits-face`, and a matcher placed first
    (`drgnx-cockpit-edits--fontify-headers`) copies it to `face`, so the diff keywords leave those lines alone.
    `font-lock-face` covers buffers without font-lock.
  - Its own commands: `n`/`p` (files), `TAB`/`S-TAB` (hunks) and `RET` (`drgnx-cockpit-edits-visit`: the file from the
    agent's folder, at the new-side line), all from the section data, plus `a`, `r` and `c`. Below them is
    `special-mode-map`, and nothing else.
- **A neutral folder.** `default-directory` is an empty folder of the pane's own (`drgnx-cockpit-edits--neutral-dir`:
  `make-temp-file … t` under `temporary-file-directory`, mode 0700), removed (while empty) by its `kill-buffer-hook`. The agent's
  folder lives only in `drgnx-cockpit-edits--source`, which only the pane's own commands use. VC (`C-x v u`, `C-x v
  v`), `epatch`/`ediff-patch-file`, `compile` and shells in the pane find nothing of the agent's.
  `drgnx-cockpit-edits--agent`, `--id`, `--source` and `--neutral` are permanent-local.
- **No clones.** The mode has `no-clone` and `no-clone-indirect`: a clone would share the pane's timers and watches, and
  killing it would stop the original's updates.
- **No other mode.** A local `change-major-mode-hook` (`drgnx-cockpit-edits--keep-mode`) signals a `user-error`, so `M-x
  diff-mode` (or any mode) cannot turn the pane into a patch buffer.
- **No undo** (`buffer-disable-undo`), no dir-local variables.
- **Nothing global.** `drgnx-cockpit-edits--teardown` (for the coming module teardown) only kills the panes; each one's
  `kill-buffer-hook` ends its timers and watches.
- **The header line** is text cached at each patch: the agent, counts, base, "stopped" (positive evidence only) and
  the keys (`a accept · r revert · c comment · n/p files`).

### Live updates

The pane never polls a file. Three things name the files that changed:

1. **File watches** (`file-notify-add-watch`, `change`) on the agent's folder and its changed files' folders, at most
   `drgnx-cockpit-edits-watch-max`, only local ones. They are updated after each round. A watch event costs a prefix
   test and a hash lookup: it marks the file dirty and schedules a tick. Paths in `.git` and outside the folder are
   ignored.
2. **Reported edits.** `drgnx-cockpit-edits--check` runs every `drgnx-cockpit-edits-check-interval` seconds while the
   pane shows. It compares `data_version` and `total_changes`, one query. When they moved, it reads the agent's `edit`
   events after the last id it saw. Their paths, cut to the folder with no remote name expanded, mark files dirty. Review
   marks set elsewhere redraw their headers.
3. **A periodic listing.** The same check marks a listing due when `drgnx-cockpit-edits--quiet-next` has come, so
   a first write in a folder nobody watches yet (and no event names) shows. A listing that finds nothing new
   (nothing to diff, nothing gone) doubles the gap (`drgnx-cockpit-edits--quiet-gap`, from the check interval up to
   10 s). Any change heard of (`--touched`) resets it.
4. **g** marks every file dirty and asks for a listing.

A file the pane does not list makes it list again (`drgnx-cockpit-changed-files`, with a fresh
`drgnx-cockpit-edit-source`, so an outside agent's newly reported paths count). Listing happens at most every 2 s.

**Ticks and rounds.**
- One owned one-shot timer runs the tick, `drgnx-cockpit-edits-delay` after the first change. A tick on a hidden pane
  only marks it stale; `window-buffer-change-functions` and `drgnx-cockpit-edits-show` catch up.
- A tick while a round runs is put off. Otherwise it starts a round: the listing when due, then the dirty files' diffs
  (`drgnx-cockpit-file-diff`), at most 3 git processes at a time.
- The round's diffs are shown together when the last one is back. A long round, the first load of many files, shows
  what came back every `drgnx-cockpit-edits-delay`.
- So 50 writes a second give at most one patch per 0.3 s.

**Patching** (`drgnx-cockpit-edits--patch`):
- Before the change, each window's point and start are kept as (file, line in its section, column). The buffer's
  own point is kept the same way.
- Only the sections whose diff changed are replaced. The diff's SHA-1 decides: an unchanged diff draws nothing.
- After the change, the windows' point and start are put back on the same file and line, inside
  `drgnx-wb-with-owned-windows`. A window that is already right is not touched.
- A file gone from the list loses its section, and a new one gets a section at the end.
- From no files to some, or to an error, the buffer is drawn anew.

**Owners.** The buffer owns its tick, flush and check timers and its watches. Its `kill-buffer-hook` cancels them
and removes the watches. A git callback for a killed buffer does nothing. The caches are buffer-local and pruned with
the files: `drgnx-cockpit-edits--info` holds counts, hash and note per file, never diff text, because the buffer
holds that.

### Accept, revert, comment

- **Accept** writes `drgnx-coord-review-mark AGENT FILE "accepted" SHA1-OF-THE-DIFF` and an `accept` event. Nothing
  is written when the diff changes later: the header derives `changed since accepted` from the hashes, and the merge
  gate (C9) compares the mark's hash with the current diff's. It never calls the hub, merges or commits.
- **Send** (`drgnx-cockpit-edits--queue`, the same routes as `drgnx-cockpit-feed--queue` in the cockpit's feed; one
  function once both are merged). Revert requests and comments are queued, never an interruption:
  - a silent worktree: a `user-error` (nobody reads messages there);
  - a live session of this Emacs: `drgnx-agents-send`, with the session's mode set to `queue` for the call when it is
    `interrupt`;
  - a live hub mirror not set to interrupt: `drgnx-agents-send`, which is the hub's `agents/send`;
  - anything else (a mirror set to interrupt, an exited or failed session, a job's agent elsewhere, an outside agent):
    `drgnx-coord-send` to the agent's id, then `coord/notify` to the hub when its socket exists. The hub delivers it
    when the agent is free; an outside agent reads it with `read_inbox`. A held message is said, and no event is
    written.
- **Direct revert** (`drgnx-cockpit-edits--direct-p`) needs all of these; anything else is a request:
  - the source is a job's with `:job-worktree` (the task worktree drgnx made, with its jtask row). Never `outside`
    (`hello` registers its cwd's toplevel as its worktree, which may be the user's, and its stop events can be forged),
    `native` or `silent` (the user may work there);
  - git says the folder is a worktree's top (`rev-parse --show-toplevel`, true names) on exactly its task's branch
    (`job/JOB-N`);
  - no other live session or registered agent has its cwd or worktree in it, by true names
    (`drgnx-cockpit-edits--alone-p`). An agent that never registered (a shell, an editor of the user's) cannot be seen;
    the job's worktree is drgnx's own, made for that task, and the question names the folder;
  - its folder is local and a linked worktree (its top has a `.git` file, so it is never the main checkout);
  - the file passes `drgnx-cockpit--file-ok`;
  - positive evidence that the agent stopped (`drgnx-cockpit-edits--stopped-p`):
    - its session here (or the hub's mirror) has status `exited` or `failed`, **and** its jtask is not `claimed`,
      `running` or `needs-input`.

    Absence from the sessions never counts.

  Then the plan comes first (`drgnx-cockpit-edits--revert-plan`). It signals when git fails, so a failure is never
  taken for "absent":
  - BASE is the merge-base when the source says `:merge-base`;
  - `git rev-parse --verify BASE^{commit}` gives the commit;
  - `git ls-tree --name-only COMMIT -- FILE` decides: empty output means the file is new.

  Then the exact question, with names masked by `drgnx-wb-display-name` and the folder abbreviated:
  - `Put F back as abc12345 has it, in WT, discarding the agent's changes? `
  - or `Delete new file F in WT (the agent's own worktree)? `

  After "yes", the source is read again and `--direct-p` and the plan are run again. If either changed (the task
  was taken up again, another agent came, the base moved), it becomes a request instead. Only then `git checkout
  COMMIT -- FILE`, or `delete-file` (a regular file only), and a `revert` event (`:direct t :to COMMIT`; a request is
  `:requested t`).
- **Comment** reads the text (a command, so it may ask) and queues `[comment] FILE:LINE: TEXT`. File names in
  prompts, messages and echoes are masked (`drgnx-wb-display-name`).
  - LINE is the new-side line of the diff line at point: the hunk's `+N` plus the context and added lines before it.
  - A `comment` event follows.

### Cost

Batch, drgnx's steady GC settings, a 2,000-line file rewritten 30 times, point and window in its middle:
- the patch: 1.4 ms p50, 2.8 ms p95;
- the whole round, git included (asynchronous, so typing goes on meanwhile): 11.7 ms p50, 27.6 ms p95.

### Tests

`test/unit/mod-cockpit-edits-test.el` (prefix `drgnx-cockpit-edits/`) runs on the cockpit fixture's outside agent. It
records file watches instead of making real ones: in batch Emacs, a real watch's event waits in an input queue that
nothing reads, and no process sentinel runs while it waits. It covers:
- the files with their counts, the header faces under diff-mode's, `n`/`p`, a reported file listed at the next look,
  watched folders, and a remote folder (an error line, no git, no watch);
- 50 writes in a second: at most 4 patches, the last write shown, point and window start on the same file, line and
  column, no window moved;
- accept, and a change shown as `changed since accepted` (the mark keeps its hash);
- accept never merging or committing;
- revert: queued while the agent runs, queued for a session set to interrupt, queued for a stopped agent in the main
  checkout, queued for an outside agent that said it stopped in its registered worktree; nothing done when you say
  no (in a job's worktree);
- a native session stopped in a linked worktree: queued, never asked;
- a job's task worktree: queued while no session proves the agent stopped, or while its task still runs; put back,
  after the exact questions, once its mirror exited and its task is done; queued while another agent registered
  its cwd there, on another branch than the job's, or when the folder is no worktree's top;
- a git failure (no such base): an error before any question, nothing deleted;
- a silent worktree: no message (said); a first write in a new folder shows without `g`; quiet listings space out
  4, 8, 10 s and a change resets them; the header's key hint;
- the pane is no diff or patch buffer: special-mode, the neutral folder, its map holding only its own commands over
  special-mode's (menu items too), `diff-mode` and `fundamental-mode` refused, `vc-deduce-fileset` naming nothing of the
  agent's and `vc-revert` changing no file, `ediff-patch-file` offered no folder of the agent's, `RET` opening the
  right file at the right line, `TAB`/`S-TAB` by hunk; the pane's folder empty, private (0700), under the fixture's
  `temporary-file-directory` and gone with the pane;
- no clone (`clone-buffer`, `clone-indirect-buffer` refused); `diff-apply-hunk`/`diff-apply-buffer` by name and `g`
  change no file (`g` only lists again);
- a revert checked again after the question: the task taken up again, or another agent come in through a link, turns
  it into a request;
- comments queued, the line a diff line stands for, the hub routes (an exited mirror gets a message in the store);
- the graph opening an agent's edits from a task or an agent;
- the keys in every profile.

## What needs you and the decisions (`drgnx-cockpit-cards.el`)

`modules/tools/drgnx-cockpit-cards.el` holds the job window's parts since M12f; the job's own frame is gone. The user's
side is in [jobs.md](../guide/jobs.md#a-job-in-the-work-cockpit).

- **Pane kinds** `needs-you` (buffer `*Needs You*`, `drgnx-cockpit-cards-mode`) and `decisions` (`*Decisions*`,
  `drgnx-cockpit-decisions-mode`), home `right`, `:stack 'happened`. Before the grid they are tabs of the right dock.
- **The filter** is the graph's, `drgnx-cockpit-graph-current-filter`, with a `:job` key.
  - `drgnx-cockpit-show-job ID` sets it to `(:job ID)`. It applies the `work` layout when one exists (C10), else it
    shows the `work-graph` pane, then focuses `needs-you` and returns nil. `drgnx-job-ui-show` calls it, so a
    format-2 workbench whose custom frame state is `(drgnx-job-ui-show ID)` restores with no frame:
    `drgnx-persist-restore` places none, because the call returns none. It binds `drgnx-persist-restoring` while it
    runs, and `drgnx-cockpit-show-job` then only sets the filter: no layout, no pane shown, no focus, so the restored
    main frame keeps its windows (Review Focus 2).
  - `drgnx-cockpit-show-jobs` (the status bar's `jobs` click) drops `:job` and keeps the other keys.
  - `drgnx-cockpit-graph-filter` keeps `:job`.
  - The graph narrows through `drgnx-cockpit-filter-functions` (`drgnx-cockpit-cards--job-node-p`): a node of
    another job is dropped, and ancestors stay.
- **Persistence.** `drgnx-persist-state-functions` saves `:cockpit-filter`. `drgnx-persist-after-restore-functions`
  (`drgnx-cockpit-cards--adopt`) takes it back only when the key is present and the value is a filter: strings, and
  a list of strings for `:states`. A workbench saved before M12f has no such key, so the filter its job window just
  set stays.
- **Drawing.** The job window's functions moved here, renamed `drgnx-cockpit-cards--insert-{tasks,card,cards,log}`.
  `drgnx-cockpit-cards--put` erases and draws a part only when its key changed. For one job, What needs you's key is
  `(JOB CARDS-PART TASKS-PART)` and the log's is `(JOB LOG-PART)`. For every job, the key is the open jobs' ids,
  titles, repos and cards parts. Windows keep their start and point, clamped.
- **The hub.** One `job/status` per refresh: `(:id JOB :decisions t)` for a job, no parameters for every job (the
  log then says it is per job). An answer for a filter that changed meanwhile is dropped. `No job …` drops the job
  filter. Any other error draws "No drgnx hub" and looks again 10 s later.
- **Refreshes.** Hub events `job`, `card` and `lease-released` of the shown job (any job's when none is shown), and
  `agent` and `fallback`, schedule one refresh per 0.5 s, only while a part shows. A hidden part only sets
  `drgnx-cockpit-cards--stale`, and the kinds' `:on-show` catches up.
- **Ownership.** The hooks (`drgnx-hub-event-functions`, `drgnx-hub-disconnect-functions`) and both timers belong to
  the parts' buffers: the last one killed removes them. The setup adds three global hook functions (the filter, the
  saved state, the restore), which module teardown should take out. The visibility check and the stale flag are what
  C5 and C7 use, for the workbench state store to replace.
- **Kept in `drgnx-job-ui.el`:** the Plan Job commands (`job-show` is now "Show Job in Work…"), the ⚑ badge mode for
  those without the status bar (a click: `drgnx-job-ui-show` of the newest card's job, else
  `drgnx-cockpit-show-jobs`), and notifications.

### Cost

The perf workload `cockpit-cards` (the old `job-window`) types while the cockpit is filtered to a job with four
cards, three tasks and twenty decisions, as three mock agents stream. The first run was on a busy machine (load 6):
input p50 2.3 ms, p95 10.4 ms, max 13.5 ms (the job window's last runs: p95 8.5–9.5 ms at load 3.4). The budget rows
are PROVISIONAL until C12. In a harness session, typing with an `agent` event every 0.1 s gave `guard_violations` 0,
no collateral moves and no layout changes.

### Tests

`test/unit/mod-cockpit-cards-test.el` covers:
- the job window's cases (cards, clash texts, buttons, Discuss, Dismiss, acted messages, the log's faces), with
  redraws only on change;
- one refresh for 50 events, and none while hidden;
- no hub, and a deleted job;
- one pane for every job or one, and the graph filtered by job;
- an old job window's state restoring with no frame, the filter set and the frame not moved;
- the filter kept with the workbench, and a bad saved value refused;
- the badge;
- the kinds, commands and key rows.

`test/ui/job-window-test.el` (GUI) checks that the right dock shows the job and that a click on `[Retry]` acts, and
that a hidden pane asks nothing and catches up when it shows. `job-ui-test.el` keeps the badge and notification
tests.
