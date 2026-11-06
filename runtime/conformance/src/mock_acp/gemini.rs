//! The Gemini personality (gemini --acp): `loadSession` only.  No list, fork, resume or close (they answer -32601),
//! no usage or rate-limit notices.

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({})
}

pub fn after_turn(_sid: &str, _turn: u64, _prompt_len: usize) -> Vec<(&'static str, Value)> {
    Vec::new()
}

/// What `session/new` and `session/load` log for Gemini: nothing the CLI reads is advertised.
pub fn note() -> Value {
    json!({"gemini": "loadSession only"})
}

/// The `tool_call` fields of an edit of PATH: a title, a kind and `locations`, and no `rawInput`.
pub fn edit_shape(path: &str) -> Value {
    json!({"title": path, "kind": "edit", "locations": [{"path": path}]})
}

/// The `tool_call` fields Gemini CLI sends for WHAT (see the Claude personality): a title, a kind and, for files,
/// `locations`; no tool name and no `rawInput`, so the query or URL is only in the title.
pub fn tool_shape(what: &str, arg: &str) -> Option<Value> {
    let file = arg.split_whitespace().next().unwrap_or("");
    Some(match what {
        "read" => json!({"title": file, "kind": "read", "locations": [{"path": file}]}),
        "grep" => json!({"title": format!("grep_search: \"{arg}\""), "kind": "search"}),
        "web-search" => json!({"title": format!("google_web_search: \"{arg}\""), "kind": "fetch"}),
        "web-fetch" => json!({"title": format!("web_fetch {arg}"), "kind": "fetch"}),
        "write" => json!({"title": arg, "kind": "edit", "locations": [{"path": arg}]}),
        _ => return None,
    })
}
