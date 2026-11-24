//! The escape probes' raw attempts: what the sandbox's own layers are measured against (docs/develop/gleipnir.md,
//! "Proving it"). `gleipnir-probe` (the `gleipnir-escape` crate's bin) runs them and prints what each found.
//!
//! These calls go to the kernel directly (`libc`, and `std`'s sockets and directory reads), never through the owner
//! crates (`eitri`, `draugr`, `stund`): an owner's guards (no links followed, a closed environment, a deadline) would
//! refuse or change the very attempt, and a "blocked" result would then come from our wrapper and not from the sandbox.
//! A probe never prints file contents. Everything else the probe binary does (its arguments, errors, output, the
//! handshake's files and waits) goes through the owner crates in the bin itself.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

/// What a probe found: `Ok(detail)` is `reached`; `Err((errno, detail))` is `blocked`. An errno of 0 says "no errno".
pub type Res = Result<Option<String>, (i32, Option<String>)>;

/// A probe's whole outcome: `Res` plus the output byte count only `run` has.
pub type Full = Result<(Option<String>, Option<u64>), (i32, Option<String>)>;

const TIMEOUT: Duration = Duration::from_secs(2);

/// How long a `run` probe's command may take before its group is killed.
const RUN_LIMIT: Duration = Duration::from_secs(600);

fn os(e: std::io::Error) -> (i32, Option<String>) {
    let n = e.raw_os_error().unwrap_or(match e.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => libc::ETIMEDOUT,
        _ => libc::EIO,
    });
    (n, None)
}

fn last_errno() -> (i32, Option<String>) {
    (
        std::io::Error::last_os_error()
            .raw_os_error()
            .unwrap_or(libc::EIO),
        None,
    )
}

fn unsupported(why: &str) -> (i32, Option<String>) {
    (libc::EOPNOTSUPP, Some(why.to_string()))
}

/// A malformed probe line (an unknown probe, too few arguments, a word that is not one): what the usage message says.
#[derive(Debug)]
pub struct Usage(pub String);

/// How many arguments probe NAME needs (`None`: there is no such probe).
fn arity(name: &str) -> Option<usize> {
    Some(match name {
        "listen-tcp" | "fds" | "landlock-abi" => 0,
        "read" | "write" | "create" | "list" | "stat" | "mkdir" | "unlink" | "connect-unix"
        | "connect-abstract" | "connect-tcp" | "tfo" | "udp" | "unix-self" | "tcp-self"
        | "bind-tcp" | "env-has" | "syscall" | "status-field" | "spawn-sleep"
        | "spawn-sleep-setsid" | "http-connect" | "http-get" | "run" => 1,
        "rename" | "link" | "clone" | "swap" | "socket" | "proc-read" | "kill"
        | "http-connect-flood" => 2,
        "serve-http" => 3,
        _ => return None,
    })
}

/// Probe NAME with its arguments A: `Ok((detail, out_bytes))` when it reached, `Err((errno, detail))` when it was
/// blocked, and a [`Usage`] when the line is malformed.
pub fn probe(name: &str, a: &[String]) -> Result<Full, Usage> {
    let Some(need) = arity(name) else {
        return Err(Usage(format!("unknown probe {name:?}")));
    };
    if a.len() < need {
        return Err(Usage(format!("{name} needs {need} argument(s)")));
    }
    if name == "run" {
        return Ok(run(a));
    }
    let r: Res = match name {
        "read" => read(&a[0]),
        "write" => open_raw(&a[0], libc::O_WRONLY, 0),
        "create" => open_raw(&a[0], libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC, 0o600),
        "list" => list(&a[0]),
        "stat" => std::fs::metadata(&a[0])
            .map(|m| Some(m.len().to_string()))
            .map_err(os),
        "rename" => rename_raw(&a[0], &a[1]),
        "link" => std::fs::hard_link(&a[0], &a[1]).map(|_| None).map_err(os),
        "clone" => clone(&a[0], &a[1]),
        "mkdir" => std::fs::create_dir(&a[0]).map(|_| None).map_err(os),
        "unlink" => std::fs::remove_file(&a[0]).map(|_| None).map_err(os),
        "swap" => swap(&a[0], &a[1]),
        "connect-unix" => UnixStream::connect(&a[0]).map(|_| None).map_err(os),
        "connect-abstract" => connect_abstract(&a[0]),
        "connect-tcp" => connect_tcp(&a[0]),
        "tfo" => tfo(&a[0]),
        "udp" => udp(&a[0]),
        "unix-self" => unix_self(&a[0]),
        "tcp-self" => tcp_self(&a[0]),
        "bind-tcp" => resolve(&a[0])
            .and_then(|addr| std::net::TcpListener::bind(addr).map_err(os))
            .map(|_| None),
        "listen-tcp" => listen_tcp(),
        "socket" => socket(a)?,
        "env-has" => env_has(a),
        "syscall" => syscall(&a[0])?,
        "status-field" => status_field(&a[0]),
        "fds" => Ok(Some(open_fds())),
        "proc-read" => std::fs::read(format!("/proc/{}/{}", a[0], a[1]))
            .map(|b| Some(b.len().to_string()))
            .map_err(os),
        "spawn-sleep" => spawn_sleep(&a[0], false),
        "spawn-sleep-setsid" => spawn_sleep(&a[0], true),
        "kill" => kill(&a[0], &a[1]),
        "http-connect" => http_connect(&a[0], 0),
        // As http-connect, but the client keeps sending (`BYTES` of filler) after its head, so a proxy that refuses it
        // and closes with unread data in its socket resets the connection (GLP-T10-3): the refusal must still arrive.
        "http-connect-flood" => {
            let bytes = a[1]
                .parse()
                .map_err(|_| Usage("BYTES is a number".into()))?;
            http_connect(&a[0], bytes)
        }
        "http-get" => http_get(&a[0]),
        "landlock-abi" => landlock_abi(),
        "serve-http" => serve_http(a),
        _ => return Err(Usage(format!("unknown probe {name:?}"))),
    };
    Ok(r.map(|d| (d, None)))
}

/// `open(2)` of PATH with FLAGS and MODE, closed at once: reached when the kernel allows it.
fn open_raw(path: &str, flags: i32, mode: u32) -> Res {
    let p = std::ffi::CString::new(path).map_err(|_| (libc::EINVAL, None))?;
    // SAFETY: a valid NUL-terminated path; the descriptor, if any, is closed at once.
    let fd = unsafe { libc::open(p.as_ptr(), flags | libc::O_CLOEXEC, mode) };
    if fd < 0 {
        return Err(last_errno());
    }
    // SAFETY: `fd` was just returned by open(2).
    unsafe { libc::close(fd) };
    Ok(None)
}

/// `rename(2)` of FROM to TO.
fn rename_raw(from: &str, to: &str) -> Res {
    let (a, b) = (
        std::ffi::CString::new(from).map_err(|_| (libc::EINVAL, None))?,
        std::ffi::CString::new(to).map_err(|_| (libc::EINVAL, None))?,
    );
    // SAFETY: two valid NUL-terminated strings.
    if unsafe { libc::rename(a.as_ptr(), b.as_ptr()) } == 0 {
        Ok(None)
    } else {
        Err(last_errno())
    }
}

/// `serve-http PORT N TEXT`: a dev server stand-in on `127.0.0.1:PORT` that answers N requests, each `200` with TEXT
/// as its body, then ends; `reached` says how many it served.
fn serve_http(a: &[String]) -> Res {
    let port: u16 = a[0].parse().map_err(|_| (libc::EINVAL, None))?;
    let n: usize = a[1].parse().map_err(|_| (libc::EINVAL, None))?;
    let listener = std::net::TcpListener::bind(("127.0.0.1", port)).map_err(os)?;
    for _ in 0..n {
        let (mut c, _) = listener.accept().map_err(os)?;
        let mut head = Vec::new();
        let mut b = [0u8; 1024];
        while !head.windows(4).any(|w| w == b"\r\n\r\n") {
            match c.read(&mut b) {
                Ok(0) | Err(_) => break,
                Ok(k) => head.extend_from_slice(&b[..k]),
            }
        }
        let body = a[2].as_bytes();
        // a client that went away before its answer is not the probe's result
        drop(write!(
            c,
            "HTTP/1.0 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        ));
        drop(c.write_all(body));
    }
    Ok(Some(format!("served {n}")))
}

fn read(path: &str) -> Res {
    let f = std::fs::File::open(path).map_err(os)?;
    // The size only: a directory has one too, and nothing is read.
    Ok(Some(f.metadata().map_err(os)?.len().to_string()))
}

fn list(dir: &str) -> Res {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map_err(os)?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    Ok(Some(names.join(",").chars().take(3000).collect()))
}

#[cfg(target_os = "macos")]
fn clone(a: &str, b: &str) -> Res {
    use std::ffi::CString;
    let (a, b) = (
        CString::new(a).map_err(|_| (libc::EINVAL, None))?,
        CString::new(b).map_err(|_| (libc::EINVAL, None))?,
    );
    // SAFETY: two valid NUL-terminated strings.
    if unsafe { libc::clonefile(a.as_ptr(), b.as_ptr(), 0) } == 0 {
        Ok(None)
    } else {
        Err(last_errno())
    }
}

#[cfg(not(target_os = "macos"))]
fn clone(_: &str, _: &str) -> Res {
    Err(unsupported("clonefile needs macos"))
}

/// Exchanges two paths in one step: `renamex_np(RENAME_SWAP)` on macOS, `renameat2(RENAME_EXCHANGE)` on Linux.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn swap(a: &str, b: &str) -> Res {
    use std::ffi::CString;
    let (a, b) = (
        CString::new(a).map_err(|_| (libc::EINVAL, None))?,
        CString::new(b).map_err(|_| (libc::EINVAL, None))?,
    );
    #[cfg(target_os = "macos")]
    // SAFETY: two valid NUL-terminated strings.
    let r = unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_SWAP) as libc::c_long };
    #[cfg(target_os = "linux")]
    // SAFETY: two valid NUL-terminated strings; 2 is RENAME_EXCHANGE.
    let r = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            a.as_ptr(),
            libc::AT_FDCWD,
            b.as_ptr(),
            2u32,
        )
    };
    if r == 0 { Ok(None) } else { Err(last_errno()) }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn swap(_: &str, _: &str) -> Res {
    Err(unsupported("swap needs macos or linux"))
}

#[cfg(target_os = "linux")]
fn connect_abstract(name: &str) -> Res {
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.trim_start_matches('@'))
        .map_err(os)?;
    UnixStream::connect_addr(&addr).map(|_| None).map_err(os)
}

#[cfg(not(target_os = "linux"))]
fn connect_abstract(_: &str) -> Res {
    Err(unsupported("abstract sockets need linux"))
}

fn resolve(target: &str) -> Result<SocketAddr, (i32, Option<String>)> {
    target
        .to_socket_addrs()
        .map_err(os)?
        .next()
        .ok_or((libc::EINVAL, Some("no address".into())))
}

fn connect_tcp(target: &str) -> Res {
    let addr = resolve(target)?;
    TcpStream::connect_timeout(&addr, TIMEOUT)
        .map(|_| None)
        .map_err(os)
}

/// `sendto(MSG_FASTOPEN)`: a data-carrying SYN that skips `connect(2)`.
#[cfg(target_os = "linux")]
fn tfo(target: &str) -> Res {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let addr = resolve(target)?;
    let family = if addr.is_ipv4() {
        libc::AF_INET
    } else {
        libc::AF_INET6
    };
    // SAFETY: a plain socket(2); the fd is owned from here.
    let fd = unsafe { libc::socket(family, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(last_errno());
    }
    // SAFETY: `fd` was just returned by socket(2).
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let tv = libc::timeval {
        tv_sec: TIMEOUT.as_secs() as _,
        tv_usec: 0,
    };
    // SAFETY: a valid timeval of the stated size.
    unsafe {
        libc::setsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDTIMEO,
            (&raw const tv).cast(),
            size_of::<libc::timeval>() as libc::socklen_t,
        );
    }
    // SAFETY: zeroed sockaddr_storage is valid; the filled part matches `len`.
    let (storage, len) = unsafe {
        let mut st: libc::sockaddr_storage = std::mem::zeroed();
        let len = match addr {
            SocketAddr::V4(a) => {
                let p = (&raw mut st).cast::<libc::sockaddr_in>();
                (*p).sin_family = libc::AF_INET as _;
                (*p).sin_port = a.port().to_be();
                (*p).sin_addr.s_addr = u32::from_ne_bytes(a.ip().octets());
                size_of::<libc::sockaddr_in>()
            }
            SocketAddr::V6(a) => {
                let p = (&raw mut st).cast::<libc::sockaddr_in6>();
                (*p).sin6_family = libc::AF_INET6 as _;
                (*p).sin6_port = a.port().to_be();
                (*p).sin6_addr.s6_addr = a.ip().octets();
                size_of::<libc::sockaddr_in6>()
            }
        };
        (st, len as libc::socklen_t)
    };
    // SAFETY: the buffer and the address are valid for their lengths.
    let n = unsafe {
        libc::sendto(
            fd.as_raw_fd(),
            b"glp".as_ptr().cast(),
            3,
            libc::MSG_FASTOPEN,
            (&raw const storage).cast(),
            len,
        )
    };
    if n < 0 { Err(last_errno()) } else { Ok(None) }
}

#[cfg(not(target_os = "linux"))]
fn tfo(_: &str) -> Res {
    Err(unsupported("MSG_FASTOPEN needs linux"))
}

fn udp(target: &str) -> Res {
    let addr = resolve(target)?;
    let local = if addr.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let sock = UdpSocket::bind(local).map_err(os)?;
    sock.set_read_timeout(Some(Duration::from_millis(500)))
        .map_err(os)?;
    sock.send_to(b"glp", addr).map_err(os)?;
    let mut buf = [0u8; 16];
    match sock.recv_from(&mut buf) {
        Ok(_) => Ok(Some("echo".into())),
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            Err((0, Some("no echo".into())))
        }
        Err(e) => Err(os(e)),
    }
}

fn unix_self(path: &str) -> Res {
    // a leftover of an earlier probe, or nothing there
    drop(std::fs::remove_file(path));
    let listener = UnixListener::bind(path).map_err(|e| {
        let (n, _) = os(e);
        (n, Some("bind".into()))
    })?;
    let r = UnixStream::connect(path).map(|_| None).map_err(|e| {
        let (n, _) = os(e);
        (n, Some("connect".into()))
    });
    drop(listener);
    drop(std::fs::remove_file(path));
    r
}

/// Binds HOST:PORT, connects to it and accepts: a program's own loopback traffic (a debug adapter and its debuggee).
/// The detail of a refusal says which step.
fn tcp_self(addr: &str) -> Res {
    let step = |s: &'static str| move |e: std::io::Error| (os(e).0, Some(s.to_string()));
    let addr = resolve(addr)?;
    let listener = std::net::TcpListener::bind(addr).map_err(step("bind"))?;
    let bound = listener.local_addr().map_err(step("bind"))?;
    let _client = std::net::TcpStream::connect(bound).map_err(step("connect"))?;
    listener.accept().map(|_| None).map_err(step("accept"))
}

/// `socket(DOMAIN, TYPE, PROTO)` and nothing more: the reduced tier's seccomp rules refuse by these three alone.
/// DOMAIN is `unix inet inet6 netlink packet vsock`, TYPE `stream dgram raw seqpacket`, PROTO a number or `tcp udp
/// icmp icmpv6 sctp mptcp` (default 0). Linux only (the reduced tier's rules; macOS has no such tier).
#[cfg(not(target_os = "linux"))]
fn socket(_: &[String]) -> Result<Res, Usage> {
    Ok(Err(unsupported("the socket probe needs linux")))
}

#[cfg(target_os = "linux")]
fn socket(a: &[String]) -> Result<Res, Usage> {
    let domain = match a[0].as_str() {
        "unix" => libc::AF_UNIX,
        "inet" => libc::AF_INET,
        "inet6" => libc::AF_INET6,
        "netlink" => libc::AF_NETLINK,
        "packet" => libc::AF_PACKET,
        "vsock" => libc::AF_VSOCK,
        other => return Err(Usage(format!("socket: unknown domain {other:?}"))),
    };
    let ty = match a[1].as_str() {
        "stream" => libc::SOCK_STREAM,
        "dgram" => libc::SOCK_DGRAM,
        "raw" => libc::SOCK_RAW,
        "seqpacket" => libc::SOCK_SEQPACKET,
        other => return Err(Usage(format!("socket: unknown type {other:?}"))),
    };
    let proto = match a.get(2).map_or("0", String::as_str) {
        "tcp" => libc::IPPROTO_TCP,
        "udp" => libc::IPPROTO_UDP,
        "icmp" => libc::IPPROTO_ICMP,
        "icmpv6" => libc::IPPROTO_ICMPV6,
        "sctp" => libc::IPPROTO_SCTP,
        "mptcp" => libc::IPPROTO_MPTCP,
        n => n
            .parse()
            .map_err(|_| Usage(format!("socket: unknown protocol {n:?}")))?,
    };
    // SAFETY: a plain socket(2); the fd is closed at once.
    let fd = unsafe { libc::socket(domain, ty | libc::SOCK_CLOEXEC, proto) };
    if fd < 0 {
        return Ok(Err(last_errno()));
    }
    // SAFETY: `fd` was just returned by socket(2).
    unsafe { libc::close(fd) };
    Ok(Ok(None))
}

/// Reached when any name is set; the detail names which (names only, never values).
fn env_has(names: &[String]) -> Res {
    let present: Vec<&str> = names
        .iter()
        .filter(|n| std::env::var_os(n).is_some())
        .map(String::as_str)
        .collect();
    if present.is_empty() {
        Err((0, Some("none present".into())))
    } else {
        Ok(Some(present.join(",")))
    }
}

fn status_field(name: &str) -> Res {
    let mut text = String::new();
    std::fs::File::open("/proc/self/status")
        .and_then(|mut f| f.read_to_string(&mut text))
        .map_err(os)?;
    text.lines()
        .find_map(|l| l.strip_prefix(name)?.strip_prefix(':'))
        .map(|v| Some(v.trim().to_string()))
        .ok_or((libc::ENOENT, Some("no such field".into())))
}

fn open_fds() -> String {
    let open: Vec<String> = (0..1024)
        .filter(|fd| {
            // SAFETY: F_GETFD only asks whether the descriptor exists.
            unsafe { libc::fcntl(*fd, libc::F_GETFD) != -1 }
        })
        .map(|fd| fd.to_string())
        .collect();
    open.join(",")
}

/// A child that sleeps `n` seconds without exec (so its command line is the probe's own, which the harness looks
/// for), with stdio on /dev/null so no pipe is held open. The probe does not wait for it.
///
/// `setsid`: the child first tries to leave the probe's process group and session (`setsid()`) and reports how that
/// went through a pipe: reached (the pid) when it left, blocked with the errno when it could not. Either way it then
/// sleeps, so a row can check that a kill of the sandbox's group still ends it (review S1).
fn spawn_sleep(n: &str, setsid: bool) -> Res {
    let secs: u32 = n.parse().map_err(|_| (libc::EINVAL, None))?;
    let mut fds = [-1i32; 2];
    // SAFETY: pipe(2) into a valid array.
    if setsid && unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(last_errno());
    }
    // SAFETY: the probe is single-threaded; the child only calls async-signal-safe functions.
    match unsafe { libc::fork() } {
        -1 => Err(last_errno()),
        0 => {
            // SAFETY: as above.
            unsafe {
                if setsid {
                    libc::close(fds[0]);
                    let e: i32 = if libc::setsid() < 0 {
                        std::io::Error::last_os_error()
                            .raw_os_error()
                            .unwrap_or(libc::EIO)
                    } else {
                        0
                    };
                    libc::write(fds[1], (&raw const e).cast(), 4);
                    libc::close(fds[1]);
                }
                let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
                for fd in 0..3 {
                    libc::dup2(null, fd);
                }
                let mut left = secs;
                while left > 0 {
                    left = libc::sleep(left);
                }
                libc::_exit(0);
            }
        }
        pid if setsid => {
            let mut e: i32 = -1;
            // SAFETY: plain reads and closes on the pipe made above.
            let n = unsafe {
                libc::close(fds[1]);
                let n = libc::read(fds[0], (&raw mut e).cast(), 4);
                libc::close(fds[0]);
                n
            };
            match (n, e) {
                (4, 0) => Ok(Some(pid.to_string())),
                (4, e) => Err((e, Some(pid.to_string()))),
                _ => Err((0, Some("the child said nothing".into()))),
            }
        }
        pid => Ok(Some(pid.to_string())),
    }
}

/// `listen(2)` on a TCP socket that was never bound: the kernel binds it to a free port on every address itself
/// (review S5). Reached when it listens; the detail is nothing (the port is the kernel's choice).
fn listen_tcp() -> Res {
    // SAFETY: plain socket/listen/close calls; the fd is closed before returning.
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err(last_errno());
        }
        let r = if libc::listen(fd, 1) == 0 {
            Ok(None)
        } else {
            Err(last_errno())
        };
        libc::close(fd);
        r
    }
}

fn kill(pid: &str, sig: &str) -> Res {
    let pid: i32 = pid.parse().map_err(|_| (libc::EINVAL, None))?;
    let sig: i32 = match sig.trim_start_matches("SIG") {
        "HUP" => libc::SIGHUP,
        "INT" => libc::SIGINT,
        "KILL" => libc::SIGKILL,
        "TERM" => libc::SIGTERM,
        "USR1" => libc::SIGUSR1,
        n => n.parse().map_err(|_| (libc::EINVAL, None))?,
    };
    // SAFETY: kill(2) with plain integers.
    if unsafe { libc::kill(pid, sig) } == 0 {
        Ok(None)
    } else {
        Err(last_errno())
    }
}

/// A command as a child: reached when it exits 0. Its output is counted, never printed.
fn run(cmd: &[String]) -> Full {
    use std::os::unix::process::ExitStatusExt;
    let spec = draugr::Spec {
        program: cmd[0].clone().into(),
        args: cmd[1..].iter().map(std::ffi::OsString::from).collect(),
        env: std::env::vars_os().collect(),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    };
    let out = draugr::run(spec, RUN_LIMIT).map_err(os)?;
    let bytes = (out.stdout.len() + out.stderr.len()) as u64;
    match (out.status.code(), out.status.signal()) {
        (Some(0), _) => Ok((Some("0".into()), Some(bytes))),
        (Some(c), _) => Err((0, Some(c.to_string()))),
        (None, s) => Err((0, Some(format!("signal {}", s.unwrap_or(0))))),
    }
}

/// A connection to `$HTTPS_PROXY`.
fn to_proxy() -> Result<TcpStream, (i32, Option<String>)> {
    let proxy = std::env::var("HTTPS_PROXY")
        .or_else(|_| std::env::var("https_proxy"))
        .map_err(|_| (libc::ENOENT, Some("HTTPS_PROXY is not set".into())))?;
    let hostport = proxy
        .split_once("://")
        .map_or(proxy.as_str(), |(_, rest)| rest)
        .trim_end_matches('/');
    let addr = resolve(hostport)?;
    let s = TcpStream::connect_timeout(&addr, TIMEOUT).map_err(os)?;
    s.set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(os)?;
    Ok(s)
}

/// A plain-HTTP `GET URL` in absolute-form through `$HTTPS_PROXY`, as a browser sends one to its proxy, with the
/// hop-by-hop headers a proxy must drop (`Proxy-*`, `Keep-Alive`, `TE`, `Upgrade`, and `X-Glp-Hop`, which
/// `Connection` lists) and one it must keep (`X-Glp-End`). Reached on a 200. The detail is the status code, then
/// each `X-Glp-NAME: VALUE` header of the answer as ` name=VALUE` (the escape fixture's upstream says what it got).
fn http_get(url: &str) -> Res {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let mut s = to_proxy()?;
    write!(
        s,
        "GET {url} HTTP/1.1\r\nHost: {host}\r\nProxy-Connection: keep-alive\r\n\
         Proxy-Authorization: Basic Z2xwOmdscA==\r\nKeep-Alive: timeout=5\r\nTE: trailers\r\nUpgrade: websocket\r\n\
         Connection: keep-alive, X-Glp-Hop\r\nX-Glp-Hop: 1\r\nX-Glp-End: 1\r\n\r\n"
    )
    .map_err(os)?;
    let mut head = Vec::new();
    let mut b = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") && head.len() < 4096 {
        if s.read(&mut b).map_err(os)? == 0 {
            break;
        }
        head.push(b[0]);
    }
    let text = String::from_utf8_lossy(&head);
    let mut lines = text.split("\r\n");
    let code = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .filter(|c| c.len() == 3 && c.bytes().all(|b| b.is_ascii_digit()))
        .ok_or((libc::EPROTONOSUPPORT, Some("no status line".into())))?;
    let mut detail = code.to_string();
    for l in lines {
        if let Some((name, value)) = l.split_once(':')
            && let Some(n) = name.to_ascii_lowercase().strip_prefix("x-glp-")
        {
            detail.push_str(&format!(" {n}={}", value.trim()));
        }
    }
    if code == "200" {
        Ok(Some(detail))
    } else {
        Err((0, Some(detail)))
    }
}

/// A CONNECT through `$HTTPS_PROXY`; the detail is the status code.
fn http_connect(target: &str, flood: usize) -> Res {
    let mut s = to_proxy()?;
    write!(s, "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").map_err(os)?;
    // the filler goes in one write, whatever the proxy does meanwhile: a reset or a broken pipe on it is not the
    // probe's answer, the status line is (or the reset it reads instead)
    if flood > 0 {
        drop(s.write_all(&vec![b'x'; flood]));
    }
    let mut head = Vec::new();
    let mut b = [0u8; 1];
    while !head.ends_with(b"\n") && head.len() < 256 {
        if s.read(&mut b).map_err(os)? == 0 {
            break;
        }
        head.push(b[0]);
    }
    let line = String::from_utf8_lossy(&head);
    let code = line
        .split_whitespace()
        .nth(1)
        .filter(|c| c.len() == 3 && c.bytes().all(|b| b.is_ascii_digit()))
        .ok_or((libc::EPROTONOSUPPORT, Some("no status line".into())))?;
    if code == "200" {
        Ok(Some(code.into()))
    } else {
        Err((0, Some(code.into())))
    }
}

#[cfg(target_os = "linux")]
fn landlock_abi() -> Res {
    // SAFETY: landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) only asks for the version.
    let v = unsafe { libc::syscall(444, std::ptr::null::<u8>(), 0usize, 1u32) };
    if v >= 1 {
        Ok(Some(v.to_string()))
    } else {
        Err(last_errno())
    }
}

#[cfg(not(target_os = "linux"))]
fn landlock_abi() -> Res {
    Err(unsupported("landlock needs linux"))
}

/// One syscall in a forked child, so a kill by the seccomp filter (SIGSYS) is a result and not the probe's end.
/// The child reports the errno (0 for success) through a pipe.
fn syscall(name: &str) -> Result<Res, Usage> {
    if !SYSCALLS.contains(&name) {
        return Err(Usage(format!("unknown syscall probe {name:?}")));
    }
    Ok(syscall_in_child(name))
}

fn syscall_in_child(name: &str) -> Res {
    let mut fds = [0i32; 2];
    // SAFETY: pipe/fork/waitpid with valid buffers; the child calls only syscalls and _exit.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return Err(last_errno());
        }
        let pid = libc::fork();
        if pid < 0 {
            return Err(last_errno());
        }
        if pid == 0 {
            libc::close(fds[0]);
            let e: i32 = attempt(name);
            libc::write(fds[1], (&raw const e).cast(), 4);
            libc::_exit(0);
        }
        libc::close(fds[1]);
        let mut e: i32 = -1;
        let n = libc::read(fds[0], (&raw mut e).cast(), 4);
        libc::close(fds[0]);
        let mut status = 0;
        libc::waitpid(pid, &raw mut status, 0);
        if libc::WIFSIGNALED(status) {
            let s = libc::WTERMSIG(status);
            let sig = if s == libc::SIGSYS {
                "SIGSYS".to_string()
            } else {
                format!("signal {s}")
            };
            return Err((0, Some(format!("killed by {sig}"))));
        }
        // No errno: EIO is what some rows' controls expect (TIOCSTI), so a silent child must not look like it.
        if n != 4 {
            return Err((0, Some("the child said nothing".into())));
        }
        if e == 0 { Ok(None) } else { Err((e, None)) }
    }
}

const SYSCALLS: &[&str] = &[
    "unshare-user",
    "io-uring",
    "keyctl",
    "add-key",
    "vsock",
    "clone3",
    "clone-newuser",
    "mount-missing",
    "tiocsti-own-pty",
    "tiocsti-high-own-pty",
    "ioctl-tioclinux",
    "ioctl-sg-io",
    "alloc-300mb",
    "open-many",
    "core-limit-zero",
    "pty-session",
    "ptrace-own-child",
    "x32-getpid",
    "i386-int80",
    "setsid",
    "setpgid",
    "pidfd-getfd",
    "process-vm-readv",
];

/// `setsid()` or `setpgid(0, 0)` in the forked child (which leads no group, so both work unconfined): its errno, 0
/// when it worked. Every Unix has them; the reduced tier refuses both (review S1).
fn leave_group(name: &str) -> i32 {
    // SAFETY: plain calls on the throwaway child's own process state.
    let r = unsafe {
        if name == "setsid" {
            libc::setsid()
        } else {
            libc::setpgid(0, 0)
        }
    };
    if r >= 0 {
        0
    } else {
        std::io::Error::last_os_error()
            .raw_os_error()
            .unwrap_or(libc::EIO)
    }
}

/// The errno of the call (0: it worked). Runs in the forked child.
#[cfg(target_os = "linux")]
fn attempt(name: &str) -> i32 {
    // SAFETY: each arm is one raw syscall (or libc call) with valid arguments; the process is a throwaway child.
    unsafe {
        let ret = |r: libc::c_long| if r >= 0 { 0 } else { *libc::__errno_location() };
        match name {
            "setsid" | "setpgid" => leave_group(name),
            "unshare-user" => ret(libc::syscall(libc::SYS_unshare, libc::CLONE_NEWUSER)),
            "io-uring" => {
                let params = [0u8; 128];
                let r = libc::syscall(libc::SYS_io_uring_setup, 1u32, params.as_ptr());
                if r >= 0 {
                    libc::close(r as i32);
                }
                ret(r)
            }
            "keyctl" => ret(libc::syscall(
                libc::SYS_keyctl,
                0, /* GET_KEYRING_ID */
                -3i64,
                0,
            )),
            "add-key" => ret(libc::syscall(
                libc::SYS_add_key,
                c"user".as_ptr(),
                c"glp".as_ptr(),
                c"x".as_ptr(),
                1usize,
                -3i32,
            )),
            "vsock" => {
                let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0);
                if fd >= 0 {
                    libc::close(fd);
                    0
                } else {
                    *libc::__errno_location()
                }
            }
            // A null argument block: the unfiltered kernel says EINVAL; the filter says ENOSYS.
            "clone3" => ret(libc::syscall(
                libc::SYS_clone3,
                std::ptr::null::<u8>(),
                0usize,
            )),
            "clone-newuser" => {
                let r = libc::syscall(
                    libc::SYS_clone,
                    (libc::CLONE_NEWUSER | libc::SIGCHLD) as libc::c_ulong,
                    0usize,
                    0usize,
                    0usize,
                    0usize,
                );
                if r == 0 {
                    libc::_exit(0);
                }
                if r > 0 {
                    libc::waitpid(r as i32, std::ptr::null_mut(), 0);
                }
                ret(r)
            }
            // The target does not exist: unfiltered, the path lookup says ENOENT; the filter says EPERM.
            "mount-missing" => {
                let r = libc::mount(
                    c"none".as_ptr(),
                    c"/glp-missing-target".as_ptr(),
                    c"tmpfs".as_ptr(),
                    0,
                    std::ptr::null(),
                );
                ret(r.into())
            }
            // An ioctl no program here needs, on /dev/null: ENOTTY unfiltered, EPERM from the filter's allowlist (GL-T5-1).
            "ioctl-tioclinux" => ioctl_on_null(0x541C),
            "ioctl-sg-io" => ioctl_on_null(0x2285),
            // What the spec's rlimits cap (Spec::rlimits): 300 MiB of address space, 40 descriptors, a core dump.
            "alloc-300mb" => {
                let len = 300usize << 20;
                let p = libc::mmap(
                    std::ptr::null_mut(),
                    len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                    -1,
                    0,
                );
                if p == libc::MAP_FAILED {
                    *libc::__errno_location()
                } else {
                    0
                }
            }
            "open-many" => {
                let mut e = 0;
                for _ in 0..40 {
                    if libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY) < 0 {
                        e = *libc::__errno_location();
                        break;
                    }
                }
                e
            }
            "core-limit-zero" => {
                let mut l = libc::rlimit {
                    rlim_cur: 1,
                    rlim_max: 1,
                };
                if libc::getrlimit(libc::RLIMIT_CORE, &mut l) == 0
                    && l.rlim_cur == 0
                    && l.rlim_max == 0
                {
                    0
                } else {
                    libc::EINVAL
                }
            }
            // What a terminal session does: open a pty, set its size and its modes (raw, cooked), read them back.
            "pty-session" => pty_session(),
            "tiocsti-own-pty" => tiocsti(false),
            "tiocsti-high-own-pty" => tiocsti(true),
            "ptrace-own-child" => {
                let child = libc::fork();
                if child == 0 {
                    libc::pause();
                    libc::_exit(0);
                }
                let r = libc::ptrace(libc::PTRACE_ATTACH, child, 0, 0);
                let e = if r == -1 {
                    *libc::__errno_location()
                } else {
                    0
                };
                libc::kill(child, libc::SIGKILL);
                libc::waitpid(child, std::ptr::null_mut(), 0);
                e
            }
            "x32-getpid" => x32_getpid(),
            "i386-int80" => i386_int80(),
            // A copy of the process's own stdin through a pidfd of itself: what would take another process's fd.
            "pidfd-getfd" => {
                let pidfd = libc::syscall(libc::SYS_pidfd_open, libc::getpid(), 0u32);
                if pidfd < 0 {
                    return *libc::__errno_location();
                }
                let r = libc::syscall(libc::SYS_pidfd_getfd, pidfd as i32, 0i32, 0u32);
                let e = ret(r);
                if r >= 0 {
                    libc::close(r as i32);
                }
                libc::close(pidfd as i32);
                e
            }
            // Four bytes of the process's own memory, read as another process's would be.
            "process-vm-readv" => {
                let src = [7u8; 4];
                let mut dst = [0u8; 4];
                let local = libc::iovec {
                    iov_base: dst.as_mut_ptr().cast(),
                    iov_len: 4,
                };
                let remote = libc::iovec {
                    iov_base: src.as_ptr() as *mut libc::c_void,
                    iov_len: 4,
                };
                ret(libc::syscall(
                    libc::SYS_process_vm_readv,
                    libc::getpid(),
                    &raw const local,
                    1usize,
                    &raw const remote,
                    1usize,
                    0usize,
                ))
            }
            _ => libc::ENOSYS,
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn attempt(name: &str) -> i32 {
    match name {
        "setsid" | "setpgid" => leave_group(name),
        _ => libc::ENOSYS,
    }
}

/// TIOCSTI on a pty the probe opens itself (never anyone's terminal). `high` sets bit 32 of the request register,
/// which the kernel ignores and a 64-bit compare in a filter would not.
#[cfg(target_os = "linux")]
unsafe fn tiocsti(high: bool) -> i32 {
    // SAFETY: the caller is a throwaway child; every call has valid arguments.
    unsafe {
        let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
        if m < 0 || libc::grantpt(m) != 0 || libc::unlockpt(m) != 0 {
            return *libc::__errno_location();
        }
        let mut name = [0 as libc::c_char; 64];
        if libc::ptsname_r(m, name.as_mut_ptr(), name.len()) != 0 {
            return libc::EIO;
        }
        let s = libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY);
        if s < 0 {
            return *libc::__errno_location();
        }
        let byte = b'x';
        let req = libc::TIOCSTI as libc::c_ulong | if high { 1 << 32 } else { 0 };
        let r = libc::syscall(libc::SYS_ioctl, s as libc::c_long, req, &raw const byte);
        if r >= 0 { 0 } else { *libc::__errno_location() }
    }
}

/// `ioctl(/dev/null, request, 0)`: its errno (0: it worked).
#[cfg(target_os = "linux")]
unsafe fn ioctl_on_null(request: libc::c_ulong) -> i32 {
    // SAFETY: the caller is a throwaway child; every call has valid arguments.
    unsafe {
        let fd = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if fd < 0 {
            return *libc::__errno_location();
        }
        let r = libc::syscall(libc::SYS_ioctl, fd as libc::c_long, request, 0usize);
        if r >= 0 { 0 } else { *libc::__errno_location() }
    }
}

/// A terminal session on a pty of its own: open it (TIOCGPTN, TIOCSPTLCK), set the window size, make the modes raw
/// and cooked again with every `tcsetattr` flavour, drain and flush, read the size back. The errno of the first thing
/// that fails (0: all worked).
#[cfg(target_os = "linux")]
unsafe fn pty_session() -> i32 {
    // SAFETY: the caller is a throwaway child; every call has valid arguments.
    unsafe {
        let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
        if m < 0 || libc::grantpt(m) != 0 || libc::unlockpt(m) != 0 {
            return *libc::__errno_location();
        }
        let mut name = [0 as libc::c_char; 64];
        if libc::ptsname_r(m, name.as_mut_ptr(), name.len()) != 0 {
            return libc::EIO;
        }
        let s = libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY);
        if s < 0 {
            return *libc::__errno_location();
        }
        let ws = libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if libc::ioctl(s, libc::TIOCSWINSZ, &raw const ws) != 0 {
            return *libc::__errno_location();
        }
        let mut t: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(s, &raw mut t) != 0 {
            return *libc::__errno_location();
        }
        let cooked = t;
        libc::cfmakeraw(&raw mut t);
        for when in [libc::TCSANOW, libc::TCSADRAIN, libc::TCSAFLUSH] {
            if libc::tcsetattr(s, when, &raw const t) != 0 {
                return *libc::__errno_location();
            }
        }
        if libc::tcsetattr(s, libc::TCSANOW, &raw const cooked) != 0
            || libc::tcdrain(s) != 0
            || libc::tcflush(s, libc::TCIOFLUSH) != 0
        {
            return *libc::__errno_location();
        }
        let mut back: libc::winsize = std::mem::zeroed();
        if libc::ioctl(s, libc::TIOCGWINSZ, &raw mut back) != 0 || back.ws_col != 80 {
            return *libc::__errno_location();
        }
        0
    }
}

/// `getpid` through the x32 ABI (bit 30 of the number): the filter kills it, an x32-less kernel says ENOSYS.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn x32_getpid() -> i32 {
    // SAFETY: getpid takes no arguments.
    let r = unsafe { libc::syscall(0x4000_0000 | 39) };
    if r >= 0 {
        0
    } else {
        // SAFETY: reads errno.
        unsafe { *libc::__errno_location() }
    }
}

#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // only `attempt`, which is Linux's, calls it
fn x32_getpid() -> i32 {
    libc::ENOSYS
}

/// `getpid` through `int 0x80` (i386 number 20): the filter kills it, a kernel without ia32 emulation says ENOSYS.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn i386_int80() -> i32 {
    let ret: i32;
    // SAFETY: int 0x80 with eax = 20 (getpid) takes no other register.
    unsafe {
        std::arch::asm!("int 0x80", inlateout("eax") 20i32 => ret, options(nostack));
    }
    if ret >= 0 { 0 } else { -ret }
}

#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // only `attempt`, which is Linux's, calls it
fn i386_int80() -> i32 {
    libc::ENOSYS
}
