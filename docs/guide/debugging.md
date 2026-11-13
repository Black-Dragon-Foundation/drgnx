# Debugging

drgnx debugs through its own client of the Debug Adapter Protocol, so the adapters VS Code uses work here. Module
`extra/debug`; it needs no package. The internals are in [develop/debugging.md](../develop/debugging.md).

## Starting a session

**Start Debugging…** offers the project's configurations: those of `.vscode/launch.json` (read as VS Code reads it,
comments, `${…}` variables, `inputs` and platform sections included), your own in the setting `debug.configurations`,
and a default for the file's language when there is neither. The adapters: debugpy for Python, the
JavaScript/TypeScript debugger, delve for Go, CodeLLDB or lldb-dap for C, C++ and Rust. A launch.json `compounds`
entry starts its configurations together (its own `preLaunchTask` first; with `stopAll`, stopping one stops them
all). A configuration's `preLaunchTask` (and `postDebugTask`) runs from `.vscode/tasks.json` first, in a terminal tab
where you watch it; a failing task stops the start, says why, and leaves its tab open (Enter closes it). A
background task (`isBackground`, such as `tsc -w`) is different: the session starts once its output matches its
problem matcher's `endsPattern` (the task's own, or `$tsc-watch`), and the task keeps running until its session ends.
Its output goes to the Debug Console, not a tab, because drgnx has to read every line to see the end pattern, which a
terminal tab does not give it. A background task with no end pattern is refused, because drgnx could not tell when it
is ready. The first
start in a folder asks you to trust it (**Trust This Folder**): an untrusted folder's configurations never run.

**Install Adapter…** (the palette) downloads the JavaScript debugger or CodeLLDB, checked against the version drgnx
pins, or puts debugpy into drgnx's own Python, and names the system package to install for the others (`drgnx doctor`
lists which are found). The Start picker marks a configuration whose debugger is missing "not installed"; picking it
offers the same install, on your yes, and then starts. If you used dape, **Convert dape Configurations…** (the
palette) turns your `dape-configs` into launch configurations once (dape itself is no longer needed).

## Stopping, stepping and values

A stop opens its file at the line, marked by an amber arrow and band; a caller frame you pick is marked green, and a
stop on an exception is red, with a card under the line saying what was raised (code with no file, such as an
`eval`, opens read-only from the debugger). Set `drgnx-debug-focus-on-stop` to bring Emacs to the front on a stop.
While stopped, the function's variables show their values at the ends of the lines that set them (a value that changed
since the last stop in amber); a file edited since its save shows none, and `drgnx-debug-inline-values` turns them off.
Rest the mouse on an expression (`self.items`, or inside a selection for the selection) and quick help's card shows its
value and type in the stopped frame (`drgnx-quickhelp-hover`, `drgnx-quickhelp-delay`); **Debug: Show Value at
Point** does it from the keyboard, in the echo area.

While the session is stopped the same command continues; **Toggle Breakpoint**, **Step Over**, **Step Into**,
**Step Out** and **Stop Debugging** do what they say. In the VS Code key profile: F5, F9, F10, F11 (Step Into while a
session runs — Zen Mode otherwise), S-F11, S-F5, C-S-F5 (**Restart**); the Emacs and Vim profiles reach them in the
palette. **Pause** is on the toolbar and in the palette in every profile: VS Code's F6 stays free as the terminal's
chord key ([Legacy terminals](terminal.md#legacy-terminals-altshift-and-f6)).

While a session runs, a toolbar floats over the editor: Continue (Pause while the program runs), the three steps,
Restart and Stop (Disconnect when you attached to a running program). Drag it sideways by its grip; it stays where
you put it in that frame. With two sessions or more, its chip picks the one the controls and keys act on. The setting
`drgnx-debug-toolbar` docks it in the editor's tab row (`docked`) or hides it (`hidden`); a terminal frame has no
toolbar. The status bar names the session and its state, and a **Paused** chip in the title row takes you back to the
stopped line.

## Run and Debug

**Run and Debug** (C-S-d in VS Code keys; the status bar's debug segment) is a sidebar view with four sections:
**Variables** (the stopped frame's scopes; values that changed since the last stop are highlighted, big arrays open in
pages of 100), **Watch** (expressions kept per project, evaluated at every stop), **Call Stack** (threads and frames;
pick a frame to move the editor and the variables to it) and **Breakpoints** (exception filters and every breakpoint,
each with a tick box). Arrow keys move and open, RET acts on the row, typing after `C-M-f` (`/` in the Emacs and Vim
profiles) filters it, F2 (`e`, `c`) sets a value; Copy Value, Copy as Expression and Add to Watch are in the
palette. Its header starts the configuration picked there. While the program runs, the last stop's values stay,
dimmed. A big list keeps its last 64 opened pages open; opening another closes the oldest.

**View Binary Data** (`m` in the Emacs and Vim profiles) shows a variable's bytes when its debugger can read memory
(C, C++, Rust, Go): 16 to a line in two halves of 8, with the address and the text, PageDown / PageUp (`n` / `p`, C-f /
C-b) for the next page, F2 (`e`, `c`) to write bytes typed in hex at point. Its header names the variable, the page's
address and size, and those keys.

**Open Disassembly View** (the palette) shows the machine instructions around the current frame when its debugger
can disassemble (C, C++, Rust, Go). A stop in code with no source file opens it by itself. Each run of instructions
has the source line it came from above it, in a quiet row. The arrow marks the current instruction. F9 (`b`) sets an
instruction breakpoint on the instruction at point. While the view has focus, the step keys step one instruction,
and the header shows an "instruction step" chip. `<` / `>` (`[` / `]` in Vim) read earlier or later instructions.

## The Debug Console

The **Debug Console** (the panel's tab; C-S-y in VS Code keys) shows the program's output, colours included, with
repeated lines counted (`×3`) and logpoints' messages with their file and line. Type an expression at the bottom and
press RET to evaluate it in the selected frame (S-RET adds a line; Up / Down, M-p / M-n or C-p / C-n go through what
you typed before; C-M-i completes from the debugger, when it offers completions). **Debug: Evaluate in Debug
Console** sends the selection or the expression at point there from the editor. A result with children opens in
place (RET or TAB on it); once the program runs on, it dims and no longer opens. Groups the program prints
(`console.group` in JavaScript, for one) fold the same way, on their first line. The output stays after the session
ends and is cleared when the same configuration starts again (`drgnx-debug-console-clear-on-restart`). A
`postDebugTask` that fails says so there. Turn on `drgnx-debug-console-timestamps` to see, before each line, the
time its output came in (to the millisecond); turning it off or on re-shows the lines already there.

## Breakpoints

Breakpoints live in a column left of the line numbers, kept per project (they survive restarts and reach a running
session at once). Click the column to add or remove one, drag one to another line to move it, shift-click for a
logpoint (a message printed instead of a stop; `{expression}` is replaced by its value), right-click for the line's
menu: a condition, a hit count, a log message, enable or disable, and Run to Cursor while a session runs. The dot is
red when an adapter bound it, grey before, hollow when disabled; a dot with two bars has a condition, a diamond is a
logpoint. A line you move by editing keeps its breakpoint, which takes the new line when you save.
`drgnx-debug-gutter-show` chooses when the column shows (`auto`: while the file has breakpoints or a session runs). The
**overview ruler** at the editor's right edge shows the whole file's breakpoints (red, grey when disabled or not
bound yet) and the stopped line (amber, across it), scaled to the window's height, with the part on screen as a
soft band. Click it to go there. It shows while the file has a breakpoint or a stop. Turn it off with
`drgnx-debug-overview-ruler`. Marks sit by their position in the file, not by line, as the scroll bar measures, so a
file with very long lines looks uneven. Nidhogg draws it, so there is none in a terminal.
Keys: VS Code F9 and C-F10 (Run to Cursor); Emacs `C-x C-a` and `C-b` (toggle), `C-c` (condition), `C-l` (logpoint),
`C-e` (enable), `C-u` (Run to Cursor), as GUD has them; Vim `SPC d` and `b`, `B`, `l`, `e`, `c`.

**Inline Breakpoint** (Shift+F9; `C-x C-a C-i`, `SPC d I`) stops at point's column rather than the line's first
statement, `a(b(x))` at `b` for one: a dot before that character, clicked to remove. While stopped, the lines with
breakpoints show faint dots where else the debugger can stop; click one to put an inline breakpoint there
(`drgnx-debug-inline-breakpoint-candidates` turns them off).

In the Run and Debug view's Breakpoints, **Triggered By…** (on a breakpoint) makes it wait for another: a session
does not stop on it until it has stopped on the one you picked ("waits for app.py:12" until then; "(none)" makes it a
plain breakpoint again). **Break on Value Change** (on a variable, while stopped) stops the program when that
variable changes, where the adapter can watch it (CodeLLDB and lldb-dap can; debugpy and the JavaScript debugger
cannot, and the command says so; when the adapter cannot watch one variable, its own reason is shown). It is listed
under Breakpoints with what it watches, lasts as long as its session, and `RET` on it removes it. Both are in the
palette.

## Recorded runs

Every session is recorded, against a snapshot of the files as they were when it started. **Add Probe…** records an
expression each time its line runs, without stopping the program and without printing anything; **Probe the
Result…** records what the line assigns, on the next line that runs (a probe runs before its line). A probe is a
ring with a dot in its own column, and its newest values show at the line's end as a sparkline and the last value.
A file opened while no hub runs opens without its probes and breakpoints. Probes need an adapter with logpoints
(debugpy and the JavaScript debugger take 2000 values a second, the rest 200, and delve and codelldb stop and resume
the program for each one; values past the rate are thinned and counted).

**Show Stop Timeline** opens a strip at the top: the run's stops, numbered (a dot for a breakpoint, a small dot for a
step, a triangle for an exception), and one lane per probe. Click a stop (or `RET` on it), or press `Alt ←` / `Alt →`
in the strip or a past stop, to open it read-only: the file as it ran under a banner (it says "not what ran" when the
file was unsaved at the start), the stop's line marked with its variables, and the stack and variables as they were
in a window beside it. `Alt →` past the newest stop, **Back to Live** (the palette) or the banner's button returns.

**What a run file holds.** A run is kept in drgnx's state folder as one compressed file per run: each stop's threads,
stack and the selected frame's variables (up to 64 KB a stop) and every probe's values (not the program's output),
plus a record naming its configuration and when it ran; the files as they were at its start are kept in the edit
history's own repository, not copied into the file. These are your program's values: anything it held in a variable
(a token, a password) can be in them. An agent reads them only as the matrix's `debug.read` row lets it (Cautious asks
first). Runs are kept 14 days (a pinned run, or one for an open task, longer), at most 2 GB per project, oldest
first; a run file holds 64 MB, past which the oldest probe values go, never a stop.

Recorded runs are encrypted on disk with a key kept in your keyring (the Secret Service on Linux: GNOME Keyring,
KWallet or KeePassXC; the login keychain on macOS), made on the first recorded session. drgnx never asks for your
keyring's password: when the keyring is locked or there is none, sessions are not recorded (the echo area says why),
and runs already on disk cannot be read until you log in and the keyring unlocks. If the keyring loses that key (it
is deleted, or the keyring is reset), the old runs cannot be read again: there is no copy of the key and no
unencrypted copy of the runs. They are disposable, so this is fine: they are removed at their 14 days as usual, and new
runs use a new key.

**Sending a run.** **Send Run…** writes an ended run, with the files as they were when it started, into one encrypted
file, after a card reminds you that it holds your program's values unencrypted to whoever opens it. drgnx shows a
share code once (52 letters and digits): the file opens only with it, and drgnx keeps no copy of it, so note it
before you close the card. drgnx sends nothing itself: send the file however you like, and the code another way.
**Open Sent Run…** adds a run someone sent you to your project's runs, encrypted under your own keyring's key, with its
paths moved to your project. You can read its stops and timeline; it is never run on your machine (no forks), since
its program and settings are the sender's. It is kept 14 days from when you opened it.

## What-if forks

On Linux, from a stop of a recorded run, **Fork from Here…** replays the run in a sealed copy of the project as it
was when the run started, up to that point (the same stop, or the same pass of that line), and then changes what you
choose: a value (`item.reserve` → `0`), the code, or nothing (a replay). It runs on to the next stop, the end, or a
probe's next hit, and the **What-if** tab shows it beside the run: "matched on N of M hits" (how far the copy did
what the run did before the point, and the first value that differed if one did), each probe's values after the
point, then and now, and how each side went on. For a code what-if the fork's copy opens first (**Open Fork** finds
this file there); edit it and **Run Fork**; **Take Fork's Change…** shows each file it changed as a diff and puts the
fork's text into your buffer (undoable, not saved). **Drop Fork** removes one.

A fork checks that it reached the run's pass: the same stack, and the values that change from pass to pass. When the
run passed the line only once, any value that differs stops the fork, since it may be the clock or a random number
(the fork replays Python's hash seed, nothing else); the tab says which value, and **Fork Anyway** forks at that pass
regardless.

The copy cannot reach the network or write outside itself; your `.env` files are read in place, never copied. Python
(debugpy) and JavaScript (js-debug) only: Go and native programs need `ptrace`, which the sandbox never allows. On
macOS the copy runs in the system's sandbox with a small block of local ports of its own, nothing else. A run whose
configuration resolves differently now (an input, a setting, launch.json) is refused, and a point the run took over a
minute to reach asks first.

## Debugging with an agent

Ask an agent to debug this with you and it works beside you, under the permissions matrix's `debug.*` rows
([security.md](security.md#the-permissions-matrix)): it reads your sessions and recorded runs, adds probes and
breakpoints (ringed in the agent's colour; the tooltip says which agent set them, and it removes only its own), forks
what-ifs, and, where the matrix allows, evaluates or steps in your live session. If you step first, its step is
refused: yours wins. It writes down hypotheses with their evidence; **Show Investigation** lists them (open,
confirmed, rejected) and **Explain Investigation…** asks it to tell the story in its chat. A fix is offered only after
it ran in a fresh fork of the run and passed (the program ended cleanly without the failure): **Review Agent's Fix**
shows its diff against your buffers with the hypothesis' evidence, and **Accept Agent's Fix** puts it in your buffers
as the agent's change in the edit history (undoable, not saved).

## Which change broke it?

**Find the Change That Broke It…** (the palette) answers "which change broke it?". Pick a state where it worked (a
commit, a recorded run's start, one of your saves or an agent's step) and a command that fails now, such as a test
(exit 0 passes, 125 skips the state, 1–127 fails). The hub runs it over the states in between, three at a time,
each in a copy of the project moved from state to state, and a card shows a dot per state and then the first bad one:
what it was, who made it (you, an agent with its step and decision, or a commit's author), and a warning when a state
gave different answers twice (flaky) or could not be judged. **Show Step** opens the change as a diff; for an agent's
step, **Revert Step** opens the revert card (nothing changes until you apply it) and **Ask the Agent** tells that
agent what broke; **Narrow** finds the hunks of the change that make it fail. `RET` on an action runs it.

## Where did this come from?

**Where Did This Come From?** (Alt-click a name at a recorded stop, or the palette) shows, for a Python program, the
chain that gave a value: the line that last set it, with the values of what it was computed from, then where each of
those came from, up to three levels. The hub replays the recorded run to that stop with a small tracer on, one replay
a level, so the chain is exact; a change made inside a call (`items.append(x)`) shows as "changed inside
`list.append`". `RET` on a link opens it as a past stop. Python older than 3.12 has no tracing hook: the card then
lists the assignments to the name in the files that ran, labelled "candidates, not traced".

JavaScript, TypeScript, Go, C, Rust and Java programs get the same card, traced another way: the replay puts a
logpoint on every line that sets the name, so the chain shows which of those ran last and what it read. A value is
shown only when reading it again runs nothing (no call). The card says what this cannot see: a value set through
another name, or in a file that is neither the stop's nor on its stack.
