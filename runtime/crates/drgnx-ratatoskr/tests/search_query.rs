//! The query through the real hub: the `search/*` methods, the MCP `search` tool on a session's `search.sock`, and the
//! built-in model answering for real (read-only model volume, `DRGNX_TEST_MODELS`; the test fails when it is unset).
//!
//! test-pattern: pure (D) for the registry; handshake (C) for the rest: the hub answers a ping when it is ready, a
//! session's socket is there when `mcp/session` has answered, and an index's progress is read from `search/status`
//! until the condition holds (`skuld::wait_until`, whose deadline only bounds a failure).

mod support;

use rmcp::model::{
    CallToolRequestParams, ClientCapabilities, ClientConfig, Implementation, ProtocolVersion,
};
use rmcp::{ClientLifecycleMode, ClientServiceExt};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;
use support::{Client, FAILED_AFTER, Hub, Root};

/// The built-in model.
fn model() -> &'static str {
    hrafn_embed::default_model().id
}

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

/// A git repository at DIR holding FILES.
fn repo(dir: &Path, files: &[(&str, &str)]) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q"]);
    for (p, text) in files {
        let f = dir.join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, text).unwrap();
    }
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", "one"]);
}

/// Ten files, one definition each, on ten different subjects.
const TOPICS: &[(&str, &str, &str)] = &[
    (
        "core/timer.el",
        "drgnx-timer-fire",
        "Run the timer when its time has come and it is due.",
    ),
    (
        "core/hub.el",
        "drgnx-hub-call",
        "Send a method and its parameters to the hub and return its answer.",
    ),
    (
        "core/embed.el",
        "drgnx-embed-texts",
        "Make vectors of the texts through the embedding provider.",
    ),
    (
        "core/json.el",
        "drgnx-json-parse",
        "Parse a JSON string into lists and hash tables.",
    ),
    (
        "core/buffer.el",
        "drgnx-buffer-kill",
        "Kill the buffer and ask before throwing away unsaved changes.",
    ),
    (
        "core/window.el",
        "drgnx-window-split",
        "Split the selected window in two halves side by side.",
    ),
    (
        "core/blame.el",
        "drgnx-git-blame",
        "Show which commit and author last changed each line of the file.",
    ),
    (
        "core/sandbox.el",
        "drgnx-sandbox-run",
        "Run a command inside the sandbox with no network and a read-only home.",
    ),
    (
        "core/keys.el",
        "drgnx-keymap-bind",
        "Bind a key sequence to a command in the keymap.",
    ),
    (
        "core/theme.el",
        "drgnx-theme-load",
        "Load the colour theme and apply its faces to every frame.",
    ),
];

fn topic_files() -> Vec<(String, String)> {
    TOPICS
        .iter()
        .map(|(path, name, doc)| {
            (
                path.to_string(),
                format!(
                    ";;; {path} --- {name}\n\n(defun {name} (arg)\n  \"{doc}\"\n  (ignore arg))\n"
                ),
            )
        })
        .collect()
}

/// A project at `<home>/NAME` of the topic files.
fn project(root: &Root, name: &str) -> PathBuf {
    let dir = root.dir.path().join("h").join(name);
    let files = topic_files();
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(p, t)| (p.as_str(), t.as_str()))
        .collect();
    repo(&dir, &refs);
    dir
}

/// The hub's `settings.el`.
fn settings(root: &Root, body: &str) {
    let dir = root.dir.path().join("h/c");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("settings.el"),
        format!("(drgnx-settings\n :version 1\n {body})\n"),
    )
    .unwrap();
}

/// The model volume's model in the hub's cache, where `Ready` is found.
fn install_model(root: &Root) {
    let volume =
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume");
    let models = root.dir.path().join("h/xk/drgnx/models");
    std::fs::create_dir_all(&models).unwrap();
    let spec = hrafn_embed::default_model();
    std::os::unix::fs::symlink(
        Path::new(&volume).join(spec.id),
        hrafn_embed::cache::model_dir(&models, spec),
    )
    .unwrap();
}

fn ready(root: &Root, n: usize) -> (Hub, Client) {
    let mut hub = Hub::start(root, n);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    (hub, c)
}

fn call(c: &mut Client, id: u64, method: &str, params: Value) -> Value {
    c.send(json!({"id": id, "method": method, "params": params}));
    let (a, _) = c.answer(id);
    a
}

fn session(c: &mut Client, id: u64, cwd: &Path) -> (String, PathBuf) {
    let a = call(
        c,
        id,
        "mcp/session",
        json!({"agent": "s-search", "cwd": cwd, "owner": std::process::id()}),
    );
    let sock = PathBuf::from(
        a["result"]["socket"]
            .as_str()
            .unwrap_or_else(|| panic!("{a}")),
    );
    (a["result"]["sid"].as_str().unwrap().to_string(), sock)
}

/// An MCP client on the socket SOCKET.
macro_rules! mcp {
    ($socket:expr) => {{
        let stream = tokio::net::UnixStream::connect($socket).await.unwrap();
        let (r, w) = stream.into_split();
        ClientConfig::new(
            ClientCapabilities::default(),
            Implementation::new("search-test", "0"),
        )
        .with_protocol_version(ProtocolVersion::V_2025_11_25)
        .serve_with_lifecycle((r, w), ClientLifecycleMode::Initialize)
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

/// Pattern D. An agent has no way into `search/*`: every method is the user's, and an agent's only door is the MCP tool.
#[test]
fn agent_class_reaches_no_search_method() {
    use runstav::registry::{Class, find};
    for m in [
        "search/query",
        "search/status",
        "search/index",
        "search/embedders",
        "search/model-download",
        "search/typing",
    ] {
        let method = find(m).unwrap_or_else(|| panic!("{m} is not in the registry"));
        assert_eq!(method.classes, &[Class::User], "{m}");
    }
}

/// Pattern C. The tool answers a name with its definition and ends with the lag line; with no model it says so, and
/// never waits for a download.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_search_answers_with_lag_line() {
    let root = Root::new();
    settings(&root, "(drgnx-agents-mcp (coordination search))");
    let proj = project(&root, "proj");
    let (_hub, mut c) = ready(&root, 1);
    let (_sid, sock) = session(&mut c, 1, &proj);
    let search_sock = sock.with_file_name("search.sock");
    assert!(search_sock.exists(), "{}", search_sock.display());
    let client = mcp!(&search_sock);
    let tools = client.list_all_tools().await.unwrap();
    assert_eq!(
        tools.iter().map(|t| t.name.as_ref()).collect::<Vec<_>>(),
        ["search"]
    );
    let r = client
        .call_tool(
            CallToolRequestParams::new("search")
                .with_arguments(args(json!({"query": "drgnx-hub-call"}))),
        )
        .await
        .unwrap();
    assert_ne!(r.is_error, Some(true), "{}", text_of(&r));
    let text = text_of(&r);
    assert!(text.starts_with("core/hub.el:"), "{text}");
    let last = text.trim_end().lines().last().unwrap();
    assert!(
        last.starts_with("vectors: not used (built-in model not downloaded"),
        "{last}"
    );
    assert!(
        last.contains("keyword and symbol results are current"),
        "{last}"
    );
    client.cancel().await.unwrap();
}

/// Pattern C. The tool is pinned to the session's working folder: a name that only another project has finds nothing, and
/// the tool takes no root of its own.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_search_is_pinned_to_the_jobs_root() {
    let root = Root::new();
    settings(&root, "(drgnx-agents-mcp (coordination search))");
    let mine = project(&root, "mine");
    let other = root.dir.path().join("h/other");
    repo(
        &other,
        &[(
            "core/secret.el",
            ";;; secret.el\n\n(defun other-only-function (x)\n  \"Only the other project has this.\"\n  x)\n",
        )],
    );
    let (_hub, mut c) = ready(&root, 1);
    let (_sid, sock) = session(&mut c, 1, &mine);
    let client = mcp!(&sock.with_file_name("search.sock"));
    let tools = client.list_all_tools().await.unwrap();
    let schema = serde_json::to_value(&tools[0].input_schema).unwrap();
    let keys: Vec<&str> = schema["properties"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(keys.len(), 3, "{schema}");
    assert!(
        !keys.contains(&"root") && !keys.contains(&"path"),
        "{schema}"
    );
    let r = client
        .call_tool(
            CallToolRequestParams::new("search")
                .with_arguments(args(json!({"query": "other-only-function"}))),
        )
        .await
        .unwrap();
    assert!(!text_of(&r).contains("secret.el"), "{}", text_of(&r));
    let mine_hit = client
        .call_tool(
            CallToolRequestParams::new("search")
                .with_arguments(args(json!({"query": "drgnx-timer-fire"}))),
        )
        .await
        .unwrap();
    assert!(
        text_of(&mine_hit).starts_with("core/timer.el:"),
        "{}",
        text_of(&mine_hit)
    );
    // a root argument is refused, with its path
    let refused = client
        .call_tool(
            CallToolRequestParams::new("search")
                .with_arguments(args(json!({"query": "x", "root": other.to_string_lossy()}))),
        )
        .await
        .unwrap();
    assert_eq!(refused.is_error, Some(true));
    assert!(
        text_of(&refused).starts_with("root: "),
        "{}",
        text_of(&refused)
    );
    client.cancel().await.unwrap();
}

/// Pattern C. The session has the search server from `mcp/session` on, and when the hub stops and starts again it is bound
/// again at the same path and answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn session_gets_the_search_server_and_keeps_it_over_a_restart() {
    let root = Root::new();
    settings(&root, "(drgnx-agents-mcp (coordination search))");
    let proj = project(&root, "proj");
    let (mut hub, mut c) = ready(&root, 1);
    let (_sid, sock) = session(&mut c, 1, &proj);
    let search_sock = sock.with_file_name("search.sock");
    assert!(search_sock.exists());
    drop(c);
    hub.term();
    assert!(hub.wait_exit().success());
    assert!(!search_sock.exists(), "a stop unbinds the socket");
    let mut second = Hub::start(&root, 2);
    second.wait_ready(&root.socket());
    skuld::wait_until(
        "the session's search.sock is bound again",
        FAILED_AFTER.as_secs(),
        || search_sock.exists().then_some(()),
    );
    let client = mcp!(&search_sock);
    let r = client
        .call_tool(
            CallToolRequestParams::new("search")
                .with_arguments(args(json!({"query": "drgnx-json-parse"}))),
        )
        .await
        .unwrap();
    assert!(text_of(&r).starts_with("core/json.el:"), "{}", text_of(&r));
    client.cancel().await.unwrap();
}

/// Pattern C. With `search` not in `drgnx-agents-mcp` (the default is the coordination tools alone), the session has no
/// search socket, so the agent's MCP servers do not list one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agents_mcp_without_search_leaves_it_out() {
    let root = Root::new();
    let proj = project(&root, "proj");
    let (_hub, mut c) = ready(&root, 1);
    let (_sid, sock) = session(&mut c, 1, &proj);
    assert!(sock.exists(), "the coordination tools are there");
    assert!(!sock.with_file_name("search.sock").exists());
}

/// Pattern C. The editor's typing signal holds the vectors back between requests: tier 2 (the real built-in model, on
/// the CPU path, with more keys than one request holds) is seen waiting while chunks still lack vectors.
#[test]
fn typing_method_holds_tier2() {
    let root = Root::new();
    install_model(&root);
    let proj = project(&root, "proj");
    let (_hub, mut c) = ready(&root, 1);
    let started = call(&mut c, 1, "search/index", json!({"root": proj}));
    assert_eq!(started["result"]["started"], true, "{started}");
    let mut id = 1;
    let mut status = |c: &mut Client| {
        id += 1;
        call(c, id, "search/status", json!({"root": proj}))["result"].clone()
    };
    // a request is in flight or about to be: the keys are not all done yet
    skuld::wait_until("tier 2 is running", FAILED_AFTER.as_secs() * 6, || {
        let s = status(&mut c);
        (s["tier2"] == "running" && s["lag"]["chunks_behind"].as_u64().unwrap_or(0) > 0)
            .then_some(())
    });
    let typed = call(&mut c, 900, "search/typing", json!({}));
    assert_eq!(typed["result"], json!({}), "{typed}");
    // typing holds the next request: tier 2 reaches `typing` with chunks still lacking vectors (or, if the last
    // request was already in flight, is already idle with none lacking)
    let s = skuld::wait_until(
        "tier 2 holds or is done",
        FAILED_AFTER.as_secs() * 6,
        || {
            let s = status(&mut c);
            (s["tier2"] == "typing" || s["tier2"] == "idle").then_some(s)
        },
    );
    if s["tier2"] == "typing" {
        assert!(s["lag"]["chunks_behind"].as_u64().unwrap() > 0, "{s}");
    }
}

/// Pattern C. With the real built-in model, each of ten questions finds its file in the top five, and the answer says the
/// model took part.
#[test]
fn end_to_end_builtin_top5() {
    let root = Root::new();
    install_model(&root);
    let proj = project(&root, "proj");
    let (_hub, mut c) = ready(&root, 1);
    assert_eq!(
        call(&mut c, 1, "search/index", json!({"root": proj}))["result"]["started"],
        true
    );
    let mut id = 1;
    skuld::wait_until(
        "every chunk has its vector",
        FAILED_AFTER.as_secs() * 10,
        || {
            id += 1;
            let s = call(&mut c, id, "search/status", json!({"root": proj}));
            let lag = &s["result"]["lag"];
            (lag["model"] == model()
                && lag["chunks_behind"] == 0
                && lag["chunks_total"].as_u64() > Some(0))
            .then_some(())
        },
    );
    let questions = [
        ("when does a timer run", "core/timer.el"),
        ("send a request to the hub", "core/hub.el"),
        ("turn texts into vectors", "core/embed.el"),
        ("read a JSON document", "core/json.el"),
        ("close a buffer without losing edits", "core/buffer.el"),
        ("divide the window", "core/window.el"),
        ("who wrote this line", "core/blame.el"),
        ("run a command isolated from the network", "core/sandbox.el"),
        ("assign a shortcut to a command", "core/keys.el"),
        ("change the colours of the editor", "core/theme.el"),
    ];
    for (q, want) in questions {
        id += 1;
        let a = call(
            &mut c,
            id,
            "search/query",
            json!({"root": proj, "text": q, "k": 5}),
        );
        assert_eq!(a["result"]["model"], model(), "{q}: {a}");
        let paths: Vec<&str> = a["result"]["hits"]
            .as_array()
            .unwrap()
            .iter()
            .map(|h| h["path"].as_str().unwrap())
            .collect();
        assert!(paths.contains(&want), "{q}: {want} not in {paths:?}");
    }
}
