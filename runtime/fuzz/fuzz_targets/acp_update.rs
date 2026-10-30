//! Arbitrary JSON (one object, or an array of them) as an agent's `session/update`s through the session's reducer
//! (entries, tool calls, plans, commands, usage): each update counts once, and nothing may panic.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    let updates = match v {
        serde_json::Value::Array(a) => a,
        one => vec![one],
    };
    drgnx_ratatoskr::agents::session::fuzz_apply(&updates);
});
