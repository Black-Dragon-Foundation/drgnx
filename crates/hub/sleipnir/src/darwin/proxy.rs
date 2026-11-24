//! A Mac job's network: Gleipnir's CONNECT proxy (`gleipnir::net::proxy`) with the hub's allow-list ([`crate::net`]),
//! served by the job's own job-exec on a loopback port for the job's life (a Mac has no network namespace and no relay
//! sidecar). `serve` binds the port when it launches the attempt ([`bind`]), so the job's profile names it before
//! anything runs and no other process can take it in between; job-exec inherits the listener
//! ([`super::attempt::launch`]'s kept descriptor), closes it to the job ([`take`]) and serves it until the job ends.
//! The job's profile lets it reach `localhost` on that port only ([`super::sandbox`]), and its proxy variables name
//! it.
//!
//! The profile's `localhost` is both loopbacks, so the port on `::1` is held as well, from [`bind`] to the job's end:
//! no other process can listen there for the job to reach past the allow-list. [`bind`] keeps the `::1` listener it
//! found the port free with and job-exec inherits it too: never released in between, so no process that forks
//! meanwhile (and holds a copy until it execs) can make job-exec's hold fail.
//!
//! The port is on the Mac's loopback, which every local process shares: another process of the machine can reach
//! the allow-listed hosts through it while the job runs, and nothing else (no other host, no address that isn't
//! public).

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener};
use std::os::fd::{FromRawFd, RawFd};
use std::path::Path;
use std::sync::Arc;

use gleipnir::net::host::Target;
use gleipnir::net::proxy::{self, Listener, ProxyEvent, SystemResolver};

/// The hub's allow-list for the job, in its attempt folder.
pub const ALLOW: &str = "net.allow";

/// A job's proxy port as [`bind`] holds it: the listener on `127.0.0.1`, the one on `::1` (none on a Mac without an
/// IPv6 loopback), both kept for job-exec ([`take`]).
pub struct Port {
    pub v4: TcpListener,
    pub v6: Option<TcpListener>,
    pub port: u16,
}

/// A loopback port for a job's proxy, held on both loopbacks: a port already taken on `::1` is skipped.
pub fn bind() -> io::Result<Port> {
    bind_from(|| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)))
}

/// [`bind`] with V4 giving each `127.0.0.1` listener to try.
fn bind_from(mut v4: impl FnMut() -> io::Result<TcpListener>) -> io::Result<Port> {
    let mut last = None;
    for _ in 0..16 {
        let l = v4()?;
        let port = l.local_addr()?.port();
        match hold_v6(port) {
            Ok(v6) => return Ok(Port { v4: l, v6, port }),
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => last = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(last.unwrap_or_else(|| io::ErrorKind::AddrInUse.into()))
}

/// PORT on `::1`, listened on so nobody else can: none on a machine without an IPv6 loopback.
fn hold_v6(port: u16) -> io::Result<Option<TcpListener>> {
    match TcpListener::bind((Ipv6Addr::LOCALHOST, port)) {
        Ok(l) => Ok(Some(l)),
        Err(e) if e.kind() == io::ErrorKind::AddrNotAvailable => Ok(None),
        Err(e) => Err(e),
    }
}

/// A running proxy, on a runtime of its own; dropping it stops it.
pub struct Proxy {
    _handle: proxy::ProxyHandle,
    _runtime: saman::Executor,
    /// The port on `::1`, held (never accepted on) while the job runs.
    _v6: Option<TcpListener>,
}

/// Job-exec's side: the inherited descriptors FD and V6 (none: the Mac has no IPv6 loopback, [`bind`]), made
/// close-on-exec again (the job never gets them), which must be sockets on `127.0.0.1:PORT` and `[::1]:PORT`, and the
/// allow-list in DIR's [`ALLOW`]. Anything else is refused, naming it: the job then never runs (a setup failure), so it
/// never has a network its profile doesn't name.
pub fn take(fd: RawFd, v6: Option<RawFd>, port: u16, dir: &Path) -> villa::Result<Proxy> {
    let l = adopt(fd, IpAddr::V4(Ipv4Addr::LOCALHOST), port).map_err(villa::Error::refused)?;
    let v6 = v6
        .map(|fd| adopt(fd, IpAddr::V6(Ipv6Addr::LOCALHOST), port))
        .transpose()
        .map_err(villa::Error::refused)?;
    let f = dir.join(ALLOW);
    let text = crate::fsio::read_to_string(&f)
        .map_err(|e| villa::Error::io(format!("{}: {e}", f.display())).with_source(e))?;
    let mut p = serve(l, crate::net::allow_list(&text)?)?;
    p._v6 = v6;
    Ok(p)
}

/// The inherited descriptor FD, close-on-exec again, as the listener on ADDR:PORT it must be.
fn adopt(fd: RawFd, addr: IpAddr, port: u16) -> Result<TcpListener, String> {
    // SAFETY: fcntl on a descriptor number; one that isn't open fails, and nothing is taken
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(format!("its socket {fd}: {}", io::Error::last_os_error()));
    }
    // SAFETY: an open descriptor this process inherited for this use and nothing else holds
    let l = unsafe { TcpListener::from_raw_fd(fd) };
    let want = SocketAddr::new(addr, port);
    match l.local_addr() {
        Ok(a) if a == want => Ok(l),
        Ok(a) => Err(format!("its socket {fd} is {a}, not {want}")),
        Err(e) => Err(format!("its socket {fd}: {e}")),
    }
}

/// Serves the proxy for ALLOW on L, on a thread of its own; refusals are said on stderr (job-exec's log).
pub fn serve(l: TcpListener, allow: Vec<Target>) -> villa::Result<Proxy> {
    l.set_nonblocking(true)?;
    let runtime = saman::Executor::tuned(1, |b| {
        b.thread_name("job-proxy");
    })?;
    let handle = runtime.block_on(async {
        let l = tokio::net::TcpListener::from_std(l)?;
        let (tx, mut rx) = tokio::sync::mpsc::channel::<ProxyEvent>(64);
        let h = proxy::start(
            crate::net::proxy_config(allow),
            Arc::new(SystemResolver),
            tx,
        );
        h.listen(Listener::Tcp(l), 0);
        saman::spawn("job-proxy-events", async move {
            while let Some(e) = rx.recv().await {
                crate::eline!("sleipnir job-exec: the proxy refused {e:?}");
            }
        })
        .detach("it ends with the proxy's event channel");
        Ok::<_, io::Error>(h)
    })?;
    Ok(Proxy {
        _handle: handle,
        _runtime: runtime,
        _v6: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::{Read, Write};
    use std::os::fd::IntoRawFd;

    fn answer(port: u16, target: &str) -> String {
        let mut c = std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        write!(c, "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").unwrap();
        let mut out = String::new();
        c.read_to_string(&mut out).unwrap();
        out
    }

    /// P's descriptors as `attempt::launch` leaves them in job-exec: kept across exec.
    fn inherited(p: Port) -> (RawFd, Option<RawFd>, u16) {
        let keep = |l: TcpListener| {
            let fd = l.into_raw_fd();
            // SAFETY: our own descriptor
            assert_eq!(unsafe { libc::fcntl(fd, libc::F_SETFD, 0) }, 0);
            fd
        };
        (keep(p.v4), p.v6.map(keep), p.port)
    }

    /// A port's `127.0.0.1` descriptor alone, inherited (the `::1` listener closed).
    fn v4_only() -> (RawFd, u16) {
        let (fd, _, port) = inherited(Port {
            v6: None,
            ..bind().unwrap()
        });
        (fd, port)
    }

    fn cloexec(fd: RawFd) -> bool {
        // SAFETY: reading the flags of a descriptor
        unsafe { libc::fcntl(fd, libc::F_GETFD) & libc::FD_CLOEXEC != 0 }
    }

    /// [D] The proxy on a job's port refuses a host off the allow-list and an address that isn't public (no network
    /// is needed to show either).
    #[test]
    fn the_proxy_refuses_what_the_list_doesnt_hold() {
        let p = bind().unwrap();
        let _p = serve(p.v4, crate::net::allow_list("example.com:443\n").unwrap()).unwrap();
        for target in ["other.example:443", "example.com:80", "10.1.2.3:443"] {
            let a = answer(p.port, target);
            assert!(a.starts_with("HTTP/1.1 403"), "{target}: {a}");
        }
    }

    /// [D] Job-exec takes its inherited sockets only when they listen on the loopback port the profile names: they
    /// are close-on-exec after (the job never holds them), and the allow-list is read from the attempt folder;
    /// another port, a descriptor that isn't a socket, one not open, the loopbacks swapped, or a missing list is
    /// refused.
    #[test]
    fn job_exec_takes_only_its_loopback_socket() {
        let d = tempfile::tempdir().unwrap();
        crate::fsio::write(d.path().join(ALLOW), "example.com:443\n").unwrap();
        let (fd, v6, port) = inherited(bind().unwrap());
        let p = take(fd, v6, port, d.path()).unwrap();
        assert!(cloexec(fd));
        assert!(v6.is_none_or(cloexec));
        assert!(answer(port, "other.example:443").starts_with("HTTP/1.1 403"));
        drop(p);

        let (fd, port) = v4_only();
        let e = take(fd, None, port.wrapping_add(1).max(1), d.path())
            .err()
            .unwrap();
        assert!(e.message().contains("not 127.0.0.1:"), "{e}");

        let (fd, port) = v4_only();
        let (not_v6, _) = v4_only();
        let e = take(fd, Some(not_v6), port, d.path()).err().unwrap();
        assert!(e.message().contains(&format!("not [::1]:{port}")), "{e}");

        let file = fs::File::open(d.path().join(ALLOW)).unwrap().into_raw_fd();
        assert!(take(file, None, port, d.path()).is_err());
        assert!(take(1_000_000, None, port, d.path()).is_err());

        let (fd, v6, port) = inherited(bind().unwrap());
        let e = take(fd, v6, port, &d.path().join("none")).err().unwrap();
        assert!(e.message().contains(ALLOW), "{e}");
    }

    /// [D] The profile's `localhost` is both loopbacks, so the job's port on `::1` is held from [`bind`] to the
    /// job's end: nobody else can listen there for the job to reach, and there is no moment it is let go. A process
    /// forked in between (another job's launch: it holds copies of every descriptor until it execs) can't make
    /// job-exec's hold fail. A Mac without an IPv6 loopback has none to hold.
    #[test]
    fn the_jobs_port_on_the_ipv6_loopback_is_held_too() {
        // whether [::1]:PORT is listened on already; none without an IPv6 loopback
        let taken = |port: u16| match TcpListener::bind((Ipv6Addr::LOCALHOST, port)) {
            Ok(_) => Some(false),
            Err(e) if e.kind() == io::ErrorKind::AddrNotAvailable => None,
            Err(e) => Some(e.kind() == io::ErrorKind::AddrInUse),
        };
        let d = tempfile::tempdir().unwrap();
        crate::fsio::write(d.path().join(ALLOW), "example.com:443\n").unwrap();
        let b = bind().unwrap();
        let port = b.port;
        if taken(port).is_none() {
            crate::eline!("no IPv6 loopback here: nothing on ::1 to hold");
        }
        assert_ne!(taken(port), Some(false), "[::1]:{port} let go after bind");
        // SAFETY: the child only pauses (async-signal-safe) until it is killed
        let child = unsafe { libc::fork() };
        if child == 0 {
            loop {
                unsafe { libc::pause() };
            }
        }
        assert!(child > 0);
        let (fd, v6, port) = inherited(b);
        let p = take(fd, v6, port, d.path());
        // SAFETY: our own child
        unsafe {
            libc::kill(child, libc::SIGKILL);
            libc::waitpid(child, std::ptr::null_mut(), 0);
        }
        let p = p.unwrap();
        assert_ne!(
            taken(port),
            Some(false),
            "[::1]:{port} let go while the job runs"
        );
        drop(p);
    }

    /// [D] [`bind`] skips a port already taken on `::1` (where the job could reach another process's listener) and
    /// keeps nothing of it.
    #[test]
    fn bind_skips_a_port_already_taken_on_the_ipv6_loopback() {
        // a port taken on ::1 and free on 127.0.0.1
        let (_other, busy) = loop {
            let Ok(o) = TcpListener::bind((Ipv6Addr::LOCALHOST, 0)) else {
                crate::eline!("no IPv6 loopback here: no port to skip");
                return;
            };
            let port = o.local_addr().unwrap().port();
            if TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok() {
                break (o, port);
            }
        };
        let mut tries = 0;
        let p = bind_from(|| {
            tries += 1;
            TcpListener::bind((Ipv4Addr::LOCALHOST, if tries == 1 { busy } else { 0 }))
        })
        .unwrap();
        assert_eq!(tries, 2);
        assert_ne!(p.port, busy);
        assert!(TcpListener::bind((Ipv4Addr::LOCALHOST, busy)).is_ok());
    }
}
