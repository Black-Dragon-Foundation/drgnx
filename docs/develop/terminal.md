# The terminal

The terminal's engine is libghostty-vt, Ghostty's terminal library (MIT), linked statically into the `drgnx-term` worker
through the crate `runtime/crates/ghostty-vt-sys`. This page covers building the engine, the worker, the hub's
methods and the editor's side.

## Building the engine

libghostty-vt is written in Zig. **Zig is a build tool only**: it builds one static library, nothing Zig is installed
with drgnx, and nothing is downloaded by a build script.

- **Pins:** `runtime/crates/ghostty-vt-sys/pin.toml` names the libghostty-vt release (1.0.x), the Zig minor it needs
  (0.17.x) and the sha256 of the two signed tarballs (the source and its dependency packages). `NOTICE` in the same
  directory lists every package built from them with its licence; a test checks it against `pin.toml`.
- **Getting the tarballs:** `runtime/crates/ghostty-vt-sys/fetch.sh` downloads them into `tarballs/` (or
  `$GHOSTTY_VT_TARBALLS`), checks the sha256 and, when `minisign` is installed, the signature. The offline bundle carries
  the same two files. A build with the files missing stops and says so.
- **What the build does:** it checks the sha256 of both tarballs against `pin.toml`, unpacks them into `OUT_DIR`, and runs
  `zig build --system <deps> -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget=<the Cargo target>` with a fresh, empty
  `ZIG_GLOBAL_CACHE_DIR` (a non-empty cache can crash Zig 0.17, and an empty one proves nothing else was used). It then
  links `libghostty-vt.a`. The build takes a few minutes on first use and is cached in the target directory.
- **Zig:** a `zig` 0.17.x on PATH (or `ZIG`). `install.sh` and `drgnx update` fetch a pinned, checksummed one when there is
  none (see [the runtime](runtime.md#zig)); a missing or other Zig stops the build with a message naming 0.17.x.
- **Your own library:** `GHOSTTY_VT_LIB=<dir holding libghostty-vt.a>` links that instead and runs no Zig. At run time
  `ghostty_vt_check()` compares the library's `ghostty_build_info` with the pin.
- **Features:** `ghostty` (default) builds and links the engine; with it off the crate is empty, which is how a target
  whose link row does not pass yet (Android) builds its consumers. `no-simd` passes `-Dsimd=false` (no simdutf and no
  Highway, so no C++): the fallback if the symbol rows fail, and much slower.

### The link rows

`cargo test -p ghostty-vt-sys --test link_rows` (run it through the cargo wrapper, in a container):

| Test | Proves |
|---|---|
| `links_and_creates_a_terminal` | a terminal is created, written to and formatted back through the static library |
| `no_duplicate_compiler_rt_symbols` | the archive's compiler_rt cannot clash with Rust's `compiler_builtins` |
| `no_libstdcxx_reference` | the binary references no libstdc++ symbol and needs no C++ runtime library |
| `builds_offline` | the crate builds in a network namespace of its own, from the pinned tarballs |
| `notice_matches_pin` | `NOTICE` names both tarballs and every package built from them |

The macOS row (`aarch64-apple-darwin`, a cross-compile from Linux and the real link on the Mac lane) and the Android row
(`cargo check --target aarch64-linux-android -p ghostty-vt-sys`) run in the release's CI pass.

## The worker

`drgnx-term` (crate `runtime/crates/drgnx-term`) runs one terminal: the PTY master, the program on it, the engine's
`Terminal` and `RenderState`, and the key and mouse encoders. The engine's objects are not thread-safe, so the worker
has **one thread**: a poll loop over the PTY, its socket and the socket's listener (`src/run.rs`). libghostty stays out
of the hub's binary, and an engine crash ends one terminal, never the hub or Emacs.

```
drgnx-term --socket PATH [--cols N] [--rows N] [--cell W,H] [--window N] [--dir DIR] -- PROGRAM [ARGS...]
```

The hub starts it; it runs PROGRAM on a new PTY (a new session whose controlling terminal is the PTY, `src/pty.rs`)
with the worker's own environment, and serves the hub on PATH. Without the `ghostty` feature the binary refuses to start
(exit 78) and the library builds only the parts that need no engine.

**The grid keeps the window's width.** The workbench owns pane sizes, so the worker refuses DECCOLM, as xterm does by
default and the other modern terminals do: mode 40 (allow 80 ⇄ 132 columns) stays off, and with it off the engine
ignores mode 3 (DECCOLM) and neither resizes nor clears. The C API cannot lock a mode, and a program sets one with
`CSI ? … h`, where `CSI ? 40 ; 3 h` sets 40 before 3 in the same sequence; so `Engine::write` holds each `CSI ? … h`
until it ends (it may span writes) and writes it without 40. A request for 40 alone writes nothing.

**The wire** (`src/proto.rs`) is one JSON object per line, tagged by `t`. The hub sends `attach {view, class, hub,
env_epoch}`, `env`, `key {key, mods, text, unshifted}`, `text`, `paste`, `focus {in}`, `mouse {kind, button, col, row,
mods}`, `resize {cols, rows, cell_px}`, `ack {version}`, `resync {model?}`, `config {config: [[name, value]…]}` and
`close {signal}`. The worker sends `hello {proto, pid, shell_pid}` on every connection, `patch {patch}` (a whole
[`drgnx-rows` patch](hub.md#rows)), `model {model}` (a whole `view-model` event: Find's matches, "The editor's side"),
`title`, `cwd`, `bell`, `notify`, `progress`, `clipboard-write`, `prompt` (OSC 133) and `exit {code, signal}`. A new
connection replaces the last (a restarted hub); until it attaches nothing is drawn,
and its attach starts with a reset. The hub going away never ends the program.

**Frames** (`src/frame.rs`, a pure clock the tests drive with fake time):

- A frame goes **at once** when a key went to the program in the last 50 ms (the echo); otherwise at most one per
  16 ms while output flows.
- While the program holds its output (mode 2026, synchronized output) the frame waits until it lets go, at most 150 ms.
- **One patch in flight:** nothing is drawn until the editor acknowledges the last patch (`ack` of its version);
  changes accumulate in the engine meanwhile. An attach, a `resync` or a new hub clears the slot and sends a reset.

**Rows** (`src/rows.rs`, `src/worker.rs`):

- The worker owns the view's patches: versions, row keys and styles. A row's key comes from the worker's monotonic
  counter when the row first reaches the editor, and never changes while the row lives (the engine's row identity
  follows the row through scrolls).
- A frame reads the screen's dirty rows. A row whose content equals what was sent is not sent again.
- **Scroll is insert-only:** rows that scroll off the top of the primary screen stay in the buffer as its newest
  scrollback; the patch inserts the new bottom rows. A row that changed after it was sent and scrolled off within one
  screen's height is replaced; one that scrolled further unseen (a flood) leaves the buffer and comes back with the
  backfill.
- The buffer keeps at most `--window` rows above the screen (`drgnx-term-scrollback-lines`; the engine's scrollback also has a byte ceiling,
  `scrollback-bytes`, 64 MB by default, since libghostty-vt's own default is one page); older rows are removed
  from its start, and no other row's key changes.
- **Resets:** an attach, a `resync`, a resize (the lines rewrap) and a switch between the primary and alternate screens.
- **Flood mode:** while output flows, patches carry the screen only. After 100 ms without output the rows above the
  screen the buffer lacks are **backfilled newest first**, in patches of at most 40 kB of rows, each inserted after the
  row the buffer holds above the gap.

**Styles** (`src/style.rs`): each distinct cell style gets an id once; a patch carries the styles its rows name that
were not sent yet (a reset: all, the table starting again). The 16 palette colours go as `{ansi: N}`, the rest of the
256-colour palette and direct colours as `{rgb}` (program data). A row has one character per cell, trailing default
blanks dropped; a wide character's second cell is a stop at the next column's pixel, so columns keep their place
whatever width the editor's font gives the character. A glyph wider than its two cells would still push its row right
up to the next stop, so the terminal's buffer replaces the hub-fed rows' fit guard (an ellipsis before the first stop,
for labels) with its own (`drgnx-view-patch-guard-function` = `drgnx-term--cell-guard`): the wide cluster before each
stop is measured once per cell width (`drgnx-term--cell-scales`, 4,096 entries) and, when wider than two cells, drawn
smaller by a `(height F)` display over all its characters (so a joined emoji stays one glyph). A guard per stop with
a scale was chosen over rescaling the emoji font (`face-font-rescale-alist`): that is global, names a font, and would
shrink emoji in every buffer; the scale here is measured from the glyph actually drawn, in this buffer only. Grapheme
clusters are one width as Unicode gives it by default (`drgnx-term-grapheme-width-method` "unicode": mode 2027 on, as
Ghostty does), so 👩‍💻 is two cells; a shell whose line editor counts code points (wcwidth) can misplace its cursor on
such a line, which "legacy" avoids. The cursor's column in `term` is an index into the row's text.

**Input:** a key name maps to libghostty's key (letters, digits and US-layout symbols by character, named keys, else
unidentified with its text; `src/keys.rs`) and is encoded from the terminal's modes (kitty keyboard flags,
modifyOtherKeys, DECCKM). Without the kitty flags, Ctrl+I, Ctrl+M and Ctrl+[ send tab, return and escape as
xterm does (the encoder would send them as CSI u, which shells do not read). A repeat or a release (`action`) is
encoded as itself only while the program set the kitty flag "report event types" (2; `term` then says `key_events`);
otherwise a repeat is a press and a release sends nothing. Paste is bracketed when the program asked (mode 2004); mouse events are encoded only while the
program tracks the mouse; focus reports only when it asked (mode 1004).

**Effects:** the engine's replies to the program (device and mode reports) go back to the PTY; bell, title, working
directory (OSC 7), clipboard writes (when `clipboard-write` allows; denied otherwise), notifications, progress
(OSC 9;4) and prompt marks (OSC 133) go to the hub.

**Logging:** stderr, at `DRGNX_TERM_LOG` (default `info`). **Nothing logged carries the program's bytes or the text
typed**, only counts; a malformed message from the hub is logged by its position, never its content.
`tests/logging.rs` runs a real PTY at trace level and checks the log.

### The worker's tests

`cargo test -p drgnx-term` (through the cargo wrapper, in a container): `tests/worker.rs` drives the worker with a fake
clock (frames, flood and backfill, the in-flight patch, mode 2026, row keys through scrolls, resizes and eviction, the
kitty, DECCKM, paste and mouse encodings, styles and wide cells); `tests/logging.rs` checks the log.

### vttest

`tests/vttest.rs` runs vttest (Thomas Dickey's VT100/VT220 test program) on a real PTY of 80 × 24 under the worker's
run loop, walks its menus with a key script and compares eight screens with their goldens in
`test/conformance/vttest/`. Each golden holds the screen's 24 rows as the editor gets them, then each row's style runs
with the style spelled out. A step types its keys and waits for text that only the next screen shows, plus one of
vttest's prompts, and then until the worker is quiet: an echoed digit or a half-drawn screen is never taken. A wait that
runs out prints the screen it saw.

| Golden | vttest | What it holds |
|---|---|---|
| `cursor-movement` | 1, first screen | the border of `*` and `+` and the frame of `E` around the text |
| `scroll-regions` | 2, up to the first scroll test | rows 12–13 as a region scrolled down |
| `character-sets` | 3 → 8 | US ASCII, British and DEC line drawing in G0 and G1 |
| `reports` | 6 → 3 | DSR 5 (`CSI 0 n`, "terminal OK") and DSR 6 (the cursor's position) |
| `insert-delete` | 8, up to the staggered column | insert and delete line, insert mode, delete character |
| `double-width` | 4, first screen | the double-width and double-height lines in 80 columns |
| `colours` | 11 → 6 → 2 | the 8 × 8 foreground/background matrix, bright off and on |
| `vt52-exit` | 7, to the screen after VT52 mode is left | the identify reply and the cursor report in ANSI mode |

vttest must be installed: the test images carry it (`test/container/base/Containerfile`, `test/container/rust-packages.sh`),
and without it the test fails, it never skips. `UPDATE_VTTEST_GOLDENS=1` writes the goldens instead of comparing.
They were recorded from the worker and checked by eye against what vttest says each screen should show. Where they
differ, the golden keeps what the worker does and the row below records the difference: it is fixed in the engine or the
worker, never in the golden.

| Screen | vttest expects | The worker |
|---|---|---|
| `double-width` | the double-width and double-height lines (DECDWL, DECDHL) drawn twice as wide | the rows carry no line size: they are drawn at normal width |
| `vt52-exit` | VT52 mode (`CSI ? 2 l`): the rectangle of `*` and `!`, then the identify reply `ESC / Z` | libghostty-vt has no VT52 mode: the VT52 sequences print as text, and the identify request gets the ANSI reply (`CSI ? 62 ; 22 c`) |
| 132-column screens (menus 1, 2 and 4) | DECCOLM switches to 132 columns when the terminal allows it | DECCOLM is refused, as in xterm's default: the grid stays at the window's 80 columns and vttest's 132-column lines wrap |
| `vt52-exit` | the cursor report after leaving VT52 mode read as `CSI 1 ; 1 R` | vttest reads that reply and the identify reply up to a Return, so the script's Return shows as `<13>` in them and vttest calls the cursor report unknown |

## The hub's methods

The editor talks to its terminals through the hub (`runstav/src/methods/term.rs`, routed by
`drgnx-ratatoskr/src/term/methods.rs`); ids are values, never object keys.

| Method | Params | Answer |
|---|---|---|
| `term/open` | `dir`, `command?`, `env` (the program's whole environment, `[[name, value]…]`), `cols`, `rows`, `cell_px?`, `class`, `window?`, `config?`, `memory_max?`, `tasks_max?` (the scope's limits) | `{id, view}`; the view is `term:<id>` and its first patch a reset |
| `term/config` | `id`, `config: [[name, value]…]` (`scrollback-lines`, `scrollback-bytes`, `clipboard-write`, `cursor-style`, `enquiry-response`, `title-report`, `grapheme-width-method`, `detached-keep`, `colours`) | `true` |
| `term/key` | `id`, `key`, `mods`, `text?`, `unshifted?`, `action?` (`press`, the default, `repeat` or `release`) | `true` |
| `term/text`, `term/paste` | `id`, `text` | `true` |
| `term/focus` | `id`, `in` | `true` |
| `term/mouse` | `id`, `kind`, `button`, `col`, `row`, `mods` | `true` |
| `term/resize` | `id`, `cols`, `rows`, `cell_px` | `true`; the next patch is a reset |
| `term/scroll` | `id`, `to: "bottom"`, or `delta` / `prompt_delta` from `from` (a row key; default the cursor's row) | `{key}` of the row to show, or none |
| `term/fetch` | `id`, `before_key?`, `max_bytes?` | `{version}` of the backfill patch sent now (none: nothing missing) |
| `term/search` | `id`, `query`, `dir?` (`up`, `down`) | `{found, held, model}`: every match, those in rows the buffer holds, and the version of the view's model that holds these (a `view-model` sent first: list `matches`, newest first for `up`, nodes `KEY:COL` with fields `key`, `col`, `len`, at most 20,000; none with no editor attached) |
| `term/text-range` | `id`, `from_key?`, `to_key?` | `{text}`; with no `from_key` from the oldest row the engine holds |
| `term/close` | `id`, `signal?` | `true`, then `term/exit` |
| `term/list` | | `[{id, pid, running, cwd, title, old, mine, orphaned, detached_at?, command, place?}…]`; 200 ms per worker, a silent one counts as running; `mine`: it draws for this connection's session |
| `term/session-end` | `keep?` (ids) | how many terminals of this connection's session were closed (a clean Emacs exit); those in `keep` detach and run on |
| `term/attach` | `id`, `cols`, `rows`, `cell_px?` | `{id, view}`: an orphaned or detached terminal now draws for this session, from a reset; refused for one another live session has |

**Events**, to the connection of the editor session that opened the terminal: `term/exit {id, code, signal}`,
`term/title`, `term/cwd`, `term/bell`, `term/notify`, `term/progress`, `term/clipboard-write` and `term/prompt` (the OSC
133 marks, for notify-on-command-finish). `term/detached {ids}` goes to every live session when terminals detach. The
view's `view/env`, `view/ack` and `view/resync` go to the worker.

Where this differs from the design's sketch: the view id is the hub's (`term:<id>`, so an adopted terminal keeps
it), `class` names the display class its patches are for, `term/scroll` takes the row it counts from (the editor owns
its window's position), `term/fetch` answers with the version of the patch it sent (the rows themselves come as a
`view-patch`, in order with the others), and `term/session-end` is the clean-exit door. The engine keeps at least
10,000 lines whatever the window (`scrollback-bytes` is the ceiling), so search and copy reach above the window.

**Tests:** `domr --only 'term/*'` (`test/conformance/term/`: open and echo, resize, fetch, search, text-range, live
scrollback, list, close, exit), `runstav`'s `term_protocol_uses_no_ids_as_object_keys`, the worker's
`scroll_by_prompts_rows_and_to_the_bottom` and `search_and_text_range_read_beyond_the_window`, and the systemd row
`tests/term_scope.rs` (`worker_survives_hub_restart_under_kill_mode_mixed`, `cgroup_memory_limit_reaches_scope`) in a
fake runner:

```
cargo test -p drgnx-ratatoskr --features fleet --test term_scope --no-run && cargo build -p drgnx-term
test/runners/fleet.sh up --runners 1
test/runners/fleet.sh host <the term_scope binary> worker_survives_hub_restart_under_kill_mode_mixed
```

## Lifetime

A terminal's worker outlives the hub that started it (`runtime/crates/drgnx-ratatoskr/src/term/`, the worker's
`src/{scope,registry,child}.rs`).

**Spawn:** with a user systemd, the worker runs in a scope of its own, `systemd-run --user --scope --unit
drgnx-term-<id>`, with `MemoryMax` and `TasksMax` from the `linux-cgroup*` settings: a hub unit stopped with
`KillMode=mixed` kills its own cgroup, not the scope. Elsewhere the worker gets a process group of its own. The worker
binds `<state>/term/<id>.sock`; its stderr goes to `<state>/term/<id>.log`. `term/open` connects every 20 ms of real
time until the worker binds, for at most 5 s, on a blocking thread (the request waits inside its serving step, under
which the test clock stands still), then reads its hello within 5 s. The hub finds the binary at
`DRGNX_TERM_BIN`, else beside its own.

**Registry:** `<state>/term/<id>.json` holds the unit, the worker's pid and start time, the shell's pid, the view
(`term:<id>`), the display class, the cwd, the editor session, the command, where the editor showed it (`place`) and
when it was detached (`detached_at`, ms since the epoch). It is written by a rename, and goes with the terminal. No
screen text is written anywhere: the screen and scrollback live in the worker's memory.

**Trust:** the boundary is the user's uid, as for tmux. `<state>/term/` is made `0700` (narrowed when found wider,
refused when another user's: nothing in it is adopted), each socket is `0600` (`drgnx_term::run::listen`), and the
worker checks every connection's peer uid (`SO_PEERCRED` on Linux, `getpeereid` on macOS), dropping another user's
unread.

**Adoption:** at the hub's start (in the background), each record's worker is checked: by its unit (`systemctl --user
is-active`) when there is one, then by its pid and start time (a reused pid is not it). A live one is connected to
again; a dead one's record and socket go. The worker's hello carries its `term` protocol: another major version
marks the terminal "from before the update" (its program keeps running; the hub sends it nothing but `close`, and
`term/list` shows it as old). A newer minor version is adopted as it is.

**Session end:** an editor's `hello` names its Emacs session. When the last connection carrying a session closes, its
terminals are **orphaned** at once (the worker is told `detach`: it draws nothing) and wait 60 seconds for a hello with
that session (a dropped socket, a hub restart); then they are **detached**: `detached_at` goes into the record and
every live session hears `term/detached {ids}`. Neither ends the program. A clean Emacs exit (`term/session-end`) ends
the session's terminals at once, but those it names in `keep`, which detach at once (their record keeps no session).
A terminal draws on the subscribed connection of its session (the editor's `drgnx-hub-session`): until one subscribes
again, an adopted terminal or one whose editor dropped its socket draws nowhere; the subscription re-attaches it
(after the grace too), and its next patch is a reset. A hello alone (the editor's call connection) moves nothing. A
hub restart while terminals are detached changes nothing: the records say so, and the grace does not start again.

**Reattach:** `term/attach` takes an orphaned or detached terminal into the asking connection's session (never one
whose session has a live connection: no stealing between two Emacs instances), writes the record, and sends the worker
`resize` with `redraw` (when the size is unchanged the worker sends the program's group SIGWINCH itself, so a
full-screen program draws its screen again) and `attach` (a reset: the screen, then the backfill).

**Lifetime alone:** the worker ends its program (SIGHUP) after `detached-keep` (from `term/config`, hours; default 24,
0 never) with no editor attached, counted by the worker itself from the first moment it was told `detach` or lost its
hub, so no hub or Emacs needs to run. A new worker counts from its start until its first attach.

**Program running:** the worker answers `status` from the shell's OSC 133 marks (C: a command's output started, D: it
ended), else from whether the shell has a child: Linux `/proc/<pid>/task/<pid>/children`, macOS `proc_listchildpids`.

**Tests:** `cargo test -p drgnx-ratatoskr --lib term::` (fake workers on the socket: adoption by pid and start time,
the protocol versions, orphaned at once and detached after the grace with `term/detached`, an attached terminal not
offered, a detached one surviving a hub restart, a clean exit that keeps some), `drgnx-term`'s `tests/running.rs`
(both ways of telling a program runs; the socket's mode and another uid's connection dropped, the latter as root, as in
the test container) and `tests/worker.rs` (`detached_keep_ends_a_worker_with_no_client`, on the fake clock).

## Remote terminals

New Terminal in a remote folder (a TRAMP name) runs the user's login shell on that host, in that folder: the PTY, the
worker and the engine stay local, the terminal's program is one command, and nothing is installed on the host
(`modules/tools/drgnx-term-remote.el`).

- **The command** (`drgnx-term-remote-command`, pure, from `tramp-dissect-file-name` and `tramp-compute-multi-hops`, so
  `tramp-default-proxies-alist` counts): for the ssh-like methods (`ssh`, `sshx`, `scp`, `scpx`, `rsync`) `ssh -t [-p
  PORT] [-l USER] [-J HOP,…] HOST 'exec /bin/sh -c SCRIPT'`, earlier ssh hops as `-J`; a last `sudo`/`doas`/`su` hop on
  the same host runs there (`sudo -u USER -H --`, `doas -u USER`, `su -l USER -s /bin/sh -c`); a container method as
  the only hop (`docker`, `podman`, `kubernetes`, `toolbox`, `distrobox`, `flatpak`) its own exec. Any other method
  (`ftp`, `smb`, `adb`, a local `sudo`, …) gets eshell and a notice naming the method (`drgnx-terminal-new`).
- **Its own connection, never TRAMP's**: TRAMP's ControlMaster is a child of Emacs (`ControlPersist=no`), so a
  terminal multiplexed through it would end with Emacs and could not be reattached. The terminal's ssh gets no control
  options: the user's ssh config decides (a persistent master of the user's own is joined), and a password, OTP or
  host-key question shows in the terminal. Host-key checking is never weakened.
- **The script** (`drgnx-term-remote-script`) is POSIX sh whatever the login shell (fish, csh) that parses ssh's
  command line: it holds no quote, `!`, newline or backslash of its own, and the folder goes as `\0NNN` escapes for
  `printf %b`, so every byte of a folder's name arrives. It goes to the folder (nothing when it is gone) and becomes the
  passwd entry's shell, else `$SHELL`, else `/bin/sh`, as a login shell.
- **Environment** (`drgnx-term--remote-env`): the local terminal's, without the local-only `DRGNX_SERVER_NAME`,
  `EDITOR`, `VISUAL`, `GIT_EDITOR`; `TERM=xterm-256color` and no `TERMINFO` with `drgnx-term-ssh-terminfo` `fallback`.
  With `install` the command is `/bin/sh etc/shell/drgnx-ssh-terminfo.sh SCRIPT ARGS…`, in the terminal's PTY: the
  first time for a host it sends Ghostty's entry to the host's `tic -x -` (both ssh's prompts show in the terminal)
  and records the outcome in `<state>/terminal-ssh-hosts`, the file the shell integration's `ssh` keeps.
- **The worker** runs locally in the home folder; `term/open`'s `remote` (TRAMP's prefix, `/ssh:host:`) goes into
  the registry and `term/list`, so a reattach knows its host.
- **Folders** (`drgnx-term--remote-cwd`): an OSC 7 `file://HOST/PATH` (or `kitty-shell-cwd://`) sets
  `default-directory` to the prefix plus PATH, unchecked (no wait on the connection). The first host named is learned
  as the terminal's own; another host's (an ssh typed inside) is not followed. A bare path is never the host's.
- **Links**: a `file://` link opens the file on the host through TRAMP, never a local one.
- **Clipboard**: an OSC 52 write from a remote terminal follows `drgnx-term-remote-clipboard-write` (`ask`, the
  default: a notice "HOST wants to set the clipboard" whose command, Answer Clipboard Request, offers Allow, Always for
  HOST (written to `drgnx-term-remote-clipboard-hosts` in your settings) and Deny; the text is never shown). Reads stay
  refused.
- **Running program**: the local program is ssh, always running, so only OSC 133 marks say a remote shell is at its
  prompt; without them a remote terminal counts as running.
- **Lost connection**: ssh's exit 255 keeps the buffer with "Connection lost (exit 255)" and **Reconnect**
  (`terminal-reconnect`: the same command in a new terminal in that buffer).
- **Title**: a remote terminal's buffer, and so its tab, is named after its host (`*terminal: HOST*`, then `HOST:
  TITLE`).

**Tests:** `test/unit/term-remote-test.el` (the command per method, hops, sudo/doas/su, containers, refused methods;
the folder through sh, bash, zsh and fish; the environment; `install`'s script; folders, links, the clipboard,
Reconnect, a reattached remote terminal) and the ssh row, `test/ssh/term-ssh-test.el`, which runs only through
`test/container/ssh-row.sh`:

```
DRGNX_TEST_IMAGE=<the line's drgnx-test image> DRGNX_RATATOSKR_BIN=runtime/target/debug/ratatoskr test/container/ssh-row.sh
```

It builds `drgnx-test-ssh:<hash>` on the test image (`Containerfile.ssh`: sshd, ssh, tcsh, sudo, tic; tagged by a hash
of that file and the base's image id, so a new base rebuilds it) and runs the batch tier on `test/ssh/`. The first
test starts sshd on 127.0.0.1:2222 inside the container with keys and users (fish, tcsh, a password user, sudo) made
there; the terminals' ssh reads a config from the run's folder (a wrapper first on PATH adds `-F`). Rows: fish and
csh users reach a folder with a quote and a space; a sudo hop reaches root; OSC 7 follows the host, not a foreign
one; an OSC 52 write asks; a dropped connection shows Reconnect and reconnects; `install` sends the terminfo after two
password prompts in the terminal; a remote terminal kept at quit is reattached by the next Emacs, the same shell. With
no image to be had the script exits 75, "image refused", never skipping.

## The editor's side

`modules/tools/drgnx-term.el` (module `tools/term`; New Terminal calls `drgnx-term-start DIR [COMMAND]` when
`drgnx-term-usable-p`). Lisp inserts rows, places the cursor, sends input and runs commands; the worker computes.

- **Open:** `term/open` goes on the subscribed connection, the one the rows come back on, with the window's size in
  cells, the program's whole environment (`drgnx-term-env`; `TERM` and `TERMINFO` from `drgnx-term--term-entries`:
  `xterm-ghostty` only while `<data>/terminfo/x/xterm-ghostty` exists; `COLORTERM`, `INSIDE_EMACS`; the shell
  integration's `DRGNX_TERMINAL`, `TERM_PROGRAM`, `GHOSTTY_SHELL_FEATURES`, `DRGNX_TERMINAL_SHELL`,
  `DRGNX_TERMINAL_SSH`, with Ghostty's other variables unset; then `drgnx-terminal-environment`, then this Emacs's;
  the shell side is `etc/shell/drgnx.*`, docs/guide/shell.md) and the window `drgnx-term-scrollback-lines`. Its answer attaches the buffer to the view
  `term:<id>` in the class `term` (one class for every terminal: the worker builds rows for cells, so a text scale or
  a font change never re-pairs the buffer, and no `view/env` is sent). A reset that came before the answer found no
  buffer, so the answer sends `view/resync` when nothing was applied yet. With no subscription the buffer waits and
  `drgnx-hub-connect` runs; the subscription opens it.
- **What an open reuses** (memos, `core/drgnx-memo.el`, activated by the module's setup): the environment (`term-env`,
  one per session, built again when `process-environment` is set or bound to another list, a terminal setting it is
  made of changes, the terminfo entry appears or goes, or the server starts or stops; the epoch `term-env-set` watches
  `process-environment`, since `setenv` edits it in place), the `colours` of the config (`term-colours`, per frame
  and weak on it, read again after a theme change: the epoch `term-theme`) and the word syntax table (`term-word-syntax`,
  one for every terminal buffer, per value of `drgnx-term-selection-word-chars`). Together they were ~38 kB of an
  open's ~78 kB of allocation.
- **The view type `drgnx-term-view`:** `:delay 0` (no throttle; the 4 ms slices stay), `:ack t`, `:epoch-reset nil`,
  `:follow-tail t`. Its PATCHED puts the inserter's overlays back, then point and the cursor on the cursor's row and
  column (`cursor-type` from the shape: block `box`, hollow `hollow`, bar `(bar . 2)`, underline `(hbar . 2)`; not
  visible: nil). A cursor past the row's last character (trailing blanks are not sent) is drawn by an overlay's
  `after-string` of blanks whose last carries `cursor`.
- **Theme:** a theme enabled or disabled bumps `term-theme` and repaints every terminal from the faces
  (`drgnx-view-patch-repaint`): rows keep their keys; the workers get the new `colours` in a `term/config`. A face
  changed without a theme (`set-face-attribute`) reaches a new terminal's worker only after the next theme change.
- **Scrollback:** `drgnx-term-scrollback-lines`'s `:apply` sends `term/config` `scrollback-lines` to every worker,
  which removes the oldest rows or backfills; window-start reaching the buffer's top sends `term/fetch` with the first
  row's key (one at a time; not again for the same top row once the worker said nothing is missing).
- **Input:** `term/key` from `drgnx-term-send-event` (`drgnx-term--event-key`: the event's base key, its modifiers
  and the text a printable key types) and `term/text` (`drgnx-term-send-string`). `drgnx-term-mode-map` binds every
  raw key (control, meta, the named keys) to `drgnx-term-send-event`; `drgnx-term-apply-keys` takes out the keys the
  active profile keeps for drgnx (`drgnx-terminal-key-split`, with `drgnx-term-reserved-keys`), on every key-stack
  change. `term/paste` sends the kill ring's newest entry (bracketed by the engine when the program asked).
- **Key repeats and releases** (Nidhogg only): a key read with `nidhogg-last-key-repeat` set goes as `action`
  `repeat`. While the selected window shows a terminal whose `term` says `key_events`, or a key pressed in one is
  held, `drgnx-term--key-gate` sets `nidhogg-key-events`, so releases arrive as `key-release` special events
  (`special-event-map`, bound by the module's setup and taken out by its teardown). A press sent to such a terminal is
  remembered in `drgnx-term--held` (by `event-basic-type`, 32 at most), and `drgnx-term-key-release` sends its release
  to that terminal, with the modifiers held at the release, wherever the keyboard is now. A terminal that loses the
  selection (`drgnx-term--selected`), or Emacs losing the focus (`after-focus-change-function`), releases what it holds.
- **Mouse:** the mouse bindings are menu-item filters that answer only while the patch's `term` says
  `mouse_tracking`; then `term/mouse` carries the cell (`drgnx-term--mouse-cell`: the screen row counts from the
  buffer's last `rows` lines). Focus changes (`window-selection-change-functions`, buffer-local) send `term/focus`.
- **Copy mode** (`drgnx-term-copy-mode`) pauses the view (`drgnx-view-patch-pause`) and swaps in a map with only
  `C-g`; leaving draws the kept patches. `drgnx-term-find` sends `term/search` up from the cursor; the worker sends the
  matches in the buffer's rows as the view's model (a `view-model` reset: list `matches`) before it answers. The
  event and the answer come on different paths, in either order: the first match is shown once both are here (the
  answer names the model's version; `drgnx-view-model-functions` says when a model is queued, and
  `drgnx-view-model-apply-queued` applies it at once, since a terminal's rows name no model). It enters copy mode
  at the first match, marked by the face `drgnx-term-search-selected`. Find again with the same text in copy mode,
  `drgnx-term-find-next` and `drgnx-term-find-previous` walk the list in Sjá (`drgnx-view-nav`, wrapping) and read the
  match's `key`, `col` and `len` fields: no hub call; a match whose row the buffer no longer draws is passed over. A
  `view/resync` with `model` sends the last model again as a reset, rows untouched; an attach starts the model again.
- **Links:** the worker sends an OSC 8 run as the row prop `drgnx-term-link`, on every row it sends: a screen cell's
  link is read through a viewport point, a row above the screen (scrolled off, a backfill, `term/fetch`) through a
  history point (row `scrollback rows - N` for viewport row `-N`: the engine's viewport never scrolls); PATCHED gives such runs `mouse-face` and a keymap, and `drgnx-term-open-link` opens a local `file://` URI with
  `find-file-other-window`, anything else with `browse-url`.
- **Resize:** a window change (`drgnx-state` `windows-changed`) debounces 50 ms per buffer
  (`drgnx-timer-debounce`), then sends `term/resize` with the selected window's size.
- **Events:** `term/cwd` sets `default-directory`, `term/title` renames the buffer, `term/progress` sets
  `mode-line-process`, `term/notify` is a notice of the source `term`, `term/clipboard-write` is a `kill-new` when
  `drgnx-term-clipboard-write` allows it (sent to the worker as `term/config` `clipboard-write`). Clipboard reads
  (OSC 52 `?`) are refused by the engine. While the subscription is down, or before the terminal opened, input queues per buffer,
  at most `drgnx-term-queue-max` (4096) bytes, and goes on `drgnx-hub-connected-functions`.
- **Session:** every hello carries `drgnx-hub-session`; the subscription re-attaches this Emacs's terminals after a
  dropped socket or a hub restart (see [Lifetime](#lifetime)).
- **End:** `term/exit` runs `drgnx-term-exit-functions` in the buffer (Export Keys forgets the typed keys there), then
  kills a shell's buffer, and leaves a command's with its status in `mode-line-process`. Killing the buffer sends
  `term/close`. Turning the module off kills every terminal buffer.
- **Quitting:** `drgnx-term--running-buffers` asks `term/list` (at most `drgnx-term-list-wait`, 0.2 s, through
  `drgnx-hub-call-sync`) for the open terminals whose program runs; no answer counts them all. With
  `drgnx-term-on-quit` `ask` they go to core's `drgnx-session-keepable-functions` (`drgnx-term-keepable`), and the
  quit question offers Keep Running, Close Them or Cancel (`drgnx-session-quit-keep`); with `close` they go to
  `drgnx-session-running-functions` (`drgnx-term-running`), asked about as any running program; with `keep` nothing
  asks. `kill-emacs-hook` sends `term/session-end` with `keep` (`drgnx-term--kept-at-quit`): every open terminal for
  `keep`, the running ones for Keep Running or a quit that could not ask, none for Close Them or `close`.
- **Reattach:** when the subscription comes up, and on `term/detached`, `drgnx-term--look` asks `term/list` and
  offers the rows that are orphaned or detached, not this session's and shown by no buffer here
  (`drgnx-term--offered-rows`; ids from the hub, never a Lisp cache): `drgnx-term-reattach` `ask` posts one notice
  that runs Reattach Terminal (Reattach All, Choose… or Close Them), `always` opens them at once, `never` leaves them
  to the command. `drgnx-term-reattach-one` makes a `drgnx-term-mode` buffer where the terminal was shown (`place`),
  sends `term/attach` at its window's size, and on the answer attaches the view and sends this Emacs's settings.
- **Callers:** Export and Import Keys run `drgnx secrets` through `drgnx-term-start` (else `term`); the key sheet's
  "In the terminal" section is on core's `drgnx-surfaces-cheatsheet-sections`; `drgnx-term-mode` is an input mode for
  the modal engines and Close Pane, and the panel's Terminal tab takes its buffers.

**Tests:** `test/unit/term-test.el` (`drgnx-term/`, a gated hub with the real worker: the shell in a worker, echo,
a flood backfilled, the scrollback setting both ways, undo off, input queued while the hub is away, a theme change
without a reset, a tty frame), `test/unit/term-cells-test.el` (`drgnx-term-cells/`: the cell guard with a fixed
measure) and the GUI rows `test/ui/term-gui-test.el` (`drgnx-term-gui/`: wide cells align, CJK, emoji and a joined
emoji among them, cursor shapes).

## Settings

Every option of Ghostty's configuration has a row in `drgnx-term-settings-options`
(`modules/tools/drgnx-term-settings.el`): `live` (a `drgnx-term-<option>` setting that applies to open terminals),
`spawn` (new terminals), `face`, `mapped` (an existing drgnx or Emacs setting), `later` or `none` (with the reason).
`test/fixtures/ghostty-options.txt` pins Ghostty's list (204 options, read 2026-11-07); a new upstream option is added
there and given a row, or `drgnx-term-settings/every-ghostty-option-is-classified` fails.
`docs/reference/terminal-settings.md` is generated from the table (`drgnx-term-settings-write-reference`; the test
`reference-is-generated-and-current` prints the command).

- **The worker's live settings** go as one `term/config` (`drgnx-term--worker-config`): at `term/open`, from each
  setting's `:apply` (`drgnx-term--apply-config`) and on a theme change. `colours` carries the faces' foreground,
  background and cursor (`drgnx-term-default`, `drgnx-term-cursor`) and, when all 16 resolve, `drgnx-term-color-0`
  to 15, as `#rrggbb` through `core/drgnx-color.el`; the worker sets them as the engine's defaults, so OSC 10, 11, 12
  and 4 read the theme back. `cursor-style` sets the default DECSCUSR style and resets the cursor to it.
- **drgnx's live settings** are read where they act: the copy filter (`filter-buffer-substring-function`: trailing
  spaces, the codepoint map), `mouse-drag-copy-region` (copy on select) and the word syntax table, set per buffer
  by `drgnx-term--set-locals` (`:apply` `drgnx-term--apply-local`); paste protection reads the meta's
  `bracketed_paste`; the mouse filters read `drgnx-term-mouse-reporting` and `-shift-capture`; OSC 133 C and D time a
  command for notify-on-command-finish; `drgnx-term--confirm-close` is a buffer-local `kill-buffer-query-functions`
  that asks only inside a command (turning the module off asks nothing).
- **Spawn settings** shape `term/open`: `drgnx-term-command`, `-env` (over drgnx's entries), `-term`, `-input` (typed
  once the terminal opens), `-working-directory` (New Terminal), and the scope's `memory_max` / `tasks_max`.
- **Not built:** `palette-generate`, `palette-harmonious`, `minimum-contrast`, `clipboard-read`,
  `cursor-click-to-move`, `link`, `link-url` (rows of class `later`).

**Tests:** `test/unit/term-settings-test.el` (`drgnx-term-settings/`), the gated
`drgnx-term-settings/live-setting-reaches-worker` in `term-test.el`, the worker's `settings_reach_the_engine`, and the
fleet row `cgroup_memory_limit_reaches_scope`.
