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
