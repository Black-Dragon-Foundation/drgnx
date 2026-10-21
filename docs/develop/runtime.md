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
| `drgnx-proc` | spawning (explicit environments, own process groups, one exit) and the orphan reaper ([hub.md](hub.md#ratatoskrs-children-drgnx-proc)) |
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
- **`registry`**, **`methods`**, **`types`**, **`events`**: every method with its classes, typed params and result,
  `writes` flag and doc; the named input types; the event types. `runtime/protocol/methods.json` and the method table
  in `docs/develop/hub.md` are generated from them and checked by tests. See
  [hub.md, "The registry"](hub.md#the-registry-protocol-v1).

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
`DRGNX_CONFORMANCE_ROOTS=DIR/PREFIX` makes the roots `DIR/PREFIXXXXXXX/` instead. Keep DIR short: the socket path
must stay within 103 bytes.

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
  `DRGNX_RATATOSKR_BACKEND`; with `--target ratatoskr`, a `v0` row gets the Lisp hub as its backend too, so the v0 rows
  run through the front (`--target ratatoskr --lisp-hub test/conformance/lisp-hub.sh --only-tag v0`). A row with
  neither runs with the backend `missing` (the harness sets no `DRGNX_DIR`).
- **The fake backend** (`runtime/target/debug/ratatoskr-fake-backend`, `conformance/src/bin/`) stands in for the
  Lisp backend: it serves `DRGNX_HUB_SERVE_SOCKET` the v0 way, appends every line it gets to
  `$STATE/fake-backend.log` and writes its environment as a JSON object to `$STATE/fake-backend.env`. It answers from
  the JSON script in `DRGNX_FAKE_BACKEND_SCRIPT` (a row's `start` `env`): `{METHOD: ANSWER}`, ANSWER an object with
  `result` or `error` (sent with the request's id), a string (the whole line, `$ID` the id), `null` (never
  answered) or `{"exit": CODE}` (it exits). Without a script: `ping`, `status` (`gateway_port` and `registrations`
  0), `subscribe` and `coord/notify` answer, anything else is an error. When the script's `trigger` method
  (`coord/notify`) is called, it sends its subscribers the events of the file `events` (a JSON array of `{event,
  data}`), then `flood` `card` events with a title of `flood_size` bytes (65536). It ends with its parent
  (`DRGNX_HUB_PARENT_PID`) unless the script says `"ignore_parent": true`.
- `--only GLOB` matches the scenario name (`*` and `?`); `--only-tag TAG` the rows that require the tag.
- Output: one `PASS name`, `SKIP name (reason)` or `FAIL name: step N (VERB): what` line per scenario, then
  `N passed, N skipped, N failed`. Exit 0 only with no FAIL. With `--require-all` a SKIP fails too, except `linux` /
  `macos` skips on the other host and `sudo` skips where neither root nor passwordless sudo exists.
- `--perf OUT.json` runs the `perf` rows and writes every `measure` step's timings to the file.
- `connect-as` connects to the socket and relays stdin and stdout over it: the other-uid connection runs it as
  uid 65534 (`setpriv` as root where util-linux has it, else `sudo -n -u nobody`; `$SUDO` names the sudo command).

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
| `hello` | `conn`, `proof`, `proto`, `expect_class`, `expect_error`, `expect_result`, `capture` | the v1 macro: read the `challenge`, send `hello` with the proof, check the class and, for `valid`, the hub's proof. `proof` is `valid`, `wrong`, `none` or `replay:NAME`. `capture: NAME` keeps the line it sent; `replay:NAME` sends such a line again, as is. `expect_error: CODE` wants the refusal with that code; `expect_result` is a pattern for the reply. A connection is challenged once: a second `hello` on it uses the nonce the first one read |
| `chmod` | `path`, `mode` | change a mode (octal string) |
| `send` | `conn`, one of `json`, `raw`, `bytes` | write one line. `raw` is the text as is, plus `\n` unless `"no_newline": true`; `bytes` is `{fill, n, newline}`. In `json`, `{"$repeat": TEXT, "times": N}` is TEXT N times (a long string without a long row). `"eof": true` then closes the sending side (a client that vanished mid-line). A write the hub closed meanwhile is no error: the next `expect_closed` says so |
| `pause` | `conn` | stop reading the connection (what arrives stays in the socket): a client that stopped reading. The next step that reads it reads again |
| `expect` | `conn`, `json` (pattern), `within_ms` (5000) | the first buffered or arriving line that matches; earlier non-matching lines stay buffered |
| `expect_next` | as `expect` | the very next line must match |
| `expect_closed` | `conn`, `within_ms` | the hub closed the connection |
| `expect_silent` | `conn`, `for_ms` (300) | no line arrives |
| `kill` | `hub` or `pid`, `signal` (`TERM KILL STOP CONT INT HUP QUIT USR1 USR2`) | signal the hub (or a captured pid) |
| `expect_exit` | `hub` or `pid`, `code`, `signal`, `within_ms` (10000) | the process ended with this status (a `pid` must be one the scenario spawned) |
| `file` | `path`, `exists`, `mode`, `owner` (`"user"` or a uid), `json`, `contains`, `lacks`, `within_ms` (5000) | inspect a file the contract names. A `*` or `?` in the last component picks the first matching name (`hub-*.jsonl`). `contains` waits up to `within_ms` until the file's text holds the string (a log is written a moment later); `lacks` is a string the text must not hold |
| `write_file` | `path`, `text` | set up an input |
| `sqlite` | `path`, `sql: [...]`, `query`, `expect` | set up a database (bundled SQLite); `query`'s rows, as `[[value…]…]`, must match the pattern `expect` |
| `backend_log` | `hub`, `expect_line`, `expect_no_line`, `within_ms`, `for_ms` | lines the fake backend received (`$STATE/fake-backend.log`): a substring, or a pattern for lines that are JSON |
| `pid` | `capture`, `alive` (true), `within_ms` (5000) | a captured pid is (or is no longer) running; a reused pid does not count |
| `class_matrix` | `table`, `args`, `env`, `agent`, `last`, `within_ms` | every method of `table` (`{method: [classes]}`, `class-matrix.json`) gets `{}` from `user` (a valid hello), `service` (no hello) and, with `agent: SID`, `agent` (that session's socket, which `args` such as `["--agent-socket", "s1:j1"]` makes the hub serve). A listed class must not get `not-allowed`; any other must. The step starts its own hubs with `args` and `env`: one for the table, and for each method of `last` (default `restart`, `shutdown`, which a user call runs) one per class |
| `bad_params` | `conn`, `registry`, `within_ms` | every method of the registry file (`methods.json`; a relative path is from the current directory) with required params gets `{}` and a wrong type for its first required key (`true` where a list belongs, else `[]`) on `conn`; each must be `invalid-params` with a `path` (one of the required keys, then that key). `hello` goes on a fresh connection each time |
| `measure` | `name`, `repeat`, `steps` | times the steps, `repeat` times, and records the milliseconds for `--perf` |

**Variables** in strings: `$ROOT $HOME $RUN $STATE $DATA $CONFIG $SOCKET $SOCKET_DIR $BACKEND_SOCKET $CAP $LOCK $PID(hub)
$HARNESS_PID` (of the step's `hub`, else the latest started), `$SCENARIOS` (the scenarios' directory, absolute: its
`fixtures/`), `$EMACS` (`$DRGNX_EMACS`, else `emacs`), and `$NAME` for a capture. A string that is just `$PID(hub)`,
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

Green is 11 `PASS` for these rows (plus the 2 `self/` rows).

### Ratatoskr's server-core rows

`v1` rows (Ratatoskr only) pin the server core ([hub.md](hub.md#the-control-socket)):

| Group | Rows |
|---|---|
| `framing/` | `a-partial-line-then-eof-closes-only-that-connection` |
| `basics/` | `two-hundred-connections-each-get-an-answer` |
| `lifecycle/` | `socket-dir-0700-cap-0600`, `sigterm-removes-socket-and-cap`, `parent-pid-gone-ends-the-hub`, `a-newer-runtime-db-is-moved-aside`; with `lisp-backend` (a Lisp hub started through `--lisp-hub`): `a-live-lisp-hub-makes-ratatoskr-exit-3`, `a-busy-lisp-hub-is-not-taken-over` (stopped with SIGSTOP), `a-stale-lisp-lock-directory-is-taken-over`, `a-lisp-lock-naming-another-program-is-taken-over` |
| `security/` | `another-uid-is-refused` (`sudo`: as root in the Fedora 45 test image, or through passwordless sudo on macOS) |

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p drgnx-conformance --features drgnx-ratatoskr/test-hooks
cargo test  --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr --features test-hooks
runtime/target/debug/drgnx-conformance --target ratatoskr --hub-bin runtime/target/debug/ratatoskr \
    --lisp-hub test/conformance/lisp-hub.sh --scenarios test/conformance --only 'lifecycle/*'
```

`tests/server.rs` starts the real binary in roots under `$TMPDIR`. It covers two hubs on one lock (the second exits
3), the cap (64 hex, 0600, gone after SIGTERM, never in the log) and the lock file's `PID START_TIME`. With
`test-hooks` it also covers a reader that stops while a `__test_flood` of 32 MiB comes. That reader is dropped past
16 MiB while another reader gets every line. In CI the `conformance-lisp` step runs this in the Linux job
(Nidhogg from `test/container/nidhogg.sh fedora-45`) and the macOS job (`nidhogg.sh macos`, which sets `DRGNX_EMACS`).

### The v1 rows

Rows with `"requires": ["v1"]` run only against Ratatoskr (`--target ratatoskr`):

| Group | Rows |
|---|---|
| `params/` | `bad-params-are-refused-with-a-path` (`bad_params` over `runtime/protocol/methods.json`), `named-types-refuse` (ids, absolute local paths, a 17-item `env/set`, an uppercase nonce: each `invalid-params` with its path), `duplicate-key-refused`, `unknown-keys-dropped-and-listed` |
| `hello/` | `challenge-on-accept`, `valid-proof-makes-user-and-hub-proves`, `wrong-proof-refused-and-logged`, `replayed-hello-is-refused` (SB-T12-6), `no-hello-is-service`, `newer-proto-refused`, `a-second-hello-is-refused`; with `test-hooks`: `an-agent-socket-is-agent-class` |
| `class/` | `matrix` (`test-hooks`: `class_matrix` over `class-matrix.json`, the agent class through `--agent-socket s1:j1`) |
| `errors/` | `every-error-has-a-code` (each code but `schema`; a refused notification gets no answer; `internal` from a fake backend's answer that does not fit) |
| `readonly/` | `a-newer-work-db-refuses-writes` (work.db at schema 9: `schema` for a writing method within the 2 s tick) |
| `basics/` | `status-shape-v1`, `events-since-without-a-work-db`, `events-since-from-the-store` (rows written into work.db with `sqlite`) |
| `forward/` (`fake-backend`) | `a-raw-duplicate-key-never-reaches-the-backend`, `a-tramp-path-never-reaches-the-backend`, `params-are-re-encoded-with-the-caller`, `a-malformed-backend-answer-is-internal`, `keys-only-from-a-proven-user`, `the-backend-gets-no-provider-key`, `the-backend-keeps-ssh-and-proxy-env`, `the-backend-gets-the-serve-socket-only`, `events-are-relayed-and-decoded`, `every-backend-event-kind-is-relayed` (`fixtures/backend-events.json`: one event of each of the nine kinds, as main sends it), `a-malformed-backend-event-is-dropped`, `backend-gone-calls-fail-once-and-it-restarts`, `an-oversized-forward-is-refused`; with `test-hooks` too: `agents-list-is-shaped-per-class`, `spend-is-own-job-for-an-agent` |
| `forward/` (`lisp-backend`) | `empty-lists-are-arrays` (A-17), `results-match-schemas` (a populated store: a proposed job, a review card, a mock-acp session with entries; every read method answers without `internal`) |
| `backpressure/` (`fake-backend`) | `a-stopped-reader-is-dropped-others-keep-going` (the backend floods 400 events of 64 KiB; a subscriber that `pause`d is closed, another gets every event) |
| `reaper/` | `a-recorded-orphan-backend-is-killed-at-start` (`fake-backend`: the hub SIGKILLed, its backend ignoring its parent; the next hub kills it within 4 s), `a-row-without-a-pid-is-dropped-and-kills-nothing` (NULL rows in `runtime.db`: removed, nothing signalled) |

The forwarding rows run with both helpers:

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p drgnx-conformance --features drgnx-ratatoskr/test-hooks
runtime/target/debug/drgnx-conformance --target ratatoskr --hub-bin runtime/target/debug/ratatoskr \
    --lisp-hub test/conformance/lisp-hub.sh --fake-backend runtime/target/debug/ratatoskr-fake-backend \
    --scenarios test/conformance
```

Paths: the agent sockets are `<root>/run/drgnx/hub-HASH.d/agent-SID.sock`, so with `DRGNX_CONFORMANCE_ROOTS` the
root's own path must leave room for them within 103 bytes (a short link to a deeper directory works).

`test/conformance/class-matrix.json` is not a row: it is the hand-written class table (`{method: [classes]}`) that the
registry's test and the `class_matrix` step read.
