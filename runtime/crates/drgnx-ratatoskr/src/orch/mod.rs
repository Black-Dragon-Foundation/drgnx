//! Orchestration in the hub (`docs/develop/orchestration.md`): the gates on the plan runner, on facts the hub
//! recorded itself.  The pure parts are the `vordr` crate's.
//!
//! - [`evidence`]: a task's jobs as `red` / `green` evidence; `orch/evidence`.
//! - [`policy`]: the rule pack a job was approved with, and the policy files read at the line's base.
//! - [`red_first`]: the red-first gate before a task's merge.
//! - [`gates`]: the gates before a task's merge, the runs they start, waivers.
//! - [`notes`]: the merge notes a task's merges need.
//! - [`queue`]: the merge queue's batches.
//! - [`groups`]: the affected groups a batch runs before it merges.
//! - [`push`]: the push gate, one full run on the exact commit before a job's agent pushes.

pub mod evidence;
pub mod gates;
pub mod groups;
pub mod notes;
pub mod policy;
pub mod push;
pub mod queue;
pub mod red_first;
