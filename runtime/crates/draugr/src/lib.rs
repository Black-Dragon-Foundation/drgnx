//! draugr: how Ratatoskr starts and ends processes (docs/develop/hub.md, "Processes").
//!
//! - [`env`]: a child's environment, built from an allowlist; nothing else of the hub's environment reaches it.
//! - [`spawn`]: every child in its own process group, SIGPIPE ignored, stderr kept as a bounded tail, one exit;
//!   descriptors passed at fixed numbers and nothing else inherited; sandboxes forked from one pinned thread.
//! - [`starttime`]: a process's start time and the boot it belongs to, so a recorded pid is never confused with a
//!   reused one.
//! - [`reap`]: the orphan reaper, which kills the process groups a crashed hub left behind, and nothing else.
//! - [`git`]: git from a root-owned path, with overrides no repository can undo, and the trusted-repository check.

pub mod env;
pub mod git;
pub mod reap;
pub mod spawn;
pub mod starttime;

pub use reap::{RealSignaller, ReapOutcome, Record, Signaller, Skip, alive, kill_group, reap};
pub use spawn::{Child, PassFd, Spec, spawn, spawn_pinned};
pub use starttime::{boot_id, start_time};
