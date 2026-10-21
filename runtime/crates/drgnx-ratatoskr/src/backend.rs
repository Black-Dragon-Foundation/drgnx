//! The Lisp backend (design 8.2): the Lisp hub, run as Ratatoskr's child on a private socket of its own, which serves
//! every method the front does not.
//!
//! - **The command:** `DRGNX_RATATOSKR_BACKEND` (an absolute executable; tests) when set, else `EMACS --batch -Q --eval
//!   "(setq load-prefer-newer t)" -L DRGNX/core -l drgnx-hub -f drgnx-hub-main`, EMACS being `DRGNX_EMACS` or the
//!   Emacs install.sh recorded (`drgnx-paths-recorded-emacs`), DRGNX `DRGNX_DIR` or the checkout the binary was built
//!   from.  Without either the backend is `missing` and every forwarded call `internal`.
//! - **Its environment:** only [`ENV_ALLOW`] (and `LC_*`), so a provider key never reaches it; plus
//!   `DRGNX_HUB_SERVE_SOCKET` (where it serves, which `drgnx-hub-main` reads and unsets) and `DRGNX_HUB_PARENT_PID`.
//! - **Its record:** a `proc` row (purpose `backend`) is inserted before the spawn and given the pid, start time and
//!   group right after it; it goes when the exit is seen.  At start every recorded row is reaped ([`reap_recorded`]).
//! - **One connection** to it (its peer checked: our uid and the child's pid), on which the front subscribes once and
//!   sends every call as `{id, method, params, caller}`; answers come back by id, events are relayed.
//! - **Its life:** it must answer `ping` within 10 s; when it exits (or its connection ends) the calls in flight fail
//!   once ("the Lisp backend restarted") and it starts again after 1 s, doubling to 30 s.

use crate::dispatch::BackendInfo;
use bytes::BytesMut;
use draugr::{self as proc, RealSignaller, Record};
use runstav::line::MAX_HUB_LINE;
use runstav::methods::hub::{Backend as BackendStatus, BackendState};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{Instant, timeout};
use tokio_util::codec::{Decoder, LinesCodec};
use zeroize::Zeroizing;

/// How long the backend has to answer `ping` on its socket after it was started.
pub const READY_WITHIN: Duration = Duration::from_secs(10);
/// A forwarded call's deadline.
pub const CALL_DEADLINE: Duration = Duration::from_secs(30);
/// How long `status` waits for the backend's own `status`.
pub const STATUS_DEADLINE: Duration = Duration::from_secs(1);
/// How long restart-when-idle waits for each of the backend's two lists.
pub const IDLE_DEADLINE: Duration = Duration::from_secs(2);
/// The first wait before a restart, doubled after each early exit up to [`BACKOFF_MAX`].
pub const BACKOFF_FIRST: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// A backend that served this long before it exited restarts after [`BACKOFF_FIRST`] again.
pub const HEALTHY_AFTER: Duration = Duration::from_secs(30);

/// The names of Ratatoskr's environment the backend gets, each when set (review I7): the dirs and the session,
/// drgnx's own, and what agents and git use on main.  Nothing else, so no provider key reaches it.
pub const ENV_ALLOW: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LANGUAGE",
    "TZ",
    "TMPDIR",
    "TMP",
    "TEMP",
    "XDG_RUNTIME_DIR",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "DRGNX_DATA_DIR",
    "DRGNX_CONFIG_DIR",
    "DRGNX_EMACS",
    "DRGNX_DIR",
    "DRGNX_JOBS_LAUNCHER",
    "DRGNX_NO_LANGUAGE_SERVERS",
    "SSH_AUTH_SOCK",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "CLAUDE_CONFIG_DIR",
    "TERM",
    "COLORTERM",
    "DISPLAY",
    "WAYLAND_DISPLAY",
];

/// The prefixes the backend's environment keeps.
pub const ENV_PREFIXES: &[&str] = &["LC_"];

/// What a test backend (`DRGNX_RATATOSKR_BACKEND`) gets besides: its script and the like.
pub const FAKE_PREFIX: &str = "DRGNX_FAKE_BACKEND_";

/// The checkout the binary was built from (install.sh and `drgnx update` set it; empty otherwise).
pub const CHECKOUT: &str = env!("DRGNX_CHECKOUT");

/// How the backend is started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Program {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    /// `DRGNX_RATATOSKR_BACKEND`'s: it gets the `DRGNX_FAKE_BACKEND_*` variables too.
    pub test_backend: bool,
}

/// The backend's command, from the variables GET reads, the data and config dirs and the build's CHECKOUT; or why
/// there is none.
pub fn program(
    get: &dyn Fn(&str) -> Option<String>,
    data: &Path,
    config: &Path,
    checkout: &str,
) -> Result<Program, String> {
    let set = |name: &str| get(name).filter(|v| !v.is_empty());
    if let Some(b) = set("DRGNX_RATATOSKR_BACKEND") {
        if !b.starts_with('/') {
            return Err(format!(
                "DRGNX_RATATOSKR_BACKEND is not an absolute name: {b}"
            ));
        }
        return Ok(Program {
            program: b.into(),
            args: vec![],
            test_backend: true,
        });
    }
    let emacs = set("DRGNX_EMACS")
        .filter(|e| e.starts_with('/'))
        .map(PathBuf::from)
        .or_else(|| [data, config].iter().find_map(|d| recorded_emacs(d)))
        .ok_or(
            "no Emacs: set DRGNX_EMACS, or let install.sh record one in the data dir's emacs file",
        )?;
    let drgnx = set("DRGNX_DIR")
        .filter(|d| d.starts_with('/'))
        .or_else(|| Some(checkout.to_string()).filter(|c| c.starts_with('/')))
        .ok_or("no drgnx checkout: set DRGNX_DIR")?;
    let core = Path::new(&drgnx).join("core");
    let args: Vec<OsString> = [
        OsStr::new("--batch"),
        OsStr::new("-Q"),
        OsStr::new("--eval"),
        OsStr::new("(setq load-prefer-newer t)"),
        OsStr::new("-L"),
        core.as_os_str(),
        OsStr::new("-l"),
        OsStr::new("drgnx-hub"),
        OsStr::new("-f"),
        OsStr::new("drgnx-hub-main"),
    ]
    .iter()
    .map(|a| a.to_os_string())
    .collect();
    Ok(Program {
        program: emacs,
        args,
        test_backend: false,
    })
}

/// `drgnx-paths-recorded-emacs` for one dir: the first line of DIR/emacs, trimmed, when it names an executable file.
fn recorded_emacs(dir: &Path) -> Option<PathBuf> {
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;
    let mut text = String::new();
    std::fs::File::open(dir.join("emacs"))
        .ok()?
        .take(4096)
        .read_to_string(&mut text)
        .ok()?;
    let line = text.lines().next()?.trim();
    if !line.starts_with('/') {
        return None;
    }
    let meta = std::fs::metadata(line).ok()?;
    (meta.is_file() && meta.permissions().mode() & 0o111 != 0).then(|| PathBuf::from(line))
}

/// The backend's whole environment: [`ENV_ALLOW`] and [`ENV_PREFIXES`] from ours (a test backend's
/// `DRGNX_FAKE_BACKEND_*` too), then the socket it serves on and our pid.
pub fn environment(
    test_backend: bool,
    serve_socket: &Path,
    parent: u32,
) -> Vec<(OsString, OsString)> {
    let mut prefixes = ENV_PREFIXES.to_vec();
    if test_backend {
        prefixes.push(FAKE_PREFIX);
    }
    let parent = parent.to_string();
    proc::env::build(
        ENV_ALLOW,
        &prefixes,
        &[
            ("DRGNX_HUB_SERVE_SOCKET", serve_socket.as_os_str()),
            ("DRGNX_HUB_PARENT_PID", OsStr::new(&parent)),
        ],
    )
}

fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

fn restarted() -> Error {
    internal("the Lisp backend restarted")
}

/// Reap every process the `proc` rows of `runtime.db` name (`draugr::reap`'s rules: a row without a pid is
/// skipped, never signalled), then delete them all.  At start, before the backend is spawned.
pub async fn reap_recorded(db: &urdr::Handle) -> Result<(), String> {
    let rows: Vec<Record> = db
        .read(|c| {
            let mut st = c.prepare("select pid, start_time, pgid, boot_id from proc")?;
            let rows = st
                .query_map([], |r| {
                    let int = |i: usize| r.get::<_, Option<i64>>(i).ok().flatten();
                    Ok(Record {
                        pid: int(0).and_then(|p| i32::try_from(p).ok()),
                        start_time: int(1).and_then(|t| u64::try_from(t).ok()),
                        pgid: int(2).and_then(|p| i32::try_from(p).ok()),
                        boot_id: r.get::<_, Option<String>>(3).ok().flatten(),
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(|e| format!("cannot read runtime.db's processes: {e}"))?;
    let outcomes = proc::reap(&rows, &RealSignaller).await;
    for (r, o) in rows.iter().zip(&outcomes) {
        if *o == proc::ReapOutcome::Killed {
            tracing::warn!(pid = ?r.pid, pgid = ?r.pgid, "killed an orphan a crashed hub left");
        } else {
            tracing::info!(pid = ?r.pid, outcome = ?o, "a recorded process");
        }
    }
    db.write(|c| Ok(c.execute("delete from proc", [])?))
        .await
        .map_err(|e| format!("cannot clear runtime.db's processes: {e}"))?;
    Ok(())
}

/// The one connection to a running backend.
pub struct Link {
    pid: i32,
    writer: tokio::sync::Mutex<OwnedWriteHalf>,
    pending: Mutex<Pending>,
}

#[derive(Default)]
struct Pending {
    waiting: HashMap<u64, oneshot::Sender<Result<Value, Error>>>,
    gone: bool,
}

impl Link {
    fn new(pid: i32, writer: OwnedWriteHalf) -> Link {
        Link {
            pid,
            writer: tokio::sync::Mutex::new(writer),
            pending: Mutex::new(Pending::default()),
        }
    }

    /// Send LINE (no newline), whose id is ID, within WITHIN: the receiver of its answer (the whole answer object).
    /// `Err(None)`: not sent, the connection is gone (the call waits for the next backend).
    async fn send(
        &self,
        id: u64,
        line: &str,
        within: Duration,
    ) -> Result<oneshot::Receiver<Result<Value, Error>>, Option<Error>> {
        let (tx, rx) = oneshot::channel();
        {
            let mut p = self.pending.lock().expect("pending");
            if p.gone {
                return Err(None);
            }
            p.waiting.insert(id, tx);
        }
        let written = timeout(within, async {
            let mut w = self.writer.lock().await;
            w.write_all(line.as_bytes()).await?;
            w.write_all(b"\n").await
        })
        .await;
        match written {
            Ok(Ok(())) => Ok(rx),
            // a line the backend never read whole is never served: the next backend gets it
            Ok(Err(_)) => {
                self.forget(id);
                Err(None)
            }
            Err(_) => {
                self.forget(id);
                Err(Some(internal("the Lisp backend does not read")))
            }
        }
    }

    fn gone(&self) -> bool {
        self.pending.lock().expect("pending").gone
    }

    fn forget(&self, id: u64) {
        self.pending.lock().expect("pending").waiting.remove(&id);
    }

    fn answer(&self, id: u64, v: Value) {
        if let Some(tx) = self.pending.lock().expect("pending").waiting.remove(&id) {
            let _ = tx.send(Ok(v));
        }
    }

    /// The connection ended: every call in flight fails once.
    fn close(&self) {
        let mut p = self.pending.lock().expect("pending");
        p.gone = true;
        for (_, tx) in p.waiting.drain() {
            let _ = tx.send(Err(restarted()));
        }
    }
}

/// Where the backend is.
#[derive(Clone)]
enum Phase {
    /// It cannot be started: why.
    Missing(String),
    /// Started (its pid once spawned), not answering yet.
    Starting(Option<i32>),
    Running(Arc<Link>),
    /// It exited or never answered: a restart comes.
    Failed,
    /// The hub stops.
    Stopped,
}

/// The backend and its supervisor's state.
pub struct Backend {
    phase: watch::Sender<Phase>,
    next_id: AtomicU64,
    program: Result<Program, String>,
    socket: Result<PathBuf, String>,
    home: PathBuf,
    runtime: urdr::Handle,
    events: mpsc::Sender<(String, Value)>,
    stop: watch::Sender<bool>,
}

/// How one run of the backend ended.
enum End {
    Stopped,
    Gone(String),
}

impl Backend {
    /// The backend that PROGRAM starts on SOCKET, recorded in RUNTIME, its events to EVENTS.  Nothing runs before
    /// [`Backend::supervise`].
    pub fn new(
        program: Result<Program, String>,
        socket: Result<PathBuf, String>,
        home: PathBuf,
        runtime: urdr::Handle,
        events: mpsc::Sender<(String, Value)>,
    ) -> Arc<Backend> {
        let phase = match (&program, &socket) {
            (Err(why), _) | (_, Err(why)) => Phase::Missing(why.clone()),
            _ => Phase::Starting(None),
        };
        Arc::new(Backend {
            phase: watch::channel(phase).0,
            // 0 is the readiness ping's
            next_id: AtomicU64::new(1),
            program,
            socket,
            home,
            runtime,
            events,
            stop: watch::channel(false).0,
        })
    }

    pub fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Ask the supervisor to stop the backend; [`Backend::supervise`] then returns.
    pub fn stop(&self) {
        self.stop.send_replace(true);
    }

    fn stopping(&self) -> bool {
        *self.stop.borrow()
    }

    async fn stopped(&self) {
        let mut rx = self.stop.subscribe();
        let _ = rx.wait_for(|s| *s).await;
    }

    /// The running backend's connection, once there is one (one that ended waits for the next backend).
    async fn link(&self) -> Result<Arc<Link>, Error> {
        let mut rx = self.phase.subscribe();
        loop {
            let now = match &*rx.borrow_and_update() {
                Phase::Running(l) if !l.gone() => Some(Ok(l.clone())),
                Phase::Running(_) => None,
                Phase::Missing(why) => Some(Err(internal(format!(
                    "the Lisp backend cannot start: {why}"
                )))),
                Phase::Stopped => Some(Err(internal("the hub is stopping"))),
                Phase::Starting(_) | Phase::Failed => None,
            };
            if let Some(r) = now {
                return r;
            }
            rx.changed()
                .await
                .map_err(|_| internal("the hub is stopping"))?;
        }
    }

    /// Send LINE (the request ID for METHOD, no newline) and wait for its answer, within [`CALL_DEADLINE`] in all: the
    /// result, or the backend's error as `internal` with its message.
    pub async fn request(
        &self,
        id: u64,
        method: &str,
        line: Zeroizing<String>,
    ) -> Result<Value, Error> {
        self.request_within(id, method, line, CALL_DEADLINE).await
    }

    async fn request_within(
        &self,
        id: u64,
        method: &str,
        line: Zeroizing<String>,
        within: Duration,
    ) -> Result<Value, Error> {
        let late = || internal(format!("the Lisp backend did not answer {method}"));
        let deadline = Instant::now() + within;
        // a call is in flight once its line went out whole: until then a backend that went away is waited out
        let (link, rx) = loop {
            let link = tokio::time::timeout_at(deadline, self.link())
                .await
                .map_err(|_| late())??;
            let left = deadline.saturating_duration_since(Instant::now());
            match link.send(id, &line, left).await {
                Ok(rx) => break (link, rx),
                Err(Some(e)) => return Err(e),
                // its reader is about to say so: the phase changes then
                Err(None) => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        };
        drop(line);
        let answer = match tokio::time::timeout_at(deadline, rx).await {
            Err(_) => {
                link.forget(id);
                return Err(late());
            }
            Ok(Err(_)) => return Err(restarted()),
            Ok(Ok(a)) => a?,
        };
        if let Some(e) = answer.get("error") {
            let message = e
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the Lisp backend failed");
            return Err(internal(message));
        }
        answer.get("result").cloned().ok_or_else(|| {
            internal(format!(
                "the Lisp backend's answer to {method} has no result"
            ))
        })
    }

    /// The backend's state and pid, and, while it runs, the gateway's port and registrations from its own `status`.
    pub async fn info(&self) -> BackendInfo {
        let phase = self.phase.borrow().clone();
        let (state, pid) = match &phase {
            Phase::Missing(_) => (BackendState::Missing, None),
            Phase::Starting(pid) => (BackendState::Starting, *pid),
            Phase::Running(l) => (BackendState::Running, Some(l.pid)),
            Phase::Failed | Phase::Stopped => (BackendState::Failed, None),
        };
        let mut info = BackendInfo {
            backend: Some(BackendStatus {
                state,
                pid: pid.and_then(|p| u64::try_from(p).ok()),
            }),
            gateway_port: None,
            registrations: None,
        };
        if let Phase::Running(_) = phase {
            let id = self.next_id();
            let line = Zeroizing::new(
                json!({"id": id, "method": "status", "params": {}, "caller": {"class": "user"}})
                    .to_string(),
            );
            if let Ok(s) = self
                .request_within(id, "status", line, STATUS_DEADLINE)
                .await
            {
                info.gateway_port = s.get("gateway_port").and_then(Value::as_u64);
                info.registrations = s.get("registrations").and_then(Value::as_u64);
            }
        }
        info
    }

    /// The turns running (restart-when-idle, [`crate::idle`]): the backend's `busy` sessions plus its `running` jobs,
    /// each list asked within [`IDLE_DEADLINE`].  A backend that cannot exist (`missing`) has none.  None when the
    /// backend does not answer or answers with something else: that is not idle.
    pub async fn busy(&self) -> Option<u64> {
        if matches!(&*self.phase.borrow(), Phase::Missing(_)) {
            return Some(0);
        }
        let ask = |method: &'static str| async move {
            let id = self.next_id();
            let line = Zeroizing::new(
                json!({"id": id, "method": method, "params": {}, "caller": {"class": "user"}})
                    .to_string(),
            );
            self.request_within(id, method, line, IDLE_DEADLINE)
                .await
                .ok()
        };
        let agents = ask("agents/list").await?;
        let jobs = ask("job/status").await?;
        crate::idle::count_busy(&agents, &jobs)
    }

    /// Run the backend until the hub stops: start it, restart it when it is gone (after a backoff), and stop it at
    /// the end.  Returns at once when it is `missing`.
    pub async fn supervise(self: Arc<Self>) {
        let (Ok(program), Ok(socket)) = (&self.program, &self.socket) else {
            if let Phase::Missing(why) = &*self.phase.borrow() {
                tracing::warn!("the Lisp backend cannot start: {why}");
            }
            return;
        };
        let mut backoff = BACKOFF_FIRST;
        loop {
            if self.stopping() {
                break;
            }
            self.phase.send_replace(Phase::Starting(None));
            let began = Instant::now();
            match self.run_once(program, socket).await {
                End::Stopped => break,
                End::Gone(why) => {
                    self.phase.send_replace(Phase::Failed);
                    if began.elapsed() >= HEALTHY_AFTER {
                        backoff = BACKOFF_FIRST;
                    }
                    tracing::warn!(
                        "the Lisp backend {why}: starting it again in {} s",
                        backoff.as_secs()
                    );
                }
            }
            tokio::select! {
                () = tokio::time::sleep(backoff) => {}
                () = self.stopped() => break,
            }
            backoff = (backoff * 2).min(BACKOFF_MAX);
        }
        self.phase.send_replace(Phase::Stopped);
    }

    /// One life of the backend: recorded, spawned, ready, served, gone.
    async fn run_once(&self, program: &Program, socket: &Path) -> End {
        match std::fs::remove_file(socket) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                return End::Gone(format!(
                    "cannot start: the stale socket {}: {e}",
                    socket.display()
                ));
            }
            _ => {}
        }
        let row = match self.record_insert().await {
            Ok(r) => r,
            Err(e) => return End::Gone(format!("cannot start: {e}")),
        };
        let spec = proc::Spec {
            program: program.program.clone(),
            args: program.args.clone(),
            env: environment(program.test_backend, socket, std::process::id()),
            cwd: Some(self.home.clone()),
            stdin_null: true,
            pass_fds: Vec::new(),
        };
        let mut child = match proc::spawn(spec).await {
            Ok(c) => c,
            Err(e) => {
                self.record_delete(row).await;
                return End::Gone(format!("cannot start ({}): {e}", program.program.display()));
            }
        };
        let pid = child.id();
        self.record_spawned(row, pid).await;
        self.phase.send_replace(Phase::Starting(Some(pid)));
        if let Some(mut out) = child.take_stdout() {
            tokio::spawn(async move {
                let mut sink = [0u8; 4096];
                while let Ok(1..) = out.read(&mut sink).await {}
            });
        }
        let mut exited = false;
        let end = 'life: {
            let ready = tokio::select! {
                r = timeout(READY_WITHIN, connect_ready(socket, pid)) => match r {
                    Ok(r) => r,
                    Err(_) => Err(format!("did not answer ping within {} s", READY_WITHIN.as_secs())),
                },
                s = child.wait() => {
                    exited = true;
                    Err(format!("ended before it answered ({})", describe(s)))
                }
                () = self.stopped() => break 'life End::Stopped,
            };
            let (stream, buf) = match ready {
                Ok(x) => x,
                Err(why) => break 'life End::Gone(why),
            };
            let (r, w) = stream.into_split();
            let link = Arc::new(Link::new(pid, w));
            let reader = tokio::spawn(read_loop(r, buf, link.clone(), self.events.clone()));
            // one subscription per backend start: its events are relayed from now on
            let id = self.next_id();
            let sub = Zeroizing::new(
                json!({"id": id, "method": "subscribe", "params": {}, "caller": {"class": "user"}})
                    .to_string(),
            );
            let subscribed = async {
                let rx = link
                    .send(id, &sub, READY_WITHIN)
                    .await
                    .map_err(|e| e.unwrap_or_else(restarted))?;
                timeout(READY_WITHIN, rx)
                    .await
                    .map_err(|_| internal("no answer"))?
                    .map_err(|_| restarted())?
            };
            let answered = tokio::select! {
                a = subscribed => a,
                s = child.wait() => {
                    exited = true;
                    link.close();
                    break 'life End::Gone(format!("ended ({})", describe(s)));
                }
            };
            if !answered.is_ok_and(|a| a.get("result") == Some(&Value::Bool(true))) {
                link.close();
                break 'life End::Gone("did not take the subscription".into());
            }
            self.phase.send_replace(Phase::Running(link.clone()));
            tracing::info!(pid, "the Lisp backend serves on {}", socket.display());
            let end = tokio::select! {
                s = child.wait() => {
                    exited = true;
                    End::Gone(format!("ended ({})", describe(s)))
                }
                _ = reader => End::Gone("closed its connection".into()),
                () = self.stopped() => End::Stopped,
            };
            link.close();
            end
        };
        if !exited {
            // never reaped yet, so its group is still ours: stop it.  The leader is reaped meanwhile: an unreaped
            // zombie keeps its group "there" for `kill(-pgid, 0)`, and the stop would wait out SIGKILL's whole
            // limit (7 s) for a backend that died at SIGTERM.
            let _ = tokio::join!(
                proc::kill_group(pid, proc::reap::GRACE, &RealSignaller),
                child.wait()
            );
        }
        tracing::debug!(pid, stderr = %child.stderr_tail(), "the Lisp backend's stderr");
        self.record_delete(row).await;
        end
    }

    async fn record_insert(&self) -> Result<i64, String> {
        let boot = proc::boot_id().ok();
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        self.runtime
            .write(move |c| {
                c.execute(
                    "insert into proc(purpose, boot_id, at) values ('backend', ?1, ?2)",
                    (boot, at),
                )?;
                Ok(c.last_insert_rowid())
            })
            .await
            .map_err(|e| format!("cannot record it in runtime.db: {e}"))
    }

    async fn record_spawned(&self, row: i64, pid: i32) {
        let start = proc::start_time(pid)
            .ok()
            .and_then(|t| i64::try_from(t).ok());
        if let Err(e) = self
            .runtime
            .write(move |c| {
                Ok(c.execute(
                    "update proc set pid = ?1, start_time = ?2, pgid = ?1 where id = ?3",
                    (pid, start, row),
                )?)
            })
            .await
        {
            tracing::warn!(
                pid,
                "cannot record the Lisp backend's pid in runtime.db: {e}"
            );
        }
    }

    async fn record_delete(&self, row: i64) {
        if let Err(e) = self
            .runtime
            .write(move |c| Ok(c.execute("delete from proc where id = ?1", [row])?))
            .await
        {
            tracing::warn!("cannot remove the Lisp backend's row from runtime.db: {e}");
        }
    }
}

fn describe(s: std::io::Result<Option<std::process::ExitStatus>>) -> String {
    use std::os::unix::process::ExitStatusExt;
    match s {
        Ok(Some(st)) => match (st.code(), st.signal()) {
            (Some(c), _) => format!("exit code {c}"),
            (_, Some(sig)) => format!("signal {sig}"),
            _ => "an unknown status".into(),
        },
        Ok(None) => "already seen".into(),
        Err(e) => format!("cannot wait for it: {e}"),
    }
}

/// Connect to the backend's SOCKET until it answers a raw `ping` (polled every 50 ms): its peer must be our uid
/// and PID.  The stream, and what was read after the ping's answer.
async fn connect_ready(socket: &Path, pid: i32) -> Result<(UnixStream, BytesMut), String> {
    let uid = rustix::process::geteuid().as_raw();
    loop {
        if let Ok(mut s) = UnixStream::connect(socket).await {
            let cred = s
                .peer_cred()
                .map_err(|e| format!("its socket's peer cannot be read: {e}"))?;
            if cred.uid() != uid || cred.pid() != Some(pid) {
                return Err(format!(
                    "its socket is served by another process (uid {}, pid {:?})",
                    cred.uid(),
                    cred.pid()
                ));
            }
            if s.write_all(b"{\"id\":0,\"method\":\"ping\"}\n")
                .await
                .is_ok()
            {
                let mut codec = LinesCodec::new_with_max_length(MAX_HUB_LINE);
                let mut buf = BytesMut::with_capacity(4096);
                loop {
                    match codec.decode(&mut buf) {
                        Ok(Some(line)) => {
                            let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                            if v.get("id") == Some(&json!(0)) && v.get("result").is_some() {
                                return Ok((s, buf));
                            }
                            continue;
                        }
                        Ok(None) => {}
                        Err(_) => break,
                    }
                    match s.read_buf(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Read the backend's lines (up to 16 MiB each) until its connection ends: answers to their call, events to the
/// relay.  Then every call in flight fails once.
async fn read_loop(
    mut r: OwnedReadHalf,
    mut buf: BytesMut,
    link: Arc<Link>,
    events: mpsc::Sender<(String, Value)>,
) {
    let mut codec = LinesCodec::new_with_max_length(MAX_HUB_LINE);
    'read: loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(line)) => handle_line(&line, &link, &events).await,
                Ok(None) => break,
                Err(e) => {
                    tracing::warn!("dropped a line from the Lisp backend: {e}");
                    continue;
                }
            }
        }
        match r.read_buf(&mut buf).await {
            Ok(0) => break 'read,
            Ok(_) => {}
            Err(e) => {
                tracing::warn!("the Lisp backend's connection failed: {e}");
                break 'read;
            }
        }
    }
    link.close();
}

async fn handle_line(line: &str, link: &Link, events: &mpsc::Sender<(String, Value)>) {
    let Ok(Value::Object(mut obj)) = serde_json::from_str::<Value>(line) else {
        tracing::warn!("dropped a line from the Lisp backend that is not a JSON object");
        return;
    };
    if let Some(Value::String(name)) = obj.remove("event") {
        let data = obj.remove("data").unwrap_or(Value::Null);
        let _ = events.send((name, data)).await;
        return;
    }
    match obj.get("id").and_then(Value::as_u64) {
        Some(id) => link.answer(id, Value::Object(obj)),
        None => tracing::warn!("dropped a line from the Lisp backend with no id and no event"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::os::unix::fs::PermissionsExt;

    fn get(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let m: BTreeMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |k: &str| m.get(k).cloned()
    }

    fn args(drgnx: &str) -> Vec<OsString> {
        [
            "--batch",
            "-Q",
            "--eval",
            "(setq load-prefer-newer t)",
            "-L",
            &format!("{drgnx}/core"),
            "-l",
            "drgnx-hub",
            "-f",
            "drgnx-hub-main",
        ]
        .iter()
        .map(OsString::from)
        .collect()
    }

    #[test]
    fn the_command_is_the_test_backend_or_emacs_with_drgnx() {
        let dir = tempfile::tempdir().unwrap();
        let (data, config) = (dir.path().join("d"), dir.path().join("c"));
        let p =
            |vars: &[(&str, &str)], checkout: &str| program(&get(vars), &data, &config, checkout);
        // a test backend: as it is, no args
        assert_eq!(
            p(
                &[
                    ("DRGNX_RATATOSKR_BACKEND", "/x/fake"),
                    ("DRGNX_EMACS", "/e")
                ],
                ""
            ),
            Ok(Program {
                program: "/x/fake".into(),
                args: vec![],
                test_backend: true
            })
        );
        assert!(p(&[("DRGNX_RATATOSKR_BACKEND", "fake")], "").is_err());
        // DRGNX_EMACS and DRGNX_DIR, else the build's checkout
        assert_eq!(
            p(
                &[("DRGNX_EMACS", "/e/emacs"), ("DRGNX_DIR", "/src/d")],
                "/co"
            ),
            Ok(Program {
                program: "/e/emacs".into(),
                args: args("/src/d"),
                test_backend: false
            })
        );
        assert_eq!(
            p(&[("DRGNX_EMACS", "/e/emacs")], "/co").map(|p| p.args),
            Ok(args("/co"))
        );
        // neither: missing, and why
        let e = p(&[("DRGNX_EMACS", "/e/emacs")], "").unwrap_err();
        assert!(e.contains("DRGNX_DIR"), "{e}");
        let e = p(&[("DRGNX_DIR", "/src/d"), ("DRGNX_EMACS", "emacs")], "").unwrap_err();
        assert!(e.contains("DRGNX_EMACS"), "{e}");
        // the Emacs install.sh recorded: data dir first, then config; an executable file only
        let exe = dir.path().join("emacs-bin");
        std::fs::write(&exe, "").unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(
            config.join("emacs"),
            format!("  {}  \nignored\n", exe.display()),
        )
        .unwrap();
        assert_eq!(
            p(&[("DRGNX_DIR", "/src/d")], "").map(|p| p.program),
            Ok(exe.clone())
        );
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(data.join("emacs"), "/no/such/emacs\n").unwrap();
        assert_eq!(
            p(&[("DRGNX_DIR", "/src/d")], "").map(|p| p.program),
            Ok(exe.clone()),
            "a recorded name that is no executable is passed over"
        );
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(p(&[("DRGNX_DIR", "/src/d")], "").is_err());
    }

    #[test]
    fn the_allowlist_has_no_key() {
        for name in ENV_ALLOW {
            let up = name.to_ascii_uppercase();
            assert!(
                !["KEY", "TOKEN", "SECRET", "PASSWORD"]
                    .iter()
                    .any(|k| up.contains(k)),
                "{name}"
            );
            assert!(!name.starts_with("DRGNX_HUB"), "{name}: set, never copied");
        }
        for name in [
            "SSH_AUTH_SOCK",
            "HTTPS_PROXY",
            "no_proxy",
            "SSL_CERT_FILE",
            "TERM",
            "DISPLAY",
        ] {
            assert!(ENV_ALLOW.contains(&name), "{name}");
        }
    }
}
