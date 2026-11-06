# Plugins: the plugin host (`brokkr`)

`runtime/crates/brokkr` is drgnx's plugin host. A plugin is a WebAssembly component that gives agents
tools (abilities) and shapes what they do (hooks). This page covers the manifest, the approval hash, the install
scan, the hook engine and the WASM host that runs plugins ("What a plugin can reach"). The hub does not call the
host yet.

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
`manifests/NAME.json`: `echo-ability`, `deny-rm-hook`, `rewrite-commit-msg`, `annotate-edit`, `slow-hook` (spins),
`trap-hook` (traps), `big-alloc` (allocates `mib` MiB), `fs-importer` (std file access, so it imports
`wasi:filesystem`), `http-ability` (the host's HTTP, key-value store and log), and the three that must fail to load,
`http-importer` (`wasi:http`) and `socket-importer` (`std::net`, so `wasi:sockets`). The guests use `wit-bindgen`
0.63.0 and plain `cargo build --target wasm32-wasip2 --release`; no binary is ever committed.

`brokkr::test_support::fixture(name)` (feature `test-support`, or `cfg(test)` inside `brokkr`) builds all of them with
one cargo run under a lock file, so parallel tests and test binaries build once, and returns an install folder
(`plugin.json` and `plugin.wasm`) that `scan` reads. It needs the `wasm32-wasip2` target of the toolchain that runs
the tests. `test_support::template()` builds the template the same way.

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
  `other`, and an `other` named `NotebookEdit` is `edit`. It never returns `drgnx`; only the hub's servers set it.
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
  1 MiB each way. Only then is `HostIo::http(plugin, HttpReq {method, url, host, port, headers, body})` called, on
  the caller's runtime; the hub checks the session's network cell and the proxy policy there. A refusal is the
  import's `Err`.
- **KV.** `HostIo::kv(plugin)`, where `plugin` is the name the host loaded, never one the guest gives. Keys are at
  most 256 bytes; a call makes at most 64 `kv-put` and `kv-delete` calls, then gets the import's `Err`.
- **Log.** `host.log`, stdout and stderr share 64 KiB per call; past it the text is cut and one warning says so.
  stdout and stderr reach `HostIo::log` when the call ends (as `info` and `warn`).
- **Failures.** `CallError::Timeout` (the epoch trap or the timeout), `Trap(message)`, `Refused(why)` (too large,
  not declared, not JSON), `Busy`, and `Plugin(message)` for the plugin's own `Err`. Wasmtime's signal handlers chain
  to the ones installed before them, so a fault outside a guest still reaches the hub's handler.

`brokkr/tests/host.rs` (feature `test-support`) runs these against the fixtures, and against component text parsed
by the `wat` crate (a dev-dependency only) for a disabled proposal and for 1 001 handles.

## The interface

`runtime/crates/brokkr/wit/agent-tools.wit` is package `drgnx:agent-tools@0.1.0`. World `plugin` exports
`ability.call(tool, args-json) -> result<string, string>` and `hook.run(point, input-json) -> result<verdict,
string>`, and imports `host`: `http-get`, `http-post`, `kv-get`, `kv-put`, `kv-delete` and `log`. A `verdict` is
`allow`, `deny(reason)`, `change(replacement-json)` or `annotate(note)`. A plugin with no abilities or no hooks
exports a stub for the missing interface; the hub calls only what the manifest declares.
