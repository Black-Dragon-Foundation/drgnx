# The Work space

The Work space shows what your agents are doing in one place. This page grows with the feature; today it covers
opening the map, and the machines and files the hub knows about.

## Opening the map

**Open the Work Space** (`work-view`; VS Code `C-k t`, Emacs `C-c w w`, Vim `SPC a w`) opens the map of the project
of the frame you are in. A *workspace* is the project's repository and, when it lies inside another repository (a
notes repository with the code repositories inside it), that repository and the repositories directly inside it. To name
the repositories yourself, set `drgnx-work-space-roots`.

The map is a read-only buffer, `*drgnx work: NAME*`, in six layers: you asked, specs, plans, agents, branches, and
files and machines. The hub keeps what the map shows and sends changes as they happen; the map never asks again until
the hub restarts. If the hub goes away the map keeps what it showed and says "reconnecting" in its mode line, and it
subscribes again by itself when the hub is back. A map no window shows costs nothing: the hub sends it no changes, and
it is drawn again when you show it.

Outside a project (a scratch buffer, a folder that is not in git) the map is empty and says so.

### What the cards show

- An **agent** is a card of five lines: its state dot, a badge (the model's initial in the agent's colour), the model
  and its name; the task it works on; how it is going (what it is doing or its state, how long, what it has cost with
  its unit, its progress, its context use once it is over 80 %); its latest conclusion; and either "⚠ shares files
  with …" or how much it has read and changed. When a plan has more agents than fit, the cards become **compact**: two
  lines, the second still carrying the ⚠ mark. An agent that needs you, and the agents on the selection's chain, stay
  rich.
- A **subagent** (Claude Code's own) is a compact card under its parent.
- Asks, specs, plans, branches, files and machines are one-line chips: a plan shows its progress, a branch its
  edits, a file its changed lines, a machine how many of its slots are taken.
- The layers' names stand in the left margin. A collapsed layer is one thin row with its name and a count.

Text that does not fit a card is cut with an ellipsis, by its width on screen; a long ask, or one with emoji in it,
never makes its row taller than the others.

### Moving around

Everything here is computed in your Emacs from what the hub already sent, so a key never waits.

| Key | Does |
|---|---|
| `←` `→` (Vim `h` `l`) | along the layer: the previous or next item |
| `↑` (Vim `k`) | follow *why* up: what the selection came from |
| `↓` (Vim `j`) | follow *touches* down: the branch an agent works on, the machine it runs on, the files a branch edits |
| `Tab` / `Shift-Tab` | the next or previous agent, plans in their order, a subagent right after its parent |
| `Enter` | open: an agent's transcript (today's Agents view), a branch's repository (Magit when it is there), a file, a spec or plan document |
| `Shift-Enter` | the same, beside the map, without moving focus |
| `Alt-←` / `Alt-→` (macOS `Ctrl--` / `Ctrl-Shift--`; Vim `Ctrl-o` / `Alt-→`) | back to the selection before the last move, or forward again; a run of arrows or agent keys is one move, a jump (search, `g N`, a click) is one |

The **selected** card is raised; its **chain** (everything it came from, up, and everything it touches, down) keeps
its normal look; everything else is dimmed. From any item, `↑` reaches the ask it came from in a handful of keys. If
the selected item goes (its agent finishes, its branch merges), the selection moves to the nearest thing it came from
that is left, and the side panel says what finished; nothing pops up.

The **side panel** (a window of the right dock) follows the selection and says in words everything a line on the map
says: *why* (you › spec › plan › task), what it *touches* (what it edits, reads, runs on, overlaps with), its latest
conclusion, and what you can do with it. Reads show as a count here; the list of each file with how it was seen
arrives with the files picker.

Two agents whose work overlaps can meet in a **huddle**: select one and press `H` to start it with the other. An open huddle
appears in the needs-you strip; its key jumps to the agents in it.

### The strip, the lens and the filters

- The **strip** is the map's header line and stays when you scroll. On the left, one chip for each thing that needs
  you, with its jump key (`g 1` to `g 9`, `+N` for more): permission asks, pushes, questions, clashes, budget pauses,
  and every agent that waits on you. On the right, the machines' load ("desktop 3/16"). `n` and `N` cycle the chips,
  and `C-k n` / `C-c w n` / `SPC a n` do it from anywhere. **A jump only selects.** Allowing, pushing and answering stay
  on the card's own keys; no key of the map settles anything.
- The **lens** (the tab line) names the views: Map, Board, Timeline. `m`, `b` and `t` switch between them in the same
  window, and the selection comes along: each view shows the nearest thing it can represent.
- `f` hides everything not on the selection's chain; while it is on, the arrow keys move inside the chain and ask the
  hub for nothing. `o` shows only the agents and branches that overlap. `1` to `6` collapse a layer to one thin row
  with its name and a count, `0` opens them all, `.` brings finished items back. Each of these is a layout you asked
  for, so the hub lays the map out again at once.
- A layout you asked for **moves**: each card slides from where it was to its new place over 160 ms, cards that leave
  fade out and new ones fade in. The compositor moves the pixels, so your keys act on the new layout from the first
  frame and nothing waits for the motion. Nothing else moves the map: agents that arrive or finish change in place.
  With reduced motion (your desktop's setting, or `drgnx-look-motion` set to `reduced`), in a terminal, and where
  Nidhogg's compositor does not draw the frame (macOS for now), the map jumps to its new layout instead.
- `/` narrows the map to the items matching your text: they keep their look, the rest dim, and Enter selects the first.
- `Esc` clears the search; then the filters and collapsed layers; then closes the pane.
- When an agent records a new conclusion, its card shows a **new** chip for four seconds.

### The Board

`b` shows the tracker's tasks in six columns (queued, running, waiting, needs you, review, done), one flat card each
with a thin progress bar (the steps of its plan that are ticked; on a terminal a row of `▰` and `▱`). With a plan, spec or ask selected on the map, the
Board shows that plan's tasks; otherwise every task. The arrow keys move between cards, `Tab` to the next card that has
an agent, `Enter` opens that agent's transcript. The Board needs drgnx's own Emacs (Nidhogg, with its view model);
in another Emacs it says so instead of drawing.

What a selection becomes when you switch:

| Selected | On the Board |
|---|---|
| an agent (or a subagent) | the card of its task |
| a file, branch or machine | the cards of the agents that touch it, lit |
| a plan, spec or ask | that plan's tasks |

From the Board back to the map, a card selects its agent; a task with no agent selects its plan.

### The Timeline and the research trail

`t` shows a lane for each agent over time. Each step is a segment, coloured by what it was (reading and searching,
editing, other tools, thinking, waiting on a job, waiting for you). Left and right move to the earlier or later step of
a lane, up and down to the lane above or below, and `Enter` opens the step. A file selected on the map lights the lanes
of the agents that touch it.

`r` on an agent opens its **research trail**: its steps in order, newest at the bottom, following the end while it works.
A row has the kind's icon, a title (`path:120–184` for a read, the query for a search, the host and title of a page,
`thinking` for a thought), and its time and duration at the right. It opens with the last 60 steps and fetches 200 more
when you scroll near its top. On the hub-drawn trail a long session shows 500 steps at a time: moving up from the first
one shown (or down from the last) brings in the 500 around it, and the key you pressed lands once they are there, so
every step of the session can be reached from the keyboard. The agent's decisions and findings stand among the steps as cards that say how many steps
they are based on and which named sources no step of the session matches ("named, not read in this session"); a step a
conclusion rests on carries that conclusion's number in a small pill. `l` on a conclusion lights its steps and goes
through them; `L` on a step goes to a conclusion that rests on it (in the Vim profile, `g l` and `g L`).

`Enter` opens a step's source: a read at its lines, a search run again now, a page in your browser, an edit as its diff,
a thought in the agent's transcript. `S-Enter` on a read opens the file **as the agent read it**, in a read-only buffer
`FILE@step-N`, when the file has changed since.

The steering keys work in every Work view, on the agent selected there:

| Key | Does |
|---|---|
| `s` | message the agent (queued or steering as its mode says, never a cancel) |
| `p` | pause it after its current tool call ("Pausing after the current tool call · u resume") |
| `u` | resume it with a plain "Continue.", labelled "resumed by you" in the trail |
| `x` | stop it, after a confirmation line |
| `?` | this view's keys |

### The review view, the merge queue and a second reviewer

`v` on an agent opens its **review**. It starts with the agent's decisions: those from the brief, then its own, then
those it needs your call on. Under each is what git computed of it ("computed": the commits that implement it, and the
later hunks that overlap its lines), never a guess. Then come where the plan stands, what the agent did and what it
spent, and every file it edited as hunks against the branch it was cut from. On a hunk:

- `a` accepts the file's change as it is now: a review mark for the merge gate. Nothing is merged.
- `D` rejects it: the file goes back to pending and the agent is told, in a queued message, to take the change back. The
  agent is not cancelled.

`V` starts a **second reviewer**. It is given the code (the files changed) and none of the author's conclusions, and it
starts an agent, so it goes through `job/propose` like every dispatch from the Work space.

A branch in the merge queue shows "queue 2/3" on its card, and "conflicts with rp-x" when a trial merge failed; selected,
its side panel says the same in words. These come from the hub's own record; a branch the hub sent no queue for shows
nothing. Merging and pushing stay on their cards.

### Files an agent is editing

A file in the worktree of an agent that is still alive (running, waiting, waiting for you, or paused) opens **read-only**,
with a "live · NAME" chip in the mode line, so you cannot write over what the agent is changing. Your own checkout,
and the worktree of an agent that has finished, stay editable.

**`W`** (or the keys that would make the buffer editable) takes the wheel, as **Take the Wheel from the Agent** does
anywhere (see "Take the wheel" in the guide to agents in the editor): the agent stops after the step it is in, the
buffer becomes editable once it has, and **W** again gives the wheel back with your edits. Turning the Work space
module off gives every such buffer back its old read-only state.

### Into the code

**Enter on a file** opens it where an agent is. The hub knows which agents have read, searched or edited the file and at
which line; Enter takes the line of the agent on the selected chain (else the most recent agent's) and opens the file in
that agent's worktree at that line. When no line is known (Codex's reads and Claude's file searches give a path and no
line) it opens at the top and says "file only". **Shift-Enter** opens it beside the map without moving focus.

The Work space opens only plain files on this machine, inside the agent's worktree or your workspace. A name an agent
gave that leads elsewhere (a remote name, a link out of its folder, a device, a compressed or encrypted file) is not
opened, and says so; an agent whose folder is on another machine has no file to open here. The diffs are text: nothing
in them opens, applies or reverts a file.

**`e`** on an agent (or its branch) lists the files it edited, each with `+N −M` and "new file" when the agent made it.
Every row has a hint key: `1` to `9`, then `a`, `b`, … without the picker's own keys (`q`, `n`, `p`, `j`, `k`, `g`).
One key opens that file at the agent's line; Enter opens the one at point and `q` closes the list.

**`d`** on an agent (or its branch) opens the files it edited side by side with their diffs: one window per file, three
side by side at most, and the rest stacked as tabs in the third window. Each diff is against the commit the agent's
worktree was cut from, as the hub recorded it, so a file the agent made shows whole. The window arrangement is saved
first; **`q`** in a diff closes them all and puts the windows back, and opening the diffs again never replaces the
arrangement that was saved. `a` (accept) and `D` (reject) are the hunk keys of the review view; in these windows they
only say so.

**Who Is in This File** (`work-who-is-here`: `C-k h` in the VS Code profile, `C-c w h` in Emacs, `SPC a h` in Vim) works
from any buffer that visits a file. It names the agents in the file, the way they are in it and their lines, selects the
file on the map when the map shows it, and focuses the map. With the editor's agents on it also opens a small list
window of them (RET follows the agent, `o` opens its panel, `q` closes the list). With nobody in it, the echo area says "No agent in this
file" and nothing moves.

### The outline

**Show the Map as an Outline** (`work-outline`, `O`) draws one block per agent instead: the agent's line, why it
exists (you › spec › plan › task), what it touches (its branch, machine, edits and reads) and its latest conclusion.
It is what a terminal frame shows, what a screen reader reads best, and what the map falls back to when it cannot fit
a window ("Too many to draw at this width · O back to the map, at a wider tile"). `O` again goes back.

The colours are the theme's: the map's faces (`drgnx-work-dim`, `drgnx-work-card`, `drgnx-work-selected`,
`drgnx-work-chain`, `drgnx-work-overlap`, `drgnx-work-needs-you`, `drgnx-work-edge`, `drgnx-work-edge-strong`,
`drgnx-work-label`, `drgnx-work-chip`, `drgnx-work-new` and `drgnx-work-agent-1` to `-6`) inherit stock faces and carry
no colour of their own. The Work tab that used to sit in the right dock (`work-view` as "Show Work") is gone, and so is
the old Work cockpit (its graph of agents, jobs and reviews, the feed, the edits pane and the job parts), and the older
drawing of specs, plans and branches (`work-graph`): the map, the Board, the Timeline and the review view replace them.

## Machines

The hub lists the machines agent work can run on:

- **`local`** is the machine the hub runs on. It is always listed. Its slots are the places an agent's job can run
  at once; a slot a job holds shows as held by "job".
- **Other machines** appear when something reports them, and stay for the time the report says (its `ttl`). A machine
  that stops reporting leaves the list after that time. The job queue (`jobq`) reports its desktop and laptop slots.

Report a machine from a terminal:

```sh
ratatoskr machines report --machine desktop --ttl 60 --json slots.json
```

`slots.json` is a list of `{"id": "d1", "kind": "agent-job", "holder": "job-7"}` (`holder` is left out for a free
slot), or an object with that list under `slots`; `-` reads it from standard input, and without `--json` the machine
has no slots. The command exits 0 when the hub took the report, 1 when the hub refused it (the machine name `local` is
the hub's own), and 2 when the arguments or the slots do not parse.

Only you can report machines: an agent's connection to the hub is refused (`not-allowed`).

## What an agent changed

For a session the hub is running, the Work space can list the files it edited, with the lines added and removed, show
one file's changes, and show a file as it was after an earlier step. Every number is measured against the folder as it
was when the session started (or when the hub made its worktree). A file the agent created is listed as new. Nothing is
asked of the agent's own folder: the hub compares its own snapshots of it. Before the agent's first edit the list is
empty.

## Reads through shell commands

When an agent reads files with shell commands (`cat`, `sed -n`, `rg`, a script) rather than its own read tool, the
Work space still shows them, in two ways:

- **From the command:** the files a command names (`cat a`, `sed -n 1,5p b > c`), read from its text. This works for
  every agent and every machine. What a command builds at run time (`$(…)`, variables, `xargs`) is never guessed.
- **Seen open** (Linux): the files the command's processes actually opened, seen by the sandbox as they open them. It
  only watches: it never blocks or changes anything, and the command's output is the same. Writes seen this way are
  shown as "written by a command".

What "seen open" keeps:

- only files in the agent's folder, by their real names (a link that leads elsewhere is dropped);
- never what git ignores (build output such as `target/`), toolchain files (`~/.cargo`, `~/.rustup`, the mise
  caches) or system files (`/usr`, `/etc`, `/proc`);
- a file the command looked for that does not exist is left out.

Some commands are not watched, and their step says why:

- **"opens not traced for this build"**: builds and test runs (`cargo`, `make`, `ninja`, `cmake`, `npm`, `pnpm`,
  `yarn`, `go build`, `go test`, `pytest`, `podman`, `emacs`, `nidhogg` and every `bin/drgnx` command), and any command
  that once made its step more than a little slower (more than 5 % or 50 ms, whichever is more, and never more than
  250 ms). Such a command is not watched again in that folder while the hub runs.
- **"opens not traced for Codex: turned off in settings"** (or Gemini): Codex and Gemini can only be watched as a whole
  (every command they run pays for it), so they are off unless you list them in `drgnx-agents-trace-opens`, for
  example `("claude" "codex")`. Claude Code is watched one shell command at a time and is on by default.
- **"opens are not traced on macOS"**: macOS has no way to watch opens without root, so there you see the files
  commands name only.
