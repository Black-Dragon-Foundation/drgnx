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

### Teardown: the cleanup stack (`drgnx-modules-record.el`)

A module can be turned off while Emacs runs. While its setup runs, `drgnx-modules--current` names it, and each call
that changes global state pushes its own undo onto the module's cleanup stack (the shape of buttercup's cleanup
stack — the code that knows what it changed knows how to change it back):

```elisp
(add-hook 'find-file-hook #'drgnx-blame--maybe)
(drgnx-modules-push-undo "hook find-file-hook drgnx-blame--maybe"
                         (lambda () (remove-hook 'find-file-hook #'drgnx-blame--maybe)))
```

- `(drgnx-modules-push-undo LABEL UNDO)` records only during a setup, and only the setup's own code: the top level
  of a library the setup loads registers for itself and stays (`require` cannot be undone; the code stays loaded
  until restart). "Own code" means the `load-file-name` the setup began with — the startup stage itself runs
  inside a `load` (`init.el` calls `drgnx-init`), so "a load is in progress" cannot tell the two apart; a nested
  `load` or `require` binds `load-file-name` anew (`drgnx-modules--recording-p`). Outside a setup it costs one
  variable test. LABEL is a short description for reports; UNDO, a function of no arguments, first checks that the
  state is still what this module set and changes nothing otherwise — it never removes what someone else added
  since.
- Whatever runs synchronously inside a setup pushes onto the module whose setup runs — including another owner's
  hook functions it runs (a nested stage's `drgnx-modules-after-stage-functions`) — and a module whose setup is run
  from another's records onto its own stack. Code a setup defers (`with-eval-after-load`, a timer) runs outside it
  and records nothing unless it binds its owner again.
- `:teardown` in `drgnx-module-define`: a function for what the stack cannot see (a theme, live frames' parameters,
  a mode turned on in live buffers, a sub-module's own state), or `restart`: the module is not turned off while Emacs
  runs, only at the next start. Anything else is an error when the module is defined, so the function must be
  defined before the `drgnx-module-define` form.
- `(drgnx-module-teardown NAME)` runs the module's `:teardown`, then its stack last in first out inside
  `unwind-protect`, each undo under its own error guard, and forgets the stack; the status becomes `off`. It returns
  the problems (nil when clean) — a failed undo is named by its label, a failed `:teardown` by `teardown` — and never
  raises. A module that is not running does nothing, and so does a `:teardown` that tears its own module down
  again. A `restart` module (and an external one) stays running and returns `("restart")`. After a batch of
  teardowns the caller runs `drgnx-modules-after-teardown-functions` once.
- A setup that does not finish — an error, a quit, a throw — is rolled back: the undos it pushed run, newest first.
  After an error the module is `failed`, with the error and any undo problems in the report; a quit or a throw goes
  on after the rollback.
- Running a module that is already on tears it down first (its `:teardown`, then its stack), so no undo is left
  behind; a `restart` module is set up again on top, as before, and keeps its earlier undos.
- Teardown and rollback run in automatic paths: they never prompt. Undos and `:teardown` run with
  `inhibit-interaction` bound, so one that would ask fails at once and is reported. Every undo checks before it
  changes anything, so off, on, off is the same as off once, and two undos of the same thing (a `:teardown` that
  calls a sub-module's off function, then the stack) leave it undone once.

#### Helpers that undo themselves (`drgnx-modules-helpers.el`)

Four changes a setup makes to global state are done through a helper that makes the change and pushes its own
undo. Each undo runs only while the state is still what this call set, so it never removes what the user, a theme
or another module put there since. Outside a setup a helper only makes the change.

| Use | For | Undo |
|---|---|---|
| `(drgnx-module-set VAR VALUE)` | another package's option, instead of `setq`, `setopt` or `setq-default` | puts the old value back (VAR unbound again if it was) |
| `(drgnx-module-alist-put VAR KEY VALUE)` | one key of an alist such as `auto-mode-alist`, `major-mode-remap-alist` or `default-frame-alist`, instead of `setf alist-get` | puts the old entry back, or removes KEY when there was none |
| `(drgnx-module-face-spec FACE SPEC)` | a face's default spec, instead of `face-spec-set` | puts the previous default spec back |
| `(drgnx-module-define-key MAP-SYMBOL KEY DEF)` | a remap or a mouse/chrome event in a global map such as `global-map` | puts the previous binding back, or removes the entry |

- `drgnx-module-set` sets through the option's custom `:set` function when it has one, else `set-default`, and the
  undo goes through the same setter, so a `:set` that does more than store runs again on the way back. The undo runs
  while the default value is still the one stored (what a setter stored, which can differ from VALUE).
- `drgnx-module-alist-put` compares keys with `equal` (an `auto-mode-alist` key is a string) and replaces the alist
  instead of changing it, so a list shared with the original value is never mutated. It stores through the
  variable's custom `:set` function too, and an alist that is not loaded yet counts as empty. A hook or an advice
  has its own helper.
- `drgnx-module-face-spec` touches only the face's default spec (`face-defface-spec`); what the user customized or a
  theme set lives apart from it and is never touched. `face-spec-set` recalculates the face, so an attribute set
  directly with `set-face-attribute` is wiped by it (at the set and again at the undo): give such a face its look
  through the spec.
- `drgnx-module-define-key` binds in the keymap object, never rebinding the variable, and looks at the map's own
  entry (not its parent's). A keyboard key signals an error: typed keys come from the key profiles
  (`keys/*.eld`). Allowed: `[remap CMD]`, the chrome (`menu-bar`, `tool-bar`, `tab-bar`, `tab-line`,
  `header-line`, `mode-line`, scroll bars, fringes) and any key whose last event is a mouse or wheel event.
- **Two modules, one target.** Each helper claims its target (the option, the alist key, the face, the key in the
  map) and remembers what it found there. Tearing the modules down in any order ends where they started: an undo
  that is not the newest claim leaves the live value alone and hands what it found to the claim above it; the
  newest one restores, if the value is still what it set (so a change by the user stays). A claim is dropped only
  by its undo, so a module that is never torn down (a `restart` module) keeps its claim until restart.
- The undo compares with `equal`: a list stored by reference and changed in place later still equals itself, so the
  undo overwrites that change. Do not mutate a value you gave `drgnx-module-set`.
- Outside a setup the helpers make the change and nothing else (no label, closure or claim).

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
OK    gui                  graphical build (pgtk)     (terminal-only: WARN)
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

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.
