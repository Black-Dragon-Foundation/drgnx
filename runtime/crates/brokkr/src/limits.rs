//! What one plugin call may use (docs/develop/plugins.md, "What a plugin can reach").

use std::time::Duration;

/// The host's limits. `memory_bytes`, `table_elements` and `instances_per_store` bound each call's store (a component
/// is several core instances: its main module, adapters and shims); `component_handles` bounds the store's handle
/// tables. `calls_per_plugin` and `guest_calls` are the two semaphores: at most that many calls of one plugin, and
/// in all, run at once; `guest_calls` is also the number of the guest runtime's threads. There is no fuel: a call is
/// stopped by its deadline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub memory_bytes: usize,
    pub table_elements: usize,
    pub instances_per_store: usize,
    pub component_handles: usize,
    pub calls_per_plugin: usize,
    pub guest_calls: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            memory_bytes: 64 * 1024 * 1024,
            table_elements: 10_000,
            instances_per_store: 32,
            component_handles: 1_000,
            calls_per_plugin: 2,
            guest_calls: 4,
        }
    }
}

/// The most an ability's arguments or result, or a hook's input or verdict, may hold as JSON text.
pub const MAX_JSON_BYTES: usize = 256 * 1024;
/// The most an HTTP request's or response's body may hold.
pub const MAX_BODY_BYTES: usize = 1024 * 1024;
/// The most a call may write to the log: `host.log`, stdout and stderr together. Past it the text is cut.
pub const MAX_LOG_BYTES: usize = 64 * 1024;
/// The most `kv-put` and `kv-delete` calls one plugin call may make; the next gets the import's error.
pub const MAX_KV_WRITES: u32 = 64;
/// The longest key of the key-value store.
pub const MAX_KV_KEY_BYTES: usize = 256;
/// The most headers a request may carry, and the longest value.
pub const MAX_HEADERS: usize = 64;
pub const MAX_HEADER_VALUE_BYTES: usize = 8 * 1024;
/// The longest URL.
pub const MAX_URL_BYTES: usize = 8 * 1024;
/// An ability call's deadline: the WASM call only, never a wait for the user.
pub const ABILITY_DEADLINE: Duration = Duration::from_secs(30);
/// The epoch ticker's period: a deadline is kept to within one tick.
pub const EPOCH_TICK: Duration = Duration::from_millis(10);
/// How long past a call's deadline the caller waits for the guest runtime before it answers `Timeout` itself.
pub const CALLER_GRACE: Duration = Duration::from_millis(50);
