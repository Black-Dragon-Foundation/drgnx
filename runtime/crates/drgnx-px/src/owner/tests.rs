//! [C] The owner's end in-process: `tokio::io::duplex` stands in for the sidecar's stdio, and a stand-in sidecar
//! writes and reads frames by hand. Where a proxy is behind the owner it is gleipnir's, on `Listener::Streams`.

use std::collections::{HashMap, VecDeque};
use std::net::Ipv4Addr;

use gleipnir::net::host::parse_target;
use gleipnir::net::proxy::{self, Listener, ProxyConfig, ProxyEvent, SystemResolver};
use tokio::io::AsyncWriteExt;
use tokio::time::timeout;

use super::*;
use crate::frame::{WINDOW, encode};

const WAIT: Duration = Duration::from_secs(10);
const LISTEN: &str = "127.0.0.2:3128";

fn listen() -> SocketAddr {
    LISTEN.parse().expect("an address")
}

/// The sidecar's side of the channel, by hand.
struct Stand {
    /// The sidecar's stdout; `None` once closed.
    w: Option<DuplexStream>,
    /// The sidecar's stdin.
    r: DuplexStream,
    dec: Decoder,
    got: VecDeque<Frame>,
    credit: HashMap<u32, usize>,
}

impl Stand {
    async fn raw(&mut self, bytes: &[u8]) {
        let w = self.w.as_mut().expect("the stand-in's stdout is open");
        w.write_all(bytes).await.expect("the owner reads");
    }

    async fn send(&mut self, f: Frame) {
        if f.kind == Kind::Open {
            self.credit.insert(f.stream, WINDOW as usize);
        }
        let mut b = Vec::new();
        encode(&f, &mut b);
        self.raw(&b).await;
    }

    fn close(&mut self) {
        self.w = None;
    }

    /// Reads one chunk of the owner's frames: `CREDIT`s are counted, `BEAT`s dropped, the rest kept. False at the end.
    async fn fill(&mut self) -> bool {
        let mut buf = vec![0u8; 64 * 1024];
        let n = timeout(WAIT, self.r.read(&mut buf))
            .await
            .expect("the owner writes or ends")
            .unwrap_or(0);
        if n == 0 {
            return false;
        }
        for f in self.dec.push(&buf[..n]).expect("the owner's frames") {
            match f.kind {
                Kind::Beat => {}
                Kind::Credit => {
                    let n = f.credit_value().expect("a CREDIT's value") as usize;
                    *self.credit.entry(f.stream).or_default() += n;
                }
                _ => self.got.push_back(f),
            }
        }
        true
    }

    /// The owner's next frame that isn't a `BEAT` or a `CREDIT`, or `None` at its end.
    async fn next(&mut self) -> Option<Frame> {
        loop {
            if let Some(f) = self.got.pop_front() {
                return Some(f);
            }
            if !self.fill().await {
                return None;
            }
        }
    }

    /// The bytes of `DATA` on `s` up to the end of a response head; other frames on the way are left out.
    async fn head(&mut self, s: u32) -> String {
        let mut got = Vec::new();
        while !got.windows(4).any(|w| w == b"\r\n\r\n") {
            match self.next().await {
                Some(f) if f.kind == Kind::Data && f.stream == s => got.extend(f.payload),
                Some(_) => {}
                None => panic!("the owner ended before an answer on {s}"),
            }
        }
        String::from_utf8_lossy(&got).into_owned()
    }

    /// Sends `bytes` on `s` as `DATA` within the stream's credit, reading the owner's frames while there is none.
    async fn push(&mut self, s: u32, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let credit = self.credit.get(&s).copied().unwrap_or(0);
            if credit == 0 {
                assert!(self.fill().await, "the owner ended before crediting {s}");
                continue;
            }
            let n = bytes.len().min(credit).min(MAX_DATA);
            self.send(Frame::data(s, bytes[..n].to_vec())).await;
            *self.credit.get_mut(&s).expect("the stream's credit") -= n;
            bytes = &bytes[n..];
        }
    }
}

/// The owner's side: its channels and its log, and `run`'s end.
struct Owner {
    streams: mpsc::Receiver<Relayed>,
    events: mpsc::Receiver<OwnerEvent>,
    log: Log,
    end: JoinHandle<End>,
}

impl Owner {
    async fn end(self) -> (End, String) {
        let end = timeout(WAIT, self.end)
            .await
            .expect("run ends")
            .expect("run's task");
        (end, String::from_utf8_lossy(&self.log.take()).into_owned())
    }

    async fn relayed(&mut self) -> Relayed {
        timeout(WAIT, self.streams.recv())
            .await
            .expect("a stream reaches the proxy's side")
            .expect("the streams channel is open")
    }
}

/// The stand-in and the owner joined by two `duplex`es (`back` bytes for the owner's writes), after a good `READY`.
async fn start(back: usize, beat: Duration, stall: Duration, events: usize) -> (Stand, Owner) {
    let (w, mut out) = tokio::io::duplex(64 * 1024);
    let (inp, r) = tokio::io::duplex(back);
    let mut stand = Stand {
        w: Some(w),
        r,
        dec: Decoder::new(),
        got: VecDeque::new(),
        credit: HashMap::new(),
    };
    stand.send(Frame::ready(listen())).await;
    wait_ready(&mut out, listen(), READY_LIMIT)
        .await
        .expect("a good READY");
    let (stx, streams) = mpsc::channel(STREAMS_ROOM);
    let (etx, events) = mpsc::channel(events);
    let log = Log::default();
    let end = tokio::spawn(run(out, inp, stx, etx, beat, stall, log.clone()));
    (
        stand,
        Owner {
            streams,
            events,
            log,
            end,
        },
    )
}

async fn plain() -> (Stand, Owner) {
    start(64 * 1024, BEAT, shell::STALL, 16).await
}

/// An upstream on loopback that echoes every connection.
async fn echo() -> SocketAddr {
    let l = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    let a = l.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = tokio::net::TcpStream::split(&mut c);
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    a
}

/// Gleipnir's proxy on the owner's streams, allowing only `up.test` (pinned to the echo upstream).
fn proxy_on(
    streams: mpsc::Receiver<Relayed>,
    up: SocketAddr,
) -> (proxy::ProxyHandle, mpsc::Receiver<ProxyEvent>) {
    let cfg = ProxyConfig {
        allow: vec![parse_target(&format!("up.test:{}", up.port())).unwrap()],
        pinned: vec![("up.test".into(), up.ip())],
        ..ProxyConfig::default()
    };
    let (tx, rx) = mpsc::channel(64);
    let h = proxy::start(cfg, Arc::new(SystemResolver), tx);
    h.listen(Listener::Streams(streams), 1);
    (h, rx)
}

fn connect(target: &str) -> Vec<u8> {
    format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").into_bytes()
}

/// [C] A stream the sidecar opens reaches the proxy behind the owner, is judged, and is spliced to its upstream.
#[tokio::test]
async fn a_relayed_connect_reaches_the_proxy() {
    let up = echo().await;
    let (mut stand, mut owner) = plain().await;
    let streams = std::mem::replace(&mut owner.streams, mpsc::channel(1).1);
    let (_proxy, _events) = proxy_on(streams, up);
    stand.send(Frame::empty(1, Kind::Open)).await;
    stand
        .send(Frame::data(1, connect(&format!("up.test:{}", up.port()))))
        .await;
    let head = stand.head(1).await;
    assert!(head.starts_with("HTTP/1.1 200"), "{head:?}");
    stand.send(Frame::data(1, b"ping".to_vec())).await;
    let mut back = Vec::new();
    while back.len() < 4 {
        let f = stand.next().await.expect("the echo");
        if f.kind == Kind::Data && f.stream == 1 {
            back.extend(f.payload);
        }
    }
    assert_eq!(back, b"ping");
    stand.close();
    assert_eq!(owner.end().await.0, End::Eof);
}

/// [C] A frame of an unknown kind ends the channel with `Violation`.
#[tokio::test]
async fn a_violation_from_the_sidecar_returns_violation() {
    let (mut stand, owner) = plain().await;
    stand.raw(&[0, 0, 0, 0, 99, 0, 0, 0, 0]).await;
    let (end, _) = owner.end().await;
    assert!(matches!(end, End::Violation(_)), "{end:?}");
}

/// [C] The sidecar's output ends before any frame: `Ready`, with the reason.
#[tokio::test]
async fn eof_before_ready_is_ready_end() {
    let (w, mut out) = tokio::io::duplex(1024);
    drop(w);
    let r = wait_ready(&mut out, listen(), READY_LIMIT).await;
    assert!(matches!(r, Err(End::Ready(_))), "{r:?}");
}

/// [C] A `READY` naming another address than the one asked for: `Ready`.
#[tokio::test]
async fn a_ready_naming_another_address_is_ready_end() {
    let (mut w, mut out) = tokio::io::duplex(1024);
    let mut b = Vec::new();
    encode(&Frame::ready("127.0.0.2:4000".parse().unwrap()), &mut b);
    w.write_all(&b).await.unwrap();
    let r = wait_ready(&mut out, listen(), READY_LIMIT).await;
    assert!(
        matches!(&r, Err(End::Ready(why)) if why.contains("127.0.0.2:4000")),
        "{r:?}"
    );
}

/// [C] The job CONNECTs to an unlisted host and keeps sending within its credit; the proxy's 403 makes the owner
/// reset the stream, the late `DATA` is discarded, and a second stream's allowed CONNECT still gets its 200.
#[tokio::test]
async fn a_proxy_403_while_the_job_sends_leaves_the_channel_whole() {
    let up = echo().await;
    let (mut stand, mut owner) = plain().await;
    let streams = std::mem::replace(&mut owner.streams, mpsc::channel(1).1);
    let (_proxy, _events) = proxy_on(streams, up);
    stand.send(Frame::empty(1, Kind::Open)).await;
    stand.send(Frame::data(1, connect("x.test:443"))).await;
    // more than the proxy reads and the stream's duplex holds, so the owner's write fails once the proxy is gone
    stand.push(1, &vec![7u8; 128 * 1024]).await;
    let mut answer = Vec::new();
    loop {
        let f = stand.next().await.expect("the owner's frames");
        match (f.stream, f.kind) {
            (1, Kind::Data) => answer.extend(f.payload),
            (1, Kind::Rst) => break,
            _ => {}
        }
    }
    // the RST drops what of the stream still waits for the writer, the 403's bytes among them in some runs
    let answer = String::from_utf8_lossy(&answer);
    assert!(
        answer.is_empty() || answer.starts_with("HTTP/1.1 403"),
        "{answer:?}"
    );
    // late, within the credit the job had: discarded
    stand.send(Frame::data(1, b"late".to_vec())).await;
    stand.send(Frame::empty(3, Kind::Open)).await;
    stand
        .send(Frame::data(3, connect(&format!("up.test:{}", up.port()))))
        .await;
    let head = stand.head(3).await;
    assert!(head.starts_with("HTTP/1.1 200"), "{head:?}");
    assert!(!owner.end.is_finished(), "the channel is still up");
}

/// [C] The stand-in never reads its stdin; with a short stall limit and fast beats, `run` returns `Stalled`.
#[tokio::test]
async fn a_sidecar_that_stops_reading_is_a_stall() {
    let (_stand, owner) = start(64, Duration::from_millis(1), Duration::from_millis(100), 16).await;
    assert_eq!(owner.end().await.0, End::Stalled);
}

/// [C] Half a `DATA` frame, then the end: `Eof`, and the log says the relay ended mid-frame.
#[tokio::test]
async fn a_partial_frame_at_eof_is_eof() {
    let (mut stand, owner) = plain().await;
    stand.send(Frame::empty(1, Kind::Open)).await;
    let mut b = Vec::new();
    encode(&Frame::data(1, vec![1u8; 100]), &mut b);
    stand.raw(&b[..HEADER + 50]).await;
    stand.close();
    let (end, log) = owner.end().await;
    assert_eq!(end, End::Eof);
    assert!(log.contains("the relay ended mid-frame"), "{log:?}");
}

/// [C] An events channel of one that nobody reads: ten foreign sources (the most a second reports), then a stream's
/// 1 MiB, which arrives whole; the drops are counted in the log at `run`'s end.
#[tokio::test]
async fn a_lagging_event_consumer_never_stalls_the_reader() {
    const TOTAL: usize = 1 << 20;
    let (mut stand, mut owner) = start(64 * 1024, BEAT, shell::STALL, 1).await;
    for i in 1..=10u8 {
        stand
            .send(Frame::event(IpAddr::V4(Ipv4Addr::new(10, 0, 0, i))))
            .await;
    }
    stand.send(Frame::empty(1, Kind::Open)).await;
    let mut r = owner.relayed().await;
    let reader = tokio::spawn(async move {
        let mut got = vec![0u8; TOTAL];
        r.io.read_exact(&mut got).await.map(|_| got)
    });
    let pattern: Vec<u8> = (0..TOTAL).map(|i| (i % 251) as u8).collect();
    stand.push(1, &pattern).await;
    let got = timeout(WAIT, reader)
        .await
        .expect("the stream's bytes arrive")
        .unwrap()
        .expect("the whole MiB");
    assert!(got == pattern, "the bytes arrive whole and in order");
    assert_eq!(
        owner.events.try_recv(),
        Ok(OwnerEvent::ForeignSource(IpAddr::V4(Ipv4Addr::new(
            10, 0, 0, 1
        ))))
    );
    stand.close();
    let (end, log) = owner.end().await;
    assert_eq!(end, End::Eof);
    assert!(log.contains("9 foreign-source events dropped"), "{log:?}");
}

/// [C] A `Relayed`'s `gone` resolves after the owner's `RST` and, for every stream, at the channel's end. After both
/// `FIN`s it waits for the proxy's side to let go (or that end), so the proxy finishes copying.
#[tokio::test]
async fn a_closed_stream_fires_its_gone() {
    let (mut stand, mut owner) = plain().await;
    // the owner's RST: the proxy dropped the stream, and the job's next bytes can't be written to it
    stand.send(Frame::empty(1, Kind::Open)).await;
    let r1 = owner.relayed().await;
    drop(r1.io);
    stand.send(Frame::data(1, b"to nobody".to_vec())).await;
    loop {
        let f = stand.next().await.expect("the owner's frames");
        if (f.stream, f.kind) == (1, Kind::Rst) {
            break;
        }
    }
    timeout(WAIT, r1.gone)
        .await
        .expect("gone after the owner's RST")
        .unwrap_err();

    // both FINs: the proxy's side ends its writing, the job ends its own; the proxy may still be copying what the
    // stream left in its duplex, so `gone` waits for the proxy to let go, or the channel's end
    stand.send(Frame::empty(3, Kind::Open)).await;
    let mut r3 = owner.relayed().await;
    r3.io.shutdown().await.unwrap();
    loop {
        let f = stand.next().await.expect("the owner's frames");
        if (f.stream, f.kind) == (3, Kind::Fin) {
            break;
        }
    }
    stand.send(Frame::empty(3, Kind::Fin)).await;
    let mut rest = Vec::new();
    timeout(WAIT, r3.io.read_to_end(&mut rest))
        .await
        .expect("the job's FIN reaches the proxy's side")
        .unwrap();
    let mut g3 = r3.gone;
    assert_eq!(
        g3.try_recv(),
        Err(oneshot::error::TryRecvError::Empty),
        "a graceful close leaves the proxy its copy"
    );

    // the channel's end: every stream still live, and the closed one still held
    stand.send(Frame::empty(5, Kind::Open)).await;
    let r5 = owner.relayed().await;
    stand.close();
    timeout(WAIT, r5.gone)
        .await
        .expect("gone at the channel's end")
        .unwrap_err();
    timeout(WAIT, g3)
        .await
        .expect("the held one too")
        .unwrap_err();
    assert_eq!(owner.end().await.0, End::Eof);
}

/// [C] A stand-in `podman` whose `run` floods stdout and stderr without end: `run` ends by a violation, and `stop`
/// returns (the timeout only guards a hang).
#[cfg(unix)]
#[tokio::test]
async fn stop_finishes_while_the_sidecar_floods() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::Builder::new().prefix("px-").tempdir().unwrap();
    let podman = dir.path().join("podman");
    std::fs::write(
        &podman,
        "#!/bin/sh\ncase \"$1\" in\nrun) while :; do echo flood; echo flood >&2; done ;;\nrm) exit 0 ;;\nesac\n",
    )
    .unwrap();
    std::fs::set_permissions(&podman, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut sc = Sidecar::start(&podman, vec!["run".into()], &[])
        .await
        .expect("the stand-in starts");
    let (inp, out) = sc.take_io().expect("its stdio");
    let (stx, _streams) = mpsc::channel(STREAMS_ROOM);
    let (etx, _events) = mpsc::channel(16);
    let end = timeout(
        WAIT,
        run(out, inp, stx, etx, BEAT, shell::STALL, Log::default()),
    )
    .await
    .expect("run ends");
    assert!(matches!(end, End::Violation(_)), "{end:?}");
    skuld::wait_until_async("the stderr drain reads as it comes", WAIT.as_secs(), || {
        let sc = &sc;
        async move { sc.stderr().contains("flood").then_some(()) }
    })
    .await;
    timeout(STOP_LIMIT * 3, sc.stop(&podman, "px-test", &[]))
        .await
        .expect("stop returns");
}

/// A key source that answers `ok` and the request back, counting its calls.
struct Echoing(Arc<AtomicU64>);

impl KeySource for Echoing {
    fn answer(&self, request: &str) -> AnswerFuture {
        self.0.fetch_add(1, Ordering::SeqCst);
        let a = format!("ok {request}\n").into_bytes();
        Box::pin(async move { Box::new(a) as Box<dyn KeyAnswer> })
    }
}

impl KeyAnswer for Vec<u8> {
    fn bytes(&self) -> &[u8] {
        self
    }
}

/// A keyed owner after a good `READY`, its key source counting the requests it answered.
async fn keyed() -> (Stand, Owner, Arc<AtomicU64>) {
    let (w, mut out) = tokio::io::duplex(64 * 1024);
    let (inp, r) = tokio::io::duplex(64 * 1024);
    let mut stand = Stand {
        w: Some(w),
        r,
        dec: Decoder::new(),
        got: VecDeque::new(),
        credit: HashMap::new(),
    };
    stand.send(Frame::ready(listen())).await;
    wait_ready(&mut out, listen(), READY_LIMIT)
        .await
        .expect("a good READY");
    let (stx, streams) = mpsc::channel(STREAMS_ROOM);
    let (etx, events) = mpsc::channel(16);
    let log = Log::default();
    let calls = Arc::new(AtomicU64::new(0));
    let src: Arc<dyn KeySource> = Arc::new(Echoing(calls.clone()));
    let end = tokio::spawn(run_keyed(
        out,
        inp,
        stx,
        src,
        etx,
        BEAT,
        shell::STALL,
        log.clone(),
    ));
    (
        stand,
        Owner {
            streams,
            events,
            log,
            end,
        },
        calls,
    )
}

impl Stand {
    /// The `DATA` on `s` until its `FIN` (or `None` at its `RST`).
    async fn answer(&mut self, s: u32) -> Option<Vec<u8>> {
        let mut got = Vec::new();
        loop {
            match self.next().await {
                Some(f) if f.stream == s && f.kind == Kind::Data => got.extend(f.payload),
                Some(f) if f.stream == s && f.kind == Kind::Fin => return Some(got),
                Some(f) if f.stream == s && f.kind == Kind::Rst => return None,
                Some(_) => {}
                None => panic!("the owner ended before the answer on {s}"),
            }
        }
    }
}

/// [C] A key stream's one request line reaches the key source and its answer comes back, then the stream's `FIN`;
/// a second line on the same stream is never read. A stream for the proxy carrying the same line never reaches the
/// key source: it goes to the proxy's side.
#[tokio::test]
async fn a_key_stream_reaches_the_key_source_once_and_a_proxy_stream_never() {
    let (mut stand, mut owner, calls) = keyed().await;
    stand.send(Frame::open_key(1)).await;
    stand.push(1, b"get A\nget B\n").await;
    stand.send(Frame::empty(1, Kind::Fin)).await;
    assert_eq!(stand.answer(1).await.as_deref(), Some(&b"ok get A\n"[..]));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    stand.send(Frame::empty(3, Kind::Open)).await;
    stand.push(3, b"get A\n").await;
    let r = owner.relayed().await;
    drop(r);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "a proxy stream reached the keys"
    );
    stand.close();
    assert_eq!(owner.end().await.0, End::Eof);
}

/// [C] A key request longer than [`KEY_REQUEST`] bytes without its newline resets the stream, and the key source
/// never sees it; nor does a line that isn't UTF-8.
#[tokio::test]
async fn an_overlong_key_request_is_reset_unread() {
    let (mut stand, owner, calls) = keyed().await;
    stand.send(Frame::open_key(1)).await;
    stand.push(1, &[b'a'; KEY_REQUEST + 1]).await;
    assert_eq!(stand.answer(1).await, None, "the stream was reset");
    stand.send(Frame::open_key(3)).await;
    stand.push(3, b"get \xff\n").await;
    assert_eq!(stand.answer(3).await, None, "the stream was reset");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    stand.close();
    assert_eq!(owner.end().await.0, End::Eof);
}

/// [C] A key stream on a channel whose job has no keys ends the channel with a violation.
#[tokio::test]
async fn a_key_stream_on_an_unkeyed_channel_ends_it() {
    let (mut stand, owner) = plain().await;
    stand.send(Frame::open_key(1)).await;
    let (end, _) = owner.end().await;
    assert!(
        matches!(&end, End::Violation(v) if v.contains("no keys")),
        "{end:?}"
    );
}
