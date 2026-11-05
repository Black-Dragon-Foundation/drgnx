//! The Linux side of a runner: what a scheduler reads about the machine ([`probe`]), the files two schedulers on one
//! machine share ([`reserve`]), and the executor.
//!
//! systemd and the cgroup files are a desktop-distro fact, so those modules are `target_os = "linux"` only. Android
//! (`target_os = "android"`) has no user manager to run jobs under: it gets none of them, and a runner there refuses
//! every job (the binary says so) instead of running one unconfined.

#[cfg(target_os = "linux")]
pub mod probe;
#[cfg(target_os = "linux")]
pub mod reserve;
#[cfg(target_os = "linux")]
mod run;
