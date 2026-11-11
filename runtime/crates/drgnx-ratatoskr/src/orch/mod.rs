//! Orchestration in the hub (`docs/develop/orchestration.md`): the gates on the plan runner, on facts the hub
//! recorded itself.  The pure parts are the `vordr` crate's.
//!
//! - [`evidence`]: a task's jobs as `red` / `green` evidence; `orch/evidence`.

pub mod evidence;
