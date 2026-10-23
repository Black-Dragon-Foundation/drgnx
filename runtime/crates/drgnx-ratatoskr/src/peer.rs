//! The process behind a connection, for an outside agent's identity (`mcp/attach`, call 8) and a session owner's
//! liveness ([`crate::sessions`]).
//!
//! The connection's peer pid is the socket's (`SO_PEERCRED` on Linux and Android, `LOCAL_PEERPID` on macOS: tokio's
//! `peer_cred`, read once in [`crate::conn`]).  Its parent is the agent that started the bridge; the parent's start
//! time tells it from a later process given the same pid.
//!
//! Platforms: `/proc` is the Linux kernel's, so Linux and Android share it (fields 3, 4 and 22 of `/proc/PID/stat`,
//! and `btime` of `/proc/stat`); macOS asks `proc_pidinfo` (`pbi_ppid`, `pbi_start_tvsec`/`usec`, `pbi_status`);
//! anything else answers `Unsupported`.

use std::io;

/// A process's parent: its pid, and its start time in seconds since the epoch when it can be read.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Parent {
    pub pid: u32,
    pub start: Option<f64>,
}

/// The parent of PID, with that parent's start time.
pub fn parent_of(pid: i32) -> io::Result<Parent> {
    if pid <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a process id",
        ));
    }
    let ppid = os::ppid(pid)?;
    Ok(Parent {
        pid: u32::try_from(ppid).unwrap_or(0),
        start: os::start_secs(ppid).ok(),
    })
}

/// Whether PID is a zombie (it ended and its parent has not reaped it): gone, though `kill(pid, 0)` still succeeds.
pub fn zombie(pid: i32) -> bool {
    pid > 0 && os::zombie(pid).unwrap_or(false)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod os {
    use std::io;

    /// The fields of `/proc/PID/stat` from field 3 (the state) on: comm, field 2, may hold spaces and parens, so they
    /// are counted from after the last `)`.
    fn fields(pid: i32) -> io::Result<Vec<String>> {
        let line = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
        Ok(after_comm(&line)?.map(str::to_owned).collect())
    }

    pub(super) fn after_comm(line: &str) -> io::Result<std::str::SplitWhitespace<'_>> {
        let end = line.rfind(')').ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "unreadable /proc/PID/stat")
        })?;
        Ok(line[end + 1..].split_whitespace())
    }

    /// Field N (1-based, as proc(5) counts) of FIELDS, which start at field 3.
    fn field(fields: &[String], n: usize) -> io::Result<&str> {
        fields
            .get(n - 3)
            .map(String::as_str)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "short /proc/PID/stat"))
    }

    fn number<T: std::str::FromStr>(s: &str) -> io::Result<T> {
        s.parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "unreadable /proc/PID/stat"))
    }

    pub(super) fn ppid(pid: i32) -> io::Result<i32> {
        number(field(&fields(pid)?, 4)?)
    }

    pub(super) fn zombie(pid: i32) -> io::Result<bool> {
        Ok(matches!(field(&fields(pid)?, 3)?, "Z" | "X"))
    }

    /// The boot time (`btime` of `/proc/stat`, whole seconds since the epoch) plus field 22, the start in clock ticks
    /// since boot: the same every time it is read, so the identity's hash never moves.
    pub(super) fn start_secs(pid: i32) -> io::Result<f64> {
        let ticks: u64 = number(field(&fields(pid)?, 22)?)?;
        let stat = std::fs::read_to_string("/proc/stat")?;
        let btime: u64 = stat
            .lines()
            .find_map(|l| l.strip_prefix("btime "))
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "no btime in /proc/stat"))
            .and_then(|b| number(b.trim()))?;
        // SAFETY: sysconf takes no pointer.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if hz <= 0 {
            return Err(io::Error::other("no clock tick rate"));
        }
        Ok(btime as f64 + ticks as f64 / hz as f64)
    }
}

#[cfg(target_os = "macos")]
mod os {
    use std::io;

    fn info(pid: i32) -> io::Result<libc::proc_bsdinfo> {
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
        if n < size {
            return Err(if n <= 0 {
                io::Error::last_os_error()
            } else {
                io::Error::new(io::ErrorKind::InvalidData, "short proc_bsdinfo")
            });
        }
        // SAFETY: proc_pidinfo filled all `size` bytes.
        Ok(unsafe { info.assume_init() })
    }

    pub(super) fn ppid(pid: i32) -> io::Result<i32> {
        Ok(info(pid)?.pbi_ppid as i32)
    }

    pub(super) fn zombie(pid: i32) -> io::Result<bool> {
        Ok(info(pid)?.pbi_status == libc::SZOMB)
    }

    pub(super) fn start_secs(pid: i32) -> io::Result<f64> {
        let i = info(pid)?;
        Ok(i.pbi_start_tvsec as f64 + i.pbi_start_tvusec as f64 / 1e6)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
mod os {
    use std::io;

    pub(super) fn ppid(_pid: i32) -> io::Result<i32> {
        Err(io::ErrorKind::Unsupported.into())
    }

    pub(super) fn zombie(_pid: i32) -> io::Result<bool> {
        Err(io::ErrorKind::Unsupported.into())
    }

    pub(super) fn start_secs(_pid: i32) -> io::Result<f64> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_of_self_matches_getppid() {
        let me = std::process::id() as i32;
        let p = parent_of(me).unwrap();
        // SAFETY: getppid takes nothing and cannot fail.
        assert_eq!(p.pid as i32, unsafe { libc::getppid() });
        let start = p.start.expect("the parent's start time reads");
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        assert!(start > 0.0 && start <= now + 1.0, "{start} vs now {now}");
        // the same every time: the identity's hash never moves
        assert_eq!(parent_of(me).unwrap(), p);
        assert!(!zombie(me));
        assert!(parent_of(0).is_err() && !zombie(-1));
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn the_stat_line_is_read_after_the_last_paren() {
        let fields: Vec<&str> = os::after_comm("42 (a) b (c)) Z 7 8\n").unwrap().collect();
        assert_eq!(fields, ["Z", "7", "8"]);
    }
}
