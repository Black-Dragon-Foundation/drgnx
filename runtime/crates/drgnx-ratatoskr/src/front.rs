//! The front: what every connection shares, and every method's handler — its own (`hello`, `ping`, `status`,
//! `subscribe`, `shutdown`, `restart`, `events/since`, `coord/notify`, `env/set`), the writes of [`crate::coord`],
//! the store's methods of [`crate::graph`] (`graph/*`, `tasks/*`), the MCP hosting of [`crate::sessions`] (`mcp/*`),
//! the gateway of [`crate::gateway`] (`gateway/*`, `spend`), the settings' (`config/settings`, `config/changed`) and
//! the agent core's of [`crate::agent_core`] (`agents/*`, `job/*`, `exec/*`, `matrix/*`, …).  One `match` over
//! `Params` with no catch-all arm routes them, so a method without a handler does not compile; a group it hands to
//! another module's `serve` is checked against that `serve`'s arms by a test (a variant with none reaches no handler).
//!
//! [`Front::line`] is one line of one connection: [`dispatch::prelude`], the refusal noted, the handler, the answer
//! queued.

use crate::Exit;
use crate::conn::Outbox;
use crate::coord::{self, Signals, ToolHub, Writer};
use crate::dispatch::{self, Call, ErrorAnswerOrDrop, Refusals};
use crate::gateway::Gate;
use crate::hello::{self, Session};
use crate::sessions::{self, Sessions};
use crate::store::WorkDb;
use crate::version::COMMIT;
use runstav::line::MAX_HUB_LINE;
use runstav::methods::Params;
use runstav::methods::gateway::KeysHeld;
use runstav::methods::hub::{EnvSetResult, HubStatus, Runtime, StoreStatus, WriterState};
use runstav::methods::mcp::AttachAnswer;
use runstav::proof::Cap;
use runstav::registry;
use runstav::registry::{Class, Method};
use runstav::wire::{Answer, Error, ErrorAnswer, ErrorCode, Event, Id};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Notify;
use urdr::graph::OpenOutcome;

/// What `status` and the doctor say of agents: every session starts in the job sandbox (`agents::launch`), and a host
/// that cannot give one refuses to start the session.
pub const JOB_AGENTS: &str = "every session runs in the job sandbox; where it cannot, none starts";

/// How long `shutdown` waits for its answer to be written before the hub stops.
const SHUTDOWN_FLUSH: Duration = Duration::from_secs(1);

/// How long the hub's end waits, in real time, for what is queued to its connections to be written before it closes
/// them.
const END_FLUSH: Duration = Duration::from_secs(1);

fn lock_conns(
    m: &Mutex<HashMap<u64, Arc<Outbox>>>,
) -> std::sync::MutexGuard<'_, HashMap<u64, Arc<Outbox>>> {
    m.lock().expect("the connections lock")
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
    /// The tools' view of the hub; [`ToolHub::bind`] gives it the front once that is in its `Arc`.
    pub tool_hub: Arc<ToolHub>,
    /// The coordination tools (`norn::tools::tools`).
    pub tool_list: Arc<[Box<dyn mimir::Tool<norn::tools::Ctx>>]>,
    /// The tools on the sessions' sockets and for outside bridges ([`crate::sessions`]).
    pub mcp: Sessions,
    /// The gateway ([`crate::gateway`]).
    pub gate: Gate,
    /// What the hub read of `settings.el` and the shipped defaults ([`crate::settings`]).
    pub settings: Arc<crate::settings::Settings>,
    /// The subscribers: the editors the agents' settings tools ask ([`crate::settings::agents`]).
    pub editors: Arc<crate::settings::agents::Editors>,
    /// Hrafn: the built-in model's worker, the open projects, the `search/*` methods ([`crate::search::methods`]).
    pub search: crate::search::Hub,
    /// Test hooks (`--test-ignore-shutdown`): `shutdown` is answered and ignored, so `stop` reaches its signal.
    pub ignore_shutdown: AtomicBool,
    /// The store's other folders (home, config, `<state>/hub`), once the server opened it.
    pub dirs: OnceLock<crate::graph::StoreDirs>,
    /// The login shell's variables the editor sent (`env/set`): the base of what the hub starts.
    pub shell_env: crate::shell_env::ShellEnv,
    /// The agent core's state ([`crate::agent_core`]): sessions, jobs, plan runs, the matrix, …
    pub core: crate::agent_core::Core,
    /// What every browser session's web proxy treats as the host itself: the host's addresses and the hub's own
    /// loopback ports ([`crate::browser::nevers`]), kept live once the hub starts its watches.
    pub browser_nevers: crate::browser::nevers::Nevers,
    refusals: Mutex<Refusals>,
    /// work.db's `meta.schema` at the last look (0: none).
    schema: AtomicU32,
    /// work.db's schema while it is newer than this hub's, else 0.
    read_only: AtomicU32,
    /// From work.db's `migrate-7` report: when the move from schema 6 committed, and the copies that still hold what
    /// its deny-list kept out.
    migration: Mutex<(Option<f64>, Vec<String>)>,
    stop: Notify,
    /// The stop asked for is a restart.
    restart: AtomicBool,
    next_conn: AtomicU64,
    /// Every connection served now, on any socket: what [`Front::end_connections`] closes.
    conns: Mutex<HashMap<u64, Arc<Outbox>>>,
}

impl Front {
    /// The front on the main SOCKET with the user's CAP, reading through WORK_DB and writing through COORD_DB; no graph
    /// store (the tests' fronts on a schema-6 file).
    pub fn new(
        cap: Cap,
        socket: PathBuf,
        work_db: WorkDb,
        coord_db: norn::store::CoordDb,
    ) -> Front {
        Front::with_graph(cap, socket, work_db, coord_db, None)
    }

    /// [`Front::new`] with the graph store GRAPH the coordination tools read and write through (the hub's, on the
    /// graph writer that made or migrated work.db).
    pub fn with_graph(
        cap: Cap,
        socket: PathBuf,
        work_db: WorkDb,
        coord_db: norn::store::CoordDb,
        graph: Option<norn::tools::GraphStore>,
    ) -> Front {
        let signals = Arc::new(Signals::default());
        let settings = Arc::new(crate::settings::Settings::new());
        let editors = Arc::new(crate::settings::agents::Editors::default());
        let hub = Arc::new(ToolHub {
            signals: signals.clone(),
            editors: editors.clone(),
            settings: settings.clone(),
            front: std::sync::OnceLock::new(),
        });
        let tool_hub = hub.clone();
        let uid = rustix::process::geteuid().as_raw();
        let coord = norn::tools::Coord::new(coord_db.clone(), hub);
        let tools = Arc::new(match graph {
            Some(g) => coord.with_graph(g),
            None => coord,
        });
        let gate = Gate::new(coord_db.clone());
        let budgets = crate::budget::Budgets::default();
        gate.attach_budgets(budgets.clone());
        let tool_list: Arc<[Box<dyn mimir::Tool<norn::tools::Ctx>>]> = norn::tools::tools().into();
        let matrix = crate::matrix_gate::MatrixGate::default();
        matrix.announce_to(editors.clone());
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
            settings,
            editors,
            search: crate::search::Hub::default(),
            ignore_shutdown: AtomicBool::new(false),
            dirs: OnceLock::new(),
            shell_env: crate::shell_env::ShellEnv::default(),
            core: crate::agent_core::Core {
                budgets,
                matrix,
                ..Default::default()
            },
            browser_nevers: crate::browser::nevers::Nevers::default(),
            tools,
            tool_hub,
            tool_list,
            refusals: Mutex::new(Refusals::default()),
            schema: AtomicU32::new(0),
            read_only: AtomicU32::new(0),
            migration: Mutex::new((None, Vec::new())),
            stop: Notify::new(),
            restart: AtomicBool::new(false),
            next_conn: AtomicU64::new(1),
            conns: Mutex::new(HashMap::new()),
        }
    }

    pub fn next_conn(&self) -> u64 {
        self.next_conn.fetch_add(1, Ordering::Relaxed)
    }

    /// Connection CONN is served, its lines going out through OUT (until [`Front::gone`]).
    pub fn serving(&self, conn: u64, out: &Arc<Outbox>) {
        lock_conns(&self.conns).insert(conn, out.clone());
    }

    /// The hub has stopped serving: every connection still open gets what is queued for it written (at most
    /// [`END_FLUSH`] of real time for all of them), then is closed, so its client reads its end of file now, before the
    /// hub waits on anything that can hang.
    pub async fn end_connections(&self) {
        let all: Vec<Arc<Outbox>> = lock_conns(&self.conns).values().cloned().collect();
        let flushed = crate::clock::real_timeout(END_FLUSH, async {
            for out in &all {
                out.flushed(END_FLUSH).await;
            }
        })
        .await;
        if flushed.is_err() {
            tracing::warn!("the hub ends with lines not yet written to a connection");
        }
        for out in all {
            out.close("closed a connection: the hub ends");
        }
        // and those `mcp/attach` handed to MCP, which left the registry then
        self.mcp.end_outside();
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

    /// Ask the hub to end with exit 75 (`restart`, restart-when-idle).
    pub fn ask_restart(&self) {
        self.restart.store(true, Ordering::SeqCst);
        self.stop.notify_one();
    }

    /// The connection CONN is gone: no more events for it.
    pub fn gone(&self, conn: u64) {
        lock_conns(&self.conns).remove(&conn);
        self.editors.gone(conn);
        self.core.presence.gone(conn);
        self.core.map.gone(conn);
    }

    /// EVENT with DATA to every subscribed connection: queued for each before any is written (a queue never waits),
    /// so a newer event never reaches one subscriber before an older one.
    pub fn broadcast(&self, event: &str, data: Value) {
        self.editors.broadcast(event, data);
    }

    /// EVENT with DATA to connection CONN only (it must be subscribed); false when it took nothing.
    pub fn send_to(&self, conn: u64, event: &str, data: Value) -> bool {
        self.editors.send_to(conn, event, data)
    }

    /// `gateway/keys-changed` to the subscribers when the held keys' ids are no longer BEFORE (ids only).  A
    /// restarted hub holds none: a reconnecting editor asks `gateway/keys-held`, and hears this when its handover
    /// fills the set again.
    fn keys_changed(&self, before: &KeysHeld) {
        let now = self.gate.keys_held();
        if now != *before {
            self.broadcast("gateway/keys-changed", json!(now));
        }
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
            gateway: Some(self.gate.status()),
            gateway_port: None,
            registrations: None,
            settings: Some(self.settings.current().status()),
        }
    }

    /// `settings.el` read again when its stamp changed (at start, and when a session starts); the problems the last
    /// read did not have go to the subscribers as notices.
    pub async fn refresh_settings(&self) {
        let before = self.settings.current();
        for n in self.settings.refresh().await {
            self.broadcast("notice", n);
        }
        // a front with no config folder (a test's) keeps the table it was given
        if self.settings.is_open() {
            self.apply_settings();
        }
        // the matrix or the deny list may have changed: the browser sessions' web proxies read them again at once
        if self.settings.current().loaded != before.loaded {
            self.writer.signals.answers_changed();
        }
    }

    /// The variables that hold a provider's key, for the providers in effect: `env/set`, a user's job and
    /// `agents/start`'s `env` never take them.
    pub(crate) fn provider_key_envs(&self) -> Vec<String> {
        let current = self.settings.current();
        crate::settings::providers::effective(
            &crate::settings::defaults().presets,
            &current.loaded.values.ai_providers,
        )
        .into_iter()
        .filter_map(|p| p.key_env.clone())
        .collect()
    }

    /// The provider table in effect (`settings.el` and the global overrides) is the gateway's.
    pub fn apply_settings(&self) {
        if let Err(e) = self.gate.apply(&self.settings.current().loaded.providers) {
            tracing::warn!("the settings' provider table does not apply: {}", e.message);
        }
    }

    /// `config/settings`: the editor's values of PROJECT (none: global) kept as last good and put to work.
    pub(crate) async fn config_settings(
        &self,
        p: runstav::methods::config::SettingsParams,
    ) -> Result<runstav::methods::config::SettingsApplied, Error> {
        let list = p
            .overrides
            .into_inner()
            .into_iter()
            .map(|o| crate::settings::overrides::Override {
                name: o.name.into_inner(),
                value: o.value.0,
                source: o.source.into_inner(),
            })
            .collect();
        let project = p.project.map(|p| p.into_inner());
        let applied = self
            .settings
            .set_overrides(project.as_deref(), list)
            .await?;
        self.apply_settings();
        self.writer.signals.answers_changed();
        Ok(runstav::methods::config::SettingsApplied { applied })
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
            batches: None,
            replays: None,
            readers: None,
        };
        if let Some(g) = self.tools.graph() {
            st.readers = Some(g.pool.in_use() as u64);
            if let Some((at, ok)) = crate::backup_timer::last().attempt {
                st.last_backup = Some(crate::log::rfc3339(at));
                st.backup_ok = Some(ok);
            }
        }
        if let Some(w) = self.writer.db.graph_writer() {
            let ws = w.status();
            st.batches = Some(ws.batches);
            st.replays = Some(ws.replays);
            let open = ws.last_open;
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
    /// notification is dispatched and never answered.
    pub async fn line(&self, s: &mut Session, out: &Arc<Outbox>, text: &str) {
        let call = match dispatch::prelude(s.class, s.proto, self.read_only(), text) {
            Ok(c) => c,
            Err(ErrorAnswerOrDrop::Drop(why)) => {
                tracing::info!(conn = s.conn, "dropped {why}");
                return;
            }
            Err(ErrorAnswerOrDrop::Refused(r)) => {
                self.refused(s.conn, s.class, r.method.as_deref(), &r.error);
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
        let caller = s.caller();
        let mut stop = false;
        let mut restart = false;
        // a new subscriber hears which keys kept registrations need, and the settings' problems, after its answer
        let mut need_keys = None;
        let mut settings_notices = Vec::new();
        // a settled card may be the one a session's permission request waits on (a matrix Ask)
        let settled = match &params {
            Params::CardsSettle(p) => i64::try_from(p.card).ok(),
            _ => None,
        };
        let result = match params {
            Params::Hello(p) => {
                let schema = self.schema.load(Ordering::Relaxed);
                hello::hello(s, &self.cap, &p, schema).map(|r| json!(r))
            }
            Params::Ping(_) => Ok(json!({"pid": self.pid})),
            Params::Status(_) => Ok(json!(self.status())),
            Params::Subscribe(_) => {
                self.editors.subscribe(s.conn, out.clone());
                need_keys = self.gate.pending_need_keys();
                settings_notices = self.settings.current().notices();
                Ok(json!(true))
            }
            Params::Shutdown(_) => {
                stop = !self.ignore_shutdown.load(Ordering::Relaxed);
                Ok(json!(true))
            }
            Params::BrowserCheck(_) => {
                self.refresh_settings().await;
                Ok(json!(crate::browser::check::run(self).await))
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
                self.writer.signals.notify_soon();
                Ok(json!(true))
            }
            // a session starts on the settings as the file says now
            Params::McpSession(p) => {
                let t = crate::clock::real_now();
                self.refresh_settings().await;
                if t.elapsed() > sessions::SLOW_OPEN {
                    let ms = t.elapsed().as_millis() as u64;
                    tracing::warn!(ms, "mcp/session: the settings took {ms} ms to refresh");
                }
                self.mcp.open(p).await.map(|a| json!(a))
            }
            Params::McpSessionClose(p) => self.mcp.close(p.sid.as_str()).await.map(|b| json!(b)),
            // the answer goes out first; the connection loop then hands the connection to MCP
            Params::McpAttach(p) => sessions::outside(s, p.kind.as_str()).map(|who| {
                let identity = who.id().unwrap_or_default().to_owned();
                s.attach = Some(who);
                json!(AttachAnswer { identity })
            }),
            // the gateway's
            Params::Spend(p) => self.gate.spend(&caller, p).await.map(|r| json!(r)),
            Params::GatewayRegister(p) => {
                let before = self.gate.keys_held();
                let r = self.gate.register(p, s.peer_pid, &self.mcp).await;
                self.keys_changed(&before);
                r.map(|r| json!(r))
            }
            Params::GatewayUnregister(p) => {
                self.gate.unregister(&p.token.0).await.map(|b| json!(b))
            }
            Params::GatewayKeys(p) => self.gate.protects_keys().map(|()| {
                let before = self.gate.keys_held();
                self.gate.take_keys(p.keys);
                self.keys_changed(&before);
                json!(true)
            }),
            Params::GatewayEditorToken(_) => {
                self.gate.editor_token(s.peer_pid).await.map(|r| json!(r))
            }
            Params::GatewayKeysHeld(_) => Ok(json!(self.gate.keys_held())),
            Params::GatewaySetBudget(p) => self.gate.set_budget(p).await.map(|b| json!(b)),
            Params::ConfigSettings(p) => self.config_settings(p).await.map(|r| json!(r)),
            Params::ConfigChanged(_) => {
                self.refresh_settings().await;
                Ok(json!(true))
            }
            Params::EnvSet(p) => {
                let vars = p
                    .env
                    .into_inner()
                    .into_iter()
                    .map(|v| (v.name.as_str().to_owned(), v.value.into_inner()))
                    .collect();
                let applied = self.shell_env.set(vars, &self.provider_key_envs());
                Ok(json!(EnvSetResult { applied }))
            }
            // the agents' settings tools: the editor's answers (crate::settings::agents)
            Params::SettingsConfirm(p) => {
                let (tx, ok) = (i64::try_from(p.tx).unwrap_or(i64::MAX), p.ok);
                let error = p.error.as_ref().map(|e| e.to_string());
                let r = crate::graph::settings_confirm(&self.writer, &caller, p).await;
                if r.is_ok() {
                    self.editors.confirmed(tx, ok, error);
                }
                r
            }
            Params::SettingsExplained(p) => {
                let rows = p
                    .settings
                    .into_inner()
                    .into_iter()
                    .map(|o| Value::Object(o.into_inner()))
                    .collect();
                Ok(json!(self.editors.explained(p.req, rows)))
            }
            // the agent core's (`agents/*`, `job/*`, `exec/*`, …)
            p @ (Params::AgentsList(_)
            | Params::AgentsStart(_)
            | Params::AgentsGet(_)
            | Params::AgentsSend(_)
            | Params::AgentsStop(_)
            | Params::AgentsKill(_)
            | Params::AgentsPermission(_)
            | Params::AgentsDo(_)
            | Params::AgentsMove(_)
            | Params::AgentsRole(_)
            | Params::AgentsSlice(_)
            | Params::AgentsEntriesSubscribe(_)
            | Params::AgentsEntriesUnsubscribe(_)
            | Params::AgentsToolInput(_)
            | Params::AgentsPause(_)
            | Params::AgentsContextDrop(_)
            | Params::AgentsContextPin(_)
            | Params::AgentsCompactPreview(_)
            | Params::AgentsProbe(_)
            | Params::MessagesRetract(_)
            | Params::ExecStart(_)
            | Params::ExecGet(_)
            | Params::ExecList(_)
            | Params::ExecStop(_)
            | Params::ExecLog(_)
            | Params::ExecBump(_)
            | Params::JobPropose(_)
            | Params::JobStartTask(_)
            | Params::JobApprove(_)
            | Params::JobOrder(_)
            | Params::JobBlock(_)
            | Params::JobUnblock(_)
            | Params::JobStop(_)
            | Params::JobStatus(_)
            | Params::JobCard(_)
            | Params::JobReply(_)
            | Params::JobDismiss(_)
            | Params::JobReassign(_)
            | Params::JobResume(_)
            | Params::MatrixGet(_)
            | Params::MatrixCheck(_)
            | Params::PresenceSet(_)
            | Params::PlansGet(_)
            | Params::PlansWrite(_)
            | Params::ReportsGet(_)
            | Params::DecisionsEffects(_)
            | Params::BriefBuild(_)
            | Params::BriefSet(_)
            | Params::TimelineGet(_)
            | Params::BudgetGet(_)
            | Params::BudgetSet(_)
            | Params::PaceGet(_)
            | Params::RecordsImport(_)
            | Params::RecordsStatus(_)
            | Params::RecordsProposals(_)
            | Params::RecordsDecide(_)
            | Params::MachinesReport(_)
            | Params::MachinesList(_)
            | Params::RunnersList(_)
            | Params::RunnersProbeHost(_)
            | Params::RunnersAdd(_)
            | Params::RunnersCheck(_)
            | Params::RunnersBench(_)
            | Params::RunnersSet(_)
            | Params::HistoryRegister(_)
            | Params::HistoryBatch(_)
            | Params::HistoryResync(_)
            | Params::HistoryUnregister(_)
            | Params::RunnersUnbench(_)
            | Params::RunnersRemove(_)
            | Params::PluginsList(_)
            | Params::PluginsApprove(_)
            | Params::PluginsDisable(_)
            | Params::WorkConclusions(_)
            | Params::AgentsPresenceSubscribe(_)
            | Params::AgentsPresenceGet(_)
            | Params::WorkMapSubscribe(_)
            | Params::WorkMapSet(_)
            | Params::WorkMapClose(_)
            | Params::WorkFiles(_)
            | Params::WorkHunks(_)
            | Params::WorkFileAt(_)) => crate::agent_core::serve(self, &caller, p)
                .await
                .unwrap_or_else(|_| unserved(method)),
            // Hrafn's (`search/*`)
            p @ (Params::SearchQuery(_)
            | Params::SearchStatus(_)
            | Params::SearchIndex(_)
            | Params::SearchEmbedders(_)
            | Params::SearchModelDownload(_)
            | Params::SearchServerPlan(_)
            | Params::SearchServerStart(_)
            | Params::SearchServerStop(_)
            | Params::SearchTyping(_)) => crate::search::methods::serve(self, &caller, p)
                .await
                .unwrap_or_else(|_| unserved(method)),
            // the graph store's (`graph/*`, `tasks/*`); a settled card too (an access card becomes a grant)
            p @ (Params::GraphPutParsed(_)
            | Params::GraphRecord(_)
            | Params::GraphEntity(_)
            | Params::GraphNeighbors(_)
            | Params::GraphPath(_)
            | Params::GraphHistory(_)
            | Params::GraphRevert(_)
            | Params::GraphExcise(_)
            | Params::GraphGrants(_)
            | Params::GraphProposed(_)
            | Params::GraphSql(_)
            | Params::GraphExport(_)
            | Params::GraphImport(_)
            | Params::GraphBackup(_)
            | Params::GraphCompact(_)
            | Params::GraphScrub(_)
            | Params::GraphSettings(_)
            | Params::GraphPrivacy(_)
            | Params::SettingsRecord(_)
            | Params::CardsSettle(_)
            | Params::TasksReady(_)
            | Params::TasksFind(_)
            | Params::TasksWrite(_)) => {
                crate::graph::serve(&self.writer, &self.tools, self.dirs.get(), &caller, p)
                    .await
                    .unwrap_or_else(|_| unserved(method))
            }
            // the coordination writes
            p @ (Params::MessagesSend(_)
            | Params::MessagesMark(_)
            | Params::EventsAdd(_)
            | Params::ReviewMark(_)
            | Params::CoordJobCreate(_)
            | Params::CoordJobSet(_)
            | Params::CoordTaskStatus(_)
            | Params::CoordLeases(_)
            | Params::CoordDecide(_)
            | Params::CoordAgent(_)
            | Params::CoordCardCreate(_)
            | Params::CoordCardSet(_)
            | Params::CoordHeld(_)
            | Params::CoordPrune(_)) => coord::serve(&self.writer, &caller, p)
                .await
                .unwrap_or_else(|_| unserved(method)),
        };
        if let (Some(card), Ok(_)) = (settled, &result) {
            self.core.agents.card_settled(card).await;
            self.core.plugins.card_settled(card);
        }
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
        for line in settings_notices
            .into_iter()
            .filter_map(|data| event_line("notice", data))
        {
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
    }
}

/// The answer for METHOD when the part it is routed to handed its params back: a routing mistake, never the
/// caller's.
fn unserved(method: &Method) -> Result<Value, Error> {
    tracing::error!(method = method.name, "a method reached no handler");
    Err(internal(format!("{} reached no handler", method.name)))
}

/// EVENT with DATA as the line a subscriber gets; none (logged) over 16 MiB.
pub(crate) fn event_line(event: &str, data: Value) -> Option<Arc<str>> {
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

/// Seconds since the epoch, on the hub's clock.
fn now() -> u64 {
    crate::clock::wall()
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
    use crate::hello::Socket;
    use runstav::registry::Class;

    fn front(dir: &std::path::Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
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
            json!({"schema": 0, "writer": "not-ready", "wal_bytes": 0, "writes": 0, "batches": 0, "replays": 0})
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
        f.set_schema(99);
        assert_eq!(f.read_only(), Some(99));
        let v = serde_json::to_value(f.status()).unwrap();
        assert_eq!(
            (v["read_only"].clone(), v["schema"].clone()),
            (json!(99), json!(99))
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
    async fn the_front_serves_ping_events_env_jobs_and_shutdown() {
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
        f.line(
            &mut s,
            &out,
            r#"{"id":3,"method":"env/set","params":{"env":[]}}"#,
        )
        .await;
        f.line(&mut s, &out, r#"{"method":"ping"}"#).await;
        f.line(&mut s, &out, r#"{"id":5,"method":"job/status"}"#)
            .await;
        assert_eq!(
            answers(&out),
            vec![
                json!({"id": 1, "result": {"pid": std::process::id()}}),
                json!({"id": 2, "result": {"since": 3, "last": 3, "events": []}}),
                json!({"id": 3, "result": {"applied": []}}),
                json!({"id": 5, "result": {"jobs": []}}),
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

    /// Every method that takes empty params reaches its handler: the routing `match` hands no part a method it does
    /// not serve (a part hands such params back, and the answer would be "reached no handler").
    #[tokio::test]
    async fn every_method_reaches_its_handler() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let mut s = Session::new(f.next_conn(), Socket::Main);
        s.class = Class::User;
        let out = Arc::new(Outbox::new(s.conn));
        let mut tried = Vec::new();
        for m in registry::registry() {
            // the stops have a test of their own; a method that needs params is refused before any handler
            if ["shutdown", "restart"].contains(&m.name) || (m.decode)(&json!({})).is_err() {
                continue;
            }
            tried.push(m.name);
            let line = json!({"id": 1, "method": m.name, "params": {}}).to_string();
            tokio::time::timeout(Duration::from_secs(10), f.line(&mut s, &out, &line))
                .await
                .unwrap_or_else(|_| panic!("{} was not answered within 10 s", m.name));
            for a in answers(&out) {
                let message = a["error"]["message"].as_str().unwrap_or_default();
                assert!(!message.contains("reached no handler"), "{}: {a}", m.name);
            }
        }
        // each part is reached: the front's own, the agent core's, the store's and the coordination writes
        for name in ["ping", "agents/list", "graph/backup", "coord/prune"] {
            assert!(tried.contains(&name), "{name} not tried: {tried:?}");
        }
    }

    #[test]
    fn status_has_the_gateways_numbers_and_no_backend() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let v = serde_json::to_value(f.status()).unwrap();
        assert!(v.get("backend").is_none(), "{v}");
        // the gateway's numbers are the front's own, counted since start; the Lisp hub's keys are gone; a front no
        // one hardened (`serve` does, review m2) refuses keys and says so
        assert_eq!(
            v["gateway"],
            json!({"registrations": 0, "requests": 0, "errors": 0, "fallbacks": 0, "bytes_in": 0,
                   "bytes_out": 0, "providers": 0, "keys_held": [], "warnings": [],
                   "keys_refused": "the hub was not hardened"})
        );
        assert!(
            v.get("gateway_port").is_none() && v.get("registrations").is_none(),
            "{v}"
        );
        let m = registry::find("status").unwrap();
        assert_eq!((m.check_result)(&v).unwrap(), v);
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

    #[tokio::test]
    async fn the_hubs_end_closes_a_connection_handed_to_mcp() {
        use tokio::io::AsyncReadExt;
        let dir = tempfile::tempdir().unwrap();
        let f = Arc::new(front(dir.path()));
        // a connection `mcp/attach` handed on: no longer in the front's registry, served as MCP
        let (hub_side, mut bridge) = tokio::net::UnixStream::pair().unwrap();
        let (r, w) = hub_side.into_split();
        let who = norn::tools::Identity::outside("claude", std::process::id(), None, None).unwrap();
        let served = {
            let f = f.clone();
            tokio::spawn(async move { f.mcp.serve_outside(who, r, w).await })
        };
        f.end_connections().await;
        // the bridge reads its end of file at the hub's end, not at the process's exit (the bound is only the failure)
        let mut buf = [0u8; 64];
        let n = tokio::time::timeout(Duration::from_secs(10), bridge.read(&mut buf))
            .await
            .expect("the hub's end closes the bridge's connection")
            .unwrap();
        assert_eq!(n, 0, "{:?}", &buf[..n]);
        served.await.unwrap();
        assert_eq!(f.mcp.status().outside, 0);
    }

    /// The `Params` variants `Front::line` (in FRONT, its source) hands to the handler it calls as CALL: the
    /// `p @ (Params::A(_) | …)` group whose arm calls it.
    fn routed<'a>(front: &'a str, call: &str) -> Vec<&'a str> {
        let at = front
            .find(call)
            .unwrap_or_else(|| panic!("front.rs calls no {call}"));
        let group = front[..at]
            .rfind("p @ (")
            .unwrap_or_else(|| panic!("no group before {call}"));
        variants(&front[group..at])
    }

    /// Each `Params::NAME` TEXT names, in order.
    fn variants(text: &str) -> Vec<&str> {
        text.match_indices("Params::")
            .map(|(i, m)| {
                let rest = &text[i + m.len()..];
                let end = rest
                    .find(|c: char| !c.is_ascii_alphanumeric())
                    .unwrap_or(rest.len());
                &rest[..end]
            })
            .collect()
    }

    /// The variants of ROUTED that the `serve` in HANDLER (a module's source) has no arm for: they would reach no
    /// handler at run time.
    fn unarmed<'a>(routed: &[&'a str], handler: &str) -> Vec<&'a str> {
        let start = handler
            .find("pub async fn serve(")
            .expect("the module has its serve");
        let body = &handler[start..];
        let body = &body[..body.find("\n}\n").unwrap_or(body.len())];
        routed
            .iter()
            .copied()
            .filter(|v| !body.contains(&format!("Params::{v}(")))
            .collect()
    }

    #[test]
    fn every_method_the_front_hands_on_has_an_arm_where_it_goes() {
        let front = include_str!("front.rs");
        let (front, _) = front
            .split_once("#[cfg(test)]\nmod tests")
            .expect("front.rs has its tests");
        let handlers = [
            ("crate::agent_core::serve(", include_str!("agent_core.rs")),
            ("crate::graph::serve(", include_str!("graph.rs")),
            ("coord::serve(&self.writer", include_str!("coord.rs")),
        ];
        let mut all = Vec::new();
        for (call, src) in handlers {
            let routed = routed(front, call);
            assert!(routed.len() > 10, "{call}: {routed:?}");
            assert_eq!(unarmed(&routed, src), Vec::<&str>::new(), "{call}");
            all.extend(routed);
        }
        // every method of the registry decodes to a variant `line` names (its match is exhaustive: the compiler
        // checks the rest)
        for v in Params::VARIANTS {
            assert!(
                all.contains(v) || front.contains(&format!("Params::{v}(")),
                "{v}"
            );
        }
        // the check bites: a variant routed to a handler with no arm for it
        let doctored =
            "pub async fn serve(\n    Ok(match p {\n        Params::A(p) => 1,\n    })\n}\n";
        assert_eq!(unarmed(&["A", "B"], doctored), ["B"]);
    }
}
