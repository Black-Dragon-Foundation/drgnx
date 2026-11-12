//! The stall watchdog: names what holds one of the runtime's workers in sync work.
//!
//! The hub runs on two async workers.  A task that does sync work on one (a blocking syscall, a contended std lock, a
//! long computation) stalls everything that worker would run; two such tasks stall the hub.  With the watchdog on, a
//! heartbeat task on the runtime ticks every [`TICK`], and a plain thread checks it: when the tick is more than the
//! threshold late, it logs a warning naming each worker's task ([`crate::clock::spawn`]'s origin, held through
//! [`Named`]), how long that task has been in its poll, and the thread's kernel state (`/proc/self/task/TID`: state,
//! wait channel, syscall), so a stall is named by the code that held the worker.
//!
//! On when `DRGNX_RATATOSKR_STALL_MS` is set (the threshold in ms, at least 2 ticks), and in a test-hooks build off the
//! virtual clock at [`DEFAULT_MS`] (conformance rows and the perf runs).  Off in a release build by default: its tick
//! wakes the runtime 20 times a second, which an idle hub must not do.

use std::borrow::Cow;
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

/// The heartbeat's period.
pub const TICK: Duration = Duration::from_millis(50);

/// The threshold a test-hooks build uses when the variable is not set.
pub const DEFAULT_MS: u64 = 250;

static ON: AtomicBool = AtomicBool::new(false);

/// What one thread is polling now: the task's name and since when.
#[derive(Default)]
struct Slot {
    now: Mutex<Option<(Cow<'static, str>, Instant)>>,
    thread: String,
    tid: i64,
}

fn slots() -> &'static Mutex<Vec<Arc<Slot>>> {
    static SLOTS: OnceLock<Mutex<Vec<Arc<Slot>>>> = OnceLock::new();
    SLOTS.get_or_init(Mutex::default)
}

thread_local! {
    static MINE: RefCell<Option<Arc<Slot>>> = const { RefCell::new(None) };
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(target_os = "linux")]
fn tid() -> i64 {
    // SAFETY: gettid has no preconditions
    i64::from(unsafe { libc::gettid() })
}

#[cfg(not(target_os = "linux"))]
fn tid() -> i64 {
    0
}

/// This thread's slot, registered at its first poll.
fn mine() -> Arc<Slot> {
    MINE.with(|m| {
        m.borrow_mut()
            .get_or_insert_with(|| {
                let slot = Arc::new(Slot {
                    now: Mutex::new(None),
                    thread: std::thread::current().name().unwrap_or("?").to_owned(),
                    tid: tid(),
                });
                lock(slots()).push(slot.clone());
                slot
            })
            .clone()
    })
}

/// Whether tasks are named for the watchdog (set once, before the first task is spawned).
pub fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

/// The threshold from the environment: `DRGNX_RATATOSKR_STALL_MS`, else [`DEFAULT_MS`] in a test-hooks build, else
/// none (off).  VIRTUAL: the virtual clock runs (its advances judge waits themselves; off).
pub fn threshold(var: Option<&str>, test_hooks: bool, virtual_clock: bool) -> Option<Duration> {
    if virtual_clock {
        return None;
    }
    let ms = match var.map(str::trim).filter(|v| !v.is_empty()) {
        Some(v) => v.parse::<u64>().ok()?,
        None if test_hooks => DEFAULT_MS,
        None => return None,
    };
    let min = 2 * TICK.as_millis() as u64;
    Some(Duration::from_millis(ms.max(min)))
}

/// `tokio::spawn` of F, named NAME for the watchdog when it runs: for the tasks that stay off the virtual clock's
/// tracking ([`crate::clock::spawn`] names the others).
pub fn spawn<F>(name: &'static str, f: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    if on() {
        return tokio::spawn(Named::new(Cow::Borrowed(name), f));
    }
    tokio::spawn(f)
}

/// Name tasks from now on (before any is spawned).
pub fn enable() {
    ON.store(true, Ordering::Relaxed);
}

/// F, whose every poll is recorded under NAME in its thread's slot.
pub struct Named<F> {
    name: Cow<'static, str>,
    fut: Pin<Box<F>>,
}

impl<F> Named<F> {
    pub fn new(name: Cow<'static, str>, fut: F) -> Named<F> {
        Named {
            name,
            fut: Box::pin(fut),
        }
    }
}

impl<F: Future> Future for Named<F> {
    type Output = F::Output;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let slot = mine();
        let outer = lock(&slot.now).replace((self.name.clone(), crate::clock::real_now()));
        let r = self.fut.as_mut().poll(cx);
        // a task polled inside another's poll (block_in_place, a nested block_on) gives the outer one back
        *lock(&slot.now) = outer;
        r
    }
}

/// What each thread polls now, held longer than HELD: (thread, tid, task, ms in the poll).
fn holders(held: Duration) -> Vec<(String, i64, String, u128)> {
    let now = crate::clock::real_now();
    lock(slots())
        .iter()
        .filter_map(|s| {
            let n = lock(&s.now);
            let (name, since) = n.as_ref()?;
            let ms = now.saturating_duration_since(*since);
            (ms >= held).then(|| (s.thread.clone(), s.tid, name.to_string(), ms.as_millis()))
        })
        .collect()
}

/// A stall's line, or none: the heartbeat LATE past THRESHOLD, or a poll in HELD (each already held past it), names
/// each held thread's task, how long, and its kernel state.
fn report(
    late: Duration,
    threshold: Duration,
    held: &[(String, i64, String, u128)],
) -> Option<String> {
    if late <= threshold && held.is_empty() {
        return None;
    }
    if held.is_empty() {
        return Some(
            "no named task held past the threshold (an unnamed task, or the runtime itself)".into(),
        );
    }
    Some(
        held.iter()
            .map(|(thread, tid, task, ms)| {
                format!("{thread} in {task} for {ms} ms ({})", kernel(*tid))
            })
            .collect::<Vec<_>>()
            .join("; "),
    )
}

/// The kernel's view of thread TID: its state, wait channel and syscall line (what a sync call waits in); Linux only.
fn kernel(tid: i64) -> String {
    if !cfg!(target_os = "linux") {
        return "no kernel view off Linux".into();
    }
    let read = |f: &str| {
        std::fs::read_to_string(format!("/proc/self/task/{tid}/{f}"))
            .map(|s| s.trim().to_owned())
            .unwrap_or_default()
    };
    let state = read("status")
        .lines()
        .find_map(|l| l.strip_prefix("State:").map(|s| s.trim().to_owned()))
        .unwrap_or_default();
    format!(
        "state {state}, wchan {}, syscall {}",
        read("wchan"),
        read("syscall")
    )
}

/// LINE appended to `DRGNX_RATATOSKR_STALL_FILE` too, when set (with the hub's pid and the wall time): a run whose
/// hubs' logs go with their folders (conformance roots, perf sessions) keeps its stalls there.
fn also_to(line: &str) {
    use std::io::Write;
    let Some(path) = std::env::var_os("DRGNX_RATATOSKR_STALL_FILE") else {
        return;
    };
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{at:.3} pid {} {line}", std::process::id());
    }
}

/// The heartbeat's last tick, in ms since START.
struct Beat {
    start: Instant,
    last: AtomicU64,
}

impl Beat {
    fn ms(&self) -> u64 {
        u64::try_from(self.start.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

/// Start the heartbeat on the current runtime and the checking thread, with THRESHOLD.  Each stall is logged once,
/// when it is found, and its end with how long it lasted.
pub fn start(threshold: Duration) {
    let beat = Arc::new(Beat {
        start: crate::clock::real_now(),
        last: AtomicU64::new(0),
    });
    let b = beat.clone();
    // a plain tokio task (not named, not on the virtual clock): its lateness is the stall
    tokio::spawn(async move {
        loop {
            b.last.store(b.ms(), Ordering::Relaxed);
            tokio::time::sleep(TICK).await;
        }
    });
    let spawned = std::thread::Builder::new()
        .name("ratatoskr-stall".into())
        .spawn(move || {
            // since when the stall being reported began (ms on the beat's clock)
            let mut stalled: Option<u64> = None;
            loop {
                std::thread::sleep(TICK);
                let now = beat.ms();
                let late = now.saturating_sub(beat.last.load(Ordering::Relaxed));
                // a poll held past the threshold is a held worker even while the other one keeps the beat
                let held = holders(threshold);
                match (
                    stalled,
                    report(Duration::from_millis(late), threshold, &held),
                ) {
                    (None, Some(_)) => {
                        // every poll in progress, however short: a task waiting on a lock names the one holding it
                        let line = report(Duration::MAX, threshold, &holders(Duration::ZERO))
                            .unwrap_or_default();
                        stalled = Some(now);
                        tracing::warn!(late_ms = late, held = line, "the runtime stalled");
                        also_to(&format!("stalled: late {late} ms; {line}"));
                    }
                    (Some(since), None) => {
                        let lasted = now.saturating_sub(since);
                        tracing::warn!(lasted_ms = lasted, "the runtime stall ended");
                        also_to(&format!("ended after {lasted} ms"));
                        stalled = None;
                    }
                    _ => {}
                }
            }
        });
    if let Err(e) = spawned {
        tracing::warn!("the stall watchdog did not start: {e}");
    }
}

#[cfg(test)]
mod tests;
