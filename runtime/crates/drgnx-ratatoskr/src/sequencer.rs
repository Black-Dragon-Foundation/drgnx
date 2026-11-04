//! The sequencer (test-hooks, `serve --test-sequencer`; docs/develop/hub.md, "Test hooks").  Requests from every
//! connection are served one at a time, in the order of the top-level `"__seq": N` the client stamped on each line.
//! Before it serves, the sequencer reads every connection's socket to `WouldBlock`: a Unix-socket write is in the
//! peer's queue when it returns, so a lower N the client wrote earlier has been read.  Lines without `__seq` (another
//! process's) are served after the sequenced ones, in read order.
//!
//! A connection's own task serves its lines (its session stays its own) when the sequencer hands them over, and its
//! writes are serving steps.  A write from any other task (a turn, a timer) is held, keyed by (virtual ms, origin,
//! the origin's count), and released in key order at `__test_advance` and `__test_barrier`; a write from a task
//! without an origin is counted (`unnamed`).

use crate::clock;
use crate::conn::Outbox;
use runstav::wire::{Answer, Event, Id};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
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

/// The order, without I/O: the lines read and not served, which one is next, and the held writes.
pub(crate) struct Order<L> {
    pending: BTreeMap<Key, (u64, L)>,
    reads: u64,
    /// The N after the highest served.
    next: u64,
    /// Connections whose socket held part of a line at the last read.
    partial: BTreeSet<u64>,
    held: BTreeMap<(u64, String, u64), (u64, Arc<str>)>,
    origin_counts: HashMap<String, u64>,
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
        self.pending.insert(key, (conn, line));
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
        self.pending.retain(|_, (c, _)| *c != conn);
    }

    pub(crate) fn holds(&self, conn: u64) -> bool {
        self.pending.values().any(|(c, _)| *c == conn)
    }

    /// The line to serve now, with its connection.  The lowest N is served at once when it follows the last one served;
    /// above a gap it waits while some connection holds part of a line (the missing N may be in it), and is served
    /// once none does (the missing N went to a connection that closed).
    pub(crate) fn next(&mut self) -> Option<(u64, L)> {
        let (&key, _) = self.pending.first_key_value()?;
        if let Key::Seq(n, _) = key {
            if n > self.next && !self.partial.is_empty() {
                return None;
            }
            self.next = self.next.max(n + 1);
        }
        self.pending.remove(&key)
    }

    /// A write to CONN outside a serving step, at virtual MS, from ORIGIN (none: a task without one, counted).
    pub(crate) fn hold(&mut self, ms: u64, origin: Option<String>, conn: u64, line: Arc<str>) {
        if origin.is_none() {
            self.unnamed += 1;
        }
        let name = origin.unwrap_or_default();
        let count = self.origin_counts.entry(name.clone()).or_insert(0);
        *count += 1;
        self.held.insert((ms, name, *count), (conn, line));
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
}

impl Sequencer {
    fn new() -> Sequencer {
        Sequencer {
            order: Mutex::new(Order::new()),
            conns: Mutex::new(BTreeMap::new()),
            eof: Mutex::new(BTreeSet::new()),
            kick: Notify::new(),
            markers: AtomicU64::new(0),
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
        let (ms, origin) = (clock::virtual_ms(), clock::origin_name());
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

    async fn run(self: Arc<Self>) {
        loop {
            self.kick.notified().await;
            // until a read brings nothing to serve
            loop {
                self.drain_all().await;
                let served = self.serve_pending().await;
                self.finish_ended();
                if !served {
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

    /// `__test_barrier` on CONN: every socket read and what it held served; the woken and spawned tasks settled and the
    /// held writes released; a numbered marker on every connection; then the answer `{marker, unnamed, busy}`.
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
            if !any {
                break;
            }
        }
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
                result: json!({"marker": marker, "unnamed": unnamed, "busy": settled.busy}),
                ignored: vec![],
            })
            .expect("an answer serializes");
            out.push_now(format!("{answer}\n").into());
        }
    }
}

#[cfg(test)]
mod tests;
