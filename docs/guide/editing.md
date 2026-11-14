# Editing code

What drgnx adds to editing code, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one
off), and each that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)); until then the
module waits.

In a large file, sticky scroll, guides, blame and the language server stay off.

## Language support (tree-sitter)

Every language is a **language pack** (`packs/` in drgnx: Python, JavaScript, TypeScript, TSX, Go, Rust, Java, C, C++,
shell, Ruby, Lua, HTML, CSS, JSON, YAML, TOML, PHP, Elixir, Haskell, Kotlin, Swift, Zig and SQL, and the format-only Terraform and
Dart). PHP and Elixir use Emacs's own tree-sitter modes, Haskell the `haskell-ts-mode` package (installed with the pack),
and Kotlin, Swift, Zig and SQL drgnx's shared tree-sitter mode (`drgnx-pack-ts-mode`): highlighting from the pack's
queries, navigation to its definitions, indentation from the previous line and the pack's rules. A pack names a language's
tree-sitter grammar (pinned to the commit Emacs's own mode pins), its modes and its formatter; the manifest format is
in `docs/develop/packs.md`.

Code buffers use a language's **tree-sitter mode** (faster, more precise highlighting and navigation) when its pack is
installed and its grammar loads (module `lang/packs`). A file whose pack is not installed opens as usual, and the echo
area says once per pack, per session, that **Install Language Support** (in the palette) adds it — never a question
(Emacs's own "install this grammar?" prompt is turned off).

The command runs `drgnx packs sync --add NAME` in the background (a durable job: Show Job Log → `packs`; it needs `git`
and a C compiler): the grammar is fetched at its pinned commit, checked against the pinned tree hash, built, and loaded
once in a separate process as a check (a grammar that crashes there fails the install and nothing else), then the lock,
a generation (`drgnx rollback` brings the packs back too) and the grammar folder `~/.local/share/drgnx/grammars/LANG/COMMIT/`
follow. When it is done, open files of that language switch to its tree-sitter mode, and new ones open in it. A grammar
a parser was already made for in this session keeps its folder until you restart, so an update never mixes two builds.
`drgnx packs list` shows the packs and which are installed. Format on save needs no install: a language whose formatter
is its community's standard (Go, Rust, Terraform, Dart) is formatted in any project.

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
`pyproject.toml` with `[tool.black]` or `[tool.ruff]`, `biome.json`, `deno.json`, `stylua.toml`, a `.google-java-format` marker file for Java (google-java-format reads no config of its own: an empty file of that name in the project root says "this project formats this way"), … — so saving a file
in someone else's repository never rewrites it in a style it does not use. Lisp and BibTeX files are never
re-indented on save. A formatter that is not installed, or fails, leaves the file as you saved it; nothing asks.
**Toggle Format on Save** turns it off or on in this buffer (with `C-u`, everywhere). Module `extra/format`, package
`apheleia`.

## Debugging

Breakpoints, stepping, the Run and Debug view, the Debug Console, recorded runs, what-if forks and debugging with an
agent have a page of their own: [debugging.md](debugging.md).

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
with and without a selection and the delay; the Explorer's own keys); `test/unit/mod-lang-packs-test.el` (the packs applied, the hint once and never a prompt, the install as a job
and its command, buffers switching after it); `test/unit/mod-amenities-test.el` (the modules wait without their
package and run with it; the booster only with its program; a missing formatter still saves); `mod-sticky-test.el` (the scopes' names, outermost first, at most three, one line, the
cost of a scroll step, never waiting for a parse that is not ready); `mod-markdown-test.el` (GFM for READMEs, the preview through pandoc or without a program,
Mermaid as a job once, without mmdc nothing); `test/ui/code-editing-test.el` (on a graphical frame: the sticky
scopes of a long function, indent guides, smooth scrolling, a screenshot); the perf workload `code-scrolling`
([perf.md](../develop/perf.md)).
