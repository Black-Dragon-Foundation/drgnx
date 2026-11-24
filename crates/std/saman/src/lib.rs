//! saman (*saman*, together): concurrency (docs/develop/standards/concurrency.md).
//!
//! - [`lock`]: a mutex's guard, also after a holder panicked (the poison is cleared; the first recovery is logged).
//! - [`Executor`]: the one tokio runtime of the work pool. [`Executor::spawn`] names each task and gives a [`Task`],
//!   which cancels the task when dropped; [`Task::detach`] lets it run on and must say why.
//! - [`Handle`]: spawns on one pool from another runtime's thread.
//! - [`Cancel`]: a cancellation token; [`Cancel::child`] is cancelled with its parent.
//! - [`spawn_thread`]: a named OS thread, for what must own one.
//! - [`ui`]: [`ui::UiQueue::post`], the only way back to the UI thread, and the [`ui::Watchdog`] that times every UI
//!   handler.
//!
//! This crate owns the concurrency standard: nothing else starts a thread or a runtime, spawns a tokio task or locks a
//! `std::sync::Mutex` directly.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};

/// M's guard, also when a holder panicked: the data a panicking holder left is what the next caller sees.
pub fn lock<T: ?Sized>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock()
        .unwrap_or_else(|poisoned: PoisonError<MutexGuard<'_, T>>| {
            static LOGGED: AtomicBool = AtomicBool::new(false);
            if !LOGGED.swap(true, Ordering::Relaxed) {
                tracing::warn!(
                    "a lock's holder panicked; the lock was recovered (logged once per process)"
                );
            }
            poisoned.into_inner()
        })
}

/// F on a new OS thread named NAME, for what must own a thread (a blocking read of a descriptor, a UI toolkit's own
/// loop, a test's second thread); background work that can be a future goes on the [`Executor`]. [`villa::Kind::Unavailable`]
/// when the system gives no thread.
pub fn spawn_thread<F, T>(name: &str, f: F) -> villa::Result<std::thread::JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    spawn_thread_with_stack(name, None, f)
}

/// [`spawn_thread`] with a stack of STACK bytes (`None`: the system's default), for a thread that needs a deep or a
/// deliberately small stack.
pub fn spawn_thread_with_stack<F, T>(
    name: &str,
    stack: Option<usize>,
    f: F,
) -> villa::Result<std::thread::JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let mut b = std::thread::Builder::new().name(name.to_string());
    if let Some(bytes) = stack {
        b = b.stack_size(bytes);
    }
    b.spawn(f).map_err(|e| {
        villa::Error::unavailable("The editor could not start a thread.")
            .with_detail(format!("starting thread {name}"))
            .with_source(e)
    })
}

/// The work pool's runtime.
pub struct Executor {
    rt: tokio::runtime::Runtime,
}

impl Executor {
    /// A pool of WORKERS threads (at least one), named `saman-worker`.
    pub fn new(workers: usize) -> villa::Result<Executor> {
        Executor::tuned(workers, |_| {})
    }

    /// [`Executor::new`], with TUNE applied to the runtime's builder first: for a test that must watch the pool's
    /// threads come and go (`thread_keep_alive`, `on_thread_stop`).
    pub fn tuned(
        workers: usize,
        tune: impl FnOnce(&mut tokio::runtime::Builder),
    ) -> villa::Result<Executor> {
        let mut builder = tokio::runtime::Builder::new_multi_thread();
        builder
            .worker_threads(workers.max(1))
            .thread_name("saman-worker")
            .enable_all();
        tune(&mut builder);
        let rt = builder
            .build()
            .map_err(|e| villa::Error::from(e).with_detail("starting the work pool"))?;
        Ok(Executor { rt })
    }

    /// FUT on the pool, as a task named NAME. Dropping the [`Task`] cancels it.
    pub fn spawn<F>(&self, name: &'static str, fut: F) -> Task<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        Task {
            name,
            handle: Some(self.rt.spawn(fut)),
        }
    }

    /// Run FUT to its end on this thread: for a command-line tool or a test, never on the UI thread.
    pub fn block_on<F: Future>(&self, fut: F) -> F::Output {
        self.rt.block_on(fut)
    }

    /// A [`Handle`] to this pool, for code that spawns on it from another runtime's thread.
    pub fn handle(&self) -> Handle {
        Handle(self.rt.handle().clone())
    }

    /// End the pool without waiting for its tasks: one that never yields (a guest spinning until its deadline) ends on
    /// its own thread, and this call returns at once. Consumes the pool, so nothing can spawn on it after.
    pub fn shutdown_background(self) {
        self.rt.shutdown_background();
    }
}

/// A way to spawn on one pool from outside it: the pool the caller was started on ([`Handle::current`]) or one's
/// [`Executor::handle`]. [`spawn`] goes to the runtime the caller is running in; a handle goes to the one it names.
#[derive(Clone)]
pub struct Handle(tokio::runtime::Handle);

impl Handle {
    /// The pool the calling thread runs in; [`villa::Kind::Invalid`] outside one.
    pub fn current() -> villa::Result<Handle> {
        tokio::runtime::Handle::try_current()
            .map(Handle)
            .map_err(|e| {
                villa::Error::invalid("There is no work pool on this thread.").with_source(e)
            })
    }

    /// FUT on this handle's pool, as a task named NAME. Dropping the [`Task`] cancels it.
    pub fn spawn<F>(&self, name: &'static str, fut: F) -> Task<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        Task {
            name,
            handle: Some(self.0.spawn(fut)),
        }
    }
}

/// Whether SENT, the result of a send on a channel (`mpsc`, `oneshot`, `watch`), reached a receiver. A receiver that is
/// gone is the ordinary end of a task whose listener left, so it is logged at debug under WHAT and never an error.
pub fn delivered<T, E>(sent: Result<T, E>, what: &str) -> bool {
    let ok = sent.is_ok();
    if !ok {
        tracing::debug!(what, "nobody was listening");
    }
    ok
}

/// FUT to its end on a new current-thread runtime: what `#[tokio::test]` gives a test, for a test that must not name the
/// runtime builder itself. Never from a runtime thread nor the UI thread.
pub fn block_on_current<F: Future>(fut: F) -> F::Output {
    match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt.block_on(fut),
        Err(e) => panic!("no current-thread runtime: {e}"),
    }
}

/// FUT as a task named NAME on the runtime the caller is running in (an [`Executor`] task, a `#[tokio::test]`, a
/// server's accept loop): for code that has no [`Executor`] of its own to call. Panics outside a runtime, as tokio's
/// own spawn does. Dropping the [`Task`] cancels it.
pub fn spawn<F>(name: &'static str, fut: F) -> Task<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    Task {
        name,
        handle: Some(tokio::spawn(fut)),
    }
}

/// F on a blocking thread of the runtime the caller is running in, as a task named NAME.
pub fn spawn_blocking<F, T>(name: &'static str, f: F) -> Task<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    Task {
        name,
        handle: Some(tokio::task::spawn_blocking(f)),
    }
}

/// A spawned task. Awaiting it gives its output, or an error: [`villa::Kind::Cancelled`] when it was cancelled,
/// [`villa::Kind::Internal`] when it panicked. Dropping it cancels the task.
pub struct Task<T> {
    name: &'static str,
    handle: Option<tokio::task::JoinHandle<T>>,
}

impl<T> Task<T> {
    pub fn name(&self) -> &'static str {
        self.name
    }

    /// Whether the task has ended (finished, panicked or been cancelled). A detached task reports `true`.
    pub fn is_finished(&self) -> bool {
        self.handle.as_ref().is_none_or(|h| h.is_finished())
    }

    /// Let the task run on with no one awaiting it. WHY is logged: a detached task is a decision, never a default.
    pub fn detach(mut self, why: &'static str) {
        tracing::debug!(task = self.name, why, "task detached");
        self.handle = None;
    }
}

impl<T> Future for Task<T> {
    type Output = villa::Result<T>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let name = self.name;
        let Some(handle) = self.handle.as_mut() else {
            return Poll::Ready(Err(villa::Error::internal("A detached task was awaited.")));
        };
        Pin::new(handle).poll(cx).map(|r| {
            r.map_err(|e| {
                if e.is_cancelled() {
                    villa::Error::cancelled("The task was cancelled.").with_detail(name)
                } else {
                    villa::Error::internal("A background task failed.")
                        .with_detail(format!("task `{name}` panicked"))
                }
            })
        })
    }
}

impl<T> Drop for Task<T> {
    fn drop(&mut self) {
        if let Some(h) = self.handle.take() {
            h.abort();
        }
    }
}

/// A cancellation token. Work checks it at its awaits ([`Cancel::cancelled`]); a [`Cancel::child`] is cancelled with
/// its parent, never the other way.
#[derive(Clone, Default)]
pub struct Cancel(tokio_util::sync::CancellationToken);

impl Cancel {
    pub fn new() -> Cancel {
        Cancel::default()
    }

    /// A token cancelled when this one is (and on its own).
    pub fn child(&self) -> Cancel {
        Cancel(self.0.child_token())
    }

    pub fn cancel(&self) {
        self.0.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }

    /// Ready once this token is cancelled.
    pub async fn cancelled(&self) {
        self.0.cancelled().await;
    }
}

pub mod ui {
    //! The UI thread's side: a queue of closures posted from anywhere, run between frames, each timed.

    use std::sync::mpsc;
    use std::time::Duration;

    /// What a UI closure gets: the UI's state as it grows (for now the frame count).
    #[derive(Debug, Default)]
    pub struct UiCx {
        pub frame: u64,
    }

    type Job = Box<dyn FnOnce(&mut UiCx) + Send>;

    /// The sending side, for any thread or task.
    #[derive(Clone)]
    pub struct UiQueue {
        tx: mpsc::Sender<(&'static str, Job)>,
    }

    impl UiQueue {
        /// F to run on the UI thread at its next frame. [`villa::Kind::Unavailable`] once the UI loop is gone.
        pub fn post<F: FnOnce(&mut UiCx) + Send + 'static>(&self, f: F) -> villa::Result<()> {
            self.tx
                .send((std::any::type_name::<F>(), Box::new(f)))
                .map_err(|_| villa::Error::unavailable("The window is closed."))
        }
    }

    /// The UI thread's side: it runs what was posted, never blocking.
    pub struct UiLoop {
        rx: mpsc::Receiver<(&'static str, Job)>,
        dog: Watchdog,
    }

    impl UiLoop {
        /// Run every closure posted so far, each under the watchdog; how many ran. Never waits.
        pub fn run_pending(&mut self, cx: &mut UiCx) -> usize {
            let mut n = 0;
            while let Ok((name, job)) = self.rx.try_recv() {
                self.dog.run(name, || job(cx));
                n += 1;
            }
            n
        }
    }

    /// A UI queue and its loop.
    pub fn queue() -> (UiQueue, UiLoop) {
        let (tx, rx) = mpsc::channel();
        (
            UiQueue { tx },
            UiLoop {
                rx,
                dog: Watchdog::default(),
            },
        )
    }

    /// Times UI handlers on the installed clock (`stund::now`): over `warn` (8 ms) a warning, over `error`
    /// (100 ms) an error event, each with the handler's name.
    #[derive(Debug, Clone)]
    pub struct Watchdog {
        pub warn: Duration,
        pub error: Duration,
    }

    impl Default for Watchdog {
        fn default() -> Watchdog {
            Watchdog {
                warn: Duration::from_millis(8),
                error: Duration::from_millis(100),
            }
        }
    }

    impl Watchdog {
        /// F, timed as the handler NAME.
        pub fn run<R>(&self, name: &str, f: impl FnOnce() -> R) -> R {
            let start = stund::now();
            let r = f();
            let took = stund::now().saturating_sub(start);
            let ms = u64::try_from(took.as_millis()).unwrap_or(u64::MAX);
            if took > self.error {
                tracing::error!(handler = name, ms, "a UI handler held the UI thread");
            } else if took > self.warn {
                tracing::warn!(handler = name, ms, "a UI handler was slow");
            }
            r
        }
    }
}
