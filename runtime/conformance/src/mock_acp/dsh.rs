//! The DeepSeek Harness personality (`dsh --profile acp`): `list, resume, close` only (no load, fork or modes).  Every
//! `tool_call` is kind `other` with its snake-case tool name as the title, and a permission request carries the tool
//! call's id only.  Its tools obey the overlay `--patch FILE` gives as the drgnx ask plugin would: a tool of a kind
//! its `kinds: [...]` line names asks, when the overlay also keeps `policy: ask`; any other tool runs without asking.

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({"list": {}, "resume": {}, "close": {}})
}

/// The overlay of ARGV's `--patch FILE`.
fn overlay(argv: &[String]) -> Option<String> {
    let i = argv.iter().position(|a| a == "--patch")?;
    std::fs::read_to_string(argv.get(i + 1)?).ok()
}

/// The overlay's `policy` and `kinds`.
fn read(argv: &[String]) -> (Option<String>, Vec<String>) {
    let Some(text) = overlay(argv) else {
        return (None, Vec::new());
    };
    let policy = text
        .lines()
        .find_map(|l| l.trim().strip_prefix("policy: "))
        .map(str::to_owned);
    let kinds = text
        .lines()
        .find_map(|l| l.trim().strip_prefix("kinds: ["))
        .and_then(|l| l.strip_suffix(']'))
        .map(|l| {
            l.split(',')
                .map(|k| k.trim().to_owned())
                .filter(|k| !k.is_empty())
                .collect()
        })
        .unwrap_or_default();
    (policy, kinds)
}

/// What `session/new` logs for DeepSeek Harness: the overlay's `policy` and `kinds`.
pub fn note(argv: &[String]) -> Value {
    let (policy, kinds) = read(argv);
    json!({"policy": policy, "kinds": kinds})
}

/// DeepSeek Harness's tool for WHAT (`provider:read|grep|write|bash|web-fetch ARG`), its `tool_call` fields, and
/// whether it asks.
pub fn tool(argv: &[String], what: &str, arg: &str) -> Option<(&'static str, Value, bool)> {
    let (name, kind) = match what {
        "read" => ("read", "read"),
        "grep" => ("grep", "search"),
        "write" => ("write", "edit"),
        "bash" => ("bash", "execute"),
        "web-fetch" => ("web_fetch", "fetch"),
        _ => return None,
    };
    let (policy, kinds) = read(argv);
    let asks = policy.as_deref() == Some("ask") && kinds.iter().any(|k| k == kind);
    let fields = json!({"title": name, "kind": "other", "rawInput": {"arg": arg}});
    Some((name, fields, asks))
}
