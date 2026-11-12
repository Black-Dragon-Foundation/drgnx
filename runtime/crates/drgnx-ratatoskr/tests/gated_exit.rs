//! A gated hub that ends writes what its sequencer still held first (docs/develop/hub.md, "The sequencer and the
//! barrier").  The hub runs from a copy of the binary made here, through `drgnx_exe` so that no other thread's fork
//! holds it open for writing (its exec would fail as busy, ETXTBSY).

#![cfg(feature = "test-hooks")]

mod support;

use serde_json::json;
use std::sync::{Arc, atomic::AtomicU64};
use support::{BIN, Client, Hub, Root};

#[test]
fn a_hub_that_ends_writes_what_it_held_first() {
    // restart-when-idle: one idle tick sends the update notice (a write no request made, so held) and, nothing being
    // busy, ends the hub in the same step; the notice reaches the subscriber before its end of file
    let root = Root::new();
    let socket = root.socket();
    let live = root.dir.path().join("live");
    drgnx_exe::copy(BIN.as_ref(), &live).unwrap();
    let mut hub = Hub::start_from(
        &live,
        &root,
        1,
        &["--test-sequencer", "--idle-tick-ms", "200"],
    );
    hub.wait_ready(&socket);
    let seq = Arc::new(AtomicU64::new(0));
    let mut editor = Client::gated(&socket, &seq);
    editor.hello(&socket);
    editor.send(json!({"id": 1, "method": "subscribe"}));
    editor.answer(1);
    // the update: another build at the path the hub runs from
    let other = root.dir.path().join("other");
    drgnx_exe::write(&other, "#!/bin/sh\necho '{\"commit\":\"another\"}'\n").unwrap();
    std::fs::rename(&other, &live).unwrap();
    let mut control = Client::gated(&socket, &seq);
    assert_eq!(control.line().unwrap()["event"], "challenge");
    control.send(json!({"id": 1, "method": "__test_advance", "params": {"ms": 200}}));
    control.answer(1);
    let status = hub.wait_exit();
    assert_eq!(status.code(), Some(75), "{}", hub.stderr_text());
    let rest: Vec<serde_json::Value> = std::iter::from_fn(|| editor.line()).collect();
    assert!(
        rest.iter().any(|v| v["event"] == "notice"
            && v["data"]["text"]
                .as_str()
                .is_some_and(|t| t.contains("updated"))),
        "the update notice before the end: {rest:?}\n{}",
        hub.stderr_text()
    );
}
