//! hermod against scripted children: `/bin/sh` scripts that print canned JSON-RPC lines (the mock agent is Task 2).

use hermod::schema::v1::{
    PermissionOptionId, RequestPermissionOutcome, RequestPermissionResponse, SessionUpdate,
};
use hermod::{ClientCaps, Conn, ConnOpts, Error, Event, ForkPoint, Incoming};
use std::path::Path;
use std::time::Duration;
use tokio::sync::mpsc::Receiver;

const INIT: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#;
const NEW: &str = r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#;

fn upd(body: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{body}}}}}"#
    )
}

fn chunk(text: &str, id: Option<&str>) -> String {
    let mid = id.map_or(String::new(), |i| format!(r#","messageId":"{i}""#));
    upd(&format!(
        r#"{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"{text}"}}{mid}}}"#
    ))
}

/// A script that answers `initialize` and `session/new` (two reads), then runs REST.
fn script(rest: &str) -> String {
    format!("read a; printf '%s\\n' '{INIT}'; read b; printf '%s\\n' '{NEW}'; {rest}")
}

fn spec(script: &str) -> draugr::Spec {
    draugr::Spec {
        program: "/bin/sh".into(),
        args: vec!["-c".into(), script.into()],
        env: draugr::env::build(&["PATH"], &[], &[]),
        cwd: None,
        stdin_null: false,
        pass_fds: vec![],
        new_session: false,
    }
}

fn opts() -> ConnOpts {
    ConnOpts {
        deadline: Duration::from_secs(10),
        stderr_tail: 4000,
    }
}

async fn start(script: &str, opts: ConnOpts) -> (Conn, Receiver<Event>) {
    Conn::spawn(spec(script), opts).await.expect("spawn")
}

async fn open(conn: &Conn) -> hermod::SessionId {
    conn.initialize(ClientCaps::default())
        .await
        .expect("initialize");
    conn.new_session(Path::new("/work"), vec![], None)
        .await
        .expect("session/new")
}

async fn next(rx: &mut Receiver<Event>) -> Event {
    tokio::time::timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("an event in time")
        .expect("the channel is open")
}

#[tokio::test]
async fn initialize_then_session() {
    let (conn, mut rx) = start(&script("cat >/dev/null"), opts()).await;
    let info = conn.initialize(ClientCaps::default()).await.unwrap();
    assert!(info.auth.is_empty());
    assert!(info.meta.is_none());
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    assert_eq!(&*sid.0, "s1");
    drop(conn);
    assert!(matches!(
        next(&mut rx).await,
        Event::Exit { code: Some(0), .. }
    ));
}

#[tokio::test]
async fn every_update_is_stamped_on_receipt() {
    let rest = format!(
        "printf '%s\\n' '{}' '{}' '{}'; cat >/dev/null",
        chunk("a", None),
        chunk("b", None),
        chunk("c", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    let before = hermod::stamp::now();
    open(&conn).await;
    let mut stamps = vec![];
    while stamps.len() < 3 {
        if let Event::Update { at, sid, .. } = next(&mut rx).await {
            assert_eq!(&*sid.0, "s1");
            stamps.push(at);
        }
    }
    let after = hermod::stamp::now();
    assert!(
        stamps.windows(2).all(|w| w[0] <= w[1]),
        "stamps never go back: {stamps:?}"
    );
    assert!(
        stamps[0] >= before && stamps[2] <= after,
        "{before} <= {stamps:?} <= {after}"
    );
}

#[tokio::test]
async fn message_ids_are_kept() {
    let rest = format!(
        "printf '%s\\n' '{}' '{}'; cat >/dev/null",
        chunk("a", Some("m1")),
        chunk("b", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    let mut ids = vec![];
    while ids.len() < 2 {
        if let Event::Update {
            message_id, update, ..
        } = next(&mut rx).await
        {
            assert!(matches!(update, SessionUpdate::AgentMessageChunk(_)));
            ids.push(message_id);
        }
    }
    assert_eq!(ids, vec![Some("m1".to_string()), None]);
}

#[tokio::test]
async fn a_request_gets_a_responder_and_an_unanswered_one_is_cancelled_at_exit() {
    let req = |id: u32| {
        format!(
            r#"{{"jsonrpc":"2.0","id":{id},"method":"session/request_permission","params":{{"sessionId":"s1","toolCall":{{"toolCallId":"t{id}"}},"options":[{{"optionId":"yes","name":"Yes","kind":"allow_once"}}]}}}}"#
        )
    };
    // the first reply is echoed to stderr; the second request is never answered
    let rest = format!(
        "printf '%s\\n' '{}'; read r; echo \"$r\" >&2; printf '%s\\n' '{}'; sleep 0.3",
        req(100),
        req(101)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    let Event::Request(Incoming::Permission(p, responder)) = next(&mut rx).await else {
        panic!("a permission request")
    };
    assert_eq!(&*p.tool_call.tool_call_id.0, "t100");
    let outcome = RequestPermissionOutcome::Selected(
        hermod::schema::v1::SelectedPermissionOutcome::new(PermissionOptionId::new("yes")),
    );
    responder
        .respond(RequestPermissionResponse::new(outcome))
        .unwrap();
    let Event::Request(Incoming::Permission(_, mut second)) = next(&mut rx).await else {
        panic!("the second request")
    };
    assert!(!second.is_cancelled());
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    assert!(
        stderr.contains(r#""id":100"#) && stderr.contains("selected"),
        "{stderr}"
    );
    assert!(second.is_cancelled());
    second.cancelled().await;
    assert!(matches!(
        second.respond(RequestPermissionResponse::new(
            RequestPermissionOutcome::Cancelled
        )),
        Err(Error::Closed)
    ));
}

#[tokio::test]
async fn exit_comes_once_with_the_stderr_tail() {
    let rest = "echo 'a long first line that gets cut off, then boom' >&2; exit 3";
    let o = ConnOpts {
        stderr_tail: 10,
        ..opts()
    };
    let (conn, mut rx) = start(&script(rest), o).await;
    open(&conn).await;
    let Event::Exit {
        code,
        signal,
        stderr,
    } = next(&mut rx).await
    else {
        panic!("exit")
    };
    assert_eq!((code, signal), (Some(3), None));
    assert!(
        stderr.chars().count() <= 10 && stderr.trim_end().ends_with("boom"),
        "{stderr:?}"
    );
    assert!(
        rx.recv().await.is_none(),
        "no second Exit, nothing after it"
    );
    assert!(matches!(
        conn.set_mode(&hermod::SessionId::new("s1"), "code").await,
        Err(Error::Closed)
    ));
}

#[tokio::test]
async fn a_deadline_fails_the_call_not_the_conn() {
    // the first session/new is never answered; the second is
    let rest = format!(
        "read c; read d; printf '%s\\n' '{}'; cat >/dev/null",
        r#"{"jsonrpc":"2.0","id":4,"result":{"sessionId":"s9"}}"#
    );
    let o = ConnOpts {
        deadline: Duration::from_millis(300),
        ..opts()
    };
    let (conn, _rx) = start(&script(&rest), o).await;
    open(&conn).await;
    let r = conn.new_session(Path::new("/work"), vec![], None).await;
    assert!(
        matches!(r, Err(Error::Deadline(ref m)) if m == "session/new"),
        "{r:?}"
    );
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    assert_eq!(&*sid.0, "s9");
}

#[tokio::test]
async fn fork_sends_the_jetbrains_meta() {
    let rest = r#"read f; echo "$f" >&2; printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s2"}}'; cat >/dev/null"#;
    let (conn, mut rx) = start(&script(rest), opts()).await;
    let sid = open(&conn).await;
    let forked = conn
        .fork(
            &sid,
            Some(ForkPoint {
                message_id: "m7".into(),
            }),
        )
        .await
        .unwrap();
    assert_eq!(&*forked.0, "s2");
    assert!(matches!(
        conn.fork(&hermod::SessionId::new("nope"), None).await,
        Err(Error::UnknownSession(_))
    ));
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    let sent: serde_json::Value = serde_json::from_str(stderr.trim()).unwrap();
    assert_eq!(sent["method"], "session/fork");
    assert_eq!(sent["params"]["sessionId"], "s1");
    assert_eq!(sent["params"]["cwd"], "/work");
    let fork = &sent["params"]["_meta"]["jetbrains"]["air"]["fork"];
    assert_eq!(
        (fork["version"].as_i64(), fork["messageId"].as_str()),
        (Some(1), Some("m7"))
    );
}

#[tokio::test]
async fn unknown_notifications_are_ignored_unknown_requests_get_32601() {
    let rest = format!(
        r#"printf '%s\n' '{{"jsonrpc":"2.0","method":"foo/bar","params":{{}}}}' '{{"jsonrpc":"2.0","id":50,"method":"terminal/create","params":{{"sessionId":"s1","command":"ls"}}}}' '{}'; read r; echo "$r" >&2"#,
        chunk("x", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    assert!(
        matches!(next(&mut rx).await, Event::Update { .. }),
        "the update after the unknown ones"
    );
    // our side answered the terminal request; the child then echoes that line when its stdin closes
    tokio::time::sleep(Duration::from_millis(200)).await;
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    assert!(
        stderr.contains("-32601") && stderr.contains(r#""id":50"#),
        "{stderr}"
    );
}
