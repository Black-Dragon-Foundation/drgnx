# The drgnx harness

The harness lets people and agents run drgnx (or any Emacs configuration) in an **isolated, invisible GUI
Emacs session**, see it, drive it and measure it — without ever touching the Emacs you are working in. It is
how every drgnx UI change is developed and verified (see [roadmap.md](roadmap.md), "Test & control harness",
and [ADR 0004](decisions/0004-headless-ui-harness.md)).

## Test tiers

| Command | What runs | Where |
|---|---|---|
| `bin/drgnx test` | ERT suites in `test/unit/` (batch Emacs) | the host |
| `bin/drgnx test --container` | the batch tier in a `fedora:45` container (Emacs 31.1, drgnx's baseline) | podman, docker or nerdctl |
| `bin/drgnx test --container --ui` | the GUI tier in a container (mutter renders without a GPU) | podman, docker or nerdctl |
| `bin/drgnx test --ui` | GUI ERT suites in `test/ui/` inside a headless session, then live ERT suites in `test/live/` (batch Emacs starting real sessions) | the host (needs mutter) |

`harness/run-ert.el` runs a suite and writes a JSON summary
(`{"total","passed","failed","failures":[{"name","condition"}]}`) to `$DRGNX_TEST_RESULTS` when set; the
summary is the source of truth for GUI runs, whose exit status is only pass/fail.

A GUI run's ERT suite executes inside the session (`DRGNX_UI_TEST` names the suite directory), writes its
summary to `DRGNX_UI_RESULTS` and exits. mutter turns any nonzero Emacs exit code into `1`, so the runner
trusts the summary, not the code. The run is killed (whole process group) after `DRGNX_UI_TEST_TIMEOUT`
seconds (default 110) and never leaves mutter, dbus or Emacs processes behind.

## Sessions

A session is GUI Emacs (pgtk) under `mutter --headless` inside its own `dbus-run-session`, with a virtual
monitor (default 1600×900) and a Wayland display named after the session. Nothing is shown on your screen
and nothing talks to your own Emacs.

**Run directory** (`$XDG_STATE_HOME/drgnx/ui/<name>/`, override with `DRGNX_UI_STATE`):

```
session.json   name, socket, size, config
init/          generated early-init.el + init.el (the session's user-emacs-directory)
out/           screenshots in progress
ready.json     written once the frame is mapped: pid, socket, emacs version, init_error, server_error
```

The **server socket** lives in `$XDG_RUNTIME_DIR/drgnx-ui/<hash of the state root>/<name>/<name>`, every
directory mode 0700 (`server-start` silently refuses anything else). It is not under the state root because
Unix socket paths are limited to ~108 bytes; the hash keeps two state roots (say, two checkouts) apart.

**Isolation**, set up by `harness/init/prelude.el` before any configuration runs:

- Everything the session writes lands in its run directory (`user-emacs-directory`, eln cache). An external
  configuration is only read: code directories (`lisp/`, `extras/`, `site-lisp/`, `tree-sitter/`, `snippets/`,
  `themes/`) are linked, `custom.el` is copied, packages load from its `elpa/`; history, recentf, places and
  other state files are not brought in.
- No network and no installs: `url-retrieve*`, `package-install`/`-refresh-contents`/`-vc-install`/`-upgrade*`
  and `treesit-install-language-grammar` signal an error.
- No secrets: the environment is rebuilt from an allowlist (`HOME USER LOGNAME LANG LC_ALL PATH
  XDG_RUNTIME_DIR GRYPHN_EMACS_DIR` + `DRGNX_UI_*`), `auth-sources` is nil.
- Deterministic look: no startup screen, no blinking cursor, no bell, no dialog boxes.
- Safety: treemacs drag-to-move is off.
- Its own server: `server-name` = the session name, `server-socket-dir` = the session's socket directory,
  set before the configuration runs so any `server-start` in it uses the session's socket. If the server
  cannot start, `ready.json` says why (`server_error`) and `drgnx ui start` fails at once.

**Configurations:** `minimal` (stock Emacs, menu/tool/scroll bars off — `harness/init/minimal.el`), `gryphn`
(the gryphn layer's config directory, `$DRGNX_GRYPHN_CONFIG` or `~/.config/emacs`), or any directory with an
`init.el`. Emacs is launched with `--init-directory` and without `-Q` (which would skip the init file).
The Emacs binary is `$DRGNX_EMACS`, else `emacs-pgtk`, else `emacs`.

## Driving a session

Input is synthetic but goes through Emacs' normal command loop: `harness/drgnx-uitest.el` queues events and
delivers **one per 40 ms timer tick** (`drgnx-uitest-tick`) onto `unread-command-events`. Redisplay runs
between events exactly as it does for a person typing or clicking; dumping a whole sequence at once would
skip redisplay and hide the very jank we want to see.

- **Pixels:** clicks take root-frame pixel coordinates — the same pixels as a screenshot (top-left = 0,0).
  `(posn-at-x-y x y root-frame)` turns them into the click position.
- **Targets:** instead of pixels, name a window by its buffer name or major mode (e.g. `treemacs-mode`) and
  some visible text; the click lands in the middle of the first character of the first visible occurrence.
  A buffer that is not shown, or text that is not visible, is an error — never a click somewhere else.
- **Clicks** are `down-mouse-N` + `mouse-N`; `count 2` adds `double-down-mouse-N` + `double-mouse-N`;
  `hold` waits between press and release (e.g. to reproduce an accidental drag).
- **Keys** use `kbd` syntax (`"C-x b"`, `"M-x"`, `"RET"`); typed text is one event per character.
- **Settled** = no queued or unread input and nothing visibly changed for 300 ms (`drgnx-uitest-quiet`).

In GUI ERT tests, `(drgnx-uitest-run EVENTS)` delivers the events and waits until settled: it runs a nested
command loop (`recursive-edit`), so the events execute as real commands while the test waits.

## Jank report

Every input action is measured. Between `measure-begin` and `measure-end` the recorder polls a signature of
every root-frame window at each tick — buffer, `window-start`, point, pixel edges, header-line and mode-line
heights — plus the minibuffer height, and also records `window-scroll-functions` calls, redisplays and GC.
The report:

| Field | Meaning |
|---|---|
| `settle_ms` | time from the last delivered input to the last visible change (0 if nothing changed after it) |
| `layout_changes` | window edge changes, windows created or deleted |
| `collateral_moves` / `collateral` | windows that changed although the input was not aimed at them (targets = the window clicked, the selected window before and after) — invariant I1 wants 0 |
| `oscillations` | a window returning to an earlier signature within one measurement (A→B→A: snap-backs) |
| `chrome_changes` | header-line or mode-line height changes (I3) |
| `echo_changes` | minibuffer/echo-area height changes (I4) |
| `scrolls`, `redisplays` | `window-scroll-functions` calls, window redisplays |
| `gc_count`, `gc_ms` | garbage collections during the measurement |
| `guard_violations`, `guard` | window-moving calls made from timers (see Guard) |
| `settled` | false if the session did not settle before the timeout |

Start measurements from a quiet state: a leftover echo-area message that disappears on the first keystroke
shrinks the echo area and resizes every window — the report rightly counts that as layout and collateral.

## Guard

`harness/drgnx-jank-guard.el` is on in every session. It records (never blocks) calls to `select-window`,
`set-window-start`, `set-window-point`, `recenter`, `split-window` and `delete-window` made **from a timer** —
the pattern behind "the layout jumps on its own" (invariant I9). Timer context is detected by wrapping
`timer-event-handler`; commands executed by a command loop nested inside a timer (a minibuffer opened from a
timer, a test's `drgnx-uitest-run`) are not timer code, so `command-execute` clears the flag.
`select-window` with NORECORD (what `with-selected-window` does) is a temporary selection and is not
recorded. Each entry names the function, the window and the timer's function. Hook context (e.g.
`buffer-list-update-hook`) is covered by the workbench change bus in M3.

## Capture

`(drgnx-uitest-capture DIR)` exports the root frame with `x-export-frames` (~30 ms for 1600×900) and each
visible child frame (posframes, popups) separately — `x-export-frames` cannot put several frames in one PNG —
together with each child's parent-relative `native-edges` offset. The CLI/MCP layer composites them with
ImageMagick (`magick root.png child.png -geometry +X+Y -composite out.png`), which is pixel-exact. Capture
writes with `write-region … 'silent`, so it never puts a message into the screenshot's echo area. The PNG
covers Emacs' drawing area only (no GTK menu or tool bar).

## Emacs-side API

Functions the CLI and MCP server call through `emacsclient -s <session socket> -e`; each returns JSON text:

| Function | Returns |
|---|---|
| `(drgnx-uitest-api-state)` | `frame {width,height}`, `windows [{id,buffer,mode,edges,body,start,point,line,header_h,mode_line_h,selected}]`, `minibuffer_h`, `children [[l,t,r,b]]`, `busy` |
| `(drgnx-uitest-api-screenshot DIR)` | `root`, `width`, `height`, `children [{path,x,y}]`, `windows` |
| `(drgnx-uitest-api-click X Y &optional BUTTON COUNT HOLD-MS)` | `x`, `y`, `window` (id, or null when the pixel is on no window) |
| `(drgnx-uitest-api-click-target BUFFER TEXT &optional BUTTON COUNT HOLD-MS)` | same; errors if not on screen |
| `(drgnx-uitest-api-keys KEYS)`, `(drgnx-uitest-api-type TEXT)` | `queued` |
| `(drgnx-uitest-api-status &optional QUIET-MS)` | `busy`, `settled` |
| `(drgnx-uitest-api-measure-begin)` / `(drgnx-uitest-api-measure-end)` | `ok` / the jank report |

Window ids (`w1`, `w2`, …; `mini` for the minibuffer) are stable for a window's lifetime. Input functions
only queue; callers poll `status` until settled.

## CLI

`bin/drgnx ui COMMAND` runs the controller (`harness/drgnx-ui.el`) in batch Emacs — no other runtime needed.
Output is JSON on stdout; errors go to stderr with exit status 1.

```sh
bin/drgnx ui start [--config minimal|gryphn|DIR] [--size 1600x900]   # → {"name":"drgnx-ui-1", …, "ready":{…}}
bin/drgnx ui ls                                  # sessions of this state root
bin/drgnx ui state drgnx-ui-1                    # frame, windows, child frames
bin/drgnx ui shot drgnx-ui-1 [out.png]           # screenshot, child frames composited
bin/drgnx ui click drgnx-ui-1 300 200 [--button 1] [--count 2] [--hold-ms 300]
bin/drgnx ui click drgnx-ui-1 --buffer treemacs-mode --text README.md
bin/drgnx ui keys drgnx-ui-1 "C-x b"             # kbd syntax
bin/drgnx ui type drgnx-ui-1 "hello"
bin/drgnx ui measure drgnx-ui-1 '[{"keys":"C-x 2"},{"x":10,"y":10}]'
bin/drgnx ui stop drgnx-ui-1 | bin/drgnx ui reap
```

Input commands wait until the session settles and print the jank report. `bin/drgnx` passes arguments after
`--`, so options Emacs itself knows (`--title`, `-nw`, …) cannot be swallowed by Emacs.

## Ownership and cleanup

Only sessions this harness created can be addressed. A name must match `drgnx-ui-N`, its run directory must
exist under the state root (`$DRGNX_UI_STATE`, default `$XDG_STATE_HOME/drgnx/ui`), and its socket must be the
one the harness assigned. Anything else — `server`, another Emacs's socket path, `../…` — is refused, so the
user's own Emacs can never be driven. `emacsclient` is always called with `-a false`, so a missing socket can
never make it start a new Emacs daemon (as `ALTERNATE_EDITOR=""` would).

`stop` ends the unit and removes the run and socket directories. `reap` does that for every session of the
current state root — run directories, plus live units whose command line points into it — and leaves sessions
of other state roots alone. Units also end on their own after 30 minutes (`RuntimeMaxSec=1800`) and are
capped at 3 GB (`MemoryMax`). A failed `drgnx test --ui` run keeps its run directory (with `session.log`) for
debugging.

## Containers

`harness/drgnx-env.el` tells where drgnx runs; `bin/drgnx doctor` prints it:

```
environment              host            # or podman, docker, kubernetes, containerd, lxc, …
container runtime        podman          # for --container test runs
session launcher         systemd         # or detached (process group, no systemd unit)
```

- **Inside a container** (detected from `KUBERNETES_SERVICE_HOST`, `/run/.containerenv`, `/.dockerenv`,
  `$container`, or `/proc/1/cgroup` mentioning kubepods/libpod/docker/containerd) there is usually no systemd
  user session, so sessions are launched **detached**: `setsid` makes a new process group whose id is kept in
  `RUN/pgid`; `stop` sends it TERM, then KILL after 2 s. Liveness is `kill -0 -PGID`. On a host without a
  systemd user session the same happens. `DRGNX_UI_LAUNCHER=systemd|detached` overrides the choice.
- Where `XDG_RUNTIME_DIR` is unset (typical in containers) sessions use a private `/tmp/drgnx-ui-<uid>`
  (mode 0700) for their Wayland displays and sockets.
- **Container runtime on the host:** `--container` uses `$DRGNX_CONTAINER` if set, else the first of
  `podman`, `docker`, `nerdctl` on `PATH` (Rancher Desktop provides `docker` in moby mode and `nerdctl` in
  containerd mode). `--podman` is short for `DRGNX_CONTAINER=podman … --container`.
- **GUI tier in a container:** `test/container/Containerfile.gui` (fedora:45 + `emacs-pgtk mutter dbus-daemon
  mesa-dri-drivers ImageMagick`, ~1.8 GB). mutter falls back to a surfaceless software renderer, so no GPU is
  needed. The container needs `--security-opt seccomp=unconfined --security-opt label=disable`: GTK loads icons
  through glycin, whose `bwrap` sandbox cannot create namespaces under the default policy, and Emacs aborts.
