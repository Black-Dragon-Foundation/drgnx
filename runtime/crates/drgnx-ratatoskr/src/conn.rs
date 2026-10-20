//! One connection (design 4.1, 5.3): the peer-uid check first, then lines in through the 1 MiB codec, and lines out
//! through a writer task of its own with a queue that drops a client that stopped reading (16 MiB queued, or 10 s
//! without the write making progress), so one stopped client never stalls another.
//!
//! The dispatcher here is the server core's stub: `ping`, a minimal `hello` (the challenge, then `user` for a valid
//! proof) so a user connection works end to end, and with the `test-hooks` feature `__test_flood`.  The hello task
//! replaces it with the registry's dispatcher.

use bytes::BytesMut;
use drgnx_proto::line::{self, MAX_HUB_LINE};
use drgnx_proto::proof::{self, Cap};
use drgnx_proto::wire::{Answer, Error, ErrorAnswer, ErrorCode, Event, Id, Request};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::{Notify, watch};
use tokio_util::codec::Decoder;

/// A client is dropped when more than this is queued for it (bytes, the line being written included).
pub const MAX_QUEUED: usize = 16 << 20;

/// A client is dropped when a write to it makes no progress for this long.
pub const STUCK_AFTER: Duration = Duration::from_secs(10);

/// May a peer of PEER_UID talk to a hub running as OWN_UID?  Only the same uid: another user (root included) is
/// closed at once.
pub fn peer_allowed(peer_uid: u32, own_uid: u32) -> bool {
    peer_uid == own_uid
}

/// What every connection shares.
pub struct Shared {
    pub cap: Cap,
    pub pid: u32,
    pub uid: u32,
    next_conn: AtomicU64,
}

impl Shared {
    pub fn new(cap: Cap) -> Shared {
        Shared {
            cap,
            pid: std::process::id(),
            uid: rustix::process::geteuid().as_raw(),
            next_conn: AtomicU64::new(1),
        }
    }
}

/// The lines waiting for one client.  Pushing never waits: a line that would put more than [`MAX_QUEUED`] in the
/// queue closes the connection instead.
pub struct Outbox {
    conn: u64,
    queue: Mutex<Queue>,
    wake: Notify,
    closed: watch::Sender<bool>,
}

struct Queue {
    lines: VecDeque<Arc<str>>,
    bytes: usize,
    /// Nothing more is queued: the writer ends once the queue is written (the client sent EOF).
    finishing: bool,
    closed: bool,
}

impl Outbox {
    fn new(conn: u64) -> Outbox {
        Outbox {
            conn,
            queue: Mutex::new(Queue {
                lines: VecDeque::new(),
                bytes: 0,
                finishing: false,
                closed: false,
            }),
            wake: Notify::new(),
            closed: watch::channel(false).0,
        }
    }

    /// Queue LINE (with its newline); false when the connection is closed, or is closed now for being over the limit.
    pub fn push(&self, line: Arc<str>) -> bool {
        let mut q = self.queue.lock().expect("the queue lock");
        if q.closed || q.finishing {
            return false;
        }
        if q.bytes + line.len() > MAX_QUEUED {
            drop(q);
            self.close("dropped a client that stopped reading: queued over 16 MiB");
            return false;
        }
        q.bytes += line.len();
        q.lines.push_back(line);
        drop(q);
        self.wake.notify_one();
        true
    }

    /// Close the connection now (logged once, with WHY).
    pub fn close(&self, why: &str) {
        let mut q = self.queue.lock().expect("the queue lock");
        if q.closed {
            return;
        }
        q.closed = true;
        q.lines.clear();
        q.bytes = 0;
        drop(q);
        tracing::info!(conn = self.conn, "{why}");
        self.closed.send_replace(true);
        self.wake.notify_one();
    }

    /// No more lines: the writer ends after what is queued.
    fn finish(&self) {
        self.queue.lock().expect("the queue lock").finishing = true;
        self.wake.notify_one();
    }

    async fn closed(&self) {
        let mut rx = self.closed.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }

    /// The line to write next (left queued until written); none when the writer is to end.
    async fn next(&self) -> Option<Arc<str>> {
        loop {
            {
                let q = self.queue.lock().expect("the queue lock");
                if q.closed {
                    return None;
                }
                if let Some(l) = q.lines.front() {
                    return Some(l.clone());
                }
                if q.finishing {
                    return None;
                }
            }
            self.wake.notified().await;
        }
    }

    fn written(&self, len: usize) {
        let mut q = self.queue.lock().expect("the queue lock");
        if !q.closed {
            q.lines.pop_front();
            q.bytes -= len;
        }
    }
}

/// The writer task: lines in order, each write given [`STUCK_AFTER`] to make progress.
async fn write_loop(mut w: OwnedWriteHalf, out: Arc<Outbox>) {
    while let Some(line) = out.next().await {
        let mut rest = line.as_bytes();
        while !rest.is_empty() {
            let step = tokio::select! {
                r = tokio::time::timeout(STUCK_AFTER, w.write(rest)) => r,
                () = out.closed() => return,
            };
            match step {
                Ok(Ok(n)) if n > 0 => rest = &rest[n..],
                Ok(Ok(_)) | Ok(Err(_)) => {
                    out.close("closed a client whose socket refused a write");
                    return;
                }
                Err(_) => {
                    out.close("dropped a client that stopped reading: no progress for 10 s");
                    return;
                }
            }
        }
        out.written(line.len());
    }
    out.close("closed a connection");
}

/// Serve one accepted connection until it closes.
pub async fn serve(stream: UnixStream, shared: Arc<Shared>) {
    let id = shared.next_conn.fetch_add(1, Ordering::Relaxed);
    let cred = match stream.peer_cred() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(
                conn = id,
                "refused a connection whose peer cannot be read: {e}"
            );
            return;
        }
    };
    if !peer_allowed(cred.uid(), shared.uid) {
        tracing::warn!(
            conn = id,
            peer_pid = cred.pid(),
            peer_uid = cred.uid(),
            "refused a connection from another uid"
        );
        return;
    }
    tracing::debug!(conn = id, peer_pid = cred.pid(), "accepted a connection");
    let (mut r, w) = stream.into_split();
    let out = Arc::new(Outbox::new(id));
    let writer = tokio::spawn(write_loop(w, out.clone()));
    let mut c = Conn {
        id,
        shared,
        out: out.clone(),
        hub_nonce: String::new(),
    };
    c.challenge();
    let mut codec = line::codec();
    let mut buf = BytesMut::with_capacity(8192);
    'read: loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(l)) => c.line(&l).await,
                Ok(None) => break,
                Err(e) => {
                    out.close(&format!("closed a connection: {e}"));
                    break 'read;
                }
            }
        }
        let n = tokio::select! {
            n = r.read_buf(&mut buf) => n,
            () = out.closed() => break,
        };
        match n {
            // EOF: a partial line is dropped with the connection; what is queued is still written
            Ok(0) => {
                out.finish();
                break;
            }
            Ok(_) => {}
            Err(e) => {
                out.close(&format!("closed a connection: {e}"));
                break;
            }
        }
    }
    let _ = writer.await;
}

struct Conn {
    id: u64,
    shared: Arc<Shared>,
    out: Arc<Outbox>,
    hub_nonce: String,
}

impl Conn {
    /// The hub's challenge, the first line on every connection (design 4.2).
    fn challenge(&mut self) {
        match proof::nonce() {
            Ok(n) => self.hub_nonce = n,
            Err(e) => {
                self.out.close(&format!("closed a connection: {e}"));
                return;
            }
        }
        self.event("challenge", json!({"nonce": self.hub_nonce}));
    }

    async fn line(&mut self, text: &str) {
        let v = match line::parse_strict(text) {
            Ok(v) => v,
            Err(e) => {
                match e.id {
                    Some(id) => self.answer(id, Err(invalid(e.message, e.path))),
                    None => tracing::info!(
                        conn = self.id,
                        "dropped a line that is no request and has no id: {}",
                        e.message
                    ),
                }
                return;
            }
        };
        let req: Request = match serde_json::from_value(v.clone()) {
            Ok(r) => r,
            Err(e) => {
                match v
                    .get("id")
                    .and_then(|i| serde_json::from_value::<Id>(i.clone()).ok())
                {
                    Some(id) => self.answer(id, Err(invalid(format!("not a request: {e}"), None))),
                    None => tracing::info!(
                        conn = self.id,
                        "dropped a line that is no request and has no id: {e}"
                    ),
                }
                return;
            }
        };
        let result = self.dispatch(&req).await;
        if let Some(id) = req.id {
            self.answer(id, result);
        }
    }

    /// The stub dispatcher (the hello task replaces it).
    async fn dispatch(&mut self, req: &Request) -> Result<Value, Error> {
        match req.method.as_str() {
            "ping" => Ok(json!({"pid": self.shared.pid})),
            "hello" => self.hello(&req.params),
            #[cfg(feature = "test-hooks")]
            "__test_flood" => self.flood(&req.params).await,
            m => Err(Error {
                code: ErrorCode::NoMethod,
                message: format!("no method {m}"),
                path: None,
            }),
        }
    }

    /// The minimal `hello` of the server core: a valid proof over both nonces makes the connection `user` and is
    /// answered with the hub's proof; a wrong one is refused; none leaves it `service`.
    fn hello(&mut self, params: &Value) -> Result<Value, Error> {
        let nonce = params["nonce"]
            .as_str()
            .ok_or_else(|| invalid("nonce: a string is needed".into(), Some("nonce".into())))?;
        match params.get("proof") {
            None => Ok(json!({"proto": 1, "class": "service"})),
            Some(p) => {
                let given = p.as_str().unwrap_or_default();
                let want = proof::client_proof(&self.shared.cap, &self.hub_nonce, nonce);
                if !proof::verify(&want, given) {
                    tracing::warn!(conn = self.id, "refused a hello with a wrong proof");
                    return Err(Error {
                        code: ErrorCode::NotAllowed,
                        message: "wrong proof".into(),
                        path: None,
                    });
                }
                let mine = proof::hub_proof(&self.shared.cap, nonce, &self.hub_nonce);
                Ok(json!({"proto": 1, "class": "user", "proof": mine}))
            }
        }
    }

    /// `__test_flood {lines, size}`: LINES `flood` events of SIZE bytes of data, one per millisecond, on this
    /// connection; answered with how many were queued before the connection was dropped.
    #[cfg(feature = "test-hooks")]
    async fn flood(&mut self, params: &Value) -> Result<Value, Error> {
        let lines = params["lines"]
            .as_u64()
            .ok_or_else(|| invalid("lines: a number is needed".into(), Some("lines".into())))?;
        let size = params["size"]
            .as_u64()
            .filter(|s| *s <= (MAX_HUB_LINE as u64) - 64)
            .ok_or_else(|| {
                invalid(
                    "size: a number up to 16 MiB is needed".into(),
                    Some("size".into()),
                )
            })?;
        let event = serde_json::to_string(&Event {
            event: "flood".into(),
            data: Value::String("x".repeat(size as usize)),
        })
        .expect("an event serializes");
        let line: Arc<str> = format!("{event}\n").into();
        let mut queued = 0u64;
        while queued < lines && self.out.push(line.clone()) {
            queued += 1;
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        Ok(json!({"queued": queued}))
    }

    fn answer(&self, id: Id, result: Result<Value, Error>) {
        let text = match result {
            Ok(result) => serde_json::to_string(&Answer {
                id: id.clone(),
                result,
                ignored: vec![],
            }),
            Err(error) => serde_json::to_string(&ErrorAnswer {
                id: id.clone(),
                error,
            }),
        }
        .expect("an answer serializes");
        let text = if text.len() > MAX_HUB_LINE {
            tracing::warn!(
                conn = self.id,
                bytes = text.len(),
                "an answer over 16 MiB was replaced"
            );
            serde_json::to_string(&ErrorAnswer {
                id,
                error: Error {
                    code: ErrorCode::Internal,
                    message: "answer over 16 MiB".into(),
                    path: None,
                },
            })
            .expect("an error serializes")
        } else {
            text
        };
        self.out.push(format!("{text}\n").into());
    }

    fn event(&self, event: &str, data: Value) {
        let text = serde_json::to_string(&Event {
            event: event.into(),
            data,
        })
        .expect("an event serializes");
        if text.len() > MAX_HUB_LINE {
            tracing::warn!(
                conn = self.id,
                event,
                bytes = text.len(),
                "an event over 16 MiB was not sent"
            );
            return;
        }
        self.out.push(format!("{text}\n").into());
    }
}

fn invalid(message: String, path: Option<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message,
        path,
    }
}
