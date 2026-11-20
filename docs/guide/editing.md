# Editing code

What drgnx adds to editing code, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one
off), and each that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)); until then the
module waits.

In a large file, sticky scroll, guides, blame and the language server stay off.

## Font size, tab size and word wrap

The three settings a VS Code user looks for first are at the top of Settings → Editor, with VS Code's meanings and
changes apply at once:

| Setting | VS Code's | Default | What it does |
|---|---|---|---|
| `drgnx-editing-font-size` | `editor.fontSize` | 13.5 | The code font's size in pixels. 13.5 is drgnx's own code size (VS Code's is 14); the code font role (`drgnx-look-font-code`) can still set a size of its own, which wins. |
| `drgnx-editing-tab-size` | `editor.tabSize` | 4 | Columns a tab takes, and an indent where the mode has none of its own. A mode with its own indent keeps it. |
| `drgnx-editing-word-wrap` | `editor.wordWrap` | `auto` | What a line longer than its window does. `off` lets it run past the edge; `on` continues it on the next row at a word (narrow windows too, with no continuation arrows in the fringes, as in VS Code); `column` wraps it at `drgnx-editing-word-wrap-column` (VS Code's `wordWrapColumn`), and at the window's edge when the window is narrower; `bounded` is the same. `auto` wraps prose (Markdown, Org, reStructuredText, LaTeX, commit messages, plain text) and cuts code, configuration and data (YAML, TOML, HTML, XML, CSS, JSON). A `(:mode MODE …)` entry gives one language its own. Buffers that are not code, data or text (the Explorer, tables, the work graph) keep their own. Under `auto` and `on` drgnx also wraps Org, which cuts by default (`org-startup-truncated`), unless you set that yourself. A file's own `truncate-lines` or `word-wrap` (a local variables line, `.dir-locals.el`) still wins. |
| `drgnx-editing-word-wrap-column` | `editor.wordWrapColumn` | 80 | The column `column` and `bounded` wrap at; the other values ignore it. |

**Toggle Word Wrap** (palette, View menu; VS Code profile Alt+Z, Emacs profile `C-x x t`, Vim profile `SPC t w`)
wraps or cuts one buffer until you close it. A restart opens the file with the setting's wrap again.

Your old `drgnx-face-line-wrap` (gone) was folded into `drgnx-editing-word-wrap` once, at the first start of this
version. A value you set (in Settings, `settings.el`, a private workspace file, Customize or your Lisp) was kept and
mapped (`word` is `on`, `truncate` is `off`), a value drgnx had written for you was dropped (so `auto` applies), and
anything it could not map (a project's shared `.drgnx/settings.el`, `nil`, a computed value) is listed in
**Settings: Migration Report**, untouched.

Indents are made of spaces, as VS Code's `editor.insertSpaces`, in every key profile: `indent-tabs-mode` defaults to
nil (Emacs's own default, tabs, would turn every 4-column indent into a tab now that a tab is 4 columns). A mode with tabs
of its own (Makefile, Go), a file's own indentation and `.editorconfig` still win.

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

## Folding

Fold a block to see the code around it: **Fold** (`C-{` in the VS Code keys, `C-c @ C-h` in the Emacs keys, `z c` in
the Vim keys) hides the block at the cursor after its first line, which then ends with `⋯ N lines`; **Unfold** shows it
again, **Toggle Fold** does whichever applies. Fold on a line already folded folds the block around it. Fold says
what it hid in the echo area, for example `folded 38 lines, 2 errors`, which screen readers read.

A chevron in the left fringe marks each line that starts a block: it shows while the pointer is over the fringe (a
folded block's, pointing right, always shows), and a click on it folds or unfolds that block. `drgnx-fold-arrows` sets
when they show (`hover`, `always`, or none). Nidhogg draws them from the line model as the window is drawn, so they cost
nothing as you scroll. The minimap shows a folded block as a dashed pill after its first line: the fold's name when
you named it, else `⋯ N folded`.

- **Fold All** / **Unfold All**; **Fold Recursively** / **Unfold Recursively** (the block and every block in it);
  **Fold Level…** (every block at one nesting level, 1 the outermost, but the one you are in; VS Code's `C-k C-1` …
  `C-k C-7`); **Fold One Level More** / **Less** (Vim's `z m` / `z r`: the deepest blocks still open fold, the
  deepest folded open); **Fold by Kind…** (functions, classes, comments, imports, tests, regions or cells, as the file has them;
  `C-k C-/` folds the comments); **Fold All Except Here** folds every block that does not hold the cursor or the
  selection and opens those that do; **Unfold All Except Here** opens every fold but those; **Next / Previous Fold**.
- **Create Fold from Selection** folds the selected lines, with an optional name shown when it is folded; **Name
  Fold…** and **Remove Manual Fold** act on the one at the cursor. A fold you made wins over the file's own blocks on
  its first line.
- Searching (`C-s`, the Find widget's isearch) opens a fold it passes through.
- A file's folds are remembered: what is folded, and the folds you made, named or not, folded or open, come back when
  you open the file again. Each is found again by the text of its first line, up to 50 lines from where it was, so
  lines added or removed above it do not lose it; one whose first line changed or went is dropped. The hub keeps them
  per project and file, sent when you save, when you close the file and 30 s after a fold change once you stop
  typing. With no hub running, the folds stay in the open file and go to the hub when it comes back.
  `drgnx-fold-remember` (on) turns this off.

Where blocks come from (`drgnx-fold-source`): in code with a tree-sitter mode, the syntax tree, by the language pack's
fold query — functions, classes, comments, imports, tests and blocks as the language has them, kept current as you type
(a pack without its own fold query folds its definitions); in a file with no tree-sitter mode whose language the hub
knows, the hub's syntax tree by the same query (the hub watches the file while you fold, as it does for the minimap;
indentation until its blocks arrive); in other code, indentation — a line and the lines after it
indented deeper, as VS Code's indentation folding; in Markdown, headings (each to the next heading of its level or above); in a notebook,
its cells; Org folds its own headings (Fold, Unfold, Toggle Fold, Fold All, Unfold All and Fold Level act on them). `indent`
uses indentation everywhere, `off` leaves only the folds you make. `drgnx-fold-summary` sets what a folded line shows
(`full`: the count and what the hidden lines hold, as `⋯ 38 lines ✕ 1 ⚠ 2 ✦ 1` for errors, warnings and agent
edits; `lines`: the count only; or an ellipsis); `drgnx-fold-max` caps the blocks a file keeps (20,000; the smallest go first). The
blocks live in Nidhogg's line model, kept with every edit, so a fold command reads them at once and the scroll bar
leaves folded lines out. The Emacs keys are hideshow's (`C-c @ C-c` toggle, `C-c @ C-M-h` / `C-c @ C-M-s` all,
`C-c @ C-l` level, `C-c @ C-n` from the selection); hideshow's own folds, if you turn `hs-minor-mode` on, are separate.
With Vim keys, evil's fold keys (`zc`, `zo`, `za`, `zC`, `zO`, `zM`, `zR`) act on these folds, `zm` / `zr` fold one level more / less, and `zf` (visual), `zd`,
`zj`, `zk` make, remove and step through them. Module `editor/fold`.

## Sticky scroll

When the start of the function, class or block you are in has scrolled off the top, its name shows in the header,
after the breadcrumb and in the breadcrumb's type — up to three enclosing scopes, outermost first: `src › shape.py ›
Shape › area`. A scope is a definition (a function, a method, a class, …): a block that names nothing (a `let` in
Lisp, an `if` block) is left out. The header line is always there (the breadcrumb), so nothing moves as you scroll — except in a terminal window with
fewer than 30 frame lines (31 terminal rows with the menu bar on), where the breadcrumb row is off and the scopes,
which share its row, are hidden too. Scopes come from
tree-sitter when the buffer has a parser (functions, methods, classes, structs, …), else from the hub: the definitions
the Outline lists around the line at the window's top, your unsaved text included (also while the tree is not ready — a
large file's first parse still running on Nidhogg's parse worker: the header never waits for it and redraws once the
tree is there). The hub is asked once per top line and text, and the header keeps what it showed until the answer
comes; without the hub, or in a remote file without tree-sitter, there are none. Each position is worked out once, and
again only when the text above the window's top changes or the hub answers. Scrolling inside the same tree-sitter
scopes reuses their names (the scope lines are read once). **Toggle Sticky Scroll** for this buffer. Module `editor/sticky` (drgnx's own). It is one of the header's tail providers: add your own with
`drgnx-chrome-add-tail-provider` (a function of a window returning a string or nil, and a depth; lowest first).

**Lines instead of names.** With `drgnx-sticky-style` set to `lines` (default `names`), the scopes' first lines show
as code, VS Code's way: up to `drgnx-sticky-max` lines (3), outermost first, in syntax colours, over the window's top
rows, the popups' shadow under the last. When the editor shows line numbers, so do the lines, padded as the editor's,
and their text starts in the editor's text column, in its font and text size, so the columns line up (also while the
editor is scrolled sideways). They are a card over the text, so the text never
moves, point stays where it is and a scroll counts the same rows. Click a line to go there; Ctrl+click folds that scope.
The scopes come from the fold table, so sticky scroll, folding and the minimap agree (else from tree-sitter). The card
is filled again only when the set of scopes changes, never per scroll. Each window with sticky scroll gets its card,
hidden, as soon as the `lines` style is on, so the first sticky line shows at once; the card goes with its window. The card stops short of the minimap,
so the minimap stays in full sight when it opens.

**Pinned regions.** **Pin Region** pins the selection, or the scope at point: it keeps a band and its name on the
minimap (the scroll bar's pin marks, which move with your edits). **Show Pinned Region** shows a pin (the one at point,
else one you choose from the buffer's pins) in the same card over the window's top rows, so you can read a signature
while you write its uses elsewhere; run it again to take it off. **Unpin Region** removes one. Pins last while the
buffer is open.

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
keeps `M-w`, `C-w` and `C-y`; the Vim profile `y`, `d` and `p`. Copy and Cut are instant: with a selection `C-c` copies and `C-x` cuts at once; drop the selection first (`Escape`) to type
an Emacs prefix such as `C-x C-s` (or set `drgnx-editing-prefix-delay` to a number of seconds to have them wait for a next key). Details are in [keys.md](keys.md#copy-cut-and-paste). In a terminal window the copy also reaches the terminal's
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
package and run with it; the booster only with its program; a missing formatter still saves); `mod-sticky-test.el` (the names in the caption face, outermost first, at most three, never
waiting for a parse that is not ready), `mod-sticky-hub-test.el` (the hub's scopes: a defun, none at its own line, an
edit above the top, one question per top line); `mod-markdown-test.el` (GFM for READMEs, the preview through pandoc or without a program,
Mermaid as a job once, without mmdc nothing); `test/ui/code-editing-test.el` (on a graphical frame: the sticky
scopes of a long function, indent guides, smooth scrolling, a screenshot); the perf workload `code-scrolling`
([perf.md](../develop/perf.md)).
