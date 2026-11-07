# The terminal

The terminal's engine is libghostty-vt, Ghostty's terminal library (MIT), linked statically into the `drgnx-term` worker
through the crate `runtime/crates/ghostty-vt-sys`. This page so far covers building the engine; the worker and the Lisp
side add their sections as they land.

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
