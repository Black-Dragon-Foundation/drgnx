# Plugins: the plugin host (`brokkr`)

`runtime/crates/brokkr` is drgnx's plugin host. A plugin is a WebAssembly component that gives agents
tools (abilities) and shapes what they do (hooks). This page grows with the host; today it covers the part that
runs nothing: the manifest, the approval hash and the install scan. Nothing in `brokkr` runs a plugin yet.

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
  point derived them from the original (required, so a point cannot forget it); and `now()`. The plugin host implements it with the call's I/O; `HookPlugin` (a manifest and
  its approved hash) is implemented for `brokkr::Installed`.
- `combine(cell, accepts_change, records) -> Outcome {decision, decided_by, annotations, provenance}`. A `Never`
  cell stays `Deny`; `Ask` stays `Ask` and `Allow` (or `None`: a hub tool whose matrix checks are in its body)
  stays `Proceed`, unless a record denies. The first deny decides (`decided_by` is its index); a failure is a deny,
  or a note when advisory; a change where `accepts_change` is false is the failure "change is not accepted here";
  the last accepted change rides on `Proceed` or `Ask`. Notes are capped at 8 of 2 KiB, then "+N more".
- Sources print as `rule:ID` (else `rule:N`) and `plugin:NAME@VERSION#` with the hash's first 4 bytes in hex.

`hooks::tests::allow_never_widens` checks every cell, both contexts and every list of up to three records of every
kind (3 200 cases).

## Plugins in the hub

`drgnx_ratatoskr::plugins` (`runtime/crates/drgnx-ratatoskr/src/plugins.rs`) is the hub's side: which plugins are
installed, which the user approved and with which files, and which run for a project. It runs nothing; it hands the
host the plugins it would run.

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

## The interface

`runtime/crates/brokkr/wit/agent-tools.wit` is package `drgnx:agent-tools@0.1.0`. World `plugin` exports
`ability.call(tool, args-json) -> result<string, string>` and `hook.run(point, input-json) -> result<verdict,
string>`, and imports `host`: `http-get`, `http-post`, `kv-get`, `kv-put`, `kv-delete` and `log`. A `verdict` is
`allow`, `deny(reason)`, `change(replacement-json)` or `annotate(note)`. A plugin with no abilities or no hooks
exports a stub for the missing interface; the hub calls only what the manifest declares.
