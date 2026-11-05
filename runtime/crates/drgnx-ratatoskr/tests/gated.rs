//! The hub's test hooks against the real binary (docs/develop/hub.md, "Test hooks"): under `serve --test-sequencer`
//! requests are served in the order of the client's `__seq`, and `__test_barrier` marks every connection.  Without
//! `test-hooks` the hooks are not there.

mod support;

use serde_json::json;
use support::{Client, Hub, Root};
#[cfg(feature = "test-hooks")]
use {
    serde_json::Value,
    std::sync::{Arc, atomic::AtomicU64},
};
#[cfg(not(feature = "test-hooks"))]
use {std::process::Command, support::BIN};

/// The lines on C up to the one DONE matches, that one included.
#[cfg(feature = "test-hooks")]
fn until(c: &mut Client, done: impl Fn(&Value) -> bool) -> Vec<Value> {
    let mut seen = vec![];
    loop {
        let v = c.line().expect("the connection closed early");
        let last = done(&v);
        seen.push(v);
        if last {
            return seen;
        }
    }
}

/// A line by what it is: `answer ID`, or the event's name.
#[cfg(feature = "test-hooks")]
fn kind(v: &Value) -> String {
    match v.get("id") {
        Some(id) => format!("answer {id}"),
        None => v["event"].as_str().unwrap_or("?").to_string(),
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn barrier_marks_every_connection_after_what_was_sent() {
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start_with(&root, 1, &["--test-sequencer"]);
    hub.wait_ready(&socket);
    let seq = Arc::new(AtomicU64::new(0));
    let (mut a, mut b) = (Client::gated(&socket, &seq), Client::gated(&socket, &seq));
    for c in [&mut a, &mut b] {
        assert_eq!(c.line().unwrap()["event"], "challenge");
    }
    a.send(json!({"id": 1, "method": "ping"}));
    b.send(json!({"id": 1, "method": "ping"}));
    a.send(json!({"id": 2, "method": "ping"}));
    b.send(json!({"id": 2, "method": "ping"}));
    a.send(json!({"id": 9, "method": "__test_barrier"}));
    let on_a = until(&mut a, |v| v["id"] == 9);
    let kinds: Vec<String> = on_a.iter().map(kind).collect();
    assert_eq!(
        kinds,
        ["answer 1", "answer 2", "__test_marker", "answer 9"],
        "{on_a:?}"
    );
    // the first barrier of this hub: marker 1, on both connections, after what each sent
    assert_eq!(on_a[2]["data"], json!({"marker": 1}));
    assert_eq!(
        on_a[3]["result"],
        json!({"marker": 1, "unnamed": 0, "busy": [], "waiting": []})
    );
    let on_b = until(&mut b, |v| v["event"] == "__test_marker");
    let kinds: Vec<String> = on_b.iter().map(kind).collect();
    assert_eq!(kinds, ["answer 1", "answer 2", "__test_marker"], "{on_b:?}");
    assert_eq!(on_b[2]["data"], json!({"marker": 1}));
}

#[cfg(feature = "test-hooks")]
#[test]
fn subscribe_and_keys_answers_come_in_seq_order() {
    // A subscribes, B hands the hub a key, A asks which keys are held, B hands another, A asks for a barrier: served
    // in that order whatever order the hub's tasks read them in, so A hears both changes and its question sees the
    // first key, every run.  Each run names its own providers (the held set only grows).
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start_with(&root, 1, &["--test-sequencer"]);
    hub.wait_ready(&socket);
    let seq = Arc::new(AtomicU64::new(0));
    for run in 0..100 {
        let (mine, theirs) = (format!("q{run}z"), format!("w{run}z"));
        let keys = |id: &str| {
            let mut k = serde_json::Map::new();
            k.insert(id.to_string(), json!("k"));
            json!({"keys": k})
        };
        let mut a = Client::gated(&socket, &seq);
        a.hello(&socket);
        let mut b = Client::gated(&socket, &seq);
        b.hello(&socket);
        a.send(json!({"id": 1, "method": "subscribe"}));
        b.send(json!({"id": 1, "method": "gateway/keys", "params": keys(&mine)}));
        a.send(json!({"id": 2, "method": "gateway/keys-held"}));
        b.send(json!({"id": 2, "method": "gateway/keys", "params": keys(&theirs)}));
        a.send(json!({"id": 9, "method": "__test_barrier"}));
        let on_a = until(&mut a, |v| v["id"] == 9);
        let on_b = until(&mut b, |v| v["event"] == "__test_marker");
        // what each line is and whether it names this run's providers; events other than these two left out
        let shape = |v: &Value| {
            let text = v.to_string();
            format!(
                "{} {} {}",
                kind(v),
                text.contains(&mine),
                text.contains(&theirs)
            )
        };
        let kept = |v: &&Value| {
            v.get("id").is_some()
                || ["gateway/keys-changed", "__test_marker"]
                    .contains(&v["event"].as_str().unwrap_or(""))
        };
        let a_seen: Vec<String> = on_a.iter().filter(kept).map(shape).collect();
        let b_seen: Vec<String> = on_b.iter().filter(kept).map(shape).collect();
        assert_eq!(
            a_seen,
            [
                "answer 1 false false",
                "gateway/keys-changed true false",
                "answer 2 true false",
                "gateway/keys-changed true true",
                "__test_marker false false",
                "answer 9 false false",
            ],
            "run {run}: {on_a:?}"
        );
        assert_eq!(
            b_seen,
            [
                "answer 1 false false",
                "answer 2 false false",
                "__test_marker false false"
            ],
            "run {run}: {on_b:?}"
        );
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn a_bare_hub_parks_every_timer_it_wakes() {
    // Pattern B, on the hub's virtual clock: a hub with no clients' work moves through seconds of its own timers (the
    // tick loops, the sweeps) and every task they woke waits on the clock again, so an advance names nothing busy (a
    // busy task holds the advance for 5 s of real time).
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start_with(&root, 1, &["--test-clock"]);
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    let mut now = 0;
    for (id, ms) in [(1, 4000), (2, 6000), (3, 30_000)] {
        now += ms;
        c.send(json!({"id": id, "method": "__test_advance", "params": {"ms": ms}}));
        let a = c.answer(id).0["result"].clone();
        assert_eq!(
            (a["now_ms"].clone(), a["busy"].clone()),
            (json!(now), json!([])),
            "{a}"
        );
    }
}

#[cfg(not(feature = "test-hooks"))]
#[test]
fn release_has_no_test_hooks() {
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    assert_eq!(c.line().unwrap()["event"], "challenge");
    for (id, method) in [(1, "__test_advance"), (2, "__test_barrier")] {
        c.send(json!({"id": id, "method": method, "params": {"ms": 1}}));
        let (a, _) = c.answer(id);
        assert_eq!(a["error"]["code"], "no-method", "{a}");
    }
    // a stamp is a field this hub does not know: dropped, and said so
    c.send(json!({"id": 3, "method": "ping", "__seq": 1}));
    let (a, _) = c.answer(3);
    assert!(a["result"]["pid"].is_number(), "{a}");
    assert_eq!(a["ignored"], json!(["__seq"]), "{a}");
    for flag in ["--test-clock", "--test-sequencer"] {
        let out = Command::new(BIN)
            .args(["serve", "--foreground", flag])
            .env_clear()
            .envs(root.vars())
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(2), "{flag}: {out:?}");
    }
}
