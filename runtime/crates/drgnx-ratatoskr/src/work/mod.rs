//! The hub's Work-space facts: what each step read, searched or fetched, and the cores built on it (agent system
//! part 2; docs/develop/work-space.md).  The pure parts take no clock and do no I/O.
//!
//! - [`detail`]: a step's detail by tool name.
//! - [`machines`]: the machines the hub lists (`local`, and those jobq reports with `machines/report`).
//! - [`shell_read`]: the files a shell command names, parsed from its text and kept inside the workspace (layer 1 of
//!   "reads through shell commands").

pub mod detail;
pub mod machines;
pub mod shell_read;
