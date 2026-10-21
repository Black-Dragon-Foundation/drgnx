//! The CONNECT-only allowlist proxy: exact `host:port` entries, one resolution, no TLS termination (Task 10).
//!
//! One proxy per job, listening on every session socket of that job ([`ProxyHandle::listen`], each with a tag), with
//! one allowlist they share. It answers `CONNECT host:port` only; a listed target gets `200` and the bytes are spliced
//! both ways as they are. Everything else is refused, and the caller hears of it through [`ProxyEvent`]: `Denied`
//! for a target that could be offered on a card, `Refused` for one that never may (a private address, a wildcard, a
//! malformed request). See docs/develop/gleipnir.md, "The proxy".

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinSet};

use super::host::{Host, Target, TargetError, is_public, parse_target};

/// What a proxy allows and how much it takes.
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    /// The allowlist at the start: exact targets, no wildcards.
    pub allow: Vec<Target>,
    /// Names resolved to a fixed address instead of asking DNS. Only a pinned name reaches an address that is not
    /// public; the name must still be on the allowlist.
    pub pinned: Vec<(String, IpAddr)>,
    /// The largest request head in bytes, the line and the headers with their blank line.
    pub max_head: usize,
    /// How long a client has to send its whole head.
    pub head_timeout: Duration,
    /// The most client connections at once, over every listener.
    pub max_conns: usize,
}

impl Default for ProxyConfig {
    fn default() -> Self {
        ProxyConfig {
            allow: Vec::new(),
            pinned: Vec::new(),
            max_head: 8192,
            head_timeout: Duration::from_secs(10),
            max_conns: 64,
        }
    }
}

/// What the proxy refused, each said at most once per target per tag. The tag names the listener, so the session.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ProxyEvent {
    /// A well-formed public target that is not on the allowlist: the caller may ask the user.
    Denied { tag: u64, target: Target },
    /// A request that is never offered: `target` is the normal form for `Private`, else the request's target with
    /// every byte outside printable ASCII escaped (at most 256 bytes of it; empty when there was none).
    Refused {
        tag: u64,
        target: String,
        why: RefuseWhy,
    },
}

/// Why a request was refused without a card.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefuseWhy {
    /// An address that is not public, as a literal or as every address DNS gave for a name that is not pinned.
    Private,
    /// A `*` in the target.
    Wildcard,
    /// Not `CONNECT target HTTP/1.x`, a target that is not `host:port`, a head too large or too slow.
    BadRequest,
    /// A target with a byte outside printable ASCII (a NUL, a U-label).
    NotAscii,
}

/// A socket the proxy accepts clients on: a Unix socket on Linux, `127.0.0.1:0` on macOS.
#[derive(Debug)]
pub enum Listener {
    Unix(UnixListener),
    Tcp(TcpListener),
}

/// Resolves a name to addresses. The proxy asks once per request and connects only to what it got.
pub trait Resolver: Send + Sync + 'static {
    fn resolve(
        &self,
        host: &str,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send>>;
}

/// The system resolver, through `tokio::net::lookup_host`.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemResolver;

impl Resolver for SystemResolver {
    fn resolve(
        &self,
        host: &str,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send>> {
        let host = host.to_owned();
        Box::pin(async move {
            Ok(tokio::net::lookup_host((host.as_str(), port))
                .await?
                .collect())
        })
    }
}

/// How the proxy opens an upstream connection; tests substitute one that records and redirects.
type Connect = Arc<dyn Fn(SocketAddr) -> Connecting + Send + Sync>;
type Connecting = Pin<Box<dyn Future<Output = io::Result<TcpStream>> + Send>>;

fn tcp_connect(a: SocketAddr) -> Connecting {
    Box::pin(TcpStream::connect(a))
}

/// What every listener of one proxy shares.
struct Shared {
    allow: Mutex<HashSet<Target>>,
    /// Names in normal form (lower case, no trailing dot).
    pinned: Vec<(String, IpAddr)>,
    max_head: usize,
    head_timeout: Duration,
    max_conns: usize,
    conns: AtomicUsize,
    resolver: Arc<dyn Resolver>,
    connect: Connect,
    events: mpsc::Sender<ProxyEvent>,
    /// The events sent already, so each is sent once.
    said: Mutex<HashSet<ProxyEvent>>,
    /// Each tag's accept loops; aborting one drops its listener and its connections with it.
    listeners: Mutex<HashMap<u64, Vec<AbortHandle>>>,
}

/// A running proxy. Dropping it shuts it down.
pub struct ProxyHandle {
    shared: Arc<Shared>,
}

/// Starts a proxy (no listener yet). Call it inside a tokio runtime.
pub fn start(
    cfg: ProxyConfig,
    resolver: Arc<dyn Resolver>,
    events: mpsc::Sender<ProxyEvent>,
) -> ProxyHandle {
    start_with(cfg, resolver, events, Arc::new(tcp_connect))
}

fn start_with(
    cfg: ProxyConfig,
    resolver: Arc<dyn Resolver>,
    events: mpsc::Sender<ProxyEvent>,
    connect: Connect,
) -> ProxyHandle {
    let pinned = cfg
        .pinned
        .into_iter()
        .map(|(n, a)| (n.strip_suffix('.').unwrap_or(&n).to_ascii_lowercase(), a))
        .collect();
    ProxyHandle {
        shared: Arc::new(Shared {
            allow: Mutex::new(cfg.allow.into_iter().collect()),
            pinned,
            max_head: cfg.max_head,
            head_timeout: cfg.head_timeout,
            max_conns: cfg.max_conns,
            conns: AtomicUsize::new(0),
            resolver,
            connect,
            events,
            said: Mutex::new(HashSet::new()),
            listeners: Mutex::new(HashMap::new()),
        }),
    }
}

impl ProxyHandle {
    /// Accepts clients on `listener`; their events carry `tag`.
    pub fn listen(&self, listener: Listener, tag: u64) {
        let task = tokio::spawn(serve(self.shared.clone(), listener, tag));
        lock(&self.shared.listeners)
            .entry(tag)
            .or_default()
            .push(task.abort_handle());
    }

    /// Drops the listeners of `tag` and every connection they accepted.
    pub fn close(&self, tag: u64) {
        for task in lock(&self.shared.listeners)
            .remove(&tag)
            .unwrap_or_default()
        {
            task.abort();
        }
        lock(&self.shared.said).retain(|e| match e {
            ProxyEvent::Denied { tag: t, .. } | ProxyEvent::Refused { tag: t, .. } => *t != tag,
        });
    }

    /// Adds `target` to the allowlist every listener shares.
    pub fn allow(&self, target: Target) {
        lock(&self.shared.allow).insert(target);
    }

    /// Removes `target` from the allowlist. Connections already spliced stay.
    pub fn deny(&self, target: &Target) {
        lock(&self.shared.allow).remove(target);
    }

    /// Drops every listener and connection.
    pub fn shutdown(&self) {
        for task in lock(&self.shared.listeners).drain().flat_map(|(_, v)| v) {
            task.abort();
        }
    }
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// A poisoned lock still holds consistent data here (sets and maps changed in one call), so it is used as it is.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A client connection, from either kind of listener.
trait Client: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Client for T {}

/// One of the `max_conns` places; given back when the connection ends.
struct Slot(Arc<Shared>);

impl Slot {
    #[allow(
        deprecated,
        reason = "fetch_update is deprecated since 1.99 as an alias of try_update, which needs 1.95 (MSRV 1.88)"
    )]
    fn take(sh: &Arc<Shared>) -> Option<Slot> {
        sh.conns
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < sh.max_conns).then_some(n + 1)
            })
            .ok()
            .map(|_| Slot(sh.clone()))
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.conns.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The accept loop of one listener. Its connections live in its `JoinSet`, so aborting it ends them too.
async fn serve(sh: Arc<Shared>, listener: Listener, tag: u64) {
    let mut conns = JoinSet::new();
    loop {
        tokio::select! {
            accepted = accept(&listener) => match accepted {
                Ok(client) => {
                    // the place is taken here, in accept order, so the cap holds however the tasks run
                    let slot = Slot::take(&sh);
                    let sh = sh.clone();
                    conns.spawn(async move {
                        match slot {
                            Some(slot) => handle(sh, client, tag, slot).await,
                            None => answer(client, FORBIDDEN).await,
                        }
                    });
                }
                // out of fds and the like: wait a little rather than spin
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            },
            Some(_) = conns.join_next(), if !conns.is_empty() => {}
        }
    }
}

async fn accept(listener: &Listener) -> io::Result<Box<dyn Client>> {
    Ok(match listener {
        Listener::Unix(l) => Box::new(l.accept().await?.0),
        Listener::Tcp(l) => Box::new(l.accept().await?.0),
    })
}

const FORBIDDEN: &str = "403 Forbidden";
const BAD_REQUEST: &str = "400 Bad Request";
const BAD_GATEWAY: &str = "502 Bad Gateway";

/// Answers `status` with no body and closes.
async fn answer(mut client: Box<dyn Client>, status: &str) {
    let text = format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    if client.write_all(text.as_bytes()).await.is_ok() {
        let _ = client.shutdown().await;
    }
}

/// Sends `event` unless it was sent before. It goes before the client's answer, so a refused client implies a queued
/// event.
async fn say(sh: &Shared, event: ProxyEvent) {
    if lock(&sh.said).insert(event.clone()) {
        let _ = sh.events.send(event).await;
    }
}

async fn refuse(
    sh: &Shared,
    client: Box<dyn Client>,
    tag: u64,
    target: String,
    why: RefuseWhy,
    status: &str,
) {
    say(sh, ProxyEvent::Refused { tag, target, why }).await;
    answer(client, status).await;
}

/// The request's target as said in an event: at most 256 bytes, everything outside printable ASCII escaped.
fn shown(raw: &[u8]) -> String {
    raw[..raw.len().min(256)].escape_ascii().to_string()
}

enum Head {
    /// The head is `buf[..end]`; what follows its blank line came early and goes upstream first.
    Done(usize),
    Socks,
    TooLarge,
    Gone,
}

/// Reads at most `max` bytes until the head's blank line. A SOCKS greeting is known by its first byte.
async fn read_head(client: &mut Box<dyn Client>, buf: &mut [u8]) -> (Head, usize) {
    let mut len = 0;
    loop {
        if len == buf.len() {
            return (Head::TooLarge, len);
        }
        match client.read(&mut buf[len..]).await {
            Ok(0) | Err(_) => return (Head::Gone, len),
            Ok(n) => {
                let from = len.saturating_sub(3);
                len += n;
                if matches!(buf[0], 0x04 | 0x05) {
                    return (Head::Socks, len);
                }
                if let Some(i) = buf[from..len].windows(4).position(|w| w == b"\r\n\r\n") {
                    return (Head::Done(from + i), len);
                }
            }
        }
    }
}

/// The target of a head's request line, which must be exactly `CONNECT target HTTP/1.x`, one space each. `head` is the
/// bytes before the blank line.
pub(crate) fn connect_request(head: &[u8]) -> Option<&[u8]> {
    let line = &head[..head
        .windows(2)
        .position(|w| w == b"\r\n")
        .unwrap_or(head.len())];
    line.strip_prefix(b"CONNECT ").and_then(|rest| {
        let sp = rest.iter().position(|&c| c == b' ')?;
        matches!(&rest[sp + 1..], b"HTTP/1.1" | b"HTTP/1.0").then_some(&rest[..sp])
    })
}

/// For the `connect_head` fuzz target: the head's end as [`read_head`] finds it, then [`connect_request`].
#[cfg(feature = "fuzzing")]
pub fn fuzz_connect_head(buf: &[u8]) -> Option<&[u8]> {
    let end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    connect_request(&buf[..end])
}

/// One client: its head, the checks, the upstream, the splice.
async fn handle(sh: Arc<Shared>, mut client: Box<dyn Client>, tag: u64, _slot: Slot) {
    let mut buf = vec![0u8; sh.max_head];
    let (head, len) =
        match tokio::time::timeout(sh.head_timeout, read_head(&mut client, &mut buf)).await {
            Ok(r) => r,
            // too slow is refused like too large
            Err(_) => (Head::TooLarge, 0),
        };
    let end = match head {
        Head::Done(end) => end,
        Head::Socks | Head::Gone => return,
        Head::TooLarge => {
            return refuse(
                &sh,
                client,
                tag,
                String::new(),
                RefuseWhy::BadRequest,
                BAD_REQUEST,
            )
            .await;
        }
    };
    let early = &buf[end + 4..len];
    let request = connect_request(&buf[..end]);
    let Some(raw) = request.filter(|r| !r.is_empty()) else {
        return refuse(
            &sh,
            client,
            tag,
            String::new(),
            RefuseWhy::BadRequest,
            BAD_REQUEST,
        )
        .await;
    };
    let text = match std::str::from_utf8(raw) {
        Ok(t) if t.bytes().all(|c| (0x21..=0x7e).contains(&c)) => t,
        _ => {
            return refuse(
                &sh,
                client,
                tag,
                shown(raw),
                RefuseWhy::NotAscii,
                BAD_REQUEST,
            )
            .await;
        }
    };
    let target = match parse_target(text) {
        Ok(t) => t,
        Err(TargetError::Wildcard) => {
            return refuse(&sh, client, tag, shown(raw), RefuseWhy::Wildcard, FORBIDDEN).await;
        }
        Err(TargetError::NotAscii) => {
            return refuse(
                &sh,
                client,
                tag,
                shown(raw),
                RefuseWhy::NotAscii,
                BAD_REQUEST,
            )
            .await;
        }
        Err(_) => {
            return refuse(
                &sh,
                client,
                tag,
                shown(raw),
                RefuseWhy::BadRequest,
                BAD_REQUEST,
            )
            .await;
        }
    };

    // An address that is not public is never reached as a literal, listed or not, and never offered on a card.
    let literal = match target.host {
        Host::V4(a) => Some(IpAddr::V4(a)),
        Host::V6(a) => Some(IpAddr::V6(a)),
        Host::Name(_) => None,
    };
    if literal.is_some_and(|ip| !is_public(ip)) {
        let shown = target.to_string();
        return refuse(&sh, client, tag, shown, RefuseWhy::Private, FORBIDDEN).await;
    }
    if !lock(&sh.allow).contains(&target) {
        say(&sh, ProxyEvent::Denied { tag, target }).await;
        return answer(client, FORBIDDEN).await;
    }

    // Where to connect, decided once: the literal, the pin, or the public part of one DNS answer, always on the
    // target's port. Nothing is resolved again.
    let addrs: Vec<SocketAddr> = match (&target.host, literal) {
        (Host::Name(name), _) => {
            if let Some((_, ip)) = sh.pinned.iter().find(|(n, _)| n == name) {
                vec![SocketAddr::new(*ip, target.port)]
            } else {
                let all = match sh.resolver.resolve(name, target.port).await {
                    Ok(all) if !all.is_empty() => all,
                    _ => return answer(client, BAD_GATEWAY).await,
                };
                let public: Vec<SocketAddr> = all
                    .iter()
                    .filter(|a| is_public(a.ip()))
                    .map(|a| SocketAddr::new(a.ip(), target.port))
                    .collect();
                if public.is_empty() {
                    let shown = target.to_string();
                    return refuse(&sh, client, tag, shown, RefuseWhy::Private, FORBIDDEN).await;
                }
                public
            }
        }
        (_, ip) => ip
            .map(|ip| SocketAddr::new(ip, target.port))
            .into_iter()
            .collect(),
    };

    let mut upstream = None;
    for a in addrs {
        if let Ok(s) = (sh.connect)(a).await {
            upstream = Some(s);
            break;
        }
    }
    let Some(mut upstream) = upstream else {
        return answer(client, BAD_GATEWAY).await;
    };
    if client
        .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
        .await
        .is_err()
        || upstream.write_all(early).await.is_err()
    {
        return;
    }
    // both ways as they are; each side's EOF is passed on as a half-close
    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use std::path::{Path, PathBuf};
    use tokio::net::UnixStream;
    use tokio::sync::oneshot;
    use tokio::time::timeout;

    /// Stands for a public answer: the test connector sends it to a fixture on loopback, so nothing leaves the host.
    const PUBLIC: Ipv4Addr = Ipv4Addr::new(93, 184, 215, 14);
    const LOOP: Ipv4Addr = Ipv4Addr::LOCALHOST;
    const WAIT: Duration = Duration::from_secs(5);

    fn t(s: &str) -> Target {
        parse_target(s).unwrap()
    }

    /// A resolver from a table, counting its calls; an answer list per call (the last one repeats).
    struct Table {
        map: HashMap<String, Vec<Vec<SocketAddr>>>,
        calls: AtomicUsize,
    }

    impl Resolver for Table {
        fn resolve(
            &self,
            host: &str,
            _port: u16,
        ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send>> {
            let n = self.calls.fetch_add(1, Ordering::SeqCst);
            let r = match self.map.get(host) {
                Some(answers) => Ok(answers[n.min(answers.len() - 1)].clone()),
                None => Err(io::Error::new(io::ErrorKind::NotFound, "no such name")),
            };
            Box::pin(async move { r })
        }
    }

    struct Rig {
        handle: ProxyHandle,
        events: mpsc::Receiver<ProxyEvent>,
        dir: tempfile::TempDir,
        attempts: Arc<Mutex<Vec<SocketAddr>>>,
        resolver: Arc<Table>,
    }

    /// A proxy with a table resolver and a connector that records every address it is asked for and sends the
    /// addresses in `redirect` to loopback fixtures (any other address is connected as it is).
    fn rig(
        cfg: ProxyConfig,
        names: &[(&str, Vec<Vec<SocketAddr>>)],
        redirect: &[(SocketAddr, SocketAddr)],
    ) -> Rig {
        let resolver = Arc::new(Table {
            map: names
                .iter()
                .map(|(n, a)| ((*n).to_owned(), a.clone()))
                .collect(),
            calls: AtomicUsize::new(0),
        });
        let attempts = Arc::new(Mutex::new(Vec::new()));
        let redirect: HashMap<SocketAddr, SocketAddr> = redirect.iter().copied().collect();
        let seen = attempts.clone();
        let connect: Connect = Arc::new(move |a: SocketAddr| -> Connecting {
            seen.lock().unwrap().push(a);
            tcp_connect(redirect.get(&a).copied().unwrap_or(a))
        });
        let (tx, events) = mpsc::channel(64);
        let handle = start_with(cfg, resolver.clone(), tx, connect);
        Rig {
            handle,
            events,
            dir: tempfile::Builder::new().prefix("glp-").tempdir().unwrap(),
            attempts,
            resolver,
        }
    }

    impl Rig {
        fn listen(&self, tag: u64) -> PathBuf {
            let p = self.dir.path().join(format!("proxy-{tag}.sock"));
            let l = UnixListener::bind(&p).unwrap();
            self.handle.listen(Listener::Unix(l), tag);
            p
        }

        /// The events said so far (each is sent before its client is answered).
        fn said(&mut self) -> Vec<ProxyEvent> {
            let mut v = Vec::new();
            while let Ok(e) = self.events.try_recv() {
                v.push(e);
            }
            v
        }

        fn attempts(&self) -> Vec<SocketAddr> {
            self.attempts.lock().unwrap().clone()
        }
    }

    /// Reads a response head byte by byte (so no tunnelled byte is taken), or what came before EOF.
    async fn read_head(s: &mut UnixStream) -> String {
        let mut head = Vec::new();
        let mut b = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            match timeout(WAIT, s.read(&mut b)).await.expect("no answer") {
                Ok(1) => head.push(b[0]),
                _ => break,
            }
        }
        String::from_utf8_lossy(&head).into_owned()
    }

    fn status(head: &str) -> u16 {
        head.strip_prefix("HTTP/1.1 ")
            .and_then(|r| r.get(..3))
            .and_then(|c| c.parse().ok())
            .unwrap_or_else(|| panic!("not a response: {head:?}"))
    }

    /// Connects to the proxy at `path`, sends `bytes`, and reads the answer's status.
    async fn ask(path: &Path, bytes: &[u8]) -> (UnixStream, u16) {
        let mut s = UnixStream::connect(path).await.unwrap();
        s.write_all(bytes).await.unwrap();
        let head = read_head(&mut s).await;
        (s, status(&head))
    }

    async fn connect_to(path: &Path, target: &str) -> (UnixStream, u16) {
        ask(
            path,
            format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes(),
        )
        .await
    }

    /// An upstream that echoes every connection.
    async fn echo() -> SocketAddr {
        let l = tokio::net::TcpListener::bind((LOOP, 0)).await.unwrap();
        let a = l.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = l.accept().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = c.split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                });
            }
        });
        a
    }

    /// An upstream for one connection: it reads to EOF, reports what it got, then sends `answer` and closes.
    async fn recorder(answer: Vec<u8>) -> (SocketAddr, oneshot::Receiver<Vec<u8>>) {
        let l = tokio::net::TcpListener::bind((LOOP, 0)).await.unwrap();
        let a = l.local_addr().unwrap();
        let (tx, rx) = oneshot::channel();
        tokio::spawn(async move {
            let (mut c, _) = l.accept().await.unwrap();
            let mut got = Vec::new();
            c.read_to_end(&mut got).await.unwrap();
            let _ = tx.send(got);
            c.write_all(&answer).await.unwrap();
        });
        (a, rx)
    }

    async fn echoes(s: &mut UnixStream, text: &[u8]) -> bool {
        if s.write_all(text).await.is_err() {
            return false;
        }
        let mut got = vec![0u8; text.len()];
        matches!(timeout(WAIT, s.read_exact(&mut got)).await, Ok(Ok(_))) && got == text
    }

    async fn closed(s: &mut UnixStream) -> bool {
        let mut b = [0u8; 64];
        matches!(timeout(WAIT, s.read(&mut b)).await, Ok(Ok(0) | Err(_)))
    }

    fn pinned_up(port: u16) -> ProxyConfig {
        ProxyConfig {
            allow: vec![t(&format!("up.test:{port}"))],
            pinned: vec![("up.test".into(), IpAddr::V4(LOOP))],
            ..ProxyConfig::default()
        }
    }

    #[tokio::test]
    async fn only_the_allowlist() {
        let up = echo().await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);

        let (mut s, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"hello").await);

        // the same name on another port, another name on the same port: not listed
        for other in ["up.test:22".to_owned(), format!("down.test:{}", up.port())] {
            let (mut s, code) = connect_to(&p, &other).await;
            assert_eq!(code, 403, "{other}");
            assert!(closed(&mut s).await);
        }
        assert_eq!(
            r.said(),
            vec![
                ProxyEvent::Denied {
                    tag: 1,
                    target: t("up.test:22")
                },
                ProxyEvent::Denied {
                    tag: 1,
                    target: t(&format!("down.test:{}", up.port()))
                },
            ]
        );
        assert_eq!(
            r.attempts(),
            vec![up],
            "only the listed target was connected"
        );
    }

    #[tokio::test]
    async fn no_tls_termination() {
        // a ClientHello-like start, then every byte value, sent with the head and after the 200
        let mut early = vec![
            0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xfc, 0x03, 0x03,
        ];
        early.extend(0u8..=255);
        early.extend_from_slice(b"\r\n\r\nCONNECT x HTTP/1.1\r\n\r\n");
        let later: Vec<u8> = (0u8..=255).rev().cycle().take(100_000).collect();
        let answer: Vec<u8> = (0u8..=255).cycle().take(70_000).collect();
        let (up, got) = recorder(answer.clone()).await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);

        let mut first = format!("CONNECT up.test:{} HTTP/1.1\r\n\r\n", up.port()).into_bytes();
        first.extend_from_slice(&early);
        let (mut s, code) = ask(&p, &first).await;
        assert_eq!(code, 200);
        s.write_all(&later).await.unwrap();
        s.shutdown().await.unwrap();
        let mut back = Vec::new();
        timeout(WAIT, s.read_to_end(&mut back))
            .await
            .unwrap()
            .unwrap();

        let mut sent = early;
        sent.extend_from_slice(&later);
        assert_eq!(
            got.await.unwrap(),
            sent,
            "the upstream sees the client's exact bytes"
        );
        assert_eq!(back, answer, "the client sees the upstream's exact bytes");
        assert!(r.said().is_empty());
    }

    #[tokio::test]
    async fn plain_get_refused() {
        let up = echo().await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        let (mut s, code) = ask(
            &p,
            format!(
                "GET http://up.test:{}/ HTTP/1.1\r\nHost: up.test\r\n\r\n",
                up.port()
            )
            .as_bytes(),
        )
        .await;
        assert_eq!(code, 400);
        assert!(closed(&mut s).await);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Refused {
                tag: 1,
                target: String::new(),
                why: RefuseWhy::BadRequest
            }]
        );
        assert!(r.attempts().is_empty());
    }

    #[tokio::test]
    async fn bad_requests_table() {
        let up = echo().await;
        let port = up.port();
        let mut cfg = pinned_up(port);
        cfg.max_head = 256;
        // listed literals that are not public: still refused, and a regression would reach the fixture
        for lit in [
            format!("127.0.0.1:{port}"),
            format!("[::ffff:127.0.0.1]:{port}"),
        ] {
            cfg.allow.push(t(&lit));
        }
        let v6up = SocketAddr::new("::ffff:127.0.0.1".parse().unwrap(), port);
        let mut r = rig(cfg, &[], &[(v6up, up)]);
        let p = r.listen(7);
        use RefuseWhy::*;
        let long = "a".repeat(300);
        let (lit4, lit6) = (
            format!("127.0.0.1:{port}"),
            format!("[::ffff:127.0.0.1]:{port}"),
        );
        // the request, the status, and the event (its target and why)
        type Row<'a> = (Vec<u8>, u16, Option<(&'a str, RefuseWhy)>);
        let rows: Vec<Row> = vec![
            (
                format!("CONNECT up.test:{port} HTTP/2.0\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                format!("connect up.test:{port} HTTP/1.1\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                format!("CONNECT  up.test:{port} HTTP/1.1\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                format!("CONNECT up.test:{port}\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                format!("CONNECT up.test:{port} HTTP/1.1 x\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                b"CONNECT a\0b.com:443 HTTP/1.1\r\n\r\n".to_vec(),
                400,
                Some(("a\\x00b.com:443", NotAscii)),
            ),
            (
                "CONNECT bücher.de:443 HTTP/1.1\r\n\r\n".into(),
                400,
                Some(("b\\xc3\\xbccher.de:443", NotAscii)),
            ),
            (
                b"CONNECT up.test:0 HTTP/1.1\r\n\r\n".to_vec(),
                400,
                Some(("up.test:0", BadRequest)),
            ),
            (
                b"CONNECT 127.1:80 HTTP/1.1\r\n\r\n".to_vec(),
                400,
                Some(("127.1:80", BadRequest)),
            ),
            (
                b"CONNECT foo_bar.com:443 HTTP/1.1\r\n\r\n".to_vec(),
                400,
                Some(("foo_bar.com:443", BadRequest)),
            ),
            (
                format!("CONNECT up.test:{port} HTTP/1.1\r\nX: {long}\r\n\r\n").into(),
                400,
                Some(("", BadRequest)),
            ),
            (
                b"*.up.test:443 HTTP/1.1\r\n\r\n".to_vec(),
                400,
                Some(("", BadRequest)),
            ),
            (
                b"CONNECT *.up.test:443 HTTP/1.1\r\n\r\n".to_vec(),
                403,
                Some(("*.up.test:443", Wildcard)),
            ),
            (
                format!("CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n").into(),
                403,
                Some((&lit4, Private)),
            ),
            (
                format!("CONNECT [::ffff:127.0.0.1]:{port} HTTP/1.1\r\n\r\n").into(),
                403,
                Some((&lit6, Private)),
            ),
            (
                b"CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n".to_vec(),
                403,
                Some(("169.254.169.254:80", Private)),
            ),
            (
                b"CONNECT [64:ff9b::a9fe:a9fe]:80 HTTP/1.1\r\n\r\n".to_vec(),
                403,
                Some(("[64:ff9b::a9fe:a9fe]:80", Private)),
            ),
            (
                b"CONNECT 10.0.0.1:443 HTTP/1.1\r\n\r\n".to_vec(),
                403,
                Some(("10.0.0.1:443", Private)),
            ),
        ];
        // each event is said once per tag: a row repeating an earlier row's event expects none
        let mut before = HashSet::new();
        for (req, want, event) in rows {
            let shown = String::from_utf8_lossy(&req).into_owned();
            let (mut s, code) = ask(&p, &req).await;
            assert_eq!(code, want, "{shown:?}");
            assert!(closed(&mut s).await, "{shown:?}");
            let expect: Vec<ProxyEvent> = event
                .map(|(target, why)| ProxyEvent::Refused {
                    tag: 7,
                    target: target.into(),
                    why,
                })
                .filter(|e| before.insert(e.clone()))
                .into_iter()
                .collect();
            assert_eq!(r.said(), expect, "{shown:?}");
        }
        assert!(
            r.attempts().is_empty(),
            "nothing was connected: {:?}",
            r.attempts()
        );
    }

    #[tokio::test]
    async fn wildcard_is_refused_without_denied() {
        let up = echo().await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        for _ in 0..2 {
            let (mut s, code) = connect_to(&p, &format!("*.up.test:{}", up.port())).await;
            assert_eq!(code, 403);
            assert!(closed(&mut s).await);
        }
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Refused {
                tag: 1,
                target: format!("*.up.test:{}", up.port()),
                why: RefuseWhy::Wildcard
            }]
        );
        assert!(r.attempts().is_empty());
    }

    #[tokio::test]
    async fn dns_answer_private_refused() {
        let up = echo().await;
        // listed, not pinned; DNS answers only private addresses, one of them the fixture
        let cfg = ProxyConfig {
            allow: vec![t("inside.test:443")],
            ..ProxyConfig::default()
        };
        let answers = vec![vec![
            SocketAddr::new(IpAddr::V4(LOOP), 443),
            "10.0.0.5:443".parse().unwrap(),
            "[::ffff:192.168.1.1]:443".parse().unwrap(),
        ]];
        let to_up = SocketAddr::new(IpAddr::V4(LOOP), 443);
        let mut r = rig(cfg, &[("inside.test", answers)], &[(to_up, up)]);
        let p = r.listen(3);
        let (mut s, code) = connect_to(&p, "inside.test:443").await;
        assert_eq!(code, 403);
        assert!(closed(&mut s).await);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Refused {
                tag: 3,
                target: "inside.test:443".into(),
                why: RefuseWhy::Private
            }]
        );
        assert!(r.attempts().is_empty(), "connected: {:?}", r.attempts());
    }

    #[tokio::test]
    async fn pinned_private_reached() {
        let up = echo().await;
        // DNS would say something else; the pin wins, and is asked of no resolver
        let wrong = vec![vec![SocketAddr::new(IpAddr::V4(PUBLIC), up.port())]];
        let mut r = rig(pinned_up(up.port()), &[("up.test", wrong)], &[]);
        let p = r.listen(1);
        let (mut s, code) = connect_to(&p, &format!("UP.test.:{}", up.port())).await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"pinned").await);
        assert_eq!(r.attempts(), vec![up]);
        assert_eq!(r.resolver.calls.load(Ordering::SeqCst), 0);
        assert!(r.said().is_empty());

        // a pin is for its exact name: a listed subdomain goes to DNS (which has no answer here)
        let sub = t(&format!("sub.up.test:{}", up.port()));
        r.handle.allow(sub.clone());
        let (_s, code) = connect_to(&p, &sub.to_string()).await;
        assert_eq!(code, 502);
        assert_eq!(r.attempts(), vec![up]);
    }

    #[tokio::test]
    async fn mixed_dns_answer_uses_the_public_address() {
        let up = echo().await;
        let cfg = ProxyConfig {
            allow: vec![t("mixed.test:443")],
            ..ProxyConfig::default()
        };
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 443);
        let private = SocketAddr::new(IpAddr::V4(LOOP), 443);
        // the private one first, and it too leads to the fixture: only the attempt list tells them apart
        let answers = vec![vec![private, "[fe80::1]:443".parse().unwrap(), public]];
        let mut r = rig(
            cfg,
            &[("mixed.test", answers)],
            &[(public, up), (private, up)],
        );
        let p = r.listen(1);
        let (mut s, code) = connect_to(&p, "mixed.test:443").await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"mixed").await);
        assert_eq!(r.attempts(), vec![public]);
        assert!(r.said().is_empty());
    }

    #[tokio::test]
    async fn one_resolution_rebinding_cannot_redirect() {
        let up = echo().await;
        let cfg = ProxyConfig {
            allow: vec![t("rebind.test:443")],
            ..ProxyConfig::default()
        };
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 443);
        let private = SocketAddr::new(IpAddr::V4(LOOP), 443);
        // a DNS answer that turns private after the first question; the port in an answer is not the target's
        let answers = vec![
            vec![SocketAddr::new(IpAddr::V4(PUBLIC), 8443)],
            vec![private],
        ];
        let r = rig(
            cfg,
            &[("rebind.test", answers)],
            &[(public, up), (private, up)],
        );
        let p = r.listen(1);
        let (mut s, code) = connect_to(&p, "rebind.test:443").await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"once").await);
        assert_eq!(r.resolver.calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            r.attempts(),
            vec![public],
            "the checked address, on the target's port"
        );
    }

    #[tokio::test]
    async fn listed_but_unreachable_is_502() {
        // a listed public name whose addresses refuse, one that does not resolve, and one whose answer is empty
        // (no address at all is unreachable, not private)
        let closed_port = {
            let l = std::net::TcpListener::bind((LOOP, 0)).unwrap();
            l.local_addr().unwrap()
        };
        let cfg = ProxyConfig {
            allow: vec![
                t("gone.test:443"),
                t("nowhere.test:443"),
                t("empty.test:443"),
            ],
            ..ProxyConfig::default()
        };
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 443);
        let mut r = rig(
            cfg,
            &[
                ("gone.test", vec![vec![public]]),
                ("empty.test", vec![vec![]]),
            ],
            &[(public, closed_port)],
        );
        let p = r.listen(1);
        for target in ["gone.test:443", "nowhere.test:443", "empty.test:443"] {
            let (mut s, code) = connect_to(&p, target).await;
            assert_eq!(code, 502, "{target}");
            assert!(closed(&mut s).await);
        }
        assert!(r.said().is_empty());
    }

    #[tokio::test]
    async fn denied_once_per_target() {
        let mut r = rig(ProxyConfig::default(), &[], &[]);
        let p = r.listen(5);
        for target in [
            "a.test:443",
            "a.test:443",
            "A.test.:443",
            "b.test:443",
            "a.test:443",
        ] {
            let (_s, code) = connect_to(&p, target).await;
            assert_eq!(code, 403, "{target}");
        }
        assert_eq!(
            r.said(),
            vec![
                ProxyEvent::Denied {
                    tag: 5,
                    target: t("a.test:443")
                },
                ProxyEvent::Denied {
                    tag: 5,
                    target: t("b.test:443")
                },
            ]
        );
    }

    #[tokio::test]
    async fn allow_takes_effect_on_retry() {
        let up = echo().await;
        let target = t(&format!("up.test:{}", up.port()));
        let cfg = ProxyConfig {
            allow: Vec::new(),
            ..pinned_up(up.port())
        };
        let mut r = rig(cfg, &[], &[]);
        let p = r.listen(1);
        let (_s, code) = connect_to(&p, &target.to_string()).await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Denied {
                tag: 1,
                target: target.clone()
            }]
        );

        r.handle.allow(target.clone());
        let (mut s, code) = connect_to(&p, &target.to_string()).await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"now").await);

        r.handle.deny(&target);
        let (_s2, code) = connect_to(&p, &target.to_string()).await;
        assert_eq!(code, 403);
        assert!(echoes(&mut s, b"spliced stays").await);
    }

    #[tokio::test]
    async fn socks_greeting_closed() {
        let up = echo().await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        for greeting in [
            &[0x05u8, 0x01, 0x00][..],
            &[0x04, 0x01, 0x00, 0x50, 127, 0, 0, 1, 0][..],
        ] {
            let mut s = UnixStream::connect(&p).await.unwrap();
            s.write_all(greeting).await.unwrap();
            let mut got = Vec::new();
            let _ = timeout(WAIT, s.read_to_end(&mut got))
                .await
                .expect("not closed");
            assert!(got.is_empty(), "answered {got:?}");
        }
        assert!(r.said().is_empty());
        assert!(r.attempts().is_empty());
    }

    #[tokio::test]
    async fn slow_head_times_out() {
        let cfg = ProxyConfig {
            head_timeout: Duration::from_millis(300),
            ..ProxyConfig::default()
        };
        let mut r = rig(cfg, &[], &[]);
        let p = r.listen(1);
        let started = std::time::Instant::now();
        let (mut s, code) = ask(&p, b"CONNECT up.test:443 HTTP/1.1\r\nHost: up").await;
        assert_eq!(code, 400);
        assert!(started.elapsed() >= Duration::from_millis(300));
        assert!(closed(&mut s).await);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Refused {
                tag: 1,
                target: String::new(),
                why: RefuseWhy::BadRequest
            }]
        );
    }

    #[tokio::test]
    async fn cap_of_64() {
        let up = echo().await;
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        let mut held = Vec::new();
        for _ in 0..64 {
            held.push(UnixStream::connect(&p).await.unwrap());
        }
        let (mut s, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 403, "the 65th");
        assert!(closed(&mut s).await);
        // the held ones are served
        held[0]
            .write_all(format!("CONNECT up.test:{} HTTP/1.1\r\n\r\n", up.port()).as_bytes())
            .await
            .unwrap();
        assert_eq!(status(&read_head(&mut held[0]).await), 200);
        assert!(r.said().is_empty());

        // the slots come back when they close
        drop(held);
        let deadline = std::time::Instant::now() + WAIT;
        loop {
            let (_s, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
            if code == 200 {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the slots never came back"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[tokio::test]
    async fn half_close_carries_the_answer() {
        let (up, got) = recorder(b"the answer".to_vec()).await;
        let r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        let (mut s, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 200);
        s.write_all(b"the question").await.unwrap();
        s.shutdown().await.unwrap();
        let mut back = Vec::new();
        timeout(WAIT, s.read_to_end(&mut back))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(got.await.unwrap(), b"the question");
        assert_eq!(back, b"the answer");
    }

    #[tokio::test]
    async fn two_listeners_one_allowlist_events_tagged() {
        let up = echo().await;
        let target = t(&format!("up.test:{}", up.port()));
        let cfg = ProxyConfig {
            allow: Vec::new(),
            ..pinned_up(up.port())
        };
        let mut r = rig(cfg, &[], &[]);
        let (p1, p2) = (r.listen(1), r.listen(2));
        r.handle.allow(target.clone());
        for p in [&p1, &p2] {
            let (mut s, code) = connect_to(p, &target.to_string()).await;
            assert_eq!(code, 200);
            assert!(echoes(&mut s, b"shared").await);
        }
        for p in [&p1, &p2] {
            let (_s, code) = connect_to(p, "x.test:443").await;
            assert_eq!(code, 403);
        }
        assert_eq!(
            r.said(),
            vec![
                ProxyEvent::Denied {
                    tag: 1,
                    target: t("x.test:443")
                },
                ProxyEvent::Denied {
                    tag: 2,
                    target: t("x.test:443")
                },
            ]
        );
    }

    #[tokio::test]
    async fn close_tag_ends_its_connections_only() {
        let up = echo().await;
        let target = format!("up.test:{}", up.port());
        let mut r = rig(pinned_up(up.port()), &[], &[]);
        let (p1, p2) = (r.listen(1), r.listen(2));
        for p in [&p1, &p2] {
            let (_s, code) = connect_to(p, "x.test:443").await;
            assert_eq!(code, 403);
        }
        assert_eq!(r.said().len(), 2, "x.test denied once on each tag");
        let (mut a, code_a) = connect_to(&p1, &target).await;
        let (mut b, code_b) = connect_to(&p2, &target).await;
        // one still in its head, on tag 1
        let mut c = UnixStream::connect(&p1).await.unwrap();
        c.write_all(b"CONNECT up").await.unwrap();
        assert_eq!((code_a, code_b), (200, 200));
        assert!(echoes(&mut a, b"before").await);

        r.handle.close(1);
        assert!(closed(&mut a).await, "tag 1's tunnel ends");
        assert!(closed(&mut c).await, "tag 1's half-read client ends");
        assert!(echoes(&mut b, b"after").await, "tag 2's tunnel stays");
        let (mut d, code) = connect_to(&p2, &target).await;
        assert_eq!(code, 200);
        assert!(echoes(&mut d, b"new").await);
        // tag 1 no longer accepts
        let deadline = std::time::Instant::now() + WAIT;
        while UnixStream::connect(&p1).await.is_ok() {
            assert!(std::time::Instant::now() < deadline, "tag 1 still accepts");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        // close forgets what tag 1 was told, and only that: tag 2 stays quiet about x.test, a new tag 1 hears it again
        let (_s, code) = connect_to(&p2, "x.test:443").await;
        assert_eq!(code, 403);
        assert!(r.said().is_empty(), "tag 2 was told about x.test already");
        let again = r.dir.path().join("again.sock");
        r.handle
            .listen(Listener::Unix(UnixListener::bind(&again).unwrap()), 1);
        let (_s, code) = connect_to(&again, "x.test:443").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Denied {
                tag: 1,
                target: t("x.test:443")
            }]
        );
    }

    #[tokio::test]
    async fn dropping_the_handle_ends_everything() {
        let up = echo().await;
        let r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        let (mut a, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 200);
        let Rig {
            handle, dir: _dir, ..
        } = r;
        drop(handle);
        assert!(closed(&mut a).await);
    }

    #[tokio::test]
    async fn shutdown_ends_everything() {
        let up = echo().await;
        let r = rig(pinned_up(up.port()), &[], &[]);
        let p = r.listen(1);
        let (mut a, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 200);
        r.handle.shutdown();
        assert!(closed(&mut a).await);
    }
}
