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
- **Messages:** yours, the agent's, and the ends of turns, in order.

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
