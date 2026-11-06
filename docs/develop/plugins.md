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

## The interface

`runtime/crates/brokkr/wit/agent-tools.wit` is package `drgnx:agent-tools@0.1.0`. World `plugin` exports
`ability.call(tool, args-json) -> result<string, string>` and `hook.run(point, input-json) -> result<verdict,
string>`, and imports `host`: `http-get`, `http-post`, `kv-get`, `kv-put`, `kv-delete` and `log`. A `verdict` is
`allow`, `deny(reason)`, `change(replacement-json)` or `annotate(note)`. A plugin with no abilities or no hooks
exports a stub for the missing interface; the hub calls only what the manifest declares.
