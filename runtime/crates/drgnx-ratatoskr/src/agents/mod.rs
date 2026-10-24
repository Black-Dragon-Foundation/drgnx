//! Sessions in the hub (agent system part 1; V2 runtime phase 5; `docs/develop/hub.md`, "Sessions"): the hub is
//! every session's ACP client (`hermod`), answers its permissions through the matrix, delivers its messages, and
//! launches it inside Gleipnir with its provider's lock.
//!
//! - [`session`]: lifecycle, permissions, the mirror's shapes (Task 8a); prompts, queue and steer, transcripts,
//!   steps (Task 8b); moving to another model (Task 26).
//! - [`queue`]: the prompt queue, steering and the origin of a prompt (Task 8b).
//! - [`transcript`]: redacted transcripts and the held queue on disk (Task 8b).
//! - [`deliver`]: delivery and take-back (`messages/retract`) (Task 24).
//! - [`lock`]: a provider's launch options that make its CLI obey the hub (Task 9).
//! - [`launch`]: the session's Gleipnir spec (Task 10).
//! - [`wake`]: a job's end prompts the session that started it; a queue wait is a step (Task 15).

pub mod deliver;
pub mod handoff;
pub mod launch;
pub mod lock;
pub mod queue;
pub mod session;
pub mod transcript;
pub mod wake;

use crate::dispatch::Caller;
use crate::front::Front;
pub use queue::Origin;
use runstav::methods::agents::{
    DoParams, SessionStatus, Sessions, StartParams, Started, Transcript,
};
use runstav::methods::timeline::AgentStep;
use runstav::registry::Class;
use runstav::wire::Error;
use session::Session;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// A step as the hub announces it: a closed row of the `step` table (`agent-step` to the editors too).
pub type StepEvent = AgentStep;

/// The step channel (a slow receiver lags; it never holds a session up).
struct StepBus(tokio::sync::broadcast::Sender<StepEvent>);

impl Default for StepBus {
    fn default() -> StepBus {
        StepBus(tokio::sync::broadcast::channel(1024).0)
    }
}

/// The sessions the hub holds (Tasks 8a, 8b fill it).
#[derive(Default)]
pub struct Hub {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    db: OnceLock<urdr::Handle>,
    steps: StepBus,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Hub {
    /// `runtime.db`, where the sessions are recorded (the server gives it once, after it opened).
    pub fn open_store(&self, db: urdr::Handle) {
        let _ = self.db.set(db);
    }

    pub(crate) fn db(&self) -> Option<&urdr::Handle> {
        self.db.get()
    }

    pub(crate) fn insert(&self, s: Arc<Session>) {
        lock(&self.sessions).insert(s.id.clone(), s);
    }

    pub(crate) fn find(&self, id: &str) -> Result<Arc<Session>, Error> {
        lock(&self.sessions)
            .get(id)
            .cloned()
            .ok_or_else(|| session::no_session(id))
    }

    /// Session ID's gateway registration token, taken (so it is unregistered once).
    pub(crate) fn take_gateway(&self, id: &str) -> Option<String> {
        self.find(id).ok()?.take_gateway()
    }

    /// Who the session SID is, for the matrix's columns (none for a session the hub does not hold).
    pub fn who(&self, sid: &str) -> Option<norn::matrix::Who> {
        lock(&self.sessions).get(sid).map(|s| s.who())
    }

    /// The worktree session SID works in (none for a session the hub does not hold).
    pub fn worktree(&self, sid: &str) -> Option<PathBuf> {
        lock(&self.sessions).get(sid).map(|s| s.worktree())
    }

    /// A session on PROFILE, started by CALLER (the user's connection), in the directory and role of P.
    pub async fn start(
        &self,
        front: &Front,
        p: StartParams,
        caller: &Caller,
    ) -> Result<Started, Error> {
        session::open(self, front, p, caller).await
    }

    /// A worker a manager started (Task 25): as [`Hub::start`], with PARENT (the manager's session id) as its parent,
    /// so its budget comes out of the manager's.  The hub acts on a request the manager's tool already checked.
    pub async fn start_child(
        &self,
        front: &Front,
        p: StartParams,
        parent: &str,
    ) -> Result<Started, Error> {
        let hub_as_user = crate::runner::user();
        session::open_as(self, front, p, &hub_as_user, Some(parent.to_owned())).await
    }

    /// Stop: cancel the running turn (the queue waits until the user delivers it or sends something).  A session
    /// with no turn running is ended instead: its process (SIGTERM, then SIGKILL after a grace period).
    pub async fn stop(&self, id: &str) -> Result<bool, Error> {
        let s = self.find(id)?;
        if s.stop_turn() {
            return Ok(true);
        }
        s.end(false).await;
        self.forget(id).await;
        Ok(true)
    }

    /// The user's message to a session.
    pub fn send(&self, id: &str, text: String) -> Result<(), Error> {
        self.prompt(id, text, Origin::User)
    }

    /// TEXT from ORIGIN to session ID: a turn when it is idle, else queued (or steered, where the profile's mode
    /// says).  It never cancels a turn.
    pub fn prompt(&self, id: &str, text: String, origin: Origin) -> Result<(), Error> {
        self.find(id)?.prompt(text, origin)
    }

    /// Every session the hub holds that has not exited.
    pub(crate) fn live_sessions(&self) -> Vec<Arc<Session>> {
        lock(&self.sessions)
            .values()
            .filter(|s| s.status() != SessionStatus::Exited)
            .cloned()
            .collect()
    }

    /// A job's result for session ID: resumes the session first when it was closed while it waited, then prompts it
    /// (a plain `session/prompt` from the hub; a turn when it waits or idles, else queued).
    pub async fn wake(&self, front: &Front, id: &str, text: String) -> Result<(), Error> {
        session::resume_closed(self, front, id)
            .await?
            .prompt(text, Origin::Hub)
    }

    /// Pause: cancel the turn once the tool call running now completes, and hold the queue.
    pub fn cancel_after_tool(&self, id: &str) -> Result<(), Error> {
        self.find(id)?.pause_after_tool()
    }

    /// What the supervisor reads of every session the hub holds.
    pub fn observations(&self) -> Vec<crate::supervisor::Obs> {
        let all: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        all.iter().map(|s| s.observe()).collect()
    }

    /// The supervisor found the session silent: its wait is a `stalled` step.
    pub fn mark_stalled(&self, id: &str) {
        if let Ok(s) = self.find(id) {
            s.mark_stalled();
        }
    }

    /// Every step as it closes (the `step` row, written first).
    pub fn subscribe_steps(&self) -> tokio::sync::broadcast::Receiver<StepEvent> {
        self.steps.0.subscribe()
    }

    pub(crate) fn step_bus(&self) -> tokio::sync::broadcast::Sender<StepEvent> {
        self.steps.0.clone()
    }

    /// The turns running now (restart-when-idle waits for these only; an idle chat does not hold an update).
    pub fn busy_count(&self) -> u64 {
        lock(&self.sessions)
            .values()
            .filter(|s| matches!(s.status(), SessionStatus::Busy | SessionStatus::Starting))
            .count() as u64
    }

    /// The hub ends: every session's process group goes, its rows, transcript and queue stay for the next start.
    pub async fn shutdown(&self) {
        let all: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        let ends: Vec<_> = all
            .into_iter()
            .map(|s| tokio::spawn(async move { s.shutdown().await }))
            .collect();
        for e in ends {
            let _ = e.await;
        }
    }

    /// After a restart: the recorded sessions resumed, their queued prompts delivered.
    pub async fn resume_all(&self, front: &Front) {
        session::resume_all(self, front).await;
    }

    /// The same, at once (SIGKILL).
    pub async fn kill(&self, id: &str) -> Result<bool, Error> {
        self.find(id)?.end(true).await;
        self.forget(id).await;
        Ok(true)
    }

    async fn forget(&self, id: &str) {
        if let Some(db) = self.db() {
            session::delete_row(db, id).await;
        }
    }

    /// The user's answer to a permission request (`option` none rejects).
    pub async fn permission(
        &self,
        caller: &Caller,
        id: &str,
        request: &runstav::types::RequestId,
        option: Option<&str>,
    ) -> Result<bool, Error> {
        if caller.class != Class::User {
            return Err(session::refuse(
                "only the user answers a permission request",
            ));
        }
        self.find(id)?.answer_permission(request, option)
    }

    pub async fn do_op(&self, caller: &Caller, p: DoParams) -> Result<bool, Error> {
        if caller.class != Class::User {
            return Err(session::refuse("only the user does this"));
        }
        self.find(p.id.as_str())?.do_op(p)
    }

    pub fn get(&self, id: &str) -> Result<Transcript, Error> {
        Ok(self.find(id)?.transcript())
    }

    /// Every session the hub holds, as snapshots, oldest first (the plan runner's view: no shaping, no copy of the
    /// entries).
    pub fn snapshots(&self) -> Vec<runstav::methods::agents::Snapshot> {
        let mut all: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        all.sort_by(|a, b| a.started.total_cmp(&b.started).then(a.id.cmp(&b.id)));
        all.iter().map(|s| s.snapshot()).collect()
    }

    /// The sessions as CALLER may see them ([`crate::shape::result`]): the shaped JSON itself, since a summary read
    /// back into a `Snapshot` would gain its empty lists again.
    pub fn list(&self, caller: &Caller) -> serde_json::Value {
        let mut all: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        all.sort_by(|a, b| a.started.total_cmp(&b.started).then(a.id.cmp(&b.id)));
        let sessions = all.iter().map(|s| s.snapshot()).collect();
        crate::shape::result(
            caller,
            "agents/list",
            serde_json::json!(Sessions { sessions }),
        )
    }
}

/// Test hook (`test-hooks` builds only): the hub dies here, at once, when `DRGNX_TEST_DIE_AT` names POINT, so a row
/// can stop it between two writes instead of timing it.
#[allow(unused_variables)]
pub(crate) fn die_at(point: &str) {
    #[cfg(feature = "test-hooks")]
    if std::env::var("DRGNX_TEST_DIE_AT").as_deref() == Ok(point) {
        std::process::exit(9);
    }
}
