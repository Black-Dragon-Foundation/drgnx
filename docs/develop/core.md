# The drgnx core

The core is what every drgnx session loads before any module: paths, staged hooks, the no-prompt guard, the
command registry and every surface generated from it, the command palette, and a minimal module system. It uses
no third-party packages. Boot it with `emacs --init-directory <checkout>/init` — or in a harness session with
`bin/drgnx ui start --config drgnx`.

```
init/early-init.el   packages not activated by Emacs (drgnx-init activates drgnx's own — packages.md); no tool bar
init/init.el         core/ on the load path, (require 'drgnx), (drgnx-init); a plain GUI start (not a daemon,
                     not drgnx safe) serves `drgnx PATH' under the name drgnx unless another drgnx does
core/drgnx.el        drgnx-init: guard on, staged hooks armed, keep-running choice read, the first window's Welcome
                     (a first start only), packages activated, core commands, modules, surfaces (DRGNX_SAFE — drgnx
                     safe — skips packages and modules)
core/drgnx-session.el  drgnx PATH's Emacs side, Open Folder…, keep running or quit, Quit drgnx (../guide/opening.md)
core/drgnx-macos.el  the drgnx app on macOS (drgnx macos-app; ../guide/opening.md)
core/drgnx-tty.el    terminals, batch-safe: which one, what it can do, keys it can send, terminfo, tmux (../guide/terminal.md)
core/drgnx-tty-recommend.el  a terminal that sends every key: installed ones, the install command per OS, the opt-in opener
core/drgnx-tty-fallback.el   keys a legacy terminal cannot send: their Alt+Shift and F6 forms, drgnx-tty-sendable-key (the layer: modules/ui/drgnx-tty-fallback-layer.el)
modules/<category>/drgnx-<name>.el   one drgnx-module-define per file
```

## Paths (`drgnx-paths.el`)

`drgnx-dir` is the checkout (code only, never written to). User configuration: `(drgnx-user-dir)` —
`$DRGNX_CONFIG_DIR` or `~/.config/drgnx/`. State and caches: `(drgnx-state-dir)` and `(drgnx-cache-dir)` under
the XDG directories. Packages: `(drgnx-data-dir)` — `$DRGNX_DATA_DIR` or `~/.local/share/drgnx/` — holds `elpa/`
(the packages every session uses) and `generations/`; `(drgnx-package-cache-dir)` keeps downloaded package files
([packages.md](../guide/packages.md)).
Started with `--init-directory <checkout>/init`, Emacs keeps its own state (`user-emacs-directory`: auto-save list,
histories) in `(drgnx-state-dir)emacs/` and native code in `(drgnx-cache-dir)eln-cache/` (`init/early-init.el`), so
nothing is written into the checkout; a harness session keeps both in its run directory.

## Staged hooks (`drgnx-hooks.el`)

Work that need not happen at startup hangs on a stage and runs once, when the stage is first reached:
`drgnx-first-input-hook` (before the first command), `drgnx-first-file-hook` (first visited file),
`drgnx-first-gui-frame-hook` (first graphical frame — for a daemon, the first `emacsclient -c`). Each function
runs under its own error guard; errors are collected in `drgnx-hooks-problems`, never shown as prompts.

## No prompts in automatic paths (`drgnx-guard.el`)

A prompt asked from a timer, a hook or while the daemon starts has nobody to answer it, and the daemon freezes.
`drgnx-guard-mode` (on in every drgnx session) makes `y-or-n-p`, `yes-or-no-p`, `read-string`,
`read-from-minibuffer`, `completing-read`, `read-passwd`, `read-number`, `read-file-name`,
`read-directory-name`, `read-buffer`, `read-multiple-choice`, `read-answer`, `read-key` and `read-char-choice`
signal `drgnx-prompt-in-automatic-path` instead — naming the prompt and where it was asked from — when called
(`read-event` is left alone: `sit-for` uses it):

- from a timer (detected by wrapping `timer-event-handler`; commands run by a nested command loop, such as a
  minibuffer opened by a command, are not timer code);
- inside `(drgnx-automatic …)` — use it for hook functions, process filters and sentinels (Emacs calls those
  from C, so they cannot be detected);
- while a daemon initialises — until the last `window-setup-hook` function, so `after-init-hook` and
  `emacs-startup-hook` count too.

## Command registry (`drgnx-registry.el`)

Every command is registered once, without keys:

```elisp
(drgnx-command-define 'palette
  :category "View" :title "Command Palette"
  :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
```

Keys: `:title`, `:category`, `:command` (required), `:scope` (`app` default, `editing` or `window` — which key-profile
layers key it), `:map` (the keymap its keys go into by default: nil for global, a keymap symbol, or
`(FEATURE . KEYMAP)` for a keymap that exists once FEATURE loads), `:menu` (menu-bar path), `:context` (right-click
contexts), `:context-first`, `:doc` and `:when` (a predicate: the command is offered only while it holds).
Redefining an id replaces it. **Keys come from key profiles** ([keys.md](../guide/keys.md)); the active keys of a command
are in its `bound` slot, which every surface reads. The entries keep the ids of the gryphn layer's registry, which
this is ported from.

## Surfaces (`drgnx-surfaces.el`, `drgnx-palette.el`)

Generated from the registry, never written by hand, showing the keys of the active key profiles: the menu bar,
right-click menus (contexts via `drgnx-surfaces-define-context`), which-key labels (when which-key is present),
the **key sheet** ("Keyboard Shortcuts", `*drgnx keys*`), a markdown cheat sheet (`drgnx-surfaces-export-markdown`), "next time:
KEY" tips after a command run from a menu or the palette, and the **command palette** (`C-S-p` in every profile): every available
command as "Category: Title" with its key and description beside it, through the normal completion UI.

**Run hook and usage counter.** `drgnx-surfaces-run` (what the palette and the menus call) runs
`drgnx-surfaces-run-functions` with the command id after the command ran; an error in a member is swallowed. The
first member counts the run: in memory only, so a run costs nothing noticeable. The counts are written at idle, at
most once a minute and at exit, never prompting, to `command-usage.eld` in the state dir
(`drgnx-shortcuts-usage-file`): `((ID COUNT (DAY . N)…)…)`, with the per-day counts (`time-to-days`) of the last 7
days. The file stays on your machine; it feeds the suggestions of the Keyboard Shortcuts editor ("you ran X 12
times this week; give it a key?"). Read it with `drgnx-surfaces-usage-count` and `drgnx-surfaces-usage-week`.

## Modules (`drgnx-modules.el`)

```elisp
(drgnx-module-define 'core/basics
  :doc "Quiet, predictable defaults and the basic file and view commands."
  :stage 'startup
  :setup (lambda () …))
```

Module files are `modules/<category>/drgnx-<name>.el`. Stages: `startup` (during `drgnx-init`) and `idle` (once
Emacs is idle). Each setup runs under its own error guard and is timed; a file that fails to load is reported as
a module too. "Help: Module Report" (`drgnx-modules-show-report`) lists stage, milliseconds and errors. Flags,
settings, doctor checks, more stages and the modules index come with M4.

## Build (`drgnx-build.el`)

`bin/drgnx build` byte-compiles `core/`, `wb/` and `modules/` in place (`.elc` files are not tracked); with native
compilation available, Emacs then compiles them natively in the background as they load. Compiled drgnx is several
times faster and makes far less garbage. `install.sh` runs it; drgnx sets `load-prefer-newer`, so a stale `.elc`
never shadows newer source. The build must stay warning-free (`test/unit/build-test.el`).

## The Emacs `bin/drgnx` runs in

The shell function `emacs_bin` picks the one Emacs every subcommand uses: `$DRGNX_EMACS`, else the first line of
`$DRGNX_CONFIG_DIR/emacs` (default `~/.config/drgnx/emacs`, written by `install.sh`'s `remember_emacs`) when it
names an executable file, else `emacs`. The file is read as a path, never evaluated. A new subcommand calls
`"$(emacs_bin)"`, never a bare `emacs`. All of them run with `load-prefer-newer`, so a stale `.elc` after a pull
never prints before the output. `emacsclient_bin` is that Emacs's `emacsclient` (beside it, or in an Emacs.app's
`Contents/MacOS/bin/`; else PATH's) — what `drgnx open` and `drgnx PATH` talk to the daemon with
([opening.md](../guide/opening.md)). `test --install` limits each image to an hour with `timeout`, else `gtimeout`.
`test/unit/bin-test.el` covers it with fake Emacs scripts.

## Doctor (`drgnx-doctor.el`)

`bin/drgnx doctor [--json] [--dev]` asks the Emacs drgnx will use (see above) whether this
machine is ready, and gives a fix for anything that is not:

```
OK    emacs-version        Emacs 31.1                 (30.2: WARN — works, 31.1 recommended; older: FAIL)
OK    native-compilation   native compilation works   (built without it, or libgccjit broken: FAIL)
OK    tree-sitter          tree-sitter available
OK    gui                  graphical build (pgtk)     (terminal-only: OK, with a note)
WARN  security             known issues up to 31.1, fixed in 31.2 (TRAMP, Flymake, read-symbol-shorthands)
OK    git                  git found
```

Native compilation is checked by actually compiling a function, not only by asking whether it is built in. Any
FAIL makes the exit status 1. `--dev` adds the tools for developing drgnx (mutter, dbus-run-session, ImageMagick, a
pgtk Emacs) and the environment, container runtime and session launcher. Without any Emacs, the doctor prints the
installer command. Checks are defined with `drgnx-doctor-define`; modules will add their own (M4).

A check may be for one platform (`:platform 'linux` or `'macos`, as `drgnx-platform` says); on the other it is absent
from the results. The dev checks for mutter, dbus-run-session and a pgtk Emacs are Linux-only. macOS adds three
warnings with their facts: `macos-app` (`~/Applications/drgnx.app` exists; fix `drgnx macos-app`), `brew` (`brew` on
PATH, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`; the doctor may run without Homebrew on PATH) and
`drgnx-on-path` (fix: `~/.local/bin` in the shell's profile: `~/.zprofile` for zsh (or, with `SHELL` unset, when it exists), else `~/.profile`, as
`drgnx-doctor--shell-profile` says; the same rule as `install.sh`).

A check that returns nil is absent from the results; `drgnx-doctor-run` also takes a group name to run one group.
The **Terminal** group (`terminal`, `terminal-colours`, `terminal-mouse`, `terminal-keys`, `terminal-clipboard`,
`terminal-tmux`, `terminal-ssh`, `terminal-popups`) reads the fact `:terminal`, which `drgnx-doctor-terminal-facts`
gathers: `drgnx-tty-facts` (the environment of the process the doctor runs in; inside tmux one `tmux show`, 1 s),
`:caps` and the fallback rows from the newest entry of `terminal-report.eld` for that kind of terminal, and `:os`.
Check This Terminal (`ui/terminal`) runs the same group with the selected terminal window's own capabilities and its
client's environment. A detail of several lines (the key table) is printed indented. See
[terminal.md](../guide/terminal.md#check-this-terminal).

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.
