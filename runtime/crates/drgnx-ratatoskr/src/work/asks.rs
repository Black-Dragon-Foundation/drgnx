//! The current ask (docs/develop/work-space.md, "Asks"): every graph write and every agent start by a session links to
//! the user's words behind it, in any turn.
//!
//! A session's **current ask** is its latest user message, until the next one; a steer becomes current from its
//! delivery. Every write of a spec, plan or task by that session, and every agent it starts, links `asked` to it, in
//! the turn that answers the message or in a later one (a wake on a job, a batched wake). A worker inherits its
//! starter's current ask when it starts. An `ask` entity is made only at the first link to it, so a message that leads
//! to no work leaves none, and records the hub did not see a session write (an import, the scan) get none.
//!
//! [`AskCore`] is pure: it takes the events in the order they happened and says what to write. The shell ([`run`])
//! feeds it, in one task, the user messages as they reach the agent, the agents' starts, and the sessions' graph
//! writes read from the store's `tx` log; it reads the log before every other input, so a write is always seen
//! before the message that followed it. It writes as `("hub", System)` through norn's writers.

use crate::coord::Writer;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::{CoordError, Tx};
use norn::write::work::AskNew;
use runstav::registry::Class;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// The kinds an `asked` link reaches from an ask.
pub const LINKED: &[&str] = &["spec", "plan", "task", "session"];

/// What the core is told, each in the order it happened.
#[derive(Clone, Debug, PartialEq)]
pub enum AskEv {
    /// The user's TEXT reached SESSION's agent (a turn's prompt); CHANNEL is `say`, `chat`, `manager` or `brainstorm`.
    UserMessage {
        session: String,
        text: String,
        channel: String,
        message_id: Option<String>,
        at: f64,
    },
    /// A steer from the user reached SESSION's agent.
    SteerDelivered {
        session: String,
        text: String,
        at: f64,
    },
    /// SESSION wrote ENTITY, of KIND.
    GraphWrite {
        session: String,
        entity: String,
        kind: String,
    },
    /// Session NEW started, by STARTER (a manager, the session that made the plan run), or by the user (none).
    AgentStart {
        starter: Option<String>,
        new: String,
    },
    /// SESSION ended.
    SessionGone { session: String },
}

/// What to write.
#[derive(Clone, Debug, PartialEq)]
pub enum AskOut {
    /// Make the `ask` entity KEY stands for (once, before its first link).
    Create {
        key: u64,
        text: String,
        channel: String,
        session: String,
        message_id: Option<String>,
        at: f64,
    },
    /// Link the ask KEY `asked` to TO (an entity id).
    Link { ask_key: u64, to: String },
}

/// An ask the core knows: a session's current one, made or not yet.
#[derive(Clone, Debug)]
struct Ask {
    text: String,
    channel: String,
    session: String,
    message_id: Option<String>,
    at: f64,
    created: bool,
}

/// See the module.
#[derive(Debug, Default)]
pub struct AskCore {
    next: u64,
    asks: BTreeMap<u64, Ask>,
    /// Each session's current ask.
    current: BTreeMap<String, u64>,
    /// Each session's channel, from its last user message (a steer keeps it).
    channel: BTreeMap<String, String>,
    linked: BTreeSet<(u64, String)>,
}

impl AskCore {
    pub fn new() -> AskCore {
        AskCore::default()
    }

    pub fn step(&mut self, ev: AskEv) -> Vec<AskOut> {
        match ev {
            AskEv::UserMessage {
                session,
                text,
                channel,
                message_id,
                at,
            } => {
                self.channel.insert(session.clone(), channel.clone());
                self.open(session, text, channel, message_id, at);
                Vec::new()
            }
            AskEv::SteerDelivered { session, text, at } => {
                let channel = self
                    .channel
                    .get(&session)
                    .cloned()
                    .unwrap_or_else(|| "chat".into());
                self.open(session, text, channel, None, at);
                Vec::new()
            }
            AskEv::GraphWrite {
                session,
                entity,
                kind,
            } => match self.current.get(&session) {
                Some(&key) if LINKED.contains(&kind.as_str()) => self.link(key, entity),
                _ => Vec::new(),
            },
            AskEv::AgentStart { starter, new } => {
                let Some(&key) = starter.as_ref().and_then(|s| self.current.get(s)) else {
                    return Vec::new();
                };
                let out = self.link(key, format!("session:{new}"));
                if let Some(old) = self.current.insert(new, key) {
                    self.forget_unused(old);
                }
                out
            }
            AskEv::SessionGone { session } => {
                self.channel.remove(&session);
                if let Some(old) = self.current.remove(&session) {
                    self.forget_unused(old);
                }
                Vec::new()
            }
        }
    }

    /// TEXT becomes SESSION's current ask (made at its first link).
    fn open(
        &mut self,
        session: String,
        text: String,
        channel: String,
        message_id: Option<String>,
        at: f64,
    ) {
        self.next += 1;
        let key = self.next;
        self.asks.insert(
            key,
            Ask {
                text,
                channel,
                session: session.clone(),
                message_id,
                at,
                created: false,
            },
        );
        if let Some(old) = self.current.insert(session, key) {
            self.forget_unused(old);
        }
    }

    /// Link ask KEY to TO: the ask made first if it is not yet, and a link already made not again.
    fn link(&mut self, key: u64, to: String) -> Vec<AskOut> {
        let mut out = Vec::new();
        let Some(a) = self.asks.get_mut(&key) else {
            return out;
        };
        if !a.created {
            a.created = true;
            out.push(AskOut::Create {
                key,
                text: a.text.clone(),
                channel: a.channel.clone(),
                session: a.session.clone(),
                message_id: a.message_id.clone(),
                at: a.at,
            });
        }
        if self.linked.insert((key, to.clone())) {
            out.push(AskOut::Link { ask_key: key, to });
        }
        out
    }

    /// Ask KEY is no session's current one any more: nothing links to it again, so it is dropped.
    fn forget_unused(&mut self, key: u64) {
        if !self.current.values().any(|k| *k == key) {
            self.asks.remove(&key);
            self.linked.retain(|(k, _)| *k != key);
        }
    }

    /// The asks some session still links to (the shell keeps their entity ids only while they are here).
    pub fn live(&self) -> impl Iterator<Item = u64> + '_ {
        self.asks.keys().copied()
    }
}

/// A version of an entity a transaction wrote, as the shell reads it from the store.
#[derive(Clone, Debug, PartialEq)]
pub struct Written {
    pub tx: i64,
    /// The transaction's session (none: the user, the hub, the scan).
    pub session: Option<String>,
    /// Brought in by an import.
    pub imported: bool,
    pub entity: String,
    pub kind: String,
}

/// The event W is, if a session wrote it: imports and writes without a session are none.
pub fn write_of(w: &Written) -> Option<AskEv> {
    if w.imported {
        return None;
    }
    Some(AskEv::GraphWrite {
        session: w.session.clone()?,
        entity: w.entity.clone(),
        kind: w.kind.clone(),
    })
}

// ---- the shell ----

/// What the shell's task is given.
enum Input {
    Ev(AskEv),
    /// Session NEW started; its starter is PARENT (a manager) or the session that made its JOB (a plan run's worker).
    Start {
        new: String,
        parent: Option<String>,
        job: Option<String>,
    },
    /// Read the sessions' writes so far, link them, then answer.
    Flush(tokio::sync::oneshot::Sender<()>),
}

/// The hub's door to the shell: cheap to clone, never blocks the caller (but [`AskTx::flush`]).
#[derive(Clone)]
pub struct AskTx {
    tx: tokio::sync::mpsc::UnboundedSender<Input>,
    running: Arc<AtomicBool>,
}

impl AskTx {
    pub fn send(&self, ev: AskEv) {
        let _ = self.tx.send(Input::Ev(ev));
    }

    /// Session NEW started, by PARENT, or within JOB.
    pub fn started(&self, new: &str, parent: Option<&str>, job: Option<&str>) {
        let _ = self.tx.send(Input::Start {
            new: new.to_string(),
            parent: parent.map(str::to_string),
            job: job.map(str::to_string),
        });
    }

    /// Wait until the sessions' graph writes committed so far are linked: a session's tool call answers after its own
    /// writes are. At once when the shell does not run (a front without a server).
    pub async fn flush(&self) {
        if !self.running.load(Ordering::SeqCst) {
            return;
        }
        let (tx, rx) = tokio::sync::oneshot::channel();
        if self.tx.send(Input::Flush(tx)).is_ok() {
            let _ = rx.await;
        }
    }
}

/// The shell's state in the agent core: its door, and its inbox until [`run`] takes it.
pub struct Asks {
    tx: AskTx,
    rx: Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<Input>>>,
}

impl Default for Asks {
    fn default() -> Asks {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        Asks {
            tx: AskTx {
                tx,
                running: Arc::new(AtomicBool::new(false)),
            },
            rx: Mutex::new(Some(rx)),
        }
    }
}

impl Asks {
    pub fn handle(&self) -> AskTx {
        self.tx.clone()
    }
}

/// The hub's own author: `("hub", System)`.
fn hub() -> Caller {
    Caller {
        class: Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// The newest `tx` row, and when SINCE is given, the spec, plan and task versions written after it (by anyone; the
/// pure [`write_of`] keeps the sessions'). The entity scan runs only when a session wrote since.
fn read_written(c: &Tx, since: Option<i64>) -> Result<(i64, Vec<Written>), CoordError> {
    let last: i64 = c.query_row("select coalesce(max(id), 0) from tx", [], |r| r.get(0))?;
    let Some(since) = since.filter(|s| *s < last) else {
        return Ok((last, Vec::new()));
    };
    let by_sessions: i64 = c.query_row(
        "select count(*) from tx where id > ?1 and id <= ?2 and session is not null and imported = 0",
        (since, last),
        |r| r.get(0),
    )?;
    if by_sessions == 0 {
        return Ok((last, Vec::new()));
    }
    let mut q = c.prepare(
        "select x.tx, e.id, e.kind, t.session, t.imported from \
         (select n, updated_tx as tx from entity where updated_tx > ?1 and updated_tx <= ?2 \
          union select n, tx_from from entity_hist where tx_from > ?1 and tx_from <= ?2) x \
         join entity e on e.n = x.n join tx t on t.id = x.tx \
         where t.state = 'committed' and e.kind in ('spec', 'plan', 'task') order by x.tx, e.n",
    )?;
    let rows = q
        .query_map((since, last), |r| {
            Ok(Written {
                tx: r.get(0)?,
                entity: r.get(1)?,
                kind: r.get(2)?,
                session: r.get(3)?,
                imported: r.get::<_, i64>(4)? != 0,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok((last, rows))
}

/// The session whose transaction made plan run JOB.
fn starter_of_job(c: &Tx, job: &str) -> Result<Option<String>, CoordError> {
    match c.query_row(
        "select t.session from job j join tx t on t.id = j.tx where j.id = ?1",
        [job],
        |r| r.get::<_, Option<String>>(0),
    ) {
        Ok(s) => Ok(s),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// The task's state: the core, the entity ids of the asks it made, the `tx` row read up to.
struct Shell {
    core: AskCore,
    ids: BTreeMap<u64, String>,
    seen: Option<i64>,
}

impl Shell {
    /// The sessions' writes since the last look, as events; the first look only sets the mark.
    async fn tail(&mut self, w: &Writer) -> Vec<AskEv> {
        let since = self.seen;
        match w.db.read(move |c| read_written(c, since)).await {
            Ok((last, rows)) => {
                self.seen = Some(last);
                rows.iter().filter_map(write_of).collect()
            }
            Err(e) => {
                tracing::debug!("the sessions' writes are not read yet: {e}");
                Vec::new()
            }
        }
    }

    async fn input(&mut self, front: &Front, i: Input) {
        let w = &front.writer;
        let mut evs = self.tail(w).await;
        let mut reply = None;
        match i {
            Input::Ev(e) => evs.push(e),
            Input::Start { new, parent, job } => {
                let starter = match (parent, job) {
                    (Some(p), _) => Some(p),
                    (None, Some(j)) => {
                        w.db.read(move |c| starter_of_job(c, &j))
                            .await
                            .ok()
                            .flatten()
                    }
                    (None, None) => None,
                };
                evs.push(AskEv::AgentStart { starter, new });
            }
            Input::Flush(tx) => reply = Some(tx),
        }
        for e in evs {
            for o in self.core.step(e) {
                self.write(w, o).await;
            }
        }
        let live: BTreeSet<u64> = self.core.live().collect();
        self.ids.retain(|k, _| live.contains(k));
        if let Some(tx) = reply {
            let _ = tx.send(());
        }
    }

    /// O, written as the hub. Best effort: a store that is not ready loses it, and a link to an entity that is gone is
    /// refused and skipped.
    async fn write(&mut self, w: &Writer, o: AskOut) {
        match o {
            AskOut::Create {
                key,
                text,
                channel,
                session,
                message_id,
                at,
            } => {
                let a = AskNew {
                    text,
                    at,
                    channel,
                    session: Some(session),
                    message_id,
                    project: None,
                };
                match w
                    .write(&hub(), "work/ask", move |tx| {
                        norn::write::work::new_ask(tx, a)
                    })
                    .await
                {
                    Ok(id) => {
                        self.ids.insert(key, id);
                    }
                    Err(e) => tracing::warn!("an ask not recorded: {e}"),
                }
            }
            AskOut::Link { ask_key, to } => {
                let Some(id) = self.ids.get(&ask_key).cloned() else {
                    return;
                };
                if let Err(e) = w
                    .write(&hub(), "work/asked", move |tx| {
                        norn::write::work::link_asked(tx, &id, &to)
                    })
                    .await
                {
                    tracing::warn!("an asked link not recorded: {e}");
                }
            }
        }
    }
}

/// The shell's task: every input in the order it came, the store's log read before each.
pub async fn run(front: Arc<Front>) {
    let asks = &front.core.asks;
    let Some(mut rx) = asks
        .rx
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
    else {
        return;
    };
    let mut sh = Shell {
        core: AskCore::new(),
        ids: BTreeMap::new(),
        seen: None,
    };
    // the mark first: what was written before this start is not linked again
    sh.tail(&front.writer).await;
    asks.tx.running.store(true, Ordering::SeqCst);
    while let Some(i) = rx.recv().await {
        sh.input(&front, i).await;
    }
}

#[cfg(test)]
mod tests;
