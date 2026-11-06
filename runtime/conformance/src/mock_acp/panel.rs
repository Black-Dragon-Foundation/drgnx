//! `--panel FEATURES` (a comma list: `context,drop,pin,compact-preview,before-tool`, any names): the personality speaks
//! drgnx's `_drgnx/panel` extension, as the org's adapter forks do. `initialize` advertises
//! `agentCapabilities._meta["_drgnx/panel"] = {version: 1, features}`; the client's `_drgnx/context/drop|pin` and
//! `_drgnx/compact/preview` are answered (and logged as `{"panel": {method, params}}`), and these words run in a turn:
//!
//! | line | what the turn does |
//! |---|---|
//! | `panel:context JSON` | the notification `_drgnx/context` with JSON (its `sessionId` added) |
//! | `panel:contexts N` | N breakdowns at once, `used` 1 to N |
//! | `panel:before-tool JSON` | the request `_drgnx/before_tool {sessionId, toolCall: JSON}` (its `toolCallId` added); says and logs `before-tool: ANSWER` (`{"before_tool": ANSWER}`), ANSWER the result or the error |
//! | `panel:big N` | a `_drgnx/before_tool` whose command is N bytes |
//! | `panel:raw METHOD JSON` | the request METHOD with JSON as its params, as it is; says and logs the answer the same way |
//! | `panel:preview JSON` | the next `_drgnx/compact/preview` is answered JSON (else a fixed preview) |

use super::{Agent, send};
use serde_json::{Value, json};
use std::sync::Mutex;

/// What the next compaction preview answers, when a turn set it.
static NEXT_PREVIEW: Mutex<Option<Value>> = Mutex::new(None);

/// `--panel`'s features, when the flag is there.
fn features(argv: &[String]) -> Option<Vec<String>> {
    let i = argv.iter().position(|a| a == "--panel")?;
    let list = argv.get(i + 1)?;
    Some(
        list.split(',')
            .filter(|f| !f.is_empty())
            .map(str::to_owned)
            .collect(),
    )
}

/// The `agentCapabilities._meta` of `initialize` (none without `--panel`).
pub(super) fn caps_meta(argv: &[String]) -> Option<Value> {
    features(argv).map(|f| json!({"_drgnx/panel": {"version": 1, "features": f}}))
}

/// The client's request METHOD (`_drgnx/*`) with PARAMS, answered as id ID.
pub(super) fn answer(a: &mut Agent, id: &Value, method: &str, params: &Value) {
    a.log("panel", json!({"method": method, "params": params}));
    let result = match method {
        "_drgnx/context/drop" | "_drgnx/context/pin" => json!({}),
        "_drgnx/compact/preview" => NEXT_PREVIEW
            .lock()
            .unwrap()
            .take()
            .unwrap_or_else(|| {
                json!({"frees": 1200, "kept": [{"id": "f1", "label": "src/a.rs", "tokens": 300}],
                       "summarised": [{"id": "t3", "label": "Bash ls", "tokens": 1200}], "note": "no model call"})
            }),
        _ => return super::rpc_error(id, -32601, &format!("method not found: {method}")),
    };
    send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

/// One `panel:WHAT REST` word of a turn.
pub(super) fn word(a: &mut Agent, sid: &str, turn: u64, what: &str, rest: &str) {
    let parsed = || serde_json::from_str::<Value>(rest).unwrap_or(json!({}));
    match what {
        "context" => {
            let mut p = parsed();
            p["sessionId"] = json!(sid);
            send(&json!({"jsonrpc": "2.0", "method": "_drgnx/context", "params": p}));
        }
        "contexts" => {
            let n: u64 = rest.parse().unwrap_or(1);
            for used in 1..=n {
                send(
                    &json!({"jsonrpc": "2.0", "method": "_drgnx/context", "params": {"sessionId": sid,
                    "used": used, "size": 200_000, "parts": [{"kind": "conversation", "tokens": used}]}}),
                );
            }
        }
        "before-tool" | "big" => {
            let mut call = if what == "big" {
                let n: usize = rest.parse().unwrap_or(0);
                json!({"title": "big", "kind": "execute", "rawInput": {"command": "x".repeat(n)}})
            } else {
                parsed()
            };
            let tid = format!("tc-{turn}-{}", a.next_out_id);
            a.next_out_id += 1;
            call["toolCallId"] = json!(tid);
            ask(
                a,
                sid,
                turn,
                "_drgnx/before_tool",
                json!({"sessionId": sid, "toolCall": call}),
            );
        }
        "raw" => {
            let (method, json) = rest.split_once(char::is_whitespace).unwrap_or((rest, "{}"));
            let p = serde_json::from_str(json.trim()).unwrap_or(json!({}));
            ask(a, sid, turn, method, p);
        }
        "preview" => *NEXT_PREVIEW.lock().unwrap() = Some(parsed()),
        _ => a.say(sid, turn, &format!("no panel word {what}\n")),
    }
}

/// The request METHOD with PARAMS to the client; its answer said and logged.
fn ask(a: &mut Agent, sid: &str, turn: u64, method: &str, params: Value) {
    let rid = a.request(method, params);
    let answer = a
        .response(rid)
        .map_or(json!("no answer"), |r| match r.get("error") {
            Some(e) => json!({"error": e}),
            None => r["result"].clone(),
        });
    a.log("before_tool", answer.clone());
    a.say(sid, turn, &format!("before-tool: {answer}\n"));
}
