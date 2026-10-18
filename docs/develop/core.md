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

## Window managers (`drgnx-platform.el`)

Emacs cannot move a frame to another monitor by itself under Wayland, and a tiling window manager ignores
`set-frame-position`. An *adapter* knows one window manager (or none): its monitors, which one a frame is on, and
how to move a frame. Nothing here blocks, prompts or signals on an automatic path (frame creation,
monitors-changed, restore): every window-manager call is asynchronous with a deadline.

**Detection** is per frame, from the frame's own environment (`(getenv VAR frame)`, else the daemon's), because
one daemon serves frames from several sessions. `(drgnx-platform-detect ENV WINDOW-SYSTEM)` is pure (ENV is a
function VAR -> value) and tries the adapters in definition order:

| Window system | Order |
|---|---|
| `ns` | `ns` |
| `pgtk` | `sway` (`SWAYSOCK`), `hyprland` (`HYPRLAND_INSTANCE_SIGNATURE`), `niri` (`NIRI_SOCKET`), `kwin` (`XDG_CURRENT_DESKTOP` lists `KDE`), `gnome` (lists `GNOME`), else `other-wayland` (also pgtk with only `DISPLAY`) |
| `x` | with `WAYLAND_DISPLAY` (Emacs on XWayland): the compositor's adapter, as for pgtk. Otherwise `i3` (`I3SOCK`, or the root window's `I3_SOCKET_PATH`; only checked for existence), else `x11` |
| terminal frame | `tty` |
| none (batch) | `WAYLAND_DISPLAY` stands for pgtk, `DISPLAY` for x; neither: `none` |

`(drgnx-platform-wm &optional FRAME)` returns the name and caches it in the frame parameter `drgnx-platform-wm`;
it never starts a process. A terminal frame counts as a workbench frame elsewhere, so commands check
`display-graphic-p` themselves (the `tty` adapter explains).

**Calls.** `(drgnx-platform-call ARGV :env :timeout :callback)` runs a program without blocking. The callback gets
`ok`, `error` or `timeout` and the output, exactly once, never before the function returns; at the deadline the
process is killed and its later output dropped; a missing program is an `error` ("PROGRAM is not installed"); an
error in the callback is shown with `message`; standard error is read to the end before a failed call is reported;
output is decoded as UTF-8. Deadlines: `drgnx-platform-command-timeout` (2 s, commands),
`drgnx-platform-restore-timeout` (5 s, restoring frames), `drgnx-platform-doctor-timeout` (1 s, the doctor's and
typed commands' `drgnx-platform-call-sync`). `(drgnx-platform-process-env FRAME)` gives the session variables of
the frame as `"K=V"` strings for `:env`; an adapter function calls `(drgnx-platform-ctx-call CTX ARGV CALLBACK)`,
which adds them and the deadline of the operation.

**Monitors** are plists `(:name :make :model :serial :geometry (X Y W H))`. `(drgnx-platform-number-monitors)`
sorts them left to right, then top to bottom and adds `:number` and `:label` ("1 — eDP-1, 1920×1200", "2 — DP-2,
2560×1440, right of 1"). `(drgnx-platform-match-monitor SAVED MONITORS)` finds a saved monitor again: make, model
and serial (all non-empty), else the name, else the geometry. Under pgtk Emacs' monitor `name` is GDK's model
string ("Unknown" under sway), not the compositor's output name, and Emacs lists monitors in no stable order: an
adapter that talks to a compositor matches Emacs' monitors to the compositor's by geometry. For that reason the
monitors drgnx builds from a pgtk frame's `display-monitor-attributes-list` (the gnome adapter's) get the name
`""`: a name is identity only when an adapter that knows the compositor vouches for it (X11 and XWayland report
the real connector names).

**Public operations** (all take a callback; `(:error MESSAGE)` instead of a signal, whatever the adapter does:
a signal in its function, in its reply (a monitor list that cannot be numbered) or in a timer of its own; an adapter
that does not answer within its deadline plus `drgnx-platform-watchdog-margin` (1 s) gets `(:error "timed out")`,
once; a `:detect` function that signals matches nothing): `drgnx-platform-monitors`,
`drgnx-platform-frame-monitor`, `drgnx-platform-move-frame` (a command's path, 2 s), `drgnx-platform-place-frame`
(restoring, 5 s) and `drgnx-platform-can-move` -> `t` or `(REASON . FIX)`, e.g. GNOME: "GNOME does not let apps
move their windows", fix "press Super+Shift+→ or Super+Shift+←".

**Built in:** `x11` and `ns` (frame positions: the move keeps the frame's `fullscreen` value, clears it, sets
`left`/`top` to the target's workarea origin and re-applies it; a negative coordinate is written `(+ N)`, because a
plain negative integer counts from the right or bottom edge. macOS native fullscreen, a Space of its own, is for the
macOS tier to check), `gnome` (explains; the doctor asks Mutter's
`DisplayConfig` for the monitors, within 1 s), `other-wayland` (names the compositor, tells the user to use its
own key), `tty` and `none`. `sway`, `hyprland`, `niri`, `kwin` and `i3` are declared (detection, title, tool,
version command); their monitor and move functions arrive with their milestone tasks.

**sway and i3** share one implementation over `swaymsg` / `i3-msg` (section "sway and i3" of
`drgnx-platform.el`). Monitors come from `-t get_outputs` (active outputs only; the output `name` is what the move
command takes, and the monitor is matched to Emacs' by geometry). Moving is limited to Emacs' own window while
it has focus: `-t get_tree`, the focused window must be this process (sway: `pid`; i3, whose tree has no pid: the
`window` equal to the frame's `outer-window-id`) and the frame must have focus (`frame-focus-state`), else
`(:error "drgnx moves only its own window while it has focus: ...")`; then `[con_id=N] move container to output
NAME` (i3: `[id=XID]`) and `[…] focus` (the move does not carry focus), plus `fullscreen enable` for a fullscreen
window (`fullscreen enable global` for a global one). An output name with anything but letters, digits and `_.:-`
is double-quoted, so it stays one argument. If the move worked but the follow-up did not, the error says so ("the
window was moved but focus was not restored"); the callback has no success-with-warning. Restoring (`:place`) cannot rely on focus: the frame's `title` parameter is set to `drgnx [placing PID-N]`,
the tree is read at 0.1, 0.3, 0.7, 1.5 and 3 s (then every second) until a window with this pid and title shows
(i3: the window with the frame's X id; no title), the window is moved without taking focus, and the title is
put back whatever happens. All calls of one operation share its deadline (the second call gets what is left), so
the core's watchdog never fires first. Messages: "sway: swaymsg is not installed, so drgnx cannot move windows",
"sway did not answer within 2 s; the window was not moved", or sway's own `error` text.

**Hyprland and niri** (status `reported`: written from the sources and documented replies, not yet run on the real
compositor). Monitors come from `hyprctl -j monitors` (mode size divided by the scale, so the geometry is the
logical one Emacs sees) and `niri msg --json outputs`. A command move acts on the focused window only when its pid
is Emacs' and the frame has focus (`frame-focus-state`); otherwise `(:error "drgnx moves only its own window while
it has focus: ...")`. A restore sets the frame's `title` to `drgnx [placing PID-N]`, looks the window up by Emacs'
pid and that title at 0.1, 0.3, 0.7, 1.5 and 3 s, moves it without taking focus and puts the title back in every
case. All calls of one move share the operation's single deadline, so the watchdog margin is not raised. Hyprland
0.56 has two config types and `hyprctl dispatch` differs: a Lua config takes
`hl.dsp.window.move({ window = "address:0x…", monitor = "NAME", follow = … })`; a hyprlang config takes
`focuswindow address:0x…` and `movewindow mon:NAME [silent]` (and the focus is given back after a silent one). The
Lua form is tried first; the answer "Invalid dispatcher" marks a hyprlang instance, remembered per
`HYPRLAND_INSTANCE_SIGNATURE`. niri answers an unknown output with exit 0 and no effect, so the output is looked up
first and an unknown one is an error; the move is `niri msg action move-window-to-monitor --id ID OUTPUT`. (niri warps the
cursor to the target output on a restore too; that cannot be turned off). A hyprlang config splits a dispatcher's
arguments at spaces and commas, so a monitor name with whitespace, `,` or `;` is refused there; if the silent move fails after
the window was focused, the window that had the focus gets it back (best effort, a call of its own).

**KWin** (Plasma 6, status `reported`) has no tool, so the adapter loads a JavaScript file into KWin through its
scripting D-Bus API (`org.kde.KWin` `/Scripting` `loadScript`, then `run` on `/Scripting/Script<id>`) and the script
answers with `callDBus` to a `Reply(s)` method Emacs registers for the length of the call. Only Emacs' own
`dbus.el` is used (no `qdbus`), and only `dbus-call-method-asynchronously` with the call's deadline as `:timeout`,
so restore may use it. The method lives under Emacs' unique bus name at an object path of its own per call:
`dbus-register-service` and `dbus-unregister-service` wait for the bus (RequestName, ReleaseName) and a well-known
name would make two calls share a reply. The script, the object and the temporary file (mode 0600) are removed on
success, error and deadline alike. `:monitors` lists `workspace.screens`; `:move` (the command) moves the active
window and only if it is Emacs' (by pid); `:place` (restore) finds Emacs' window by pid and the frame's title (else
the only normal window of that pid). Without D-Bus support or a session bus, `:can-move` says so with a fix. It
has no `:frame-monitor` yet, so the monitor a frame is on is unknown there. Not run on a real Plasma session.

**Another compositor** (river, Wayfire, labwc, Cosmic, ...): call `drgnx-platform-define-adapter` from your
config. A new name goes before `x11` (so an adapter for an X window manager such as bspwm, awesome or xmonad
wins over plain X) and before the catch-alls `tty`, `other-wayland` and `none`; its `:detect` is tried after the
built-in compositors. Defining an existing name replaces only the keys you give.

```elisp
(drgnx-platform-define-adapter
 'labwc :title "labwc" :status 'reported
 :detect (lambda (env wsys) (and (memq wsys '(pgtk x)) (funcall env "LABWC_PID") t))
 :monitors (lambda (ctx callback)          ; CTX: (:frame :env :wm :timeout)
             (drgnx-platform-ctx-call ctx '("wlr-randr" "--json")
                                      (lambda (status out)
                                        (funcall callback (if (eq status 'ok) (my-parse out) (list :error out))))))
 :move (lambda (ctx monitor callback) ...))  ; CALLBACK: `ok' or (:error MESSAGE)
```

Keys: `:detect` (fn ENV WINDOW-SYSTEM), `:title`, `:tool` (program or nil), `:version` (argv or nil), `:status`
(`verified` = tested against the real thing, `reported` = from documentation), `:monitors` and `:frame-monitor`
(fn CTX CALLBACK), `:move` and `:place` (fn CTX MONITOR CALLBACK; `:place` defaults to `:move`), `:can-move`
(fn CTX -> `t` or `(REASON . FIX)`), `:doctor` (fn ENV -> plist `:monitors`, `:answers`; synchronous).

Tests use `test/fixtures/wm/fake-wm.sh`, linked as `swaymsg`, `i3-msg`, `hyprctl` and `niri` into a temp bin: it logs
its arguments, prints the recorded reply a regexp picks (`DRGNX_FAKE_WM_MAP`) and can sleep or fail.

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.
