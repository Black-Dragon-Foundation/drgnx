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

#[test]
fn v2_turn_ends_at_idle() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_message_upsert_is_replace() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_tool_call_created_on_first_update() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_state_carries_background() {
    saman::block_on_current(async {
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
    })
}

// Review focus 1: an agent that exits mid-turn must not leave the turn waiting for an idle that will not come.
#[test]
fn v2_exit_mid_turn_ends_the_turn() {
    saman::block_on_current(async {
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
    })
}

// Review focus 2: a repeated idle (the background list changed) is not a new completion.
#[test]
fn v2_repeated_idle_is_not_a_new_completion() {
    saman::block_on_current(async {
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
    })
}

// Review focus 3: after session/cancel, updates for surviving background work still apply, and the prompt's -32800
// answer is a cancelled outcome, not an error.
#[test]
fn v2_cancel_keeps_background_updates() {
    saman::block_on_current(async {
        let cancelled = r#"{"jsonrpc":"2.0","id":3,"error":{"code":-32800,"message":"cancelled"}}"#;
        let rest = format!(
            "read p; read c; {}; cat >/dev/null",
            say(&[
                cancelled.into(),
                upd(
                    r#"{"sessionUpdate":"tool_call_update","toolCallId":"bg","status":"in_progress"}"#
                ),
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
    })
}

#[test]
fn v2_terminal_chunk_decoded() {
    saman::block_on_current(async {
        // "héllo": the é (c3 a9) split across two chunks: each chunk is base64 of its own bytes
        let update = upd(
            r#"{"sessionUpdate":"terminal_update","terminalId":"t1","command":"ls","cwd":"/w","output":{"data":"aMM="},"exitStatus":{"exitCode":3},"capabilities":{"cancel":{}}}"#,
        );
        let c1 =
            upd(r#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t1","data":"aMM="}"#);
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
    })
}

// ---- Task 2: negotiation (these go in conn.rs's file in the tree; kept here with the v2 helpers) ----

/// A script that echoes the client's first line (initialize) to stderr, answers with ANSWER, then runs REST.
fn init_echo(answer: &str, rest: &str) -> String {
    format!("read a; echo \"$a\" >&2; printf '%s\\n' '{answer}'; {rest}")
}

#[test]
fn v2_asked_and_granted() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_asked_v1_answered() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_off_sends_v1() {
    saman::block_on_current(async {
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
    })
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

#[test]
fn v2_cancel_requests_written() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v1_cancels_refused_locally() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_load_is_resume() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_set_mode_is_config_option() {
    saman::block_on_current(async {
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
    })
}

#[test]
fn v2_set_mode_without_a_mode_option_is_refused() {
    saman::block_on_current(async {
        // session/new reports no config options
        let new = r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#;
        let s = format!("read a; printf '%s\\n' '{INIT}'; read b; printf '%s\\n' '{new}'; cat >&2");
        let (conn, mut rx) = start(&s).await;
        let sid = open(&conn).await;
        let r = conn.set_mode(&sid, "plan").await;
        assert!(matches!(r, Err(Error::Rpc { .. })), "{r:?}");
        drop(conn);
        assert_eq!(written(&mut rx).await.len(), 0);
    })
}

// ---- v2 diffs: a diff item is `changes` plus git patch text; the hub reads `path`, `oldText`, `newText` ----

use hermod::schema::v1::ToolCallContent;

/// The diff items of the v1 tool call the update BODY (a v2 `tool_call_update`) became.
async fn diffs_of(body: &str) -> Vec<(String, Option<String>, String)> {
    let rest = format!("{}; cat >/dev/null", say(&[upd(body)]));
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    let Event::Update { update, .. } = next(&mut rx).await else {
        panic!("an update");
    };
    let SessionUpdate::ToolCall(call) = update else {
        panic!("a tool call: {update:?}");
    };
    call.content
        .iter()
        .filter_map(|c| match c {
            ToolCallContent::Diff(d) => Some((
                d.path.display().to_string(),
                d.old_text.clone(),
                d.new_text.clone(),
            )),
            _ => None,
        })
        .collect()
}

fn diff_call(diff: &str) -> String {
    format!(
        r#"{{"sessionUpdate":"tool_call_update","toolCallId":"e1","title":"Edit","kind":"edit","status":"completed","content":[{diff}]}}"#
    )
}

#[test]
fn v2_diff_hunks_are_the_v1_diff_fragments() {
    saman::block_on_current(async {
        let patch = "diff --git /w/a.rs /w/a.rs\\n--- /w/a.rs\\n+++ /w/a.rs\\n@@ -1,3 +1,3 @@\\n fn a() {\\n-    1\\n+    2\\n }\\n@@ -10,2 +10,3 @@\\n x\\n+y\\n z\\n";
        let diff = format!(
            r#"{{"type":"diff","changes":[{{"operation":"modify","path":"/w/a.rs","fileType":"text"}}],"patch":{{"format":"git_patch","text":"{patch}"}}}}"#
        );
        let got = diffs_of(&diff_call(&diff)).await;
        assert_eq!(
            got,
            vec![
                (
                    "/w/a.rs".to_string(),
                    Some("fn a() {\n    1\n}\n".to_string()),
                    "fn a() {\n    2\n}\n".to_string()
                ),
                (
                    "/w/a.rs".to_string(),
                    Some("x\nz\n".to_string()),
                    "x\ny\nz\n".to_string()
                ),
            ],
            "one fragment per hunk, context kept, as Codex's one Diff per hunk"
        );
    })
}

#[test]
fn v2_diff_of_an_added_and_a_deleted_file() {
    saman::block_on_current(async {
        let patch = "diff --git /dev/null /w/b.rs\\nnew file mode 100644\\n--- /dev/null\\n+++ /w/b.rs\\n@@ -0,0 +1,2 @@\\n+x\\n+y\\ndiff --git /w/c.rs /dev/null\\ndeleted file mode 100644\\n--- /w/c.rs\\n+++ /dev/null\\n@@ -1 +0,0 @@\\n-gone\\n";
        let diff = format!(
            r#"{{"type":"diff","changes":[{{"operation":"add","path":"/w/b.rs"}},{{"operation":"delete","path":"/w/c.rs"}}],"patch":{{"format":"git_patch","text":"{patch}"}}}}"#
        );
        let got = diffs_of(&diff_call(&diff)).await;
        assert_eq!(
            got,
            vec![
                ("/w/b.rs".to_string(), None, "x\ny\n".to_string()),
                (
                    "/w/c.rs".to_string(),
                    Some("gone\n".to_string()),
                    String::new()
                ),
            ]
        );
    })
}

#[test]
fn v2_diff_without_usable_patch_still_names_its_paths() {
    saman::block_on_current(async {
        // no patch, a patch format this code does not know, and a move: the affected paths from `changes`, no text
        let diff = r#"{"type":"diff","changes":[{"operation":"modify","path":"/w/logo.png","fileType":"binary"},{"operation":"move","oldPath":"/w/o.rs","path":"/w/n.rs"}],"patch":{"format":"_custom","text":"whatever"}}"#;
        let got = diffs_of(&diff_call(diff)).await;
        assert_eq!(
            got,
            vec![
                ("/w/logo.png".to_string(), None, String::new()),
                ("/w/n.rs".to_string(), None, String::new()),
            ]
        );
    })
}

#[test]
fn v1_shaped_diff_items_pass_through() {
    saman::block_on_current(async {
        let diff = r#"{"type":"diff","path":"/w/a.rs","oldText":"a","newText":"b"}"#;
        let got = diffs_of(&diff_call(diff)).await;
        assert_eq!(
            got,
            vec![(
                "/w/a.rs".to_string(),
                Some("a".to_string()),
                "b".to_string()
            )]
        );
    })
}

// ---- falling back to v1 ----

fn init_error() -> &'static str {
    r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"unsupported protocol version 2"}}"#
}

fn v1_init(id: u32) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{id},"result":{{"protocolVersion":1,"agentCapabilities":{{}},"authMethods":[]}}}}"#
    )
}

#[test]
fn v2_initialize_rejected_is_asked_again_as_v1_on_the_same_connection() {
    saman::block_on_current(async {
        // the agent answers the v2 initialize with an error, then the v1 one with an answer
        let s = format!(
            "read a; echo \"$a\" >&2; printf '%s\\n' '{}'; read b; echo \"$b\" >&2; printf '%s\\n' '{}'; cat >/dev/null",
            init_error(),
            v1_init(2)
        );
        let (conn, mut rx) = start(&s).await;
        let info = conn.initialize(ClientCaps::default()).await.unwrap();
        assert_eq!(info.proto, Proto::V1);
        assert_eq!(conn.proto(), Proto::V1);
        let why = info.v2_fallback.expect("the fallback is recorded");
        assert!(why.contains("unsupported protocol version"), "{why}");
        drop(conn);
        let Event::Exit { stderr, .. } = next(&mut rx).await else {
            panic!("exit");
        };
        let sent: Vec<Value> = stderr
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0]["params"]["protocolVersion"], json!(2));
        assert_eq!(sent[1]["params"]["protocolVersion"], json!(1));
        assert!(
            sent[1]["params"].get("clientCapabilities").is_some(),
            "a real v1 request"
        );
    })
}

#[test]
fn v2_initialize_rejected_twice_is_not_asked_a_third_time() {
    saman::block_on_current(async {
        let again = r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"nope"}}"#;
        let s = format!(
            "read a; echo \"$a\" >&2; printf '%s\\n' '{}'; read b; echo \"$b\" >&2; printf '%s\\n' '{again}'; read c; echo \"$c\" >&2; cat >/dev/null",
            init_error()
        );
        let (conn, mut rx) = start(&s).await;
        let r = conn.initialize(ClientCaps::default()).await;
        assert!(
            matches!(r, Err(Error::Rpc { code: -32603, .. })),
            "{r:?}: the v1 answer is the answer"
        );
        drop(conn);
        let Event::Exit { stderr, .. } = next(&mut rx).await else {
            panic!("exit");
        };
        // (the script's third read, at the close of its stdin, echoes an empty line)
        let asks = stderr.lines().filter(|l| l.contains("initialize")).count();
        assert_eq!(asks, 2, "two asks, no third: {stderr}");
    })
}

#[test]
fn v2_initialize_that_ends_the_agent_is_the_owners_to_restart() {
    saman::block_on_current(async {
        // the agent exits on the v2 ask: the connection is gone, so it is the owner that starts it again as v1
        let (conn, _rx) = start("read a; exit 3").await;
        let r = conn.initialize(ClientCaps::default()).await;
        assert!(matches!(r, Err(Error::Closed)), "{r:?}");
    })
}

// ---- v2 permission requests: `title`, `description`, `subject`, no top-level `toolCall` ----

fn permission(subject: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":70,"method":"session/request_permission","params":{{"sessionId":"s1","title":"Approve file edit?","description":"Allow the agent to edit src/main.rs?","subject":{subject},"options":[{{"optionId":"allow-once","name":"Allow once","kind":"allow_once"}},{{"optionId":"reject-once","name":"Reject","kind":"reject_once"}}]}}}}"#
    )
}

/// What the hub sees of a v2 permission request SUBJECT: the events up to the request, the request as JSON, and the
/// line the agent got back (after the answer).
async fn asked(subject: &str) -> (Vec<Event>, Value, Value) {
    let rest = format!(
        "{}; read r; echo \"$r\" >&2; cat >/dev/null",
        say(&[permission(subject)])
    );
    let (conn, mut rx) = start(&script(&rest)).await;
    open(&conn).await;
    let mut before = vec![];
    loop {
        match next(&mut rx).await {
            Event::Request(hermod::Incoming::Permission(req, resp)) => {
                let outcome = hermod::schema::v1::RequestPermissionOutcome::Selected(
                    hermod::schema::v1::SelectedPermissionOutcome::new(
                        hermod::schema::v1::PermissionOptionId::new("allow-once"),
                    ),
                );
                resp.respond(hermod::schema::v1::RequestPermissionResponse::new(outcome))
                    .unwrap();
                drop(conn);
                let Event::Exit { stderr, .. } = next(&mut rx).await else {
                    panic!("exit");
                };
                let answer: Value = serde_json::from_str(stderr.lines().next().unwrap()).unwrap();
                return (before, serde_json::to_value(&req).unwrap(), answer);
            }
            other => before.push(other),
        }
    }
}

#[test]
fn v2_permission_for_a_tool_call_subject() {
    saman::block_on_current(async {
        let subject = r#"{"type":"tool_call","toolCall":{"toolCallId":"call_1","title":"Edit src/main.rs","kind":"edit","status":"pending","rawInput":{"file_path":"/w/src/main.rs"}}}"#;
        let (before, req, answer) = asked(subject).await;
        assert_eq!(req["toolCall"]["toolCallId"], json!("call_1"));
        assert_eq!(req["toolCall"]["title"], json!("Edit src/main.rs"));
        assert_eq!(req["toolCall"]["kind"], json!("edit"));
        assert_eq!(
            req["toolCall"]["rawInput"]["file_path"],
            json!("/w/src/main.rs")
        );
        assert_eq!(req["options"].as_array().unwrap().len(), 2);
        assert_eq!(req["options"][1]["kind"], json!("reject_once"));
        // the subject's tool call is applied like a tool_call_update, before the prompt is shown: the call exists
        let created = before.iter().any(|e| {
            matches!(e,
        Event::Update { update: SessionUpdate::ToolCall(c), .. } if &*c.tool_call_id.0 == "call_1")
        });
        assert!(created, "the tool call of the subject is created first");
        // the answer goes back in v2's shape (the same outcome object)
        assert_eq!(answer["id"], json!(70));
        assert_eq!(answer["result"]["outcome"]["outcome"], json!("selected"));
        assert_eq!(answer["result"]["outcome"]["optionId"], json!("allow-once"));
    })
}

#[test]
fn v2_permission_for_a_command_subject() {
    saman::block_on_current(async {
        let subject = r#"{"type":"command","command":"cargo test","cwd":"/w","toolCallId":"call_2","terminalId":"term_1"}"#;
        let (_, req, _) = asked(subject).await;
        assert_eq!(req["toolCall"]["toolCallId"], json!("call_2"));
        assert_eq!(req["toolCall"]["kind"], json!("execute"));
        assert_eq!(req["toolCall"]["rawInput"]["command"], json!("cargo test"));
        assert_eq!(req["toolCall"]["rawInput"]["cwd"], json!("/w"));
        assert_eq!(
            req["toolCall"]["title"],
            json!("Approve file edit?"),
            "the request's title names it"
        );
    })
}

#[test]
fn v2_permission_for_a_subject_this_code_does_not_know() {
    saman::block_on_current(async {
        // a future subject type: the common prompt fields stand, with an id of the request's own
        let (_, req, _) = asked(r#"{"type":"_future","x":1}"#).await;
        assert_eq!(req["toolCall"]["title"], json!("Approve file edit?"));
        assert!(
            req["toolCall"]["toolCallId"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
        );
        assert_eq!(req["options"].as_array().unwrap().len(), 2);
    })
}
