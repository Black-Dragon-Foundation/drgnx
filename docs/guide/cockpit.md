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

Marks: `✓` done, `●` working, `○` open or pending, `⚠` failed or needing input, `⏸` paused or stopped. A node that
waits on you has `◐` in red, the words "waits on you", and, in the drawing, a red dot and a red border. A node
waits while an open question, an open ask card or a permission is about it. A terminal that does not write UTF-8
gets ASCII marks (`+ * o ! || ?`).

A task that exists only in its plan file (no job runs it) is read-only here. The drawing shows it with a dashed
border.

## The drawing and the outline

- **The drawing** (SVG, built in): four columns, left to right: specs | plans | tasks and TODOs | agents, jobs
  and reviews. Each box sits level with what it joins; a plan sits in the middle of its tasks.
  - A line joins each node to its parent.
  - A dashed arc joins a task to the task it needs, in the warning colour while it still blocks.
  - A line that skips a column (a job to its plan) goes round that column's boxes, above or below them.
  - Hovering a box shows its full title, state and file.
- **The outline**: the same nodes as a tree — spec › plan › tasks, TODOs, jobs — then the agents.

The drawing shows in a graphical window wide enough for it. Elsewhere you get the outline: terminal frames, small
frames and the narrow left dock. Widen the window and the drawing comes back. With `drgnx-cockpit-graph-svg` nil
you always get the outline.

## Keys and clicks

| Key | Command | Does |
|---|---|---|
| `RET` | Open Node (`cockpit-open`) | opens the node on this line (in the drawing: you pick one by name) |
| `o` | Open in Plan (`cockpit-open-in-plan`) | the plan at this task's heading (an agent: its task's) |
| `f` | Filter Graph… (`cockpit-filter`) | a milestone (text in a title or path), an agent, states; empty: all |
| `g` | Draw Graph Again (`cockpit-refresh`) | reads the store again and draws now (after a theme change too) |

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

## When it redraws

The graph never asks anything, and it never blocks typing. It redraws when one of these happens:

- the hub sends an event (a job, a card, an agent or a lease changed; not a transcript's chunks or the gateway's
  requests);
- an agent session here changes;
- the work tracker finishes a scan.

Each event asks for a redraw. However many events come, at most one redraw runs per `drgnx-cockpit-redraw-delay`
(0.5 s). It reads the store, and it draws only when what the graph would show changed: an outline line that did
not change is left as it is, and so is your place in it.

A hidden graph does nothing. It remembers that something changed and catches up when it shows. Remote (TRAMP)
folders are never touched. Writes that reach the store without a hub event show at the next event, or with `g`:
for example, an outside agent's MCP server when no hub runs.

## Customizing

Customize group `drgnx-cockpit`; each option applies at once, `setopt` in `config.el` too.

- `drgnx-cockpit-graph-columns`: the columns, each a list of node kinds, default
  `((spec) (plan) (task todo) (agent job review))`. A kind no column lists goes in the last one; adding a column
  is adding a list.
- `drgnx-cockpit-graph-svg`: draw (t) or always the outline (nil).
- `drgnx-cockpit-graph-box-chars` (32): how much of a title a box shows.
- `drgnx-cockpit-graph-states`: each state's face and mark.
- `drgnx-cockpit-open-functions`: what opening a node of each kind does.
- `drgnx-cockpit-redraw-delay` (0.5 s).

Faces, all inheriting your theme's:

| Face | Inherits | Used for |
|---|---|---|
| `drgnx-cockpit-waiting` | `error` | the waiting mark |
| `drgnx-cockpit-done` | `shadow` | done work |
| `drgnx-cockpit-running` | `success` | work going on |
| `drgnx-cockpit-blocked` | `warning` | pending and failed work, blocks lines |
| `drgnx-cockpit-edge` | `shadow` | lines, column titles, details |
| `drgnx-cockpit-kind` | `bold` | kind words |

The drawing takes every colour from these faces and `default`. When a face has no colour, it uses the window's
text colour.

A new node kind needs a function on `drgnx-cockpit-node-functions` (the model), a column (or the last one) and,
if you like, an entry in `drgnx-cockpit-open-functions`.

## Cost

Measured in batch with drgnx's steady GC settings. Each figure is the mean of a forced redraw: the model, the
outline or the drawing, and the buffer. A garbage collection (40–50 ms) lands in about one redraw in 20.

| Store | Nodes | Outline | Drawing |
|---|---|---|---|
| The cockpit fixture | 13 | 0.7 ms | 1.0 ms |
| 151 jobs (11 open) and 2,000 events | 83 | 2.0 ms | 3.8 ms |
| 41 open jobs | 293 | 7.3 ms | 16.6 ms |

In a GUI session, a 293-node drawing with its rendering on screen takes about 28 ms (median). A redraw that would
show the same takes the model's time, about 2.5 ms at 300 nodes. With `drgnx-cockpit-include-closed-jobs` and 151
jobs (1,063 nodes), the outline takes about 25 ms and the drawing about 85 ms.

## Tests

`test/unit/mod-cockpit-graph-test.el` (prefix `drgnx-cockpit-graph/`) runs on the cockpit fixture
(`test/fixtures/cockpit-fixture.el`). It covers:

- the columns and edges;
- the waiting mark (outline, drawing, ASCII);
- that every colour in the drawing comes from a face;
- the outline in terminals and small windows;
- that clicks and `RET` open the right tab;
- one redraw per burst of events, none when nothing changed, none while hidden;
- the keys in every profile.
