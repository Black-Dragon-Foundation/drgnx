//! The hub's clock: its timers and its readings of the time go through here (docs/develop/hub.md, "Test hooks").
//!
//! A release build is tokio's and std's clock, every function inlined over them.  With the `test-hooks` feature,
//! `serve --test-clock` installs a **virtual clock** before any task starts: it stands still until
//! `__test_advance {ms}` ([`advance`]) moves it, so a test chooses when each timer fires.  tokio's own clock is never
//! paused: the runtime stays multi-thread, and a paused tokio clock jumps ahead whenever the runtime is idle.
//!
//! Its reach is this crate.  The timers inside draugr (a kill's grace), hermod (the ACP timeouts), bifrost and urdr
//! run on real time; a path through one of them is not decided by the test's advances.

use std::borrow::Cow;
use std::future::Future;
use std::time::{Duration, SystemTime};

/// The name of a task [`spawn`] started (`"module:what"`).  With the `test-hooks` feature it is held task-local, and
/// an advance names a task by it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Origin(Cow<'static, str>);

impl Origin {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&'static str> for Origin {
    fn from(s: &'static str) -> Origin {
        Origin(Cow::Borrowed(s))
    }
}

impl From<String> for Origin {
    fn from(s: String) -> Origin {
        Origin(Cow::Owned(s))
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

/// The hub's monotonic time.
#[inline]
pub fn now() -> tokio::time::Instant {
    #[cfg(feature = "test-hooks")]
    if let Some(v) = virt::current() {
        return v.now();
    }
    tokio::time::Instant::now()
}

/// The hub's time of day.
#[inline]
pub fn wall() -> SystemTime {
    #[cfg(feature = "test-hooks")]
    if let Some(v) = virt::current() {
        return v.wall();
    }
    SystemTime::now()
}

/// The hub's time of day, in seconds since the epoch.
#[inline]
pub fn wall_secs() -> f64 {
    wall()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Real time, whatever clock the hub runs on: only for a limit on a blocking thread's wait for something outside the
/// hub (a podman pull), which a virtual clock, standing still, would never end.
#[inline]
pub fn real_now() -> std::time::Instant {
    std::time::Instant::now()
}

/// Wait D on the hub's clock.
#[inline]
pub async fn sleep(d: Duration) {
    #[cfg(feature = "test-hooks")]
    if let Some(v) = virt::current() {
        return virt::Sleep::new(&v, d).await;
    }
    tokio::time::sleep(d).await
}

/// F, or [`Elapsed`] once D has passed on the hub's clock.
#[inline]
pub async fn timeout<F: Future>(d: Duration, f: F) -> Result<F::Output, Elapsed> {
    #[cfg(feature = "test-hooks")]
    if let Some(v) = virt::current() {
        return virt::timeout(&v, d, f).await;
    }
    tokio::time::timeout(d, f).await.map_err(|_| Elapsed)
}

/// Ticks every PERIOD on the hub's clock, the first at once; a late tick moves the next ones (tokio's
/// `MissedTickBehavior::Delay`).
pub fn interval(period: Duration) -> Interval {
    assert!(!period.is_zero(), "an interval's period is above zero");
    #[cfg(feature = "test-hooks")]
    if let Some(v) = virt::current() {
        let next = v.elapsed();
        return Interval(Ticks::Virtual {
            clock: v,
            period,
            next,
        });
    }
    let mut t = tokio::time::interval(period);
    t.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    Interval(Ticks::Real(t))
}

/// See [`interval`].
pub struct Interval(Ticks);

enum Ticks {
    Real(tokio::time::Interval),
    #[cfg(feature = "test-hooks")]
    Virtual {
        clock: std::sync::Arc<virt::Virtual>,
        period: Duration,
        next: Duration,
    },
}

impl Interval {
    /// The next tick: waits for it, and returns when it was due.
    pub async fn tick(&mut self) -> tokio::time::Instant {
        match &mut self.0 {
            Ticks::Real(t) => t.tick().await,
            #[cfg(feature = "test-hooks")]
            Ticks::Virtual {
                clock,
                period,
                next,
            } => {
                virt::Sleep::until(clock, *next).await;
                let at = clock.elapsed().max(*next);
                *next = at + *period;
                clock.at(at)
            }
        }
    }
}

/// `tokio::spawn` of F, named ORIGIN.  With the `test-hooks` feature the name is held task-local, and on the virtual
/// clock the task is tracked: an advance waits for it ([`advance`]).
#[cfg(not(feature = "test-hooks"))]
#[inline]
pub fn spawn<F>(origin: impl Into<Origin>, f: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    let _ = origin;
    tokio::spawn(f)
}

/// `tokio::spawn` of F, named ORIGIN.  With the `test-hooks` feature the name is held task-local, and on the virtual
/// clock the task is tracked: an advance waits for it ([`advance`]).
#[cfg(feature = "test-hooks")]
pub fn spawn<F>(origin: impl Into<Origin>, f: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    virt::spawn(origin.into(), f)
}

/// What an advance did: the virtual time now, how many sleepers it woke, the tasks still running after
/// [`BUSY_AFTER`] of real time (by origin), and how many of the woken sleepers were in a task without an origin (not
/// [`spawn`]ed here: not waited for).
#[cfg(feature = "test-hooks")]
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Advanced {
    pub now_ms: u64,
    pub woken: u32,
    pub busy: Vec<String>,
    pub unnamed: u32,
}

/// How long an advance waits, in real time, for a task to wait on the clock again before naming it busy.
#[cfg(feature = "test-hooks")]
pub const BUSY_AFTER: Duration = Duration::from_secs(5);

/// The virtual clock, from now on, for the whole process (`serve --test-clock`, before any task starts).  Once.
#[cfg(feature = "test-hooks")]
pub fn install_virtual() {
    virt::install();
}

/// Does the hub run on the virtual clock?
#[cfg(feature = "test-hooks")]
pub fn is_virtual() -> bool {
    virt::current().is_some()
}

/// Move the virtual clock by D.  Time moves to each due deadline in order; sleepers due at one instant wake in the order
/// they began to wait, one at a time.  After each wake the advance waits until the woken task, and every task it
/// spawned, waits on the clock again or has ended; a task spawned before the advance, until it was first run.  A task
/// still running after [`BUSY_AFTER`] of real time is named in `busy`, and the advance goes on.  Advances run one at a
/// time.  Panics on the real clock.
#[cfg(feature = "test-hooks")]
pub async fn advance(d: Duration) -> Advanced {
    let v = virt::current().expect("the hub runs on the real clock");
    v.advance(d).await
}

/// The origin of the task running now (test-hooks): its [`spawn`] name and the task's spawn ordinal (one count across
/// every task this process spawned), none outside such a task.
#[cfg(feature = "test-hooks")]
pub(crate) fn origin() -> Option<(String, u64)> {
    virt::origin()
}

/// F, a wait on something outside the hub's clock that ends by itself (a child's exit, a blocking thread, another
/// process's answer).  With the `test-hooks` feature, on the virtual clock, a [`spawn`]ed task inside one is waited for
/// by a barrier, and named `waiting` when it stays inside ([`settle_real`]).
#[inline]
pub(crate) async fn real<F: Future>(f: F) -> F::Output {
    #[cfg(feature = "test-hooks")]
    let f = virt::real(f);
    f.await
}

/// Wait, at most WITHIN of real time, until no [`spawn`]ed task whose origin OK does not list is inside a [`real`] wait
/// or in the poll that left one; then the origins of the tasks still inside one (sorted, once each): those OK lists,
/// and after WITHIN the others.  Empty on the real clock (test-hooks).
#[cfg(feature = "test-hooks")]
pub(crate) async fn settle_real(within: Duration, ok: &[String]) -> Vec<String> {
    match virt::current() {
        Some(v) => v.settle_real(within, ok).await,
        None => vec![],
    }
}

/// F, or [`Elapsed`] once D of real time has passed, whatever clock the hub runs on: only for a limit on a wait a
/// standing virtual clock would never end (the hub's end: the sequencer's, the connections', the store threads').
#[inline]
pub(crate) async fn real_timeout<F: Future>(d: Duration, f: F) -> Result<F::Output, Elapsed> {
    tokio::time::timeout(d, f).await.map_err(|_| Elapsed)
}

/// The virtual clock's time since it was installed, in ms; 0 on the real clock (test-hooks).
#[cfg(feature = "test-hooks")]
pub(crate) fn virtual_ms() -> u64 {
    virt::current().map_or(0, |v| {
        u64::try_from(v.elapsed().as_millis()).unwrap_or(u64::MAX)
    })
}

/// F on a two-worker runtime whose threads (and this one) read a fresh virtual clock (unit tests).
#[cfg(all(test, feature = "test-hooks"))]
pub(crate) fn on_virtual<F: Future>(f: F) -> F::Output {
    let clock = std::sync::Arc::new(virt::Virtual::new());
    let theirs = clock.clone();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .on_thread_start(move || virt::LOCAL.with(|l| *l.borrow_mut() = Some(theirs.clone())))
        .build()
        .unwrap();
    virt::LOCAL.with(|l| *l.borrow_mut() = Some(clock));
    let out = rt.block_on(f);
    virt::LOCAL.with(|l| *l.borrow_mut() = None);
    rt.shutdown_background();
    out
}

/// How many sleepers wait on the virtual clock now; 0 on the real clock (unit tests).
#[cfg(all(test, feature = "test-hooks"))]
pub(crate) fn sleepers() -> usize {
    virt::current().map_or(0, |v| v.sleepers())
}

#[cfg(feature = "test-hooks")]
mod virt {
    use super::{Advanced, BUSY_AFTER, Elapsed, Origin};
    use std::collections::{BTreeMap, BTreeSet, HashSet};
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
    use std::task::{Context, Poll, Waker};
    use std::time::{Duration, SystemTime};
    use tokio::sync::Notify;
    use tokio::task::futures::TaskLocalFuture;

    static GLOBAL: OnceLock<Arc<Virtual>> = OnceLock::new();

    // Unit tests run many clocks in one process: a test's runtime threads carry their own.
    #[cfg(test)]
    thread_local! {
        pub(super) static LOCAL: std::cell::RefCell<Option<Arc<Virtual>>> =
            const { std::cell::RefCell::new(None) };
    }

    tokio::task_local! {
        static TASK: Arc<Task>;
    }

    pub(super) fn install() {
        let _ = GLOBAL.set(Arc::new(Virtual::new()));
    }

    pub(super) fn origin() -> Option<(String, u64)> {
        TASK.try_with(|t| (t.origin.as_str().to_string(), t.ordinal))
            .ok()
    }

    /// The next task's spawn ordinal.
    static ORDINALS: AtomicU64 = AtomicU64::new(0);

    pub(super) fn current() -> Option<Arc<Virtual>> {
        #[cfg(test)]
        if let Some(v) = LOCAL.with(|l| l.borrow().clone()) {
            return Some(v);
        }
        GLOBAL.get().cloned()
    }

    fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
        m.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A task [`super::spawn`] started.  Lock order: the clock's state, then a task's flags.
    pub(super) struct Task {
        origin: Origin,
        /// Its place in the order the process spawned tasks in: one origin's tasks are told apart by it.
        ordinal: u64,
        flags: Mutex<Flags>,
    }

    #[derive(Default)]
    struct Flags {
        /// Inside a poll now.
        polling: bool,
        polls: u64,
        ended: bool,
        /// Its sleepers registered and not fired.
        waits: u32,
        /// Wakes the clock gave it, and the count its last finished poll began after.
        fired: u64,
        seen: u64,
        /// The [`super::real`] waits it is inside.
        real: u32,
    }

    impl Task {
        fn flags(&self) -> MutexGuard<'_, Flags> {
            lock(&self.flags)
        }

        /// Waits on the clock and runs nothing: ended, or between polls with a sleeper registered and every wake it
        /// was given seen by a poll.
        fn parked(&self) -> bool {
            let f = self.flags();
            f.ended || (!f.polling && f.seen == f.fired && f.waits > 0)
        }

        /// Run once (its first sleeper, if any, registered at the time it was spawned).
        fn started(&self) -> bool {
            let f = self.flags();
            f.ended || (!f.polling && f.polls > 0)
        }
    }

    struct Entry {
        waker: Waker,
        task: Option<Arc<Task>>,
    }

    struct State {
        elapsed: Duration,
        next_seq: u64,
        /// The sleepers, by deadline, then the order they registered in.
        queue: BTreeMap<(Duration, u64), Entry>,
        /// Sleepers woken whose future has not seen it yet.
        fired: HashSet<u64>,
        /// Tasks spawned outside an advance, until they have run once.
        fresh: Vec<Arc<Task>>,
        /// During an advance: the tasks the woken ones spawned.
        born: Vec<Arc<Task>>,
        advancing: bool,
        /// Tasks that went into a real wait, until a settle sees them out of it and its poll.
        real: Vec<Arc<Task>>,
    }

    pub(crate) struct Virtual {
        base: tokio::time::Instant,
        base_wall: SystemTime,
        state: Mutex<State>,
        /// A task polled, registered, ended or dropped a sleeper.
        changed: Notify,
        one_at_a_time: tokio::sync::Mutex<()>,
    }

    impl Virtual {
        pub(super) fn new() -> Virtual {
            Virtual {
                base: tokio::time::Instant::now(),
                base_wall: SystemTime::now(),
                state: Mutex::new(State {
                    elapsed: Duration::ZERO,
                    next_seq: 0,
                    queue: BTreeMap::new(),
                    fired: HashSet::new(),
                    fresh: Vec::new(),
                    born: Vec::new(),
                    advancing: false,
                    real: Vec::new(),
                }),
                changed: Notify::new(),
                one_at_a_time: tokio::sync::Mutex::new(()),
            }
        }

        fn state(&self) -> MutexGuard<'_, State> {
            lock(&self.state)
        }

        pub(super) fn elapsed(&self) -> Duration {
            self.state().elapsed
        }

        #[cfg(test)]
        pub(super) fn sleepers(&self) -> usize {
            self.state().queue.len()
        }

        pub(super) fn at(&self, elapsed: Duration) -> tokio::time::Instant {
            self.base + elapsed
        }

        pub(super) fn now(&self) -> tokio::time::Instant {
            self.at(self.elapsed())
        }

        pub(super) fn wall(&self) -> SystemTime {
            self.base_wall + self.elapsed()
        }

        pub(super) async fn advance(&self, d: Duration) -> Advanced {
            let _one = self.one_at_a_time.lock().await;
            let target = {
                let mut st = self.state();
                st.advancing = true;
                st.elapsed + d
            };
            let mut out = Advanced::default();
            let mut busy = BTreeSet::new();
            self.settle(None, &mut busy).await;
            while let Some(task) = self.fire_next(target) {
                out.woken += 1;
                if task.is_none() {
                    out.unnamed += 1;
                }
                self.settle(task, &mut busy).await;
            }
            let now = {
                let mut st = self.state();
                st.elapsed = st.elapsed.max(target);
                st.advancing = false;
                st.born.clear();
                st.elapsed
            };
            out.now_ms = u64::try_from(now.as_millis()).unwrap_or(u64::MAX);
            out.busy = busy.into_iter().collect();
            out
        }

        /// The first sleeper due by TARGET woken, the clock at its deadline: Some(its task), or None when none is due.
        #[allow(clippy::option_option)]
        fn fire_next(&self, target: Duration) -> Option<Option<Arc<Task>>> {
            let entry = {
                let mut st = self.state();
                let (&(at, seq), _) = st.queue.first_key_value()?;
                if at > target {
                    return None;
                }
                let e = st.queue.remove(&(at, seq)).expect("the first entry");
                st.elapsed = st.elapsed.max(at);
                st.fired.insert(seq);
                if let Some(t) = &e.task {
                    let mut f = t.flags();
                    f.waits -= 1;
                    f.fired += 1;
                }
                e
            };
            entry.waker.wake();
            Some(entry.task)
        }

        /// Wait until WOKEN and the tasks it spawned are parked, and every task spawned before has run once; at most
        /// [`BUSY_AFTER`] of real time, after which those still running are named in BUSY and not waited for again.
        async fn settle(&self, woken: Option<Arc<Task>>, busy: &mut BTreeSet<String>) {
            let give_up = tokio::time::Instant::now() + BUSY_AFTER;
            let mut woken = woken;
            loop {
                let note = self.changed.notified();
                let mut note = std::pin::pin!(note);
                note.as_mut().enable();
                let mut running: Vec<Arc<Task>> = Vec::new();
                {
                    let mut st = self.state();
                    st.fresh.retain(|t| !t.started());
                    st.born.retain(|t| !t.parked());
                    running.extend(st.fresh.iter().cloned());
                    running.extend(st.born.iter().cloned());
                }
                if let Some(w) = &woken {
                    if w.parked() {
                        woken = None;
                    } else {
                        running.push(w.clone());
                    }
                }
                if running.is_empty() {
                    return;
                }
                if tokio::time::timeout_at(give_up, note).await.is_err() {
                    for t in &running {
                        busy.insert(t.origin.as_str().to_string());
                    }
                    let mut st = self.state();
                    st.fresh
                        .retain(|t| !running.iter().any(|r| Arc::ptr_eq(r, t)));
                    st.born
                        .retain(|t| !running.iter().any(|r| Arc::ptr_eq(r, t)));
                    return;
                }
            }
        }
    }

    /// A wait on the virtual clock until a deadline (time since the clock was installed).  It registers at its first
    /// poll, and is ready only once an advance woke it (or when its deadline had passed already).
    pub(super) struct Sleep {
        clock: Arc<Virtual>,
        deadline: Duration,
        seq: Option<u64>,
    }

    impl Sleep {
        pub(super) fn new(clock: &Arc<Virtual>, d: Duration) -> Sleep {
            Sleep::until(clock, clock.elapsed() + d)
        }

        pub(super) fn until(clock: &Arc<Virtual>, deadline: Duration) -> Sleep {
            Sleep {
                clock: clock.clone(),
                deadline,
                seq: None,
            }
        }
    }

    impl Future for Sleep {
        type Output = ();

        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
            let this = &mut *self;
            let mut st = this.clock.state();
            match this.seq {
                Some(seq) => {
                    if st.fired.remove(&seq) {
                        this.seq = None;
                        return Poll::Ready(());
                    }
                    if let Some(e) = st.queue.get_mut(&(this.deadline, seq)) {
                        e.waker.clone_from(cx.waker());
                    }
                    Poll::Pending
                }
                None => {
                    if this.deadline <= st.elapsed {
                        return Poll::Ready(());
                    }
                    let seq = st.next_seq;
                    st.next_seq += 1;
                    let task = TASK.try_with(Arc::clone).ok();
                    if let Some(t) = &task {
                        t.flags().waits += 1;
                    }
                    st.queue.insert(
                        (this.deadline, seq),
                        Entry {
                            waker: cx.waker().clone(),
                            task,
                        },
                    );
                    this.seq = Some(seq);
                    Poll::Pending
                }
            }
        }
    }

    impl Drop for Sleep {
        fn drop(&mut self) {
            let Some(seq) = self.seq else { return };
            let mut st = self.clock.state();
            st.fired.remove(&seq);
            if let Some(e) = st.queue.remove(&(self.deadline, seq))
                && let Some(t) = e.task
            {
                t.flags().waits -= 1;
                drop(st);
                self.clock.changed.notify_waiters();
            }
        }
    }

    pub(super) async fn timeout<F: Future>(
        clock: &Arc<Virtual>,
        d: Duration,
        f: F,
    ) -> Result<F::Output, Elapsed> {
        let mut f = std::pin::pin!(f);
        let mut sleep = Sleep::new(clock, d);
        // the future first: one that is ready registers no sleeper
        std::future::poll_fn(|cx| {
            if let Poll::Ready(v) = f.as_mut().poll(cx) {
                return Poll::Ready(Ok(v));
            }
            Pin::new(&mut sleep).poll(cx).map(|()| Err(Elapsed))
        })
        .await
    }

    /// Inside a [`super::real`] wait: counted in its task's flags while it lasts.
    struct InReal {
        clock: Arc<Virtual>,
        task: Arc<Task>,
    }

    impl Drop for InReal {
        fn drop(&mut self) {
            self.task.flags().real -= 1;
            self.clock.changed.notify_waiters();
        }
    }

    pub(super) async fn real<F: Future>(f: F) -> F::Output {
        let (Some(clock), Ok(task)) = (current(), TASK.try_with(Arc::clone)) else {
            return f.await;
        };
        {
            let mut st = clock.state();
            task.flags().real += 1;
            if !st.real.iter().any(|t| Arc::ptr_eq(t, &task)) {
                st.real.push(task.clone());
            }
        }
        let _inside = InReal { clock, task };
        f.await
    }

    impl Virtual {
        pub(super) async fn settle_real(&self, within: Duration, ok: &[String]) -> Vec<String> {
            let give_up = tokio::time::Instant::now() + within;
            loop {
                let note = self.changed.notified();
                let mut note = std::pin::pin!(note);
                note.as_mut().enable();
                let waited: Vec<Arc<Task>> = {
                    let mut st = self.state();
                    // inside a real wait, or in the poll that left one
                    st.real.retain(|t| {
                        let f = t.flags();
                        !f.ended && (f.real > 0 || f.polling)
                    });
                    st.real
                        .iter()
                        .filter(|t| !ok.iter().any(|o| o == t.origin.as_str()))
                        .cloned()
                        .collect()
                };
                if waited.is_empty() || tokio::time::timeout_at(give_up, note).await.is_err() {
                    let st = self.state();
                    let mut inside: Vec<String> = st
                        .real
                        .iter()
                        .filter(|t| t.flags().real > 0)
                        .map(|t| t.origin.as_str().to_string())
                        .collect();
                    inside.sort();
                    inside.dedup();
                    return inside;
                }
            }
        }
    }

    pub(super) fn spawn<F>(origin: Origin, f: F) -> tokio::task::JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let task = Arc::new(Task {
            origin,
            ordinal: ORDINALS.fetch_add(1, Ordering::SeqCst),
            flags: Mutex::default(),
        });
        let scoped = TASK.scope(task.clone(), f);
        let Some(clock) = current() else {
            return tokio::spawn(scoped);
        };
        {
            let mut st = clock.state();
            // spawned by a task an advance woke (or by one of its own): waited for until it parks
            if st.advancing && TASK.try_with(|_| ()).is_ok() {
                st.born.push(task.clone());
            } else {
                st.fresh.retain(|t| !t.started());
                st.fresh.push(task.clone());
            }
        }
        tokio::spawn(Tracked {
            fut: Box::pin(scoped),
            task,
            clock,
        })
    }

    /// A spawned task on the virtual clock: each poll is recorded in its flags.
    struct Tracked<F: Future> {
        fut: Pin<Box<TaskLocalFuture<Arc<Task>, F>>>,
        task: Arc<Task>,
        clock: Arc<Virtual>,
    }

    impl<F: Future> Future for Tracked<F> {
        type Output = F::Output;

        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
            let this = &mut *self;
            let seen = {
                let mut f = this.task.flags();
                f.polling = true;
                f.fired
            };
            let r = this.fut.as_mut().poll(cx);
            {
                let mut f = this.task.flags();
                f.polling = false;
                f.polls += 1;
                f.seen = seen;
                f.ended |= r.is_ready();
            }
            this.clock.changed.notify_waiters();
            r
        }
    }

    impl<F: Future> Drop for Tracked<F> {
        fn drop(&mut self) {
            self.task.flags().ended = true;
            self.clock.changed.notify_waiters();
        }
    }
}

#[cfg(all(test, feature = "test-hooks"))]
mod tests;
