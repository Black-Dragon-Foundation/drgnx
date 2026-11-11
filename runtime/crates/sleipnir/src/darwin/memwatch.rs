//! A Mac job's memory cap, which no kernel enforces (no cgroups): job-exec's watchdog (design §5.3, spike S3). Every
//! [`TICK`] it lists the processes, takes the job's (its session, and processes that left it but carry the attempt's
//! marker variable and were born after it started), and sums their physical footprint; past [`cap_bytes`] it kills
//! them all. The cap is the grant minus [`HEADROOM_MIB`], the overshoot S3 measured at this tick, so the real peak stays
//! within the grant.
//!
//! The selection is pure ([`select`]); reading a process is per OS: `proc_listallpids`, `proc_pidinfo`,
//! `proc_pid_rusage` (`ri_phys_footprint`) and `KERN_PROCARGS2` on macOS, `/proc` (resident set) on Linux, where the
//! rows run.

#[cfg(any(target_os = "linux", target_os = "macos"))]
use crate::linux::reserve;
use std::time::Duration;

/// The environment variable every process of an attempt carries (`<hub>/<job>/<attempt>`): the watchdog finds the
/// processes that left the job's session by it.
pub const MARKER: &str = "DRGNX_RUNNER_ATTEMPT";
/// How often the watchdog scans.
pub const TICK: Duration = Duration::from_millis(500);
/// What a job reached past the scan that saw it cross, at [`TICK`]: S3's 164 MiB (a 512 MiB grant, a fast allocator
/// with an escaped child), rounded up.
pub const HEADROOM_MIB: u64 = 192;

/// The footprint at which a job with a grant of GRANT_MIB is killed: the grant less [`HEADROOM_MIB`], never under half
/// the grant.
pub fn cap_bytes(grant_mib: u64) -> u64 {
    grant_mib.saturating_sub(HEADROOM_MIB).max(grant_mib / 2) << 20
}

/// One process, as the watchdog sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proc {
    pub pid: i32,
    pub sid: i32,
    pub uid: u32,
    /// As [`reserve::start_time`] reads it (comparable with another of its readings only).
    pub start: u64,
    pub bytes: u64,
}

/// The job's processes among PROCS: those in session SID, and those of UID outside it born at or after BORN that carry
/// the marker (MARKED asks, so the environment is read only for those candidates); never ME (job-exec).
pub fn select(
    procs: &[Proc],
    me: i32,
    sid: i32,
    uid: u32,
    born: u64,
    marked: impl Fn(i32) -> bool,
) -> Vec<&Proc> {
    procs
        .iter()
        .filter(|p| p.pid != me && p.pid > 1)
        .filter(|p| p.sid == sid || (p.uid == uid && p.start >= born && marked(p.pid)))
        .collect()
}

/// A scan: the job's pids, and their footprint, bytes.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub struct Scan {
    pub pids: Vec<i32>,
    pub bytes: u64,
}

/// The job's processes now: session SID, or MARKER (`NAME=VALUE`) on a process of ours born at or after BORN (the
/// command's start); not ME.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn scan(me: i32, sid: i32, born: u64, marker: &str) -> Scan {
    // SAFETY: getuid has no failure
    let uid = unsafe { libc::getuid() };
    let procs: Vec<Proc> = os::pids().into_iter().filter_map(os::proc_of).collect();
    let chosen = select(&procs, me, sid, uid, born, |pid| {
        os::environ(pid).iter().any(|e| e == marker)
    });
    Scan {
        pids: chosen.iter().map(|p| p.pid).collect(),
        bytes: chosen.iter().map(|p| p.bytes).sum(),
    }
}

/// SIGKILL to each of PIDS (one already gone is no error).
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn kill_all(pids: &[i32]) {
    for p in pids {
        // SAFETY: a plain kill of a pid the scan just listed as the job's
        unsafe { libc::kill(*p, libc::SIGKILL) };
    }
}

/// The start time of PID, for [`Proc::start`] and the attempt's own.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn start_of(pid: i32) -> u64 {
    reserve::start_time(pid as u32).unwrap_or(0)
}

/// The leftovers of HUB's attempts among MARKED (a pid and its marker's value, `<hub>/<job>/<attempt>`): those whose
/// attempt RUNS doesn't say runs. Another hub's, and a value that isn't an attempt's, are left alone.
pub fn strays(marked: &[(i32, String)], hub: &str, runs: impl Fn(&str, u32) -> bool) -> Vec<i32> {
    marked
        .iter()
        .filter(|(_, v)| {
            let mut it = v.rsplitn(3, '/');
            let (Some(n), Some(job), Some(h)) = (it.next(), it.next(), it.next()) else {
                return false;
            };
            h == hub && n.parse().is_ok_and(|n| !runs(job, n))
        })
        .map(|(p, _)| *p)
        .collect()
}

/// This user's processes (not ME) that carry the marker, with its value.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn marked(me: i32) -> Vec<(i32, String)> {
    // SAFETY: getuid has no failure
    let uid = unsafe { libc::getuid() };
    let want = format!("{MARKER}=");
    os::pids()
        .into_iter()
        .filter(|p| *p != me && *p > 1)
        .filter_map(os::proc_of)
        .filter(|p| p.uid == uid)
        .filter_map(|p| {
            let v = os::environ(p.pid)
                .into_iter()
                .find_map(|e| e.strip_prefix(&want).map(String::from))?;
            Some((p.pid, v))
        })
        .collect()
}

#[cfg(target_os = "macos")]
mod os {
    use super::Proc;

    pub fn pids() -> Vec<i32> {
        // SAFETY: a null buffer asks for the count
        let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        let mut buf = vec![0 as libc::c_int; n.max(0) as usize + 256];
        let bytes = (buf.len() * std::mem::size_of::<libc::c_int>()) as libc::c_int;
        // SAFETY: a buffer of BYTES bytes
        let got = unsafe { libc::proc_listallpids(buf.as_mut_ptr().cast(), bytes) };
        buf.truncate(got.max(0) as usize);
        buf
    }

    pub fn proc_of(pid: i32) -> Option<Proc> {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: a buffer of SIZE bytes for one proc_bsdinfo
        let n = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        if n != size || info.pbi_status == libc::SZOMB {
            return None;
        }
        let mut ru: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
        // SAFETY: a rusage_info_v2 to fill, the flavor naming it
        let rc = unsafe {
            libc::proc_pid_rusage(
                pid,
                libc::RUSAGE_INFO_V2,
                (&mut ru as *mut libc::rusage_info_v2).cast(),
            )
        };
        Some(Proc {
            pid,
            // SAFETY: getsid of a listed pid; -1 when it is gone
            sid: unsafe { libc::getsid(pid) },
            uid: info.pbi_uid,
            start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            bytes: if rc == 0 { ru.ri_phys_footprint } else { 0 },
        })
    }

    /// PID's environment (`KERN_PROCARGS2`: argc, the exec path, argv, then the environment); empty when it can't be
    /// read (another user's process).
    pub fn environ(pid: i32) -> Vec<String> {
        let mut argmax: libc::c_int = 0;
        let mut len = std::mem::size_of::<libc::c_int>();
        let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
        // SAFETY: an int-sized buffer for KERN_ARGMAX
        if unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                2,
                (&mut argmax as *mut libc::c_int).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return vec![];
        }
        let mut buf = vec![0u8; argmax.max(0) as usize];
        let mut len = buf.len();
        let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        // SAFETY: a buffer of LEN bytes
        if unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                buf.as_mut_ptr().cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        } != 0
            || len < 4
        {
            return vec![];
        }
        let argc = i32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]).max(0) as usize;
        let mut fields = buf[4..len].split(|b| *b == 0).filter(|s| !s.is_empty());
        fields.next(); // the exec path
        fields
            .skip(argc)
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect()
    }
}

#[cfg(target_os = "linux")]
mod os {
    use super::Proc;
    use std::fs;
    use std::os::unix::fs::MetadataExt;

    pub fn pids() -> Vec<i32> {
        fs::read_dir("/proc")
            .map(|rd| {
                rd.flatten()
                    .filter_map(|e| e.file_name().to_str()?.parse().ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn proc_of(pid: i32) -> Option<Proc> {
        let dir = format!("/proc/{pid}");
        let stat = fs::read_to_string(format!("{dir}/stat")).ok()?;
        let rest: Vec<&str> = stat[stat.rfind(')')? + 1..].split_whitespace().collect();
        // after the name: state, ppid, pgrp, session, …, starttime (the 20th)
        if rest.first() == Some(&"Z") {
            return None;
        }
        let statm = fs::read_to_string(format!("{dir}/statm")).ok()?;
        let resident: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
        // SAFETY: sysconf has no failure for this name
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) }.max(0) as u64;
        Some(Proc {
            pid,
            sid: rest.get(3)?.parse().ok()?,
            uid: fs::metadata(&dir).ok()?.uid(),
            start: rest.get(19)?.parse().ok()?,
            bytes: resident * page,
        })
    }

    pub fn environ(pid: i32) -> Vec<String> {
        fs::read(format!("/proc/{pid}/environ"))
            .map(|b| {
                b.split(|c| *c == 0)
                    .filter(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: i32, sid: i32, uid: u32, start: u64, mib: u64) -> Proc {
        Proc {
            pid,
            sid,
            uid,
            start,
            bytes: mib << 20,
        }
    }

    /// [D] pure: the job is its session (not job-exec) plus marked processes of ours born after it started; another
    /// session, another user's process, one born before, or an unmarked one is not.
    #[test]
    fn the_job_is_its_session_and_its_marked_escapees() {
        let procs = [
            p(100, 100, 501, 10, 5),   // job-exec, the session leader
            p(101, 100, 501, 11, 50),  // the command
            p(102, 100, 0, 11, 7),     // in the session, whatever its user
            p(200, 200, 501, 12, 300), // left the session, marked
            p(201, 201, 501, 12, 40),  // left the session, unmarked
            p(202, 202, 501, 5, 40),   // marked, but older than the attempt
            p(203, 203, 502, 12, 40),  // marked, another user
            p(1, 1, 0, 0, 10),         // launchd
        ];
        let marked = |pid: i32| matches!(pid, 200 | 202 | 203);
        let got: Vec<i32> = select(&procs, 100, 100, 501, 10, marked)
            .iter()
            .map(|p| p.pid)
            .collect();
        assert_eq!(got, vec![101, 102, 200]);
    }

    /// [D] pure: the sweep takes this hub's markers whose attempt no longer runs; a running attempt's, another hub's
    /// and a malformed value stay.
    #[test]
    fn the_sweep_takes_only_this_hubs_ended_attempts() {
        let marked = [
            (10, "hubA/j1/1".to_string()),
            (11, "hubA/j2/3".to_string()),
            (12, "hubB/j1/1".to_string()),
            (13, "nonsense".to_string()),
            (14, "hubA/j3/x".to_string()),
            (15, "hub/with/slash/j4/2".to_string()),
        ];
        let runs = |job: &str, n: u32| job == "j2" && n == 3;
        assert_eq!(strays(&marked, "hubA", runs), vec![10]);
        assert_eq!(strays(&marked, "hub/with/slash", runs), vec![15]);
    }

    /// [D] pure: the cap is the grant less the measured headroom, never under half the grant.
    #[test]
    fn the_cap_leaves_the_measured_headroom() {
        assert_eq!(cap_bytes(4096), (4096 - HEADROOM_MIB) << 20);
        assert_eq!(cap_bytes(256), 128 << 20);
        assert_eq!(cap_bytes(0), 0);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    /// [D] A real scan finds this process's own session's other members only by session: a marker nobody carries finds
    /// no stranger.
    #[test]
    fn a_scan_reads_the_live_process_table() {
        let me = std::process::id() as i32;
        // SAFETY: getsid(0) of this process
        let sid = unsafe { libc::getsid(0) };
        let s = scan(me, sid, start_of(me), "DRGNX_RUNNER_ATTEMPT=nobody");
        assert!(!s.pids.contains(&me));
        assert!(s.pids.iter().all(|p| *p > 1));
    }
}
