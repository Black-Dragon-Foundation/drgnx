//! vordr: the orchestration gates' pure core (`docs/develop/orchestration.md`).
//!
//! The hub's gates read only records it wrote itself; this crate holds the parts of them that need no I/O, so each
//! is tested on its own:
//!
//! - [`rows`]: a job's log read as rows (a name, a verdict and, for a failure, its class), for cargo test, ERT and
//!   domr output alike.
//!
//! No clock, no threads, no files: `serde` only.

pub mod rows;
