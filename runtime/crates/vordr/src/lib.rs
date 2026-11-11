//! vordr: the orchestration gates' pure core (`docs/develop/orchestration.md`).
//!
//! The hub's gates read only records it wrote itself; this crate holds the parts of them that need no I/O, so each
//! is tested on its own:
//!
//! - [`rows`]: a job's log read as rows (a name, a verdict and, for a failure, its class), for cargo test, ERT and
//!   domr output alike.
//! - [`facts`]: what a job ran on (tree key, env stamp, platform, selector), which evidence must match.
//! - [`evidence`]: one fact a gate reads, bound to a task.
//! - [`pack`]: a rule pack (the gates' rules and parameters) and the policy paths a tip can't change alone.
//! - [`redfirst`], [`gates`]: red first, trailers, the author check, waivers.
//! - [`notes`]: a merge's structured intent notes and what they must cover.
//! - [`batch`]: the merge queue's next batch.
//!
//! No clock, no threads, no files: `serde` only.

pub mod batch;
pub mod evidence;
pub mod facts;
pub mod gates;
pub mod notes;
pub mod pack;
pub mod redfirst;
pub mod rows;
