//! `serve`: the start order (review I2), the accept loop and the stop.
//!
//! 1. the SQLite floor (3.51.3);
//! 2. the socket's directory made private (`private_dir`), and `<state>/hub` and its `log/`, then logging;
//! 3. the lock ([`crate::lock`]); signals are caught from here on;
//! 4. only while holding it: a stale socket removed, the cap written (0600, temp + rename), the socket bound and made
//!    0600;
//! 5. `runtime.db`.
//!
//! It serves until SIGTERM, SIGINT or the `--parent-pid` process is gone (checked each second), then stops accepting
//! and removes the socket and the cap while the lock is still held.

use crate::cli::ServeArgs;
use crate::conn::{self, Shared};
use crate::lock::{self, LockError};
use crate::{Exit, log, runtime_db};
use drgnx_proto::paths::{self, Env};
use drgnx_proto::proof::Cap;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UnixListener;
use tokio::signal::unix::{SignalKind, signal};

/// `sqlite3_libversion_number()` Ratatoskr needs: 3.51.3.
pub const SQLITE_FLOOR: i32 = 3_051_003;

pub async fn run(args: ServeArgs) -> Exit {
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
    let store = match runtime_db::open(&hub_dir) {
        Ok((store, _handle)) => store,
        Err(e) => {
            tracing::error!("cannot start: {e}");
            drop(listener);
            remove(&socket, &cap_path);
            return Exit::CannotStart;
        }
    };
    let shared = Arc::new(Shared::new(cap));
    tracing::info!(
        pid = shared.pid,
        commit = crate::version::COMMIT,
        "serving on {}",
        socket.display()
    );

    let mut parent = args.parent_pid.map(|p| {
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
                    tokio::spawn(conn::serve(stream, shared.clone()));
                }
                Err(e) => {
                    // out of descriptors, for example: never a hot loop
                    tracing::warn!("accept failed: {e}");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            },
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
    // the lock is still held: these are ours
    remove(&socket, &cap_path);
    let _ = tokio::task::spawn_blocking(move || store.shutdown()).await;
    drop(lock);
    exit
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
