//! The built `drgnx-px` against a test owner on its stdio, and its socket rules ([C]: each test waits for a frame,
//! an exit or a socket error the sidecar announces; 30 s only bounds a failure).
//!
//! Linux only: the tests bind 127.0.0.2–4, which macOS doesn't route without aliases, and the sidecar runs in a
//! Linux container anyway.
#![cfg(target_os = "linux")]

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::AsRawFd;
use std::process::Stdio;
use std::time::Duration;

use drgnx_px::frame::{Decoder, Frame, Kind, MAX_STREAMS, Ready, encode};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tokio::time::timeout;

const BOUND: Duration = Duration::from_secs(30);
const PX: &str = env!("CARGO_BIN_EXE_drgnx-px");

enum Got {
    Frame(Frame),
    /// stdout ended; the bytes of a frame not complete
    Eof {
        buffered: usize,
    },
    Bad(String),
}

/// The sidecar and the test's end of its channel.
struct Px {
    child: Child,
    stdin: Option<ChildStdin>,
    got: mpsc::UnboundedReceiver<Got>,
    /// what the sidecar wrote to a piped stderr (read by the test-hooks tests)
    #[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
    stderr: Option<tokio::task::JoinHandle<Vec<u8>>>,
    listen: SocketAddr,
}

fn ip(s: &str) -> IpAddr {
    s.parse().expect("an address")
}

impl Px {
    /// Starts the sidecar with `--listen 127.0.0.2:0 --job-ip 127.0.0.3` and `extra`, and reads its `READY`.
    async fn start(extra: &[&str]) -> Px {
        Px::start_with(extra, Stdio::piped()).await
    }

    async fn start_with(extra: &[&str], stderr: Stdio) -> Px {
        let mut child = Command::new(PX)
            .args(["--listen", "127.0.0.2:0", "--job-ip", "127.0.0.3"])
            .args(extra)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(stderr)
            .kill_on_drop(true)
            .spawn()
            .expect("drgnx-px starts");
        let mut stdout = child.stdout.take().expect("stdout");
        let (tx, got) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut dec = Decoder::new();
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match stdout.read(&mut buf).await {
                    Ok(0) | Err(_) => {
                        let _ = tx.send(Got::Eof {
                            buffered: dec.buffered(),
                        });
                        return;
                    }
                    Ok(n) => match dec.push(&buf[..n]) {
                        Ok(frames) => {
                            for f in frames {
                                let _ = tx.send(Got::Frame(f));
                            }
                        }
                        Err(v) => {
                            let _ = tx.send(Got::Bad(v.to_string()));
                            return;
                        }
                    },
                }
            }
        });
        let stderr = child.stderr.take().map(|mut e| {
            tokio::spawn(async move {
                let mut all = Vec::new();
                let _ = e.read_to_end(&mut all).await;
                all
            })
        });
        let stdin = child.stdin.take();
        let mut px = Px {
            child,
            stdin,
            got,
            stderr,
            listen: "0.0.0.0:0".parse().unwrap(),
        };
        let ready = px.next().await;
        assert_eq!(ready.kind, Kind::Ready, "the first frame");
        px.listen = Ready::parse(&ready.payload)
            .expect("READY's payload")
            .listen;
        px
    }

    async fn next(&mut self) -> Frame {
        match timeout(BOUND, self.got.recv()).await {
            Ok(Some(Got::Frame(f))) => f,
            Ok(Some(Got::Eof { buffered })) => panic!("stdout ended ({buffered} bytes of a frame)"),
            Ok(Some(Got::Bad(v))) => panic!("stdout carried a bad frame: {v}"),
            Ok(None) => panic!("the frame reader is gone"),
            Err(_) => panic!("no frame within {BOUND:?}"),
        }
    }

    /// The next frame that isn't a `CREDIT`.
    async fn next_not_credit(&mut self) -> Frame {
        loop {
            let f = self.next().await;
            if f.kind != Kind::Credit {
                return f;
            }
        }
    }

    async fn send(&mut self, f: Frame) {
        let mut bytes = Vec::new();
        encode(&f, &mut bytes);
        self.send_raw(&bytes).await;
    }

    async fn send_raw(&mut self, bytes: &[u8]) {
        let stdin = self.stdin.as_mut().expect("stdin open");
        stdin
            .write_all(bytes)
            .await
            .expect("the sidecar reads its stdin");
    }

    fn close_stdin(&mut self) {
        self.stdin = None;
    }

    async fn exit(&mut self) -> Option<i32> {
        timeout(BOUND, self.child.wait())
            .await
            .expect("the sidecar exits")
            .expect("its status")
            .code()
    }

    /// The frames left on stdout and the bytes of an incomplete one at its end.
    #[cfg(feature = "test-hooks")]
    async fn rest(&mut self) -> (Vec<Frame>, usize) {
        let mut frames = Vec::new();
        loop {
            match timeout(BOUND, self.got.recv()).await.expect("stdout ends") {
                Some(Got::Frame(f)) => frames.push(f),
                Some(Got::Eof { buffered }) => return (frames, buffered),
                Some(Got::Bad(v)) => panic!("stdout carried a bad frame: {v}"),
                None => panic!("the frame reader is gone"),
            }
        }
    }

    #[cfg(feature = "test-hooks")]
    async fn stderr(&mut self) -> String {
        let h = self.stderr.take().expect("stderr piped");
        String::from_utf8_lossy(
            &timeout(BOUND, h)
                .await
                .expect("stderr ends")
                .expect("the reader"),
        )
        .into_owned()
    }
}

/// A connection to `to` from the address `from`.
async fn connect_from(from: &str, to: SocketAddr) -> TcpStream {
    let s = TcpSocket::new_v4().expect("a socket");
    s.bind(SocketAddr::new(ip(from), 0))
        .expect("bind the source");
    timeout(BOUND, s.connect(to))
        .await
        .expect("connect within the bound")
        .expect("connect")
}

async fn read_err(s: &mut TcpStream) -> io::Result<usize> {
    let mut b = [0u8; 64];
    loop {
        match timeout(BOUND, s.read(&mut b)).await.expect("the read ends") {
            Ok(0) => return Ok(0),
            Ok(_) => continue,
            Err(e) => return Err(e),
        }
    }
}

/// [C] The job's connection becomes `OPEN` and its bytes `DATA`; a connection from another source becomes an
/// `EVENT` naming it, and is closed.
#[tokio::test]
async fn the_sidecar_relays_and_checks_the_source() {
    let mut px = Px::start(&[]).await;
    assert_eq!(px.listen.ip(), ip("127.0.0.2"));
    assert_ne!(px.listen.port(), 0, "READY names the bound port");
    let mut job = connect_from("127.0.0.3", px.listen).await;
    job.write_all(b"hello").await.unwrap();
    assert_eq!(px.next().await, Frame::empty(1, Kind::Open));
    assert_eq!(px.next().await, Frame::data(1, b"hello".to_vec()));
    let mut foreign = connect_from("127.0.0.4", px.listen).await;
    assert_eq!(px.next().await, Frame::event(ip("127.0.0.4")));
    // closed: an end or a reset, never bytes
    let _ = read_err(&mut foreign).await;
    px.close_stdin();
    assert_eq!(px.exit().await, Some(0));
}

/// [C] With 64 streams open the 65th connection is taken by the backlog but yields no `OPEN`; once the owner resets
/// one stream, it opens.
#[tokio::test]
async fn the_65th_connection_waits_for_a_free_stream() {
    let mut px = Px::start(&[]).await;
    let mut jobs = Vec::new();
    for i in 0..MAX_STREAMS as u32 {
        jobs.push(connect_from("127.0.0.3", px.listen).await);
        assert_eq!(px.next().await, Frame::empty(2 * i + 1, Kind::Open));
    }
    let _waiting = connect_from("127.0.0.3", px.listen).await;
    tokio::task::spawn_blocking(|| {
        skuld::window(Duration::from_millis(300), "no OPEN for the 65th")
    })
    .await
    .unwrap();
    // the handshake: DATA to stream 1 comes back as its CREDIT, behind anything the sidecar sent before it
    px.send(Frame::data(1, b"ping".to_vec())).await;
    let mut b = [0u8; 4];
    timeout(BOUND, jobs[0].read_exact(&mut b))
        .await
        .unwrap()
        .unwrap();
    loop {
        let f = px.next().await;
        assert_ne!(f.kind, Kind::Open, "the 65th opened at 64 counted: {f:?}");
        if f == Frame::credit(1, 4) {
            break;
        }
    }
    px.send(Frame::empty(1, Kind::Rst)).await;
    assert_eq!(px.next_not_credit().await, Frame::empty(129, Kind::Open));
}

/// [C] The relay's port can't be bound a second time, with `SO_REUSEPORT` or without: the sidecar never sets it.
#[tokio::test]
async fn a_second_bind_on_the_relay_port_fails() {
    let px = Px::start(&[]).await;
    let plain = std::net::TcpListener::bind(px.listen).expect_err("a second plain bind");
    assert_eq!(plain.kind(), io::ErrorKind::AddrInUse);
    let s = TcpSocket::new_v4().unwrap();
    s.set_reuseport(true).unwrap();
    let shared = s
        .bind(px.listen)
        .expect_err("a second bind with SO_REUSEPORT");
    assert_eq!(shared.kind(), io::ErrorKind::AddrInUse);
}

fn sockopt(fd: i32, opt: libc::c_int) -> libc::c_int {
    let mut v: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: `v` and `len` are live and sized for the option.
    let rc = unsafe { libc::getsockopt(fd, libc::SOL_SOCKET, opt, (&raw mut v).cast(), &mut len) };
    assert_eq!(rc, 0, "getsockopt: {}", io::Error::last_os_error());
    v
}

/// [C] An accepted socket has 64 KiB send and receive buffers (Linux reports them doubled).
#[tokio::test]
async fn accepted_sockets_have_64k_buffers() {
    let l = drgnx_px::sidecar::listen("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = l.local_addr().unwrap();
    let _client = TcpStream::connect(addr).await.unwrap();
    let (s, _) = drgnx_px::sidecar::accept(&l).await.unwrap();
    assert_eq!(sockopt(s.as_raw_fd(), libc::SO_RCVBUF), 2 * 65_536);
    assert_eq!(sockopt(s.as_raw_fd(), libc::SO_SNDBUF), 2 * 65_536);
}

/// [C] Stdin's end ends the sidecar with 0.
#[tokio::test]
async fn stdin_eof_ends_the_sidecar_with_0() {
    let mut px = Px::start(&[]).await;
    px.close_stdin();
    assert_eq!(px.exit().await, Some(0));
}

/// [C] A frame of an unknown kind ends it with 4.
#[tokio::test]
async fn a_malformed_frame_ends_it_with_4() {
    let mut px = Px::start(&[]).await;
    px.send_raw(&[0, 0, 0, 1, 9, 0, 0, 0, 0]).await;
    assert_eq!(px.exit().await, Some(4));
}

/// [C] A panic (forced by a test-only flag at the first `BEAT`) lands on stderr; stdout decodes cleanly to its end.
#[cfg(feature = "test-hooks")]
#[tokio::test]
async fn nothing_but_frames_on_stdout() {
    let mut px = Px::start(&["--test-panic-on-beat"]).await;
    px.send(Frame::empty(0, Kind::Beat)).await;
    assert_eq!(px.exit().await, Some(101));
    let (frames, buffered) = px.rest().await;
    assert_eq!(
        (frames, buffered),
        (vec![], 0),
        "nothing after READY, no partial frame"
    );
    let err = px.stderr().await;
    assert!(
        err.contains("panicked") && err.contains("test hook"),
        "stderr: {err}"
    );
}

/// [C] The owner's `RST` resets the job's socket: its read gets `ECONNRESET`, not an end.
#[tokio::test]
async fn an_owner_rst_resets_the_job_socket() {
    let mut px = Px::start(&[]).await;
    let mut job = connect_from("127.0.0.3", px.listen).await;
    job.write_all(b"x").await.unwrap();
    assert_eq!(px.next().await, Frame::empty(1, Kind::Open));
    assert_eq!(px.next().await, Frame::data(1, b"x".to_vec()));
    px.send(Frame::empty(1, Kind::Rst)).await;
    let e = read_err(&mut job).await.expect_err("a reset, not an end");
    assert_eq!(e.kind(), io::ErrorKind::ConnectionReset);
}

/// [C] Stdin's end with streams open resets every job socket, then the exit is 0.
#[tokio::test]
async fn stdin_eof_with_streams_open_resets_them() {
    let mut px = Px::start(&[]).await;
    let mut jobs = Vec::new();
    for i in 0..3u32 {
        jobs.push(connect_from("127.0.0.3", px.listen).await);
        assert_eq!(px.next().await, Frame::empty(2 * i + 1, Kind::Open));
    }
    px.close_stdin();
    for job in &mut jobs {
        let e = read_err(job).await.expect_err("a reset, not an end");
        assert_eq!(e.kind(), io::ErrorKind::ConnectionReset);
    }
    assert_eq!(px.exit().await, Some(0));
}

/// A pipe whose buffer is 4096 bytes: (read end, write end).
#[cfg(feature = "test-hooks")]
fn small_pipe() -> (std::os::fd::OwnedFd, std::os::fd::OwnedFd) {
    use std::os::fd::FromRawFd;
    let mut fds = [0; 2];
    // SAFETY: `fds` has room for the two fds pipe2 writes.
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    // SAFETY: two fresh fds, owned by nothing else.
    let (r, w) = unsafe {
        (
            std::os::fd::OwnedFd::from_raw_fd(fds[0]),
            std::os::fd::OwnedFd::from_raw_fd(fds[1]),
        )
    };
    // SAFETY: fcntl on a live pipe fd.
    assert!(unsafe { libc::fcntl(w.as_raw_fd(), libc::F_SETPIPE_SZ, 4096) } >= 4096);
    (r, w)
}

/// [C] The sidecar's stderr is a 4096-byte pipe that nobody reads, and a test-only flag logs every frame: a stream's
/// 4 MiB round trip still finishes, and the exit at stdin's end is 0.
#[cfg(feature = "test-hooks")]
#[tokio::test]
async fn a_full_stderr_never_stalls_the_relay() {
    const TOTAL: usize = 4 << 20;
    let (_unread, w) = small_pipe();
    let mut px = Px::start_with(&["--test-log-frames"], Stdio::from(w)).await;
    let job = connect_from("127.0.0.3", px.listen).await;
    let (mut jr, mut jw) = job.into_split();
    let pattern: Vec<u8> = (0..TOTAL).map(|i| (i % 251) as u8).collect();
    let sent = pattern.clone();
    let writer = tokio::spawn(async move {
        jw.write_all(&sent).await.unwrap();
        jw.shutdown().await.unwrap();
        jw
    });
    let reader = tokio::spawn(async move {
        let mut back = Vec::new();
        jr.read_to_end(&mut back).await.unwrap();
        back
    });
    // the owner: echo every byte, credit what it took at once, send within the sidecar's credit
    let mut echo: Vec<u8> = Vec::new();
    let mut credit = drgnx_px::frame::WINDOW as usize;
    let (mut fin_seen, mut fin_sent) = (false, false);
    while !fin_sent {
        let f = px.next().await;
        match f.kind {
            Kind::Open => assert_eq!(f.stream, 1),
            Kind::Data => {
                px.send(Frame::credit(1, f.payload.len() as u32)).await;
                echo.extend_from_slice(&f.payload);
            }
            Kind::Credit => credit += f.credit_value().unwrap() as usize,
            Kind::Fin => fin_seen = true,
            other => panic!("unexpected {other:?}"),
        }
        while credit > 0 && !echo.is_empty() {
            let n = echo.len().min(credit).min(drgnx_px::frame::MAX_DATA);
            let chunk: Vec<u8> = echo.drain(..n).collect();
            credit -= n;
            px.send(Frame::data(1, chunk)).await;
        }
        if fin_seen && echo.is_empty() {
            px.send(Frame::empty(1, Kind::Fin)).await;
            fin_sent = true;
        }
    }
    let back = timeout(BOUND, reader).await.unwrap().unwrap();
    assert!(
        back == pattern,
        "the round trip came back whole ({} of {TOTAL} bytes)",
        back.len()
    );
    drop(timeout(BOUND, writer).await.unwrap().unwrap());
    px.close_stdin();
    assert_eq!(px.exit().await, Some(0));
}
