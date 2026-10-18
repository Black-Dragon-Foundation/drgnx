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
waiting for packages, from the last session; when all is well it counts the modules that run and those that are
off ("12 ok, 3 off"), and every answer says how old the report is ("from the last session, 2 h ago").

## Packages

A module that needs a package says so (`:packages '(magit)`). Until the package is installed the module does not run
and is reported as waiting for it — Emacs never installs anything on its own; `drgnx sync` does
([packages.md](packages.md)). External code
gets the same treatment: a `use-package … :ensure t`, `:vc` or `package-install` in an external module installs
nothing — the package is recorded and the module reported as waiting for it.

## modules.eld

Your choices live in `~/.config/drgnx/modules.eld` (`$DRGNX_CONFIG_DIR`):

```elisp
(:version 2
 :disabled (ui/zen lang/python)          ; modules that do not run
 :enabled (editor/evil)                  ; modules that are off until chosen, and were (below)
 :flags ((ui/popups +childframe)))       ; module flags
```

`:enabled` is absent until a module that is off until chosen is turned on, and is kept as it is when drgnx writes
the file (a bootstrap or onboarding that writes modules.eld keeps it too). `:theme` is the colour theme Color Theme
picked (ui/look writes it). modules.eld is format 2. An older format (the first, a bare list of disabled modules, or
format 1) is read as it is and written as format 2 the next time drgnx changes the file, after a backup
(`modules.eld.bak-<time>`). A file from a newer drgnx is used when it fits what this drgnx knows, but is never changed.
A file with a mistake (it does not read, or a field is not what drgnx expects, say `:disabled` that is not a list of
modules) is not used: the last copy that read well applies, or the defaults, and one notice says where the mistake is
(Preferences: Open Config File… opens it there) — never an error at start. While it has a mistake drgnx does not
write it: turning a module on or off, onboarding and Color Theme say why and change nothing, so what you typed is
never lost. Your comments and keys of your own stay as they are when drgnx changes the file; two Emacs changing it
at once both keep their change.

The Next start column of Preferences: Modules shows what the file says now, so a change made in another Emacs shows
at once; a module you turn off or on here takes effect at the next start. The file is listed in the generated [config reference](../reference/config.md).

## Modules that are off until chosen

A module defined with `:default 'off` does not run, and its `:packages` are neither synced nor loaded, until it is in
`:enabled`; nothing installs or loads for it before that. The Vim key stack (the evil module) is the first. Who turns
such a module on: the key profile that needs it (choosing a Vim key stack in onboarding or Preferences), or you —
Preferences: Modules says `off (chosen by the key profile)` in its Next start column and `RET` on the row adds it to
`:enabled` (and again, removes it). `:disabled` always wins: a module in both lists stays off. A module that is on by
default is turned off through `:disabled` as before. `drgnx bisect` leaves an off-until-chosen module out unless it is
enabled. The shipped lock still lists its packages, so a fresh install that chooses the module before its first sync
gets verified versions; once a sync has rewritten your own lock from what is installed, the module's packages are not
in it until they are installed. From Lisp:
`(drgnx-module-default-off-p MODULE)`, `(drgnx-module-disabled-p MODULE)`, `(drgnx-modules-set-enabled MODULE ON)` and,
for any other change to the file, `(drgnx-modules-update-state FN)` (FN gets the file as it is and returns the new plist).

## Your own code: config.el

`~/.config/drgnx/config.el` (`$DRGNX_CONFIG_DIR`) is your own Emacs Lisp. It loads at the end of every start,
after the `startup` modules, so what you set there wins; for a package that loads later, use
`with-eval-after-load`. **Preferences: Open User Config** (palette, Options menu) opens it, made from a short
template the first time. An error in it is said in `*Messages*` (what came before it ran, the rest did not) and
drgnx starts anyway; `drgnx safe` skips it. Code you want reported as a module, with its own row in
Preferences: Modules, is an external module (below).

What Customize saves (and `M-x package-install`'s list of packages) goes to `custom.el` beside it, which loads in every
start once your packages are active (so a package's mode saved on there turns on) and before config.el; an error in
it is said in `*Messages*`, and `drgnx safe` skips it. A theme picked with Color Theme (ui/look) wins over one saved
through Customize: ui/look loads it after custom.el.

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
their keys join the key profiles (the VS Code and Emacs profiles bind them, the Vim profile leaves them to the palette) — never replacing what a profile ships: a profile that has an entry for the command or binds the key keeps its own, and the Emacs profile keeps Emacs' own keys. drgnx never changes the gryphn checkout.
A gryphn command whose id drgnx already has (gryphn's `view-explorer`, Toggle Sidebar, next to drgnx's View: Explorer)
never replaces drgnx's: it is registered as `gryphn/<id>`, its key bound where the profile does not own it, and
`*Messages*` says so once.

### What an external module honours: `drgnx-loading-external`

While drgnx loads the files of an external module, the variable `drgnx-loading-external` is `t`; it is `nil` again
when the load ends, whether the feature loaded or failed. It is the switch for code that belongs to your key
profiles rather than to the module: global keymap sets, fixes for the CUA keys, popper setup. An external module that
also runs outside drgnx wraps those parts and keeps everything else:

```elisp
(unless (bound-and-true-p drgnx-loading-external)
  (global-set-key (kbd "C-c b") #'gryphn-board))   ; skipped under drgnx: the profile binds the command
```

`bound-and-true-p` keeps the file working where drgnx is not loaded. Commands, menus and context definitions are not
affected: they reach the registry and the palette as before.

## Writing a module

```elisp
(drgnx-module-define 'tools/example
  :doc "One line: what it gives you."
  :stage 'idle
  :requires '(core/workbench)            ; modules that must have run (in the same stage: they run first)
  :packages '(example-mode)              ; features that must be loadable
  :flags '(+fancy)                       ; (drgnx-module-flag-p 'tools/example '+fancy)
  :default 'on                           ; or 'off: off until chosen (below); `on' when left out
  :doctor (lambda () (unless (executable-find "example") '("the example program is not installed")))
  :settings '((example-width . "Width of the example pane"))
  :setup
  (lambda ()
    (drgnx-command-define 'example-run :category "Example" :title "Run Example" :command #'example-run
      :doc "Run the example")))
```

`:doctor` returns the problems it finds (strings) after the module ran; they are kept with the module's status and
`drgnx doctor` reports them as a warning. `:settings` is reserved for the Settings screen (M6) and not used yet.
`(drgnx-module-running-p 'tools/example)` says whether a module's setup ran and went well. Another module can use
it to take a path only while that module runs.

Every command goes through the registry (`drgnx-command-define`) and gets a key — or `:none` with a reason — in each
key profile ([keys.md](keys.md)); faces inherit theme faces (no colours). See [core.md](../develop/core.md) for the registry.

## Shipped modules

| Module | Stage | What it gives you |
|---|---|---|
| `core/basics` | startup | quiet defaults (no bell, no dialogs, y/n, background compiler warnings only in the log), Open File, Save, Save As, New Untitled, Reopen Closed Tab, New Window, Close Window, Cancel / Close Popup (Escape), line numbers, trusted folders and their guards (Trust This Folder, the "restricted" mark; [security.md](security.md)) |
| `core/workbench` | startup | the workbench: docks, panel, popups, chrome, groups, several windows, moving a window to another monitor, the layout across restarts (each window back on its monitor) ([workbench.md](workbench.md)) |
| `editor/editing` | startup | Fold / Unfold, Change Case (camelCase, snake_case, kebab-case, cycle — a single word says it has nothing to cycle), Expand / Shrink Selection (tree-sitter nodes when the buffer has a parser), Go to Line, Move Line Up / Down (the line or the selected lines), Select Line (again for the next), Select All, Duplicate Line, Delete Line, New Line Below / Above, Redo, Toggle Comment, Back / Forward, VS Code's cursor moves and deletes (Line Start — the first non-blank, then the start — / End, File Start / End, Word Left / Right, Delete Word Left, Delete to Line Start; Cmd+←, Option+←, Cmd+⌫ on a Mac, [keys.md](keys.md#on-a-mac)) |
| `ui/look` | startup | Color Theme (remembered in modules.eld; a saved theme that does not load is said in `*Messages*`, and Color Theme picks another), Zen Mode (only the text; again to give the sidebar and panel back), Zoom In / Out / Reset (every window; then `+`, `-` or `0`) |
| `ui/face` | startup | the frame and the buffers: no light menu bar or scroll bar, thin themed dividers, line numbers in code that never shift sideways, problems at the end of their line, ASCII glyphs on non-UTF-8 terminals; the status bar (segments you reorder, drop or add to), the top line (project, branch, the three keys that open everything), a dark title bar that follows the theme, quick help beside the symbol, a × and Esc/q on every help pane, popup and side pane, the start page in an empty editor; Toggle Menu Bar, Open the Menu (F10 as text while the bar is hidden), Look and Layout Settings ([face.md](face.md)) |
| `lang/eglot` | startup | a language server (eglot) for code files whose server is installed — never a question; it stops when the project's last buffer closes; tree-sitter modes where the grammar is installed; Go to Definition, Find References, Rename Symbol, Show Hover (in the panel), Quick Fix, Problems (in the panel), Format Document (re-indents without a server) |
| `lang/grammars` | startup | tree-sitter grammars on request: a file whose grammar is missing says so once (never asks); Install Language Support builds them in the background, then open files switch to their tree-sitter modes ([editing.md](editing.md)) |
| `extra/booster` | idle | language servers through `emacs-lsp-booster` when it is installed (eglot-booster, from Git); else nothing changes ([editing.md](editing.md)) |
| `extra/format` | idle | format on save with the language's formatter when installed (apheleia; in the background, never blocking the save); Toggle Format on Save ([editing.md](editing.md)) |
| `extra/debug` | idle | a debugger (dape, the Debug Adapter Protocol): Start Debugging (or continue), Toggle Breakpoint, Step Over / Into / Out, Stop — VS Code's F5, F9, F10, F11 (while a session runs), S-F11, S-F5 in that profile ([editing.md](editing.md)) |
| `extra/guides` | first-frame | indent guides in code and YAML on graphical frames (indent-bars, the theme's colours); Toggle Indent Guides ([editing.md](editing.md)) |
| `ui/smooth` | first-frame | smooth, pixel-precise scrolling on graphical frames (ultra-scroll when installed, else Emacs's own); Toggle Smooth Scrolling ([editing.md](editing.md)) |
| `editor/sticky` | startup | sticky scroll: the function, class or block you are in, when its start has scrolled off, after the breadcrumb (tree-sitter or indentation; drgnx's own); Toggle Sticky Scroll ([editing.md](editing.md)) |
| `editor/clipboard` | startup | clipboard managers: line and word kills stay in the kill ring, everything else reaches the system clipboard, a clipboard owner that does not answer is given up on after 1.5 s (X11 and Wayland), selecting text stops filling the history when Klipper, CopyQ or GPaste syncs it ([editing.md](editing.md#the-system-clipboard)) |
| `editor/evil` | startup | Vim editing (evil), off until you choose a Vim key stack: normal / insert / visual states in editors, panels and forms in Emacs state, shells and commit messages in insert state, the state in the mode line and the cursor shape per state; evil-collection's keys for Magit, Dired and other third-party modes (flag `no-collection` leaves them out); multiple cursors in Emacs state; Toggle Modal Editing (`SPC u m`) turns it off and on for the session ([keys.md](keys.md#vim-keys)) |
| `lang/markdown` | startup | Markdown (READMEs as GitHub Flavored Markdown): code blocks in their language, math; Markdown: Open Preview (pandoc, cmark or markdown when installed), Mermaid diagrams through mmdc ([editing.md](editing.md)) |
| `tools/vc` | startup | Source Control (the project's changes), Diff with File, Blame — on Emacs' VC |
| `tools/diff` | idle | the diff view: working tree, staged or branch vs base; split or unified, files folded, open the file at the line ([git.md](git.md)) |
| `tools/replace` | idle | search and replace ([replace.md](replace.md)): the Search view in the sidebar and the find bar above an editor; text through ripgrep (else git grep or grep) in the background, symbols through the language server's rename; stale matches skipped, one Undo for every file |
| `tools/layouts` | idle | layouts ([layouts.md](layouts.md)): Agent (the Explorer, the editor beside the current agent's chat, the Agents list), Editor, Zen (the text centred), Browser, and your own (Save Layout As…, in layouts.eld); Next Layout cycles them; switching back restores the arrangement you left |
| `tools/commit-message` | idle | Git: Generate Commit Message — the staged diff through the `chat` role, never a trailer ([git.md](git.md)) |
| `tools/review` | idle | Review Branch: the `review` route's agent reads this branch's diff; findings in the panel's Review tab ([git.md](git.md)) |
| `tools/prs` | idle | the Pull Requests tab: stacks, forge's review view, Changes in the diff view, `#` in commit messages (needs forge) ([git.md](git.md)) |
| `tools/terminal` | startup | New Terminal (eshell, in the panel's Terminal tab), Open Terminal Here (Explorer) |
| `tools/search` | startup | Quick Open (project files), Search in Project (results in the panel), Go to Symbol (file, project), Find in File, Replace in Project, Recent Buffers (consult when installed); Semantic Search, Index Project, Index Status, Set Up Semantic Search, and a re-index 30 s after a file of an indexed project is saved ([search.md](search.md)) |
| `tools/agents` | startup | Show Agents (the right dock's Agents tab: sessions and durable jobs), New Agent Session, Send to Agent (queued while it works), Stop Agent, Take Over Agent Session, Answer Agent, edit review hunk by hunk, Show Job Log, Stop Job ([agents.md](agents.md)) |
| `tools/jobs` | startup | Show Job in Work (the Work cockpit filtered to a job: what needs you, its tasks, its decisions), Start Job from Plan, Approve Plan Job, Show Plan Jobs, Stop Plan Job; the ⚑ badge and notifications ([jobs.md](jobs.md)) |
| `tools/work` | startup | Show Work (the right dock's Work tab: specs › plans › tasks › steps, TODOs, commits, branches), Show Work as Graph (the Work cockpit's graph when `tools/cockpit` runs, else specs, plans and branches drawn with svg.el), Start Agent on Task, Open Plan's Worktree ([work.md](work.md)) |
| `tools/cockpit` | startup | the Work cockpit: the Work graph (pane `work-graph`, the left dock's Work view) — specs, plans, tasks, agents, jobs and reviews, who is on what, needs and blocks, what waits on you, worktrees that do not report; drawn in a wide graphical window, an outline elsewhere; Filter Graph, Open Node, Open in Plan, Draw Graph Again, Select Next/Previous Node; What needs you and Decisions (panes `needs-you`, `decisions`): every job's cards and messages, a job's log ([cockpit.md](cockpit.md)) |
| `tools/ai` | startup | ghost-text completion in code buffers (the `complete` role), one Tab for suggestion / popup / snippet / heading / indent, Accept Suggestion (word, line), Toggle AI Completion, Edit with AI… (reviewed hunk by hunk), Ask the Codebase…, Choose AI Provider/Model… ([ai.md](ai.md)) |
| `org/org` | startup | Capture `C-c c`, Agenda `C-c a` |
| `extra/jump` | idle | Jump to Text (needs avy) |
| `extra/mc` | idle | Add Next Occurrence, Select All Occurrences — a cursor on each match (needs multiple-cursors) |
| `extra/undo` | idle | Undo Tree (needs vundo) |
| `extra/wgrep` | idle | Edit Results / Apply Edited Results in search results (needs wgrep) |
| `extra/hunks` | idle | changed lines in the gutter; Show / Revert / Stage Change (needs diff-hl) |
| `extra/blame` | idle | inline blame: the current line's author, age and commit subject at its end; Blame: Show Commit of Line ([git.md](git.md)) |
| `extra/keycast` | idle | Show Keys As I Type (needs keycast): the key and command in the status bar's `misc` segment (in the stock mode line elsewhere) |
| `extra/llm` | idle | LLM Menu, Send to LLM (needs gptel; its model and key are gptel's configuration) |
| `extra/windows` | idle | Pick Window: a letter on every window, type it to go there (needs ace-window) |
| `extra/magit` | idle | Source Control opens magit (needs magit) |
| `extra/completion` | idle | vertical minibuffer lists, any-order matching, completion popups as you type (needs vertico, orderless, marginalia, corfu) |
| `tools/browser` | idle | the browser pane ([browser.md](browser.md)): a web page beside the editor (WebKit, else your system browser), Browser: Test Report (Playwright), Browser: Agent's Page |
| `tools/live` | idle | the Live view ([live.md](live.md)): a headless browser for agents, watched live (CDP screencast) and taken over (needs websocket) |
| `tools/remote` | idle | Open Remote… ([remote.md](remote.md)): an ssh host from `~/.ssh/config` or a podman container, then a folder, through TRAMP; a status-line segment (⇄ HOST, connected or lost); Reconnect keeps buffers and changes; language servers run on the remote side (looked for only by these commands, never automatically) |
| `tools/shortcuts` | idle | Preferences: Keyboard Shortcuts ([shortcuts.md](shortcuts.md)): every command with its keys, source and place; record keys and chords, conflicts, filters, suggestions from use |
| `tools/agent-settings` | idle | Agents: Settings ([agent-settings.md](agent-settings.md)): one page per agent — Claude Code, Codex, Gemini, Kimi Code — with its routes and billing, MCP servers, hooks and skills; add, edit, remove, turn on or off in the agent's own files; Test an MCP server or a hook in a separate process; opening the page starts nothing |
| `ui/terminal` | startup | terminal windows (`emacsclient -t`, `emacs -nw`): what each terminal can do, asked once per terminal and written to terminal-report.eld with the keys it cannot send; `C-S-` chords through modifyOtherKeys (xterm, WezTerm; tmux with `extended-keys`); the mouse in terminal windows (Toggle Mouse in Terminal Windows); copy to your clipboard by OSC 52 (also in tmux and over SSH), true colour per window, VS Code's `C-c` / `C-x` / `C-v` on a selection; for terminals that cannot send `C-S-` chords, Alt+Shift or F6 then the key; Check This Terminal (the doctor's Terminal group for the window you are in); `emacsclient -t FILE` (git's `EDITOR`) shows the editor only and returns when you close the tab or press `C-x #` ([terminal.md](terminal.md)) |
| `ui/terminal-keys` | startup | `C-S-` chords, `` C-` ``, `C-.` … in terminals that have the kitty keyboard protocol but no confirmed modifyOtherKeys (kitty, foot, Alacritty, Ghostty); `C-g` there stops a hanging `git` but not busy Lisp; `drgnx-tty-use-kkp` turns it off (needs kkp; [terminal.md](terminal.md#keys)) |
| `ui/terminal-layout` | startup | the workbench in a small terminal: the sidebar and panel by the terminal's size, docks as fractions of it, nothing closed that you opened ([terminal.md](terminal.md)) |
| `ui/terminal-popups` | startup | popups in terminal windows: corfu's child frame with box-drawing borders on Emacs 31.1; completion as you type in the popup lane on 30.2; ASCII marks for the tab line, breadcrumb and Explorer in a terminal that does not write UTF-8 ([terminal.md](terminal.md#popups)) |

The `extra/` modules wait until their packages are installed; Preferences: Modules says which.
