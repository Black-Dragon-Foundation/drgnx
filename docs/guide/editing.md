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
Emacs's tree-sitter). On Emacs 31 a tree-sitter mode that names its own grammar version is built at that version. Languages: bash, c, cpp, css, go, html, java, javascript, json, lua,
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
area(self):`. The header line is always there (the breadcrumb), so nothing moves as you scroll. Scopes come from
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

## Tests

`test/unit/mod-grammars-test.el` (the language of a buffer, the hint once and never a prompt, the install as a job
and its command, buffers switching after it); `test/unit/mod-amenities-test.el` (the modules wait without their
package and run with it; the booster only with its program; a missing formatter still saves); `mod-sticky-test.el` (the scopes, outermost first, at most three, one line, the
cost of a scroll step); `mod-markdown-test.el` (GFM for READMEs, the preview through pandoc or without a program,
Mermaid as a job once, without mmdc nothing); `test/ui/code-editing-test.el` (on a graphical frame: the sticky
scopes of a long function, indent guides, smooth scrolling, a screenshot); the perf workload `code-scrolling`
([perf.md](../develop/perf.md)).
