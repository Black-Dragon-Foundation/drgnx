//! The Kimi Code personality (`kimi acp`): `loadSession`, and `list, resume, close, delete, fork`; its four modes,
//! reported when a session opens and switched with a `current_mode_update`.  Its tools obey
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

/// Kimi Code's ACP modes, `(id, name)`, in `ACP_MODES`' order (`packages/acp-server/src/modes.ts:22-43`): the only ids
/// `isAcpModeId` (`:52-54`) knows, so `session/set_mode` to another is invalid params (`server.ts:483-488`).
const MODES: [(&str, &str); 4] = [
    ("default", "Default"),
    ("plan", "Plan"),
    ("auto", "Auto"),
    ("yolo", "YOLO"),
];

pub fn session_caps() -> Value {
    json!({"list": {}, "resume": {}, "close": {}, "delete": {}, "fork": {}})
}

/// Whether ID is a mode Kimi Code's ACP server knows.
pub fn known_mode(id: &str) -> bool {
    MODES.iter().any(|(m, _)| *m == id)
}

/// The `modes` of an answer that opens a session (`AcpSession.modeState`, `session.ts:1067-1069`): every session opens
/// in `default` (`modes.ts:46`, `session.ts:208`); `--start-mode MODE` in ARGV stands in for a Kimi that opens in
/// another.
pub fn modes(argv: &[String]) -> Value {
    let current = argv
        .iter()
        .position(|a| a == "--start-mode")
        .and_then(|i| argv.get(i + 1))
        .map_or("default", String::as_str);
    let available: Vec<Value> = MODES
        .iter()
        .map(|(id, name)| json!({"id": id, "name": name}))
        .collect();
    json!({"currentModeId": current, "availableModes": available})
}

/// The notification a switch to MODE sends (`setMode`, `session.ts:1138-1156`; its shape, `events-map.ts:471-482`).
pub fn mode_update(mode: &str) -> Value {
    json!({"sessionUpdate": "current_mode_update", "currentModeId": mode})
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

/// Whether `$KIMI_CODE_HOME/config.toml` has a deny rule for tool NAME (a `[[permission.rules]]` with `decision =
/// "deny"`): the tool is refused without asking.
pub fn denied(name: &str) -> bool {
    let Some(text) = std::env::var_os("KIMI_CODE_HOME")
        .and_then(|h| std::fs::read_to_string(std::path::Path::new(&h).join("config.toml")).ok())
    else {
        return false;
    };
    text.split("[[permission.rules]]").any(|rule| {
        rule.contains(&format!("tool = \"{name}\"")) && rule.contains("decision = \"deny\"")
    })
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
