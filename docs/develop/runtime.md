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
| `huginn` | a reader for the data subset of Emacs Lisp: literal values with byte spans, never evaluated, every reader macro refused; settings files and a serde deserializer (feature `serde`); generic ([settings.md](settings.md#the-data-subset)). `drgnx-ratatoskr` reads `settings.el` and the shipped `runtime-defaults.el` with it ([hub.md](hub.md#settings)) |
| `hermod` | an ACP client on `agent-client-protocol-schema`'s types and runstav's line codec (no SDK role framework): stamped updates, message ids, fork at a message, exactly-once exit; generic (agent system part 1, Task 1) |
| `saga` | the org folder's record formats (plans, ledgers, DEFERRED, the build board, `board.org`) parsed and rendered back byte-exact, turned into graph operations; pure, `pulldown-cmark` for Markdown (agent system part 1, Tasks 5, 6, 14) |
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
`cargo check --locked --manifest-path runtime/Cargo.toml --target aarch64-linux-android -p runstav -p draugr -p eitri -p gleipnir -p drgnx-ratatoskr`.
`drgnx-ratatoskr` depends on `urdr`, whose bundled SQLite is C, and compiling C for Android needs the NDK. A type-check
does not link, so without the NDK stub the C compiler and archiver: `CC_aarch64_linux_android=/usr/bin/true
AR_aarch64_linux_android=/usr/bin/true` (the Rust is still checked in full; only the C object files are fake).

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
- **`paths`**: `data_dir`, `socket_path`, `cap_path` (`hub-HASH.cap`), `lock_path` (`hub-HASH.sock.lock`) and
  `backend_socket_path`, the Lisp backend's private socket `<socket dir>/hub-HASH.d/backend.sock` (one per data dir, so
  two data dirs sharing a runtime dir never collide). Over 103 bytes it goes to `<tmp>/drgnx-hub-UID/hub-HASH.d/`, and
  past 103 bytes there too it is `PathError::TooLong`. `session_dir(env, socket, SID)` is one agent session's
  directory, `<socket dir>/s/SID/` (design §4.2): it holds that session's sockets, `hub.sock` (agent class) today and
  `mcp.sock`, `search.sock` and `gateway.sock` later, and never the backend's (review M10): a sandbox is given `s/SID`
  alone (Gleipnir's run parent is `s/`), so nothing bound into it reaches `backend.sock`. Over 103 bytes for its longest
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
  Callers pass fixed candidates (bwrap, `sandbox-exec`, git); `PATH` is never searched.

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
the caller. The port keeps what the Lisp gateway (`core/drgnx-gateway.el`) did, with the changes listed in the
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

## The conformance harness

`domr` runs **scenarios** (data) against a hub binary: a process that answers the hub protocol on its socket.
Every scenario gets fresh temporary roots under `/tmp/rtsk-XXXXXX/` (`/tmp`, not `$TMPDIR`, so macOS socket paths stay
short) holding `home run state data config cache tmp`, and the hub's `HOME`, `XDG_*`, `DRGNX_DATA_DIR`,
`DRGNX_CONFIG_DIR` and `TMPDIR` point there. A hub is started with `--parent-pid` of the harness, so it ends with the
test, and `RATATOSKR_SUPERVISOR=none` keeps a supervisor out of it. Only `PATH` and `DRGNX_EMACS` are inherited.
`DRGNX_CONFORMANCE_ROOTS=DIR/PREFIX` makes the roots `DIR/PREFIXXXXXXX/` instead. Keep DIR short: the socket path
must stay within 103 bytes.

```
domr --target lisp|ratatoskr --hub-bin PATH --scenarios DIR
                  [--lisp-hub PATH] [--fake-backend PATH]
                  [--only GLOB] [--only-tag TAG] [--require-all] [--perf OUT.json]
domr connect-as --socket PATH
```

- `--target lisp` runs only the `v0` rows, against the Lisp hub (through `test/conformance/lisp-hub.sh`, which maps
  `serve --foreground --parent-pid PID` to `emacs --batch -Q -L core -l drgnx-hub -f drgnx-hub-main` using
  `$DRGNX_EMACS`). `--target ratatoskr` runs every row, the `v0` ones too: they must pass both ways.
- `--lisp-hub` and `--fake-backend` are what a `lisp-backend` / `fake-backend` row hands Ratatoskr as
  `DRGNX_RATATOSKR_BACKEND`; with `--target ratatoskr`, a `v0` row gets the Lisp hub as its backend too, so the v0 rows
  run through the front (`--target ratatoskr --lisp-hub test/conformance/lisp-hub.sh --only-tag v0`). A row with
  neither runs with the backend `missing` (the harness sets no `DRGNX_DIR`).
- **The fake backend** (`runtime/target/debug/ratatoskr-fake-backend`, `conformance/src/bin/`) stands in for the
  Lisp backend: it serves `DRGNX_HUB_SERVE_SOCKET` the v0 way, closes a connection whose first line is not `{"auth":
  DRGNX_HUB_SERVE_SECRET}` (as the Lisp backend does; that line is not logged), appends every other line it gets to
  `$STATE/fake-backend.log` and writes its environment as a JSON object to `$STATE/fake-backend.env`. It answers from
  the JSON script in `DRGNX_FAKE_BACKEND_SCRIPT` (a row's `start` `env`): `{METHOD: ANSWER}`, ANSWER an object with
  `result` or `error` (sent with the request's id), a string (the whole line, `$ID` the id), `null` (never
  answered), `{"exit": CODE}` (it exits) or `{"from_file": PATH}` (the answer object is read from PATH at each call,
  which a row rewrites meanwhile). Without a script: `ping`, `status` (`gateway_port` and `registrations`
  0), `subscribe` and `coord/notify` answer, anything else is an error. When the script's `trigger` method
  (`coord/notify`) is called, it sends its subscribers the events of the file `events` (a JSON array of `{event,
  data}`), then `flood` `card` events with a title of `flood_size` bytes (65536). It ends with its parent
  (`DRGNX_HUB_PARENT_PID`) unless the script says `"ignore_parent": true`. An entry `{METHOD: {"call_front":
  {"method": M, "params": P}, "then": ANSWER}}` makes it call M on the front's main socket as a proven user (it reads
  `hub-HASH.cap`, answers the challenge with the HMAC proof, and keeps that one connection for later calls), wait up to
  10 s, log `front-answer {...}`, and answer METHOD with ANSWER (`"$front"`: the front's own answer). It logs
  `notification {"method", "params"}` for every `coord/notify` and `budget` it receives, and answers no line without
  an id (the front's coalesced `coord/notify` is a notification); its front connection never subscribes (the front
  would refuse it: the seam rule).
- `--only GLOB` matches the scenario name (`*` and `?`); `--only-tag TAG` the rows that require the tag.
- Output: one `PASS name`, `SKIP name (reason)` or `FAIL name: step N (VERB): what` line per scenario, then
  `N passed, N skipped, N failed`. Exit 0 only with no FAIL. With `--require-all` a SKIP fails too, except `linux` /
  `macos` skips on the other host, `sudo` skips where neither root nor passwordless sudo exists, `perf` rows
  without `--perf`, and rows with a `drop_ptrace` step where the harness has `CAP_SYS_PTRACE` and no `setpriv`.
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
| `start` | `hub` (a name, default `hub`), `bin` (`"under-test"`, `"lisp"` or an absolute path, `$ROOT` being the root: a copy `install_bin` made), `args`, `env`, `same_root_as`, `wait` | start `BIN serve --foreground --parent-pid <harness pid> ARGS` in a fresh root (the `root` step's, or another hub's root); with `wait` (default true) it waits up to 10 s until `ping` answers; `wait: false` is for a start expected to exit |
| `root` | none | make a root with no hub in it (`$ROOT $SOCKET $LOCK …` name its paths). The `run`, `start` and file steps after it work in that root; what `ensure` started there, detached, is stopped when the scenario ends (the lock file's pid, while its start time is the recorded one) |
| `run` | `capture`, `bin`, `args`, `env`, `hub`, `concurrent`, `retry_ms`, `drop_ptrace`, `expect_code`, `expect_stdout`, `expect_stderr` | run `BIN ARGS` to completion (30 s) in the hub's root (else the `root` step's): `ensure`, `stop`, `status`, `restart`. `DRGNX_HUB_PARENT_PID` is the harness's, so a hub it starts detached ends with the harness. `concurrent: N` runs N copies at once, each of which must satisfy the expectations; `retry_ms` repeats the run until they hold. The capture is `{stdout, code, json}`; `expect_stdout` is a string the output contains or a pattern for its JSON (`$capture:NAME` / `$NAME` work in both); `expect_stderr` is a string the error output contains. `drop_ptrace: true` runs it without `CAP_SYS_PTRACE` where the harness has it (bit 19 of `CapEff`: root on a CI host, `--cap-add`), under `setpriv --inh-caps=-sys_ptrace --bounding-set=-sys_ptrace`, since the capability sees through a non-dumpable hub; where `setpriv` is missing the row is skipped with that reason. Podman's default set lacks it, so rows run as they are there |
| `rename`, `remove` | `from`, `to` / `path` | rename-replace a file, remove one (an update of a binary on disk) |
| `install_bin` | `to` | copy the hub under test to `to` (0755), a binary a scenario can replace |
| `connect` | `conn` (default `c`), `hub`, `socket` (`"main"`, `"backend"`, the Lisp backend's own socket, `"agent:SID"` or `"path:STRING"`, a captured path with `$NAME` substituted), `as` | open a connection; lines are buffered per connection. `"user"` (default) on a v1 target performs the `hello` macro with a valid proof and consumes the `challenge`; on `--target lisp` it does nothing. `"service"` and `"raw"` connect and read nothing first (the `challenge`, if the socket sends one, stays buffered; the `mcp.sock` of a session sends none). `"other-uid"` needs `sudo`: it runs `connect-as` as another uid, and makes the root directory 0711 for it |
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
| `expect_closed` | `conn`, `within_ms`, `silent` | the hub closed the connection; with `"silent": true`, without sending a line first (a refusal answers nothing) |
| `expect_silent` | `conn`, `for_ms` (300) | no line arrives |
| `kill` | `hub` or `pid`, `signal` (`TERM KILL STOP CONT INT HUP QUIT USR1 USR2`) | signal the hub (or a captured pid) |
| `expect_exit` | `hub`, `pid` or `conn`, `code`, `signal`, `within_ms` (10000) | the process ended with this status (a `pid` must be one the scenario spawned; a `conn` one a `spawn_conn` started) |
| `file` | `path`, `exists`, `mode`, `owner` (`"user"` or a uid), `json`, `contains`, `count` (1), `at_most`, `lacks`, `within_ms` (5000) | inspect a file the contract names. A `*` or `?` in the last component picks the first matching name (`hub-*.jsonl`). `contains` waits up to `within_ms` until the file's text holds the string `count` times (a log is written a moment later), and then no more than `at_most` times when given (a line logged once); `lacks` is a string the text must not hold |
| `proc` | `pid` (a number, `$PID(hub)` or a capture), `part` (`"argv"`, `"environ"` or `"launch_env"`), `contains`, `lacks`, `except_var`, `refused`, `drop_ptrace` | a process's arguments, or the environment it started with, as the system shows them to the same user: `/proc/PID/cmdline` and `/proc/PID/environ` on Linux, `sysctl kern.procargs2` on macOS (which has no `/proc`). `launch_env` is the environment the harness gave a hub it started at exec (exactly those variables, nothing inherited): a non-dumpable hub's own `/proc/PID/environ` is not readable. An empty read fails (it would pass any `lacks`); `contains` is a string one of the entries holds, `lacks` one none may hold, except the entry `NAME=…` that `except_var` names. `refused: true` (with `environ` and `drop_ptrace`) checks the opposite: the read is refused (EACCES) to a process of the same user without `CAP_SYS_PTRACE` (`cat` under `setpriv` where the harness has it), which is how a non-dumpable process looks; on macOS (`PT_DENY_ATTACH`, which only an attach would show) it checks nothing |
| `write_file` | `path`, `text` or `json` (a JSON value; `{"$repeat": TEXT, "times": N}` expands, as in `send`), `mode` (octal string) | set up an input |
| `sqlite` | `path`, `sql_file`, `sql: [...]`, `query`, `expect` | set up a database (bundled SQLite): the statements of `sql_file` (a schema such as `$SCENARIOS/../fixtures/work-db-6.sql`), then `sql`; `query`'s rows, as `[[value…]…]`, must match the pattern `expect` |
| `spawn_conn` | `conn`, `argv`, `env`, `cwd` | start a child (for example `ratatoskr mcp-bridge …`) whose stdin and stdout are connection `conn` for `send` / `expect`. `env` is its whole environment (`{}` is empty, never the harness's). Its stderr is kept in `spawn-conn-CONN.err` in the root; it is killed at the scenario's end. `expect_closed` means its stdout closed; `expect_exit` with `conn` reads its status |
| `sql_expect` | `path` (`$DATA/work.db`), `sql`, `rows` | run a read-only query and match its rows (`[[value…]…]`) against the pattern `rows` |
| `capture_file` | `path`, `capture`, `json_path`, `within_ms` (5000) | read a JSON file (waiting for it to exist) and capture the value at `json_path` (dot-separated keys and array indexes, `$` or absent: the whole file), for example a socket path a helper wrote |
| `backend_log` | `hub`, `expect_line`, `expect_no_line`, `count` (`at_least`, `at_most`), `within_ms`, `for_ms` | lines the fake backend received (`$STATE/fake-backend.log`): a substring, or a pattern for lines that are JSON; `count`: after `for_ms`, how many lines match is within the bounds |
| `pid` | `capture`, `alive` (true), `within_ms` (5000), `stays_for_ms` | a captured pid is (or is no longer) running; a reused pid does not count. With `stays_for_ms` a pid that is running must stay so that long (a signal sent a moment ago has landed by then) |
| `class_matrix` | `table`, `args`, `env`, `agent`, `last`, `within_ms` | every method of `table` (`{method: [classes]}`, `class-matrix.json`) gets `{}` from `user` (a valid hello), `service` (no hello) and, with `agent: SID`, `agent` (that session's socket, which `args` such as `["--agent-socket", "s1:j1"]` makes the hub serve). A listed class must not get `not-allowed`; any other must. The step starts its own hubs with `args` and `env`: one for the table, and for each method of `last` (default `restart`, `shutdown`, which a user call runs) one per class |
| `bad_params` | `conn`, `registry`, `within_ms` | every method of the registry file (`methods.json`; a relative path is from the current directory) with required params gets `{}` and a wrong type for its first required key (`true` where a list belongs, else `[]`) on `conn`; each must be `invalid-params` with a `path` (one of the required keys, then that key). `hello`, and a method whose classes leave out `user` (`mcp/attach`), go on a fresh connection (service class) each time |
| `measure` | `name`, `repeat`, `steps` | times the steps, `repeat` times, and records the milliseconds for `--perf` |

**`ratatoskr-mock`** (`conformance/src/bin/`, std only; `$MOCK` is its path, beside `domr`) stands in for the network:

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
  hangs up before the answer ended. It ends when `--parent` is gone.
- `proxy [--log FILE]` prints `MOCK-PROXY-PORT N`; `CONNECT host:port` is logged (`{"connect": "host:port"}`) and
  tunnelled, anything else gets 405 (`{"refused": "METHOD TARGET"}`).

**Variables** in strings: `$MOCK $ROOT $HOME $RUN $STATE $DATA $CONFIG $SOCKET $SOCKET_DIR $BACKEND_SOCKET $CAP $LOCK $PID(hub)
$HARNESS_PID` (of the step's `hub`, else the latest started), `$SCENARIOS` (the scenarios' directory, absolute: its
`fixtures/`), `$EMACS` (`$DRGNX_EMACS`, else `emacs`), and `$NAME` for a capture. A string that is just `$PID(hub)`,
`$HARNESS_PID` or a capture keeps its JSON type (a number stays a number). Agent sockets are
`$SOCKET_DIR/s/SID/hub.sock` (`paths::session_dir`).

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
cargo build --locked --manifest-path runtime/Cargo.toml -p domr
runtime/target/debug/domr --target lisp --hub-bin test/conformance/lisp-hub.sh --scenarios test/conformance
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
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr --features drgnx-ratatoskr/test-hooks
cargo test  --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr --features test-hooks
runtime/target/debug/domr --target ratatoskr --hub-bin runtime/target/debug/ratatoskr \
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
| `forward/` (`fake-backend`) | `a-raw-duplicate-key-never-reaches-the-backend`, `a-tramp-path-never-reaches-the-backend`, `params-are-re-encoded-with-the-caller`, `a-malformed-backend-answer-is-internal`, `the-backend-gets-no-provider-key`, `the-backend-keeps-ssh-and-proxy-env`, `the-backend-gets-the-serve-socket-only`, `events-are-relayed-and-decoded` (and the backend's `events` dropped), `every-backend-event-kind-is-relayed` (`fixtures/backend-events.json`: one event of each of the nine kinds, as main sends it; `events`, `request`, `budget` and the job-less `fallback` are the front's and dropped, the hub log says so three times for the gateway's), `a-malformed-backend-event-is-dropped`, `backend-gone-calls-fail-once-and-it-restarts`, `an-oversized-forward-is-refused`; with `test-hooks` too: `agents-list-is-shaped-per-class`, `spend-is-own-job-for-an-agent` (summed from work.db's rows; the backend is never asked) |
| `gateway/` (`fake-backend`; [hub.md](hub.md#registrations)) | `register-keeps-only-the-hash` (the token's SHA-256, computed by `sh`, is the row's `hash`; `file_grep` finds the token in no file under the root), `a-gone-owners-registrations-are-pruned` (owner a `spawn`ed `sleep`, killed: `status --json` with `retry_ms`), `config-providers-refuses-a-bad-url`, `a-lan-http-provider-is-allowed-with-a-warning` (logged once after two calls: `file` with `count` and `at_most`; `doctor --json`), `the-backend-never-gets-keys`, `budget-reaches-the-backend-as-a-notification` (a request through the gateway to `ratatoskr-mock llm`, the spend row in work.db, `notification {"method":"budget",…}` in the backend log), `no-usable-step-is-refused`; with `test-hooks` too: `keys-only-on-a-user-connection` (service and agent connections) |
| `coord/` (`fake-backend`) | the front's writes (`sqlite` makes a schema-6 work.db from `fixtures/work-db-6.sql`): `cards-settle-once`, `messages-send-held-by-version`, `only-the-backend-names-a-sender` (`call_front`), `events-add-is-broadcast-once`, `review-mark-and-its-event-commit-together` (a trigger refuses the second event: neither is written), `a-write-before-work-db-is-ready-says-so`, `a-newer-work-db-refuses-coord-writes`, `notify-is-coalesced` (100 `coord/notify` → at most 2 notifications, `backend_log` `count`); with `lisp-backend`: `results-are-typed` |
| `graph/` (`fake-backend`; [store.md](store.md#parsed-entities-task-15a)) | `put-parsed-round-trip` (read back through the `node`, `file` and `link` rows; the same scan again writes nothing; a derived status; `gone`), `put-parsed-refuses-a-denied-source` (a personal-notes fixture under the row's HOME as a `file` source, a `spec` source and a plan's link end: refused whole, no row holds its canary or path), `record-twice-is-one` (keyed by the collected key) |
| `seam/` (`fake-backend`) | `a-backend-call-to-the-front-never-deadlocks` (the backend's `job/stop` calls `events/add` on the front before it answers), `the-backend-may-call-only-what-the-front-serves` (`job/status` and `subscribe` from the backend's connection: `not-allowed`) |
| `seam/` (`lisp-backend`) | `a-lisp-job-writes-through-the-front` (`job/propose` and `job/stop`: `status.store.writes` 0 → 3 → 6, the rows in work.db), `the-backend-sends-no-events` (the front broadcasts the event log; the backend's `events` is never dropped since none comes), `a-lisp-job-reads-its-own-writes` |
| `forward/` (`lisp-backend`) | `empty-lists-are-arrays` (A-17), `results-match-schemas` (a populated store: a proposed job, a review card, a mock-acp session with entries; every read method answers without `internal`) |
| `settings/` (`fake-backend`; [hub.md](hub.md#settings)) | `the-hub-reads-settings-el` (a profile and a provider of the user's join the built-in ones: `status.settings`), `no-editor-still-has-presets-and-profiles` (16 and 7 with no file), `a-package-entry-never-stops-the-hub` (entries of any shape the hub does not know: no problem), `a-broken-file-gives-strict-agents-and-last-good-providers` (the file breaks; the next `mcp/session` reads it again: a `notice`, the profile gone, the provider kept from `kv`, and the same after a restart) |
| `backpressure/` (`fake-backend`) | `a-stopped-reader-is-dropped-others-keep-going` (the backend floods 400 events of 64 KiB; a subscriber that `pause`d is closed, another gets every event) |
| `lifecycle/` (Task 16) | `ensure-starts-once` (two `ensure`s at once with no supervisor: one hub), `stop-ends-it`, `kill-9-then-ensure-restarts`, `stop-ends-a-non-dumpable-hub` (`test-hooks`: `--test-ignore-shutdown`, so `stop` reaches its SIGTERM through the listener's pidfd; `drop_ptrace`), `stop-never-signals-a-forged-argv0` (`test-hooks`, `linux`: the lock's text rewritten to name a `sleep` started as `exec -a ratatoskr`, with its true start time; `stop` exits 1 and both live), `stop-with-a-stale-lock-signals-nothing` (a lock file naming a live `sleep` that nobody holds: not running, no signal), `stop-ends-a-lisp-hub` (`lisp-backend`) |
| `restart/` | `the-restart-method-exits-75`, `a-self-detached-hub-re-execs`; with `fake-backend` and `test-hooks` (`--idle-tick-ms 200`; the answers of `agents/list` come from a file the row rewrites): `a-changed-binary-sends-the-notice`, `a-busy-backend-delays-it`, `a-missing-or-broken-new-binary-never-restarts` |
| `reaper/` | `a-recorded-orphan-backend-is-killed-at-start` (`fake-backend`: the hub SIGKILLed, its backend ignoring its parent; the next hub kills it within 4 s), `a-row-without-a-pid-is-dropped-and-kills-nothing` (NULL rows in `runtime.db`: removed, nothing signalled) |
| `mcp/` | the coordination tools on session sockets and outside bridges ([hub.md](hub.md#sessions-and-their-sockets)): `the-session-directory-is-private`, `a-gone-owners-sessions-are-closed` (a `spawn`ed owner killed), `a-closed-session-is-gone`, `an-unknown-tool-is-32602`, `a-fifth-connection-is-closed`; with `fake-backend` (a schema-6 work.db): `a-session-socket-is-its-identity` (an `agent` argument changes nothing), `an-outside-bridge-is-ext-and-unverified`, `sessions-come-back-after-a-restart`, `bad-argument-is-a-tool-error-with-its-path`, `modern-and-legacy-handshakes`, `tool-writes-are-broadcast-as-events`, `drgnx-agent-in-the-environment-is-ignored`; with `test-hooks`: `attach-needs-service-or-gets-not-allowed` |
| `bridge/` | `ratatoskr mcp-bridge` ([hub.md](hub.md#the-mcp-bridge)), a copy of the hub under test (`install_bin`) run by `spawn_conn`: `outside-refuses-an-untrusted-directory` (the socket's directory at 0755: exit 1, the reason on stderr); with `fake-backend`: `survives-a-hub-restart` and `survives-a-hub-restart-modern` (the gate rows: a TERM, a start on the same root, the next call works; both eras), `an-in-flight-call-is-an-error-never-a-retry` (a call to a STOPped hub, then KILL: the went-away tool error, one event after the restart), `a-call-while-away-waits-then-errors`, `tools-list-from-the-cache-while-away`, `drgnx-agent-in-the-environment-is-ignored`, `outside-is-service-class-and-ext`, `stdin-eof-ends-it`; with `test-hooks` (`--bridge-backoff-ms`, `--bridge-give-up-ms`): `gives-up` |

The forwarding rows run with both helpers:

```
cargo build --locked --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr --features drgnx-ratatoskr/test-hooks
runtime/target/debug/domr --target ratatoskr --hub-bin runtime/target/debug/ratatoskr \
    --lisp-hub test/conformance/lisp-hub.sh --fake-backend runtime/target/debug/ratatoskr-fake-backend \
    --scenarios test/conformance
```

Paths: the agent sockets are `<root>/run/drgnx/s/SID/hub.sock`; past 103 bytes (sized for the longest session socket,
`gateway.sock`) a session dir goes to `<tmp>/drgnx-hub-UID/s/SID/`.

`test/conformance/class-matrix.json` is not a row: it is the hand-written class table (`{method: [classes]}`) that the
registry's test and the `class_matrix` step read.

### The perf rows

`perf/` rows (`requires` `v1` and `perf`) run only with `--perf OUT.json`; without it they are skipped, and
`--require-all` lets that be. Each is a `measure` step; the file lists every sample and the median. There are no
budgets: this is a recorded baseline, not a regression gate.

| Row | Measures | Samples |
|---|---|---|
| `start` | starting the hub to its first answered `ping` on a proven connection | 1 |
| `hello-round-trip` | `ping` and its answer on a proven connection | 100 |
| `a-1-mib-request-line` | an `agents/send` line of about 1 MiB read, re-encoded, forwarded to the fake backend and answered | 20 |
| `a-4-mb-snapshot` | `agents/get` with a transcript of about 4 MB from the fake backend, to the client | 10 |
| `mcp-tool-call` | `tools/call read_inbox` over a session socket (initialized, `hello` called once before) | 100 |
| `coord-write` | `events/add` through the main socket, answered with the new id | 100 |
| `gateway-added-latency` | an agent's `POST /v1/messages` to the mock provider, head read: `direct-first-byte` against the mock, `gateway-first-byte` through the gateway with an agent token (the difference is the gateway's) | 50 each |
| `gateway-editor-fim-latency` | the editor's FIM-sized request, a 2 KiB `POST /completions` with a 64-token answer: `direct-fim` against the mock, `gateway-fim` as `/p/mock/completions` with the editor token; compare the median and p95 | 100 each |
| `walk-4-hops` | `graph/neighbors` four hops, out and both ways, on graph B (10^5 entities, about 10^6 links, 6 kinds; seeded into the running hub's store) | 20 each |
| `group-commit` | eight connections each send an `events/add` and wait for all eight answers (one round, group-committed) | 500 |
| `as-of-churn` | `graph/neighbors` as of a tx inside 200,000 versions of one link, one hop and two, and the same hop now | 20 each |
| `find` | `tasks/find` on 10^5 tasks: a word 1,000 hold, and a word one holds | 20 each |

The writer-level group-commit number, with `secure_delete` on and off, is `urdr`'s ignored bench
(`cargo test -p urdr --bench group_commit --release -- --ignored --nocapture`).

```
cargo build --locked --release --manifest-path runtime/Cargo.toml -p drgnx-ratatoskr -p domr
runtime/target/release/domr --target ratatoskr --hub-bin runtime/target/release/ratatoskr \
    --fake-backend runtime/target/release/ratatoskr-fake-backend --scenarios test/conformance \
    --only 'perf/*' --perf perf.json
```

CI runs this on Linux and macOS and keeps the files as artifacts ([ci.md](ci.md)). Numbers are for a release build on a
quiet machine.

### The gateway rows

`test/conformance/gateway/*.jsonl` drive the real gateway (`ratatoskr`'s front, [bifrost](#bifrost-the-gateway)) with
`ratatoskr-mock llm` as the only mock, standing in for the provider (and `ratatoskr-mock proxy` for the proxy). A row
starts the mock with `spawn` and `capture_stdout`, hands the hub the provider table (`config/settings`, a global `drgnx-ai-providers` override) and, where the
provider takes a key, a canary (`gateway/keys`), takes a token (`gateway/register`, or `gateway/editor-token` for the
editor), and acts as the agent or the editor with `http`. The mock's JSONL log is what reached the provider; the
mock's answers are `fixtures/llm-*.json` or a `write_file` in the row. All rows are `v1`; run them with one glob per
`domr` run: `--only 'gateway/*'`.

- **The gate rows** (phase 3, design §12): `fallback-on-429-before-the-head`, `budget-pauses-a-lisp-job`
  (`lisp-backend`: a git repo made with `run`, `fixtures/plan-budget.md`, `job/propose` and `job/approve`, a job
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
- **Keys:** `keys-are-never-on-disk-or-in-the-backend` (`file_grep` over the hub's roots, the mock's log kept apart),
  `the-agent-never-sees-the-key`, `need-keys-after-a-restart`.
- **The editor's token:** `editor-chat-through-the-gateway` (the body byte for byte, the hub's key upstream),
  `editor-fim-through-the-gateway`, `editor-embed-through-the-gateway`, `editor-stream-through-the-gateway`,
  `an-editor-token-is-refused-on-the-messages-path`, `an-agent-token-is-refused-on-the-editor-paths`,
  `editor-requests-carry-no-restrictions`, `an-openrouter-base-keeps-its-v1`.
- **Not rows:** `no-proxy-is-respected` keeps a plain-HTTP provider (the connector tunnels through `HTTP_PROXY` for any
  scheme, so it proves the `NO_PROXY` rule without TLS). A kill -9 between a registration's row write and its answer is
  declined (phase 6's `op` rows are the target).

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
(`g++`: CI's `fuzz` job runs on the Ubuntu runner, which has it; 60 s a target on a push to `main` or `ci/*`, 10 minutes a target
daily, `fuzz_minutes` on demand: [ci.md](ci.md)).

| Target | What it feeds |
|---|---|
| `line_codec` | arbitrary bytes, cut into chunks of a size the input picks, through the client line codec, then `parse_strict` on every line |
| `request_prelude` | a line through `dispatch::prelude` (steps 1 to 5, no handler) for every class and several protocol states |
| `hello` | hello params decoded from arbitrary JSON, then `hello()` against a fixed cap: as given, with the correct proof, on a main and on an agent socket, and a second hello |
| `connect_head` | bytes as a proxy request head: the blank-line search, the exactly-`CONNECT target HTTP/1.x` line, then `parse_target` on the target (gleipnir's `fuzzing` feature exposes the entry point) |
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

The seed corpus in `fuzz/corpus/<target>/` is the request lines of the conformance rows (phase 1; for `mcp_message` and
`jsonrpc_parse` the JSON-RPC lines the `mcp/*` and `bridge/*` rows send), the unit tables (gleipnir's targets) and, for
the gateway's targets, the SSE fixtures (`test/fixtures/sse`) and a few hand-made heads and bodies; for `huginn_read`
it is huginn's hand corpus (`test/fixtures/huginn/corpus/`, copied as `accept-NAME` and `refuse-NAME`). The
bridge's `classify`, `id_in_prefix` and `read_bounded` are private to `mimir::bridge`, so they are not targets; the
bridge's lines are covered by `jsonrpc_parse` and `mcp_message`. A run adds files to the
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
