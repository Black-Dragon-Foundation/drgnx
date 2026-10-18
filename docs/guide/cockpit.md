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

The keys are the same in the VS Code, Emacs and Vim profiles: the graph's buffer starts in Emacs state under evil.
A click on a node (a box or an outline line) opens it too.

What a node opens:

| Node | Opens |
|---|---|
| Spec, plan, TODO | its file at its line |
| Task | the edits of the agent working on it ([below](#an-agents-edits)). A task nobody works on opens its plan at its heading. A read-only one opens there too, and the echo area names **Start Job from Plan…** (`job-start`), which starts a job. The graph never creates a job or edits a plan file by itself. |
| Agent | its edits ([below](#an-agents-edits)) |
| Job, review | the job's window |

The filter keeps the nodes it matches and their ancestors (a task keeps its plan and spec). The first line says
what it keeps.

## An agent's edits

Long transcripts hide what an agent actually changed. Click a task or an agent in the graph (or select it and
press `RET`) and that agent's file changes since it started open in the editor area, as a live diff. The pane is
`agent-edits`, and its buffer is `*edits: AGENT*`.

- **One section per changed file.** A header line comes first: `FILE +A −B`, then `new` or `deleted`, then its
  review mark (`✓ accepted`, or `changed since accepted`). The file's diff follows, with diff-mode's colours and keys:
  `TAB` moves by hunk and `RET` opens the file at that line.
- **The header line** at the top names the agent and counts the files changed and the files you accepted. It also
  says what the changes are compared against, and whether the agent is stopped.
- **Since it started.** A job's agent is compared with its task's base. A chat session is compared with where it
  started. An outside agent is compared with its registered base, and only the files it reported are shown. A
  silent worktree is compared with where it forked from the main branch.
  ([Where the edits are](../develop/cockpit.md#edits).)

| Key | Command | Does |
|---|---|---|
| `n`, `p` | Next / Previous Changed File (`cockpit-edits-next-file`, `cockpit-edits-previous-file`) | moves to the next or previous file's header line |
| `a` | Accept File (`cockpit-accept-file`) | marks the file accepted with the hash of the diff you see. The mark counts toward the task's merge gate. It never merges or commits anything. When the agent changes the file again, the mark becomes pending and the header says `changed since accepted`. |
| `r` | Revert File… (`cockpit-revert-file`) | asks the agent to undo its changes to the file. The message `[revert] please undo your changes to FILE` is queued for it and never interrupts it. One case is different: when the agent is **stopped** and the file is in **its own worktree**, you are asked once for that file, and then the file is put back as the base has it (`git checkout BASE -- FILE`, or deleted when it is new). The main checkout is never touched. |
| `c` | Comment on Line… (`cockpit-comment`) | asks for a comment and queues `[comment] FILE:LINE: TEXT` for the agent. LINE is the file's line that the diff line at point stands for. |
| `g` | | lists the changes again and diffs every file |

The keys are the same in the VS Code, Emacs and Vim profiles: the buffer starts in Emacs state under evil.

**How a message reaches the agent.** It is always queued. Sending a message never cancels the agent's work.
- A session of this Emacs gets it when its turn ends, even when the session is set to interrupt.
- A hub session gets it through the hub (`agents/send`): queued, or steered into its turn when it can be steered.
- Any other agent gets it through the coordination store's queue: a hub session set to interrupt, a job's agent
  elsewhere, or an outside agent. The hub delivers it as a new turn when the agent is free, and an outside agent reads
  it with `read_inbox`.

Each accept, revert and comment is also an event (`accept`, `revert`, `comment`) in the agent's history.

**Live.** The pane follows the agent while it shows:
- File watches on the agent's folder and on the folders of its changed files see each write. At most
  `drgnx-cockpit-edits-watch-max` (32) folders are watched.
- The edits an outside agent reports through its MCP server are seen too: the pane looks at the store every
  `drgnx-cockpit-edits-check-interval` (2 s).
- Only the files that changed are diffed again, at most once per `drgnx-cockpit-edits-delay` (0.3 s), however often
  the agent writes. Only their sections of the buffer are replaced.
- Your point and the window's scroll stay on the same file and line. No window moves.
- A file the pane does not list yet makes it list the changes again, at most every 2 s.
- A hidden pane only notes what changed. It catches up when it shows.
- Remote (TRAMP) folders are never touched: such an agent's pane says so, with no git and no watch.

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

Faces, all inheriting your theme's:

| Face | Inherits | Used for |
|---|---|---|
| `drgnx-cockpit-waiting` | `error` | the waiting mark |
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
