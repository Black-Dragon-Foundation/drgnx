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
  Whatever the adapter sends before the `initialize` answer is kept and handled after it: js-debug sends `initialized`
  right behind its answer, and on a loaded machine the event can be read first (dropped, the session never
  configured and js-debug never answered the attach).
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
  state, reason, caps, attach}]}` (`attach`: an attach session, whose toolbar shows Disconnect); `debug-ended` once per session, with its reason and exit code.
- `debug-frame` on a stop: the selected frame's `path` (or `ref` for a `sourceReference`), `line`, `col`, `top`,
  `reason`, its `name` and its source's `source_name`, and on an exception stop `exception`: `exceptionInfo`'s `{id,
  message, break_mode, type, trace}` (asked in the same stop when the adapter has `supportsExceptionInfoRequest`), else
  `{message}` from the stop's description. The editor that started the session gets it with `open: true` (it opens the file); the
  others get `open: false` and draw it only in windows already showing the file (spec §3.3 step 12).
- `runInTerminal` opens a drgnx terminal for the starting editor (`Terminals`), answers the program's pid and sends
  that editor `debug-terminal {session, term}`.
- `startDebugging` starts a child session (`Launcher::child`: a second connection for a TCP adapter) under its parent.
  A stop or disconnect stops the children first and resolves when all have ended (a parent that ends on its own
  meanwhile, as js-debug's root session does once the program is gone, counts as stopped); the hub's end stops every
  session and refuses new ones.
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

### Tasks (`debug/tasks.rs`)

A configuration's `preLaunchTask` names a task in the root's `.vscode/tasks.json`, read as JSONC like launch.json, each
task with its platform section merged over it and its strings through the same variables. The task's `dependsOn` (a
label or a list) runs first, depth first in the order given, each task once; a cycle (`a → b → a`) or an unknown
label is an error that names it. A `shell` task (also one without a `type`) runs its command line in `/bin/sh -c`,
each `args` item quoted for the shell; a `process` task runs `command` and `args` as they are, never split.
`options.cwd` (relative: under the root) and `options.env` apply. `isBackground` tasks (watchers that never end) are
refused. The steps run one at a time before the adapter starts (so a TCP adapter's free port is picked after the
build); the first that fails stops the rest and the start, and the error gives its exit status and the end of its
output (2,000 bytes of stdout, then stderr's tail). `${defaultBuildTask}` is the label of the task whose `group` is
`{"kind": "build", "isDefault": true}`. `postDebugTask` is read from the same file at the start (a wrong name stops the
start too) and runs once the root session has ended, a restart's end included; its failure goes to the hub's log
until the debug console shows it.

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

- `:install` (Debug: Install Adapter, `debug/install`, `debug/install.rs`): `(:url U :sha256 H :into DIR [:root R])`
  or `(:into DIR :platforms ((:platform "linux-x64" :url U :sha256 H) …))` (the platform keys are `linux-x64`,
  `linux-arm64`, `darwin-x64`, `darwin-arm64`), `(:pip "debugpy==V" :hash "sha256:…")` or `(:system "dnf install …")`.
  An archive is downloaded over https through the browser installer's client (`browser::install::fetch`, its proxy and
  certificate settings), checked against the pin, and unpacked (a tar.gz, or a zip such as CodeLLDB's `.vsix`) with
  only regular files and folders allowed: an absolute, climbing or linking entry fails the whole install. The result
  (only its `:root` folder, when given) replaces `<data>/debug-adapters/DIR` whole through `DIR.partial` and `DIR.old`,
  so any failure leaves the folder as it was. debugpy goes into the tools venv (made first if missing) with `pip
  install --require-hashes --no-deps`. A system package is never run: the error names its command. js-debug and
  CodeLLDB are pinned archives (CodeLLDB is built in, untested, started from its `extension/adapter/codelldb`).

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
- `debug/source {session, ref}`: the adapter's `source` request for a frame with no file, answered `{text, mime?}`.
- `debug/install {adapter, adapters?}`: the adapter's `:install` entry carried out (see Adapters); the answer says what
  was installed. A system package's, an adapter without an entry and an unknown id are errors (conformance
  `debug/install-refusals`; the downloads are the unit tests' `debug::tests_install`, from local files).

Adapters start in the root with the shell's environment (`env/set`), each in its own process group: a stdio adapter
over pipes; a TCP adapter with stdin on `/dev/null`, on a free port of 127.0.0.1 that the hub connects to within 5 s
(`LISTEN_WITHIN`), with a child session (`startDebugging`) on a second connection to the same port. They are found on
`PATH` or in `<data>/debug-adapters` (debugpy in its `venv/`). `debugServer` connects to 127.0.0.1 and starts nothing.
An adapter that goes on its own ends its session with the end of its stderr in the reason.

`runInTerminal` opens a drgnx terminal in the panel (`term::Terms::spawn`, 80×24 until the editor sizes it) with the
shell's environment and the adapter's `env` over it; `debug-terminal {session, term, view}` tells the starting editor,
which shows the view. At the hub's end every session stops, children first, before the store closes.

## The module: `drgnx-debug.el`

`extra/debug` needs no package (dape is no longer its client). `drgnx-debug-mode` (its setup; off in its teardown)
puts the breakpoint column in every file's buffer and `drgnx-debug--event` on `drgnx-hub-event-functions`: each
`debug-state` replaces `drgnx-debug--sessions` and turns `drgnx-debug-session-mode` (the session keys, such as F11 for
Step Into) on while there is a session. A command acts on the project's session (its root is the project's), the
stopped one first, so a stopped child comes before its running parent: Start Debugging continues it (`debug/control
continue`) or, with none stopped, picks a configuration and starts it; Step Over / Into / Out and Stop send `next`,
`step-in`, `step-out` and `stop`. Tests: `test/unit/debug-module-test.el`.

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
  added to `drgnx-debug-configurations` in settings.el; one without `:type` is named and left out. It is the
  palette's **Convert dape Configurations…** (`debug-convert-dape`), on no key in any profile.

`drgnx doctor`'s `debug-adapters` line (group Tools) reads `etc/debug-adapters.eld` as data and says which built-in
adapters are found (`:path` on `PATH`, `:python-module` importable by `python3`, `:tools` under
`<data>/debug-adapters/`) and how to get the others (a system package's command, else Debug: Install Adapter).

`drgnx-debug-install-adapter` is the palette's **Install Adapter…** (`debug-install-adapter`, on no key in any
profile): it offers the table's built-in adapters with an `:install` entry and calls `debug/install` with your
`drgnx-debug-adapters`; the answer or the error is shown in the echo area.

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
  height, the text or the marks changed; folded lines and lines with a mark are skipped. A window that only scrolled
  or was resized drops its dots and lays them again once it has rested 0.1 s (`drgnx-debug-gutter--settle`): drawn on
  every scroll frame they cost ~10 % of it (docs/develop/perf.md, "The breakpoint column's margin"). Only on a graphical frame of a
  Nidhogg that lights a margin's `mouse-face` (feature `glitnir-margin-mouse-face`); elsewhere there is no pool.

The module's global `drgnx-debug-mode` (turned on by `extra/debug`'s setup, off by its teardown) turns the column on
in every file's buffer (`find-file-hook`) and holds `drgnx-debug-mode-map`, where the Emacs profile's `C-x C-a` keys
go: a loaded gud binds `C-x C-a` in `global-map`, and a minor mode's map comes first. The breakpoint commands
(`debug-breakpoint`, `-conditional`, `debug-logpoint`, `debug-breakpoint-enable`, `debug-run-to-cursor`) act on
point's line through the column.

Its tests (`test/unit/debug-gutter-test.el`) script the hub with a small store of their own;
`test/ui/debug-gutter-gui-test.el` reads the margin's pixels: no dot at rest on a plain, current (hl-line), region or
banded line, and the pointer noted on a dot lights it.

### The stopped line (spec §5)

The module's handler (`drgnx-debug--event`) gives each `debug-frame` to `drgnx-debug-gutter-show-frame`:

- A top frame is a new stop (or the top picked again): the session's marks go, then its line gets the arrow (`stop`;
  `stop-bp` over a breakpoint, whose own glyph is hidden until the stop goes; `exception` on an exception) and a band
  (`drgnx-debug-stopped-line`, or `drgnx-debug-exception-line`). A caller frame (`top: false`) replaces only the
  session's caller mark: the outline arrow and `drgnx-debug-frame-line`. The marks are overlays tagged
  `drgnx-debug-stop` (`top` / `frame`), kept per session in `drgnx-debug-gutter--stops`; the band ends after the
  line's newline, so its `:extend` reaches the window's edge and the exception card (its `after-string`: the type,
  break mode and place, the message, and the active profile's keys for Stop and Continue) starts the next row.
- `open: true` (the starting editor) visits the file, shows it in the window the session's last stop used (else the
  selected one), puts point at the line and column (the window scrolls only when the line left it) and, with
  `drgnx-debug-focus-on-stop`, raises the frame. Without `open` only a buffer already visiting the file is marked.
- A `ref` (no file) opens the read-only buffer `<source_name> (from the debugger)`, filled by `debug/source`; a frame
  with neither says `No source: <name>`.
- `debug-state` with the session running starts a 150 ms timer (`drgnx-debug-gutter-stop-linger`, keyed
  `(debug-stop . ID)`, owned by the marked buffer) that clears its marks unless a stop comes first, so a step does not
  flicker; a session gone from `debug-state`, or `debug-ended`, clears them at once.
- The bands' colours are theme tokens: `stop-band` (warn at 15 % in dark, the warn tint in light), `ok-tint`,
  `error-tint`; high contrast has no tints, so there the arrow alone marks the line. The card is the raised surface
  ringed in the error colour.

Tests: `test/unit/debug-stop-test.el`; perf row `debug-step-line` (120 steps through the fixture, p95 ≤ 16 ms; 3.4 ms
measured on the desktop).

## The toolbar: `drgnx-debug-toolbar.el` (spec §6)

The session's controls, drawn from `drgnx-debug--sessions` at each `debug-state` (`drgnx-debug-toolbar-sync`):

- **Where** (`drgnx-debug-toolbar`): `floating` puts a card in a child frame over each graphical root frame, centred at
  the top of its editor window under the tab row (over the breadcrumb). The card is made once per root frame
  (`drgnx-debug-toolbar--children`, weak) and hidden between sessions, never deleted; its text is drawn again only
  when what it shows changed. It never takes the focus: a click runs the command in the parent's editor window, the
  registry's way. The grip drags it sideways (the mouse is tracked only while the button is down); the offset is kept
  per frame and the card stays inside the window. `docked` gives the same buttons to the editor window's tab row,
  before the split and more buttons, through `drgnx-chrome-tab-row-function`. `hidden`, and every terminal frame,
  have the keys, the palette and the status bar's segment only.
- **Buttons**: Continue while stopped, Pause while running (disabled while starting), Step Over / Into / Out only while
  stopped, Restart always (the hub stops and starts again when the adapter has no `restart`), and Stop, or Disconnect
  for an attach session (`debug-state`'s `attach`). Their colours are the roles: accent, muted, ok, error. Hover shows
  the registry title with the active profile's key. With two or more sessions a chip names the session the controls
  act on; picking another (Select Debug Session) sets `drgnx-debug--focus`, which every debug command then follows.
- **Status bar**: the segment `debug` (after `branch`), `<bug> NAME · STATE` in the warn colour while a session runs
  ("paused on breakpoint", "running"); a click opens Run and Debug. **Title row**: the Paused chip (the warn pill)
  while the session is stopped, through `drgnx-topline-paused-function`; a click goes to the stopped line.

Tests: `test/unit/debug-toolbar-test.el`; perf row `debug-toolbar-show` (120 shows and hides, p95 ≤ 5 ms).

## The Run and Debug view (spec §7)

A sidebar view the hub builds, as the Explorer is (Sjá: the hub sends the model and the rows; keys answer from the
replica in the key's own frame). Hub: `view/debug.rs` keeps each (connection, view)'s state and builds it; the pure
parts are `view/debug/model.rs` (the lines, the model, the requests that fill it) and `view/debug/rows.rs` (the rows).
Editor: `modules/extra/drgnx-debug-view.el`, the section `run-and-debug` of the sidebar view `debug`
(`drgnx-debug-view`, also the status bar's debug segment's click).

- **Sections:** VARIABLES (the selected session's scopes: a cheap scope open with the variables its stop fetched, an
  `expensive` one closed and fetched when opened), WATCH, CALL STACK (sessions only when two or more → threads →
  frames), BREAKPOINTS (each adapter type's exception filters as tick boxes, function breakpoints, each file's source
  breakpoints: tick = enabled, dim = unverified, the adapter's message as a field). Each header opens and closes.
- **Node ids are paths, stable across stops:** `v:SESSION:SCOPE/NAME/…`, chunks `…/[100..199]`, watches `w:EXPR`,
  threads `t:SESSION:THREAD`, frames `f:SESSION:THREAD:N` (their place in the stack), hidden runs `h:…:N`, more frames
  `m:SESSION:THREAD`, filters `x:TYPE:FILTER`, `fn:NAME`, `b:ID`. A `/` or `%` in a name is escaped; a name seen twice
  under a parent gets `#2`. So a step's model diff (`Doc::diff`) and row patch carry only what changed, and the
  editor's selection survives it.
- **Open nodes** are kept per view (each node has a default: sections, cheap scopes, the stopped thread and sessions
  open; the user's opening or closing wins). At each stop the hub fetches the open paths again, breadth first
  (`model::wants`), at most `FETCH_CAP` = 200 calls (`variables`, or `stackTrace` for another thread's frames); past
  it a node is shown closed with "expand again", and opening it fetches it past the cap. A fetch that fails is kept
  with its message and not asked again in that stop.
- **Paging:** a node with more than 100 `indexedVariables` lists its named children (`filter: named`, unless
  `namedVariables` is 0), then chunks; past 100 chunks the chunk size grows by 100 (100,000 is ten chunks of 10,000,
  each a hundred of 100). Only an opened leaf chunk is fetched (`filter: indexed`, `start`, `count`).
- **Lazy values** (`presentationHint.lazy`) show `(…)`; opened, the one child's value shows in their place (its own
  children then come from `PATH/(…)`).
- **Changed values:** the selected session's values at its last stop are kept by `evaluateName` (else path); a value
  that differs now is drawn in `drgnx-debug-view-changed`. A new value is not marked.
- **Running again:** the last stop's nodes stay, dim, and fetch nothing (`Line::dim`; the editor refuses to open them)
  until the next stop.
- **Watch:** the project's expressions, saved with its breakpoints (`Store::watches`), evaluated in the selected
  frame (`context: watch`) once per stop and frame and after every change of the list; an error is kept as its
  message (`drgnx-debug-view-error`).
- **Call Stack:** a thread's chip says why it stopped (`PAUSED ON BREAKPOINT`, `… EXCEPTION`, `… STEP`, `… ENTRY`)
  or `PAUSED` / `RUNNING`; a run of two or more `subtle` (or `deemphasize`d) frames folds into "N frames hidden";
  `label` frames are dim separators; "Load more frames" (`debug/expand` on the `m:` node) fetches the next page
  (`Handle::more_frames`), kept with the view.
- **Filter on typing:** `debug/view`'s `filter` keeps the rows whose label or value contains it (any case), the rows
  above them and the section headers (`model::filter`).
- **Rebuilds:** `Debug::on_change` listeners are told at every `debug-state` and breakpoint change; the views build
  again, one at a time (a change meanwhile builds once more), and a class that sends its env gets the last lines.

Methods (runstav `methods::debug`, the user class; served by `view::debug::serve`):

- `debug/view {view, root, session?, indent?, filter?}` → bool: show ROOT's view (the open nodes are kept while the
  root is the same).
- `debug/expand {view, node, open}` → bool.
- `debug/watch {root, op: add | edit | remove | move, index?, expr?, to?}` → the list.
- `debug/set-value {view, node, value}` → `{value}`: `setExpression` when the adapter has it and the node an
  `evaluateName`, else `setVariable` on the parent's reference; the view's fetched values are then fetched again.
- `debug/evaluate {session, frame?, expr, context: repl | hover | clipboard | watch}` → `{result, type?, reference?}`
  (Copy Value uses `clipboard` when the adapter has `supportsClipboardContext`).
- `debug/breakpoints`' ops `filter {adapter, name, enabled}` (kept per adapter type and sent to its sessions at once),
  `enable-all {enabled}` and `remove-all` (function breakpoints too).

The editor's half asks on the connection the rows come on (`drgnx-hub--events`): the hub keeps the view per
connection. A key that opens or closes a node waits up to `drgnx-debug-view-await-limit` (12 ms) for the rows, so
they show in the key's own frame. The header line holds Start (▶) and the configuration picker.

## Live adapters: the image

The tests that run real adapters (debugpy, js-debug, delve, lldb-dap) use `drgnx-debug-adapters:f45`, built from
`test/container/Containerfile.debug` on top of the line's dev image. Every download is pinned: the debugpy wheel by
pip's `--require-hashes`, delve by Go's checksum database, the js-debug tarball by SHA-256; lldb-dap is Fedora's.

Native debuggers trace their debuggee, so their container needs `CAP_SYS_PTRACE`: the container script's `--ptrace`
adds it (podman's default seccomp profile then allows `ptrace`). lldb-dap launches set `disableASLR: false`, since a
container may not turn address randomisation off.

Inside the sandbox (Gleipnir) `ptrace` stays refused in both tiers, so delve and lldb-dap run outside it; Python and
JavaScript adapters run in the full tier.

## Sessions inside a port block (spec §21)

Under macOS's Seatbelt a session's adapter and program may use only the loopback ports its profile names
(`mac_loopback_ports`), and debugpy's and js-debug's launch modes bind ephemeral ports of their own. So a sandboxed
session gets a block of ports and its launch configuration becomes an attach the hub sets up
(`debug/ports.rs`, `debug/blocked.rs`):

- **The block** (`ports::Blocks`): 8 ports cut from 47000–48999, below macOS's ephemeral range (49152), so the system
  never hands one out for an outgoing connection. A block is claimed machine-wide: an exclusive `flock` on
  `block-FIRST` in `/private/tmp/drgnx-debug-ports/` (`/tmp/…` on Linux; made 1777, each file 0666, so every hub on
  the machine, another account's or a test hub, sees it; an existing directory that is not sticky is refused, since
  a held lock file could be deleted and its name locked again). The lock is held for the session's life and goes
  with the process. A child forked by another thread shares the locked file until it execs, so the block's drop
  unlocks it (`LOCK_UN`, which frees it for every copy) before closing: a block is free as soon as its session lets it
  go. Under it each port is bound once on 127.0.0.1, ::1 and 0.0.0.0 and let go; a block locked
  elsewhere or with a port another process holds is passed over (the macOS runner had 47610 taken now and then), and
  when none is free the session is refused, naming the range. The block goes back when the session's launcher is
  dropped. Linux's reduced tier has no loopback flag, so no blocks.
- **Whose listener:** the probe and the adapter's own bind are apart, so before the hub connects to a block port, or
  starts a program that will, it checks that every listener on it is in the process group of the adapter or program
  it started there (`ports::owned`: `lsof` on macOS, `/proc/net/tcp*` and the processes' descriptors on Linux). A
  stranger's listener ends the session with a message naming the port and process; the hub never connects to it.
  (`lsof` sees this account's processes only: another account's listener makes the adapter's own bind fail instead.)
- **debugpy:** the adapter listens for the hub on the block's first port (`debugpy.adapter --host 127.0.0.1 --port
  A`); the attach has `listen: {host, port: B}` and `subProcess`; the hub starts the program as `python -m debugpy
  --connect 127.0.0.1:B --configure-subProcess BOOL (PROGRAM | -m MODULE) ARGS…`. debugpy connects once without
  retrying, so the hub starts it once B listens, the listener checked to be the adapter's (no probe connection), and
  gives up after 30 s, stopping the adapter.
  Subprocesses connect to B too.
- **js-debug:** the hub starts `node RUNTIME-ARGS… --inspect-brk=127.0.0.1:B PROGRAM ARGS…`, which waits at its first
  line, then the adapter (`dapDebugServer.js A`), and attaches to B with `autoAttachChildProcesses` and
  `continueOnAttach`. js-debug writes its bootloader into the program's `NODE_OPTIONS` only once attached (104–166
  ms later on the macOS runner), and it answers the attach only after `configurationDone`, so the program already
  runs by then (holding `configurationDone` for the answer deadlocks): a child started before the bootloader is there
  would run without a debugger. So `etc/debug-node-preload.js`, first in `NODE_OPTIONS`, makes `child_process`'s
  spawn, fork and exec functions wait for it first (`DRGNX_DEBUG_WAIT_BOOTLOADER`, set unless
  `autoAttachChildProcesses` is off), in 5 ms sleeps between which V8 runs the inspector's messages, at most 5 s
  (measured: 128–165 ms on the macOS runner, at most 52 ms on a desktop under full CPU load); past it the child
  starts without the debugger and stderr says so.
  Children (`startDebugging`) are second connections to A. A child's `inspector.open(0)` goes through the preload
  too: it takes the block's next port, claimed with an O_EXCL file under `TMP/drgnx-debug-ports/`, and drops an
  inherited `--inspect-brk` from forked children's `execArgv`. The preload is written into each session's tmp.
- **A seventh child** (the block has six ports for children), or a child whose port another process holds, runs
  without the debugger: its inspector stays closed (the sandbox allows no other port), stderr says
  `drgnx: process PID runs without the debugger: …`, and `TMP/drgnx-debug-ports/refused-PID` records it. The program
  goes on; the children that got ports keep their breakpoints.
- TMPDIR is the session's tmp for the program (js-debug's inspector socket lands there). Its stdout is drained: the
  adapters send what it prints as output events (debugpy with `redirectOutput`; js-debug the console's calls).
- The hub owns both processes: they get the session's signals, and once the adapter is gone the program is killed.
- lldb-dap runs outside the sandbox on macOS (no task port) and delve needs `ptrace`: both are refused here.

The live tests (`debug/tests_blocked_live.rs`, ignored by default) run both adapters through the hub's sessions in
the adapter image: each program starts a child at once (js-debug forks on its first line), the breakpoint is in the
child, and while it is stopped every TCP listener in the container is one of the block's ports; a third gives a
js-debug program a block of three ports, so its second child runs without the debugger and says so. The block's own
tests (`debug/tests_ports.rs`) include two processes claiming in one lock directory (the test binary runs itself as
the second) and a stranger's listener on the adapter's port (`debug/tests_blocked.rs`).

## Recorded runs: probes, the stop timeline (spec §19.2)

Every session the hub starts is recorded (`debug/record.rs`, `Records`; the hub's records are made in
`debug/runs_wire.rs` from `<state>`):

- **The launch snapshot**: `begin` writes the root's tree into the checkpoints' shadow repository
  (`timeline::snapshot::take_kept`, the files as on disk, with the editor's unsaved list kept beside it) and keeps it
  as `refs/drgnx/debug/<run>`, so a past stop shows the file that ran. A Python launch gets `PYTHONHASHSEED` (the
  run's, kept in the record) so a replay hashes the same.
- **Probes** (`debug/probes.rs`): logpoints whose message is `"\u{1e}drgnx:<probe>:{<thread>}:{<expr>}"`. Python's
  thread is `threading.get_ident()` and its value `repr(expr)`; the others send no thread. Output events carry no
  thread, so it rides in the marker. `Records::output` takes those lines out of the console text and records them as
  hits. Probes are appended after the user's breakpoints in every `setBreakpoints` (a line with a user breakpoint gets
  no probe), and `breakpoints::fit` drops them for an adapter without `supportsLogPoints`, so a probe never becomes a
  stop. Caps per second (`probes::cap`): 2000 for debugpy and js-debug, 200 for the rest (which stop to probe, and
  the run says so); the rest are thinned and counted; a fork's run keeps every hit. "Probe the Result"
  (`probes::next_line`) places the probe on the next line that runs, past continuation lines, blanks and comments. A
  project's probes are kept in `<state>/debug-probes/<xxh3 of root>.json`.
- **The run file** (`debug/runfile.rs`): `<state>/debug/runs/<run>.drun`, `DRUN1\n`, then blocks (u32 raw length, u32
  compressed length, zstd) of JSON-lines frames, 64 KB raw each; `<run>.drun.idx` indexes blocks, stops and each
  probe's hits. Each stop's capture (threads, the stack, the selected frame's scopes and variables) is cut to 64 KB:
  the last scope's variables first, then frames past the selected one, then threads. A file holds 64 MB: past that
  the oldest hits go (rewritten to three quarters), never a stop.
- **The record** (`<run>.json`, `RunMeta`) is also an Urdr entity of kind `debug_run` (`norn::write::debug`), written
  in order on one task, `recording` then `ended`.
- **Retention** (`Records::prune`, after every run's end): 14 days, except pinned runs and runs whose task is open,
  then 2 GB per project, oldest first; a pruned run's file, snapshot ref and entity go.
- **Ordering**: `RunHit.seq` and `RunStop.index` come from one counter, so "the hits before stop k" is
  `seq < index`. `bp_hit` counts the stops at that line, this one included; `steps` are the step ops since the last
  breakpoint stop. `RunInfo` and `trait Runs` are what a fork (spec §19.3) reads.

Methods (runstav `methods::debug_runs`, the user class only: agents are refused, which is `debug.read`'s gate):
`debug/probe/op {root, op?}` (add, result, remove, edit) → the project's probes; `debug/runs/list {root}`;
`debug/run/get {run, from?, count?, current?}` → a page of stops, each probe's lane (at most 2000 hits) and `strip`,
the timeline's rows (`debug/strip.rs`, the hub's rows: a head, the stops, a lane per probe with a sparkline);
`debug/run/stop {run, stop, file?}` → the capture and the file's text from the snapshot (`not_what_ran` when it was
unsaved at the start); `debug/run/pin {run, pinned}`. Events: `debug-run {run, n, root, session, name, state, stops, hits,
thinned, dropped, stops_to_probe, outcome, stop}` at the start, each stop and the end; `debug-probe-hits {run, hits}`, batched every 50 ms.

The editor's half, `drgnx-debug-timeline.el`: the probe column (`drgnx-margins-claim 'debug-probe … :order 1`, after
the breakpoint column; an SVG ring with a dot, `◉` or `o` on a terminal), the values at a line's end (throttled to 10
a second), the strip buffer (it only inserts the hub's rows: a face or property the editor does not know is dropped),
and past stops (`drgnx-debug-past-mode`'s keys, the past buffer with the snapshot's text and the banner, the variables
buffer). Tests: `debug::tests_probes`, `debug::tests_record`, `test/unit/debug-timeline-test.el`.

## What-if forks (spec §19.3)

A fork replays a recorded run in a sealed copy up to a point, changes a value or the code there, and runs on; the
What-if tab shows it beside the run. Linux only for now; other hosts refuse with the reason.

- **The engine** (`debug/fork.rs`): `check` maps the point onto the run: a stop of the run (a stop reached by
  stepping maps to the breakpoint stop before it plus the steps since), or a line's N-th pass. Refused: an attach
  run, an adapter that needs `ptrace` (delve, lldb-dap: Gleipnir allows none), a run with no launch snapshot, a hit
  beyond the run's. A point the run took more than 60 s to reach asks first. `drive` sets a breakpoint on the point's
  line and the probes' logpoints (a plain breakpoint wins on a shared line, and the probe there is read by
  `evaluate`), reaches the line's pass (the adapter counts where it can and no probe sits on the line: debugpy's
  `hitCondition`, for js-debug a condition with a counter that V8 runs (under `Symbol.for('drgnx.forkPass')`, a key no program
  name can clash with), since its `hitCondition` pauses at every pass;
  the landing must have had the run's probe hits before it and the stack the run recorded at that stop (names and
  lines), and, where no probe hit tells the passes apart, the run's plain locals there (values without children):
  when the run recorded two or more passes of the line, only the locals that change between them (`fork::varying`:
  loop counters, accumulators), and a difference fails naming both sides; without that record any plain local, and a
  difference fails saying it may come from a source the fork does not replay, with `anyway` in the failed view (the
  editor's Fork Anyway sends `debug/fork` again with `anyway`). Only `PYTHONHASHSEED` is replayed: the clock, random
  numbers and the environment's other values are the program's own; otherwise the
  hub counts, stopping and continuing at each pass), repeats the steps, reads the thread's id
  expression, applies the change (`setExpression` when the adapter has it and the variable an `evaluateName`, else
  `setVariable`), takes the point's breakpoint away and runs until the next stop, the end, or a probe's next hit.
  Child sessions (`startDebugging`) are second connections to the same sandbox. It stops every session at the end,
  children first.
- **Probes**: the run's own (`debug/probes.rs`), each a logpoint whose message is the one the run recorded with
  (Python's value its `repr`); hits are parsed out of output events. Threads are paired by the order of their first
  hit (the id expression differs per run; JavaScript names none, on either side).
- **Comparison** (`debug/compare.rs`): "matched on N of M hits" on the stopping thread before the point and the first
  hit that differs; each probe's values after it, then and now.
- **In the hub** (`debug/fork_hub.rs`): each fork is an object of its own (`fN`), never `history/fork`. Its tree is a
  folder under the runs root, `debug-forks/FORK/w`, with the run's launch snapshot restored into it (no git branch);
  `tmp/` beside it is the session's temp. The run's configuration is resolved again from its `debug/start`, and its
  hash (`record::config_hash`: xxh3 of the substituted configuration with keys sorted) must be the run's, else the
  fork is refused (the run would not replay). A code what-if stops at `editing` with the tree's path; `debug/fork/run`
  measures what the edit changed (each file's hash against the tree as restored, `.env` files left out) and runs it.
  The run's `PYTHONHASHSEED` is replayed. The `debug-fork` event follows the fork; `debug/fork/drop` removes it and
  its folder. The hub's start removes any trees an earlier hub left under `debug-forks/`.
- **For the other debugging tools** (`debug/fork_wire.rs`): `trace(front, run, stop, env, files)` replays a run to
  one of its stops in a tree of its own and ends there (the origin trail): FILES (paths inside the tree) are written
  into it and ENV, called with the tree's path, adds to the environment before the launch; the tree goes when the
  returned `TraceTree` does. `run_in(front, run, tree, watch, limit)` runs the run's configuration, sealed, in a
  bisect slot (TREE, its links resolved, strictly under `fork_seal::slots_root`, `debug-forks/slots`) to the
  program's end, watching an exception stop at a line or a probe's values (paths relative to the project), and
  reports where the exception stopped, the values, the exit code, or that LIMIT ran out (`timed_out`, not an error).
  Both resolve the configuration again and refuse a different hash or an input the run needs; neither makes a fork
  entry or an event.
- **The seal** (`debug/fork_seal.rs`): the adapter and the program run under Gleipnir's full tier (the reduced tier
  is refused): the system, the adapter's install and the hub's own program read-only; the tree and the temp
  writable; an isolated network with its own loopback and no relay (`net.isolated.loopback` with an empty `relay`,
  allowed for this alone), so nothing gets out. The project's `.env` and `.env.*` (at its root and the
  configuration's cwd) and its `envFile` are bound read-only over empty files at their places in the tree: the
  program reads them, and they are never copied or shown. The configuration's environment values reach the launch
  and never an event.
- **The shim** (`etc/debug-fork-shim.py`, `etc/debug-fork-shim.js`; the hub's side `debug/fork_mux.rs`): the hub
  reaches nothing inside the namespace but stdio, so a shim in the adapter's own runtime (the hub's program and its
  folder stay closed to sandboxes) multiplexes: each message carries `Drgnx-Conn: N`; connection N is one more
  `python -m debugpy.adapter` (debugpy's sub-process sessions), or one more TCP connection to js-debug's server, which
  the shim starts on the namespace's loopback; `Drgnx-Close: N` says one ended. It is written into the fork's temp.
- **The methods** (runstav `methods::debug_fork`): `debug/fork` (the fork, or `ask` for a slow point, or `needs` for
  an input whose value was not kept), `debug/fork/run`, `debug/fork/drop`, `debug/compare`.
- **The editor** (`drgnx-debug-fork.el`): Fork from Here asks what changes and where the fork ends, the What-if tab
  draws each `debug-fork` event (values that differ in the `warning` face), Open Fork finds the file in the tree, and
  Take Fork's Change shows each changed file's diff and puts the fork's text into the buffer (undoable, not saved).
- **Tests:** `debug::tests_fork` (the engine on mock adapters), `debug::tests_fork_hub` (refusals, the event from
  preparing to done, a code what-if, drop; no environment value in any event; a trace's env and files, plain runs'
  exception, probe values and time box, the slot check), `debug::tests_fork_seal` (the
  manifest, the `.env` binds, the spec validates), the mux test, `test/unit/debug-fork-test.el`, and the
  live rows in `debug::tests_fork_live` (ignored by default; the adapter image, `--sandbox`): Python and JS forks
  that match 20 of 20, a clock fixture whose first difference is found, a program that cannot connect out or write
  outside its tree, a `.env` the program reads that is never in the tree, a trace whose program sees its injected
  value and file, plain runs in bisect slots, and a run recorded live and then forked.

## Debugging with an agent (spec §19.5)

A partner agent debugs beside the user through six norn tools (`norn/src/tools/debug.rs`), which a session gets once its project debugs (a launch
configuration, a live session or a recorded run; [coordination.md](coordination.md)), mid-session too;
each is a thin `CoordTool` whose call reaches the hub as `Hub::debug(sid, op, args)` with the caller's session (an
outside agent is refused: "the debugger's tools are for agents drgnx runs"). The hub's half is
`drgnx-ratatoskr/src/debug/agent.rs`: `tool` finds the session, maps the op to its matrix row (`action_of`), gates it
with the manager's `gate` (an Ask makes a card and the call answers "X needs the user's yes (card N)"; Never answers
its reason), then dispatches:

- `debug_read` (`debug.read`): the sessions, a session's stop, a recorded run's summary or one stop (`Runs::capture`),
  a fork's view. `history/*` stays the user's: no tool reads the edit history.
- `debug_probe` (`debug.probe`): adds a probe or breakpoint marked with the agent's session (`Probe.agent`,
  `Bp.agent`; `Probes::mark`, `Debug::mark_breakpoint`) and removes only its own. `debug-probes` tells the editors.
- `debug_fork` (`debug.fork`): a value or replay what-if, marked as the agent's (`Forks::mark`, the view's `agent`).
  A code what-if is refused here: code goes through `debug_fix`.
- `debug_live` (`debug.live-eval` for `evaluate`, `debug.drive` for steps): carries the `epoch` of the stop the agent
  read. `still_at` checks it before and again right before the control op, so a step the user took first wins.
- `debug_hypothesis`: an Urdr record of kind `debug_hypothesis` (`norn::write::debug::hypothesis`; open, confirmed or
  rejected, with evidence), written as `agent:SID` and changed only by the agent that made it; `debug-investigation`
  `{root, hypothesis}` tells the editors.
- `debug_fix` (`debug.fork`): `Forks::check_fix` makes a fresh tree from the run's launch snapshot, writes the files
  (relative paths inside the tree only), runs the run's configuration in it (`run_in`, `FIX_LIMIT` 120 s) and drops the
  tree. The fix is offered (`debug-investigation` `{root, fix}`) only when the predicate passes: a clean exit with no
  stop on the failure's `watch` text (`Predicate`).

The editor's half is `drgnx-debug-investigation.el`: it keeps the hypotheses (200) and fixes (20) the events bring,
draws the **Investigation** buffer, asks the agent to explain itself (`agents/send`), shows a fix as diffs against the
user's buffers and accepts it through `drgnx-history-with-origin "agent:SID#fix-H"`, so the history and undo record it
as the agent's step. The gutter and the probe column ring an agent's marks in `drgnx-debug-agent-ring` (inheriting
`drgnx-agent-1`) and name the agent in the tooltip.

Tests: `debug::tests_agent` (each row gates its tool, the user's step wins, an agent removes only its own marks
(`may_remove`), a fix passes only a clean exit without the failure, and one that still fails is not offered
(`offer`)), the fork hub's `a_fix_is_run_in_a_fresh_tree_with_its_files` and `a_forks_view_names_the_agent_that_made_it`,
norn's `each_debugger_tool_reaches_the_hub_as_its_session`, `a_hypothesis_is_recorded_changed_by_its_agent_only` and
`debug_rows_per_preset`, `test/unit/debug-investigation-test.el`, and the conformance scenarios
`debug/partner-agent-under-cautious` (Never: a reason, no card), `debug/partner-agent-under-balanced` (Ask: a card)
and `debug/partner-agent-investigates` (the mock adapter, Autonomous: the agent reads the stop, cannot remove the
user's breakpoint, sets its own, which the editors get with its agent, and its step read before the user's step is
refused while its step at the new stop runs). The tools' schemas are held to `BUDGET_DEBUG` (5,000 bytes; 3,791 when
it was set) in `tools_schema`.

## Which change broke it: bisect over the edit history (spec §19.6)

`debug/bisect.rs` is the search, `debug/bisect_wire.rs` the states and the methods, `debug/bisect_card.rs` the card.

- **The states** (`bisect_wire::gather`): the good state the user picked (a commit, a recorded run's launch snapshot, or
  a save or agent step of the edit history), then everything after it, ordered by time: the commits on HEAD's
  first-parent line (`git log good..HEAD`), the saves and agent steps of the worktree's history branch
  (`verdandi::History::records_on`; typing is never a state), the launch snapshots of recorded runs; and last "now",
  the folder as it is (`take_kept`, ref `refs/drgnx/bisect/<id>` until the next bisect of the project). At most 512
  (the newest).
- **Their trees** (`bisect_wire::materialise`): each state is a tree in the bisect's own shadow repository
  (`<state>/hub/runs/debug-forks/slots/<id>/`, the forks' slots root: the one place in the state folder a sealed
  job's tree may be), which borrows the objects of the project's repository and of the snapshots'
  through `objects/info/alternates`, so a commit's or a launch's tree is used as it is and nothing is copied. A record
  is the history branch's base commit with every document as it was after it (`History::texts_after`) written over
  it (blobs by `hash-object`, the base's file modes kept). A state whose tree equals the one before it is dropped.
- **The search** (`bisect::Search`): `git bisect run`'s meanings (exit 0 good, 125 skip, 1–127 bad; a signal, a time
  box or a code past 127 skips). The good state runs first; when it fails too the bisect ends with `needs-good`. Then
  each round runs the states that cut the range between the last good and the first bad into equal parts, one per
  free slot (default 3, at most 8); a skipped state's neighbour is asked instead. The first bad state and the last
  good one run once more: a run that disagrees is reported as flaky. Only skipped states between them: the answer is a
  range (`skipped`).
- **Slots**: each slot keeps one folder (`slot-N`), moved from state to state by delta
  (`timeline::snapshot::restore_into`: only the files that differ are written, a file the state lacks is removed).
  The slots go when the bisect ends; the repository stays for narrowing until the project's next bisect, and nothing
  outlives the hub (the forks' sweep at the hub's start clears the slots root).
- **The predicate** (`bisect_wire::Jobs`): `test` (ARGV's exit code) or `exit` (ARGV exits with CODE: bad), with an
  optional BUILD run first (its failure skips the state), each run a sealed job in the slot's folder
  (`exec::start_sealed`, label `bisect-<id>`: an agent's sandbox with the slot its only writable folder, since the
  states may be an agent's writing; the time box `timebox_s`, default 600 s). `exception` and `probe` (Python and
  JS) run the recorded run RUN's configuration in the slot, sealed as a fork is (`fork_wire::run_in`, spec §19.3),
  watching AT (`path:line`, relative to the project): `exception` is bad when it raises there; `probe` is bad when
  CONDITION is true there once (`bisect_wire::outcome_of`). A run the time box cut, or a probe line that never ran
  in that state, skips it.
- **Narrowing** (`bisect::narrow`): the hunks from the last good tree to the first bad one (`git diff -U0`), then delta
  debugging (ddmin) over them: each set tried is the good tree with those hunks applied (`git apply --cached
  --unidiff-zero` into a temporary index), run in its own `narrow` folder.

Methods (runstav `methods::debug_bisect`, the user class only): `debug/bisect/states {root, good?}` → the states
after GOOD (`{id, kind, at, label, author?, session?, step?, decision?, record?}`); `debug/bisect {root, good,
predicate, parallel?}` → `{bisect, states, estimate: {runs, slots, states}}`; `debug/bisect/cancel {bisect}` (the runs
are stopped); `debug/bisect/narrow {bisect}`. Event: `debug-bisect {bisect, state, dots, estimate, result?, why?,
hunks?, rows}`, `state` one of `checking-good`, `running`, `found`, `needs-good`, `cancelled`, `failed`, `narrowing`,
`narrowed`, `narrow-failed`; `result` is `{first_bad, last_good, skipped, flaky, runs, diff}` (the diff at most 256
KB). `rows` is the card (`bisect_card::rows` over the bisect's events merged).

The editor's half, `drgnx-debug-bisect.el`: **Find the Change That Broke It…** reads a good state and a command,
the card inserts the hub's rows, and its actions are Show Step (the diff), Revert Step (`history/revert`'s card of
the step before, for an agent's step), Ask the Agent (`agents/send` to the session that made it), Narrow and Cancel.
Tests: `debug::tests_bisect` (the search, ddmin, slots, flaky, cancel), `debug::tests_bisect_wire` (commits and records
as trees, a slot moved between them, hunks, the card), `verdandi`'s `tests/materialise.rs`,
`test/unit/debug-bisect-test.el`.

## Where did this come from: the origin trail (spec §19.4)

`debug/origin.rs` is the trail, `debug/origin_wire.rs` the method, `etc/debug-origin.py` the tracer.

- **The tracer** runs inside the replayed program, so it is Python (≥ 3.12, `sys.monitoring`, PEP 669; tool id 4,
  else 3 or 1). It is written into the replay's tree (`.drgnx-origin/drgnx_origin.py` with a `sitecustomize.py`,
  first on `PYTHONPATH`) and turned on by `DRGNX_ORIGIN={"out", "root", "watch"}`: only code under ROOT is watched.
  For each code object it reads the bytecode once (`dis`): each line's stores (names, attributes, subscripts), the
  names it loads, and method calls on names. On LINE events it records the previous line's stores to the watched
  targets (a dotted question matches that attribute on any object), with the line's operand values, as JSON lines in
  `.drgnx-origin/records.jsonl`; the first line is `{"python": version}`. A method call on a watched value is a record
  of kind `call` ("changed inside `list.append`").
- **The trail** (`origin::trail`): level 1 replays to the stop watching the question; its link is the last record
  about it (`origin::link`). The link's operands that hold data (not functions, classes or modules) are the next
  level's questions (`origin::follow`, at most 6), one replay per level, at most 3 levels (`depth`).
- **Python older than 3.12** (the records file names the version and holds nothing else): the static candidates, the
  assignments to the name in the files of the stop and its stack as they ran (the launch snapshot), found with
  Hrafn's grammar (`$O.attr = $V`, `name = $V` and the augmented forms), labelled "candidates, not traced".
- **The replay** is the `origin::Replay` trait, set when the hub binds (`origin_wire::ForkReplay`): a sealed trace
  of the run (`fork_wire::trace`, spec §19.3), ended at the stop, with the tracer's files written into the trace's
  tree (`origin::trace_files`) and its environment (`origin::trace_env`); the records are read back with their files
  named as the project's (`origin::read_trace`), and the tree goes. One replay per level.

Method (runstav `methods::debug_origin`, the user class only): `debug/origin {run, stop, expr, depth?}` →
`{origin}`; EXPR is a name or a dotted path. Event: `debug-origin {origin, run, stop, expr, n, state, level?, links,
note?, why?, rows}`, `state` one of `tracing`, `done`, `failed`; a link is `{level, question, target, value?, path,
line, func, operands, inside?, traced}`. `rows` is the card (`origin::rows`).

The editor's half, `drgnx-debug-origin.el`: **Where Did This Come From?** (`debug-origin`, Alt-click on a name in a
past stop's buffer) asks for the name at point, the card inserts the hub's rows, and `RET` on a link
(`debug-origin-open`) opens it as a past stop. Tests: `debug::tests_origin` (golden trails on
`tests/fixtures/origin/stock.py` run by python3 under the tracer: three levels with attribute stores, a change inside
`list.append`, the 3.11 candidates, lenient parsing, the card), `debug::tests_fork_live`'s
`a_python_trail_is_traced_in_sealed_replays` (live: debugpy in Gleipnir, three levels through real traces),
`test/unit/debug-origin-test.el`.
