//! The sequencer (test-hooks, `serve --test-sequencer`; docs/develop/hub.md, "Test hooks").  Requests from every
//! connection are served one at a time, in the order of the top-level `"__seq": N` the client stamped on each line.
//! Before it serves, the sequencer reads every connection's socket to `WouldBlock`: a Unix-socket write is in the
//! peer's queue when it returns, so a lower N the client wrote earlier has been read.  The sockets are read one after
//! another, so a line above a gap waits for one more full drain, begun after it was read.  Lines without `__seq`
//! (another process's) are served after the sequenced ones, in read order.
//!
//! A connection's own task serves its lines (its session stays its own) when the sequencer hands them over, and its
//! writes are serving steps.  A write from any other task (a turn, a timer) is held, keyed by (virtual ms, origin,
//! the task's spawn ordinal, the task's own count), and released in key order at `__test_advance` and
//! `__test_barrier`; a write from a task without an origin is counted (`unnamed`).
//!
//! When the hub ends ([`Sequencer::end`]), the step being served finishes, nothing more is served, and what is still
//! held is released in key order and written before the connections close: an end never drops a held write, and the
//! client's delivery gate still decides when its client sees it.

use crate::clock;
use crate::conn::Outbox;
use runstav::wire::{Answer, Event, Id};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Duration;
use tokio::sync::{Notify, mpsc, oneshot};

tokio::task_local! {
    static SERVING: ();
}

static GLOBAL: OnceLock<Arc<Sequencer>> = OnceLock::new();

/// The sequencer, from now on, for the whole process (`serve --test-sequencer`, before any connection).  Once.
pub fn install() {
    let seq = Arc::new(Sequencer::new());
    if GLOBAL.set(seq.clone()).is_ok() {
        // not a clock task: a barrier's advance runs inside it, and must not wait for the task it runs in
        tokio::spawn(SERVING.scope((), seq.run()));
    }
}

pub fn current() -> Option<Arc<Sequencer>> {
    GLOBAL.get().cloned()
}

/// Is this task's write a serving step (a connection's own task, or the sequencer's)?
pub(crate) fn serving() -> bool {
    SERVING.try_with(|_| ()).is_ok()
}

/// F as a serving step: its writes go out at once.
pub(crate) async fn in_serving_step<F: Future>(f: F) -> F::Output {
    SERVING.scope((), f).await
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A line a client sent, `__seq` taken out.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Line {
    pub(crate) seq: Option<u64>,
    pub(crate) text: String,
    pub(crate) id: Option<Id>,
    /// `__test_barrier`: the sequencer serves it itself.
    pub(crate) barrier: bool,
    /// `mcp/attach`: what follows it may be MCP, so nothing after it is read as lines until it is served.
    pub(crate) attach: bool,
}

impl Line {
    pub(crate) fn read(text: String) -> Line {
        let Ok(Value::Object(mut o)) = serde_json::from_str::<Value>(&text) else {
            return Line {
                seq: None,
                text,
                id: None,
                barrier: false,
                attach: false,
            };
        };
        let method = o.get("method").and_then(Value::as_str).unwrap_or_default();
        let (barrier, attach) = (method == "__test_barrier", method == "mcp/attach");
        let id = o
            .get("id")
            .cloned()
            .and_then(|i| serde_json::from_value::<Id>(i).ok());
        // a `__seq` that is no number stays in the line: the dispatcher lists it as ignored
        let seq = o.get("__seq").and_then(Value::as_u64);
        let text = if seq.is_some() {
            o.remove("__seq");
            Value::Object(o).to_string()
        } else {
            text
        };
        Line {
            seq,
            text,
            id,
            barrier,
            attach,
        }
    }
}

/// Where a pending line stands: sequenced lines by N (then read order), then the others in read order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
    Seq(u64, u64),
    Read(u64),
}

/// A held write's place: (virtual ms, origin, the task's spawn ordinal, the task's own count).
type HeldKey = (u64, String, u64, u64);

/// The order, without I/O: the lines read and not served, which one is next, and the held writes.
pub(crate) struct Order<L> {
    /// Each with its connection and the drain that read it.
    pending: BTreeMap<Key, (u64, u64, L)>,
    reads: u64,
    /// The N after the highest served.
    next: u64,
    /// Connections whose socket held part of a line at the last read.
    partial: BTreeSet<u64>,
    /// The full drain under way (or the last one begun), and the last one that ended.
    round: u64,
    drained: u64,
    held: BTreeMap<HeldKey, (u64, Arc<str>)>,
    origin_counts: HashMap<(String, u64), u64>,
    unnamed: u32,
}

impl<L> Default for Order<L> {
    fn default() -> Order<L> {
        Order::new()
    }
}

impl<L> Order<L> {
    pub(crate) fn new() -> Order<L> {
        Order {
            pending: BTreeMap::new(),
            reads: 0,
            next: 1,
            partial: BTreeSet::new(),
            round: 0,
            drained: 0,
            held: BTreeMap::new(),
            origin_counts: HashMap::new(),
            unnamed: 0,
        }
    }

    /// LINE read on CONN, with its N if it had one.
    pub(crate) fn read(&mut self, conn: u64, seq: Option<u64>, line: L) {
        self.reads += 1;
        let key = match seq {
            Some(n) => Key::Seq(n, self.reads),
            None => Key::Read(self.reads),
        };
        self.pending.insert(key, (conn, self.round, line));
    }

    /// Whether CONN's socket held part of a line at its last read.
    pub(crate) fn set_partial(&mut self, conn: u64, partial: bool) {
        if partial {
            self.partial.insert(conn);
        } else {
            self.partial.remove(&conn);
        }
    }

    /// CONN read EOF: nothing more comes from it (the part of a line it held is dropped); its lines are still served.
    pub(crate) fn ended(&mut self, conn: u64) {
        self.partial.remove(&conn);
    }

    /// CONN closed: its lines are not served.
    pub(crate) fn drop_conn(&mut self, conn: u64) {
        self.partial.remove(&conn);
        self.pending.retain(|_, (c, _, _)| *c != conn);
    }

    pub(crate) fn holds(&self, conn: u64) -> bool {
        self.pending.values().any(|(c, _, _)| *c == conn)
    }

    /// A read of every connection begins: the lines read until [`Order::end_drain`] are this drain's.
    pub(crate) fn begin_drain(&mut self) {
        self.round += 1;
    }

    pub(crate) fn end_drain(&mut self) {
        self.drained = self.round;
    }

    /// Whether the next line waits above a gap for one more full drain only (no socket holds part of a line): the
    /// sequencer drains again at once rather than waiting for a socket to become readable.
    pub(crate) fn wants_drain(&self) -> bool {
        match self.pending.first_key_value() {
            Some((Key::Seq(n, _), (_, round, _))) => {
                *n > self.next && self.partial.is_empty() && self.drained <= *round
            }
            _ => false,
        }
    }

    /// The line to serve now, with its connection.  The lowest N is served at once when it follows the last one served.
    /// Above a gap it waits while some connection holds part of a line (the missing N may be in it), and until a full
    /// drain begun after it was read has ended: the connections are read one after another, so a lower N the client
    /// wrote just before it may be in a socket this drain read earlier.  Then it is served (the missing N went to a
    /// connection that closed).
    pub(crate) fn next(&mut self) -> Option<(u64, L)> {
        let (&key, &(_, round, _)) = self.pending.first_key_value()?;
        if let Key::Seq(n, _) = key {
            if n > self.next && (!self.partial.is_empty() || self.drained <= round) {
                return None;
            }
            self.next = self.next.max(n + 1);
        }
        self.pending.remove(&key).map(|(c, _, l)| (c, l))
    }

    /// A write to CONN outside a serving step, at virtual MS, from ORIGIN (the task's name and spawn ordinal; none: a
    /// task without one, counted).
    pub(crate) fn hold(
        &mut self,
        ms: u64,
        origin: Option<(String, u64)>,
        conn: u64,
        line: Arc<str>,
    ) {
        if origin.is_none() {
            self.unnamed += 1;
        }
        let (name, task) = origin.unwrap_or_default();
        let count = self.origin_counts.entry((name.clone(), task)).or_insert(0);
        *count += 1;
        self.held.insert((ms, name, task, *count), (conn, line));
    }

    /// The held writes, in key order, taken.
    pub(crate) fn release(&mut self) -> Vec<(u64, Arc<str>)> {
        std::mem::take(&mut self.held).into_values().collect()
    }

    /// The writes from tasks without an origin since the last time, taken.
    pub(crate) fn take_unnamed(&mut self) -> u32 {
        std::mem::take(&mut self.unnamed)
    }
}

/// What the sequencer asks of a connection's task.
pub(crate) enum Msg {
    /// Read the socket to `WouldBlock` (or EOF) and hand over the lines.
    Drain(oneshot::Sender<Drained>),
    /// Serve this line, then say so.
    Serve(String, oneshot::Sender<()>),
    /// EOF was read and every line served: finish.
    Finish,
}

pub(crate) struct Drained {
    pub(crate) lines: Vec<Line>,
    pub(crate) partial: bool,
    pub(crate) end: Option<End>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum End {
    Eof,
    Closed,
}

struct Handle {
    mail: mpsc::UnboundedSender<Msg>,
    out: Arc<Outbox>,
}

/// See the module.  Lock order: none is held while another is taken.
pub struct Sequencer {
    order: Mutex<Order<Line>>,
    conns: Mutex<BTreeMap<u64, Handle>>,
    /// Connections that read EOF and are not finished yet.
    eof: Mutex<BTreeSet<u64>>,
    /// A connection's socket became readable.
    kick: Notify,
    markers: AtomicU64,
    /// Held while a round of reads and serving steps runs, and by [`Sequencer::end`].
    step: tokio::sync::Mutex<()>,
    /// The hub ends: nothing more is served.
    ended: AtomicBool,
}

/// How long, in real time, the hub's end waits for the step being served and for each connection's queue to be written.
const END_WITHIN: Duration = Duration::from_secs(5);

impl Sequencer {
    fn new() -> Sequencer {
        Sequencer {
            order: Mutex::new(Order::new()),
            conns: Mutex::new(BTreeMap::new()),
            eof: Mutex::new(BTreeSet::new()),
            kick: Notify::new(),
            markers: AtomicU64::new(0),
            step: tokio::sync::Mutex::new(()),
            ended: AtomicBool::new(false),
        }
    }

    fn order(&self) -> MutexGuard<'_, Order<Line>> {
        lock(&self.order)
    }

    /// CONN (its outbox OUT) from now on: its task reads the messages.  Before its challenge is written, so any line
    /// on it comes after.
    pub(crate) fn register(&self, conn: u64, out: Arc<Outbox>) -> mpsc::UnboundedReceiver<Msg> {
        let (mail, rx) = mpsc::unbounded_channel();
        lock(&self.conns).insert(conn, Handle { mail, out });
        rx
    }

    pub(crate) fn unregister(&self, conn: u64) {
        lock(&self.conns).remove(&conn);
        lock(&self.eof).remove(&conn);
        self.order().drop_conn(conn);
    }

    pub(crate) fn kick(&self) {
        self.kick.notify_one();
    }

    /// A write to CONN outside a serving step: held.
    pub(crate) fn hold(&self, conn: u64, line: Arc<str>) {
        let (ms, origin) = (clock::virtual_ms(), clock::origin());
        self.order().hold(ms, origin, conn, line);
    }

    /// The held writes, written in key order (to the connections still here).
    pub(crate) fn release(&self) {
        let held = self.order().release();
        for (conn, line) in held {
            let out = lock(&self.conns).get(&conn).map(|h| h.out.clone());
            if let Some(out) = out {
                out.push_now(line);
            }
        }
    }

    /// The hub ends (its shutdown, a restart, a signal): once the step being served is done, nothing more is served;
    /// what is still held is released in key order, and every connection's queue is written.  Each wait is bounded by
    /// [`END_WITHIN`] of real time (the virtual clock stands still), and one that runs out is logged.
    pub async fn end(&self) {
        let step = clock::real_timeout(END_WITHIN, self.step.lock()).await;
        if step.is_err() {
            tracing::warn!("the hub ends while a request is still being served");
        }
        self.ended.store(true, Ordering::SeqCst);
        self.release();
        let outs: Vec<Arc<Outbox>> = lock(&self.conns).values().map(|h| h.out.clone()).collect();
        for out in outs {
            if clock::real_timeout(END_WITHIN, out.flushed(END_WITHIN))
                .await
                .is_err()
            {
                tracing::warn!("the hub ends with lines not yet written to a connection");
            }
        }
    }

    async fn run(self: Arc<Self>) {
        loop {
            self.kick.notified().await;
            // until a read brings nothing to serve
            loop {
                let _step = self.step.lock().await;
                if self.ended.load(Ordering::SeqCst) {
                    return;
                }
                self.drain_all().await;
                let served = self.serve_pending().await;
                self.finish_ended();
                if !served && !self.order().wants_drain() {
                    break;
                }
            }
        }
    }

    /// Every connection's socket read; its lines and state in the order.
    async fn drain_all(&self) {
        let conns: Vec<(u64, mpsc::UnboundedSender<Msg>)> = lock(&self.conns)
            .iter()
            .map(|(c, h)| (*c, h.mail.clone()))
            .collect();
        self.order().begin_drain();
        for (conn, mail) in conns {
            if lock(&self.eof).contains(&conn) {
                continue;
            }
            let (tx, rx) = oneshot::channel();
            let drained = match mail.send(Msg::Drain(tx)) {
                Ok(()) => rx.await.ok(),
                Err(_) => None,
            };
            let ended = {
                let mut order = self.order();
                let Some(d) = drained else {
                    order.drop_conn(conn);
                    continue;
                };
                for l in d.lines {
                    let seq = l.seq;
                    order.read(conn, seq, l);
                }
                match d.end {
                    None => order.set_partial(conn, d.partial),
                    Some(End::Eof) => order.ended(conn),
                    Some(End::Closed) => order.drop_conn(conn),
                }
                d.end == Some(End::Eof)
            };
            if ended {
                lock(&self.eof).insert(conn);
            }
        }
        self.order().end_drain();
    }

    /// Serve what the order allows, one line at a time; whether any was.
    async fn serve_pending(&self) -> bool {
        let mut any = false;
        loop {
            let next = self.order().next();
            let Some((conn, line)) = next else {
                return any;
            };
            any = true;
            if line.barrier {
                self.barrier(conn, line).await;
            } else {
                self.serve(conn, line.text).await;
            }
        }
    }

    async fn serve(&self, conn: u64, text: String) {
        let mail = lock(&self.conns).get(&conn).map(|h| h.mail.clone());
        let Some(mail) = mail else { return };
        let (tx, rx) = oneshot::channel();
        if mail.send(Msg::Serve(text, tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Connections at EOF with nothing left to serve: finished.
    fn finish_ended(&self) {
        let ended: Vec<u64> = lock(&self.eof).iter().copied().collect();
        for conn in ended {
            if self.order().holds(conn) {
                continue;
            }
            let mail = lock(&self.conns).get(&conn).map(|h| h.mail.clone());
            if let Some(mail) = mail {
                let _ = mail.send(Msg::Finish);
            }
            lock(&self.eof).remove(&conn);
        }
    }

    /// `__test_barrier` on CONN: every socket read and what it held served; the tasks inside a real wait waited for
    /// (those its `waiting_ok` origins name excepted); the woken and spawned tasks settled and the held writes
    /// released; a numbered marker on every connection; then the answer `{marker, unnamed, busy, waiting}`.
    async fn barrier(&self, conn: u64, line: Line) {
        let mut barriers = vec![(conn, line)];
        loop {
            self.drain_all().await;
            let mut any = false;
            loop {
                let next = self.order().next();
                let Some((c, l)) = next else { break };
                any = true;
                if l.barrier {
                    barriers.push((c, l));
                } else {
                    self.serve(c, l.text).await;
                }
            }
            if !any && !self.order().wants_drain() {
                break;
            }
        }
        let ok: Vec<String> = barriers
            .iter()
            .flat_map(|(_, l)| waiting_ok(&l.text))
            .collect();
        let waiting = clock::settle_real(clock::BUSY_AFTER, &ok).await;
        let settled = clock::advance(Duration::ZERO).await;
        self.release();
        let unnamed = self.order().take_unnamed() + settled.unnamed;
        for (c, l) in barriers {
            let marker = self.markers.fetch_add(1, Ordering::SeqCst) + 1;
            let event: Arc<str> = format!(
                "{}\n",
                serde_json::to_string(&Event {
                    event: "__test_marker".into(),
                    data: json!({"marker": marker}),
                })
                .expect("an event serializes")
            )
            .into();
            let outs: Vec<(u64, Arc<Outbox>)> = lock(&self.conns)
                .iter()
                .map(|(c, h)| (*c, h.out.clone()))
                .collect();
            for (_, out) in &outs {
                out.push_now(event.clone());
            }
            let (Some(id), Some((_, out))) = (l.id, outs.iter().find(|(o, _)| *o == c)) else {
                continue;
            };
            let answer = serde_json::to_string(&Answer {
                id,
                result: json!({
                    "marker": marker,
                    "unnamed": unnamed,
                    "busy": settled.busy,
                    "waiting": waiting
                }),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push_now(format!("{answer}\n").into());
        }
    }
}

/// The origins a barrier's `params.waiting_ok` lists (TEXT: its line).
fn waiting_ok(text: &str) -> Vec<String> {
    serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| {
            v.pointer("/params/waiting_ok")
                .and_then(Value::as_array)
                .cloned()
        })
        .unwrap_or_default()
        .into_iter()
        .filter_map(|o| o.as_str().map(str::to_string))
        .collect()
}

#[cfg(test)]
mod tests;
