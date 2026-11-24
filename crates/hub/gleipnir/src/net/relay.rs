//! The relay: loopback ports inside the sandbox forwarded to the session's Unix sockets (Task 11).
//!
//! Plain unix code (fds, Unix sockets, SIGTERM), so no `cfg(target_os)` gate: it builds on Linux, macOS and Android
//! (Android: built, never run - no sandbox backend there, so nothing starts it; fails closed upstream).

use std::ffi::OsString;
use std::io::{self, Write};
use std::net::Ipv4Addr;
use std::os::fd::{FromRawFd, OwnedFd};
use std::path::PathBuf;
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::signal::unix::{SignalKind, signal};

/// One forwarded port: connections to `127.0.0.1:port` go to the Unix socket at `socket`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayPair {
    pub port: u16,
    pub socket: PathBuf,
}

/// `"3128=/run/drgnx/proxy.sock"`: the port is 1-65535 and the path absolute.
pub fn parse_pair(s: &str) -> villa::Result<RelayPair> {
    let (port, socket) = s
        .split_once('=')
        .ok_or_else(|| villa::Error::invalid(format!("relay pair {s:?}: expected PORT=SOCKET")))?;
    let port: u16 = port.parse().ok().filter(|p| *p != 0).ok_or_else(|| {
        villa::Error::invalid(format!("relay pair {s:?}: the port must be 1-65535"))
    })?;
    let socket = PathBuf::from(socket);
    if !socket.is_absolute() {
        return Err(villa::Error::invalid(format!(
            "relay pair {s:?}: the socket path must be absolute"
        )));
    }
    Ok(RelayPair { port, socket })
}

/// Forwards one accepted connection to the socket; an unreachable socket closes only this connection.
async fn forward(tcp: TcpStream, socket: PathBuf) {
    match UnixStream::connect(&socket).await {
        // Errors mid-stream (a peer reset) end this connection only; there is nothing to report.
        Ok(unix) => splice(tcp, unix).await,
        Err(e) => crate::say(&format!(
            "gleipnir relay: cannot reach {}: {e}",
            socket.display()
        )),
    }
}

/// A copy or a shutdown that ended with an error: a peer's reset ends its own connection and nothing else, so it is only logged.
fn peer_gone<T>(ended: io::Result<T>, what: &str) {
    if let Err(e) = ended {
        tracing::debug!(error = %e, what, "a relayed connection ended with an error");
    }
}

/// Both directions on their own: one that ends or fails never cuts the other short, so what the socket's side sent
/// before it went (the proxy's 403 to a client still sending, GLP-T10-3) still reaches the client. Once the socket's
/// side takes no more, what the client still sends is read and dropped: its connection then ends with nothing unread,
/// where a close with unread data would reset it and the client could lose the answer.
async fn splice(tcp: TcpStream, unix: UnixStream) {
    use tokio::io::AsyncWriteExt;
    let (mut tr, mut tw) = tcp.into_split();
    let (mut ur, mut uw) = unix.into_split();
    let up = async {
        if tokio::io::copy(&mut tr, &mut uw).await.is_ok() {
            peer_gone(uw.shutdown().await, "shutdown toward the socket");
        } else {
            peer_gone(
                tokio::io::copy(&mut tr, &mut tokio::io::sink()).await,
                "drain of the client",
            );
        }
    };
    let down = async {
        peer_gone(
            tokio::io::copy(&mut ur, &mut tw).await,
            "copy to the client",
        );
        peer_gone(tw.shutdown().await, "shutdown toward the client");
    };
    tokio::join!(up, down);
}

async fn accept_loop(listener: TcpListener, socket: PathBuf) {
    loop {
        match listener.accept().await {
            Ok((tcp, _)) => {
                saman::spawn("relay-forward", forward(tcp, socket.clone()))
                    .detach("a connection lives until one of its two ends closes");
            }
            Err(e) => {
                // EMFILE and friends: back off instead of spinning.
                crate::say(&format!("gleipnir relay: accept: {e}"));
                stund::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// Binds every pair, writes `ready\n` to `ready`, then forwards for ever. Fails (with `ready` closed unwritten)
/// when a port cannot be bound. The listen backlog is tokio's default (1024).
pub async fn run(pairs: Vec<RelayPair>, ready: Option<OwnedFd>) -> io::Result<()> {
    let mut listeners = Vec::with_capacity(pairs.len());
    for p in pairs {
        let l = TcpListener::bind((Ipv4Addr::LOCALHOST, p.port)).await?;
        listeners.push((l, p.socket));
    }
    if let Some(fd) = ready {
        let mut f = std::fs::File::from(fd);
        f.write_all(b"ready\n")?;
    }
    let mut set = tokio::task::JoinSet::new();
    for (l, socket) in listeners {
        set.spawn(accept_loop(l, socket));
    }
    // The accept loops never end; if one is lost to a panic, the relay is no longer whole.
    match set.join_next().await {
        Some(Err(e)) => Err(io::Error::other(e)),
        _ => Ok(()),
    }
}

/// Resolves when the parent process changes (the sandbox's init went away).
async fn parent_gone(initial: Option<rustix::process::Pid>) {
    loop {
        stund::sleep(Duration::from_secs(1)).await;
        if rustix::process::getppid() != initial {
            return;
        }
    }
}

/// The option that names the relay's expected parent; the inner helper appends it, with its own pid, last.
pub const PARENT_PID_ARG: &str = "--parent-pid";

const USAGE: &str = "usage: relay --parent-pid PID [--ready-fd N] PORT=SOCKET...";

struct Args {
    parent: rustix::process::Pid,
    ready: Option<OwnedFd>,
    pairs: Vec<RelayPair>,
}

/// The options may come anywhere among the pairs (the helper appends `--parent-pid` after them).
fn parse_args(args: impl Iterator<Item = OsString>) -> Result<Args, String> {
    let mut args = args;
    let mut ready = None;
    let mut parent = None;
    let mut pairs = Vec::new();
    while let Some(a) = args.next() {
        if a == "--ready-fd" {
            let n: i32 = args
                .next()
                .and_then(|v| v.to_str().and_then(|v| v.parse().ok()))
                .filter(|n| *n >= 0)
                .ok_or("--ready-fd needs a file descriptor number")?;
            // The caller passed this fd for us to own; nothing else in this process holds it.
            ready = Some(unsafe { OwnedFd::from_raw_fd(n) });
        } else if a == PARENT_PID_ARG {
            let pid = args
                .next()
                .and_then(|v| v.to_str().and_then(|v| v.parse::<i32>().ok()))
                .and_then(rustix::process::Pid::from_raw)
                .ok_or("--parent-pid needs a pid above 0")?;
            parent = Some(pid);
        } else {
            let s = a.to_str().ok_or("relay pair is not UTF-8")?;
            pairs.push(parse_pair(s).map_err(|e| e.to_string())?);
        }
    }
    match parent {
        Some(parent) if !pairs.is_empty() => Ok(Args {
            parent,
            ready,
            pairs,
        }),
        _ => Err(USAGE.into()),
    }
}

/// Ask for SIGTERM when the parent thread exits (Linux and Android), then check that the parent is `expected`. In
/// that order, a parent that dies after the check is caught by the signal, and one that died before it by the check.
fn adopt_parent(expected: rustix::process::Pid) -> Result<(), String> {
    // A Linux prctl (Android: the same kernel). Elsewhere (macOS) only the check and the poll below.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    rustix::process::set_parent_process_death_signal(Some(rustix::process::Signal::TERM))
        .map_err(|e| format!("PR_SET_PDEATHSIG: {e}"))?;
    match rustix::process::getppid() {
        Some(p) if p == expected => Ok(()),
        got => Err(format!(
            "the parent is {}, not {}: it has gone",
            got.map_or(0, |p| p.as_raw_nonzero().get()),
            expected.as_raw_nonzero()
        )),
    }
}

/// `--parent-pid PID [--ready-fd N] PAIR...`; returns the exit code: 0 when the parent changes or on SIGTERM, 1 on
/// a runtime failure (a port cannot be bound, the parent is not PID), 2 on bad arguments.
pub fn main(args: impl Iterator<Item = OsString>) -> i32 {
    let Args {
        parent,
        ready,
        pairs,
    } = match parse_args(args) {
        Ok(v) => v,
        Err(e) => {
            crate::say(&format!("gleipnir relay: {e}"));
            return 2;
        }
    };
    if let Err(e) = adopt_parent(parent) {
        crate::say(&format!("gleipnir relay: {e}"));
        return 1;
    }
    let initial = Some(parent);
    let pool = match saman::Executor::new(1) {
        Ok(pool) => pool,
        Err(e) => {
            crate::say(&format!("gleipnir relay: runtime: {e}"));
            return 1;
        }
    };
    pool.block_on(async {
        let Ok(mut term) = signal(SignalKind::terminate()) else {
            crate::say("gleipnir relay: cannot watch SIGTERM");
            return 1;
        };
        tokio::select! {
            r = run(pairs, ready) => match r {
                Ok(()) => 0,
                Err(e) => {
                    crate::say(&format!("gleipnir relay: {e}"));
                    1
                }
            },
            () = parent_gone(initial) => 0,
            _ = term.recv() => 0,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::OwnedFd;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpStream, UnixListener};

    fn free_port() -> u16 {
        std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    }

    /// An echo server: every byte read comes back; half-close is passed on.
    fn echo_server(path: &std::path::Path) {
        let l = UnixListener::bind(path).unwrap();
        saman::spawn("echo-accept", async move {
            loop {
                let Ok((mut s, _)) = l.accept().await else {
                    return;
                };
                saman::spawn("echo", async move {
                    let (mut r, mut w) = s.split();
                    peer_gone(tokio::io::copy(&mut r, &mut w).await, "echo copy");
                    peer_gone(w.shutdown().await, "echo shutdown");
                })
                .detach("an echo lives until its client closes");
            }
        })
        .detach("the echo server lives until the test's runtime ends");
    }

    fn pattern(n: usize, seed: u8) -> Vec<u8> {
        (0..n)
            .map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed))
            .collect()
    }

    /// Starts the relay in-process on `n` free ports (`make` turns them into its pairs), waits for `ready`, returns the
    /// ports' task and the ports. Other tests of this process bind and connect on loopback too and can take a port
    /// between `free_port` and the relay's bind (ci/ci-gate: about 1 run in 13 locally); the relay then fails with
    /// AddrInUse and no ready line, and fresh ports are asked for. Any other failure fails the test.
    async fn start(
        n: usize,
        make: impl Fn(&[u16]) -> Vec<RelayPair>,
    ) -> (saman::Task<io::Result<()>>, Vec<u16>) {
        for _ in 0..5 {
            let ports: Vec<u16> = (0..n).map(|_| free_port()).collect();
            let (mut r, w) = std::io::pipe().unwrap();
            let h = saman::spawn("relay", run(make(&ports), Some(OwnedFd::from(w))));
            let line = saman::spawn_blocking("read-ready", move || {
                let mut s = String::new();
                r.read_to_string(&mut s).unwrap();
                s
            })
            .await
            .unwrap();
            if line == "ready\n" {
                return (h, ports);
            }
            let res = h.await.unwrap();
            assert!(
                matches!(&res, Err(e) if e.kind() == io::ErrorKind::AddrInUse),
                "no ready line: {line:?}, {res:?}"
            );
        }
        panic!("5 sets of free ports were all taken before the relay bound them");
    }

    #[test]
    fn parse_pair_rules() {
        assert_eq!(
            parse_pair("3128=/run/drgnx/proxy.sock").unwrap(),
            RelayPair {
                port: 3128,
                socket: "/run/drgnx/proxy.sock".into()
            }
        );
        for bad in [
            "0=/a",
            "65536=/a",
            "x=/a",
            "3128",
            "3128=",
            "3128=rel/a",
            "=/a",
            "-1=/a",
        ] {
            assert!(parse_pair(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn bytes_both_ways() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let sock = dir.path().join("e.sock");
            echo_server(&sock);
            let (h, ports) = start(1, |p| {
                vec![RelayPair {
                    port: p[0],
                    socket: sock.clone(),
                }]
            })
            .await;
            let port = ports[0];
            let up = pattern(1 << 20, 1);
            let mut c = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
            let (mut r, mut w) = c.split();
            let send = async {
                w.write_all(&up).await.unwrap();
                w.shutdown().await.unwrap();
            };
            let mut got = Vec::new();
            let recv = r.read_to_end(&mut got);
            let (_, n) = tokio::join!(send, recv);
            assert_eq!(n.unwrap(), up.len());
            assert_eq!(got, up);
            drop(h);
        });
    }

    #[test]
    fn ready_only_after_every_listener() {
        saman::block_on_current(async {
            // The second port is taken: run fails, and `ready` is closed without a byte.
            let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let busy = taken.local_addr().unwrap().port();
            let (mut r, w) = std::io::pipe().unwrap();
            let res = run(
                vec![
                    RelayPair {
                        port: free_port(),
                        socket: "/nonexistent/a".into(),
                    },
                    RelayPair {
                        port: busy,
                        socket: "/nonexistent/b".into(),
                    },
                ],
                Some(OwnedFd::from(w)),
            )
            .await;
            assert!(res.is_err());
            let mut s = String::new();
            r.read_to_string(&mut s).unwrap();
            assert_eq!(s, "", "no ready line when a listener failed");
            // And on success the listeners are already accepting when `ready` arrives.
            let dir = tempfile::tempdir().unwrap();
            let sock = dir.path().join("e.sock");
            echo_server(&sock);
            let (h, ports) = start(1, |p| {
                vec![RelayPair {
                    port: p[0],
                    socket: sock.clone(),
                }]
            })
            .await;
            let mut c = TcpStream::connect(("127.0.0.1", ports[0])).await.unwrap();
            c.write_all(b"hi").await.unwrap();
            let mut b = [0u8; 2];
            c.read_exact(&mut b).await.unwrap();
            assert_eq!(&b, b"hi");
            drop(h);
        });
    }

    #[test]
    fn hundred_connections() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let sock = dir.path().join("e.sock");
            echo_server(&sock);
            let (h, ports) = start(1, |p| {
                vec![RelayPair {
                    port: p[0],
                    socket: sock.clone(),
                }]
            })
            .await;
            let port = ports[0];
            let mut set = tokio::task::JoinSet::new();
            for i in 0..100u8 {
                set.spawn(async move {
                    let mut c = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
                    let msg = pattern(4096, i);
                    c.write_all(&msg).await.unwrap();
                    let mut got = vec![0u8; msg.len()];
                    c.read_exact(&mut got).await.unwrap();
                    assert_eq!(got, msg);
                });
            }
            while let Some(r) = set.join_next().await {
                r.unwrap();
            }
            drop(h);
        });
    }

    #[test]
    fn unreachable_socket_closes_only_that_connection() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let good = dir.path().join("good.sock");
            echo_server(&good);
            let (h, ports) = start(2, |p| {
                vec![
                    RelayPair {
                        port: p[0],
                        socket: dir.path().join("missing.sock"),
                    },
                    RelayPair {
                        port: p[1],
                        socket: good.clone(),
                    },
                ]
            })
            .await;
            let (bad_port, good_port) = (ports[0], ports[1]);
            let mut c = TcpStream::connect(("127.0.0.1", bad_port)).await.unwrap();
            let mut buf = Vec::new();
            let n = tokio::time::timeout(Duration::from_secs(5), c.read_to_end(&mut buf))
                .await
                .expect("closed, not hung");
            assert!(n.is_err() || n.unwrap() == 0);
            // The listener and the other pair live on.
            for port in [bad_port, good_port] {
                let mut c = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
                peer_gone(c.write_all(b"x").await, "a probe write");
            }
            let mut c = TcpStream::connect(("127.0.0.1", good_port)).await.unwrap();
            c.write_all(b"ok").await.unwrap();
            let mut b = [0u8; 2];
            c.read_exact(&mut b).await.unwrap();
            assert_eq!(&b, b"ok");
            assert!(!h.is_finished());
            drop(h);
        });
    }

    #[test]
    fn half_close_preserved() {
        saman::block_on_current(async {
            // The server answers only after it saw EOF from the client; the client must still be able to read.
            let dir = tempfile::tempdir().unwrap();
            let sock = dir.path().join("h.sock");
            let l = UnixListener::bind(&sock).unwrap();
            saman::spawn("half-close-server", async move {
                let (mut s, _) = l.accept().await.unwrap();
                let mut all = Vec::new();
                s.read_to_end(&mut all).await.unwrap();
                s.write_all(format!("saw {}", all.len()).as_bytes())
                    .await
                    .unwrap();
            })
            .detach("the server lives until the test's runtime ends");
            let (h, ports) = start(1, |p| {
                vec![RelayPair {
                    port: p[0],
                    socket: sock.clone(),
                }]
            })
            .await;
            let mut c = TcpStream::connect(("127.0.0.1", ports[0])).await.unwrap();
            c.write_all(&[7u8; 1000]).await.unwrap();
            c.shutdown().await.unwrap();
            let mut reply = String::new();
            c.read_to_string(&mut reply).await.unwrap();
            assert_eq!(reply, "saw 1000");
            drop(h);
        });
    }

    /// The socket's side answers and goes while the client is still sending (the proxy's 403 to a flooding client,
    /// GLP-T10-3): the answer still reaches the client, and the client's connection is never reset under it. The order
    /// is forced: the answer and the close both land while the relay cannot run (the test holds its runtime's only
    /// thread), so its next poll sees them at once, with most of the client's 32 MiB still to come.
    #[test]
    fn an_answer_sent_before_the_socket_went_reaches_a_client_still_sending() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let sock = dir.path().join("p.sock");
            let ul = std::os::unix::net::UnixListener::bind(&sock).unwrap();
            let tl = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = tl.local_addr().unwrap();
            // the client: its head, then 32 MiB without reading (more than both sockets' buffers), then its answer
            let client = saman::spawn_thread("flooding-client", move || {
                let mut c = std::net::TcpStream::connect(addr).unwrap();
                c.write_all(b"HEAD\n").unwrap();
                let sent = c.write_all(&vec![b'x'; 32 << 20]).map_err(|e| e.kind());
                let mut got = Vec::new();
                // a reset here is what the test's assertion on `got` reports
                peer_gone(c.read_to_end(&mut got), "the client's read");
                (sent, got)
            })
            .unwrap();
            let (tcp, _) = tl.accept().unwrap();
            tcp.set_nonblocking(true).unwrap();
            let tcp = TcpStream::from_std(tcp).unwrap();
            let unix = UnixStream::connect(&sock).await.unwrap();
            let (mut server, _) = ul.accept().unwrap();
            let (head_tx, head_rx) = tokio::sync::oneshot::channel();
            let (go_tx, go_rx) = std::sync::mpsc::channel::<()>();
            let (gone_tx, gone_rx) = std::sync::mpsc::channel::<()>();
            let srv = saman::spawn_thread("closing-server", move || {
                let mut head = [0u8; 5];
                server.read_exact(&mut head).unwrap();
                head_tx.send(()).unwrap();
                go_rx.recv().unwrap();
                server.write_all(b"403\n").unwrap();
                // closed with the flood unread
                drop(server);
                gone_tx.send(()).unwrap();
            })
            .unwrap();
            let relay = saman::spawn("splice", splice(tcp, unix));
            head_rx.await.unwrap();
            // this thread is the relay's: held here, it runs again only after the answer and the close
            go_tx.send(()).unwrap();
            gone_rx.recv().unwrap();
            relay.await.unwrap();
            srv.join().unwrap();
            // the client's flood was read to its end (a relay that closed with it unread resets the connection, and a reset
            // can take the answer with it), and the answer arrived
            let (sent, got) = client.join().unwrap();
            assert_eq!(sent, Ok(()), "the client's connection was reset");
            assert_eq!(got, b"403\n");
        });
    }

    /// Not a test of its own: the entry the parent test re-executes this binary into.
    #[test]
    fn child_entry() {
        let Some(args) = std::env::var_os("GLEIPNIR_RELAY_CHILD") else {
            return;
        };
        let args: Vec<OsString> = args
            .to_string_lossy()
            .split_whitespace()
            .map(OsString::from)
            .collect();
        std::process::exit(main(args.into_iter()));
    }

    /// Gleipnir T11-1: a relay whose parent is not the one it was told (that parent died before the relay ran, and it
    /// was reparented) refuses to start: exit 1, no port bound, the ready pipe closed unwritten. Without the option
    /// it does not start either.
    #[test]
    fn refuses_a_parent_it_was_not_given() {
        let exe = std::env::current_exe().unwrap();
        let port = free_port();
        let pair = format!("{port}=/nonexistent/s.sock");
        let run = |args: String| {
            draugr::run(
                draugr::Spec {
                    program: exe.clone(),
                    args: ["--exact", "net::relay::tests::child_entry", "--nocapture"]
                        .map(OsString::from)
                        .into_iter()
                        .chain([OsString::from("--test-threads=1")])
                        .collect(),
                    env: draugr::env::build(
                        &["PATH", "TMPDIR", "RUST_BACKTRACE"],
                        &[],
                        &[("GLEIPNIR_RELAY_CHILD", std::ffi::OsStr::new(&args))],
                    ),
                    cwd: None,
                    stdin_null: true,
                    pass_fds: Vec::new(),
                    new_session: false,
                },
                Duration::from_secs(60),
            )
            .unwrap()
        };
        // The child's parent is this process; ours is someone else.
        let out = run(format!(
            "{pair} --parent-pid {}",
            std::os::unix::process::parent_id()
        ));
        assert_eq!(out.status.code(), Some(1), "{}", out.stderr);
        // "it has gone" is `adopt_parent`'s refusal, which `main` returns before it binds anything. (No connect to the
        // port here: the child has exited, so nothing it bound could still listen, and another test of this process
        // may hold that free port: ci/ci-gate, 1 of 60 local runs.)
        assert!(out.stderr.contains("it has gone"));
        let out = run(pair);
        assert_eq!(out.status.code(), Some(2), "no --parent-pid: usage");
        let parse = |a: &[&str]| parse_args(a.iter().map(OsString::from)).map(|a| a.pairs.len());
        assert_eq!(parse(&["--parent-pid", "5", "1=/a"]), Ok(1), "the control");
        assert!(parse(&["--parent-pid", "0", "1=/a"]).is_err());
        assert!(parse(&["--parent-pid", "5"]).is_err(), "no pair");
        assert!(
            parse(&["--ready-fd", "-1", "--parent-pid", "5", "1=/a"]).is_err(),
            "a negative fd is refused"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android"))] // only the /proc liveness probe below uses it
    fn state_of(pid: u32) -> Option<char> {
        let s =
            eitri::read_string(std::path::Path::new(&format!("/proc/{pid}/stat")), 1 << 16).ok()?;
        s.rsplit(')').next()?.trim().chars().next()
    }

    #[test]
    #[cfg(any(target_os = "linux", target_os = "android"))] // /proc; macOS CI skips the liveness probe
    fn ends_when_the_parent_goes() {
        use tokio::io::AsyncBufReadExt;
        let dir = tempfile::tempdir().unwrap();
        let port = free_port();
        let exe = std::env::current_exe().unwrap();
        // the shell's stdout and the relay's are read on a pool of two while this thread waits on the kernel
        let pool = saman::Executor::new(2).unwrap();
        // The shell is the relay's parent and stays alive while we hold its stdin.
        let mut sh = pool
            .block_on(draugr::spawn(draugr::Spec {
                program: "sh".into(),
                args: vec![
                    "-c".into(),
                    // fd 3 is the shell's stdout for the relay: it says `ready` there once its port is bound
                    r#"GLEIPNIR_RELAY_CHILD="$1 --parent-pid $$ --ready-fd 3" "$0" --exact net::relay::tests::child_entry --nocapture --test-threads=1 </dev/null 3>&1 >/dev/null 2>&1 &
echo $!; read x"#
                        .into(),
                    exe.into_os_string(),
                    format!("{port}={}", dir.path().join("s.sock").display()).into(),
                ],
                env: draugr::env::build(&["PATH", "TMPDIR", "RUST_BACKTRACE"], &[], &[]),
                cwd: None,
                stdin_null: false,
                pass_fds: Vec::new(),
                new_session: false,
            }))
            .unwrap();
        // GLEIPNIR_RELAY_CHILD: the pair, then the shell's own pid as the expected parent.
        // The shell says its relay's pid (`echo $!`); the relay says `ready` on the same pipe once its port is bound.
        // Both lines are read, in whichever order they came.
        let mut lines = tokio::io::BufReader::new(sh.take_stdout().unwrap()).lines();
        let pid = pool.block_on(async {
            let (mut pid, mut ready) = (None, false);
            while pid.is_none() || !ready {
                let line = lines.next_line().await.unwrap().unwrap_or_else(|| {
                    panic!("the shell or the relay ended before it was ready (pid {pid:?})")
                });
                match line.trim() {
                    "ready" => ready = true,
                    n => pid = Some(n.parse::<u32>().unwrap()),
                }
            }
            pid.unwrap()
        });
        // A handle on the relay's exit, taken while it is certainly there (its parent lives).
        // SAFETY: pidfd_open(2) with plain integers; the result is a new descriptor of ours.
        let pidfd = unsafe {
            let fd = libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0);
            assert!(fd >= 0, "pidfd_open: {}", std::io::Error::last_os_error());
            std::os::fd::OwnedFd::from_raw_fd(fd as i32)
        };
        let alive = |pid: u32| matches!(state_of(pid), Some(c) if c != 'Z' && c != 'X');
        assert!(alive(pid), "relay up while the parent lives");
        // The one wait that is a window, not an event: nothing must happen. The relay looks at its parent once a
        // second (`parent_gone`), so a window of a poll and a half covers a check that would wrongly end it.
        const A_POLL_AND_A_HALF: Duration = Duration::from_millis(1500);
        skuld::window(A_POLL_AND_A_HALF, "the relay ends while its parent lives");
        assert!(alive(pid), "still up after a poll while the parent lives");
        // The parent goes.
        let mut stdin = sh.take_stdin().unwrap();
        pool.block_on(tokio::io::AsyncWriteExt::write_all(&mut stdin, b"\n"))
            .unwrap();
        drop(stdin);
        pool.block_on(sh.wait_deadline(Duration::from_secs(30)))
            .unwrap();
        // The relay's exit is what the descriptor reports; 30 s only bounds a failure.
        let mut p = libc::pollfd {
            fd: std::os::fd::AsRawFd::as_raw_fd(&pidfd),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll(2) on one valid pollfd.
        let gone = unsafe { libc::poll(&mut p, 1, 30_000) } == 1;
        if !gone
            && let Err(e) = rustix::process::kill_process(
                rustix::process::Pid::from_raw(pid as i32).unwrap(),
                rustix::process::Signal::KILL,
            )
        {
            tracing::debug!(error = %e, "the relay was already gone");
        }
        assert!(gone, "the relay exits when its parent does");
        assert!(!alive(pid));
    }
}
