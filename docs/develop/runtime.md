# The runtime workspace and the conformance harness

`runtime/` is drgnx's Rust workspace: Ratatoskr, the agent runtime, and the crates it is built from. Everything else in
drgnx is Emacs Lisp; Rust lives only here. Until prebuilt binaries exist, install.sh and `drgnx update` build it from
source.

## The workspace

```
runtime/
  Cargo.toml        workspace: members = ["conformance", "crates/*"], exclude = ["fuzz"], resolver 3
  Cargo.lock        committed; every build is --locked
  deny.toml         the supply-chain policy (cargo deny check)
  conformance/      drgnx-conformance, the harness below
  crates/           the runtime's crates (one directory each)
  fuzz/             cargo-fuzz targets: its own workspace, nightly only
```

- **MSRV 1.88**, edition 2024, `license = "GPL-3.0-or-later"` on every crate of ours. There is no
  `rust-toolchain.toml`: distro cargo ignores it.
- **Dependencies** are declared once in `[workspace.dependencies]`; a crate writes `x.workspace = true`. A new
  dependency needs a line in its commit message saying which job it does and what it adds to `cargo tree`.
- **Release profile:** `strip = true`, `lto = "thin"`, `panic = "unwind"` (a panicking task must not end every
  session).
- **`cargo deny check`** runs all four sections (advisories, licenses, bans, sources) on every push and daily. `deny.toml`
  bans OpenSSL and native-tls (one TLS stack), async-std and smol (one runtime), `h2` (HTTP/1.1 only) and `aws-lc-sys`
  (the ring provider), and denies yanked, unmaintained and unsound crates; an exception is an explicit, dated `ignore`.

### Crate names

| Name | What it is |
|---|---|
| `drgnx-ratatoskr` (binary `ratatoskr`, symlink `rtsk`) | the runtime: the hub protocol's server |
| `drgnx-proto` | the hub protocol's contract: wire types, strict lines, typed decode, proofs, paths ([below](#drgnx-proto-the-contract)) |
| `urdr` | the SQLite store; self-contained, its public API names no drgnx type |
| `gleipnir` | the sandbox; self-contained |
| `hrafn` | search and the indexer |
| `drgnx-conformance` | the conformance harness (this page) |

The protocol is still called "the hub protocol", and the socket, cap and lock files keep their `hub-HASH.*` names.

### Building

Build only with `--locked`, and cap the build's memory and jobs on a small machine (a build that is not capped has run a
machine out of memory):

```bash
cargo build --locked --manifest-path runtime/Cargo.toml -j 2
cargo test  --locked --manifest-path runtime/Cargo.toml -j 2
cargo fmt   --manifest-path runtime/Cargo.toml --check
cargo clippy --locked --manifest-path runtime/Cargo.toml --all-targets -- -D warnings
cargo deny  --manifest-path runtime/Cargo.toml check
```

Only `Cargo.lock` regeneration (`cargo generate-lockfile`, `cargo update -w`) runs without `--locked`.

## drgnx-proto: the contract

`crates/drgnx-proto` holds what the hub protocol is on the Rust side; the server, the client half and the tests share it.

- **`wire`**: `Request {id?, method, params}` (`params` is `{}` when absent; no `id` makes a notification), `Answer {id,
  result, ignored?}` (`ignored` left out when empty), `ErrorAnswer {id, error}`, `Error {code, message, path?}` and
  `Event {event, data}`. An `Id` is a number or a string. The codes are `no-method`, `not-allowed`, `proto`,
  `invalid-params`, `schema` and `internal`. Not JSON-RPC: no `jsonrpc` key.
- **`line`**: a client line is at most `MAX_CLIENT_LINE` (1 MiB) and `codec()` enforces it (a longer line is an error,
  and the connection is closed); a hub line is at most `MAX_HUB_LINE` (16 MiB). `parse_strict` refuses a duplicate key at
  any depth, nesting deeper than 64 (the top object is depth 1) and anything but an object at the top. Its `LineError`
  carries the path (`params.env[1].k`) and the line's `id` when it can be read: the top-level `id` of a line that is JSON
  (duplicates and depth aside), else the Lisp hub's rule (the first `"id": <digits>` followed by `,` or `}`), so the
  sender gets an `invalid-params` answer instead of waiting.
- **`decode`**: `typed::<T>(&params)` decodes through `serde_path_to_error` around `serde_ignored`. It returns the value
  and the keys `T` has no field for, as paths (`env[0].x`), which become the answer's `ignored`. A value that does not
  fit is `invalid-params` with the path of the part that did not; a field missing at the top has no path.
- **`proof`**: `Cap` is 32 random bytes as 64 lowercase hex, kept in a `secrecy` string (no `Debug`, zeroed on drop);
  `Cap::read` refuses a file over 256 bytes or one that is not exactly 64 lowercase hex. `nonce()` is 16 random bytes as
  32 hex. The client proves `HMAC-SHA256(cap, "drgnx-hub client " + hub_nonce + " " + client_nonce)` and the hub
  `HMAC-SHA256(cap, "drgnx-hub hub " + client_nonce + " " + hub_nonce)`, keyed with the cap's 64 hex characters as ASCII
  (as the Lisp `drgnx-hub-hmac`). `verify` decodes both proofs to 32 bytes (a malformed one, uppercase included, is never
  valid) and compares the bytes in constant time (`subtle`).
- **`paths`**: `data_dir`, `socket_path`, `cap_path` (`hub-HASH.cap`), `lock_path` (`hub-HASH.sock.lock`) and
  `backend_socket_path`, the Lisp backend's private socket `<socket dir>/hub-HASH.d/backend.sock` (one per data dir, so
  two data dirs sharing a runtime dir never collide). Over 103 bytes it goes to `<tmp>/drgnx-hub-UID/hub-HASH.d/`, and
  past 103 bytes there too it is `PathError::TooLong`. `private_dir` makes a directory 0700 (parents too) when it is not
  there, refuses one that is a link, not a directory or another user's, and chmods it 0700 through the descriptor it
  checked (opened with `O_NOFOLLOW`), as the Lisp `drgnx-hub--private-dir` does.

`cargo test -p drgnx-proto` runs the unit tests (RFC 4231 case 2 for the HMAC, the socket fixture below), a
compile-fail doc test that `Cap` has no `Debug`, and the proptest `tests/proptest_line.rs`: random byte streams, read in
random pieces, through the codec and `parse_strict` never panic, and the codec never holds more than one line's limit
plus the read that went past it.

## The conformance harness

`drgnx-conformance` runs **scenarios** (data) against a hub binary: a process that answers the hub protocol on its socket.
Every scenario gets fresh temporary roots under `/tmp/rtsk-XXXXXX/` (`/tmp`, not `$TMPDIR`, so macOS socket paths stay
short) holding `home run state data config cache tmp`, and the hub's `HOME`, `XDG_*`, `DRGNX_DATA_DIR`,
`DRGNX_CONFIG_DIR` and `TMPDIR` point there. A hub is started with `--parent-pid` of the harness, so it ends with the
test, and `RATATOSKR_SUPERVISOR=none` keeps a supervisor out of it. Only `PATH` and `DRGNX_EMACS` are inherited.

```
drgnx-conformance --target lisp|ratatoskr --hub-bin PATH --scenarios DIR
                  [--lisp-hub PATH] [--fake-backend PATH]
                  [--only GLOB] [--only-tag TAG] [--require-all] [--perf OUT.json]
drgnx-conformance connect-as --socket PATH
```

- `--target lisp` runs only the `v0` rows, against the Lisp hub (through `test/conformance/lisp-hub.sh`, which maps
  `serve --foreground --parent-pid PID` to `emacs --batch -Q -L core -l drgnx-hub -f drgnx-hub-main` using
  `$DRGNX_EMACS`). `--target ratatoskr` runs every row, the `v0` ones too: they must pass both ways.
- `--lisp-hub` and `--fake-backend` are what a `lisp-backend` / `fake-backend` row hands Ratatoskr as
  `DRGNX_RATATOSKR_BACKEND`.
- `--only GLOB` matches the scenario name (`*` and `?`); `--only-tag TAG` the rows that require the tag.
- Output: one `PASS name`, `SKIP name (reason)` or `FAIL name: step N (VERB): what` line per scenario, then
  `N passed, N skipped, N failed`. Exit 0 only with no FAIL. With `--require-all` a SKIP fails too, except `linux` /
  `macos` skips on the other host and `sudo` skips where neither root nor passwordless sudo exists.
- `--perf OUT.json` runs the `perf` rows and writes every `measure` step's timings to the file.
- `connect-as` connects to the socket and relays stdin and stdout over it: the other-uid connection runs it as
  uid 65534 (`setpriv` as root, else `sudo -n -u nobody`; `$SUDO` names the sudo command).

### The scenario format

A scenario is one file, `test/conformance/<group>/<name>.jsonl`. Line 1 is the header

```json
{"scenario": "<group>/<name>", "requires": ["v0"], "doc": "what this row pins"}
```

Every other line is a step `{"do": VERB, ...}`. Steps are numbered from 1 in failure messages.

**Tags** (`requires`): `v0` (any hub), `v1` (hello v1: Ratatoskr), `fake-backend`, `lisp-backend`, `sudo` (euid 0, or
`sudo -n true` succeeds), `test-hooks` (the binary's `version --json` says `"test_hooks": true`), `linux`, `macos`,
`perf`. A row whose requirement is missing is skipped (with `--target lisp`, rows without `v0` are not selected at all).

| VERB | Keys | Meaning |
|---|---|---|
| `start` | `hub` (a name, default `hub`), `bin` (`"under-test"` or `"lisp"`), `args`, `env`, `same_root_as`, `wait` | start `BIN serve --foreground --parent-pid <harness pid> ARGS` in a fresh root (or another hub's root); with `wait` (default true) it waits up to 10 s until `ping` answers; `wait: false` is for a start expected to exit |
| `run` | `capture`, `bin`, `args`, `env`, `hub`, `expect_code`, `expect_stdout` | run `BIN ARGS` to completion (30 s) in the hub's root: `ensure`, `stop`, `status`. The capture is `{stdout, code, json}`; `expect_stdout` is a string the output contains or a pattern for its JSON |
| `spawn` | `capture`, `argv` | start a helper (for example `sleep 60`); the capture is its pid, and `NAME_start` its start time. Killed when the scenario ends |
| `connect` | `conn` (default `c`), `hub`, `socket` (`"main"` or `"agent:SID"`), `as` | open a connection; lines are buffered per connection. `"user"` (default) on a v1 target performs the `hello` macro with a valid proof and consumes the `challenge`; on `--target lisp` it does nothing. `"service"` connects raw (the `challenge` stays buffered). `"other-uid"` needs `sudo`: it runs `connect-as` as another uid, and makes the root directory 0711 for it |
| `hello` | `conn`, `proof`, `proto`, `expect_class`, `expect_error`, `capture` | the v1 macro: read the `challenge`, send `hello` with the proof, check the class and, for `valid`, the hub's proof. `proof` is `valid`, `wrong`, `none` or `replay:NAME`. `capture: NAME` keeps the line it sent; `replay:NAME` sends such a line again, as is. `expect_error: CODE` wants the refusal with that code |
| `chmod` | `path`, `mode` | change a mode (octal string) |
| `send` | `conn`, one of `json`, `raw`, `bytes` | write one line. `raw` is the text as is, plus `\n` unless `"no_newline": true`; `bytes` is `{fill, n, newline}`. A write the hub closed meanwhile is no error: the next `expect_closed` says so |
| `expect` | `conn`, `json` (pattern), `within_ms` (5000) | the first buffered or arriving line that matches; earlier non-matching lines stay buffered |
| `expect_next` | as `expect` | the very next line must match |
| `expect_closed` | `conn`, `within_ms` | the hub closed the connection |
| `expect_silent` | `conn`, `for_ms` (300) | no line arrives |
| `kill` | `hub` or `pid`, `signal` (`TERM KILL STOP CONT INT HUP QUIT USR1 USR2`) | signal the hub (or a captured pid) |
| `expect_exit` | `hub` or `pid`, `code`, `signal`, `within_ms` (10000) | the process ended with this status (a `pid` must be one the scenario spawned) |
| `file` | `path`, `exists`, `mode`, `owner` (`"user"` or a uid), `json` | inspect a file the contract names |
| `write_file` | `path`, `text` | set up an input |
| `sqlite` | `path`, `sql: [...]` | set up a database (bundled SQLite) |
| `backend_log` | `hub`, `expect_line`, `expect_no_line`, `within_ms`, `for_ms` | lines the fake backend received (`$STATE/fake-backend.log`): a substring, or a pattern for lines that are JSON |
| `pid` | `capture`, `alive` (true), `within_ms` (5000) | a captured pid is (or is no longer) running; a reused pid does not count |
| `class_matrix` | `table` | generated checks over the class table: the reader arrives with the hello task |
| `bad_params` | `registry` | generated checks over the registry: the reader arrives with the registry task |
| `measure` | `name`, `repeat`, `steps` | times the steps, `repeat` times, and records the milliseconds for `--perf` |

**Variables** in strings: `$ROOT $HOME $RUN $STATE $DATA $CONFIG $SOCKET $SOCKET_DIR $CAP $LOCK $PID(hub) $HARNESS_PID`
(of the step's `hub`, else the latest started), and `$NAME` for a capture. A string that is just `$PID(hub)`,
`$HARNESS_PID` or a capture keeps its JSON type (a number stays a number). Agent sockets are
`$SOCKET_DIR/hub-HASH.d/agent-SID.sock`.

**Patterns** are JSON. An object matches when it has every key of the pattern (extra keys are fine). Arrays match element
by element and in length, unless the pattern is `{"$contains": [...]}` (every listed pattern matches some element).
Special strings: `"$any"`, `"$string"`, `"$number"`, `"$hex64"`, `"$absent"` (the key must be missing), `"$capture:NAME"`
(matches anything, remembers it) and `"$NAME"` (equal to the value captured earlier).

**The `hello` proofs** are computed by the harness itself, with its own HMAC-SHA256: the client proof is
`HMAC(cap hex as ASCII, "drgnx-hub client " + hub_nonce + " " + client_nonce)` and the hub's is
`HMAC(cap, "drgnx-hub hub " + client_nonce + " " + hub_nonce)`, both as lowercase hex. The cap is read from
`hub-HASH.cap`, beside the socket.

### Where the socket is: one fixture for Lisp and Rust

The data directory and the socket path follow Lisp's `drgnx-paths-dir 'data` and `drgnx-hub-socket` exactly
(`crates/drgnx-proto/src/paths.rs` and, until it switches to that module, `conformance/src/paths.rs` are the Rust side): only an absolute environment value counts; names are normalised as Emacs's
`expand-file-name` does it, oddities kept (`/a/../../b` is `/../b`, `//a` stays `//a`); `sha1` of the data directory
(with its trailing `/`), cut to 8 hex digits, names `hub-HASH.sock`; it is under `$XDG_RUNTIME_DIR/drgnx/` when that is a
directory, else under `<state>/hub/`; a path over 103 bytes goes to `<tmp>/drgnx-hub-UID/`, where `<tmp>` is the first
of `TMPDIR`, `TMP`, `TEMP` that is set, else `/tmp` (Emacs's `temporary-file-directory`). A relative value is out of
scope.

`test/fixtures/hub-socket-cases.json` holds cases `{env, data_dir, socket}` (`$UID` stands for the uid); the Lisp test
`drgnx-hub-socket-cases/lisp-agrees-with-the-fixture` and the Rust tests `paths::tests::socket_cases_fixture` (in the
harness and in `drgnx-proto`) all read it. To add a case, run the Lisp side to measure it and put the result in; never write an expected value by hand.

### Testing the harness

`cargo test -p drgnx-conformance` covers the parser, the matcher, the paths, the proofs and, in `tests/harness.rs`, whole
runs against a scripted hub (a small hub inside the test binary). `test/conformance/self/*.jsonl` are the harness's own
rows: they are valid against any hub, so they also run against the Lisp hub.

### The v0 rows

The rows with `"requires": ["v0"]` pin what every hub does, today's Lisp hub and Ratatoskr alike. Each `connect` takes the
default `"as": "user"`, so the same rows run through Ratatoskr's front once it exists.

| Group | Rows |
|---|---|
| `framing/` | `one-object-per-line`, `line-over-1-mib-closes`, `malformed-line-with-id-gets-an-error`, `malformed-line-without-id-is-dropped` |
| `basics/` | `ping`, `status-shape`, `agents-list-empty`, `shutdown-ends-the-hub`, `a-second-hub-exits-3` (a second hub on the same data dir exits 3) |
| `events/` | `since-shape`, `subscribe-relays-events` (a proposed then stopped job: its event's `data` is a JSON object, from `events/since` and as an `events` event) |

Run them against the Lisp hub (Emacs from `$DRGNX_EMACS`, else `emacs` on `PATH`):

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-conformance
runtime/target/debug/drgnx-conformance --target lisp --hub-bin test/conformance/lisp-hub.sh --scenarios test/conformance
```

Green is 11 `PASS` for these rows (plus the 2 `self/` rows). In CI the `conformance-lisp` step runs this in the Linux job
(Nidhogg from `test/container/nidhogg.sh fedora-45`) and the macOS job (`nidhogg.sh macos`, which sets `DRGNX_EMACS`).
