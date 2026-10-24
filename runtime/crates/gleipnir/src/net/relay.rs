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
pub fn parse_pair(s: &str) -> Result<RelayPair, String> {
    let (port, socket) = s
        .split_once('=')
        .ok_or_else(|| format!("relay pair {s:?}: expected PORT=SOCKET"))?;
    let port: u16 = port
        .parse()
        .ok()
        .filter(|p| *p != 0)
        .ok_or_else(|| format!("relay pair {s:?}: the port must be 1-65535"))?;
    let socket = PathBuf::from(socket);
    if !socket.is_absolute() {
        return Err(format!(
            "relay pair {s:?}: the socket path must be absolute"
        ));
    }
    Ok(RelayPair { port, socket })
}

/// Forwards one accepted connection to the socket; an unreachable socket closes only this connection.
async fn forward(mut tcp: TcpStream, socket: PathBuf) {
    match UnixStream::connect(&socket).await {
        // Errors mid-stream (a peer reset) end this connection only; there is nothing to report.
        Ok(mut unix) => {
            let _ = tokio::io::copy_bidirectional(&mut tcp, &mut unix).await;
        }
        Err(e) => eprintln!("gleipnir relay: cannot reach {}: {e}", socket.display()),
    }
}

async fn accept_loop(listener: TcpListener, socket: PathBuf) {
    loop {
        match listener.accept().await {
            Ok((tcp, _)) => {
                tokio::spawn(forward(tcp, socket.clone()));
            }
            Err(e) => {
                // EMFILE and friends: back off instead of spinning.
                eprintln!("gleipnir relay: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
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
        tokio::time::sleep(Duration::from_secs(1)).await;
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
            pairs.push(parse_pair(s)?);
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
            eprintln!("gleipnir relay: {e}");
            return 2;
        }
    };
    if let Err(e) = adopt_parent(parent) {
        eprintln!("gleipnir relay: {e}");
        return 1;
    }
    let initial = Some(parent);
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("gleipnir relay: runtime: {e}");
            return 1;
        }
    };
    rt.block_on(async {
        let Ok(mut term) = signal(SignalKind::terminate()) else {
            eprintln!("gleipnir relay: cannot watch SIGTERM");
            return 1;
        };
        tokio::select! {
            r = run(pairs, ready) => match r {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("gleipnir relay: {e}");
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
        tokio::spawn(async move {
            loop {
                let Ok((mut s, _)) = l.accept().await else {
                    return;
                };
                tokio::spawn(async move {
                    let (mut r, mut w) = s.split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                    let _ = w.shutdown().await;
                });
            }
        });
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
    ) -> (tokio::task::JoinHandle<io::Result<()>>, Vec<u16>) {
        for _ in 0..5 {
            let ports: Vec<u16> = (0..n).map(|_| free_port()).collect();
            let (mut r, w) = std::io::pipe().unwrap();
            let h = tokio::spawn(run(make(&ports), Some(OwnedFd::from(w))));
            let line = tokio::task::spawn_blocking(move || {
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

    #[tokio::test]
    async fn bytes_both_ways() {
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
        h.abort();
    }

    #[tokio::test]
    async fn ready_only_after_every_listener() {
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
        h.abort();
    }

    #[tokio::test]
    async fn hundred_connections() {
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
        h.abort();
    }

    #[tokio::test]
    async fn unreachable_socket_closes_only_that_connection() {
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
            let _ = c.write_all(b"x").await;
        }
        let mut c = TcpStream::connect(("127.0.0.1", good_port)).await.unwrap();
        c.write_all(b"ok").await.unwrap();
        let mut b = [0u8; 2];
        c.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"ok");
        assert!(!h.is_finished());
        h.abort();
    }

    #[tokio::test]
    async fn half_close_preserved() {
        // The server answers only after it saw EOF from the client; the client must still be able to read.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("h.sock");
        let l = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            let mut all = Vec::new();
            s.read_to_end(&mut all).await.unwrap();
            s.write_all(format!("saw {}", all.len()).as_bytes())
                .await
                .unwrap();
        });
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
        h.abort();
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
        use std::process::Command;
        let exe = std::env::current_exe().unwrap();
        let port = free_port();
        let pair = format!("{port}=/nonexistent/s.sock");
        let run = |args: String| {
            Command::new(&exe)
                .args(["--exact", "net::relay::tests::child_entry", "--nocapture"])
                .arg("--test-threads=1")
                .env("GLEIPNIR_RELAY_CHILD", args)
                .output()
                .unwrap()
        };
        // The child's parent is this process; ours is someone else.
        let out = run(format!(
            "{pair} --parent-pid {}",
            std::os::unix::process::parent_id()
        ));
        assert_eq!(
            out.status.code(),
            Some(1),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        // "it has gone" is `adopt_parent`'s refusal, which `main` returns before it binds anything. (No connect to the
        // port here: the child has exited, so nothing it bound could still listen, and another test of this process
        // may hold that free port: ci/ci-gate, 1 of 60 local runs.)
        assert!(String::from_utf8_lossy(&out.stderr).contains("it has gone"));
        let out = run(pair);
        assert_eq!(out.status.code(), Some(2), "no --parent-pid: usage");
        let parse = |a: &[&str]| parse_args(a.iter().map(OsString::from)).map(|a| a.pairs.len());
        assert_eq!(parse(&["--parent-pid", "5", "1=/a"]), Ok(1), "the control");
        assert!(parse(&["--parent-pid", "0", "1=/a"]).is_err());
        assert!(parse(&["--parent-pid", "5"]).is_err(), "no pair");
    }

    #[cfg(any(target_os = "linux", target_os = "android"))] // only the /proc liveness probe below uses it
    fn state_of(pid: u32) -> Option<char> {
        let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        s.rsplit(')').next()?.trim().chars().next()
    }

    #[test]
    #[cfg(any(target_os = "linux", target_os = "android"))] // /proc; macOS CI skips the liveness probe
    fn ends_when_the_parent_goes() {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let dir = tempfile::tempdir().unwrap();
        let port = free_port();
        let exe = std::env::current_exe().unwrap();
        // The shell is the relay's parent and stays alive while we hold its stdin.
        let mut sh = Command::new("sh")
            .arg("-c")
            .arg(
                r#"GLEIPNIR_RELAY_CHILD="$1 --parent-pid $$" "$0" --exact net::relay::tests::child_entry --nocapture --test-threads=1 </dev/null >/dev/null 2>&1 &
echo $!; read x"#,
            )
            .arg(&exe)
            .arg(format!("{port}={}", dir.path().join("s.sock").display()))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        // GLEIPNIR_RELAY_CHILD: the pair, then the shell's own pid as the expected parent.
        let mut out = String::new();
        {
            let mut line = Vec::new();
            let so = sh.stdout.as_mut().unwrap();
            let mut b = [0u8; 1];
            while so.read(&mut b).unwrap() == 1 && b[0] != b'\n' {
                line.push(b[0]);
            }
            out.push_str(&String::from_utf8(line).unwrap());
        }
        let pid: u32 = out.trim().parse().unwrap();
        let up = |p: u16| std::net::TcpStream::connect(("127.0.0.1", p)).is_ok();
        let mut listening = false;
        for _ in 0..100 {
            if up(port) {
                listening = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let alive = |pid: u32| matches!(state_of(pid), Some(c) if c != 'Z' && c != 'X');
        assert!(listening && alive(pid), "relay up while the parent lives");
        std::thread::sleep(Duration::from_millis(1500));
        assert!(alive(pid), "still up after a poll while the parent lives");
        // The parent goes.
        drop(sh.stdin.take().unwrap().write_all(b"\n"));
        let _ = sh.wait();
        let mut gone = false;
        for _ in 0..60 {
            if !alive(pid) {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        if !gone {
            let _ = rustix::process::kill_process(
                rustix::process::Pid::from_raw(pid as i32).unwrap(),
                rustix::process::Signal::KILL,
            );
        }
        assert!(gone, "the relay exits within seconds of its parent");
    }
}
