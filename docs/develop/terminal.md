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

**The wire** (`src/proto.rs`) is one JSON object per line, tagged by `t`. The hub sends `attach {view, class, hub,
env_epoch}`, `env`, `key {key, mods, text, unshifted}`, `text`, `paste`, `focus {in}`, `mouse {kind, button, col, row,
mods}`, `resize {cols, rows, cell_px}`, `ack {version}`, `resync`, `config {config: [[name, value]…]}` and `close
{signal}`. The worker sends `hello {proto, pid, shell_pid}` on every connection, `patch {patch}` (a whole
[`drgnx-rows` patch](hub.md#rows)), `title`, `cwd`, `bell`, `notify`, `progress`, `clipboard-write`, `prompt` (OSC 133)
and `exit {code, signal}`. A new connection replaces the last (a restarted hub); until it attaches nothing is drawn,
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
whatever width the editor's font gives the character. The cursor's column in `term` is an index into the row's text.

**Input:** a key name maps to libghostty's key (letters, digits and US-layout symbols by character, named keys, else
unidentified with its text; `src/keys.rs`) and is encoded from the terminal's modes (kitty keyboard flags,
modifyOtherKeys, DECCKM). Without the kitty flags, Ctrl+I, Ctrl+M and Ctrl+[ send tab, return and escape as
xterm does (the encoder would send them as CSI u, which shells do not read). Paste is bracketed when the program asked (mode 2004); mouse events are encoded only while the
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

## The hub's methods

The editor talks to its terminals through the hub (`runstav/src/methods/term.rs`, routed by
`drgnx-ratatoskr/src/term/methods.rs`); ids are values, never object keys.

| Method | Params | Answer |
|---|---|---|
| `term/open` | `dir`, `command?`, `env` (the program's whole environment, `[[name, value]…]`), `cols`, `rows`, `cell_px?`, `class`, `window?`, `config?`, `memory_max?`, `tasks_max?` (the scope's limits) | `{id, view}`; the view is `term:<id>` and its first patch a reset |
| `term/config` | `id`, `config: [[name, value]…]` (`scrollback-lines`, `scrollback-bytes`, `clipboard-write`, `cursor-style`, `enquiry-response`, `title-report`, `grapheme-width-method`, `colours`) | `true` |
| `term/key` | `id`, `key`, `mods`, `text?`, `unshifted?` | `true` |
| `term/text`, `term/paste` | `id`, `text` | `true` |
| `term/focus` | `id`, `in` | `true` |
| `term/mouse` | `id`, `kind`, `button`, `col`, `row`, `mods` | `true` |
| `term/resize` | `id`, `cols`, `rows`, `cell_px` | `true`; the next patch is a reset |
| `term/scroll` | `id`, `to: "bottom"`, or `delta` / `prompt_delta` from `from` (a row key; default the cursor's row) | `{key}` of the row to show, or none |
| `term/fetch` | `id`, `before_key?`, `max_bytes?` | `{version}` of the backfill patch sent now (none: nothing missing) |
| `term/search` | `id`, `query`, `dir?` (`up`, `down`) | `{matches: [[key, col, len]…]}`; no key for a row the buffer lacks |
| `term/text-range` | `id`, `from_key?`, `to_key?` | `{text}`; with no `from_key` from the oldest row the engine holds |
| `term/close` | `id`, `signal?` | `true`, then `term/exit` |
| `term/list` | | `[{id, pid, running, cwd, title, old}…]`; 200 ms per worker, a silent one counts as running |
| `term/session-end` | | how many terminals of this connection's session were closed (a clean Emacs exit) |

**Events**, to the connection of the editor session that opened the terminal: `term/exit {id, code, signal}`,
`term/title`, `term/cwd`, `term/bell`, `term/notify`, `term/progress`, `term/clipboard-write` and `term/prompt` (the OSC
133 marks, for notify-on-command-finish). The view's `view/env`, `view/ack` and `view/resync` go to the worker.

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
(`term:<id>`), the display class, the cwd and the editor session. It is written by a rename, and goes with the
terminal.

**Adoption:** at the hub's start (in the background), each record's worker is checked: by its unit (`systemctl --user
is-active`) when there is one, then by its pid and start time (a reused pid is not it). A live one is connected to
again; a dead one's record and socket go. The worker's hello carries its `term` protocol: another major version
marks the terminal "from before the update" (its program keeps running; the hub sends it nothing but `close`, and
`term/list` shows it as old). A newer minor version is adopted as it is.

**Session end:** an editor's `hello` names its Emacs session. When the last connection carrying a session closes, its
terminals wait 60 seconds for a hello with that session (a dropped socket, a hub restart); then they end (`close`,
SIGHUP to the program's group). A clean Emacs exit ends them at once. A terminal draws on the subscribed connection
of its session (the editor's `drgnx-hub-session`): until one subscribes again, an adopted terminal or one whose editor
dropped its socket draws nowhere; the subscription re-attaches it, and its next patch is a reset. A hello alone (the
editor's call connection) moves nothing.

**Program running:** the worker answers `status` from the shell's OSC 133 marks (C: a command's output started, D: it
ended), else from whether the shell has a child: Linux `/proc/<pid>/task/<pid>/children`, macOS `proc_listchildpids`.

**Tests:** `cargo test -p drgnx-ratatoskr --lib term::` (fake workers on the socket: adoption by pid and start time,
the protocol versions, the grace, a clean exit) and `drgnx-term`'s `tests/running.rs` (both ways of telling a
program runs).

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
- **The view type `drgnx-term-view`:** `:delay 0` (no throttle; the 4 ms slices stay), `:ack t`, `:epoch-reset nil`,
  `:follow-tail t`. Its PATCHED puts the inserter's overlays back, then point and the cursor on the cursor's row and
  column (`cursor-type` from the shape: block `box`, hollow `hollow`, bar `(bar . 2)`, underline `(hbar . 2)`; not
  visible: nil). A cursor past the row's last character (trailing blanks are not sent) is drawn by an overlay's
  `after-string` of blanks whose last carries `cursor`.
- **Theme:** a theme enabled or disabled repaints every terminal from the faces (`drgnx-view-patch-repaint`): rows
  keep their keys, nothing goes to the hub.
- **Scrollback:** `drgnx-term-scrollback-lines`'s `:apply` sends `term/config` `scrollback-lines` to every worker,
  which removes the oldest rows or backfills; window-start reaching the buffer's top sends `term/fetch` with the first
  row's key (one at a time; not again for the same top row once the worker said nothing is missing).
- **Input:** `term/key` from `drgnx-term-send-event` (`drgnx-term--event-key`: the event's base key, its modifiers
  and the text a printable key types) and `term/text` (`drgnx-term-send-string`). `drgnx-term-mode-map` binds every
  raw key (control, meta, the named keys) to `drgnx-term-send-event`; `drgnx-term-apply-keys` takes out the keys the
  active profile keeps for drgnx (`drgnx-terminal-key-split`, with `drgnx-term-reserved-keys`), on every key-stack
  change. `term/paste` sends the kill ring's newest entry (bracketed by the engine when the program asked).
- **Mouse:** the mouse bindings are menu-item filters that answer only while the patch's `term` says
  `mouse_tracking`; then `term/mouse` carries the cell (`drgnx-term--mouse-cell`: the screen row counts from the
  buffer's last `rows` lines). Focus changes (`window-selection-change-functions`, buffer-local) send `term/focus`.
- **Copy mode** (`drgnx-term-copy-mode`) pauses the view (`drgnx-view-patch-pause`) and swaps in a map with only
  `C-g`; leaving draws the kept patches. `drgnx-term-find` sends `term/search` up from the cursor and enters copy mode
  at the first match, marked by the face `drgnx-term-search-selected`.
- **Links:** the worker sends an OSC 8 run as the row prop `drgnx-term-link` (screen rows only: backfilled rows carry
  none); PATCHED gives such runs `mouse-face` and a keymap, and `drgnx-term-open-link` opens a local `file://` URI with
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
- **Quitting:** `drgnx-term-running` is on core's `drgnx-session-running-functions`: it asks `term/list` (at most
  `drgnx-term-list-wait`, 0.2 s, through `drgnx-hub-call-sync`) and names the open terminals whose program runs; no
  answer names them all. `kill-emacs-hook` sends `term/session-end`, so a clean quit ends this session's terminals.
- **Callers:** Export and Import Keys run `drgnx secrets` through `drgnx-term-start` (else `term`); the key sheet's
  "In the terminal" section is on core's `drgnx-surfaces-cheatsheet-sections`; `drgnx-term-mode` is an input mode for
  the modal engines and Close Pane, and the panel's Terminal tab takes its buffers.

**Tests:** `test/unit/term-test.el` (`drgnx-term/`, a gated hub with the real worker: the shell in a worker, echo,
a flood backfilled, the scrollback setting both ways, undo off, input queued while the hub is away, a theme change
without a reset, a tty frame) and the GUI rows `test/ui/term-gui-test.el` (`drgnx-term-gui/`: wide cells align,
cursor shapes).

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
