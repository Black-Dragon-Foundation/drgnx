//! hermod on ACP v2: scripted v2 agents (`/bin/sh` scripts that print canned JSON-RPC lines).  A script's reads pace
//! it: the client's calls are ids 1 (initialize), 2 (session/new), 3 (the first call after).

use hermod::schema::v1::SessionUpdate;
use hermod::{
    BackgroundRef, ClientCaps, Conn, ConnOpts, ContentBlock, Error, Event, MessageKind, Proto,
    RunState, StopReason, TerminalEv,
};
use serde_json::{Value, json};
use std::path::Path;
use std::time::Duration;
use tokio::sync::mpsc::Receiver;

const INIT: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2,"info":{"name":"v2-mock","version":"1"},"capabilities":{"session":{"prompt":{"embeddedContext":{}}}},"authMethods":[]}}"#;
const NEW: &str = r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","configOptions":[{"configId":"mode","name":"Mode","category":"mode","type":"select","currentValue":"ask","options":[]}]}}"#;
const ACK: &str = r#"{"jsonrpc":"2.0","id":3,"result":{"messageId":"u1"}}"#;

fn upd(body: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{body}}}}}"#
    )
}

fn state(body: &str) -> String {
    upd(&format!(r#"{{"sessionUpdate":"state_update",{body}}}"#))
}

/// A script that answers `initialize` and `session/new` (two reads), then runs REST.
fn script(rest: &str) -> String {
    format!("read a; printf '%s\\n' '{INIT}'; read b; printf '%s\\n' '{NEW}'; {rest}")
}

/// Prints each of LINES on its own line.
fn say(lines: &[String]) -> String {
    let args: Vec<String> = lines.iter().map(|l| format!("'{l}'")).collect();
    format!("printf '%s\\n' {}", args.join(" "))
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
        v2: true,
        ..ConnOpts::default()
    }
}

async fn start(script: &str) -> (Conn, Receiver<Event>) {
    Conn::spawn(spec(script), opts()).await.expect("spawn")
}

async fn open(conn: &Conn) -> hermod::SessionId {
    let info = conn
        .initialize(ClientCaps::default())
        .await
        .expect("initialize");
    assert_eq!(info.proto, Proto::V2);
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

fn text(t: &str) -> Vec<ContentBlock> {
    vec![ContentBlock::Text(hermod::schema::v1::TextContent::new(t))]
}

/// The next State event (others skipped).
async fn next_state(rx: &mut Receiver<Event>) -> (RunState, Option<Vec<BackgroundRef>>) {
    loop {
        if let Event::State {
            state, background, ..
        } = next(rx).await
        {
            return (state, background);
        }
    }
}

#[tokio::test]
async fn v2_turn_ends_at_idle() {
    let rest = format!(
        "read p; {}; cat >/dev/null",
        say(&[
            ACK.into(),
            state(r#""state":"running""#),
            state(
                r#""state":"idle","stopReason":"end_turn","usage":{"totalTokens":7,"inputTokens":3,"outputTokens":4},"_meta":{"turnId":"t9"}"#
            ),
        ])
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    let sid = open(&conn).await;
    let out = conn.prompt(&sid, text("hi"), None).await.unwrap();
    assert_eq!(out.stop, StopReason::EndTurn);
    assert_eq!(out.usage.map(|u| u.total_tokens), Some(7));
    assert_eq!(out.turn_id.as_deref(), Some("t9"));
    // the states reached the owner before the turn's end
    assert_eq!(next_state(&mut rx).await.0, RunState::Running);
    assert_eq!(
        next_state(&mut rx).await.0,
        RunState::Idle(Some(StopReason::EndTurn))
    );
}

#[tokio::test]
async fn v2_message_upsert_is_replace() {
    let rest = format!(
        "{}; cat >/dev/null",
        say(&[upd(
            r#"{"sessionUpdate":"agent_message","messageId":"m1","content":[{"type":"text","text":"whole"}]}"#
        )])
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    let Event::Replace {
        sid,
        message_id,
        kind,
        content,
        ..
    } = next(&mut rx).await
    else {
        panic!("a replace");
    };
    assert_eq!(&*sid.0, "s1");
    assert_eq!(message_id, "m1");
    assert_eq!(kind, MessageKind::Agent);
    assert_eq!(content, json!([{"type": "text", "text": "whole"}]));
}

#[tokio::test]
async fn v2_tool_call_created_on_first_update() {
    let first = upd(
        r#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","title":"Run","kind":"execute","status":"in_progress","capabilities":{"cancel":{}}}"#,
    );
    let second = upd(
        r#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"paused","capabilities":null}"#,
    );
    let rest = format!("{}; cat >/dev/null", say(&[first, second]));
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    let Event::Update { update, .. } = next(&mut rx).await else {
        panic!("an update");
    };
    let SessionUpdate::ToolCall(call) = update else {
        panic!("the first sight creates the v1 call: {update:?}");
    };
    assert_eq!(&*call.tool_call_id.0, "c1");
    let meta = call.meta.expect("meta");
    assert_eq!(meta["_hermod/can_cancel"], json!(true));
    assert_eq!(meta["_hermod/status"], json!("in_progress"));
    let Event::Update { update, .. } = next(&mut rx).await else {
        panic!("an update");
    };
    let SessionUpdate::ToolCallUpdate(u) = update else {
        panic!("later sight updates it: {update:?}");
    };
    let meta = u.meta.expect("meta");
    assert_eq!(meta["_hermod/can_cancel"], json!(false), "null clears it");
    assert_eq!(meta["_hermod/status"], json!("paused"), "the real status");
}

#[tokio::test]
async fn v2_state_carries_background() {
    let rest = format!(
        "{}; cat >/dev/null",
        say(&[
            state(r#""state":"idle""#),
            state(r#""state":"idle","background":[]"#),
            state(
                r#""state":"idle","background":[{"type":"terminal","terminalId":"t1"},{"type":"tool_call","toolCallId":"c1"},{"type":"subagent","sessionId":"k1"},{"type":"_weird","x":1}]"#
            ),
            state(r#""state":"unknown""#),
        ])
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    assert_eq!(next_state(&mut rx).await.1, None, "omitted is not reported");
    assert_eq!(next_state(&mut rx).await.1, Some(vec![]), "[] is nothing");
    let (_, list) = next_state(&mut rx).await;
    let list = list.expect("a list");
    assert_eq!(list[0], BackgroundRef::Terminal("t1".into()));
    assert_eq!(list[1], BackgroundRef::ToolCall("c1".into()));
    assert!(matches!(&list[2], BackgroundRef::Subagent(s) if &*s.0 == "k1"));
    assert!(matches!(&list[3], BackgroundRef::Other(v) if v["type"] == "_weird"));
    let (s, _) = next_state(&mut rx).await;
    assert_eq!(s, RunState::Unknown, "unknown stays unknown");
}

// Review focus 1: an agent that exits mid-turn must not leave the turn waiting for an idle that will not come.
#[tokio::test]
async fn v2_exit_mid_turn_ends_the_turn() {
    let rest = format!(
        "read p; {}; exit 0",
        say(&[ACK.into(), state(r#""state":"running""#)])
    );
    let (conn, _rx) = start(&script(&rest)).await;
    let sid = open(&conn).await;
    let r = tokio::time::timeout(Duration::from_secs(10), conn.prompt(&sid, text("hi"), None))
        .await
        .expect("the turn ends");
    assert!(matches!(r, Err(Error::Closed)), "{r:?}");
}

// Review focus 2: a repeated idle (the background list changed) is not a new completion.
#[tokio::test]
async fn v2_repeated_idle_is_not_a_new_completion() {
    let ack2 = r#"{"jsonrpc":"2.0","id":4,"result":{"messageId":"u2"}}"#;
    // turn one ends.  For the second prompt the agent sends a repeated idle (its list changed) and the
    // acknowledgement, then a sentinel; its second turn really ends later, with another stop reason
    let rest = format!(
        "read p; {}; read q; {}; read r; {}; cat >/dev/null",
        say(&[
            ACK.into(),
            state(r#""state":"running""#),
            state(r#""state":"idle","stopReason":"end_turn""#)
        ]),
        say(&[
            ack2.into(),
            state(
                r#""state":"idle","stopReason":"end_turn","background":[{"type":"terminal","terminalId":"t1"}]"#
            ),
            upd(
                r#"{"sessionUpdate":"agent_message_chunk","messageId":"sentinel","content":{"type":"text","text":"."}}"#
            ),
        ]),
        say(&[
            state(r#""state":"running""#),
            state(r#""state":"idle","stopReason":"max_tokens""#)
        ]),
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    let sid = open(&conn).await;
    let one = conn.prompt(&sid, text("one"), None).await.unwrap();
    assert_eq!(one.stop, StopReason::EndTurn);
    let two = conn.send_prompt(&sid, text("two"), None).unwrap();
    tokio::pin!(two);
    // everything the agent sent for the second prompt has been read once the sentinel is out
    while !matches!(&next(&mut rx).await, Event::Update { message_id: Some(m), .. } if m == "sentinel")
    {
    }
    tokio::select! {
        biased;
        r = &mut two => panic!("the repeated idle ended the second turn: {r:?}"),
        () = std::future::ready(()) => {}
    }
    // its own running and idle end it, with their stop reason
    conn.cancel(&sid).unwrap();
    assert_eq!(two.await.unwrap().stop, StopReason::MaxTokens);
}

// Review focus 3: after session/cancel, updates for surviving background work still apply, and the prompt's -32800
// answer is a cancelled outcome, not an error.
#[tokio::test]
async fn v2_cancel_keeps_background_updates() {
    let cancelled = r#"{"jsonrpc":"2.0","id":3,"error":{"code":-32800,"message":"cancelled"}}"#;
    let rest = format!(
        "read p; read c; {}; cat >/dev/null",
        say(&[
            cancelled.into(),
            upd(r#"{"sessionUpdate":"tool_call_update","toolCallId":"bg","status":"in_progress"}"#),
            state(
                r#""state":"idle","stopReason":"cancelled","background":[{"type":"tool_call","toolCallId":"bg"}]"#
            ),
        ])
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    let sid = open(&conn).await;
    let turn = conn.send_prompt(&sid, text("go"), None).unwrap();
    conn.cancel(&sid).unwrap();
    let out = turn.await.unwrap();
    assert_eq!(out.stop, StopReason::Cancelled);
    let Event::Update { update, .. } = next(&mut rx).await else {
        panic!("the background update still arrives");
    };
    assert!(matches!(update, SessionUpdate::ToolCall(_)));
    let (_, bg) = next_state(&mut rx).await;
    assert_eq!(bg, Some(vec![BackgroundRef::ToolCall("bg".into())]));
}

#[tokio::test]
async fn v2_terminal_chunk_decoded() {
    // "héllo": the é (c3 a9) split across two chunks: each chunk is base64 of its own bytes
    let update = upd(
        r#"{"sessionUpdate":"terminal_update","terminalId":"t1","command":"ls","cwd":"/w","output":{"data":"aMM="},"exitStatus":{"exitCode":3},"capabilities":{"cancel":{}}}"#,
    );
    let c1 = upd(r#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t1","data":"aMM="}"#);
    let c2 =
        upd(r#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t1","data":"qWxsbw=="}"#);
    let rest = format!("{}; cat >/dev/null", say(&[update, c1, c2]));
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    let Event::Terminal { id, update, .. } = next(&mut rx).await else {
        panic!("a terminal event");
    };
    assert_eq!(id, "t1");
    let TerminalEv::Update {
        command,
        cwd,
        snapshot,
        exit,
        can_cancel,
    } = update
    else {
        panic!("an update");
    };
    assert_eq!(command.as_deref(), Some("ls"));
    assert_eq!(cwd.as_deref(), Some("/w"));
    assert_eq!(snapshot, Some(vec![b'h', 0xc3]));
    assert_eq!(exit, Some((Some(3), None)));
    assert_eq!(can_cancel, Some(true));
    let mut bytes = vec![];
    for _ in 0..2 {
        let Event::Terminal {
            update: TerminalEv::Chunk(b),
            ..
        } = next(&mut rx).await
        else {
            panic!("a chunk");
        };
        bytes.extend(b);
    }
    assert_eq!(String::from_utf8(bytes).unwrap(), "héllo");
}

// ---- Task 2: negotiation (these go in conn.rs's file in the tree; kept here with the v2 helpers) ----

/// A script that echoes the client's first line (initialize) to stderr, answers with ANSWER, then runs REST.
fn init_echo(answer: &str, rest: &str) -> String {
    format!("read a; echo \"$a\" >&2; printf '%s\\n' '{answer}'; {rest}")
}

#[tokio::test]
async fn v2_asked_and_granted() {
    let (conn, mut rx) = start(&init_echo(INIT, "cat >/dev/null")).await;
    let caps: ClientCaps = serde_json::from_value(
        json!({"fs": {"readTextFile": true, "writeTextFile": true}, "_meta": {"_drgnx/panel": {"features": ["x"]}}}),
    )
    .unwrap();
    let info = conn.initialize(caps).await.unwrap();
    assert_eq!(info.proto, Proto::V2);
    assert_eq!(conn.proto(), Proto::V2);
    assert_eq!(info.name.as_deref(), Some("v2-mock"));
    // the v2 capabilities, read as the v1 shape the hub keys on
    let caps = serde_json::to_value(&info.caps).unwrap();
    assert_eq!(caps["promptCapabilities"]["embeddedContext"], json!(true));
    assert_eq!(caps["loadSession"], json!(true));
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit");
    };
    let sent: Value = serde_json::from_str(stderr.lines().next().unwrap()).unwrap();
    assert_eq!(sent["params"]["protocolVersion"], json!(2));
    assert_eq!(sent["params"]["info"]["name"], json!("hermod"));
    assert_eq!(
        sent["params"]["capabilities"]["_meta"]["_drgnx/panel"],
        json!({"features": ["x"]})
    );
    assert!(
        sent["params"].get("clientCapabilities").is_none(),
        "no v1 fields"
    );
}

#[tokio::test]
async fn v2_asked_v1_answered() {
    let v1 = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"authMethods":[]}}"#;
    // a v1 agent: session/load is session/load, and the answer to the modes call is the v1 one
    let rest = r#"read b; echo "$b" >&2; printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{}}'; cat >/dev/null"#;
    let (conn, mut rx) = start(&init_echo(v1, rest)).await;
    let info = conn.initialize(ClientCaps::default()).await.unwrap();
    assert_eq!(info.proto, Proto::V1);
    assert_eq!(conn.proto(), Proto::V1);
    conn.load_session(
        &hermod::SessionId::new("s9".to_string()),
        Path::new("/w"),
        vec![],
        None,
    )
    .await
    .unwrap();
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit");
    };
    let mut lines = stderr.lines();
    let first: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(
        first["params"]["protocolVersion"],
        json!(2),
        "it asked for 2"
    );
    let second: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(second["method"], json!("session/load"), "and goes on in v1");
}

#[tokio::test]
async fn v2_off_sends_v1() {
    let v1 = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#;
    let mut o = opts();
    o.v2 = false;
    let (conn, mut rx) = Conn::spawn(spec(&init_echo(v1, "cat >/dev/null")), o)
        .await
        .unwrap();
    let info = conn.initialize(ClientCaps::default()).await.unwrap();
    assert_eq!(info.proto, Proto::V1);
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit");
    };
    let sent: Value = serde_json::from_str(stderr.lines().next().unwrap()).unwrap();
    assert_eq!(sent["params"]["protocolVersion"], json!(1));
    assert!(sent["params"].get("clientCapabilities").is_some());
    assert!(sent["params"].get("capabilities").is_none());
}

// ---- Task 4: v2 requests ----

/// A script that opens a v2 session, then echoes every line it reads (up to N) to stderr, answering each request
/// with an empty result (id 3, 4, …).
fn echo_calls(n: usize) -> String {
    let mut s = String::new();
    for i in 0..n {
        s.push_str(&format!(
            "read l; echo \"$l\" >&2; printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{}}}}'; ",
            3 + i
        ));
    }
    script(&format!("{s} cat >/dev/null"))
}

async fn written(rx: &mut Receiver<Event>) -> Vec<Value> {
    let Event::Exit { stderr, .. } = next(rx).await else {
        panic!("exit");
    };
    stderr
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

#[tokio::test]
async fn v2_cancel_requests_written() {
    let (conn, mut rx) = start(&echo_calls(3)).await;
    let sid = open(&conn).await;
    conn.cancel_tool_call(&sid, "call_9").await.unwrap();
    conn.cancel_terminal(&sid, "term_9").await.unwrap();
    conn.cancel_child(&hermod::SessionId::new("kid".to_string()))
        .unwrap();
    drop(conn);
    let w = written(&mut rx).await;
    assert_eq!(w[0]["method"], json!("tool_call/cancel"));
    assert_eq!(
        w[0]["params"],
        json!({"sessionId": "s1", "toolCallId": "call_9"})
    );
    assert_eq!(w[1]["method"], json!("terminal/cancel"));
    assert_eq!(
        w[1]["params"],
        json!({"sessionId": "s1", "terminalId": "term_9"})
    );
    // a child is cancelled as a session, with the child's id
    assert_eq!(w[2]["method"], json!("session/cancel"));
    assert_eq!(w[2]["params"], json!({"sessionId": "kid"}));
    assert!(w[2].get("id").is_none(), "a notification");
}

#[tokio::test]
async fn v1_cancels_refused_locally() {
    let (conn, mut rx) = Conn::spawn(
        spec(&format!(
            "read a; printf '%s\\n' '{}'; read b; printf '%s\\n' '{}'; cat >&2",
            r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
            r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#
        )),
        opts(),
    )
    .await
    .unwrap();
    let info = conn.initialize(ClientCaps::default()).await.unwrap();
    assert_eq!(info.proto, Proto::V1);
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    for r in [
        conn.cancel_tool_call(&sid, "c").await,
        conn.cancel_terminal(&sid, "t").await,
        conn.cancel_child(&sid),
    ] {
        assert!(matches!(r, Err(Error::Rpc { code: -32601, .. })), "{r:?}");
    }
    drop(conn);
    // nothing was written after session/new: the script's stderr holds no line
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit");
    };
    assert_eq!(stderr.trim(), "", "nothing written for a refused cancel");
}

#[tokio::test]
async fn v2_load_is_resume() {
    let (conn, mut rx) = start(&echo_calls(2)).await;
    let sid = open(&conn).await;
    conn.load_session(&sid, Path::new("/w"), vec![], None)
        .await
        .unwrap();
    conn.resume_session(&sid, Path::new("/w"), vec![], None)
        .await
        .unwrap();
    drop(conn);
    let w = written(&mut rx).await;
    assert_eq!(w[0]["method"], json!("session/resume"));
    assert_eq!(
        w[0]["params"]["replayFrom"],
        json!({"type": "start"}),
        "load replays"
    );
    assert_eq!(w[1]["method"], json!("session/resume"));
    assert!(
        w[1]["params"].get("replayFrom").is_none(),
        "resume does not"
    );
}

#[tokio::test]
async fn v2_set_mode_is_config_option() {
    let (conn, mut rx) = start(&echo_calls(1)).await;
    let sid = open(&conn).await;
    conn.set_mode(&sid, "plan").await.unwrap();
    drop(conn);
    let w = written(&mut rx).await;
    assert_eq!(w[0]["method"], json!("session/set_config_option"));
    assert_eq!(
        w[0]["params"],
        json!({"sessionId": "s1", "configId": "mode", "type": "id", "value": "plan"})
    );
}

#[tokio::test]
async fn v2_set_mode_without_a_mode_option_is_refused() {
    // session/new reports no config options
    let new = r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#;
    let s = format!("read a; printf '%s\\n' '{INIT}'; read b; printf '%s\\n' '{new}'; cat >&2");
    let (conn, mut rx) = start(&s).await;
    let sid = open(&conn).await;
    let r = conn.set_mode(&sid, "plan").await;
    assert!(matches!(r, Err(Error::Rpc { .. })), "{r:?}");
    drop(conn);
    assert_eq!(written(&mut rx).await.len(), 0);
}
