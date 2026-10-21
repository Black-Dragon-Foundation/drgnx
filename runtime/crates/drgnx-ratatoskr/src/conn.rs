//! One connection (design 4.1, 5.3): the peer-uid check first, then the hub's challenge, then lines in through the
//! 1 MiB codec to [`Front::start_line`] (at most 64 forwarded calls in flight), and lines out through a writer task
//! of its own with a queue that drops a client that stopped reading (16 MiB queued, or 10 s without the write making
//! progress), so one stopped client never stalls another.  With the `test-hooks` feature a line calling `__test_flood` is served here, before the
//! dispatcher (it is no method of the registry).

use crate::front::{Front, MAX_IN_FLIGHT};
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
use tokio::sync::{Notify, Semaphore, watch};
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

    /// Wait until everything queued so far is written (or the connection closed), at most WITHIN.
    pub async fn flushed(&self, within: Duration) {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            {
                let q = self.queue.lock().expect("the queue lock");
                if q.closed || q.lines.is_empty() {
                    return;
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
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
    let writer = tokio::spawn(write_loop(w, out.clone()));
    let mut session = Session::new(id, socket);
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
    // this connection's forwarded calls in flight
    let slots = Arc::new(Semaphore::new(MAX_IN_FLIGHT));
    'read: loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(l)) => {
                    #[cfg(feature = "test-hooks")]
                    if flood::serve(&out, &l).await {
                        continue;
                    }
                    front.start_line(&mut session, &out, &l, &slots).await;
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
            // EOF: a partial line is dropped with the connection; what is queued is still written, the answers of
            // the calls in flight too (each ends by its deadline)
            Ok(0) => {
                let _ = slots.acquire_many(MAX_IN_FLIGHT as u32).await;
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
    let _ = writer.await;
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
            tokio::time::sleep(Duration::from_millis(1)).await;
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
