# The agent panel

The agent panel shows one agent session in the right dock, beside the editor and never as one of its tabs: who it is and what it is doing, a row of chips, and the
conversation as rows. Open it with **Agents: Open the Agent Panel** (`C-k p` in the VS Code profile, `SPC a p` in Vim).
There is one tab for each open agent.

Turn it off with the module `tools/agent-panel` (see [modules](modules.md)); every panel goes with it.

## What you see

- **Header:** the agent's icon and name, then what it is doing: "Claude · running 6 min", "held by you" (you paused
  it) or "Pair · editing your checkout"; on the right the **watch · review · debug** lens, the preset in force raised.
- **Chips:** model, context ring, cost, mode, sandbox, MCP servers, files edited, checkpoints. A chip appears only when
  the hub reports it; none is made up.
- **Steps:** a tool call is one line: a dot for its state, its title (a shell step: "Shell" and its command in the
  code font), its result after `·`, and its time and cost on the
  right in the code font. A slow step (over `drgnx-agent-panel-slow-seconds`) or an expensive one (over
  `drgnx-agent-panel-expensive-cost`) shows that figure in the warning colour. The agent's thinking is folded under the
  step it belongs to; `TAB` opens or folds it, with the step's detail.
- **Fonts:** the panel's text is in the UI font; a tool's output, the diffs (in the steps and on the cards) and code in
  a message are in the code font.
- **Checkpoints:** `R` on a step opens the revert card for it (the edit history's revert: nothing changes until you
  apply it) and `F` forks a second agent from it; the prompt of a fork says what one more run like it costs when the
  forecast is there. A step with no checkpoint to go back to refuses `R`. A step a revert undid is marked `↶ undone`; the rows reload by themselves when a revert, redo or take is applied.
  The checkpoints chip names how much of the conversation the agent's provider restores (message, turn or summary)
  when the hub reports it.
- **A paired chat's edits:** a paired chat writes your own checkout, so it has no worktree base to diff against. Its
  ledger (`L`) lists the hunks the edit history holds for that chat, one line each with the file and the lines; `D` on a
  line takes that one hunk back through the history's selective revert, keeping what you typed after it. A hunk you
  undid yourself (with undo) shows `undone by you`.
- **Messages:** yours, the agent's, and the ends of turns, in order. The agent's messages are drawn as Markdown:
  headings, code, quotes, lists, rules and tables, with emphasis, strong, strike-through, links and code in the look's
  faces. As a message streams, only the blocks that changed are drawn again; a reopened session keeps the styling,
  because the hub sends each message's blocks with its history.


## Why a step was allowed, and what a chip means

Under a step the panel shows the hooks' verdict lines (refused, changed, failed, or busy) and RET on one opens its
provenance: who (rule or plugin, version, hash), what, how long. A request you answered with `A` Always is written down by the hub (`agents/grants`), and the step shows
`allowed by your Always` from that ledger. `V` on that step takes the grant back through the hub: it asks you again for a
matching request from then on. The agent keeps its own rule until it starts again, so `V` also offers to restart the
agent at its latest step (a new agent from there, which has no rule); the message after a revoke says when the rule is
kept.

`i` on a chip (or anywhere, then pick one) opens its facts from the hub (`agents/explain`): the context breakdown with
`[drop]` and `[pin]` only when the agent advertises them and `[What /compact keeps]` when it can say; the dearest
steps and the cache hits; the mode, its lock and the row of the permissions matrix; what the agent waits for and the
key that answers it; the MCP servers the hub gave the session with their tool counts. A fact the hub does not know is
not listed.

## Subagents and huddles

A step a subagent made (Claude's `Task` tool) is indented under its call and drawn in a colour of its own. A huddle is two
agents stating their positions about a clash, with you deciding; its thread is a panel of its own: each agent's reply
with its position quoted, the decision it proposes, the outcome, and a composer (`s`) that writes to both agents.
Opening the thread is joining (`agents-huddle-open` in the palette). Start one from the who-is-here list: `m` marks an
agent, `h` meets the two marked ones; `agents-huddle` in the palette does the same by name. While a huddle is open or
waits for you the status bar says `huddle N`.

## Controlling the session

`x` stops, `p` holds, `u` resumes. `m` moves the session to another profile: it stops after its current tool call and
the new agent continues in the same worktree (the panel of the new session opens). `c` is `/compact`; an agent that
can say what a compaction keeps shows that first. `o` switches the mode, offering only the modes the provider's lock
allows; when it allows none the hub's reason is shown. `S` switches the model (the agent refuses one it does not have,
and the panel says so). `agents-panel-start` in the palette starts another agent in this folder; `R` and `F` revert and
fork at a step; `/commands` complete in the composer.

## Live and paged

A panel asks the hub for the session's entries only while a window shows it, and lets them go when none does. It opens
on the last page of steps (`drgnx-agent-panel-page-steps`, 50) and loads the page before when you scroll to the top
(or run **Load Earlier Steps**). New entries are added at the end and changed ones are patched in place; what is
already on screen is never drawn again, and rows are drawn in slices of 4 ms or less that stop when you type.

## What opens

The strip under the chips reads **Open:** and has a pill for each step type (thinking, read, search, edit, execute,
fetch, other), raised when it is on; **make default** is at its right end. In a narrow panel the pills go on as
many lines as they need, and they follow the panel's width when you resize it. A type that is on shows the detail of its
steps; a click on its pill or `T` flips one, `TAB` opens or folds the step at point whatever the toggles say.
A step that failed opens by itself. `1`, `2` and `3` (or a click on the header's lens) are presets: **watch** (titles only), **review** (edits and
commands open) and **debug** (everything, thinking included). What is open belongs to the chat. `M` makes the current
choice the default for new panels and saves it in your settings (`drgnx-agent-panel-disclosure`).

**Moving between steps.** `]` and `[` go to the next and previous tool call, `}` and `{` to the next and previous step
that changed a file, `>` and `<` to your next and previous message, from the step at point and wrapping at the ends
(**Next Tool Call**, **Next Change**, **Next Message You Sent** and their **Previous** twins, in every profile). They
answer at once, without asking the hub. With nothing at point, `TAB` opens or folds the step you moved to.

## Steering

Under the transcript are the notes waiting for the agent's turn to end, one row each, and the composer: a field ("Steer
the agent…"; a click writes to the agent, as `s` does) and under it a bar with the model and mode chips and the
**Stop after this step** and **Send** buttons.

- `s` writes to the agent. While it works, the message is queued and goes in when the turn ends; **sending never cancels
  the turn**. In the message, `@` completes a file of the agent's folder and `/` at the start completes one of its
  commands.
- `e` edits the queued note at point, `d` takes it out, until it is sent.
- `p` stops the agent after its current step and holds its queue, `u` resumes it with a plain "continue". `x` stops
  the turn, after a confirmation line; it also ends after the current step.
- `C` and the Pair chip next to the composer start pair mode. They are there only when pair mode is.
- A click on the model or mode chip switches it, as **Switch the Model** and **Switch the Mode** do.

## Cards

What the agent changed and what it asks sit under the transcript as cards.

- **Diff cards:** one for each hunk of each file the agent edited (flat, with a border). A header over it names the
  file, the lines and which hunk it is ("215–217 · hunk 1 of 1"), with **Reject** and **Accept** at the right; each line
  shows its number (the new file's; a removed line, the old file's). `a` accepts the hunk: it writes
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

## The agents list

*Show Agents* (`agents-view`) lists the sessions the hub runs, one on a line: name, status, how full the context is
and what waits for you. `RET` opens that session's panel. Enter on an agent's card on the Work map opens the panel
too. This list and the panel replaced the old Agents view; chat with a model (gptel) is gone with it, and the
agent panel is where you talk to a model now.
