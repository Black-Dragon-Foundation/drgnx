//! A small LSP client for the `lsp-command` start kind (language packs Task 10j): JSON-RPC over `Content-Length`
//! frames, enough to start a language server, ask it for a command's answer and read what it says on its way. It
//! knows nothing of any language. Every wait has a deadline, every frame a cap, and the end of the server's output
//! (or a bad frame) fails every waiting request at once, with the reason.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};
use tokio::sync::{oneshot, watch};

/// The largest frame the client reads. A frame over it ends the connection (the server's answers are small).
pub const MAX_FRAME: usize = 16 << 20;
/// The largest header block of one frame.
const MAX_HEADER: usize = 8 << 10;
/// How many lines of what the server logged are kept.
const LOG_LINES: usize = 40;

/// Why a request or the connection failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The server's output ended (it exited or closed its stdout), or its input broke.
    Closed(String),
    /// A frame announced more than [`MAX_FRAME`] bytes (or a header block was over its cap).
    TooLarge(usize),
    /// A frame that is not a JSON-RPC message.
    BadFrame(String),
    /// No answer within the deadline.
    Deadline { what: String, secs: u64 },
    /// The server answered with an error.
    Server { code: i64, message: String },
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::Closed(why) => write!(f, "the language server's connection ended: {why}"),
            Failure::TooLarge(n) => write!(
                f,
                "the language server sent a frame of {n} bytes, over the {MAX_FRAME}-byte cap"
            ),
            Failure::BadFrame(why) => write!(f, "the language server sent a bad frame: {why}"),
            Failure::Deadline { what, secs } => {
                write!(
                    f,
                    "the language server did not answer {what} within {secs} s"
                )
            }
            Failure::Server { code, message } => {
                write!(f, "the language server refused ({code}): {message}")
            }
        }
    }
}

type Pending = Mutex<HashMap<i64, oneshot::Sender<Result<Value, Failure>>>>;

/// One frame from R: `None` at a clean end of input. Headers other than `Content-Length` are skipped; a length over MAX
/// is [`Failure::TooLarge`] before a byte of the body is read.
pub async fn read_frame<R: AsyncBufRead + Unpin>(
    r: &mut R,
    max: usize,
) -> Result<Option<Value>, Failure> {
    let mut length: Option<usize> = None;
    let mut header_bytes = 0usize;
    let mut first = true;
    // what came before the end, for the error (a server that prints a message instead of a frame)
    let mut seen = String::new();
    loop {
        let mut line = String::new();
        // a header line is read one byte at a time past its cap check: `read_line` would buffer without a limit
        let n = read_line_capped(r, &mut line, MAX_HEADER - header_bytes.min(MAX_HEADER - 1))
            .await
            .map_err(|e| Failure::Closed(e.to_string()))?;
        if n == 0 {
            return if first {
                Ok(None)
            } else {
                Err(Failure::Closed(format!(
                    "the input ended inside a header (after {:?})",
                    seen.chars().take(200).collect::<String>()
                )))
            };
        }
        first = false;
        seen.push_str(&line);
        header_bytes += n;
        if header_bytes > MAX_HEADER {
            return Err(Failure::TooLarge(header_bytes));
        }
        let l = line.trim_end_matches(['\r', '\n']);
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':')
            && k.trim().eq_ignore_ascii_case("content-length")
        {
            length = Some(
                v.trim()
                    .parse()
                    .map_err(|_| Failure::BadFrame(format!("Content-Length {v:?}")))?,
            );
        }
    }
    let len = length.ok_or_else(|| Failure::BadFrame("no Content-Length".into()))?;
    if len > max {
        return Err(Failure::TooLarge(len));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)
        .await
        .map_err(|e| Failure::Closed(format!("the input ended inside a body: {e}")))?;
    serde_json::from_slice(&body)
        .map(Some)
        .map_err(|e| Failure::BadFrame(e.to_string()))
}

/// A line of R (to `\n`) appended to LINE, at most CAP bytes: the count read; over the cap it stops with the cap's worth.
async fn read_line_capped<R: AsyncBufRead + Unpin>(
    r: &mut R,
    line: &mut String,
    cap: usize,
) -> std::io::Result<usize> {
    let mut bytes = Vec::new();
    loop {
        let buf = r.fill_buf().await?;
        if buf.is_empty() {
            break;
        }
        let take = buf
            .iter()
            .position(|b| *b == b'\n')
            .map_or(buf.len(), |i| i + 1);
        let take = take.min(cap.saturating_sub(bytes.len()).max(1));
        bytes.extend_from_slice(&buf[..take]);
        let done = bytes.last() == Some(&b'\n');
        r.consume(take);
        if done || bytes.len() >= cap {
            break;
        }
    }
    let n = bytes.len();
    line.push_str(&String::from_utf8_lossy(&bytes));
    Ok(n)
}

/// What the server said on the side.
#[derive(Default)]
struct Side {
    ready: bool,
    log: Vec<String>,
    /// The `language/status` types the server announced, in order.
    statuses: Vec<String>,
}

/// A connection to a language server.
pub struct Client {
    writer: tokio::sync::Mutex<Box<dyn AsyncWrite + Send + Unpin>>,
    pending: Arc<Pending>,
    next: AtomicI64,
    side: Arc<Mutex<Side>>,
    /// Set once the server's output ended or broke: the reason.
    closed: watch::Receiver<Option<Failure>>,
    ready: watch::Receiver<bool>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Client {
    /// A client over READER and WRITER (the server's stdout and stdin). A task reads frames until the end.
    pub fn new<R, W>(reader: R, writer: W) -> Arc<Client>
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        let pending: Arc<Pending> = Arc::new(Mutex::new(HashMap::new()));
        let side = Arc::new(Mutex::new(Side::default()));
        let (closed_tx, closed) = watch::channel(None);
        let (ready_tx, ready) = watch::channel(false);
        let client = Arc::new(Client {
            writer: tokio::sync::Mutex::new(Box::new(writer)),
            pending: pending.clone(),
            next: AtomicI64::new(1),
            side: side.clone(),
            closed,
            ready,
        });
        let weak = Arc::downgrade(&client);
        crate::clock::spawn("debug:lsp-reader", async move {
            let mut reader = BufReader::new(reader);
            let end = loop {
                match read_frame(&mut reader, MAX_FRAME).await {
                    Ok(Some(msg)) => {
                        let Some(client) = weak.upgrade() else { return };
                        client.dispatch(msg, &ready_tx).await;
                    }
                    Ok(None) => break Failure::Closed("the server closed its output".into()),
                    Err(f) => break f,
                }
            };
            let _ = closed_tx.send(Some(end.clone()));
            for (_, tx) in lock(&pending).drain() {
                let _ = tx.send(Err(end.clone()));
            }
        });
        client
    }

    async fn dispatch(&self, msg: Value, ready: &watch::Sender<bool>) {
        let id = msg.get("id").cloned();
        let method = msg.get("method").and_then(Value::as_str).map(str::to_owned);
        match (id, method) {
            // an answer
            (Some(id), None) => {
                let Some(id) = id.as_i64() else { return };
                let tx = lock(&self.pending).remove(&id);
                if let Some(tx) = tx {
                    let r = match msg.get("error") {
                        Some(e) => Err(Failure::Server {
                            code: e.get("code").and_then(Value::as_i64).unwrap_or(0),
                            message: e
                                .get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("no message")
                                .chars()
                                .take(500)
                                .collect(),
                        }),
                        None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
                    };
                    let _ = tx.send(r);
                }
            }
            // a request of the server's (`workspace/configuration`, `client/registerCapability`, progress): answered null,
            // so it never waits on us
            (Some(id), Some(_)) => {
                let _ = self
                    .send(&json!({"jsonrpc": "2.0", "id": id, "result": Value::Null}))
                    .await;
            }
            // a notification
            (None, Some(method)) => {
                let params = msg.get("params");
                match method.as_str() {
                    "language/status" => {
                        let t = params.and_then(|p| p.get("type")).and_then(Value::as_str);
                        if let Some(t) = t {
                            let mut s = lock(&self.side);
                            if s.statuses.len() < 64 {
                                s.statuses.push(t.to_owned());
                            }
                        }
                        if matches!(t, Some("ServiceReady" | "Started")) {
                            lock(&self.side).ready = true;
                            let _ = ready.send(true);
                        }
                    }
                    "window/logMessage" | "window/showMessage" => {
                        if let Some(m) = params
                            .and_then(|p| p.get("message"))
                            .and_then(Value::as_str)
                        {
                            let mut s = lock(&self.side);
                            s.log.push(m.chars().take(300).collect());
                            if s.log.len() > LOG_LINES {
                                s.log.remove(0);
                            }
                        }
                    }
                    _ => {}
                }
            }
            (None, None) => {}
        }
    }

    async fn send(&self, msg: &Value) -> Result<(), Failure> {
        let body = serde_json::to_vec(msg).map_err(|e| Failure::BadFrame(e.to_string()))?;
        let mut w = self.writer.lock().await;
        let head = format!("Content-Length: {}\r\n\r\n", body.len());
        w.write_all(head.as_bytes())
            .await
            .map_err(|e| Failure::Closed(e.to_string()))?;
        w.write_all(&body)
            .await
            .map_err(|e| Failure::Closed(e.to_string()))?;
        w.flush().await.map_err(|e| Failure::Closed(e.to_string()))
    }

    /// METHOD with PARAMS, answered within WITHIN (WHAT names it in the deadline error).
    pub async fn request(
        &self,
        method: &str,
        params: Value,
        within: Duration,
    ) -> Result<Value, Failure> {
        self.request_named(method, method, params, within).await
    }

    async fn request_named(
        &self,
        what: &str,
        method: &str,
        params: Value,
        within: Duration,
    ) -> Result<Value, Failure> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        // insert first, then look at `closed`: the reader marks the client closed before it drains `pending`, so a
        // request is either refused here or drained there, never left to wait for its deadline
        lock(&self.pending).insert(id, tx);
        if let Some(f) = self.closed.borrow().clone() {
            lock(&self.pending).remove(&id);
            return Err(f);
        }
        let sent = self
            .send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .await;
        if let Err(f) = sent {
            lock(&self.pending).remove(&id);
            return Err(f);
        }
        match crate::clock::timeout(within, rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err(self
                .closed
                .borrow()
                .clone()
                .unwrap_or_else(|| Failure::Closed("the connection dropped".into()))),
            Err(_) => {
                lock(&self.pending).remove(&id);
                Err(Failure::Deadline {
                    what: what.to_owned(),
                    secs: within.as_secs(),
                })
            }
        }
    }

    /// `workspace/executeCommand` for COMMAND with PARAMS, answered within WITHIN: a deadline names COMMAND, not the method.
    pub async fn command(
        &self,
        command: &str,
        params: Value,
        within: Duration,
    ) -> Result<Value, Failure> {
        self.request_named(command, "workspace/executeCommand", params, within)
            .await
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<(), Failure> {
        self.send(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    /// Waits for the server to say it is ready (`language/status` ServiceReady), or fails when its output ends first
    /// or WITHIN passes.
    pub async fn wait_ready(&self, within: Duration) -> Result<(), Failure> {
        let (mut ready, mut closed) = (self.ready.clone(), self.closed.clone());
        let wait = async {
            loop {
                if *ready.borrow() {
                    return Ok(());
                }
                if let Some(f) = closed.borrow().clone() {
                    return Err(f);
                }
                tokio::select! {
                    r = ready.changed() => { if r.is_err() { return Err(Failure::Closed("the connection dropped".into())); } }
                    c = closed.changed() => { if c.is_err() { return Err(Failure::Closed("the connection dropped".into())); } }
                }
            }
        };
        match crate::clock::timeout(within, wait).await {
            Ok(r) => r,
            Err(_) => Err(Failure::Deadline {
                what: "the start (ServiceReady)".into(),
                secs: within.as_secs(),
            }),
        }
    }

    /// The `language/status` types the server has announced so far (for an error message).
    pub fn statuses(&self) -> Vec<String> {
        lock(&self.side).statuses.clone()
    }

    /// What the server logged last, newest last (for an error message).
    pub fn log_tail(&self) -> Vec<String> {
        lock(&self.side).log.clone()
    }
}
