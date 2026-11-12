//! The Search view's index modes through the real hub: a Symbol search's reset goes with its first rows, after the
//! index has answered, never ahead of them. Sent at once, the reset was drawn alone one frame on, and rows that came
//! after the index's answer waited for the view's throttle (`drgnx-view-delay`) instead of sharing that frame.
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
fn a_symbol_search_resets_its_rows_with_the_first_of_them() {
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
    let reset =
        at(&|v| s_patch(v) && v["data"]["ops"][0].get("reset").is_some()).expect("the reset");
    let rows =
        at(&|v| s_patch(v) && v["data"]["ops"][0].get("reset").is_none()).expect("the first rows");
    assert!(
        answer < reset,
        "the reset came before the index answered: {lines:#?}"
    );
    assert!(reset < rows, "{lines:#?}");
    // nothing but the run's model between its reset and its first rows: they are one burst
    assert!(
        lines[reset + 1..rows]
            .iter()
            .all(|v| v["event"] == "view-model"),
        "{lines:#?}"
    );
}
