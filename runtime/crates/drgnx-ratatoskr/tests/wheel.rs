//! Take the wheel across a hub restart (docs/develop/coordination.md, "Take the wheel"), against the real binary.

mod support;

use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use support::{Client, Hub, Root, mock_binary};

/// The lines on C up to the one DONE matches, that one included.
fn until(c: &mut Client, done: impl Fn(&Value) -> bool) -> Value {
    loop {
        let v = c.line().expect("the connection closed early");
        if done(&v) {
            return v;
        }
    }
}

/// An editor connection: `hello`, then `subscribe`.
fn editor(socket: &std::path::Path) -> Client {
    let mut e = Client::open(socket);
    e.hello(socket);
    e.send(json!({"id": 1, "method": "subscribe"}));
    assert_eq!(e.answer(1).0["result"], json!(true));
    e
}

/// [C] Handshake: a real hub announces the hold (`agent-wheel held`) and parks; it ends (TERM) and a second hub
/// process starts on the same root.  The session comes back still held by the user, paused, with the message queued
/// while held still waiting, and a give then lifts the hold.
#[test]
fn restart_while_held_stays_held() {
    let root = Root::new();
    let socket = root.socket();
    let config = root.dir.path().join("h/c");
    std::fs::create_dir_all(&config).unwrap();
    let settings = config.join("settings.el");
    std::fs::write(
        &settings,
        format!(
            "(drgnx-settings :version 1 (drgnx-agents-profiles ((\"mock\" :command ({:?} \"acp\" \"--as\" \"claude\")))))\n",
            mock_binary().display().to_string()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&settings, std::fs::Permissions::from_mode(0o600)).unwrap();
    let work = root.dir.path().join("h/work");
    std::fs::create_dir_all(&work).unwrap();

    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let mut e = editor(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    c.send(json!({"id": 1, "method": "agents/start",
        "params": {"profile": "mock", "cwd": work, "role": "worker"}}));
    let (started, _) = c.answer(1);
    let sid = started["result"]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{started}: {}", hub.stderr_text()))
        .to_string();
    c.send(json!({"id": 2, "method": "agents/wheel/take", "params": {"id": sid}}));
    let (took, _) = c.answer(2);
    assert_eq!(took["result"], json!(true), "{took}");
    // the handshake: the hold is announced
    until(&mut e, |v| {
        v["event"] == "agent-wheel"
            && v["data"]["id"] == sid.as_str()
            && v["data"]["state"] == "held"
    });
    c.send(
        json!({"id": 3, "method": "agents/send", "params": {"id": sid, "text": "kept while held"}}),
    );
    assert_eq!(c.answer(3).0["result"], json!(true));
    drop((c, e));
    hub.term();
    assert!(hub.wait_exit().success(), "{}", hub.stderr_text());

    let mut hub2 = Hub::start(&root, 2);
    hub2.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    // the session is resumed by the second hub: still held, paused, its queue kept
    let got = skuld::wait_until(
        "the session is resumed",
        support::FAILED_AFTER.as_secs(),
        || {
            c.send(json!({"id": 4, "method": "agents/get", "params": {"id": sid}}));
            let (a, _) = c.answer(4);
            a.get("result").cloned()
        },
    );
    let s = &got["session"];
    assert_eq!(
        (
            s["held_by"].clone(),
            s["paused"].clone(),
            s["queue"].clone()
        ),
        (json!("user"), json!(true), json!(["kept while held"])),
        "{got}: {}",
        hub2.stderr_text()
    );
    // no editor is connected: nothing can be unsaved, so the give goes on without asking
    c.send(json!({"id": 5, "method": "agents/wheel/give", "params": {"id": sid}}));
    assert_eq!(c.answer(5).0["result"], json!(true));
    c.send(json!({"id": 6, "method": "agents/get", "params": {"id": sid}}));
    let (a, _) = c.answer(6);
    assert!(a["result"]["session"].get("held_by").is_none(), "{a}");
}
