//! Where guest code runs: a tokio runtime of the host's own (`brokkr-guest` threads), never the caller's workers.
//!
//! A guest in a tight loop never yields to its executor until its epoch deadline traps, so a guest on the hub's two
//! workers would hold one of them for its whole deadline. Every call is admitted by two semaphores (the plugin's,
//! then the global one), each waited for up to the call's deadline, and then runs on the guest runtime; the caller
//! only awaits its result. The epoch ticker is a thread that bumps the engine's epoch every [`EPOCH_TICK`].

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use stund::Instant;

use crate::host::CallError;
use crate::limits::{CALLER_GRACE, EPOCH_TICK, Limits};

/// The guest runtime, the semaphores and the epoch ticker.
pub(crate) struct Guest {
    rt: Option<saman::Executor>,
    global: Arc<Semaphore>,
    guest_calls: usize,
    per_plugin: Mutex<HashMap<String, Arc<Semaphore>>>,
    calls_per_plugin: usize,
}

/// The two permits a running call holds; dropped when the guest's task ends, not when its caller stops waiting.
pub(crate) struct Permits {
    _plugin: OwnedSemaphorePermit,
    _global: OwnedSemaphorePermit,
}

impl Guest {
    pub(crate) fn new(limits: &Limits, engine: &wasmtime::Engine) -> std::io::Result<Guest> {
        let rt = saman::Executor::tuned(limits.guest_calls, |b| {
            b.thread_name("brokkr-guest");
        })
        .map_err(std::io::Error::other)?;
        let weak = engine.weak();
        // Ends once the host and every store are gone, so a guest still running after its host was dropped is still
        // stopped at its deadline.
        // the ticker keeps real time whatever clock a test installs: a guest's epoch deadline is a real one
        saman::spawn_thread("brokkr-epoch", move || {
            while let Some(engine) = weak.upgrade() {
                engine.increment_epoch();
                drop(engine);
                stund::real::sleep_blocking(EPOCH_TICK);
            }
        })
        .map_err(std::io::Error::other)?;
        Ok(Guest {
            rt: Some(rt),
            global: Arc::new(Semaphore::new(limits.guest_calls)),
            guest_calls: limits.guest_calls,
            per_plugin: Mutex::new(HashMap::new()),
            calls_per_plugin: limits.calls_per_plugin,
        })
    }

    /// How many guest calls hold the global permit now.
    pub(crate) fn running(&self) -> usize {
        self.guest_calls - self.global.available_permits()
    }

    fn plugin_semaphore(&self, plugin: &str) -> Arc<Semaphore> {
        let mut map = saman::lock(&self.per_plugin);
        map.entry(plugin.to_string())
            .or_insert_with(|| Arc::new(Semaphore::new(self.calls_per_plugin)))
            .clone()
    }

    /// Takes the plugin's permit, then a global one, both by `until`; `Busy` when either is not free by then. The
    /// plugin's comes first, so a plugin's queued calls never hold global permits that other plugins could use.
    pub(crate) async fn admit(&self, plugin: &str, until: Instant) -> Result<Permits, CallError> {
        let one = self.plugin_semaphore(plugin);
        let plugin = stund::timeout(
            until.saturating_duration_since(Instant::now()),
            one.acquire_owned(),
        )
        .await
        .map_err(|_| CallError::Busy)?
        .map_err(|_| CallError::Busy)?;
        let global = stund::timeout(
            until.saturating_duration_since(Instant::now()),
            self.global.clone().acquire_owned(),
        )
        .await
        .map_err(|_| CallError::Busy)?
        .map_err(|_| CallError::Busy)?;
        Ok(Permits {
            _plugin: plugin,
            _global: global,
        })
    }

    /// Runs `work` on the guest runtime with its permits, and waits for its result up to `left` plus
    /// [`CALLER_GRACE`]: past that the caller answers `Timeout` at once, while the guest is still stopped by its epoch
    /// deadline on its own thread.
    pub(crate) async fn run<T, F>(
        &self,
        permits: Permits,
        left: Duration,
        work: F,
    ) -> Result<T, CallError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, CallError>> + Send + 'static,
    {
        let Some(rt) = self.rt.as_ref() else {
            return Err(CallError::Refused(
                "the plugin host is shutting down".into(),
            ));
        };
        let task = rt.spawn("guest-call", async move {
            let _permits = permits;
            match stund::timeout(left, work).await {
                Ok(r) => r,
                Err(_) => Err(CallError::Timeout),
            }
        });
        match stund::timeout(left + CALLER_GRACE, task).await {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => Err(CallError::Trap(format!("the guest's task ended: {e}"))),
            Err(_) => Err(CallError::Timeout),
        }
    }
}

impl Drop for Guest {
    fn drop(&mut self) {
        // never blocks: a guest still spinning ends at its epoch deadline on its own thread
        if let Some(rt) = self.rt.take() {
            rt.shutdown_background();
        }
    }
}
