//! The escape harness: rows as data, run against the `ratatoskr` binary with the probe inside (Task 14; docs/develop/
//! gleipnir.md, "Proving it"). Test tooling, never shipped or installed.
//!
//! - [`row`]: the row format and its parse (closed placeholders, a control run for every `blocked`).
//! - [`fixture`]: the fixture under `/tmp/glp-XXXXXX/`, with random canaries and recording listeners.
//! - [`run`]: one row: skip with a listed reason, the control run, the sandboxed run, the comparison.
//! - [`report`]: the report file.

pub mod fixture;
pub mod report;
pub mod row;
pub mod run;
