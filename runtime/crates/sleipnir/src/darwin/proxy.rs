//! A Mac job's network: Gleipnir's CONNECT proxy (`gleipnir::net::proxy`) with the hub's allow-list ([`crate::net`]),
//! served by the job's own job-exec on a loopback port for the job's life (a Mac has no network namespace and no relay
//! sidecar). `serve` binds the port when it launches the attempt ([`bind`]), so the job's profile names it before
//! anything runs and no other process can take it in between; job-exec inherits the listener
//! ([`super::attempt::launch`]'s kept descriptor), closes it to the job ([`take`]) and serves it until the job ends.
//! The job's profile lets it reach `localhost` on that port only ([`super::sandbox`]), and its proxy variables name
//! it.
//!
//! The port is on the Mac's loopback, which every local process shares: another process of the machine can reach
//! the allow-listed hosts through it while the job runs, and nothing else (no other host, no address that isn't
//! public).

use std::fs;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener};
use std::os::fd::{FromRawFd, RawFd};
use std::path::Path;
use std::sync::Arc;

use gleipnir::net::host::Target;
use gleipnir::net::proxy::{self, Listener, ProxyEvent, SystemResolver};

/// The hub's allow-list for the job, in its attempt folder.
pub const ALLOW: &str = "net.allow";

/// A loopback port for a job's proxy: the listener and its port.
pub fn bind() -> io::Result<(TcpListener, u16)> {
    let l = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    let port = l.local_addr()?.port();
    Ok((l, port))
}

/// A running proxy, on a runtime of its own; dropping it stops it.
pub struct Proxy {
    _handle: proxy::ProxyHandle,
    _runtime: tokio::runtime::Runtime,
}

/// Job-exec's side: the inherited descriptor FD, made close-on-exec again (the job never gets it), which must be a
/// socket listening on `127.0.0.1:PORT`, and the allow-list in DIR's [`ALLOW`]. Anything else is refused, naming
/// it: the job then never runs (a setup failure), so it never has a network its profile doesn't name.
pub fn take(fd: RawFd, port: u16, dir: &Path) -> Result<Proxy, String> {
    // SAFETY: fcntl on a descriptor number; one that isn't open fails, and nothing is taken
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(format!("its socket {fd}: {}", io::Error::last_os_error()));
    }
    // SAFETY: an open descriptor this process inherited for this use and nothing else holds
    let l = unsafe { TcpListener::from_raw_fd(fd) };
    let want = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    match l.local_addr() {
        Ok(a) if a == want => {}
        Ok(a) => return Err(format!("its socket {fd} is {a}, not {want}")),
        Err(e) => return Err(format!("its socket {fd}: {e}")),
    }
    let f = dir.join(ALLOW);
    let text = fs::read_to_string(&f).map_err(|e| format!("{}: {e}", f.display()))?;
    serve(l, crate::net::allow_list(&text)?)
}

/// Serves the proxy for ALLOW on L, on a thread of its own; refusals are said on stderr (job-exec's log).
pub fn serve(l: TcpListener, allow: Vec<Target>) -> Result<Proxy, String> {
    l.set_nonblocking(true).map_err(|e| e.to_string())?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("job-proxy")
        .enable_all()
        .build()
        .map_err(|e| format!("its runtime: {e}"))?;
    let handle = {
        let _in = runtime.enter();
        let l = tokio::net::TcpListener::from_std(l).map_err(|e| e.to_string())?;
        let (tx, mut rx) = tokio::sync::mpsc::channel::<ProxyEvent>(64);
        let h = proxy::start(
            crate::net::proxy_config(allow),
            Arc::new(SystemResolver),
            tx,
        );
        h.listen(Listener::Tcp(l), 0);
        tokio::spawn(async move {
            while let Some(e) = rx.recv().await {
                eprintln!("sleipnir job-exec: the proxy refused {e:?}");
            }
        });
        h
    };
    Ok(Proxy {
        _handle: handle,
        _runtime: runtime,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::IntoRawFd;

    fn answer(port: u16, target: &str) -> String {
        let mut c = std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        write!(c, "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").unwrap();
        let mut out = String::new();
        c.read_to_string(&mut out).unwrap();
        out
    }

    /// [D] The proxy on a job's port refuses a host off the allow-list and an address that isn't public (no network
    /// is needed to show either).
    #[test]
    fn the_proxy_refuses_what_the_list_doesnt_hold() {
        let (l, port) = bind().unwrap();
        let _p = serve(l, crate::net::allow_list("example.com:443\n").unwrap()).unwrap();
        for target in ["other.example:443", "example.com:80", "10.1.2.3:443"] {
            let a = answer(port, target);
            assert!(a.starts_with("HTTP/1.1 403"), "{target}: {a}");
        }
    }

    /// [D] Job-exec takes its inherited socket only when it listens on the loopback port the profile names: it is
    /// close-on-exec after (the job never holds it), and the allow-list is read from the attempt folder; another
    /// port, a descriptor that isn't a socket, one not open, or a missing list is refused.
    #[test]
    fn job_exec_takes_only_its_loopback_socket() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join(ALLOW), "example.com:443\n").unwrap();
        let inherited = |port: &mut u16| {
            let (l, p) = bind().unwrap();
            *port = p;
            let fd = l.into_raw_fd();
            // SAFETY: our own descriptor, as attempt::launch leaves it in job-exec
            assert_eq!(unsafe { libc::fcntl(fd, libc::F_SETFD, 0) }, 0);
            fd
        };
        let mut port = 0;
        let fd = inherited(&mut port);
        let p = take(fd, port, d.path()).unwrap();
        // SAFETY: reading the flags of a descriptor the proxy holds open
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        assert!(answer(port, "other.example:443").starts_with("HTTP/1.1 403"));
        drop(p);

        let fd = inherited(&mut port);
        let e = take(fd, port.wrapping_add(1).max(1), d.path())
            .err()
            .unwrap();
        assert!(e.contains("not 127.0.0.1:"), "{e}");

        let file = fs::File::open(d.path().join(ALLOW)).unwrap().into_raw_fd();
        assert!(take(file, port, d.path()).is_err());
        assert!(take(1_000_000, port, d.path()).is_err());

        let fd = inherited(&mut port);
        let e = take(fd, port, &d.path().join("none")).err().unwrap();
        assert!(e.contains(ALLOW), "{e}");
    }
}
