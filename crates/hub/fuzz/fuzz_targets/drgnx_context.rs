//! Arbitrary JSON as an agent's `_drgnx/context` notification and `_drgnx/before_tool` request params through the
//! hub's checks (size, own session, schema with unknown fields refused): nothing may panic, a breakdown that is taken
//! respects its bounds and round-trips, and one from another session is never taken.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    drgnx_ratatoskr::agents::session::fuzz_context(&v);
});
