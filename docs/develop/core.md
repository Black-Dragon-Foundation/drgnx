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

**Undefining.** `(drgnx-command-undefine ID)` removes a command from the table and the order (it returns ID, or nil
when there was none). A `drgnx-command-define` made by a module's setup pushes its own undo (see "Teardown" under Modules):
if the table still holds that very definition, the one it replaced comes back (keeping its bound keys and its place
in the order), or the command goes when it replaced none. Definitions of one id form a chain, so the undos are safe in
any order: tearing down the first of two modules that defined an id leaves the second one's entry alone and the second
one's teardown does not bring the first one back; a definition made outside a setup (a user's `config.el`) is never
touched. A library a setup `require`s registers for itself and stays until restart.

**How keys and menus follow.** The registry is the one source: after a batch of teardowns
`drgnx-modules-after-teardown-functions` runs `drgnx--after-teardown`, which calls `drgnx-keys-apply` (it puts back
Emacs's own bindings first, then binds what the registry still holds, so a removed command's keys are free again and
nothing a user bound is touched) and `drgnx-surfaces-refresh`.

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

**Removing what a command added.** The palette, the key sheet, the cheat sheet and the right-click menu are computed
from the registry on each use, so an undefined command is gone from them at once. The menu bar and which-key are
written, so they are undone explicitly. `drgnx-surfaces-build-menus` remembers what it added, per command id: the item
(a claim on its menu path and title, `drgnx-module--claim`, so two commands sharing a title in one submenu go in either
order), the binding it replaced and the submenus it had to create. A command that is no longer the registered one
(undefined, or defined again) has its item taken out, newest first: a replaced item is put back in its place, a submenu
made for the item goes once empty, and an item someone else replaced or removed since is left alone. Every other
item is replaced where it stands (`easy-menu-add-item` keeps the position, and refreshes `:keys`), so nothing untouched
moves behind an item someone else added meanwhile. `drgnx-surfaces-apply-which-key` already removes its previous labels
on every refresh. Right-click contexts: `(drgnx-surfaces-undefine-context CONTEXT)` removes one;
`drgnx-surfaces-define-context` called from a setup claims the context (the same claims as the option and key helpers),
so two modules defining one context, and a user's own definition on top, undo in any order.

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
  behind; a `restart` module is set up again on top, as before, and keeps its earlier undos. That teardown does not
  run `drgnx-modules-after-teardown-functions`: the setup registers its commands again at once, and `drgnx-modules-run`
  runs `drgnx-modules-after-stage-functions` (keys and menus apply) once after the whole stage, so a hook per re-run
  would only add a second full keys resolve while the registry is half rebuilt. Whoever tears down on purpose
  (Preferences, the batch teardown) runs the after-teardown hook once.
- Teardown and rollback run in automatic paths: they never prompt. Undos and `:teardown` run with
  `inhibit-interaction` bound, so one that would ask fails at once and is reported. Every undo checks before it
  changes anything, so off, on, off is the same as off once, and two undos of the same thing (a `:teardown` that
  calls a sub-module's off function, then the stack) leave it undone once.

#### Workbench registries (`wb/`)

The workbench's registries push their own undo, so a module that defines a section, a tab, a rule, a place or a
bus subscription in its setup leaves none behind. Each undo changes the entry only while it is still the one this
module defined; a definition that replaced an entry puts the previous one back instead of removing it. Each
definition claims its target with the helpers' claims (`drgnx-module--claim`, `drgnx-module--release`: a section by
name, a tab by area and name, a rule by matcher, a place by name), so two modules that define the same one end where
they started whichever is torn down first.

| Define | Undo (also callable on its own) | Open panes |
|---|---|---|
| `drgnx-wb-define-section` | `(drgnx-wb-undefine-section NAME)` | the section's dock window closes (focus leaves it first); the dock keeps its other sections. A restored previous section shows again the next time the dock is shown. |
| `drgnx-wb-define-tab` | `(drgnx-wb-undefine-tab AREA TAB)` | where the area shows the tab it shows the next tab in the same window (the one before for the last tab), or hides when it was the only one; the tab row is redrawn and the frame's saved buffer for the tab dropped. A restored tab replaces the module's placeholder in a window that shows it. |
| `drgnx-wb-place` | `(drgnx-wb-unplace MATCHER)` (`equal`) | none: rules decide only where a buffer goes next. |
| `drgnx-wb-define-place` | `(drgnx-wb-undefine-place PLACE)` | none. A rule that still names an undefined place sends its buffers to the editor, with a one-time message. |
| `drgnx-signal-subscribe` | `drgnx-signal-unsubscribe` | none. A count per (event, function): each module's subscription holds it and the last release unsubscribes. A function already subscribed by code that records nothing (a mode, the user) is never unsubscribed by a module. A subscription re-made outside a setup (a mode switched off and on by the user) while a module holds one is unsubscribed with the module's last release. |

The `add-function` on `after-focus-change-function` (Explorer and Buffers panel) pushes its `remove-function`
beside it, by the advice's name. Areas (`drgnx-wb-define-area`) are not undone: they belong to the workbench.

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

#### Hooks and advice: `drgnx-module-hook` and `drgnx-module-advice`

A global hook function or advice a module adds goes through a paired helper (Doom's `add-hook!` and `defadvice!`
shape). It defines the function with a name and an owner, adds it, and pushes its removal, which is what
AGENTS.md asks of every global hook and advice ("named, with an owner", no lambdas).

```elisp
(drgnx-module-hook 'find-file-hook maybe ()           ; defines drgnx-editor/blame--maybe
  (drgnx-blame--check))
(drgnx-module-hook '(text-mode-hook prog-mode-hook) enable () :depth 90 (drgnx-blame-mode 1))
(drgnx-module-advice 'save-buffer :after refresh (&rest _) (drgnx-blame--refresh))
(drgnx-module-unhook 'find-file-hook maybe)           ; early, e.g. when a mode turns off
```

- The function is `drgnx-<module>--<NAME>`, the module being the one the file's `drgnx-module-define` names (the
  file's forms are read at macro-expansion time, so comments and strings never count; cached by the file's mtime) or
  `:module NAME` (a symbol) first in the body. NAME is a plain symbol and is used once per module file: the same
  NAME for two helpers is an error at expansion. `:depth N` goes to `add-hook` (`drgnx-module-advice` refuses it).
  HOOK is evaluated: a symbol or a list of symbols; SYMBOL and HOW of an advice are evaluated. The advice is named
  by its function (`advice-add` name property), so equal NAMEs in two modules never replace each other.
- Running a helper again changes nothing. The undo takes the function off only when no claim on it is left: the
  helpers use the claims of the section above (target: the hook and the function, or the advised symbol and the
  function), so two modules adding the same named function tear down in either order, and a function that was on
  the hook before the module added it stays. `drgnx-module-unhook` and `drgnx-module-unadvise` drop the calling
  module's own claim early (its teardown then has nothing left to do); another module's claim keeps the function in
  place. Outside a setup the helper adds and records nothing; a name is a symbol, never a lambda.
- The safety net of the cleanup stack (below) records raw `add-hook` and `advice-add` calls a setup makes. It
  skips the helpers' own changes: every claim-aware helper (these two, and `drgnx-module-set`,
  `-alist-put`, `-face-spec`) makes its change inside `drgnx-modules--quietly`. A raw call is a fallback; use the
  helper.

### The safety net: what a setup reaches through Emacs's own doors

Code a setup reaches that does not push its own undo — wb modes, the setup functions of `wb/` libraries, packages'
mode functions — is recorded anyway. For each setup's extent only (`drgnx-modules--with-recorder`, inside
`drgnx-modules--run-setup`), drgnx advises four functions and removes the advice in `unwind-protect`, also after
an error, a quit or a throw (a second quit during the removal is held off). Outside a setup nothing is advised and
no call goes through the net; what stays is two properties `advice-remove` leaves on each advised symbol's plist
(`function-documentation`, `defalias-fset-function`), which change nothing.

| What the setup does | Recorded when | Undo (each checks first) |
|---|---|---|
| `add-hook` on a hook's global value | the function was not on it before | `remove-hook`, if it is still there |
| `advice-add` | `advice-member-p` was nil before | `advice-remove`, if still there |
| `add-to-list` on a list's global value | the element was not a member before (same test as `add-to-list`) | remove that one element, if still a member; others' additions stay |
| a new timer (`timer-list`, `timer-idle-list` compared before and after) | it is not one of Emacs's own (below) | `cancel-timer`, if still pending |
| a global minor mode newly in `global-minor-modes` | it was off before | `(MODE -1)`, if still on; pushed after everything the setup pushed, so modes go off first and their own off code runs before the hook and timer undos. This is the one break in last in, first out: a mode goes off before undos the setup pushed after turning it on |
| a feature newly in `features` | always | none: kept for the report, `(drgnx-modules-features-of MODULE)` |

Labels read `hook HOOK FN`, `advice SYMBOL FN`, `list VAR ELEMENT`, `timer FN`, `mode MODE` (`a lambda` for an
anonymous function), cut to 100 characters. The undos make teardown and rollback complete for these doors.

The net's undos are unconditional: they check that the thing is still there, not whether another module still
needs it. So a change made by a claim-aware API — one whose undo hands over to another module's claim (the helpers
above) — must not also be recorded by the net: such an API makes its change inside `drgnx-modules--quietly`, which
binds `drgnx-module--in-helper` (the three advices record nothing) and marks the timers and global modes started
in its extent as seen, for nobody. Then a mode that module A's option turned on stays on while module B's claim on
the option stands. A plain `drgnx-modules-push-undo` next to a raw call (an unconditional undo too) may be
recorded twice; that is harmless, since the second finds nothing to do.

What it does **not** record:

- **Buffer-local changes**: `add-hook … nil t`, a buffer-local list value. Buffers own those.
- **`add-to-list` on `global-minor-modes` or `local-minor-modes`**: Emacs 31's `define-minor-mode` keeps them that
  way; the modes are compared after the setup instead.
- **A drgnx helper's own changes** (`drgnx-modules--quietly`, above).
- **Emacs's own timers.** Emacs's libraries start singleton timers lazily from code a setup calls (an edit starts
  undo's boundary timer, a buffer's jit-lock its context timer) and keep them in a variable; cancelled, they would
  stay dead for the session (undo boundaries for process output would stop). A timer whose function is defined
  under `lisp-directory` (or preloaded), or that sits in one of `drgnx-modules--emacs-timer-variables` (jit-lock's
  lambdas), is left alone.
- **Global modes are owned by the first module that turns them on.** "Newly on" is all the net sees: when module
  A turns `drgnx-signal-mode` on and B relies on it, tearing A down turns it off. Modes a module shares go through
  an option (`drgnx-module-set`, claim-aware) or B's `:teardown`/`requires`. And a mode a setup turns *off* is not
  turned back on at teardown.
- **Timer callbacks that fire inside a setup** (`sit-for`, `accept-process-output`) run with the module current,
  so what they change is recorded onto it.
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

**Cost.** The safety net around a setup costs 16–22 µs (byte-compiled, 30.2: four `advice-add` and
`advice-remove`, two snapshots and their comparison), and up to about 70 µs in runs where the garbage it makes
brings a collection forward (65–73 µs measured so); 41 setups × 75 µs ≈ 3 ms at worst. The shipped startup stage (16 modules, batch) took 29.4 ms with
it and 28.2 ms without (5 runs each, within the runs' noise); the budget is 5 ms across all setups.
`test/unit/modules-record-test.el` covers it, including `startup-is-unchanged`: the shipped modules' startup stage
gives the same statuses and commands with the recorder as without it.

## The change bus (`wb/drgnx-signal.el`)

`drgnx-signal-mode` listens to the raw window and buffer hooks and emits deduplicated edges after an idle delay
(`drgnx-signal-delay`). A flush reads the buffer list only for what a hook said changed. `drgnx-signal--dirty` holds
the parts to rebuild, and each part has a named raw-hook function that sets it:

| Hook | Function | Sets |
|---|---|---|
| `buffer-list-update-hook` (a buffer made, killed, selected or renamed) | `drgnx-signal--set-dirty` | `set` |
| `first-change-hook`, `after-save-hook`, `after-revert-hook` | `drgnx-signal--modified-dirty` | `modified` |
| `after-save-hook` (`write-file` under the buffer's own name makes it a file buffer, with no rename) | `drgnx-signal--set-dirty` | `set` |
| `after-change-major-mode-hook` (`dired-mode` on an existing buffer; internal buffers are skipped) | `drgnx-signal--mode-changed` | `set` |
| `kill-buffer-hook` | `drgnx-signal--killed` | `set` and `modified` |
| `post-command-hook` | `drgnx-signal--post-command` | nothing, unless the current buffer's modified flag or name differs from the cached one |

`set` rebuilds `:set` and `:names` (and `:modified` with them, since the buffers changed); `modified` rebuilds
`:modified`. A part that is not dirty keeps its cached value, so a keystroke that changed no buffer costs the
post-command comparison and a flush that compares only the editor window and its point (a median of about 5 µs with 300
buffers, byte-compiled, against 479 µs when every flush scanned them). Undo back to the saved state and
`set-buffer-modified-p` run no hook, which is what the comparison is for; it covers the current buffer, and a buffer
that becomes current is compared with what the last flush saw of it (two `assq`, no buffer list). With the mode off
nothing says what changed, so a flush called directly (tests, the bench) rebuilds everything. The edges and what they
mean are unchanged. The hooks are added by the mode, so the mode owns them; a module that needs the bus turns the mode
on (see "Global modes are owned by the first module that turns them on" in the safety net above).

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

## TOML (`drgnx-toml.el`)

A minimal reader and a writer that changes one table only, for config files drgnx edits but does not own (the
agent settings pages use it on Codex's `config.toml`).

| Function | Does |
| --- | --- |
| `drgnx-toml-parse STRING` | The whole file as an alist in file order: tables are alists, arrays vectors (arrays of tables are vectors of alists), `t` / `:false`, numbers, strings; a date or time is `(:date . "TEXT")` and is written back bare. Comments, bare/quoted/dotted keys, `[a.b]`, `[[a.b]]`, basic/literal/multi-line strings, inline tables and multi-line arrays are read. A syntax error signals `drgnx-toml-error` with data `(LINE MESSAGE)`. |
| `drgnx-toml-table-region STRING PATH` | `(BEG . END)` (0-based) of `[PATH]` and its sub-tables (`[PATH.x]`), up to the last key line; blank lines and comments after it belong to what follows. nil when absent. |
| `drgnx-toml-set-table STRING PATH ALIST` | STRING with that region replaced by fresh text (nested alists as inline tables), added at the end when absent (after a blank line), removed when ALIST is nil. |
| `drgnx-toml-set-array-entry STRING PATH PRED ALIST` | The same for the first `[[PATH]]` entry PRED (called with the entry as an alist) accepts; appended when none is. |
| `drgnx-toml-encode-value VALUE` | One value as TOML text. |

Every byte outside the changed region stays as it was: comments, order, unknown keys, spacing, line ends, a leading
byte order mark. New text uses the file's own line end (CRLF when its first line ends that way). PATH is a
list of keys, so dotted and quoted names (`("projects" "/p")`) work. A table that is defined some other way than by
its own header (dotted keys in a parent table, an inline table, an array of tables, a header split into
pieces, or a parent of an array of tables, which would become an inline array) is read but never written: the writer signals `drgnx-toml-error` with the line, so a caller reports it
and writes nothing. Text drgnx writes is re-encoded (comments inside the replaced table go), which is why callers keep one backup per write.

## Agent settings model (`drgnx-agent-config.el`)

What the settings pages of Claude Code, Codex, Gemini and Kimi Code share; each agent's own file (later tasks)
implements the three generic functions. Tests use `test/fixtures/agent-config-fixture.el` (`drgnx-agent-config-test-env`:
temp agent homes and HOME, a temp project, fake `claude`/`codex`/`kimi` scripts that log their argv); a test never
reads the user's real agent homes.

An item is a plist `(:kind :section mcp|hook|skill :name :from user|project|local|plugin|extension|system|legacy :file
:line :spec :enabled :readonly :problem)`; `:spec` is `(:type :command :args :env :url :headers)` for an MCP server
(`:env`, `:headers` alists), `(:event :matcher :command :timeout)` for a hook, `(:dir :description)` for a skill.

| Function | Does |
| --- | --- |
| `drgnx-agent-config-kinds`, `-title KIND` | `(claude codex gemini kimi)`; "Claude Code", "Codex", "Gemini", "Kimi Code". |
| `drgnx-agent-config-vendor-env` | The vendor keys and switches nothing drgnx starts for an agent inherits: the default of `drgnx-agents-scrubbed-env`, and what MCP Test and Hook Test unset (drgnx-agent-check.el reads the customized list when drgnx-agents is loaded). |
| `-home KIND` | The agent's user directory (trailing slash): `$CLAUDE_CONFIG_DIR` / `~/.claude`, `$CODEX_HOME` / `~/.codex`, `$GEMINI_CLI_HOME/.gemini` (gemini 0.64 replaces its home directory with that variable) / `~/.gemini`, `$KIMI_CODE_HOME` / `~/.kimi-code`. An empty variable counts as unset. |
| `-read KIND ROOT`, `-scopes KIND SECTION ROOT`, `-write KIND OP ITEM SCOPE ROOT CALLBACK` | Generic functions (`cl-defgeneric`, `eql` specializers on KIND) each agent file implements: everything configured as `(:rules :items :problems :routes :notes)`; where an add may go, `((SCOPE LABEL FILE)…)`; add/edit/remove/toggle with a callback getting `(:ok t :note S)` or `(:error S)`. |
| `-json-read FILE` | `(:value V :indent N)`: objects are alists with symbol keys in file order, arrays vectors, `:null`, `:false`. A missing or blank file is `(:value nil :indent 2)`; one that does not parse signals `drgnx-agent-config-unreadable` with `(FILE LINE MESSAGE)` (a trailing comma names the comma's line). |
| `-json-write FILE VALUE INDENT [EXPECT]` | Key order as in VALUE, INDENT spaces, a final newline; through `-write-text`, with the file's and the new text's JSON parse as checks. Unreadable files are never written. A VALUE that is not JSON is an error naming its place and type (`Not a JSON value at mcpServers.x.args (a list, expected a vector)`), never its content. |
| `-write-text FILE TEXT CHECK [VERIFY [EXPECT]]` | EXPECT (the text, or the modification time, seen when the caller read FILE): a FILE that differs now signals `drgnx-agent-config-changed` and nothing is touched (Claude Code rewrites `~/.claude.json` often). CHECK (called with FILE's current text) must not signal, else nothing is touched; VERIFY the same with TEXT. TEXT equal to what FILE holds is not written and the backup stays. Then FILE is copied to `FILE.drgnx-bak` (exactly one backup, with FILE's modes), TEXT goes to a temp file next to FILE with FILE's modes (0600 for a new file) and is renamed over it. A symlink is written through; directories it has to make get 0700. The TOML writes use it too. |
| `-secrets SPEC`, `-mask-text TEXT SECRETS` | Every env and header value, and the value of any key matching token, secret, key, password or authorization (case-insensitive; every string inside a list or object under such a key), longer than 3 characters. Also, in `:args`, `:url`, a hook's `:command` and every other string, only the secret part of: `NAME=VALUE` / `--flag=VALUE` with a secret-ish name, `Bearer`/`Basic`/`Token` values, `Authorization:` values, URL userinfo and secret-ish query parameters, well-known token shapes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`, JWTs), the argument after a secret-ish flag, `-p`, `-H`/`--header` and `-e`/`--env`, and 24+ character `:url` path segments. `-mask-text` replaces each by `••••` and keeps the context. |
| `-cheap-status ITEM [ROOT]` | `(ok . DETAIL)`, `missing-command`, `no-url` or `unreadable`, from files and `exec-path` only: nothing is run. A relative command with a slash is the spec's `cwd`'s (relative to ROOT), else ROOT's, else `~/`'s, never `default-directory`'s. The detail is masked like any text shown (a URL keeps its host and path, not its secrets). |
| `-save-backup FILE`, `-json-read-text FILE TEXT` | The one-backup copy used by `-write-text` (public: a CLI write takes its own backup first); `-json-read` for a text already read. |
| `-json-keystr`, `-json-str`, `-json-alist-p`, `-json-cell OBJ KEY`, `-json-get OBJ KEY…`, `-json-set OBJ KEYS VALUE`, `-json-del OBJ KEYS`, `-json-strings`, `-json-string-alist`, `-json-pairs` | Taking apart and changing a parsed JSON object (a path is a list of key strings): a set member keeps its place and a new one goes last; `-json-pairs` turns `(("NAME" . "value")…)` into an object, refusing a value that is not text. Shared by all four agent files. |
| `-json-modify FILE FUNCTION` | Replace the JSON object in FILE with `(FUNCTION VALUE)`: one read, the write refused when FILE changed since, tried once more with the new content, a second refusal signals `drgnx-agent-config-changed`. |
| `-hook-matcher= GROUP MATCHER`, `-error-text ERR ITEM` | A JSON hook group has the matcher (nil and `""` are the same); the message for a failed write: where and why, never the item's data. |
| `-skills-in DIR FROM KIND`, `-new-skill DIR NAME DESCRIPTION` | Items for `DIR/*/SKILL.md` (name and description from the front matter); creates a skill, refusing an existing name. |

JSON that is tab-indented is re-written with 2 spaces; arrays are always written one entry per line.

## Claude Code's settings (`drgnx-agent-config-claude.el`)

The `claude` methods of the three generic functions, and `drgnx-agent-config-claude-routes`. Read: the files below;
write: only the entry that changed, with one backup next to the file. Credential files are never opened; no key is
looked up.
`drgnx-agent-config-claude-hook-events`: Claude Code's hook events, offered by the settings page (other names may be typed).

| What | Where |
| --- | --- |
| User MCP servers | `mcpServers` in `(drgnx-agent-config-claude-json-file)`: `$CLAUDE_CONFIG_DIR/.claude.json` when the variable is set, else `~/.claude.json` (not inside `~/.claude`). |
| Local MCP servers | `projects[ROOT].mcpServers` in the same file (ROOT without the trailing slash). |
| Project MCP servers | `ROOT/.mcp.json`. |
| Read only | The enabled plugins' servers (`plugin:PLUGIN:SERVER`), skills and `managed-mcp.json`; hooks of the managed settings (`managed-settings.json`, `managed-settings.d/*.json` in `/etc/claude-code`, `/Library/Application Support/ClaudeCode` on macOS). Plugins come from `plugins/installed_plugins.json` and `enabledPlugins`. |
| Hooks | `hooks` of `HOME/settings.json` (user), `ROOT/.claude/settings.json` (project), `ROOT/.claude/settings.local.json` (local). |
| Skills | `HOME/skills`, `ROOT/.claude/skills`; on or off by `skillOverrides` (`"off"`; absent is on; `name-only` and `user-invocable-only` still count as on). |
| Rules | `HOME/CLAUDE.md`, `ROOT/CLAUDE.md`, `ROOT/.claude/CLAUDE.md` when present. |

How a write goes (`-write 'claude OP ITEM SCOPE ROOT CALLBACK`; for an edit ITEM carries `:replaces`, the item it replaces):

- **User and local MCP servers** run `claude mcp add-json NAME JSON --scope S` / `claude mcp remove NAME --scope S` in ROOT
  (asynchronous, 20 s each; an edit is a remove, then an add; a backup of `.claude.json` is taken first). A server whose
  `drgnx-agent-config-secrets` is not empty never goes on a command line: `-merge-entry` re-reads the file, merges the one
  entry and writes it directly, and the note says to restart running Claude sessions. Claude Code rewrites the file every
  few seconds: each direct write passes what it read as EXPECT, so a file that changed is read again and the entry merged
  again, once; a second change is reported ("changed by another program") and nothing is written.
- **`.mcp.json`, hooks and `skillOverrides`** are edited directly (key order and indent kept). Switching a skill off
  writes `"off"` into the user's settings (a project skill: the project-local settings, private); switching it on removes
  an `"off"` from every settings file that has one.
- An edit keeps the members of an entry drgnx does not edit (an MCP server's `oauth` or `headersHelper`, a hook's
  `statusMessage` or `async`): they are merged into the existing object. An MCP entry that has such members is edited
  directly, not through the CLI, so nothing is dropped. If an edit's `remove` worked and its `add-json` failed, the old
  entry is put back by a direct write ("the change failed; the previous entry was put back"); only if that fails too does
  the message point to the backup, which the next command line write then leaves alone until the name is written again.
  The backup is taken only when `claude` will run.
- Switching a skill on removes the `"off"` from the settings files that make it off (local, then project, then user, up
  to the first other value) and names them; every file is parsed before one is written. Switching it off warns when a
  higher-priority file sets another value.
- A server name is letters, digits, `.`, `-` and `_` and cannot start with `-` or `.` (it is a command-line argument);
  other names (spaces) are a drgnx limit: edit them in Claude Code.
- Errors name the file and line, never the entry's data (values are masked with `-secrets` besides).

`(drgnx-agent-config-claude-routes ROOT)` lists one route per Claude Code profile (command `claude-agent-acp`) with its
billing, derived from the provider and not from the profile's name: no `:ai` is the subscription; the OpenRouter
provider `openrouter`; a loopback URL `local`; any other provider (a `:key-env`) `per-token`, the vendor being the
provider's name. `:key-where` names the variable and the keyring host. An `env` entry of a settings file that sets
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_SMALL_FAST_MODEL` or
`ANTHROPIC_DEFAULT_*_MODEL` is a note ("overrides every profile's route"), by file and name, never the value.

## Kimi Code's settings (`drgnx-agent-config-kimi.el`)

The `kimi` methods of the three generic functions (checked against kimi-code 2.2.0). Read: the files below; write: only
the entry that changed, with one backup next to the file. `HOME/credentials/` is never opened and no key is looked up.
The route is one: Kimi Code's own login (`kimi login`), billing `subscription`.

| What | Where |
| --- | --- |
| Home | `(drgnx-agent-config-home 'kimi)`: `$KIMI_CODE_HOME` (unset or empty: `~/.kimi-code`). |
| User / project MCP servers | `mcpServers` of `HOME/mcp.json` and `ROOT/.kimi-code/mcp.json`. An entry has `command` (stdio) or `url` (http; `transport` "sse" is written for sse); `enabled` false is off; `bearerTokenEnvVar` names a variable. |
| Read only | `ROOT/.mcp.json` (Kimi Code reads it too; Claude Code's page edits it), the enabled plugins' servers (`plugin-ID:SERVER`), hooks and skills (`HOME/plugins/installed.json`, each root's `kimi.plugin.json` or `.kimi-plugin/plugin.json`), and the old kimi-cli's `~/.kimi` (`mcp.json`, `config.toml` hooks, `skills/`) under `:from legacy` with the note "the old kimi-cli's config: kimi-code migrates from it; drgnx does not edit it". |
| Hooks | `[[hooks]]` tables (`event`, `matcher`, `command`, `timeout` 1 to 600) in `HOME/config.toml`, user scope only. Hooks written some other way (an inline `hooks = [...]`) are read only, with `:reason` naming the line. |
| Skills | `HOME/skills`, `~/.agents/skills`, `ROOT/.kimi-code/skills`, `ROOT/.agents/skills`. The format has no off switch: a skill is always on and a toggle is refused. |
| Rules | `HOME/AGENTS.md`, `ROOT/.kimi-code/AGENTS.md`, `ROOT/AGENTS.md` when present. |

Writes are synchronous (the callback runs at once). An MCP edit merges the modelled members (`transport`, `command`,
`args`, `env`, `cwd`, `url`, `headers`, `bearerTokenEnvVar`) into the entry that is there and keeps every other member
(`enabled`, timeouts, `auth`, tool lists, ...); a rename keeps the entry's place. A hook edit does the same for its
table. Each write re-reads the file just before and passes what it read as EXPECT, so a file changed meanwhile is read
again, once; a second change is reported and nothing is written. A file that does not parse is reported with its line
and never written. Errors never show the entry's data. The hook events are the 16 `config.toml` accepts; any other
makes Kimi Code reject the whole file, so drgnx refuses it.

## Codex's settings (`drgnx-agent-config-codex.el`)

The `codex` methods of the three generic functions, `drgnx-agent-config-codex-trusted-p`, `-routes`, `-openrouter-snippet`
and `-add-openrouter`. Formats checked against codex 0.163.0. Credential files (`auth.json`) are never opened.
`drgnx-agent-config-codex-hook-events`: Codex's hook events, offered by the settings page (other names may be typed).
A config.toml that does not parse is a problem "not valid TOML" with its line, never the parser's text (it quotes the file).

| What | Where |
| --- | --- |
| User settings | `CODEX_HOME/config.toml` (`$CODEX_HOME`, else `~/.codex`). |
| Project settings | `ROOT/.codex/config.toml` and `ROOT/.codex/hooks.json`, read only when `(drgnx-agent-config-codex-trusted-p ROOT)`: the user's config has `[projects."ROOT"]` with `trust_level = "trusted"` for ROOT or its repository root. Otherwise they are still read and shown: each item carries `:inactive "Codex ignores it until the project is trusted"` and `:notes` names the file, because trust gates the effect, not the display (drgnx matches ROOT, its real path and the nearest folder with a `.git`; a git worktree has a `.git` of its own, so only its own path counts here, and whether Codex also honours the main checkout's entry is not verified). |
| MCP servers | `[mcp_servers.NAME]`: `command`/`args`/`env` (stdio), `url`/`bearer_token_env_var`/`http_headers`/`env_http_headers` (streamable HTTP; no `sse`), `enabled`. `:headers` holds the literal `http_headers` values (secrets, masked); `env_http_headers` give `:env-headers` (header names) and `:env-header-vars` (the variable names, same order): names are not secrets, so the page shows them as "from $NAME" unmasked. A value there that cannot be a variable name is also put in `:headers`, so it is masked. |
| Hooks | `hooks.json` of the Codex home and of ROOT/.codex (editable, shaped like Claude Code's); inline `[[hooks.EVENT]]` in a config.toml are shown read-only with a note to edit hooks.json. |
| Skills | `~/.agents/skills`, `ROOT/.agents/skills`; off by a `[[skills.config]]` entry (`path` of the skill's `SKILL.md` or directory, `enabled = false`) in the user's config.toml (the state is read from the user's config only, not from a project's). |
| Rules | `CODEX_HOME/AGENTS.md`, `ROOT/AGENTS.md`. |

Writing: a TOML write parses the file first (one that does not parse, or has a duplicate table, is never written), builds
the new text with `drgnx-toml-set-table` / `-set-array-entry` (nothing outside the changed table moves; comments inside
a replaced table do not survive: the backup has them), checks it parses, and goes through `-write-text` with what it read
as EXPECT (one retry when Codex changed the file meanwhile). A server table is rebuilt from the existing one with only the
modelled keys replaced, so `startup_timeout_sec`, `enabled_tools` and other keys stay; a rename is one write. A hook edit
keeps the hook object's other members (`statusMessage`, `async`) and its group's. Toggling an MCP server changes only its `enabled` key in the text (a word swapped or one line added under the header; comments and value forms stay; a table that is not shaped so is rebuilt);
toggling a skill adds, changes or removes its `[[skills.config]]` entry (an entry with other keys only has `enabled`
changed). A project write in an untrusted project works and says Codex ignores it until the project is trusted.

Routes: `(:profile "codex" ... :billing subscription)`, "its own CLI with your ChatGPT login", then one per
`[profiles.NAME]` whose `model_provider` is OpenRouter (the id `openrouter` or a `base_url` on openrouter.ai) with
`:billing openrouter` and `:launch "codex --profile NAME"`. `(drgnx-agent-config-codex-add-openrouter MODEL)` writes
`[model_providers.openrouter]` (`name`, `base_url = "https://openrouter.ai/api/v1"`, `env_key = "OPENROUTER_API_KEY"`,
`wire_api = "responses"`: 0.163 refuses `chat`) and `[profiles.openrouter]` (`model_provider`, `model`) into the user's
config.toml, keeping other keys of those two tables (a `base_url` or `env_key` that differs from OpenRouter's is the user's: kept, and the note says so; only `wire_api = "chat"` is changed); the default stays the ChatGPT login. `-openrouter-snippet MODEL` is
the same two tables as text to paste.

## Gemini CLI's settings (`drgnx-agent-config-gemini.el`)

The `gemini` methods of the three generic functions, and `drgnx-agent-config-gemini-routes` (one route: Gemini's own CLI
with a Google login, `subscription`; the login is never read). Checked against gemini 0.64.0. It uses the shared JSON
helpers of `drgnx-agent-config.el`; only its comment-refusing `drgnx-agent-config-gemini--modify` is its own.

| What | Where |
| --- | --- |
| User / project settings | `HOME/settings.json` (HOME is `.gemini` under `$GEMINI_CLI_HOME`, else `~/.gemini`), `ROOT/.gemini/settings.json`. |
| System (read only) | `$GEMINI_CLI_SYSTEM_SETTINGS_PATH` else `/etc/gemini-cli/settings.json` (macOS: `/Library/Application Support/GeminiCli`), and `system-defaults.json` (`$GEMINI_CLI_SYSTEM_DEFAULTS_PATH`). |
| MCP servers | `mcpServers`. In 0.64.0 `url` plus `type` http or sse is current, `url` alone is Streamable HTTP (the docs say SSE), `httpUrl` is deprecated: read as http, never written. Edits write `url` + `type`. |
| Hooks | `hooks.EVENT[]` = `{matcher, sequential, hooks: [{type, command, name, timeout}]}`; `:timeout` is in milliseconds (`:timeout-unit ms` in the spec). Off by `name` (else the command) in `hooksConfig.disabled`. |
| Skills | `HOME/skills`, `$GEMINI_CLI_HOME-or-~/.agents/skills`, `ROOT/.gemini/skills`, `ROOT/.agents/skills`, extensions' `skills/` (read only). Off by name in `skills.disabled`, the union of all settings files. |
| Extensions | `HOME/extensions/*/gemini-extension.json` (`mcpServers` as `extension:NAME:SERVER`) and `hooks/hooks.json`, read only. On unless `extensions/extension-enablement.json` has a rule for NAME that matches the project (last wins, `!` disables). |
| Rules | `GEMINI.md`, or the names in `context.fileName`, in HOME and ROOT. |

Gemini reads its settings files with comments (JSONC) and keeps them when it writes; drgnx cannot. A file with comments is
read (comments ignored, line numbers kept), its items are read-only, a note says why, and it is never written. A write
changes only the modelled members of one entry (`command`, `args`, `env`, `url`, `httpUrl`, `type`, `headers`; a hook's
`type`, `command`, `timeout`) and keeps every other member in place (`cwd`, `trust`, `includeTools`, unknown keys); it passes
what it read as EXPECT, so a file changed meanwhile is refused. Switching a skill off adds its name to `skills.disabled` of the
user's settings (or the chosen file); switching it on removes it from every writable file that lists it (the project's
file is shared with the team, and the note says so). All those files are checked first (parse, no comments, not listed by the
system settings) and nothing is written if one fails; a later failed write puts the earlier files back and says so. An edit of an
http server that has `httpUrl` keeps `httpUrl` (older Gemini CLIs). Hooks and MCP servers cannot be switched off here. A new server name is letters, digits, `-`
and `.` (Gemini's policy rules misread an underscore).

## MCP Test and Hook Test (`drgnx-agent-check.el`)

The two checks of the agent settings pages. Both run the user's configured command, so they run only from a command
(Test, Test all), never from a timer, hook or sentinel, and never in the editing Emacs. Tests use the mock server in
`test/fixtures/mock-mcp.el` only (stdio modes `ok`, `hang`, `crash`, `flood`, `echo-env`, `fork-child` as
`emacs --batch -Q -l mock-mcp.el -f drgnx-mock-mcp-main MODE MARKER`, plus `error` and `oom`; an HTTP one,
`drgnx-mock-mcp-http-start MODE` with `ok`, `needs-login`, `hang`, `error-body`, `echo-path` and `legacy-sse`, served by
the test Emacs); never the user's servers, hooks or agent homes. The tests run with `DRGNX_JOBS_LAUNCHER=detached`, so
they never create a scope in the user's systemd manager.

| Function | Does |
| --- | --- |
| `drgnx-agent-check-timeout` | 20 seconds for an MCP Test. |
| `(drgnx-agent-check-mcp ITEM ROOT CALLBACK)` | Starts a batch Emacs (`emacs --batch -Q -L core -l drgnx-agent-check -f drgnx-agent-check-main`) inside `systemd-run --user --scope -p MemoryMax=512M -p MemorySwapMax=0` when `(drgnx-jobs-launcher)` is `systemd`, and returns its process. The server's spec (command, args, environment, URL, headers, the secrets to hide) is one line of JSON on that Emacs's stdin: never a command line, never a file. CALLBACK gets `(:status ok\|failed\|needs-login\|timeout :tools NAMES :error STRING :stderr STRING :time FLOAT)`, masked. `${VAR}` and `${VAR:-default}` are expanded for Claude Code and Gemini, as those agents do, and the expanded values are masked too. |
| `drgnx-agent-check-main` | Child side. stdio: starts the server in ROOT with its environment, sends `initialize` (MCP revision 2025-06-18), `notifications/initialized` and `tools/list` (every page), ends the server's whole tree (descendants, its group and session) at the end. HTTP (`http` and `sse` items; Streamable HTTP only): POSTs the same, keeps the `Mcp-Session-Id` and `MCP-Protocol-Version`, reads JSON or SSE answers (an SSE stream the server leaves open is fine). A 401 with `WWW-Authenticate` is `needs-login`, and `:error` says how to log in (`drgnx-agent-check-login-hint`: Claude `/mcp`, Codex `codex mcp login NAME`, Gemini `/mcp auth NAME`). Limits: the timeout; 256 KB of output that is not JSON-RPC (a flood); 4 MB for one message or answer; stderr 8 KB. This Emacs ends the child (and everything under it) 5 seconds after the timeout if it did not. A TLS certificate that cannot be verified is refused (the child cannot ask), so a server with a self-signed certificate fails with a message saying so. A connection that never completes is ended by the 5-second backstop above. |
| `(drgnx-agent-check-hook ITEM ROOT CALLBACK)` | Runs the hook's command with `sh -c` in ROOT (in the same memory cap), the sample event as JSON on stdin, for the hook's timeout (Gemini's is milliseconds) or 60 seconds. The command travels in the environment (`DRGNX_HOOK_COMMAND`, unset before it runs), not on a command line. CALLBACK gets `(:exit N :stdout S :stderr S :time F)`, masked, 16 KB each; a hook that ran out of time has `:exit nil :timeout t`; one that could not start has `:exit nil :error S`. |
| `(drgnx-agent-check-sample-event KIND EVENT ROOT)` | The event as an alist. Claude Code and Kimi Code: `session_id`, `transcript_path`, `cwd`, `hook_event_name` and per event `tool_name` `Bash` with `tool_input` `{"command": "echo drgnx-hook-test"}` (and `tool_response`, `prompt`, `source`, `trigger`, … as the event has them). Codex: the same plus `model` and `turn_id`. Gemini: its own events (`BeforeTool` with `run_shell_command`, `BeforeAgent` with `prompt`, …) and `timestamp`. The Codex and Gemini fields are the builder's table from their documentation, not checked against a running agent. |
| `(drgnx-agent-check-remember ITEM RESULT)`, `(drgnx-agent-check-last ITEM)` | The last result per `(KIND SECTION NAME FILE)` in `(drgnx-state-dir)/agent-checks.eld` (0600), masked, with `:at` (the time). Each write keeps the newest 300 (by `:at`) and drops results whose local FILE is gone. |
| `(drgnx-agent-check-results)` | Every remembered result in one read, `((KIND SECTION NAME FILE) . RESULT)…` (the settings page reads it once per drawing). |

Ending a check: the child Emacs and the scope it runs in are named (`systemd-run --scope --unit=drgnx-check-PID-N`); at
the timeout this Emacs runs `systemctl --user kill --signal=KILL` on the scope as an asynchronous process, so the editing
Emacs does not stop (11 ms longest stall measured). The scope name has a random part. The kill is started from the
temp directory (a timer runs in any buffer, whose directory may be gone); if `systemctl` cannot be started or fails the
tree is ended instead; 3 seconds after the timeout the check is over whatever happened (tree ended, a hanging `systemctl`
deleted, the callback called once). A check that ends normally also asks systemd to clear its scope and ignores the answer. Where there is no systemd (or `systemctl` fails) it ends the process
tree: parent, group and session links are read from `/proc/PID/stat` (45 ms for 640 processes; `process-attributes`
needs 320 ms), the tree is stopped, found again until it does not change, then killed. The child ends its server the same way.

Secrets: every string a check hands back is masked, in the members `:error`, `:stderr`, `:stdout` and `:tools` (not the
status, the time or the exit code), with the item's secrets (`drgnx-agent-config-secrets`); the values `${VAR}` (and
Gemini's `$VAR`) were replaced by; the variables a spec names for a bearer token or a header (Codex `bearer_token_env_var`
and `env_http_headers`, Kimi `bearerTokenEnvVar`, sent as `Authorization: Bearer VALUE` and the named headers when set);
and this Emacs's own secret-looking environment, because a server may print its environment: a name with token, secret,
key, password, passwd, authorization, cred, cookie, dsn or pat in it always, a name with only pass, auth or session in it
unless it is `XDG_SESSION_TYPE`, `XDG_SESSION_CLASS`, `XDG_SESSION_ID`, `XDG_SESSION_DESKTOP`, `XDG_SESSION_PATH`,
`DESKTOP_SESSION`, `GDMSESSION`, `SESSION_MANAGER`, `DBUS_SESSION_BUS_ADDRESS`, `XAUTHORITY`, `ICEAUTHORITY`,
`SSH_AUTH_SOCK` or has askpass in it (`drgnx-agent-check--not-secret-names`), and the userinfo of URL values. In a
server's own configuration the names with pass, auth or session count too. Each secret
is also hidden percent-encoded, percent-decoded, JSON-escaped and cleaned (so a secret with a carriage return still matches). Overlapping matches are one range
(`drgnx-agent-config-mask-text`). A short value (4 to 7 characters) with a plain name (`MODE=prod`) is hidden in errors
and stderr but not in tool names. Output is cleaned first (escape sequences, control characters, bytes that are not UTF-8),
then masked, then cut to its limit, so a secret is never split by an escape or cut in two. An HTTP error body is masked
before its first 200 characters are shown, and a JSON-RPC error is cut to 500. A project on a remote host (TRAMP) is
refused. A signal 9 is said to be the memory cap only when the check runs in a scope. Hooks get `CLAUDE_PROJECT_DIR` (Claude Code, Kimi Code, Gemini) and `GEMINI_PROJECT_DIR` (Gemini). An unset
`${VAR}` with no default is passed as written and named in the result (`:unset`, and in `:error` when the check failed).
The only file written is `agent-checks.eld`; the child Emacs writes nothing.

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

`claude-adapter` (group Tools): the fact is `drgnx-agents-claude-adapter` (`drgnx-agents.el`), the adapter that the
claude profiles would run, with the name, version and npm prefix read from the `package.json` it links into. The
adapter is never run. The judgement is `drgnx-agents-adapter-problem`, the same one the onboarding Agents step and
the agent start use. The maintained package at `drgnx-agents-claude-min-version` (0.93.0) or newer is OK. The
deprecated `@zed-industries/claude-agent-acp`, an older version, or a program of no known package is WARN. The fix
is an npm command in the adapter's own global prefix, or `drgnx-agents-adapter-advice` when there is none (pnpm,
volta, a project's `node_modules`). None is INFO. A `package.json` is read only when it is a regular file of at most
64 KiB (`drgnx-agents--package-json-max`; a FIFO would block the read); otherwise it is no known package. A
pre-release version is compared without its `-…`/`+…` suffix. Tests: `test/unit/doctor-test.el` and
`test/unit/agents-adapter-test.el`.

## Pane kinds (`wb/drgnx-panes.el`)

Every pane (Explorer, agents, terminal, help, …) is one data definition, a kind, made with
`(drgnx-pane-define-kind KIND :title :buffer :placeholder :home :size :view :slot :height :fill :on-show :on-focus :stack)`.
`:home` is `left`, `bottom`, `right` or `editor`. Callers show and find panes by kind and never use the dock, area
or section API directly: `drgnx-pane-show` (`:buffer`, `:select`), `drgnx-pane-hide`, `drgnx-pane-toggle`,
`drgnx-pane-focus`, `drgnx-pane-window`, `drgnx-pane-kind`, `drgnx-pane-kinds`. `drgnx-pane-show` never changes
the selected window unless `:select` is given. `drgnx-pane-backend` (`areas`) says where kinds live; `areas` forwards
a `left` kind to `drgnx-wb-define-section`, a `bottom` or `right` kind to `drgnx-wb-define-tab` (areas `panel` and
`right`), an `editor` kind (its `:buffer` a name) to a `drgnx-wb-place` rule, and `:fill` to
`drgnx-layouts-define-pane`. A backend is an entry in `drgnx-pane--backends` (the functions for `:define`, `:show`,
`:hide`, `:window`, `:focus`); the tiled grid registers `grid` there. Switching backends and replaying the
defined kinds into the new one is the grid's job (B3), not done here. Test: `test/unit/wb-panes-test.el`.

What the `areas` backend does with the edges:

- `:buffer` is a function, a buffer, or a buffer name (made when missing). A left kind ignores `show :buffer`
  (a section's buffer is its own).
- `hide` does nothing for a kind that is not shown: another view's left kind, or a bottom or right kind that is not
  the area's front tab. Hiding a left kind hides the whole left dock. An editor kind has no hide (so `toggle` of
  one that shows does nothing).
- `drgnx-pane-window` is nil for a non-front tab and for a left kind of another view. An editor kind's window is the
  one showing the last buffer `show` or `focus` put there on that frame (a function `:buffer` or a `show :buffer`
  included).
- `:size` and `:stack` are stored for the grid and not applied; the docks keep their own sizes.
- `:on-show` runs on every `show`, for every home.
- `show` without `:select` never moves focus. A view swap from a window inside the left dock leaves the dock
  first, so focus ends in the editor window rather than in the new dock.
- Redefining a kind with another home takes it out of its old dock; an editor kind's place rule goes when its
  `:buffer` or home changes.

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.
