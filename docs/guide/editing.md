# Editing code

What drgnx adds to editing code, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one
off), and each that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)); until then the
module waits.

## Language support (tree-sitter)

Code buffers use a language's **tree-sitter mode** (faster, more precise highlighting and navigation) when its
grammar is installed (`lang/eglot`). A file whose grammar is missing opens as usual, and the echo area says once per
language, per session, that **Install Language Support** (in the palette) adds it — never a question.

The command builds the grammar in the background (a durable job: Show Job Log → `grammars`; it needs `git` and a C
compiler) into `~/.local/share/drgnx/tree-sitter/`; when it is done, open files of that language switch to its
tree-sitter mode, and new ones open in it. Languages: bash, c, cpp, css, go, html, java, javascript, json, lua,
python, ruby, rust, toml, tsx, typescript, yaml (module `lang/grammars`, sources in `drgnx-grammars-sources`).

## Faster language servers

With the [`emacs-lsp-booster`](https://github.com/blahgeek/emacs-lsp-booster) program installed (its release binary
on your `PATH`), eglot talks to every language server through it: the server's JSON is parsed outside Emacs, so a big
answer (completions, diagnostics of a large file) no longer stalls typing (module `extra/booster`, package
`eglot-booster` — from Git, `drgnx sync` installs it). Without the program nothing changes.

## Format on save

Saving formats the buffer with its language's formatter — black or ruff for Python, prettier for JavaScript,
TypeScript, CSS and Markdown, gofmt, rustfmt, shfmt, clang-format, … (apheleia's list) — when that formatter is
installed: in the background, after the save, keeping the point and the view where they were. A formatter that is not
installed, or fails, leaves the file as you saved it; nothing asks. **Toggle Format on Save** turns it off or on in
this buffer (with `C-u`, everywhere). Module `extra/format`, package `apheleia`.

## Tests

`test/unit/mod-grammars-test.el` (the language of a buffer, the hint once and never a prompt, the install as a job
and its command, buffers switching after it); `test/unit/mod-amenities-test.el` (the modules wait without their
package and run with it; the booster only with its program; a missing formatter still saves).
