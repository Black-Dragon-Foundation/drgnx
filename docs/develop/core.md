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

`(drgnx-guard-automatic-p)` says whether the code running now is such a path, for code that would rather not ask
than signal (choosing a Vim stack records it as pending instead of offering to install evil).

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

## Modal core (`drgnx-modal.el`)

The engine-neutral half of modal editing; evil plugs into it (the `editor/evil` module, below), another engine could.
Nothing in it needs evil, and `test/unit/modal-core-test.el` drives it with a fake engine.

- **Maps.** `drgnx-modal-leader-map` holds the leader keys (`SPC …`, `C-w …`), `drgnx-modal-panel-map` the keys
  that exist only in panels. Both are emulation maps (`drgnx-modal--leader-alist`, `drgnx-modal--panel-alist`),
  switched per buffer; `drgnx-modal-order-alists` puts them in front of the engine's in
  `emulation-mode-map-alists` after `drgnx-keys--everywhere-alist` and before the AI ghost text's (the ghost's has
  its place whether or not it exists yet; the everywhere alist is in the list only while there are `:everywhere`
  keys, and goes back in at the front, its place), and `drgnx-modal-sync-engine` calls it after an engine starts.
  A module whose keys must beat the engine's too (Esc and `q` closing a pane, the quick-help card) adds its alist's
  symbol to `drgnx-modal-front-alists` when its map comes on and calls `drgnx-modal-order-alists`: those go right
  after the panel alist, before the ghost text's.
- **State.** An engine calls `(drgnx-modal-set-state STATE)` on every change (`normal insert visual visual-line
  visual-block replace motion operator emacs`, nil when no engine runs in the buffer). The leader map is on in
  `normal`, `motion` and the visual states, and in a panel's `emacs` state; the panel map only in a panel's `emacs`
  state. A buffer whose keys go elsewhere sets `drgnx-modal-keys-off` (buffer-local) and calls
  `(drgnx-modal-set-state drgnx-modal-state)`: neither map is on there in any state (the Live view does it while you
  drive the page, so `SPC`, `j` and `k` reach the page). The switches are buffer-local and are dropped with the
  major mode, so an engine calls `drgnx-modal-init-buffer` (the buffer's `drgnx-modal-initial-state`: emacs in forms and panels, insert in input
  buffers, else normal) in every buffer when it starts and after each major-mode change (or mirrors its own state with
`drgnx-modal-set-state`; the minibuffer is never modal: `drgnx-modal-init-buffer` leaves it alone). Panels, forms and input buffers are told apart by `drgnx-modal-panel-modes`, `-form-modes` (fields you
  type in: no modal keys) and `-input-modes` (shells and message buffers: start in insert or emacs state), with
  `drgnx-modal-panel-p`, `-form-p` and `-input-p`.
- **Indicator.** `(drgnx-modal-mode-line)` returns the state name (` NORMAL `, ` V-LINE `, …) in
  `drgnx-modal-normal`, `-insert`, `-visual` or `-emacs`, which inherit theme faces. It is one self-contained
  construct, `(:eval (drgnx-modal-mode-line))`, that any mode-line layout can place;
  `drgnx-modal-indicator-on` / `-off` add and remove it at the front of the default `mode-line-format`. The strings
  are made once (`drgnx-modal--indicator-texts`); redisplay only looks one up.
- **Typing.** `(drgnx-modal-typing-p)` says whether a printable key types in this buffer: no engine runs here, or
  the state is insert, replace or emacs. Code that passes a key on to the buffer (a closing key) asks it instead of
  naming an engine.
- **Selection.** An engine sets `drgnx-modal-selection-function`; `(drgnx-modal-selection)` returns
  `(BEG . END)` from it, else from the active region, else nil.
- **Engines.** `(drgnx-modal-define-engine NAME :module M :start F :stop F)` registers one. A key profile asks for
  an engine with a top-level `:modal (:engine NAME :leader KEYS :default-map … :maps …)` (keys/vim.eld);
  `drgnx-modal-sync-engine` starts the engine the current layers need (once) and stops any other (a stop clears every buffer's state and
  removes the indicator, so `SPC` types a space again; an engine's start turns the indicator on), and
  `drgnx-modal-running` names it. `(drgnx-modal-mixed-p LAYERS)` is non-nil when a layer is of a profile without
  `:modal` (a Vim stack mixed with another editor's keys); `drgnx-modal-sync-functions` are called with the layers
  at the end of every sync, started or not. `drgnx-modal-suspended` (one element: the layers at the time) keeps the engine off
for those layers, however often the keys are applied again (Toggle Modal Editing); other layers end it. `:maps` says, per keymap, the states a key bound there must also work in
  (the key resolver reads it); `drgnx-modal-where` names a map for the key sheet ("" for the leader map, whose keys show plain; with VERBOSE it
  says where the leader works, from `:maps`: "normal, visual, motion state and panels", the Shortcuts "where" column).
  `drgnx-modal-default-notes` are lines the key sheet and `keys-report.eld` append to the conflicts: what the modal keys
  take from Emacs' defaults that the resolver does not report without an Emacs layer (the Leader Menu on `M-SPC`
  over `cycle-spacing`). `keys-report.eld` also carries `:modal (:engine :module :running :pending :suspended)` and
  `:leader-menu-key`, and is written again when the engine starts or stops (while modal editing is toggled off
  `:engine` is nil and `:suspended` t, and the leader's which-key labels go); `:module` is the engine's module (the
  doctor runs without the modal core); `:pending` is `:pending-layers` of keys.eld, read as data. The doctor's `modal`
  check reads them: "modal editing is off for this session" while toggled off.
- **Where keys go** (`core/drgnx-keys-modal.el`, pure, used by `drgnx-keys-resolve`). `drgnx-keys-modal-leader-p`
  tells a leader key (`SPC f f`, `C-w h`) from the rest; `drgnx-keys-modal-key-map` binds a leader key in the
  profile's `:map` (`drgnx-modal-leader-map`) whatever the entry says, any other key in the entry's map, the
  command's, `:default-map`, else the profile's; `drgnx-keys-modal-states` gives the states a `:maps` keymap works
  in; `drgnx-keys-modal-of-stack` finds the stack's modal layer (a `keys.eld` leader key goes in its leader map).
  A modal profile's entries for commands outside its layer's scopes are **extras**: their keys in a `:maps` keymap
  are bound next to the command's own layer's keys, never replacing them. `drgnx-keys-after-apply-functions` (abnormal
  hook, the layers) runs at the end of every `drgnx-keys-apply`; the core adds `drgnx-modal-sync-engine` to it.
- **Claims per state** (`drgnx-keys-modal-claims`). When `drgnx-keys-modal` loads it registers
  `(eval-after-load 'evil …)`, which copies evil's state maps named in `:maps` into `drgnx-keys-modal-snapshots`
  before any binding drgnx defers to evil's load (a map not defined is skipped). `drgnx-keys-resolve :snapshots`
  (`drgnx-keys-apply` passes that variable) meets every other layer's `global-map` binding with what a snapshot binds
  on its key (or a prefix of it, or keys under it), and every `global-map` or panel-map binding
  (`drgnx-keys-modal-panel-maps`) with the leader and panel maps' bindings of the resolution; without snapshots the
  `:claims` with STATES stand in, each on the engine maps whose states it covers. In a mixed stack there is no
  insert-state claim (Vim's insert keys are off there). The binding is kept; the conflict carries `:states` and
  `:elsewhere t`. A binding of a higher rank gets `:also` (the engine maps), which `drgnx-keys-apply` binds through
  `drgnx-keys--apply-binding` and records in `drgnx-cmd-bound`, so `drgnx-keys--restore` undoes it — unless the
  engine map's key now differs from the snapshot and is not empty (`drgnx-keys--theirs`: the user's own binding, kept
  and reported as a conflict); leader or panel keys it beats are dropped and each named among the losers. In panels the leader and panel maps always win (they are above the panel's own map).
- **Commands.** `modal-leader` (Leader Menu) reads the leader's keys from any state: a transient map holding the
  leader's `SPC`, and `SPC` read again as if typed (`(t . 32)` in `unread-command-events`, as which-key replays a
  prefix), so which-key shows the `SPC` popup with the leader's labels (`+File`, the command titles).
  `panel-next` / `panel-previous` (Next / Previous Row, bound in the panel map) run the panel's own `<down>` /
  `<up>` binding, else `next-line` / `previous-line`, so a panel keeps its row movement.

## Choosing a modal stack (`drgnx-modal-choose.el`)

A key stack with a modal profile (Vim) needs its engine, and the engine's module is off until chosen.
`drgnx-modal-prepare LAYERS &optional INTERACTIVE` is what Keyboard Profile… and onboarding's Look and Keys call before
they switch, and it returns `ready` (no engine needed, or it is loaded, or it is installed and this process runs no modules: the CLI), `started`, `installed` (one
question, then `drgnx sync` as a job, then a start), `declined`, `pending` or `(fail REASON LOG)`. It turns the engine's
module on (`drgnx-modal-set-module`, which also turns every other engine module off for a stack without a modal profile;
the table is `drgnx-modal-engine-modules`) and asks only when INTERACTIVE and `(drgnx-guard-automatic-p)` is nil; anything
else records `:pending-layers` in keys.eld without asking and writes `keys-report.eld` (only when keys were applied in this
process). The question, the sync and the start run inside `unwind-protect`, so a quit or an error turns the module back off
unless it was on before. `drgnx-modal-apply-pending` runs at the end of `drgnx-init`, after `drgnx-keys-apply`, and
switches a pending stack whose engine has loaded (it never asks and catches its errors). The caller switches the keys only
on `ready`, `started` or `installed`, and saves the layers after the engine runs, so keys.eld never names a Vim stack
without evil. `drgnx-modal-engine-start-now` runs the module mid-session through `drgnx-modules--run-one`; going back to
another stack stops the engine but evil stays loaded until the restart (module teardown owns unloading).

## The Vim engine (`modules/editor/drgnx-evil.el`)

Module `editor/evil` (`:default 'off`, startup stage; packages `evil`, `evil-collection`). `drgnx-evil-setup` sets
`evil-want-keybinding` nil and `evil-want-C-u-scroll` t before `(require 'evil)`, then `drgnx-evil--settings` applies the
module defaults with `setopt` (`evil-undo-system` `undo-redo`, `evil-search-module` `evil-search`, `evil-want-minibuffer`
nil, `evil-mode-line-format` nil; the user's `setopt` in config.el runs later), registers the engine with
`drgnx-modal-define-engine` and the command Toggle Modal Editing, and calls `drgnx-modal-sync-engine`. `drgnx-evil-start`
and `-stop` own what the engine adds (hooks, advice, variable watchers, saved variables): the stop takes it all out
again, except the `eval-after-load` entries (`multiple-cursors-core`, `term/xterm`, the initial state of a mode whose
library loads later), which stay and do nothing while the engine is off (each checks `drgnx-evil--active`), and
evil-collection's registrations, which only bind keys in evil's own maps (inactive without evil). A failing start
undoes what it did. When an engine's stop signals, `drgnx-modal-sync-engine` still clears every buffer's state and
the indicator.

- **States.** The core's `drgnx-modal-panel-modes` and `-form-modes` start in emacs state and `-input-modes` in insert
  state (`drgnx-evil--initial-states`, set again when the mode's library loads and when a list grows); every state
  entry hook calls `drgnx-evil--sync`, which passes the state to `drgnx-modal-set-state`.
- **Cursor and terminal.** `drgnx-evil--cursors-on` gives each state a shape from `drgnx-evil--cursor-vars`, never a colour,
  keeps a variable the user set, and panels keep their own cursor. On 31.1 `xterm-update-cursor` is `type` while the
  engine runs, also for terminal frames already live (`drgnx-evil--xterm`).
- **evil-collection and unimpaired.** Registered per mode when the mode's library loads (`drgnx-evil-collection-modes`,
  the flag `no-collection`); the unimpaired keys follow the engine; multiple cursors switch to emacs state through
  `drgnx-evil--mc-hooks`.
- **Insert-state keys.** `drgnx-evil--insert-bindings` is on only in the pure Vim stack (`drgnx-modal-sync-functions` calls
  `drgnx-evil--insert-for-layers`), through `evil-update-insert-state-bindings` (it does nothing when you set
  `evil-disable-insert-state-bindings`).
- **Ex commands and window keys.** `drgnx-evil-ex-routes` (`:w`, `:wa`, `:e`) are redefined with `evil-ex-define-cmd`, keeping
  evil's argument properties; evil's quit and split commands are `:around` advice (`drgnx-evil--advice-pairs`) that call
  evil's own when the workbench is off. In a buffer another program waits for, the quit advice ends the edit first
  (`drgnx-evil-ex--end-edit`): `with-editor-finish` / `-cancel` in a magit commit or rebase message, `server-edit` (or
  `server-buffer-done` for `:q!`) in an emacsclient buffer.
- **AI.** `drgnx-evil--ghost-inhibit` is on `drgnx-ai-ghost-inhibit-functions` (ghost text asks in insert and emacs state
  only) and `drgnx-evil--selection` is `drgnx-modal-selection-function` (the visual selection, a block widened to its lines).
- **Which-key.** The built-in which-key is turned on, with transient maps shown, while the engine runs, and put back at stop.
- **Order.** `drgnx-modal-order-alists` runs after the engine starts and on `evil-local-mode-hook`, because evil pushes its
  maps onto `emulation-mode-map-alists`.

Tests load the real evil from `DRGNX_MODAL_ELPA` and run in their own Emacs ([harness.md](harness.md)).

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
