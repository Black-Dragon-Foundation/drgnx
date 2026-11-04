//! The one real-time wait Rust tests may use.

use std::time::{Duration, Instant};

/// Polls `f` every 10 ms until it returns a value, and returns it. Panics naming `what` when `secs` pass first. The
/// deadline only bounds a failure: a passing test never waits on it, so it is never a reason to widen one.
pub fn wait_until<T>(what: &str, secs: u64, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(v) = f() {
            return v;
        }
        if Instant::now() >= deadline {
            panic!("skuld::wait_until: {what}: not within {secs} s");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
