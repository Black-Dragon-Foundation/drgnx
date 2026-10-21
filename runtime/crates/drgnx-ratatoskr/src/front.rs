//! The front: what every connection shares, and the methods it serves itself — `hello`, `ping`, `status`,
//! `subscribe`, `shutdown` and `events/since`.  Every other method goes to [`Forward`].
//!
//! [`Front::line`] is one line of one connection: [`dispatch::prelude`], the refusal noted, the handler, the answer
//! queued.  [`Front::start_line`] is the same for the connection loop, except that a forwarded call runs on a task
//! of its own (at most [`MAX_IN_FLIGHT`] per connection; past that the connection is not read until one ends).

use crate::Exit;
use crate::conn::Outbox;
use crate::dispatch::{self, Call, Caller, ErrorAnswerOrDrop, Forward, Refusals};
use crate::hello::{self, Session};
use crate::store::WorkDb;
use crate::version::COMMIT;
use drgnx_proto::line::MAX_HUB_LINE;
use drgnx_proto::methods::Params;
use drgnx_proto::methods::hub::{HubStatus, Runtime};
use drgnx_proto::proof::Cap;
use drgnx_proto::registry;
use drgnx_proto::registry::{Class, Method};
use drgnx_proto::wire::{Answer, Error, ErrorAnswer, ErrorCode, Event, Id};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::sync::Semaphore;

/// What `status` and the doctor say of job agents in this phase.
pub const JOB_AGENTS: &str = "unsandboxed (as on main; the sandbox comes with phase 6)";

/// How long `shutdown` waits for its answer to be written before the hub stops.
const SHUTDOWN_FLUSH: Duration = Duration::from_secs(1);

/// Forwarded calls one connection may have in flight.
pub const MAX_IN_FLIGHT: usize = 64;

/// A call that passed the dispatcher and goes on to [`Forward`].
pub struct Forwarded {
    id: Option<Id>,
    method: &'static Method,
    params: Params,
    ignored: Vec<String>,
    caller: Caller,
}

/// What every connection shares.
pub struct Front {
    pub cap: Cap,
    pub pid: u32,
    pub uid: u32,
    /// The main socket.
    pub socket: PathBuf,
    /// When the hub started (RFC 3339, UTC).
    pub started: String,
    pub work_db: WorkDb,
    forward: Arc<dyn Forward>,
    refusals: Mutex<Refusals>,
    /// work.db's `meta.schema` at the last look (0: none).
    schema: AtomicU32,
    /// work.db's schema while it is newer than this hub's, else 0.
    read_only: AtomicU32,
    subscribers: Mutex<BTreeMap<u64, Arc<Outbox>>>,
    stop: Notify,
    /// The stop asked for is a restart.
    restart: AtomicBool,
    next_conn: AtomicU64,
}

impl Front {
    pub fn new(cap: Cap, socket: PathBuf, work_db: WorkDb, forward: Arc<dyn Forward>) -> Front {
        Front {
            cap,
            pid: std::process::id(),
            uid: rustix::process::geteuid().as_raw(),
            socket,
            started: crate::log::rfc3339(now()),
            work_db,
            forward,
            refusals: Mutex::new(Refusals::default()),
            schema: AtomicU32::new(0),
            read_only: AtomicU32::new(0),
            subscribers: Mutex::new(BTreeMap::new()),
            stop: Notify::new(),
            restart: AtomicBool::new(false),
            next_conn: AtomicU64::new(1),
        }
    }

    pub fn next_conn(&self) -> u64 {
        self.next_conn.fetch_add(1, Ordering::Relaxed)
    }

    /// work.db's schema is SCHEMA now (0: no file): read-only while it is newer than this hub's.  Logged when that
    /// changes.
    pub fn set_schema(&self, schema: u32) {
        self.schema.store(schema, Ordering::Relaxed);
        let ro = if schema > registry::SCHEMA { schema } else { 0 };
        let was = self.read_only.swap(ro, Ordering::Relaxed);
        if was != ro {
            if ro > 0 {
                tracing::warn!(
                    schema,
                    "work.db is schema {schema}, newer than this hub's {}: read-only (methods that write are refused)",
                    registry::SCHEMA
                );
            } else {
                tracing::info!(
                    schema,
                    "work.db is of this hub's schema again: writes allowed"
                );
            }
        }
    }

    pub fn read_only(&self) -> Option<u32> {
        match self.read_only.load(Ordering::Relaxed) {
            0 => None,
            n => Some(n),
        }
    }

    /// Wait until `shutdown` or `restart` (or restart-when-idle) asks the hub to stop: how it should end.
    pub async fn stopped(&self) -> Exit {
        self.stop.notified().await;
        if self.restart.load(Ordering::SeqCst) {
            Exit::Restart
        } else {
            Exit::Stopped
        }
    }

    /// Ask the hub to end with exit 75 (`restart`, restart-when-idle).  In phase 1 the backend has no turns to
    /// cancel: the stop that follows shuts it down first.
    pub fn ask_restart(&self) {
        self.restart.store(true, Ordering::SeqCst);
        self.stop.notify_one();
    }

    /// The connection CONN is gone: no more events for it.
    pub fn gone(&self, conn: u64) {
        self.subscribers.lock().expect("subscribers").remove(&conn);
    }

    /// EVENT with DATA to every subscribed connection: queued for each before any is written (a queue never waits),
    /// so a newer event never reaches one subscriber before an older one.
    pub fn broadcast(&self, event: &str, data: Value) {
        let text = serde_json::to_string(&Event {
            event: event.into(),
            data,
        })
        .expect("an event serializes");
        if text.len() > MAX_HUB_LINE {
            tracing::warn!(
                event,
                bytes = text.len(),
                "an event over 16 MiB was not sent"
            );
            return;
        }
        let line: Arc<str> = format!("{text}\n").into();
        self.subscribers
            .lock()
            .expect("subscribers")
            .retain(|_, out| out.push(line.clone()));
    }

    pub fn status(&self) -> HubStatus {
        HubStatus {
            pid: u64::from(self.pid),
            socket: Some(self.socket.to_string_lossy().into_owned()),
            started: Some(self.started.clone()),
            proto: Some(u64::from(registry::PROTO)),
            proto_min: Some(u64::from(registry::PROTO_MIN)),
            records: Some(u64::from(registry::RECORDS)),
            drgnx_version: Some(COMMIT.into()),
            schema: Some(u64::from(self.schema.load(Ordering::Relaxed))),
            read_only: self.read_only().map(u64::from),
            runtime: Some(Runtime {
                version: env!("CARGO_PKG_VERSION").into(),
                commit: COMMIT.into(),
            }),
            refusals: Some(self.refusals.lock().expect("refusals").status()),
            job_agents: Some(JOB_AGENTS.into()),
            backend: None,
            gateway_port: None,
            registrations: None,
        }
    }

    /// `status`: the front's keys, and the backend's state with what its own `status` says of the gateway.
    pub async fn status_with_backend(&self) -> HubStatus {
        let mut st = self.status();
        let b = self.forward.status().await;
        st.backend = b.backend;
        st.gateway_port = b.gateway_port;
        st.registrations = b.registrations;
        st
    }

    /// Count and log a refusal on connection CONN of CLASS.
    fn refused(&self, conn: u64, class: Class, method: Option<&str>, error: &Error) {
        self.refusals.lock().expect("refusals").note(
            crate::log::rfc3339(now()),
            conn,
            class,
            method,
            error,
        );
    }

    /// One line of the connection S, whose answers go to OUT: the dispatcher's checks, then the handler (a failure
    /// is `internal`; a refusal of its own, such as a wrong proof, is counted like the dispatcher's).  A
    /// notification is dispatched and never answered.  A forwarded call is waited for here.
    pub async fn line(&self, s: &mut Session, out: &Arc<Outbox>, text: &str) {
        if let Some(f) = self.begin(s, out, text).await {
            self.finish(out, f).await;
        }
    }

    /// [`Front::line`] for the connection loop: a forwarded call runs on a task of its own, holding one of SLOTS
    /// (this connection's [`MAX_IN_FLIGHT`]); with none free, this waits, so the connection is not read meanwhile.
    pub async fn start_line(
        self: &Arc<Self>,
        s: &mut Session,
        out: &Arc<Outbox>,
        text: &str,
        slots: &Arc<Semaphore>,
    ) {
        let Some(f) = self.begin(s, out, text).await else {
            return;
        };
        let Ok(slot) = slots.clone().acquire_owned().await else {
            return;
        };
        let (front, out) = (self.clone(), out.clone());
        tokio::spawn(async move {
            front.finish(&out, f).await;
            drop(slot);
        });
    }

    /// The forwarded call F, answered on OUT.
    async fn finish(&self, out: &Arc<Outbox>, f: Forwarded) {
        let Forwarded {
            id,
            method,
            params,
            ignored,
            caller,
        } = f;
        let (conn, class) = (caller.conn_id, caller.class);
        let result = self.forward.call(caller, method, params).await;
        if let Err(e) = &result
            && e.code != ErrorCode::Internal
        {
            self.refused(conn, class, Some(method.name), e);
        }
        if let Some(id) = id {
            out.push(answer_line(conn, id, result, ignored));
        }
    }

    /// Everything of a line but a forwarded call, which it gives back.
    async fn begin(&self, s: &mut Session, out: &Arc<Outbox>, text: &str) -> Option<Forwarded> {
        let call = match dispatch::prelude(s.class, s.proto, self.read_only(), text) {
            Ok(c) => c,
            Err(ErrorAnswerOrDrop::Drop(why)) => {
                tracing::info!(conn = s.conn, "dropped {why}");
                return None;
            }
            Err(ErrorAnswerOrDrop::Refused(r)) => {
                self.refused(s.conn, s.class, r.method.as_deref(), &r.error);
                if let Some(id) = r.id {
                    out.push(answer_line(s.conn, id, Err(r.error), vec![]));
                }
                return None;
            }
        };
        let Call {
            id,
            method,
            params,
            ignored,
        } = call;
        let mut stop = false;
        let mut restart = false;
        let result = match params {
            Params::Hello(p) => {
                let schema = self.schema.load(Ordering::Relaxed);
                hello::hello(s, &self.cap, &p, schema).map(|r| json!(r))
            }
            Params::Ping(_) => Ok(json!({"pid": self.pid})),
            Params::Status(_) => Ok(json!(self.status_with_backend().await)),
            Params::Subscribe(_) => {
                self.subscribers
                    .lock()
                    .expect("subscribers")
                    .insert(s.conn, out.clone());
                Ok(json!(true))
            }
            Params::Shutdown(_) => {
                stop = true;
                Ok(json!(true))
            }
            Params::Restart(_) => {
                restart = true;
                Ok(json!(true))
            }
            Params::EventsSince(p) => self
                .work_db
                .events_since(p.since, p.limit)
                .await
                .map(|page| json!(page))
                .map_err(internal),
            other => {
                return Some(Forwarded {
                    id,
                    method,
                    params: other,
                    ignored,
                    caller: s.caller(),
                });
            }
        };
        if let Err(e) = &result
            && e.code != ErrorCode::Internal
        {
            self.refused(s.conn, s.class, Some(method.name), e);
        }
        if let Some(id) = id {
            out.push(answer_line(s.conn, id, result, ignored));
        }
        if stop || restart {
            // the answer first, then the stop
            out.flushed(SHUTDOWN_FLUSH).await;
            if restart {
                self.ask_restart();
            } else {
                self.stop.notify_one();
            }
        }
        None
    }
}

/// Seconds since the epoch.
fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn internal(message: String) -> Error {
    Error {
        code: ErrorCode::Internal,
        message,
        path: None,
    }
}

/// The answer line for ID: the result with the dropped keys, or the error; an answer over 16 MiB becomes
/// `internal` "answer over 16 MiB".
fn answer_line(conn: u64, id: Id, result: Result<Value, Error>, ignored: Vec<String>) -> Arc<str> {
    let text = match result {
        Ok(result) => serde_json::to_string(&Answer {
            id: id.clone(),
            result,
            ignored,
        }),
        Err(error) => serde_json::to_string(&ErrorAnswer {
            id: id.clone(),
            error,
        }),
    }
    .expect("an answer serializes");
    let text = if text.len() > MAX_HUB_LINE {
        tracing::warn!(
            conn,
            bytes = text.len(),
            "an answer over 16 MiB was replaced"
        );
        serde_json::to_string(&ErrorAnswer {
            id,
            error: internal("answer over 16 MiB".into()),
        })
        .expect("an error serializes")
    } else {
        text
    };
    format!("{text}\n").into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::NoBackend;
    use crate::hello::Socket;
    use drgnx_proto::registry::Class;

    fn front(dir: &std::path::Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            Arc::new(NoBackend),
        )
    }

    fn answers(out: &Outbox) -> Vec<Value> {
        out.take_lines()
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    #[test]
    fn status_has_the_fronts_keys_and_fits_the_registry() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let v = serde_json::to_value(f.status()).unwrap();
        assert_eq!(v["pid"], std::process::id());
        assert_eq!(
            v["socket"],
            dir.path().join("hub-x.sock").to_string_lossy().as_ref()
        );
        assert_eq!(
            (
                v["proto"].clone(),
                v["proto_min"].clone(),
                v["records"].clone()
            ),
            (json!(1), json!(1), json!(2))
        );
        assert_eq!(v["schema"], 0);
        assert_eq!(v["drgnx_version"], COMMIT);
        assert_eq!(v["runtime"]["commit"], COMMIT);
        assert_eq!(v["refusals"], json!({"count": 0, "last": []}));
        assert_eq!(v["job_agents"], JOB_AGENTS);
        assert!(v.get("read_only").is_none(), "{v}");
        let started = v["started"].as_str().unwrap();
        assert!(started.len() == 20 && started.ends_with('Z'), "{started}");
        let m = registry::find("status").unwrap();
        assert_eq!((m.check_result)(&v).unwrap(), v);
    }

    #[test]
    fn a_newer_schema_is_read_only_until_it_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        f.set_schema(6);
        assert_eq!(f.read_only(), None);
        f.set_schema(9);
        assert_eq!(f.read_only(), Some(9));
        let v = serde_json::to_value(f.status()).unwrap();
        assert_eq!(
            (v["read_only"].clone(), v["schema"].clone()),
            (json!(9), json!(9))
        );
        f.set_schema(6);
        assert_eq!(f.read_only(), None);
        f.set_schema(0);
        assert_eq!(f.read_only(), None);
    }

    #[tokio::test]
    async fn subscribe_adds_the_connection_to_the_broadcast() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        let (a, b) = (Arc::new(Outbox::new(s.conn)), Arc::new(Outbox::new(99)));
        f.broadcast("events", json!({"n": 0}));
        f.line(&mut s, &a, r#"{"id":1,"method":"subscribe"}"#).await;
        assert_eq!(answers(&a), vec![json!({"id": 1, "result": true})]);
        f.broadcast("events", json!({"n": 1}));
        assert_eq!(
            answers(&a),
            vec![json!({"event": "events", "data": {"n": 1}})]
        );
        assert!(answers(&b).is_empty(), "b never subscribed");
        f.gone(s.conn);
        f.broadcast("events", json!({"n": 2}));
        assert!(answers(&a).is_empty(), "a is gone");
    }

    #[tokio::test]
    async fn the_front_serves_ping_events_and_shutdown_and_forwards_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        let out = Arc::new(Outbox::new(s.conn));
        f.line(&mut s, &out, r#"{"id":1,"method":"ping"}"#).await;
        f.line(
            &mut s,
            &out,
            r#"{"id":2,"method":"events/since","params":{"since":3}}"#,
        )
        .await;
        f.line(&mut s, &out, r#"{"id":3,"method":"job/status"}"#)
            .await;
        f.line(&mut s, &out, r#"{"method":"ping"}"#).await;
        assert_eq!(
            answers(&out),
            vec![
                json!({"id": 1, "result": {"pid": std::process::id()}}),
                json!({"id": 2, "result": {"since": 3, "last": 3, "events": []}}),
                json!({"id": 3, "error": {"code": "internal", "message": "backend not running"}}),
            ]
        );
        // shutdown: answered, then the hub is asked to stop
        let stop = f.stopped();
        tokio::pin!(stop);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), &mut stop)
                .await
                .is_err(),
            "nothing asked to stop yet"
        );
        f.line(&mut s, &out, r#"{"id":4,"method":"shutdown"}"#)
            .await;
        assert_eq!(answers(&out), vec![json!({"id": 4, "result": true})]);
        tokio::time::timeout(Duration::from_secs(5), stop)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn restart_answers_true_then_ends_the_hub_with_75() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        let out = Arc::new(Outbox::new(s.conn));
        f.line(&mut s, &out, r#"{"id":1,"method":"restart"}"#).await;
        assert_eq!(answers(&out), vec![json!({"id": 1, "result": true})]);
        let how = tokio::time::timeout(Duration::from_secs(5), f.stopped())
            .await
            .unwrap();
        assert_eq!(how, Exit::Restart);
        // a plain shutdown is still a plain stop
        let g = front(dir.path());
        g.line(&mut s, &out, r#"{"id":2,"method":"shutdown"}"#)
            .await;
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), g.stopped())
                .await
                .unwrap(),
            Exit::Stopped
        );
    }

    /// A backend whose calls each wait for a permit of its gate, and whose status says it runs.
    struct Gated(Arc<Semaphore>);

    impl Forward for Gated {
        fn call<'a>(&'a self, _: Caller, _: &'static Method, _: Params) -> dispatch::Answer<'a> {
            Box::pin(async {
                self.0.acquire().await.unwrap().forget();
                Ok(json!(true))
            })
        }

        fn status<'a>(
            &'a self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = dispatch::BackendInfo> + Send + 'a>>
        {
            Box::pin(async {
                dispatch::BackendInfo {
                    backend: Some(drgnx_proto::methods::hub::Backend {
                        state: drgnx_proto::methods::hub::BackendState::Running,
                        pid: Some(42),
                    }),
                    gateway_port: Some(7),
                    registrations: Some(2),
                }
            })
        }
    }

    fn gated(dir: &std::path::Path, gate: Arc<Semaphore>) -> Arc<Front> {
        Arc::new(Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            Arc::new(Gated(gate)),
        ))
    }

    #[tokio::test]
    async fn a_connection_has_at_most_64_forwarded_calls_in_flight() {
        let dir = tempfile::tempdir().unwrap();
        let gate = Arc::new(Semaphore::new(0));
        let f = gated(dir.path(), gate.clone());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        let out = Arc::new(Outbox::new(s.conn));
        let slots = Arc::new(Semaphore::new(MAX_IN_FLIGHT));
        let call = |i: usize| format!(r#"{{"id":{i},"method":"job/status"}}"#);
        for i in 0..MAX_IN_FLIGHT {
            tokio::time::timeout(
                Duration::from_secs(5),
                f.start_line(&mut s, &out, &call(i), &slots),
            )
            .await
            .expect("a call within the limit is taken at once");
        }
        // the front-served methods still answer at once
        f.start_line(&mut s, &out, r#"{"id":"p","method":"ping"}"#, &slots)
            .await;
        assert_eq!(answers(&out).len(), 1, "only ping is answered");
        // the 65th waits for a slot: the connection is not read meanwhile
        let next = call(MAX_IN_FLIGHT);
        let fut = f.start_line(&mut s, &out, &next, &slots);
        tokio::pin!(fut);
        assert!(
            tokio::time::timeout(Duration::from_millis(200), &mut fut)
                .await
                .is_err(),
            "a 65th call in flight"
        );
        gate.add_permits(1);
        tokio::time::timeout(Duration::from_secs(5), &mut fut)
            .await
            .expect("taken once one call ended");
        gate.add_permits(1000);
        let mut got = 0;
        for _ in 0..500 {
            got += answers(&out).len();
            if got == MAX_IN_FLIGHT + 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(got, MAX_IN_FLIGHT + 1, "every call answered");
    }

    #[tokio::test]
    async fn status_has_the_backends_state_and_the_gateways_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let f = gated(dir.path(), Arc::new(Semaphore::new(0)));
        let v = serde_json::to_value(f.status_with_backend().await).unwrap();
        assert_eq!(v["backend"], json!({"state": "running", "pid": 42}));
        assert_eq!(
            (v["gateway_port"].clone(), v["registrations"].clone()),
            (json!(7), json!(2))
        );
        let m = registry::find("status").unwrap();
        assert_eq!((m.check_result)(&v).unwrap(), v);
        // without a backend there is nothing to say of it
        let f = front(dir.path());
        let v = serde_json::to_value(f.status_with_backend().await).unwrap();
        assert!(
            v.get("backend").is_none() && v.get("gateway_port").is_none(),
            "{v}"
        );
    }

    #[tokio::test]
    async fn a_hello_is_answered_and_sets_the_session() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.hub_nonce = drgnx_proto::proof::nonce().unwrap();
        let nonce = drgnx_proto::proof::nonce().unwrap();
        let p = drgnx_proto::proof::client_proof(&f.cap, &s.hub_nonce, &nonce);
        let out = Arc::new(Outbox::new(s.conn));
        let line =
            json!({"id": 1, "method": "hello", "params": {"proto": 1, "nonce": nonce, "proof": p}});
        f.line(&mut s, &out, &line.to_string()).await;
        let a = answers(&out);
        assert_eq!(a[0]["result"]["class"], "user", "{a:?}");
        assert_eq!(s.class, Class::User);
        // a wrong proof is a refusal: counted
        let mut t = Session::new(f.next_conn(), Socket::Main);
        t.hub_nonce = drgnx_proto::proof::nonce().unwrap();
        f.line(&mut t, &out, &line.to_string()).await;
        assert_eq!(answers(&out)[0]["error"]["code"], "not-allowed");
        assert_eq!(f.status().refusals.map(|r| r.count), Some(1));
    }
}
