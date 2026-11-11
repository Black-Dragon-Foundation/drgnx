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
them); the `vor-mock SCRIPT.json` binary (built with the feature) plays one on stdio for ERT, and so does a test-hooks
hub's `ratatoskr debug-mock SCRIPT.json`, which the `debug/*` conformance rows name as their adapter (`$HUB_BIN`).

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

## Adapters

`etc/debug-adapters.eld` is the adapter table, read by the hub with huginn's reader as data only (strings, numbers,
symbols and lists; nothing is evaluated; an unknown key is an error). Each entry names the launch.json `type`s it
serves, the languages whose default configurations it gives, whether drgnx's live tests run it (`:tested`: debugpy,
js-debug, delve, lldb-dap), how to find it and how to start it:

- `:find`: `(:path "dlv")` (an executable on `PATH`), `(:tools "js-debug/src/dapDebugServer.js")` (a file in drgnx's
  tools folder) or `(:python-module "debugpy")` (in the tools venv, `venv/lib/python*/site-packages`).
- `:start`: `(:stdio ARGV)` or `(:tcp ARGV)`, where `{program}`, `{python}`, `{tools}` and `{port}` are filled in; a
  TCP adapter gets a free port on 127.0.0.1 picked by the hub (`adapters::free_port`; another local process could take
  it first, and DAP has no authentication: spec §9.5).

The untested entries' command lines come from dape's recipes (credited in the file). Adapters drgnx cannot start are
listed with `:not-built-in t`, so their type says to add them in the setting `debug.adapters`; an unknown type lists
the known ones.

## Breakpoints: the store (`debug/breakpoints.rs`)

Each project (by root) has one store, saved in the hub's state directory as `debug-breakpoints/<hash of the
root>.json`, written atomically. If the file is damaged, it is moved aside to `….damaged` and the store starts empty.

- **Operations by id** (`Op`): add, remove, edit, move, add or remove a function breakpoint.
  - Adding a line that already has a breakpoint gives that one. Removing or editing one that is gone is no change.
    So two editors toggling one file never undo each other.
  - Every change raises the file's version.
  - The line held is the saved line: the editor keeps a moved line as a draft and sends `move` on save.
- **What each session made of a breakpoint:** its adapter id, verified, message and line. These come from the
  `setBreakpoints` answer, read in the order sent, and from `breakpoint` events by adapter id.
  - A breakpoint shows verified when any session verified it.
  - It shows `bound_line` when the adapter put it on another line.
  - When a session ends, what it made of the breakpoints goes with it.
- **Adapter capabilities:** conditions, hit counts and log messages go only to adapters whose capabilities take them
  (`fit`). The store keeps them and shows them as `unsupported` for that session.
- **Function breakpoints** go to adapters with `supportsFunctionBreakpoints`.
- **Exception filters:** the ones chosen are remembered per adapter type; otherwise the adapter's defaults.
- **Run to Cursor:** a breakpoint for one session only. It is never shown or saved, and goes at that session's next
  stop or end. The registry then sends the file again.

The registry starts each session with the store's breakpoints, and sends a changed file to every session of the
root at once. It tells the editors with the `debug-breakpoints` event: the file's view, with its root. The editors use `debug/breakpoints` (`{root, path?, op?}`: an operation by id, answered with the file's view) and
`debug/run-to-cursor` (`{session, path, line}`). Tests:
`tests_breakpoints.rs` (the store) and `tests_registry.rs` (with mock adapters).

## The `debug/*` methods

`debug/wire.rs` serves them (runstav `methods::debug`, the user class) and keeps, in memory for the hub's life, the
roots `debug/trust` called trusted and each root's last started configuration.

- `debug/configs {root, file?, language?, user?, adapters?}` → `{configs: [{id, name, source, type, request,
  needs_trust}], last?, error?}`: launch.json's (`launch:N`, in the picker's order, `hidden` ones left out), the user's
  own configurations from the setting `debug.configurations`, which the editor sends (`user:N`), and the adapter table's
  defaults for the language (`default:N`). A launch.json that does not parse comes back as `error {path, line, col,
  message}`.
- `debug/start {root, config, file?, line?, col?, selection?, language?, inputs?, user?, adapters?}`: a root never told
  trusted answers `{needs: "trust"}` and runs nothing. Then the configuration's `${input:…}` and
  `${command:pickProcess}` that `inputs` (`[{id, value}]`) does not answer come back as `{needs: [{input: {id, kind,
  description, default, options, password}} | "pickProcess"]}`; a `pickString` answer outside its options is
  `invalid-params` at `inputs`. With every answer: the platform section, the variables, the type's adapter (the user's
  `adapters`, from the setting `debug.adapters` in the table's fields, before `etc/debug-adapters.eld`'s), and
  `{session}`.
- `debug/control {session, thread?, op}` (`continue`, `pause`, `next`, `step-in`, `step-out`, `restart`, `stop`,
  `stop-and-kill`, `disconnect`), `debug/select {session, thread?, frame}`, and `debug/trust {root, trusted}`, whose
  revocation stops the root's sessions.

Adapters start in the root with the shell's environment (`env/set`), each in its own process group: a stdio adapter
over pipes; a TCP adapter with stdin on `/dev/null`, on a free port of 127.0.0.1 that the hub connects to within 5 s
(`LISTEN_WITHIN`), with a child session (`startDebugging`) on a second connection to the same port. They are found on
`PATH` or in `<data>/debug-adapters` (debugpy in its `venv/`). `debugServer` connects to 127.0.0.1 and starts nothing.
An adapter that goes on its own ends its session with the end of its stderr in the reason.

`runInTerminal` opens a drgnx terminal in the panel (`term::Terms::spawn`, 80×24 until the editor sizes it) with the
shell's environment and the adapter's `env` over it; `debug-terminal {session, term, view}` tells the starting editor,
which shows the view. At the hub's end every session stops, children first, before the store closes.

## The editor's half: `drgnx-debug-launch.el`

`modules/extra/drgnx-debug-launch.el` holds what a start needs in the editor, all from commands you invoke:

- `drgnx-debug-launch-configs` / `-read-config`: `debug/configs` for the project root (`project-current`, else the
  folder) with the buffer's language (its major mode's stem: `python-ts-mode` → `python`), your configurations
  (`drgnx-debug-configurations`, plists of launch.json's fields) and adapters (`drgnx-debug-adapters`, plists of the
  table's fields; `-` in a key becomes `_`, lists become arrays). The picker offers the root's last start first and
  marks untrusted rows; a launch.json that does not read opens at its line and column.
- `drgnx-debug-launch-start`: `debug/start` until it answers a session. `needs: "trust"` asks once (Trust This
  Folder, then `debug/trust`); inputs are asked in the minibuffer (`pickString` from its options, `promptString` with
  its default, a password unechoed, `pickProcess` from this user's processes) and sent back as `inputs`.
- Trust: before each call a trusted root is told to the hub (`debug/trust`, which keeps it in memory only);
  `drgnx-trust-changed-functions` (run by Trust This Folder and Untrust This Folder) gives the hub every change, and
  taking trust back stops the folder's sessions.
- `drgnx-debug-convert-dape-configs`: once, with dape installed, each of `dape-configs` is evaluated here (a function
  value is called once), dape's own keys (`command`, `port`, `modes`, `fn` …) are dropped, and the plain result is
  added to `drgnx-debug-configurations` in settings.el; one without `:type` is named and left out.

`drgnx doctor`'s `debug-adapters` line (group Tools) reads `etc/debug-adapters.eld` as data and says which built-in
adapters are found (`:path` on `PATH`, `:python-module` importable by `python3`, `:tools` under
`<data>/debug-adapters/`) and how to get the others.

Its tests (`test/unit/debug-launch-test.el`) script the hub's answers.

## The breakpoint column: `drgnx-debug-gutter.el`

`drgnx-debug-gutter-mode` draws a file's breakpoints in the left margin, in a column claimed through
`core/drgnx-margins.el` (owner `debug`, order 0: outermost, 18 px rounded up to whole columns; one column in a
terminal). The hub holds the breakpoints; the mode asks `debug/breakpoints` for the file when it turns on, sends each
change as an op by id and draws the answer, and redraws on the hub's `debug-breakpoints` event (a newer `version`
only).

- Glyphs follow the mockup's legend (`docs/specs/drgnx/the-look/debugging.html`): ten kinds (`bp`, `unverified`,
  `cond`, `log`, `off`, `hover`, `stop`, `stop-bp`, `frame`, `exception`) as SVGs coloured from the role faces
  (`drgnx-debug-breakpoint`, `-unverified`, `-hover`, `-stopped`, `-frame`, `-exception`) through `drgnx-color`, cached
  per kind, size and colours; a terminal shows `● ◐ ◆ ○ ▶ ▷` (ASCII `B C L o > -` where it is not UTF-8) in the face.
- Each mark is an overlay over its line. While the buffer has unsaved changes a moved mark is a draft and a hub event
  leaves it where the text put it; on save each moved mark sends `move` (the store's line plus how far it moved), each
  mark whose line was deleted sends `remove`; a revert puts the marks back on the store's lines. A breakpoint the
  adapter bound elsewhere (`bound_line`) sits on that line.
- `drgnx-debug-gutter-show`: `auto` (while the file has breakpoints or a session runs in its project, from
  `debug-state`), `always` or `never`.
- Mouse: `mouse-1` in the column toggles (`drgnx-debug-gutter-toggle`), `S-mouse-1` adds a logpoint, `mouse-3`
  opens the line's menu (`drgnx-debug-gutter--menu-items`): Add Breakpoint / Conditional / Logpoint on an empty line;
  Remove, Edit Condition / Hit Count / Log Message and Enable or Disable on a breakpoint; Run to Cursor while a session
  runs in the project (`debug/run-to-cursor`).
- The prompt (`drgnx-debug-gutter-edit`) starts from the field's text; an empty answer clears it (an `edit` op with
  `""`), and on a line without a breakpoint a non-empty answer adds one with that field.
- The hover dot: with the pointer over the column, a line without a mark shows a faint dot ("Click to add a
  breakpoint"), with no Lisp on mouse motion. Each shown line carries a margin string, `●` in the column's middle
  character in the UI font (its `●` is the mockup's 10 px; the code font's is 8), in the margin's own background (`default` as the buffer remaps it) with a `mouse-face` of
  `drgnx-debug-hover` at 38 % over it, both through `drgnx-color`. The strings sit on a pool of overlays per window (the
  overlay's `window`), laid out from `pre-redisplay-functions` and `window-scroll-functions` when the window's start or
  height, the text or the marks changed; folded lines and lines with a mark are skipped. Only on a graphical frame of a
  Nidhogg that lights a margin's `mouse-face` (feature `glitnir-margin-mouse-face`); elsewhere there is no pool.

The module's global `drgnx-debug-mode` (turned on by `extra/debug`'s setup, off by its teardown) turns the column on
in every file's buffer (`find-file-hook`) and holds `drgnx-debug-mode-map`, where the Emacs profile's `C-x C-a` keys
go: a loaded gud binds `C-x C-a` in `global-map`, and a minor mode's map comes first. The breakpoint commands
(`debug-breakpoint`, `-conditional`, `debug-logpoint`, `debug-breakpoint-enable`, `debug-run-to-cursor`) act on
point's line through the column.

Its tests (`test/unit/debug-gutter-test.el`) script the hub with a small store of their own;
`test/ui/debug-gutter-gui-test.el` reads the margin's pixels: no dot at rest on a plain, current (hl-line), region or
banded line, and the pointer noted on a dot lights it.

## Live adapters: the image

The tests that run real adapters (debugpy, js-debug, delve, lldb-dap) use `drgnx-debug-adapters:f45`, built from
`test/container/Containerfile.debug` on top of the line's dev image. Every download is pinned: the debugpy wheel by
pip's `--require-hashes`, delve by Go's checksum database, the js-debug tarball by SHA-256; lldb-dap is Fedora's.

Native debuggers trace their debuggee, so their container needs `CAP_SYS_PTRACE`: the container script's `--ptrace`
adds it (podman's default seccomp profile then allows `ptrace`). lldb-dap launches set `disableASLR: false`, since a
container may not turn address randomisation off.

Inside the sandbox (Gleipnir) `ptrace` stays refused in both tiers, so delve and lldb-dap run outside it; Python and
JavaScript adapters run in the full tier.
