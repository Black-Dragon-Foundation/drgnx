//! The structural tools through the real hub: `search/symbols` and `search/outline`, the MCP `symbols` and `outline`
//! tools on a session's `search.sock`, and the same tools from `ratatoskr search mcp` on stdio.
//!
//! test-pattern: pure (D) for the registry; handshake (C) for the rest: the hub answers a ping when it is ready, a
//! session's socket is there when `mcp/session` has answered, and a worktree's view is read until it is seeded
//! (`skuld::wait_until`, whose deadline only bounds a failure).

mod support;

use rmcp::model::{
    CallToolRequestParams, ClientCapabilities, ClientConfig, Implementation, ProtocolVersion,
};
use rmcp::{ClientLifecycleMode, ClientServiceExt};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;
use support::{Client, FAILED_AFTER, Hub, Root};

fn git(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

const FILES: &[(&str, &str)] = &[
    (
        "core/hub.el",
        ";;; hub.el\n\n(defun drgnx-hub-call (method)\n  \"Send METHOD to the hub.\"\n  (ignore method))\n",
    ),
    (
        "src/widget.rs",
        "/// Makes a widget.\npub fn make_widget() -> Widget {\n    Widget\n}\n\npub struct Widget;\n\nimpl Widget {\n    pub fn size(&self) -> u32 {\n        1\n    }\n}\n",
    ),
    (
        "tests/widget_test.rs",
        "fn make_widget_test() {\n    make_widget();\n}\n",
    ),
    ("src/user.rs", "fn use_widget() {\n    make_widget();\n}\n"),
    (
        "src/secret_key.rs",
        "fn hidden_fn() {\n    make_widget();\n}\n",
    ),
];

/// A project at `<home>/NAME` of FILES, and a linked worktree of it, `NAME-wt` on branch `topic`, with a new file.
fn project(root: &Root, name: &str) -> (PathBuf, PathBuf) {
    let dir = root.dir.path().join("h").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q"]);
    for (p, text) in FILES {
        let f = dir.join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, text).unwrap();
    }
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "-q", "-m", "one"]);
    let wt = root.dir.path().join("h").join(format!("{name}-wt"));
    git(
        &dir,
        &["worktree", "add", "-q", "-b", "topic", wt.to_str().unwrap()],
    );
    std::fs::write(
        wt.join("src/branch.rs"),
        "pub fn branch_only() {\n    make_widget();\n}\n",
    )
    .unwrap();
    (dir, wt)
}

fn settings(root: &Root, body: &str) {
    let dir = root.dir.path().join("h/c");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("settings.el"),
        format!("(drgnx-settings\n :version 1\n {body})\n"),
    )
    .unwrap();
}

fn ready(root: &Root) -> (Hub, Client) {
    let mut hub = Hub::start(root, 1);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    (hub, c)
}

fn call(c: &mut Client, id: u64, method: &str, params: Value) -> Value {
    c.send(json!({"id": id, "method": method, "params": params}));
    c.answer(id).0
}

macro_rules! mcp_on {
    ($r:expr, $w:expr) => {{
        ClientConfig::new(
            ClientCapabilities::default(),
            Implementation::new("tools-test", "0"),
        )
        .with_protocol_version(ProtocolVersion::V_2025_11_25)
        .serve_with_lifecycle(($r, $w), ClientLifecycleMode::Initialize)
        .await
        .unwrap()
    }};
}

fn args(v: Value) -> serde_json::Map<String, Value> {
    v.as_object().unwrap().clone()
}

fn text_of(r: &rmcp::model::CallToolResult) -> String {
    r.content
        .first()
        .and_then(|c| c.as_text())
        .map(|t| t.text.clone())
        .unwrap_or_default()
}

/// Pattern D. The new methods are the user's alone: an agent's way in is its MCP tools.
#[test]
fn the_methods_are_the_users() {
    use runstav::registry::{Class, find};
    for m in [
        "search/symbols",
        "search/outline",
        "search/map",
        "search/usages",
    ] {
        let method = find(m).unwrap_or_else(|| panic!("{m} is not in the registry"));
        assert_eq!(method.classes, &[Class::User], "{m}");
        assert!(!method.writes, "{m}");
    }
}

/// Pattern C. Definitions by name and a file's outline, from the index: lines, signature, doc line, nesting; code
/// before tests; a secret-looking file is never there; the freshness of the answer comes with it.
#[test]
fn symbols_and_outline_answer_from_the_index() {
    let root = Root::new();
    let (proj, _wt) = project(&root, "proj");
    let (_hub, mut c) = ready(&root);
    let a = call(
        &mut c,
        1,
        "search/symbols",
        json!({"root": proj, "name": "drgnx-hub-call"}),
    );
    let r = &a["result"];
    assert_eq!(r["matched"], "exact", "{a}");
    let s = &r["symbols"][0];
    assert_eq!(s["path"], "core/hub.el", "{a}");
    assert_eq!(
        (s["line_start"].clone(), s["line_end"].clone()),
        (json!(3), json!(5))
    );
    assert_eq!(s["sig"], "(defun drgnx-hub-call (method)");
    assert_eq!(s["doc1"], "Send METHOD to the hub.");
    assert_eq!(r["fresh"]["files_pending"], 0, "{a}");
    assert_eq!(r["fresh"]["view"]["state"], "base", "{a}");

    let a = call(
        &mut c,
        2,
        "search/symbols",
        json!({"root": proj, "name": "make_wid"}),
    );
    let paths: Vec<&str> = a["result"]["symbols"]
        .as_array()
        .unwrap_or_else(|| panic!("{a}"))
        .iter()
        .map(|s| s["path"].as_str().unwrap())
        .collect();
    assert_eq!(paths, ["src/widget.rs", "tests/widget_test.rs"], "{a}");
    assert_eq!(a["result"]["matched"], "prefix");

    let a = call(
        &mut c,
        3,
        "search/symbols",
        json!({"root": proj, "name": "hidden_fn"}),
    );
    assert_eq!(a["result"]["symbols"], json!([]), "{a}");

    let a = call(
        &mut c,
        4,
        "search/outline",
        json!({"root": proj, "path": "src/widget.rs"}),
    );
    let names: Vec<(String, u64)> = a["result"]["entries"]
        .as_array()
        .unwrap_or_else(|| panic!("{a}"))
        .iter()
        .map(|e| {
            (
                e["name"].as_str().unwrap().to_string(),
                e["depth"].as_u64().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        names,
        [
            ("make_widget".to_string(), 0),
            ("Widget".to_string(), 0),
            ("Widget".to_string(), 0),
            ("size".to_string(), 1)
        ]
    );
    assert_eq!(a["result"]["lang"], "rust");
}

/// Pattern C. The map ranks the used definition first and keeps to its budget; the usages of a name come under the
/// definition that uses them, code before tests, never from a secret-looking file.
#[test]
fn map_and_usages_answer_from_the_index() {
    let root = Root::new();
    let (proj, _wt) = project(&root, "proj");
    let (_hub, mut c) = ready(&root);
    let a = call(
        &mut c,
        1,
        "search/map",
        json!({"root": proj, "budget": 512}),
    );
    let r = &a["result"];
    assert_eq!(r["files"][0]["path"], "src/widget.rs", "{a}");
    assert_eq!(r["files"][0]["defs"][0]["name"], "make_widget", "{a}");
    assert!(r["tokens"].as_u64().unwrap() <= 512, "{a}");
    assert_eq!(
        r["files_total"], 3,
        "the code files (the secret-looking one is never indexed): {a}"
    );
    let text = r["text"].as_str().unwrap();
    assert!(
        text.starts_with("src/widget.rs:\n   2│ pub fn make_widget() -> Widget\n"),
        "{text}"
    );
    assert!(text.ends_with(", budget 512"), "{text}");
    assert_eq!(r["fresh"]["view"]["state"], "base", "{a}");

    let a = call(
        &mut c,
        2,
        "search/usages",
        json!({"root": proj, "name": "make_widget"}),
    );
    let r = &a["result"];
    assert_eq!(r["defined"][0]["path"], "src/widget.rs", "{a}");
    let got: Vec<(String, u64, String)> = r["usages"]
        .as_array()
        .unwrap_or_else(|| panic!("{a}"))
        .iter()
        .map(|u| {
            (
                u["path"].as_str().unwrap().to_string(),
                u["line"].as_u64().unwrap(),
                u["enclosing"].as_str().unwrap_or("").to_string(),
            )
        })
        .collect();
    assert_eq!(
        got,
        [
            ("src/user.rs".to_string(), 2, "use_widget".to_string()),
            (
                "tests/widget_test.rs".to_string(),
                2,
                "make_widget_test".to_string()
            ),
        ],
        "{a}"
    );
}

/// Pattern D on the hub's checks. Arguments outside the root or the limits are refused with the field they name.
#[test]
fn bad_arguments_are_refused() {
    let root = Root::new();
    let (proj, _wt) = project(&root, "proj");
    let (_hub, mut c) = ready(&root);
    for (id, method, params, field) in [
        (
            1,
            "search/outline",
            json!({"root": proj, "path": "../x.rs"}),
            "path",
        ),
        (
            2,
            "search/outline",
            json!({"root": proj, "path": "/etc/passwd"}),
            "path",
        ),
        (
            3,
            "search/outline",
            json!({"root": proj, "path": "src/none.rs"}),
            "path",
        ),
        (
            4,
            "search/outline",
            json!({"root": proj, "path": "src/secret_key.rs"}),
            "path",
        ),
        (
            5,
            "search/symbols",
            json!({"root": proj, "name": ""}),
            "name",
        ),
        (
            6,
            "search/symbols",
            json!({"root": proj, "name": "(", "match": "regex"}),
            "name",
        ),
        (
            7,
            "search/symbols",
            json!({"root": proj, "name": "x", "k": 0}),
            "k",
        ),
        (
            8,
            "search/symbols",
            json!({"root": proj, "name": "x", "path": "../*"}),
            "path",
        ),
        (
            9,
            "search/map",
            json!({"root": proj, "budget": 255}),
            "budget",
        ),
        (
            10,
            "search/map",
            json!({"root": proj, "budget": 32001}),
            "budget",
        ),
        (
            11,
            "search/map",
            json!({"root": proj, "focus": ["../x.rs"]}),
            "focus",
        ),
        (
            12,
            "search/map",
            json!({"root": proj, "focus": ["/etc/passwd"]}),
            "focus",
        ),
        (
            13,
            "search/map",
            json!({"root": proj, "focus": vec!["src/user.rs"; 51]}),
            "focus",
        ),
        (
            14,
            "search/map",
            json!({"root": proj, "names": vec!["x"; 51]}),
            "names",
        ),
        (
            15,
            "search/usages",
            json!({"root": proj, "name": ""}),
            "name",
        ),
        (
            16,
            "search/usages",
            json!({"root": proj, "name": "x", "k": 101}),
            "k",
        ),
    ] {
        let a = call(&mut c, id, method, params);
        assert_eq!(a["error"]["path"], field, "{id}: {a}");
    }
}

/// Pattern C. From a linked worktree the tools answer from its view; `base: true` from the base.
#[test]
fn a_worktree_root_answers_from_its_view() {
    let root = Root::new();
    let (_proj, wt) = project(&root, "proj");
    let (_hub, mut c) = ready(&root);
    let mut id = 10;
    let a = skuld::wait_until(
        "the worktree's view is seeded",
        FAILED_AFTER.as_secs(),
        || {
            id += 1;
            let a = call(
                &mut c,
                id,
                "search/symbols",
                json!({"root": wt, "name": "branch_only"}),
            );
            let state = a["result"]["fresh"]["view"]["state"].clone();
            (state == "live" || state == "unwatched").then_some(a)
        },
    );
    assert_eq!(a["result"]["symbols"][0]["path"], "src/branch.rs", "{a}");
    assert!(a["result"]["fresh"]["view"]["worktree"].is_string(), "{a}");
    let b = call(
        &mut c,
        2,
        "search/symbols",
        json!({"root": wt, "name": "branch_only", "base": true}),
    );
    assert_eq!(b["result"]["symbols"], json!([]), "{b}");
    let o = call(
        &mut c,
        3,
        "search/outline",
        json!({"root": wt, "path": "src/branch.rs"}),
    );
    assert_eq!(o["result"]["entries"][0]["name"], "branch_only", "{o}");
    // the worktree's new file uses make_widget; the base does not see it
    let usages = |a: &Value| -> Vec<String> {
        a["result"]["usages"]
            .as_array()
            .unwrap_or_else(|| panic!("{a}"))
            .iter()
            .map(|u| u["path"].as_str().unwrap().to_string())
            .collect()
    };
    let u = call(
        &mut c,
        4,
        "search/usages",
        json!({"root": wt, "name": "make_widget"}),
    );
    assert!(usages(&u).contains(&"src/branch.rs".to_string()), "{u}");
    let u = call(
        &mut c,
        5,
        "search/usages",
        json!({"root": wt, "name": "make_widget", "base": true}),
    );
    assert!(!usages(&u).contains(&"src/branch.rs".to_string()), "{u}");
    let m = call(&mut c, 6, "search/map", json!({"root": wt}));
    assert!(m["result"]["fresh"]["view"]["worktree"].is_string(), "{m}");
}

/// The tools a search socket lists, by name.
/// A session's search tools; `search_results` answers only the session a Search view hand-off went to.
const TOOLS: [&str; 6] = [
    "find_usages",
    "outline",
    "repo_map",
    "search",
    "search_results",
    "symbols",
];

/// Pattern C. A session's search socket serves the three tools; their text answers; refusals are tool errors.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_session_socket_serves_symbols_and_outline() {
    let root = Root::new();
    settings(&root, "(drgnx-agents-mcp (coordination search))");
    let (proj, _wt) = project(&root, "proj");
    let (_hub, mut c) = ready(&root);
    let a = call(
        &mut c,
        1,
        "mcp/session",
        json!({"agent": "s-tools", "cwd": proj, "owner": std::process::id()}),
    );
    let sock = PathBuf::from(
        a["result"]["socket"]
            .as_str()
            .unwrap_or_else(|| panic!("{a}")),
    );
    let stream = tokio::net::UnixStream::connect(sock.with_file_name("search.sock"))
        .await
        .unwrap();
    let (r, w) = stream.into_split();
    let client = mcp_on!(r, w);
    let tools = client.list_all_tools().await.unwrap();
    assert_eq!(
        tools.iter().map(|t| t.name.as_ref()).collect::<Vec<_>>(),
        TOOLS
    );
    let r = client
        .call_tool(
            CallToolRequestParams::new("symbols")
                .with_arguments(args(json!({"name": "make_widget"}))),
        )
        .await
        .unwrap();
    let text = text_of(&r);
    assert!(
        text.starts_with("src/widget.rs:2-4  function  make_widget  — Makes a widget.\n    pub fn make_widget() -> Widget\n"),
        "{text}"
    );
    assert!(text.trim_end().ends_with("index: current"), "{text}");
    let r = client
        .call_tool(
            CallToolRequestParams::new("outline")
                .with_arguments(args(json!({"path": "src/widget.rs", "docs": false}))),
        )
        .await
        .unwrap();
    let text = text_of(&r);
    assert!(
        text.starts_with("src/widget.rs (rust)\n2-4  function  pub fn make_widget() -> Widget\n"),
        "{text}"
    );
    assert!(
        text.contains("\n  9-11  method  pub fn size(&self) -> u32\n"),
        "{text}"
    );
    let r = client
        .call_tool(
            CallToolRequestParams::new("repo_map").with_arguments(args(json!({"budget": 512}))),
        )
        .await
        .unwrap();
    let text = text_of(&r);
    assert!(
        text.starts_with("src/widget.rs:\n   2│ pub fn make_widget() -> Widget\n"),
        "{text}"
    );
    assert!(text.contains("\nmap: "), "{text}");
    let r = client
        .call_tool(
            CallToolRequestParams::new("find_usages")
                .with_arguments(args(json!({"name": "make_widget"}))),
        )
        .await
        .unwrap();
    let text = text_of(&r);
    assert!(
        text.starts_with("make_widget: defined at src/widget.rs:2-4; usages by name only\n"),
        "{text}"
    );
    assert!(
        text.contains("\nsrc/user.rs:2  in use_widget  ×1  [lines 2]\n"),
        "{text}"
    );
    assert!(!text.contains("secret_key"), "{text}");
    for (tool, bad) in [
        ("outline", json!({"path": "/etc/passwd"})),
        ("outline", json!({"path": "src/secret_key.rs"})),
        ("outline", json!({"path": "x", "extra": 1})),
        ("repo_map", json!({"focus": ["/etc/passwd"]})),
        ("repo_map", json!({"budget": 10})),
        ("find_usages", json!({"name": ""})),
    ] {
        let r = client
            .call_tool(CallToolRequestParams::new(tool).with_arguments(args(bad.clone())))
            .await;
        let refused = match r {
            Ok(r) => r.is_error == Some(true),
            Err(_) => true,
        };
        assert!(refused, "{tool} {bad}");
    }
    client.cancel().await.unwrap();
}

/// Pattern C. `ratatoskr search mcp ROOT` on stdio serves the same tools and answers as the socket does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_serves_the_same_tools() {
    let root = Root::new();
    let (proj, _wt) = project(&root, "proj");
    let (_hub, _c) = ready(&root);
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_ratatoskr"))
        .args(["search", "mcp"])
        .arg(&proj)
        .envs(root.vars())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let (out, inp) = (child.stdout.take().unwrap(), child.stdin.take().unwrap());
    let client = mcp_on!(out, inp);
    let tools = client.list_all_tools().await.unwrap();
    assert_eq!(
        tools.iter().map(|t| t.name.as_ref()).collect::<Vec<_>>(),
        TOOLS
    );
    let r = client
        .call_tool(
            CallToolRequestParams::new("symbols")
                .with_arguments(args(json!({"name": "drgnx-hub", "match": "prefix"}))),
        )
        .await
        .unwrap();
    let text = text_of(&r);
    assert!(
        text.starts_with("matched: prefix\ncore/hub.el:3-5  function  drgnx-hub-call"),
        "{text}"
    );
    client.cancel().await.unwrap();
}
