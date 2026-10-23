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
//!
//! **The process listening on a socket** ([`listener_of`], `stop`'s target; call 14, review B1): `stop` signals only
//! the process that listens on the hub's socket, never one a lock file or a command line names.
//!
//! - **Linux and Android:** the socket's directory passes `trusted_dir` and the socket `owned_in_trusted`; a
//!   non-blocking, close-on-exec `connect` (`EAGAIN`: "the hub's socket is full"); `SO_PEERPIDFD` gives a pidfd of the
//!   listener (its pid from `/proc/self/fdinfo/FD`).  A kernel before 6.5 (`ENOPROTOOPT`), or an architecture whose
//!   value of the option is not known here, takes `SO_PEERCRED`'s pid and `pidfd_open` on it.  The peer's uid must be
//!   ours.  The signal goes through the pidfd (`pidfd_send_signal`), so it reaches that process or none.
//! - **macOS:** `LOCAL_PEERPID` and `getpeereid`; the signal is `kill` right after `stop` compared the start time
//!   (call 14's guard, with its stated residual window).
//! - **Elsewhere:** refused ("signal it yourself").

use std::io;
use std::path::Path;

/// The process listening on a socket ([`listener_of`]).
pub struct Listener {
    pub pid: u32,
    pub uid: u32,
    #[cfg(any(target_os = "linux", target_os = "android"))]
    pidfd: std::os::fd::OwnedFd,
}

impl Listener {
    /// Whether it still runs (signal 0; on Linux and Android through its pidfd, so a reused pid never answers).
    pub fn running(&self) -> bool {
        listen::signal(self, 0).is_ok()
    }

    /// SIGTERM to it.
    pub fn terminate(&self) -> io::Result<()> {
        listen::signal(self, libc::SIGTERM)
    }
}

/// The process listening on SOCKET, for `stop` (above).
pub fn listener_of(socket: &Path) -> Result<Listener, String> {
    let dir = socket.parent().unwrap_or(Path::new("/"));
    let name = Path::new(socket.file_name().unwrap_or_default());
    let fd = runstav::paths::trusted_dir(dir).map_err(|e| e.to_string())?;
    runstav::paths::owned_in_trusted(&fd, name).map_err(|e| match e.kind() {
        io::ErrorKind::NotFound => format!("{} is gone", socket.display()),
        _ => e.to_string(),
    })?;
    let l = listen::listener(socket)?;
    let me = rustix::process::geteuid().as_raw();
    if l.uid != me {
        return Err(format!(
            "the process listening on {} (pid {}) is another user's",
            socket.display(),
            l.pid
        ));
    }
    Ok(l)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod listen {
    use super::Listener;
    use rustix::io::Errno;
    use rustix::net::{AddressFamily, SocketAddrUnix, SocketFlags, SocketType};
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::path::Path;

    /// `SO_PEERPIDFD` (asm-generic/socket.h, Linux 6.5): 77 on x86_64 and aarch64.  libc 0.2.191 exports it for
    /// Android only, so it is named here; elsewhere its value is not known here and `SO_PEERCRED` + `pidfd_open` serve.
    #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
    const SO_PEERPIDFD: Option<libc::c_int> = Some(77);
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    const SO_PEERPIDFD: Option<libc::c_int> = None;

    pub(super) fn listener(socket: &Path) -> Result<Listener, String> {
        let sock = rustix::net::socket_with(
            AddressFamily::UNIX,
            SocketType::STREAM,
            SocketFlags::NONBLOCK | SocketFlags::CLOEXEC,
            None,
        )
        .map_err(|e| format!("no socket: {e}"))?;
        let addr = SocketAddrUnix::new(socket)
            .map_err(|e| format!("{} is not a socket path: {e}", socket.display()))?;
        match rustix::net::connect(&sock, &addr) {
            Ok(()) => {}
            Err(Errno::AGAIN) => return Err("the hub's socket is full".into()),
            Err(e) => {
                return Err(format!("nothing listens on {} ({e})", socket.display()));
            }
        }
        let cred = rustix::net::sockopt::socket_peercred(&sock)
            .map_err(|e| format!("the listener's credentials do not read: {e}"))?;
        let uid = cred.uid.as_raw();
        let pidfd = match SO_PEERPIDFD.map(|opt| peer_pidfd(&sock, opt)) {
            Some(Ok(fd)) => fd,
            None | Some(Err(Errno::NOPROTOOPT)) => {
                pidfd_open(rustix::process::Pid::as_raw(Some(cred.pid)))?
            }
            Some(Err(e)) => return Err(format!("the listener's pidfd does not read: {e}")),
        };
        let pid = pid_of(&pidfd)?;
        Ok(Listener { pid, uid, pidfd })
    }

    /// `getsockopt(SOL_SOCKET, SO_PEERPIDFD)` on SOCK.
    fn peer_pidfd(sock: &OwnedFd, opt: libc::c_int) -> Result<OwnedFd, Errno> {
        let mut fd: libc::c_int = -1;
        let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        // SAFETY: FD and LEN are a c_int and its size, as the option writes them
        let r = unsafe {
            libc::getsockopt(
                sock.as_raw_fd(),
                libc::SOL_SOCKET,
                opt,
                (&raw mut fd).cast(),
                &raw mut len,
            )
        };
        if r != 0 {
            return Err(Errno::from_io_error(&io::Error::last_os_error()).unwrap_or(Errno::INVAL));
        }
        if fd < 0 {
            return Err(Errno::SRCH);
        }
        // SAFETY: the kernel gave us this new descriptor; nothing else owns it
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// A pidfd of PID (before Linux 6.5): `ENOSYS` (before 5.3) and a gone process are refusals.
    fn pidfd_open(pid: i32) -> Result<OwnedFd, String> {
        // SAFETY: pidfd_open takes a pid and flags and returns a new descriptor or -1
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if fd < 0 {
            let e = io::Error::last_os_error();
            return Err(match e.raw_os_error() {
                Some(libc::ENOSYS) => "this kernel has no pidfd (before Linux 5.3)".into(),
                Some(libc::EINVAL | libc::ESRCH) => {
                    format!("the process listening (pid {pid}) is gone")
                }
                _ => format!("no pidfd for pid {pid}: {e}"),
            });
        }
        let fd = libc::c_int::try_from(fd).map_err(|_| "a pidfd out of range".to_string())?;
        // SAFETY: the kernel gave us this new descriptor; nothing else owns it
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// The pid FD names: the `Pid:` line of `/proc/self/fdinfo/FD` (-1 or 0: the process is gone).
    fn pid_of(fd: &OwnedFd) -> Result<u32, String> {
        let info = std::fs::read_to_string(format!("/proc/self/fdinfo/{}", fd.as_raw_fd()))
            .map_err(|e| format!("the pidfd's process does not read: {e}"))?;
        info.lines()
            .find_map(|l| l.strip_prefix("Pid:"))
            .and_then(|p| p.trim().parse::<i64>().ok())
            .and_then(|p| u32::try_from(p).ok())
            .filter(|p| *p > 0)
            .ok_or_else(|| "the process listening is gone".to_string())
    }

    pub(super) fn signal(l: &Listener, sig: libc::c_int) -> io::Result<()> {
        // SAFETY: pidfd_send_signal on a pidfd we own, no siginfo, no flags
        let r = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                l.pidfd.as_raw_fd(),
                sig,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        if r == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

#[cfg(target_os = "macos")]
mod listen {
    use super::Listener;
    use std::io;
    use std::os::fd::AsRawFd;
    use std::path::Path;

    pub(super) fn listener(socket: &Path) -> Result<Listener, String> {
        let sock = std::os::unix::net::UnixStream::connect(socket)
            .map_err(|e| format!("nothing listens on {} ({e})", socket.display()))?;
        let mut pid: libc::pid_t = 0;
        let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        // SAFETY: PID and LEN are a pid_t and its size, as LOCAL_PEERPID writes them
        let r = unsafe {
            libc::getsockopt(
                sock.as_raw_fd(),
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&raw mut pid).cast(),
                &raw mut len,
            )
        };
        if r != 0 || pid <= 0 {
            return Err(format!(
                "the listener's pid does not read: {}",
                io::Error::last_os_error()
            ));
        }
        let (mut uid, mut gid) = (0, 0);
        // SAFETY: two out-parameters of the right types
        if unsafe { libc::getpeereid(sock.as_raw_fd(), &raw mut uid, &raw mut gid) } != 0 {
            return Err(format!(
                "the listener's uid does not read: {}",
                io::Error::last_os_error()
            ));
        }
        Ok(Listener {
            pid: pid as u32,
            uid,
        })
    }

    pub(super) fn signal(l: &Listener, sig: libc::c_int) -> io::Result<()> {
        let pid = i32::try_from(l.pid).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        // SAFETY: kill(2) of one positive pid that `stop` compared with the lock just before
        if unsafe { libc::kill(pid, sig) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
mod listen {
    use super::Listener;
    use std::io;
    use std::path::Path;

    pub(super) fn listener(_socket: &Path) -> Result<Listener, String> {
        Err("this platform cannot tell which process listens on the hub's socket".into())
    }

    pub(super) fn signal(_l: &Listener, _sig: libc::c_int) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

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

    #[cfg(any(target_os = "linux", target_os = "android", target_os = "macos"))]
    #[test]
    fn listener_of_a_socket_we_listen_on_is_us() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = dir.path().join("hub-x.sock");
        let _listening = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let l = listener_of(&path).unwrap();
        assert_eq!(l.pid, std::process::id());
        assert_eq!(l.uid, rustix::process::geteuid().as_raw());
        assert!(l.running(), "signal 0 reaches this process");
        // nothing listening, and a directory open to others: refused, with why
        let gone = listener_of(&dir.path().join("none.sock")).err().unwrap();
        assert!(gone.contains("is gone"), "{gone}");
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        let open = listener_of(&path).err().unwrap();
        assert!(open.contains("open to other users"), "{open}");
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn the_stat_line_is_read_after_the_last_paren() {
        let fields: Vec<&str> = os::after_comm("42 (a) b (c)) Z 7 8\n").unwrap().collect();
        assert_eq!(fields, ["Z", "7", "8"]);
    }
}
