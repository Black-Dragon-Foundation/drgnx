//! Seeing the files a shell step opens (layer 2 of the Work space's reads through shell commands;
//! docs/develop/sandbox.md, "Seeing the files a shell step opens"). It only records and never decides: every notified
//! call is answered "continue", and the kernel then applies Landlock and the deny-list to it as before.
//!
//! - [`install`]: a seccomp filter on the calling thread that sends `open`, `openat` and `openat2` to a listener fd
//!   (`SECCOMP_FILTER_FLAG_NEW_LISTENER`), after `no_new_privs`. Every other call goes on at BPF speed. A deny rule's
//!   `ERRNO` outranks `USER_NOTIF`, so a call the deny-list refuses is never notified.
//! - The hand-off, over a Unix socket a supervisor outside the sandbox listens on: the traced side [`offer`]s a
//!   [`Hello`] (its command) and parks; the supervisor [`accept`]s it and answers `skip` or `trace`. Only on `trace`
//!   does the traced side install the listener, and then it sends the fd (`SCM_RIGHTS`), or says `busy` when a
//!   listener is already above it (one per thread, `EBUSY`). No supervisor, no answer within [`HANDOFF_DEADLINE`], or
//!   EOF: the command runs untraced. The hand-off never refuses a command and never waits past the deadline.
//! - [`listen`]: the answering thread. Per notification it does only the receive, the path read from
//!   `/proc/<pid>/mem` (and, for a relative path, the link of the working directory or the dirfd) between two
//!   `NOTIF_ID_VALID` checks, and the continue. What it read goes to a channel, so resolving and the rules run on the
//!   caller's thread. It ends when every task the filter covers is gone (`POLLHUP`) or when asked ([`Listener::stop`]);
//!   an `ENOENT` or `EINTR` from the receive goes back to `poll`, never round a busy loop (since Linux 6.6 the receive
//!   fails at once with `ENOENT` when no task is left). No sync wake-up unless asked (spike S4: slower everywhere).
//! - [`wrapper_main`]: `gleipnir-trace CMD`, the per-step wrapper (Claude Code's `CLAUDE_CODE_SHELL_PREFIX`).
//!
//! A path read this way is an observation, not a check: a program can change it between the read and the kernel's
//! open (seccomp_unotify(2)). Linux only; elsewhere [`install`], [`accept`] and [`listen`] say unsupported, and
//! [`offer`] leaves the command untraced.

use crate::seccomp::{Arch, SockFilter};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

/// The wrapper finds the supervisor's socket here.
pub const SOCK_ENV: &str = "GLEIPNIR_TRACE_SOCK";
/// The name the wrapper is started by (the inner helper runs as the wrapper under this name).
pub const WRAPPER_NAME: &str = "gleipnir-trace";
/// The hello's version.
pub const VERSION: u32 = 1;
/// The longest command offered; a longer one runs untraced.
pub const HELLO_MAX: usize = 256 * 1024;
/// How long either side waits for the other during the hand-off.
pub const HANDOFF_DEADLINE: Duration = Duration::from_secs(2);

/// What is traced: one shell step (the wrapper), or a process's whole tree (the inner helper).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    Step,
    Tree,
}

/// The traced side's first line: what it is about to run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub v: u32,
    pub scope: Scope,
    pub command: String,
}

/// How an [`offer`] ended, on the traced side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Offered {
    /// The listener is installed and its fd is the supervisor's.
    Traced,
    /// The supervisor answered `skip`: nothing installed.
    Skipped,
    /// A listener is already above this one (`EBUSY`), and the supervisor was told.
    Busy,
    /// Nothing installed, for this reason.
    Untraced(String),
    /// The listener is installed but its fd did not reach the supervisor: every later open would fail (`ENOSYS`).
    Lost(String),
}

/// What the traced side sent after `trace`, on the supervisor's side.
#[derive(Debug)]
pub enum Handed {
    Listener(OwnedFd),
    Busy,
    Failed(String),
}

/// One of the calls the listener sees.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Call {
    Open,
    Openat,
    Openat2,
}

/// One notified open, as the answering thread read it.
#[derive(Debug, Clone)]
pub struct Open {
    /// The opening task, in the supervisor's pid namespace.
    pub pid: u32,
    pub call: Call,
    /// The path argument as given (maybe relative).
    pub path: PathBuf,
    /// For a relative path: the directory it is relative to (the working directory, or the dirfd's target).
    pub base: Option<PathBuf>,
    pub flags: u64,
    /// When it was received.
    pub at: Instant,
}

/// `O_WRONLY | O_RDWR | O_CREAT | O_TRUNC`, Linux's numbers on every architecture gleipnir filters.
const WRITE_FLAGS: u64 = 0o1 | 0o2 | 0o100 | 0o1000;

impl Open {
    /// The path, absolute when it can be: as given, or joined to its base.
    pub fn full(&self) -> Option<PathBuf> {
        if self.path.is_absolute() {
            Some(self.path.clone())
        } else {
            self.base.as_ref().map(|b| b.join(&self.path))
        }
    }

    /// Opened to write (or create or truncate), by its flags.
    pub fn writes(&self) -> bool {
        self.flags & WRITE_FLAGS != 0
    }
}

/// How [`listen`] answers.
#[derive(Debug, Clone, Default)]
pub struct ListenOptions {
    /// Ask for `SECCOMP_USER_NOTIF_FD_SYNC_WAKE_UP` (6.6+); without it, or when the kernel refuses, the plain mode.
    pub sync_wakeup: bool,
    /// Whole-tree mode: opens by this thread group (the agent's CLI itself) are continued unread.
    pub ignore_tgid: Option<u32>,
    /// Test hook: the sync wake-up's ioctl fails with this errno (the `ENOSYS` fallback).
    #[cfg(feature = "test-hooks")]
    pub set_flags_errno: Option<i32>,
}

/// What the answering thread did, when it ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ended {
    pub notifications: u64,
    /// Opens of the ignored thread group.
    pub ignored: u64,
    /// Continued without reading ([`Listener::set_reading`] off).
    pub unread: u64,
    /// The receive's errno, when it ended the loop.
    pub error: Option<i32>,
}

#[derive(Default)]
struct Counts {
    notifications: AtomicU64,
    answering_ns: AtomicU64,
}

/// A running answering thread. Dropping it stops and joins it.
pub struct Listener {
    stop: Option<OwnedFd>,
    reading: Arc<AtomicBool>,
    counts: Arc<Counts>,
    sync: bool,
    thread: Option<std::thread::JoinHandle<Ended>>,
}

impl Listener {
    /// Whether the sync wake-up is on.
    pub fn sync(&self) -> bool {
        self.sync
    }

    /// Off: every later open is continued without reading its path (only the round trip is left: the over-budget
    /// answer, since a filter cannot be removed).
    pub fn set_reading(&self, on: bool) {
        self.reading.store(on, Ordering::Relaxed);
    }

    /// Notifications so far.
    pub fn notifications(&self) -> u64 {
        self.counts.notifications.load(Ordering::Relaxed)
    }

    /// Time spent answering so far (receive to continue), in ns.
    pub fn answering_ns(&self) -> u64 {
        self.counts.answering_ns.load(Ordering::Relaxed)
    }

    /// Ask the thread to end now (it ends by itself once every traced task is gone).
    pub fn stop(&mut self) {
        // closing the write end wakes the poll (POLLHUP on the read end)
        self.stop.take();
    }

    /// Wait for the thread to end: when every traced task is gone, or after [`Listener::stop`].
    pub fn join(mut self) -> Ended {
        self.thread
            .take()
            .and_then(|t| t.join().ok())
            .unwrap_or_default()
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        if let Some(t) = self.thread.take() {
            self.stop.take();
            let _ = t.join();
        }
    }
}

/// The calls the listener sees on `arch`, with their numbers (aarch64 has no `open`).
pub fn calls(arch: Arch) -> &'static [(Call, u32)] {
    match arch {
        Arch::X86_64 => &[(Call::Open, 2), (Call::Openat, 257), (Call::Openat2, 437)],
        Arch::Aarch64 => &[(Call::Openat, 56), (Call::Openat2, 437)],
    }
}

const LD_W_ABS: u16 = 0x20;
const JEQ_K: u16 = 0x15;
const RET_K: u16 = 0x06;
const RET_ALLOW: u32 = 0x7fff_0000;
const RET_USER_NOTIF: u32 = 0x7fc0_0000;

/// The listener's filter for `arch`: a native open call → `USER_NOTIF`; anything else (a foreign architecture too) →
/// `ALLOW`. The deny-list is a filter of its own, and the kernel takes the highest-precedence answer of all.
pub fn program(arch: Arch) -> Vec<SockFilter> {
    let calls = calls(arch);
    let n = calls.len() as u8;
    let i = |code, jt, jf, k| SockFilter { code, jt, jf, k };
    let mut p = vec![
        i(LD_W_ABS, 0, 0, 4), // seccomp_data.arch
        i(JEQ_K, 0, n + 1, arch.audit()),
        i(LD_W_ABS, 0, 0, 0), // seccomp_data.nr
    ];
    for (j, (_, nr)) in calls.iter().enumerate() {
        p.push(i(JEQ_K, n - j as u8, 0, *nr));
    }
    p.push(i(RET_K, 0, 0, RET_ALLOW));
    p.push(i(RET_K, 0, 0, RET_USER_NOTIF));
    p
}

/// Install the listener's filter on the calling thread (and so on everything it execs and starts from now on), after
/// `no_new_privs`, and return the listener fd, close-on-exec. `EBUSY`: a listener is already above this thread.
pub fn install() -> io::Result<OwnedFd> {
    #[cfg(target_os = "linux")]
    {
        linux::install()
    }
    #[cfg(not(target_os = "linux"))]
    {
        Err(unsupported())
    }
}

/// Offer the command at `sock` (the traced side; see the module). Never refuses the command: every outcome but
/// [`Offered::Lost`] lets it run.
pub fn offer(sock: &Path, scope: Scope, command: &str) -> Offered {
    #[cfg(target_os = "linux")]
    {
        linux::offer(sock, scope, command)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (sock, scope, command);
        Offered::Untraced("opens are traced on Linux only".into())
    }
}

/// A hello the supervisor has read, waiting for its answer.
pub struct Offer {
    pub hello: Hello,
    /// The traced side's pid in the supervisor's namespace (`SO_PEERCRED`): the wrapper becomes the command's shell,
    /// the inner helper the agent's CLI.
    pub peer_pid: Option<i32>,
    stream: UnixStream,
}

/// Read the hello on a connection the supervisor accepted (waiting at most [`HANDOFF_DEADLINE`]).
pub fn accept(stream: UnixStream) -> io::Result<Offer> {
    #[cfg(target_os = "linux")]
    {
        linux::accept(stream)
    }
    #[cfg(not(target_os = "linux"))]
    {
        drop(stream);
        Err(unsupported())
    }
}

impl Offer {
    /// Answer `skip`: the command runs untraced.
    pub fn skip(self) -> io::Result<()> {
        use std::io::Write;
        (&self.stream).write_all(b"skip\n")
    }

    /// Answer `trace` and take what comes back: the listener fd, or `busy`, or why it failed.
    pub fn trace(self) -> io::Result<Handed> {
        #[cfg(target_os = "linux")]
        {
            linux::trace(self.stream)
        }
        #[cfg(not(target_os = "linux"))]
        {
            drop(self.stream);
            Err(unsupported())
        }
    }
}

/// Start the answering thread on listener `fd`; each open it read goes to `out`.
pub fn listen(fd: OwnedFd, opts: ListenOptions, out: Sender<Open>) -> io::Result<Listener> {
    #[cfg(target_os = "linux")]
    {
        linux::listen(fd, opts, out)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (fd, opts, out);
        Err(unsupported())
    }
}

#[cfg(not(target_os = "linux"))]
fn unsupported() -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, "opens are traced on Linux only")
}

/// `gleipnir-trace CMD`: offer CMD at `$GLEIPNIR_TRACE_SOCK`, then `exec bash -c CMD` whatever the answer. The
/// command's output and exit are its own; the wrapper writes nothing unless the hand-off left it unable to run (the
/// listener installed but not handed over: 125).
pub fn wrapper_main(args: Vec<OsString>) -> i32 {
    let [_, cmd] = args.as_slice() else {
        eprintln!("usage: {WRAPPER_NAME} COMMAND");
        return 2;
    };
    if let (Some(sock), Some(text)) = (std::env::var_os(SOCK_ENV), cmd.to_str())
        && let Offered::Lost(why) = offer(Path::new(&sock), Scope::Step, text)
    {
        eprintln!("{WRAPPER_NAME}: {why}");
        return 125;
    }
    use std::os::unix::process::CommandExt;
    let mut e = std::process::Command::new("bash").arg("-c").arg(cmd).exec();
    if e.kind() == io::ErrorKind::NotFound {
        e = std::process::Command::new("/bin/bash")
            .arg("-c")
            .arg(cmd)
            .exec();
    }
    eprintln!("{WRAPPER_NAME}: cannot run bash: {e}");
    if e.kind() == io::ErrorKind::NotFound {
        127
    } else {
        126
    }
}

// Linux only: seccomp user notification. Android: no backend; fails closed.
#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, RawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::FileExt;

    const SECCOMP_SET_MODE_FILTER: libc::c_ulong = 1;
    const SECCOMP_FILTER_FLAG_NEW_LISTENER: libc::c_ulong = 1 << 3;
    // _IOWR('!', 0, struct seccomp_notif), _IOWR('!', 1, struct seccomp_notif_resp), _IOW('!', 2, __u64),
    // _IOW('!', 4, __u64): the generic ioctl encoding, the same on x86_64 and aarch64.
    const IOCTL_RECV: libc::c_ulong = 0xc050_2100;
    const IOCTL_SEND: libc::c_ulong = 0xc018_2101;
    const IOCTL_ID_VALID: libc::c_ulong = 0x4008_2102;
    const IOCTL_SET_FLAGS: libc::c_ulong = 0x4008_2104;
    const FLAG_CONTINUE: u32 = 1;
    const FD_SYNC_WAKE_UP: u64 = 1;
    const PATH_MAX: usize = 4096;
    /// Bounds of the answering thread's caches (open `/proc/<pid>/mem` files, tid → tgid).
    const MEMS_MAX: usize = 256;
    const TGIDS_MAX: usize = 4096;

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct SeccompData {
        nr: i32,
        arch: u32,
        ip: u64,
        args: [u64; 6],
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct Notif {
        id: u64,
        pid: u32,
        flags: u32,
        data: SeccompData,
    }

    #[repr(C)]
    struct Resp {
        id: u64,
        val: i64,
        error: i32,
        flags: u32,
    }

    fn errno() -> i32 {
        io::Error::last_os_error().raw_os_error().unwrap_or(0)
    }

    pub(super) fn install() -> io::Result<OwnedFd> {
        let arch = crate::seccomp::native().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Unsupported,
                "no open filter for this architecture",
            )
        })?;
        let prog: Vec<libc::sock_filter> = program(arch)
            .iter()
            .map(|i| libc::sock_filter {
                code: i.code,
                jt: i.jt,
                jf: i.jf,
                k: i.k,
            })
            .collect();
        rustix::thread::set_no_new_privs(true).map_err(io::Error::from)?;
        let fprog = libc::sock_fprog {
            len: prog.len() as u16,
            filter: prog.as_ptr() as *mut _,
        };
        // SAFETY: a valid program that outlives the call; no_new_privs is set.
        let r = unsafe {
            libc::syscall(
                libc::SYS_seccomp,
                SECCOMP_SET_MODE_FILTER,
                SECCOMP_FILTER_FLAG_NEW_LISTENER,
                &fprog as *const libc::sock_fprog,
            )
        };
        if r < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the kernel just made this fd for us.
        let fd = unsafe { OwnedFd::from_raw_fd(r as RawFd) };
        // the kernel makes it close-on-exec; say so again, so no exec can carry it
        rustix::io::fcntl_setfd(&fd, rustix::io::FdFlags::CLOEXEC).map_err(io::Error::from)?;
        Ok(fd)
    }

    /// One line (without its `\n`) of at most `max` bytes. Nothing after the line is sent before it is answered, so
    /// reading in chunks never takes more than the line.
    fn read_line(mut s: &UnixStream, max: usize) -> io::Result<String> {
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let n = s.read(&mut buf)?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the other side closed",
                ));
            }
            out.extend_from_slice(&buf[..n]);
            if out.last() == Some(&b'\n') {
                out.pop();
                return String::from_utf8(out)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "not UTF-8"));
            }
            if out.len() > max {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "too long"));
            }
        }
    }

    fn deadlines(s: &UnixStream) -> io::Result<()> {
        s.set_read_timeout(Some(HANDOFF_DEADLINE))?;
        s.set_write_timeout(Some(HANDOFF_DEADLINE))
    }

    pub(super) fn offer(sock: &Path, scope: Scope, command: &str) -> Offered {
        if command.len() > HELLO_MAX {
            return Offered::Untraced(format!("the command is longer than {HELLO_MAX} bytes"));
        }
        let s = match UnixStream::connect(sock) {
            Ok(s) => s,
            Err(e) => {
                return Offered::Untraced(format!("no supervisor at {}: {e}", sock.display()));
            }
        };
        if let Err(e) = deadlines(&s) {
            return Offered::Untraced(format!("the hand-off socket: {e}"));
        }
        let hello = Hello {
            v: VERSION,
            scope,
            command: command.to_owned(),
        };
        let mut line = serde_json::to_vec(&hello).unwrap_or_default();
        line.push(b'\n');
        if let Err(e) = (&s).write_all(&line) {
            return Offered::Untraced(format!("the hello: {e}"));
        }
        match read_line(&s, 64).as_deref() {
            Ok("trace") => {}
            Ok("skip") => return Offered::Skipped,
            Ok(other) => return Offered::Untraced(format!("the supervisor answered {other:?}")),
            Err(e) => return Offered::Untraced(format!("no answer: {e}")),
        }
        match install() {
            Ok(fd) => match send_fd(&s, fd.as_fd(), b"fd\n") {
                Ok(()) => Offered::Traced,
                Err(e) => Offered::Lost(format!(
                    "the open listener is installed but did not reach the supervisor: {e}"
                )),
            },
            Err(e) if e.raw_os_error() == Some(libc::EBUSY) => {
                let _ = (&s).write_all(b"busy\n");
                Offered::Busy
            }
            Err(e) => {
                let _ = (&s).write_all(format!("failed: {e}\n").as_bytes());
                Offered::Untraced(format!("the open listener: {e}"))
            }
        }
    }

    fn send_fd(s: &UnixStream, fd: BorrowedFd<'_>, payload: &[u8]) -> io::Result<()> {
        let raw = fd.as_raw_fd();
        // SAFETY: the message, its iovec and its control buffer outlive the call; CMSG_* stay inside the buffer.
        unsafe {
            let mut iov = libc::iovec {
                iov_base: payload.as_ptr() as *mut _,
                iov_len: payload.len(),
            };
            let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
            let mut cbuf = vec![0u8; space];
            let mut msg: libc::msghdr = std::mem::zeroed();
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = cbuf.as_mut_ptr() as *mut _;
            msg.msg_controllen = space as _;
            let c = libc::CMSG_FIRSTHDR(&msg);
            (*c).cmsg_level = libc::SOL_SOCKET;
            (*c).cmsg_type = libc::SCM_RIGHTS;
            (*c).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
            std::ptr::write_unaligned(libc::CMSG_DATA(c) as *mut RawFd, raw);
            if libc::sendmsg(s.as_raw_fd(), &msg, libc::MSG_NOSIGNAL) < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    /// One message up to its `\n`, and the fd that came with it, if any (close-on-exec on our side).
    fn recv_fd(s: &UnixStream) -> io::Result<(Option<OwnedFd>, String)> {
        let mut text = Vec::new();
        let mut got: Option<OwnedFd> = None;
        while text.last() != Some(&b'\n') {
            let mut buf = [0u8; 512];
            // SAFETY: as in send_fd; a received fd is owned at once.
            let n = unsafe {
                let mut iov = libc::iovec {
                    iov_base: buf.as_mut_ptr() as *mut _,
                    iov_len: buf.len(),
                };
                let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
                let mut cbuf = vec![0u8; space];
                let mut msg: libc::msghdr = std::mem::zeroed();
                msg.msg_iov = &mut iov;
                msg.msg_iovlen = 1;
                msg.msg_control = cbuf.as_mut_ptr() as *mut _;
                msg.msg_controllen = space as _;
                let n = libc::recvmsg(s.as_raw_fd(), &mut msg, libc::MSG_CMSG_CLOEXEC);
                if n < 0 {
                    return Err(io::Error::last_os_error());
                }
                let c = libc::CMSG_FIRSTHDR(&msg);
                if !c.is_null()
                    && (*c).cmsg_level == libc::SOL_SOCKET
                    && (*c).cmsg_type == libc::SCM_RIGHTS
                {
                    let fd = std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const RawFd);
                    got = Some(OwnedFd::from_raw_fd(fd));
                }
                n as usize
            };
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the traced side closed",
                ));
            }
            text.extend_from_slice(&buf[..n]);
            if text.len() > 4096 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "too long"));
            }
        }
        text.pop();
        Ok((got, String::from_utf8_lossy(&text).into_owned()))
    }

    fn peer_pid(s: &UnixStream) -> Option<i32> {
        let mut cred = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: a buffer of the option's size.
        let r = unsafe {
            libc::getsockopt(
                s.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut cred as *mut _ as *mut _,
                &mut len,
            )
        };
        (r == 0 && cred.pid > 0).then_some(cred.pid)
    }

    pub(super) fn accept(stream: UnixStream) -> io::Result<Offer> {
        deadlines(&stream)?;
        let line = read_line(&stream, HELLO_MAX + 4096)?;
        let hello: Hello = serde_json::from_str(&line)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("the hello: {e}")))?;
        if hello.v != VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("hello version {} is not {VERSION}", hello.v),
            ));
        }
        Ok(Offer {
            peer_pid: peer_pid(&stream),
            hello,
            stream,
        })
    }

    pub(super) fn trace(stream: UnixStream) -> io::Result<Handed> {
        (&stream).write_all(b"trace\n")?;
        let (fd, text) = recv_fd(&stream)?;
        Ok(match (fd, text.as_str()) {
            (Some(fd), "fd") => Handed::Listener(fd),
            (None, "busy") => Handed::Busy,
            (_, t) => Handed::Failed(t.strip_prefix("failed: ").unwrap_or(t).to_owned()),
        })
    }

    fn set_sync(fd: &OwnedFd, opts: &ListenOptions) -> Result<(), i32> {
        #[cfg(feature = "test-hooks")]
        if let Some(e) = opts.set_flags_errno {
            return Err(e);
        }
        let _ = opts;
        // SAFETY: an ioctl on our listener fd with a by-value flag.
        let r = unsafe { libc::ioctl(fd.as_raw_fd(), IOCTL_SET_FLAGS as _, FD_SYNC_WAKE_UP) };
        if r < 0 { Err(errno()) } else { Ok(()) }
    }

    pub(super) fn listen(
        fd: OwnedFd,
        opts: ListenOptions,
        out: Sender<Open>,
    ) -> io::Result<Listener> {
        let arch = crate::seccomp::native().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Unsupported,
                "no open filter for this architecture",
            )
        })?;
        // ENOSYS (before 6.6) or anything else: the plain mode
        let sync = opts.sync_wakeup && set_sync(&fd, &opts).is_ok();
        let mut ends = [0 as RawFd; 2];
        // SAFETY: a two-int buffer.
        if unsafe { libc::pipe2(ends.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: two fresh fds we own.
        let (stop_r, stop_w) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        let reading = Arc::new(AtomicBool::new(true));
        let counts = Arc::new(Counts::default());
        let a = Answerer {
            fd,
            stop: stop_r,
            calls: calls(arch),
            ignore: opts.ignore_tgid,
            reading: reading.clone(),
            counts: counts.clone(),
            out,
            mems: HashMap::new(),
            tgids: HashMap::new(),
        };
        let thread = std::thread::Builder::new()
            .name(WRAPPER_NAME.into())
            .spawn(move || a.run())?;
        Ok(Listener {
            stop: Some(stop_w),
            reading,
            counts,
            sync,
            thread: Some(thread),
        })
    }

    struct Answerer {
        fd: OwnedFd,
        stop: OwnedFd,
        calls: &'static [(Call, u32)],
        ignore: Option<u32>,
        reading: Arc<AtomicBool>,
        counts: Arc<Counts>,
        out: Sender<Open>,
        mems: HashMap<u32, File>,
        tgids: HashMap<u32, u32>,
    }

    impl Answerer {
        fn run(mut self) -> Ended {
            let mut ended = Ended::default();
            loop {
                let mut fds = [
                    libc::pollfd {
                        fd: self.fd.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                    libc::pollfd {
                        fd: self.stop.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                ];
                // SAFETY: two valid pollfds.
                if unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) } < 0 {
                    match errno() {
                        libc::EINTR => continue,
                        e => {
                            ended.error = Some(e);
                            break;
                        }
                    }
                }
                if fds[1].revents != 0 {
                    break; // stop asked (the write end closed)
                }
                if fds[0].revents & libc::POLLIN == 0 {
                    if fds[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                        break; // every task the filter covered is gone
                    }
                    continue;
                }
                let mut n = Notif::default();
                // SAFETY: a buffer of the kernel's struct seccomp_notif.
                let r = unsafe {
                    libc::ioctl(self.fd.as_raw_fd(), IOCTL_RECV as _, &mut n as *mut Notif)
                };
                if r < 0 {
                    match errno() {
                        // one cancelled notification, or (6.6+) no task left: back to poll, which says which
                        libc::ENOENT | libc::EINTR => continue,
                        e => {
                            ended.error = Some(e);
                            break;
                        }
                    }
                }
                self.one(&n, &mut ended);
            }
            ended
        }

        /// Read, check, continue; then hand what was read on.
        fn one(&mut self, n: &Notif, ended: &mut Ended) {
            let t0 = Instant::now();
            ended.notifications += 1;
            self.counts.notifications.fetch_add(1, Ordering::Relaxed);
            let a = n.data.args;
            let call = self
                .calls
                .iter()
                .find(|(_, nr)| *nr as i32 == n.data.nr)
                .map_or(Call::Openat, |(c, _)| *c);
            let (ptr, dirfd) = match call {
                Call::Open => (a[0], libc::AT_FDCWD),
                Call::Openat | Call::Openat2 => (a[1], a[0] as i32),
            };
            let mut read = None;
            if self.ignore.is_some() && self.tgid(n.pid) == self.ignore {
                ended.ignored += 1;
            } else if !self.reading.load(Ordering::Relaxed) {
                ended.unread += 1;
            } else if self.valid(n.id) {
                let path = self.path(n.pid, ptr);
                let flags = match call {
                    Call::Open => a[1],
                    Call::Openat => a[2],
                    Call::Openat2 => self.u64_at(n.pid, a[2]).unwrap_or(0),
                };
                let base = match &path {
                    Some(p) if p.first() != Some(&b'/') => base_of(n.pid, dirfd),
                    _ => None,
                };
                if let Some(p) = path
                    && self.valid(n.id)
                {
                    read = Some((p, base, flags));
                }
            }
            self.continue_(n.id);
            self.counts
                .answering_ns
                .fetch_add(t0.elapsed().as_nanos() as u64, Ordering::Relaxed);
            if let Some((p, base, flags)) = read {
                let open = Open {
                    pid: n.pid,
                    call,
                    path: PathBuf::from(std::ffi::OsStr::from_bytes(&p)),
                    base,
                    flags,
                    at: t0,
                };
                if self.out.send(open).is_err() {
                    // nobody keeps the opens any more: only the round trip from here on
                    self.reading.store(false, Ordering::Relaxed);
                }
            }
        }

        fn valid(&self, id: u64) -> bool {
            // SAFETY: an ioctl on our listener fd with a pointer to a u64.
            unsafe { libc::ioctl(self.fd.as_raw_fd(), IOCTL_ID_VALID as _, &id as *const u64) == 0 }
        }

        fn continue_(&self, id: u64) {
            let resp = Resp {
                id,
                val: 0,
                error: 0,
                flags: FLAG_CONTINUE,
            };
            // SAFETY: an ioctl on our listener fd with a struct seccomp_notif_resp. ENOENT (the task went) is fine.
            unsafe { libc::ioctl(self.fd.as_raw_fd(), IOCTL_SEND as _, &resp as *const Resp) };
        }

        fn mem(&mut self, pid: u32) -> Option<&File> {
            if !self.mems.contains_key(&pid) {
                if self.mems.len() >= MEMS_MAX {
                    self.mems.clear();
                }
                let f = File::open(format!("/proc/{pid}/mem")).ok()?;
                self.mems.insert(pid, f);
            }
            self.mems.get(&pid)
        }

        /// The NUL-terminated string at `addr` in `pid`'s memory; a reused pid's stale file is opened again once.
        fn path(&mut self, pid: u32, addr: u64) -> Option<Vec<u8>> {
            for _ in 0..2 {
                if let Some(p) = self.mem(pid).and_then(|f| read_cstr(f, addr)) {
                    return Some(p);
                }
                self.mems.remove(&pid);
            }
            None
        }

        fn u64_at(&mut self, pid: u32, addr: u64) -> Option<u64> {
            let mut b = [0u8; 8];
            self.mem(pid)?.read_exact_at(&mut b, addr).ok()?;
            Some(u64::from_ne_bytes(b))
        }

        /// The thread group of task `tid` (cached: a task's group never changes).
        fn tgid(&mut self, tid: u32) -> Option<u32> {
            if let Some(g) = self.tgids.get(&tid) {
                return Some(*g);
            }
            let s = std::fs::read_to_string(format!("/proc/{tid}/status")).ok()?;
            let g = s
                .lines()
                .find_map(|l| l.strip_prefix("Tgid:"))
                .and_then(|v| v.trim().parse().ok())?;
            if self.tgids.len() >= TGIDS_MAX {
                self.tgids.clear();
            }
            self.tgids.insert(tid, g);
            Some(g)
        }
    }

    /// What a relative path is relative to: the task's working directory, or the dirfd's target.
    fn base_of(pid: u32, dirfd: i32) -> Option<PathBuf> {
        let link = if dirfd == libc::AT_FDCWD {
            format!("/proc/{pid}/cwd")
        } else {
            format!("/proc/{pid}/fd/{dirfd}")
        };
        std::fs::read_link(link).ok()
    }

    fn read_cstr(mem: &File, mut addr: u64) -> Option<Vec<u8>> {
        let mut out = Vec::with_capacity(128);
        let mut buf = [0u8; 256];
        while out.len() < PATH_MAX {
            // never across a page: the next page may be unmapped
            let room = (4096 - (addr % 4096)) as usize;
            let want = room.min(buf.len()).min(PATH_MAX - out.len());
            let n = mem.read_at(&mut buf[..want], addr).ok()?;
            if n == 0 {
                return None;
            }
            if let Some(z) = buf[..n].iter().position(|&b| b == 0) {
                out.extend_from_slice(&buf[..z]);
                return Some(out);
            }
            out.extend_from_slice(&buf[..n]);
            addr += n as u64;
        }
        None
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// The structs are the kernel's sizes, which the ioctl numbers encode.
        #[test]
        fn structs_are_the_kernels_sizes() {
            assert_eq!(std::mem::size_of::<Notif>(), 0x50);
            assert_eq!(std::mem::size_of::<Resp>(), 0x18);
            assert_eq!((IOCTL_RECV >> 16) & 0x3fff, 0x50);
            assert_eq!((IOCTL_SEND >> 16) & 0x3fff, 0x18);
        }

        /// The native numbers are libc's.
        #[test]
        fn native_numbers_are_libcs() {
            let arch = crate::seccomp::native().unwrap();
            for (call, nr) in calls(arch) {
                let want = match call {
                    #[cfg(target_arch = "x86_64")]
                    Call::Open => libc::SYS_open,
                    #[cfg(not(target_arch = "x86_64"))]
                    Call::Open => unreachable!("no open on this architecture"),
                    Call::Openat => libc::SYS_openat,
                    Call::Openat2 => libc::SYS_openat2,
                };
                assert_eq!(*nr as libc::c_long, want, "{call:?}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pattern D. The filter: the architecture check jumps to ALLOW, each open call's jump lands on USER_NOTIF.
    #[test]
    fn the_program_notifies_open_calls_only() {
        for arch in [Arch::X86_64, Arch::Aarch64] {
            let p = program(arch);
            let calls = calls(arch);
            let allow = p.len() - 2;
            let notif = p.len() - 1;
            assert_eq!((p[allow].code, p[allow].k), (RET_K, RET_ALLOW));
            assert_eq!((p[notif].code, p[notif].k), (RET_K, RET_USER_NOTIF));
            assert_eq!(p[1].k, arch.audit());
            assert_eq!(2 + p[1].jf as usize, allow, "a foreign arch is allowed");
            for (j, (_, nr)) in calls.iter().enumerate() {
                let at = 3 + j;
                assert_eq!((p[at].code, p[at].k), (JEQ_K, *nr));
                assert_eq!(at + 1 + p[at].jt as usize, notif);
                assert_eq!(p[at].jf, 0);
            }
            assert_eq!(p.len(), 3 + calls.len() + 2);
        }
    }

    /// Pattern D. Read or write by the flags; a relative path joins its base.
    #[test]
    fn an_open_is_a_write_by_its_flags() {
        let o = |path: &str, base: Option<&str>, flags: u64| Open {
            pid: 1,
            call: Call::Openat,
            path: path.into(),
            base: base.map(PathBuf::from),
            flags,
            at: Instant::now(),
        };
        assert!(!o("a", Some("/w"), 0).writes());
        assert_eq!(o("a", Some("/w"), 0).full(), Some(PathBuf::from("/w/a")));
        assert_eq!(o("a", None, 0).full(), None);
        assert_eq!(o("/x/a", None, 0).full(), Some(PathBuf::from("/x/a")));
        for f in [0o1, 0o2, 0o100, 0o1000, 0o1101] {
            assert!(o("c", Some("/w"), f).writes(), "{f:o}");
        }
        assert!(
            !o("c", Some("/w"), 0o2000000 | 0o400000).writes(),
            "O_CLOEXEC | O_NOFOLLOW read"
        );
    }

    /// The hello's wire form.
    #[test]
    fn the_hello_round_trips() {
        let h = Hello {
            v: VERSION,
            scope: Scope::Step,
            command: "cat 'a b'\nx".into(),
        };
        let line = serde_json::to_string(&h).unwrap();
        assert!(!line.contains('\n'));
        assert_eq!(serde_json::from_str::<Hello>(&line).unwrap(), h);
        assert!(
            serde_json::from_str::<Hello>(r#"{"v":1,"scope":"step","command":"x","fd":3}"#)
                .is_err()
        );
    }
}
