//! The bridge's redial state machine (design §5.8; docs/develop/hub.md, "The MCP bridge"), generic over a
//! [`Connector`]: an agent's stdio on one side, a hub's MCP socket on the other, and the hub may go away and come back.
//! Claude Code never respawns a dead stdio server (anthropics/claude-code#82746), so the bridge outlives the hub.
//!
//! - Lines are copied both ways. One from the agent over [`Limits::max_in`] is answered `-32600` on its id (dropped
//!   when it has none) and the bridge goes on; one from the hub over [`Limits::max_out`] drops the connection.
//! - Cached: the agent's `initialize` (once the hub accepted it) and whether `notifications/initialized` went, and the
//!   last `server/discover` and `tools/list` answers.
//! - When the socket drops, the bridge redials ([`BridgeOpts::backoff`] doubling to [`BridgeOpts::backoff_max`]) and
//!   ends after [`BridgeOpts::give_up`] without a connection. On reconnect it replays the cached `initialize` with an
//!   id of its own (the hub's answer is dropped: the agent has one) and `notifications/initialized`, fetches
//!   `tools/list` once, and tells the agent `notifications/tools/list_changed` when the list differs (the `initialize`
//!   era only). The stateless era (2026-07-28) has nothing to replay.
//! - While away: `tools/list` and `server/discover` are answered from the cache, `ping` with `{}`. Any other request
//!   waits up to [`BridgeOpts::wait`] for the socket (a dial is tried at once), then a `tools/call` gets the tool error
//!   [`RESTARTING`] and anything else `-32603`.
//! - A request in flight when the socket dropped is never sent again: a write has no request key before schema 7, so
//!   a resend could write twice. A `tools/call` gets the tool error [`WENT_AWAY`] (the agent decides), anything else
//!   `-32603`.
//! - The agent's stdin closing ends the bridge at once (MCP stdio: the server should exit on EOF).

use std::collections::VecDeque;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use runstav::jsonrpc::{ErrorObject, INTERNAL_ERROR, INVALID_REQUEST, Id};
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::jsonrpc_glue as glue;
use crate::server::Limits;
use crate::tool::BoxFuture;
use crate::version;

/// The tool error of a `tools/call` that waited [`BridgeOpts::wait`] while the hub was away.
pub const RESTARTING: &str = "drgnx hub restarting; retry";

/// The `-32603` message of any other request that waited while the hub was away.
pub const RESTARTING_ERROR: &str = "drgnx hub restarting";

/// The tool error of a `tools/call` that was in flight when the socket dropped (never sent again).
pub const WENT_AWAY: &str = "the drgnx hub went away during this call; whether it took effect is unknown — check with \
                             read_inbox, task_status or read_decisions before you retry (if you passed req, \
                             retrying with the same req is safe)";

/// The `-32603` message of any other request in flight when the socket dropped.
pub const WENT_AWAY_ERROR: &str = "the drgnx hub went away during this request";

/// `notifications/initialized`.
const INITIALIZED: &str = "notifications/initialized";

/// Lines read and not yet handled, each way.
const QUEUE: usize = 64;

/// The most agent lines kept while the hub is away: past it a request is answered at once as if it had waited, and a
/// notification is dropped.
const MAX_WAITING: usize = 256;

/// Why a dial failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Dial {
    /// No hub now (no socket, refused, closed in the prelude, …): dial again after the backoff.
    Again(String),
    /// The hub, or what stands where it should be, refuses this bridge (an untrusted directory, a refused attach):
    /// the bridge ends with this text.
    Fatal(String),
}

impl From<io::Error> for Dial {
    fn from(e: io::Error) -> Dial {
        Dial::Again(e.to_string())
    }
}

/// How the bridge reaches the hub. `connect` and `prelude` run on each dial; their futures own what they need, so a
/// dial runs while the bridge goes on answering the agent.
pub trait Connector: Send + Sync + 'static {
    type R: AsyncRead + Unpin + Send + 'static;
    type W: AsyncWrite + Unpin + Send + 'static;

    /// A connection to the hub.
    #[allow(clippy::type_complexity)]
    fn connect(&self) -> BoxFuture<'static, Result<(Self::R, Self::W), Dial>>;

    /// What the connection says before it carries MCP (an outside bridge's `hello` and `mcp/attach`); the bytes the
    /// reader holds after it are MCP. None by default.
    #[allow(clippy::type_complexity)]
    fn prelude(
        &self,
        r: BufReader<Self::R>,
        w: Self::W,
    ) -> BoxFuture<'static, Result<(BufReader<Self::R>, Self::W), Dial>> {
        Box::pin(async move { Ok((r, w)) })
    }
}

/// The bridge's timings and line limits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BridgeOpts {
    /// The wait before the first redial after a drop (doubled after each failed dial).
    pub backoff: Duration,
    /// The longest wait between dials.
    pub backoff_max: Duration,
    /// How long without a connection before the bridge ends ([`BridgeEnd::GaveUp`]).
    pub give_up: Duration,
    /// How long a request waits for the socket while the hub is away.
    pub wait: Duration,
    /// `max_in`: the longest agent line; `max_out`: the longest hub line.
    pub limits: Limits,
}

impl Default for BridgeOpts {
    /// 0.1 s doubling to 5 s, 10 min, 10 s (design §5.8); 1 MiB in, 16 MiB out.
    fn default() -> Self {
        BridgeOpts {
            backoff: Duration::from_millis(100),
            backoff_max: Duration::from_secs(5),
            give_up: Duration::from_secs(600),
            wait: Duration::from_secs(10),
            limits: Limits::default(),
        }
    }
}

/// Why the bridge ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BridgeEnd {
    /// The agent closed stdin.
    StdinClosed,
    /// Writing to the agent failed (it is gone).
    StdoutClosed,
    /// No connection for [`BridgeOpts::give_up`]; the text says so.
    GaveUp(String),
    /// A dial ended with [`Dial::Fatal`].
    Fatal(String),
}

impl BridgeEnd {
    /// The exit status: 0 when the agent went, 1 otherwise.
    pub fn code(&self) -> u8 {
        match self {
            BridgeEnd::StdinClosed | BridgeEnd::StdoutClosed => 0,
            BridgeEnd::GaveUp(_) | BridgeEnd::Fatal(_) => 1,
        }
    }
}

/// The wait after NOW's: doubled, at most MAX.
pub fn next_backoff(now: Duration, max: Duration) -> Duration {
    now.saturating_mul(2).min(max)
}

/// Bridge STDIN and STDOUT (an agent's) to the hub CONN reaches, until stdin closes, stdout fails, a dial is refused
/// for good or no connection was made for `opts.give_up`. The first dial is at once.
pub async fn run<C, I, O>(conn: C, stdin: I, stdout: O, opts: BridgeOpts) -> BridgeEnd
where
    C: Connector,
    I: AsyncRead + Unpin + Send + 'static,
    O: AsyncWrite + Unpin,
{
    let (tx, mut rx) = mpsc::channel(QUEUE);
    let agent = tokio::spawn(read_agent(stdin, tx, opts.limits.max_in));
    let now = Instant::now();
    let mut b = Bridge {
        conn: Arc::new(conn),
        out: stdout,
        opts,
        live: None,
        dialing: None,
        next_dial: Some(now),
        backoff: opts.backoff,
        away_since: now,
        told: false,
        init: None,
        initialized: false,
        discover: None,
        tools: None,
        sent: Vec::new(),
        ours: Vec::new(),
        next_ours: 1,
        queue: VecDeque::new(),
    };
    let end = loop {
        if let Err(end) = b.step(&mut rx).await {
            break end;
        }
    };
    agent.abort();
    if let Some(live) = b.live.take() {
        live.reader.abort();
    }
    end
}

/// What a line read in full turned out to be.
enum Got {
    Line,
    Eof,
    /// Over the limit: the line was read to its end, and the buffer holds its first bytes.
    TooLong,
}

/// One line into BUF without its newline, never more than MAX bytes of it (the rest of a longer one is read and
/// dropped). A last line without a newline counts as a line.
async fn read_bounded<R: AsyncBufRead + Unpin>(
    r: &mut R,
    buf: &mut Vec<u8>,
    max: usize,
) -> io::Result<Got> {
    let mut over = false;
    loop {
        let avail = r.fill_buf().await?;
        if avail.is_empty() {
            return Ok(if over {
                Got::TooLong
            } else if buf.is_empty() {
                Got::Eof
            } else {
                Got::Line
            });
        }
        let (take, newline) = match avail.iter().position(|b| *b == b'\n') {
            Some(i) => (i, true),
            None => (avail.len(), false),
        };
        if !over {
            let room = max.saturating_sub(buf.len());
            if take > room {
                buf.extend_from_slice(&avail[..room]);
                over = true;
            } else {
                buf.extend_from_slice(&avail[..take]);
            }
        }
        r.consume(take + usize::from(newline));
        if newline {
            return Ok(if over { Got::TooLong } else { Got::Line });
        }
    }
}

/// A `\r` before the newline dropped; whether anything but blanks is left.
fn trimmed(buf: &mut Vec<u8>) -> bool {
    if buf.last() == Some(&b'\r') {
        buf.pop();
    }
    !buf.iter().all(u8::is_ascii_whitespace)
}

enum FromAgent {
    Line(String),
    /// A line over the limit, with the id found in its first bytes.
    TooLong(Option<Id>),
}

/// The agent's lines into TX until stdin ends (TX dropped).
async fn read_agent<I: AsyncRead + Unpin>(stdin: I, tx: mpsc::Sender<FromAgent>, max: usize) {
    let mut r = BufReader::new(stdin);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let msg = match read_bounded(&mut r, &mut buf, max).await {
            Ok(Got::Line) => {
                if !trimmed(&mut buf) {
                    continue;
                }
                FromAgent::Line(String::from_utf8_lossy(&buf).into_owned())
            }
            Ok(Got::TooLong) => FromAgent::TooLong(id_in_prefix(&buf)),
            Ok(Got::Eof) | Err(_) => return,
        };
        if tx.send(msg).await.is_err() {
            return;
        }
    }
}

/// The hub's lines into TX until the connection ends (TX dropped): its end, a read error, a line over MAX bytes or
/// one that is not UTF-8.
async fn read_hub<R: AsyncRead + Unpin>(mut r: BufReader<R>, tx: mpsc::Sender<String>, max: usize) {
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match read_bounded(&mut r, &mut buf, max).await {
            Ok(Got::Line) => {}
            Ok(Got::TooLong) => {
                tracing::warn!(
                    "the drgnx hub sent a line over {max} bytes: dropping the connection"
                );
                return;
            }
            Ok(Got::Eof) | Err(_) => return,
        }
        if !trimmed(&mut buf) {
            continue;
        }
        let Ok(line) = String::from_utf8(std::mem::take(&mut buf)) else {
            tracing::warn!("the drgnx hub sent a line that is not UTF-8: dropping the connection");
            return;
        };
        if tx.send(line).await.is_err() {
            return;
        }
    }
}

/// What a line is, as far as the bridge cares.
enum Msg {
    Request {
        id: Id,
        method: String,
        params: Option<Value>,
    },
    Notification {
        method: String,
    },
    /// A result (`Some`) or an error (`None`) answering ID.
    Answer {
        id: Id,
        result: Option<Value>,
    },
    /// Not a JSON-RPC message the bridge can place (the hub judges it).
    Other,
}

fn id_of(v: &Value) -> Option<Id> {
    match v {
        Value::Number(n) => n.as_i64().map(Id::Num),
        Value::String(s) => Some(Id::Str(s.clone())),
        _ => None,
    }
}

fn classify(line: &str) -> Msg {
    let Ok(Value::Object(mut o)) = serde_json::from_str::<Value>(line) else {
        return Msg::Other;
    };
    let id = o.get("id").and_then(id_of);
    let method = o.get("method").and_then(Value::as_str).map(str::to_owned);
    match (method, id) {
        (Some(method), Some(id)) => Msg::Request {
            id,
            method,
            params: o.remove("params"),
        },
        (Some(method), None) if !o.contains_key("id") => Msg::Notification { method },
        (None, Some(id)) => Msg::Answer {
            id,
            result: o.remove("result"),
        },
        _ => Msg::Other,
    }
}

/// The `id` of a JSON object cut short in BYTES (a line over the limit): found when its top-level `"id"` comes before
/// the cut.
fn id_in_prefix(bytes: &[u8]) -> Option<Id> {
    let ws = |mut i: usize| {
        while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
            i += 1;
        }
        i
    };
    let mut i = ws(0);
    if bytes.get(i) != Some(&b'{') {
        return None;
    }
    i += 1;
    loop {
        i = ws(i);
        if bytes.get(i) != Some(&b'"') {
            return None;
        }
        let after = string_end(bytes, i)?;
        let key = &bytes[i + 1..after - 1];
        i = ws(after);
        if bytes.get(i) != Some(&b':') {
            return None;
        }
        i = ws(i + 1);
        let end = value_end(bytes, i)?;
        if key == b"id" {
            return serde_json::from_slice::<Value>(&bytes[i..end])
                .ok()
                .as_ref()
                .and_then(id_of);
        }
        i = ws(end);
        if bytes.get(i) != Some(&b',') {
            return None;
        }
        i += 1;
    }
}

/// The index after the string that opens at I (a `"`), escapes skipped.
fn string_end(bytes: &[u8], i: usize) -> Option<usize> {
    let mut j = i + 1;
    while let Some(&b) = bytes.get(j) {
        match b {
            b'\\' => j += 2,
            b'"' => return Some(j + 1),
            _ => j += 1,
        }
    }
    None
}

/// The index after the value that starts at I; `None` when it runs past the end of BYTES.
fn value_end(bytes: &[u8], i: usize) -> Option<usize> {
    match bytes.get(i)? {
        b'"' => string_end(bytes, i),
        b'{' | b'[' => {
            let (mut depth, mut j) = (0usize, i);
            while let Some(&b) = bytes.get(j) {
                match b {
                    b'"' => {
                        j = string_end(bytes, j)?;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(j + 1);
                        }
                    }
                    _ => {}
                }
                j += 1;
            }
            None
        }
        _ => {
            let mut j = i;
            while let Some(b) = bytes.get(j) {
                if matches!(b, b',' | b'}' | b']') || b.is_ascii_whitespace() {
                    return Some(j);
                }
                j += 1;
            }
            None
        }
    }
}

/// Does a request carry the stateless era's version in `params._meta`?
fn meta_version(params: Option<&Value>) -> bool {
    params
        .and_then(|p| p.get("_meta"))
        .and_then(|m| m.get(version::META_PROTOCOL_VERSION))
        .is_some()
}

/// RESULT with `resultType` when it answers a stateless request.
fn finish(mut result: Value, modern: bool) -> Value {
    if modern && let Value::Object(m) = &mut result {
        m.insert("resultType".into(), "complete".into());
    }
    result
}

fn tool_error(text: &str, modern: bool) -> Value {
    finish(
        json!({"content": [{"type": "text", "text": text}], "isError": true}),
        modern,
    )
}

/// The connection the bridge has.
struct Live<W> {
    w: W,
    rx: mpsc::Receiver<String>,
    reader: JoinHandle<()>,
}

/// An agent request sent on the live connection, waiting for its answer.
enum Sent {
    Call { modern: bool },
    Initialize(Value),
    Discover,
    List,
    Other,
}

/// A request of the bridge's own on the live connection.
enum Ours {
    Initialize,
    List,
}

/// An agent line kept while the hub is away.
struct Queued {
    line: String,
    /// A request's: what it is answered when it waited too long.
    wait: Option<Waiting>,
}

struct Waiting {
    id: Id,
    call: bool,
    modern: bool,
    until: Instant,
}

enum Ev<T> {
    Agent(Option<FromAgent>),
    Hub(Option<String>),
    Dialed(Result<T, Dial>),
    Tick,
}

type Dialed<C> = (BufReader<<C as Connector>::R>, <C as Connector>::W);

struct Bridge<C: Connector, O> {
    conn: Arc<C>,
    out: O,
    opts: BridgeOpts,
    live: Option<Live<C::W>>,
    dialing: Option<BoxFuture<'static, Result<Dialed<C>, Dial>>>,
    /// When to dial next: only while away and not dialing.
    next_dial: Option<Instant>,
    backoff: Duration,
    away_since: Instant,
    /// This time away has been logged.
    told: bool,
    /// The agent's `initialize` params, once the hub answered them with a result.
    init: Option<Value>,
    initialized: bool,
    discover: Option<Value>,
    tools: Option<Value>,
    sent: Vec<(Id, Sent)>,
    ours: Vec<(Id, Ours)>,
    next_ours: u64,
    queue: VecDeque<Queued>,
}

async fn recv_live<W>(live: &mut Option<Live<W>>) -> Option<String> {
    match live {
        Some(l) => l.rx.recv().await,
        None => std::future::pending().await,
    }
}

async fn dialed<T>(d: &mut Option<BoxFuture<'static, Result<T, Dial>>>) -> Result<T, Dial> {
    match d {
        Some(f) => f.await,
        None => std::future::pending().await,
    }
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(t) => tokio::time::sleep_until(t).await,
        None => std::future::pending().await,
    }
}

impl<C: Connector, O: AsyncWrite + Unpin> Bridge<C, O> {
    /// One event handled; `Err` ends the bridge.
    async fn step(&mut self, rx: &mut mpsc::Receiver<FromAgent>) -> Result<(), BridgeEnd> {
        let wake = self.wake();
        // the hub's side first: a socket that closed is seen before an agent line that came meanwhile, which then
        // waits for the redial instead of going into a dead socket (and coming back as "went away")
        let ev = tokio::select! {
            biased;
            l = recv_live(&mut self.live) => Ev::Hub(l),
            d = dialed(&mut self.dialing) => Ev::Dialed(d),
            m = rx.recv() => Ev::Agent(m),
            () = sleep_until(wake) => Ev::Tick,
        };
        match ev {
            Ev::Agent(None) => Err(BridgeEnd::StdinClosed),
            Ev::Agent(Some(FromAgent::Line(line))) => self.agent_line(line).await,
            Ev::Agent(Some(FromAgent::TooLong(id))) => self.too_long(id).await,
            Ev::Hub(Some(line)) => self.hub_line(line).await,
            Ev::Hub(None) => self.dropped().await,
            Ev::Dialed(d) => {
                self.dialing = None;
                match d {
                    Ok((r, w)) => self.connected(r, w).await,
                    Err(Dial::Fatal(why)) => Err(BridgeEnd::Fatal(why)),
                    Err(Dial::Again(why)) => self.dial_failed(why),
                }
            }
            Ev::Tick => self.tick().await,
        }
    }

    /// The next instant something is due: a dial (only while away and not dialing), or a waiting request's end.
    fn wake(&self) -> Option<Instant> {
        let waiting = self
            .queue
            .iter()
            .filter_map(|q| q.wait.as_ref().map(|w| w.until))
            .min();
        let dial = self
            .next_dial
            .filter(|_| self.live.is_none() && self.dialing.is_none());
        match (dial, waiting) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    async fn tick(&mut self) -> Result<(), BridgeEnd> {
        let now = Instant::now();
        if self.next_dial.is_some_and(|at| at <= now) {
            self.dial();
        }
        let mut i = 0;
        while i < self.queue.len() {
            if self.queue[i].wait.as_ref().is_none_or(|w| w.until > now) {
                i += 1;
                continue;
            }
            if let Some(Queued { wait: Some(w), .. }) = self.queue.remove(i) {
                self.waited_too_long(w).await?;
            }
        }
        Ok(())
    }

    /// Start a dial now (unless connected or dialing).
    fn dial(&mut self) {
        if self.live.is_some() || self.dialing.is_some() {
            return;
        }
        self.next_dial = None;
        let c = self.conn.clone();
        self.dialing = Some(Box::pin(async move {
            let (r, w) = c.connect().await?;
            c.prelude(BufReader::new(r), w).await
        }));
    }

    fn dial_failed(&mut self, why: String) -> Result<(), BridgeEnd> {
        let now = Instant::now();
        let limit = self.away_since + self.opts.give_up;
        if now >= limit {
            return Err(BridgeEnd::GaveUp(format!(
                "no drgnx hub answered for {} s ({why}); giving up",
                self.opts.give_up.as_secs_f64()
            )));
        }
        if !self.told {
            tracing::warn!("cannot reach the drgnx hub ({why}); trying again");
            self.told = true;
        }
        self.next_dial = Some((now + self.backoff).min(limit));
        self.backoff = next_backoff(self.backoff, self.opts.backoff_max);
        Ok(())
    }

    /// A dial made it: replay what the agent said to the hub before, then what waited.
    async fn connected(&mut self, r: BufReader<C::R>, w: C::W) -> Result<(), BridgeEnd> {
        let (tx, rx) = mpsc::channel(QUEUE);
        let reader = tokio::spawn(read_hub(r, tx, self.opts.limits.max_out));
        self.live = Some(Live { w, rx, reader });
        self.next_dial = None;
        self.backoff = self.opts.backoff;
        if self.told {
            tracing::warn!("reached the drgnx hub again");
            self.told = false;
        }
        if let Some(params) = self.init.clone() {
            let id = self.our_id(Ours::Initialize);
            let line =
                json!({"jsonrpc": "2.0", "id": id, "method": "initialize", "params": params});
            self.send_to_hub(&line.to_string()).await?;
            if self.initialized {
                let line = json!({"jsonrpc": "2.0", "method": INITIALIZED});
                self.send_to_hub(&line.to_string()).await?;
            }
            let id = self.our_id(Ours::List);
            let line = json!({"jsonrpc": "2.0", "id": id, "method": "tools/list"});
            self.send_to_hub(&line.to_string()).await?;
        }
        while self.live.is_some()
            && let Some(q) = self.queue.pop_front()
        {
            self.forward(q.line).await?;
        }
        Ok(())
    }

    /// A bridge-chosen id for KIND (a string the agent's numbers never meet).
    fn our_id(&mut self, kind: Ours) -> Id {
        let id = Id::Str(format!("drgnx-bridge-{}", self.next_ours));
        self.next_ours += 1;
        self.ours.push((id.clone(), kind));
        id
    }

    /// The socket closed (or a write to it failed): every request in flight is answered, never sent again.
    async fn dropped(&mut self) -> Result<(), BridgeEnd> {
        if let Some(live) = self.live.take() {
            live.reader.abort();
        }
        self.ours.clear();
        let now = Instant::now();
        self.away_since = now;
        self.next_dial = Some(now + self.opts.backoff);
        self.backoff = next_backoff(self.opts.backoff, self.opts.backoff_max);
        if !self.told {
            tracing::warn!("the drgnx hub went away; redialing");
            self.told = true;
        }
        for (id, sent) in std::mem::take(&mut self.sent) {
            let answer = match sent {
                Sent::Call { modern } => glue::result(&id, tool_error(WENT_AWAY, modern)),
                _ => glue::error(
                    Some(&id),
                    &ErrorObject::new(INTERNAL_ERROR, WENT_AWAY_ERROR),
                ),
            };
            self.say(&answer).await?;
        }
        Ok(())
    }

    /// Is a request with PARAMS of the stateless era? (After `initialize` a connection is the handshake's.)
    fn modern(&self, params: Option<&Value>) -> bool {
        self.init.is_none() && meta_version(params)
    }

    async fn agent_line(&mut self, line: String) -> Result<(), BridgeEnd> {
        if self.live.is_some() {
            return self.forward(line).await;
        }
        match classify(&line) {
            Msg::Request { id, method, params } => {
                let modern = self.modern(params.as_ref());
                let cached = match method.as_str() {
                    "ping" => Some(finish(json!({}), modern)),
                    "tools/list" => self.tools.clone(),
                    "server/discover" => self.discover.clone(),
                    _ => None,
                };
                if let Some(result) = cached {
                    return self.say(&glue::result(&id, result)).await;
                }
                let wait = Waiting {
                    id,
                    call: method == "tools/call",
                    modern,
                    until: Instant::now() + self.opts.wait,
                };
                if self.queue.len() >= MAX_WAITING {
                    return self.waited_too_long(wait).await;
                }
                self.queue.push_back(Queued {
                    line,
                    wait: Some(wait),
                });
                // a request does not wait for the backoff: try now
                self.dial();
            }
            Msg::Notification { method } => {
                // the replay sends it on reconnect
                let replayed = method == INITIALIZED && self.init.is_some() && self.initialized;
                if !replayed && self.queue.len() < MAX_WAITING {
                    self.queue.push_back(Queued { line, wait: None });
                }
            }
            // the hub asks the agent nothing, so an answer has no one to go to
            Msg::Answer { .. } | Msg::Other => {}
        }
        Ok(())
    }

    /// An agent line to the live hub, noting a request so its answer (or the drop) can be placed.
    async fn forward(&mut self, line: String) -> Result<(), BridgeEnd> {
        match classify(&line) {
            Msg::Request { id, method, params } => {
                let sent = match method.as_str() {
                    "tools/call" => Sent::Call {
                        modern: self.modern(params.as_ref()),
                    },
                    "initialize" => Sent::Initialize(params.unwrap_or(Value::Null)),
                    "server/discover" => Sent::Discover,
                    "tools/list" => Sent::List,
                    _ => Sent::Other,
                };
                self.sent.push((id, sent));
            }
            Msg::Notification { method } if method == INITIALIZED => self.initialized = true,
            _ => {}
        }
        self.send_to_hub(&line).await
    }

    async fn waited_too_long(&mut self, w: Waiting) -> Result<(), BridgeEnd> {
        let answer = if w.call {
            glue::result(&w.id, tool_error(RESTARTING, w.modern))
        } else {
            glue::error(
                Some(&w.id),
                &ErrorObject::new(INTERNAL_ERROR, RESTARTING_ERROR),
            )
        };
        self.say(&answer).await
    }

    async fn too_long(&mut self, id: Option<Id>) -> Result<(), BridgeEnd> {
        let max = self.opts.limits.max_in;
        match id {
            Some(id) => {
                let e =
                    ErrorObject::new(INVALID_REQUEST, format!("the message is over {max} bytes"));
                self.say(&glue::error(Some(&id), &e)).await
            }
            None => {
                tracing::warn!("dropped a message over {max} bytes from the agent (it has no id)");
                Ok(())
            }
        }
    }

    /// A hub line: an answer to the bridge's own request stays here; the rest goes to the agent as it came.
    async fn hub_line(&mut self, line: String) -> Result<(), BridgeEnd> {
        if let Msg::Answer { id, result } = classify(&line) {
            if let Some(i) = self.ours.iter().position(|(o, _)| *o == id) {
                let (_, ours) = self.ours.remove(i);
                return self.ours_answered(ours, result).await;
            }
            if let Some(i) = self.sent.iter().position(|(s, _)| *s == id) {
                let (_, sent) = self.sent.remove(i);
                if let Some(result) = result {
                    match sent {
                        Sent::Initialize(params) => self.init = Some(params),
                        Sent::Discover => self.discover = Some(result),
                        Sent::List => self.tools = Some(result),
                        Sent::Call { .. } | Sent::Other => {}
                    }
                }
            }
        }
        self.say_line(&line).await
    }

    async fn ours_answered(&mut self, ours: Ours, result: Option<Value>) -> Result<(), BridgeEnd> {
        match (ours, result) {
            (Ours::Initialize, None) => {
                tracing::warn!("the drgnx hub refused the replayed initialize");
            }
            (Ours::List, Some(list)) => {
                let changed = self
                    .tools
                    .as_ref()
                    .is_some_and(|old| old.get("tools") != list.get("tools"));
                self.tools = Some(list);
                if changed && self.init.is_some() {
                    let note =
                        json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"});
                    return self.say(&note).await;
                }
            }
            (Ours::Initialize, Some(_)) | (Ours::List, None) => {}
        }
        Ok(())
    }

    async fn say(&mut self, v: &Value) -> Result<(), BridgeEnd> {
        self.say_line(&v.to_string()).await
    }

    /// LINE to the agent; a failed write ends the bridge.
    async fn say_line(&mut self, line: &str) -> Result<(), BridgeEnd> {
        let mut bytes = Vec::with_capacity(line.len() + 1);
        bytes.extend_from_slice(line.as_bytes());
        bytes.push(b'\n');
        let w = &mut self.out;
        let wrote: io::Result<()> = async {
            w.write_all(&bytes).await?;
            w.flush().await
        }
        .await;
        wrote.map_err(|_| BridgeEnd::StdoutClosed)
    }

    /// LINE to the hub, when connected; a write that fails or makes no progress for `opts.wait` drops the connection.
    async fn send_to_hub(&mut self, line: &str) -> Result<(), BridgeEnd> {
        let Some(live) = &mut self.live else {
            return Ok(());
        };
        let mut bytes = Vec::with_capacity(line.len() + 1);
        bytes.extend_from_slice(line.as_bytes());
        bytes.push(b'\n');
        let w = &mut live.w;
        let wrote = tokio::time::timeout(self.opts.wait, async {
            w.write_all(&bytes).await?;
            w.flush().await?;
            io::Result::Ok(())
        })
        .await;
        if matches!(wrote, Ok(Ok(()))) {
            return Ok(());
        }
        self.dropped().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{End, ServerInfo, serve};
    use crate::tool::{Tool, ToolResult};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{DuplexStream, ReadHalf, WriteHalf, duplex, split};

    /// What the fake hub's tools saw.
    #[derive(Default)]
    struct Ctx {
        echo: AtomicUsize,
        slow: AtomicUsize,
    }

    /// `echo`: counted, answers `ok`.
    struct Echo;
    /// `slow`: counted, never answers.
    struct Slow;
    /// `extra`: only in the second tool list.
    struct Extra;

    impl Tool<Ctx> for Echo {
        fn name(&self) -> &'static str {
            "echo"
        }
        fn description(&self) -> &'static str {
            "Answer ok."
        }
        fn input_schema(&self) -> Value {
            json!({"type": "object"})
        }
        fn call<'a>(&'a self, ctx: &'a Ctx, _: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                ctx.echo.fetch_add(1, Ordering::SeqCst);
                ToolResult::Ok {
                    text: "ok".into(),
                    structured: None,
                }
            })
        }
    }

    impl Tool<Ctx> for Slow {
        fn name(&self) -> &'static str {
            "slow"
        }
        fn description(&self) -> &'static str {
            "Never answers."
        }
        fn input_schema(&self) -> Value {
            json!({"type": "object"})
        }
        fn call<'a>(&'a self, ctx: &'a Ctx, _: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                ctx.slow.fetch_add(1, Ordering::SeqCst);
                std::future::pending::<ToolResult>().await
            })
        }
    }

    impl Tool<Ctx> for Extra {
        fn name(&self) -> &'static str {
            "extra"
        }
        fn description(&self) -> &'static str {
            "One more."
        }
        fn input_schema(&self) -> Value {
            json!({"type": "object"})
        }
        fn call<'a>(&'a self, _: &'a Ctx, _: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async {
                ToolResult::Ok {
                    text: "extra".into(),
                    structured: None,
                }
            })
        }
    }

    type Tools = Arc<[Box<dyn Tool<Ctx>>]>;

    fn first_tools() -> Tools {
        let all: Vec<Box<dyn Tool<Ctx>>> = vec![Box::new(Echo), Box::new(Slow)];
        Arc::from(all)
    }

    fn other_tools() -> Tools {
        let all: Vec<Box<dyn Tool<Ctx>>> = vec![Box::new(Echo), Box::new(Slow), Box::new(Extra)];
        Arc::from(all)
    }

    struct HubState {
        up: bool,
        tools: Tools,
        servers: Vec<JoinHandle<End>>,
        dials: Vec<Instant>,
    }

    /// A fake hub: each dial (while it is up) gets a fresh `mimir::serve` over an in-memory pipe.
    #[derive(Clone)]
    struct Fake {
        hub: Arc<Mutex<HubState>>,
        ctx: Arc<Ctx>,
    }

    impl Fake {
        fn new() -> Fake {
            Fake {
                hub: Arc::new(Mutex::new(HubState {
                    up: true,
                    tools: first_tools(),
                    servers: Vec::new(),
                    dials: Vec::new(),
                })),
                ctx: Arc::new(Ctx::default()),
            }
        }

        fn set_up(&self, up: bool) {
            self.hub.lock().expect("hub").up = up;
        }

        fn set_tools(&self, tools: Tools) {
            self.hub.lock().expect("hub").tools = tools;
        }

        /// The hub goes away: every connection's server ends, so its socket closes.
        fn drop_all(&self) {
            for s in self.hub.lock().expect("hub").servers.drain(..) {
                s.abort();
            }
        }

        fn dials(&self) -> Vec<Instant> {
            self.hub.lock().expect("hub").dials.clone()
        }

        fn echoes(&self) -> usize {
            self.ctx.echo.load(Ordering::SeqCst)
        }

        fn slows(&self) -> usize {
            self.ctx.slow.load(Ordering::SeqCst)
        }
    }

    impl Connector for Fake {
        type R = ReadHalf<DuplexStream>;
        type W = WriteHalf<DuplexStream>;

        fn connect(&self) -> BoxFuture<'static, Result<(Self::R, Self::W), Dial>> {
            let (hub, ctx) = (self.hub.clone(), self.ctx.clone());
            Box::pin(async move {
                let mut h = hub.lock().expect("hub");
                h.dials.push(Instant::now());
                if !h.up {
                    return Err(Dial::Again("no hub".into()));
                }
                let (bridge_end, hub_end) = duplex(1 << 16);
                let (r, w) = split(hub_end);
                let tools = h.tools.clone();
                h.servers.push(tokio::spawn(serve(
                    ctx,
                    tools,
                    ServerInfo::default(),
                    r,
                    w,
                    Limits::default(),
                )));
                Ok(split(bridge_end))
            })
        }
    }

    /// The agent's side of a running bridge.
    struct Agent {
        w: WriteHalf<DuplexStream>,
        r: BufReader<ReadHalf<DuplexStream>>,
        bridge: JoinHandle<BridgeEnd>,
    }

    fn start(fake: &Fake, opts: BridgeOpts) -> Agent {
        let (agent_end, bridge_end) = duplex(1 << 20);
        let (stdin, stdout) = split(bridge_end);
        let bridge = tokio::spawn(run(fake.clone(), stdin, stdout, opts));
        let (r, w) = split(agent_end);
        Agent {
            w,
            r: BufReader::new(r),
            bridge,
        }
    }

    impl Agent {
        async fn send(&mut self, v: Value) {
            let mut line = v.to_string();
            line.push('\n');
            self.w.write_all(line.as_bytes()).await.expect("stdin");
        }

        async fn recv(&mut self) -> Value {
            let mut line = String::new();
            let n = self.r.read_line(&mut line).await.expect("stdout");
            assert!(n > 0, "the bridge closed stdout");
            serde_json::from_str(&line).expect("a JSON line")
        }

        /// `initialize` (2025-06-18) answered, then `notifications/initialized`.
        async fn handshake(&mut self) {
            self.send(req(
                0,
                "initialize",
                json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}),
            ))
            .await;
            let a = self.recv().await;
            assert_eq!(a["result"]["protocolVersion"], "2025-06-18", "{a}");
            self.send(json!({"jsonrpc": "2.0", "method": INITIALIZED}))
                .await;
        }
    }

    fn req(id: i64, method: &str, params: Value) -> Value {
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
    }

    fn call(id: i64, name: &str) -> Value {
        req(id, "tools/call", json!({"name": name, "arguments": {}}))
    }

    /// Wait (in steps of 1 ms, on the paused clock) until F holds.
    async fn until(what: &str, f: impl Fn() -> bool) {
        for _ in 0..1_000_000 {
            if f() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        panic!("never: {what}");
    }

    fn ms(d: Duration) -> u128 {
        d.as_millis()
    }

    #[tokio::test(start_paused = true)]
    async fn replays_initialize_and_drops_its_answer() {
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        a.send(call(1, "echo")).await;
        assert_eq!(a.recv().await["result"]["content"][0]["text"], "ok");
        fake.drop_all();
        until("the bridge redialed", || fake.dials().len() == 2).await;
        // no handshake from the agent: the replayed one serves, and its answer never reaches the agent
        a.send(call(2, "echo")).await;
        let answer = a.recv().await;
        assert_eq!(answer["id"], 2, "{answer}");
        assert_eq!(answer["result"]["content"][0]["text"], "ok", "{answer}");
        a.send(req(3, "ping", json!({}))).await;
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 3, "result": {}})
        );
        assert_eq!(fake.echoes(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_call_in_flight_at_the_drop_is_an_error_never_resent() {
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        a.send(call(1, "slow")).await;
        until("the hub has the call", || fake.slows() == 1).await;
        fake.drop_all();
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 1, "result": {
                "content": [{"type": "text", "text": WENT_AWAY}],
                "isError": true,
            }})
        );
        until("the bridge redialed", || fake.dials().len() == 2).await;
        a.send(call(2, "echo")).await;
        assert_eq!(a.recv().await["id"], 2);
        assert_eq!(fake.slows(), 1, "the call in flight was never sent again");
        // another request in flight is -32603
        a.send(req(3, "tools/call", json!({"name": "slow"}))).await;
        until("the hub has the second call", || fake.slows() == 2).await;
        // queued behind the call, which the hub never answers
        a.send(req(4, "tools/list", json!({}))).await;
        tokio::time::sleep(Duration::from_millis(1)).await;
        fake.drop_all();
        let mut answers = [a.recv().await, a.recv().await];
        answers.sort_by_key(|x| x["id"].as_i64());
        assert_eq!(answers[0]["result"]["isError"], true);
        assert_eq!(
            answers[1]["error"],
            json!({"code": INTERNAL_ERROR, "message": WENT_AWAY_ERROR})
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_call_while_away_waits_then_errors() {
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        fake.set_up(false);
        fake.drop_all();
        until("the bridge tried again", || fake.dials().len() >= 2).await;
        let t0 = Instant::now();
        a.send(call(1, "echo")).await;
        a.send(req(2, "resources/list", json!({}))).await;
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 1, "result": {
                "content": [{"type": "text", "text": RESTARTING}],
                "isError": true,
            }})
        );
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 2, "error": {"code": INTERNAL_ERROR, "message": RESTARTING_ERROR}})
        );
        let waited = t0.elapsed();
        assert!((10_000..10_100).contains(&ms(waited)), "waited {waited:?}");
        assert_eq!(fake.echoes(), 0);
        // the hub back within the wait: the call goes through
        let back = fake.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(3)).await;
            back.set_up(true);
        });
        a.send(call(3, "echo")).await;
        let answer = a.recv().await;
        assert_eq!(answer["id"], 3, "{answer}");
        assert_eq!(answer["result"]["content"][0]["text"], "ok", "{answer}");
        assert_eq!(fake.echoes(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn tools_list_from_the_cache_while_away() {
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        a.send(req(1, "tools/list", json!({}))).await;
        let listed = a.recv().await;
        assert_eq!(listed["result"]["tools"].as_array().map(Vec::len), Some(2));
        fake.set_up(false);
        fake.drop_all();
        until("the bridge tried again", || fake.dials().len() >= 2).await;
        let t0 = Instant::now();
        a.send(req(2, "tools/list", json!({}))).await;
        let cached = a.recv().await;
        assert_eq!(cached["id"], 2);
        assert_eq!(cached["result"], listed["result"]);
        a.send(req(3, "ping", json!({}))).await;
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 3, "result": {}})
        );
        assert!(ms(t0.elapsed()) < 100, "answered at once");
    }

    #[tokio::test(start_paused = true)]
    async fn list_changed_after_a_reconnect_with_other_tools() {
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        a.send(req(1, "tools/list", json!({}))).await;
        a.recv().await;
        fake.set_tools(other_tools());
        fake.drop_all();
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        );
        a.send(req(2, "tools/list", json!({}))).await;
        let listed = a.recv().await;
        assert_eq!(listed["result"]["tools"][1]["name"], "extra", "{listed}");
        // the same list after the next reconnect: nothing said
        fake.drop_all();
        until("the bridge redialed", || fake.dials().len() == 3).await;
        a.send(req(3, "ping", json!({}))).await;
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 3, "result": {}})
        );
    }

    #[tokio::test(start_paused = true)]
    async fn backoff_doubles_to_5s_and_gives_up() {
        assert_eq!(
            next_backoff(Duration::from_secs(4), Duration::from_secs(5)),
            Duration::from_secs(5)
        );
        let fake = Fake::new();
        fake.set_up(false);
        let t0 = Instant::now();
        let a = start(&fake, BridgeOpts::default());
        let end = a.bridge.await.expect("the bridge ends");
        assert!(matches!(end, BridgeEnd::GaveUp(_)), "{end:?}");
        assert_eq!(end.code(), 1);
        // the paused clock jumps to each timer: within a millisecond of the schedule
        let near = |got: u128, want: u128| got.abs_diff(want) <= 1;
        assert!(near(ms(t0.elapsed()), 600_000), "{:?}", t0.elapsed());
        let dials = fake.dials();
        assert!(near(ms(dials[0] - t0), 0), "the first dial is at once");
        let gaps: Vec<u128> = dials.windows(2).map(|w| ms(w[1] - w[0])).collect();
        let want = [100, 200, 400, 800, 1600, 3200, 5000, 5000];
        assert!(gaps.len() > want.len(), "{gaps:?}");
        assert!(gaps.iter().zip(want).all(|(g, w)| near(*g, w)), "{gaps:?}");
        assert!(gaps.iter().all(|g| *g <= 5001), "{gaps:?}");
        let last = dials.last().expect("dials");
        assert!(
            near(ms(*last - t0), 600_000),
            "the last dial is at the limit"
        );
        drop(a.w);
    }

    #[tokio::test(start_paused = true)]
    async fn stdin_eof_ends_it() {
        // a call in flight that the hub never answers
        let fake = Fake::new();
        let mut a = start(&fake, BridgeOpts::default());
        a.handshake().await;
        a.send(call(1, "slow")).await;
        until("the hub has the call", || fake.slows() == 1).await;
        a.w.shutdown().await.expect("close stdin");
        let end = tokio::time::timeout(Duration::from_millis(1), &mut a.bridge)
            .await
            .expect("ends at once")
            .expect("the bridge ends");
        assert_eq!(end, BridgeEnd::StdinClosed);
        assert_eq!(end.code(), 0);
        // away, with a request waiting
        let fake = Fake::new();
        fake.set_up(false);
        let mut a = start(&fake, BridgeOpts::default());
        a.send(call(1, "echo")).await;
        a.w.shutdown().await.expect("close stdin");
        let end = tokio::time::timeout(Duration::from_millis(1), &mut a.bridge)
            .await
            .expect("ends at once")
            .expect("the bridge ends");
        assert_eq!(end, BridgeEnd::StdinClosed);
    }

    #[tokio::test(start_paused = true)]
    async fn a_line_over_the_limit_is_32600_on_its_id_and_the_bridge_goes_on() {
        let fake = Fake::new();
        let opts = BridgeOpts {
            limits: Limits {
                max_in: 200,
                max_out: 1 << 20,
            },
            ..BridgeOpts::default()
        };
        let mut a = start(&fake, opts);
        a.handshake().await;
        let pad = "x".repeat(300);
        a.send(json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "echo", "arguments": {"pad": pad}}}))
            .await;
        let answer = a.recv().await;
        assert_eq!(answer["id"], 7, "{answer}");
        assert_eq!(answer["error"]["code"], INVALID_REQUEST);
        // a long notification has no id: dropped, and the next request is answered
        a.send(json!({"jsonrpc": "2.0", "method": "notifications/x", "params": {"pad": pad}}))
            .await;
        a.send(req(8, "ping", json!({}))).await;
        assert_eq!(
            a.recv().await,
            json!({"jsonrpc": "2.0", "id": 8, "result": {}})
        );
        assert_eq!(fake.echoes(), 0);
    }

    #[test]
    fn the_id_of_a_line_cut_short() {
        let cases: [(&str, Option<Id>); 9] = [
            (
                r#"{"jsonrpc":"2.0","id":7,"method":"x","params":{"a":"#,
                Some(Id::Num(7)),
            ),
            (r#" { "id" : "a\"b" , "#, Some(Id::Str("a\"b".into()))),
            (
                r#"{"method":"x","params":{"id":3,"b":[1,{"c":"}"}]},"id":-2,"#,
                Some(Id::Num(-2)),
            ),
            (r#"{"params":{"id":3},"method":"x","pad":"xxxx"#, None),
            (r#"{"jsonrpc":"2.0","method":"x","params":{"a":"#, None),
            (r#"{"id":7"#, None),
            (r#"{"id":1.5,"#, None),
            (r#"{"id":null,"#, None),
            (r#"[{"id":1}"#, None),
        ];
        for (line, want) in cases {
            assert_eq!(id_in_prefix(line.as_bytes()), want, "{line}");
        }
    }
}
