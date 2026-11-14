//! The Search view's index modes through the real hub: a Symbol search's first patch is one reset holding its first
//! file's rows, after the index has answered. The view draws it at once (`drgnx-view-patch-hurry`): a reset alone would be
//! drawn empty, and rows apart from it would wait for the view's throttle (`drgnx-view-delay`).
//!
//! test-pattern: handshake (C): the hub answers a ping when it is ready, and an index's progress is read from
//! `search/status` until it holds the files (`skuld::wait_until`, whose deadline only bounds a failure).

mod support;

use serde_json::{Value, json};
use std::path::Path;
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

fn call(c: &mut Client, id: u64, method: &str, params: Value) -> Value {
    c.send(json!({"id": id, "method": method, "params": params}));
    c.answer(id).0
}

/// Pattern C.
#[test]
fn a_symbol_search_s_first_patch_is_a_reset_with_its_first_rows() {
    let root = Root::new();
    let proj = root.dir.path().join("h/proj");
    std::fs::create_dir_all(&proj).unwrap();
    git(&proj, &["init", "-q"]);
    std::fs::write(proj.join("a.rs"), "fn needle() -> u32 {\n    1\n}\n").unwrap();
    std::fs::write(
        proj.join("b.rs"),
        "fn other() -> u32 {\n    needle() + 1\n}\n",
    )
    .unwrap();
    git(&proj, &["add", "-A"]);
    git(&proj, &["commit", "-q", "-m", "one"]);
    let mut hub = Hub::start(&root, 1);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    assert_eq!(call(&mut c, 1, "subscribe", json!({}))["result"], true);
    let env = json!({"view": "s", "class": "gui-1", "display": "gui", "scale": 1,
                     "fonts": [["ui", null, 0, 13, 12, 3, 7, 4]], "cell": [8, 17], "width_px": 400,
                     "palette": [], "epoch": 1});
    assert_eq!(call(&mut c, 2, "view/env", env)["result"], true);
    let started = call(
        &mut c,
        3,
        "search/index",
        json!({"root": proj, "now": true}),
    );
    assert!(started.get("error").is_none(), "{started}");
    let mut id = 3;
    skuld::wait_until(
        "the index holds both files",
        FAILED_AFTER.as_secs() * 6,
        || {
            id += 1;
            let s = call(&mut c, id, "search/status", json!({"root": proj}));
            (s["result"]["chunks"].as_u64().unwrap_or(0) >= 2).then_some(())
        },
    );
    let run = id + 1;
    c.send(json!({"id": run, "method": "search/run", "params": {
        "view": "s", "root": proj, "search": {"query": {"mode": "symbol", "name": "needle"}}}}));
    // every line up to the run's end, in the order the hub wrote them
    let mut lines = Vec::new();
    loop {
        let v = c
            .line()
            .expect("the connection closed before the search ended");
        let done = v["event"] == "search-run-done" && v["data"]["view"] == "s";
        lines.push(v);
        if done {
            break;
        }
    }
    let at = |p: &dyn Fn(&Value) -> bool| lines.iter().position(p);
    let s_patch = |v: &Value| v["event"] == "view-patch" && v["data"]["view"] == "s";
    let answer = at(&|v| v["id"] == json!(run)).expect("the run's answer");
    let first = at(&s_patch).expect("the first patch");
    assert!(
        answer < first,
        "the first patch came before the index answered: {lines:#?}"
    );
    // one reset holding the first file's rows (a header and a match), never a reset alone
    let ops = lines[first]["data"]["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 1, "{lines:#?}");
    let reset = ops[0]["reset"].as_array().expect("a reset");
    assert!(reset.len() >= 2, "{lines:#?}");
}
