//! The Claude personality (what claude-agent-acp advertises and sends): `close, fork, list, resume`, forks at a
//! message, reads `_meta.claudeCode.options` and logs them, `usage_update {used,size,cost}` and `_claude/rateLimit`.

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({"close": {}, "fork": {}, "list": {}, "resume": {}})
}

/// The options the client put in `_meta.claudeCode.options` (null when absent).
pub fn options(params: &Value) -> Value {
    params
        .pointer("/_meta/claudeCode/options")
        .cloned()
        .unwrap_or(Value::Null)
}

/// The notifications that follow a turn: `(method, params)`; the usage update is a `session/update`.
pub fn after_turn(sid: &str, turn: u64, prompt_len: usize) -> Vec<(&'static str, Value)> {
    vec![
        (
            "session/update",
            json!({"sessionId": sid, "update": {"sessionUpdate": "usage_update",
                "used": 1000 * turn + prompt_len as u64, "size": 200_000,
                "cost": {"amount": 0.01 * turn as f64, "currency": "USD"}}}),
        ),
        (
            "_claude/rateLimit",
            json!({"sessionId": sid, "status": "allowed_warning", "rateLimitType": "five_hour",
                "utilization": 0.8, "resetsAt": 4_102_444_800u64}),
        ),
    ]
}

/// The `tool_call` fields claude-agent-acp sends for WHAT (`read FILE [OFFSET LIMIT]`, `grep PATTERN`,
/// `web-search QUERY`, `web-fetch URL`, `write FILE`), with the tool name in `_meta.claudeCode.toolName`: a `Read` has
/// `locations [{path, line}]` and the end line only from `limit`, a `Grep` has no `locations`, and `WebSearch` is
/// kind `fetch` like `WebFetch`.
pub fn tool_shape(what: &str, arg: &str) -> Option<Value> {
    let meta = |name: &str| json!({"claudeCode": {"toolName": name}});
    Some(match what {
        "read" => {
            let mut w = arg.split_whitespace();
            let file = w.next().unwrap_or("");
            let offset: Option<u64> = w.next().and_then(|n| n.parse().ok());
            let limit: Option<u64> = w.next().and_then(|n| n.parse().ok());
            let mut raw = json!({"file_path": file});
            if let Some(o) = offset {
                raw["offset"] = json!(o);
            }
            if let Some(l) = limit {
                raw["limit"] = json!(l);
            }
            json!({"title": format!("Read {file}"), "kind": "read",
                "locations": [{"path": file, "line": offset.unwrap_or(1)}],
                "rawInput": raw, "_meta": meta("Read")})
        }
        "grep" => json!({"title": format!("grep \"{arg}\" ."), "kind": "search",
            "rawInput": {"pattern": arg, "path": "."}, "_meta": meta("Grep")}),
        "web-search" => json!({"title": arg, "kind": "fetch",
            "rawInput": {"query": arg}, "_meta": meta("WebSearch")}),
        "web-fetch" => json!({"title": format!("Fetch {arg}"), "kind": "fetch",
            "rawInput": {"url": arg}, "_meta": meta("WebFetch")}),
        "write" => json!({"title": format!("Write {arg}"), "kind": "edit",
            "locations": [{"path": arg}],
            "rawInput": {"file_path": arg, "content": "written by the mock\n"}, "_meta": meta("Write")}),
        _ => return None,
    })
}
