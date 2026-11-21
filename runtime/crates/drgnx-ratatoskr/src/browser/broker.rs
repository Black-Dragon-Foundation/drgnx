//! The hub's CDP broker on a session's `cdp.sock` (docs/develop/hub.md, "The CDP broker"): the agent's websocket on
//! one side, the browser host's socketpair on the other, `heimdall::Router` between them.
//!
//! - **The endpoint** is a capability URL: `GET /devtools/browser/<64 hex>` with a websocket upgrade, from a peer of
//!   the hub's own uid. The secret is compared in constant time; anything else is 404 with no body. Logs name the
//!   endpoint `cdp://SID`, never the path.
//! - **Before the upgrade** the matrix's gate is asked: `Allow` upgrades, `Ask(n)` is 403 "waiting for the user's yes:
//!   card N", `Never(why)` is 403 with WHY. One agent websocket at a time: a second is 409.
//! - **The browser** starts at the first upgrade while it is stopped (`{"op":"start"}` to the host), and the agent's
//!   messages are held until it has started and the router is ready.
//! - **Stops:** no agent for `idle` stops it (`idle`); [`BrokerHandle::stop`] stops it with a reason (`memory` closes
//!   the agent's websocket with 1001 and the memory text). Each stop is a `BrokerEvent::Stopped`. The next upgrade
//!   starts a fresh one.
//! - **Chromium's own end** (`exited`) closes the agent's websocket with 1011 "the browser exited (…)".
//! - **The host's end** (EOF on the socketpair) ends the broker's browser for good: new upgrades get 503. A broker
//!   made by [`start_after_restart`] has no host at all and says so for the hub's restart.
//!
//! One task (the actor) owns the router and the state; the accept loop, each connection, and the host's reader and
//! writer are tasks of their own that talk to it over channels.

use std::convert::Infallible;
use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use fastwebsockets::{FragmentCollectorRead, Frame, OpCode, Payload};
use heimdall::codec::{self, FrameDecoder, KIND_CDP, KIND_CONTROL};
use heimdall::{BrokerEvent, Router, Step};
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use mimir::BoxFuture;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::clock;
use crate::conn::peer_allowed;
use crate::matrix_gate::Gate;

/// The matrix's answer for the session's `browser` cell, asked before each upgrade.
pub type GateFn = Arc<dyn Fn() -> BoxFuture<'static, Gate> + Send + Sync>;

/// A new upgrade after the hub restarted: the socketpair died with the old hub, and an inherited fd cannot be handed
/// over again.
pub const ENDED_BY_RESTART: &str =
    "the browser ended with the hub's restart; restart the session to get it back";
/// A new upgrade after the browser host ended while the hub ran.
pub const HOST_ENDED: &str = "the browser's host ended; restart the session to get it back";
/// A second agent websocket.
pub const BUSY: &str = "the agent's browser is already connected";
/// The agent's close reason for `stop("memory")`.
pub const MEMORY_STOP: &str = "the browser was stopped: the session is near its memory cap";
/// The path before the secret's hex.
pub const PATH_PREFIX: &str = "/devtools/browser/";

const CLOSE_GOING_AWAY: u16 = 1001;
const CLOSE_POLICY: u16 = 1008;
const CLOSE_TOO_BIG: u16 = 1009;
const CLOSE_ERROR: u16 = 1011;
/// A close frame's reason is at most 123 bytes.
const CLOSE_REASON_MAX: usize = 123;
/// After the broker's close frame, how long the agent has to answer it before the connection is cut.
const CLOSE_WAIT: Duration = Duration::from_secs(1);
/// How long a request head may take.
const HEADER_READ_TIMEOUT: Duration = Duration::from_secs(10);
/// A frame from the host may be this much over the message limit (the host's `FRAME_SLACK`; the host is Linux only).
const FRAME_SLACK: usize = 64;

/// What a broker is made with.
pub struct BrokerCfg {
    /// The session's id (logs say `cdp://SID`).
    pub sid: String,
    /// The capability's 32 random bytes; the URL carries them as lower-case hex.
    pub secret: [u8; 32],
    /// The largest CDP message, either way (`agents-browser-max-message`).
    pub max_message: usize,
    /// How long the browser runs with no agent websocket (`agents-browser-idle`).
    pub idle: Duration,
    /// The session's `browser` cell, asked before each upgrade.
    pub gate: GateFn,
    /// Downloads, a missing browser session and stops. Sent with `try_send`: a full channel loses the event (logged).
    pub events: mpsc::Sender<BrokerEvent>,
    /// The browser's own stderr lines (at most one a second), for the one caller that reads them: the doctor's check.
    pub stderr: Option<mpsc::UnboundedSender<String>>,
}

/// The running broker. Dropping it closes it ([`BrokerHandle::close`]).
pub struct BrokerHandle {
    ctl: mpsc::UnboundedSender<Cmd>,
    connected: Arc<AtomicBool>,
    accept: JoinHandle<()>,
}

impl BrokerHandle {
    /// Stop the browser (`why`: `memory`, or the caller's reason); an agent connected gets a 1001 close. A stopped
    /// browser starts again at the next upgrade.
    pub fn stop(&self, why: &str) {
        let _ = self.ctl.send(Cmd::Stop(why.to_owned()));
    }

    /// End the broker: the browser stopped (`hub`), the agent closed, no more upgrades, and the socketpair closed, so
    /// the browser host exits.
    pub fn close(&self) {
        let _ = self.ctl.send(Cmd::Close);
        self.accept.abort();
    }

    /// An agent websocket is open.
    pub fn connected(&self) -> bool {
        self.connected.load(Ordering::Acquire)
    }
}

impl Drop for BrokerHandle {
    fn drop(&mut self) {
        self.close();
    }
}

/// Serve `listener` (the session's `cdp.sock`) for the browser host at the other end of `host`. Must be called inside
/// a tokio runtime; the broker's tasks run until it is closed.
pub fn start(cfg: BrokerCfg, listener: UnixListener, host: UnixStream) -> BrokerHandle {
    spawn(cfg, listener, Some(host))
}

/// A broker for a session resumed after the hub's restart, whose browser host is gone: every upgrade with the right
/// secret is 503 [`ENDED_BY_RESTART`].
pub fn start_after_restart(cfg: BrokerCfg, listener: UnixListener) -> BrokerHandle {
    spawn(cfg, listener, None)
}

enum Cmd {
    /// May an agent connect (Free), or not (Busy, Ended)? With `reserve`, the slot is the caller's (its generation).
    Claim {
        reserve: bool,
        reply: oneshot::Sender<Claim>,
    },
    /// The upgrade of connection `conn` completed; the actor answers `ack` once it routes to `tx`.
    Agent {
        conn: u64,
        tx: mpsc::Sender<ToAgent>,
        ack: oneshot::Sender<()>,
    },
    AgentGone {
        conn: u64,
    },
    Stop(String),
    Close,
}

enum Claim {
    Free(u64),
    Busy,
    Ended(String),
}

enum ToAgent {
    Text(Vec<u8>),
    /// A frame the websocket owes the agent (a pong, the answer to its close).
    Frame(Frame<'static>),
    Close(u16, String),
}

enum HostEv {
    Cdp(Vec<u8>),
    Control(Value),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum State {
    Stopped,
    Starting,
    Running,
    /// `stop` was sent; `exited` has not come yet.
    Stopping,
    /// The host is gone; the text is the 503's.
    Ended(String),
}

struct Shared {
    sid: String,
    /// `PATH_PREFIX` + the secret's hex: never logged.
    path: String,
    gate: GateFn,
    ctl: mpsc::UnboundedSender<Cmd>,
    data: mpsc::Sender<(u64, Vec<u8>)>,
    max_message: usize,
}

fn spawn(cfg: BrokerCfg, listener: UnixListener, host: Option<UnixStream>) -> BrokerHandle {
    let (ctl, ctl_rx) = mpsc::unbounded_channel();
    let (data, data_rx) = mpsc::channel(32);
    let (host_ev, host_rx) = mpsc::channel(64);
    let connected = Arc::new(AtomicBool::new(false));
    let hex: String = cfg.secret.iter().map(|b| format!("{b:02x}")).collect();
    let (host_tx, state) = match host {
        Some(h) => {
            let (rd, wr) = h.into_split();
            let (tx, rx) = mpsc::channel::<Vec<u8>>(64);
            clock::spawn("browser:host-writer", host_writer(wr, rx));
            clock::spawn(
                "browser:host-reader",
                host_reader(rd, cfg.max_message + FRAME_SLACK, host_ev),
            );
            (Some(tx), State::Stopped)
        }
        None => {
            drop(host_ev);
            (None, State::Ended(ENDED_BY_RESTART.into()))
        }
    };
    let actor = Actor {
        sid: cfg.sid.clone(),
        max: cfg.max_message,
        idle: cfg.idle,
        events: cfg.events,
        stderr: cfg.stderr,
        connected: connected.clone(),
        host_tx,
        state,
        router: None,
        agent: None,
        next_conn: 1,
        held: Vec::new(),
        held_bytes: 0,
        idle_at: None,
    };
    clock::spawn("browser:broker", actor.run(ctl_rx, data_rx, host_rx));
    let shared = Arc::new(Shared {
        sid: cfg.sid,
        path: format!("{PATH_PREFIX}{hex}"),
        gate: cfg.gate,
        ctl: ctl.clone(),
        data,
        max_message: cfg.max_message,
    });
    tracing::info!("cdp://{}: the browser endpoint is served", shared.sid);
    let accept = clock::spawn("browser:accept", accept(listener, shared));
    BrokerHandle {
        ctl,
        connected,
        accept,
    }
}

/// Frames to the host, in order; dropping the sender closes the socketpair's write side, which the host reads as EOF.
async fn host_writer(mut wr: OwnedWriteHalf, mut rx: mpsc::Receiver<Vec<u8>>) {
    while let Some(f) = rx.recv().await {
        if wr.write_all(&f).await.is_err() {
            break;
        }
    }
}

async fn host_reader(mut rd: OwnedReadHalf, max: usize, tx: mpsc::Sender<HostEv>) {
    let mut dec = FrameDecoder::new(max);
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = match rd.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        let Ok(frames) = dec.push(&buf[..n]) else {
            return;
        };
        for f in frames {
            let ev = match f.kind {
                KIND_CDP => HostEv::Cdp(f.payload),
                KIND_CONTROL => match serde_json::from_slice(&f.payload) {
                    Ok(v) => HostEv::Control(v),
                    Err(_) => continue,
                },
                _ => continue,
            };
            if tx.send(ev).await.is_err() {
                return;
            }
        }
    }
}

struct Slot {
    conn: u64,
    /// Set once the upgrade completed.
    tx: Option<mpsc::Sender<ToAgent>>,
}

struct Actor {
    sid: String,
    max: usize,
    idle: Duration,
    events: mpsc::Sender<BrokerEvent>,
    stderr: Option<mpsc::UnboundedSender<String>>,
    connected: Arc<AtomicBool>,
    host_tx: Option<mpsc::Sender<Vec<u8>>>,
    state: State,
    /// The router of the browser that runs (made at `started`).
    router: Option<Router>,
    agent: Option<Slot>,
    next_conn: u64,
    /// The agent's messages while the browser starts or the router is not ready, in order.
    held: Vec<Vec<u8>>,
    held_bytes: usize,
    idle_at: Option<Instant>,
}

async fn until(t: Option<Instant>) {
    match t {
        Some(t) => clock::sleep(t.saturating_duration_since(clock::now())).await,
        None => std::future::pending().await,
    }
}

impl Actor {
    async fn run(
        mut self,
        mut ctl: mpsc::UnboundedReceiver<Cmd>,
        mut data: mpsc::Receiver<(u64, Vec<u8>)>,
        mut host: mpsc::Receiver<HostEv>,
    ) {
        let mut host_open = !matches!(self.state, State::Ended(_));
        loop {
            tokio::select! {
                c = ctl.recv() => match c {
                    None | Some(Cmd::Close) => break,
                    Some(c) => self.control(c).await,
                },
                Some((conn, msg)) = data.recv() => self.agent_message(conn, msg).await,
                h = host.recv(), if host_open => match h {
                    Some(ev) => self.host(ev).await,
                    None => {
                        host_open = false;
                        self.host_gone().await;
                    }
                },
                () = until(self.idle_at) => {
                    self.idle_at = None;
                    if self.agent.is_none() {
                        self.stop("idle").await;
                    }
                }
            }
        }
        self.close().await;
    }

    fn active(&self) -> bool {
        matches!(self.state, State::Starting | State::Running)
    }

    async fn control(&mut self, c: Cmd) {
        match c {
            Cmd::Claim { reserve, reply } => {
                let answer = match &self.state {
                    State::Ended(t) => Claim::Ended(t.clone()),
                    _ if self.agent.is_some() => Claim::Busy,
                    _ if !reserve => Claim::Free(0),
                    _ => {
                        let conn = self.next_conn;
                        self.next_conn += 1;
                        self.agent = Some(Slot { conn, tx: None });
                        self.idle_at = None;
                        Claim::Free(conn)
                    }
                };
                let _ = reply.send(answer);
            }
            Cmd::Agent { conn, tx, ack } => {
                let Some(slot) = self.agent.as_mut().filter(|s| s.conn == conn) else {
                    return;
                };
                slot.tx = Some(tx);
                self.connected.store(true, Ordering::Release);
                tracing::info!("cdp://{}: the agent connected", self.sid);
                if self.state == State::Stopped {
                    self.start_browser().await;
                }
                let _ = ack.send(());
            }
            Cmd::AgentGone { conn } => {
                if self.agent.as_ref().is_some_and(|s| s.conn == conn) {
                    self.agent_left(None, true).await;
                }
            }
            Cmd::Stop(why) => self.stop(&why).await,
            Cmd::Close => {}
        }
    }

    async fn start_browser(&mut self) {
        tracing::info!("cdp://{}: starting the browser", self.sid);
        self.state = State::Starting;
        self.send_host(
            KIND_CONTROL,
            json!({"op": "start"}).to_string().into_bytes(),
        )
        .await;
    }

    /// The agent's slot is free again: with `close`, the agent is told so first; with `cleanup`, the router puts its
    /// sessions away (resumes what it left paused, detaches, attaches afresh for the next one).
    async fn agent_left(&mut self, close: Option<(u16, String)>, cleanup: bool) {
        let Some(slot) = self.agent.take() else {
            return;
        };
        self.connected.store(false, Ordering::Release);
        if let (Some((code, why)), Some(tx)) = (close, &slot.tx) {
            let _ = tx.send(ToAgent::Close(code, reason(&why))).await;
        }
        self.held.clear();
        self.held_bytes = 0;
        if cleanup
            && self.state == State::Running
            && let Some(r) = self.router.as_mut()
        {
            let cmds = r.agent_closed();
            for c in cmds {
                self.send_host(KIND_CDP, c).await;
            }
        }
        if self.active() {
            self.idle_at = Some(clock::now() + self.idle);
        }
        tracing::info!("cdp://{}: the agent's websocket closed", self.sid);
    }

    async fn agent_message(&mut self, conn: u64, msg: Vec<u8>) {
        if self.agent.as_ref().is_none_or(|s| s.conn != conn) {
            return;
        }
        if msg.len() > self.max {
            let why = format!("a message over the limit of {} bytes", self.max);
            self.agent_left(Some((CLOSE_TOO_BIG, why)), true).await;
            return;
        }
        let ready = self.state == State::Running && self.router.as_ref().is_some_and(Router::ready);
        if ready && self.held.is_empty() {
            self.route_agent(&msg).await;
            return;
        }
        self.held_bytes += msg.len();
        self.held.push(msg);
        if self.held_bytes > self.max.saturating_mul(2) {
            let why = "too much was sent while the browser started".to_owned();
            self.agent_left(Some((CLOSE_POLICY, why)), true).await;
        }
    }

    async fn route_agent(&mut self, msg: &[u8]) {
        let Some(r) = self.router.as_mut() else {
            return;
        };
        let step = r.from_agent(msg);
        self.apply(step).await;
    }

    /// The held messages, once the router is ready.
    async fn flush(&mut self) {
        let ready = self.state == State::Running && self.router.as_ref().is_some_and(Router::ready);
        if !ready {
            return;
        }
        let held = std::mem::take(&mut self.held);
        self.held_bytes = 0;
        for m in held {
            self.route_agent(&m).await;
        }
    }

    async fn apply(&mut self, step: Step) {
        match step {
            Step::ToBrowser(b) => self.send_host(KIND_CDP, b).await,
            Step::ToAgent(a) => self.send_agent(a).await,
            Step::Both { browser, agent } => {
                self.send_host(KIND_CDP, browser).await;
                self.send_agent(agent).await;
            }
            Step::Drop => {}
            Step::Event(e) => self.event(e),
            Step::ToAgentAndEvent { agent, event } => {
                self.send_agent(agent).await;
                self.event(event);
            }
        }
    }

    async fn send_agent(&mut self, msg: Vec<u8>) {
        if let Some(tx) = self.agent.as_ref().and_then(|s| s.tx.as_ref()) {
            let _ = tx.send(ToAgent::Text(msg)).await;
        }
    }

    async fn send_host(&mut self, kind: u8, payload: Vec<u8>) {
        if let Some(tx) = &self.host_tx {
            let _ = tx.send(codec::Frame::encode(kind, &payload)).await;
        }
    }

    fn event(&self, e: BrokerEvent) {
        if let BrokerEvent::NoBrowserSession = e {
            tracing::warn!(
                "cdp://{}: no browser session (Target.attachToBrowserTarget failed): the agent has the root",
                self.sid
            );
        }
        if self.events.try_send(e).is_err() {
            tracing::warn!(
                "cdp://{}: a broker event was lost (the channel is full)",
                self.sid
            );
        }
    }

    async fn host(&mut self, ev: HostEv) {
        match ev {
            HostEv::Cdp(m) => {
                let Some(r) = self.router.as_mut() else {
                    return;
                };
                let was = r.ready();
                let step = r.from_browser(&m);
                let now = r.ready();
                self.apply(step).await;
                if !was && now {
                    self.flush().await;
                }
            }
            HostEv::Control(v) => match v["ev"].as_str() {
                Some("started") => {
                    if self.state != State::Starting {
                        return;
                    }
                    tracing::info!("cdp://{}: the browser started (pid {})", self.sid, v["pid"]);
                    self.state = State::Running;
                    let (r, first) = Router::new();
                    self.router = Some(r);
                    for c in first {
                        self.send_host(KIND_CDP, c).await;
                    }
                }
                Some("exited") => self.exited(&v).await,
                Some("stderr") => {
                    if let Some(tx) = &self.stderr {
                        let _ = tx.send(v["line"].as_str().unwrap_or("").to_owned());
                    }
                    tracing::debug!(
                        "cdp://{}: browser: {}",
                        self.sid,
                        v["line"].as_str().unwrap_or("")
                    );
                }
                _ => {}
            },
        }
    }

    async fn exited(&mut self, v: &Value) {
        let what = exit_text(v);
        let was = std::mem::replace(&mut self.state, State::Stopped);
        self.router = None;
        self.idle_at = None;
        match was {
            State::Starting | State::Running => {
                tracing::warn!("cdp://{}: the browser exited ({what})", self.sid);
                let why = format!("the browser exited ({what})");
                self.agent_left(Some((CLOSE_ERROR, why)), false).await;
            }
            State::Stopping => {
                tracing::info!("cdp://{}: the browser stopped ({what})", self.sid);
                // an agent that connected while it stopped gets a fresh one
                if self.agent.as_ref().is_some_and(|s| s.tx.is_some()) {
                    self.start_browser().await;
                }
            }
            other => self.state = other,
        }
    }

    async fn host_gone(&mut self) {
        tracing::warn!("cdp://{}: the browser host ended", self.sid);
        self.state = State::Ended(HOST_ENDED.into());
        self.router = None;
        self.idle_at = None;
        self.host_tx = None;
        self.agent_left(
            Some((CLOSE_ERROR, "the browser's host ended".into())),
            false,
        )
        .await;
    }

    async fn stop(&mut self, why: &str) {
        if !self.active() {
            return;
        }
        tracing::info!("cdp://{}: stopping the browser ({why})", self.sid);
        self.state = State::Stopping;
        self.router = None;
        let text = if why == "memory" {
            MEMORY_STOP.to_owned()
        } else {
            format!("the browser was stopped ({why})")
        };
        self.agent_left(Some((CLOSE_GOING_AWAY, text)), false).await;
        self.idle_at = None;
        self.send_host(
            KIND_CONTROL,
            json!({"op": "stop", "why": why}).to_string().into_bytes(),
        )
        .await;
        self.event(BrokerEvent::Stopped {
            why: why.to_owned(),
        });
    }

    /// The broker's end: the browser stopped, then the socketpair closed (the host exits at its EOF).
    async fn close(&mut self) {
        if self.active() {
            tracing::info!("cdp://{}: stopping the browser (hub)", self.sid);
            self.state = State::Stopping;
            self.router = None;
            let why = "the browser was stopped (the session ended)".to_owned();
            self.agent_left(Some((CLOSE_GOING_AWAY, why)), false).await;
            self.send_host(
                KIND_CONTROL,
                json!({"op": "stop", "why": "hub"}).to_string().into_bytes(),
            )
            .await;
        } else {
            self.agent_left(
                Some((CLOSE_GOING_AWAY, "the browser endpoint closed".into())),
                false,
            )
            .await;
        }
        self.host_tx = None;
        tracing::info!("cdp://{}: the browser endpoint closed", self.sid);
    }
}

/// `exited`'s reason: its error, its signal or its code.
fn exit_text(v: &Value) -> String {
    if let Some(e) = v["error"].as_str() {
        return e.to_owned();
    }
    match (v["code"].as_i64(), v["signal"].as_i64()) {
        (_, Some(s)) => format!("signal {s}"),
        (Some(c), _) => format!("code {c}"),
        _ => "unknown".into(),
    }
}

/// `why` cut to a close frame's reason (123 bytes, on a char boundary).
fn reason(why: &str) -> String {
    let mut end = why.len().min(CLOSE_REASON_MAX);
    while !why.is_char_boundary(end) {
        end -= 1;
    }
    why[..end].to_owned()
}

/// Equal, in a time that depends on the lengths only.
fn same(a: &[u8], b: &[u8]) -> bool {
    use subtle::ConstantTimeEq;
    a.ct_eq(b).into()
}

async fn accept(listener: UnixListener, sh: Arc<Shared>) {
    let own = rustix::process::geteuid().as_raw();
    loop {
        let s = match listener.accept().await {
            Ok((s, _)) => s,
            Err(e) => {
                tracing::warn!("cdp://{}: accept: {e}", sh.sid);
                clock::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        match s.peer_cred() {
            Ok(c) if peer_allowed(c.uid(), own) => {}
            _ => {
                tracing::warn!("cdp://{}: a connection from another user: closed", sh.sid);
                continue;
            }
        }
        let sh = sh.clone();
        clock::spawn("browser:http", async move {
            let svc = service_fn(move |req| {
                let sh = sh.clone();
                async move { Ok::<_, Infallible>(handle(sh, req).await) }
            });
            let mut b = http1::Builder::new();
            b.timer(TokioTimer::new())
                .header_read_timeout(HEADER_READ_TIMEOUT);
            let _ = b
                .serve_connection(TokioIo::new(s), svc)
                .with_upgrades()
                .await;
        });
    }
}

fn status(code: StatusCode, text: &str) -> Response<Full<Bytes>> {
    let mut b = Response::builder().status(code);
    if !text.is_empty() {
        b = b.header(hyper::header::CONTENT_TYPE, "text/plain; charset=utf-8");
    }
    b.body(Full::new(Bytes::from(text.to_owned())))
        .expect("a plain response builds")
}

async fn claim(sh: &Shared, reserve: bool) -> Claim {
    let (reply, rx) = oneshot::channel();
    if sh.ctl.send(Cmd::Claim { reserve, reply }).is_err() {
        return Claim::Ended(HOST_ENDED.into());
    }
    rx.await.unwrap_or_else(|_| Claim::Ended(HOST_ENDED.into()))
}

async fn handle(sh: Arc<Shared>, mut req: Request<Incoming>) -> Response<Full<Bytes>> {
    let endpoint = req.method() == Method::GET
        && req.uri().query().is_none()
        && same(req.uri().path().as_bytes(), sh.path.as_bytes());
    if !endpoint || !fastwebsockets::upgrade::is_upgrade_request(&req) {
        tracing::info!(
            "cdp://{}: a request that is not the endpoint's upgrade: 404",
            sh.sid
        );
        return status(StatusCode::NOT_FOUND, "");
    }
    match claim(&sh, false).await {
        Claim::Ended(t) => return status(StatusCode::SERVICE_UNAVAILABLE, &t),
        Claim::Busy => return status(StatusCode::CONFLICT, BUSY),
        Claim::Free(_) => {}
    }
    match (sh.gate)().await {
        Gate::Allow => {}
        Gate::Ask(card) => {
            tracing::info!(
                "cdp://{}: the browser waits for the user's yes (card {card})",
                sh.sid
            );
            let text = format!("waiting for the user's yes: card {card}");
            return status(StatusCode::FORBIDDEN, &text);
        }
        Gate::Never(why) => {
            tracing::info!("cdp://{}: the browser is refused: {why}", sh.sid);
            return status(StatusCode::FORBIDDEN, &why);
        }
    }
    let conn = match claim(&sh, true).await {
        Claim::Free(g) => g,
        Claim::Busy => return status(StatusCode::CONFLICT, BUSY),
        Claim::Ended(t) => return status(StatusCode::SERVICE_UNAVAILABLE, &t),
    };
    let (resp, fut) = match fastwebsockets::upgrade::upgrade(&mut req) {
        Ok(x) => x,
        Err(_) => {
            let _ = sh.ctl.send(Cmd::AgentGone { conn });
            return status(StatusCode::NOT_FOUND, "");
        }
    };
    clock::spawn("browser:agent", agent_conn(sh, conn, fut));
    resp.map(|_| Full::new(Bytes::new()))
}

/// One agent websocket: a writer task for what the actor sends, and this task reading the agent's messages.
async fn agent_conn(sh: Arc<Shared>, conn: u64, fut: fastwebsockets::upgrade::UpgradeFut) {
    let mut ws = match fut.await {
        Ok(ws) => ws,
        Err(e) => {
            tracing::debug!("cdp://{}: the upgrade did not complete: {e}", sh.sid);
            let _ = sh.ctl.send(Cmd::AgentGone { conn });
            return;
        }
    };
    ws.set_max_message_size(sh.max_message.saturating_add(1));
    ws.set_auto_close(true);
    ws.set_auto_pong(true);
    let (rd, mut wr) = ws.split(tokio::io::split);
    let mut rd = FragmentCollectorRead::new(rd);
    let (tx, mut rx) = mpsc::channel::<ToAgent>(64);
    let (ack, acked) = oneshot::channel();
    if sh
        .ctl
        .send(Cmd::Agent {
            conn,
            tx: tx.clone(),
            ack,
        })
        .is_err()
        || acked.await.is_err()
    {
        return;
    }
    let done = Arc::new(Notify::new());
    let finished = done.clone();
    clock::spawn("browser:agent-writer", async move {
        while let Some(m) = rx.recv().await {
            let r = match m {
                ToAgent::Text(b) => wr.write_frame(Frame::text(Payload::Owned(b))).await,
                ToAgent::Frame(f) => wr.write_frame(f).await,
                ToAgent::Close(code, why) => {
                    let _ = wr.write_frame(Frame::close(code, why.as_bytes())).await;
                    clock::sleep(CLOSE_WAIT).await;
                    break;
                }
            };
            if r.is_err() {
                break;
            }
        }
        finished.notify_one();
    });
    loop {
        let owed = tx.clone();
        let mut send = move |f: Frame<'static>| {
            let owed = owed.clone();
            async move {
                owed.send(ToAgent::Frame(f))
                    .await
                    .map_err(|_| io::Error::other("the agent's writer is gone"))
            }
        };
        let frame = tokio::select! {
            () = done.notified() => break,
            r = rd.read_frame(&mut send) => r,
        };
        match frame {
            Ok(f) if matches!(f.opcode, OpCode::Text | OpCode::Binary) => {
                if sh.data.send((conn, f.payload.to_vec())).await.is_err() {
                    break;
                }
            }
            Ok(f) if f.opcode == OpCode::Close => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = sh.ctl.send(Cmd::AgentGone { conn });
}

/// `__test_browser_endpoint {socket}` (test-hooks): a broker on SOCKET whose gate allows, with no browser host
/// behind it (its end of the socketpair is kept open and never read), for the conformance rows on the endpoint itself.
/// Answers the secret's hex.
#[cfg(feature = "test-hooks")]
pub fn test_endpoint(socket: &std::path::Path) -> Result<String, String> {
    use std::io::Read;
    use std::sync::Mutex;
    static KEPT: Mutex<Vec<(BrokerHandle, UnixStream)>> = Mutex::new(Vec::new());
    let mut secret = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut secret))
        .map_err(|e| format!("/dev/urandom: {e}"))?;
    let listener = UnixListener::bind(socket).map_err(|e| format!("{}: {e}", socket.display()))?;
    let (ours, theirs) = UnixStream::pair().map_err(|e| format!("a socketpair: {e}"))?;
    let (events, _) = mpsc::channel(1);
    let cfg = BrokerCfg {
        sid: "test".into(),
        secret,
        max_message: 64 << 20,
        idle: Duration::from_secs(600),
        gate: Arc::new(|| Box::pin(async { Gate::Allow }) as BoxFuture<'static, Gate>),
        events,
        stderr: None,
    };
    let handle = start(cfg, listener, ours);
    KEPT.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .push((handle, theirs));
    Ok(secret.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(all(test, target_os = "linux"))]
mod tests;
