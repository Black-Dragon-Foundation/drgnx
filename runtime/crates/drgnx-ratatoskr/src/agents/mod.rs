//! Sessions in the hub (agent system part 1; V2 runtime phase 5; `docs/develop/hub.md`, "Sessions"): the hub is
//! every session's ACP client (`hermod`), answers its permissions through the matrix, delivers its messages, and
//! launches it inside Gleipnir with its provider's lock.
//!
//! - [`session`]: lifecycle, permissions, the mirror's shapes (Task 8a); prompts, queue and steer, transcripts,
//!   steps (Task 8b); moving to another model (Task 26).
//! - [`deliver`]: delivery and take-back (`messages/retract`) (Task 24).
//! - [`lock`]: a provider's launch options that make its CLI obey the hub (Task 9).
//! - [`launch`]: the session's Gleipnir spec (Task 10).

pub mod deliver;
pub mod launch;
pub mod lock;
pub mod session;

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::agents::{DoParams, Sessions, StartParams, Started, Transcript};
use runstav::registry::Class;
use runstav::wire::Error;
use session::Session;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// The sessions the hub holds (Tasks 8a, 8b fill it).
#[derive(Default)]
pub struct Hub {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    db: OnceLock<urdr::Handle>,
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

    /// A session on PROFILE, started by CALLER (the user's connection), in the directory and role of P.
    pub async fn start(
        &self,
        front: &Front,
        p: StartParams,
        caller: &Caller,
    ) -> Result<Started, Error> {
        session::open(self, front, p, caller).await
    }

    /// End the session's turn and its process (SIGTERM, then SIGKILL after a grace period).
    pub async fn stop(&self, id: &str) -> Result<bool, Error> {
        self.find(id)?.end(false).await;
        self.forget(id).await;
        Ok(true)
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

    pub fn list(&self, caller: &Caller) -> Sessions {
        let mut all: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        all.sort_by(|a, b| a.started.total_cmp(&b.started).then(a.id.cmp(&b.id)));
        let sessions = all.iter().map(|s| s.snapshot()).collect();
        let v = serde_json::json!(Sessions { sessions });
        let shaped = crate::shape::result(caller, "agents/list", v);
        serde_json::from_value(shaped).unwrap_or(Sessions {
            sessions: Vec::new(),
        })
    }
}
