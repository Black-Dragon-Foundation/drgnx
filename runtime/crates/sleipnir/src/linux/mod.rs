//! The Linux side of a runner: what a scheduler reads about the machine ([`probe`]), the files two schedulers on one
//! machine share ([`reserve`]), and the executor: the slice tree ([`slices`]), a job's unit ([`unit`]), job-exec
//! ([`jobexec`]) and its `result.json` ([`result`]), the row parsers ([`parse`]), the one podman argv ([`podman`]), whether podman can run a networked job ([`netcheck`]) and
//! jobq's shim ([`shim`]).
//!
//! systemd and the cgroup files are a desktop-distro fact, so those modules are `target_os = "linux"` only. Android
//! (`target_os = "android"`) has no user manager to run jobs under: it gets none of them, and a runner there refuses
//! every job (the binary says so) instead of running one unconfined. The argv, the shim, the parsers and the result
//! are pure and build everywhere: a hub on macOS runs its container jobs with the same argv.

pub mod netcheck;
pub mod parse;
pub mod podman;
pub mod result;
pub mod shim;

#[cfg(target_os = "linux")]
pub mod jobexec;
#[cfg(target_os = "linux")]
pub mod probe;
#[cfg(target_os = "linux")]
pub mod reserve;
#[cfg(target_os = "linux")]
pub(crate) mod run;
#[cfg(target_os = "linux")]
pub mod slices;
#[cfg(target_os = "linux")]
pub mod unit;
