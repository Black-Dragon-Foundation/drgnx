# Modules

Everything drgnx does beyond its core is a **module**: one file `modules/<category>/drgnx-<name>.el` with one
`drgnx-module-define`. Modules start in **stages**, each under its own error guard and timed, so one broken module
never stops Emacs from starting:

| Stage | When |
|---|---|
| `startup` | while drgnx starts |
| `idle` | the first time Emacs is idle (one second), one module per idle moment — what you type in between is handled first |
| `first-frame` | when the first graphical window opens (a daemon's first `emacsclient -c`) |
| `first-file` | when the first file is visited |
| `first-input` | before the first command you give |

**Preferences: Modules** (palette, Options menu) lists every module with its status — `ok`, `failed: …` (a module
file that does not load says `(in <library>)` when the error came from a library it loads), `needs <package>`,
`needs <module>`, `disabled` — its stage, how long it took, and whether it runs at the next start; `RET`
turns the module on that row off (or back on) from the next start. A column header sorts by it (ms as a number, Stage
in the order of the stages); an external module's row says its path and features. `drgnx doctor` reports failed modules and modules
waiting for packages, from the last session.

## Packages

A module that needs a package says so (`:packages '(magit)`). Until the package is installed the module does not run
and is reported as waiting for it — Emacs never installs anything on its own; `drgnx sync` does
([packages.md](packages.md)). External code
gets the same treatment: a `use-package … :ensure t`, `:vc` or `package-install` in an external module installs
nothing — the package is recorded and the module reported as waiting for it.

## modules.eld

Your choices live in `~/.config/drgnx/modules.eld` (`$DRGNX_CONFIG_DIR`):

```elisp
(:version 1
 :disabled (ui/zen lang/python)          ; modules that do not run
 :flags ((ui/popups +childframe)))       ; module flags
```

`:theme` is the colour theme Color Theme picked (ui/look writes it). An older format is migrated when it is read; a
field that is not what drgnx expects (a typo) is dropped with a message in `*Messages*`; an unreadable file, or one
from a newer drgnx, is reported and ignored (modules use their defaults) — never an error at start — and before drgnx
next writes the file it keeps yours as `modules.eld.bak-<time>`.

## External modules (gryphn)

Code that lives elsewhere loads as an **external module**, listed in modules.eld:

```elisp
(:version 1
 :external ((:name gryphn :path "~/src/gryphn/emacs"
             :features (gryphn-org gryphn-run gryphn-board gryphn-board-ui gryphn-agents gryphn-search gryphn-llm))))
```

At idle each feature is loaded and reported as module `external/<name>/<feature>` (Preferences: Modules); a missing
directory or a feature that fails to load is reported, never fatal; an entry without `:name`, `:path` or `:features`
is listed as failed (and kept in the file as you wrote it); `external/<name>` in `:disabled` (or `RET` on its
row) keeps it from loading. gryphn's files load unchanged: drgnx provides
`gryphn-command-define` and `gryphn-surfaces-define-context` on its own registry and surfaces
(`core/drgnx-compat-gryphn.el`), so the board, runs, agents and search commands appear in the palette and menus and
their keys join the VS Code key profile. drgnx never changes the gryphn checkout.

## Writing a module

```elisp
(drgnx-module-define 'tools/example
  :doc "One line: what it gives you."
  :stage 'idle
  :requires '(core/workbench)            ; modules that must have run (in the same stage: they run first)
  :packages '(example-mode)              ; features that must be loadable
  :flags '(+fancy)                       ; (drgnx-module-flag-p 'tools/example '+fancy)
  :doctor (lambda () (unless (executable-find "example") '("the example program is not installed")))
  :settings '((example-width . "Width of the example pane"))
  :setup
  (lambda ()
    (drgnx-command-define 'example-run :category "Example" :title "Run Example" :command #'example-run
      :doc "Run the example")))
```

`:doctor` returns the problems it finds (strings) after the module ran; they are kept with the module's status and
`drgnx doctor` reports them as a warning. `:settings` is reserved for the Settings screen (M6) and not used yet.

Every command goes through the registry (`drgnx-command-define`) and gets a key — or `:none` with a reason — in each
key profile ([keys.md](keys.md)); faces inherit theme faces (no colours). See [core.md](../develop/core.md) for the registry.

## Shipped modules

| Module | Stage | What it gives you |
|---|---|---|
| `core/basics` | startup | quiet defaults (no bell, no dialogs, y/n, background compiler warnings only in the log), Open File, Save, Save As, New Untitled, Reopen Closed Tab, New Window, Close Window, Cancel / Close Popup (Escape), line numbers |
| `core/workbench` | startup | the workbench: docks, panel, popups, chrome, groups, several windows, the layout across restarts ([workbench.md](workbench.md)) |
| `editor/editing` | startup | Fold / Unfold, Change Case (camelCase, snake_case, kebab-case, cycle — a single word says it has nothing to cycle), Expand / Shrink Selection (tree-sitter nodes when the buffer has a parser), Go to Line, Move Line Up / Down (the line or the selected lines), Select Line (again for the next), Select All, Duplicate Line, Delete Line, New Line Below / Above, Redo, Toggle Comment, Back / Forward |
| `ui/look` | startup | Color Theme (remembered in modules.eld; a saved theme that does not load is said in `*Messages*`, and Color Theme picks another), Zen Mode (only the text; again to give the sidebar and panel back), Zoom In / Out / Reset (every window; then `+`, `-` or `0`) |
| `lang/eglot` | startup | a language server (eglot) for code files whose server is installed — never a question; it stops when the project's last buffer closes; tree-sitter modes where the grammar is installed; Go to Definition, Find References, Rename Symbol, Show Hover (in the panel), Quick Fix, Problems (in the panel), Format Document (re-indents without a server) |
| `lang/grammars` | startup | tree-sitter grammars on request: a file whose grammar is missing says so once (never asks); Install Language Support builds them in the background, then open files switch to their tree-sitter modes ([editing.md](editing.md)) |
| `extra/booster` | idle | language servers through `emacs-lsp-booster` when it is installed (eglot-booster, from Git); else nothing changes ([editing.md](editing.md)) |
| `extra/format` | idle | format on save with the language's formatter when installed (apheleia; in the background, never blocking the save); Toggle Format on Save ([editing.md](editing.md)) |
| `tools/vc` | startup | Source Control (the project's changes), Diff with File, Blame — on Emacs' VC |
| `tools/terminal` | startup | New Terminal (eshell, in the panel's Terminal tab), Open Terminal Here (Explorer) |
| `tools/search` | startup | Quick Open (project files), Search in Project (results in the panel), Go to Symbol (file, project), Find in File, Replace in Project, Recent Buffers (consult when installed); Semantic Search, Index Project, Index Status, Set Up Semantic Search, and a re-index 30 s after a file of an indexed project is saved ([search.md](search.md)) |
| `tools/agents` | startup | Show Agents (the right dock's Agents tab: sessions and durable jobs), New Agent Session, Send to Agent (queued while it works), Stop Agent, Take Over Agent Session, Answer Agent, edit review hunk by hunk, Show Job Log, Stop Job ([agents.md](agents.md)) |
| `tools/jobs` | startup | Show Job Window (tasks and agents · what needs you · the decision log), Start Job from Plan, Approve Plan Job, Show Plan Jobs, Stop Plan Job ([jobs.md](jobs.md)) |
| `tools/work` | startup | Show Work (the right dock's Work tab: specs › plans › tasks › steps, TODOs, commits, branches), Show Work as Graph (svg.el; click a box to open it), Start Agent on Task, Open Plan's Worktree ([work.md](work.md)) |
| `tools/ai` | startup | ghost-text completion in code buffers (the `complete` role), one Tab for suggestion / popup / snippet / heading / indent, Accept Suggestion (word, line), Toggle AI Completion, Edit with AI… (reviewed hunk by hunk), Ask the Codebase…, Choose AI Provider/Model… ([ai.md](ai.md)) |
| `org/org` | startup | Capture `C-c c`, Agenda `C-c a` |
| `extra/jump` | idle | Jump to Text (needs avy) |
| `extra/mc` | idle | Add Next Occurrence, Select All Occurrences — a cursor on each match (needs multiple-cursors) |
| `extra/undo` | idle | Undo Tree (needs vundo) |
| `extra/wgrep` | idle | Edit Results / Apply Edited Results in search results (needs wgrep) |
| `extra/hunks` | idle | changed lines in the gutter; Show / Revert / Stage Change (needs diff-hl) |
| `extra/keycast` | idle | Show Keys As I Type (needs keycast) |
| `extra/llm` | idle | LLM Menu, Send to LLM (needs gptel; its model and key are gptel's configuration) |
| `extra/windows` | idle | Pick Window: a letter on every window, type it to go there (needs ace-window) |
| `extra/magit` | idle | Source Control opens magit (needs magit) |
| `extra/completion` | idle | vertical minibuffer lists, any-order matching, completion popups as you type (needs vertico, orderless, marginalia, corfu) |

The `extra/` modules wait until their packages are installed; Preferences: Modules says which.
