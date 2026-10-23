//! `serve`: the start order (review I2), the accept loop and the stop.
//!
//! 1. the SQLite floor (3.51.3);
//! 2. the socket's directory made private (`private_dir`), and `<state>/hub` and its `log/`, then logging;
//! 3. the lock ([`crate::lock`]); signals are caught from here on;
//! 4. only while holding it: a stale socket removed, the cap written (0600, temp + rename), the socket bound and made
//!    0600, and the agent sockets (test-hooks) bound as `s/SID/hub.sock`, each session's dir private and apart from
//!    the backend's `hub-HASH.d/` (review M10);
//! 5. `runtime.db`, then the read-only `work.db` reader, whose schema is read now and at each 2 s tick, and the
//!    writer (`norn::store::CoordDb`), which opens a schema-6 file now and at each tick ([`crate::coord`]);
//! 6. the processes `runtime.db` recorded reaped, then the Lisp backend started (and kept running) on its own socket,
//!    the sessions' `mcp.sock` of live owners bound again ([`crate::sessions`]; their owners watched each second),
//!    the `events` broadcaster and the `coord/notify` coalescer.
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
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
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
    // the writer: a blocking first look at the file, before anything is served
    let coord_db = {
        let path = paths::data_dir(&env).join("work.db");
        match tokio::task::spawn_blocking(move || norn::store::CoordDb::spawn(path)).await {
            Ok(db) => db,
            Err(e) => {
                tracing::error!("cannot start: no work.db writer: {e}");
                remove_all(&agent_paths);
                remove(&socket, &cap_path);
                return Exit::CannotStart;
            }
        }
    };
    // what a crashed run left (its backend's group): killed before a new backend starts
    if let Err(e) = backend::reap_recorded(&runtime).await {
        tracing::warn!("{e}");
    }
    let (events_tx, events_rx) = tokio::sync::mpsc::channel(relay::QUEUE);
    let backend = new_backend(&env, &socket, runtime.clone(), events_tx);
    let front = Arc::new(Front::new(
        cap,
        socket.clone(),
        work_db,
        coord_db,
        Arc::new(ToBackend(backend.clone())),
    ));
    // the sessions' sockets: those of live owners bound again (a bridge redials the same path), before serving
    front.mcp.open_store(env.clone(), socket.clone(), runtime);
    front.mcp.restore().await;
    tokio::spawn(sessions::watch(front.clone()));
    // read-only at start and at each tick while work.db is newer than this hub
    front.set_schema(front.work_db.schema().await.unwrap_or(0));
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
    // the lock is still held: these are ours (the sessions' rows stay for the next start)
    front.mcp.unbind_all();
    remove_all(&agent_paths);
    remove(&socket, &cap_path);
    let _ = tokio::task::spawn_blocking(move || store.shutdown()).await;
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

/// work.db's schema every 2 s: read-only while it is newer than this hub's.  A read that fails keeps the last state.
/// The writer looks at the file too (opened when it is there, again when it was replaced), and the `events`
/// broadcaster sends what the Lisp backend wrote meanwhile (`drgnx-hub--events-check`'s 2 s).
async fn watch_schema(front: Arc<Front>) {
    let mut every = tokio::time::interval(SCHEMA_TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    every.tick().await;
    loop {
        every.tick().await;
        match front.work_db.schema().await {
            Ok(n) => front.set_schema(n),
            Err(e) => tracing::warn!("cannot read work.db's schema: {e}"),
        }
        let db = front.writer.db.clone();
        let _ = tokio::task::spawn_blocking(move || db.tick()).await;
        front.writer.signals.events_soon();
    }
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
