# The Work cockpit

The Work cockpit shows where agent work stands without reading long transcripts. Its home screen is the **Work
graph**: specs, plans, tasks, agents, jobs and reviews, who works on what, what needs or blocks what, and what waits
on you. It reads the live store: the work tracker's specs and plans, the coordination store's jobs, tasks, cards and
events, and the agent sessions this Emacs knows ([the model](../develop/cockpit.md)). Module `tools/cockpit`.

## Opening it

**Show Work as Graph** (`work-graph`, in the palette) shows the graph in its pane, `work-graph`, and focuses it.
Before the tiled grid, that is the left dock's **Work** view. **View Explorer** (Ctrl+Shift+E in the VS Code
profile) brings back the Explorer.

## What it shows

The first line counts what waits on you, the agents and the jobs. The nodes follow it.

| Node | Mark | Details |
|---|---|---|
| Spec, Plan, TODO, Job, Review | its kind, in bold | a plan: its tasks done of all; a job: its state |
| Task | `T2` and its state's mark | `← agent` (who works on it), `review: …`, its state; then `needs:` and `blocks:` lines |
| Agent | its state's mark | how it reports (`job`, `native`, `outside`, `silent`), its tasks, its state |

Marks: `✓` done, `●` working, `○` open or pending, `⚠` failed or needing input, `⏸` paused or stopped.

A node that waits on you is marked several ways:
- `◐` in red, and "waits on you" first among its details, so a cut line keeps it;
- in the drawing, a red dot and a red border;
- hovering it shows the first line of the open question.

A node waits while an open question, an open ask card or a permission is about it. A terminal that does not write
UTF-8 gets ASCII marks (`+ * o ! || ?`).

A task that exists only in its plan file (no job runs it) is read-only here. The drawing shows it with a dashed
border. **Start as Job** (`s`) proposes a job for it ([below](#changing-jobs-from-the-graph)).

A job's task you marked blocked shows the state `blocked` (mark `⏸`, in the warning colour) while no agent works on
it.

**Silent worktrees.** A worktree with changes that no agent reports from shows as an agent of its own, `silent`,
"not reporting": to make an agent in it report, add drgnx on its settings page
([agent-settings.md](agent-settings.md#report-to-drgnx)). When the tracker knows its plan, it hangs under that plan.
The graph looks for these while it shows:
- in the repositories the store knows (jobs' and plans', and those registered agents work in);
- at most every `drgnx-cockpit-silent-interval` (45 s), and after each work-tracker scan;
- with one git process per repository, and never in a remote (TRAMP) one.

## The drawing and the outline

- **The drawing** (SVG, built in): four columns, left to right: specs | plans | tasks and TODOs | agents, jobs
  and reviews. Each box sits level with what it joins; a plan sits in the middle of its tasks.
  - A line joins each node to its parent in the next column.
  - A dashed arc joins a task to the task it needs, in the warning colour while it still blocks.
  - A link that would cross a column is not drawn: behind that column's boxes it would seem to come out of one of
    them. A job joins its plan through its tasks; an agent on a plan shows on the plan's box (`← name`).
  - Hovering a box shows its full title, state, open question and file.
- **The outline**: the same nodes as a tree — spec › plan › tasks, TODOs, jobs — then the agents.

The drawing shows in a graphical window wide enough for it. Elsewhere you get the outline: terminal frames, small
frames and the narrow left dock. Widen the window and the drawing comes back. With `drgnx-cockpit-graph-svg` nil
you always get the outline.

## Keys and clicks

| Key | Command | Does |
|---|---|---|
| `TAB`, `S-TAB` (Vim also `n`, `p`) | Select Next / Previous Node (`cockpit-next`, `cockpit-previous`) | selects the next node and says what it is. In the drawing that is the next box in column order: it gets a focus stroke and scrolls into view. In the outline it is the next node's line. |
| `RET` | Open Node (`cockpit-open`) | opens the node on this line, or the selected one (with nothing selected in the drawing, you pick one by name) |
| `o` | Open in Plan (`cockpit-open-in-plan`) | the plan at this task's heading (an agent: its task's) |
| `f` | Filter Graph… (`cockpit-filter`) | a milestone (completion offers the specs' and plans' titles; any text in a title or path works), an agent, states, a job (it names the one shown now); empty: all |
| `g` | Draw Graph Again (`cockpit-refresh`) | reads the store again and draws now |
| `A` | Answer Question… (`cockpit-answer`) | answers the question about the node on this line or selected; also in What happened and the timeline (see below) |
| `R` | Reassign Task… (`cockpit-reassign`) | a job's task to an agent of the profile you pick ([below](#changing-jobs-from-the-graph)) |
| `b` | Mark Blocked / Unblock (`cockpit-block`) | asks why, and no agent starts on the job's task; on a blocked task, unblocks it |
| `M-<up>`, `M-<down>` | Run Earlier / Run Later (`cockpit-run-earlier`, `cockpit-run-later`) | moves a job's task one place (a prefix argument: that many) in the order ready tasks get agents in |
| `s` | Start as Job (`cockpit-start-as-job`) | on a plan's task no job runs: proposes a job of it and the tasks it needs |

The keys are the same in the VS Code, Emacs and Vim profiles: the graph's buffer starts in Emacs state under evil.
A click on a node (a box or an outline line) opens it too.

What a node opens:

| Node | Opens |
|---|---|
| Spec, plan, TODO | its file at its line |
| Task | the edits of the agent working on it ([below](#an-agents-edits)). A task nobody works on opens its plan at its heading. A read-only one opens there too, and the echo area names **Start as Job** (`cockpit-start-as-job`, `s`), which proposes a job for it. The graph never creates a job or edits a plan file by itself. |
| Agent | its edits ([below](#an-agents-edits)) |
| Job, review | the cockpit filtered to the job: What needs you and its decisions ([below](#what-needs-you-and-the-decisions)) |

The filter keeps the nodes it matches and their ancestors (a task keeps its plan and spec). The first line says
what it keeps.

## Changing jobs from the graph

Four commands change a job from the graph. Each acts on the node on this line, else the selected one (`TAB`), else
one you pick by name. Each is one call to the hub, which changes the job in the store; the graph and What needs
you redraw when the hub says so. None of them writes a plan file: a job runs a copy of its plan taken when it was
proposed.

- **Reassign Task…** (`R`): a job's task goes to an agent of the profile you pick, from now on. When an agent
  works on it, or it waits on you with a card, that agent ends and its card is settled: the task is ready for a
  new agent, as a card's Retry does. A task not started yet just starts on that profile. A task in review is refused until
  its review is over: its reviewer would otherwise answer about the next agent's work. Its fall-back profiles are
  the ones after it on its role's route ([jobs.md](jobs.md#routes-and-the-estimate)), none when it is not on the route.
- **Mark Blocked / Unblock** (`b`): asks why (kept as one line of at most 500 characters; control and bidi-control
  characters become spaces), then no agent starts on the task until you unblock it. An agent
  already working on it goes on. The graph shows the state `blocked`, and What needs you lists the task as blocked.
- **Run Earlier / Run Later** (`M-<up>`, `M-<down>`): moves the task one place in its job's run order, among the
  tasks not done. When more tasks are ready than `drgnx-job-max-agents`, the earlier ones get agents first. The
  echo area says where the task is now.
- **Start as Job** (`s`): on a plan's task no job runs (read-only here), proposes a job of that task and the tasks
  it needs, directly or not. The job's title ends in `— Task N`. The cockpit shows the job and its proposal card:
  nothing starts before you approve it, unless `drgnx-job-auto-start` is on. It takes your `drgnx-job-merge-gate`
  with it ([jobs.md](jobs.md#the-merge-gate)).

The hub has these as methods `job/reassign`, `job/block`, `job/unblock`, `job/order` and `job/start-task`
([hub.md](../develop/hub.md)).

## An agent's edits

Long transcripts hide what an agent actually changed. Click a task or an agent in the graph (or select it and
press `RET`) and that agent's file changes since it started open in the editor area, as a live diff. The pane is
`agent-edits`, and its buffer is `*edits: AGENT*`.

- **One section per changed file.** A header line comes first: `FILE +A −B`, then `new` or `deleted`, then its
  review mark (`✓ accepted`, or `changed since accepted`). The file's diff follows, in diff-mode's colours.
- **The header line** at the top names the agent and counts the files changed and the files you accepted. It also
  says what the changes are compared against, whether the agent is known to be stopped, and the keys (`a accept ·
  r revert · c comment · n/p files`).
- **Since it started.** A job's agent is compared with its task's base. A chat session is compared with where it
  started. An outside agent is compared with its registered base, and only the files it reported are shown. A
  silent worktree is compared with where it forked from the main branch.
  ([Where the edits are](../develop/cockpit.md#edits).)

| Key | Command | Does |
|---|---|---|
| `n`, `p` | Next / Previous Changed File (`cockpit-edits-next-file`, `cockpit-edits-previous-file`) | moves to the next or previous file's header line |
| `TAB`, `S-TAB` | Next / Previous Hunk (`cockpit-edits-next-hunk`, `cockpit-edits-previous-hunk`) | moves to the next or previous hunk |
| `RET` | Open File at Line (`cockpit-edits-visit`) | opens the real file (writable), from the agent's folder, at the line the diff line stands for |
| `a` | Accept File (`cockpit-accept-file`) | marks the file accepted with the hash of the diff you see. The mark counts toward the task's merge gate. It never merges or commits anything. When the agent changes the file again, the header says `changed since accepted`: the mark keeps the hash you accepted, and the merge gate compares it with the diff's. |
| `r` | Revert File… (`cockpit-revert-file`) | asks the agent to undo its changes to the file. The message `[revert] please undo your changes to FILE` is queued for it and never interrupts it. See below for the one case where the file is put back here. |
| `c` | Comment on Line… (`cockpit-comment`) | asks for a comment and queues `[comment] FILE:LINE: TEXT` for the agent. LINE is the file's line that the diff line at point stands for. |
| `g` | | lists the changes again and diffs every file |

The keys are the same in the VS Code, Emacs and Vim profiles: the buffer starts in Emacs state under evil.

**Read-only.** The pane is text in diff-mode's colours, not a diff buffer. Nothing outside its own commands acts on
the agent's files:
- its folder (`default-directory`) is an empty private folder of its own (removed with the pane), not the agent's,
  so VC (`C-x v u`, `C-x v v`), `ediff-patch-file`, `compile` or a shell started from it find nothing of the agent's;
- it cannot be switched to another mode (`M-x diff-mode` is refused), or cloned;
- it has no Diff menu.

`RET` opens the agent's real file, and that buffer is an ordinary, writable one: what you change and save there
changes the agent's worktree.

`r` and `c` are the way to act on an agent's change.

**When `r` puts a file back itself.** Only when all of these hold. Anything else is a request to the agent.
- The agent is a job's, and the folder is its task's worktree: the `.claude/worktrees/JOB-N/` that drgnx made for
  that task. git must say that the folder is a worktree's top and that it is on that task's branch (`job/JOB-N`), and
  no other session or registered agent may work in it. An agent that never registered (your own shell or editor in
  that folder) cannot be seen, so check the folder the question names.

  Everything else is only ever a request: an outside agent (the worktree it registered may be your own, and its
  reports cannot prove it stopped), a chat session's folder, a silent worktree and the main checkout. That holds even
  in a linked worktree where you may be working.
- The agent is known to have stopped: its session (here or the hub's) has exited **and** its task is no longer
  claimed, running or waiting for input. Not being among the sessions proves nothing.
- git can name the base. The base is resolved to a commit first, and the file is looked up in it. If git fails,
  nothing is changed: a failure is never taken to mean that the file is new.

You are then asked exactly what will happen, with the names shown safely and the folder shortened:
- `Put FILE back as abc12345 has it, in WORKTREE, discarding the agent's changes?`
- or, for a file the base does not have: `Delete new file FILE in WORKTREE (the agent's own worktree)?`

After you say yes, everything is checked again. If the agent has started again, another agent has come, or the base
has moved, it becomes a request to the agent instead.

**How a message reaches the agent.** It is always queued. Sending a message never cancels the agent's work.

| Agent | The message |
|---|---|
| a live session of this Emacs | waits in its queue for the end of its turn, even when the session is set to interrupt |
| a live hub session | goes through the hub (`agents/send`): queued, or steered into its turn when it can be steered; one set to interrupt gets a message in the store instead |
| an exited session, a job's agent elsewhere, an outside agent | a message in the store: the hub gives it to the agent as a new turn when it is free (and is told at once), and an outside agent reads it with `read_inbox` |
| a silent worktree | nothing: nobody reads messages there, and you are told so |

A message the store holds back (the agent's queue is full) is said as held, and no event is written.

Each accept, revert and comment is also an event (`accept`, `revert`, `comment`) in the agent's history.

**Live.** The pane follows the agent while it shows:
- File watches on the agent's folder and on the folders of its changed files see each write. At most
  `drgnx-cockpit-edits-watch-max` (32) folders are watched.
- The edits an outside agent reports through its MCP server are seen too: the pane looks at the store every
  `drgnx-cockpit-edits-check-interval` (2 s).
- Only the files that changed are diffed again, at most once per `drgnx-cockpit-edits-delay` (0.3 s), however often
  the agent writes. Only their sections of the buffer are replaced.
- Your point and the window's scroll stay on the same file and line. No window moves.
- A file the pane does not list yet makes it list the changes again, at most every 2 s. While the pane shows, it
  also lists them on its own, so a first write in a folder nobody watches yet shows without `g`. That happens every
  `drgnx-cockpit-edits-check-interval`, and the gap doubles, up to 10 s, while these listings find nothing new. Any
  change heard of brings it back.
- A hidden pane only notes what changed. It catches up when it shows.
- Remote (TRAMP) folders are never touched: such an agent's pane says so, with no git and no watch.

## What happened, the timeline, questions

Long transcripts lose things. The cockpit shows the same work as short lines.

**What happened** (**Show What Happened…**, `cockpit-happened`, in the palette; or an agent's name in the timeline)
shows one agent in the right pane, `happened`, in a buffer `*happened: AGENT*`:

- one line per event, newest at the bottom, each with its time: `decided #3 …`, `edited 2 files: a.el, b.el`,
  `tests 12/12 ✓ (make test)`, `asks: …`, `answered: …`, `review: …`. It covers the agent's own events and the
  cards, questions and answers about the job tasks it holds. It shows as many of the newest as fit its window, at
  most `drgnx-cockpit-happened-limit` (50), so the newest is always in view;
- each line opens what it is about (RET or a click): the task's plan at its heading, the agent, the job;
- **Open the full transcript ▸**, when the agent's session is in this Emacs. An agent outside drgnx says "no
  transcript: an outside agent";
- **Reply… (queues, never interrupts)**: it answers the agent's open question, or else sends a message the agent
  gets when its turn ends.

**The timeline** (**Show Timeline**, `cockpit-timeline`, in the palette) shows every agent in the bottom pane,
`timeline`, one row per agent:

```
Timeline · oldest left, newest right · ◐ 2 waiting on you
claude · jx#2  ‹ 1 ◐ s-1 asks you · T2 running · decision #1 · 2 files · 12/12 ✓
Claude Code    started · 2 files
jobs           job running · ◐ T3 asks you: Pick a name
you            answered
```

- The chips run left to right by time. A row shows as many of its newest chips as fit in its window.
- A chip that waits on you is drawn first, right after the name (or `‹ N`), however old it is: newer chips make
  room for it, and so does an open question older than the events the timeline reads. An open ask card shows in
  the `jobs` row the same way.
- `‹ N` says how many chips are not drawn; `‹ N ◐` means one of them waits on you (a row too narrow for all its
  questions). Click it to list them with their times.
- A chip opens what it is about, as a line of What happened does. The agent's name opens its What happened.
- `you` holds your answers. `jobs` holds a job's events that have no agent.

**Questions everywhere.** A question waiting on you shows in the graph (`◐` and a red dot) and in the timeline (a
`◐` chip in the waiting face, red). What happened marks its line the same way, and its first line names the agent's
oldest open question, so it stays in view after its line scrolls away. An answered question loses the mark.
The timeline's head counts escalations, `ask_user` questions and ask cards. The status bar's "waiting on you" adds
the questions no job holds (`drgnx-cockpit-waiting-count`); an ask card and a job's message to you are its jobs
segment's ⚑, so each shows once. Permissions show in the graph, and their
own count is the status bar's. While the cockpit module runs, a look every `drgnx-cockpit-check-interval` tells the
status bar when the number changed, so it moves even when another process asked, whatever shows.

**Answer Question…** (`cockpit-answer`, `A` in the graph, What happened and the timeline) answers the question
under point: a line or a chip, or the graph node on this line or selected. Otherwise it answers the agent of What
happened, or you pick one. It asks for the text. An answer never interrupts anyone:

| What asked | Where the answer goes |
|---|---|
| A job's agent | the hub's `job/reply`: a message it gets when it is free |
| A session in this Emacs | queued in it: it starts a turn when the session is free, else waits for the turn to end (steering the turn when its mode is `steer`). A session whose mode is `interrupt` is never interrupted here: the answer waits in its queue |
| A session of the hub | queued through the hub (`agents/send`). One whose mode is `interrupt` gets a message in the store instead, which the hub gives it when it is free |
| An exited session | a message in the store |
| An agent outside drgnx | a message in the store, which it reads with `read_inbox` |
| An ask card | the card is settled with your text |
| A permission | its transcript opens, where you answer it |

Then an `answer` event closes the question everywhere. When the store holds the message back (the agent's queue is
full, or too many messages between you two), the echo area says "held, not sent" and the question stays open. While
an answer is on its way to the hub (the echo area says "sent to the hub"), a second answer to the same question is
refused for up to 30 seconds.

Both are plain text, so terminals get the same lines and chips. A terminal that does not write UTF-8 gets ASCII
marks: `?` for `◐`, `+` for `✓`, `!` for `⚠`, `<` for `‹`, `>` for `▸`, `...` for `…`.

## What needs you and the decisions

A job's cards, the messages agents sent you and its decision log are panes of the cockpit too (until M12f they were
a job window of their own; [jobs.md](jobs.md#a-job-in-the-work-cockpit) has the details):

- **What needs you** (pane `needs-you`, buffer `*Needs You*`; **Show What Needs You**, `cockpit-needs-you`): every
  job's cards with their actions and the messages to you, each job under its name;
- **Decisions** (pane `decisions`, buffer `*Decisions*`; **Show Decisions**, `cockpit-decisions`): a job's decision
  log.

Both live in the right dock, stacked with What happened. **Show Job in Work…** (`job-show`), opening a job or review
node, a click on a job's name in What needs you, or the badge filter the cockpit to one job: the graph keeps that
job's nodes and their ancestors (its first line says `job ID`), What needs you adds the job's tasks, agents and
spend, and Decisions shows its log. **Show What Needs You** (and the status bar's jobs count) shows every job again.
The filter is kept with the saved workbench. In the Vim profile both buffers start in Emacs state; `RET` or a
click pushes a button, `g` asks the hub again.

## When it redraws

The graph never asks anything, and it never blocks typing. It redraws when one of these happens:

- the hub sends an event (a job, a card, an agent or a lease changed; not a transcript's chunks or the gateway's
  requests);
- an agent session here changes;
- the work tracker finishes a scan;
- a theme is enabled (the drawing's colours come from faces);
- a check every `drgnx-cockpit-check-interval` (3 s) finds that another process wrote the store, for example an
  outside agent's MCP server or another Emacs. The check is one query, and it runs only while the graph's pane shows:
  it starts when the pane shows and stops when it is hidden;
- its pane shows again, or its window changes size (the drawing may now fit, or no longer).

However many events come, at most one redraw runs per `drgnx-cockpit-redraw-delay` (0.5 s). A redraw first
compares a cheap key, which costs about 20 µs. The key covers the store's version and change count, what the graph
shows of each agent session (not its transcript, so an agent that streams costs nothing more), scans and silent
worktrees, the filter, the options, the font, and the windows. When the key is the same, the redraw ends there.

Otherwise it reads the store, and it draws only what changed:
- In the outline, each line belongs to its node: only the lines that changed are drawn again, and your place stays
  on its line.
- In the drawing, while no box moves, the buffer's text stays and only the images of the bands that changed are
  drawn again. Their old pixels are released first.

A hidden graph does nothing and keeps no timer: an event only notes that something changed, and the graph catches
up when it shows. Remote (TRAMP) folders are never touched.

What happened and the timeline follow the same events, the same check and the same delay, only while one shows.
When the store did not change, an update ends after one query. Otherwise they only add: new lines go under What
happened's last line, and new chips go into their rows. Only the rows that changed are written again, and only when
a window's width changes is every row fitted again. `drgnx-cockpit-waiting-count` returns a cached number, counted
again only when the store changed.

What needs you and Decisions ask the hub (never waiting for it) after a job, card, agent or lease event that
concerns the job they show, at most once per 0.5 s and only while one shows. A part is drawn again only when what it
shows changed, and its windows keep their place.

## Customizing

Customize group `drgnx-cockpit`, or `setopt` in `config.el`.
- The drawing's options apply at once: the graph is drawn again.
- The others take effect at the next redraw, check or open.

The options:

- `drgnx-cockpit-graph-columns`: the columns, each a list of node kinds, default
  `((spec) (plan) (task todo) (agent job review))`. A kind no column lists goes in the last one; adding a column
  is adding a list.
- `drgnx-cockpit-graph-svg`: draw (t) or always the outline (nil).
- `drgnx-cockpit-graph-box-chars` (32): how much of a title a box shows.
- `drgnx-cockpit-graph-band-height` (400): the drawing is made of images this tall, one under the other. A change
  draws again only the bands it reaches.
- `drgnx-cockpit-graph-states`: each state's face and mark.
- `drgnx-cockpit-open-functions`: what opening a node of each kind does.
- `drgnx-cockpit-redraw-delay` (0.5 s), `drgnx-cockpit-check-interval` (3 s), `drgnx-cockpit-silent-interval` (45 s).
- An agent's edits: `drgnx-cockpit-edits-delay` (0.3 s), `drgnx-cockpit-edits-check-interval` (2 s),
  `drgnx-cockpit-edits-watch-max` (32).
- `drgnx-cockpit-happened-limit` (50): the most lines in What happened. `drgnx-cockpit-timeline-limit` (300): chips the
  timeline reads at once and keeps per row. `drgnx-cockpit-timeline-name-width` (14): the agents' names' column.

Faces, all inheriting your theme's:

| Face | Inherits | Used for |
|---|---|---|
| `drgnx-cockpit-waiting` | `error` | the waiting mark, in the graph, What happened and the timeline |
| `drgnx-cockpit-chip` | nothing (set it to make chips stand apart) | the timeline's chips |
| `drgnx-cockpit-done` | `shadow` | done work |
| `drgnx-cockpit-running` | `success` | work going on |
| `drgnx-cockpit-blocked` | `warning` | pending and failed work, blocks lines |
| `drgnx-cockpit-edge` | `shadow` | lines, column titles, details |
| `drgnx-cockpit-kind` | `bold` | kind words |
| `drgnx-cockpit-edits-file` | `bold` | a changed file's name on its header line |
| `drgnx-cockpit-edits-added`, `drgnx-cockpit-edits-removed` | `success`, `error` | the `+A` and `−B` counts |
| `drgnx-cockpit-edits-accepted`, `drgnx-cockpit-edits-changed` | `success`, `warning` | `✓ accepted`, `changed since accepted` |
| `drgnx-cockpit-edits-note` | `shadow` | `new`, `deleted`, a diff on its way or too large to show |
| `drgnx-cockpit-focus` | `highlight` | the selected node's stroke: its background colour, or, when that stands out less than 3:1 from the default background, its foreground, else the text colour |

The drawing takes every colour from these faces and `default`. When a face has no colour, it uses the window's
text colour.

A new node kind needs a function on `drgnx-cockpit-node-functions` (the model), a column (or the last one) and,
if you like, an entry in `drgnx-cockpit-open-functions`.

What it costs, and its tests: [the cockpit, for developers](../develop/cockpit.md).
