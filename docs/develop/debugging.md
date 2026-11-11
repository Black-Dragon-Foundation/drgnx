# Graphical debugging: the internals

drgnx's debugger is a client of the Debug Adapter Protocol (DAP): the hub owns each session through the `vor` crate,
and Emacs draws the gutter, the toolbar and the views. This page is for contributors; it grows with the feature.

## vor: the DAP client

`runtime/crates/vor/` (Vör) speaks DAP to one adapter over stdio or TCP, on tokio. It knows nothing of drgnx.

- **Framing** (`vor::codec::DapCodec`): `Content-Length: N` headers, then N bytes of JSON. Other headers are skipped
  and the header name is matched in any case. A header block over 8 KiB, a missing or malformed length, or a body
  over 256 MiB breaks the stream (the connection ends); a body that is not a DAP message (bad JSON, not UTF-8) is
  reported as `Incoming::Bad` and the stream goes on.
- **Correlation** (`vor::Client`): `request(command, arguments)` returns a `Pending` future answered by the
  response with the same `request_seq`, in any order. A `success: false` answer is `Error::Failed` with the
  adapter's message. Dropping a `Pending` forgets the request, so a late answer is ignored; `cancel(seq)` asks the
  adapter to stop it (only when it has `supportsCancelRequest`). Callers put their own deadline around the future.
- **What the adapter sends on its own** arrives in order on the stream `Client::new` returns: events and reverse
  requests (`runInTerminal`, `startDebugging`). A `ReverseRequest` is answered with `ok(body)` or `err(message)`;
  dropped unanswered, it is refused (`not handled`), so an adapter never waits forever.
- **The end:** when the adapter exits or the stream breaks, every waiting request gets `Error::Closed` once, with
  the same reason, the stream ends, and later requests fail at once with that reason.
- **Transports:** `Client::stdio(&mut child)`, `Client::tcp(stream)`, and `Client::connect_tcp(addr, within)`, which
  tries a port the hub picked every 50 ms until the adapter opens it (adapters such as delve and js-debug listen a
  moment after they start).
- **Types** (`vor::types`): generated from the protocol's JSON schema, vendored at `schema/debugAdapterProtocol.json`
  (`schema/README.md` gives its revision and terms). Each request has a marker type in `types::requests` (`Request`:
  `COMMAND`, `Arguments`, `Body`) used with `Client::send`, and each event one in `types::events` (`Event`), read with
  `vor::event_body`. Every struct keeps the fields it does not know in `extra`, so an adapter's own fields pass
  through. String enums are `String` with the known values as constants (`…Values`), since adapters send others.
  To refresh: replace the schema, then from `runtime/` run
  `cargo run -p vor --example gen_types -- crates/vor/schema/debugAdapterProtocol.json > crates/vor/src/types.rs`
  and `cargo fmt -p vor` (in a container, like every build).

Dropping every handle (the `Client`s and unanswered reverse requests) closes the adapter's input, so a stdio adapter
reads its end.

### The mock adapter

`vor::mock` (feature `mock`) plays a script against a client: expected requests (in order, or a set in any order)
with canned answers, events, reverse requests whose answers it checks, and the adapter's death. It fails on any request
it did not expect, a request after the script's end, or a client that leaves early, and `Mock::finish` names what it
expected and what came, with a log of every request and its arguments. The steps are JSON (the module's doc lists
them); the `vor-mock SCRIPT.json` binary (built with the feature) plays one on stdio for ERT.

```json
[{"expect": "initialize", "ok": {"supportsTerminateRequest": true}},
 {"expect": "launch", "defer": true},
 {"event": "initialized"},
 {"expect": "configurationDone"},
 {"answer": "launch"},
 {"any": [{"expect": "variables", "args": {"variablesReference": 1}},
          {"expect": "variables", "args": {"variablesReference": 2}}]},
 {"expect": "terminate", "silent": true},
 {"die": true}]
```

Its tests (`crates/vor/tests/client.rs`) drive the client against a hand-written adapter on an in-memory pipe and one
TCP socket, and the mock's own (`tests/mock.rs`); the waits use tokio's paused clock.

## Sessions in the hub

`crates/drgnx-ratatoskr/src/debug/session.rs` runs one session as one task that owns the adapter's connection and its
process; the hub holds a `Handle` and reads `Update`s in order. Its waits read the hub's clock.

- **Launch** (spec §3.3 step 4): `initialize` (drgnx declares paging, types, `runInTerminal`, `startDebugging`,
  progress, `invalidated`, ANSI styling), then `launch` / `attach` without waiting for the answer. On `initialized`:
  `setBreakpoints` for each source, `setExceptionBreakpoints` when the adapter has filters, `configurationDone` when it
  has the request. The launch answer may come before or after; a failed launch ends the session with its message.
- **Stops and epochs:** each `stopped` opens a new epoch and fetches `threads`, `stackTrace` (20 frames;
  `more_frames` fetches the next 20 while `totalFrames` says there are more), `scopes` of the top frame and the first
  page of `variables` of every scope that is not `expensive`, published as one `Stop`. `variables(epoch, reference)`
  refuses a reference from an older epoch, so it never reaches the adapter. `invalidated` fetches its areas again in
  the same epoch; `Select` fetches another frame's scopes.
- **Stop sequence:** a launch session sends `terminate` (with `supportsTerminateRequest`) and waits 2 s for
  `terminated`; then `disconnect {terminateDebuggee}` with 2 s for the answer and the process's exit; then SIGTERM to
  the adapter's process group, 1 s, SIGKILL. An attach session starts at `disconnect {terminateDebuggee: false}`. The
  process is always waited for (an adapter that died gets 2 s, then the same signals).
- **Restart:** `restart` with the launch arguments when the adapter has it; otherwise the session stops and ends with
  `restart: Some(null)`, and the hub starts it again. `terminated {restart: V}` ends it with `restart: Some(V)`, which
  the next start passes back as `__restart`.
- **Reverse requests** go up as `Update::RunInTerminal` (answered with the terminal's pid) and
  `Update::StartDebugging`; unanswered they are refused.
- **The end** (`Update::Ended`) comes once: after a stop, `terminated`, `exited` (with its code), the adapter's death,
  or the last handle dropped. Controls queued behind it are told the session has ended.

The hub's sessions (`debug::Debug`, in `debug/mod.rs`) start each through a `Launcher` (the adapter started on stdio
or on a port, or a `debugServer` connected to) and route its updates:

- `debug-state` to every editor whenever a session starts, runs, stops or ends: `{sessions: [{id, name, parent, root,
  state, reason, caps}]}`; `debug-ended` once per session, with its reason and exit code.
- `debug-frame` on a stop: the selected frame's `path` (or `ref` for a `sourceReference`), `line`, `col`, `top`,
  `reason` and `exception`. The editor that started the session gets it with `open: true` (it opens the file); the
  others get `open: false` and draw it only in windows already showing the file (spec §3.3 step 12).
- `runInTerminal` opens a drgnx terminal for the starting editor (`Terminals`), answers the program's pid and sends
  that editor `debug-terminal {session, term}`.
- `startDebugging` starts a child session (`Launcher::child`: a second connection for a TCP adapter) under its parent.
  A stop or disconnect stops the children first and resolves when all have ended; the hub's end stops every session
  and refuses new ones.
- A restart without the adapter's request, or `terminated {restart}`, starts the same configuration again (with
  `__restart`).

The tests (`debug/tests.rs`, `debug/tests_registry.rs`) run each of these against the mock adapter on tokio's paused clock; the stop sequence's
waits are checked to the second.

## launch.json

`debug/launch.rs` reads `.vscode/launch.json` as JSONC (comments and trailing commas only; a syntax error gives its
line and column). The picker lists configurations by `presentation.group`, then `order`, then the file's order, and
leaves `hidden` ones out. The `linux` / `osx` / `windows` section for this system is merged over the base (objects such
as `env` key by key) and removed.

Variables come in two passes. The first (`needs`) finds what must be asked: each `${input:id}` (its `promptString` or
`pickString` declaration; a `pickString` answer must be one of its options) and `${command:pickProcess}`. The second
(`substitute`) replaces every variable in every string in one scan, so an answer or an environment value is never
read for variables again and an `args` item stays one argument. It knows all of VS Code's predefined variables
(`workspaceFolder`, `file` and its parts, `relativeFile`, `lineNumber`, `selectedText`, `execPath`, `userHome`,
`defaultBuildTask`, `workspaceFolder:NAME` …), `${env:…}` and `${config:…}`; the latter reads drgnx settings by name or
through a short table of VS Code names (`python.defaultInterpreterPath` → `debug-python-interpreter`). Paths are true
names (symlinks resolved). An unknown variable, setting or folder is an error that names it.

`debugServer` connects to this machine only (a port, or `localhost:N`). The fields drgnx reads itself
(`presentation`, `preLaunchTask`, `postDebugTask`, `debugServer`, `internalConsoleOptions`, `serverReadyAction`) are
not passed to the adapter; every other field is.

## Live adapters: the image

The tests that run real adapters (debugpy, js-debug, delve, lldb-dap) use `drgnx-debug-adapters:f45`, built from
`test/container/Containerfile.debug` on top of the line's dev image. Every download is pinned: the debugpy wheel by
pip's `--require-hashes`, delve by Go's checksum database, the js-debug tarball by SHA-256; lldb-dap is Fedora's.

Native debuggers trace their debuggee, so their container needs `CAP_SYS_PTRACE`: the container script's `--ptrace`
adds it (podman's default seccomp profile then allows `ptrace`). lldb-dap launches set `disableASLR: false`, since a
container may not turn address randomisation off.

Inside the sandbox (Gleipnir) `ptrace` stays refused in both tiers, so delve and lldb-dap run outside it; Python and
JavaScript adapters run in the full tier.
