//! The front: what every connection shares, and the methods it serves itself (`Home::Front`) — `hello`, `ping`,
//! `status`, `subscribe`, `shutdown`, `restart`, `events/since`, `coord/notify`, the writes of [`crate::coord`], the
//! MCP hosting of [`crate::sessions`] (`mcp/*`) and the gateway of [`crate::gateway`] (`gateway/*`,
//! `config/providers`, `spend`).  Every other method goes to [`Forward`].
//!
//! [`Front::line`] is one line of one connection: [`dispatch::prelude_as`] (the connection is the backend's when its
//! peer pid is the backend's), the refusal noted, the handler, the answer queued.  [`Front::start_line`] is the same
//! for the connection loop, except that a forwarded call runs on a task of its own (at most [`MAX_IN_FLIGHT`] per
//! connection; past that the connection is not read until one ends).

use crate::Exit;
use crate::conn::Outbox;
use crate::coord::{self, Signals, ToolHub, Writer};
use crate::dispatch::{self, Call, Caller, ErrorAnswerOrDrop, Forward, Refusals};
use crate::gateway::Gate;
use crate::hello::{self, Session};
use crate::sessions::{self, Sessions};
use crate::store::WorkDb;
use crate::version::COMMIT;
use runstav::line::MAX_HUB_LINE;
use runstav::methods::Params;
use runstav::methods::hub::{HubStatus, Runtime, StoreStatus, WriterState};
use runstav::methods::mcp::AttachAnswer;
use runstav::proof::Cap;
use runstav::registry;
use runstav::registry::{Class, Method};
use runstav::wire::{Answer, Error, ErrorAnswer, ErrorCode, Event, Id};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::sync::Semaphore;
use urdr::graph::OpenOutcome;

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
    /// The writer of the front's methods ([`crate::coord`]).
    pub writer: Writer,
    /// The coordination tools' shared state, on the same writer (for the MCP hosting).
    pub tools: Arc<norn::tools::Coord>,
    /// The coordination tools (`norn::tools::tools`).
    pub tool_list: Arc<[Box<dyn mimir::Tool<norn::tools::Ctx>>]>,
    /// The tools on the sessions' sockets and for outside bridges ([`crate::sessions`]).
    pub mcp: Sessions,
    /// The gateway ([`crate::gateway`]).
    pub gate: Gate,
    /// Test hooks (`--test-ignore-shutdown`): `shutdown` is answered and ignored, so `stop` reaches its signal.
    pub ignore_shutdown: AtomicBool,
    forward: Arc<dyn Forward>,
    refusals: Mutex<Refusals>,
    /// work.db's `meta.schema` at the last look (0: none).
    schema: AtomicU32,
    /// work.db's schema while it is newer than this hub's, else 0.
    read_only: AtomicU32,
    /// From work.db's `migrate-7` report: when the move from schema 6 committed, and the copies that still hold what
    /// its deny-list kept out.
    migration: Mutex<(Option<f64>, Vec<String>)>,
    subscribers: Mutex<BTreeMap<u64, Arc<Outbox>>>,
    stop: Notify,
    /// The stop asked for is a restart.
    restart: AtomicBool,
    next_conn: AtomicU64,
}

impl Front {
    /// The front on the main SOCKET with the user's CAP, reading through WORK_DB and writing through COORD_DB, the
    /// rest to FORWARD; no graph store (the tests' fronts on a schema-6 file).
    pub fn new(
        cap: Cap,
        socket: PathBuf,
        work_db: WorkDb,
        coord_db: norn::store::CoordDb,
        forward: Arc<dyn Forward>,
    ) -> Front {
        Front::with_graph(cap, socket, work_db, coord_db, None, forward)
    }

    /// [`Front::new`] with the graph store GRAPH the coordination tools read and write through (the hub's, on the
    /// graph writer that made or migrated work.db).
    pub fn with_graph(
        cap: Cap,
        socket: PathBuf,
        work_db: WorkDb,
        coord_db: norn::store::CoordDb,
        graph: Option<norn::tools::GraphStore>,
        forward: Arc<dyn Forward>,
    ) -> Front {
        let signals = Arc::new(Signals::default());
        let hub = Arc::new(ToolHub {
            forward: forward.clone(),
            signals: signals.clone(),
        });
        let uid = rustix::process::geteuid().as_raw();
        let coord = norn::tools::Coord::new(coord_db.clone(), hub);
        let tools = Arc::new(match graph {
            Some(g) => coord.with_graph(g),
            None => coord,
        });
        let gate = Gate::new(coord_db.clone());
        let tool_list: Arc<[Box<dyn mimir::Tool<norn::tools::Ctx>>]> = norn::tools::tools().into();
        Front {
            cap,
            pid: std::process::id(),
            uid,
            socket,
            started: crate::log::rfc3339(now()),
            work_db,
            writer: Writer {
                db: coord_db,
                signals,
            },
            mcp: Sessions::new(uid, tools.clone(), tool_list.clone()),
            gate,
            ignore_shutdown: AtomicBool::new(false),
            tools,
            tool_list,
            forward,
            refusals: Mutex::new(Refusals::default()),
            schema: AtomicU32::new(0),
            read_only: AtomicU32::new(0),
            migration: Mutex::new((None, Vec::new())),
            subscribers: Mutex::new(BTreeMap::new()),
            stop: Notify::new(),
            restart: AtomicBool::new(false),
            next_conn: AtomicU64::new(1),
        }
    }

    pub fn next_conn(&self) -> u64 {
        self.next_conn.fetch_add(1, Ordering::Relaxed)
    }

    /// Where the methods the front does not serve go.
    pub fn forward(&self) -> &dyn Forward {
        &*self.forward
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

    /// work.db's `migrate-7` report REPORT (its JSON text; none for a file made at schema 7): `status.store`'s
    /// `migrated_at` and `denied_in`.
    pub fn note_migration(&self, report: Option<&str>) {
        let v: Value = report
            .and_then(|r| serde_json::from_str(r).ok())
            .unwrap_or(Value::Null);
        let at = v["at"].as_f64().filter(|a| *a > 0.0);
        let copies: Vec<String> = v["denied_in"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        *self.migration.lock().expect("migration") = (at, copies);
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
        let Some(line) = event_line(event, data) else {
            return;
        };
        self.subscribers
            .lock()
            .expect("subscribers")
            .retain(|_, out| out.push(line.clone()));
    }

    pub fn status(&self) -> HubStatus {
        let schema = self.schema.load(Ordering::Relaxed);
        HubStatus {
            pid: u64::from(self.pid),
            socket: Some(self.socket.to_string_lossy().into_owned()),
            started: Some(self.started.clone()),
            proto: Some(u64::from(registry::PROTO)),
            proto_min: Some(u64::from(registry::PROTO_MIN)),
            records: Some(u64::from(registry::RECORDS)),
            drgnx_version: Some(COMMIT.into()),
            schema: Some(u64::from(schema)),
            read_only: self.read_only().map(u64::from),
            store: Some(self.store_status(schema)),
            mcp: Some(self.mcp.status()),
            runtime: Some(Runtime {
                version: env!("CARGO_PKG_VERSION").into(),
                commit: COMMIT.into(),
            }),
            refusals: Some(self.refusals.lock().expect("refusals").status()),
            job_agents: Some(JOB_AGENTS.into()),
            backend: None,
            gateway: Some(self.gate.status()),
            gateway_port: None,
            registrations: None,
        }
    }

    /// `status.store`: with the hub's graph writer, its opening rule's last answer (a failed migration's reason in
    /// `failed`) and the WAL's size; without one (the tests' fronts), from the schema at the last tick.
    fn store_status(&self, schema: u32) -> StoreStatus {
        let (migrated_at, denied_in) = self.migration.lock().expect("migration").clone();
        let mut st = StoreStatus {
            schema: u64::from(schema),
            writer: match schema {
                s if s == norn::store::SCHEMA => WriterState::Ready,
                s if s > norn::store::SCHEMA => WriterState::ReadOnly,
                _ => WriterState::NotReady,
            },
            writes: self.writer.signals.writes(),
            migrated_at,
            failed: None,
            wal_bytes: None,
            last_backup: None,
            backup_ok: None,
            denied_in,
        };
        if let Some(w) = self.writer.db.graph_writer() {
            let open = w.status().last_open;
            st.writer = match &open {
                Some(OpenOutcome::Ready { .. }) => WriterState::Ready,
                Some(OpenOutcome::ReadOnly { .. }) => WriterState::ReadOnly,
                _ => WriterState::NotReady,
            };
            if let Some(OpenOutcome::Failed(why)) = open {
                st.failed = Some(why);
            }
            let mut wal = w.path().as_os_str().to_owned();
            wal.push("-wal");
            st.wal_bytes = Some(std::fs::metadata(PathBuf::from(wal)).map_or(0, |m| m.len()));
        }
        st
    }

    /// `status`: the front's keys (the gateway's among them), and the backend's state.
    pub async fn status_with_backend(&self) -> HubStatus {
        let mut st = self.status();
        st.backend = self.forward.status().await.backend;
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
        // the Lisp backend wrote the rest of the event log meanwhile: its rows go out now
        if method.writes && result.is_ok() {
            self.writer.signals.events_soon();
        }
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
        // the backend's own connection (its peer pid; R-FIX-M9 must keep marking it): held to what the front serves
        let backend = s.peer_pid.is_some() && s.peer_pid == self.forward.backend_pid();
        let call = match dispatch::prelude_as(s.class, backend, s.proto, self.read_only(), text) {
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
        let mut caller = s.caller();
        caller.backend = backend;
        let mut stop = false;
        let mut restart = false;
        // a new subscriber hears which keys kept registrations need, after its answer
        let mut need_keys = None;
        let result = match params {
            Params::Hello(p) => {
                let schema = self.schema.load(Ordering::Relaxed);
                hello::hello(s, &self.cap, &p, schema).map(|r| json!(r))
            }
            Params::Ping(_) => Ok(json!({"pid": self.pid})),
            // the backend never waits on itself: its status is the front's
            Params::Status(_) if backend => Ok(json!(self.status())),
            Params::Status(_) => Ok(json!(self.status_with_backend().await)),
            Params::Subscribe(_) => {
                self.subscribers
                    .lock()
                    .expect("subscribers")
                    .insert(s.conn, out.clone());
                need_keys = self.gate.pending_need_keys();
                Ok(json!(true))
            }
            Params::Shutdown(_) => {
                stop = !self.ignore_shutdown.load(Ordering::Relaxed);
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
            Params::CoordNotify(_) => {
                self.writer.signals.events_soon();
                if !backend {
                    self.writer.signals.notify_soon();
                }
                Ok(json!(true))
            }
            Params::McpSession(p) => self.mcp.open(p).await.map(|a| json!(a)),
            Params::McpSessionClose(p) => self.mcp.close(p.sid.as_str()).await.map(|b| json!(b)),
            // the answer goes out first; the connection loop then hands the connection to MCP
            Params::McpAttach(p) => sessions::outside(s, p.kind.as_str()).map(|who| {
                let identity = who.id().unwrap_or_default().to_owned();
                s.attach = Some(who);
                json!(AttachAnswer { identity })
            }),
            // the gateway's: keys and registrations never reach the backend
            Params::Spend(p) => self.gate.spend(&caller, p).await.map(|r| json!(r)),
            Params::GatewayRegister(p) => self
                .gate
                .register(p, s.peer_pid, &self.mcp)
                .await
                .map(|r| json!(r)),
            Params::GatewayUnregister(p) => {
                self.gate.unregister(&p.token.0).await.map(|b| json!(b))
            }
            Params::GatewayKeys(p) => {
                self.gate.take_keys(p.keys);
                Ok(json!(true))
            }
            Params::GatewaySetBudget(p) => self.gate.set_budget(p).await.map(|b| json!(b)),
            Params::ConfigProviders(p) => self.gate.config_providers(p).await.map(|r| json!(r)),
            other => match coord::serve(&self.writer, &caller, other).await {
                Ok(result) => result,
                Err(params) => {
                    return Some(Forwarded {
                        id,
                        method,
                        params: *params,
                        ignored,
                        caller,
                    });
                }
            },
        };
        if let Err(e) = &result
            && e.code != ErrorCode::Internal
        {
            self.refused(s.conn, s.class, Some(method.name), e);
        }
        if let Some(id) = id {
            out.push(answer_line(s.conn, id, result, ignored));
        }
        if let Some(line) = need_keys.and_then(|data| event_line("gateway/need-keys", data)) {
            out.push(line);
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

/// EVENT with DATA as the line a subscriber gets; none (logged) over 16 MiB.
fn event_line(event: &str, data: Value) -> Option<Arc<str>> {
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
        return None;
    }
    Some(format!("{text}\n").into())
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
    use runstav::registry::Class;

    fn front(dir: &std::path::Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
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
        assert_eq!(
            v["store"],
            // the store's writer made the file (schema 7) when it was spawned: its WAL is there, empty
            json!({"schema": 0, "writer": "not-ready", "wal_bytes": 0, "writes": 0})
        );
        assert_eq!(v["mcp"], json!({"sessions": 0, "outside": 0}));
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
                    backend: Some(runstav::methods::hub::Backend {
                        state: runstav::methods::hub::BackendState::Running,
                        pid: Some(42),
                    }),
                }
            })
        }
    }

    fn gated(dir: &std::path::Path, gate: Arc<Semaphore>) -> Arc<Front> {
        Arc::new(Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
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
        // the gateway's numbers are the front's own, counted since start; the Lisp hub's keys are gone
        assert_eq!(
            v["gateway"],
            json!({"registrations": 0, "requests": 0, "errors": 0, "fallbacks": 0, "bytes_in": 0,
                   "bytes_out": 0, "providers": 0, "keys_held": [], "warnings": []})
        );
        assert!(
            v.get("gateway_port").is_none() && v.get("registrations").is_none(),
            "{v}"
        );
        let m = registry::find("status").unwrap();
        assert_eq!((m.check_result)(&v).unwrap(), v);
        // without a backend there is nothing to say of it
        let f = front(dir.path());
        let v = serde_json::to_value(f.status_with_backend().await).unwrap();
        assert!(v.get("backend").is_none(), "{v}");
    }

    /// A backend whose pid is 4242, counting the calls forwarded to it.
    struct Behind(std::sync::atomic::AtomicUsize);

    impl Forward for Behind {
        fn call<'a>(&'a self, _: Caller, _: &'static Method, _: Params) -> dispatch::Answer<'a> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Ok(json!(true)) })
        }

        fn backend_pid(&self) -> Option<i32> {
            Some(4242)
        }
    }

    #[tokio::test]
    async fn the_backends_connection_is_held_to_what_the_front_serves() {
        let dir = tempfile::tempdir().unwrap();
        let behind = Arc::new(Behind(std::sync::atomic::AtomicUsize::new(0)));
        let f = Front::new(
            Cap::generate().unwrap(),
            dir.path().join("hub-x.sock"),
            WorkDb::spawn(dir.path().join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.path().join("work.db")),
            behind.clone(),
        );
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        s.peer_pid = Some(4242);
        let out = Arc::new(Outbox::new(s.conn));
        f.line(&mut s, &out, r#"{"id":1,"method":"job/status"}"#)
            .await;
        f.line(&mut s, &out, r#"{"id":2,"method":"subscribe"}"#)
            .await;
        f.line(&mut s, &out, r#"{"id":3,"method":"status"}"#).await;
        let a = answers(&out);
        assert_eq!(
            a[0]["error"],
            json!({"code": "not-allowed", "message": "the backend may call only what the front serves"})
        );
        assert_eq!(
            a[1]["error"]["message"],
            "the backend hears the front through notifications"
        );
        // its status never asks the backend
        assert!(a[2]["result"].get("backend").is_none(), "{a:?}");
        assert_eq!(behind.0.load(Ordering::SeqCst), 0);
        // another pid's user connection is forwarded as before
        let mut t = Session::new(f.next_conn(), Socket::Main);
        t.class = Class::User;
        t.peer_pid = Some(4243);
        f.line(&mut t, &out, r#"{"id":4,"method":"job/status"}"#)
            .await;
        assert_eq!(answers(&out), vec![json!({"id": 4, "result": true})]);
        assert_eq!(behind.0.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn attach_is_the_peers_parent_and_hands_the_connection_on() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        // the peer is a child of this process (a test runner may itself be pid 1's child, or pid 1)
        let mut peer = std::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let attach = r#"{"id":1,"method":"mcp/attach","params":{"kind":"claude"}}"#;
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.peer_pid = Some(peer.id() as i32);
        s.cwd = Some(PathBuf::from("/w"));
        let out = Arc::new(Outbox::new(s.conn));
        f.line(&mut s, &out, attach).await;
        let a = answers(&out);
        let id = a[0]["result"]["identity"].as_str().unwrap_or_default();
        let hash = norn::tools::identity::start_hash(
            crate::peer::parent_of(peer.id() as i32)
                .unwrap()
                .start
                .unwrap(),
        );
        assert_eq!(
            id,
            format!("ext:claude:{}-{hash}", std::process::id()),
            "{a:?}"
        );
        let who = s.attach.as_ref().expect("the connection is handed to MCP");
        assert_eq!(
            (who.id(), who.home(), who.job()),
            (Some(id), Some(std::path::Path::new("/w")), None)
        );
        // a user connection never attaches, and a kind is the bin/drgnx rule
        let mut u = Session::new(f.next_conn(), Socket::Main);
        u.class = Class::User;
        u.peer_pid = s.peer_pid;
        f.line(&mut u, &out, attach).await;
        let bad = r#"{"id":2,"method":"mcp/attach","params":{"kind":"Claude"}}"#;
        let mut t = Session::new(f.next_conn(), Socket::Main);
        t.peer_pid = s.peer_pid;
        f.line(&mut t, &out, bad).await;
        let a = answers(&out);
        assert_eq!(a[0]["error"]["code"], "not-allowed", "{a:?}");
        assert_eq!(
            (a[1]["error"]["code"].clone(), a[1]["error"]["path"].clone()),
            (json!("invalid-params"), json!("kind"))
        );
        assert!(u.attach.is_none() && t.attach.is_none());
        peer.kill().unwrap();
        peer.wait().unwrap();
    }

    #[tokio::test]
    async fn a_hello_is_answered_and_sets_the_session() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.hub_nonce = runstav::proof::nonce().unwrap();
        let nonce = runstav::proof::nonce().unwrap();
        let p = runstav::proof::client_proof(&f.cap, &s.hub_nonce, &nonce);
        let out = Arc::new(Outbox::new(s.conn));
        let line =
            json!({"id": 1, "method": "hello", "params": {"proto": 1, "nonce": nonce, "proof": p}});
        f.line(&mut s, &out, &line.to_string()).await;
        let a = answers(&out);
        assert_eq!(a[0]["result"]["class"], "user", "{a:?}");
        assert_eq!(s.class, Class::User);
        // a wrong proof is a refusal: counted
        let mut t = Session::new(f.next_conn(), Socket::Main);
        t.hub_nonce = runstav::proof::nonce().unwrap();
        f.line(&mut t, &out, &line.to_string()).await;
        assert_eq!(answers(&out)[0]["error"]["code"], "not-allowed");
        assert_eq!(f.status().refusals.map(|r| r.count), Some(1));
    }
}
