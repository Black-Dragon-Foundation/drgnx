//! The mock adapter (feature `mock`): a script of expected requests and canned answers and events, failing on any
//! request it did not expect.
#![cfg(feature = "mock")]
use serde_json::{Value, json};
use vor::mock::{Mock, Script};
use vor::{Client, Error, Incoming};

fn start(script: Value) -> (Client, tokio::sync::mpsc::UnboundedReceiver<Incoming>, Mock) {
    let script: Script = serde_json::from_value(script).unwrap();
    let (a, b) = tokio::io::duplex(1 << 20);
    let (cr, cw) = tokio::io::split(a);
    let (mr, mw) = tokio::io::split(b);
    let mock = Mock::start(script, mr, mw);
    let (client, inc) = Client::new(cr, cw);
    (client, inc, mock)
}

#[tokio::test]
async fn expected_requests_get_their_answers_and_events_follow() {
    let (client, mut inc, mock) = start(json!([
        {"expect": "initialize", "args": {"adapterID": "py"}, "ok": {"supportsTerminateRequest": true}},
        {"event": "initialized"},
        {"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}},
    ]));
    let caps = client
        .request(
            "initialize",
            json!({"adapterID": "py", "linesStartAt1": true}),
        )
        .await
        .unwrap();
    assert_eq!(caps["supportsTerminateRequest"], true);
    assert!(
        matches!(inc.recv().await, Some(Incoming::Event { event, .. }) if event == "initialized")
    );
    let t = client.request("threads", Value::Null).await.unwrap();
    assert_eq!(t["threads"][0]["name"], "main");
    drop(client);
    let log = mock.finish().await.unwrap();
    assert_eq!(log.commands(), ["initialize", "threads"]);
}

#[tokio::test]
async fn an_unexpected_request_fails_the_script_and_names_both() {
    let (client, _inc, mock) = start(json!([{"expect": "threads", "ok": {}}]));
    let r = client.request("stackTrace", json!({"threadId": 1})).await;
    assert!(
        matches!(r, Err(Error::Failed { .. })),
        "the mock refuses it: {r:?}"
    );
    drop(client);
    let err = mock.finish().await.unwrap_err();
    assert!(
        err.contains("threads") && err.contains("stackTrace"),
        "{err}"
    );
}

#[tokio::test]
async fn arguments_that_do_not_match_fail_the_script() {
    let (client, _inc, mock) =
        start(json!([{"expect": "stackTrace", "args": {"levels": 20}, "ok": {}}]));
    let _ = client
        .request("stackTrace", json!({"threadId": 1, "levels": 5}))
        .await;
    drop(client);
    let err = mock.finish().await.unwrap_err();
    assert!(err.contains("levels"), "{err}");
}

#[tokio::test]
async fn a_request_after_the_script_ends_fails_it() {
    let (client, _inc, mock) = start(json!([]));
    let _ = client.request("threads", Value::Null).await;
    drop(client);
    assert!(mock.finish().await.unwrap_err().contains("threads"));
}

#[tokio::test]
async fn a_script_not_finished_when_the_client_leaves_fails() {
    let (client, _inc, mock) = start(json!([{"expect": "threads", "ok": {}}]));
    drop(client);
    assert!(mock.finish().await.unwrap_err().contains("threads"));
}

#[tokio::test]
async fn an_unordered_group_takes_its_requests_in_any_order() {
    let (client, _inc, mock) = start(json!([
        {"any": [
            {"expect": "variables", "args": {"variablesReference": 1}, "ok": {"variables": []}},
            {"expect": "variables", "args": {"variablesReference": 2}, "ok": {"variables": []}},
        ]},
    ]));
    let b = client.request("variables", json!({"variablesReference": 2}));
    let a = client.request("variables", json!({"variablesReference": 1}));
    assert!(b.await.is_ok() && a.await.is_ok());
    drop(client);
    mock.finish().await.unwrap();
}

#[tokio::test]
async fn a_deferred_answer_comes_when_its_step_says() {
    let (client, mut inc, mock) = start(json!([
        {"expect": "launch", "defer": true},
        {"event": "initialized"},
        {"expect": "configurationDone", "ok": {}},
        {"answer": "launch", "ok": {}},
    ]));
    let launch = client.request("launch", json!({"program": "x"}));
    assert!(
        matches!(inc.recv().await, Some(Incoming::Event { event, .. }) if event == "initialized")
    );
    client
        .request("configurationDone", Value::Null)
        .await
        .unwrap();
    launch.await.unwrap();
    drop(client);
    mock.finish().await.unwrap();
}

#[tokio::test]
async fn a_request_never_answered_stays_pending() {
    let (client, _inc, mock) = start(json!([
        {"expect": "terminate", "silent": true},
        {"expect": "disconnect", "ok": {}},
    ]));
    let t = client.request("terminate", Value::Null);
    client.request("disconnect", Value::Null).await.unwrap();
    drop(t);
    drop(client);
    mock.finish().await.unwrap();
}

#[tokio::test]
async fn a_reverse_request_waits_for_its_answer() {
    let (client, mut inc, mock) = start(json!([
        {"reverse": "runInTerminal", "arguments": {"args": ["prog"]}, "answer": {"processId": 42}},
    ]));
    let Some(Incoming::Request(r)) = inc.recv().await else {
        panic!()
    };
    assert_eq!(r.command, "runInTerminal");
    r.ok(json!({"processId": 42}));
    drop(client);
    mock.finish().await.unwrap();
}

#[tokio::test]
async fn a_refused_reverse_request_fails_the_script() {
    let (client, mut inc, mock) = start(json!([
        {"reverse": "runInTerminal", "arguments": {}, "answer": {}},
    ]));
    let Some(Incoming::Request(r)) = inc.recv().await else {
        panic!()
    };
    r.err("no terminal");
    drop(client);
    assert!(mock.finish().await.unwrap_err().contains("runInTerminal"));
}

#[tokio::test]
async fn die_ends_the_connection() {
    let (client, mut inc, mock) = start(json!([{"expect": "threads", "ok": {}}, {"die": true}]));
    client.request("threads", Value::Null).await.unwrap();
    assert!(inc.recv().await.is_none());
    assert!(matches!(
        client.request("threads", Value::Null).await,
        Err(Error::Closed(_))
    ));
    mock.finish().await.unwrap();
}

#[tokio::test]
async fn the_log_keeps_every_request_with_its_arguments() {
    let (client, _inc, mock) =
        start(json!([{"expect": "setBreakpoints", "ok": {"breakpoints": []}}]));
    client
        .request(
            "setBreakpoints",
            json!({"source": {"path": "/p/a.py"}, "breakpoints": [{"line": 3}]}),
        )
        .await
        .unwrap();
    drop(client);
    let log = mock.finish().await.unwrap();
    assert_eq!(log.requests[0].1["breakpoints"][0]["line"], 3);
}
