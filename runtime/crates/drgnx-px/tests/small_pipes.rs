//! [C] Both directions saturated through 4096-byte pipes and a conmon stand-in (design §5.3, B1).
//!
//! The sidecar (the shell in-process, or the built binary) and the owner's `run`, with gleipnir's proxy behind it, are
//! joined through OS pipes of 4096 bytes and one thread that stands in for conmon: it `poll`s its inputs and copies each
//! to its output with a blocking `write_all`, so one full direction stalls the others while it waits, as conmon does.
//! It reads 8 KiB at a time from the sidecar's stdout and stderr and 32 KiB from the owner's side, and carries the
//! sidecar's stderr (every frame logged) to a drain on the owner's side.
//!
//! 64 streams each push 4 MiB up and 4 MiB down at once. Streams 1–32 pause their job-side reads and 33–48 their
//! upstream's reads; 49–64 never pause. The paused ones are released only once every one of 49–64 has finished both ways
//! with its bytes checked: a barrier on that count, so a relay that lets one stalled stream hold up the channel never
//! gets there, and the run hits the timeout that otherwise only guards a hang.
#![cfg(all(target_os = "linux", feature = "test-hooks"))]

use std::fs::File;
use std::io::{Read as _, Write as _};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use drgnx_px::mux::Side;
use drgnx_px::owner::{self, STREAMS_ROOM};
use drgnx_px::shell::{BEAT_LIMIT, Config, Log, STALL};
use drgnx_px::sidecar;
use gleipnir::net::host::parse_target;
use gleipnir::net::proxy::{self, Listener, ProxyConfig, SystemResolver};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::unix::pipe;
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::time::timeout;

const PX: &str = env!("CARGO_BIN_EXE_drgnx-px");
const STREAMS: usize = 64;
const EACH: usize = 4 << 20;
const CHUNK: usize = 64 * 1024;
/// Only a hang reaches it.
const HANG: Duration = Duration::from_secs(240);
const JOB_IP: Ipv4Addr = Ipv4Addr::new(127, 0, 0, 3);

/// A pipe whose buffer is 4096 bytes: (read end, write end).
fn small_pipe() -> (OwnedFd, OwnedFd) {
    let mut fds = [0; 2];
    // SAFETY: `fds` has room for the two fds pipe2 writes.
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    // SAFETY: two fresh fds, owned by nothing else.
    let (r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    // SAFETY: fcntl on a live pipe fd.
    assert!(unsafe { libc::fcntl(w.as_raw_fd(), libc::F_SETPIPE_SZ, 4096) } >= 4096);
    (r, w)
}

/// The conmon stand-in: one thread, `poll` on every input, each read copied to its output with a blocking `write_all`.
/// An input at its end (or an output that fails) closes that link.
fn conmon(links: Vec<(OwnedFd, OwnedFd, usize)>) {
    std::thread::spawn(move || {
        let mut live: Vec<Option<(File, File, usize)>> = links
            .into_iter()
            .map(|(from, to, size)| Some((File::from(from), File::from(to), size)))
            .collect();
        let mut buf = vec![0u8; 32 * 1024];
        loop {
            let idx: Vec<usize> = (0..live.len()).filter(|i| live[*i].is_some()).collect();
            if idx.is_empty() {
                return;
            }
            let mut fds: Vec<libc::pollfd> = idx
                .iter()
                .map(|i| libc::pollfd {
                    fd: live[*i].as_ref().expect("live").0.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                })
                .collect();
            // SAFETY: `fds` holds `fds.len()` initialised pollfds.
            if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) } < 0 {
                continue;
            }
            for (p, i) in fds.iter().zip(idx) {
                if p.revents == 0 {
                    continue;
                }
                let (from, to, size) = live[i].as_mut().expect("live");
                let ok = match from.read(&mut buf[..*size]) {
                    Ok(0) | Err(_) => false,
                    Ok(n) => to.write_all(&buf[..n]).is_ok(),
                };
                if !ok {
                    live[i] = None;
                }
            }
        }
    });
}

/// The bytes one direction of one stream carries, in chunks cut from a shared random block: a chunk out of order,
/// twice or lost changes the hash.
struct Pattern {
    base: Arc<Vec<u8>>,
}

impl Pattern {
    fn new() -> Pattern {
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let base = (0..2 * CHUNK)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        Pattern {
            base: Arc::new(base),
        }
    }

    fn chunk(&self, seed: usize, k: usize) -> &[u8] {
        let at = (seed * 131 + k * 977) % CHUNK;
        &self.base[at..at + CHUNK]
    }
}

/// Writes `EACH` bytes of `seed`'s pattern and half-closes; the hash of what it wrote.
async fn push(w: &mut (impl AsyncWrite + Unpin), base: &Pattern, seed: usize) -> Vec<u8> {
    let mut h = Sha256::new();
    for k in 0..EACH / CHUNK {
        let c = base.chunk(seed, k);
        h.update(c);
        w.write_all(c).await.expect("the relay takes the bytes");
    }
    w.shutdown().await.expect("the half-close");
    h.finalize().to_vec()
}

/// Reads to the end; the count and the hash of what came.
async fn pull(r: &mut (impl AsyncRead + Unpin)) -> (usize, Vec<u8>) {
    let mut h = Sha256::new();
    let mut buf = vec![0u8; CHUNK];
    let mut n = 0;
    loop {
        match r.read(&mut buf).await.expect("the relay's bytes") {
            0 => return (n, h.finalize().to_vec()),
            k => {
                h.update(&buf[..k]);
                n += k;
            }
        }
    }
}

async fn released(mut rx: watch::Receiver<bool>) {
    rx.wait_for(|r| *r).await.expect("the barrier");
}

/// What an upstream saw: the count and hash of the bytes it got, and the hash of the bytes it sent.
type Upstream = ((usize, Vec<u8>), Vec<u8>);

/// Stream `i`'s upstream: one connection; it reads the job's bytes (after the barrier for 33–48) and sends its own.
async fn upstream(
    l: TcpListener,
    i: usize,
    base: Arc<Pattern>,
    gate: watch::Receiver<bool>,
) -> Upstream {
    let (c, _) = l.accept().await.expect("the proxy connects");
    let (mut r, mut w) = c.into_split();
    let sent = tokio::spawn(async move { push(&mut w, &base, 1000 + i).await });
    if (32..48).contains(&i) {
        released(gate).await;
    }
    let got = pull(&mut r).await;
    (got, sent.await.expect("the upstream's writer"))
}

/// Reads a response head byte by byte, so no tunnelled byte is taken.
async fn head(s: &mut TcpStream) -> String {
    let mut h = Vec::new();
    let mut b = [0u8; 1];
    while !h.ends_with(b"\r\n\r\n") {
        assert_eq!(s.read(&mut b).await.expect("the answer"), 1, "{h:?}");
        h.push(b[0]);
    }
    String::from_utf8_lossy(&h).into_owned()
}

/// Stream `i`'s job: CONNECT through the sidecar, then its bytes up and the upstream's down (after the barrier for
/// 1–32). Whole both ways, checked; 49–64 count toward the barrier.
#[allow(clippy::too_many_arguments, reason = "one stream's parts")]
async fn job(
    i: usize,
    to: SocketAddr,
    up: SocketAddr,
    base: Arc<Pattern>,
    gate: watch::Receiver<bool>,
    fixture: tokio::task::JoinHandle<Upstream>,
    done: Arc<AtomicUsize>,
    release: Arc<watch::Sender<bool>>,
) {
    let sock = TcpSocket::new_v4().expect("a socket");
    sock.bind(SocketAddr::new(IpAddr::V4(JOB_IP), 0))
        .expect("bind the job's address");
    let mut c = sock.connect(to).await.expect("the sidecar accepts");
    let target = format!("up.test:{}", up.port());
    c.write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await
        .expect("the CONNECT");
    let h = head(&mut c).await;
    assert!(h.starts_with("HTTP/1.1 200"), "stream {i}: {h:?}");
    let (mut r, mut w) = c.into_split();
    let b = base.clone();
    let sent = tokio::spawn(async move { push(&mut w, &b, i).await });
    if i < 32 {
        released(gate).await;
    }
    let (n_down, down) = pull(&mut r).await;
    let up_sent = sent.await.expect("the job's writer");
    let ((n_up, up_got), down_sent) = fixture.await.expect("the upstream");
    assert_eq!((n_up, n_down), (EACH, EACH), "stream {i}: bytes up, down");
    assert!(
        up_got == up_sent,
        "stream {i}: the bytes up arrive whole and in order"
    );
    assert!(
        down == down_sent,
        "stream {i}: the bytes down arrive whole and in order"
    );
    if i >= 48 && done.fetch_add(1, Ordering::SeqCst) + 1 == STREAMS - 48 {
        release.send_replace(true);
    }
}

/// The sidecar the run uses.
enum Px {
    /// The shell in-process, on the pipes.
    Shell,
    /// The built binary, the pipes as its fds 0, 1 and 2.
    Binary,
}

async fn saturate(px: Px) {
    // the sidecar's stdin, stdout and stderr; the owner's input and output; the owner's stderr drain
    let (sc_in_r, sc_in_w) = small_pipe();
    let (sc_out_r, sc_out_w) = small_pipe();
    let (sc_err_r, sc_err_w) = small_pipe();
    let (ow_in_r, ow_in_w) = small_pipe();
    let (ow_out_r, ow_out_w) = small_pipe();
    let (drain_r, drain_w) = small_pipe();
    conmon(vec![
        (sc_out_r, ow_in_w, 8 * 1024),
        (sc_err_r, drain_w, 8 * 1024),
        (ow_out_r, sc_in_w, 32 * 1024),
    ]);

    // the sidecar, listening on 127.0.0.2
    let listen: SocketAddr;
    let mut child = None;
    let mut shell_end = None;
    match px {
        Px::Shell => {
            let l = sidecar::listen("127.0.0.2:0".parse().unwrap()).expect("the sidecar listens");
            listen = l.local_addr().unwrap();
            let mut cfg = Config::new(Side::Sidecar);
            cfg.beat_limit = Some(BEAT_LIMIT);
            cfg.log_frames = true;
            let input = pipe::Receiver::from_owned_fd(sc_in_r).unwrap();
            let output = pipe::Sender::from_owned_fd(sc_out_w).unwrap();
            let log_out = pipe::Sender::from_owned_fd(sc_err_w).unwrap();
            shell_end = Some(tokio::spawn(sidecar::serve(
                cfg,
                l,
                listen,
                IpAddr::V4(JOB_IP),
                None,
                input,
                output,
                Some(log_out),
                Log::default(),
            )));
        }
        Px::Binary => {
            // a free port, so the owner knows the address READY must name
            let probe = std::net::TcpListener::bind("127.0.0.2:0").unwrap();
            listen = probe.local_addr().unwrap();
            drop(probe);
            child = Some(
                tokio::process::Command::new(PX)
                    .args(["--listen", &listen.to_string(), "--job-ip", "127.0.0.3"])
                    .arg("--test-log-frames")
                    .stdin(Stdio::from(sc_in_r))
                    .stdout(Stdio::from(sc_out_w))
                    .stderr(Stdio::from(sc_err_w))
                    .kill_on_drop(true)
                    .spawn()
                    .expect("drgnx-px starts"),
            );
        }
    }

    // the owner's stderr drain reads all the time
    let mut drain = pipe::Receiver::from_owned_fd(drain_r).unwrap();
    let logged = tokio::spawn(async move { pull(&mut drain).await.0 });

    // the upstreams, and the proxy behind the owner
    let base = Arc::new(Pattern::new());
    let (release, gate) = watch::channel(false);
    let release = Arc::new(release);
    let mut ups = Vec::new();
    let mut allow = Vec::new();
    for i in 0..STREAMS {
        let l = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let a = l.local_addr().unwrap();
        allow.push(parse_target(&format!("up.test:{}", a.port())).unwrap());
        ups.push((a, tokio::spawn(upstream(l, i, base.clone(), gate.clone()))));
    }
    let cfg = ProxyConfig {
        allow,
        pinned: vec![("up.test".into(), IpAddr::V4(Ipv4Addr::LOCALHOST))],
        ..ProxyConfig::default()
    };
    let (ptx, _proxy_events) = mpsc::channel(64);
    let proxy = proxy::start(cfg, Arc::new(SystemResolver), ptx);
    let (stx, streams) = mpsc::channel(STREAMS_ROOM);
    proxy.listen(Listener::Streams(streams), 1);

    let mut out = pipe::Receiver::from_owned_fd(ow_in_r).unwrap();
    let inp = pipe::Sender::from_owned_fd(ow_out_w).unwrap();
    owner::wait_ready(&mut out, listen, owner::READY_LIMIT)
        .await
        .expect("the sidecar's READY");
    let (etx, _events) = mpsc::channel(16);
    let owner_log = Log::default();
    let owner_end = tokio::spawn(owner::run(
        out,
        inp,
        stx,
        etx,
        owner::BEAT,
        STALL,
        owner_log.clone(),
    ));

    let done = Arc::new(AtomicUsize::new(0));
    let jobs: Vec<_> = ups
        .into_iter()
        .enumerate()
        .map(|(i, (up, fixture))| {
            tokio::spawn(job(
                i,
                listen,
                up,
                base.clone(),
                gate.clone(),
                fixture,
                done.clone(),
                release.clone(),
            ))
        })
        .collect();
    let all = async {
        for j in jobs {
            j.await.expect("a stream's job");
        }
    };
    if timeout(HANG, all).await.is_err() {
        panic!(
            "a hang: {} of streams 49–64 finished; the owner's log: {}",
            done.load(Ordering::SeqCst),
            String::from_utf8_lossy(&owner_log.take())
        );
    }
    assert!(!owner_end.is_finished(), "the owner's channel is still up");
    if let Some(e) = &shell_end {
        assert!(!e.is_finished(), "the sidecar's channel is still up");
    }
    // the owner closes the sidecar's stdin: the channel ends at both ends
    owner_end.abort();
    if let Some(e) = shell_end {
        let end = timeout(HANG, e).await.expect("the sidecar ends").unwrap();
        assert_eq!(end, drgnx_px::shell::End::Eof);
    }
    if let Some(mut c) = child {
        let code = timeout(HANG, c.wait())
            .await
            .expect("the sidecar exits")
            .unwrap();
        assert_eq!(code.code(), Some(0));
    }
    assert!(
        timeout(HANG, logged)
            .await
            .expect("the drain ends")
            .unwrap()
            > 0,
        "the sidecar's frame log reached the owner's drain"
    );
}

/// [C, Linux] The sidecar's shell in-process and the owner's `run`, through 4096-byte pipes and the conmon stand-in.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn both_directions_saturated_through_small_pipes_finish() {
    saturate(Px::Shell).await;
}

/// [C, Linux] The same with the built `drgnx-px` as the sidecar.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_built_binary_through_small_pipes_finishes() {
    saturate(Px::Binary).await;
}
