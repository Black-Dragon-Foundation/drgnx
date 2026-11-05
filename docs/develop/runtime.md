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
  conformance/      domr, the harness below
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
| `runstav` (formerly `drgnx-proto`) | the hub protocol's contract: wire types, strict lines, typed decode, proofs, paths ([below](#runstav-the-contract)) |
| `urdr` | the SQLite store; self-contained, its public API names no drgnx type. `urdr::graph` is the generic graph store of `work.db` schema 7 (the one writer, entities and links with history, walks, search, the read pool, backup, export, excise; [store.md](store.md)): kinds, link names and policy are the caller's |
| `draugr` (formerly `drgnx-proc`) | spawning (explicit environments, own process groups, one exit) and the orphan reaper ([hub.md](hub.md#ratatoskrs-children-draugr)); passed fds, the pinned spawner and the git runner ([below](#draugr-passed-fds-and-git)) |
| `gleipnir` | the sandbox: the spec and its validation, bwrap, Landlock, seccomp, Seatbelt, the relay and the CONNECT proxy; self-contained ([gleipnir.md](gleipnir.md)) |
| `eitri` | file access that never follows a link: opens pinned by fd, bounded reads, writes by rename, root-owned programs; generic, used by `gleipnir` and `draugr` ([below](#eitri-no-link-file-access)) |
| `gleipnir-escape` | test tooling, never shipped: the probe binary and the escape harness ([gleipnir.md](gleipnir.md), "Proving it") |
| `mimir` | a tools-only MCP server for both protocol eras (`initialize`, and the stateless 2026-07-28) and the bridge's redial; self-contained, pure Rust |
| `norn` | `work.db`'s coordination writer, its readers and the 16 coordination tools on `mimir` ([coordination.md](coordination.md)); drgnx's policy over `urdr::graph` (closed kinds and links, the personal-notes deny-list, scopes, grants, trust marking, projects), the schema 6 → 7 migration, the tracker and its tools ([store.md](store.md)); pure Rust but for urdr's bundled SQLite, so off the Android cross-check |
| `bifrost` | the gateway: admission, tokens, chain fallback, the SSE usage scanner, budget, the HTTP/1.1 upstream client over rustls; self-contained (certificate checks behind its default feature `platform-verifier`). Rust but for `ring`'s C and assembly, so its cross-checks stub the C compiler as urdr's do (below) |
| `hrafn` | search and the indexer |
| `hrafn-embed` | Hrafn's embedding side: the pinned model table, the model cache's checks and the built-in embedder; pure Rust, no C, builds for Android ("Hrafn" below) |
| `huginn` | a reader for the data subset of Emacs Lisp: literal values with byte spans, never evaluated, every reader macro refused; settings files and a serde deserializer (feature `serde`); generic ([settings.md](settings.md#the-data-subset)). `drgnx-ratatoskr` reads `settings.el` and the shipped `runtime-defaults.el` with it ([hub.md](hub.md#settings)) |
| `hermod` | an ACP client on `agent-client-protocol-schema`'s types and runstav's line codec (no SDK role framework): stamped updates, message ids, fork at a message, exactly-once exit; generic (agent system part 1, Task 1) |
| `saga` | the org folder's record formats (plans, ledgers, DEFERRED, the build board, `board.org`) parsed and rendered back byte-exact, turned into graph operations; pure, `pulldown-cmark` for Markdown (agent system part 1, Tasks 5, 6, 14) |
| `forseti` | the scheduler core: the job model, priority, admission, the memory cap and ladder, kill classes, expected times, placement and fairness; pure, `serde` only, shared by the hub, the runners and jobq ([forseti.md](forseti.md)) |
| `sleipnir` | the runner: the Linux machine probe and runner contract, the reservation files two schedulers share, the executor; its `linux` and `sync` features are blocking, never tokio, so jobq takes them ([sleipnir.md](sleipnir.md)) |
| `vegvisir` | the Work space's map core: its model (items in six layers, edges, chains, overlaps, needs-you) and its layout, stepped by typed events with effects out; pure, `serde` only ([work-space.md](work-space.md)) |
| `skuld` | test support, never shipped: every order of a pure core, and the one real-time wait Rust tests may use ([below](#every-order-skuld)); crates name it under `[dev-dependencies]` only |
| `heimdall` | the CDP broker's pure part: envelope parsing over `serde_json`'s `RawValue` (params never re-encoded), routing one browser connection between the agent and the hub by session owner, the refusal list, downloads, cleanup when the agent goes, and the pipe's NUL and frame codecs; no I/O, std and serde only, built for Android too ([hub.md](hub.md#the-cdp-broker)) |
| `domr` (formerly `drgnx-conformance`; lives in `runtime/conformance/`) | the conformance harness (this page) |

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

### Platforms

Linux and macOS are supported; Android is not a target, but the door stays open. Every `cfg(target_os)` gate names its
Android stance. Rust's Android target is `target_os = "android"`, not `"linux"`, so a Linux-kernel fact (`/proc`,
`SO_PEERCRED`, inotify) is gated `any(target_os = "linux", target_os = "android")`, and a desktop-distro fact (systemd,
bwrap) `target_os = "linux"` alone with the Android stance (a stub, or "unsupported") in a comment. Every `cfg` chain
ends in a fallback that returns `None` or `Unsupported`, never a missing item. Platform code sits in one module or
function per crate. The type-check (`rustup target add aarch64-linux-android` first) is
`cargo check --locked --manifest-path runtime/Cargo.toml --target aarch64-linux-android -p runstav -p draugr -p eitri -p gleipnir -p heimdall -p drgnx-ratatoskr`.
`drgnx-ratatoskr` depends on `urdr`, whose bundled SQLite is C, and compiling C for Android needs the NDK. A type-check
does not link, so without the NDK stub the C compiler and archiver: `CC_aarch64_linux_android=/usr/bin/true
AR_aarch64_linux_android=/usr/bin/true` (the Rust is still checked in full; only the C object files are fake).

## The hub since phase 7

There is no Lisp runtime. Ratatoskr is the whole server side, and the editor is its client ([hub.md](hub.md)):

- **One process, one writer.** The hub serves every method of the registry itself; no backend process sits behind it
  and nothing is forwarded. It is `work.db`'s only writer ([coordination.md](coordination.md#who-writes-what)), the
  owner of every agent session and the gateway.
- **The login shell's environment** reaches it as `env/set` (`shell_env.rs`): an overlay in the hub's memory that every
  process it starts next takes.
- **The editor's background jobs** (grammars, mermaid, the browser, local AI servers, onboarding installs) are the hub's
  `exec/*` jobs (`core/drgnx-exec.el` is the client); a server that stays up for days starts with `no_timebox`
  ([hub.md](hub.md#jobs-exec)).
- **At start** the hub reaps the process groups `runtime.db` recorded and moves what the Lisp runtime left in the state
  directory aside, once (`legacy::migrate`, [hub.md](hub.md#what-the-lisp-runtime-left)).
- **The doctor** has a `lisp-runtime` check (a Lisp hub still running, an outside agent's config that still starts the
  Lisp coordination server, old jobs still running, what waits in `hub/migrated-p7/`; [install.md](../guide/install.md))
  and reads the job sandbox's state from `ratatoskr doctor --json`.

## runstav: the contract

`crates/runstav` holds what the hub protocol is on the Rust side; the server, the client half and the tests share it.

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
- **`jsonrpc`**: the one JSON-RPC 2.0 module for ACP and MCP (not the hub protocol). `parse(line)` gives a `Message`
  (`Request`, `Notification`, `Result`, `Error`); invalid JSON is `-32700`, and a batch (removed in MCP 2025-06-18), a
  duplicate key (through `line::parse_strict`), a wrong `jsonrpc` or any other shape is `-32600`. `Pending<T>` holds
  outstanding client requests by id with deadlines; `resolve` and `expire` each remove an entry, so it ends once.
- **`text`**: the one sanitizer for user-visible text. `CONTROL` is the Lisp `drgnx-coord-control-chars`; `one_line`
  (runs of control characters and `\n\r\t` become one space, cut at N characters with `…`, `header` also drops `]` and
  `#`), `coord_line` (event summaries and card titles as the Lisp writer stores them: each control character a
  space, cut at N characters, no `…`), `cut` (the MCP tool-text rule; says whether it cut) and `agent_label` (`ext:KIND:…` is "outside agent
  (unverified) KIND").
- **`url`**: `check(url, schemes)` refuses `NAME::` transports, schemes outside the list (`user@host:path` is `ssh`, an
  absolute path `file`), control characters, a leading `-`, http(s) userinfo and a missing host. `provider_base` is the
  gateway's rule: `https`, or `http` on any host, with `clear_text` set off loopback; no fragment or userinfo.
- **`decode`**: `typed::<T>(&params)` decodes through `serde_path_to_error` around `serde_ignored`. It returns the value
  and the keys `T` has no field for, as paths (`env[0].x`), which become the answer's `ignored`. A value that does not
  fit is `invalid-params` with the path of the part that did not; a field missing at the top has no path.
- **`proof`**: `Cap` is 32 random bytes as 64 lowercase hex, kept in a `secrecy` string (no `Debug`, zeroed on drop);
  `Cap::read` refuses a file over 256 bytes or one that is not exactly 64 lowercase hex. `nonce()` is 16 random bytes as
  32 hex. The client proves `HMAC-SHA256(cap, "drgnx-hub client " + hub_nonce + " " + client_nonce)` and the hub
  `HMAC-SHA256(cap, "drgnx-hub hub " + client_nonce + " " + hub_nonce)`, keyed with the cap's 64 hex characters as ASCII
  (as the Lisp `drgnx-hub-hmac`). `verify` decodes both proofs to 32 bytes (a malformed one, uppercase included, is never
  valid) and compares the bytes in constant time (`subtle`).
- **`paths`**: `data_dir`, `socket_path`, `cap_path` (`hub-HASH.cap`) and `lock_path` (`hub-HASH.sock.lock`).
  `session_dir(env, socket, SID)` is one agent session's directory, `<socket dir>/s/SID/` (design §4.2): it holds
  that session's sockets, `hub.sock` (agent class) today and `mcp.sock`, `search.sock` and `gateway.sock` later; a
  sandbox is given `s/SID` alone (Gleipnir's run parent is `s/`). Over 103 bytes for its longest
  socket (`gateway.sock`) it is `<tmp>/drgnx-hub-UID/s/SID/`; a SID that is not letters, digits, `-` and `_` is
  `PathError::BadName`. `make_session_dir` makes the socket dir (or that `<tmp>` one), `s/` and `s/SID/` with
  `private_dir` and checks each with `trusted_dir`. `private_dir` makes a directory 0700 (parents too) when it is not
  there, refuses one that is a link, not a directory or another user's, and chmods it 0700 through the descriptor it
  checked (opened with `O_NOFOLLOW`), as the Lisp `drgnx-hub--private-dir` does.
- **`registry`**, **`methods`**, **`types`**, **`events`**: every method with its classes, typed params and result,
  `writes` flag and doc; the named input types; the event types. `runtime/protocol/methods.json` and the method table
  in `docs/develop/hub.md` are generated from them and checked by tests. See
  [hub.md, "The registry"](hub.md#the-registry-protocol-v1).

`cargo test -p runstav` runs the unit tests (RFC 4231 case 2 for the HMAC, the socket fixture below), a
compile-fail doc test that `Cap` has no `Debug`, and the proptest `tests/proptest_line.rs`: random byte streams, read in
random pieces, through the codec and `parse_strict` never panic, and the codec never holds more than one line's limit
plus the read that went past it.

## hermod: the ACP client

hermod speaks the Agent Client Protocol to one agent process (Claude Code's or Codex's ACP adapter, `gemini --acp`).
It is generic (no drgnx type) and sits on `agent-client-protocol-schema` (the types), runstav's `jsonrpc` and `line`
(the codec: lines of at most 1 MiB, a longer one is dropped) and draugr's `spawn` (own process group, bounded stderr
tail). There is no SDK role framework.

- **Tasks.** A connection is one child, a writer task (lines to its stdin), a reader task (lines from its stdout) and
  a watchdog that waits for the child. `Conn::spawn(spec, ConnOpts { deadline, stderr_tail })` returns the `Conn`
  (cheap to clone; dropping every clone closes the child's stdin) and the event receiver, which the owner drains
  (1024 events buffer).
- **Calls.** `initialize` (always without the `terminal` capability; `terminal/*` requests from an agent get -32601),
  `new_session`, `load_session`, `resume_session`, `close_session`, `set_mode`, `prompt`, `cancel`, `fork`. Every
  call except `prompt` has the connection's `deadline`: a missed one fails that call with `Error::Deadline`, and the
  connection keeps working. A `prompt` ends by the agent's answer, `cancel`, or the child's exit (`Error::Closed`).
  `PromptOutcome` carries the stop reason, the turn's token usage and `_meta.turnId` when the agent sends one.
- **Fork.** `fork(sid, Some(ForkPoint { message_id }))` sends `session/fork` with
  `_meta.jetbrains.air.fork {version: 1, messageId}`; without a point, a plain fork. The new session starts in the
  directory of the session it forks (the connection remembers the `cwd` of every session it opened or loaded).
- **Events.** `Update { at, sid, update, message_id }`: `at` is the receipt time in seconds since the epoch, taken
  when the line is read and never going backwards; `message_id` is the `messageId` of a message or thought chunk.
  `Request(Incoming)`: `Permission`, `ReadFile` or `WriteFile`, each with a `Responder`. A responder dropped
  unanswered answers -32800 "cancelled"; once the child has exited, `respond` fails with `Error::Closed` and
  `is_cancelled()` is true. `Exit { code, signal, stderr }` comes exactly once, after every update the child wrote
  (the reader gets two seconds to drain), with the last `stderr_tail` characters of stderr; calls still waiting fail
  with `Error::Closed`.
- Unknown notifications are ignored; unknown requests get -32601.
- **Tests.** `runtime/crates/hermod/tests/conn.rs` runs scripted `/bin/sh` children; the mock agent is
  `ratatoskr-mock acp`.

## eitri: no-link file access

`crates/eitri` is how the runtime touches a path someone else can change (an agent's tree, a candidate program):
every open refuses a link in any component and hands back the fd it checked, so what was checked is what is used.
It names no drgnx type or path. Every error is an `FsError`: `Link { path }`, `NotRegular`, `NotDir`, `TooLarge {
cap }`, `Escapes`, `Untrusted { path, why }`, `Unsupported` or `Io`.

- **`open_path(abs, kind)`** and **`open_beneath(dir, rel, kind)`** return a `Pinned { fd, dev, ino, is_dir }`.
  `kind` is `Dir`, `File` (a regular file) or `Any`, checked with `fstat` on the fd. Linux and Android use
  `openat2(O_PATH | O_CLOEXEC, RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)`, plus `RESOLVE_BENEATH` for
  `open_beneath`; macOS uses `open`/`openat` with `O_NOFOLLOW_ANY | O_NONBLOCK | O_NOCTTY`. A `rel` that is absolute
  or has a `..` component is `Escapes` before any syscall. A kernel without `openat2` (before 5.6, or one that
  refuses its flags) gives `Unsupported`: there is no fallback that resolves by path. Any other OS is `Unsupported`.
- **`read_regular(dir, rel, cap)`** opens `O_RDONLY | O_NONBLOCK | O_NOCTTY` with the same resolution, refuses
  anything but a regular file (a FIFO opens at once and is never read) and reads at most `cap + 1` bytes; one more
  than `cap` is `TooLarge`.
- **`write_regular(dir, rel, bytes, mode)`** opens the parent with `open_beneath`, creates `.eitri-<16 hex>` in it
  with `O_CREAT | O_EXCL | O_NOFOLLOW` and `mode` (at most 0o777, less the umask), writes, `fsync`s and `renameat`s
  it over `rel`. A link at `rel` is replaced, never followed; anything else that is not a regular file is
  `NotRegular`. The temporary file is removed on every error.
- **`trusted_program(candidates)`** returns the first candidate that only root can change, as a `TrustedProgram {
  path, dev, ino }`: an absolute path with no `.` or `..`, opened with `open_path`, a regular file with an execute
  bit, owned by uid 0 and not group- or world-writable, in directories up to `/` that are owned by uid 0 and not
  group- or world-writable (so never under `/tmp`). Otherwise the last candidate's `Untrusted { path, why }`.
  Callers pass fixed candidates (bwrap, `sandbox-exec`, git); `PATH` is never searched. A link in any component,
  the last one included, is refused even when root owns it: the candidates are the distributions' own regular files.
  Not every system program is one (Ubuntu 26.04's `coreutils-from-uutils` makes `/usr/bin/env` a link into
  `/usr/lib/cargo/bin/coreutils/`), so the tests that need a trusted program take `/usr/bin/env`'s resolved path.

`cargo test -p eitri` runs the unit tests (links in every component, `..` refused with no syscall made, a FIFO
refused within 100 ms, the cap, a write over a link, no temporary file left, `ENOSYS`/`EINVAL` from `openat2`
injected through a test seam, each `Untrusted.why`) and the proptest `tests/tree.rs`: random trees with links to
inside, outside and `/`, where every `Ok` is the `(dev, ino)` an `lstat` walk finds and every path through a link is
`Link`. The fixtures that need root-owned ancestors (`/var/lib/glp-…`) run as uid 0, as in the build container, and
are skipped otherwise.

## draugr: passed fds and git

`crates/draugr` starts and ends Ratatoskr's processes ([hub.md](hub.md#ratatoskrs-children-draugr)). For the sandbox it also
passes descriptors at fixed numbers, forks sandboxes from one pinned thread, and runs git.

**Passed descriptors.** `spawn::Spec` has `pass_fds: Vec<PassFd>`, each `PassFd { fd: Arc<OwnedFd>, target }`. The
child gets exactly 0–2 and the targets, in this order:

1. The targets are checked: each 3 or more, each once (else `InvalidInput`). In the parent, every source is copied
   with `fcntl(F_DUPFD_CLOEXEC, highest target + 1)`, so no `dup2` in the child overwrites a source it still needs.
2. Every free number from 3 to the highest target is held with a close-on-exec copy until the child is started.
   std reports a failed exec over a socket it opens just before the fork, at the lowest free number; on a target
   the child's `dup2` would close it, and a failed exec would look like a start. Another thread that closes a low
   descriptor during the spawn can still free a number for it. A failed exec then shows as a child that exits 1 at
   once, and std's 8 bytes go to the passed descriptor at that number. The callers fail closed on both (no status
   line from the helper).
3. In the child (`pre_exec`, no allocation): every descriptor from 3 up is marked close-on-exec, with
   `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` on Linux and Android. Before Linux 5.11, and on macOS, an
   `fcntl(F_SETFD, FD_CLOEXEC)` loop up to `RLIMIT_NOFILE` (at most 2^20) does it. Then each source is `dup2`'d to
   its target, and `dup2` clears close-on-exec on the copy. So a descriptor the hub inherited without close-on-exec
   (from systemd, launchd or Emacs) reaches no child. This holds for every spawn, not only those with `pass_fds`.

`spawn` consumes its `Spec` and drops the `PassFd`s once the child is started, so the parent keeps no copy of a pipe
end it waits on for EOF. Never keep a clone of a `Spec` that has `pass_fds`.

**`spawn_pinned`.** bwrap's `--die-with-parent` and the reduced helper's `PR_SET_PDEATHSIG` fire when the *thread*
that forked them exits. A spawn from a tokio blocking-pool thread would kill the sandbox when that thread retires.
`spawn_pinned` hands the spec to one thread, `draugr-spawner`, which is started on first use and lives as long as
the process. That thread enters the caller's runtime and spawns. If the caller stopped waiting, the thread kills the
child's group. Every sandboxed spawn goes through it; other spawns keep `spawn`.

**`new_session`.** A `Spec` with `new_session` starts its child with `setsid()` before exec instead of a process
group of its own (std's `setpgid` runs before `pre_exec`, and a group leader cannot `setsid`). Gleipnir's reduced
tier needs it: its helper starts a session itself (GL-T8-1). Either way the child's pid is its group's, so
`kill_group` ends it.

**git.**
- `git::git_program()` gives git from a root-owned path (`eitri::trusted_program`), never through `PATH`.
  - Linux: `/usr/bin/git`.
  - macOS: never the `/usr/bin/git` shim, which runs whatever developer dir is selected. It reads the link
    `/private/var/db/xcode_select_link`. That link and every directory up to `/` must be root's and not group- or
    world-writable. The program is then `<developer dir>/usr/bin/git`, which must pass `trusted_program`. The
    Command Line Tools pass; Xcode under the admin-writable `/Applications` is refused.
  - Any other OS (Android included): `Unsupported`.
- `git::command(&GitCall { place, allow_protocols, args })` returns the argv after the program, and the environment
  to add.
  - **The argv.** Every call starts with `-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c
    core.editor=false -c protocol.ext.allow=never`. `Place::Trusted { read_only: true }` adds
    `--no-optional-locks`. Then come `args`.
  - **The environment.** Every call gets `GIT_TERMINAL_PROMPT=0` and `GIT_ALLOW_PROTOCOL` (the protocols joined by
    `:`; `ext` is refused, since that variable overrides `protocol.ext.allow`). `Place::InSandbox` adds
    `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 HOME=/nonexistent
    GIT_LFS_SKIP_SMUDGE=1`. It never sets `DEVELOPER_DIR`, `TOOLCHAINS` or `SDKROOT`, and the caller's part of the
    environment must not either.
  - **Refused anywhere in `args`**, also as `--NAME=VALUE` and as any abbreviation git accepts (a prefix of the name,
    so `--text` too: use `-a`):
    - config: `-c`, `--config`, `--config-env`;
    - programs: `--textconv`, `--ext-diff`, `--extcmd`, `--upload-pack`, `--receive-pack`, `--exec`, `--exec-path`,
      `-O`, `--open-files-in-pager`;
    - files: `--output`, `--template`;
    - repository location: `--git-dir`, `--work-tree`, `-C` (they would bypass `check_trusted_repo`).
    A short letter is refused alone, with a value attached (`-Ovim`) or in a cluster (`-iO`).
  - **Refused after a subcommand:** `-u` after `clone`, `fetch`, `pull`, `ls-remote` or `archive`; `-x` after
    `rebase` or `difftool`.
  - **The rule for callers:** values that came from an agent go after `--`, or are checked as hex object ids. Phase 6
    may narrow this to an allowlist of the subcommands it uses.
- `git::check_trusted_repo(repo, in_ledger)` refuses `InLedger { path }` when any of these lies in a folder for which
  `in_ledger` is true (it is asked about the path and every folder above it):
  - the git dir: `repo/.git` as a directory, or what a `.git` file's `gitdir:` line names (read with `read_regular`,
    at most 4 KiB, relative to `repo`);
  - the common dir: what `<git dir>/commondir` names, or the git dir;
  - `config` and `config.worktree` in both, and every `<common dir>/worktrees/*/config.worktree`.
  Every path is opened without links, and a link anywhere is refused, since git would follow it. `..` is resolved by
  components, which is safe because no link was followed. A `gitdir:` line that looks like a remote
  (`/ssh:host:/x`) is just a missing path. Phase 6 passes the ledger.
  **What it does not hold (gate review S9, DEFERRED):** the check reads paths once, and git later opens them by path
  again, so an agent that can write the worktree could swap `.git` (a directory or a `gitdir:` file) in between. The
  repository's own config can still name programs the overrides above do not cover (`filter.*.clean`/`smudge`/
  `process`, `diff.*.command` and `textconv`, `diff.external`, `core.sshCommand`, `credential.helper`,
  `core.askPass`), and `status` and `diff` read each populated submodule's own config. So phase 6 must keep `.git`
  pinned (not writable by any agent) while agents run, and pick its trusted subcommands with this in mind; blanking
  those keys here would also drop the user's own global helpers for a trusted fetch.

`cargo test -p draugr` covers this:
- `spawn::tests`: three pipes at 3, 4 and 5, and at the sources' own numbers rotated; a parent fd without
  close-on-exec that the child never sees (the child lists its descriptors through `/dev/fd`); the passed fds
  dropped after the spawn; bad targets; a `setpriv --pdeathsig KILL` child that `spawn_pinned` started from a
  blocking-pool thread, alive 1.2 s after that thread retired.
- `tests/fds.rs`: a failed exec with targets 3–63 is still an error. It is its own test binary, so no other test
  frees a number during the spawn.
- `git::tests`: the argv, the environment, and a table of every refused form with controls. The macOS resolver also
  runs against a fixture under `/var/lib/glp-…`, as uid 0.
- `tests/git.rs`:
  - a planted `core.fsmonitor` and `post-checkout` hook run under plain git, the control, and never through
    `command`;
  - a `.git` file, a `.git` directory and a `commondir` into a ledger folder are refused;
  - a real `git worktree` passes, and is refused when its main repository is in the ledger;
  - links in the metadata are refused;
  - a remote-looking `gitdir:` is not found.

## mimir: the MCP server

`crates/mimir` is a tools-only MCP server, hand-written on runstav's `jsonrpc` (library evaluation §12: rmcp is a
dev-dependency for the interop test only). It names no drgnx type: `norn` gives it the coordination tools, and
Ratatoskr gives it a connection.

- **`serve(ctx, tools, info, r, w, limits) -> End`** serves one connection: newline-delimited JSON-RPC 2.0, one
  message per line. A line over `limits.max_in` (1 MiB) ends the connection (`End::LineTooLong`); an answer over
  `limits.max_out` (16 MiB) becomes `-32603`. A `\r` before the newline is dropped and blank lines are skipped. One
  worker answers the lines in order, one at a time, and is the only writer, so answers keep request order. Every line
  read before the end is answered. `End` is `ClientClosed`, `LineTooLong` or `Io(kind)`. `ServerInfo` defaults to
  `{name: "drgnx", version: CRATE_VERSION}`; the name stays `drgnx`, so tool names (`mcp__drgnx__…`) and permission
  rules do not change.
- **Two protocol eras** (`version`):
  - **`initialize`** (2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25): `negotiate` echoes the client's version when
    it is one of these, else answers `2025-11-25`. The answer is `{protocolVersion, capabilities: {tools:
    {listChanged: false}}, serverInfo}`. Before `initialize`, a request other than `initialize`, `ping` or
    `server/discover` is `-32600` "initialize first": an error, never silence, since a client's discovery probe falls
    back only after an error or a timeout.
  - **Stateless 2026-07-28**: a request whose `params._meta["io.modelcontextprotocol/protocolVersion"]` is set is
    served on its own, with no handshake, unless `initialize` already chose the old era for the connection (the
    `_meta` check comes first). Another version is `-32022` with `data: {supported: ["2026-07-28", "2025-11-25"],
    requested}`, and a missing `io.modelcontextprotocol/clientCapabilities` is `-32602`. `server/discover` answers
    `supportedVersions: ["2026-07-28"]`, `capabilities: {tools: {}}`, the server's name and version in
    `_meta["io.modelcontextprotocol/serverInfo"]`, `ttlMs: 3600000` and `cacheScope: "public"`; `tools/list` carries
    the same `ttlMs` and `cacheScope`, and every result carries `resultType: "complete"`.
- **`tools/list`** gives `{name, description, inputSchema, outputSchema?}` in name order, the same every time.
- **`tools/call`** follows MCP 2025-11-25 (design §4.6 item 7, contract Task 10 as amended):
  - params that are not a CallToolRequest (`name` a string, `arguments` an object or absent) and an unknown tool
    (`Unknown tool: NAME`) are `-32602`;
  - arguments that fail the tool's `check` are a result, `{content: [{type: "text", text: "PATH: what is wrong"}],
    isError: true, _meta: {"dev.drgnx/error": {code: "invalid-arguments", path: PATH}}}`, and the tool never runs;
  - `ToolResult::Err(text)` is `{content: [text], isError: true}`; `Ok` is `{content: [text]}`, with
    `structuredContent` only when the tool declares an `outputSchema`;
  - a tool runs on its own task, so a panic is `-32603` (logged) and the connection goes on.
  Otherwise an unknown method is `-32601`, a line that is not JSON (or not UTF-8) `-32700` with `id: null`, a batch or
  any other invalid request `-32600` (on the request's `id` when it can be read), and notifications, results and
  errors from the client get no answer.
- **Tools** (`tool`) implement `Tool<Ctx>`: `name` (1–128 characters of `A-Za-z0-9_-.`, `valid_name`),
  `description`, `input_schema`, `output_schema`, `check` and `call`. `typed::<Args>()` is a tool's typed arguments:
  `.schema()` is the `inputSchema` (schemars, JSON Schema 2020-12, every object closed with `additionalProperties:
  false`, the top's `$schema` and `title` left out; no arguments is `{"type": "object", "additionalProperties":
  false}`), `.check(args)` is what `check` returns, and `.decode(args)` is what `call` starts with. The decode is
  runstav's `decode::typed` with unknown keys refused: an `ArgsError { path, message }` is `PATH: unknown key`,
  `PATH: required, missing`, or serde's message at its path (`items[2].name`; `arguments` for the whole). The default
  `check` accepts anything, so a tool with arguments overrides it.
- **The bridge** (`bridge`, [hub.md](hub.md#the-mcp-bridge)): `run(connector, stdin, stdout, opts) -> BridgeEnd`
  copies an agent's stdio to a hub socket and outlives the hub. A `Connector` dials (`connect`) and says what comes
  before MCP (`prelude`: an outside bridge's `hello` and `mcp/attach`); a dial fails with `Dial::Again` (dial again
  after the backoff) or `Dial::Fatal` (end). `BridgeOpts` holds the timings (0.1 s doubling to 5 s, give up after
  10 min, a request waits 10 s) and the line limits. `BridgeEnd::code()` is the exit status: 0 when the agent went
  (`StdinClosed`, `StdoutClosed`), 1 for `GaveUp` and `Fatal`.

`cargo test -p mimir` runs `server::tests` (both eras over an in-memory pipe: the handshake, the stateless rules,
every error shape, a bad argument that never reaches the tool, a 1 MiB line that ends the connection, a panicking
tool) and `tests/interop.rs`: rmcp 3.6's client over a Unix socket pair, with `initialize` at each of the four old
versions, `server/discover` at 2026-07-28 and its automatic probe, lists the tools, calls `echo`, and gets a bad
argument back as a tool error with its path and an unknown tool as a protocol error. `bridge::tests` run the bridge
against a real `serve` on a paused clock: the replayed `initialize` whose answer is dropped, a call in flight at the
drop (a tool error, never resent), a call while away (the tool error after 10 s, or the answer when the hub is back
first), `tools/list` from the cache, `list_changed` after a reconnect to other tools, the backoff and the give-up,
stdin's end, and a line over the limit.

## bifrost: the gateway

`crates/bifrost` is the gateway's library: what an agent's or the editor's request must show to be forwarded, and
what reaches the provider. It names no drgnx path: provider ids, URLs, listener ids and the token registry come from
the caller. The port keeps what the old Lisp gateway did, with the changes listed in the
Ratatoskr phase-3 plan (chunked request bodies, keep-alive, a drained refusal, a header-read timeout).

**The caller's types** (crate root):
- `Provider { id, kind, base, auth, messages, caps, price }`. `kind` is `Openai`, `Ollama`, `Llamacpp`, `Tei` or
  `Anthropic`; `base` is a URL already checked by `runstav::url::provider_base`; `auth` is `Bearer`, `XApiKey` or
  `None` (a keyless local server: no key is needed or sent); `messages` says whether it speaks Anthropic's Messages
  API; `price` is `budget::Price`.
- `Registration { class, job, task, agent, chain, budget, openrouter, listener }`. `class` is `Agent` or `Editor`;
  `chain` is the agent's `Step { provider, model }` list; `listener` is `Loopback` or `Session(SID)`, the only
  listener the token is good on. `Registration::editor()` is the editor's: agent `editor`, no job, chain, budget or
  restrictions, on `Loopback`.
- `Restrictions` (OpenRouter's `only`, `ignore`, data collection denied, `zdr`): `Restrictions::new` refuses a slug
  that is not `^[A-Za-z0-9][A-Za-z0-9._/-]*$`.
- `keys::Keys`: provider id → `secrecy::SecretString`, memory only, with no `Debug`, `Clone` or `Serialize`. A key
  is exposed in one place: the upstream request's auth header, which is marked sensitive.

**Admission** (`admit::head`) runs on the request head alone, so a bad token is answered before any body is read:
1. on the loopback listener, exactly one `Host`, `127.0.0.1:PORT` or `localhost:PORT` (else 400 "this gateway
   answers on 127.0.0.1 only": the DNS-rebinding class);
2. the token, from `Authorization: Bearer` ("Bearer" as written), else `x-api-key`, looked up by the SHA-256 hex of
   its bytes (`admit::token_hash`) through the caller's `Registry`; a token issued for another listener is no token
   (401 "not a drgnx gateway token");
3. the path, by the registration's class (404):
   - an agent's: `^/v1/(messages(/count_tokens)?|models(/[A-Za-z0-9._:-]+)?)(\?[^#]*)?$`, routed along its chain
     (`Route::Chain`);
   - the editor's: `/p/PROVIDER/REST[?query]`, PROVIDER in the provider table and REST one of its kind's paths
     (`Kind::paths`: `openai` `/chat/completions`, `/completions`, `/embeddings`; `ollama` `/api/chat`,
     `/api/generate`, `/api/embed`; `llamacpp` `/infill`, `/v1/chat/completions`, `/v1/embeddings`; `tei` `/embed`;
     `anthropic` none), routed to that one provider (`Route::Provider { id, rest }`);
   - either way no `..`, no control, space or `#` character, and only the origin form (`/…`);
4. a `Content-Length` over 32 MiB (`admit::MAX_BODY`) is 413.

A `Refusal { status, kind, message }` answers with the Lisp's body, `{"type":"error","error":{"type":…,"message":…}}`.

**What reaches a provider** (`rewrite`):
- `body`: an agent step's `model` replaces the top-level `"model"`; on OpenRouter's `/v1/messages` (any query) the
  registration's restrictions merge into the top-level `"provider"` object, the stricter value winning: `only` the
  intersection (a 400 "no provider in common …" when it is empty, and nothing is sent), `ignore` the union,
  `data_collection` `"deny"`, `zdr` true; every other key of the client's object stays. With restrictions, a body
  that is not a JSON object (or a `provider` that is not one) is a 400; without, the bytes go as they came. Key order
  is kept; a rewritten key the client sent twice is written once, merged from its last value. The editor's route
  never calls it: its body passes unchanged.
- `upstream_uri` (agents): the base without a trailing `/` and then `/v1`, plus the request's path and query;
  `provider_uri` (the editor): the base without a trailing `/`, plus REST, with no `/v1` stripping (OpenRouter's base
  is `…/api/v1`). Both refuse a result whose scheme, host or port differ from the base's.
- `headers`: only `content-type`, `accept`, `anthropic-version` and `anthropic-beta` are forwarded, their control
  characters removed, plus the provider's auth header with the key (`x-api-key` for `XApiKey`, else Bearer; none for
  a keyless provider). The client's own token never goes upstream.

**Forwarding** (`engine::Gateway`, built with the registry, the provider table and `Keys` behind `RwLock`s, a
`Ledger`, an event channel and one `upstream::Upstream`):
1. admission (above); a refusal answers at once with `Connection: close`, then reads and drops up to 64 KiB of the
   unread body for at most 2 s, so the client is not reset while it still sends (A-25). A client waiting for
   `100 Continue` is not invited to send;
2. an agent whose job has a budget: `Ledger::spent(job) >= budget` is a `GatewayEvent::Budget` and 429
   `budget_exceeded` "the job's budget (N USD) is spent";
3. the body, at most 32 MiB (chunked or not; over is 413);
4. an agent's chain, step by step. A step is skipped, with its reason, when its provider is unknown ("not
   configured"), cannot speak the Messages API ("the gateway cannot carry it") or has no key ("no key", plus
   `GatewayEvent::NeedKeys`, at most once a minute per provider). Otherwise the body is rewritten, sent, and the head
   awaited: no head ("no answer (…)"), or 401, 402, 408, 409, 429 or 5xx while another step remains ("HTTP N"), moves
   on. Each move emits `GatewayEvent::Fallback` when a step remains. The first other head **starts** the answer
   (the chain's literal last step passes its provider's refusal through), and nothing falls back after that. No step
   left: 502 `api_error` "no provider answered: P: WHY; …";
5. the editor's route goes to its one provider with the body as it came: no budget, no rewrite, no fallback. A
   keyed provider without its key is `NeedKeys` and 503 "no key for P in the drgnx hub"; no head is 502;
6. a started answer: the provider's status, `Content-Type` (default `application/json`) and `Retry-After`, then each
   chunk as it comes, through the usage scanner. When it ends, or the client hangs up (which drops the upstream body
   and so its connection), one spend row is recorded through `Ledger::record` (`job` none and agent `editor` on the
   editor's route; status 0 when the client left before the head), then `GatewayEvent::Request`, then `Budget` if the
   job's total reached its budget. A guard's `Drop` writes the row, so it is written once whichever way the request
   ends, and a skipped or abandoned step writes none.

A key is read per attempt and goes only into the upstream request's sensitive header; logs name providers, never keys
or tokens.

**Listeners** (`listen`): `serve_tcp(gw, listener, port)` for the loopback listener and `serve_unix(gw, listener,
ListenerId::Session(SID))` for a session's socket; the caller binds them. hyper's HTTP/1.1 server with keep-alive
(the token is checked on every request), a 30 s header-read timeout and a 64 KiB head (longer is 431). At most 64
connections on the TCP listener and 8 on a session's socket; one more is accepted, closed at once and logged.

`cargo test -p bifrost` runs `admit::tests` (each refusal and its order, a token of another listener, both path
classes, the proptest `admit_never_panics` over random targets and headers), `rewrite::tests` (the Lisp's
`gateway-test.el` and `gateway-openrouter-test.el` cases by name), `keys::tests` and `tests/engine.rs`: a client over
TCP or a session socket, the gateway on its listener and `ratatoskr-mock llm` as the provider (fallback, the literal
last step, streaming first chunk first, spend once, the budget, a hang-up, need-keys, keep-alive, the drained
refusal, the connection cap, the editor's pass-through). It finds the mock at `RATATOSKR_MOCK`, else beside its own
binary, so build it first: `cargo build -p domr --bin ratatoskr-mock` (a workspace `cargo test` builds it anyway).

## Every order: skuld

`crates/skuld` is the Rust half of the `orders` test pattern (the Lisp half is `drgnx-test-every-order`). Code whose
correctness depends on the order of its inputs is split into a **pure core** (no I/O, clock or threads) and a thin
shell that does the I/O; a test runs the core in every order its inputs can arrive in, so an ordering bug fails at
write time instead of flaking later. Crates name `skuld` under `[dev-dependencies]` only.

```rust
#[derive(Clone, Debug)]
enum Ev { Data(u8), Eof, Closed }
skuld::events!(Ev { Data, Eof, Closed });   // the declared kinds: every one must be produced

impl skuld::Core for Conn {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> { /* … */ }   // returns the events its effects raise
}

let mut p = skuld::Partial::new();
let socket = p.source("socket", vec![Ev::Data(1), Ev::Eof]);
let client = p.source("client", vec![Ev::Data(2)]);
p.before((client, 0), (socket, 1));   // a claim the shell keeps; its own test checks it
skuld::every_order(&p, skuld::Bound::default(), Conn::new, |conn, order| conn.check(order));
```

- **The inputs are a partial order:** sources, each in its own order, plus happens-before edges across them
  (`before(a, b)`: event `a.1` of source `a.0` before event `b.1` of source `b.0`). Each edge is a claim about the
  shell; write it next to the test and test it in the shell's tests.
- **Effects re-enter:** the events a step returns are fed back, depth first, before the next external event.
  `check` gets the core and the external order; a failure message also shows everything fed.
- **The bound** (`Bound::default()`): every order while there are at most 20,000 of them (`exhaustive_max`; two
  sources of 8 events give C(16,8) = 12,870). Above that, every order within 2 delays (`delays`) of the natural
  one: the natural scheduler always takes the lowest-numbered source whose next event is enabled, and a delay skips
  the source it would take, once (Emmi, Qadeer and Rakamarić's delay-bounded scheduling). Two chains of 9 events
  have 48,620 orders, so they run the 55 within two delays. `skuld::count(&p, cap)` counts the orders exactly up to
  `cap` (dynamic programming over the sources' positions); the `Report` says how many ran and in which `Mode`.
- **Random orders on top:** `random_orders(&p, seeds, make, check)` runs one order per seed, drawn uniformly from
  every order (not only the bounded ones) by proptest's ChaCha `TestRng`; the same seed gives the same order.
- **No vacuous pass:** a cycle in the edges ("the edges form a cycle"), no events or no seeds ("no order to run"), a
  declared kind that no order produced (external or re-entrant: "the author forgot the EOF" fails), and re-entry
  deeper than `reentry_depth` (64) each panic with the cause. A failing check panics with
  `order I of N (MODE): [events…], fed: […]: MESSAGE`, and a random one names its seed.
- **What a pass means:** the core is right in every order of the declared events within this bound; nothing about
  events the test did not declare, or about the shell beyond its edges.

`skuld::wait_until(what, secs, f)` is the one real-time wait Rust tests may use: it polls `f` every 10 ms and panics
naming `what` after `secs`. The deadline only bounds a failure, so a test never widens it to pass.

`cargo test -p skuld` checks the helper against answers known exactly: the closed forms (12,870 for 2×8, 1,680 for
3×3, 63,063,000 for 4×4, binomials up to 7×7, the cap), and brute force over every interleaving for the orders an
exhaustive or a delay-bounded run visits (with and without edges, two and three sources), each once; the re-entry
order, each vacuous run, the printed order, a seed's repeat, and a uniformity check that a per-step coin would fail.

## Real time in tests

Rust test code (a crate's `tests/` files, `tests.rs` files and `#[cfg(test)]` items) never sleeps or reads a clock:
no `tokio::time::sleep`, `std::thread::sleep`, `Instant::now` or `SystemTime::now`. They make a test depend on how
fast the machine is. `cargo test --workspace` runs `skuld`'s `real_time_in_tests::no_real_time_in_test_code`, which
reads the sources (comments and strings blanked) and fails naming `file:line` for each banned call.

What a test does instead:

- **Waits for what it needs:** `skuld::wait_until(what, secs, || Some(value))` (or `wait_until_async` where the look
  awaits) polls until the condition holds; the deadline only bounds a failure. A sleep that "lets it settle" becomes a
  wait on what it waited for.
- **Has no elapsed assertion:** an upper bound on a call that has its own timeout is dropped. A bound that is the
  point (a grace kept, a deadline met, a parse under 50 ms) is its own **timing test**:
  `#[ignore = "timing: …"]`, run alone with `-- --ignored` on a pinned host. It may read the clock; the correctness
  assertions stay in a test that does not.
- **Runs on paused tokio time:** `#[tokio::test(start_paused = true)]` makes `tokio::time::sleep` virtual, and the
  check allows it there. In a file that imports `tokio::time::Instant` and has paused tests, `Instant::now` and the
  sleeps of its helpers read the paused clock too (`std::time::Instant::now` is still banned).
- **Needs a time as a value, not a wait:** `skuld::origin()` is an `Instant` to add durations to (a pure timer core's
  test), `skuld::host_now()` the wall clock for a test that compares a time the OS reports (a process start, a file
  time) with now. A unique name comes from the process id, not from the time.
- **Needs a window in which nothing may happen:** `skuld::window(length, "what may not happen")`. Nothing marks that
  nothing did, so the test can only wait; a window can make a wrong program pass if it is too short, never fail a right
  one. It says what may not happen.

Exempt: `#[ignore = "timing…"]` tests and `tests/timing.rs`, `skuld/src/wait.rs` (where these functions live) and the
hub clock's module (`drgnx-ratatoskr/src/clock*`).

## The conformance harness

`domr` runs **scenarios** (data) against a hub binary: a process that answers the hub protocol on its socket.
Every scenario gets fresh temporary roots under `/tmp/rtsk-XXXXXX/` (`/tmp`, not `$TMPDIR`, so macOS socket paths stay
short) holding `home run state data config cache tmp`, and the hub's `HOME`, `XDG_*`, `DRGNX_DATA_DIR`,
`DRGNX_CONFIG_DIR` and `TMPDIR` point there. A hub is started with `--parent-pid` of the harness, so it ends with the
test, and `RATATOSKR_SUPERVISOR=none` keeps a supervisor out of it. Only `PATH`, `DRGNX_EMACS` (for the rows that
run the editor's own CLIs, such as the personal-notes canary) and `DBUS_SESSION_BUS_ADDRESS` are inherited.
`DRGNX_CONFORMANCE_ROOTS=DIR/PREFIX` makes the roots `DIR/PREFIXXXXXXX/` instead. Keep DIR short: the socket path
must stay within 103 bytes.

```
domr --hub-bin PATH --scenarios DIR
     [--only GLOB] [--only-tag TAG] [--require-all] [--perf OUT.json]
domr connect-as --socket PATH
```

- One target, Ratatoskr: every row runs against the one hub binary. There is no Lisp hub and no stand-in backend; a
  row that needs a second process (an agent, a provider, a proxy) starts one of `ratatoskr-mock`'s.
- `--only GLOB` matches the scenario name (`*` and `?`); `--only-tag TAG` the rows that require the tag.
- Output: one `PASS name`, `SKIP name (reason)` or `FAIL name: step N (VERB): what` line per scenario, then
  `N passed, N skipped, N failed`. A FAIL of a row that is not `pending` goes on with when each step ran and how long
  it took, and the last 60 lines of each hub's stderr and of its own log, kept before the root is removed: a red that
  does not come again still says where its time went. Exit 0 only with no FAIL. With `--require-all` a SKIP fails too, except `linux` /
  `macos` skips on the other host, `sudo` skips where neither root nor passwordless sudo exists, `perf` rows
  without `--perf`, and rows with a `drop_ptrace` step where the harness has `CAP_SYS_PTRACE` and no `setpriv`.
- `--perf OUT.json` runs the `perf` rows and writes every `measure` step's timings to the file.
- `connect-as` connects to the socket and relays stdin and stdout over it: the other-uid connection runs it as
  uid 65534 (`setpriv` as root where util-linux has it, else `sudo -n -u nobody`; `$SUDO` names the sudo command).

### The scenario format

A scenario is one file, `test/conformance/<group>/<name>.jsonl`. Line 1 is the header

```json
{"scenario": "<group>/<name>", "requires": ["v1"], "doc": "what this row pins"}
```

Every other line is a step `{"do": VERB, ...}`. Steps are numbered from 1 in failure messages.

**Tags** (`requires`): `v1` (hello v1: every row), `sudo` (euid 0, or `sudo -n true` succeeds), `test-hooks` (the
binary's `version --json` says `"test_hooks": true`), `linux`, `macos`, `perf`, `agent-locks`, `podman` (`podman` is on
the PATH; an excused skip otherwise), `real-sandbox` (the binary has **no** test hooks and its `sandbox check --json`
says `ok`; an excused skip otherwise, with the reason: [the real-start rows](#the-real-start-rows)), `chromium` (the hub
gives sessions a browser here: its `sandbox check` reports Landlock ABI 9 or later, and `browser list --json` resolves a
Chromium), `playwright-mcp` (`node` on the PATH and Playwright MCP in `/opt/pw-mcp`, as the browser test image has them),
`internet` (the row reaches the outside network; it runs only with `DRGNX_TEST_INTERNET=1`). `chromium` and
`playwright-mcp` are excused skips where they are missing, except with `DRGNX_TEST_REAL_BROWSER=1` in domr's
environment: real browsers were asked for, so a missing one fails `--require-all`. A tag that is not in this list is a
parse error naming it. A row whose requirement is missing is skipped.

**Known reds** (`"pending": "REASON"` in the header, REASON naming the task that turns it green): the row runs, and a
failure is listed as `PENDING` and counted apart (`N pending` in the summary), never as a failure; a row that passes
while marked fails the run, so the mark goes as soon as its task lands. A row is never deleted for it.

| VERB | Keys | Meaning |
|---|---|---|
| `start` | `hub` (a name, default `hub`), `bin` (`"under-test"` or an absolute path, `$ROOT` being the root: a copy `install_bin` made), `args`, `env`, `same_root_as`, `wait` | start `BIN serve --foreground --parent-pid <harness pid> ARGS` in a fresh root (the `root` step's, or another hub's root); with `wait` (default true) it waits up to 10 s until `ping` answers; `wait: false` is for a start expected to exit |
| `root` | none | make a root with no hub in it (`$ROOT $SOCKET $LOCK …` name its paths). The `run`, `start` and file steps after it work in that root; what `ensure` started there, detached, is stopped when the scenario ends (the lock file's pid, while its start time is the recorded one) |
| `run` | `capture`, `bin`, `args`, `env`, `hub`, `concurrent`, `retry_ms`, `drop_ptrace`, `expect_code`, `expect_stdout`, `expect_stderr` | run `BIN ARGS` to completion (30 s) in the hub's root (else the `root` step's): `ensure`, `stop`, `status`, `restart`. `DRGNX_HUB_PARENT_PID` is the harness's, so a hub it starts detached ends with the harness. `concurrent: N` runs N copies at once, each of which must satisfy the expectations; `retry_ms` repeats the run until they hold. The capture is `{stdout, code, json}`; `expect_stdout` is a string the output contains or a pattern for its JSON (`$capture:NAME` / `$NAME` work in both); `expect_stderr` is a string the error output contains. `drop_ptrace: true` runs it without `CAP_SYS_PTRACE` where the harness has it (bit 19 of `CapEff`: root on a CI host, `--cap-add`), under `setpriv --inh-caps=-sys_ptrace --bounding-set=-sys_ptrace`, since the capability sees through a non-dumpable hub; where `setpriv` is missing the row is skipped with that reason. Podman's default set lacks it, so rows run as they are there |
| `rename`, `remove` | `from`, `to` / `path` | rename-replace a file, remove one (an update of a binary on disk) |
| `install_bin` | `to` | copy the hub under test to `to` (0755), a binary a scenario can replace |
| `connect` | `conn` (default `c`), `hub`, `socket` (`"main"`, `"agent:SID"` or `"path:STRING"`, a captured path with `$NAME` substituted), `as` | open a connection; lines are buffered per connection. `"user"` (default) performs the `hello` macro with a valid proof and consumes the `challenge`. `"service"` and `"raw"` connect and read nothing first (the `challenge`, if the socket sends one, stays buffered; the `mcp.sock` of a session sends none). `"other-uid"` needs `sudo`: it runs `connect-as` as another uid, and makes the root directory 0711 for it |
| `spawn` | `capture`, `argv`, `capture_stdout: {regex, name}` | start a helper (for example `sleep 60`); the capture is its pid, and `NAME_start` its start time. Killed when the scenario ends. `capture_stdout`: the first stdout line that matches within 5 s, its group captured as `name` (a number stays a number). The regex is a small form: literal text and at most one group, `(\d+)`, `([0-9]+)`, `(\w+)`, `(\S+)` or `(.+)`; `\x` in the literals is `x` |
| `http` | `conn` (default `c`), `to` (`"tcp:HOST:PORT"` or `"unix:PATH"`; without it the open connection is used again), `method` (GET), `path`, `headers`, `body` or `body_bytes {fill, n}`, `read` (`"all"` (default), `"head"` or `{bytes: N}`), `close_after` (true: close the connection after the read), `within_ms` (5000) | one HTTP/1.1 request, a `Host` and a `Content-Length` added when missing. `read: "head"` leaves the body unread; `{bytes: N}` reads until N body bytes are in. A server that answers early and closes without reading all of a big body is not an error |
| `expect_http` | `conn`, `status`, `headers` (pattern; names compare lower-case), `body_contains`, `body_json` (pattern; a chunked body is decoded), `within_ms` (5000) | the response read so far must match; more is read until `within_ms` |
| `file_grep` | `paths` (globs: `*` and `?` in a component, `**` for any depth), `absent` | no file matching the globs contains the text (bytes, binary files too: `runtime.db`, logs). Symlinks are skipped; a glob set that matches no file at all is an error |
| `hello` | `conn`, `proof`, `proto`, `expect_class`, `expect_error`, `expect_result`, `capture` | the v1 macro: read the `challenge`, send `hello` with the proof, check the class and, for `valid`, the hub's proof. `proof` is `valid`, `wrong`, `none` or `replay:NAME`. `capture: NAME` keeps the line it sent; `replay:NAME` sends such a line again, as is. `expect_error: CODE` wants the refusal with that code; `expect_result` is a pattern for the reply. A connection is challenged once: a second `hello` on it uses the nonce the first one read |
| `chmod` | `path`, `mode`, `owner` | change a mode (octal string) and/or the owner: `"other"` gives the path to uid and gid 65534, `"self"` back to the harness's (root does it itself; anyone else through passwordless `sudo -n chown`, so such a row needs `sudo`) |
| `send` | `conn`, one of `json`, `raw`, `bytes` | write one line. `raw` is the text as is, plus `\n` unless `"no_newline": true`; `bytes` is `{fill, n, newline}`. In `json`, `{"$repeat": TEXT, "times": N}` is TEXT N times (a long string without a long row). `"eof": true` then closes the sending side (a client that vanished mid-line). A write the hub closed meanwhile is no error: the next `expect_closed` says so |
| `pause` | `conn` | stop reading the connection (what arrives stays in the socket): a client that stopped reading. The next step that reads it reads again |
| `expect` | `conn`, `json` (pattern), `within_ms` (5000) | the first buffered or arriving line that matches; earlier non-matching lines stay buffered |
| `expect_next` | as `expect` | the very next line must match |
| `poll` | `conn`, `json` (a request with an `id`), `expect` (pattern), `within_ms` (5000), `every_ms` (200) | send the request and take its reply (by id) again until one matches: for state the hub reaches in the background (sessions resumed after a restart), read back instead of an event that may have gone before the row subscribed |
| `expect_closed` | `conn`, `within_ms`, `silent` | the hub closed the connection; with `"silent": true`, without sending a line first (a refusal answers nothing) |
| `expect_silent` | `conn`, `for_ms` (300) | no line arrives |
| `count_events` | `conn`, `for_ms` (1000), `at_most` (event name → N), `none` (event names), `lacks` | read the connection for `for_ms` (lines already buffered included) and count its events by name: no name over its `at_most`, none of `none` at all, no line holding the text `lacks`. For traffic budgets |
| `kill` | `hub` or `pid`, `signal` (`TERM KILL STOP CONT INT HUP QUIT USR1 USR2`) | signal the hub (or a captured pid) |
| `expect_exit` | `hub`, `pid` or `conn`, `code`, `signal`, `within_ms` (10000) | the process ended with this status (a `pid` must be one the scenario spawned; a `conn` one a `spawn_conn` started) |
| `file` | `path`, `exists`, `mode`, `owner` (`"user"` or a uid), `json`, `contains`, `count` (1), `at_most`, `lacks`, `within_ms` (5000) | inspect a file the contract names. A `*` or `?` in the last component picks the first matching name (`hub-*.jsonl`). `contains` waits up to `within_ms` until the file's text holds the string `count` times (a log is written a moment later), and then no more than `at_most` times when given (a line logged once); `lacks` is a string the text must not hold |
| `proc` | `pid` (a number, `$PID(hub)` or a capture), `part` (`"argv"`, `"environ"` or `"launch_env"`), `contains`, `lacks`, `except_var`, `refused`, `drop_ptrace` | a process's arguments, or the environment it started with, as the system shows them to the same user: `/proc/PID/cmdline` and `/proc/PID/environ` on Linux, `sysctl kern.procargs2` on macOS (which has no `/proc`). `launch_env` is the environment the harness gave a hub it started at exec (exactly those variables, nothing inherited): a non-dumpable hub's own `/proc/PID/environ` is not readable. An empty read fails (it would pass any `lacks`); `contains` is a string one of the entries holds, `lacks` one none may hold, except the entry `NAME=…` that `except_var` names. `refused: true` (with `environ` and `drop_ptrace`) checks the opposite: the read is refused (EACCES) to a process of the same user without `CAP_SYS_PTRACE` (`cat` under `setpriv` where the harness has it), which is how a non-dumpable process looks; on macOS (`PT_DENY_ATTACH`, which only an attach would show) it checks nothing |
| `write_file` | `path`, `text` or `json` (a JSON value; `{"$repeat": TEXT, "times": N}` expands, as in `send`), `mode` (octal string) | set up an input |
| `sqlite` | `path`, `sql_file`, `sql: [...]`, `query`, `expect` | set up a database (bundled SQLite): the statements of `sql_file` (a schema such as `$SCENARIOS/../fixtures/work-db-6.sql`), then `sql`; `query`'s rows, as `[[value…]…]`, must match the pattern `expect` |
| `spawn_conn` | `conn`, `argv`, `env`, `cwd` | start a child (for example `ratatoskr mcp-bridge …`) whose stdin and stdout are connection `conn` for `send` / `expect`. `env` is its whole environment (`{}` is empty, never the harness's). Its stderr is kept in `spawn-conn-CONN.err` in the root; it is killed at the scenario's end. `expect_closed` means its stdout closed; `expect_exit` with `conn` reads its status |
| `sql_expect` | `path` (`$DATA/work.db`), `sql`, `rows` | run a read-only query and match its rows (`[[value…]…]`) against the pattern `rows` |
| `db_digest` | `path` (`$DATA/work.db`), `capture` or `same_as`, `except` (tables, each with a reason in the row) | a digest of every table (row count and sha256 of its rows); `same_as` fails when any table appeared, went or changed since the capture |
| `capture_file` | `path`, `capture`, `json_path`, `within_ms` (5000) | read a JSON file (waiting for it to exist) and capture the value at `json_path` (dot-separated keys and array indexes, `$` or absent: the whole file), for example a socket path a helper wrote |
| `pid` | `capture`, `alive` (true), `within_ms` (5000), `stays_for_ms` | a captured pid is (or is no longer) running; a reused pid does not count. With `stays_for_ms` a pid that is running must stay so that long (a signal sent a moment ago has landed by then) |
| `class_matrix` | `table`, `args`, `env`, `agent`, `last`, `within_ms` | every method of `table` (`{method: [classes]}`, `class-matrix.json`) gets `{}` from `user` (a valid hello), `service` (no hello) and, with `agent: SID`, `agent` (that session's socket, which `args` such as `["--agent-socket", "s1:j1"]` makes the hub serve). A listed class must not get `not-allowed`; any other must. The step starts its own hubs with `args` and `env`: one for the table, and for each method of `last` (default `restart`, `shutdown`, which a user call runs) one per class |
| `bad_params` | `conn`, `registry`, `within_ms` | every method of the registry file (`methods.json`; a relative path is from the current directory) with required params gets `{}` and a wrong type for its first required key (`true` where a list belongs, else `[]`) on `conn`; each must be `invalid-params` with a `path` (one of the required keys, then that key). `hello`, and a method whose classes leave out `user` (`mcp/attach`), go on a fresh connection (service class) each time |
| `measure` | `name`, `repeat`, `steps` | times the steps, `repeat` times, and records the milliseconds for `--perf` |

**`ratatoskr-mock`** (`conformance/src/bin/`, std only; `$MOCK` is its path, beside `domr`) stands in for the network:

- `acp --as claude|codex|gemini [--script FILE] [--log FILE] [--llm URL] [--refuse-mode MODE]` is a scripted ACP agent on stdio
  (`conformance/src/mock_acp/`, the stand-in for the outside agents' CLIs; wire of `agent-client-protocol-schema
  =1.12.0`). A prompt's lines are its program: `tool:read|edit PATH`, `tool:exec CMD`, `tool:write N` (a Write of N bytes of input), `ask:permission KIND`,
  `call:MCPTOOL JSON` (through the first stdio server of `mcpServers`), `decide TEXT` (`record_decision`),
  `commit MSG`, `sleep-loop` (asks to run `sleep 30; pgrep …`), `silent N` (a `session/cancel` ends it),
  `crash` (exit 3); anything else is echoed. `--script` gives the n-th prompt its n-th line. Every answer carries
  `_meta.turnId` (`t1`, …); chunks carry `messageId`; the terminal capability is never used. Personalities: claude
  (`close fork list resume`; logs `_meta.claudeCode.options`; forks after a message; `usage_update` with cost and
  `_claude/rateLimit`), codex (same set; logs `-c` overrides of argv; forks at a turn; `usage_update` and
  `_codex/rateLimits`), gemini (`loadSession` only; the rest answers -32601). `--refuse-mode MODE` refuses `session/set_mode` to MODE (a lock that does not hold; the `agent-locks` rows); other modes are accepted. `--log` is JSONL; `--llm URL` POSTs
  to a `ratatoskr-mock llm` once per turn, so its log counts requests.
- `http-serve PORT TEXT` prints `MOCK-HTTP-PORT N` and serves on 127.0.0.1:PORT (0: any free port) a page whose title
  and text are TEXT, and `/download`, TEXT as an attachment: an agent's dev server inside its sandbox, or a site on the
  host's loopback.
- `cdp-drive URL…` is an outside agent's browser tool: it runs Playwright MCP (`node
  /opt/pw-mcp/node_modules/@playwright/mcp/cli.js`, the browser test image's) over stdio with its own environment, so
  Playwright reaches the browser that `PLAYWRIGHT_MCP_CDP_ENDPOINT` names (never in an argv), and for each URL calls
  `browser_navigate` and `browser_snapshot` and prints `TITLE <the page's title>` or `ERROR <url>: <why>`; it exits 1
  when any failed.
- `llm --script FILE [--log FILE] [--tls CA_FILE] [--parent PID]` prints `MOCK-LLM-PORT N` and serves a scripted
  provider on 127.0.0.1 (a port of `test/fixtures/mock-llm.el`). With `--tls` it makes a certificate authority and a
  leaf for `localhost` and 127.0.0.1 at start (`rcgen`), writes the CA's certificate (no key) to CA_FILE, prints
  `MOCK-LLM-CA CA_FILE` before the port line and serves TLS; the keys never leave its memory, so no test key is
  committed. Without it, plain HTTP. FILE is a JSON array
  of answers `{path, match?, status (200; 0 = never answer), delay_ms, body ("{}"), headers {name: value}, once,
  chunks [[delay_ms, text]…], content_type, no_end}`. The first answer whose `path` is a prefix of the request path and
  whose `match` occurs in the body answers; none: 404 `{}`. `chunks` streams (the head at once, no length, each text
  after its delay, then the close; `no_end`: the connection is dropped instead). The log is JSONL:
  `{"request": {method, path, headers (lower-case names), body}}` per request, then `{"closed": true}` when the client
  hangs up before the answer ended (with `--print-closed`, the mock also prints `MOCK-LLM-CLOSED` then, for a test to
  wait on). It ends when `--parent` is gone.
- `proxy [--log FILE]` prints `MOCK-PROXY-PORT N`; `CONNECT host:port` is logged (`{"connect": "host:port"}`) and
  tunnelled, anything else gets 405 (`{"refused": "METHOD TARGET"}`).
- `hf --dir DIR [--log FILE] [--cut FILE BYTES] [--bad FILE] [--location URL] [--no-range]` is the model host. It prints
  `MOCK-HF-PORT N` and `MOCK-HF-CDN-PORT M`: `/…/resolve/REV/FILE` on N answers 302 to `FILE?sig=1` on M, as the real host
  sends a download to its CDN, or to URL with `--location`; M serves DIR's files and honours `Range: bytes=START-` unless
  `--no-range`. `--cut` stops the first response for FILE after BYTES, `--bad` flips FILE's last byte. The log is JSONL:
  `{server, path, range, credentials}` per request.

**Variables** in strings: `$MOCK $ROOT $HOME $RUN $STATE $DATA $CONFIG $SOCKET $SOCKET_DIR $BACKEND_SOCKET $CAP $LOCK $PID(hub)
$HARNESS_PID` (of the step's `hub`, else the latest started; `$BACKEND_SOCKET` is where an older hub's Emacs child
kept its socket, for a row that plants its leftovers), `$SCENARIOS` (the scenarios' directory, absolute: its
`fixtures/`), and `$NAME` for a capture. A string that is just `$PID(hub)`,
`$HARNESS_PID` or a capture keeps its JSON type (a number stays a number). Agent sockets are
`$SOCKET_DIR/s/SID/hub.sock` (`paths::session_dir`).

**Patterns** are JSON. An object matches when it has every key of the pattern (extra keys are fine). Arrays match element
by element and in length, unless the pattern is `{"$contains": [...]}` (every listed pattern matches some element).
Special strings: `"$any"`, `"$string"`, `"$number"`, `"$hex64"`, `"$absent"` (the key must be missing), `"$capture:NAME"`
(matches anything, remembers it) and `"$NAME"` (equal to the value captured earlier); `"$NAME#1"` (a captured string
followed by more text, such as a task id `JOB#1`) is the capture with that text appended.

**The `hello` proofs** are computed by the harness itself, with its own HMAC-SHA256: the client proof is
`HMAC(cap hex as ASCII, "drgnx-hub client " + hub_nonce + " " + client_nonce)` and the hub's is
`HMAC(cap, "drgnx-hub hub " + client_nonce + " " + hub_nonce)`, both as lowercase hex. The cap is read from
`hub-HASH.cap`, beside the socket.

### Where the socket is: one fixture for Lisp and Rust

The data directory and the socket path follow Lisp's `drgnx-paths-dir 'data` and `drgnx-hub-socket` exactly
(`crates/runstav/src/paths.rs` is the Rust side, for the hub and the harness alike): only an absolute environment value counts; names are normalised as Emacs's
`expand-file-name` does it, oddities kept (`/a/../../b` is `/../b`, `//a` stays `//a`); `sha1` of the data directory
(with its trailing `/`), cut to 8 hex digits, names `hub-HASH.sock`; it is under `$XDG_RUNTIME_DIR/drgnx/` when that is a
directory, else under `<state>/hub/`; a path over 103 bytes goes to `<tmp>/drgnx-hub-UID/`, where `<tmp>` is the first
of `TMPDIR`, `TMP`, `TEMP` that is set, else `/tmp`. Lisp reads those variables itself, not Emacs's
`temporary-file-directory`: on macOS that starts as `getconf DARWIN_USER_TEMP_DIR` when none of the three is set, and a
user can change it, so only the environment gives one answer on both sides. A relative value is out of scope.

`test/fixtures/hub-socket-cases.json` holds cases `{env, data_dir, socket}` (`$UID` stands for the uid); the Lisp test
`drgnx-hub-socket-cases/lisp-agrees-with-the-fixture` and the Rust tests `paths::tests::socket_cases_fixture` (in the
harness and in `runstav`) all read it. To add a case, run the Lisp side to measure it and put the result in; never write an expected value by hand.

### Testing the harness

`cargo test -p domr` covers the parser, the matcher, the paths, the proofs and, in `tests/harness.rs`, whole
runs against a scripted hub (a small hub inside the test binary). `test/conformance/self/*.jsonl` are the harness's own
rows: they test the harness's verbs against whatever hub it is given.

### The basic rows

The first rows pin what a hub does at its socket. Each `connect` takes the default `"as": "user"`, so the hello is
done for them.

| Group | Rows |
|---|---|
| `framing/` | `one-object-per-line`, `line-over-1-mib-closes`, `malformed-line-with-id-gets-an-error`, `malformed-line-without-id-is-dropped` |
| `basics/` | `ping`, `agents-list-empty`, `shutdown-ends-the-hub`, `a-second-hub-exits-3` (a second hub on the same data dir exits 3); `status-shape` is `status-shape-v1`'s |
| `events/` | `since-shape`, `subscribe-relays-events` (a proposed then stopped job: its event's `data` is a JSON object, from `events/since` and as an `events` event) |

(The rows once ran against the Lisp hub too, tagged `v0`; where a `v1` row of the same behaviour existed, the `v0`
one was deleted, the others became `v1`.)

### Ratatoskr's server-core rows

`v1` rows pin the server core ([hub.md](hub.md#the-control-socket)):

| Group | Rows |
|---|---|
| `framing/` | `a-partial-line-then-eof-closes-only-that-connection` |
| `basics/` | `two-hundred-connections-each-get-an-answer` |
| `lifecycle/` | `socket-dir-0700-cap-0600`, `sigterm-removes-socket-and-cap`, `parent-pid-gone-ends-the-hub`, `a-newer-runtime-db-is-moved-aside`; the leftovers of an older Lisp hub, planted by the row (no Lisp process): `a-stale-lisp-lock-directory-is-taken-over`, `a-lisp-lock-naming-another-program-is-taken-over`, `a-stale-backend-lock-is-removed` (no obstacle) |
| `security/` | `another-uid-is-refused` (`sudo`: as root in the Fedora 45 test image, or through passwordless sudo on macOS) |

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr --features drgnx-ratatoskr/test-hooks
cargo test  --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr --features test-hooks
runtime/target/debug/domr --hub-bin runtime/target/debug/ratatoskr --scenarios test/conformance --only 'lifecycle/*'
```

`tests/server.rs` starts the real binary in roots under `$TMPDIR`. It covers two hubs on one lock (the second exits
3), the cap (64 hex, 0600, gone after SIGTERM, never in the log) and the lock file's `PID START_TIME`. With
`test-hooks` it also covers a reader that stops while a `__test_flood` of 32 MiB comes. That reader is dropped past
16 MiB while another reader gets every line. In CI the `conformance` step runs every row in the Linux job
(Nidhogg from `test/container/nidhogg.sh fedora-45`) and the macOS job (`nidhogg.sh macos`, which sets `DRGNX_EMACS`);
the Emacs is for the canary row's editor CLIs.

### The v1 rows

Rows with `"requires": ["v1"]` (all of them) run against Ratatoskr:

| Group | Rows |
|---|---|
| `params/` | `bad-params-are-refused-with-a-path` (`bad_params` over `runtime/protocol/methods.json`), `named-types-refuse` (ids, absolute local paths, a 17-item `env/set`, an uppercase nonce: each `invalid-params` with its path), `duplicate-key-refused`, `unknown-keys-dropped-and-listed` |
| `hello/` | `challenge-on-accept`, `valid-proof-makes-user-and-hub-proves`, `wrong-proof-refused-and-logged`, `replayed-hello-is-refused` (SB-T12-6), `no-hello-is-service`, `newer-proto-refused`, `a-second-hello-is-refused`; with `test-hooks`: `an-agent-socket-is-agent-class` |
| `class/` | `matrix` (`test-hooks`: `class_matrix` over `class-matrix.json`, the agent class through `--agent-socket s1:j1`) |
| `agents/` (`test-hooks`, probe) | `probe-answers` (a mock ACP agent answers `agents/probe` with its name and version; no session; an unknown profile and `wait_s` over 60 are `invalid-params`), `probe-times-out` (an agent that never answers: `ok: false`, "did not answer within 1 seconds"), `probe-bad-command` (a missing program, and one that exits 7 with a line on stderr: `ok: false`, the status and the stderr tail), `send-if-free-never-interrupts` (`agents/send` with `if_free` on a busy steer-mode session: false, nothing queued, steered or cancelled; on a free one: a turn) |
| `hub/` | `env-set-served-by-the-front` (no backend: the front answers, a `PATH` that is no list of absolute directories is `invalid-params`), `env-set-applies-path` (the next job's `PATH` has the sent directory), `env-set-refuses-key-names` (a secret-looking name and a provider's key variable are left out of `applied` and out of the job's environment), `env-set-refuses-path-rule-names` (`HOME`, `TMPDIR`, `XDG_RUNTIME_DIR`, `DRGNX_DIR`, `SSH_AUTH_SOCK` are left out of `applied` and out of the job's environment; a plain name is kept) |
| `errors/` | `every-error-has-a-code` (each code but `schema`; a refused notification gets no answer), `empty-lists-are-arrays` (A-17: an empty list is `[]` on the wire, never null), `results-match-schemas` (a populated store: a proposed job, a review card, a mock agent session with entries; every read method answers without `internal`; `test-hooks`) |
| `readonly/` | `a-newer-work-db-refuses-writes` (work.db at schema 99: `schema` for a writing method within the 2 s tick) |
| `basics/` | `status-shape-v1`, `events-since-without-a-work-db`, `events-since-from-the-store` (rows written into work.db with `sqlite`) |
| `gateway/` ([hub.md](hub.md#registrations)) | `register-keeps-only-the-hash` (the token's SHA-256, computed by `sh`, is the row's `hash`; `file_grep` finds the token in no file under the root), `a-gone-owners-registrations-are-pruned` (owner a `spawn`ed `sleep`, killed: `status --json` with `retry_ms`), `config-providers-refuses-a-bad-url`, `a-lan-http-provider-is-allowed-with-a-warning` (logged once after two calls: `file` with `count` and `at_most`; `doctor --json`), `a-spend-over-the-budget-is-recorded` (a request through the gateway to `ratatoskr-mock llm`, the spend row in work.db), `keys-are-never-on-disk` (`file_grep` over the hub's roots), `no-usable-step-is-refused`; with `test-hooks` too: `keys-only-on-a-user-connection` (service and agent connections), `spend-is-own-job-for-an-agent` (summed from work.db's rows) |
| `coord/` | the front's writes (`sqlite` makes a schema-6 work.db from `fixtures/work-db-6.sql`): `cards-settle-once`, `messages-send-held-by-version`, `events-add-is-broadcast-once`, `review-mark-and-its-event-commit-together` (a trigger refuses the second event: neither is written), `a-write-before-work-db-is-ready-says-so`, `a-newer-work-db-refuses-coord-writes` (a `sender` on `messages/send`: `messages/a-sender-is-refused`) |
| `graph/` ([store.md](store.md#parsed-entities-task-15a)) | `put-parsed-round-trip` (read back through the `node`, `file` and `link` rows; the same scan again writes nothing; a derived status; `gone`), `put-parsed-refuses-a-denied-source` (a personal-notes fixture under the row's HOME as a `file` source, a `spec` source and a plan's link end: refused whole, no row holds its canary or path), `record-twice-is-one` (keyed by the collected key) |
| `settings/` ([hub.md](hub.md#settings)) | `the-hub-reads-settings-el` (a profile and a provider of the user's join the built-in ones: `status.settings`), `no-editor-still-has-presets-and-profiles` (16 and 7 with no file), `a-package-entry-never-stops-the-hub` (entries of any shape the hub does not know: no problem), `a-broken-file-gives-strict-agents-and-last-good-providers` (the file breaks; the next `mcp/session` reads it again: a `notice`, the profile gone, the provider kept from `kv`, and the same after a restart) |
| `lifecycle/` (Task 16) | `ensure-starts-once` (two `ensure`s at once with no supervisor: one hub), `stop-ends-it`, `kill-9-then-ensure-restarts`, `stop-ends-a-non-dumpable-hub` (`test-hooks`: `--test-ignore-shutdown`, so `stop` reaches its SIGTERM through the listener's pidfd; `drop_ptrace`), `stop-never-signals-a-forged-argv0` (`test-hooks`, `linux`: the lock's text rewritten to name a `sleep` started as `exec -a ratatoskr`, with its true start time; `stop` exits 1 and both live), `stop-with-a-stale-lock-signals-nothing` (a lock file naming a live `sleep` that nobody holds: not running, no signal) |
| `restart/` | `the-restart-method-exits-75`, `a-self-detached-hub-re-execs`; with `test-hooks` (`--idle-tick-ms 200`; a running turn of a mock agent is what keeps the hub): `a-changed-binary-sends-the-notice`, `a-busy-session-delays-it`, `a-missing-or-broken-new-binary-never-restarts` |
| `reaper/` | `a-recorded-orphan-is-killed-at-start` (`linux`: the row plants a `runtime.db` record for a live process of its own group, as an older hub's Emacs child left one; the next hub kills it within 4 s and logs it), `a-row-without-a-pid-is-dropped-and-kills-nothing` (NULL rows in `runtime.db`: removed, nothing signalled) |
| `mcp/` | the coordination tools on session sockets and outside bridges ([hub.md](hub.md#sessions-and-their-sockets)): `the-session-directory-is-private`, `a-gone-owners-sessions-are-closed` (a `spawn`ed owner killed), `a-closed-session-is-gone`, `an-unknown-tool-is-32602`, `a-fifth-connection-is-closed`, `a-session-socket-is-its-identity` (an `agent` argument changes nothing), `an-outside-bridge-is-ext-and-unverified`, `sessions-come-back-after-a-restart`, `bad-argument-is-a-tool-error-with-its-path`, `modern-and-legacy-handshakes`, `tool-writes-are-broadcast-as-events`, `drgnx-agent-in-the-environment-is-ignored`; with `test-hooks`: `attach-needs-service-or-gets-not-allowed` |
| `bridge/` | `ratatoskr mcp-bridge` ([hub.md](hub.md#the-mcp-bridge)), a copy of the hub under test (`install_bin`) run by `spawn_conn`: `outside-refuses-an-untrusted-directory` (the socket's directory at 0755: exit 1, the reason on stderr); more: `survives-a-hub-restart` and `survives-a-hub-restart-modern` (the gate rows: a TERM, a start on the same root, the next call works; both eras), `an-in-flight-call-is-an-error-never-a-retry` (a call to a STOPped hub, then KILL: the went-away tool error, one event after the restart), `a-call-while-away-waits-then-errors`, `tools-list-from-the-cache-while-away`, `drgnx-agent-in-the-environment-is-ignored`, `outside-is-service-class-and-ext`, `stdin-eof-ends-it`; with `test-hooks` (`--bridge-backoff-ms`, `--bridge-give-up-ms`): `gives-up` |

All rows run with one command:

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr --features drgnx-ratatoskr/test-hooks
runtime/target/debug/domr --hub-bin runtime/target/debug/ratatoskr --scenarios test/conformance
```

Run it as a child of a shell (`bash -c '…; exit $?'`) in a container: the outside-agent rows need the harness to have
a parent process, which the container's first process has not.

Paths: the agent sockets are `<root>/run/drgnx/s/SID/hub.sock`; past 103 bytes (sized for the longest session socket,
`gateway.sock`) a session dir goes to `<tmp>/drgnx-hub-UID/s/SID/`.

`test/conformance/class-matrix.json` is not a row: it is the hand-written class table (`{method: [classes]}`) that the
registry's test and the `class_matrix` step read.

### The real-start rows

A test-hooks hub starts every agent session unsandboxed (`spawn_spec`'s test launch), so no other row runs the launch a
user gets. `real-start/*` rows (`requires` `real-sandbox`) run against a **release** hub on a host whose sandbox starts:
`cargo build --release -p drgnx-ratatoskr -p domr`, then `domr --hub-bin runtime/target/release/ratatoskr --scenarios
test/conformance --only 'real-start/*' --require-all` (a Linux host with bwrap and user namespaces, a VM, or a podman
container with `--security-opt unmask=ALL`). Against a test-hooks hub, or where `sandbox check` fails, they are
excused skips that name the reason.

| Row | Proves |
|---|---|
| `an-agent-starts-sandboxed` | the editor's shape (a project cwd, no task) through `launch::spawn_chat`, Gleipnir's validation and the sandbox: the mock agent is a link in `~/.local/bin` to a versioned install under `~/.local/share/claude/versions` (Claude's own layout), so the [toolchain roots](gleipnir.md#toolchain-roots) must be bound for it to exec; it answers a prompt, cannot write the home, `agents/get` says `enforced: true`, and `agents/stop` leaves no process and no session dir |
| `the-agent-drives-its-browser` | (also `chromium`, `playwright-mcp`: Landlock ABI 9, the browser test image) the agent browser as a user gets it: under Autonomous the agent runs `ratatoskr-mock cdp-drive` with the endpoint from its environment and reaches its own `http-serve` on local port 5173 inside the sandbox; a server on the host's loopback, as `host.drgnx.internal:PORT`, is refused with one `browser.private` card offering `session`; settled `session`, the retry reaches it and a second retry makes no card; `agents/stop` leaves no Chromium, no session dir and no `drgnx-session-SID` scope |
| `no-browser-below-abi9` | [OD1](hub.md#the-cdp-broker): a session whose host cannot give it a browser starts without one: a notice with the fix, `browser_why` in `agents/get`, no endpoint variable in the agent's environment. Below ABI 9 the kernel is the reason; on ABI 9 the row's setting names a missing program, so it holds on every kernel |
| `local-network-access-smoke` | (also `internet`: the gate only, once) Playwright opens `http://example.com/` through the web proxy under Autonomous; whether Chromium's Local Network Access blocked the proxied fetch is in the agent's `drive.out` (a block is a deferred item, not a red) |

CI's sandbox lane (`escape-host` in `runtime.yml`) runs these on its runner: the first and the third run there (bwrap,
user namespaces, a kernel below ABI 9), the browser rows are excused skips. The Fedora VM runs all four at the gate.

### The real browser tests

`drgnx-ratatoskr/tests/browser_real.rs` (`test-hooks`) runs the CDP broker against real browsers, one test per kind:
Fedora's `chromium-headless` (the headless shell) and the full `chromium`. Each starts `ratatoskr browser-host
--unconfined` with the real program, a broker over it, and `ratatoskr-mock cdp-drive` as the agent, which navigates a
`data:` page and an `http-serve` page; a raw CDP client of the test then checks that `Target.exposeDevToolsProtocol` is
refused, that a download lands in the browser's own `downloads/` with its `Browser.downloadProgress` event and the
broker's `Download`, and that a page the agent left paused (`waitForDebuggerOnStart`) loads once the agent's websocket
closes. It prints whether the hub's `Target.attachToBrowserTarget` worked on that Chromium, or the fallback ran.

It runs only with `DRGNX_TEST_REAL_BROWSER=1`, in the browser test image (`test/container/browser/Containerfile`: the
image the Rust tests run in, plus Chromium, Node and Playwright MCP pinned in `/opt/pw-mcp`), with `ratatoskr-mock`
built beside `ratatoskr`; with the variable set, a missing browser, Node or Playwright MCP fails the test.
`DRGNX_TEST_RECORD_DIR=DIR` writes the browser side of each run to `DIR/real-KIND.jsonl`, which `heimdall`'s tests read
from its `tests/data`. No page comes from the network: `http-serve` serves them on loopback, which Chromium reaches
without its proxy.

### The perf rows

`perf/` rows (`requires` `v1` and `perf`) run only with `--perf OUT.json`; without it they are skipped, and
`--require-all` lets that be. Each is a `measure` step; the file lists every sample and the median. Most have no
budgets (a recorded baseline, not a regression gate); the `agents-*` rows check theirs in the row.

| Row | Measures | Samples |
|---|---|---|
| `start` | starting the hub to its first answered `ping` on a proven connection | 1 |
| `hello-round-trip` | `ping` and its answer on a proven connection | 100 |
| `a-1-mib-request-line` | an `env/set` line of about 1 MiB read and decoded: its 16 values of 32 KiB re-encoded, answered by the front, a 500 KB unknown key dropped | 20 |
| `mcp-tool-call` | `tools/call read_inbox` over a session socket (initialized, `hello` called once before) | 100 |
| `coord-write` | `events/add` through the main socket, answered with the new id | 100 |
| `gateway-added-latency` | an agent's `POST /v1/messages` to the mock provider, head read: `direct-first-byte` against the mock, `gateway-first-byte` through the gateway with an agent token (the difference is the gateway's) | 50 each |
| `gateway-editor-fim-latency` | the editor's FIM-sized request, a 2 KiB `POST /completions` with a 64-token answer: `direct-fim` against the mock, `gateway-fim` as `/p/mock/completions` with the editor token; compare the median and p95 | 100 each |
| `walk-4-hops` | `graph/neighbors` four hops, out and both ways, on graph B (10^5 entities, about 10^6 links, 6 kinds; seeded into the running hub's store) | 20 each |
| `group-commit` | eight connections each send an `events/add` and wait for all eight answers (one round, group-committed) | 500 |
| `as-of-churn` | `graph/neighbors` as of a tx inside 200,000 versions of one link, one hop and two, and the same hop now | 20 each |
| `find` | `tasks/find` on 10^5 tasks: a word 1,000 hold, and a word one holds | 20 each |
| `agents-streaming-20` | 20 mock agents stream at once (25 chunks and 25 tool calls each) with an editor subscribed, 100 `ping` round trips meanwhile. **Budgets in the row** (`/proc`, Linux only): the hub's CPU (utime + stime) under 40 % of one core over the window, resident set under 400 MB. The ping samples are the keystroke-latency proxy (p95 < 16 ms, judged on the desktop lane) |
| `agents-idle-20` | 20 idle mock agents for 10 s: the hub's CPU under 3 % of one core (budget in the row) |

The writer-level group-commit number, with `secure_delete` on and off, is `urdr`'s ignored bench
(`cargo test -p urdr --bench group_commit --release -- --ignored --nocapture`).

```
cargo build --locked --release --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr
runtime/target/release/domr --hub-bin runtime/target/release/ratatoskr --scenarios test/conformance \
    --only 'perf/*' --perf perf.json
```

CI runs this on Linux and macOS and keeps the files as artifacts ([ci.md](ci.md)). Numbers are for a release build on a
quiet machine.

### The system rows (the agent core's exit criteria)

`test/conformance/system/*.jsonl` prove the agent core's exit criteria across groups, on mocks only (`ratatoskr-mock acp` and
`llm`; no live run). Each row says in its `doc` what makes it fail. Time-compressed rows shrink the hub's settings (the
silent limit, the idle close) and hold the build for a multiple of the limit instead of sleeping for minutes.

| Row | Criterion | Fails when |
|---|---|---|
| `three-providers-one-plan-under-balanced` | 1, 3 | a task starts on the wrong profile; an in-matrix action makes a card or waits; an ask runs without a card or the user's answer, or never reaches the event stream; Codex starts as a worker. Three providers means Claude, Gemini and an API-key `:ai` profile (Codex stays refused until `CODEX_LOCK_PROVEN`) |
| `a-manager-runs-the-plan` | 1 (the manager half) | the manager cannot start a worker per task through `agent_start`; a worker is not its child or not on its task; an in-matrix action makes a card or waits; the Gemini ask runs without a card or the user's answer; a worker the manager asks to fetch (network, which the manager lacks) is allowed or asked; Codex starts |
| `mixed-providers-lease-clash-review-spend` | 7, 8 | a task is claimed by the wrong session; the overlap (an `overlap` card) is not carded once; a review is not handed to the reviewer profile; the job does not finish; a step lacks its turn id, log version, plan or task, or the two workers' steps do not name two providers; a worker's rollup differs from its step rows |
| `ten-minute-build-zero-requests` | 4 | any model request (supervisor, reminder, heartbeat) during the wait; the waiting agent is judged silent; the wake opens a new session |
| `stall-paused` | 5 | the stuck agent is not paused within its limit, or with the wrong rule or limit; the card names another session or is made twice; the waiting agent is judged, or its wait is not one `job-wait` step longer than the limit (steps are written when they close) |
| `cost-matches-records` | 6 | the budget adds each cumulative cost report to the last; a rollup differs from the step table; gateway request events, spend rows, `spend` and the status count differ |

Criterion 2 is the laundering rows (`exec/`, `locks/`, `grants/`, `matrix/`), 10 the `restart/*` rows. The perf rows
`perf/agents-*` are the hub half of "20 agents streaming": hub CPU and resident set from `/proc` with budgets in the row
(run with `--perf`), and ping round trips while they stream. The editor half (the mirror redraws at most once per frame;
keystroke p95 under 16 ms) needs a GUI session with a live hub and 20 mock agents; the hub already coalesces a session's
events to one `agent` and `agent-entries` pair per 50 ms. It runs on a pinned host's timing lane.

### The gateway rows

`test/conformance/gateway/*.jsonl` drive the real gateway (`ratatoskr`'s front, [bifrost](#bifrost-the-gateway)) with
`ratatoskr-mock llm` as the only mock, standing in for the provider (and `ratatoskr-mock proxy` for the proxy). A row
starts the mock with `spawn` and `capture_stdout`, hands the hub the provider table (`config/settings`, a global `drgnx-ai-providers` override) and, where the
provider takes a key, a canary (`gateway/keys`), takes a token (`gateway/register`, or `gateway/editor-token` for the
editor), and acts as the agent or the editor with `http`. The mock's JSONL log is what reached the provider; the
mock's answers are `fixtures/llm-*.json` or a `write_file` in the row. All rows are `v1`; run them with one glob per
`domr` run: `--only 'gateway/*'`.

- **The gate rows** (phase 3, design §12): `fallback-on-429-before-the-head`, `budget-pauses-a-lisp-job`
  (a git repo made with `run`, `fixtures/plan-budget.md`, `job/propose` and `job/approve`, a job
  registration with a budget that one priced request passes; a `card` event of kind `budget`, `job/status` `paused`,
  then 429 `budget_exceeded`), `streaming-first-chunk-first`, `a-bad-token-is-refused-before-the-body` (a 20 MiB
  `Content-Length`, no body sent, 401 within 1 s), `proxy-from-the-environment` (`linux`: `HTTPS_PROXY` and
  `SSL_CERT_FILE` in the hub's environment, an https provider from `ratatoskr-mock llm --tls`, the proxy's `CONNECT`).
- **TLS:** `tls-with-the-system-store` (`linux`: the platform verifier reads `SSL_CERT_FILE`; a hub without the
  mock's CA gets 502 and nothing reaches the mock, a hub on the same root with `SSL_CERT_FILE` naming it gets the
  answer). Each TLS row sets `SSL_CERT_FILE` in its own `start` only, so CI sets nothing.
- **Chain and budget:** `no-proxy-is-respected`, `the-last-step-passes-its-refusal-through`, `every-step-failing-says-why`,
  `no-fallback-once-started`, `budget-refuses-at-equal`, `openrouter-restrictions-reach-the-body`,
  `a-hang-up-stops-the-upstream`, `request-events-and-spend-rows`.
- **Admission and sizes:** `host-check-on-loopback`, `a-session-token-is-refused-on-tcp`,
  `the-session-socket-serves-its-token` (`http` over `unix:`), `a-head-over-64-kib-is-431` (the 70,000-byte header comes
  from a `write_file` with `$repeat` and a `capture_file`), `a-body-over-32-mib-is-413`,
  `count-tokens-and-models-paths-pass`.
- **Keys:** `keys-are-never-on-disk` (`file_grep` over the hub's roots, the mock's log kept apart),
  `the-agent-never-sees-the-key`, `need-keys-after-a-restart`.
- **The editor's token:** `editor-chat-through-the-gateway` (the body byte for byte, the hub's key upstream),
  `editor-fim-through-the-gateway`, `editor-embed-through-the-gateway`, `editor-stream-through-the-gateway`,
  `an-editor-token-is-refused-on-the-messages-path`, `an-agent-token-is-refused-on-the-editor-paths`,
  `editor-requests-carry-no-restrictions`, `an-openrouter-base-keeps-its-v1`.
- **Not rows:** `no-proxy-is-respected` keeps a plain-HTTP provider (the connector tunnels through `HTTP_PROXY` for any
  scheme, so it proves the `NO_PROXY` rule without TLS). A kill -9 between a registration's row write and its answer is
  declined (phase 6's `op` rows are the target).

## Hrafn

`runtime/crates/hrafn` is the code-search indexer. It is generic: it has no hub types, and the binary passes in its
paths. Its git and file-watcher doors sit behind the traits `Git` and `Watch` under the default feature `host`.

### The code store

`CodeStore::open(<state>/code/<project-id>.db)` opens one SQLite file through `urdr` (one owning thread, WAL, mode
0600, migrations as data). Schema v1:

| Table | Holds |
|---|---|
| `file` | path, git blob, class, language, generated flag, size, indexed time |
| `chunk` | byte and line span, symbol, content `key`, `embed` flag, and `embed_text` (the only copy of a chunk's text, because `chunk_fts` is contentless) |
| `chunk_fts` | FTS5 over `path, symbols, doc, body`, contentless with `contentless_delete=1`; rowid = `chunk.id`; a trigger removes the row, and the chunk's symbols, with the chunk |
| `symbol`, `symbol_fts` | defined names with kind, span, chunk and definer; a trigram FTS over the names |
| `vec` | one quantized vector per `(model, key)` |
| `meta` | `urdr`'s table: the schema version, `chunker_version`, `built_from` and the like |

`vec_key(chunker, embed_text)` is sha256 over the length-prefixed chunker version and text. A chunk has one key; each
model that embeds it adds a `vec` row, so a branch switch back embeds nothing.

FTS5 has one tokenizer per table, and `tokenchars '-'` would hide `timer` in `drgnx-timer--fire` from the `body`
column. So the `symbols` column holds names encoded by `encode_symbol`, which maps each ASCII punctuation character to a
private-use character (a token character in `unicode61`): a whole name matches only the whole name, and `body`
still splits it. Queries encode the same way.

### The file list and coverage

`files::list(root, git, config, allow)` is the one place a path enters the index. Git sits behind the `Git` trait
(`GitCli` runs the `git` executable; `blobs` hashes the working tree with `hash-object --stdin-paths`, so an
uncommitted edit changes the blob), file bytes are read through `eitri` (a link, FIFO, missing or over-1-MiB file is
skipped), and `allow` is the hub's deny-list check on the relative path. A path is listed unless:

- a component starts with a dot, or the basename looks like a key, certificate, secret or credential file;
- it is inside a nested repository (an untracked clone or a submodule);
- it has a NUL byte in its first 8,000 bytes;
- the project's `include`/`exclude` globs (the editor sends `drgnx-search-{include,exclude,off}` per project) leave it out, or `off` is set.

`.drgnx/search.eld` that is there but cannot be read (a directory, a link, empty, over 64 KiB) is an error that
stops the listing, never the defaults. Each file gets a class (`code`, `test`, `docs`) and a language, from its extension, or
from a `#!` line when it has none. A file is marked `generated` (listed, not dropped) by `.gitattributes`
`linguist-generated`/`linguist-vendored`, by "generated" or "DO NOT EDIT" in its first five lines, or by a name like
`*-autoloads.el`, `loaddefs.el`, `*.lock` or `*.min.*`.

`coverage(listed, chunks_per_file)` reports a class with files but no chunks, and any non-empty file with no chunk.

### Chunks and symbols

`chunk::chunk_file(path, lang, generated, text, budget)` returns the file's chunks and symbols. A file's chunks put
together give back the file, byte for byte (offsets are bytes). The budget is 1,800 non-whitespace characters
(`BUDGET`); `CHUNKER_VERSION` is part of every vector's content key. A chunk's `line_start` is the line of its first
non-blank character (chunks are cut on the previous chunk's last newline, so the byte offset alone would name the line
before), which is where a hit opens and what `reanchor` compares against. Version 2 is that rule: an index made by
version 1 is chunked again at the next refresh, whether or not a file changed (and, the version being in every
vector's key, embedded again).

For Emacs Lisp (`tree-sitter` 0.25, ABI 15, with `tree-sitter-elisp` 1.7; 0.26 and later need Rust 1.90, above the
workspace's 1.88) the units are the top-level forms, each with the comments right above it, and the stretches between
them. Adjacent units merge greedily up to the budget and never across a section heading (a `;;;` line with text, at
column 0). A form over the budget splits at its child forms; every part's header repeats the signature, the first
docstring line and "part i/n". A `defconst`, `defvar` or `defcustom` whose value is a literal list or vector and
which is over the budget is one chunk that embeds only its first line and docstring (the FTS body keeps all of it).
The header (path, title line, section, defined symbols and kinds) is in `embed_text` and the FTS `path` and `symbols`
columns, never in `body`; a generated file gets `embed = false`.

The definer table (`chunk/definers.rs`) is closed: it names `defun`, `defvar`, `defcustom`, `defmacro`, `cl-defun`,
`defconst`, `defvar-local`, `defface`, `defgroup`, `defsubst`, `cl-defmacro`, `defvar-keymap`, `defalias`,
`define-obsolete-function-alias`, `define-error`, `cl-defgeneric`, `cl-defmethod`, `cl-defstruct` (type, constructors,
predicate, accessors), `define-minor-mode` and `define-derived-mode` (mode, `-hook`, `-map`), and drgnx's
`drgnx-defsetting`, `drgnx-memo-define`, `drgnx-module-define`, `drgnx-doctor-define`, `drgnx-config-define` and
`drgnx-command-define`. Project code is read, never evaluated.

Rust, C and shell (`tree-sitter-rust` 0.24, `tree-sitter-c` 0.24, `tree-sitter-bash` 0.25, all ABI 15) use the same
pipeline over their top-level items. Definitions are `function_item`, `impl_item`, `struct_item`, `enum_item`,
`trait_item`, `mod_item` and `macro_definition` (and type, const, static and union items) in Rust, with the
methods of an `impl`, trait or module as symbols of their own; `function_definition`, the struct, union and enum
specifiers, typedefs and `#define`s in C; `function_definition` in shell. The comment lines directly above an item
(`///`, `//`, `#`) are its docstring. An oversized item is cut before the members of its body.

Org and Markdown chunk by the heading tree (`chunk/outline.rs`): a chunk's header is its outline path (`A > B`), a
heading with nothing under it joins the next one, source blocks and fences stay whole under the budget, property
drawers and logbooks are left out of `embed_text` (the FTS body keeps them), and a table over the budget splits by
rows with its header rows repeated in `embed_text`. Plain text is line windows under the budget, with no symbols
(`chunk/text.rs`); a line over the budget is cut inside.

The test fixtures' form spans come from the Emacs reader: `tests/fixtures/elisp/gen.el` writes `NAME.forms.json` for
each `NAME.el` next to it (run it once in a Nidhogg 31 container, `emacs --batch -Q -l …/gen.el`), and the test holds
the grammar's top-level spans to them.

### The embedder

Hrafn is the code search behind `search/*` and the MCP `search` tool. `hrafn-embed` holds its embedding side, in pure Rust
with no SQLite, no tree-sitter and no C, so the crate builds for `aarch64-linux-android`.

- **The model table (`models.rs`).** `MODELS` lists gte-modernbert-base, Granite small r2 (the default, `default_model()`: the
  eval on drgnx's own queries put it ahead overall, 0.312 against 0.271 MRR@10, and 2.7 times faster to embed; gte-modernbert-base stays
  selectable by id) and CodeRankEmbed, each at a pinned revision. A row names exactly four files with their sizes and sums:
  `model.safetensors`, `tokenizer.json`, `config.json` and `1_Pooling/config.json`. There is no ONNX file and no GGUF.
  `ModelConfig::read` takes the network's shape from the model's own `config.json`, so a model of the same family needs
  a table row and nothing else. All three pool on CLS.
- **The cache (`cache.rs`).** A model lives in `<root>/<id>-<revision[..12]>/`. `<file>.part` is a transfer in progress; a file
  under its real name has passed its sum. `state` is `Missing`, `Partial`, `Ready` or `Corrupt`, and `Ready` means every byte was
  hashed (about a second). `import` copies a model from a directory, for an air-gapped machine.
- **Weights and tokens.** `Weights` reads F16, BF16 and F32 tensors, drops the `model.` prefix, and gives a tensor as f32 or as
  f16 bytes, transposed on request. `Tokens` truncates at `max_tokens` (1,024), never pads, and applies the model's prefixes.

- **The embedder (`local.rs`).** `LocalEmbedder` is one interface over a private `Engine` trait, with one impl per path, so a
  different engine replaces an impl and nothing else. `embed_ids` takes one batch of at most `TOKEN_CAP` (4,096) tokens and
  returns unit vectors; it checks every id against the vocabulary before anything reaches an engine. `embed_docs` and
  `embed_query` are conveniences at a 2,048-token budget. Tokens are flat, with no padding: token t of the batch is row t,
  and the softmax is streamed, so no S × S matrix exists. Word embeddings are gathered on the CPU, so the table costs no
  VRAM and fits any adapter's largest binding.
- **The GPU path (`gpu/`).** ModernBERT's forward pass in WGSL on raw `wgpu`: `lineart`, `norm`, `rope`, `attn`, `glu` and `add`.
  Weights stay f16 where the adapter has `SHADER_F16`, with an f32 sum (`kernels-f16.wgsl`); otherwise f32, at about 0.7× the
  speed and 2× the weights' VRAM. Linear weights are always transposed. Sizes come from `ModelConfig`: the model's shape
  is written in front of `kernels.wgsl` as constants, because WGSL sizes a function's arrays with constants only, and a
  kernel's input and output widths are pipeline overrides. There is one submit per layer, each waited for up to 10 s, so
  there is a pause point between any two layers and no submit can run into a driver's watchdog (Forward's `worst_submit`
  reports the longest). The shaders run without `wgpu`'s bounds checks, which cost 14 to 29 % on the Radeon; `embed_ids`
  bounds every id and length, and `load` checks each weight's shape. `load` refuses an adapter whose limits don't fit a
  buffer. A timeout, the device-lost callback, any
  uncaptured error, or the panic `wgpu` raises out of `poll` on a lost device all end in `EmbedFail::DeviceLost`, so the
  caller can take the CPU path. `libvulkan` is opened at run time, so a machine with no loader has no adapters.
- **The CPU path (`cpu/`).** The same forward pass in pure Rust, for machines with no usable GPU and for a lost device, and it
  must agree with the GPU path because vectors from both land in one index. `gemm` does the matmuls and the rest runs row by
  row, on a `rayon` pool of `threads` that the embedder owns. The non-linear kernels are built twice on x86-64, baseline and
  AVX2 + FMA, and chosen at run time; the build itself stays baseline. aarch64 uses baseline NEON. No AVX-512: it ran slower
  here. `worst_submit` is zero on this path.

- **The download (`drgnx-ratatoskr/src/search/`).** `download` fetches exactly a table row's files into `<cache>/models`, from
  `drgnx-search-model-mirror` or the Hugging Face host at `{base}/{repo}/resolve/{revision}/{file}`, and only with a `Consent`
  whose model and bytes match; the consent is kept in `runtime.db`'s `kv` (`search.consent`). The target of `resolve/` is a
  signed URL on another host, so redirects are followed by hand: at most 3, to https only (plain http only between loopback
  addresses, for a local mirror and the test host), with no credentials in the URL. Each file is written to `<file>.part`,
  verified and renamed. A failed run keeps its parts, and the next one asks `resolve/` again and resumes with `Range`. Nothing
  retries: `Offline` is reported once, and the hub tries again at its next start or on `search/model-download`. Proxies come
  from the environment, through `bifrost::upstream::Upstream::get`. `test-tiny` (test-hooks builds, `test/fixtures/test-tiny/`)
  is a model of no weights for the flows that need no inference. The download's stall limit runs on the hub's clock.

### The index: tier 1, tier 2 and the embed worker

- **Tier 1 (`hrafn::index::refresh`).** The file list against the store's blobs: rows (chunks, FTS, symbols) are rebuilt
  only for files whose blob changed, all of them after a chunker change, 64 files to a transaction; files gone from the
  list leave the store. Vectors are keyed by content, so a branch switch back embeds nothing. `vec.last_used` is a
  logical clock (one past the store's highest), moved when a vector is written and when tier 1 writes a chunk that
  refers to its key; `collect` keeps unreferenced keys up to twice the live set, the least recently referenced going
  first. A vector row holds the sign bits and then the int8 values of `urdr`'s `quantize` (`bits` = 8).
- **When tier 1 runs (`hrafn::fresh`).** `Settle` is a pure core over the watcher's events: a change under the gitdir is
  due once `index.lock` is gone and the gitdir has been quiet for 2 s; a saved file once it has been quiet for 30 s.
  `NotifyWatch` (feature `host`, the `notify` crate) feeds it. A project without watches diffs the blobs at query time
  (`fresh::diff`, at most 2,000 differences named).
- **The device (`hrafn_embed::device`).** A cached choice whose key (model, `ENGINE_VERSION`, each adapter's name and
  driver) matches; on battery the CPU path with nothing measured or cached; otherwise the first adapter of `order`
  (software adapters dropped, discrete and Metal before integrated) that passes its self-check and the CPU path are
  probed on the model's `data/<model>.selfcheck.json`, and the faster wins. A cosine under 0.999 puts a device out; when
  the CPU path misses too, nothing embeds and only keyword and symbol results remain.
- **Pacing (`hrafn_embed::pace`).** A batch's worst submit over 8 ms halves the token budget, under 4 ms doubles it, up to
  `TOKEN_CAP`; it starts at 2,048 and never stays below the chunk that leads the next batch.
- **The embed worker (`ratatoskr embed-worker`, `drgnx-ratatoskr/src/search/worker.rs`).** A child process, the only one
  that opens a GPU, started by `WorkerEmbedder` on demand: JSON lines in (`{"id", "kind": "doc"|"query", "texts"}`) and
  out (`{"id", "vectors"}` or `{"id", "error"}`), first `{"ready": {"device", "name", "why"}}`, and `{"fallback": {"from",
  "reason"}}` when a lost GPU sends the batch again on the CPU path. A query that arrives during a request is answered
  before its next batch. It runs at nice 10, caps its address space at 2 GiB on the CPU path (llvmpipe could not start a
  thread under the cap, so the GPU path runs without it). On the GPU path it reads its peak resident memory (`getrusage`'s `ru_maxrss`, so on macOS too)
  before each batch instead: over 1.5 GiB it answers the request with the reason and `"exit": true` and exits, and the hub
  starts a fresh worker for the next request (no crash is counted, nothing is retried). It also exits after 300 s idle and
  at the end of its stdin. The hub
  starts it with `--device auto` on AC and `--device cpu` on battery; a query uses whatever worker runs. A worker that dies
  inside a request is started again and the request sent again, once.
- **A project (`search/project.rs`).** The store is `<state>/code/<id>.db`, `id` the first 16 hex characters of the
  sha256 of the main checkout's real path, so a linked worktree shares its main checkout's store. A root the deny-list
  refuses is refused before anything is listed; inside an allowed root every file is checked again. Tier 2 sends requests
  of 8 missing keys to each embedder; between requests it waits while typing holds (3 s from the last `note_typing`) and,
  on battery, until AC or `index_now`. Its state (`Stopped`, `Idle`, `Running`, `Typing`, `Battery`, `Failed`) and the
  vectors written are published for `search/status`. Its embedders are `DocEmbedder`s: the built-in model's worker and
  each server that answers, every one filling its own model's `vec` rows.
- **The query (`hrafn::query`).** Lists from the routes, fused by RRF (k = 60): an exact one-identifier query pins its
  definitions first (non-test before test, then by kind); prefix and trigram name matches from the identifier-like
  tokens of a question add a list that is never pinned; a token that names a file adds a path list; `bm25(chunk_fts, 5,
  5, 2, 1)` ranks identifier phrases on `symbols` and words over `doc` and `body`; vectors are scanned by Hamming
  distance over the sign bits and the nearest 200 re-ranked by their int8 values. A test or generated file keeps half
  its score. Hits in files changed since indexing are looked for again by their first line, else their symbol (20 files,
  50 ms). The scope (`code`, which holds tests below it, `tests`, `docs`, `all`) filters by file class. Every answer has
  the lag line.
  A query reads indexes and small tables, never the `chunk` table (its rows hold their text): the lag's counts run on
  `chunk_embed`, name prefixes on `symbol_name_nc` (`like` ignores case, so the index has the same collation), path
  tokens on `file`, and the vector scan reads `vec` alone, looking a chunk up only for a vector that can enter the best
  200. Each is a plan test in `hrafn/tests/query.rs`. Store schema 2 adds the two indexes.
- **The methods (`search/methods.rs`).** `Hub` (`Front::search`) opens a project on first use of its root and runs its
  driver (`Project::tick` every 500 ms on the hub clock, dropped with the project); `search/query` refreshes tier 1 when
  the files changed (the watcher's events, else a blob diff), picks the model (`search::prefer`), embeds the question
  with it and answers; `search/status`, `search/index`, `search/embedders`, `search/model-download` (consent checked
  against the model's size; the projects open again once it lands) and `search/typing` are the others. All are the
  user's: an agent has no search method. A project's globs are `.drgnx/search.eld` (a file that does not read turns
  its search off) and the editor's per-project `drgnx-search-{include,exclude,off}` (`overrides::PER_PROJECT`).
- **Servers on request (`search/servers.rs`).** `search/server-plan` shows what starting TEI or Ollama would run (it
  writes and runs nothing); `search/server-start` needs `confirm: true` and answers the provider entry for the settings'
  provider table (the hub writes no settings: the editor's writer adds it); `search/server-stop` stops it. TEI is a
  podman Quadlet `drgnx-tei.container` under `$XDG_CONFIG_HOME/containers/systemd/` (CPU image, or the GPU tag of the
  card when the NVIDIA CDI device is present; 4 GiB or 2 GiB memory cap, loopback port 8087, a named cache volume, no
  `[Install]`): Linux with podman and a systemd user session, and not inside a container. Ollama needs `ollama` on the
  PATH; its service starts only when it does not answer (`systemctl --user`, or `launchctl` on macOS), then the model
  is pulled. Nothing in the hub's idle paths reaches a start. With test-hooks the runner only records the commands in
  `$XDG_STATE_HOME/drgnx/servers-test.log`. The macOS Ollama start (`launchctl start com.ollama.ollama`) is unverified
  on a Mac.
- **The eval (`hrafn::eval`, `ratatoskr search eval`).** `eval gen ROOT` makes questions from the project's own history
  (commit subjects without ticket ids, dropping those that name an identifier; the answer is the top-level forms the
  commit changed, found again at HEAD by name) into `runtime/crates/hrafn/eval/<project>/{dev,test}.jsonl`, which are
  frozen once written. `eval run ROOT --model ID --device cpu|gpu:ADAPTER` indexes the project into a scratch store,
  embeds it in-process with the model, asks the set and prints MRR@10 and nDCG@10 (chunk level) and recall@5/@10 (file
  level) with bootstrap intervals per stratum, and writes the run as JSON. `eval compare A.json B.json` is the gate:
  the lower bound of the paired MRR@10 difference must be at least -0.01 overall and -0.03 per stratum, the index has no
  coverage error and exact-symbol recall@1 is 1.0. It needs no hub.
- **The MCP tool (`search/mcp.rs`).** A session whose `mcp/session` came while `drgnx-agents-mcp` holds `search` gets
  `search.sock` beside `mcp.sock` (recorded in the session's row, so it is bound again at a restart and closed with the
  session): the `search` tool (`query`, `scope`, `k`), pinned to the session's `cwd`. The agent's `mcpServers` list it
  as `drgnx-search`. `ratatoskr search mcp [ROOT]` serves the same tool on stdio for an agent outside drgnx, its
  questions going to the hub; `ratatoskr search index|query` are terminal clients of `search/index` and `search/query`.
- **Servers as embedders (`embed.rs`, `Gate::embedders`).** The providers of kind `tei` and `ollama` with the `embed`
  capability embed through the hub's own gateway listener (`/p/ID/embed`, `/p/ID/api/embed`), so each request is in
  `spend`. An Ollama provider needs the model the `embed` role names for it, and its model name is
  `ollama:<provider>:<model>` (TEI's is `tei:<provider>`). A query to a server carries `Instruct: <task>\nQuery:<q>`;
  documents go plain. `search::prefer` picks the model a query uses: an answering server with at least 95 % of the live
  chunks covered, else the built-in model (unless `drgnx-search-builtin` is nil), else an answering server whatever it
  covers. `embed::answered_family` is the doctor's probe of which address family answers; `localhost` of a local
  server's URL is used as `127.0.0.1`. The hub never starts a server. The entity embedder (`embed::run`) fills with the
  first embedder in line that answers, a server before the built-in model, and each model keeps its own vector
  (`entity_vec` is keyed `(n, model)`), so a server that comes back finds its vectors still there.
  `ratatoskr-mock embed` is the test stand-in for TEI and Ollama (`tests/search_prefer.rs`).

Tests read the real models from a read-only volume (`DRGNX_TEST_MODELS`) and **fail** when it's unset; they never skip.
`tests/fixtures/<model>.json` holds what CI can't make: reference vectors for token-id lists of 1, 2, 128, 129, 130, 1,023
and 1,024 tokens (the edges of the 129-token local span and of the 1,024 cap), and for 4 chunks and 2 queries. Those come
from a direct forward pass in Transformers, f32, batch 1, CLS, L2-normalised. `data/<model>.selfcheck.json` is one fixed
text of 167 tokens, longer than the local span so both attention paths run, with its vector.

GPU tests name their adapter in `DRGNX_TEST_ADAPTER` (a substring of its name) and fail when it's unset or matches nothing;
production skips software adapters, a test's named adapter doesn't. `tests/parity_gpu.rs` runs the real shaders on llvmpipe, Mesa's
software Vulkan, so no GPU is needed; `full_references_*` (`#[ignore]`) are for a real GPU, as are the rows of `tests/timing.rs` (a timing file: the real-time lint exempts it),
which print throughput, query time and the stall a second process sees on the same card, and assert nothing. Its `bench_cpu`
row prints the CPU path's figures and needs no GPU. `tests/parity_cpu.rs` holds the CPU path against the references, and
`cpu_and_gpu_agree` in `parity_gpu.rs` holds the two paths against each other.

## Building and installing Ratatoskr

Users get the binary from install.sh and `drgnx update`; both call `drgnx runtime` (bin/drgnx, plain bash):

- `drgnx runtime build [--install] [--prefix DIR]`: `cargo build --release --locked -j N --manifest-path
  runtime/Cargo.toml -p drgnx-ratatoskr`, with **no** `test-hooks` feature. The cargo is the one in `<data>/cargo`
  (install.sh records it, with `RUSTUP_HOME`/`CARGO_HOME` lines for a private rustup), else `cargo` on `PATH`; neither:
  exit 1, "no Rust toolchain: run install.sh again". `CARGO_TARGET_DIR` is `<cache>/ratatoskr-target`, `CARGO_HOME`
  `<cache>/cargo` unless the record sets it, `DRGNX_BUILD_COMMIT` is the checkout's HEAD (plus `-dirty`) and
  `DRGNX_CHECKOUT` the checkout, so `ratatoskr version --json` says what it was built from. On Linux with a user systemd
  the build runs in `systemd-run --user --scope` with `MemoryMax` min(jobs x 1536 MiB + 1 GiB, available - 1 GiB) and
  `MemorySwapMax=0`; without one, `-j` alone and a note. macOS has no cap.
- `drgnx runtime install [--prefix DIR]`: refuses a binary whose `version --json` says `"test_hooks": true` (or says
  nothing), copies it to `<data>/bin/ratatoskr.new` and renames it to `ratatoskr` (a running hub sees a new inode at
  its resolved path); with `--prefix` links `DIR/bin/ratatoskr` and `DIR/bin/rtsk`.
- `drgnx update` runs `runtime build --install` as its third step; a failure rolls the update back
  (`DRGNX_UPDATE_RUNTIME_CMD` replaces the step in tests). The doctor's `ratatoskr` check (group Agents) reads
  `ratatoskr doctor --json`: no binary, test hooks or a bad socket directory fail; a failed runtime update, a binary or
  hub older than the checkout, or an Emacs SQLite in 3.7.0 to 3.51.2 (WAL bug) warn.

Tests set `DRGNX_INSTALL_RUNTIME=none` so install.sh runs no toolchain probe or build; `bin/drgnx test --install` builds
for real.

## Fuzzing

`runtime/fuzz/` is a cargo-fuzz crate with its own `[workspace]` (the product workspace excludes it). It builds on
nightly only: the pin is `nightly-2026-10-15`, set by the CI job and by local runs, never by a `rust-toolchain.toml`
(a toolchain file would make a plain `cargo` there install a nightly). cargo-fuzz needs a C++ compiler for libFuzzer
(`g++`: CI's `fuzz-build` job runs on the Ubuntu runner, which has it; 60 s a target on a push to `main` or `ci/*`, 10 minutes a target
daily, `fuzz_minutes` on demand: [ci.md](ci.md)). CI builds every target once (`cargo fuzz build`, the build `cargo fuzz
run` makes) and passes each of the four shards its targets' binaries as an artifact (`fuzz-bins-N`, one day); a shard
runs each binary as `cargo fuzz run` does (`-artifact_prefix=runtime/fuzz/artifacts/<target>/`, the corpus directory,
`ASAN_OPTIONS=detect_odr_violation=0`).

| Target | What it feeds |
|---|---|
| `line_codec` | arbitrary bytes, cut into chunks of a size the input picks, through the client line codec, then `parse_strict` on every line |
| `request_prelude` | a line through `dispatch::prelude` (steps 1 to 5, no handler) for every class and several protocol states |
| `hello` | hello params decoded from arbitrary JSON, then `hello()` against a fixed cap: as given, with the correct proof, on a main and on an agent socket, and a second hello |
| `connect_head` | bytes as a proxy request head: the blank-line search, the exactly-`CONNECT target HTTP/1.x` line, then `parse_target` on the target (gleipnir's `fuzzing` feature exposes the entry point) |
| `absolute_head` | bytes as a web proxy's plain-HTTP head: the blank-line search, the absolute-form line and headers, `parse_target`, then the rewritten head, which must have one blank line (at its end), no bare CR or LF, and end in `Connection: close` |
| `host_target` | text through `parse_target`; a success must `Display` back to a string that parses to the same target |
| `sbpl_quote` | text through `sbpl::quote`; a success must read back through `sbpl::sexp` as one string equal to the input |
| `bwrap_version` | text as `bwrap --version` output through `parse_version` and `version_at_floor` |
| `inner_spec` | bytes decoded as the helper's `InnerSpec` (`deny_unknown_fields`); a success must re-encode and decode to the same value |
| `mcp_message` | bytes as the lines of one MCP connection through `mimir::serve` with the 16 `norn` tools over a schema-6 `work.db` (a file from the oracle's fixture, shared by all inputs), as given and after a legacy `initialize` handshake; every answer line must be JSON |
| `jsonrpc_parse` | a line through `jsonrpc::parse` and mimir's `lenient_id`: an error is `-32700` (only for non-JSON) or `-32600`; a parsed request or result has the id `lenient_id` reads |
| `text_one_line` | text (and a length limit and the `header` flag from the first two bytes) through `text::one_line`, `coord_line` and `cut`: no `CONTROL` character (`one_line`: no newline, tab or CR either), never over the limit |
| `put_parsed` | bytes as `graph/put-parsed` params: the registry's decode, then `parsed::dirs` and `put` on an in-memory schema 7 in a tx that is dropped; nothing may panic |
| `task_write_args` | JSON (`@T` is a seeded task's id) as `task_write`'s arguments over a schema-7 store: check, typed decode and run of every op; a refusal is an answer |
| `graph_read_args` | the same for `graph_read` (neighbors, path, history, who_touched) |
| `trust_fence` | text, author and project (split at NUL) through `trust::fence`: exactly one opening tag at the start and one closing tag at the end, ASCII case ignored |
| `sqlro_sql` | SQL through `graph/sql`'s runner on a WAL store with a pending WAL: the database file and the WAL stay byte for byte as they were (no write, no checkpoint), and the answer comes within the 50 ms deadline plus 100 ms |
| `sse_usage` | bytes through `bifrost::usage::Scanner`, whole, byte by byte and in pieces of sizes the first two bytes pick: the same `Usage` every way, no panic |
| `provider_merge` | a body and OpenRouter restrictions (flags, `only` and `ignore` lines, then the body) through `rewrite::body`: when the restrictions apply, the answer is a JSON object whose `provider` carries all of them; with nothing to apply the bytes stay |
| `gateway_admit` | a request head (token class, listener, header style from the first byte; target and headers as lines) through `admit::head`: an admission belongs to its listener, takes a path of its class and stays under the body cap; a refusal is a 4xx with a JSON body |
| `huginn_read` | bytes through `huginn::read::read_all` under the default limits and under tight ones (512 bytes, depth 6): no panic; a refusal's span inside the input; every node's span inside its parent's, on character boundaries; nesting within the limit; the source of each top-level datum reads alone to the same datum |
| `bridge_line` | bytes (the first picks a line limit) through the bridge's `read_bounded`; every kept line is within the limit and has no newline; `classify` on each text line and `id_in_prefix` on the line cut at every position: no panic |
| `acp_update` | JSON (an object, or an array of them) as an agent's `session/update`s through the session reducer (`agents::session::fuzz_apply`, feature `fuzzing`): each update counts once in `seq`, no panic |
| `report_submit` | JSON as `report_submit`'s arguments over a schema-7 store (as `task_write_args`) |
| `saga_plan` | text through `saga::plan::parse` and `render`: the output equals the input |
| `saga_deferred` | the same through `saga::deferred` |
| `saga_org` | the same through `saga::org` (`board.org`) |
| `cdp_envelope` | bytes as one browser connection through heimdall: NUL-split under a limit the first byte picks, each message's first byte choosing the agent, the browser or the agent's close; every envelope parses or is refused without a panic, whatever goes to the browser is a command with an id and no NUL, and no refused method from the agent reaches it; the same bytes through the frame decoder whole and in two pieces give the same frames |

The seed corpus in `fuzz/corpus/<target>/` is the request lines of the conformance rows (phase 1; for `mcp_message` and
`jsonrpc_parse` the JSON-RPC lines the `mcp/*` and `bridge/*` rows send), the unit tables (gleipnir's targets) and, for
the gateway's targets, the SSE fixtures (`test/fixtures/sse`) and a few hand-made heads and bodies; for `huginn_read`
it is huginn's hand corpus (`test/fixtures/huginn/corpus/`, copied as `accept-NAME` and `refuse-NAME`); for
`cdp_envelope` it is heimdall's transcripts (`crates/heimdall/tests/data/*.jsonl`, one seed each: `0` agent, `1`
browser, `2` close before each message, NUL after). The
bridge's `classify`, `id_in_prefix` and `read_bounded` are private to `mimir::bridge`; mimir's `fuzzing` feature
exposes them through `bridge::fuzzing` for `bridge_line` (seeds: the `mcp_message` corpus behind a limit byte). A run adds files to the
corpus directory, so run on a scratch copy and keep the repository's seeds as they are.

Local run (keep the toolchain and the crate cache out of `~`: point `RUSTUP_HOME` and `CARGO_HOME` at a scratch
directory):

```
export RUSTUP_HOME=/path/to/scratch/rustup CARGO_HOME=/path/to/scratch/cargo
rustup toolchain install nightly-2026-10-15 --profile minimal
cargo install cargo-fuzz --locked
cp -r runtime/fuzz/corpus /path/to/scratch/corpus
cargo +nightly-2026-10-15 fuzz run line_codec --fuzz-dir runtime/fuzz /path/to/scratch/corpus/line_codec \
  -- -max_total_time=60 -rss_limit_mb=2048
```

A crash is written to `runtime/fuzz/artifacts/<target>/` (ignored by git). Commit the input as a regression test in
`runstav` (or the crate that owns the parser) before fixing it.
