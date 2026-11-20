//! The background model (`background.rs`) and how a session keeps it: snapshots, terminals, ends, the cancel gate.

use super::background::*;
use super::{EntryType, State};
use hermod::{BackgroundRef, MessageKind, RunState, SessionId, TerminalEv};
use runstav::methods::agents::{
    BackgroundEndStatus as EndStatus, BackgroundKind, BackgroundStatus,
};
use serde_json::json;

fn term(id: &str) -> BackgroundRef {
    BackgroundRef::Terminal(id.into())
}

fn terminal_exit(k: &mut Known, id: &str, code: Option<i32>, signal: Option<&str>) {
    k.terminals.update(
        id,
        TerminalEv::Update {
            command: None,
            cwd: None,
            snapshot: None,
            exit: Some((code, signal.map(String::from))),
            can_cancel: Some(false),
        },
        0,
    );
}

fn started(k: &mut Known, id: &str, command: &str) {
    k.terminals.update(
        id,
        TerminalEv::Update {
            command: Some(command.into()),
            cwd: Some("/w".into()),
            snapshot: None,
            exit: None,
            can_cancel: Some(true),
        },
        1000,
    );
}

fn ids(b: &Background) -> Vec<String> {
    b.items.iter().flatten().map(|i| i.id.clone()).collect()
}

// [C] not reported is not "nothing running".
#[test]
fn snapshot_none_vs_empty() {
    let k = Known::default();
    let mut b = Background::default();
    assert!(b.items.is_none(), "a session starts with none reported");
    b.apply_snapshot(Some(vec![]), |r| k.item(r));
    assert_eq!(b.items, Some(vec![]));
    b.apply_snapshot(None, |r| k.item(r));
    assert_eq!(b.items, None, "an omitted list is not an empty one");
}

// Review focus 5: a resumed session's first snapshot replaces the stale list wholesale.
#[test]
fn background_snapshot_replaces_on_resume() {
    let mut k = Known::default();
    started(&mut k, "a", "sleep 100");
    started(&mut k, "b", "sleep 200");
    started(&mut k, "c", "make");
    let mut b = Background::default();
    b.apply_snapshot(Some(vec![term("a"), term("b")]), |r| k.item(r));
    assert_eq!(ids(&b), ["a", "b"]);
    b.apply_snapshot(Some(vec![term("c")]), |r| k.item(r));
    assert_eq!(ids(&b), ["c"], "replaced, not merged");
}

#[test]
fn ended_item_keeps_exit_code() {
    let mut k = Known::default();
    started(&mut k, "t1", "cargo test");
    let mut b = Background::default();
    b.apply_snapshot(Some(vec![term("t1")]), |r| k.item(r));
    let i = &b.items.as_ref().unwrap()[0];
    assert_eq!(i.description, "cargo test");
    assert_eq!(i.started_ms, 1000);
    assert!(i.can_cancel && i.end.is_none());
    terminal_exit(&mut k, "t1", Some(3), None);
    b.apply_snapshot(Some(vec![]), |r| k.item(r));
    let e = b.ended.back().expect("it ended");
    let end = e.end.as_ref().expect("with an end");
    assert_eq!(end.status, EndStatus::Failed);
    assert_eq!(end.exit_code, Some(3));
    assert_eq!(e.description, "cargo test");
    assert!(!e.can_cancel, "an exited terminal cannot be cancelled");
}

#[test]
fn exit_zero_completes_and_a_stop_signal_stops() {
    let mut k = Known::default();
    started(&mut k, "ok", "true");
    started(&mut k, "sig", "sleep 9");
    terminal_exit(&mut k, "ok", Some(0), None);
    terminal_exit(&mut k, "sig", None, Some("SIGTERM"));
    let ok = k.item(&term("ok")).end.unwrap();
    assert_eq!((ok.status, ok.exit_code), (EndStatus::Completed, Some(0)));
    assert_eq!(k.item(&term("sig")).end.unwrap().status, EndStatus::Stopped);
}

#[test]
fn unknown_state_marks_items_unknown() {
    let mut st = State::new();
    st.on_terminal(
        "a",
        TerminalEv::Update {
            command: Some("x".into()),
            cwd: None,
            snapshot: None,
            exit: None,
            can_cancel: Some(true),
        },
        1000,
    );
    st.on_state(RunState::Idle(None), Some(vec![term("a")]));
    assert_eq!(
        st.bg.items.as_ref().unwrap()[0].status,
        BackgroundStatus::Running
    );
    st.on_state(RunState::Unknown, Some(vec![term("a")]));
    assert_eq!(
        st.bg.items.as_ref().unwrap()[0].status,
        BackgroundStatus::Unknown,
        "unobservable is not running and not done"
    );
    // an output line is not the agent's word that it observes again
    st.on_terminal("a", TerminalEv::Chunk(b"hi\n".to_vec()), 2000);
    assert_eq!(
        st.bg.items.as_ref().unwrap()[0].status,
        BackgroundStatus::Unknown
    );
    // the next state is
    st.on_state(RunState::Running, Some(vec![term("a")]));
    let i = &st.bg.items.as_ref().unwrap()[0];
    assert_eq!(i.status, BackgroundStatus::Running);
    assert_eq!(i.progress.as_deref(), Some("hi"), "the last output line");
}

// Review focus 4: chunks are bytes joined in order (a UTF-8 sequence may split between them); over the cap the
// newest bytes stay.
#[test]
fn terminal_chunks_join_bytes_then_cap() {
    let mut t = Terminals::default();
    t.chunk("t", &[b'h', 0xc3], 0);
    t.chunk("t", &[0xa9, b'y'], 0);
    assert_eq!(
        String::from_utf8(t.get("t").unwrap().bytes.clone()).unwrap(),
        "héy"
    );
    let mut t = Terminals::default();
    t.chunk("t", &vec![b'a'; TERMINAL_CAP], 0);
    t.chunk("t", b"newest", 0);
    let bytes = &t.get("t").unwrap().bytes;
    assert_eq!(bytes.len(), TERMINAL_CAP);
    assert!(bytes.ends_with(b"newest"), "the newest bytes are kept");
    // a snapshot replaces what was kept, later chunks append to it
    t.update(
        "t",
        TerminalEv::Update {
            command: None,
            cwd: None,
            snapshot: Some(b"fresh".to_vec()),
            exit: None,
            can_cancel: None,
        },
        0,
    );
    t.chunk("t", b"+more", 0);
    assert_eq!(t.get("t").unwrap().bytes, b"fresh+more");
}

#[test]
fn ended_capped_at_20() {
    let mut k = Known::default();
    let mut b = Background::default();
    for n in 0..25 {
        let id = format!("t{n}");
        started(&mut k, &id, &id);
        b.apply_snapshot(Some(vec![term(&id)]), |r| k.item(r));
    }
    b.apply_snapshot(Some(vec![]), |r| k.item(r));
    assert_eq!(b.ended.len(), ENDED_CAP);
    assert_eq!(b.ended.back().unwrap().id, "t24");
    assert_eq!(b.ended.front().unwrap().id, "t5", "the oldest went");
}

#[test]
fn tool_calls_and_children_are_items() {
    let mut k = Known::default();
    k.tool(
        &json!({"toolCallId": "m1", "title": "Monitor logs", "status": "in_progress",
            "_meta": {"_hermod/status": "paused", "_hermod/can_cancel": true},
            "content": [{"type": "content", "content": {"type": "text", "text": "a\nlast line\n"}}]}),
        5000,
    );
    k.subagent(
        &json!({"sessionId": "k1", "title": "review", "capabilities": {"cancel": {}}}),
        6000,
    );
    k.child_state("k1", &RunState::Running);
    let m = k.item(&BackgroundRef::ToolCall("m1".into()));
    assert_eq!(m.kind, BackgroundKind::ToolCall);
    assert_eq!(
        m.status,
        BackgroundStatus::Paused,
        "the agent's own status, not v1's"
    );
    assert_eq!(m.progress.as_deref(), Some("last line"));
    assert!(m.can_cancel);
    let c = k.item(&BackgroundRef::Subagent(SessionId::new("k1".to_string())));
    assert_eq!((c.description.as_str(), c.can_cancel), ("review", true));
    assert_eq!(c.status, BackgroundStatus::Running);
    assert!(k.is_child("k1") && !k.is_child("k2"));
    // it ends: a final status on the call
    k.tool(
        &json!({"toolCallId": "m1", "_meta": {"_hermod/status": "completed"}}),
        7000,
    );
    let m = k.item(&BackgroundRef::ToolCall("m1".into()));
    assert_eq!(m.end.unwrap().status, EndStatus::Completed);
    assert!(!m.can_cancel);
    // an unknown reference is listed, as unknown: it still counts
    let o = k.item(&BackgroundRef::Other(json!({"type": "_weird"})));
    assert_eq!(o.status, BackgroundStatus::Unknown);
}

// [C] a v1 session never reports background work: none, not an empty list.
#[test]
fn v1_session_has_no_background() {
    let mut st = State::new();
    st.apply(&json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run", "status": "in_progress"}));
    st.apply(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"}),
    );
    assert!(st.bg.items.is_none());
    assert!(st.background_view(vec![]).is_none());
    assert!(st.bg.ended.is_empty());
}

// drgnx's own jobs (`exec/start`) are items of the same list, cancellable, whatever the agent reports.
#[test]
fn own_jobs_are_background_items() {
    let j = job_item("job-7", "cargo test -p x", 4000);
    assert_eq!(j.kind, BackgroundKind::Terminal);
    assert_eq!(
        (j.id.as_str(), j.description.as_str()),
        ("job-7", "cargo test -p x")
    );
    assert!(j.can_cancel && j.end.is_none());
    assert_eq!(j.started_ms, 4000);
    let mut st = State::new();
    // nothing reported by the agent: the jobs alone are the list
    let v = st.background_view(vec![j.clone()]).expect("a list");
    assert_eq!(ids_of(&v), ["job-7"]);
    // beside what the agent reports
    st.on_state(RunState::Idle(None), Some(vec![]));
    st.on_terminal(
        "t1",
        TerminalEv::Update {
            command: Some("make".into()),
            cwd: None,
            snapshot: None,
            exit: None,
            can_cancel: Some(true),
        },
        1,
    );
    st.on_state(RunState::Idle(None), Some(vec![term("t1")]));
    let v = st.background_view(vec![j]).unwrap();
    assert_eq!(ids_of(&v), ["t1", "job-7"]);
}

fn ids_of(v: &[runstav::methods::agents::BackgroundItem]) -> Vec<&str> {
    v.iter().map(|i| i.id.as_str()).collect()
}

fn item(kind: BackgroundKind, can_cancel: bool) -> runstav::methods::agents::BackgroundItem {
    runstav::methods::agents::BackgroundItem {
        kind,
        id: "x".into(),
        description: "x".into(),
        started_ms: 0,
        progress: None,
        status: BackgroundStatus::Running,
        end: None,
        can_cancel,
    }
}

// `agents/background-cancel` routes by kind: a terminal, a tool call, a child session, or one of drgnx's own jobs.
#[test]
fn background_cancel_routes_by_kind() {
    let r = |k, own| route_cancel(&item(k, true), own).unwrap();
    assert_eq!(
        r(BackgroundKind::Terminal, false),
        Route::Terminal("x".into())
    );
    assert_eq!(
        r(BackgroundKind::ToolCall, false),
        Route::ToolCall("x".into())
    );
    assert_eq!(
        r(BackgroundKind::Subagent, false),
        Route::Subagent("x".into())
    );
    assert_eq!(
        r(BackgroundKind::Terminal, true),
        Route::Job("x".into()),
        "a job of the hub's own"
    );
}

// The gate: an item that does not (or no longer does) advertise cancel is never sent a cancel.
#[test]
fn background_cancel_refuses_not_cancellable() {
    for k in [
        BackgroundKind::Terminal,
        BackgroundKind::ToolCall,
        BackgroundKind::Subagent,
    ] {
        for own in [false, true] {
            assert_eq!(
                route_cancel(&item(k, false), own),
                Err(Refusal::NotCancellable),
                "{k:?} own={own}"
            );
        }
    }
    let mut ended = item(BackgroundKind::Terminal, true);
    ended.end = Some(runstav::methods::agents::BackgroundEnd {
        status: EndStatus::Completed,
        summary: None,
        exit_code: Some(0),
    });
    assert_eq!(route_cancel(&ended, false), Err(Refusal::NotCancellable));
}

// A whole-message upsert replaces the entry's text; later chunks of the message append to the replaced text.
#[test]
fn replace_swaps_a_messages_text() {
    let mut st = State::new();
    let chunk = |t: &str| json!({"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": t}});
    st.apply(&chunk("he"));
    st.apply(&chunk("llo"));
    st.replace_message(
        MessageKind::Agent,
        "m1",
        &json!([{"type": "text", "text": "whole"}]),
    );
    let agent: Vec<_> = st
        .entries
        .iter()
        .filter(|e| e.kind == EntryType::Agent)
        .collect();
    assert_eq!(agent.len(), 1);
    assert_eq!(agent[0].rest["text"], "whole");
    assert_eq!(agent[0].rest["length"], 5);
    st.apply(&chunk("!"));
    let last = st
        .entries
        .iter()
        .rfind(|e| e.kind == EntryType::Agent)
        .unwrap();
    assert_eq!(last.rest["text"], "whole!");
    // a message the hub has not seen is added
    st.replace_message(
        MessageKind::Thought,
        "t9",
        &json!([{"type": "text", "text": "hm"}]),
    );
    assert!(
        st.entries
            .iter()
            .any(|e| e.kind == EntryType::Thought && e.rest["text"] == "hm")
    );
    // null clears it
    st.replace_message(MessageKind::Thought, "t9", &json!(null));
    let t = st
        .entries
        .iter()
        .rfind(|e| e.kind == EntryType::Thought)
        .unwrap();
    assert_eq!(t.rest["text"], "");
}

// v2 reports the user's own prompt back as `user_message`: it is the entry the turn already made, not a second one.
#[test]
fn the_echo_of_the_prompt_is_the_turns_own_entry() {
    let mut st = State::new();
    st.text(EntryType::User, "hello", None);
    st.replace_message(
        MessageKind::User,
        "u1",
        &json!([{"type": "text", "text": "hello"}]),
    );
    let users: Vec<_> = st
        .entries
        .iter()
        .filter(|e| e.kind == EntryType::User)
        .collect();
    assert_eq!(users.len(), 1, "no duplicate");
    assert_eq!(
        users[0].rest["messageId"], "u1",
        "it carries the agent's id now"
    );
    assert_eq!(users[0].rest["text"], "hello");
}
