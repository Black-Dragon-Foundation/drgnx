//! drgnx-proc: how Ratatoskr starts and ends processes (docs/develop/hub.md, "Processes").
//!
//! - [`env`]: a child's environment, built from an allowlist; nothing else of the hub's environment reaches it.
//! - [`spawn`]: every child in its own process group, SIGPIPE ignored, stderr kept as a bounded tail, one exit.
//! - [`starttime`]: a process's start time and the boot it belongs to, so a recorded pid is never confused with a
//!   reused one.
//! - [`reap`]: the orphan reaper, which kills the process groups a crashed hub left behind, and nothing else.

pub mod env;
pub mod reap;
pub mod spawn;
pub mod starttime;

pub use reap::{RealSignaller, ReapOutcome, Record, Signaller, Skip, kill_group, reap};
pub use spawn::{Child, Spec, spawn};
pub use starttime::{boot_id, start_time};
