//! One connection (design 4.1, 5.3): the peer-uid check first, then the hub's challenge, then lines in through the
//! 1 MiB codec to [`Front::line`], and lines out through a writer task
//! of its own with a queue that drops a client that stopped reading (16 MiB queued, or 10 s without the write making
//! progress), so one stopped client never stalls another.  With the `test-hooks` feature a line calling
//! `__test_flood`, `__test_owner_gone` or `__test_advance` is served here, before the dispatcher (none is a method of
//! the registry).
//!
//! After `mcp/attach` is answered (an outside agent's bridge), the connection is MCP's: the answer and any call in
//! flight are written, and the bytes after the attach line go to [`crate::sessions::Sessions::serve_outside`].

use crate::clock;
use crate::front::Front;
use crate::hello::{Session, Socket};
use bytes::BytesMut;
use runstav::line;
use runstav::proof;
use runstav::wire::Event;
use serde_json::json;
use std::collections::VecDeque;
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

/// The lines waiting for one client.  Pushing never waits: a line that would put more than [`MAX_QUEUED`] in the
/// queue closes the connection instead.
pub struct Outbox {
    conn: u64,
    queue: Mutex<Queue>,
    wake: Notify,
    /// A line was written, or the queue dropped: what [`Outbox::flushed`] waits on.
    drained: Notify,
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
    pub fn new(conn: u64) -> Outbox {
        Outbox {
            conn,
            queue: Mutex::new(Queue {
                lines: VecDeque::new(),
                bytes: 0,
                finishing: false,
                closed: false,
            }),
            wake: Notify::new(),
            drained: Notify::new(),
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

    /// Close the connection now (logged once, with WHY): nothing more is written, and its lines are no longer read.
    pub fn close(&self, why: &str) {
        self.discard(why);
        self.closed.send_replace(true);
        self.wake.notify_one();
    }

    /// The client left (its socket refused a write): nothing more is written, but the lines it sent before it left are
    /// still read and served, to its end of file: a CLI that sends `exec/stop` as it exits, behind calls whose answers
    /// it no longer reads, still has its job stopped.  Logged once, with WHY.
    fn gone(&self, why: &str) {
        self.discard(why);
        self.wake.notify_one();
    }

    /// Drop what is queued and take no more (logged with WHY the first time).
    fn discard(&self, why: &str) {
        let mut q = self.queue.lock().expect("the queue lock");
        if q.closed {
            return;
        }
        q.closed = true;
        q.lines.clear();
        q.bytes = 0;
        drop(q);
        self.drained.notify_waiters();
        tracing::info!(conn = self.conn, "{why}");
    }

    /// Wait until everything queued so far is written (or the connection closed), at most WITHIN on the hub's clock.
    /// Woken by each write, never by polling: on the virtual clock a poll's sleep would wait for an advance.
    pub async fn flushed(&self, within: Duration) {
        let _ = clock::timeout(within, async {
            loop {
                let note = self.drained.notified();
                let mut note = std::pin::pin!(note);
                note.as_mut().enable();
                {
                    let q = self.queue.lock().expect("the queue lock");
                    if q.closed || q.lines.is_empty() {
                        return;
                    }
                }
                note.await;
            }
        })
        .await;
    }

    /// What is queued, taken (tests: an outbox without a writer).
    #[cfg(test)]
    pub(crate) fn take_lines(&self) -> Vec<Arc<str>> {
        let mut q = self.queue.lock().expect("the queue lock");
        q.bytes = 0;
        q.lines.drain(..).collect()
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
        drop(q);
        self.drained.notify_waiters();
    }

    /// EVENT with DATA on this connection only; an event over 16 MiB is not sent (logged).
    pub fn event(&self, event: &str, data: serde_json::Value) {
        let text = serde_json::to_string(&Event {
            event: event.into(),
            data,
        })
        .expect("an event serializes");
        if text.len() > line::MAX_HUB_LINE {
            tracing::warn!(
                conn = self.conn,
                event,
                bytes = text.len(),
                "an event over 16 MiB was not sent"
            );
            return;
        }
        self.push(format!("{text}\n").into());
    }
}

/// The writer task: lines in order, each write given [`STUCK_AFTER`] on the hub's clock to make progress.  When the
/// queue was finished
/// and written whole (never closed), the write half comes back: `mcp/attach` hands it on.
async fn write_loop(mut w: OwnedWriteHalf, out: Arc<Outbox>) -> Option<OwnedWriteHalf> {
    while let Some(line) = out.next().await {
        let mut rest = line.as_bytes();
        while !rest.is_empty() {
            let step = tokio::select! {
                r = clock::timeout(STUCK_AFTER, w.write(rest)) => r,
                () = out.closed() => return None,
            };
            match step {
                Ok(Ok(n)) if n > 0 => rest = &rest[n..],
                Ok(Ok(_)) | Ok(Err(_)) => {
                    out.gone("closed a client whose socket refused a write");
                    return None;
                }
                Err(_) => {
                    out.close("dropped a client that stopped reading: no progress for 10 s");
                    return None;
                }
            }
        }
        out.written(line.len());
    }
    let whole = !out.queue.lock().expect("the queue lock").closed;
    out.close("closed a connection");
    whole.then_some(w)
}

/// Serve one connection accepted on SOCKET until it closes.
pub async fn serve(stream: UnixStream, front: Arc<Front>, socket: Socket) {
    let id = front.next_conn();
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
    if !peer_allowed(cred.uid(), front.uid) {
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
    let writer = clock::spawn("conn:write", write_loop(w, out.clone()));
    let mut session = Session::new(id, socket);
    session.peer_pid = cred.pid();
    // the hub's challenge, the first line on every connection (design 4.2)
    match proof::nonce() {
        Ok(n) => {
            session.hub_nonce = n;
            out.event("challenge", json!({"nonce": session.hub_nonce}));
        }
        Err(e) => out.close(&format!("closed a connection: {e}")),
    }
    let mut codec = line::codec();
    let mut buf = BytesMut::with_capacity(8192);
    // `mcp/attach` answered: the identity the rest of the connection's bytes are MCP for
    let mut attached = None;
    'read: loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(l)) => {
                    #[cfg(feature = "test-hooks")]
                    if flood::serve(&out, &l).await
                        || owner_gone::serve(&front, &out, &l).await
                        || advance::serve(&out, &l).await
                    {
                        continue;
                    }
                    front.line(&mut session, &out, &l).await;
                    if let Some(who) = session.attach.take() {
                        // what follows the line in BUF is the first MCP bytes, never a hub line
                        attached = Some(who);
                        break 'read;
                    }
                }
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
    front.gone(id);
    let Some(who) = attached else {
        let _ = writer.await;
        return;
    };
    // the answer written first, then the connection is MCP's from its next byte
    out.finish();
    let Ok(Some(w)) = writer.await else {
        return;
    };
    let rest = std::io::Cursor::new(buf.to_vec());
    front.mcp.serve_outside(who, rest.chain(r), w).await;
}

/// `__test_owner_gone {owner}` (test-hooks): the sessions OWNER owns closed as if it had died, now; answered with how
/// many.
#[cfg(feature = "test-hooks")]
mod owner_gone {
    use super::Outbox;
    use crate::front::Front;
    use runstav::wire::{Answer, Request};
    use serde_json::json;

    /// Serve LINE when it is a `__test_owner_gone` request (true), else leave it to the dispatcher.
    pub(super) async fn serve(front: &Front, out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_owner_gone" {
            return false;
        }
        let owner = req.params["owner"]
            .as_u64()
            .and_then(|o| u32::try_from(o).ok())
            .unwrap_or(0);
        let closed = front.mcp.owner_gone(owner).await;
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result: json!({"closed": closed}),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
        }
        true
    }
}

/// `__test_advance {ms}` (test-hooks): the virtual clock moved by MS ([`clock::advance`]); answered with
/// `{now_ms, woken, busy, unnamed}`, or refused when the hub runs on the real clock (no `serve --test-clock`).
#[cfg(feature = "test-hooks")]
mod advance {
    use super::Outbox;
    use crate::clock;
    use runstav::wire::{Answer, Error, ErrorAnswer, ErrorCode, Request};
    use serde_json::json;
    use std::time::Duration;

    /// Serve LINE when it is a `__test_advance` request (true), else leave it to the dispatcher.
    pub(super) async fn serve(out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_advance" {
            return false;
        }
        let text = if !clock::is_virtual() {
            req.id.map(|id| {
                serde_json::to_string(&ErrorAnswer {
                    id,
                    error: Error {
                        code: ErrorCode::NotAllowed,
                        message: "the hub runs on the real clock".into(),
                        path: None,
                    },
                })
            })
        } else {
            let ms = req.params["ms"].as_u64().unwrap_or(0);
            let a = clock::advance(Duration::from_millis(ms)).await;
            req.id.map(|id| {
                serde_json::to_string(&Answer {
                    id,
                    result: json!({"now_ms": a.now_ms, "woken": a.woken, "busy": a.busy, "unnamed": a.unnamed}),
                    ignored: vec![],
                })
            })
        };
        if let Some(text) = text {
            out.push(format!("{}\n", text.expect("an answer serializes")).into());
        }
        true
    }
}

/// `__test_flood {lines, size}` (test-hooks): LINES `flood` events of SIZE bytes of data, one per millisecond, on
/// this connection; answered with how many were queued before the connection was dropped.
#[cfg(feature = "test-hooks")]
mod flood {
    use super::Outbox;
    use runstav::line::MAX_HUB_LINE;
    use runstav::wire::{Answer, Event, Request};
    use serde_json::{Value, json};
    use std::sync::Arc;
    use std::time::Duration;

    /// Serve LINE when it is a `__test_flood` request (true), else leave it to the dispatcher.
    pub(super) async fn serve(out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_flood" {
            return false;
        }
        let lines = req.params["lines"].as_u64().unwrap_or(0);
        let size = req.params["size"]
            .as_u64()
            .unwrap_or(0)
            .min((MAX_HUB_LINE as u64) - 64);
        let event = serde_json::to_string(&Event {
            event: "flood".into(),
            data: Value::String("x".repeat(size as usize)),
        })
        .expect("an event serializes");
        let event: Arc<str> = format!("{event}\n").into();
        let mut queued = 0u64;
        while queued < lines && out.push(event.clone()) {
            queued += 1;
            crate::clock::sleep(Duration::from_millis(1)).await;
        }
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result: json!({"queued": queued}),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
        }
        true
    }
}
