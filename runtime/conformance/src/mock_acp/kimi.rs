//! The Kimi Code personality (`kimi acp`): `loadSession`, and `list, resume, close, delete, fork`.  Its tools obey
//! its config as Kimi Code's policy does: a user ask rule in `$KIMI_CODE_HOME/config.toml` makes a tool ask; a tool
//! it approves by default (reads, searches, its fetches) runs without asking otherwise; any other tool asks (manual
//! mode's fallback).  A permission request has a `title` and no `kind`; the `tool_call` before it has the kind of
//! Kimi's `events-map.ts` (Read, Glob, Grep: `read`; Write, Edit: `edit`; Bash: `execute`; WebFetch, WebSearch: `fetch`;
//! anything else, `FetchURL` among them: `other`).

use serde_json::{Value, json};

/// The flags that make Kimi Code run without asking.
const NO_ASK: [&str; 5] = ["--yolo", "-y", "--yes", "--auto-approve", "--auto"];

/// The tools Kimi Code approves by default.
const DEFAULT_APPROVED: [&str; 6] = [
    "Read",
    "ReadMediaFile",
    "Glob",
    "Grep",
    "WebSearch",
    "FetchURL",
];

pub fn session_caps() -> Value {
    json!({"list": {}, "resume": {}, "close": {}, "delete": {}, "fork": {}})
}

/// The tool names of `$KIMI_CODE_HOME/config.toml`'s ask rules (`tool = "NAME"` lines).
fn asked() -> Vec<String> {
    let Some(text) = std::env::var_os("KIMI_CODE_HOME")
        .and_then(|h| std::fs::read_to_string(std::path::Path::new(&h).join("config.toml")).ok())
    else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("tool = \""))
        .filter_map(|l| l.strip_suffix('"'))
        .map(str::to_owned)
        .collect()
}

/// What `session/new` logs for Kimi Code: whether argv has a flag that does not ask, and whether its config is
/// there.
pub fn note(argv: &[String]) -> Value {
    let config = std::env::var_os("KIMI_CODE_HOME")
        .is_some_and(|h| std::path::Path::new(&h).join("config.toml").is_file());
    json!({"yolo": argv.iter().any(|a| NO_ASK.contains(&a.as_str())), "config": config})
}

/// Kimi Code's tool for WHAT (`provider:read|grep|write|bash|web-search|web-fetch ARG`), its `tool_call` fields, and
/// whether it asks.
pub fn tool(what: &str, arg: &str) -> Option<(&'static str, Value, bool)> {
    let (name, kind) = match what {
        "read" => ("Read", "read"),
        "grep" => ("Grep", "read"),
        "write" => ("Write", "edit"),
        "bash" => ("Bash", "execute"),
        "web-search" => ("WebSearch", "fetch"),
        "web-fetch" => ("FetchURL", "other"),
        _ => return None,
    };
    let asks = asked().iter().any(|t| t == name) || !DEFAULT_APPROVED.contains(&name);
    let fields = json!({"title": format!("{name} {arg}"), "kind": kind, "rawInput": {"arg": arg}});
    Some((name, fields, asks))
}
