//! A process's start time and the boot it belongs to.
//!
//! A pid alone names a process only until it is reused; the pair (pid, start time) names one process. Linux start
//! times count clock ticks since boot and `runtime.db` survives a reboot, so a record is only ever compared within
//! its own boot ([`boot_id`]).
//!
//! Platforms: `/proc` is a Linux-kernel fact, so Linux and Android share it; macOS has its own; any other platform
//! gets `Unsupported` from the `os` module below.

use std::io;

/// What the reaper needs to know about a live pid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stat {
    pub start_time: u64,
    pub zombie: bool,
}

/// The start time of `pid`. Linux: field 22 of `/proc/PID/stat` (ticks since boot). macOS: `proc_pidinfo`'s
/// `pbi_start_tvsec * 1_000_000 + pbi_start_tvusec`.
pub fn start_time(pid: i32) -> io::Result<u64> {
    stat(pid).map(|s| s.start_time)
}

/// This boot's identity. Linux: `/proc/sys/kernel/random/boot_id`. macOS: `kern.bootsessionuuid` (not
/// `kern.boottime`, which moves when the clock is set).
pub fn boot_id() -> io::Result<String> {
    let id = os::boot_id()?;
    if id.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "empty boot id"));
    }
    Ok(id)
}

/// `pid`'s start time and whether it is a zombie. A process that is gone is `ErrorKind::NotFound`.
pub(crate) fn stat(pid: i32) -> io::Result<Stat> {
    if pid <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a process id",
        ));
    }
    os::stat(pid)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod os {
    use super::{Stat, parse_linux_stat};
    use std::io;

    pub(super) fn stat(pid: i32) -> io::Result<Stat> {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(line) => parse_linux_stat(&line),
            // A read that races the exit fails with ESRCH.
            Err(e) if e.raw_os_error() == Some(libc::ESRCH) => Err(io::ErrorKind::NotFound.into()),
            Err(e) => Err(e),
        }
    }

    pub(super) fn boot_id() -> io::Result<String> {
        Ok(std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?
            .trim()
            .to_owned())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
mod os {
    use super::Stat;
    use std::io;

    pub(super) fn stat(_pid: i32) -> io::Result<Stat> {
        Err(io::ErrorKind::Unsupported.into())
    }

    pub(super) fn boot_id() -> io::Result<String> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

/// `/proc/PID/stat`: `pid (comm) state …`, where comm may hold spaces and parens; the fields are counted from after
/// the last `)`. State is field 3, starttime field 22.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn parse_linux_stat(line: &str) -> io::Result<Stat> {
    let bad = || io::Error::new(io::ErrorKind::InvalidData, "unreadable /proc/PID/stat");
    let rest = &line[line.rfind(')').ok_or_else(bad)? + 1..];
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let state = fields.first().ok_or_else(bad)?;
    let start_time = fields
        .get(22 - 3)
        .ok_or_else(bad)?
        .parse()
        .map_err(|_| bad())?;
    Ok(Stat {
        start_time,
        zombie: matches!(*state, "Z" | "X"),
    })
}

#[cfg(target_os = "macos")]
mod os {
    use super::Stat;
    use std::io;

    pub(super) fn stat(pid: i32) -> io::Result<Stat> {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: the buffer is a proc_bsdinfo of `size` bytes, as PROC_PIDTBSDINFO expects.
        let n = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size,
            )
        };
        if n <= 0 {
            let e = io::Error::last_os_error();
            return Err(if e.raw_os_error() == Some(libc::ESRCH) {
                io::ErrorKind::NotFound.into()
            } else {
                e
            });
        }
        if n < size {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "short proc_bsdinfo",
            ));
        }
        // SAFETY: proc_pidinfo filled all `size` bytes.
        let info = unsafe { info.assume_init() };
        Ok(Stat {
            start_time: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            zombie: info.pbi_status == libc::SZOMB,
        })
    }

    /// `kern.bootsessionuuid`, as the Lisp hub's boot check uses (`kern.boottime` moves when the clock is set).
    pub(super) fn boot_id() -> io::Result<String> {
        let mut buf = [0u8; 64];
        let mut len = buf.len();
        // SAFETY: a NUL-terminated name; `buf` holds `len` bytes and sysctlbyname writes at most that.
        let r = unsafe {
            libc::sysctlbyname(
                c"kern.bootsessionuuid".as_ptr(),
                buf.as_mut_ptr().cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if r != 0 {
            return Err(io::Error::last_os_error());
        }
        let s = &buf[..len.min(buf.len())];
        let s = s.split(|&b| b == 0).next().unwrap_or_default();
        Ok(String::from_utf8_lossy(s).trim().to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ps -o etime=`: `[[dd-]hh:]mm:ss`.
    fn parse_etime(s: &str) -> u64 {
        let (days, rest) = match s.trim().split_once('-') {
            Some((d, r)) => (d.parse::<u64>().unwrap(), r),
            None => (0, s.trim()),
        };
        rest.split(':')
            .fold(0, |acc, n| acc * 60 + n.parse::<u64>().unwrap())
            + days * 86_400
    }

    /// How long ago `pid` started, in seconds, from our start time.
    fn our_elapsed(pid: i32) -> f64 {
        let start = start_time(pid).unwrap() as f64;
        #[cfg(target_os = "linux")]
        {
            let uptime: f64 = std::fs::read_to_string("/proc/uptime")
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .parse()
                .unwrap();
            let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
            uptime - start / hz
        }
        #[cfg(not(target_os = "linux"))]
        {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs_f64();
            now - start / 1e6
        }
    }

    #[test]
    fn matches_ps() {
        for pid in [std::process::id() as i32, unsafe { libc::getppid() }] {
            let out = std::process::Command::new("ps")
                .args(["-o", "etime=", "-p", &pid.to_string()])
                .env("LC_ALL", "C")
                .output()
                .unwrap();
            assert!(out.status.success());
            let ps = parse_etime(&String::from_utf8(out.stdout).unwrap()) as f64;
            let ours = our_elapsed(pid);
            assert!(
                (ps - ours).abs() <= 2.0,
                "pid {pid}: ps says {ps} s, we say {ours} s"
            );
        }
        assert_eq!(
            start_time(std::process::id() as i32).unwrap(),
            start_time(std::process::id() as i32).unwrap()
        );
    }

    #[test]
    fn boot_id_is_stable_and_non_empty() {
        let a = boot_id().unwrap();
        assert!(!a.is_empty());
        assert_eq!(a, a.trim());
        assert_eq!(a, boot_id().unwrap());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_stat_line_is_read_after_the_last_paren() {
        // comm may hold spaces and parens; fields count from after the last ')'.
        let rest = (4..=21)
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        let line = format!("42 (a) b (c)) Z {rest} 777 23 24\n");
        assert_eq!(
            parse_linux_stat(&line).unwrap(),
            Stat {
                start_time: 777,
                zombie: true
            }
        );
        let line = format!("42 (sleep) S {rest} 778 23 24\n");
        assert_eq!(
            parse_linux_stat(&line).unwrap(),
            Stat {
                start_time: 778,
                zombie: false
            }
        );
        assert!(parse_linux_stat("42 (sleep) S 1 2").is_err());
        assert!(stat(0).is_err() && stat(-1).is_err());
    }
}
