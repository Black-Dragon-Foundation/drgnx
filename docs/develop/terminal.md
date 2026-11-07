# The terminal

The terminal's engine is libghostty-vt, Ghostty's terminal library (MIT), linked statically into the `drgnx-term` worker
through the crate `runtime/crates/ghostty-vt-sys`. This page covers building the engine and the worker; the Lisp side
adds its sections as it lands.

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
