//! Pattern D (pure): every test parses bytes or reads a temporary folder; no clock, no thread, no network.

use std::fs;
use std::os::unix::fs::symlink;

use serde_json::{Value, json};

use super::*;
use crate::store::scan;

fn base() -> Value {
    json!({
        "name": "deny-rm",
        "version": "0.1.0",
        "abilities": [{
            "name": "check_path",
            "description": "Says whether a path is inside the worktree.",
            "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}}
        }],
        "hooks": [{
            "point": "before-tool",
            "verdicts": ["deny", "annotate"],
            "filter": {"tool_kinds": ["execute"]},
            "deadline_ms": 500
        }],
        "hosts": ["api.example.com", "internal.example.com:8443"],
        "kv_bytes": 65536
    })
}

fn bytes(v: &Value) -> Vec<u8> {
    serde_json::to_vec(v).unwrap()
}

fn parse_v(v: &Value) -> Result<Manifest, ManifestError> {
    parse(&bytes(v))
}

fn refused(v: &Value) -> ManifestError {
    parse_v(v).expect_err("the manifest should have been refused")
}

fn hook(point: &str, verdicts: Value, filter: Value) -> Value {
    let mut m = base();
    m["hooks"] = json!([{"point": point, "verdicts": verdicts, "filter": filter}]);
    m
}

#[test]
fn the_base_manifest_parses() {
    let m = parse_v(&base()).unwrap();
    assert_eq!(m.name.as_str(), "deny-rm");
    assert_eq!(m.abilities[0].name.as_str(), "check_path");
    assert_eq!(m.hooks[0].point, Point::BeforeTool);
    assert_eq!(m.hooks[0].deadline_ms, Some(500));
    assert!(!m.hooks[0].advisory);
    assert_eq!(m.hosts[0].host(), "api.example.com");
    assert_eq!(m.hosts[0].port(), 443);
    assert_eq!(m.hosts[1].port(), 8443);
    assert_eq!(m.kv_bytes, Some(65536));
}

#[test]
fn parse_refuses_unknown_keys() {
    let mut m = base();
    m["bogus"] = json!(1);
    let e = refused(&m);
    assert!(e.message.contains("bogus"), "{e}");

    let mut m = base();
    m["hooks"][0]["extra"] = json!(true);
    let e = refused(&m);
    assert!(e.path.starts_with("hooks[0]"), "{e}");
    assert!(e.message.contains("extra"), "{e}");

    let mut m = base();
    m["abilities"][0]["filter"] = json!({});
    assert!(refused(&m).path.starts_with("abilities[0]"));

    // the error carries the path of a wrong value too
    let mut m = base();
    m["hooks"][0]["verdicts"] = json!(["allow", "explode"]);
    assert_eq!(refused(&m).path, "hooks[0].verdicts[1]");
}

#[test]
fn change_before_tool_only_for_own_tools() {
    let own = json!({"tool_kinds": ["drgnx"], "tools": ["mcp__drgnx__merge"]});
    parse_v(&hook("before-tool", json!(["change"]), own)).unwrap();
    for filter in [
        json!({"tool_kinds": ["execute"]}),
        json!({"tool_kinds": ["execute"], "tools": ["mcp__drgnx__merge"]}),
        json!({}),
        json!({"paths": ["src/**"]}),
    ] {
        let e = refused(&hook("before-tool", json!(["change"]), filter.clone()));
        assert!(e.path.starts_with("hooks[0]"), "{filter}: {e}");
    }
    // no filter at all
    let mut m = base();
    m["hooks"] = json!([{"point": "before-tool", "verdicts": ["change"]}]);
    refused(&m);
    // after-edit, commit and review take a change without naming tools
    for point in ["after-edit", "before-commit", "at-review"] {
        parse_v(&hook(point, json!(["change"]), json!({}))).unwrap();
    }
}

#[test]
fn change_needs_named_tools() {
    for tools in [
        json!([]),
        json!(["Bash"]),
        json!(["mcp__drgnx"]),
        json!(["mcp__other__merge"]),
        json!(["mcp__drgnx__merge", "Bash"]),
    ] {
        let f = json!({"tool_kinds": ["drgnx"], "tools": tools});
        refused(&hook("before-tool", json!(["change"]), f));
    }
    // "drgnx" alone is refused for change and fine for a hook that only denies or annotates
    refused(&hook(
        "before-tool",
        json!(["change"]),
        json!({"tool_kinds": ["drgnx"]}),
    ));
    parse_v(&hook(
        "before-tool",
        json!(["deny", "annotate"]),
        json!({"tool_kinds": ["drgnx"]}),
    ))
    .unwrap();
    // both servers' names are accepted
    let f = json!({"tool_kinds": ["drgnx"], "tools": ["mcp__drgnx__merge", "mcp__drgnx-plugins__deny-rm_check_path"]});
    parse_v(&hook("before-tool", json!(["change"]), f)).unwrap();
    // the kind must be drgnx and only drgnx
    let f = json!({"tool_kinds": ["drgnx", "execute"], "tools": ["mcp__drgnx__merge"]});
    refused(&hook("before-tool", json!(["change"]), f));
}

#[test]
fn deadline_above_point_limit_refused() {
    for (point, limit) in [
        ("before-tool", 2000),
        ("after-edit", 5000),
        ("before-commit", 10_000),
        ("at-review", 30_000),
    ] {
        let mut m = hook(point, json!(["deny"]), json!({}));
        m["hooks"][0]["deadline_ms"] = json!(limit);
        parse_v(&m).unwrap();
        m["hooks"][0]["deadline_ms"] = json!(limit + 1);
        assert_eq!(refused(&m).path, "hooks[0].deadline_ms", "{point}");
        m["hooks"][0]["deadline_ms"] = json!(0);
        refused(&m);
    }
}

#[test]
fn annotate_only_is_advisory() {
    let m = parse_v(&hook("after-edit", json!(["annotate"]), json!({}))).unwrap();
    assert!(m.hooks[0].advisory, "annotate-only is forced advisory");
    let mut v = hook("after-edit", json!(["annotate"]), json!({}));
    v["hooks"][0]["advisory"] = json!(false);
    assert!(parse_v(&v).unwrap().hooks[0].advisory);
    // a hook that can deny keeps what the manifest says
    let m = parse_v(&hook("after-edit", json!(["annotate", "deny"]), json!({}))).unwrap();
    assert!(!m.hooks[0].advisory);
    let mut v = hook("after-edit", json!(["annotate", "deny"]), json!({}));
    v["hooks"][0]["advisory"] = json!(true);
    assert!(parse_v(&v).unwrap().hooks[0].advisory);
}

#[test]
fn host_wildcard_refused() {
    for h in [
        "*.example.com",
        "*",
        "api.*.com",
        "127.0.0.1",
        "8.8.8.8:443",
        "[::1]",
        "[2001:db8::1]:443",
        "2130706433",
        "Example.com",
        "exa mple.com",
        "example.com:0",
        "example.com:70000",
        "example.com:",
        "example.com:80:80",
        "-a.example.com",
        "a-.example.com",
        "a..example.com",
        "example.com.",
        "münchen.example",
        "",
    ] {
        let mut m = base();
        m["hosts"] = json!([h]);
        let e = refused(&m);
        assert_eq!(e.path, "hosts[0]", "{h:?}: {e}");
    }
    // 16 are fine, 17 are not
    let many = |n: usize| {
        json!(
            (0..n)
                .map(|i| format!("h{i}.example.com"))
                .collect::<Vec<_>>()
        )
    };
    let mut m = base();
    m["hosts"] = many(16);
    parse_v(&m).unwrap();
    m["hosts"] = many(17);
    refused(&m);
    // A-labels are accepted, and a name twice is one too many
    let mut m = base();
    m["hosts"] = json!(["xn--mnchen-3ya.example"]);
    parse_v(&m).unwrap();
    m["hosts"] = json!(["a.example.com", "a.example.com"]);
    refused(&m);
}

#[test]
fn local_and_internal_hosts_refused() {
    for h in [
        "localhost",
        "localhost:9222",
        "a.localhost",
        "deep.a.localhost:8080",
        "host.drgnx.internal",
        "x.internal",
        "metadata.google.internal",
        "metadata.azure.com",
        "sub.metadata.azure.com",
        "intranet",
        "intranet:8443",
    ] {
        let mut m = base();
        m["hosts"] = json!([h]);
        let e = refused(&m);
        assert_eq!(e.path, "hosts[0]", "{h}: {e}");
    }
    // control: a name that only looks like one
    let mut m = base();
    m["hosts"] = json!([
        "notlocalhost.example.com",
        "internal.example.com",
        "azure.com"
    ]);
    parse_v(&m).unwrap();
}

#[test]
fn names_and_sizes_are_checked() {
    for name in ["", "Deny", "1a", "a_b", "a.b", "-a", &"a".repeat(33)] {
        let mut m = base();
        m["name"] = json!(name);
        assert_eq!(refused(&m).path, "name", "{name:?}");
    }
    let mut m = base();
    m["name"] = json!("a".repeat(32));
    m["abilities"] = json!([]);
    parse_v(&m).unwrap();

    for ab in ["", "Check", "1a", "a-b", "a.b", &"a".repeat(49)] {
        let mut m = base();
        m["abilities"][0]["name"] = json!(ab);
        assert_eq!(refused(&m).path, "abilities[0].name", "{ab:?}");
    }
    // len(name) + 1 + len(ability) <= 44
    let mut m = base();
    m["name"] = json!("p".repeat(10));
    m["abilities"][0]["name"] = json!("a".repeat(33));
    parse_v(&m).unwrap();
    m["abilities"][0]["name"] = json!("a".repeat(34));
    assert_eq!(refused(&m).path, "abilities[0].name");

    let mut m = base();
    m["abilities"][0]["description"] = json!("d".repeat(1025));
    assert_eq!(refused(&m).path, "abilities[0].description");
    m["abilities"][0]["description"] = json!("d".repeat(1024));
    parse_v(&m).unwrap();

    for schema in [json!({"type": "string"}), json!([]), json!({}), json!(3)] {
        let mut m = base();
        m["abilities"][0]["input_schema"] = schema;
        assert_eq!(refused(&m).path, "abilities[0].input_schema");
    }

    // a keyword the call's checker does not check is refused at load, where it is; annotations pass
    let mut m = base();
    m["abilities"][0]["input_schema"]["properties"]["path"]["pattern"] = json!("^/");
    let e = refused(&m);
    assert_eq!(e.path, "abilities[0].input_schema.properties.path");
    assert!(e.message.contains("pattern"), "{e}");
    let mut m = base();
    m["abilities"][0]["input_schema"]["properties"]["path"]["description"] = json!("a path");
    parse_v(&m).unwrap();

    let mut m = base();
    m["abilities"] = json!([
        base()["abilities"][0].clone(),
        base()["abilities"][0].clone()
    ]);
    refused(&m);

    let mut m = base();
    m["kv_bytes"] = json!(1_048_577);
    assert_eq!(refused(&m).path, "kv_bytes");
    m["kv_bytes"] = json!(1_048_576);
    parse_v(&m).unwrap();
    m["kv_bytes"] = json!(-1);
    refused(&m);

    for v in ["", "1 0", "v/1", &"1".repeat(65)] {
        let mut m = base();
        m["version"] = json!(v);
        assert_eq!(refused(&m).path, "version", "{v:?}");
    }

    // required keys, and bytes that are not JSON
    let mut m = base();
    m.as_object_mut().unwrap().remove("name");
    refused(&m);
    assert!(parse(b"{").is_err());
    assert!(parse(b"[]").is_err());
}

#[test]
fn one_hook_per_point_and_valid_filters() {
    let mut m = base();
    m["hooks"] = json!([
        {"point": "after-edit", "verdicts": ["deny"]},
        {"point": "after-edit", "verdicts": ["annotate"]}
    ]);
    assert_eq!(refused(&m).path, "hooks[1].point");

    let mut m = base();
    m["hooks"] = json!([]);
    parse_v(&m).unwrap();

    let mut m = base();
    m["hooks"][0]["verdicts"] = json!([]);
    assert_eq!(refused(&m).path, "hooks[0].verdicts");

    let mut m = base();
    m["hooks"][0]["filter"] = json!({"tool_kinds": ["shell"]});
    assert_eq!(refused(&m).path, "hooks[0].filter.tool_kinds[0]");

    let mut m = base();
    m["hooks"][0]["filter"] =
        json!({"paths": ["src/**", "*.lock", "/abs/**", "a?c"], "tools": ["Bash"]});
    let m = parse_v(&m).unwrap();
    let f = m.hooks[0].filter.as_ref().unwrap();
    assert_eq!(f.paths.len(), 4);
    assert_eq!(f.tools, ["Bash"]);

    let mut m = base();
    m["hooks"][0]["filter"] = json!({"paths": [""]});
    assert_eq!(refused(&m).path, "hooks[0].filter.paths[0]");
    m["hooks"][0]["filter"] = json!({"tools": ["has space"]});
    assert_eq!(refused(&m).path, "hooks[0].filter.tools[0]");
}

#[test]
fn hash_changes_with_either_file() {
    let h = plugin_hash(b"manifest", b"wasm");
    assert_eq!(h, plugin_hash(b"manifest", b"wasm"));
    assert_ne!(h, plugin_hash(b"manifesT", b"wasm"));
    assert_ne!(h, plugin_hash(b"manifest", b"wasM"));
    // the pair is length-prefixed: moving the boundary changes the hash
    assert_ne!(plugin_hash(b"ab", b"c"), plugin_hash(b"a", b"bc"));
    assert_ne!(plugin_hash(b"", b"x"), plugin_hash(b"x", b""));
}

fn install(root: &std::path::Path, dir: &str, manifest: &Value, wasm: &[u8]) {
    let d = root.join(dir);
    fs::create_dir_all(&d).unwrap();
    fs::write(d.join("plugin.json"), bytes(manifest)).unwrap();
    fs::write(d.join("plugin.wasm"), wasm).unwrap();
}

#[test]
fn scan_skips_a_link_out_of_root() {
    let outside = tempfile::tempdir().unwrap();
    install(outside.path(), "evil", &base(), b"\0asm");
    let data = tempfile::tempdir().unwrap();
    let root = data.path().join("plugins");
    install(&root, "deny-rm", &base(), b"\0asm");
    symlink(outside.path().join("evil"), root.join("evil")).unwrap();
    symlink(outside.path().join("evil/plugin.wasm"), root.join("stray")).unwrap();
    fs::write(root.join("a-file"), b"x").unwrap();

    let found = scan(&root);
    assert_eq!(found.len(), 1, "{found:?}");
    let ok = found[0].as_ref().unwrap();
    assert_eq!(ok.manifest.name.as_str(), "deny-rm");
    assert_eq!(ok.dir, root.canonicalize().unwrap().join("deny-rm"));
    let raw = bytes(&base());
    assert_eq!(ok.hash, plugin_hash(&raw, b"\0asm"));
}

#[test]
fn scan_reports_a_bad_manifest_by_name() {
    let data = tempfile::tempdir().unwrap();
    let root = data.path();
    install(root, "deny-rm", &base(), b"\0asm");
    let mut bad = base();
    bad["hosts"] = json!(["*.example.com"]);
    install(root, "bad", &bad, b"\0asm");
    // a folder whose manifest names another plugin
    install(root, "other", &base(), b"\0asm");
    // no wasm, no manifest, a linked file inside the folder
    fs::create_dir(root.join("empty")).unwrap();
    let mut b = base();
    b["name"] = json!("linked");
    install(root, "linked", &b, b"\0asm");
    fs::remove_file(root.join("linked/plugin.wasm")).unwrap();
    symlink("/etc/hostname", root.join("linked/plugin.wasm")).unwrap();

    let found = scan(root);
    let mut names: Vec<(String, bool)> = found
        .iter()
        .map(|r| match r {
            Ok(i) => (i.manifest.name.as_str().to_string(), true),
            Err((n, _)) => (n.clone(), false),
        })
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            ("bad".to_string(), false),
            ("deny-rm".to_string(), true),
            ("empty".to_string(), false),
            ("linked".to_string(), false),
            ("other".to_string(), false),
        ]
    );
    let e = found
        .iter()
        .find_map(|r| match r {
            Err((n, e)) if n == "bad" => Some(e),
            _ => None,
        })
        .unwrap();
    assert_eq!(e.path, "hosts[0]");
}

#[test]
fn scan_of_a_missing_root_is_empty() {
    let data = tempfile::tempdir().unwrap();
    assert!(scan(&data.path().join("nope")).is_empty());
}
