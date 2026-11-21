//! drgnx-clock: the time source the runtime's timers read.
//!
//! A timer in a crate (a kill's grace, a deadline, a debounce) waits through [`sleep`] and [`timeout`], not through tokio
//! or `std::thread` directly.  With nothing installed they are tokio's own, and cost one atomic read more.  A test
//! installs a [`Provider`] (the hub's virtual clock, or [`Manual`] with the `test-hooks` feature) and the timer then waits
//! on virtual time: the test chooses when it fires, and no assertion depends on how fast the machine is.
//!
//! What a virtual clock cannot do is wait for something outside it (a child's exit, a socket): that is an event wait, and
//! it stays real (docs/develop/runtime.md, "Virtual clocks").

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, RwLock};
use std::time::Duration;

#[cfg(feature = "test-hooks")]
mod manual;
#[cfg(feature = "test-hooks")]
pub use manual::Manual;

/// A time source other than tokio's: `sleep` is its one primitive.
pub trait Provider: Send + Sync + 'static {
    /// A future that is ready once D has passed on this clock.
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>>;
    /// This clock's reading: time since an origin that stays the same for the clock's life (only differences count).
    fn now(&self) -> Duration;
}

static PROVIDER: RwLock<Option<Arc<dyn Provider>>> = RwLock::new(None);

tokio::task_local! {
    static LOCAL: Arc<dyn Provider>;
}

thread_local! {
    static THREAD: std::cell::RefCell<Option<Arc<dyn Provider>>> = const { std::cell::RefCell::new(None) };
}

/// The clock of this thread until the guard drops: for a test on a current-thread runtime (`#[tokio::test]`), whose every
/// task, spawned ones too, runs on its thread, so a clock no other test of the process sees reaches them all.
pub fn on_this_thread(p: Arc<dyn Provider>) -> ThreadClock {
    THREAD.with(|t| *t.borrow_mut() = Some(p));
    ThreadClock(())
}

/// See [`on_this_thread`].
pub struct ThreadClock(());

impl Drop for ThreadClock {
    fn drop(&mut self) {
        THREAD.with(|t| *t.borrow_mut() = None);
    }
}

/// F with P as its clock: only the timers F itself waits on (not the tasks it spawns: wrap those in `scope` too) read
/// P, so a test's clock reaches no other test of the process.
pub async fn scope<F: Future>(p: Arc<dyn Provider>, f: F) -> F::Output {
    LOCAL.scope(p, f).await
}

/// Install P as the clock (replacing any); every timer through this crate reads it from now on.
pub fn install(p: Arc<dyn Provider>) {
    *PROVIDER.write().unwrap_or_else(|e| e.into_inner()) = Some(p);
}

/// Back to tokio's clock.
pub fn uninstall() {
    *PROVIDER.write().unwrap_or_else(|e| e.into_inner()) = None;
}

fn current() -> Option<Arc<dyn Provider>> {
    LOCAL
        .try_with(Arc::clone)
        .ok()
        .or_else(|| THREAD.with(|t| t.borrow().clone()))
        .or_else(|| PROVIDER.read().unwrap_or_else(|e| e.into_inner()).clone())
}

/// Wait D on the installed clock, else on tokio's.
pub async fn sleep(d: Duration) {
    match current() {
        Some(p) => p.sleep(d).await,
        None => tokio::time::sleep(d).await,
    }
}

/// The installed clock's reading, else tokio's: only differences between two readings mean anything.
pub fn now() -> Duration {
    match current() {
        Some(p) => p.now(),
        None => {
            static ORIGIN: std::sync::OnceLock<tokio::time::Instant> = std::sync::OnceLock::new();
            tokio::time::Instant::now()
                .saturating_duration_since(*ORIGIN.get_or_init(tokio::time::Instant::now))
        }
    }
}

/// A [`timeout`] that ran out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Elapsed;

impl std::fmt::Display for Elapsed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("deadline has elapsed")
    }
}

impl std::error::Error for Elapsed {}

/// F, or [`Elapsed`] once D has passed on the installed clock, else tokio's.
pub async fn timeout<F: Future>(d: Duration, f: F) -> Result<F::Output, Elapsed> {
    match current() {
        None => tokio::time::timeout(d, f).await.map_err(|_| Elapsed),
        Some(p) => {
            let mut f = std::pin::pin!(f);
            let mut s = p.sleep(d);
            std::future::poll_fn(|cx| {
                if let std::task::Poll::Ready(v) = f.as_mut().poll(cx) {
                    return std::task::Poll::Ready(Ok(v));
                }
                match s.as_mut().poll(cx) {
                    std::task::Poll::Ready(()) => std::task::Poll::Ready(Err(Elapsed)),
                    std::task::Poll::Pending => std::task::Poll::Pending,
                }
            })
            .await
        }
    }
}
