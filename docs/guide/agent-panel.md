# The agent panel

The agent panel shows one agent session in the right dock: who it is and what it is doing, a row of chips, and the
conversation as rows. Open it with **Agents: Open the Agent Panel** (`C-k p` in the VS Code profile, `SPC a p` in Vim).
There is one tab for each open agent.

Turn it off with the module `tools/agent-panel` (see [modules](modules.md)); every panel goes with it.

## What you see

- **Header:** the agent's name, then what it is doing: "Claude · running 6 min", "held by you" (you paused it) or
  "Pair · editing your checkout".
- **Chips:** model, context ring, cost, mode, sandbox, MCP servers, files edited, checkpoints. A chip appears only when
  the hub reports it; none is made up.
- **Steps:** a tool call is one line: a dot for its state, its title, its result after `·`, and its time and cost on the
  right in the code font. A slow step (over `drgnx-agent-panel-slow-seconds`) or an expensive one (over
  `drgnx-agent-panel-expensive-cost`) shows that figure in the warning colour. The agent's thinking is folded under the
  step it belongs to; `TAB` opens or folds it, with the step's detail.
- **Checkpoints:** `R` on a step opens the revert card for it (the edit history's revert: nothing changes until you
  apply it) and `F` forks a second agent from it; the prompt of a fork says what one more run like it costs when the
  forecast is there. A step with no checkpoint to go back to refuses `R`. A step a revert undid is marked `↶ undone`.
  The checkpoints chip names how much of the conversation the agent's provider restores (message, turn or summary)
  when the hub reports it.
- **Messages:** yours, the agent's, and the ends of turns, in order. The agent's messages are drawn as Markdown:
  headings, code, quotes, lists, rules and tables, with emphasis, strong, strike-through, links and code in the look's
  faces. As a message streams, only the blocks that changed are drawn again; a reopened session keeps the styling,
  because the hub sends each message's blocks with its history.


## Live and paged

A panel asks the hub for the session's entries only while a window shows it, and lets them go when none does. It opens
on the last page of steps (`drgnx-agent-panel-page-steps`, 50) and loads the page before when you scroll to the top
(or run **Load Earlier Steps**). New entries are added at the end and changed ones are patched in place; what is
already on screen is never drawn again, and rows are drawn in slices of 4 ms or less that stop when you type.

## What opens

The strip under the chips has a toggle for each step type (thinking, read, search, edit, execute, fetch, other). A type
that is on shows the detail of its steps; `T` flips one, `TAB` opens or folds the step at point whatever the toggles say.
A step that failed opens by itself. `1`, `2` and `3` are presets: **watch** (titles only), **review** (edits and
commands open) and **debug** (everything, thinking included). What is open belongs to the chat. `M` makes the current
choice the default for new panels and saves it in your settings (`drgnx-agent-panel-disclosure`).

## Steering

Under the transcript are the notes waiting for the agent's turn to end, one row each, and the composer.

- `s` writes to the agent. While it works, the message is queued and goes in when the turn ends; **sending never cancels
  the turn**. In the message, `@` completes a file of the agent's folder and `/` at the start completes one of its
  commands.
- `e` edits the queued note at point, `d` takes it out, until it is sent.
- `p` stops the agent after its current step and holds its queue, `u` resumes it with a plain "continue". `x` stops
  the turn, after a confirmation line; it also ends after the current step.
- `C` and the Pair chip next to the composer start pair mode. They are there only when pair mode is.
- The model and mode chips are read-only here.

## Cards

What the agent changed and what it asks sit under the transcript as cards.

- **Diff cards:** one for each hunk of each file the agent edited (flat, with a border). `a` accepts the hunk: it writes
  the review mark the merge gate compares, and nothing is merged. `D` rejects it: the file goes back to pending and the
  agent is told, in a queued message, to take it back. The panel never writes to an agent's worktree and keeps no queue
  of its own; both keys are the review view's own functions (module `tools/work-space`).
- **Permission cards:** a request the agent waits on, ringed in the attention colour. `RET` allows it once, `A` always,
  `D` denies it. The card goes when the hub's next snapshot no longer holds the request.

## Large outputs

An open step whose output is long shows its first ten and last ten lines and, between them, "N lines hidden · / search ·
O open in a buffer". When the hub kept only the ends of a huge output the count is an estimate, marked `~`.

- `/` asks for a regexp and lists the matching lines of the output (with their byte offsets, at most 200) in a buffer. The
  panel pages through the whole output for it, 256 KiB at a time.
- `O` opens the output in a read-only buffer. It holds the first range at once; `n`, or scrolling to the end, adds the
  next one. The header line says how many bytes are in. The whole output is never in the buffer, or in a single hub
  answer, at once.

## Pins, the to-do list and the edits ledger

- `P` on a step or a card pins it under the chips, for this chat; `P` on the pinned card unpins it.
- The agent's plan shows inline as a to-do list ("To do · 1 of 3 done"), replaced as the agent updates it, from its plan
  entries. It is there only when the agent made a plan.
- The **edits ledger** lists the files the agent edited with their added and removed lines (`L` lists or folds it). The
  line says how many edits came **since you looked**: looking is opening the ledger, which sets a mark at the newest
  entry, and later edits count from there. A panel you have never looked at counts every edit.
