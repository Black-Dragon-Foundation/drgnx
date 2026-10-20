//! The orphan reaper (docs/develop/hub.md, "The orphan reaper"): at start, Ratatoskr kills the process groups a
//! crashed hub recorded in `runtime.db`, and only those.
//!
//! Every signal, the `0` probes included, goes through a [`Signaller`], so tests can watch what would be sent.

use std::io;
use std::time::Duration;

/// A `runtime.db` process row as read: any column may be NULL.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    pub pid: Option<i32>,
    pub start_time: Option<u64>,
    pub pgid: Option<i32>,
    pub boot_id: Option<String>,
}

/// Why a record was left alone without a look at its processes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Skip {
    /// `pid`, `pgid`, `start_time` or `boot_id` is NULL.
    NoPid,
    /// The group is one nobody may kill: `pgid <= 1`, our own group or our session leader's, or the pid is ours.
    Refused,
    /// Recorded in another boot.
    OtherBoot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReapOutcome {
    /// The group was signalled and no longer exists.
    Killed,
    /// The recorded pid now belongs to another process (another start time): left alone.
    Reused,
    /// Neither the leader nor the group exists.
    Gone,
    Skipped(Skip),
    /// Signalling failed, or the group outlived SIGKILL by [`KILL_WAIT`].
    Failed(io::ErrorKind),
}

/// Sends signals: `kill(2)` semantics, a negative `target` names a process group.
pub trait Signaller: Sync {
    fn kill(&self, target: i32, sig: i32) -> io::Result<()>;
}

/// `libc::kill`. It refuses `target` 0 and -1 (the caller's group and every process of the user) whatever its caller
/// asks.
pub struct RealSignaller;

impl Signaller for RealSignaller {
    fn kill(&self, target: i32, sig: i32) -> io::Result<()> {
        if target == 0 || target == -1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "kill(0) and kill(-1) are never sent",
            ));
        }
        // SAFETY: kill(2) has no memory effects.
        if unsafe { libc::kill(target, sig) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

/// SIGTERM to SIGKILL.
pub const GRACE: Duration = Duration::from_secs(2);
/// How long after SIGKILL the group may take to go before the reaper reports [`ReapOutcome::Failed`].
pub const KILL_WAIT: Duration = Duration::from_secs(5);
/// How often the reaper probes a group it signalled.
const POLL: Duration = Duration::from_millis(20);

/// Reap each record, in order (one outcome per record), by the rule in hub.md:
/// 1. a NULL `pid`, `pgid`, `start_time` or `boot_id` → `Skipped(NoPid)`, nothing signalled;
/// 2. a group nobody may kill ([`refused`]) or our own pid → `Skipped(Refused)`;
/// 3. another boot (or ours unknown) → `Skipped(OtherBoot)`;
/// 4. the leader alive, not a zombie, with the recorded start time → reap;
/// 5. the leader alive with another start time → `Reused` (a live group with that id is the new process's);
/// 6. the leader dead and the group alive → reap: POSIX does not reuse a group id while the group exists;
/// 7. otherwise `Gone`.
pub async fn reap(records: &[Record], sig: &dyn Signaller) -> Vec<ReapOutcome> {
    let boot = crate::starttime::boot_id().ok();
    let mut out = Vec::with_capacity(records.len());
    for r in records {
        out.push(reap_one(r, boot.as_deref(), sig).await);
    }
    out
}

async fn reap_one(r: &Record, boot: Option<&str>, sig: &dyn Signaller) -> ReapOutcome {
    let (Some(pid), Some(start_time), Some(pgid), Some(rec_boot)) =
        (r.pid, r.start_time, r.pgid, r.boot_id.as_deref())
    else {
        return ReapOutcome::Skipped(Skip::NoPid);
    };
    if refused(pgid) || pid <= 1 || pid == std::process::id() as i32 {
        return ReapOutcome::Skipped(Skip::Refused);
    }
    if boot != Some(rec_boot) {
        return ReapOutcome::Skipped(Skip::OtherBoot);
    }
    if probe(sig, pid) {
        match crate::starttime::stat(pid) {
            Ok(s) if !s.zombie => {
                return if s.start_time == start_time {
                    terminate(pgid, GRACE, sig).await
                } else {
                    ReapOutcome::Reused
                };
            }
            // A zombie, or it exited after the probe: the leader is dead.
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            // Alive but unreadable: its start time cannot be checked, so nothing is signalled.
            Err(e) => return ReapOutcome::Failed(e.kind()),
        }
    }
    if probe(sig, -pgid) {
        return terminate(pgid, GRACE, sig).await;
    }
    ReapOutcome::Gone
}

/// SIGTERM to the group `-pgid`, SIGKILL after `grace`, then wait for it to go; with the refusals of [`reap`].
pub async fn kill_group(pgid: i32, grace: Duration, sig: &dyn Signaller) -> ReapOutcome {
    if refused(pgid) {
        return ReapOutcome::Skipped(Skip::Refused);
    }
    terminate(pgid, grace, sig).await
}

/// Groups nobody may signal: `pgid <= 1` (`kill(-1)` reaches every process of the user, `kill(0)` our own group),
/// our own group, and our session leader's (for example the terminal's shell).
fn refused(pgid: i32) -> bool {
    // SAFETY: getpgrp and getsid have no memory effects.
    pgid <= 1 || pgid == unsafe { libc::getpgrp() } || pgid == unsafe { libc::getsid(0) }
}

/// Whether `target` exists: `kill(target, 0)` succeeds or fails with EPERM (it exists, but is not ours to signal).
fn probe(sig: &dyn Signaller, target: i32) -> bool {
    match sig.kill(target, 0) {
        Ok(()) => true,
        Err(e) => e.raw_os_error() == Some(libc::EPERM),
    }
}

/// Whether the group can still be signalled; only ESRCH says it is gone.
fn group_left(sig: &dyn Signaller, pgid: i32) -> bool {
    match sig.kill(-pgid, 0) {
        Ok(()) => true,
        Err(e) => e.raw_os_error() != Some(libc::ESRCH),
    }
}

async fn terminate(pgid: i32, grace: Duration, sig: &dyn Signaller) -> ReapOutcome {
    match sig.kill(-pgid, libc::SIGTERM) {
        Ok(()) => {}
        Err(e) if e.raw_os_error() == Some(libc::ESRCH) => return ReapOutcome::Gone,
        Err(e) => return ReapOutcome::Failed(e.kind()),
    }
    if wait_gone(sig, pgid, grace).await {
        return ReapOutcome::Killed;
    }
    match sig.kill(-pgid, libc::SIGKILL) {
        Ok(()) => {}
        Err(e) if e.raw_os_error() == Some(libc::ESRCH) => return ReapOutcome::Killed,
        Err(e) => return ReapOutcome::Failed(e.kind()),
    }
    if wait_gone(sig, pgid, KILL_WAIT).await {
        ReapOutcome::Killed
    } else {
        ReapOutcome::Failed(io::ErrorKind::TimedOut)
    }
}

/// Probe the group until it is gone (true) or `limit` has passed (false).
async fn wait_gone(sig: &dyn Signaller, pgid: i32, limit: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        if !group_left(sig, pgid) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(POLL).await;
    }
}
