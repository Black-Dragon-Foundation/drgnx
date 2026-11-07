//! One connection (design 4.1, 5.3): the peer-uid check first, then the hub's challenge, then lines in through the
//! 1 MiB codec to [`Front::line`], and lines out through a writer task
//! of its own with a queue that drops a client that stopped reading (16 MiB queued, or 10 s without the write making
//! progress), so one stopped client never stalls another.  With the `test-hooks` feature a line calling
//! `__test_flood`, `__test_owner_gone`, `__test_advance`, `__test_matrix_ask`, `__test_browser_endpoint` or `__test_view_rows` is served
//! here, before the dispatcher (none is a method of the registry), and under `serve --test-sequencer` lines are read and
//! served in the order the `sequencer` gives (`__test_barrier` is its own).
//!
//! The queue and the choice between reading and stopping are a pure core (`pure`, tested in every order); this file is
//! the shell that does the I/O and feeds the core every event.
//!
//! After `mcp/attach` is answered (an outside agent's bridge), the connection is MCP's: the answer and any call in
//! flight are written, and the bytes after the attach line go to [`crate::sessions::Sessions::serve_outside`].

mod pure;
#[cfg(test)]
mod tests;

use crate::clock;
use crate::front::Front;
use crate::hello::{Session, Socket};
use bytes::BytesMut;
use pure::{ConnCore, ConnEffect, ConnEvent};
use runstav::line;
use runstav::proof;
use runstav::wire::Event;
use serde_json::json;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
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

/// The core, and the lines its queue counts.
struct Queue {
    core: ConnCore,
    lines: VecDeque<Arc<str>>,
    /// Every event fed to the core, in order (tests: the shell's edges).
    #[cfg(test)]
    events: Vec<ConnEvent>,
}

impl Queue {
    /// EV through the core; LINE, if the core queues it, joins the lines, which follow its effects.
    fn step(&mut self, ev: ConnEvent, line: Option<Arc<str>>) -> Vec<ConnEffect> {
        #[cfg(test)]
        self.events.push(ev);
        let effects = self.core.step(ev);
        for e in &effects {
            match e {
                ConnEffect::Queue => self.lines.extend(line.clone()),
                ConnEffect::Drop => self.lines.clear(),
                ConnEffect::Pop => {
                    self.lines.pop_front();
                }
                ConnEffect::Refuse | ConnEffect::Log | ConnEffect::Serve | ConnEffect::Skip => {}
            }
        }
        effects
    }
}

impl Outbox {
    pub fn new(conn: u64) -> Outbox {
        Outbox {
            conn,
            queue: Mutex::new(Queue {
                core: ConnCore::new(),
                lines: VecDeque::new(),
                #[cfg(test)]
                events: Vec::new(),
            }),
            wake: Notify::new(),
            drained: Notify::new(),
            closed: watch::channel(false).0,
        }
    }

    /// Queue LINE (with its newline); false when the connection is closed, or is closed now for being over the limit.
    /// Under the test-hooks sequencer a push outside a serving step is held (and true) until the sequencer releases it.
    pub fn push(&self, line: Arc<str>) -> bool {
        #[cfg(feature = "test-hooks")]
        if let Some(seq) = crate::sequencer::current()
            && !crate::sequencer::serving()
        {
            seq.hold(self.conn, line);
            return true;
        }
        self.push_now(line)
    }

    /// [`Outbox::push`] at once, whatever step this is.
    pub(crate) fn push_now(&self, line: Arc<str>) -> bool {
        let len = line.len();
        self.step_with(
            ConnEvent::Push { len },
            "dropped a client that stopped reading: queued over 16 MiB",
            Some(line),
        )
        .contains(&ConnEffect::Queue)
    }

    /// Close the connection now (logged once, with WHY): nothing more is written, and its lines are no longer read.
    pub fn close(&self, why: &str) {
        self.step(ConnEvent::Close, why);
    }

    /// The client left (its socket refused a write): nothing more is written, but the lines it sent before it left are
    /// still read and served, to its end of file: a CLI that sends `exec/stop` as it exits, behind calls whose answers
    /// it no longer reads, still has its job stopped.  Logged once, with WHY.
    fn gone(&self, why: &str) {
        self.step(ConnEvent::WriteRefused, why);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Queue> {
        self.queue.lock().expect("the queue lock")
    }

    /// EV through the core (WHY logged if it is the connection's first close).
    fn step(&self, ev: ConnEvent, why: &str) -> Vec<ConnEffect> {
        self.step_with(ev, why, None)
    }

    fn step_with(&self, ev: ConnEvent, why: &str, line: Option<Arc<str>>) -> Vec<ConnEffect> {
        let mut q = self.lock();
        let effects = q.step(ev, line);
        let closed = q.core.closed();
        drop(q);
        if effects.contains(&ConnEffect::Log) {
            tracing::info!(conn = self.conn, "{why}");
        }
        if effects.contains(&ConnEffect::Drop) || effects.contains(&ConnEffect::Pop) {
            self.drained.notify_waiters();
        }
        // the reader's choice: its socket, or this close
        if closed {
            self.closed
                .send_if_modified(|c| !std::mem::replace(c, true));
        }
        self.wake.notify_one();
        effects
    }

    /// Is the line just read served (true), or has reading stopped?
    fn line_read(&self) -> bool {
        self.step(ConnEvent::LineRead, "") == [ConnEffect::Serve]
    }

    /// Are the client's lines still read?
    fn reading(&self) -> bool {
        self.lock().core.reading()
    }

    /// Reading the client's socket failed (logged once, with WHY).
    fn read_error(&self, why: &str) {
        self.step(ConnEvent::ReadError, why);
    }

    /// A write made no progress for [`STUCK_AFTER`] (logged once, with WHY).
    fn stuck(&self, why: &str) {
        self.step(ConnEvent::WriteStuck, why);
    }

    /// The connection is MCP's from its next byte: no more lines are read; the writer ends after what is queued.
    fn attached(&self) {
        self.step(ConnEvent::Attach, "");
    }

    /// Every event fed to the core so far (tests).
    #[cfg(test)]
    fn events(&self) -> Vec<ConnEvent> {
        self.lock().events.clone()
    }

    /// Wait until everything queued so far is written (or the connection closed), at most WITHIN on the hub's clock.
    /// Woken by each write, never by polling: on the virtual clock a poll's sleep would wait for an advance.
    pub async fn flushed(&self, within: Duration) {
        let _ = clock::timeout(within, async {
            loop {
                let note = self.drained.notified();
                let mut note = std::pin::pin!(note);
                note.as_mut().enable();
                if self.lock().core.queued_bytes() == 0 {
                    return;
                }
                note.await;
            }
        })
        .await;
    }

    /// What is queued, taken (tests: an outbox without a writer).
    #[cfg(test)]
    pub(crate) fn take_lines(&self) -> Vec<Arc<str>> {
        let mut q = self.lock();
        let mut taken = Vec::new();
        while let Some(l) = q.lines.front().cloned() {
            q.step(ConnEvent::Written { len: l.len() }, None);
            taken.push(l);
        }
        taken
    }

    /// The client's end of file: no more lines; the writer ends after what is queued.
    fn finish(&self) {
        self.step(ConnEvent::ClientEof, "");
    }

    async fn closed(&self) {
        let mut rx = self.closed.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }

    /// The line to write next (left queued until written); none when the writer is to end.
    async fn next(&self) -> Option<Arc<str>> {
        loop {
            {
                let q = self.lock();
                if !q.core.writing() {
                    return None;
                }
                if let Some(l) = q.lines.front() {
                    return Some(l.clone());
                }
            }
            self.wake.notified().await;
        }
    }

    fn written(&self, len: usize) {
        self.step(ConnEvent::Written { len }, "");
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

/// The writer task: lines in order, each write given [`STUCK_AFTER`] on the hub's clock to make progress.  It reports
/// a line written only after writing it all (a `Written` follows its `Push`), and at most one of a refused and a stuck
/// write, then ends.  When the queue was finished and written whole (never closed), the write half comes back:
/// `mcp/attach` hands it on.
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
                    out.stuck("dropped a client that stopped reading: no progress for 10 s");
                    return None;
                }
            }
        }
        out.written(line.len());
    }
    let whole = out.lock().core.whole();
    out.close("closed a connection");
    whole.then_some(w)
}

/// A connection's reading side: its socket's bytes, decoded into lines.
struct Reader {
    codec: tokio_util::codec::LinesCodec,
    buf: BytesMut,
}

impl Reader {
    fn new() -> Reader {
        Reader {
            codec: line::codec(),
            buf: BytesMut::with_capacity(8192),
        }
    }

    /// The next line to serve, read from R: none once reading stops (the client's EOF, which is the last read event, a
    /// read error, a malformed line, or a close).  Whether a line read is served is the core's choice.
    async fn next(&mut self, r: &mut OwnedReadHalf, out: &Outbox) -> Option<String> {
        loop {
            match self.codec.decode(&mut self.buf) {
                Ok(Some(l)) => return out.line_read().then_some(l),
                Ok(None) => {}
                Err(e) => {
                    out.close(&format!("closed a connection: {e}"));
                    return None;
                }
            }
            if !out.reading() {
                return None;
            }
            let n = tokio::select! {
                n = r.read_buf(&mut self.buf) => n,
                () = out.closed() => return None,
            };
            match n {
                // EOF: a partial line is dropped with the connection; what is queued is still written
                Ok(0) => {
                    out.finish();
                    return None;
                }
                Ok(_) => {}
                Err(e) => {
                    out.read_error(&format!("closed a connection: {e}"));
                    return None;
                }
            }
        }
    }
}

/// Serve one connection accepted on SOCKET until it closes.
pub async fn serve(stream: UnixStream, front: Arc<Front>, socket: Socket) {
    // under the sequencer the connection's own writes are serving steps: its challenge, its answers, what its
    // requests broadcast
    #[cfg(feature = "test-hooks")]
    if crate::sequencer::current().is_some() {
        return crate::sequencer::in_serving_step(serve_conn(stream, front, socket)).await;
    }
    serve_conn(stream, front, socket).await
}

async fn serve_conn(stream: UnixStream, front: Arc<Front>, socket: Socket) {
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
    // known to the front until it is gone: the hub's end closes it
    front.serving(id, &out);
    // known to the sequencer before its challenge: every line on it comes after
    #[cfg(feature = "test-hooks")]
    let sequencer = crate::sequencer::current().map(|s| {
        let mail = s.register(id, out.clone());
        (s, mail)
    });
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
    let mut reader = Reader::new();
    // `mcp/attach` answered: the identity the rest of the connection's bytes are MCP for
    let mut attached = None;
    #[cfg(feature = "test-hooks")]
    let sequenced = match sequencer {
        Some((seq, mail)) => {
            attached = sequenced(
                &seq,
                mail,
                &r,
                (&mut reader.codec, &mut reader.buf),
                &front,
                &out,
                &mut session,
            )
            .await;
            seq.unregister(id);
            true
        }
        None => false,
    };
    #[cfg(not(feature = "test-hooks"))]
    let sequenced = false;
    if !sequenced {
        while let Some(l) = reader.next(&mut r, &out).await {
            #[cfg(feature = "test-hooks")]
            if flood::serve(&out, &l).await
                || owner_gone::serve(&front, &out, &l).await
                || advance::serve(&out, &l).await
                || matrix_ask::serve(&front, &out, &l).await
                || browser_endpoint::serve(&out, &l)
                || buffer_views::serve(&front, &out, &l)
                || view_rows::serve(&front, id, &out, &l)
                || barrier_refused(&out, &l)
            {
                continue;
            }
            front.line(&mut session, &out, &l).await;
            if let Some(who) = session.attach.take() {
                // what follows the line in the reader's buffer is the first MCP bytes, never a hub line
                attached = Some(who);
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
    out.attached();
    let Ok(Some(w)) = writer.await else {
        return;
    };
    let rest = std::io::Cursor::new(reader.buf.to_vec());
    front.mcp.serve_outside(who, rest.chain(r), w).await;
}

/// The read loop under the sequencer (test-hooks): the socket is read when the sequencer asks (each readable socket
/// asks it to), and a line is served when it hands it back.  The identity `mcp/attach` answered, if it was.
#[cfg(feature = "test-hooks")]
async fn sequenced(
    seq: &crate::sequencer::Sequencer,
    mut mail: tokio::sync::mpsc::UnboundedReceiver<crate::sequencer::Msg>,
    r: &tokio::net::unix::OwnedReadHalf,
    (codec, buf): (&mut tokio_util::codec::LinesCodec, &mut BytesMut),
    front: &Front,
    out: &Arc<Outbox>,
    session: &mut Session,
) -> Option<norn::tools::Identity> {
    use crate::sequencer::{End, Msg};
    // asked to be read and not read since; read EOF; an `mcp/attach` handed over and not served
    let (mut kicked, mut ended, mut attaching) = (false, false, false);
    loop {
        tokio::select! {
            biased;
            m = mail.recv() => match m {
                None => return None,
                Some(Msg::Drain(reply)) => {
                    kicked = false;
                    let d = drain(r, codec, buf, out, attaching);
                    ended |= d.end.is_some();
                    attaching |= d.lines.last().is_some_and(|l| l.attach);
                    let closed = d.end == Some(End::Closed);
                    let _ = reply.send(d);
                    if closed {
                        return None;
                    }
                }
                Some(Msg::Serve(l, done)) => {
                    if out.line_read()
                        && !(flood::serve(out, &l).await
                            || owner_gone::serve(front, out, &l).await
                            || advance::serve(out, &l).await
                            || matrix_ask::serve(front, out, &l).await
                            || browser_endpoint::serve(out, &l)
                            || buffer_views::serve(front, out, &l))
                    {
                        front.line(session, out, &l).await;
                    }
                    if crate::sequencer::Line::read(l).attach {
                        attaching = false;
                    }
                    let who = session.attach.take();
                    let _ = done.send(());
                    if who.is_some() {
                        return who;
                    }
                }
                Some(Msg::Finish) => {
                    // EOF, and every line served: what is queued is still written
                    out.finish();
                    return None;
                }
            },
            _ = r.readable(), if !kicked && !ended => {
                kicked = true;
                seq.kick();
            }
            () = out.closed() => return None,
        }
    }
}

/// R read to `WouldBlock` (or EOF, or an error, which closes OUT), and the complete lines in BUF decoded: none after
/// an `mcp/attach` (ATTACHING: one is waiting to be served), whose bytes may be MCP's.
#[cfg(feature = "test-hooks")]
fn drain(
    r: &tokio::net::unix::OwnedReadHalf,
    codec: &mut tokio_util::codec::LinesCodec,
    buf: &mut BytesMut,
    out: &Outbox,
    attaching: bool,
) -> crate::sequencer::Drained {
    use crate::sequencer::{Drained, End, Line};
    use rustix::io::Errno;
    let mut end = None;
    // read(2) itself first: tokio's `try_read` answers WouldBlock without reading while the reactor has not yet seen
    // the socket readable, and a line the client finished writing must be in this drain (the sequencer's premise)
    let mut chunk = [0u8; 8192];
    loop {
        match rustix::io::read(r.as_ref(), &mut chunk[..]) {
            Ok(0) => {
                end = Some(End::Eof);
                break;
            }
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if e == Errno::AGAIN || e == Errno::WOULDBLOCK => break,
            Err(e) if e == Errno::INTR => {}
            Err(e) => {
                out.close(&format!("closed a connection: {e}"));
                end = Some(End::Closed);
                break;
            }
        }
    }
    // then tokio's own read to WouldBlock, which clears its readiness (so `readable()` waits for new bytes rather than
    // firing at once), with whatever came meanwhile
    while end.is_none() {
        // room first: a read into no room returns 0, which is EOF
        buf.reserve(8192);
        match r.try_read_buf(buf) {
            Ok(0) => end = Some(End::Eof),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) => {
                out.close(&format!("closed a connection: {e}"));
                end = Some(End::Closed);
            }
        }
    }
    let mut lines: Vec<Line> = Vec::new();
    let mut waiting = attaching;
    while end != Some(End::Closed) && !waiting {
        match codec.decode(buf) {
            Ok(Some(l)) => {
                let l = Line::read(l);
                waiting = l.attach;
                lines.push(l);
            }
            Ok(None) => break,
            Err(e) => {
                out.close(&format!("closed a connection: {e}"));
                end = Some(End::Closed);
            }
        }
    }
    Drained {
        partial: !waiting && !buf.is_empty(),
        lines,
        end,
    }
}

/// `__test_barrier` on a hub without `--test-sequencer` (test-hooks): refused (true), else left to the dispatcher.
#[cfg(feature = "test-hooks")]
fn barrier_refused(out: &Outbox, line: &str) -> bool {
    use runstav::wire::{Error, ErrorAnswer, ErrorCode, Request};
    let Ok(req) = serde_json::from_str::<Request>(line) else {
        return false;
    };
    if req.method != "__test_barrier" {
        return false;
    }
    if let Some(id) = req.id {
        let a = serde_json::to_string(&ErrorAnswer {
            id,
            error: Error {
                code: ErrorCode::NotAllowed,
                message: "the hub runs without a sequencer (serve --test-sequencer)".into(),
                path: None,
            },
        })
        .expect("an answer serializes");
        out.push(format!("{a}\n").into());
    }
    true
}

/// `__test_buffer_views` (test-hooks): the editors' buffer views open now and the frame bodies built so far
/// ([`crate::editor::Buffers::counts`]), answered `{views, built}`.
#[cfg(feature = "test-hooks")]
mod buffer_views {
    use super::Outbox;
    use crate::front::Front;
    use runstav::wire::{Answer, Request};
    use serde_json::json;

    /// Serve LINE when it is a `__test_buffer_views` request (true), else leave it to the dispatcher.
    pub(super) fn serve(front: &Front, out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_buffer_views" {
            return false;
        }
        let (views, built) = front.core.buffers.counts();
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result: json!({"views": views, "built": built}),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
        }
        true
    }
}

/// `__test_view_rows {view, rows, images?}` (test-hooks): this connection's fixture view VIEW shows ROWS (and may name
/// IMAGES, `[[id, svg]]`) in every display class it has an env for ([`crate::view::Views::fixture`]); answered true.
#[cfg(feature = "test-hooks")]
mod view_rows {
    use super::Outbox;
    use crate::front::Front;
    use drgnx_rows::{ImageId, Row};
    use runstav::wire::{Answer, Request};
    use serde_json::json;

    /// Serve LINE when it is a `__test_view_rows` request (true), else leave it to the dispatcher.
    pub(super) fn serve(front: &Front, conn: u64, out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_view_rows" {
            return false;
        }
        let view = req.params["view"].as_str().unwrap_or_default().to_owned();
        let rows: Vec<Row> = serde_json::from_value(req.params["rows"].clone()).unwrap_or_default();
        let images: Vec<(ImageId, String)> =
            serde_json::from_value(req.params["images"].clone()).unwrap_or_default();
        front.core.views.fixture(front, conn, view, rows, images);
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result: json!(true),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
        }
        true
    }
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
            // what the woken tasks wrote, before the answer
            if let Some(seq) = crate::sequencer::current() {
                seq.release();
            }
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

/// `__test_matrix_ask {action, who, session?, plan?, facts?}` (test-hooks): the matrix gate asked for ACTION by WHO in
/// that session and plan with those facts, as the hub's own callers ask it (an Ask makes and announces the card);
/// answered `{"gate": "allow"}`, `{"gate": "ask", "card": N}` or `{"gate": "never", "why": W}`.  The rows of the
/// browser cards raise their cards with it.
#[cfg(feature = "test-hooks")]
mod matrix_ask {
    use super::Outbox;
    use crate::front::Front;
    use crate::matrix_gate::{ActionCtx, Gate, who_of};
    use runstav::methods::matrix::Action;
    use runstav::wire::{Answer, Request};
    use serde_json::json;

    /// Serve LINE when it is a `__test_matrix_ask` request (true), else leave it to the dispatcher.
    pub(super) async fn serve(front: &Front, out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_matrix_ask" {
            return false;
        }
        let p = &req.params;
        let text = |k: &str| p[k].as_str().map(str::to_owned);
        let result = match p["action"].as_str().and_then(Action::from_id) {
            None => json!({"gate": "never", "why": "no such action"}),
            Some(a) => {
                let ctx = ActionCtx {
                    session: text("session"),
                    plan: text("plan"),
                    facts: serde_json::from_value(p["facts"].clone()).unwrap_or_default(),
                    ..ActionCtx::default()
                };
                let who = who_of(&p["who"]);
                let gate = front
                    .core
                    .matrix
                    .decide(&front.settings, &front.writer, who, a, ctx)
                    .await;
                match gate {
                    Gate::Allow => json!({"gate": "allow"}),
                    Gate::Ask(card) => json!({"gate": "ask", "card": card}),
                    Gate::Never(why) => json!({"gate": "never", "why": why}),
                }
            }
        };
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result,
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
        }
        true
    }
}

/// `__test_browser_endpoint {socket}` (test-hooks): a CDP broker on SOCKET with no browser behind it
/// (`browser::broker::test_endpoint`), answered with its secret (`{"secret": HEX}`, or `{"error": TEXT}`).
#[cfg(feature = "test-hooks")]
mod browser_endpoint {
    use super::Outbox;
    use runstav::wire::{Answer, Request};
    use serde_json::json;

    /// Serve LINE when it is a `__test_browser_endpoint` request (true), else leave it to the dispatcher.
    pub(super) fn serve(out: &Outbox, line: &str) -> bool {
        let Ok(req) = serde_json::from_str::<Request>(line) else {
            return false;
        };
        if req.method != "__test_browser_endpoint" {
            return false;
        }
        let socket = req.params["socket"].as_str().unwrap_or("");
        let result = match crate::browser::broker::test_endpoint(std::path::Path::new(socket)) {
            Ok(secret) => json!({"secret": secret}),
            Err(e) => json!({"error": e}),
        };
        if let Some(id) = req.id {
            let a = serde_json::to_string(&Answer {
                id,
                result,
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push(format!("{a}\n").into());
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
