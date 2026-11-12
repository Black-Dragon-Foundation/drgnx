# Editing code

What drgnx adds to editing code, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one
off), and each that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)); until then the
module waits.

In a large file, sticky scroll, guides, blame and the language server stay off.

## Language support (tree-sitter)

Code buffers use a language's **tree-sitter mode** (faster, more precise highlighting and navigation) when its
grammar is installed (`lang/eglot`, reading the language/mode table of `lang/grammars`, `drgnx-grammars-modes`). A file whose grammar is missing opens as usual, and the echo area says once per
language, per session, that **Install Language Support** (in the palette) adds it — never a question.

The command builds the grammar in the background (a durable job: Show Job Log → `grammars`; it needs `git` and a C
compiler) into `~/.local/share/drgnx/tree-sitter/`; when it is done, open files of that language switch to its
tree-sitter mode, and new ones open in it. A grammar counts as installed only when it was built and this Emacs can
load it — otherwise the job says it failed (its log tells why: no `git`, no compiler, a grammar newer than this
Emacs's tree-sitter). A tree-sitter mode that names its own grammar version is built at that version; otherwise each grammar is built at a pinned release tag whose parser is tree-sitter ABI 14. Emacs 30 always builds the pinned tags, whatever its tree-sitter library supports (a pinned parser loads in a newer library, and Emacs 30's tree-sitter modes were written against those grammar versions); Emacs 31 or later with an ABI 15 library (`treesit-library-abi-version`) builds the default branch instead. Languages: bash, c, cpp, css, go, html, java, javascript, json, lua,
python, ruby, rust, toml, tsx, typescript, yaml (module `lang/grammars`, sources in `drgnx-grammars-sources`).

## Faster language servers

With the [`emacs-lsp-booster`](https://github.com/blahgeek/emacs-lsp-booster) program installed (its release binary
on your `PATH`), eglot talks to every language server through it: the server's JSON is parsed outside Emacs, so a big
answer (completions, diagnostics of a large file) no longer stalls typing (module `extra/booster`, package
`eglot-booster` — from Git, `drgnx sync` installs it). Without the program nothing changes. The booster is not used
while Nidhogg's own reading of language servers is on (`nidhogg-workers-framing`): its worker thread then finds and
parses the messages, which the booster would make it stand back from.

## The language server log

eglot copies every message to and from a server into a log buffer, which costs time on big answers; drgnx turns that
off. **Show LSP Log** (Code, in the palette) turns it on and shows the current server's log, and turns it off when you
run it again. A running server keeps the setting it started with: the log fills from the next server you start.

## Format on save

Saving formats the buffer with its language's formatter — black or ruff for Python, prettier for JavaScript,
TypeScript and CSS, gofmt, rustfmt, clang-format, … (apheleia's list) — when that formatter is installed: in the
background, after the save, keeping the point and the view where they were. It formats only code whose project
formats it: Go, Rust, Zig, Elixir, Terraform and Dart always (their formatter is their standard); other languages
only under a formatter's config — `.prettierrc*`, `prettier.config.*`, `.clang-format`, `ruff.toml`, a
`pyproject.toml` with `[tool.black]` or `[tool.ruff]`, `biome.json`, `deno.json`, `stylua.toml`, … — so saving a file
in someone else's repository never rewrites it in a style it does not use. Lisp and BibTeX files are never
re-indented on save. A formatter that is not installed, or fails, leaves the file as you saved it; nothing asks.
**Toggle Format on Save** turns it off or on in this buffer (with `C-u`, everywhere). Module `extra/format`, package
`apheleia`.

## Debugging

**Start Debugging…** runs a debug session through drgnx's own client of the Debug Adapter Protocol, so the adapters
VS Code uses work here: debugpy for Python, the JavaScript/TypeScript debugger, delve for Go, CodeLLDB or lldb-dap for
C, C++ and Rust. It offers the project's configurations: those of `.vscode/launch.json` (read as VS Code reads it,
comments, `${…}` variables, `inputs` and platform sections included), your own in the setting `debug.configurations`,
and a default for the file's language when there is neither. A configuration's `preLaunchTask` (and `postDebugTask`)
runs from `.vscode/tasks.json` first; a failing task stops the start and says why. The first start in a folder asks
you to trust it (**Trust This Folder**): an untrusted folder's configurations never run.

**Install Adapter…** (the palette) downloads the JavaScript debugger or CodeLLDB, checked against the version drgnx
pins, or puts debugpy into drgnx's own Python, and names the system package to install for the others (`drgnx doctor`
lists which are found).

A stop opens its file at the line, marked by an amber arrow and band; a caller frame you pick is marked green, and a
stop on an exception is red, with a card under the line saying what was raised (code with no file, such as an
`eval`, opens read-only from the debugger). Set `drgnx-debug-focus-on-stop` to bring Emacs to the front on a stop.
While stopped, the function's variables show their values at the ends of the lines that set them (a value that changed
since the last stop in amber); a file edited since its save shows none, and `drgnx-debug-inline-values` turns them off.
While the session is stopped the same command continues; **Toggle Breakpoint**, **Step Over**, **Step Into**,
**Step Out** and **Stop Debugging** do what they say. If you used dape, **Convert dape Configurations…** (the palette)
turns your `dape-configs` into launch configurations once (dape itself is no longer needed).
In the VS Code key profile: F5, F9, F10, F11 (Step Into while a session runs — Zen Mode otherwise), S-F11, S-F5,
C-S-F5 (**Restart**); the Emacs and Vim profiles reach them in the palette. **Pause** is on the toolbar and in the
palette in every profile: VS Code's F6 stays free as the terminal's chord key ([Legacy terminals](terminal.md#legacy-terminals-altshift-and-f6)).
Module `extra/debug`; it needs no package.

While a session runs, a toolbar floats over the editor: Continue (Pause while the program runs), the three steps,
Restart and Stop (Disconnect when you attached to a running program). Drag it sideways by its grip; it stays where
you put it in that frame. With two sessions or more, its chip picks the one the controls and keys act on. The setting
`drgnx-debug-toolbar` docks it in the editor's tab row (`docked`) or hides it (`hidden`); a terminal frame has no
toolbar. The status bar names the session and its state, and a **Paused** chip in the title row takes you back to the
stopped line.

**Run and Debug** (C-S-d in VS Code keys; the status bar's debug segment) is a sidebar view with four sections:
**Variables** (the stopped frame's scopes; values that changed since the last stop are highlighted, big arrays open in
pages of 100), **Watch** (expressions kept per project, evaluated at every stop), **Call Stack** (threads and frames;
pick a frame to move the editor and the variables to it) and **Breakpoints** (exception filters and every breakpoint,
each with a tick box). Arrow keys move and open, RET acts on the row, typing after `C-M-f` (`/` in the Emacs and Vim
profiles) filters it, F2 (`e`, `c`) sets a value; Copy Value, Copy as Expression and Add to Watch are in the
palette. Its header starts the configuration picked there. While the program runs, the last stop's values stay, dimmed.

Breakpoints live in a column left of the line numbers, kept per project (they survive restarts and reach a running
session at once). Click the column to add or remove one, shift-click for a logpoint (a message printed instead of
a stop; `{expression}` is replaced by its value), right-click for the line's menu: a condition, a hit count, a log
message, enable or disable, and Run to Cursor while a session runs. The dot is red when an adapter bound it, grey
before, hollow when disabled; a dot with two bars has a condition, a diamond is a logpoint. A line you move by
editing keeps its breakpoint, which takes the new line when you save. `drgnx-debug-gutter-show` chooses when the
column shows (`auto`: while the file has breakpoints or a session runs). Keys: VS Code F9 and C-F10 (Run to Cursor);
Emacs `C-x C-a` and `C-b` (toggle), `C-c` (condition), `C-l` (logpoint), `C-e` (enable), `C-u` (Run to Cursor), as
GUD has them; Vim `SPC d` and `b`, `B`, `l`, `e`, `c`.

Every session is recorded, against a snapshot of the files as they were when it started. **Add Probe…** records an
expression each time its line runs, without stopping the program and without printing anything; **Probe the
Result…** records what the line assigns, on the next line that runs (a probe runs before its line). A probe is a
ring with a dot in its own column, and its newest values show at the line's end as a sparkline and the last value.
A file opened while no hub runs opens without its probes.
**Show Stop Timeline** opens a strip at the top: the run's stops, numbered (a dot for a breakpoint, a small dot for a
step, a triangle for an exception), and one lane per probe. Click a stop (or `RET` on it), or press `Alt ←` / `Alt →` in the strip or
a past stop, to open it read-only: the file as it ran under a banner (it says "not what ran" when
the file was unsaved at the start), the stop's line marked with its variables, and the stack and variables as they
were in a window beside it. `Alt →` past the newest stop, **Back to Live** (the palette) or the banner's button returns.
Recorded runs hold your program's values: an agent reads them only as the matrix's `debug.read` row lets it (Cautious asks
first). They are kept 14 days (a pinned
run, or one for an open task, longer), at most 2 GB per project, oldest first. Probes need an adapter with logpoints
(debugpy and the JavaScript debugger take 2000 values a second, the rest 200, and delve and codelldb stop and resume
the program for each one; values past the rate are thinned and counted).

**What-if forks** (Linux): from a stop of a recorded run, **Fork from Here…** replays the run in a sealed copy of the
project as it was when the run started, up to that point (the same stop, or the same pass of that line), and then
changes what you choose: a value (`item.reserve` → `0`), the code, or nothing (a replay). It runs on to the next
stop, the end, or a probe's next hit, and the **What-if** tab shows it beside the run: "matched on N of M hits" (how
far the copy did what the run did before the point, and the first value that differed if one did), each probe's
values after the point, then and now, and how each side went on. For a code what-if the fork's copy opens first
(**Open Fork** finds this file there); edit it and **Run Fork**; **Take Fork's Change…** shows each file it changed
as a diff and puts the fork's text into your buffer (undoable, not saved). **Drop Fork** removes one.
A fork checks that it reached the run's pass: the same stack, and the values that change from pass to pass. When the
run passed the line only once, any value that differs stops the fork, since it may be the clock or a random number
(the fork replays Python's hash seed, nothing else); the tab says which value, and **Fork Anyway** forks at that pass
regardless.
The copy cannot reach the network or write outside itself; your `.env` files are read in place, never copied. Python
(debugpy) and JavaScript (js-debug) only: Go and native programs need `ptrace`, which the sandbox never allows, and
macOS forks wait for a sandbox rule of their own. A run whose configuration resolves differently now (an input, a
setting, launch.json) is refused, and a point the run took over a minute to reach asks first.

**Debugging with an agent.** Ask an agent to debug this with you and it works beside you, under the permissions
matrix's `debug.*` rows ([security.md](security.md#the-permissions-matrix)): it reads your sessions and recorded runs,
adds probes and breakpoints (ringed in the agent's colour; the tooltip says which agent set them, and it removes only
its own), forks what-ifs, and, where the matrix allows, evaluates or steps in your live session. If you step first,
its step is refused: yours wins. It writes down hypotheses with their evidence; **Show Investigation** lists them
(open, confirmed, rejected) and **Explain Investigation…** asks it to tell the story in its chat. A fix is offered only
after it ran in a fresh fork of the run and passed (the program ended cleanly without the failure): **Review Agent's
Fix** shows its diff against your buffers with the hypothesis' evidence, and **Accept Agent's Fix** puts it in your
buffers as the agent's change in the edit history (undoable, not saved).

**Find the Change That Broke It…** (the palette) answers "which change broke it?". Pick a state where it worked (a
commit, a recorded run's start, one of your saves or an agent's step) and a command that fails now, such as a test
(exit 0 passes, 125 skips the state, 1–127 fails). The hub runs it over the states in between, three at a time,
each in a copy of the project moved from state to state, and a card shows a dot per state and then the first bad one:
what it was, who made it (you, an agent with its step and decision, or a commit's author), and a warning when a state
gave different answers twice (flaky) or could not be judged. **Show Step** opens the change as a diff; for an agent's
step, **Revert Step** opens the revert card (nothing changes until you apply it) and **Ask the Agent** tells that
agent what broke; **Narrow** finds the hunks of the change that make it fail. `RET` on an action runs it.

**Where Did This Come From?** (Alt-click a name at a recorded stop, or the palette) shows, for a Python program, the
chain that gave a value: the line that last set it, with the values of what it was computed from, then where each of
those came from, up to three levels. The hub replays the recorded run to that stop with a small tracer on, one replay
a level, so the chain is exact; a change made inside a call (`items.append(x)`) shows as "changed inside
`list.append`". `RET` on a link opens it as a past stop. Python older than 3.12 has no tracing hook: the card then
lists the assignments to the name in the files that ran, labelled "candidates, not traced".

## Indent guides

Thin vertical guides at each indentation level of code and YAML, on graphical frames, drawn by indent-bars (stipples,
not characters: they cost little and the cursor never lands on them; with tree-sitter they follow the code's
structure). Their colour comes from the theme — the `shadow` face, blended — so they follow theme changes.
**Toggle Indent Guides** for this buffer. Module `extra/guides`, package `indent-bars`: **off until you choose it**
(Settings → Modules, or `extra/guides` in modules.eld), as the look's code shows no guides.

## Smooth scrolling

Touchpad and wheel scrolling move by pixels, not lines, on graphical frames: with
[ultra-scroll](https://github.com/jdtsmith/ultra-scroll) when it is installed (faster on large buffers — add
`ultra-scroll` to `:packages` in `packages.eld`), else Emacs's own `pixel-scroll-precision-mode`. Terminal frames
scroll by lines as always. **Toggle Smooth Scrolling**. Module `ui/smooth`.

## Sticky scroll

When the start of the function, class or block you are in has scrolled off the top, its name shows in the header,
after the breadcrumb and in the breadcrumb's type — up to three enclosing scopes, outermost first: `src › shape.py ›
Shape › area`. A scope that names nothing (a `let` in Lisp, an `if` block) is left out. The header line is always there (the breadcrumb), so nothing moves as you scroll — except in a terminal window with
fewer than 30 frame lines (31 terminal rows with the menu bar on), where the breadcrumb row is off and the scopes,
which share its row, are hidden too. Scopes come from
tree-sitter when the buffer has a parser (functions, methods, classes, structs, …), else from indentation (also while
the tree is not ready — a large file's first parse still running on Nidhogg's parse worker: the header never waits for
it and redraws once the tree is there); each
position is worked out once, and again only when the text above the window's top changes. Scrolling inside the same
scopes reuses their names (the scope lines are read once), and a comment block or a long string above the
top is passed in one step, however many lines it has. **Toggle Sticky Scroll** for this buffer. Module `editor/sticky` (drgnx's own). It is one of the header's tail providers: add your own with
`drgnx-chrome-add-tail-provider` (a function of a window returning a string or nil, and a depth; lowest first).

## Markdown

Markdown files open in markdown-mode — READMEs as GitHub Flavored Markdown — with code blocks highlighted in their
own language, math marked, headings scaled, and remote pictures not fetched. **Markdown: Open Preview** (C-S-v in markdown buffers only, in the
VS Code profile) renders the file beside it and again after each save: through `pandoc` (or `cmark-gfm`, `cmark`,
`markdown` — the first installed; tables, task lists and links as GitHub shows them), else markdown-mode's own view.
The conversion runs in the background (typing never waits for it); local pictures show, pictures on the network do
not (the preview fetches nothing).

` ```mermaid ` blocks become pictures when [`mmdc`](https://github.com/mermaid-js/mermaid-cli) is installed: each is
drawn in the background (a durable job, Show Job Log → `mermaid`) into `~/.cache/drgnx/mermaid/`, by its text's hash,
so a diagram is drawn once (in mmdc's dark theme under a dark one); until it is, it shows as code — and one mmdc
cannot draw (a typo) stays code, said once, until its text changes. Module `lang/markdown`, package `markdown-mode`.

## Copy, cut and paste

**Copy**, **Cut** and **Paste** work on the selection. In the VS Code profile they are `C-c`, `C-x` and `C-v`
(`s-c`, `s-x`, `s-v` on a Mac): `C-c` and `C-x` act only while text is selected, so without a selection they stay
Emacs's prefixes (`C-x C-s`, `C-c C-c` in a mode). Paste replaces the selection, in one undo step. The Emacs profile
keeps `M-w`, `C-w` and `C-y`; the Vim profile `y`, `d` and `p`. A prefix key typed with a selection (`C-x C-s`, `C-x b`) still works: they wait 0.3 seconds
(`drgnx-editing-prefix-delay`) for the next key before they cut. Details are in [keys.md](keys.md#copy-cut-and-paste). In a terminal window the copy also reaches the terminal's
clipboard ([terminal.md](terminal.md#clipboard)). Module `editor/editing`.

## The system clipboard

Clipboard managers (GPaste and Clipboard Indicator on GNOME, Klipper on KDE, CopyQ, Maccy, the Windows clipboard
history) keep every change of the clipboard, and Emacs by default changes it a lot. Module `editor/clipboard`
(on by default) deals with three clashes:

- **Kills do not fill the history.** The line and word kills (`C-k`, `M-d`, `M-DEL`, `C-S-DEL`, `M-z`, the sexp,
  sentence and paragraph kills, evil's `x` and `D`, and drgnx's Delete Word Left and Delete to Line Start —
  `Ctrl+Backspace` and `Cmd+Backspace` in the VS Code profile) stay in Emacs's kill ring; they are listed in
  `drgnx-clipboard-local-kills`. Everything else reaches the system clipboard as in plain Emacs: copy and cut,
  commands of other packages (Magit's copy commands, Embark's), and kills made by Lisp or a timer with no command
  running. In a terminal window the same rule decides what reaches the terminal's clipboard over OSC 52, so a
  laptop's manager is not flooded over SSH either. `C-y` still brings in what another program copied last. Setting
  `drgnx-clipboard-kills` to `all` gives Emacs's own behaviour back; code can bind `drgnx-clipboard-force` to push a
  kill whatever the command. A command's first kill decides for the whole command, and it pushes once.
- **A clipboard owner that does not answer cannot freeze Emacs for ever.** Emacs waits for ever for the program that
  owns the clipboard; a stuck one froze the whole session. drgnx makes the wait end after
  `drgnx-clipboard-read-timeout` seconds (1.5). Emacs then reports it itself in the echo area (`gui-get-selection:
  (error "Timed out waiting for reply from selection owner")`) and the paste comes from the kill ring; drgnx adds
  no message of its own on that path (its once-per-session message only appears for a paste function that does not
  catch the error, which Emacs's own does). It sets the timeout variable only while it is at Emacs's standard 0, so a value you
  chose stays. What is guaranteed depends on the window system; the wait is still a wait (Emacs does not take
  input for up to 1.5 s per paste):

  | Where | Guarantee |
  |---|---|
  | X11 (Emacs built for X) | `x-selection-timeout` bounds the read (Emacs `src/xselect.c`). Read from the source; not run here. |
  | Wayland (pgtk build) | `pgtk-selection-timeout` bounds the read (Emacs `src/pgtkselect.c`, `pgtk_get_foreign_selection`). Run: in a headless compositor with a clipboard owner stopped with SIGSTOP, the read ends with an error after 1.50 s; with the timeout at 0 it never ends. An owner reached through XWayland was not tried. |
  | macOS | Untouched: Emacs has no selection timeout there (the pasteboard is read in the same process), so drgnx claims nothing. |
  | Terminal window | Nothing to bound: drgnx never reads the terminal's clipboard unless you turn that on ([terminal.md](terminal.md#clipboard)). |
- **Selecting text does not create clipboard entries.** Some managers copy the selection (PRIMARY) into the
  clipboard, so every mouse selection or `shift`-selection becomes a history entry. drgnx looks, at startup and
  again whenever a graphical window opens (so a manager started later is found), without waiting, for Klipper with `SyncClipboards=true` in `klipperrc`, CopyQ with `copy_selection`
  or `check_selection` on, and GPaste with *synchronize clipboards* or *primary to history* on (asked from
  `gsettings` in the background, one second at most; either one alone is enough, because *primary to history* puts
  every selection into the history and *synchronize clipboards* copies it to the clipboard, which GPaste records),
  on X11 and Wayland windows. With `drgnx-clipboard-publish-selection` at `auto` (the default) it then turns
  `select-active-regions` off; `t` makes selections publish (a setting such as `only` that already publishes stays),
  `nil` never does. The doctor shows what was found and what drgnx changed (`drgnx-clipboard-doctor-facts`).

Module `editor/clipboard`. Tests: `test/unit/mod-clipboard-test.el`.

## Tests

`test/unit/edit-clipboard-test.el` (the keys pressed through the command loop in each profile; the prefixes
with and without a selection and the delay; the Explorer's own keys); `test/unit/mod-grammars-test.el` (the language of a buffer, the hint once and never a prompt, the install as a job
and its command, buffers switching after it); `test/unit/mod-amenities-test.el` (the modules wait without their
package and run with it; the booster only with its program; a missing formatter still saves); `mod-sticky-test.el` (the scopes' names, outermost first, at most three, one line, the
cost of a scroll step, never waiting for a parse that is not ready); `mod-markdown-test.el` (GFM for READMEs, the preview through pandoc or without a program,
Mermaid as a job once, without mmdc nothing); `test/ui/code-editing-test.el` (on a graphical frame: the sticky
scopes of a long function, indent guides, smooth scrolling, a screenshot); the perf workload `code-scrolling`
([perf.md](../develop/perf.md)).
