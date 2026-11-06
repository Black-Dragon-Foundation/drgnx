//! The Codex personality (codex-acp): `resume, list, close, fork`, `-c key=value` overrides in argv (logged), forks
//! at a turn (a message id keeps its whole turn), `usage_update {used,size}` and a rate-limit window.

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({"resume": {}, "list": {}, "close": {}, "fork": {}})
}

/// The `-c key=value` pairs of argv, as the strings after each `-c`.
pub fn overrides(argv: &[String]) -> Vec<String> {
    argv.windows(2)
        .filter(|w| w[0] == "-c")
        .map(|w| w[1].clone())
        .collect()
}

pub fn after_turn(sid: &str, turn: u64, prompt_len: usize) -> Vec<(&'static str, Value)> {
    vec![
        (
            "session/update",
            json!({"sessionId": sid, "update": {"sessionUpdate": "usage_update",
                "used": 800 * turn + prompt_len as u64, "size": 258_400}}),
        ),
        (
            "_codex/rateLimits",
            json!({"sessionId": sid, "primary": {"usedPercent": 42.0, "windowMinutes": 300,
                "resetsAt": 4_102_444_800u64}}),
        ),
    ]
}

/// The `tool_call` fields codex-acp sends for WHAT (see the Claude personality): parsed reads and searches are kind
/// `read`/`search` with a path and no line; a web search is kind `fetch` with `rawInput {query, action}`.  No tool name.
pub fn tool_shape(what: &str, arg: &str) -> Option<Value> {
    let file = arg.split_whitespace().next().unwrap_or("");
    Some(match what {
        "read" => {
            json!({"title": format!("Read {file}"), "kind": "read", "locations": [{"path": file}]})
        }
        "grep" => {
            json!({"title": format!("Search {arg}"), "kind": "search", "rawInput": {"query": arg}})
        }
        "web-search" => json!({"title": "Searching the web", "kind": "fetch",
            "rawInput": {"query": arg, "action": {"type": "search", "query": arg}}}),
        "web-fetch" => json!({"title": "Opening a page", "kind": "fetch",
            "rawInput": {"action": {"type": "open_page", "url": arg}}}),
        "write" => {
            json!({"title": format!("Edit {arg}"), "kind": "edit", "locations": [{"path": arg}]})
        }
        _ => return None,
    })
}
