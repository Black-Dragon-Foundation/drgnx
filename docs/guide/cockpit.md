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
border.

**Silent worktrees.** A worktree with changes that no agent reports from shows as an agent of its own, `silent`,
"not reporting". When the tracker knows its plan, it hangs under that plan. The graph looks for these while it
shows:
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
| `f` | Filter Graph… (`cockpit-filter`) | a milestone (completion offers the specs' and plans' titles; any text in a title or path works), an agent, states; empty: all |
| `g` | Draw Graph Again (`cockpit-refresh`) | reads the store again and draws now |
| `A` | Answer Question… (`cockpit-answer`) | answers the question about the node on this line or selected; also in What happened and the timeline (see below) |

The keys are the same in the VS Code, Emacs and Vim profiles: the graph's buffer starts in Emacs state under evil.
A click on a node (a box or an outline line) opens it too.

What a node opens:

| Node | Opens |
|---|---|
| Spec, plan, TODO | its file at its line |
| Task | its plan at its heading. A read-only task opens there too, and the echo area names **Start Job from Plan…** (`job-start`), which starts a job. The graph never creates a job or edits a plan file by itself. |
| Agent | its transcript when its session is in this Emacs; otherwise the echo area says what it is doing |
| Job, review | the job's window |

The filter keeps the nodes it matches and their ancestors (a task keeps its plan and spec). The first line says
what it keeps.

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
claude · jx#2  ‹ 1 T2 running · decision #1 · 2 files · 12/12 ✓ · ◐ s-1 asks you
Claude Code    started · 2 files
you            answered
```

- The chips run left to right by time. A row shows as many of its newest chips as fit in its window.
- `‹ N` says how many older chips there are. Click it to list them with their times.
- A chip opens what it is about, as a line of What happened does. The agent's name opens its What happened.
- `you` holds your answers. `jobs` holds a job's events that have no agent.

**Questions everywhere.** A question waiting on you shows in the graph (`◐` and a red dot) and in the timeline (a
`◐` chip in the waiting face, red). What happened marks its line the same way, and its first line names the agent's
oldest open question, so it stays in view after its line scrolls away. An answered question loses the mark.
`drgnx-cockpit-waiting-count` gives how many wait, for the status bar's "waiting on you" count. Escalations,
`ask_user` questions and ask cards count. Permissions show in the graph, and their own count is the status bar's.

**Answer Question…** (`cockpit-answer`, `A` in the graph, What happened and the timeline) answers the question
under point: a line or a chip, or the graph node on this line or selected. Otherwise it answers the agent of What
happened, or you pick one. It asks for the text. An answer never interrupts anyone:

| What asked | Where the answer goes |
|---|---|
| A job's agent | the hub's `job/reply`: a message it gets when it is free |
| A session in this Emacs or the hub's | queued in the session (`agents/send`), or steering its turn when its mode is `steer`. A session whose mode is `interrupt` gets a message in the store instead, which it gets when it is free |
| An agent outside drgnx | a message in the store, which it reads with `read_inbox` |
| An ask card | the card is settled with your text |
| A permission | its transcript opens, where you answer it |

Then an `answer` event closes the question everywhere.

Both are plain text, so terminals get the same lines and chips. A terminal that does not write UTF-8 gets ASCII
marks: `?` for `◐`, `+` for `✓`, `!` for `⚠`, `<` for `‹`, `>` for `▸`, `...` for `…`.

## When it redraws

The graph never asks anything, and it never blocks typing. It redraws when one of these happens:

- the hub sends an event (a job, a card, an agent or a lease changed; not a transcript's chunks or the gateway's
  requests);
- an agent session here changes;
- the work tracker finishes a scan;
- a theme is enabled (the drawing's colours come from faces);
- a check every `drgnx-cockpit-check-interval` (3 s) finds that another process wrote the store, for example an
  outside agent's MCP server or another Emacs. The check is one query, and it runs only while the graph shows.

However many events come, at most one redraw runs per `drgnx-cockpit-redraw-delay` (0.5 s). A redraw first
compares a cheap key, which costs about 20 µs. The key covers the store's version and change count, what the graph
shows of each agent session (not its transcript, so an agent that streams costs nothing more), scans and silent
worktrees, the filter, the options, the font, and the windows. When the key is the same, the redraw ends there.

Otherwise it reads the store, and it draws only what changed:
- In the outline, an unchanged line stays, and so does your place in it.
- In the drawing, while no box moves, the buffer's text stays and only the images of the bands that changed are
  drawn again. Their old pixels are released first.

A hidden graph does nothing: it remembers that something changed and catches up when it shows. Remote (TRAMP)
folders are never touched.

What happened and the timeline follow the same events, the same check and the same delay, only while one shows.
When the store did not change, an update ends after one query. Otherwise they only add: new lines go under What
happened's last line, and new chips go into their rows. Only the rows that changed are written again, and only when
a window's width changes is every row fitted again. `drgnx-cockpit-waiting-count` returns a cached number, counted
again only when the store changed.

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
| `drgnx-cockpit-focus` | `highlight` | the selected node's stroke: its background colour, or, when that stands out less than 3:1 from the default background, its foreground, else the text colour |

The drawing takes every colour from these faces and `default`. When a face has no colour, it uses the window's
text colour.

A new node kind needs a function on `drgnx-cockpit-node-functions` (the model), a column (or the last one) and,
if you like, an entry in `drgnx-cockpit-open-functions`.

What it costs, and its tests: [the cockpit, for developers](../develop/cockpit.md).
