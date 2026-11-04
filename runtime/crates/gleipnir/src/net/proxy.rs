//! The proxy outside the sandbox: one resolution per request, no TLS termination, and a policy per instance (Task 10).
//!
//! One proxy per job, listening on every session socket of that job ([`ProxyHandle::listen`], each with a tag), with
//! one policy they share. Under [`Policy::Allowlist`] (the provider proxy) it answers `CONNECT host:port` only, to exact
//! listed targets. Under [`Policy::Web`] (a browser session's web proxy) it judges by `net::policy` and also forwards
//! plain-HTTP absolute-form requests in origin-form. An allowed target's bytes are spliced both ways as they are.
//! Everything else is refused, and the caller hears of it through [`ProxyEvent`]. See docs/develop/gleipnir.md, "The
//! proxy".

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinSet};

use super::host::{Host, Target, TargetError, is_public, parse_target};
use super::policy::{
    Class, HostAddrs, Judgement, NeverSet, Pre, PrivateGrant, WebCtx, judge, pre_resolve,
};

/// Which rules a proxy runs.
#[derive(Debug, Clone, Default)]
pub enum Policy {
    /// Exact `host:port` entries ([`ProxyConfig::allow`], [`ProxyConfig::pinned`]), CONNECT only: the provider
    /// proxy, as it always was.
    #[default]
    Allowlist,
    /// The web policy (`net::policy`) on the state the caller keeps changing; CONNECT and plain-HTTP absolute-form.
    /// `allow` and `pinned` are not read.
    Web(Arc<WebState>),
}

/// What the web policy is judged on, read afresh at each request; the setters take effect on the next one.
#[derive(Debug, Default)]
pub struct WebState {
    web: AtomicBool,
    /// Public `host:port`s open while `web` is off (a `browser.web` once grant names one), each until it expires.
    web_hosts: RwLock<Vec<(Target, Option<f64>)>>,
    grants: RwLock<Vec<PrivateGrant>>,
    deny_hosts: RwLock<Vec<String>>,
    host_addrs: Arc<RwLock<HostAddrs>>,
    never: Arc<RwLock<NeverSet>>,
}

impl WebState {
    /// `browser.web` off, no grants, no deny list; the host's addresses and the hub's endpoints are the caller's,
    /// shared with every session's state and kept live there.
    pub fn new(host_addrs: Arc<RwLock<HostAddrs>>, never: Arc<RwLock<NeverSet>>) -> Self {
        WebState {
            host_addrs,
            never,
            ..WebState::default()
        }
    }

    /// Whether `browser.web` is granted.
    pub fn set_web(&self, on: bool) {
        self.web.store(on, Ordering::SeqCst);
    }

    /// Public targets judged as if `browser.web` were granted while it is not, each exactly (`host:port`) until its
    /// expiry (Unix seconds; `None`: until replaced), replacing the last list. Everything else the web policy says
    /// still holds for them (ports 80 and 443, the hard nevers, the deny list).
    pub fn set_web_hosts(&self, hosts: Vec<(Target, Option<f64>)>) {
        *write(&self.web_hosts) = hosts;
    }

    /// The live `browser.private` grants, replacing the last list.
    pub fn set_grants(&self, grants: Vec<PrivateGrant>) {
        *write(&self.grants) = grants;
    }

    /// The user's deny list (`agents-browser-deny-hosts`), replacing the last one.
    pub fn set_deny_hosts(&self, hosts: Vec<String>) {
        *write(&self.deny_hosts) = hosts;
    }

    /// Whether public targets are open now: `browser.web`, else `target` alone through a live web host.
    fn web_for(&self, target: &Target, now: f64) -> bool {
        self.web.load(Ordering::SeqCst)
            || read(&self.web_hosts)
                .iter()
                .any(|(t, e)| t == target && e.is_none_or(|e| now < e))
    }

    /// `f` on a context of the state as it is now for `target` (Unix seconds for `now`). No lock is held past `f`.
    fn with_ctx<R>(&self, target: &Target, f: impl FnOnce(&WebCtx) -> R) -> R {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let web = self.web_for(target, now);
        let (grants, deny) = (read(&self.grants), read(&self.deny_hosts));
        let (host_addrs, never) = (read(&self.host_addrs), read(&self.never));
        f(&WebCtx {
            web,
            deny_hosts: &deny,
            grants: &grants,
            now,
            host_addrs: &host_addrs,
            never: &never,
        })
    }
}

/// A poisoned lock still holds a whole value here (each is replaced in one assignment), so it is used as it is.
fn read<T>(l: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    l.read().unwrap_or_else(|e| e.into_inner())
}
fn write<T>(l: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    l.write().unwrap_or_else(|e| e.into_inner())
}

/// What a proxy allows and how much it takes.
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    /// The rules; [`Policy::Allowlist`] by default.
    pub policy: Policy,
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
            policy: Policy::Allowlist,
            allow: Vec::new(),
            pinned: Vec::new(),
            max_head: 8192,
            head_timeout: Duration::from_secs(10),
            max_conns: 64,
        }
    }
}

/// What the proxy refused or reached, each said at most once per target (or host) per tag. The tag names the
/// listener, so the session.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ProxyEvent {
    /// [`Policy::Allowlist`]: a well-formed public target that is not on the allowlist: the caller may ask the user.
    Denied { tag: u64, target: Target },
    /// A request that is never offered: `target` is the normal form for a well-formed target, else the request's
    /// target with every byte outside printable ASCII escaped (at most 256 bytes of it; empty when there was none).
    Refused {
        tag: u64,
        target: String,
        why: RefuseWhy,
    },
    /// [`Policy::Web`]: a public target while `browser.web` is not granted (the card's question).
    WebOff { tag: u64, target: Target },
    /// [`Policy::Web`]: a private target no grant opens (the card's question): what was asked, and where it leads.
    Private {
        tag: u64,
        asked: Target,
        addr: SocketAddr,
        class: Class,
    },
    /// [`Policy::Web`]: a host connected to, once per host: its name or its address, without the port.
    Reached { tag: u64, host: String },
}

impl ProxyEvent {
    /// The listener's tag.
    pub fn tag(&self) -> u64 {
        match self {
            ProxyEvent::Denied { tag, .. }
            | ProxyEvent::Refused { tag, .. }
            | ProxyEvent::WebOff { tag, .. }
            | ProxyEvent::Private { tag, .. }
            | ProxyEvent::Reached { tag, .. } => *tag,
        }
    }
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
    /// The web policy: a hard never (a metadata address or name, `0/8`, `::`, multicast, broadcast, `240/4`, another
    /// reserved range, a hub endpoint), under any grant.
    Never,
    /// The web policy: a public target on a port other than 80 and 443.
    Port,
    /// The web policy: an IPv6 address that carries a private IPv4 one (mapped, NAT64, 6to4, …).
    Embedded,
    /// The web policy: a loopback spelling or one of the host's own addresses, which only `host.drgnx.internal`
    /// reaches.
    Loopback,
    /// The web policy: on the user's deny list.
    DenyListed,
    /// The web policy: a name whose private answer a grant covers, but no grant names the name (DNS rebinding).
    Rebound,
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
pub type Connect = Arc<dyn Fn(SocketAddr) -> Connecting + Send + Sync>;
/// An upstream connection being opened.
pub type Connecting = Pin<Box<dyn Future<Output = io::Result<TcpStream>> + Send>>;

fn tcp_connect(a: SocketAddr) -> Connecting {
    Box::pin(TcpStream::connect(a))
}

/// What every listener of one proxy shares.
struct Shared {
    policy: Policy,
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

/// [`start`] with the upstream connections opened by `connect` (the escape fixture redirects "public" addresses).
#[cfg(any(feature = "test-hooks", feature = "escape-fixture"))]
pub fn start_for_tests(
    cfg: ProxyConfig,
    resolver: Arc<dyn Resolver>,
    events: mpsc::Sender<ProxyEvent>,
    connect: Connect,
) -> ProxyHandle {
    start_with(cfg, resolver, events, connect)
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
            policy: cfg.policy,
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
        lock(&self.shared.said).retain(|e| e.tag() != tag);
    }

    /// Lets the questions of `tag` (its `WebOff` and `Private` events) be said again: the caller's answer changed
    /// (a card settled, a grant ended), so the next refusal of a target asks anew. The other events stay said once.
    pub fn forget_questions(&self, tag: u64) {
        lock(&self.shared.said).retain(|e| {
            e.tag() != tag || !matches!(e, ProxyEvent::WebOff { .. } | ProxyEvent::Private { .. })
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

/// A plain-HTTP request in absolute-form, as the web policy forwards it.
pub(crate) struct Absolute<'a> {
    method: &'a [u8],
    /// The target's text: the URI's `host[:port]`, with `:80` added when it names no port.
    target: Vec<u8>,
    /// The origin-form request target: the URI's path and query, `/` when it has no path.
    path: Vec<u8>,
    version: &'a [u8],
    /// The header lines that go upstream, each without its CRLF.
    kept: Vec<&'a [u8]>,
}

/// An HTTP token character (RFC 9110 §5.6.2).
fn tchar(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&c)
}

/// `b` split at each CRLF.
fn crlf_lines(mut b: &[u8]) -> Vec<&[u8]> {
    let mut lines = Vec::new();
    while let Some(i) = b.windows(2).position(|w| w == b"\r\n") {
        lines.push(&b[..i]);
        b = &b[i + 2..];
    }
    lines.push(b);
    lines
}

/// `head` (the bytes before the blank line) as `METHOD http://HOST[:PORT][/PATH] HTTP/1.x`, one space each, and its
/// header lines. `None` for anything else: another scheme (`https://` among them), userinfo, a fragment, an obsolete
/// line folding, a bare CR or LF, a NUL, a byte outside printable ASCII in the request target, a header line that is
/// not `name: value`. The received `Host`, `Connection` and every name it lists, `Keep-Alive`, `TE`, `Upgrade` and
/// `Proxy-*` are not kept.
pub(crate) fn absolute_request(head: &[u8]) -> Option<Absolute<'_>> {
    let lines = crlf_lines(head);
    if lines
        .iter()
        .any(|l| l.iter().any(|&c| matches!(c, b'\r' | b'\n' | 0)))
    {
        return None;
    }
    let parts: Vec<&[u8]> = lines[0].split(|&c| c == b' ').collect();
    let &[method, uri, version] = parts.as_slice() else {
        return None;
    };
    if method.is_empty()
        || !method.iter().all(|&c| tchar(c))
        || !matches!(version, b"HTTP/1.1" | b"HTTP/1.0")
    {
        return None;
    }
    let rest = uri
        .get(..7)
        .filter(|s| s.eq_ignore_ascii_case(b"http://"))
        .map(|_| &uri[7..])?;
    if rest.contains(&b'#') || !rest.iter().all(|c| (0x21..=0x7e).contains(c)) {
        return None;
    }
    let cut = rest
        .iter()
        .position(|&c| c == b'/' || c == b'?')
        .unwrap_or(rest.len());
    let (authority, path) = rest.split_at(cut);
    if authority.is_empty() || authority.contains(&b'@') {
        return None;
    }
    let after_v6 = authority
        .iter()
        .rposition(|&c| c == b']')
        .map_or(authority, |i| &authority[i + 1..]);
    let mut target = authority.to_vec();
    if !after_v6.contains(&b':') {
        target.extend_from_slice(b":80");
    }
    let path = match path.first() {
        None => b"/".to_vec(),
        Some(b'?') => [&b"/"[..], path].concat(),
        Some(_) => path.to_vec(),
    };

    let mut named: Vec<(Vec<u8>, &[u8])> = Vec::new();
    for line in &lines[1..] {
        let colon = line.iter().position(|&c| c == b':')?;
        let name = &line[..colon];
        if name.is_empty() || !name.iter().all(|&c| tchar(c)) {
            return None;
        }
        named.push((name.to_ascii_lowercase(), line));
    }
    let listed: HashSet<Vec<u8>> = named
        .iter()
        .filter(|(n, _)| n == b"connection")
        .flat_map(|(_, line)| line[b"connection:".len()..].split(|&c| c == b','))
        .map(|t| t.trim_ascii().to_ascii_lowercase())
        .filter(|t| !t.is_empty())
        .collect();
    let kept = named
        .into_iter()
        .filter(|(n, _)| {
            !(n.starts_with(b"proxy-")
                || matches!(
                    n.as_slice(),
                    b"host" | b"connection" | b"keep-alive" | b"te" | b"upgrade"
                )
                || listed.contains(n))
        })
        .map(|(_, line)| line)
        .collect();
    Some(Absolute {
        method,
        target,
        path,
        version,
        kept,
    })
}

/// The head that goes upstream: origin-form, `Host` from the target (without the port when it is 80), the kept
/// headers in their order, `Connection: close`, the blank line.
fn rewrite(a: &Absolute, target: &Target) -> Vec<u8> {
    let host = match (&target.host, target.port) {
        (Host::Name(n), 80) => n.clone(),
        (Host::V4(v4), 80) => v4.to_string(),
        (Host::V6(v6), 80) => format!("[{v6}]"),
        _ => target.to_string(),
    };
    let mut out = Vec::with_capacity(256);
    let line: [&[u8]; 8] = [
        a.method,
        b" ",
        &a.path,
        b" ",
        a.version,
        b"\r\nHost: ",
        host.as_bytes(),
        b"\r\n",
    ];
    for part in line {
        out.extend_from_slice(part);
    }
    for line in &a.kept {
        out.extend_from_slice(line);
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(b"Connection: close\r\n\r\n");
    out
}

/// For the `absolute_head` fuzz target: the head's end as [`read_head`] finds it, [`absolute_request`], the target
/// through `parse_target`, then the rewritten head.
#[cfg(feature = "fuzzing")]
pub fn fuzz_absolute_head(buf: &[u8]) -> Option<Vec<u8>> {
    let end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    let a = absolute_request(&buf[..end])?;
    let target = parse_target(std::str::from_utf8(&a.target).ok()?).ok()?;
    Some(rewrite(&a, &target))
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
    let head = &buf[..end];
    // `CONNECT target`, or under the web policy a plain-HTTP absolute-form request
    let connect = connect_request(head);
    let absolute = match (connect, &sh.policy) {
        (None, Policy::Web(_)) => absolute_request(head),
        _ => None,
    };
    let raw: &[u8] = match (&absolute, connect) {
        (Some(a), _) => &a.target,
        (None, Some(r)) if !r.is_empty() => r,
        _ => {
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

    let addrs = match &sh.policy {
        Policy::Allowlist => allowlisted(&sh, tag, &target).await,
        Policy::Web(w) => web(&sh, w, tag, &target).await,
    };
    let addrs = match addrs {
        Ok(a) => a,
        Err(s) => return stop(&sh, client, s).await,
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
    if let Policy::Web(_) = sh.policy {
        let host = match &target.host {
            Host::Name(n) => n.clone(),
            Host::V4(a) => a.to_string(),
            Host::V6(a) => a.to_string(),
        };
        say(&sh, ProxyEvent::Reached { tag, host }).await;
    }
    // CONNECT: the 200 to the client; absolute-form: the rewritten head to the upstream. Then the early bytes.
    let started = match &absolute {
        None => client
            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
            .await
            .is_ok(),
        Some(a) => upstream.write_all(&rewrite(a, &target)).await.is_ok(),
    };
    if !started || upstream.write_all(early).await.is_err() {
        return;
    }
    // both ways as they are; each side's EOF is passed on as a half-close
    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
}

/// How a request ends without an upstream.
enum Stop {
    /// Say the event (once), then answer the status.
    Say(ProxyEvent, &'static str),
    /// Answer the status only.
    Answer(&'static str),
}

async fn stop(sh: &Shared, client: Box<dyn Client>, s: Stop) {
    match s {
        Stop::Say(event, status) => {
            say(sh, event).await;
            answer(client, status).await;
        }
        Stop::Answer(status) => answer(client, status).await,
    }
}

/// [`Policy::Allowlist`]: where to connect, decided once: the literal, the pin, or the public part of one DNS answer,
/// always on the target's port. Nothing is resolved again.
async fn allowlisted(sh: &Shared, tag: u64, target: &Target) -> Result<Vec<SocketAddr>, Stop> {
    let private = || {
        let target = target.to_string();
        let why = RefuseWhy::Private;
        Stop::Say(ProxyEvent::Refused { tag, target, why }, FORBIDDEN)
    };
    // An address that is not public is never reached as a literal, listed or not, and never offered on a card.
    let literal = match target.host {
        Host::V4(a) => Some(IpAddr::V4(a)),
        Host::V6(a) => Some(IpAddr::V6(a)),
        Host::Name(_) => None,
    };
    if literal.is_some_and(|ip| !is_public(ip)) {
        return Err(private());
    }
    if !lock(&sh.allow).contains(target) {
        let target = target.clone();
        return Err(Stop::Say(ProxyEvent::Denied { tag, target }, FORBIDDEN));
    }
    let Host::Name(name) = &target.host else {
        return Ok(literal
            .map(|ip| SocketAddr::new(ip, target.port))
            .into_iter()
            .collect());
    };
    if let Some((_, ip)) = sh.pinned.iter().find(|(n, _)| n == name) {
        return Ok(vec![SocketAddr::new(*ip, target.port)]);
    }
    let all = match sh.resolver.resolve(name, target.port).await {
        Ok(all) if !all.is_empty() => all,
        _ => return Err(Stop::Answer(BAD_GATEWAY)),
    };
    let public: Vec<SocketAddr> = all
        .iter()
        .filter(|a| is_public(a.ip()))
        .map(|a| SocketAddr::new(a.ip(), target.port))
        .collect();
    if public.is_empty() {
        return Err(private());
    }
    Ok(public)
}

/// [`Policy::Web`]: `pre_resolve`, one DNS question for a name, then `judge` on the state as it is now. The answer
/// judged is the one connected to.
async fn web(
    sh: &Shared,
    w: &WebState,
    tag: u64,
    target: &Target,
) -> Result<Vec<SocketAddr>, Stop> {
    let refused = |why| {
        let target = target.to_string();
        Stop::Say(ProxyEvent::Refused { tag, target, why }, FORBIDDEN)
    };
    let answer = match w.with_ctx(target, |ctx| pre_resolve(target, ctx)) {
        Pre::Refuse(why) => return Err(refused(why)),
        Pre::Fixed(addrs) => addrs,
        Pre::Resolve => {
            let Host::Name(name) = &target.host else {
                return Err(Stop::Answer(BAD_GATEWAY));
            };
            match sh.resolver.resolve(name, target.port).await {
                Ok(all) if !all.is_empty() => all,
                _ => return Err(Stop::Answer(BAD_GATEWAY)),
            }
        }
    };
    match w.with_ctx(target, |ctx| judge(target, &answer, ctx)) {
        Judgement::Connect(addrs) if !addrs.is_empty() => Ok(addrs),
        Judgement::Connect(_) => Err(Stop::Answer(BAD_GATEWAY)),
        Judgement::WebOff => {
            let target = target.clone();
            Err(Stop::Say(ProxyEvent::WebOff { tag, target }, FORBIDDEN))
        }
        Judgement::Private { addr, class } => {
            let asked = target.clone();
            let event = ProxyEvent::Private {
                tag,
                asked,
                addr,
                class,
            };
            Err(Stop::Say(event, FORBIDDEN))
        }
        Judgement::Refuse(why) => Err(refused(why)),
    }
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
        // a socket bound but never listening: a connection to it is refused, and the port stays held for the test (a
        // dropped listener's port went back to the kernel, which could hand it to another test's listener: 200)
        let held = tokio::net::TcpSocket::new_v4().unwrap();
        held.bind(SocketAddr::new(IpAddr::V4(LOOP), 0)).unwrap();
        let closed_port = held.local_addr().unwrap();
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
        let (mut s, code) = ask(&p, b"CONNECT up.test:443 HTTP/1.1\r\nHost: up").await;
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
    }

    /// The refusal waits out the head timeout: a timing test (the elapsed time is the assertion).
    #[tokio::test]
    #[ignore = "timing: a slow head is refused only after the head timeout"]
    async fn slow_head_is_refused_only_after_the_head_timeout() {
        let cfg = ProxyConfig {
            head_timeout: Duration::from_millis(300),
            ..ProxyConfig::default()
        };
        let r = rig(cfg, &[], &[]);
        let p = r.listen(1);
        let started = std::time::Instant::now();
        let (_s, code) = ask(&p, b"CONNECT up.test:443 HTTP/1.1\r\nHost: up").await;
        assert_eq!(code, 400);
        assert!(started.elapsed() >= Duration::from_millis(300));
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
        let target = format!("up.test:{}", up.port());
        skuld::wait_until_async("the slots come back", WAIT.as_secs(), || {
            let (p, target) = (&p, &target);
            async move {
                let (_s, code) = connect_to(p, target).await;
                (code == 200).then_some(())
            }
        })
        .await;
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
        skuld::wait_until_async("tag 1 stops accepting", WAIT.as_secs(), || {
            let p1 = &p1;
            async move { UnixStream::connect(p1).await.is_err().then_some(()) }
        })
        .await;

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

    use crate::net::policy::PrivateTarget;

    fn web_on() -> Arc<WebState> {
        let w = Arc::new(WebState::default());
        w.set_web(true);
        w
    }

    fn web_cfg(w: &Arc<WebState>) -> ProxyConfig {
        ProxyConfig {
            policy: Policy::Web(w.clone()),
            ..ProxyConfig::default()
        }
    }

    fn reached(tag: u64, host: &str) -> ProxyEvent {
        ProxyEvent::Reached {
            tag,
            host: host.into(),
        }
    }

    /// Sends `bytes` in one write, half-closes, and reads everything back.
    async fn send_all(path: &Path, bytes: &[u8]) -> Vec<u8> {
        let mut s = UnixStream::connect(path).await.unwrap();
        s.write_all(bytes).await.unwrap();
        s.shutdown().await.unwrap();
        let mut back = Vec::new();
        timeout(WAIT, s.read_to_end(&mut back))
            .await
            .unwrap()
            .unwrap();
        back
    }

    #[tokio::test]
    async fn absolute_form_is_rewritten() {
        let answer =
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok".to_vec();
        let (up1, got1) = recorder(answer.clone()).await;
        let (up2, got2) = recorder(answer.clone()).await;
        let pub1 = SocketAddr::new(IpAddr::V4(PUBLIC), 80);
        let pub2 = SocketAddr::new("2606:4700::1".parse().unwrap(), 80);
        let w = web_on();
        let mut r = rig(
            web_cfg(&w),
            &[(
                "web.test",
                vec![vec![SocketAddr::new(IpAddr::V4(PUBLIC), 0)]],
            )],
            &[(pub1, up1), (pub2, up2)],
        );
        let p = r.listen(4);

        let req = "GET http://WEB.test/a/b?c=1 HTTP/1.1\r\nHost: evil.test\r\n\
                   Proxy-Authorization: Basic eA==\r\nProxy-Connection: keep-alive\r\n\
                   Connection: keep-alive, X-Secret\r\nX-Secret: 1\r\nKeep-Alive: 300\r\nTE: trailers\r\n\
                   Upgrade: h2c\r\nAccept: */*\r\nuser-agent: t\r\n\r\n";
        assert_eq!(
            send_all(&p, req.as_bytes()).await,
            answer,
            "the response head is not rewritten"
        );
        assert_eq!(
            String::from_utf8(got1.await.unwrap()).unwrap(),
            "GET /a/b?c=1 HTTP/1.1\r\nHost: web.test\r\nAccept: */*\r\nuser-agent: t\r\nConnection: close\r\n\r\n"
        );

        // a literal with no path, a query only, HTTP/1.0
        let req = "HEAD http://[2606:4700::1]?q HTTP/1.0\r\n\r\n";
        assert_eq!(send_all(&p, req.as_bytes()).await, answer);
        assert_eq!(
            String::from_utf8(got2.await.unwrap()).unwrap(),
            "HEAD /?q HTTP/1.0\r\nHost: [2606:4700::1]\r\nConnection: close\r\n\r\n"
        );
        assert_eq!(
            r.said(),
            vec![reached(4, "web.test"), reached(4, "2606:4700::1")]
        );
        assert_eq!(r.attempts(), vec![pub1, pub2]);
    }

    #[tokio::test]
    async fn absolute_form_early_body_reaches_upstream_once() {
        let (up, got) = recorder(b"HTTP/1.1 204 No Content\r\n\r\n".to_vec()).await;
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 80);
        let w = web_on();
        let r = rig(
            web_cfg(&w),
            &[("post.test", vec![vec![public]])],
            &[(public, up)],
        );
        let p = r.listen(1);
        // 3 KiB of body that looks like nothing in particular, then a second request hidden in it
        let mut body: Vec<u8> = (0u8..=255).cycle().take(3072).collect();
        body.extend_from_slice(
            b"\r\n\r\nGET http://other.test/ HTTP/1.1\r\nHost: other.test\r\n\r\n",
        );
        let later: Vec<u8> = (0u8..=255).rev().cycle().take(5000).collect();
        let length = body.len() + later.len();
        let mut first =
            format!("POST http://post.test/form HTTP/1.1\r\nContent-Length: {length}\r\n\r\n")
                .into_bytes();
        first.extend_from_slice(&body);

        let mut s = UnixStream::connect(&p).await.unwrap();
        // one write, so the body comes in the same read as the head
        s.write_all(&first).await.unwrap();
        s.write_all(&later).await.unwrap();
        s.shutdown().await.unwrap();
        let mut back = Vec::new();
        timeout(WAIT, s.read_to_end(&mut back))
            .await
            .unwrap()
            .unwrap();

        let mut want = format!(
            "POST /form HTTP/1.1\r\nHost: post.test\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        )
        .into_bytes();
        want.extend_from_slice(&body);
        want.extend_from_slice(&later);
        assert!(
            got.await.unwrap() == want,
            "the upstream gets the head, then the body once, in order"
        );
        assert_eq!(back, b"HTTP/1.1 204 No Content\r\n\r\n");
        assert_eq!(r.attempts(), vec![public]);
    }

    #[tokio::test]
    async fn https_absolute_and_userinfo_are_400() {
        let up = echo().await;
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 80);
        let w = web_on();
        let mut r = rig(
            web_cfg(&w),
            &[("web.test", vec![vec![public]])],
            &[(public, up)],
        );
        let p = r.listen(9);
        let rows: &[&[u8]] = &[
            b"GET https://web.test/ HTTP/1.1\r\n\r\n",
            b"GET HTTPS://web.test/ HTTP/1.1\r\n\r\n",
            b"GET http://user:pw@web.test/ HTTP/1.1\r\n\r\n",
            b"GET http://user@web.test/ HTTP/1.1\r\n\r\n",
            b"GET ftp://web.test/ HTTP/1.1\r\n\r\n",
            b"GET http://web.test/#top HTTP/1.1\r\n\r\n",
            b"GET http:///x HTTP/1.1\r\n\r\n",
            b"GET http://web.test/ HTTP/2.0\r\n\r\n",
            b"GET  http://web.test/ HTTP/1.1\r\n\r\n",
            b"G(T http://web.test/ HTTP/1.1\r\n\r\n",
            b"GET http://web.test/\x01 HTTP/1.1\r\n\r\n",
            b"GET /origin-form HTTP/1.1\r\nHost: web.test\r\n\r\n",
            b"GET http://web.test/ HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n",
            b"GET http://web.test/ HTTP/1.1\r\nNo-Colon\r\n\r\n",
            b"GET http://web.test/ HTTP/1.1\r\nBad Name: x\r\n\r\n",
            b"GET http://web.test/ HTTP/1.1\r\nX-A: 1\nHost: evil.test\r\n\r\n",
            b"GET http://web.test/ HTTP/1.1\r\nX-A: \0\r\n\r\n",
        ];
        for req in rows {
            let (mut s, code) = ask(&p, req).await;
            assert_eq!(code, 400, "{:?}", String::from_utf8_lossy(req));
            assert!(closed(&mut s).await);
        }
        // a malformed authority is the target's error, said with its text
        let (_s, code) = ask(&p, b"GET http://web.test:/ HTTP/1.1\r\n\r\n").await;
        assert_eq!(code, 400);
        assert_eq!(
            r.said(),
            vec![
                ProxyEvent::Refused {
                    tag: 9,
                    target: String::new(),
                    why: RefuseWhy::BadRequest
                },
                ProxyEvent::Refused {
                    tag: 9,
                    target: "web.test:".into(),
                    why: RefuseWhy::BadRequest
                },
            ]
        );
        assert!(r.attempts().is_empty());
        assert_eq!(r.resolver.calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn allowlist_policy_is_unchanged() {
        assert!(matches!(ProxyConfig::default().policy, Policy::Allowlist));
        let up = echo().await;
        let cfg = ProxyConfig {
            policy: Policy::Allowlist,
            ..pinned_up(up.port())
        };
        let mut r = rig(cfg, &[], &[]);
        let p = r.listen(1);
        let (mut s, code) = connect_to(&p, &format!("up.test:{}", up.port())).await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"listed").await);
        for (target, want) in [
            ("x.test:443", 403),
            ("192.168.1.20:80", 403),
            ("169.254.169.254:80", 403),
        ] {
            let (_s, code) = connect_to(&p, target).await;
            assert_eq!(code, want, "{target}");
        }
        let (mut s, code) = ask(
            &p,
            format!("GET http://up.test:{}/ HTTP/1.1\r\n\r\n", up.port()).as_bytes(),
        )
        .await;
        assert_eq!(code, 400, "absolute-form stays refused");
        assert!(closed(&mut s).await);
        assert_eq!(
            r.said(),
            vec![
                ProxyEvent::Denied {
                    tag: 1,
                    target: t("x.test:443")
                },
                ProxyEvent::Refused {
                    tag: 1,
                    target: "192.168.1.20:80".into(),
                    why: RefuseWhy::Private
                },
                ProxyEvent::Refused {
                    tag: 1,
                    target: "169.254.169.254:80".into(),
                    why: RefuseWhy::Private
                },
                ProxyEvent::Refused {
                    tag: 1,
                    target: String::new(),
                    why: RefuseWhy::BadRequest
                },
            ],
            "no Reached, no WebOff: the allowlist's own events"
        );
        assert_eq!(r.attempts(), vec![up]);
    }

    #[tokio::test]
    async fn web_off_says_weboff_once_per_target() {
        let up = echo().await;
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 443);
        let any_port = SocketAddr::new(IpAddr::V4(PUBLIC), 0);
        let w = Arc::new(WebState::default());
        let mut r = rig(
            web_cfg(&w),
            &[
                ("web.test", vec![vec![any_port]]),
                ("other.test", vec![vec![any_port]]),
            ],
            &[(public, up)],
        );
        let p = r.listen(2);
        for target in [
            "web.test:443",
            "web.test:443",
            "other.test:443",
            "WEB.test.:443",
        ] {
            let (mut s, code) = connect_to(&p, target).await;
            assert_eq!(code, 403, "{target}");
            assert!(closed(&mut s).await);
        }
        let (_s, code) = ask(&p, b"GET http://web.test/ HTTP/1.1\r\n\r\n").await;
        assert_eq!(code, 403);
        let weboff = |target: &str| ProxyEvent::WebOff {
            tag: 2,
            target: t(target),
        };
        assert_eq!(
            r.said(),
            vec![
                weboff("web.test:443"),
                weboff("other.test:443"),
                weboff("web.test:80")
            ]
        );
        assert!(r.attempts().is_empty());

        w.set_web(true);
        let (mut s, code) = connect_to(&p, "web.test:443").await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"now").await);
        assert_eq!(r.said(), vec![reached(2, "web.test")]);
        assert_eq!(r.attempts(), vec![public]);
    }

    #[tokio::test]
    async fn a_web_host_opens_only_itself_and_forgotten_questions_are_asked_again() {
        let up = echo().await;
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 443);
        let any_port = SocketAddr::new(IpAddr::V4(PUBLIC), 0);
        let w = Arc::new(WebState::default());
        let mut r = rig(
            web_cfg(&w),
            &[
                ("web.test", vec![vec![any_port]]),
                ("other.test", vec![vec![any_port]]),
                ("old.test", vec![vec![any_port]]),
            ],
            &[(public, up)],
        );
        let p = r.listen(2);
        // a once grant opens its host:port alone, until it expires
        w.set_web_hosts(vec![
            (t("web.test:443"), None),
            (t("old.test:443"), Some(1.0)),
        ]);
        let (mut s, code) = connect_to(&p, "web.test:443").await;
        assert_eq!(code, 200);
        assert!(echoes(&mut s, b"one").await);
        for target in ["web.test:80", "other.test:443", "old.test:443"] {
            let (_s, code) = connect_to(&p, target).await;
            assert_eq!(code, 403, "{target}");
        }
        let weboff = |target: &str| ProxyEvent::WebOff {
            tag: 2,
            target: t(target),
        };
        assert_eq!(
            r.said(),
            vec![
                reached(2, "web.test"),
                weboff("web.test:80"),
                weboff("other.test:443"),
                weboff("old.test:443")
            ]
        );
        // said once, until the caller forgets the questions; what was reached stays said
        let (_s, code) = connect_to(&p, "other.test:443").await;
        assert_eq!(code, 403);
        assert!(r.said().is_empty());
        r.handle.forget_questions(2);
        r.handle.forget_questions(7);
        for target in ["other.test:443", "web.test:443"] {
            let _ = connect_to(&p, target).await;
        }
        assert_eq!(r.said(), vec![weboff("other.test:443")]);
    }

    #[tokio::test]
    async fn grant_set_at_runtime_takes_effect_on_next_request() {
        let up = echo().await;
        let lan: SocketAddr = "192.168.1.20:8080".parse().unwrap();
        let host_addrs = Arc::new(RwLock::new(HostAddrs::default()));
        let w = Arc::new(WebState::new(
            host_addrs.clone(),
            Arc::new(RwLock::new(NeverSet::default())),
        ));
        let mut r = rig(web_cfg(&w), &[("evil.test", vec![vec![lan]])], &[(lan, up)]);
        let p = r.listen(3);
        let refused = |target: &str, why| ProxyEvent::Refused {
            tag: 3,
            target: target.into(),
            why,
        };
        let grant = |expires| PrivateGrant {
            target: PrivateTarget::HostPort(t("192.168.1.20:8080")),
            expires,
        };

        // no grant: the card's question, with the address
        let (_s, code) = connect_to(&p, "192.168.1.20:8080").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![ProxyEvent::Private {
                tag: 3,
                asked: t("192.168.1.20:8080"),
                addr: lan,
                class: Class::Lan
            }]
        );

        // granted: the next request goes through
        w.set_grants(vec![grant(None)]);
        let (mut a, code) = connect_to(&p, "192.168.1.20:8080").await;
        assert_eq!(code, 200);
        assert!(echoes(&mut a, b"granted").await);
        assert_eq!(r.said(), vec![reached(3, "192.168.1.20")]);

        // a name rebound onto the grant is refused
        let (_s, code) = connect_to(&p, "evil.test:8080").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![refused("evil.test:8080", RefuseWhy::Rebound)]
        );

        // the host's addresses and the deny list are read at each request
        host_addrs.write().unwrap().0.insert(lan.ip());
        let (_s, code) = connect_to(&p, "192.168.1.20:8080").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![refused("192.168.1.20:8080", RefuseWhy::Loopback)]
        );
        host_addrs.write().unwrap().0.clear();
        w.set_deny_hosts(vec!["192.168.1.20".into()]);
        let (_s, code) = connect_to(&p, "192.168.1.20:8080").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![refused("192.168.1.20:8080", RefuseWhy::DenyListed)]
        );
        w.set_deny_hosts(Vec::new());

        // expired: refused again (the question was said already); the tunnel spliced before stays
        w.set_grants(vec![grant(Some(1.0))]);
        let (_s, code) = connect_to(&p, "192.168.1.20:8080").await;
        assert_eq!(code, 403);
        assert!(r.said().is_empty());
        assert!(echoes(&mut a, b"stays").await);
        assert_eq!(r.attempts(), vec![lan]);
    }

    #[tokio::test]
    async fn connect_to_80_for_websockets() {
        let up = echo().await;
        let public = SocketAddr::new(IpAddr::V4(PUBLIC), 80);
        let w = web_on();
        let mut r = rig(
            web_cfg(&w),
            &[("ws.test", vec![vec![public]])],
            &[(public, up)],
        );
        let p = r.listen(1);
        let (mut s, code) = ask(
            &p,
            b"CONNECT ws.test:80 HTTP/1.1\r\nHost: ws.test:80\r\n\r\n",
        )
        .await;
        assert_eq!(code, 200);
        assert!(
            echoes(
                &mut s,
                b"GET /socket HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n"
            )
            .await,
            "the tunnel carries the upgrade as it is"
        );
        let (_s, code) = connect_to(&p, "ws.test:8080").await;
        assert_eq!(code, 403);
        assert_eq!(
            r.said(),
            vec![
                reached(1, "ws.test"),
                ProxyEvent::Refused {
                    tag: 1,
                    target: "ws.test:8080".into(),
                    why: RefuseWhy::Port
                }
            ]
        );
        assert_eq!(r.attempts(), vec![public]);
    }
}
