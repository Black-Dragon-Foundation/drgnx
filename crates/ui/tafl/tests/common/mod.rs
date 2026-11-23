//! What the engine's tests share: an engine on the sandbox's virtual clock, and instance keys.

#![allow(dead_code)]

use std::sync::Arc;

use tafl::{Engine, InstanceKey};

/// A sandbox (temp HOME, virtual clock) and an engine whose clock is the sandbox's, with a two-thread pool.
pub fn engine() -> (raun::Sandbox, Engine) {
    let sb = raun::Sandbox::new();
    let pool = Arc::new(saman::Executor::new(2).expect("the work pool"));
    let e = Engine::new(pool, Arc::new(sb.clock().clone()));
    (sb, e)
}

/// An engine on a fresh virtual clock and one pool shared by the process: for property tests, which make thousands.
pub fn engine_light() -> Engine {
    static POOL: std::sync::OnceLock<Arc<saman::Executor>> = std::sync::OnceLock::new();
    let pool = POOL
        .get_or_init(|| Arc::new(saman::Executor::new(1).expect("the work pool")))
        .clone();
    Engine::new(pool, Arc::new(stund::Manual::default()))
}

/// The instance key of document DOC at PATH.
pub fn key(doc: &str, path: &[u32]) -> InstanceKey {
    InstanceKey {
        doc: Arc::from(doc),
        path: Arc::from(path),
    }
}
