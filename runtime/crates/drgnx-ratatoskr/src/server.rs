//! `serve`: the start order (review I2), the accept loop and the stop.
//!
//! 1. the SQLite floor (3.51.3);
//! 2. the socket's directory made private (`private_dir`), and `<state>/hub` and its `log/`, then logging;
//! 3. the lock ([`crate::lock`]); signals are caught from here on; the process made not dumpable ([`harden`]: no core
//!    file, no `ptrace` or `/proc/PID/mem` of it by another process of the user), before a key can reach it;
//! 4. only while holding it: a stale socket removed, the cap written (0600, temp + rename), the socket bound and made
//!    0600, and the agent sockets (test-hooks) bound as `s/SID/hub.sock`, each session's dir private and apart from
//!    the backend's `hub-HASH.d/` (review M10);
//! 5. `runtime.db`, then the read-only `work.db` reader, whose schema is read now and at each 2 s tick, and the
//!    store (`open_store`): the graph writer with `norn::migrate7`'s opening rule (a missing file made at schema 7,
//!    a schema-6 one migrated after a checked copy), waited for, so a migration ends before the first request; the
//!    coordination writer (`norn::store::CoordDb`) on the same file, and the graph store the tools use
//!    ([`crate::coord`]);
//! 6. the processes `runtime.db` recorded reaped, then the Lisp backend started (and kept running) on its own socket,
//!    the sessions' `mcp.sock` of live owners bound again ([`crate::sessions`]; their owners watched each second),
//!    the gateway listening on 127.0.0.1 and its registrations of live owners kept ([`crate::gateway`]; pruned each
//!    second), the `events` broadcaster and the `coord/notify` coalescer.
//!
//! Every socket is close-on-exec (Rust's default, tested), so no child (the backend, an agent) inherits a listener.
//!
//! It serves until SIGTERM, SIGINT, `shutdown` or the `--parent-pid` process is gone (checked each second), then
//! stops accepting and removes the sockets (the sessions' too; their rows stay) and the cap while the lock is still
//! held.

use crate::backend::{self, Backend};
use crate::cli::{AgentSocket, ServeArgs, Supervisor};
use crate::conn;
use crate::coord;
use crate::forward::ToBackend;
use crate::front::Front;
use crate::gateway;
use crate::hello::Socket;
use crate::idle;
use crate::lock::{self, LockError};
use crate::relay;
use crate::sessions;
use crate::store::WorkDb;
use crate::{Exit, log, runtime_db};
use runstav::paths::{self, Env};
use runstav::proof::Cap;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UnixListener;
use tokio::signal::unix::{SignalKind, signal};

/// `sqlite3_libversion_number()` Ratatoskr needs: 3.51.3.
pub const SQLITE_FLOOR: i32 = 3_051_003;

/// How often work.db's schema is read (read-only while it is newer).
pub const SCHEMA_TICK: Duration = Duration::from_secs(2);

/// How long the stop waits for the backend to end (its group gets SIGKILL 2 s after SIGTERM).
const BACKEND_STOP: Duration = Duration::from_secs(10);

pub async fn run(args: ServeArgs) -> Exit {
    // the executable's path, once, while it still names the file on disk (restart-when-idle, re-exec)
    if let Err(e) = idle::resolve_exe() {
        eprintln!("ratatoskr: cannot resolve its own path ({e}): restart-when-idle is off");
    }
    if let Err(e) = urdr::check_floor(SQLITE_FLOOR) {
        let have = urdr::sqlite_version_number();
        eprintln!(
            "ratatoskr: cannot start: SQLite {}.{}.{} is below 3.51.3 ({e})",
            have / 1_000_000,
            have / 1000 % 1000,
            have % 1000
        );
        return Exit::CannotStart;
    }
    let env = Env::process();
    let socket = paths::socket_path(&env);
    let hub_dir = paths::state_dir(&env).join("hub");
    let log_dir = hub_dir.join("log");
    for dir in [
        socket.parent().unwrap_or(Path::new("/")),
        &hub_dir,
        &log_dir,
    ] {
        if let Err(e) = paths::private_dir(dir) {
            eprintln!("ratatoskr: cannot start: {e}");
            return Exit::CannotStart;
        }
    }
    let _log = match log::init(&log_dir) {
        Ok(g) => g,
        Err(e) => {
            eprintln!(
                "ratatoskr: cannot start: the log in {}: {e}",
                log_dir.display()
            );
            return Exit::CannotStart;
        }
    };
    let lock_path = paths::lock_path(&socket);
    let lock = match lock::acquire(&lock_path, &lock::System) {
        Ok(l) => l,
        Err(LockError::LispHub { pid }) => {
            tracing::error!(pid, "{}", lock::LISP_HUB_SERVES);
            return Exit::AnotherHub;
        }
        Err(LockError::Held) => {
            tracing::error!("another hub serves here ({})", socket.display());
            return Exit::AnotherHub;
        }
        Err(LockError::Io(e)) => {
            tracing::error!("cannot start: the lock {}: {e}", lock_path.display());
            return Exit::CannotStart;
        }
    };
    let (mut term, mut int) = match (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
    ) {
        (Ok(t), Ok(i)) => (t, i),
        (Err(e), _) | (_, Err(e)) => {
            tracing::error!("cannot start: no signal handler: {e}");
            return Exit::CannotStart;
        }
    };
    let hardened = harden();
    let cap_path = paths::cap_path(&socket);
    let (listener, cap) = match bind(&socket, &cap_path) {
        Ok(x) => x,
        Err(e) => {
            tracing::error!("cannot start: {e}");
            remove(&socket, &cap_path);
            return Exit::CannotStart;
        }
    };
    // the agent sockets (test-hooks: `--agent-socket SID[:JOB]`), bound under the lock too
    let (mut agents, mut agent_paths) = (Vec::new(), Vec::new());
    for a in &args.agent_sockets {
        match bind_agent(&env, &socket, a) {
            Ok((dir, l, s)) => {
                agent_paths.push(dir);
                agents.push((l, s));
            }
            Err(e) => {
                tracing::error!("cannot start: {e}");
                remove_all(&agent_paths);
                remove(&socket, &cap_path);
                return Exit::CannotStart;
            }
        }
    }
    let (store, runtime) = match runtime_db::open(&hub_dir) {
        Ok(x) => x,
        Err(e) => {
            tracing::error!("cannot start: {e}");
            drop(listener);
            remove_all(&agent_paths);
            remove(&socket, &cap_path);
            return Exit::CannotStart;
        }
    };
    let work_db = match WorkDb::spawn(paths::data_dir(&env).join("work.db")) {
        Ok(w) => w,
        Err(e) => {
            tracing::error!("cannot start: no work.db reader: {e}");
            remove_all(&agent_paths);
            remove(&socket, &cap_path);
            return Exit::CannotStart;
        }
    };
    // the graph writer: work.db made at schema 7, or a schema-6 file migrated, before anything is served
    let (graph_writer, graph, coord_db, home) = match open_store(&env).await {
        Ok(x) => x,
        Err(e) => {
            tracing::error!("cannot start: no work.db writer: {e}");
            remove_all(&agent_paths);
            remove(&socket, &cap_path);
            return Exit::CannotStart;
        }
    };
    // what a crashed run left (its backend's group): killed before a new backend starts
    if let Err(e) = backend::reap_recorded(&runtime).await {
        tracing::warn!("{e}");
    }
    let (events_tx, events_rx) = tokio::sync::mpsc::channel(relay::QUEUE);
    let backend = new_backend(&env, &socket, runtime.clone(), events_tx);
    let front = Arc::new(Front::with_graph(
        cap,
        socket.clone(),
        work_db,
        coord_db,
        Some(graph),
        Arc::new(ToBackend(backend.clone())),
    ));
    front.tool_hub.bind(&front);
    let _ = front.dirs.set(crate::graph::StoreDirs {
        home,
        config: paths::config_dir(&env),
        hub: hub_dir.clone(),
    });
    // before anything is served: a hub that could not be hardened takes no key
    front.gate.set_hardened(hardened);
    #[cfg(feature = "test-hooks")]
    front
        .ignore_shutdown
        .store(args.ignore_shutdown, std::sync::atomic::Ordering::Relaxed);
    #[cfg(feature = "test-hooks")]
    let gateway_port = args.gateway_port;
    #[cfg(not(feature = "test-hooks"))]
    let gateway_port = None;
    // the sessions' sockets: those of live owners bound again (a bridge redials the same path), before serving
    front
        .mcp
        .open_store(env.clone(), socket.clone(), runtime.clone());
    front.mcp.restore().await;
    front.core.agents.open_store(runtime.clone());
    tokio::spawn(sessions::watch(front.clone()));
    // a job's end wakes the session that started it
    tokio::spawn(crate::agents::wake::run(front.clone()));
    // settings.el and the shipped defaults, as data, before anything is served (its last good values in runtime.db)
    front
        .settings
        .open(paths::config_dir(&env), runtime.clone());
    front.refresh_settings().await;
    // the sessions recorded before this start: resumed (their profiles are in the settings now), queues delivered
    // (in the background: a slow agent never delays serving)
    {
        let f = front.clone();
        tokio::spawn(async move { f.core.agents.resume_all(&f).await });
    }
    // the gateway: listening, then the registrations of live owners (and their sessions' sockets) kept
    front.gate.open_store(runtime);
    match front.gate.listen(gateway_port).await {
        Ok(events) => {
            front.gate.restore(&front.mcp).await;
            tokio::spawn(gateway::run_events(events, front.clone()));
            tokio::spawn(gateway::watch(front.clone()));
        }
        Err(e) => tracing::error!("the gateway does not listen: {e}"),
    }
    // read-only at start and at each tick while work.db is newer than this hub
    front.set_schema(front.work_db.schema().await.unwrap_or(0));
    front.note_migration(
        front
            .work_db
            .meta(norn::migrate7::REPORT_KEY)
            .await
            .ok()
            .flatten()
            .as_deref(),
    );
    tokio::spawn(watch_schema(front.clone()));
    tokio::spawn(relay::run(events_rx, front.clone()));
    tokio::spawn(coord::broadcast_events(front.clone()));
    tokio::spawn(coord::notify_backend(front.clone()));
    let supervisor = tokio::spawn(backend.clone().supervise());
    #[cfg(feature = "test-hooks")]
    let tick = args.idle_tick_ms.map_or(idle::TICK, Duration::from_millis);
    #[cfg(not(feature = "test-hooks"))]
    let tick = idle::TICK;
    tokio::spawn(idle::run(front.clone(), backend.clone(), tick));
    for (l, s) in agents {
        tokio::spawn(accept(l, front.clone(), s));
    }
    tracing::info!(
        pid = front.pid,
        commit = crate::version::COMMIT,
        "serving on {}",
        socket.display()
    );

    // `--parent-pid`, else `DRGNX_HUB_PARENT_PID` (the Lisp hub's name for it): tests end a hub with their process
    let parent_pid = args.parent_pid.or_else(|| {
        env.vars
            .get("DRGNX_HUB_PARENT_PID")
            .and_then(|p| p.parse().ok())
            .filter(|p| *p > 0)
    });
    let mut parent = parent_pid.map(|p| {
        let mut every = tokio::time::interval(Duration::from_secs(1));
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        (p, every)
    });
    let exit = loop {
        let parent_gone = async {
            match &mut parent {
                Some((pid, every)) => loop {
                    every.tick().await;
                    if !lock::alive(*pid) {
                        return *pid;
                    }
                },
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            a = listener.accept() => match a {
                Ok((stream, _)) => {
                    tokio::spawn(conn::serve(stream, front.clone(), Socket::Main));
                }
                Err(e) => {
                    // out of descriptors, for example: never a hot loop
                    tracing::warn!("accept failed: {e}");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            },
            how = front.stopped() => {
                tracing::info!(exit = how as u8, "shutdown or restart asked: stopping");
                break how;
            }
            _ = term.recv() => {
                tracing::info!("SIGTERM: stopping");
                break Exit::Stopped;
            }
            _ = int.recv() => {
                tracing::info!("SIGINT: stopping");
                break Exit::Stopped;
            }
            pid = parent_gone => {
                tracing::info!(parent = pid, "the parent process is gone: stopping");
                break Exit::Stopped;
            }
        }
    };
    drop(listener);
    // the backend stopped (its group: SIGTERM, then SIGKILL) and its row gone, while runtime.db is still open
    backend.stop();
    if tokio::time::timeout(BACKEND_STOP, supervisor)
        .await
        .is_err()
    {
        tracing::warn!("the Lisp backend did not stop within 10 s");
    }
    // the hub's own sessions end with it (their rows, transcripts and queues stay for the next start)
    front.core.agents.shutdown().await;
    // the lock is still held: these are ours (the sessions' rows stay for the next start)
    front.mcp.unbind_all();
    remove_all(&agent_paths);
    remove(&socket, &cap_path);
    let _ = tokio::task::spawn_blocking(move || store.shutdown()).await;
    let _ = tokio::task::spawn_blocking(move || graph_writer.shutdown()).await;
    if exit == Exit::Restart && args.supervisor == Supervisor::SelfDetached {
        // nothing supervises this hub, so `main` executes the binary again: the lock stays held until the exec
        // closes it (every descriptor is close-on-exec), and the new image takes it
        tracing::info!(
            "restart: executing {} again",
            idle::start_exe().map_or_else(String::new, |p| p.display().to_string())
        );
        std::mem::forget(lock);
    } else {
        drop(lock);
    }
    exit
}

/// The process made not dumpable, before it holds a key (design §6.2): no core file, and no other process of the user
/// may `ptrace` it or read its memory.  Linux and Android: `PR_SET_DUMPABLE 0`; macOS: `PT_DENY_ATTACH` (it fails
/// when the hub was started under a debugger or tracer); elsewhere nothing can be done.  An `Err` says why: the hub
/// then serves, but refuses every key (`Gate::set_hardened`, fail closed), and `status`/`doctor` say so.
pub fn harden() -> Result<(), String> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let r = rustix::process::set_dumpable_behavior(rustix::process::DumpableBehavior::NotDumpable)
        .map_err(|e| format!("cannot make the hub not dumpable: {e}"));
    #[cfg(target_os = "macos")]
    let r = {
        // SAFETY: PT_DENY_ATTACH takes no address or data
        let denied = unsafe { libc::ptrace(libc::PT_DENY_ATTACH, 0, std::ptr::null_mut(), 0) };
        if denied != 0 {
            Err(format!(
                "cannot deny debuggers the hub: {}",
                std::io::Error::last_os_error()
            ))
        } else {
            Ok(())
        }
    };
    #[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
    let r = Err("this platform cannot keep other processes out of the hub's memory".to_string());
    if let Err(why) = &r {
        tracing::warn!("{why}: provider keys are refused");
    }
    r
}

/// The Lisp backend for this hub (its socket's directory made private here, under the lock), its events to EVENTS;
/// `missing` when there is no command or no socket path for it.
fn new_backend(
    env: &Env,
    socket: &Path,
    runtime: urdr::Handle,
    events: tokio::sync::mpsc::Sender<(String, serde_json::Value)>,
) -> Arc<Backend> {
    let get = |k: &str| env.vars.get(k).cloned();
    let program = backend::program(
        &get,
        &paths::data_dir(env),
        &paths::config_dir(env),
        backend::CHECKOUT,
    );
    // its directory only for a backend that can start
    let serve = paths::backend_socket_path(env, socket)
        .map_err(|e| e.to_string())
        .and_then(|p| match &program {
            Err(_) => Ok(p),
            Ok(_) => {
                let dir = p.parent().unwrap_or(Path::new("/"));
                paths::private_dir(dir)
                    .and_then(|()| paths::trusted_dir(dir))
                    .map(|_| p.clone())
                    .map_err(|e| format!("its socket's directory: {e}"))
            }
        });
    let home = PathBuf::from(get("HOME").unwrap_or_else(|| "/".into()));
    Backend::new(program, serve, home, runtime, events)
}

/// Accept on an agent socket for as long as the hub serves.
async fn accept(listener: UnixListener, front: Arc<Front>, socket: Socket) {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(conn::serve(stream, front.clone(), socket.clone()));
            }
            Err(e) => {
                tracing::warn!("accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// The store at start (Urdr Task 11): the data dir made when missing, the graph writer spawned on `<data>/work.db` with
/// the migration's opening rule (`norn::migrate7`: a missing file made at schema 7, a schema-6 one migrated after a
/// checked copy in `<data>/backup/`), and its first answer waited for, so a migration ends before the first request;
/// then the coordination store on the same file, and the graph store the tools use (a read pool, the deny-list).  A
/// migration that failed or waits is no reason not to start: writes answer its text, `status.store` and the doctor
/// say why.
async fn open_store(
    env: &Env,
) -> Result<
    (
        urdr::graph::Writer,
        norn::tools::GraphStore,
        norn::store::CoordDb,
        PathBuf,
    ),
    String,
> {
    let data = paths::data_dir(env);
    // made 0700 when missing; one that is there (perhaps a link the user made) is used as it is
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&data)
        .map_err(|e| format!("{}: {e}", data.display()))?;
    let home = env
        .vars
        .get("HOME")
        .filter(|h| Path::new(h).is_absolute())
        .map(PathBuf::from)
        .ok_or("HOME is not set to an absolute path: the personal-notes deny-list needs it")?;
    let config = paths::config_dir(env);
    let path = data.join("work.db");
    crate::backup_timer::seed(&data.join("backup"));
    let opts = norn::migrate7::MigrateOpts {
        backup_dir: data.join("backup"),
        home: home.clone(),
        config_dir: config.clone(),
    };
    let mut guard = urdr::graph::guard::Guard::default();
    norn::grants::register(&mut guard);
    let (writer, handle) = urdr::graph::Writer::spawn(
        &path,
        urdr::graph::WriterOpts {
            guard: Arc::new(guard),
            ..urdr::graph::WriterOpts::default()
        },
        norn::migrate7::open_rule(opts),
    )
    .map_err(|e| e.to_string())?;
    // the writer runs the rule before it serves anything: a tick's answer comes after it
    handle.tick().await;
    match handle.status().last_open {
        Some(urdr::graph::OpenOutcome::Ready { schema }) => {
            tracing::info!(schema, "work.db is open")
        }
        Some(other) => tracing::warn!("work.db is not open for writing: {other:?}"),
        None => {}
    }
    let deny: norn::deny::SharedDeny = Arc::new(std::sync::RwLock::new(Arc::new(
        norn::deny::DenyList::load(&home, &config),
    )));
    let graph = norn::tools::GraphStore {
        writer: handle.clone(),
        pool: urdr::graph::ReadPool::open(&path, 4),
        deny,
    };
    let db = tokio::task::spawn_blocking(move || norn::store::CoordDb::with_graph(handle))
        .await
        .map_err(|e| e.to_string())?;
    Ok((writer, graph, db, home))
}

/// work.db's schema every 2 s: read-only while it is newer than this hub's.  A read that fails keeps the last state.
/// The writer looks at the file too (opened when it is there, again when it was replaced), and the `events`
/// broadcaster sends what the Lisp backend wrote meanwhile (`drgnx-hub--events-check`'s 2 s).
async fn watch_schema(front: Arc<Front>) {
    let mut every = tokio::time::interval(SCHEMA_TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    every.tick().await;
    let mut privacy = norn::privacy::Watch::default();
    let embed = Arc::new(std::sync::Mutex::new(crate::embed::Timer::new(
        std::time::Instant::now(),
    )));
    loop {
        every.tick().await;
        // the graph writer first: it runs its opening rule again while not ready, and on a replaced file
        if let Some(w) = front.writer.db.graph_writer() {
            w.tick().await;
        }
        match front.work_db.schema().await {
            Ok(n) => front.set_schema(n),
            Err(e) => tracing::warn!("cannot read work.db's schema: {e}"),
        }
        if let Ok(report) = front.work_db.meta(norn::migrate7::REPORT_KEY).await {
            front.note_migration(report.as_deref());
        }
        let db = front.writer.db.clone();
        let _ = tokio::task::spawn_blocking(move || db.tick()).await;
        // the personal-notes opt-ins: applied when their file changed (norn::privacy, Task 9b)
        if let (Some(g), Some(d)) = (front.tools.graph(), front.dirs.get())
            && let Some(r) =
                norn::privacy::tick(&mut privacy, &g.writer, &g.deny, &d.home, &d.config).await
        {
            tracing::info!(
                added = r.added.len(),
                removed = r.removed.len(),
                excised = r.excised,
                "the personal-notes opt-ins changed and were applied"
            );
            // said to every editor, whoever changed the files (any process of the user's can: M9b2-11)
            if let Some(text) = r.notice {
                front.broadcast(
                    "notice",
                    serde_json::json!({"source": "hub", "severity": "warn", "id": "privacy-opt-ins",
                                       "life": "event", "text": text}),
                );
            }
            front.writer.signals.notify_soon();
        }
        nightly_backup(&front);
        embed_idle(&front, &embed);
        front.writer.signals.events_soon();
    }
}

/// The entity embedder (`embed`): a round after a quiet minute, when the store is ready and a `tei` provider is in the
/// table.  It never starts the provider; the round runs on its own task.
fn embed_idle(front: &Arc<Front>, timer: &Arc<std::sync::Mutex<crate::embed::Timer>>) {
    let Some(g) = front.tools.graph() else { return };
    let st = g.writer.status();
    if !matches!(st.last_open, Some(urdr::graph::OpenOutcome::Ready { .. })) {
        return;
    }
    let now = std::time::Instant::now();
    let (due, probe) = {
        let mut t = timer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // only writes that put text: the Lisp backend's 60 s housekeeping (leases, events) never does
        let due = t.due(st.texts, now);
        (due, t.probing())
    };
    if !due {
        return;
    }
    let Ok(Some(e)) = front.gate.embedder() else {
        timer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .finish(false, now);
        return;
    };
    let (front, timer, deny) = (
        front.clone(),
        timer.clone(),
        g.deny
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone(),
    );
    tokio::spawn(async move {
        let out = crate::embed::run(&front.writer.db, &e, &deny, probe).await;
        let stopped = matches!(out, crate::embed::Outcome::Stopped { .. });
        match &out {
            crate::embed::Outcome::Stopped { embedded, why } => {
                tracing::info!(embedded, "the embedder stopped: {why}");
            }
            crate::embed::Outcome::Filled { embedded, denied } => {
                tracing::info!(embedded, denied, "entity vectors made");
            }
            crate::embed::Outcome::Nothing => {}
        }
        timer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .finish(stopped, std::time::Instant::now());
    });
}

/// The nightly backup (`backup_timer`): at 03:00 local time, or at the first tick after a missed one, once the store
/// is open and ready and no excise runs.  The copy runs on its own task, so the tick goes on.
fn nightly_backup(front: &Front) {
    let Some(g) = front.tools.graph() else { return };
    let ready = matches!(
        g.writer.status().last_open,
        Some(urdr::graph::OpenOutcome::Ready { .. })
    );
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    if !ready || !crate::backup_timer::due_at(now) || !crate::backup_timer::begin() {
        return;
    }
    let g = g.clone();
    tokio::spawn(async move {
        crate::graph::run_backup(&g).await;
        crate::backup_timer::finish();
    });
}

/// Under the lock: agent socket A at `hub.sock` in its session dir, `<socket dir>/s/SID/` (`paths::make_session_dir`:
/// each level private and checked; a stale socket removed, the socket 0600).  The session dir, which the stop removes.
fn bind_agent(
    env: &Env,
    socket: &Path,
    a: &AgentSocket,
) -> Result<(PathBuf, UnixListener, Socket), String> {
    let dir = paths::make_session_dir(env, socket, &a.sid).map_err(|e| e.to_string())?;
    let path = dir.join(paths::SESSION_HUB_SOCKET);
    match std::fs::remove_file(&path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!(
                "cannot remove the stale socket {}: {e}",
                path.display()
            ));
        }
        _ => {}
    }
    let listener =
        UnixListener::bind(&path).map_err(|e| format!("cannot bind {}: {e}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("cannot chmod {}: {e}", path.display()))?;
    tracing::info!(sid = a.sid, "agent socket {}", path.display());
    let s = Socket::Agent {
        sid: a.sid.clone(),
        job: a.job.clone(),
    };
    Ok((dir, listener, s))
}

/// The session dirs this hub made, with what is in them (under the lock: they are ours).
fn remove_all(dirs: &[PathBuf]) {
    for f in dirs {
        match std::fs::remove_dir_all(f) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                tracing::warn!("cannot remove {}: {e}", f.display());
            }
            _ => {}
        }
    }
}

/// Under the lock: the stale socket removed, the cap written, the socket bound and made 0600.
fn bind(socket: &Path, cap_path: &Path) -> Result<(UnixListener, Cap), String> {
    match std::fs::remove_file(socket) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!(
                "cannot remove the stale socket {}: {e}",
                socket.display()
            ));
        }
        _ => {}
    }
    let cap = Cap::generate().map_err(|e| format!("no cap: {e}"))?;
    write_private(cap_path, cap.expose().as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", cap_path.display()))?;
    let listener =
        UnixListener::bind(socket).map_err(|e| format!("cannot bind {}: {e}", socket.display()))?;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("cannot chmod {}: {e}", socket.display()))?;
    // close-on-exec, and never a child's (call 14)
    draugr::spawn::never_pass(&listener);
    Ok((listener, cap))
}

/// FILE replaced by TEXT atomically: a temporary file beside it (0600 from the start, never a link), then a rename.
fn write_private(file: &Path, text: &[u8]) -> std::io::Result<()> {
    let mut name = file.as_os_str().to_owned();
    name.push(format!(".tmp-{}", std::process::id()));
    let tmp = PathBuf::from(name);
    let _ = std::fs::remove_file(&tmp);
    let written = (|| {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)?;
        f.write_all(text)?;
        f.sync_all()?;
        std::fs::rename(&tmp, file)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

fn remove(socket: &Path, cap: &Path) {
    for f in [socket, cap] {
        match std::fs::remove_file(f) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                tracing::warn!("cannot remove {}: {e}", f.display());
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Whether this process has `CAP_SYS_PTRACE` (bit 19 of `CapEff`), which reads a non-dumpable process anyway.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn has_cap_sys_ptrace() -> bool {
        std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|s| {
                s.lines()
                    .find_map(|l| l.strip_prefix("CapEff:"))
                    .and_then(|v| u64::from_str_radix(v.trim(), 16).ok())
            })
            .is_some_and(|caps| caps & (1 << 19) != 0)
    }

    /// `harden` runs in a forked child, which reports `PR_GET_DUMPABLE` over a pipe: this test binary stays dumpable
    /// (review S6).  With `CAP_SYS_PTRACE` here, the child's view of itself is still checked; the parent's look at the
    /// child's `/proc/PID/exe` (refused for a non-dumpable process) is skipped, with the reason.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn the_hub_is_not_dumpable() {
        use std::io::Read;
        use std::os::fd::FromRawFd;
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: a two-int array, as pipe(2) takes
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: the child calls only async-signal-safe functions (prctl, write, pause) until it is killed
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0, "fork failed");
        if pid == 0 {
            let _ = harden(); // what it did is read back below
            // SAFETY: prctl(PR_GET_DUMPABLE) takes no pointer
            let d = unsafe { libc::prctl(libc::PR_GET_DUMPABLE) } as u8;
            // SAFETY: one byte from a live buffer to the pipe's write end
            unsafe { libc::write(fds[1], (&raw const d).cast(), 1) };
            // wait for the parent to look at us: it kills us after (reading the pipe would take back our own byte)
            loop {
                // SAFETY: pause(2) takes nothing and is async-signal-safe
                unsafe { libc::pause() };
            }
        }
        // the child is killed and reaped however the test ends, a failed assertion below included: a child left in
        // pause() would hold the test's output open, and the run would never end
        struct Reap(libc::pid_t);
        impl Drop for Reap {
            fn drop(&mut self) {
                // SAFETY: SIGKILL to our own child (blocked in pause), then waitpid on it
                unsafe {
                    libc::kill(self.0, libc::SIGKILL);
                    libc::waitpid(self.0, std::ptr::null_mut(), 0);
                }
            }
        }
        let child = Reap(pid);
        // SAFETY: the parent owns its copies of both ends
        let (mut r, w) = unsafe {
            (
                std::fs::File::from_raw_fd(fds[0]),
                std::fs::File::from_raw_fd(fds[1]),
            )
        };
        let mut d = [9u8; 1];
        r.read_exact(&mut d).unwrap();
        assert_eq!(d[0], 0, "the child is not dumpable after harden");
        if has_cap_sys_ptrace() {
            eprintln!(
                "skipped: CAP_SYS_PTRACE is effective here, so /proc/PID/exe of a non-dumpable process reads"
            );
        } else {
            assert!(
                std::fs::read_link(format!("/proc/{pid}/exe")).is_err(),
                "another process reads the hub's /proc/PID/exe"
            );
        }
        drop((r, w));
        drop(child);
        // and this test binary is still dumpable
        // SAFETY: prctl(PR_GET_DUMPABLE) takes no pointer
        assert_eq!(unsafe { libc::prctl(libc::PR_GET_DUMPABLE) }, 1);
    }

    #[tokio::test]
    async fn the_listening_socket_is_cloexec() {
        let dir = tempfile::tempdir().unwrap();
        let (listener, _cap) = bind(
            &dir.path().join("hub-x.sock"),
            &dir.path().join("hub-x.cap"),
        )
        .unwrap();
        let cloexec = |fd: std::os::fd::BorrowedFd<'_>| {
            rustix::io::fcntl_getfd(fd)
                .unwrap()
                .contains(rustix::io::FdFlags::CLOEXEC)
        };
        use std::os::fd::AsFd;
        assert!(cloexec(listener.as_fd()), "the main socket");
        // and the gateway's loopback listener, bound as `Gate::listen` binds it
        let tcp = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        assert!(cloexec(tcp.as_fd()), "the gateway's listener");
    }
}
