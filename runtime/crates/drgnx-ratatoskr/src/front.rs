//! The front: what every connection shares, and the methods it serves itself — `hello`, `ping`, `status`,
//! `subscribe`, `shutdown` and `events/since`.  Every other method goes to [`Forward`].
//!
//! [`Front::line`] is one line of one connection: [`dispatch::prelude`], the refusal noted, the handler, the answer
//! queued.

use crate::conn::Outbox;
use crate::dispatch::{self, Call, ErrorAnswerOrDrop, Forward, Refusals};
use crate::hello::{self, Session};
use crate::store::WorkDb;
use crate::version::COMMIT;
use drgnx_proto::line::MAX_HUB_LINE;
use drgnx_proto::methods::Params;
use drgnx_proto::methods::hub::{HubStatus, Runtime};
use drgnx_proto::proof::Cap;
use drgnx_proto::registry;
use drgnx_proto::wire::{Answer, Error, ErrorAnswer, ErrorCode, Event, Id};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

/// What `status` and the doctor say of job agents in this phase.
pub const JOB_AGENTS: &str = "unsandboxed (as on main; the sandbox comes with phase 6)";

/// How long `shutdown` waits for its answer to be written before the hub stops.
const SHUTDOWN_FLUSH: Duration = Duration::from_secs(1);

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

    /// Wait until `shutdown` asks the hub to stop.
    pub async fn stopped(&self) {
        self.stop.notified().await;
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

    /// Count and log a refusal on S.
    fn refused(&self, s: &Session, method: Option<&str>, error: &Error) {
        self.refusals.lock().expect("refusals").note(
            crate::log::rfc3339(now()),
            s.conn,
            s.class,
            method,
            error,
        );
    }

    /// One line of the connection S, whose answers go to OUT: the dispatcher's checks, then the handler (a failure
    /// is `internal`; a refusal of its own, such as a wrong proof, is counted like the dispatcher's).  A
    /// notification is dispatched and never answered.
    pub async fn line(&self, s: &mut Session, out: &Arc<Outbox>, text: &str) {
        let call = match dispatch::prelude(s.class, s.proto, self.read_only(), text) {
            Ok(c) => c,
            Err(ErrorAnswerOrDrop::Drop(why)) => {
                tracing::info!(conn = s.conn, "dropped {why}");
                return;
            }
            Err(ErrorAnswerOrDrop::Refused(r)) => {
                self.refused(s, r.method.as_deref(), &r.error);
                if let Some(id) = r.id {
                    out.push(answer_line(s.conn, id, Err(r.error), vec![]));
                }
                return;
            }
        };
        let Call {
            id,
            method,
            params,
            ignored,
        } = call;
        let mut stop = false;
        let result = match params {
            Params::Hello(p) => {
                let schema = self.schema.load(Ordering::Relaxed);
                hello::hello(s, &self.cap, &p, schema).map(|r| json!(r))
            }
            Params::Ping(_) => Ok(json!({"pid": self.pid})),
            Params::Status(_) => Ok(json!(self.status())),
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
            Params::EventsSince(p) => self
                .work_db
                .events_since(p.since, p.limit)
                .await
                .map(|page| json!(page))
                .map_err(internal),
            other => {
                self.forward
                    .call(s.caller(), method, other.to_value())
                    .await
            }
        };
        if let Err(e) = &result
            && e.code != ErrorCode::Internal
        {
            self.refused(s, Some(method.name), e);
        }
        if let Some(id) = id {
            out.push(answer_line(s.conn, id, result, ignored));
        }
        if stop {
            // the answer first, then the Task 13 stop
            out.flushed(SHUTDOWN_FLUSH).await;
            self.stop.notify_one();
        }
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
