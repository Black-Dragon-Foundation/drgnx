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
