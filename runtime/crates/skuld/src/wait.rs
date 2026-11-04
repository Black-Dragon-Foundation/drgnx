//! The real-time reads Rust tests may use, in one file that the time check (`tests/real_time_in_tests.rs`) exempts.

use std::future::Future;
use std::time::{Duration, Instant, SystemTime};

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

/// [`wait_until`] for a look that awaits: `f` makes the future of one look, polled every 10 ms on the tokio runtime.
pub async fn wait_until_async<T, Fut: Future<Output = Option<T>>>(
    what: &str,
    secs: u64,
    mut f: impl FnMut() -> Fut,
) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(v) = f().await {
            return v;
        }
        if Instant::now() >= deadline {
            panic!("skuld::wait_until_async: {what}: not within {secs} s");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// A window in which nothing may happen, and `nothing` says what. Nothing marks that nothing did, so the test can only
/// wait: a window that is long enough can make a wrong program pass if it is too short, and can never fail a right
/// one. A test that waits for something to happen uses [`wait_until`], never this.
pub fn window(length: Duration, nothing: &str) {
    let _ = nothing;
    std::thread::sleep(length);
}

/// An `Instant` to add durations to: the origin of a test's pure time arithmetic (a timer core fed `origin() +
/// 30 s`). Never to wait on, nor to measure with.
pub fn origin() -> Instant {
    Instant::now()
}

/// The host's wall clock as a value: for a test that compares a time the OS reports (a process start, a file time) or
/// the code's own clock reading with it. Never to wait on, nor to measure with.
pub fn host_now() -> SystemTime {
    SystemTime::now()
}
