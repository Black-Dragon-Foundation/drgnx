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
  from another's records onto its own stack. Code a setup defers (`eval-after-load`, a timer) runs outside it
  and records nothing unless it names its owner (`drgnx-modules-with-owner`, below). That holds also when the
  deferred code runs *inside* a setup: `eval-after-load` forms that a setup's `require` triggers belong to nobody
  (see the safety net).
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

### The safety net: what a setup reaches through Emacs's own doors

Code a setup reaches that does not push its own undo — wb modes, the setup functions of `wb/` libraries, packages'
mode functions — is recorded anyway. For each setup's extent only (`drgnx-modules--with-recorder`, inside
`drgnx-modules--run-setup`), drgnx advises four functions and removes the advice in `unwind-protect`, also after
an error, a quit or a throw. Outside a setup nothing is advised and nothing costs anything.

| What the setup does | Recorded when | Undo (each checks first) |
|---|---|---|
| `add-hook` on a hook's global value | the function was not on it before | `remove-hook`, if it is still there |
| `advice-add` | `advice-member-p` was nil before | `advice-remove`, if still there |
| `add-to-list` on a list's global value | the element was not a member before (same test as `add-to-list`) | remove that one element, if still a member; others' additions stay |
| a new timer (`timer-list`, `timer-idle-list` compared before and after) | always | `cancel-timer`, if still pending |
| a global minor mode newly in `global-minor-modes` | it was off before | `(MODE -1)`, if still on; pushed last, so modes go off first and their own off code runs before the hook and timer undos |
| a feature newly in `features` | always | none: kept for the report, `(drgnx-modules-features-of MODULE)` |

Labels read `hook HOOK FN`, `advice SYMBOL FN`, `list VAR ELEMENT`, `timer FN`, `mode MODE` (`a lambda` for an
anonymous function). The undos make teardown and rollback complete for these doors. An undo that a drgnx API
also pushes (the same hook, recorded twice) is harmless: the second finds nothing to do.

What it does **not** record:

- **Buffer-local changes**: `add-hook … nil t`, a buffer-local list value. Buffers own those.
- **`add-to-list` on `global-minor-modes` or `local-minor-modes`**: Emacs 31's `define-minor-mode` keeps them that
  way; the modes are compared after the setup instead.
- **A drgnx helper's own calls**: the paired hook and advice helpers bind `drgnx-module--in-helper` while they call
  `add-hook` and `advice-add`, and push their own undo, which respects what other modules still claim. A second,
  unconditional undo from the net would remove a function another module still needs.
- **The top level of a library the setup loads** (hooks, advice, list entries): it registers for itself and stays
  (`drgnx-modules--recording-p`). Timers and global modes are found by comparing lists, so one that a library
  starts at its top level while the setup loads it *is* recorded onto the setup — a library that does that is
  itself the bug.
- **`eval-after-load` forms that the setup's `require` triggers.** They run once, when their library loads, after
  `load-file-name` is back to the setup's. Recorded, turning the module off would undo them and turning it on
  again would not bring them back (the library is already loaded). So while they run (`do-after-load-evaluation`
  is advised too) no module is current, and the timers and modes they start are claimed by nobody. A form that
  names its owner records onto it.
- **A setup run inside another's** records onto its own module only: what an inner recorder found is claimed,
  and the outer one skips it.
- **`add-to-list` that the compiler rewrote.** Its compiler macro turns `(add-to-list 'VAR …)` into a plain
  `push` when VAR is not special at compile time — a lexical variable, or one whose `defvar` the compiling Emacs
  has not run, such as one defined in the caller's own file or declared with a bare `(defvar VAR)`
  (`drgnx-search.el`'s `drgnx-ai-retrievers`). Checked on 30.2 and 31.1. Use `drgnx-modules-push-undo` (or the
  module helpers) for such a list.
- `setq`, `setf`, `put`, `add-function`, key bindings, faces, frames: the module's own undo or `:teardown`.

**Deferred work: `drgnx-modules-with-owner`.** `(drgnx-modules-with-owner BODY…)` evaluates to a function: it
names the module whose setup evaluates the form, and when called later runs BODY as that module's code, with the
safety net — what BODY changes is recorded onto the module, as in its setup. Use it as the deferred thing itself:

```elisp
(eval-after-load 'drgnx-ai-ui (drgnx-modules-with-owner (add-to-list 'drgnx-ai-retrievers #'my-retriever t)))
(run-with-idle-timer 1 nil (drgnx-modules-with-owner (my-mode 1)))
```

Not `(with-eval-after-load 'x (drgnx-modules-with-owner …))`: there the form is evaluated only when `x` loads, so
it names no module, and its function is never called. Once the module is turned off, rolled back, or run again
(each run of a setup gets a fresh token in `drgnx-modules--runs`), the function does nothing and returns nil, so a
late `eval-after-load` or idle step of a turned-off module never runs and an off-on cycle never runs the old run's
work twice. Evaluated outside a setup, it just runs BODY. Each call installs the safety net for its extent (about
20 µs): for one-off work, not for a hook that runs on every command.

**Cost.** The safety net around a setup costs about 20 µs (byte-compiled, 30.2: four `advice-add` and
`advice-remove`, two snapshots and their comparison). The shipped startup stage (16 modules, batch) took 29.4 ms
with it and 28.2 ms without (5 runs each, within the runs' noise); the budget is 5 ms across all setups.
`test/unit/modules-record-test.el` covers it, including `startup-is-unchanged`: the shipped modules' startup stage
gives the same statuses and commands with the recorder as without it.

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
