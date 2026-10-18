# The drgnx harness

The harness lets people and agents run drgnx (or any Emacs configuration) in an **isolated, invisible GUI
Emacs session**, see it, drive it and measure it — without ever touching the Emacs you are working in. It is
how every drgnx UI change is developed and verified.

## Test tiers

| Command | What runs | Where |
|---|---|---|
| `bin/drgnx test` | ERT suites in `test/unit/` (batch Emacs, SIGPIPE ignored — as the hub runs: tests serve one in-process, and a write to a client that left must fail as an error, not kill the run) | the host |
| `bin/drgnx test --scenario [--config C]` | behaviour scenarios in `test/scenario/` inside a session of configuration C (default `drgnx`; `gryphn` is skipped where that config is absent) | the host (needs mutter) |
| `bin/drgnx test --container` | the batch tier in a `fedora:45` container (Emacs 31.1, drgnx's baseline); `DRGNX_TEST_IMAGE` / `DRGNX_TEST_GUI_IMAGE` use a prebuilt image ([ci.md](ci.md)) | podman, docker or nerdctl |
| `bin/drgnx test --container --ui` | the GUI tier in a container (mutter renders without a GPU) | podman, docker or nerdctl |
| `bin/drgnx test --tty` / `--container --tty [--fedora 44 or 45]` | the terminal tier in `test/tty/`: drgnx in Emacs sessions inside private tmux servers — see [Terminal tier](#terminal-tier) | the host (needs tmux); a container |
| `bin/drgnx test --ui` | GUI ERT suites in `test/ui/` inside a headless session, then live ERT suites in `test/live/` (batch Emacs starting real sessions) | the host (needs mutter) |
| `bin/drgnx test --bench` | the workbench timed against treemacs and ibuffer in a GUI session on a 25k-file project — see [workbench.md](../guide/workbench.md#performance) | the host (needs mutter); treemacs from `$DRGNX_BENCH_ELPA` |
| `bin/drgnx test --perf` / `--soak [MIN]` | input latency, frames, GC, startup and memory against budgets; the memory soak — see [perf.md](perf.md) | the host (needs mutter) |
| `bin/drgnx test --install [NAME…]` | `install.sh` end to end in fresh distribution containers: source builds on Fedora 44, Debian 13, Ubuntu 26.04, packages on Fedora 45 and Arch; then the doctor, a second run (no-op), on Fedora packages emacs-nw installed beside emacs-pgtk (`emacs` must stay the pgtk build) and `--dry-run` (no changes) — see [install.md](../guide/install.md) | podman, docker or nerdctl; slow, network |

`bin/drgnx check` runs the build and all of these host tiers in one go, in parallel where that is safe — see
[check.md](check.md).

`harness/run-ert.el` runs a suite — a directory, or test files (a shard) — and writes a JSON summary
(`{"total","passed","failed","failures":[{"name","condition"}],"tests":[{"name","result","file","seconds"}]}`) to
`$DRGNX_TEST_RESULTS` when set; the summary is the source of truth for GUI runs, whose exit status is only
pass/fail. `$DRGNX_TEST_SELECTOR` (an ERT selector, e.g. `(tag :timing)`) picks the tests a run takes.

### One Emacs per test file

`bin/drgnx test` and each unit shard of `bin/drgnx check` run every test file in a batch Emacs of its own, as Emacs's
own `make check` does: a hook, timer, advice, feature or variable a file leaves behind never reaches the next file,
so a test cannot pass or fail because of the file that happened to run before it. Within a file, ERT still runs the
tests in name order in one Emacs. Each file's Emacs gets the runner's `load-path` and environment — the temp HOME
and XDG directories, the dead session bus, `$DRGNX_TEST_SELECTOR` (applied inside each file), the trampoline
directory below — and a temp directory (and HOME) of its own, removed when it ends: inside `$DRGNX_RUN_TMP` under
`bin/drgnx test`, beside the runner's own under `check`, never deeper than a single Emacs's would be (a Unix socket
path has ~104 bytes). It writes its own summary; the runner merges them into one, in the same shape, plus `"files"`
(`[{"file","exit","seconds"}]`). A file whose Emacs dies (a test calls `kill-emacs`), exits non-zero without a failed
test, or runs longer than `$DRGNX_TEST_FILE_TIMEOUT` seconds (default 300; it gets TERM, 5 s, then KILL, with what it
started) is a failure named `file NAME-test.el`, and the other files still run. Files run one after another;
`$DRGNX_TEST_JOBS` runs that many at once (their output is then printed whole as each ends). Interrupting the run ends
the files' Emacsen too.

With a name selector (a string: a regexp on test names), only the files that define a matching test (`(ert-deftest
NAME`) get an Emacs, so a narrow run stays quick; any other selector (a tag, `(not …)`) runs every file.

`bin/drgnx test --one-process` (or `DRGNX_TEST_ONE_PROCESS=1`) runs every file in one Emacs instead: for hunting a
leak from one file into another (run the files in question this way; a test that fails only here depends on what an
earlier file left). `bin/drgnx check`'s `unit-timing` job uses it too (16 tests across all files). The runner unsets
the variable for the tests themselves, so a test that runs the runner gets one Emacs per file unless it sets it. The
GUI and live tiers and the tests that start an Emacs of their own keep their own runners.

### Native trampolines

A test that `cl-letf`s a primitive (`buffer-list`, `message`, …) makes Emacs compile a native trampoline, which it
writes to the first writable directory of `native-comp-eln-load-path` — by default the user's
`~/.config/emacs/eln-cache`, fixed when Emacs started, before the runner swaps HOME. The runner puts a directory of
drgnx's first in that list and drops the user's own eln-cache from it (so a test neither writes nor reads there), and
exports it as `$DRGNX_TEST_ELN_DIR`: every Emacs of the run (each file's, a test that runs the runner, `check`'s shards)
uses the same one, so each trampoline is compiled once. `native-comp-enable-subr-trampolines` set to a directory would not do:
Emacs looks for an existing trampoline only along `native-comp-eln-load-path`. The directory is
`$XDG_CACHE_HOME/drgnx/test-eln/EMACS-VERSION/` (`~/.cache/…`, read before HOME is swapped), kept between runs: a full
unit run compiles ~60 trampolines at ~0.2 s each, which would cost every run 12–15 s. It is drgnx's own and holds only
trampolines (~1 MB); delete it at any time. When it cannot be made, the run's temp directory (`eln/`) is used.
`$DRGNX_TEST_ELN_DIR` set from outside (an absolute path) chooses another.

`/tmp` is RAM on many machines, so a test run leaves nothing there. `bin/drgnx test` (every tier) and `bin/drgnx check`
run in a `$TMPDIR` of their own — a fresh `mktemp -d` (`drgnx-run.XXXXXX`, made absolute) below the caller's `$TMPDIR` or
`/tmp`, so `temporary-file-directory` and the native compiler's libgccjit files land in it too — and remove it on every
exit: the end, a failure, Ctrl-C, `TERM` or `HUP`. The command runs in a process group of its own that the shell's trap
stops (TERM; the command then has `$DRGNX_RUN_GRACE` seconds, default 30, to end and stop what it started outside the
group — check's jobs, the GUI tiers' sessions — then KILL; a second signal does not cut it short) before it deletes the
directory. That group is a background one: a tier that read from the terminal would be stopped (none does). `bin/drgnx
test` tells the batch runner the directory in `$DRGNX_RUN_TMP`; the runner uses it as the suite's temp home but never
deletes it (only a real directory of that name owned by the user is used: empty, a symlink, another name or owner is ignored),
and makes and deletes a `drgnx-unit…` directory of its own when run standalone, also from `kill-emacs-hook`. `check`
leaves `$DRGNX_RUN_TMP` unset: each shard makes its own directory in the shared `$TMPDIR`. A harness session's `TMPDIR`
is `tmp/` in its run dir (so, without `$XDG_RUNTIME_DIR`, the session sockets' fallback directory is inside it too).
`$DRGNX_TEST_DIR` runs a smaller suite than `test/unit` (the tests of this cleanup use it). Tests still delete what they
make (`unwind-protect` and `delete-directory … t`); the directory is the net under them.

The batch unit tier never reaches the user's desktop. `bin/drgnx test` and the unit shards of `bin/drgnx check` start
Emacs with `DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-unit-test` (dbus.el connects with the process's own
environment, which a Lisp `setenv` does not reach, so a test that loads it would otherwise talk to the real session bus)
and without `DISPLAY`, `WAYLAND_DISPLAY`, `SWAYSOCK`, `I3SOCK`, `HYPRLAND_INSTANCE_SIGNATURE` and `NIRI_SOCKET`; the runner
binds the same inside Emacs and gives `XDG_RUNTIME_DIR` a private directory (mode 700) in the run's temp directory. A test
that needs a bus, a display or a runtime directory sets its own with `process-environment`. The GUI tiers run their own
session and are not changed. `bin/drgnx test --container` passes `$DRGNX_TEST_SELECTOR` into the container. A test file that
does not read or load (an unbalanced paren) fails the run: the runner prints the file and the error and counts it as a
failure, so a broken file cannot look green.

A GUI run's ERT suite executes inside the session (`DRGNX_UI_TEST` names the suite directory), writes its
summary to `DRGNX_UI_RESULTS` and exits. mutter turns any nonzero Emacs exit code into `1`, so the runner
trusts the summary, not the code. The run is killed (whole process group) after `DRGNX_UI_TEST_TIMEOUT`
seconds (default 110; `bin/drgnx check` gives its `ui` job 300) and never leaves mutter, dbus or Emacs processes behind.

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

- Everything the session writes lands in its run directory (`user-emacs-directory`), or in the state root's
  shared eln cache (`ROOT/eln-cache`: native code and trampolines compiled once for every session; starting a
  session and `reap` delete `.eln` files unused — neither read nor written — for 30 days, and directories left
  empty, so the cache of an Emacs no longer run goes too). An external
  configuration is only read: code directories (`lisp/`, `extras/`, `site-lisp/`, `tree-sitter/`, `snippets/`,
  `themes/`) are linked, `custom.el` is copied, packages load from its `elpa/`; history, recentf, places and
  other state files are not brought in.
- No network and no installs: `url-retrieve*`, `package-install`/`-refresh-contents`/`-vc-install`/`-upgrade*`
  and `treesit-install-language-grammar` signal an error.
- No secrets: the environment is rebuilt from an allowlist (`HOME USER LOGNAME LANG LC_ALL PATH
  XDG_RUNTIME_DIR GRYPHN_EMACS_DIR DRGNX_UITEST_SETTLE_SCALE` + `DRGNX_UI_*`), `auth-sources` is nil.
- Your drgnx files are never touched: a session gets its own `DRGNX_CONFIG_DIR` (`RUN/drgnx-config`) and
  `XDG_STATE_HOME` (`RUN/state`), so it neither reads `~/.config/drgnx` (keys.eld, …) nor writes
  `~/.local/state` (the key report). `XDG_CACHE_HOME` is kept: font and shader caches would be rebuilt every start.
- No language servers: `DRGNX_NO_LANGUAGE_SERVERS=1`, so a scenario's fixture projects do not each start one (a run
  once had 12 pyrights); a test that needs a server sets it to "" in its session.
- Deterministic look: no startup screen, no blinking cursor, no bell, no dialog boxes.
- Safety: treemacs drag-to-move is off.
- Its own server, started (with the harness agent) by the generated `init.el` *before* the configuration's
  `init.el`, on `server-name` = the session name and `server-socket-dir` = the session's socket directory. If
  the server cannot start, `ready.json` says why (`server_error`) and `drgnx ui start` fails at once. If the
  configuration moves the server elsewhere (another name or directory — it could even take the name of your
  own Emacs server), start stops the session and fails: the harness only drives sessions it owns.
- **A configuration that asks something during init** (a minibuffer prompt) does not block `start`: after 2 s
  without `ready.json`, start asks the session whether a prompt is active and, if so, returns at once with
  `ready: {init_running: true, prompt: "…"}`. The session stays up: take a screenshot, answer with
  `ui_type`/`ui_keys`, and init continues (`ready.json` appears when it finishes).

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
  An occurrence counts only if it is not invisible (folded) and a click at the computed pixel lands on it
  (same window, same position) — text cut off at the right edge of a truncated line is skipped. A buffer that
  is not shown, or text with no such occurrence, is an error — never a click somewhere else.
- **Clicks** are `down-mouse-N` + a release; `count 2` adds `double-down-mouse-N` + `double-mouse-N`;
  `hold` waits between press and release. The release is resolved when it is delivered, the way Emacs treats
  real input: if the buffer position under the pressed pixel changed meanwhile (the text moved under a held
  button), it becomes `drag-mouse-N` from the press, else `mouse-N` — which is how a click on a moving file tree
  can turn into a drag.
- **Keys** use `kbd` syntax (`"C-x b"`, `"M-x"`, `"RET"`); typed text is one event per character.
- **Settled** = no queued or unread input and nothing visibly changed for 300 ms (`drgnx-uitest-quiet`).

In GUI ERT tests, `(drgnx-uitest-run EVENTS)` delivers the events and waits until settled: it runs a nested
command loop (`recursive-edit`), so the events execute as real commands while the test waits. Its default timeout is 5 s times
`(drgnx-uitest-settle-scale)`: the 1-minute load average per CPU (at least 1, at most 8), so a loaded machine
settles slower without a failing test; `DRGNX_UITEST_SETTLE_SCALE=N` (reaches sessions through the allowlist) sets the factor, and an explicit
TIMEOUT argument is never scaled.

## Jank report

Every input action is measured. Between `measure-begin` and `measure-end` the recorder keeps a signature of
every root-frame window — buffer, `window-start`, point, pixel edges, header-line and mode-line heights,
selected — plus the minibuffer height, and also records `window-scroll-functions` calls, redisplays and GC.
It snapshots the signatures **just before and right after every command** (`pre-`/`post-command-hook`) and
**every timer** (advice on `timer-event-handler`), and polls once per tick, so each change is attributed to its
cause: the innermost command or timer running when it happened (`command:NAME`, `timer:FUNCTION` — a timer
that runs inside another timer's or a command's `sit-for` keeps its own changes), or `other` when neither ran
(process output — filters and sentinels are called from C and cannot be intercepted — or redisplay). A scroll
counts only when a window's start really changes. A timer that moves point with `goto-char` inside
`with-selected-window` (no window function called) is still caught and named.
The report:

| Field | Meaning |
|---|---|
| `settle_ms` | time from the last delivered input to the last visible change (0 if nothing changed after it) |
| `layout_changes` | window edge changes, windows created or deleted |
| `collateral_moves` / `collateral` | windows that changed although the input was not aimed at them (targets = the window clicked, the selected window when the measurement starts, and any window a command moved focus to — in any frame; a window only a timer focused is collateral) — invariant I1 wants 0 |
| `oscillations` | snap-backs: a change that returns one of a window's fields (point, start, buffer, edges, header/mode-line height) to an earlier value within the measurement, even if other fields changed meanwhile |
| `chrome_changes` | header-line or mode-line height changes (I3) |
| `echo_changes` | minibuffer/echo-area height changes (I4) |
| `scrolls`, `redisplays` | `window-scroll-functions` calls, window redisplays |
| `gc_count`, `gc_ms` | garbage collections during the measurement |
| `guard_violations`, `guard` | window-moving calls made from timers or window change hooks (see Guard) |
| `timer_moves` | window changes made by timers (any window) |
| `causes` | `[{cause, count}]` — every command and timer that changed something |
| `trace` | `[{t_ms, cause, window, fields, from, to}]` in order (≤ 50): what changed, when, and why |
| `settled` | false if the session did not settle before the timeout |

Reading a trace — one click on an Explorer folder in the gryphn layer:

```
+  14 ms  command:treemacs-leftclick-action   w3 (:point 36) → (:point 11)   the click selects the folder
+  44 ms  command:mouse-set-point             w3 (:point 11) → (:point 17)
+ 196 ms  timer:gryphn-workspace--on-change   w3 (:point 17) → (:point 36)   the follow snaps back
```

Start measurements from a quiet state: a leftover echo-area message that disappears on the first keystroke
shrinks the echo area and resizes every window — the report rightly counts that as layout and collateral.

## Daemon sessions and new frames

`drgnx ui start --daemon` (MCP `ui_start {daemon: true}`) runs Emacs as `--fg-daemon` under the session's
compositor: it is ready once its server is up, with no frame. `drgnx ui frame NAME` (MCP `ui_frame`) opens a
frame the way a user does — `emacsclient -c -n` with the session's Wayland display — and reports `exit`,
`output`, `client_ms` (until emacsclient returned), `visible_ms` (until the frame was mapped) and `hooks`: the
slowest of `make-frame` itself, each named function on the frame hooks (`after-make-frame-functions`,
`server-after-make-frame-hook`, …) and each hook's total run. Screenshots and state use the first visible
graphical frame; without one, capture fails with a clear message.

## The harness does not perturb the session

Code under test often hangs followers and debounces on change hooks — gryphn's Explorer follow is re-armed by
`first-change-hook` — and every `emacsclient -e` reply is printed through a temp buffer, whose first insertion
runs that hook. Without care, the harness's own polling (every 50 ms while waiting to settle) would keep
re-arming such debounces and the measurement would end before the follower ever ran: exactly the snap-back the
report should show would be hidden. So the session evaluates harness requests with
`inhibit-modification-hooks` bound to t (advice on `server-process-filter`, installed before the configuration
loads). Hooks a request installs are kept; temp buffers already skip the buffer-list and kill hooks. One
consequence: a buffer edited *through a harness request* gets no change hooks (no `after-change-functions`, so
no syntax-cache flush or jit-lock notice) — set up buffers through requests if you like, but drive the behaviour
under test with input events. A live test
installs a gryphn-shaped follower and checks that `measure` reports its snap-back.

## Guard

`harness/drgnx-jank-guard.el` is on in every session. It records (never blocks) calls to `select-window`,
`set-window-start`, `set-window-point`, `recenter`, `split-window` and `delete-window` made **from a timer or a window change hook**
— the pattern behind "the layout jumps on its own" (invariant I9). Timer context is detected by wrapping
`timer-event-handler`; commands executed by a command loop nested inside a timer (a minibuffer opened from a
timer, a test's `drgnx-uitest-run`) are not timer code, so `command-execute` clears the flag.
`select-window` with NORECORD (what `with-selected-window` does) is a temporary selection and is not
recorded. Each entry names the function, the window and the timer's function (or the hook and its member).
Hooks run from C, so the guard wraps the global members of `window-configuration-change-hook`,
`window-size-change-functions`, `window-selection-change-functions`, `window-buffer-change-functions` and
`window-state-change-functions` when it starts, wraps later `add-hook`s to them too, and makes `remove-hook`
find the wrapped member; turning the guard off puts the originals back. Other hooks
(`buffer-list-update-hook`) are not wrapped; the workbench change bus covers those.

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
Output is JSON on stdout; errors go to stderr with exit status 1. Arguments and output are UTF-8 whatever the
caller's locale (without a UTF-8 locale Emacs passes the arguments on as raw bytes; the CLI decodes them).

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

Input commands wait until the session settles and print the jank report. `click` takes X and Y as non-negative
integers (pixels) and fails on anything else, never clicking at 0,0 instead. In `measure`, each action is
delivered before the next one is resolved, so a click after `C-x 3` is aimed at the layout the keys produced. An
action that fails (a bad key, a target not on screen) ends the measurement — the session's recorder stops — and
the error names it: `action 2 (:keys "bad"): …`; later actions are not sent. `bin/drgnx` passes arguments after
`--`, so options Emacs itself knows (`--title`, `-nw`, …) cannot be swallowed by Emacs.

## Ownership and cleanup

Only sessions this harness created can be addressed. A name must match `drgnx-ui-N`, its run directory must
exist under the state root (`$DRGNX_UI_STATE`, default `$XDG_STATE_HOME/drgnx/ui`), and its socket must be the
one the harness assigned. Anything else — `server`, another Emacs's socket path, `../…` — is refused, so the
user's own Emacs can never be driven. `emacsclient` is always called with `-a false`, so a missing socket can
never make it start a new Emacs daemon (as `ALTERNATE_EDITOR=""` would).

`stop` first asks the session's Emacs to exit (`emacsclient --eval (kill-emacs)`, up to 5 s — its exit hooks run, so
the layout is saved as on a real exit), then ends the session and removes its run and socket directories and mutter's
Wayland socket. It only ever
stops what belongs to the current state root: a systemd unit only if its command line names this root's run
directory (unit names are global — another checkout may run `drgnx-ui-1` too), a detached process group only if
one of its members names the run directory (a stale `pgid` file may point at a reused id; ids 0 and 1 are never
signalled), and a Wayland display only when no process serves it any more. `reap` does that for every session of the
current state root — run directories, plus live units whose command line points into it — and leaves sessions
of other state roots alone. Units also end on their own after 30 minutes (`RuntimeMaxSec=1800`) and are
capped at 3 GB (`MemoryMax`). A detached session (no systemd: a container, or `DRGNX_UI_LAUNCHER=detached`) has the same time cap, from `timeout -k 10` (also `DRGNX_UI_MAX_RUNTIME`), and a 16 GB virtual-memory `ulimit` (generous on purpose: a GL stack maps a lot; it is a limit per process, not a cap on the whole group like `MemoryMax`). A systemd stop kills what is left after 10 s (`TimeoutStopSec`; systemd's default is 90). A test process that is ended (`DRGNX_UI_STOP_ON_EXIT`) first tells all its units to stop without waiting (`systemctl stop --no-block`), then stops each session in turn, so the stops overlap; one session takes 18 s at the very most (asking Emacs to exit: 8 s, then the unit: 10 s), within the 25 s `bin/drgnx check` gives an ended job. The slow exit seen under load (more than 45 s) was not reproduced on a quiet machine; this bounds it, it does not explain it. A failed `drgnx test --ui` or `--scenario` run keeps its run directory
(`drgnx-ui-test-PID-N`, with `session.log`) for debugging, for 7 days: `reap` and the next test run delete older
ones.

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
  `RUN/pgid`; `stop` sends it TERM, then KILL after 2 s. Liveness is `kill -0 -PGID`. A launch that fails stops
  its group at once, and `stop` treats a run directory with a `pgid` file but no recorded launcher (a start that
  failed before saving it) as detached. On a host without a
  systemd user session the same happens. `DRGNX_UI_LAUNCHER=systemd|detached` overrides the choice.
- Where `XDG_RUNTIME_DIR` is unset (typical in containers) sessions use a private `/tmp/drgnx-ui-<uid>`
  (mode 0700) for their Wayland displays and sockets. An existing one is used only if it is a directory (not a
  symlink) owned by the user with mode 0700; anything else is an error — `/tmp` is shared, and another user could
  have made the name first.
- **Container runtime on the host:** `--container` uses `$DRGNX_CONTAINER` if set, else the first of
  `podman`, `docker`, `nerdctl` on `PATH` (Rancher Desktop provides `docker` in moby mode and `nerdctl` in
  containerd mode). `--podman` is short for `DRGNX_CONTAINER=podman … --container`.
- **GUI tier in a container:** `test/container/Containerfile.gui` (fedora:45 + `emacs-pgtk mutter dbus-daemon
  mesa-dri-drivers ImageMagick`, ~1.8 GB). mutter falls back to a surfaceless software renderer, so no GPU is
  needed. The container needs `--security-opt seccomp=unconfined --security-opt label=disable`: GTK loads icons
  through glycin, whose `bwrap` sandbox cannot create namespaces under the default policy, and Emacs aborts.

## MCP server

`bin/drgnx ui mcp` serves the harness as MCP tools over stdio (`harness/drgnx-ui-mcp.el`, batch Emacs — no
other runtime). Register it with an agent, e.g. Claude Code:

```sh
claude mcp add -s user drgnx-ui -- /path/to/drgnx/bin/drgnx ui mcp
```

| Tool | Arguments | Returns |
|---|---|---|
| `ui_start` | `config` (minimal, gryphn, a directory), `size`, `daemon`, `monitors` (virtual monitors of that size, for multi-window tests) | the session (name, socket, ready) |
| `ui_frame` | `session` (a daemon session) | `{exit, output, client_ms, visible_ms, hooks}` |
| `ui_stop` | `session` | `{stopped}` |
| `ui_list` | — | sessions of the state root |
| `ui_state` | `session` | frame, windows, minibuffer, child frames, busy |
| `ui_screenshot` | `session`, `path`? | an image block (PNG, child frames composited) + path and window map |
| `ui_click` | `session`, `x`+`y` or `buffer`+`text`, `button`?, `count`?, `hold_ms`? | jank report |
| `ui_keys` | `session`, `keys` (kbd syntax) | jank report |
| `ui_type` | `session`, `text` (a newline is the Return key) | jank report |
| `ui_wait` | `session`, `quiet_ms`?, `timeout_ms`? | `{settled}` |
| `ui_measure` | `session`, `actions` (list of `{keys}`, `{type}`, `{x,y}`, `{buffer,text}`) | one jank report |
| `ui_diff` | `session` (diffs against the state the previous `ui_state`/`ui_diff` saw), or `a` and `b` | `changes`: `{window, field, old, new}` (also a field only one of the states has), windows `added`/`removed` |
| `ui_record` | `session`, `action` (`start` / `stop`) | `stop`: the jank report of everything between (input, timers, redisplays) |
| `ui_perf` | `session`, `workload`, `audit`? | a perf workload's numbers: input latency, GC, frames, redisplay ([perf.md](perf.md)) |

A typical agent loop: `ui_start` → `ui_screenshot` (look) → `ui_click`/`ui_keys` (act; read the jank report) →
`ui_screenshot` (check) → `ui_stop`. Every tool resolves its session through the ownership rules above, so a
call naming `server` or another Emacs's socket returns an error starting with `refused`. Failures are tool
results with `isError`, never a crashed server (a reply that cannot be written as JSON becomes a JSON-RPC error
-32603 for its request). `harness/drgnx-ui-mcp.el` also has a small client
(`drgnx-ui-mcp-client-start/-request/-tool/-stop`) used by the tests and handy for scripts.

## Known limits

- Changes made by process filters and sentinels (e.g. asynchronous git status in a file tree) are attributed to
  `other`: Emacs calls those from C, so they cannot be wrapped. Commands and timers are always named.
- The guard sees window moves from timers and from the window change hooks above, not from other hooks
  (`buffer-list-update-hook`, …) — the workbench change bus covers those. A hook member added buffer-locally is not wrapped.
- Input is synthetic (no real pointer hover or OS-level drag yet); clicks target the root frame.
- Wayland via mutter only; X11 (Xvfb) and tiling WMs (sway headless) come later. macOS needs a different capture
  backend (`x-export-frames` exists only on Cairo builds).
- A GUI run's exit status is only pass/fail (mutter); `results.json` has the details.

## Scenario tier

Scenarios are ERT tests named `drgnx-scenario/…` in `test/scenario/` that state how the UI should behave (VS
Code's behaviour is the reference) and run inside a session of the configuration under test. They use only the
harness API and a per-configuration **driver** (`test/scenario/drivers/<config>.el`: how to open the Explorer,
open a file, find a row, …); a configuration without a driver skips them.

**Known reds.** `test/scenario/known-red.eld` lists, per configuration, scenarios expected to fail
(`((gryphn drgnx-scenario/explorer-click-stays …))`). Such a scenario counts as expected only if it fails an
assertion made with `drgnx-scenario-check`, which carries the jank report's trace — so every known red explains
itself. A known red that *errors* (missing fixture, broken driver, timeout) or unexpectedly *passes* makes the
tier fail. Output:

```
scenarios on gryphn:
  red (known)  drgnx-scenario/explorer-click-stays: a single click on a folder must keep the selection on it; …
                 +13 ms  command:treemacs-leftclick-action  w9 point 55 → 30
                 +44 ms  command:mouse-set-point  w9 point 30 → 36
                 +196 ms  timer:gryphn-workspace--on-change  w9 point 36 → 55
  green        drgnx-scenario/explorer-follow-override
  green        drgnx-scenario/frame-from-daemon-fast (median 431 ms <= budget 500 ms …)
results: …/drgnx/ui/scenarios/gryphn.json
scenario tier: as expected in 64.9s
```

What can never pass as a known red: a measurement that did not settle within its timeout (an error that lists
the last changes), a failed setup precondition (`drgnx-scenario-require`), an error of any kind, a failure of a
bare `should` (only `drgnx-scenario-check` failures carry an explanation and trace), and for the frame scenario
a frame that never appeared. Scenarios wait for 1 s of quiet (`drgnx-scenario-quiet`): configurations under test
may follow up to ~0.7 s later. The last results of each configuration are kept in
`$XDG_STATE_HOME/drgnx/ui/scenarios/<config>.json`. A configuration directory that does not exist fails the tier
(exit 2); only a missing `gryphn` configuration is skipped.

A suite with a `frames.eld` (`((budget-ms . 500) (frames . 3))`) also gets `drgnx-scenario/frame-from-daemon-fast`,
run by the controller after the in-session suite: frames are opened in a daemon session of the configuration with
`emacsclient -c`, and the median time-to-visible must stay within the budget (it can be a known red like any
other scenario; when red, the first frame's slowest hooks are listed).

Helpers (`harness/drgnx-scenario.el`): `drgnx-scenario-check OK EXPLANATION REPORT`,
`drgnx-scenario-require OK WHAT`,
`drgnx-scenario-expected 'NAME` (for `:expected-result`), `drgnx-scenario-with-fixture (ROOT [KIND])` (a fresh
git repo, removed afterwards with its file and dired buffers and the Explorer roots in it; fixtures of yours older than a
day — a run killed at its timeout — are deleted when the next is made), `drgnx-scenario-load-driver`. The results file adds `tests` (every test with its
result) and `known_red` (name, summary, trace) — see [scenarios.md](scenarios.md) for the scenarios themselves.

## Terminal tier

`test/tty/` tests drgnx in a terminal. They run in batch Emacs under `drgnx-run-ert-batch` (temp HOME and XDG
dirs) and drive the session through `harness/drgnx-tty-session.el`:

- **Session:** a run directory prepared as for a GUI session (`drgnx-ui-prepare-run`: generated init, its own server
  socket), named `drgnx-tty-PID-N`. Its Emacs runs in a pane of a **private tmux server**, `tmux -L drgnx-tty-PID-N
  -f /dev/null`, with `TMUX_TMPDIR` in the run directory, so the socket is under it too. The run directory is under
  `$DRGNX_UI_STATE` when that is set, else under a short private directory of its own, `tUID` in the temp directory
  (`drgnx-tty-session-state-root`, not the GUI sessions' `$XDG_STATE_HOME/drgnx/ui`): a Unix socket path holds about 107
  bytes, and `RUN/tmux-UID/NAME` with a 7-digit PID twice in NAME passed that under a long home or a test run's nested
  temp directories. Without `:daemon` the pane
  runs `emacs -nw`. With `:daemon`, window 0 runs `emacs --fg-daemon` and window 1 runs `emacsclient -t`.
  `drgnx-tty-session-client SESS :env ENV :args ARGS` opens more clients, each in its own window, with extra
  variables (`TERM=…`) and emacsclient arguments (files, `-e FORM`). `drgnx-tty-session-pty-start` opens a client
  under Emacs's own pty that never answers a query: a silent terminal. `:keys PROFILE` (`vscode`, `emacs` or `vim`)
  writes the session's `keys.eld` with that profile. `drgnx-tty-session-tmux SESS ARGS…` runs any tmux command on the
  session's server.
- **Isolation:** every program runs under `env -i` with the GUI harness's allowlist. HOME, `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` are in the run directory, and `TMUX` is unset. Every tmux
  call names the server (`-L`) and passes `-f /dev/null`, so neither `~/.tmux.conf` nor `/etc/tmux.conf` is read and
  the user's tmux server is never used (a test checks every call). The server gets `set-clipboard on`, `extended-keys on`, `window-size
  manual`, `status off`, `mouse off` (the application gets the mouse bytes) and `default-shell /bin/sh`. `:options`
  adds more tmux commands for one test.
- **Nested (tmux inside tmux):** `:nested LINES` runs a second private tmux in the pane (`tmux -L inner -f
  RUN/inner.conf`, its socket under `RUN/inner-tmux`, which `TMUX_TMPDIR` names) with Emacs in it, the way drgnx runs in
  real life: Emacs gets the inner tmux's own `TMUX` and `TERM`. `inner.conf` is `default-terminal`, `status off`
  and `default-shell /bin/sh`, then LINES; the inner tmux keeps tmux's own defaults (`set-clipboard external`,
  `extended-keys off`, `focus-events off`) unless LINES change them, so a test says what it turns on. Keys, the screen
  and the clipboard go through the outer server, which is the inner tmux's terminal; `drgnx-tty-session-inner-tmux`
  runs a command on the inner server, and `drgnx-tty-session-stop` kills it first. With `:command`, that command runs in
  the inner tmux instead of Emacs (to see the bytes tmux passes on). Not with `:daemon`.
  The inner server is not under the outer server's time budget: it ends when Emacs (its only pane) ends, and
  `drgnx-tty-session-stop` and the sweep of sessions whose runner died kill it (its command line names the run
  directory).
- **Cleanup:** `drgnx-tty-session-stop` asks Emacs to exit, kills the tmux server and anything still running from the
  run directory, then removes the run and socket directories. `drgnx-tty-session-with` stops the session even when
  the test fails, and `kill-emacs-hook` stops any session a test left running. A runner killed with SIGKILL runs
  no hook, so two more things cover it. The server runs as `setsid timeout -s TERM -k 10 BUDGET tmux … -D` and ends
  after `$DRGNX_TTY_MAX_RUNTIME` seconds (default 1800) with everything in it. Each start also sweeps the sessions
  whose owner is dead: the PID in `drgnx-tty-PID-N` is no running Emacs. It kills their processes, found by name in
  any state root, and removes their run and socket directories (the run directory from the process's
  `DRGNX_UI_RUN`, or the current state root). Processes in another PID namespace are left alone: a container's
  sessions carry the container's PIDs, which mean nothing to a host sweep.
- **Input is raw bytes:** `drgnx-tty-session-send` uses `tmux send-keys -H`, one argument per byte. A test proved
  this delivers every byte unchanged; `paste-buffer -r -d` showed ESC as `^[`. Keys are encoded the way a kitty
  keyboard protocol, modifyOtherKeys or legacy terminal sends them (`drgnx-tty-session-key`): characters, RET, TAB,
  ESC, DEL, and the arrows, Home, End, PgUp, PgDn and F1–F12 with modifiers as xterm sends them. Text given as a
  multibyte string goes as UTF-8. Mouse input uses
  SGR reports on 1-based cells (`-click`, `-wheel`, `-drag`).
- **Output:** the screen comes from `capture-pane` (`-screen`, `-find`, `-wait-screen`, `-quiet`). The paste buffer
  shows what OSC 52 copied (`-clipboard`), and `-pane-flags` reports the pane's mouse and key modes. The inner Emacs's
  state comes through its socket (`-eval`, `-wait`).

Run it:

```
bin/drgnx test --tty                          # on the host (needs tmux)
bin/drgnx test --container --tty              # in a Fedora 45 container, Emacs 31.1
bin/drgnx test --container --tty --fedora 44  # Fedora 44, Emacs 30.2
```

`bin/drgnx test --tty` is `drgnx-run-ert-batch` on `test/tty`, every file in an Emacs of its own like the unit tier,
SIGPIPE ignored, in a temp directory of its own; the environment is the caller's (the sessions start theirs with
`env -i`). `DRGNX_TEST_SELECTOR` narrows it. In a container the image `drgnx-test-tty:fNN` is built from
`test/container/Containerfile.tty` with `--build-arg FEDORA=NN`; the image has tmux, plus kitty and mutter for the exit
test. It runs with the GUI tier's security options (`seccomp=unconfined`, `label=disable`) and `--memory 3g`.
`DRGNX_TEST_TTY_IMAGE` uses a prebuilt image. `bin/drgnx check` runs the tier as the `tty` job (a GUI job for the memory
accounting, in the parallel phase) when tmux is installed; `--no-gui` leaves it out. The `Terminal tier` workflow runs
the two container runs nightly ([ci.md](ci.md)).
