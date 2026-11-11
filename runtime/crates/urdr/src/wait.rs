//! A caller's wait for a store thread's answer (the store's thread, the graph writer's, a read pool's blocking
//! thread), told to whoever asked (test-hooks): the hub's test clock marks the task that waits, so a test's barrier
//! waits for the answer and what the task does with it (docs/develop/hub.md, "The sequencer and the barrier").

use std::any::Any;
use std::panic::Location;
use std::sync::OnceLock;

/// Called as a wait for a store thread's answer begins, with the urdr line that waits (a barrier's report names it);
/// what it returns is dropped as the wait ends.
pub type Hook = fn(&'static Location<'static>) -> Box<dyn Any + Send>;

static HOOK: OnceLock<Hook> = OnceLock::new();

/// HOOK, for every wait of this process from now on.  Once: a later call is ignored.
pub fn set(hook: Hook) {
    let _ = HOOK.set(hook);
}

/// The hook's guard for one wait (none without a hook), at the caller's line.
#[track_caller]
pub(crate) fn begin() -> Option<Box<dyn Any + Send>> {
    let at = Location::caller();
    HOOK.get().map(|h| h(at))
}
