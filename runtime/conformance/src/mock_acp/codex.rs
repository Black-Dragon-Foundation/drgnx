//! The Codex personality (codex-acp 2.x): `resume, list, close, fork`; what it reads of its lock is its environment
//! (`CODEX_CONFIG`, `INITIAL_AGENT_MODE`; logged, with the argv `-c` overrides it ignores), the mode it picks from
//! `INITIAL_AGENT_MODE` (reported in the answers that open a session), forks at a turn (a message id keeps its whole
//! turn), `usage_update {used,size}` and a rate-limit window.

use serde_json::{Value, json};

/// codex-acp 2.5.0's modes, `(id, name)`, in `AgentMode.all()`'s order (`src/AgentMode.ts:135-137`; ids and names at
/// `:39-93`): the only ids `AgentMode.find` (`:139-142`) knows.
const MODES: [(&str, &str); 4] = [
    ("read-only", "Read-only"),
    ("workspace-write", "Workspace access"),
    ("agent", "Auto review"),
    ("agent-full-access", "Full access"),
];

/// `AgentMode.DEFAULT_AGENT_MODE` (`src/AgentMode.ts:95`): Auto review, whose approvals a reviewer model gives.
const DEFAULT_MODE: &str = "agent";

pub fn session_caps() -> Value {
    json!({"resume": {}, "list": {}, "close": {}, "fork": {}})
}

/// Whether ID is a mode codex-acp knows (`AgentMode.find`): `session/set_mode` to another is invalid params
/// (`src/CodexAcpServer.ts:2752-2756`).
pub fn known_mode(id: &str) -> bool {
    MODES.iter().any(|(m, _)| *m == id)
}

/// The mode a session opens in, as `AgentMode.getInitialAgentMode` (`src/AgentMode.ts:144-151`) picks it:
/// `INITIAL_AGENT_MODE` when set and known, else the default, silently.
pub fn initial_mode() -> &'static str {
    let asked = std::env::var("INITIAL_AGENT_MODE").unwrap_or_default();
    MODES
        .iter()
        .map(|(m, _)| *m)
        .find(|m| *m == asked)
        .unwrap_or(DEFAULT_MODE)
}

/// The `modes` of an answer that opens a session (`AgentMode.toSessionModeState`, `src/AgentMode.ts:108-113`).
pub fn modes() -> Value {
    let available: Vec<Value> = MODES
        .iter()
        .map(|(id, name)| json!({"id": id, "name": name}))
        .collect();
    json!({"currentModeId": initial_mode(), "availableModes": available})
}

/// Why Codex refuses to start a thread on `CODEX_CONFIG`, if it does: Codex 0.165 refuses `approval_policy =
/// "untrusted"` in a config (`core/src/config/mod.rs:232-233`, `:3898-3903`).
pub fn refused_config() -> Option<String> {
    let c: Value = serde_json::from_str(&std::env::var("CODEX_CONFIG").ok()?).ok()?;
    (c["approval_policy"] == "untrusted").then(|| {
        "approval_policy = \"untrusted\" is no longer supported; remove this setting".to_string()
    })
}

/// The `-c key=value` pairs of argv, as the strings after each `-c`.
pub fn overrides(argv: &[String]) -> Vec<String> {
    argv.windows(2)
        .filter(|w| w[0] == "-c")
        .map(|w| w[1].clone())
        .collect()
}

/// What `session/new` logs for Codex (`codex_config`): `CODEX_CONFIG` as JSON (null when unset or not JSON),
/// `INITIAL_AGENT_MODE`, and the argv overrides codex-acp 2.x ignores.
pub fn config(argv: &[String]) -> Value {
    let config = std::env::var("CODEX_CONFIG")
        .ok()
        .and_then(|c| serde_json::from_str::<Value>(&c).ok());
    json!({"config": config, "mode": std::env::var("INITIAL_AGENT_MODE").ok(),
        "argv_overrides": overrides(argv)})
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
