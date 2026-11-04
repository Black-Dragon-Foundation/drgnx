//! The front writes work.db (docs/develop/coordination.md, "Who writes what"): the editor's five methods and the
//! seam's `coord/*`, each decoded by the registry, written by norn's writer in one transaction and answered typed.
//!
//! - **Errors:** a file that is not ready is `internal` with its text (looked at once more first: the schema tick's
//!   open, now); a newer one is `schema`; a busy one `internal` "work.db is busy; retry" (a best-effort event and
//!   `coord/agent seen` answer `{}` instead); a writer's refusal `invalid-params` with its text.
//! - **`events`:** every committed write wakes [`broadcast_events`], which reads the new `event` rows on the reader's
//!   thread and sends `events` `{since, last, events}` to the subscribers: at most 200 rows a batch, every 0.25 s at
//!   most.  The 2 s schema tick wakes it too.
//! - **The tools' hub** ([`ToolHub`]): `sessions()` is the front's session table, read at once; `notify()` wakes the
//!   broadcast, the records' views and the delivery; `after_tool()` holds a session's tool answer until its writes are
//!   linked to its current ask ([`crate::work::asks`]).
//! - **One writer:** the hub. A `tx` row's actor comes from the connection ([`tx_meta`]); no param names a writer, and
//!   `messages/send` refuses `sender` from every caller.

use crate::dispatch::Caller;
use crate::front::Front;
use mimir::BoxFuture;
use norn::read::decisions::{self as decision_log, Decision as Logged};
use norn::store::{CoordDb, CoordError, WTx};
use norn::tools::{Hub, SessionRow};
use norn::write::{agents, cards, decisions, event, jobs, messages, meta, prune, review, tasks};
use runstav::methods::Params;
use runstav::methods::coord as api;
use runstav::registry::{self, Class};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::Notify;
use urdr::graph::{Class as TxClass, TxMeta};

/// The `events` broadcast's pace.
pub const PACE: Duration = Duration::from_millis(250);
/// The most event rows one `events` event carries.
pub const EVENTS_BATCH: u64 = 200;

/// What a write wakes, and the writes counted for `status`.
#[derive(Default)]
pub struct Signals {
    events: Notify,
    /// A message may be waiting for a hub session (delivery, Task 24).
    pub deliver: Notify,
    writes: AtomicU64,
    /// A write the record views may follow ([`crate::records::follow`]).
    pub records: Notify,
    /// A write the Work map may follow: asks, specs, plans, tasks, worktree bases, cards ([`crate::work::map::run`]).
    pub map: Notify,
    /// What the proposal tools ask of the records (set once the hub's front is built).
    pub records_tool: std::sync::OnceLock<RecordsTool>,
    /// Counts the writes that may have settled a card or made or revoked a grant (`cards/settle`, `graph/grants`):
    /// each browser session's web proxy reads its grants and cards again ([`crate::browser::web`]).
    pub grants: tokio::sync::watch::Sender<u64>,
}

/// The proposal tools' door into the records: the proposal ID, `None` to read it or `Some(accept)` to decide it,
/// and the session asking (always an agent: the user decides through `records/decide`); the answer is the tool's text.
pub type RecordsTool = Arc<
    dyn Fn(String, Option<bool>, Option<String>) -> BoxFuture<'static, Result<String, String>>
        + Send
        + Sync,
>;

impl Signals {
    /// A transaction of the front's methods committed: counted, and its events go out.
    pub fn wrote(&self) {
        self.writes.fetch_add(1, Ordering::Relaxed);
        self.records.notify_one();
        self.map.notify_one();
        self.deliver.notify_one();
        self.events_soon();
    }

    /// New `event` rows may be there: the broadcaster looks (once, however often it is woken meanwhile).
    pub fn events_soon(&self) {
        self.events.notify_one();
    }

    /// A message may be waiting for a hub session: the delivery looks (coalesced).
    pub fn notify_soon(&self) {
        self.deliver.notify_one();
    }

    /// The transactions the front's methods committed since the hub started.
    pub fn writes(&self) -> u64 {
        self.writes.load(Ordering::Relaxed)
    }
}

/// The front's writer: norn's store and what its writes wake.
#[derive(Clone)]
pub struct Writer {
    pub db: CoordDb,
    pub signals: Arc<Signals>,
}

impl Writer {
    /// F in one transaction of the graph writer, its `tx` row from CALLER and METHOD (see [`tx_meta`]).  A store that
    /// was not ready is looked at again first (norn's store does, for the tools too): a work.db the migration just
    /// finished is written at once, not at the next tick.
    pub(crate) async fn write<R, F>(
        &self,
        caller: &Caller,
        method: &'static str,
        f: F,
    ) -> Result<R, CoordError>
    where
        R: Send + 'static,
        F: FnOnce(&mut WTx<'_>) -> Result<R, CoordError> + Send + 'static,
    {
        let r = self.db.write(tx_meta(caller, method), f).await;
        if r.is_ok() {
            self.signals.wrote();
            if matches!(method, "cards/settle" | "graph/grants") {
                self.signals.grants.send_modify(|n| *n += 1);
            }
        }
        r
    }
}

/// The `tx` row of a front method's write (Urdr Task 12): who it is comes from the connection, never from a param.
/// The hub is the one writer; the actor is
/// - for a seam method (`coord/*`, the hub's own housekeeping): `hub`, class `system`;
/// - for the editor's own methods (`cards/settle`, `messages/*`, `events/add`, `review/mark`) from the user's
///   connection: `user`, class `user`;
/// - for an agent socket's session: `agent:SID`, class `agent`;
/// - for anyone else (a service connection, the front's own timers): `hub`, class `system`.
///
/// `tool` is `proto:<method>`.
pub fn tx_meta(caller: &Caller, method: &str) -> TxMeta {
    let tool = format!("proto:{method}");
    let mut meta = if method.starts_with("coord/") {
        TxMeta::new("hub", TxClass::System, tool)
    } else {
        match (caller.class, &caller.sid) {
            (Class::User, _) => TxMeta::new("user", TxClass::User, tool),
            (Class::Agent, Some(sid)) => {
                let mut m = TxMeta::new(format!("agent:{sid}"), TxClass::Agent, tool);
                m.session = Some(sid.clone());
                m
            }
            _ => TxMeta::new("hub", TxClass::System, tool),
        }
    };
    meta.job = caller.job.clone();
    meta
}

/// A writer's error as the method answers it.
pub(crate) fn fail(e: CoordError) -> Error {
    let (code, message) = match &e {
        CoordError::ReadOnly { .. } => (ErrorCode::Schema, e.to_string()),
        CoordError::Busy => (ErrorCode::Internal, "work.db is busy; retry".into()),
        CoordError::Refused(text) => (ErrorCode::InvalidParams, text.clone()),
        CoordError::NotReady(_) => (ErrorCode::Internal, e.to_string()),
        CoordError::Sql(_) => {
            tracing::warn!("a coordination write failed: {e}");
            (ErrorCode::Internal, e.to_string())
        }
    };
    Error {
        code,
        message,
        path: None,
    }
}

/// Seconds since the epoch, as `float-time` gives them.
fn now() -> f64 {
    crate::clock::wall_secs()
}

/// A wire number as the store's integer.
fn int(n: u64) -> i64 {
    i64::try_from(n).unwrap_or(i64::MAX)
}

fn decision(d: Logged) -> api::Decision {
    api::Decision {
        n: d.n,
        kind: d.kind,
        subject: d.subject,
        task: d.task,
        paths: d.paths,
        reason: d.reason,
        author: d.author,
        status: d.status,
        job: d.job,
        replaces: d.replaces,
        at: d.at,
        ver: d.ver,
    }
}

fn kind(k: api::EventKind) -> event::EventKind {
    event::EventKind::parse(k.as_str()).expect("the registry's event kinds are the writer's")
}

/// An event's `data`: a turn's `start`/`stop` says `turn: true` in it.
fn turn(data: Option<&serde_json::Map<String, Value>>) -> bool {
    data.and_then(|d| d.get("turn")) == Some(&Value::Bool(true))
}

/// CALLER's PARAMS when they are a method this module serves: the answer (a write committed, or why not).  Any other
/// method's params come back (boxed: `Params` is large).
pub async fn serve(
    w: &Writer,
    caller: &Caller,
    params: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    let now = now();
    let answer = match params {
        // an access card settles into a grant, a close card into done (crate::graph); the rest as they are
        Params::CardsSettle(p) => {
            let (card, choice) = (int(p.card), p.choice.as_str().to_owned());
            // the front's goes through crate::graph::serve, which has the tools a settings card needs
            return Ok(crate::graph::settle(w, caller, card, choice, now).await);
        }
        Params::MessagesSend(p) => {
            // the sender is the connection's, never a param: no caller names one
            if p.sender.is_some() {
                return Ok(Err(Error {
                    code: ErrorCode::InvalidParams,
                    message: "a message's sender is its connection's; no caller names one".into(),
                    path: Some("sender".into()),
                }));
            }
            let s = messages::Send {
                job: p.job.map(|j| j.as_str().to_owned()),
                sender: None,
                recipient: p.recipient.as_str().to_owned(),
                text: p.text.as_str().to_owned(),
                seen: p.seen,
                answers: p.answers.map(int),
                question: p.question == Some(true),
            };
            w.write(caller, "messages/send", move |tx| {
                Ok(match messages::send(tx, s.clone(), now)? {
                    messages::SendResult::Ok { id, state } => api::SendResult {
                        ok: Some(true),
                        id: Some(id.max(0) as u64),
                        state: Some(state),
                        ..Default::default()
                    },
                    messages::SendResult::Held { version, seen } => api::SendResult {
                        held: Some(true),
                        version: Some(version),
                        changes: Some(
                            decision_log::decisions_since(tx.sql(), seen, None)?
                                .into_iter()
                                .map(decision)
                                .collect(),
                        ),
                        ..Default::default()
                    },
                })
            })
            .await
            .map(|r| json!(r))
        }
        Params::MessagesMark(p) => {
            let (id, state) = (int(p.id), p.state.as_str());
            w.write(caller, "messages/mark", move |tx| {
                messages::mark(tx, id, state, now)
            })
            .await
            .map(|changed| json!(api::Changed { changed }))
        }
        Params::EventsAdd(p) => {
            let best_effort = p.best_effort == Some(true);
            let data = p.data.map(|d| d.into_inner());
            let e = event::Event {
                at: now,
                agent: p.agent.map(|a| a.as_str().to_owned()),
                job: p.job.map(|j| j.as_str().to_owned()),
                task: p.task.map(|t| t.as_str().to_owned()),
                kind: kind(p.kind),
                summary: p.summary.map(|s| s.as_str().to_owned()).unwrap_or_default(),
                turn: turn(data.as_ref()),
                data: data.map(Value::Object),
            };
            match w
                .write(caller, "events/add", move |tx| event::event(tx, e.clone()))
                .await
            {
                Err(CoordError::Busy) if best_effort => Ok(json!({})),
                r => r.map(|id| {
                    json!(api::Added {
                        id: Some(id.max(0) as u64)
                    })
                }),
            }
        }
        Params::ReviewMark(p) => {
            let agent = p.agent.as_str().to_owned();
            let (path, hash) = (p.path.into_inner(), p.hash.into_inner());
            let state = p.state.as_str();
            let ev = p.event.map(|e| {
                let data = e.data.map(|d| d.into_inner());
                event::Event {
                    at: now,
                    agent: Some(agent.clone()),
                    job: e.job.map(|j| j.as_str().to_owned()),
                    task: None,
                    kind: kind(e.kind),
                    summary: e.summary.map(|s| s.as_str().to_owned()).unwrap_or_default(),
                    turn: turn(data.as_ref()),
                    data: data.map(Value::Object),
                }
            });
            w.write(caller, "review/mark", move |tx| {
                review::review_mark(tx, &agent, &path, state, &hash, now, ev.clone())
            })
            .await
            .map(|ok| json!(ok))
        }
        Params::CoordJobCreate(p) => {
            let j = jobs::NewJob {
                id: p.id.as_str().to_owned(),
                title: p.title.as_str().to_owned(),
                plan: p.plan.map(|s| s.into_inner()),
                repo: p.repo.map(|s| s.into_inner()),
                tasks: p
                    .tasks
                    .map(|t| t.into_inner())
                    .unwrap_or_default()
                    .into_iter()
                    .map(|t| jobs::NewTask {
                        n: int(t.n),
                        title: t.title.as_str().to_owned(),
                        role: t.role.map(|r| r.into_inner()),
                        deps: t
                            .deps
                            .map(|d| d.into_inner())
                            .unwrap_or_default()
                            .into_iter()
                            .map(int)
                            .collect(),
                    })
                    .collect(),
                data: p.data.map(|d| Value::Object(d.into_inner())),
            };
            w.write(caller, "coord/job-create", move |tx| {
                jobs::job_create(tx, j.clone(), now)
            })
            .await
            .map(|id| json!(api::JobCreated { id }))
        }
        Params::CoordJobSet(p) => {
            let id = p.id.as_str().to_owned();
            let status = p.status.map(|s| s.as_str().to_owned());
            let data = p.data.map(|d| Value::Object(d.into_inner()));
            w.write(caller, "coord/job-set", move |tx| {
                jobs::job_set(tx, &id, status.as_deref(), data.as_ref(), now)
            })
            .await
            .map(|()| json!(true))
        }
        Params::CoordTaskStatus(p) => {
            let task = p.task.as_str().to_owned();
            let status = p.status.as_str().to_owned();
            let agent = p.agent.map(|a| a.as_str().to_owned());
            w.write(caller, "coord/task-status", move |tx| {
                tasks::force_status(tx, &task, &status, agent.as_deref(), now)
            })
            .await
            .map(|ok| json!(ok))
        }
        Params::CoordLeases(p) => {
            let renew: Vec<String> = p
                .renew
                .map(|r| r.into_inner())
                .unwrap_or_default()
                .iter()
                .map(|a| a.as_str().to_owned())
                .collect();
            let stale = p.release_stale == Some(true);
            w.write(caller, "coord/leases", move |tx| {
                for agent in &renew {
                    tasks::renew(tx, agent, now)?;
                }
                if stale {
                    tasks::release_stale(tx, now)
                } else {
                    Ok(Vec::new())
                }
            })
            .await
            .map(|released| {
                json!(api::Leases {
                    released: released
                        .into_iter()
                        .map(|r| api::Released {
                            task: r.task,
                            agent: r.agent,
                            job: r.job,
                        })
                        .collect(),
                })
            })
        }
        Params::CoordDecide(p) => {
            let d = decisions::Decide {
                kind: p.kind.into_inner(),
                subject: p.subject.as_str().to_owned(),
                task: p.task.map(|t| t.as_str().to_owned()),
                paths: p.paths.map(|s| s.as_str().to_owned()),
                reason: p.reason.map(|s| s.as_str().to_owned()),
                author: p.author.as_str().to_owned(),
                seen: p.seen,
                replaces: p.replaces.map(int),
                job: p.job.map(|j| j.as_str().to_owned()),
            };
            w.write(caller, "coord/decide", move |tx| {
                decisions::decide(tx, d.clone(), now)
            })
            .await
            .map(|r| {
                json!(match r {
                    decisions::DecideResult::Ok { n, status, version } => api::Decided {
                        ok: Some(true),
                        n: Some(n),
                        status: Some(status),
                        version: Some(version),
                        ..Default::default()
                    },
                    decisions::DecideResult::Held(h) => api::Decided {
                        held: Some(true),
                        version: Some(h.version),
                        changes: Some(h.changes.into_iter().map(decision).collect()),
                        ..Default::default()
                    },
                    decisions::DecideResult::Error(text) => api::Decided {
                        error: Some(text),
                        ..Default::default()
                    },
                })
            })
        }
        Params::CoordAgent(p) => match (p.register, p.seen) {
            (Some(a), _) => {
                let r = agents::AgentRegister {
                    id: a.id.as_str().to_owned(),
                    kind: a.kind.map(|s| s.into_inner()),
                    name: a.name.map(|s| s.into_inner()),
                    cwd: a.cwd.map(|s| s.into_inner()),
                    worktree: a.worktree.map(|s| s.into_inner()),
                    branch: a.branch.map(|s| s.into_inner()),
                    base: a.base.map(|s| s.into_inner()),
                    plan: a.plan.map(|s| s.into_inner()),
                    task: a.task.map(|t| t.as_str().to_owned()),
                    pid: a.pid.map(int),
                    clear: a
                        .clear
                        .map(|c| c.into_inner())
                        .unwrap_or_default()
                        .iter()
                        .filter_map(|f| agents::AgentField::parse(f.as_str()))
                        .collect(),
                };
                w.write(caller, "coord/agent", move |tx| {
                    agents::agent_register(tx, r.clone(), now)
                })
                .await
                .map(|id| {
                    json!(api::AgentResult {
                        id: Some(id),
                        ..Default::default()
                    })
                })
            }
            (None, Some(id)) => {
                let id = id.as_str().to_owned();
                match w
                    .write(caller, "coord/agent", move |tx| {
                        agents::agent_seen(tx, &id, now)
                    })
                    .await
                {
                    // telemetry: a busy file is no error
                    Err(CoordError::Busy) => Ok(json!({})),
                    r => r.map(|seen| {
                        json!(api::AgentResult {
                            seen,
                            ..Default::default()
                        })
                    }),
                }
            }
            // the registry's check takes one of the two
            (None, None) => Err(CoordError::Refused(
                "coord/agent takes one of register or seen".into(),
            )),
        },
        Params::CoordCardCreate(p) => {
            let c = cards::NewCard {
                job: p.job.map(|j| j.as_str().to_owned()),
                task: p.task.map(|t| t.as_str().to_owned()),
                kind: p.kind.map(|k| k.into_inner()),
                title: p.title.map(|t| t.as_str().to_owned()),
                data: p.data.map(|d| Value::Object(d.into_inner())),
            };
            w.write(caller, "coord/card-create", move |tx| {
                cards::card_create(tx, c.clone(), now)
            })
            .await
            .map(|id| {
                json!(api::CardCreated {
                    id: id.max(0) as u64
                })
            })
        }
        Params::CoordCardSet(p) => {
            let id = int(p.id);
            let set = cards::CardSet {
                title: p.title.map(|t| t.as_str().to_owned()),
                data: p.data.map(|d| Value::Object(d.into_inner())),
                state: p.state.map(|s| s.as_str().to_owned()),
            };
            w.write(caller, "coord/card-set", move |tx| {
                cards::card_set(tx, id, set.clone(), now)
            })
            .await
            .map(|()| json!(true))
        }
        Params::CoordHeld(p) => {
            let agent = p.agent.as_str().to_owned();
            // the Lisp's argument counts only as non-nil
            let held = p.held.then_some(0);
            w.write(caller, "coord/held", move |tx| {
                meta::note_held(tx, &agent, held)
            })
            .await
            .map(|()| json!(true))
        }
        Params::CoordPrune(_) => {
            // the daily prune never fails its caller: the next day's runs
            let pruned = match w
                .write(caller, "coord/prune", move |tx| {
                    prune::prune_daily_tx(tx, now)
                })
                .await
            {
                Ok(ran) => ran,
                Err(e) => {
                    tracing::info!("the daily event prune did not run: {e}");
                    false
                }
            };
            Ok(json!(api::Pruned { pruned }))
        }
        other => return Err(Box::new(other)),
    };
    Ok(answer.map_err(fail))
}

/// Send the `events` the writer added, whenever woken: from the newest row at start, at most [`EVENTS_BATCH`] rows
/// an event and one batch each [`PACE`].
pub async fn broadcast_events(front: Arc<Front>) {
    let signals = front.writer.signals.clone();
    let mut last = front.work_db.last_event_id().await.unwrap_or_else(|e| {
        tracing::warn!("cannot read work.db's newest event: {e}");
        0
    });
    loop {
        signals.events.notified().await;
        loop {
            match front
                .work_db
                .events_since(Some(last), Some(EVENTS_BATCH))
                .await
            {
                Ok(page) if !page.events.is_empty() => {
                    let full = page.events.len() as u64 >= EVENTS_BATCH;
                    last = page.last;
                    front.broadcast("events", json!(page));
                    if !full {
                        break;
                    }
                    crate::clock::sleep(PACE).await;
                }
                Ok(_) => break,
                Err(e) => {
                    tracing::warn!("cannot read work.db's new events: {e}");
                    break;
                }
            }
        }
        crate::clock::sleep(PACE).await;
    }
}

/// The hub as the coordination tools see it (`norn::tools::Hub`).
pub struct ToolHub {
    pub signals: Arc<Signals>,
    /// The editors the settings tools ask (unified-settings Task 32).
    pub editors: Arc<crate::settings::agents::Editors>,
    /// What the hub read of `settings.el`, for a `settings_get` with no editor.
    pub settings: Arc<crate::settings::Settings>,
    /// The front the job tools call (set once the front is in its `Arc`: [`ToolHub::bind`]).
    pub front: std::sync::OnceLock<std::sync::Weak<Front>>,
}

impl ToolHub {
    /// The front the job tools reach `exec/*` through.
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
    }
}

impl Hub for ToolHub {
    /// The front's own session table, read at once; `None` only before the front is bound.
    fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
        let front = self.front.get().and_then(std::sync::Weak::upgrade);
        Box::pin(async move { front.map(|f| f.core.agents.snapshots()) })
    }

    fn proposal(
        &self,
        id: String,
        accept: Option<bool>,
        session: Option<String>,
    ) -> BoxFuture<'_, Result<String, String>> {
        match self.signals.records_tool.get() {
            Some(f) => f(id, accept, session),
            None => Box::pin(async { Err("the records are not open".to_string()) }),
        }
    }

    fn notify(&self) {
        // every tool write says so: the record views follow it too
        self.signals.records.notify_one();
        self.signals.map.notify_one();
        self.signals.events_soon();
        self.signals.notify_soon();
    }

    fn exec(
        &self,
        sid: &str,
        method: &'static str,
        params: Value,
    ) -> BoxFuture<'_, Result<Value, String>> {
        let sid = sid.to_string();
        Box::pin(async move {
            let front = self
                .front
                .get()
                .and_then(std::sync::Weak::upgrade)
                .ok_or("jobs are not ready: the hub is starting")?;
            let m = registry::find(method).ok_or_else(|| format!("no method {method}"))?;
            let (params, _) = (m.decode)(&params).map_err(|e| e.message)?;
            let caller = Caller {
                class: Class::Agent,
                sid: Some(sid),
                job: None,
                conn_id: 0,
            };
            match crate::agent_core::serve(&front, &caller, params).await {
                Ok(answer) => answer.map_err(|e| e.message),
                Err(_) => Err(format!("{method} is not a job method")),
            }
        })
    }

    fn manager(
        &self,
        sid: &str,
        op: &'static str,
        args: Value,
    ) -> BoxFuture<'_, Result<String, String>> {
        let sid = sid.to_string();
        Box::pin(async move {
            let front = self
                .front
                .get()
                .and_then(std::sync::Weak::upgrade)
                .ok_or("the hub is starting")?;
            crate::manager::tool(&front, &sid, op, args).await
        })
    }

    /// A session's tool call ended: its graph writes link to its current ask before it answers.
    fn after_tool(&self, _sid: &str, _tool: &'static str) -> BoxFuture<'_, ()> {
        let front = self.front.get().and_then(std::sync::Weak::upgrade);
        Box::pin(async move {
            if let Some(f) = front {
                f.core.asks.handle().flush().await;
            }
        })
    }

    fn wait_refused(&self, sid: &str) {
        if let Some(front) = self.front.get().and_then(std::sync::Weak::upgrade)
            && let Ok(s) = front.core.agents.find(sid)
        {
            s.refuse_wait();
        }
    }

    fn propose(
        &self,
        event: runstav::methods::settings::Proposed,
        wait: Duration,
    ) -> BoxFuture<'_, norn::tools::EditorAnswer> {
        Box::pin(self.editors.propose(event, wait))
    }

    fn explain(
        &self,
        scope: runstav::methods::settings::SettingScope,
        names: Option<Vec<String>>,
        root: Option<String>,
    ) -> BoxFuture<'_, Option<Vec<Value>>> {
        Box::pin(
            self.editors
                .explain(scope, names, root, norn::tools::settings::EXPLAIN_WAIT),
        )
    }

    /// The runtime settings in effect globally (the project overrides are the editor's, keyed by its names).
    fn known_settings(&self, names: Option<&[String]>) -> Vec<Value> {
        crate::settings::RUNTIME_NAMES
            .iter()
            .filter(|n| names.is_none_or(|l| l.iter().any(|x| x.as_str() == **n)))
            .filter_map(|n| {
                let (value, _) = self.settings.effective(n, None)?;
                Some(json!({"name": n, "value": value, "source": "hub"}))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::registry::find;

    const DDL: &str = include_str!("../../../../test/fixtures/work-db-6.sql");

    fn caller() -> Caller {
        Caller {
            class: Class::User,
            sid: None,
            job: None,
            conn_id: 1,
        }
    }

    fn params(method: &str, v: Value) -> Params {
        (find(method).unwrap().decode)(&v).unwrap().0
    }

    fn writer(dir: &std::path::Path) -> Writer {
        Writer {
            db: CoordDb::spawn(dir.join("work.db")),
            signals: Arc::new(Signals::default()),
        }
    }

    async fn call(w: &Writer, method: &str, v: Value) -> Result<Value, Error> {
        match serve(w, &caller(), params(method, v)).await {
            Ok(answer) => answer,
            Err(_) => panic!("{method} is not the writer's"),
        }
    }

    #[test]
    fn tx_meta_per_caller_kind() {
        let user = tx_meta(&caller(), "cards/settle");
        assert_eq!(
            (user.actor.as_str(), user.class, user.tool.as_str()),
            ("user", TxClass::User, "proto:cards/settle")
        );
        // the seam's methods are the hub's, and so is a service connection's write
        let seam = tx_meta(&caller(), "coord/decide");
        assert_eq!(
            (seam.actor.as_str(), seam.class, seam.tool.as_str()),
            ("hub", TxClass::System, "proto:coord/decide")
        );
        let service = tx_meta(
            &Caller {
                class: Class::Service,
                ..caller()
            },
            "messages/send",
        );
        assert_eq!(
            (service.actor.as_str(), service.class),
            ("hub", TxClass::System)
        );
        // an agent socket's session writes as itself, with its job
        let agent = tx_meta(
            &Caller {
                class: Class::Agent,
                sid: Some("s-1".into()),
                job: Some("j".into()),
                conn_id: 2,
            },
            "events/add",
        );
        assert_eq!(
            (
                agent.actor.as_str(),
                agent.class,
                agent.session.as_deref(),
                agent.job.as_deref()
            ),
            ("agent:s-1", TxClass::Agent, Some("s-1"), Some("j"))
        );
    }

    #[tokio::test]
    async fn not_ready_is_internal_with_its_text() {
        let dir = tempfile::tempdir().unwrap();
        // a schema-5 file: the opening rule's text, as an internal error
        let file = dir.path().join("work.db");
        urdr::Connection::open(&file)
            .unwrap()
            .execute_batch(
                "create table meta (key text primary key, value text); insert into meta values ('schema', '5');",
            )
            .unwrap();
        let w = writer(dir.path());
        let e = call(&w, "cards/settle", json!({"card": 1, "choice": "ok"}))
            .await
            .unwrap_err();
        assert_eq!(
            (e.code, e.message.as_str()),
            (
                ErrorCode::Internal,
                "work.db is schema 5; open it once with drgnx 6 first, or remove it (installs are disposable)"
            )
        );
        assert_eq!(w.signals.writes(), 0);
        // the daily prune never fails its caller
        assert_eq!(
            call(&w, "coord/prune", json!({})).await.unwrap(),
            json!({"pruned": false})
        );
        // another method's params come back
        assert!(
            serve(&w, &caller(), params("job/status", json!({})))
                .await
                .is_err()
        );
        // once a schema-6 file is there (made, say, by an older drgnx), the next write migrates it and goes through
        // (no tick needed)
        let next = dir.path().join("next.db");
        urdr::Connection::open(&next)
            .unwrap()
            .execute_batch(DDL)
            .unwrap();
        for ext in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(dir.path().join(format!("work.db{ext}")));
        }
        std::fs::rename(&next, &file).unwrap();
        let card = call(
            &w,
            "coord/card-create",
            json!({"kind": "ask", "title": "t"}),
        )
        .await
        .unwrap();
        assert!(card["id"].as_u64().is_some(), "{card}");
        assert_eq!(w.signals.writes(), 1);
    }

    #[tokio::test]
    async fn read_only_is_schema() {
        let dir = tempfile::tempdir().unwrap();
        urdr::Connection::open(dir.path().join("work.db"))
            .unwrap()
            .execute_batch(
                "create table meta (key text primary key, value text); insert into meta values ('schema', '99');",
            )
            .unwrap();
        let w = writer(dir.path());
        let e = call(&w, "events/add", json!({"kind": "job"}))
            .await
            .unwrap_err();
        assert_eq!(
            (e.code, e.message.as_str()),
            (
                ErrorCode::Schema,
                "work.db is schema 99, newer than this drgnx: read-only"
            )
        );
    }

    #[tokio::test]
    async fn writes_are_typed_and_counted() {
        let dir = tempfile::tempdir().unwrap();
        urdr::Connection::open(dir.path().join("work.db"))
            .unwrap()
            .execute_batch(DDL)
            .unwrap();
        let w = writer(dir.path());
        let card = call(
            &w,
            "coord/card-create",
            json!({"kind": "ask", "title": "t"}),
        )
        .await
        .unwrap();
        let id = card["id"].clone();
        let settle = json!({"card": id, "choice": "yes"});
        assert_eq!(
            call(&w, "cards/settle", settle.clone()).await.unwrap(),
            json!({"settled": true})
        );
        assert_eq!(
            call(&w, "cards/settle", settle).await.unwrap(),
            json!({"settled": false})
        );
        let e = call(
            &w,
            "messages/send",
            json!({"recipient": "a1", "text": "hi", "sender": "a2"}),
        )
        .await
        .unwrap_err();
        assert_eq!(
            (e.code, e.path.as_deref()),
            (ErrorCode::InvalidParams, Some("sender"))
        );
        let sent = call(
            &w,
            "messages/send",
            json!({"recipient": "a1", "text": "hi"}),
        )
        .await
        .unwrap();
        assert_eq!(
            (sent["ok"].clone(), sent["state"].clone()),
            (json!(true), json!("queued"))
        );
        // every answer fits its method's result
        let added = call(&w, "events/add", json!({"kind": "comment", "summary": "s"}))
            .await
            .unwrap();
        for (method, v) in [
            ("coord/card-create", card),
            ("messages/send", sent),
            ("events/add", added),
        ] {
            assert_eq!(
                (find(method).unwrap().check_result)(&v).unwrap(),
                v,
                "{method}"
            );
        }
        assert_eq!(w.signals.writes(), 5);
        // the refused send wrote nothing
        let n: i64 = urdr::Connection::open(dir.path().join("work.db"))
            .unwrap()
            .query_row("select count(*) from message", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    #[tokio::test]
    async fn a_tool_write_reaches_the_view() {
        let signals = Arc::new(Signals::default());
        let hub = ToolHub {
            signals: signals.clone(),
            editors: Arc::new(Default::default()),
            settings: Arc::new(crate::settings::Settings::new()),
            front: Default::default(),
        };
        // the tools call `notify` after each write: the records' follower wakes
        hub.notify();
        tokio::time::timeout(Duration::from_millis(500), signals.records.notified())
            .await
            .expect("the follower was not woken");
    }

    #[tokio::test]
    async fn sender_is_refused_for_every_class() {
        let dir = tempfile::tempdir().unwrap();
        urdr::Connection::open(dir.path().join("work.db"))
            .unwrap()
            .execute_batch(DDL)
            .unwrap();
        let w = writer(dir.path());
        for c in [
            caller(),
            Caller {
                class: Class::Service,
                ..caller()
            },
            Caller {
                class: Class::Agent,
                sid: Some("s-1".into()),
                ..caller()
            },
        ] {
            let p = params(
                "messages/send",
                json!({"recipient": "a1", "text": "hi", "sender": "a2"}),
            );
            let e = match serve(&w, &c, p).await {
                Ok(answer) => answer.unwrap_err(),
                Err(_) => panic!("messages/send is not the writer's"),
            };
            assert_eq!(
                (e.code, e.path.as_deref()),
                (ErrorCode::InvalidParams, Some("sender")),
                "{:?}",
                c.class
            );
        }
        assert_eq!(w.signals.writes(), 0, "a refused send writes nothing");
    }

    #[tokio::test]
    async fn tool_hub_sessions_are_the_fronts() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("work.db");
        urdr::Connection::open(&db)
            .unwrap()
            .execute_batch(DDL)
            .unwrap();
        let (config, work) = (dir.path().join("config"), dir.path().join("work"));
        std::fs::create_dir_all(&config).unwrap();
        std::fs::create_dir_all(&work).unwrap();
        let mock = crate::embed::tests::mock_binary();
        let file = config.join("settings.el");
        std::fs::write(
            &file,
            format!(
                "(drgnx-settings :version 1 (drgnx-agents-profiles ((\"mock-claude\" :command ({mock:?} \"acp\" \"--as\" \"claude\")))))\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let front = Arc::new(Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.path().join("hub-x.sock"),
            crate::store::WorkDb::spawn(db.clone()).unwrap(),
            CoordDb::spawn(db),
        ));
        let (_store, runtime) = crate::runtime_db::open(dir.path()).unwrap();
        front.settings.open(config, runtime);
        let hub: Arc<ToolHub> = front.tool_hub.clone();
        assert!(hub.sessions().await.is_none(), "no front bound yet");
        hub.bind(&front);
        assert_eq!(hub.sessions().await.map(|s| s.len()), Some(0));
        let user = caller();
        let start = params(
            "agents/start",
            json!({"profile": "mock-claude", "cwd": work.display().to_string()}),
        );
        let id = match crate::agent_core::serve(&front, &user, start).await {
            Ok(Ok(v)) => v["id"].as_str().unwrap().to_owned(),
            Ok(Err(e)) => panic!("agents/start: {}", e.message),
            Err(_) => panic!("agents/start is not the agent core's"),
        };
        // listed at once, from the front's own table: no request, no deadline
        let rows = hub.sessions().await.expect("the front is bound");
        assert!(
            rows.iter().any(|r| r.id == id),
            "{id} not in {:?}",
            rows.iter().map(|r| &r.id).collect::<Vec<_>>()
        );
        let kill = params("agents/kill", json!({"id": id}));
        let _ = crate::agent_core::serve(&front, &user, kill).await;
    }
}
