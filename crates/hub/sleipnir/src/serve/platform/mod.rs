//! What `serve` asks of the machine it runs on (`docs/develop/sleipnir.md`, "Platforms"): the probe and the contract,
//! the reservations between schedulers, starting, watching and stopping attempts, the caps (pause, grow, CPU
//! weights), keys and the cleanup of what the attempts leave. `serve`'s protocol loop reaches the machine only through
//! a [`Platform`]: [`LinuxPlatform`] (transient systemd units in job slices, containers under rootless podman, cgroups
//! and PSI) on Linux, [`DarwinPlatform`] (host jobs under Seatbelt, started in their own session) on a Mac.

use super::Pins;
use super::attempts::Meta;
use super::cleanup;
use crate::linux::reserve::Reservations;
use crate::linux::resize::{Resize, Sized};
use crate::proto::{Facts, Missing};
use forseti::{Limits, MachineState, Profile};
use std::io;
use std::path::Path;

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
pub use darwin::DarwinPlatform;
#[cfg(target_os = "linux")]
pub use linux::LinuxPlatform;
#[cfg(all(test, target_os = "linux"))]
pub(in crate::serve) use linux::{job_caps, mount_of, net_helper, unallocated};

/// The owner's disk cap a runner's own config sets, GB: the `quota_gb = N` line under `[disk]` of its `runner.conf`.
/// Only that one shape is read (a TOML subset); anything else is ignored. The hub's value can lower it, never raise it
/// ([`forseti::disk::owners_quota`]).
pub fn disk_quota_gb(text: &str) -> Option<u64> {
    let mut in_disk = false;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_disk = line == "[disk]";
        } else if in_disk
            && let Some(v) = line
                .strip_prefix("quota_gb")
                .map(str::trim_start)
                .and_then(|r| r.strip_prefix('='))
        {
            return v.trim().parse().ok();
        }
    }
    None
}

/// An attempt to start, as `serve` hands it to [`Platform::launch`]: its folder and record, the source it runs on,
/// and what the hub's `start` said.
pub struct LaunchReq<'a> {
    pub dir: &'a Path,
    pub meta: &'a Meta,
    pub src: &'a Path,
    pub image: Option<String>,
    pub env: &'a [(String, String)],
    pub net_hosts: &'a [String],
    pub pins: Pins,
    pub parser: &'a str,
}

/// The machine under `serve`. Every call is blocking and short; none prompts.
pub trait Platform {
    /// The machine as `forseti` reads it at NOW (the other schedulers' live reservations included).
    fn machine(&self, now: u64, limits: &Limits) -> io::Result<MachineState>;
    /// The admission limits of PROFILE on this machine.
    fn limits(&self, profile: Profile) -> Limits;
    /// This boot (empty when it can't be read).
    fn boot_id(&self) -> String;
    /// The runner contract: the facts, or every item missing with its fix.
    fn contract(&self) -> Result<Facts, Vec<Missing>>;
    /// Whether attempts outlive the link (Linux: linger).
    fn survives_link(&self) -> bool;
    /// What the job runner can't do here (none: it can), and the features it gives jobs.
    fn job_runner(&self) -> (Option<String>, Vec<String>);
    /// The reservations between schedulers on this machine.
    fn reservations(&self) -> Reservations;
    /// The start time of process PID, as the reservations compare it.
    fn start_time(&self, pid: u32) -> io::Result<u64>;
    /// Job ID's memory in use, MiB, where it can be read.
    fn current_mib(&self, id: &str) -> Option<u64>;
    /// Starts the attempt (its `job.json` written, job-exec running past this `serve`): the name the attempt runs
    /// under (its unit) and job-exec's pid (0 when unknown).
    fn launch(&self, req: &LaunchReq) -> villa::Result<(String, u32)>;
    /// Whether the attempt running under UNIT is still up.
    fn active(&self, unit: &str) -> bool;
    /// Kills job ID's command; job-exec sees it end and writes the verdict the reason written before names.
    fn kill(&self, id: &str) -> villa::Result<()>;
    /// Pauses job ID (the ladder's long builds).
    fn pause(&self, id: &str) -> villa::Result<()>;
    /// Lets a paused job ID go on.
    fn unpause(&self, id: &str) -> villa::Result<()>;
    /// Job ID as a grow judges it, when it runs near its cap CAP_MIB (MAX_MIB its most); none: not near, or no grow
    /// on this platform.
    fn grow_candidate(&self, id: &str, cap_mib: u64, max_mib: u64) -> Option<Sized>;
    /// Carries a grow out.
    fn resize(&self, r: &Resize) -> villa::Result<()>;
    /// What job ID's CPU weight is set on; none: no weights on this platform.
    fn weight_unit(&self, id: &str) -> Option<String>;
    /// Sets the CPU weight of UNIT.
    fn set_weight(&self, unit: &str, w: u32) -> villa::Result<()>;
    /// Hands key NAME's VALUE to the job helper of the attempt in DIR. `NotFound` or `ConnectionRefused`: the helper
    /// isn't listening yet (the key waits); any other error ends the key.
    fn hand_key(&self, dir: &Path, name: &str, value: &[u8]) -> io::Result<()>;
    /// Removes what this hub's attempts left under ROOT and on the machine (only OWNER's prefixed, labelled items).
    fn cleanup(&self, root: &Path, owner: &cleanup::Owner);
    /// The ladder's level from the kernel's own memory-pressure event (a Mac's), when the platform has one: it sets
    /// the ladder in place of PSI, and a kill it calls for is an eviction (the user's own load, not the runner's fault).
    /// None: the ladder reads the machine (`forseti::ladder_level`).
    fn pressure(&self) -> Option<forseti::safety::Level> {
        None
    }
    /// Whether ISLAND (`--island`) may be this machine's timing island: whole L3 groups. A platform without a timing
    /// lane refuses any.
    fn island_check(&self, island: &str) -> villa::Result<()> {
        Err(villa::Error::unavailable(format!(
            "this platform has no timing lane (--island {island})"
        )))
    }
    /// The island on (its CPU list: timing jobs there, work on the rest) or off (work on every CPU again).
    fn island(&self, _on: Option<&str>) -> villa::Result<()> {
        Ok(())
    }
    /// The runner folder ROOT's filesystem, as the disk guard reads it (`statvfs`).
    fn df(&self, root: &Path) -> io::Result<crate::sync::guard::Df> {
        crate::sync::guard::df(root)
    }
    /// The unallocated bytes of ROOT's filesystem when it is btrfs (sysfs, no root); none otherwise.
    fn btrfs_unallocated(&self, _root: &Path) -> Option<u64> {
        None
    }
    /// The machine owner's cap on what drgnx keeps here, GB (`runner.conf` `[disk] quota_gb`); none: no cap of its own.
    fn disk_quota_gb(&self) -> Option<u64> {
        None
    }
}
