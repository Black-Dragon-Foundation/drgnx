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
