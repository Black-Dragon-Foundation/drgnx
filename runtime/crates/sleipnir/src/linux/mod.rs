//! The Linux side of a runner: what a scheduler reads about the machine ([`probe`]), the files two schedulers on one
//! machine share ([`reserve`]), and the executor: the slice tree ([`slices`]), a job's unit ([`unit`]), job-exec
//! ([`jobexec`]) and its `result.json` ([`result`]), a job's disk watch ([`disk`]), live resizing ([`resize`]), the row parsers ([`parse`]), the one
//! podman argv ([`podman`]), whether podman can run a networked job ([`netcheck`]), a confined SELinux login that can't
//! run containers ([`confined`]) and jobq's shim ([`shim`]).
//!
//! systemd and the cgroup files are a desktop-distro fact, so those modules are `target_os = "linux"` only. Android
//! (`target_os = "android"`) has no user manager to run jobs under: it gets none of them, and a runner there refuses
//! every job (the binary says so) instead of running one unconfined. The argv, the shim, the parsers and the result
//! are pure and build everywhere: a hub on macOS runs its container jobs with the same argv.

pub mod confined;
pub mod netcheck;
pub mod parse;
pub mod podman;
pub mod result;
pub mod shim;

/// also a Mac's job-exec's (no job helper there)
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod disk;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod jobexec;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod probe;
/// also a Mac runner's (its start times from `proc_pidinfo`)
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod reserve;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod resize;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) mod run;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod slices;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod unit;
