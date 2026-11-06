use std::collections::VecDeque;

use serde_json::Value;

use super::*;

const PLAYWRIGHT_CONNECT: &str = include_str!("../../tests/data/playwright-connect.jsonl");
const CLOSE: &str = include_str!("../../tests/data/close.jsonl");
const DOWNLOADS: &str = include_str!("../../tests/data/downloads.jsonl");
const ATTACH_FAILS: &str = include_str!("../../tests/data/attach-fails.jsonl");
const REAL_FULL: &str = include_str!("../../tests/data/real-full.jsonl");
const REAL_HEADLESS_SHELL: &str = include_str!("../../tests/data/real-headless-shell.jsonl");

#[derive(Debug, PartialEq)]
enum Got {
    Browser(Value),
    Agent(Value),
    Event(BrokerEvent),
    Drop,
}

fn json_of(bytes: &[u8]) -> Value {
    assert!(!bytes.contains(&0), "a NUL in the router's output");
    serde_json::from_slice(bytes).expect("the router's output is JSON")
}

fn browser(bytes: Vec<u8>) -> Got {
    // whatever goes to the browser reads back as a CDP message with an id
    assert!(envelope::parse(&bytes, usize::MAX).unwrap().id.is_some());
    Got::Browser(json_of(&bytes))
}

fn gots(step: Step) -> Vec<Got> {
    match step {
        Step::ToBrowser(b) => vec![browser(b)],
        Step::ToAgent(a) => vec![Got::Agent(json_of(&a))],
        Step::Both { browser: b, agent } => vec![browser(b), Got::Agent(json_of(&agent))],
        Step::Drop => vec![Got::Drop],
        Step::Event(e) => vec![Got::Event(e)],
        Step::ToAgentAndEvent { agent, event } => {
            vec![Got::Agent(json_of(&agent)), Got::Event(event)]
        }
    }
}

fn event_of(v: &Value) -> BrokerEvent {
    if v == "no-browser-session" {
        return BrokerEvent::NoBrowserSession;
    }
    let d = &v["download"];
    BrokerEvent::Download {
        guid: d["guid"].as_str().unwrap().to_owned(),
        path: d["path"].as_str().unwrap().to_owned(),
    }
}

/// Plays a transcript (tests/data/*.jsonl) through a new router. Each line is one key:
/// - an input: `agent` (a message from the agent), `browser` (from the browser), `close` (the agent's websocket closed);
/// - what the input before gave, in order: `to_browser`, `to_agent` (a message, or `"same"`: the input unchanged),
///   `event`, `drop`. The lines before the first input are `Router::new`'s commands;
/// - `note`, ignored.
fn play(transcript: &str) -> Router {
    let (mut r, first) = Router::new();
    let mut pending: VecDeque<Got> = first.into_iter().map(browser).collect();
    let mut input = Value::Null;
    let mut from = "Router::new".to_owned();
    for (n, line) in transcript
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
    {
        let n = n + 1;
        let v: Value = serde_json::from_str(line).unwrap_or_else(|e| panic!("line {n}: {e}"));
        let (key, val) = v
            .as_object()
            .and_then(|o| o.iter().next())
            .unwrap_or_else(|| panic!("line {n}: empty"));
        let same = |val: &Value| {
            if val == "same" {
                input.clone()
            } else {
                val.clone()
            }
        };
        let want = match key.as_str() {
            "agent" | "browser" | "close" => {
                assert!(pending.is_empty(), "line {n}: {from} also gave {pending:?}");
                let msg = serde_json::to_vec(val).unwrap();
                pending = match key.as_str() {
                    "agent" => gots(r.from_agent(&msg)),
                    "browser" => gots(r.from_browser(&msg)),
                    _ => r.agent_closed().into_iter().map(browser).collect(),
                }
                .into();
                input = val.clone();
                from = format!("line {n}");
                continue;
            }
            "to_browser" => Got::Browser(same(val)),
            "to_agent" => Got::Agent(same(val)),
            "event" => Got::Event(event_of(val)),
            "drop" => Got::Drop,
            "note" => continue,
            other => panic!("line {n}: unknown key {other}"),
        };
        let got = pending
            .pop_front()
            .unwrap_or_else(|| panic!("line {n}: {from} gave nothing more; wanted {want:?}"));
        assert_eq!(got, want, "line {n}");
    }
    assert!(pending.is_empty(), "{from} also gave {pending:?}");
    r
}

/// A router past the attach, with the agent's browser session `S-browser` and its page `S-page`.
fn connected() -> Router {
    let mut r = play(PLAYWRIGHT_CONNECT);
    // a session the hub attached on the root (a watched page, phase 2), and its child
    r.from_browser(
        br#"{"method":"Target.attachedToTarget","params":{"sessionId":"S-hub","targetInfo":{"targetId":"T-page","type":"page"},"waitingForDebugger":false}}"#,
    );
    r.from_browser(
        br#"{"method":"Target.attachedToTarget","params":{"sessionId":"S-hub-child","targetInfo":{"targetId":"T-frame","type":"iframe"},"waitingForDebugger":false},"sessionId":"S-hub"}"#,
    );
    r
}

fn agent_value(step: Step) -> Value {
    match step {
        Step::ToAgent(a) => json_of(&a),
        other => panic!("expected a message to the agent, got {other:?}"),
    }
}

fn assert_refused(step: Step, id: u64, session: Option<&str>, code: i64, message: &str) {
    let mut want = serde_json::json!({"id": id, "error": {"code": code, "message": message}});
    if let Some(s) = session {
        want["sessionId"] = s.into();
    }
    assert_eq!(agent_value(step), want);
}

#[test]
fn agent_gets_its_browser_session() {
    let mut r = play(PLAYWRIGHT_CONNECT);
    assert!(r.ready());
    assert_eq!(r.agent_session.as_deref(), Some("S-browser"));
    for s in ["S-browser", "S-page", "S-worker"] {
        assert_eq!(r.sessions[s].owner, Owner::Agent, "{s}");
    }
    assert_eq!(r.browser_target.as_deref(), Some("T-browser"));
    // a screenshot-sized reply on the agent's browser session loses the session id and nothing else
    let data = "iVBORw0KGgo".repeat(100_000);
    let msg = format!(r#"{{"id":9,"result":{{"data":"{data}"}},"sessionId":"S-browser"}}"#);
    let Step::ToAgent(out) = r.from_browser(msg.as_bytes()) else {
        panic!("not to the agent")
    };
    assert_eq!(
        out,
        format!(r#"{{"id":9,"result":{{"data":"{data}"}}}}"#).into_bytes()
    );
}

#[test]
fn ids_never_collide_with_the_hubs() {
    let (mut r, first) = Router::new();
    assert_eq!(
        envelope::parse(&first[0], usize::MAX).unwrap().id,
        Some(HUB_ID_BASE)
    );
    let mut r2 = play(PLAYWRIGHT_CONNECT);
    // an agent id in the hub's range is refused before anything else; the one below passes
    assert_refused(
        r2.from_agent(
            format!(r#"{{"id":{HUB_ID_BASE},"method":"Page.reload","sessionId":"S-page"}}"#)
                .as_bytes(),
        ),
        HUB_ID_BASE,
        Some("S-page"),
        -32600,
        "the id is out of range",
    );
    let below = HUB_ID_BASE - 1;
    assert!(matches!(
        r2.from_agent(
            format!(r#"{{"id":{below},"method":"Page.reload","sessionId":"S-page"}}"#).as_bytes()
        ),
        Step::ToBrowser(_)
    ));
    // a reply with a hub id is the hub's even on the agent's session; with the agent's id it is the agent's
    assert_eq!(
        r2.from_browser(br#"{"id":1073741900,"result":{},"sessionId":"S-page"}"#),
        Step::Drop
    );
    assert!(matches!(
        r2.from_browser(br#"{"id":77,"result":{},"sessionId":"S-page"}"#),
        Step::ToAgent(_)
    ));
    // the hub's ids stay in Chromium's 32-bit range: they wrap back to the base
    r.next_id = HUB_ID_LAST;
    assert_eq!((r.hub_id(), r.hub_id()), (HUB_ID_LAST, HUB_ID_BASE));
}

#[test]
fn children_follow_their_parent() {
    let mut r = connected();
    assert_eq!(r.sessions["S-hub"].owner, Owner::Hub);
    assert_eq!(r.sessions["S-hub-child"].owner, Owner::Hub);
    assert_eq!(r.sessions["S-worker"].owner, Owner::Agent);
    assert_eq!(r.sessions["S-worker"].parent.as_deref(), Some("S-page"));
    // the hub's sessions' traffic never reaches the agent
    assert_eq!(
        r.from_browser(
            br#"{"method":"Page.frameNavigated","params":{},"sessionId":"S-hub-child"}"#
        ),
        Step::Drop
    );
    assert_eq!(
        r.from_browser(br#"{"id":3,"result":{},"sessionId":"S-hub"}"#),
        Step::Drop
    );
    // an attach on a session nobody knows is not taken up
    assert_eq!(
        r.from_browser(br#"{"method":"Target.attachedToTarget","params":{"sessionId":"S-x","targetInfo":{"targetId":"T-x","type":"page"},"waitingForDebugger":false},"sessionId":"S-unknown"}"#),
        Step::Drop
    );
    assert!(!r.sessions.contains_key("S-x"));
    // an attach event cannot take over a session that exists: the first owner stays
    let step = r.from_browser(
        br#"{"method":"Target.attachedToTarget","params":{"sessionId":"S-hub","targetInfo":{"targetId":"T-page","type":"page"},"waitingForDebugger":false},"sessionId":"S-page"}"#,
    );
    assert!(matches!(step, Step::ToAgent(_)));
    assert_eq!(r.sessions["S-hub"].owner, Owner::Hub);
    // a detach takes the session and everything under it
    r.from_browser(br#"{"method":"Target.detachedFromTarget","params":{"sessionId":"S-hub","targetId":"T-page"}}"#);
    assert!(!r.sessions.contains_key("S-hub") && !r.sessions.contains_key("S-hub-child"));
}

#[test]
fn agent_cannot_detach_or_close_hub_sessions() {
    let mut r = connected();
    let not_yours: [(&str, Option<&str>); 9] = [
        (
            r#"{"id":1,"method":"Target.detachFromTarget","params":{"sessionId":"S-hub"}}"#,
            None,
        ),
        (
            r#"{"id":1,"method":"Target.detachFromTarget","params":{"sessionId":"S-hub-child"}}"#,
            None,
        ),
        (
            r#"{"id":1,"method":"Target.closeTarget","params":{"targetId":"T-browser"}}"#,
            None,
        ),
        (
            r#"{"id":1,"method":"Target.detachFromTarget","params":{"targetId":"T-browser"}}"#,
            None,
        ),
        (
            r#"{"id":1,"method":"Target.attachToTarget","params":{"targetId":"T-browser","flatten":true}}"#,
            None,
        ),
        (
            r#"{"id":1,"method":"Target.detachFromTarget","params":{"sessionId":"S-nobody"}}"#,
            None,
        ),
        // on a hub session, or on one nobody has
        (
            r#"{"id":1,"method":"Runtime.evaluate","params":{"expression":"1"},"sessionId":"S-hub"}"#,
            Some("S-hub"),
        ),
        (
            r#"{"id":1,"method":"Page.close","sessionId":"S-hub-child"}"#,
            Some("S-hub-child"),
        ),
        (
            r#"{"id":1,"method":"Page.close","sessionId":"S-nobody"}"#,
            Some("S-nobody"),
        ),
    ];
    for (msg, session) in not_yours {
        assert_refused(
            r.from_agent(msg.as_bytes()),
            1,
            session,
            -32000,
            "not yours",
        );
    }
    // its own sessions and targets are its own
    for msg in [
        r#"{"id":2,"method":"Target.detachFromTarget","params":{"sessionId":"S-worker"}}"#,
        r#"{"id":2,"method":"Target.closeTarget","params":{"targetId":"T-page"}}"#,
        r#"{"id":2,"method":"Target.createTarget","params":{"url":"about:blank"}}"#,
        r#"{"id":2,"method":"Page.navigate","params":{"url":"http://127.0.0.1:5173/"},"sessionId":"S-page"}"#,
    ] {
        assert!(
            matches!(r.from_agent(msg.as_bytes()), Step::ToBrowser(_)),
            "{msg}"
        );
    }
}

#[test]
fn refused_methods_get_an_error_reply() {
    let mut r = play(PLAYWRIGHT_CONNECT);
    for entry in REFUSED_ALWAYS {
        let method = if entry.ends_with('.') {
            format!("{entry}anything")
        } else {
            (*entry).to_owned()
        };
        for session in [None, Some("S-page")] {
            let msg = match session {
                None => format!(r#"{{"id":4,"method":"{method}","params":{{}}}}"#),
                Some(s) => {
                    format!(r#"{{"id":4,"method":"{method}","params":{{}},"sessionId":"{s}"}}"#)
                }
            };
            assert_refused(
                r.from_agent(msg.as_bytes()),
                4,
                session,
                -32601,
                "refused by drgnx",
            );
        }
    }
    for method in [
        "Browser.getVersion",
        "Browser.closeX",
        "TetheringX.bind",
        "Target.getTargets",
        "Page.crash",
    ] {
        let msg = format!(r#"{{"id":5,"method":"{method}"}}"#);
        assert!(
            matches!(r.from_agent(msg.as_bytes()), Step::ToBrowser(_)),
            "{method}"
        );
    }
}

#[test]
fn download_behavior_is_answered_and_replaced() {
    let mut r = play(DOWNLOADS);
    // without a context, the router's own has none either; sent with a session id, it is still set on the root, and
    // the agent's own behaviour (here deny) is never passed on
    let step = r.from_agent(br#"{"id":6,"method":"Browser.setDownloadBehavior","params":{"behavior":"deny"},"sessionId":"S-browser"}"#);
    let Step::Both { browser, agent } = step else {
        panic!("not a message to each")
    };
    assert_eq!(
        json_of(&browser),
        serde_json::json!({"id": 1073741826, "method": "Browser.setDownloadBehavior",
                           "params": {"behavior": "allowAndName", "downloadPath": DOWNLOAD_DIR, "eventsEnabled": true}})
    );
    assert_eq!(
        json_of(&agent),
        serde_json::json!({"id": 6, "result": {}, "sessionId": "S-browser"})
    );
    assert_refused(
        r.from_agent(
            br#"{"id":7,"method":"Browser.setDownloadBehavior","params":{"browserContextId":3}}"#,
        ),
        7,
        None,
        -32602,
        "invalid params",
    );
}

#[test]
fn close_detaches_and_resumes_paused_targets() {
    let r = play(CLOSE);
    assert!(r.ready());
    assert_eq!(r.agent_session.as_deref(), Some("S-browser-2"));
    // a second close before the new attach is answered asks for no second attach
    let (mut r, _) = Router::new();
    r.from_browser(br#"{"id":1073741824,"result":{"sessionId":"S-b"}}"#);
    assert_eq!(r.agent_closed().len(), 2);
    assert!(!r.ready());
    assert_eq!(r.agent_closed(), Vec::<Vec<u8>>::new());
}

#[test]
fn attach_failure_falls_back_to_root() {
    let r = play(ATTACH_FAILS);
    assert!(r.ready() && r.fallback);
    assert!(r.agent_session.is_none());
    // a reply without a session id counts as a failure too
    let (mut r, _) = Router::new();
    assert_eq!(
        r.from_browser(br#"{"id":1073741824,"result":{}}"#),
        Step::Event(BrokerEvent::NoBrowserSession)
    );
}

/// In the fallback the agent owns the root, so a reply there that arrives after its agent has gone would reach the
/// next one: the router drops the first reply of each id the gone agent left unanswered.
#[test]
fn a_gone_agents_late_root_reply_never_reaches_the_next() {
    let (mut r, _) = Router::new();
    r.from_browser(br#"{"id":1073741824,"error":{"code":-32000,"message":"no"}}"#);
    assert!(r.fallback);
    let cmd = |id: u64| format!(r#"{{"id":{id},"method":"Page.navigate","params":{{}}}}"#);
    let reply = |id: u64| format!(r#"{{"id":{id},"result":{{}}}}"#);
    assert!(matches!(
        r.from_agent(cmd(5).as_bytes()),
        Step::ToBrowser(_)
    ));
    assert!(matches!(
        r.from_agent(cmd(7).as_bytes()),
        Step::ToBrowser(_)
    ));
    assert!(matches!(
        r.from_browser(reply(5).as_bytes()),
        Step::ToAgent(_)
    ));
    r.agent_closed();
    // the next agent reuses 7 before the old 7 is answered: the first 7 is the old one's
    assert!(matches!(
        r.from_agent(cmd(7).as_bytes()),
        Step::ToBrowser(_)
    ));
    assert_eq!(r.from_browser(reply(7).as_bytes()), Step::Drop);
    assert!(matches!(
        r.from_browser(reply(7).as_bytes()),
        Step::ToAgent(_)
    ));
    // 5 was answered before the agent went: a reply 5 now is the new agent's (or nobody's) as usual
    assert!(matches!(
        r.from_browser(reply(5).as_bytes()),
        Step::ToAgent(_)
    ));
}

/// The browser side of real runs (drgnx-ratatoskr's tests/browser_real.rs, Fedora's Chromium as the full browser and
/// as its headless shell): the router's first command is the one the broker sent there, and everything the browser
/// said goes through a router as well-formed output (the agent side is not recorded, so its answers are not checked).
#[test]
fn real_recordings_go_through_the_router() {
    for (name, rec) in [("full", REAL_FULL), ("headless-shell", REAL_HEADLESS_SHELL)] {
        let lines: Vec<Value> = rec
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{name}: {e}")))
            .collect();
        let (mut r, first) = Router::new();
        let sent = lines.iter().find_map(|v| v.get("to_browser"));
        assert_eq!(first.first().map(|b| json_of(b)).as_ref(), sent, "{name}");
        let mut n = 0;
        for m in lines.iter().filter_map(|v| v.get("browser")) {
            gots(r.from_browser(&serde_json::to_vec(m).unwrap()));
            n += 1;
        }
        assert!(n > 100, "{name}: only {n} browser messages");
    }
}
