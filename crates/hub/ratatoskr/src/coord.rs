//! The front writes work.db (docs/develop/coordination.md, "Who writes what"): the editor's five methods, each decoded
//! by the registry, written by norn's writer in one transaction and answered typed.
//!
//! - **Errors:** a file that is not ready is `internal` with its text (looked at once more first: the schema tick's
//!   open, now); a newer one is `schema`; a busy one `internal` "work.db is busy; retry" (a best-effort event
//!   answers `{}` instead); a writer's refusal `invalid-params` with its text.
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
use norn::write::{event, messages, review};
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
    /// A write or a closed step the trails may follow ([`crate::work::trail::run`]).
    pub trail: Notify,
    /// What the proposal tools ask of the records (set once the hub's front is built).
    pub records_tool: std::sync::OnceLock<RecordsTool>,
    /// Counts the changes that may change what a browser session may reach ([`Signals::answers_changed`]): each
    /// session's web proxy reads its cells, grants and cards again at once ([`crate::browser::web`]).
    pub answers: tokio::sync::watch::Sender<u64>,
}

/// The conflict tools' door into the records: the conflicted record's ID, `None` to read it or `Some(keep_file)` to
/// resolve it, and the session asking (always an agent: the user resolves through `records/resolve`); the answer is the
/// tool's text.
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
        self.trail.notify_one();
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

    /// What the user answered may have changed: a write of theirs (a card settled, a grant made or revoked, a plan's or
    /// a project's matrix override), the settings in effect, or the away flag.  Every web proxy reads again.
    pub fn answers_changed(&self) {
        self.answers.send_modify(|n| *n += 1);
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
            if caller.class == Class::User || matches!(method, "cards/settle" | "graph/grants") {
                self.signals.answers_changed();
            }
        }
        r
    }
}

/// The method name of the hub's hook records (`hook_points`): not a wire method.
pub const HOOKS_METHOD: &str = "hub/hooks";
/// The `tx` actor of those records, and only of those.
pub const HOOKS_ACTOR: &str = "hub:hooks";

/// The `tx` row of a front method's write (Urdr Task 12): who it is comes from the connection, never from a param.
/// The hub is the one writer; the actor is
/// - for the hub's own housekeeping writes (`coord/*` tool names, no wire method): `hub`, class `system`;
/// - for the editor's own methods (`cards/settle`, `messages/*`, `events/add`, `review/mark`) from the user's
///   connection: `user`, class `user`;
/// - for an agent socket's session: `agent:SID`, class `agent`;
/// - for an outside agent (`ext:KIND:PID-HASH`, through the tools' `exec` only): that id, class `ext`;
/// - for anyone else (a service connection, the front's own timers): `hub`, class `system`;
/// - for the hub's hook records ([`HOOKS_METHOD`], whoever the caller): `hub:hooks`, class `system`. No wire method
///   has that name, so no connection writes as `hub:hooks`, and a step's provenance reads only its rows.
///
/// `tool` is `proto:<method>`.
pub fn tx_meta(caller: &Caller, method: &str) -> TxMeta {
    let tool = format!("proto:{method}");
    let mut meta = if method == HOOKS_METHOD {
        TxMeta::new(HOOKS_ACTOR, TxClass::System, tool)
    } else if method.starts_with("coord/") {
        TxMeta::new("hub", TxClass::System, tool)
    } else {
        match (caller.class, &caller.sid) {
            (Class::User, _) => TxMeta::new("user", TxClass::User, tool),
            // an outside agent (only ever through the tools' `exec`, after `crate::outside` found it bound): its own
            // id, class `ext`
            (Class::Agent, Some(sid)) if crate::outside::is_ext(sid) => {
                let mut m = TxMeta::new(sid.clone(), TxClass::Ext, tool);
                m.session = Some(sid.clone());
                m
            }
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
        crate::soft::done(self.front.set(Arc::downgrade(front)), "coord");
    }

    /// The front, once bound and while it lives.
    pub fn front(&self) -> Option<Arc<Front>> {
        self.front.get().and_then(std::sync::Weak::upgrade)
    }

    /// The hub's session SID (a tool's caller), or why not.
    fn session(&self, sid: &str) -> Result<Arc<crate::agents::session::Session>, String> {
        let front = self.front().ok_or("the hub is starting")?;
        front
            .core
            .agents
            .find(sid)
            .map_err(|_| "only a chat drgnx runs edits your checkout".to_string())
    }
}

impl Hub for ToolHub {
    /// The `before-tool` hooks of a call of the hub's own tool ([`crate::hook_points::at_hub_server`]). Before the
    /// front is bound no session socket serves, so nothing reaches this.
    fn before_tool<'a>(
        &'a self,
        sid: &'a str,
        server: &'static str,
        tool: &'a str,
        args: Value,
    ) -> BoxFuture<'a, Result<Value, String>> {
        let front = self.front();
        Box::pin(async move {
            match front {
                Some(f) => crate::hook_points::at_hub_server(&f, sid, server, tool, args)
                    .await
                    .map_err(|e| e.message().to_owned()),
                None => Err("drgnx refused the tool call: the hub is starting".into()),
            }
        })
    }

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
            // `agent_core::serve` checks no registry class: an outside actor reaches its listed methods only
            if crate::outside::is_ext(&sid) && !crate::outside::outside_methods().contains(&method)
            {
                return Err(format!("{method} is not open to an outside agent"));
            }
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

    /// The matrix for a bound outside agent (`crate::outside::who_for`: its binding read now, its caps applied).
    fn gate(
        &self,
        actor: &str,
        action: norn::matrix::Action,
        own_record: bool,
        change: norn::grants::Change,
    ) -> BoxFuture<'_, Result<(), String>> {
        let actor = actor.to_owned();
        Box::pin(async move {
            use crate::matrix_gate::{ActionCtx, Gate};
            let front = self.front().ok_or("the hub is starting")?;
            if !crate::outside::is_ext(&actor) {
                return Err("the gate here is an outside agent's".into());
            }
            let caller = Caller {
                class: Class::Agent,
                sid: Some(actor),
                job: None,
                conn_id: 0,
            };
            let (who, base) = crate::outside::who_for(&front, &caller)
                .await
                .map_err(|e| e.message)?;
            let ctx = ActionCtx {
                own_record,
                change: Some(change),
                ..base
            };
            match front
                .core
                .matrix
                .decide(&front.settings, &front.writer, who, action, ctx)
                .await
            {
                Gate::Allow => Ok(()),
                Gate::Ask(card) => Err(format!("the matrix asks the user first (card {card})")),
                Gate::Never(why) => Err(why),
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
            crate::manager::tool(&front, &sid, op, args)
                .await
                .map_err(|e| e.message().to_owned())
        })
    }

    /// A debugger tool (D4): the hub's side checks the matrix's `debug.*` rows and acts.
    fn debug(
        &self,
        sid: &str,
        op: &'static str,
        args: Value,
    ) -> BoxFuture<'_, Result<String, String>> {
        let (front, sid) = (self.front(), sid.to_owned());
        Box::pin(async move {
            let f = front.ok_or("the hub is starting")?;
            crate::debug::agent::tool(&f, &sid, op, args)
                .await
                .map_err(|e| e.message().to_owned())
        })
    }

    /// A session's tool call ended: its graph writes link to its current ask before it answers.
    fn after_tool(&self, _sid: &str, _tool: &str) -> BoxFuture<'_, ()> {
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

    /// A chat's `read_file`: its session's read through the pair door.
    fn pair_read(&self, sid: &str, path: String) -> BoxFuture<'_, Result<String, String>> {
        let found = self.session(sid);
        Box::pin(async move { found?.pair_read(path).await })
    }

    /// A chat's `edit_file` or `write_file`: its session's write through the pair door.
    fn huddle_reply(
        &self,
        sid: &str,
        huddle: String,
        text: String,
        proposal: Option<String>,
    ) -> BoxFuture<'_, Result<String, String>> {
        let (front, sid) = (self.front(), sid.to_owned());
        Box::pin(async move {
            let f = front.ok_or("the hub is starting")?;
            f.core
                .huddles
                .reply(&f, &sid, &huddle, text, proposal)
                .await
                .map_err(|e| e.message().to_owned())
        })
    }

    /// A session's answer in a paragraph comment's thread: only the session it was steered to.
    fn comment_reply(
        &self,
        sid: &str,
        comment: String,
        text: String,
    ) -> BoxFuture<'_, Result<String, String>> {
        let (front, sid) = (self.front(), sid.to_owned());
        Box::pin(async move {
            let f = front.ok_or("the hub is starting")?;
            crate::work::comments::reply_from(&f, &sid, &comment, &text)
                .await
                .map_err(|e| e.message().to_owned())
        })
    }

    fn escalated(&self, sid: &str) {
        if let Some(f) = self.front() {
            f.core.huddles.escalated(&f, sid);
        }
    }

    fn pair_write(
        &self,
        sid: &str,
        w: norn::tools::pair::PairWrite,
    ) -> BoxFuture<'_, Result<String, String>> {
        let found = self.session(sid);
        Box::pin(async move { found?.pair_write(w).await })
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

    fn extension_fact(
        &self,
        id: &str,
    ) -> BoxFuture<'_, Option<norn::tools::extensions::ExtensionFact>> {
        let front = self.front.get().and_then(std::sync::Weak::upgrade);
        let id = id.to_string();
        Box::pin(async move { front?.extensions.fact(&id).await })
    }

    /// A tool's card goes to the editors as every card does (`card`).
    fn card_event(&self, event: Value) {
        self.editors.broadcast("card", event);
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
        // the hub's own housekeeping writes are the hub's, and so is a service connection's write
        let seam = tx_meta(&caller(), "coord/agent-register");
        assert_eq!(
            (seam.actor.as_str(), seam.class, seam.tool.as_str()),
            ("hub", TxClass::System, "proto:coord/agent-register")
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
        // an outside agent writes as its own id, class `ext`
        let ext = tx_meta(
            &Caller {
                class: Class::Agent,
                sid: Some("ext:claude:42-abcdef".into()),
                job: None,
                conn_id: 0,
            },
            "plans/write",
        );
        assert_eq!(
            (ext.actor.as_str(), ext.class, ext.session.as_deref()),
            (
                "ext:claude:42-abcdef",
                TxClass::Ext,
                Some("ext:claude:42-abcdef")
            )
        );
    }

    #[test]
    fn not_ready_is_internal_with_its_text() {
        saman::block_on_current(async move {
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
                crate::soft::done(
                    std::fs::remove_file(dir.path().join(format!("work.db{ext}"))),
                    "std::fs::remove_file",
                );
            }
            crate::fsio::rename(&next, &file).unwrap();
            let sent = call(
                &w,
                "messages/send",
                json!({"recipient": "a1", "text": "hi"}),
            )
            .await
            .unwrap();
            assert_eq!(sent["ok"], json!(true), "{sent}");
            assert_eq!(w.signals.writes(), 1);
        })
    }

    #[test]
    fn read_only_is_schema() {
        saman::block_on_current(async move {
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
        })
    }

    #[test]
    fn writes_are_typed_and_counted() {
        saman::block_on_current(async move {
            let dir = tempfile::tempdir().unwrap();
            urdr::Connection::open(dir.path().join("work.db"))
                .unwrap()
                .execute_batch(DDL)
                .unwrap();
            let w = writer(dir.path());
            urdr::Connection::open(dir.path().join("work.db"))
                .unwrap()
                .execute_batch(
                    "insert into card (id, kind, title, state, at) values (7, 'ask', 't', 'open', 1.0)",
                )
                .unwrap();
            let settle = json!({"card": 7, "choice": "yes"});
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
            for (method, v) in [("messages/send", sent), ("events/add", added)] {
                assert_eq!(
                    (find(method).unwrap().check_result)(&v).unwrap(),
                    v,
                    "{method}"
                );
            }
            assert_eq!(w.signals.writes(), 4);
            // the refused send wrote nothing
            let n: i64 = urdr::Connection::open(dir.path().join("work.db"))
                .unwrap()
                .query_row("select count(*) from message", [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, 1);
        })
    }

    #[test]
    fn a_tool_write_reaches_the_view() {
        saman::block_on_current(async move {
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
        })
    }

    #[test]
    fn sender_is_refused_for_every_class() {
        saman::block_on_current(async move {
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
        })
    }

    #[test]
    fn tool_hub_sessions_are_the_fronts() {
        saman::block_on_current(async move {
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
            crate::fsio::write(
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
            crate::soft::done(
                crate::agent_core::serve(&front, &user, kill).await,
                "crate::agent_core::serve",
            );
        })
    }
}
