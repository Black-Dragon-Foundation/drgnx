# Plugins: the plugin host (`brokkr`)

`runtime/crates/brokkr` is drgnx's plugin host. A plugin is a WebAssembly component that gives agents
tools (abilities) and shapes what they do (hooks). This page covers the manifest, the approval hash, the install
scan, the hook engine, the WASM host that runs plugins ("What a plugin can reach") and the hub's side (install,
approval, abilities, the hook points). To write a plugin read "Building a plugin" first; users read
[the guide](../guide/plugins.md).

## Building a plugin

A plugin is a Rust crate that builds to a WebAssembly component with plain cargo: no `cargo component`.

1. Add the target once: `rustup target add wasm32-wasip2` (drgnx's own toolchain pins it through mise).
2. Start from `runtime/plugins/template` (copy it; its `Cargo.toml` has `crate-type = ["cdylib"]` and
   `wit-bindgen =0.63.0`).
3. `cargo build --target wasm32-wasip2 --release`.
4. Make a folder named after the plugin, with `plugin.json` and the built `.wasm` copied to `plugin.wasm`
   (`target/wasm32-wasip2/release/my_plugin.wasm`).
5. `drgnx plugins install FOLDER`, then approve it on the Plugins page and put it on `drgnx-agents-plugins`
   ([guide](../guide/plugins.md#installing-and-approving)).

Rust is the supported language. Any language whose toolchain makes a component of the `drgnx:agent-tools/plugin` world
and imports only the interfaces under "What a plugin can reach" works, but only Rust is tested. No `.wasm` file is
ever committed to this repository: the fixtures are built at test time.

## The template walk-through

`template/plugin.json` declares one ability, `shout`, with an input schema (the schema keywords the host accepts are
listed in the guide's "Abilities"), and one `before-tool` hook that may `deny` or `annotate` calls of kind `execute`
within 500 ms. No hosts, a 64 KiB store.

`template/src/lib.rs` does four things:

- `wit_bindgen::generate!` with `path` pointing at the WIT directory (`../../crates/brokkr/wit` in the drgnx sources;
  copy `runtime/crates/brokkr/wit` next to your plugin otherwise) and `world: "drgnx:agent-tools/plugin"`.
- `impl ability::Guest`: `call(tool, args_json)` matches the ability's name, parses the JSON arguments and answers a
  JSON string or an `Err` text. Arguments were already checked against `input_schema`.
- `impl hook::Guest`: `run(point, input_json)` returns a `Verdict`. The template ignores every point but
  `BeforeTool`, reads `tool.command` from the input and denies `rm -rf /`; everything else is `Allow`.
- `export!(MyPlugin)`.

A hook is called only for the points its manifest declares, and only a verdict the manifest lists is accepted: a
verdict outside `verdicts` (`allow` always passes) counts as a failure of the hook, which refuses the step unless the
hook is `advisory`.

## The hook's input

`input_json` is the point's `detail` object with `v`, `point`, `session`, `step` and `previous` set (see "The hook
engine"). `before-tool` carries `tool` (`kind`, `name`, `title`, `input`, `paths`, `command`); `after-edit` carries
`edit` (`path`, `diff`, and `content` when the hub writes the file). `before-commit` carries
`commit` (`branch`, `message`, `diff_stat`, `paths`) and `at-review` carries `review` (`summary`, `report`,
`diff_stat`); `session`, `step` and the role are `null` at both, since a job's point has no calling session
(`hook_points::before_commit`, `hook_points::at_review`; the runner calls them in `runner/review.rs`: `commit_hooks`
after the gate cleared, `review_hooks` before `start_review_agent`). `report` is empty today. A `change` returns the point's replacement object: `{"arguments": {…}}`, `{"content": "…"}`, `{"message": "…"}` or `{"notes":
"…"}`, and is accepted only where the hub itself performs the action (the guide's "Before a tool call" and "After an
edit" say where).

## Point budgets

| Point | Budget | `deadline_ms` up to |
|---|---|---|
| `before-tool` | 2 s | 2000 |
| `after-edit` | 5 s | 5000 |
| `before-commit` | 10 s | 10000 |
| `at-review` | 30 s | 30000 |

The budget is shared by every rule and hook at the point; each hook gets the smaller of its `deadline_ms` and what is
left. An ability's deadline is 30 s. Hooks run on a runtime of their own: at most 2 calls per plugin and 4 in all, so a
plugin that spins can neither starve the hub nor another plugin for longer than its deadline.

## Testing a plugin

- **By hand:** install it, approve it, enable it in a project, and look at the step's provenance in the agent view: it
  names each rule and hook that looked, its verdict and its time.
- **In the drgnx tree:** add the plugin to `runtime/plugins/fixtures` (a binary and `manifests/NAME.json`) and use
  `brokkr::test_support::fixture("NAME")`, which builds every fixture with one cargo run and returns an install folder.
  Drive it through `brokkr::Host` (`brokkr/tests/host.rs` is the model) on real time: the host's timeout runs on the
  caller's runtime, so paused tokio time would end every wait at once. The template builds the same way through
  `test_support::template()`.
- Both need the `wasm32-wasip2` target of the toolchain that runs the tests, and run in a container like every build.

Test a hostile case too: a hook that spins (`slow-hook`), traps (`trap-hook`) or allocates (`big-alloc`) must end in a
refusal, not a hang.

## The manifest

A plugin is a folder `NAME/` holding `plugin.json` and `plugin.wasm`, installed under `<data>/plugins/NAME/`.
`brokkr::parse` reads the manifest as data. Unknown keys are refused, and every error carries the JSON path of the
value at fault (`hooks[0].deadline_ms: 1 to 2000 at this point`).

```json
{
  "name": "deny-rm", "version": "0.1.0",
  "abilities": [{"name": "check_path", "description": "Says whether a path is inside the worktree.",
                 "input_schema": {"type": "object", "properties": {"path": {"type": "string"}},
                                  "required": ["path"], "additionalProperties": false}}],
  "hooks": [{"point": "before-tool", "verdicts": ["deny", "annotate"], "filter": {"tool_kinds": ["execute"]},
             "deadline_ms": 500, "advisory": false}],
  "hosts": ["api.example.com", "internal.example.com:8443"],
  "kv_bytes": 65536
}
```

| Key | Rule |
|---|---|
| `name` | `^[a-z][a-z0-9-]{0,31}$`; the folder has the same name |
| `version` | 1 to 64 characters of letters, digits, `.`, `+`, `-` |
| `abilities[].name` | `^[a-z][a-z0-9_]{0,47}$`, unique; `len(plugin name) + 1 + len(ability name) <= 44`, so the tool name `mcp__drgnx-plugins__NAME_ABILITY` fits 64 characters |
| `abilities[].description` | at most 1024 characters |
| `abilities[].input_schema` | a JSON Schema object schema (`"type": "object"`) |
| `hooks[]` | at most one per point; `point` is `before-tool`, `after-edit`, `before-commit` or `at-review`; `verdicts` is a non-empty subset of `allow`, `deny`, `change`, `annotate` |
| `hooks[].deadline_ms` | 1 up to the point's budget: 2000, 5000, 10000, 30000 ms |
| `hooks[].advisory` | an advisory hook's failure is a note, not a deny; forced on when `verdicts` is only `annotate` |
| `hooks[].filter` | `tool_kinds` (the ACP kinds, or `drgnx` for the hub's own tools), `tools` (exact full tool names), `paths` (globs); all optional, ANDed |
| `hosts` | at most 16 https hosts, each a lowercase ASCII name (an international name as its `xn--` form) with an optional `:port` (default 443) |
| `kv_bytes` | at most 1 MiB, which is also the default |

**A `change` before a tool must name its tools.** A hook that rewrites a tool call's arguments needs
`filter.tool_kinds == ["drgnx"]` and a non-empty `filter.tools`, each name starting `mcp__drgnx__` or
`mcp__drgnx-plugins__`. `["drgnx"]` alone is refused for `change`; a hook that only denies or annotates may use it.
`change` at `after-edit` applies to writes the hub makes (`fs/write_text_file`) only; that is enforced when the hook
runs, not by the manifest.

**Hosts.** No wildcard, no IP literal (a last label that does not start with a letter is refused too, since
`0x7f.0x1` and `2130706433` are addresses), no single-label name, no `localhost` or `*.localhost`, no `*.internal`,
and none of the web policy's `NAME_NEVER` names or the names under them. A private address is reached only through
the sandbox proxy's pinned addresses setting, never by a manifest.

## The approval hash

`plugin_hash(manifest_bytes, wasm_bytes)` is SHA-256 over each file preceded by its length (8 bytes, big endian), so
a byte cannot move from one file to the other. A user approves a hash, and a plugin whose files hash differently is
not the plugin that was approved.

## The install scan

`scan(root)` reads `<root>/*/`: for each folder it reads `plugin.json` (at most 256 KiB) and `plugin.wasm` (at most
64 MiB) through `eitri`, beneath a directory fd it pinned, so no link under `root` is followed. A folder that is a
link, or a stray file, is skipped. A folder that cannot be read, whose manifest is refused, or whose manifest names
another plugin is an error named by the folder. `root` itself may pass through links (it is the user's own
configuration). Results come in folder-name order.

## Test fixtures

`runtime/plugins/fixtures` is a crate of its own (its own workspace, excluded from the runtime workspace, so
`cargo test --workspace` never builds it for the host). One binary per test plugin, each with its manifest in
`manifests/NAME.json`: `echo-ability`, `deny-rm-hook`, `rewrite-commit-msg`, `annotate-edit`, `change-tool-arg` (a
`before-tool` change of the `echo-ability` call's arguments to `{"changed": true}`), `slow-hook` (spins),
`trap-hook` (traps), `big-alloc` (allocates `mib` MiB), `fs-importer` (std file access, so it imports
`wasi:filesystem`), `http-ability` (the host's HTTP, key-value store and log), and the three that must fail to load,
`http-importer` (`wasi:http`) and `socket-importer` (`std::net`, so `wasi:sockets`). The guests use `wit-bindgen`
0.63.0 and plain `cargo build --target wasm32-wasip2 --release`; no binary is ever committed.

`brokkr::test_support::fixture(name)` (feature `test-support`, or `cfg(test)` inside `brokkr`) builds all of them with
one cargo run under a lock file, so parallel tests and test binaries build once, and returns an install folder
(`plugin.json` and `plugin.wasm`) that `scan` reads. It needs the `wasm32-wasip2` target of the toolchain that runs
the tests. `test_support::template()` builds the template the same way.

CI builds them first, in their own step (`.github/ci/wasm-target.sh`, in the Linux and macOS jobs of `runtime.yml`): with
rustup it adds the target; the Fedora 45 job's packaged Rust has no `wasm32-wasip2` standard library and cannot use an
upstream one (its crates are tagged with its own rustc), so the script installs the same rustc version with rustup-init
(checked against its published SHA-256) for the fixtures alone. `DRGNX_WASM_CARGO` names the cargo the test support
builds them with, when it is not the one running the tests.

## The template

`runtime/plugins/template` is a minimal plugin with one ability (`shout`) and one `before-tool` hook, commented for
plugin authors. Build it with `cargo build --target wasm32-wasip2 --release`, copy `my_plugin.wasm` to `plugin.wasm`
beside `plugin.json` in a folder named after the plugin, and install the folder. Outside the drgnx sources, copy
`runtime/crates/brokkr/wit` next to the plugin and change the `path` in `wit_bindgen::generate!`.

## The hook engine

`norn::hooks` decides a step from the user's rules and the plugins' hooks. It is pure: it runs no plugin and touches
no store. The hub's points (before a tool call, after an edit, before a commit, at review) call it.

- `parse_rules(&Value)` checks `drgnx-agents-hook-rules` (the rule format: [guide](../guide/plugins.md#your-rules)):
  unknown keys refused, every error with its JSON path (`[2].id`), ids unique, `command` compiled by the `regex`
  crate (linear time) under a 1 MiB size limit, never `fancy-regex`. `glob_match` is the segment-aware glob of rules
  and hook filters (`*` and `?` in one segment, a `**` segment across segments), iterative with one backtrack point
  per level; `runner/clash.rs`'s glob is not reused (there `*` crosses `/`, and it recurses).
- `acp_kind(raw, tool_name)` normalises an agent's kind: an ACP kind stays, anything else (`drgnx` included) is
  `other`, and an `other` whose tool name is in `KIND_BY_NAME` takes that kind (Claude's `NotebookEdit`, Kimi Code's
  `FetchURL`, DeepSeek Harness's snake-case tools). It never returns `drgnx`; only the hub's servers set it
  (`hook_points::hub_kind`: `drgnx`, but the pair tools `read_file` → `read`, `edit_file` and `write_file` → `edit`).
  `Session::pair_write` runs the after-edit point before the pair door, as `write_file` does for
  `fs/write_text_file` (`pair/after-edit-rules-see-a-pair-write`). The
  table only sharpens what a filter sees: the seam's `classify` reads the agent's own kind, unchanged.
- `subscribed(input, rules, plugins)` is the points' fast path: does any rule, or any plugin's hook at the point
  whose `filter` matches, look at this step.
- `run(input, budget, accepts_change, rules, plugins, host)` runs the matching rules in list order, then each plugin's matching hook
  in plugin order, and returns one `Record {source, verdict, ms, error, advisory}` per match. A deny, or a failure of
  a non-advisory hook, stops the run (later matches are recorded with no verdict and no error: not run). Each hook
  gets `min(deadline_ms, what is left of the point's budget)`, measured on `HookHost::now` (the hub's clock); with
  nothing left it is not run and its record is that failure. A verdict outside the manifest's `verdicts` (`allow` is
  always allowed), a change where `accepts_change` is false ("change is not accepted here") and a change that is
  not the point's replacement object (`{"arguments": object}`, `{"content": string}`, `{"message": string}`,
  `{"notes": string}`) are failures, and such a change is never written in. Each hook's input is the point's
  `detail` object with `v`, `point`, `session`, `step` and `previous` (`[{source, verdict}]`) set, and the last
  accepted change written in (`tool.input`, `edit.content`, `commit.message`, `review.notes`). After each accepted
  change `HookHost::refresh` re-reads the step's matching fields (`paths`, `command`) from it, so a later hook's
  filter matches the step as it will run, not as the point first gave it. Rules run first, before any change, so
  they match the step as given.
- `HookHost` is what `run` calls a hook through: `run_hook(plugin, point, input, deadline)`, which keeps the hook
  within its deadline; `refresh(&mut input)`, which derives `paths` and `command` from a changed `detail` the way the
  point derived them from the original (required, so a point cannot forget it); and `now()`. `PluginHooks {host,
  io, refresh}` implements it over `brokkr::Host`: the step's session or job I/O, and the point's own `refresh`;
  the point passes its `accepts_change` to `run`. A host `Timeout` reads `timed out (300 ms)`, the others as
  `CallError` prints them (`trap: …`, `refused: …`, `busy`, `error: …`). `HookPlugin` (a manifest and its approved
  hash) is implemented for `brokkr::Installed` and `brokkr::Plugin`. `Verdict` is `brokkr::Verdict`.
- `combine(cell, accepts_change, records) -> Outcome {decision, decided_by, annotations, provenance}`. A `Never`
  cell stays `Deny`; `Ask` stays `Ask` and `Allow` (or `None`: a hub tool whose matrix checks are in its body)
  stays `Proceed`, unless a record denies. The first deny decides (`decided_by` is its index); a failure is a deny,
  or a note when advisory; a change where `accepts_change` is false is the failure "change is not accepted here";
  the last accepted change rides on `Proceed` or `Ask`. Notes are capped at 8 of 2 KiB, then "+N more".
- Sources print as `rule:ID` (else `rule:N`) and `plugin:NAME@VERSION#` with the hash's first 4 bytes in hex.

`hooks::tests::allow_never_widens` checks every cell, both contexts and every list of up to three records of every
kind (3 200 cases).

## The hook points

`drgnx-ratatoskr/src/hook_points.rs` runs the engine where the hub sees a step. Before a tool call is there; after an
edit, before a commit and at review use its row.

- **Sites** (`At`): `Seam` (`Session::seam_hooks`, from `permission_request`), `HubServer` (`at_hub_server`: the
  coordination tools through `sessions.rs`'s `AfterTool` and `norn::tools::Hub::before_tool`, and the abilities'
  server), `Adapter` (the panel extension's `_drgnx/before_tool`). Only `HubServer` accepts a change; the caller
  checks the changed arguments against the tool's schema again.
- **A site's facts** (`Site`): session, Urdr project (its plan's, else its folder's repository, resolved once),
  folder, role, profile, job, task. `Session::hook_site(at)` makes one; `Session::tool_call_info(toolCall)` reads a
  request as the hooks see it (`ToolCallInfo::from_acp`: the folded `tool_call`'s kind when the request has none,
  the adapter's tool name, paths from `locations` and the raw input, the command, the session's step).
- **The seam, in order:** the wait-loop refusal and the freshness gate; `classify`; a hub tool's step (`other`,
  named `mcp__drgnx__*` or `mcp__drgnx-plugins__*`) skips the hooks, with a row "hooked at the hub's server" when
  its server would run some; `prepare` (the fast path: the project's rules and enabled plugins, and `subscribed`:
  nothing subscribed is today's seam, with no `dry` and no row); `refresh_from(settings)`, `MatrixGate::dry`; Never
  refuses with no hook run; `run`; a turn no longer asking (`TurnCore::asks_in`) answers `cancelled`; a deny answers
  the reject option and makes no card; a `dry` Allow answers Allow with no `decide`; a `dry` Ask goes to `decide`.
- **`run(front, site, call, prepared, cell)`**: the plugins loaded into the hub's one host (`Plugins::host`,
  `Plugins::loaded`: read, hashed and compiled once per approved hash, then from memory), the I/O of the session
  (`plugins::host_io`, the session's network cell), `norn::hooks::run` with the point's 2 s and the site's
  `accepts_change`, then `combine`. Rules alone run without starting the host. A plugin that does not load, or a
  host or I/O that cannot be made, fails its matching hook (a deny, or a note when advisory). Then one row, the
  notes as `note` entries under the step (`Session::hook_note`), and a deny's `refusal` steered into the turn.
- **The row** (`record_data`, `write_row`): kind `status`, `{"hook": true, point, session, step, job, task, tool, at,
  records: [{source, verdict, ms, reason?}], outcome, more?}`, written with `coord::HOOKS_METHOD`, whose tx actor is
  `hub:hooks` (no wire method has that name). It stays within `DATA_MAX`: the envelope and every source and verdict
  first, then the deciding reason, then the others' (an annotation at most 200 characters), and when even the
  sources do not fit, the deciding record and `more`. `provenance(conn, sid, step)` reads only `hub:hooks` rows;
  `timeline/get` puts them on each step as `hooks`.
- **The lock** (`agents/lock.rs`): `subscribed_kinds(plugins, project)` at launch (a rule or hook naming no kind:
  every kind), `LaunchPlan::with_hook_asks(kinds)` (Claude: managed ask rules of `claude_ask_tools(kind)`, beside
  the user's, never an allow rule) and `hooked(profile, kinds, plan)`, the snapshot's `hooked {before_tool,
  by_adapter, unhooked, why}`. The other providers' locks are in `docs/develop/hub.md` ("Session start: lock, sandbox
  and matrix").

## What a plugin can reach

`brokkr::Host` runs plugins inside the hub's process, on wasmtime 48 (the LTS; features `runtime`, `cranelift`,
`component-model`, `async`, `std`; `wasmtime-wasi` with `p2` only). A plugin gets its arguments, gives a result,
and reaches nothing else unless `HostIo`, the hub's side, gives it.

- **Loading.** `Host::load(installed, approved)` refuses a plugin whose scan hash is not `approved`, then reads
  `plugin.json` and `plugin.wasm` again (through `eitri`, no link followed) and refuses them unless they still hash
  to `approved` ("changed on disk since it was approved"), so code swapped after the scan never compiles. A component
  is compiled once per hash. It fails to load when it uses a Wasm proposal that is off (tail calls, memory64, multi
  memory, relaxed SIMD, wide arithmetic, custom page sizes, stack switching, shared-everything threads, GC; threads
  and exceptions are compiled out), when it imports anything outside the list below ("… imports wasi:http/types@0.2.x,
  which drgnx does not provide"), or when it lacks the export its manifest needs.
- **Imports.** `drgnx:agent-tools/{types,host}`, and the WASI 0.2 interfaces Rust's `wasm32-wasip2` std imports,
  each linked by its own generated `add_to_linker` (`brokkr::PROVIDED`): `wasi:cli/{environment, exit, stdin,
  stdout, stderr, terminal-input, terminal-output, terminal-stdin, terminal-stdout, terminal-stderr}`,
  `wasi:io/{error, poll, streams}`, `wasi:clocks/{monotonic-clock, wall-clock}`,
  `wasi:random/{random, insecure, insecure-seed}`, `wasi:filesystem/{types, preopens}`. `wasi:sockets` and
  `wasi:http` are not linked at all. The fixtures that must load confirm the list. The WASI context grants nothing:
  no arguments, an empty environment, stdin closed, stdout and stderr into the log, **no preopened directory** (a
  file open or a directory listing fails), real clocks and random.
- **Calls.** Every call gets a fresh store and instance. The store holds 64 MiB of linear memory (a growth past it
  traps), 10 000 table elements, 32 core instances and 1 000 component handles (`Store::set_max_component_handles`;
  the default is 100 000). Arguments, results, hook inputs and verdicts are JSON of at most 256 KiB each way. An
  ability's deadline is 30 s; a hook's is what the engine hands it. There is no fuel.
- **Where guests run.** `Host::new` starts a runtime of its own, `guest_calls` (4) threads named `brokkr-guest`, and
  an epoch ticker thread (10 ms). A call first takes its plugin's permit (2 per plugin), then a global one (4), each
  by its deadline, else `CallError::Busy`; the plugin's comes first, so one plugin's queued calls never hold global
  permits. The guest then runs on the guest runtime, stopped by an epoch deadline that traps and a timeout around the
  call, and its permits are released when it ends. The caller only awaits the result, up to the deadline plus 50 ms,
  so a guest in a tight loop never holds the hub's workers. A caller's runtime on paused tokio time would see that
  wait end at once: drive the host on real time.
- **HTTP** (`http-get`, `http-post`). `brokkr` checks the URL first: printable ASCII with no backslash, `https://`,
  no credentials, no IP literal, and a `host:port` (port 443 when none) equal to a manifest entry. Headers: at most
  64, names are tokens (sent lowercased), values without CR, LF or NUL, and none of `host`, `connection`, `proxy-*`,
  `upgrade`, `content-length`, `transfer-encoding`, `te`, `trailer`, `expect`, `keep-alive`. Bodies are at most
  1 MiB each way. A `host:port` the manifest does not name is told to `HostIo::denied(plugin, host, why)`, awaited on
  the caller's runtime before the plugin gets its `Err`, so the hub records it. Only then is `HostIo::http(plugin,
  HttpReq {method, url, host, port, headers, body})` called, on the caller's runtime; the hub checks the session's
  network cell and the proxy policy there. A refusal is the import's `Err`.
- **KV.** `HostIo::kv(plugin)`, where `plugin` is the name the host loaded, never one the guest gives. Keys are at
  most 256 bytes; a call makes at most 64 `kv-put` and `kv-delete` calls, then gets the import's `Err`.
- **Log.** `host.log`, stdout and stderr share 64 KiB per call; past it the text is cut and one warning says so.
  stdout and stderr reach `HostIo::log` when the call ends (as `info` and `warn`).
- **Failures.** `CallError::Timeout` (the epoch trap or the timeout), `Trap(message)`, `Refused(why)` (too large,
  not declared, not JSON), `Busy`, and `Plugin(message)` for the plugin's own `Err`. Wasmtime's signal handlers chain
  to the ones installed before them, so a fault outside a guest still reaches the hub's handler.

`brokkr/tests/host.rs` (feature `test-support`) runs these against the fixtures, and against component text parsed
by the `wat` crate (a dev-dependency only) for a disabled proposal and for 1 001 handles.

## Plugins in the hub

`drgnx_ratatoskr::plugins` (`runtime/crates/drgnx-ratatoskr/src/plugins.rs`) is the hub's side: which plugins are
installed, which the user approved and with which files, which run for a project, and the I/O the host's calls get.
It runs nothing; it hands the host the plugins it would run.

- **Install** is the CLI's: `ratatoskr plugins install PATH [--replace]` (`drgnx plugins …`) reads `plugin.json` and
  `plugin.wasm` of PATH through `eitri` (no link followed), parses the manifest, and copies both into
  `<data>/plugins/NAME/` (0700, files 0600) through a staging folder and a rename; an existing name is refused without
  `--replace`, which puts the new files in the folder's place whole. `list` asks the hub; `remove NAME` deletes the
  folder. A running hub is told afterwards (`plugins/list`), so its card appears at once.
- **`Plugins::sync`** runs at hub start and at every `plugins/list`: `brokkr::scan` of the folder, the rows of
  `runtime.db`'s `plugin` table (migration 10: `name`, `hash`, `approved_hash`, `approved_at`, `enabled`,
  `approved_reach`), and the five states: `unapproved` (no `approved_hash`), `changed` (`approved_hash` is not the hash
  on disk), `disabled` (`enabled` is 0), `approved`, and `broken` (the manifest does not read; `problem` says why). The
  hash on disk is stored at each look; a row is dropped, with the plugin's `plugin_kv` rows, when its folder is gone.
  It returns the rows and what changed since the last look; the methods turn changes into `plugin` events and cards.
- **`plugins/approve {name, hash}`** (user class only) reads the folder again and refuses a hash that is not the files'
  now (`invalid-params` at `hash`; a name not installed or broken at `name`). It stores the hash and the manifest's
  whole reach as JSON (`approved_reach`), so that a `changed` plugin's `plugins/list` entry carries
  `approved_reach: {abilities, hosts, hooks: [{point, verdicts, tool_kinds, tools, paths}]}` beside the reach it asks
  for now. `plugins/disable {name}` sets `enabled` to 0. Neither is reachable by an agent connection (the class
  matrix) or by a tool.
- **Cards:** one card of kind `plugin` for each plugin that is `unapproved` or `changed`, with
  `data: {plugin, hash, why: "unapproved" | "changed", choices: ["review"]}`. A card is raised when the state is entered
  and withdrawn when the plugin is approved, disabled or removed, or replaced by a new one when the hash moved on.
- **`Plugins::enabled_for(project)`** gives the approved plugins that run, in the order of `drgnx-agents-plugins`:
  the project's own list when its set (from `config/settings`) has one, else the global list. **`rules_for(project)`**
  gives the global `drgnx-agents-hook-rules` minus the project's `drgnx-agents-hook-rules-off` ids, then the project's
  own rules, a repeat of a global rule counted once (the editor sends the merged list). The three settings are
  `:scope project :workspace never :agents never`; the editor sends a project's values from the user's private
  workspace file only. A rule list is checked by `norn::hooks::parse_rules` when a set is taken (keys may be written
  with `-` or `_`), and a bad rule refuses the whole set at `overrides[N].value[I].KEY`.
- **`plugins::io`** decides what a plugin's imports may do, without the host: `kv_get`, `kv_put` and `kv_delete` on
  `plugin_kv` (the manifest's `kv_bytes` is the quota of keys and values together; a write over it changes nothing),
  and `judge_http`, which turns `host:port` into the addresses to connect to or says why not. A request needs a
  session's or a job's context; the manifest must name the host; except in the `open` network cell the `plugin` tier
  of `drgnx-agents-net-hosts` must list it too; the name goes through the web policy's checks, and only a public
  address passes (a name pinned in `drgnx-sandbox-proxy-pinned-addresses` may also reach a LAN, ULA or CGNAT address;
  loopback, the host's own, link-local and the policy's nevers never).
- **`plugins::hub_io::HubIo`** is `brokkr::HostIo` over those decisions. `plugins::host_io(front, ctx, manifests)`
  makes one per session or job (`IoCtx` and the network cell it launched with; none refuses every request), over the
  manifests of the plugins it runs, and the host gets it as `Arc<dyn HostIo>` at each call.
  - HTTP: `judge_http` on the settings as they are at the request and the host's own addresses (`browser::nevers`),
    the one lookup on a blocking thread after the other checks. The hub connects to a judged address itself (TCP with a
    10 s connect timeout per address, TLS by the platform's verifier for the request's name, HTTP/1.1 with `host` from
    the checked name, no redirect followed, the body read up to 1 MiB); the name is never looked up again.
  - A refusal, the hub's or the host's (`denied`), is the import's `Err`, a log line, and a `status` event
    `{"proxy-denied": true, session | job, host, plugin}` (the session as its agent, or the job), once per host per
    `HubIo`: never a silent drop.
  - KV: `kv_get`/`kv_put`/`kv_delete` with the manifest's `kv_bytes` (default 1 MiB). `brokkr::Kv` is synchronous and
    called on the guest runtime's thread, which waits for the store there (`block_in_place`), never on a hub worker.
  - Logs go to the hub's log with the plugin's name.
  - `plugins/hub_io/tests.rs` runs the `http-ability` fixture through the real host on real time (the host's outer
    timeout runs on the caller's runtime): an undeclared or off-tier or loopback host refused with its event and no
    connection, a declared host fetched over TLS at the judged address from an in-test server, the quota across calls.

## The interface

`runtime/crates/brokkr/wit/agent-tools.wit` is package `drgnx:agent-tools@0.1.0`. World `plugin` exports
`ability.call(tool, args-json) -> result<string, string>` and `hook.run(point, input-json) -> result<verdict,
string>`, and imports `host`: `http-get`, `http-post`, `kv-get`, `kv-put`, `kv-delete` and `log`. A `verdict` is
`allow`, `deny(reason)`, `change(replacement-json)` or `annotate(note)`. A plugin with no abilities or no hooks
exports a stub for the missing interface; the hub calls only what the manifest declares.
