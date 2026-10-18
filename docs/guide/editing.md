# Editing code

What drgnx adds to editing code, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one
off), and each that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)); until then the
module waits.

## Language support (tree-sitter)

Code buffers use a language's **tree-sitter mode** (faster, more precise highlighting and navigation) when its
grammar is installed (`lang/eglot`, reading the language/mode table of `lang/grammars`, `drgnx-grammars-modes`). A file whose grammar is missing opens as usual, and the echo area says once per
language, per session, that **Install Language Support** (in the palette) adds it — never a question.

The command builds the grammar in the background (a durable job: Show Job Log → `grammars`; it needs `git` and a C
compiler) into `~/.local/share/drgnx/tree-sitter/`; when it is done, open files of that language switch to its
tree-sitter mode, and new ones open in it. A grammar counts as installed only when it was built and this Emacs can
load it — otherwise the job says it failed (its log tells why: no `git`, no compiler, a grammar newer than this
Emacs's tree-sitter). On Emacs 31 a tree-sitter mode that names its own grammar version is built at that version; otherwise each grammar is built at a pinned release tag whose parser is tree-sitter ABI 14. Emacs 30 always builds the pinned tags, whatever its tree-sitter library supports (a pinned parser loads in a newer library, and Emacs 30's tree-sitter modes were written against those grammar versions); Emacs 31 or later with an ABI 15 library (`treesit-library-abi-version`) builds the default branch instead. Languages: bash, c, cpp, css, go, html, java, javascript, json, lua,
python, ruby, rust, toml, tsx, typescript, yaml (module `lang/grammars`, sources in `drgnx-grammars-sources`).

## Faster language servers

With the [`emacs-lsp-booster`](https://github.com/blahgeek/emacs-lsp-booster) program installed (its release binary
on your `PATH`), eglot talks to every language server through it: the server's JSON is parsed outside Emacs, so a big
answer (completions, diagnostics of a large file) no longer stalls typing (module `extra/booster`, package
`eglot-booster` — from Git, `drgnx sync` installs it). Without the program nothing changes.

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

**Start Debugging…** runs a debug session through dape, which speaks the Debug Adapter Protocol: the adapters VS
Code uses — debugpy for Python, the JavaScript/TypeScript debugger, delve for Go, codelldb for C, C++ and Rust — work
here once installed (dape's documentation lists how to get each). While the session is stopped the same command
continues; **Toggle Breakpoint**, **Step Over**, **Step Into**, **Step Out** and **Stop Debugging** do what they say.
In the VS Code key profile: F5, F9, F10, F11 (Step Into while a session runs — Zen Mode otherwise), S-F11, S-F5; the
Emacs and Vim profiles reach them in the palette. dape's windows (scopes, stack, breakpoints, the REPL) open on the
right, so the panel stays the workbench's. Module `extra/debug`, package `dape`.

## Indent guides

Thin vertical guides at each indentation level of code and YAML, on graphical frames, drawn by indent-bars (stipples,
not characters: they cost little and the cursor never lands on them; with tree-sitter they follow the code's
structure). Their colour comes from the theme — the `highlight` face, blended — so they follow theme changes.
**Toggle Indent Guides** for this buffer. Module `extra/guides`, package `indent-bars`.

## Smooth scrolling

Touchpad and wheel scrolling move by pixels, not lines, on graphical frames: with
[ultra-scroll](https://github.com/jdtsmith/ultra-scroll) when it is installed (faster on large buffers — add
`ultra-scroll` to `:packages` in `packages.eld`), else Emacs's own `pixel-scroll-precision-mode`. Terminal frames
scroll by lines as always. **Toggle Smooth Scrolling**. Module `ui/smooth`.

## Sticky scroll

When the start of the function, class or block you are in has scrolled off the top, its first line shows in the
header, after the breadcrumb — up to three enclosing scopes, outermost first: `src › shape.py › class Shape: › def
area(self):`. The header line is always there (the breadcrumb), so nothing moves as you scroll — except in a terminal window with
fewer than 30 frame lines (31 terminal rows with the menu bar on), where the breadcrumb row is off and the scopes,
which share its row, are hidden too. Scopes come from
tree-sitter when the buffer has a parser (functions, methods, classes, structs, …), else from indentation; each
position is worked out once, and again only when the text above the window's top changes. **Toggle Sticky Scroll** for this buffer. Module `editor/sticky` (drgnx's own; a buffer
can add to the header the same way: `drgnx-chrome-header-tail`).

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
  | X11 (Emacs built for X) | `x-selection-timeout` bounds the read (Emacs 30 `src/xselect.c`). Read from the source; not run here. |
  | Wayland (pgtk build) | `pgtk-selection-timeout` bounds the read (Emacs 30 `src/pgtkselect.c`, `pgtk_get_foreign_selection`). Run: in a headless compositor with a clipboard owner stopped with SIGSTOP, the read ends with an error after 1.50 s; with the timeout at 0 it never ends. An owner reached through XWayland was not tried. |
  | macOS | Untouched: Emacs has no selection timeout there (the pasteboard is read in the same process), so drgnx claims nothing. |
  | Terminal window | Nothing to bound: drgnx never reads the terminal's clipboard unless you turn that on ([terminal.md](terminal.md#clipboard)). |
- **Selecting text does not create clipboard entries.** Some managers copy the selection (PRIMARY) into the
  clipboard, so every mouse selection or `shift`-selection becomes a history entry. drgnx looks, once at
  startup and without waiting, for Klipper with `SyncClipboards=true` in `klipperrc`, CopyQ with `copy_selection`
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
package and run with it; the booster only with its program; a missing formatter still saves); `mod-sticky-test.el` (the scopes, outermost first, at most three, one line, the
cost of a scroll step); `mod-markdown-test.el` (GFM for READMEs, the preview through pandoc or without a program,
Mermaid as a job once, without mmdc nothing); `test/ui/code-editing-test.el` (on a graphical frame: the sticky
scopes of a long function, indent guides, smooth scrolling, a screenshot); the perf workload `code-scrolling`
([perf.md](../develop/perf.md)).
