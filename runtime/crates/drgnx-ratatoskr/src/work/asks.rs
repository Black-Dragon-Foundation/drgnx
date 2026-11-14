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
    /// SESSION is being resumed after a restart: its writes wait for its ask ([`AskEv::Restore`],
    /// [`AskEv::NoRestore`]), and a message that reaches it first is its ask instead.
    Restoring { session: String },
    /// SESSION's last user message (TEXT, of CHANNEL, with MESSAGE_ID when it had one) is its current ask again.
    /// ADOPT is the entity of the ask an earlier hub made for exactly that message, when there is one: it is adopted,
    /// never made again.  Ignored when the session has a current ask already.
    Restore {
        session: String,
        text: String,
        channel: String,
        message_id: Option<String>,
        at: f64,
        adopt: Option<String>,
    },
    /// SESSION has no user message to restore from: what it wrote while resuming links to nothing.
    NoRestore { session: String },
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
    /// The ask KEY is the entity ID an earlier hub made: nothing is made for it.
    Adopt { key: u64, id: String },
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
    /// The sessions being resumed, whose writes wait for their ask, and what they wrote meanwhile.
    restoring: BTreeSet<String>,
    held: BTreeMap<String, Vec<String>>,
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
                self.settle_restore(&session);
                self.channel.insert(session.clone(), channel.clone());
                self.open(session, text, channel, message_id, at);
                Vec::new()
            }
            AskEv::SteerDelivered { session, text, at } => {
                self.settle_restore(&session);
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
            } => {
                if self.restoring.contains(&session) {
                    if LINKED.contains(&kind.as_str()) {
                        self.held.entry(session).or_default().push(entity);
                    }
                    return Vec::new();
                }
                match self.current.get(&session) {
                    Some(&key) if LINKED.contains(&kind.as_str()) => self.link(key, entity),
                    _ => Vec::new(),
                }
            }
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
            AskEv::Restoring { session } => {
                if !self.current.contains_key(&session) {
                    self.restoring.insert(session);
                }
                Vec::new()
            }
            AskEv::Restore {
                session,
                text,
                channel,
                message_id,
                at,
                adopt,
            } => {
                // a message that came first, or an earlier restore, is the current ask: this changes nothing
                if !self.restoring.remove(&session) || self.current.contains_key(&session) {
                    self.held.remove(&session);
                    return Vec::new();
                }
                self.channel
                    .entry(session.clone())
                    .or_insert_with(|| channel.clone());
                self.open(session.clone(), text, channel, message_id, at);
                let key = self.next;
                let mut out = Vec::new();
                if let Some(id) = adopt {
                    if let Some(a) = self.asks.get_mut(&key) {
                        a.created = true;
                    }
                    out.push(AskOut::Adopt { key, id });
                }
                for entity in self.held.remove(&session).unwrap_or_default() {
                    out.extend(self.link(key, entity));
                }
                out
            }
            AskEv::NoRestore { session } => {
                self.settle_restore(&session);
                Vec::new()
            }
            AskEv::SessionGone { session } => {
                self.settle_restore(&session);
                self.channel.remove(&session);
                if let Some(old) = self.current.remove(&session) {
                    self.forget_unused(old);
                }
                Vec::new()
            }
        }
    }

    /// SESSION is no longer being restored: what it wrote meanwhile is dropped (a message came first, or there was none
    /// to restore from, or it is gone): never linked to a guess.
    fn settle_restore(&mut self, session: &str) {
        self.restoring.remove(session);
        self.held.remove(session);
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
    /// SESSION is being resumed after a restart.
    Restoring {
        session: String,
    },
    /// SESSION's last user message, when the transcript has one: its current ask again.
    Restore {
        session: String,
        last: Option<LastMessage>,
    },
}

/// The text of the ask a session gets when a hub restart left no message to take it from: the Work map's one line for
/// it, made at the session's first write after the restart (and the same entity at every restart after).
pub const UNKNOWN_ASK: &str = "Ask before a hub restart: not recorded";

/// A session's last user message as its transcript holds it.
#[derive(Clone, Debug, PartialEq)]
pub struct LastMessage {
    pub text: String,
    /// `say`, `chat`, `manager` or `brainstorm`.
    pub channel: String,
    /// The hub's key of the message (`message:ID`), when it had one.
    pub message_id: Option<String>,
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

    /// Session SESSION is being resumed after a restart: what it writes waits for [`AskTx::restore`].
    pub fn restoring(&self, session: &str) {
        let _ = self.tx.send(Input::Restoring {
            session: session.to_string(),
        });
    }

    /// Session SESSION's last user message (none: it has none, or its transcript cannot be read) is its current ask
    /// again; the ask entity an earlier hub made for it is adopted.
    pub fn restore(&self, session: &str, last: Option<LastMessage>) {
        let _ = self.tx.send(Input::Restore {
            session: session.to_string(),
            last,
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
pub(crate) fn hub() -> Caller {
    Caller {
        class: Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// A conclusion a session's tool call recorded: the stamp core's `McpCall`.
#[derive(Clone, Debug, PartialEq)]
pub struct Recorded {
    pub session: String,
    /// The transaction's tool: `mcp:record_decision`, `mcp:note_add`.
    pub tool: String,
    pub conclusion: String,
    pub at: f64,
}

/// What the log held since the last look: the newest `tx` row, the entity versions written, the conclusions recorded.
#[derive(Debug, Default)]
struct Seen {
    last: i64,
    written: Vec<Written>,
    recorded: Vec<Recorded>,
}

/// The newest `tx` row, and when SINCE is given, the spec, plan and task versions written after it (by anyone; the
/// pure [`write_of`] keeps the sessions') and the decisions and findings sessions recorded. The entity scans run only
/// when a session wrote since.
fn read_written(c: &Tx, since: Option<i64>) -> Result<Seen, CoordError> {
    let last: i64 = c.query_row("select coalesce(max(id), 0) from tx", [], |r| r.get(0))?;
    let nothing = Seen {
        last,
        ..Seen::default()
    };
    let Some(since) = since.filter(|s| *s < last) else {
        return Ok(nothing);
    };
    let by_sessions: i64 = c.query_row(
        "select count(*) from tx where id > ?1 and id <= ?2 and session is not null and imported = 0",
        (since, last),
        |r| r.get(0),
    )?;
    if by_sessions == 0 {
        return Ok(nothing);
    }
    let mut q = c.prepare(
        "select t.session, coalesce(t.tool, ''), e.id, t.at from entity e join tx t on t.id = e.created_tx \
         where e.created_tx > ?1 and e.created_tx <= ?2 and t.session is not null and t.imported = 0 \
         and t.state = 'committed' \
         and (e.kind = 'decision' or (e.kind = 'note' and json_extract(e.data, '$.kind') = 'finding')) \
         order by e.created_tx, e.n",
    )?;
    let recorded = q
        .query_map((since, last), |r| {
            Ok(Recorded {
                session: r.get(0)?,
                tool: r.get(1)?,
                conclusion: r.get(2)?,
                at: r.get(3)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
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
    Ok(Seen {
        last,
        written: rows,
        recorded,
    })
}

/// The stamp event R is: the MCP call of its drgnx tool.
pub fn call_of(r: &Recorded) -> Option<crate::work::conclusions::StampEv> {
    let tool = r.tool.strip_prefix("mcp:")?;
    crate::work::conclusions::TOOLS.contains(&tool).then(|| {
        crate::work::conclusions::StampEv::McpCall {
            session: r.session.clone(),
            tool: tool.to_string(),
            call: r.conclusion.clone(),
            at: r.at,
        }
    })
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
    /// The sessions' writes since the last look, as events; the first look only sets the mark. The conclusions they
    /// recorded go to the stamp core at once (their calls answer only after this).
    async fn tail(&mut self, front: &Front) -> Vec<AskEv> {
        let since = self.seen;
        match front.writer.db.read(move |c| read_written(c, since)).await {
            Ok(seen) => {
                self.seen = Some(seen.last);
                let due: Vec<_> = seen
                    .recorded
                    .iter()
                    .filter_map(call_of)
                    .flat_map(|ev| front.core.stamps.step(ev))
                    .collect();
                crate::work::conclusions::put(&front.writer, due).await;
                seen.written.iter().filter_map(write_of).collect()
            }
            Err(e) => {
                tracing::debug!("the sessions' writes are not read yet: {e}");
                Vec::new()
            }
        }
    }

    async fn input(&mut self, front: &Front, i: Input) {
        let w = &front.writer;
        let mut evs = self.tail(front).await;
        let mut reply = None;
        match i {
            // told before the log's writes are read as events: what the session writes after its prompt is held
            Input::Restoring { session } => evs.insert(0, AskEv::Restoring { session }),
            // no user message of its own (a worker, or a transcript that cannot be read): the ask that started it,
            // from the `asked` link that dispatched it; else a line that says the ask was not recorded
            Input::Restore {
                session,
                last: None,
            } => {
                let (last, adopt) = match self.dispatching_ask(w, &session).await {
                    Some((id, last)) => (last, Some(id)),
                    None => {
                        let last = LastMessage {
                            text: UNKNOWN_ASK.to_string(),
                            channel: "chat".to_string(),
                            message_id: None,
                        };
                        let adopt = self.earlier_ask(w, &session, &last).await;
                        (last, adopt)
                    }
                };
                evs.push(AskEv::Restore {
                    session,
                    text: last.text,
                    channel: last.channel,
                    message_id: last.message_id,
                    at: crate::clock::wall_secs(),
                    adopt,
                });
            }
            Input::Restore {
                session,
                last: Some(last),
            } => {
                let adopt = self.earlier_ask(w, &session, &last).await;
                evs.push(AskEv::Restore {
                    session,
                    text: last.text,
                    channel: last.channel,
                    message_id: last.message_id,
                    at: crate::clock::wall_secs(),
                    adopt,
                });
            }
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

    /// The newest ask that an `asked` link joins to SESSION (the link that dispatched it: its manager's or its plan
    /// run's starter's ask), as its entity id and the message it holds. None when no ask links to it.
    async fn dispatching_ask(&self, w: &Writer, session: &str) -> Option<(String, LastMessage)> {
        let to = format!("session:{session}");
        w.db.read(move |c| {
            let Some((_, ask)) = norn::read::work::asks_of(c, &[to.as_str()])?
                .into_iter()
                .next_back()
            else {
                return Ok(None);
            };
            let row = c.query_row(
                "select json_extract(data, '$.text'), json_extract(data, '$.channel'), json_extract(data, '$.message_id') \
                 from entity where id = ?1",
                [&ask],
                |r| {
                    Ok((
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<String>>(2)?,
                    ))
                },
            )?;
            Ok::<_, CoordError>(row.0.map(|text| {
                (
                    ask,
                    LastMessage {
                        text,
                        channel: row.1.unwrap_or_else(|| "chat".to_string()),
                        message_id: row.2,
                    },
                )
            }))
        })
        .await
        .ok()
        .flatten()
    }

    /// The `ask` entity an earlier hub made for SESSION's last message LAST, when it is the session's newest ask and
    /// says the same: by message id when both have one, else by text.  None when there is none (or it cannot be read):
    /// then the ask is made at its first link, as ever; never one that only looks alike.
    async fn earlier_ask(&self, w: &Writer, session: &str, last: &LastMessage) -> Option<String> {
        let sid = session.to_string();
        let newest = w
            .db
            .read(move |c| {
                let row = c.query_row(
                    "select id, json_extract(data, '$.text'), json_extract(data, '$.message_id') from entity \
                     where kind = 'ask' and json_extract(data, '$.session') = ?1 order by n desc limit 1",
                    [&sid],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, Option<String>>(2)?,
                        ))
                    },
                );
                match row {
                    Ok(r) => Ok(Some(r)),
                    Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
                    Err(e) => Err(e.into()),
                }
            })
            .await
            .ok()
            .flatten()?;
        let (id, text, message_id) = newest;
        let same = match (&last.message_id, &message_id) {
            (Some(a), Some(b)) => a == b,
            (None, None) => text.as_deref() == Some(last.text.as_str()),
            _ => false,
        };
        same.then_some(id)
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
            AskOut::Adopt { key, id } => {
                self.ids.insert(key, id);
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
    sh.tail(&front).await;
    asks.tx.running.store(true, Ordering::SeqCst);
    while let Some(i) = rx.recv().await {
        sh.input(&front, i).await;
    }
}

#[cfg(test)]
mod tests;
