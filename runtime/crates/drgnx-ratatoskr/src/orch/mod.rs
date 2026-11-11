//! Orchestration in the hub (`docs/develop/orchestration.md`): the gates on the plan runner, on facts the hub
//! recorded itself.  The pure parts are the `vordr` crate's.
//!
//! - [`evidence`]: a task's jobs as `red` / `green` evidence; `orch/evidence`.
//! - [`policy`]: the rule pack a job was approved with, and the policy files read at the line's base.
//! - [`red_first`]: the red-first gate before a task's merge.

pub mod evidence;
pub mod policy;
pub mod red_first;
