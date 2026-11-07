//! The abilities' rows against a real hub front, the real plugin host and the fixture plugins (built at test time):
//! what a session is offered, what a call may do, the card an Ask makes, and the sockets sessions get. Pattern C
//! (handshake) where a call waits: the wait registry's own counters are what a test waits on, never a sleep.

use super::*;
use crate::dispatch::Caller;
use crate::settings::overrides::Override;
use brokkr::test_support::fixture;
use norn::matrix::Role;
use runstav::proof::Cap;
use serde_json::json;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Rig {
    dir: tempfile::TempDir,
    _store: urdr::Store,
    f: Arc<Front>,
    overrides: std::sync::Mutex<std::collections::BTreeMap<String, serde_json::Value>>,
}

/// A hub front with the fixtures NAMES installed, approved and enabled for every project, and its sessions' store.
async fn rig(names: &[&str]) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("hub-x.sock");
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let f = Arc::new(Front::new(
        Cap::generate().unwrap(),
        socket.clone(),
        crate::store::WorkDb::spawn(dir.path().join("work.db")).unwrap(),
        norn::store::CoordDb::spawn(dir.path().join("work.db")),
    ));
    f.settings.open(dir.path().to_path_buf(), db.clone());
    f.settings.refresh().await;
    let root = dir.path().join("plugins");
    f.core
        .plugins
        .open(root.clone(), db.clone(), f.settings.clone());
    let env = runstav::paths::Env::new(
        &[("TMPDIR", dir.path().to_str().unwrap())],
        rustix::process::geteuid().as_raw(),
    );
    f.mcp.open_store(env, socket, db);
    f.mcp.bind_search(&f);
    let r = Rig {
        dir,
        _store: store,
        f,
        overrides: Default::default(),
    };
    for n in names {
        install(&root, n);
    }
    let rows = r.f.core.plugins.sync().await.unwrap().rows;
    for n in names {
        let hash = rows
            .iter()
            .find(|p| p.name == *n)
            .and_then(|p| p.hash.as_ref())
            .unwrap()
            .as_str()
            .to_owned();
        r.f.core.plugins.approve(n, &hash).await.unwrap();
    }
    r.set("drgnx-agents-plugins", json!(names)).await;
    r
}

/// The fixture NAME copied into ROOT, where the hub reads its plugins.
fn install(root: &Path, name: &str) {
    let from = fixture(name);
    let to = root.join(name);
    std::fs::create_dir_all(&to).unwrap();
    for file in ["plugin.json", "plugin.wasm"] {
        std::fs::copy(from.join(file), to.join(file)).unwrap();
    }
}

impl Rig {
    /// Setting NAME to VALUE, the others set so far kept (`set_overrides` takes the whole set at once).
    async fn set(&self, name: &str, value: serde_json::Value) {
        let all: Vec<Override> = {
            let mut kept = self.overrides.lock().unwrap();
            kept.insert(name.to_owned(), value);
            kept.iter()
                .map(|(name, value)| Override {
                    name: name.clone(),
                    value: value.clone(),
                    source: "test".into(),
                })
                .collect()
        };
        self.f.settings.set_overrides(None, all).await.unwrap();
    }

    /// The `plugin.abilities` cell of the worker column, and the preset it sits on.
    async fn cell(&self, verdict: &str) {
        self.set(
            "drgnx-agents-matrix",
            json!({"preset": "balanced", "cells": [
                {"action": "plugin.abilities", "column": {"role": "worker"}, "verdict": verdict}]}),
        )
        .await;
    }

    fn ctx(&self, sid: &str, who: &Who) -> AbilityCtx {
        AbilityCtx::new(&self.f, sid, who.clone())
    }

    /// The matrix cards of the ability row: (id, state, title).
    async fn cards(&self) -> Vec<(i64, String, String)> {
        self.f
            .writer
            .db
            .read(|c| {
                let mut st = c.prepare(
                    "select id, state, title from card where kind = 'matrix' \
                     and json_extract(data, '$.action') = 'plugin.abilities' order by id",
                )?;
                let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
                Ok(rows.collect::<Result<Vec<_>, _>>()?)
            })
            .await
            .unwrap()
    }

    /// The user answers CARD yes, through `cards/settle`, and the hub tells the waiting calls.
    async fn allow(&self, card: i64) {
        let user = Caller {
            class: runstav::registry::Class::User,
            sid: None,
            job: None,
            conn_id: 1,
        };
        self.f
            .writer
            .write(&user, "cards/settle", move |tx| {
                assert!(norn::write::cards::card_settle(
                    tx,
                    card,
                    "allow",
                    crate::clock::wall_secs()
                )?);
                Ok(())
            })
            .await
            .unwrap();
        self.f.core.plugins.card_settled(card);
    }

    async fn open(&self, sid: &str, who: &Who) -> runstav::methods::mcp::SessionAnswer {
        self.f.mcp.note_who(sid, who.clone());
        let p = json!({"agent": sid, "sid": sid, "cwd": "/w", "owner": std::process::id()});
        self.f
            .mcp
            .open(runstav::decode::typed(&p).unwrap().0)
            .await
            .unwrap()
    }
}

/// Until one call waits on a card; a call that ends first (it panicked, say) fails the test instead of hanging it.
async fn until_waiting<T: std::fmt::Debug>(
    waiting: &mut tokio::sync::watch::Receiver<usize>,
    call: &mut tokio::task::JoinHandle<T>,
) {
    tokio::select! {
        w = waiting.wait_for(|n| *n == 1) => { w.unwrap(); }
        ended = call => panic!("the call ended before it waited: {ended:?}"),
    }
}

fn worker(agent: &str, provider: Option<&str>) -> Who {
    Who {
        role: Some(Role::Worker),
        agent: Some(agent.into()),
        provider: provider.map(Into::into),
    }
}

/// A Claude-like and an OpenRouter-like profile: the abilities do not depend on which.
fn profiles() -> [Who; 2] {
    [worker("claude", None), worker("or", Some("openrouter"))]
}

fn names(list: &[Box<dyn Tool<AbilityCtx>>]) -> Vec<String> {
    list.iter().map(|t| t.name().to_owned()).collect()
}

async fn run(
    list: &[Box<dyn Tool<AbilityCtx>>],
    ctx: &AbilityCtx,
    args: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let t = &list[0];
    t.check(&args).map_err(|e| e.to_string())?;
    match t.call(ctx, args).await {
        ToolResult::Ok { structured, text } => Ok(structured.unwrap_or(json!(text))),
        ToolResult::Err(e) => Err(e),
        ToolResult::Rich { .. } => panic!("an ability answers plain text"),
    }
}

/// What a client of the socket PATH is offered: the tool names `tools/list` gives.
async fn served(path: &Path) -> Vec<String> {
    let mut s = tokio::net::UnixStream::connect(path).await.unwrap();
    let lines = [
        json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "t", "version": "0"}}}),
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}),
    ];
    for l in lines {
        s.write_all(format!("{l}\n").as_bytes()).await.unwrap();
    }
    s.shutdown().await.unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).await.unwrap();
    let answer: serde_json::Value = serde_json::from_str(out.lines().nth(1).unwrap()).unwrap();
    answer["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

// [D] pure: abilities/listed-for-every-profile
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn listed_for_every_profile() {
    let r = rig(&["echo-ability"]).await;
    for who in profiles() {
        let list = offered(&r.f, "s1", &who).await;
        assert_eq!(names(&list), ["echo-ability_echo"]);
        assert_eq!(list[0].description(), "Returns its arguments.");
        assert_eq!(list[0].input_schema(), json!({"type": "object"}));
    }
}

// [C] handshake: abilities/call-round-trips
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn call_round_trips() {
    let r = rig(&["echo-ability"]).await;
    for who in profiles() {
        let list = offered(&r.f, "s1", &who).await;
        let got = run(&list, &r.ctx("s1", &who), json!({"a": [1, "b"]})).await;
        assert_eq!(got, Ok(json!({"a": [1, "b"]})));
    }
}

// [D] pure: abilities/never-cell-hides-it, and a call outside the grants is refused
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn never_cell_hides_it_and_refuses_a_call() {
    let r = rig(&["echo-ability"]).await;
    let who = worker("claude", None);
    // offered while the cell lets it, then the user's matrix says never
    let list = offered(&r.f, "s1", &who).await;
    assert_eq!(names(&list), ["echo-ability_echo"]);
    r.cell("never").await;
    assert!(offered(&r.f, "s1", &who).await.is_empty());
    // a client that listed before can still name it: the call is refused, and nothing ran
    let got = run(&list, &r.ctx("s1", &who), json!({"a": 1})).await;
    let why = got.unwrap_err();
    assert!(why.contains("plugin.abilities is never allowed"), "{why}");
    // another column is unaffected
    let chat = Who {
        role: Some(Role::Chat),
        ..who.clone()
    };
    assert_eq!(
        names(&offered(&r.f, "s2", &chat).await),
        ["echo-ability_echo"]
    );
}

// [D] pure: a plugin that is not enabled is not offered, and a call after it was switched off is refused
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plugin_that_is_not_enabled_is_not_offered_or_run() {
    let r = rig(&["echo-ability", "http-ability"]).await;
    let who = worker("claude", None);
    r.set("drgnx-agents-plugins", json!(["echo-ability"])).await;
    let list = offered(&r.f, "s1", &who).await;
    assert_eq!(
        names(&list),
        ["echo-ability_echo"],
        "http-ability is approved but not enabled"
    );
    r.set("drgnx-agents-plugins", json!([])).await;
    assert!(offered(&r.f, "s1", &who).await.is_empty());
    let why = run(&list, &r.ctx("s1", &who), json!({})).await.unwrap_err();
    assert!(why.contains("not enabled"), "{why}");
}

// [D] pure: arguments outside the manifest's schema never reach the plugin
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn arguments_are_checked_against_the_schema() {
    let r = rig(&["http-ability"]).await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let fetch = list
        .iter()
        .find(|t| t.name() == "http-ability_fetch")
        .unwrap();
    let e = fetch.check(&json!({"url": 3})).unwrap_err();
    assert_eq!(e.path, "url");
    let e = fetch.check(&json!({})).unwrap_err();
    assert_eq!(
        (e.path.as_str(), e.message.as_str()),
        ("url", "required, missing")
    );
    assert!(
        fetch
            .check(&json!({"url": "https://api.example.com/"}))
            .is_ok()
    );
}

// [C] handshake: abilities/http-to-an-undeclared-host-fails
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_to_an_undeclared_host_fails() {
    let r = rig(&["http-ability"]).await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let t = list
        .iter()
        .find(|t| t.name() == "http-ability_fetch")
        .unwrap();
    let args = json!({"url": "https://other.example.com/x"});
    match t.call(&r.ctx("s1", &who), args).await {
        ToolResult::Err(e) => assert!(e.contains("not a host this plugin declared"), "{e}"),
        _ => panic!("a host the manifest does not name was reached"),
    }
}

// [C] handshake: abilities/ask-cell-makes-a-card
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ask_cell_makes_a_card_and_waits_for_the_answer() {
    let r = rig(&["echo-ability"]).await;
    r.cell("ask").await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    assert_eq!(names(&list), ["echo-ability_echo"], "an Ask is offered");
    let mut waiting = r.f.core.plugins.waiting();
    let ctx = r.ctx("s1", &who);
    let mut call = tokio::spawn(async move { run(&list, &ctx, json!({"x": 1})).await });
    until_waiting(&mut waiting, &mut call).await;
    let cards = r.cards().await;
    assert_eq!(cards.len(), 1, "{cards:?}");
    let (id, state, title) = &cards[0];
    assert_eq!(state, "open");
    assert!(
        title.contains("echo-ability_echo") && title.contains(r#"{"x":1}"#),
        "the card names the tool and shows the arguments: {title}"
    );
    assert!(!call.is_finished(), "the call waits for the user");
    r.allow(*id).await;
    let got = call.await.unwrap();
    assert_eq!(got, Ok(json!({"x": 1})));
}

// [C] handshake: abilities/an-ask-waits-past-30-s (the 30 s deadline is the WASM call's only)
#[tokio::test(flavor = "current_thread")]
async fn an_ask_waits_past_30_s() {
    let r = rig(&["echo-ability"]).await;
    r.cell("ask").await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let mut waiting = r.f.core.plugins.waiting();
    let ctx = r.ctx("s1", &who);
    let mut call = tokio::spawn(async move { run(&list, &ctx, json!({})).await });
    until_waiting(&mut waiting, &mut call).await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(95)).await;
    assert!(
        !call.is_finished(),
        "a minute and a half later it still waits"
    );
    tokio::time::resume();
    let id = r.cards().await[0].0;
    r.allow(id).await;
    assert_eq!(call.await.unwrap(), Ok(json!({})));
}

// [C] handshake: abilities/ask-card-is-withdrawn-when-the-call-ends
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_ask_card_is_withdrawn_when_the_call_ends() {
    let r = rig(&["echo-ability"]).await;
    r.cell("ask").await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let mut waiting = r.f.core.plugins.waiting();
    let mut withdrawn = r.f.core.plugins.withdrawn();
    let ctx = r.ctx("s1", &who);
    let mut call = tokio::spawn(async move { run(&list, &ctx, json!({})).await });
    until_waiting(&mut waiting, &mut call).await;
    // the client cancels the MCP call: the server drops the call's future
    call.abort();
    let _ = call.await;
    waiting.wait_for(|n| *n == 0).await.unwrap();
    withdrawn.wait_for(|n| *n == 1).await.unwrap();
    let cards = r.cards().await;
    assert_eq!(cards.len(), 1);
    assert_eq!(cards[0].1, "withdrawn", "{cards:?}");
}

// [D] pure: abilities/first-ability-needs-a-restart
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn first_ability_needs_a_restart() {
    let r = rig(&[]).await;
    let who = worker("claude", None);
    r.open("s1", &who).await;
    assert!(
        r.f.mcp.plugins_socket_of("s1").is_none(),
        "no ability when it started"
    );
    assert!(!r.f.mcp.plugins_changed("s1"));
    // a plugin is installed, approved and enabled afterwards
    install(&r.dir.path().join("plugins"), "echo-ability");
    let rows = r.f.core.plugins.sync().await.unwrap().rows;
    let hash = rows[0].hash.as_ref().unwrap().as_str().to_owned();
    r.f.core
        .plugins
        .approve("echo-ability", &hash)
        .await
        .unwrap();
    r.set("drgnx-agents-plugins", json!(["echo-ability"])).await;
    r.f.mcp.plugins_refresh();
    assert!(
        r.f.mcp.plugins_socket_of("s1").is_none(),
        "mcpServers are fixed at session/new"
    );
    assert!(
        r.f.mcp.plugins_changed("s1"),
        "the snapshot says the set moved"
    );
    // a session started now has the server
    r.open("s2", &who).await;
    assert!(r.f.mcp.plugins_socket_of("s2").is_some());
    assert!(!r.f.mcp.plugins_changed("s2"));
}

// [D] pure: abilities/list-changed-on-enable (a client of a running session sees the new set at its next list)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_running_sessions_list_follows_the_enabled_set() {
    let r = rig(&["echo-ability", "http-ability"]).await;
    r.set("drgnx-agents-plugins", json!(["echo-ability"])).await;
    let who = worker("claude", None);
    r.open("s1", &who).await;
    let sock = r.f.mcp.plugins_socket_of("s1").expect("a plugins.sock");
    assert_eq!(
        sock.file_name().unwrap(),
        runstav::paths::SESSION_PLUGINS_SOCKET
    );
    assert_eq!(served(&sock).await, ["echo-ability_echo"]);
    r.set(
        "drgnx-agents-plugins",
        json!(["echo-ability", "http-ability"]),
    )
    .await;
    r.f.mcp.plugins_refresh();
    let now = served(&sock).await;
    assert_eq!(now.len(), 4, "{now:?}");
    assert!(r.f.mcp.plugins_changed("s1"));
    // the cell of the session's column hides what it may not run
    r.cell("never").await;
    assert!(served(&sock).await.is_empty());
}

// [D] pure: abilities::tests::annotation_keywords_are_accepted
#[test]
fn annotation_keywords_are_accepted() {
    let manifest = |schema: serde_json::Value| {
        serde_json::to_vec(&json!({"name": "p", "version": "1", "abilities": [
            {"name": "a", "description": "d", "input_schema": schema}]}))
        .unwrap()
    };
    let ok = json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "title": "t",
        "$comment": "c", "description": "d", "default": {}, "examples": [{}], "deprecated": false,
        "readOnly": false, "writeOnly": false, "type": "object",
        "properties": {"x": {"type": "string", "description": "x"}}});
    assert!(brokkr::parse(&manifest(ok)).is_ok());
    let e = brokkr::parse(&manifest(json!({"type": "object", "minProperties": 1}))).unwrap_err();
    assert!(e.message.contains("minProperties"), "{e}");
}

/// The hub's own hook rows (`hub:hooks` writer), oldest first.
async fn hook_rows(r: &Rig) -> Vec<serde_json::Value> {
    let rows =
        r.f.writer
            .db
            .read(|c| {
                let mut st = c.prepare(
                    "select e.data from event e join tx t on t.id = e.tx \
                 where t.actor = 'hub:hooks' order by e.id",
                )?;
                let rows = st.query_map([], |r| r.get::<_, String>(0))?;
                Ok(rows.collect::<Result<Vec<_>, _>>()?)
            })
            .await
            .unwrap();
    rows.iter()
        .map(|t| serde_json::from_str(t).unwrap())
        .collect()
}

/// A rule that notes every hub tool call (kind `drgnx`).
fn note_rule() -> serde_json::Value {
    json!([{"id": "seen", "point": "before-tool", "tool-kinds": ["drgnx"],
            "verdict": "annotate", "reason": "seen"}])
}

// [D] pure: hooks/an-ability-call-is-hooked-once. The seam and the panel's adapter site both skip
// `mcp__drgnx-plugins__*`, so the ability server's own `before_tool` is the only place the call is hooked: one row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ability_call_is_hooked_once() {
    let r = rig(&["echo-ability"]).await;
    r.set("drgnx-agents-hook-rules", note_rule()).await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let got = run(&list, &r.ctx("s1", &who), json!({"x": 1})).await;
    assert_eq!(got, Ok(json!({"x": 1})));
    let rows = hook_rows(&r).await;
    assert_eq!(rows.len(), 1, "one row for one call: {rows:?}");
    assert_eq!(rows[0]["at"], "hub-server");
    assert_eq!(rows[0]["tool"], "mcp__drgnx-plugins__echo-ability_echo");
    assert_eq!(rows[0]["records"][0]["source"], "rule:seen");
}

// [D] pure: hooks/change-rewrites-an-ability-argument. A plugin's `change` at before-tool, named for this ability,
// is what the ability runs with (the schema is checked again on the changed arguments).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn change_rewrites_an_ability_argument() {
    let r = rig(&["echo-ability", "change-tool-arg"]).await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let got = run(&list, &r.ctx("s1", &who), json!({"a": 1})).await;
    assert_eq!(
        got,
        Ok(json!({"changed": true})),
        "the ability ran with the hook's arguments"
    );
    let rows = hook_rows(&r).await;
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0]["outcome"], "change");
    assert_eq!(rows[0]["records"][0]["verdict"], "change");
}

// [C] handshake: hooks/change-before-an-ability-is-shown-on-its-card. The matrix's Ask comes after the hooks, so the
// card shows the arguments that will run, never the ones the agent sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn change_before_an_ability_is_shown_on_its_card() {
    let r = rig(&["echo-ability", "change-tool-arg"]).await;
    r.cell("ask").await;
    let who = worker("claude", None);
    let list = offered(&r.f, "s1", &who).await;
    let mut waiting = r.f.core.plugins.waiting();
    let ctx = r.ctx("s1", &who);
    let mut call = tokio::spawn(async move { run(&list, &ctx, json!({"a": 1})).await });
    until_waiting(&mut waiting, &mut call).await;
    let cards = r.cards().await;
    assert_eq!(cards.len(), 1, "{cards:?}");
    let (id, _, title) = &cards[0];
    assert!(
        title.contains(r#"{"changed":true}"#) && !title.contains(r#"{"a":1}"#),
        "the card shows what will run: {title}"
    );
    r.allow(*id).await;
    assert_eq!(call.await.unwrap(), Ok(json!({"changed": true})));
}
