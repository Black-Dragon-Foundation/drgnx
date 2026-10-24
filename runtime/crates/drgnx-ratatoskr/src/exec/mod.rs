//! Jobs: the execution layer (`exec/*`; Task 11, container jobs Task 11b, the wake Task 15; `docs/guide/jobs.md`).
//! A job runs in its starter's Gleipnir spec as a unit of its own (a `systemd-run --user` transient unit on Linux,
//! else its own session and process group), its exit and log in `<state>/hub/exec/<id>/`; a hub restart re-attaches
//! it; its end is the `exec-done` event and the starter's wake.
//!
//! - [`unit`]: the transient unit or process group, and re-attaching after a restart.
//! - [`summary`]: cargo test, ERT and domr output read for failing names, at most 20 lines.
//!
//! A job's folder holds `meta.json` (what it is), `log`, `exit` (written by the wrapper shell), `why` (`stopped` or
//! `timed-out`, written before the hub kills it) and, once it ended, `result.json`.  A folder without `result.json` is
//! running; the hub's monitor (or, after a restart, the re-attached one) writes the result once.

pub mod summary;
pub mod unit;

use crate::agents::launch::{self, NetCell};
use crate::agents::lock::{Enforced, LaunchPlan};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::sandbox::SessionShape;
use gleipnir::{Refusal, Rule};
use runstav::methods::exec::{
    ById, ExecDone, ExecKind, ExecRow, ExecStatus, ExecSummary, Jobs, ListParams, LogParams,
    LogSlice, StartParams, Started,
};
use runstav::paths::Env;
use runstav::wire::{Error, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use unit::Meta;

/// Who started a job: a session (its sandbox runs the job) or the user (their own rights).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Starter {
    Session(String),
    User,
}

/// What a job's output is read as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CheckKind {
    Cargo,
    Ert,
    Domr,
    Other,
}

impl CheckKind {
    fn name(self) -> &'static str {
        match self {
            CheckKind::Cargo => "cargo",
            CheckKind::Ert => "ert",
            CheckKind::Domr => "domr",
            CheckKind::Other => "other",
        }
    }

    fn from_name(s: &str) -> CheckKind {
        match s {
            "cargo" => CheckKind::Cargo,
            "ert" => CheckKind::Ert,
            "domr" => CheckKind::Domr,
            _ => CheckKind::Other,
        }
    }
}

/// A job to start.
#[derive(Clone, Debug)]
pub struct ExecSpec {
    pub starter: Starter,
    pub cwd: PathBuf,
    pub argv: Vec<String>,
    pub timebox: Duration,
    pub kind: CheckKind,
}

/// What the runner reaches beyond its own folder: the store (a job is an entity), the subscribers (`exec-done`), the
/// memory cap and whether a user systemd carries the units.
#[derive(Clone)]
pub struct Hooks {
    pub writer: Option<crate::coord::Writer>,
    pub editors: Option<Arc<crate::settings::agents::Editors>>,
    /// `MemoryMax` of a unit (`agents-job-memory`).
    pub memory: String,
    pub systemd: bool,
}

impl Default for Hooks {
    fn default() -> Hooks {
        Hooks {
            writer: None,
            editors: None,
            memory: "4G".into(),
            systemd: unit::systemd_user(),
        }
    }
}

/// How a job ended, as `result.json` keeps it.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct End {
    status: ExecStatus,
    exit: Option<i32>,
    ended: f64,
    summary: ExecSummary,
}

struct Inner {
    root: PathBuf,
    hooks: Hooks,
    seq: AtomicU64,
    finishing: Mutex<HashSet<String>>,
}

/// The jobs the hub runs.
#[derive(Default)]
pub struct Runner {
    inner: OnceLock<Arc<Inner>>,
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn refusal(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: None,
        message: message.into(),
    }
}

fn setup(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: message.into(),
    }
}

impl Runner {
    /// Open the runner on ROOT (`<state>/hub/exec`) and re-attach the jobs a hub before this one left running.  Runs
    /// inside a tokio runtime.  A second call changes nothing.
    pub fn open(&self, root: PathBuf, hooks: Hooks) {
        let mut fresh = false;
        let inner = self.inner.get_or_init(|| {
            fresh = true;
            Arc::new(Inner {
                root,
                hooks,
                seq: AtomicU64::new(0),
                finishing: Mutex::new(HashSet::new()),
            })
        });
        if fresh {
            inner.reattach();
        }
    }

    fn inner(&self) -> Result<&Arc<Inner>, Refusal> {
        self.inner
            .get()
            .ok_or_else(|| setup("jobs are not open yet"))
    }

    /// Start a job; answers its id.  A session's job runs in that session's sandbox (its worktree is the CWD, writable;
    /// no sandbox here is a refusal); the user's runs with the user's rights.
    pub async fn start(&self, spec: ExecSpec) -> Result<String, Refusal> {
        self.inner()?.clone().start(spec).await
    }

    pub fn get(&self, id: &str) -> Option<ExecRow> {
        self.inner.get()?.row(id)
    }

    /// The jobs, newest first; SESSION only that session's, RUNNING only those that run.
    pub fn list(&self, session: Option<&str>, running: bool) -> Vec<ExecRow> {
        self.inner
            .get()
            .map(|i| i.list(session, running))
            .unwrap_or_default()
    }

    /// End a running job (its group gets SIGTERM, then SIGKILL) and answer its row once it ended.
    pub async fn stop(&self, id: &str) -> Option<ExecRow> {
        self.inner.get()?.clone().stop(id).await
    }

    /// N lines of the job's log from line FROM (0-based).
    pub fn log_slice(&self, id: &str, from: usize, n: usize) -> Vec<String> {
        let Some(i) = self.inner.get() else {
            return vec![];
        };
        std::fs::read_to_string(i.dir(id).join("log"))
            .map(|t| t.lines().skip(from).take(n).map(String::from).collect())
            .unwrap_or_default()
    }
}

impl Inner {
    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    fn meta(&self, id: &str) -> Option<Meta> {
        let text = std::fs::read_to_string(self.dir(id).join("meta.json")).ok()?;
        serde_json::from_str(&text).ok()
    }

    fn end(&self, id: &str) -> Option<End> {
        let text = std::fs::read_to_string(self.dir(id).join("result.json")).ok()?;
        serde_json::from_str(&text).ok()
    }

    fn save_meta(&self, m: &Meta) -> Result<(), Refusal> {
        let dir = self.dir(&m.id);
        let tmp = dir.join("meta.tmp");
        std::fs::write(&tmp, serde_json::to_vec(m).unwrap_or_default())
            .and_then(|()| std::fs::rename(&tmp, dir.join("meta.json")))
            .map_err(|e| setup(format!("{}: {e}", dir.display())))
    }

    fn row(&self, id: &str) -> Option<ExecRow> {
        let m = self.meta(id)?;
        let end = self.end(id);
        let kind = match m.kind.as_str() {
            "cargo" => ExecKind::Cargo,
            "ert" => ExecKind::Ert,
            "domr" => ExecKind::Domr,
            "container" => ExecKind::Container,
            _ => ExecKind::Other,
        };
        Some(ExecRow {
            id: m.id,
            session: m.session,
            task: None,
            kind,
            argv: m.argv,
            cwd: m.cwd,
            image: None,
            status: end.as_ref().map_or(ExecStatus::Running, |e| e.status),
            started: m.started,
            ended: end.as_ref().map(|e| e.ended),
            timebox_s: m.timebox_s,
            unit: m.unit,
            summary: end.map(|e| e.summary),
        })
    }

    fn list(&self, session: Option<&str>, running: bool) -> Vec<ExecRow> {
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return vec![];
        };
        let mut rows: Vec<ExecRow> = rd
            .flatten()
            .filter_map(|e| self.row(&e.file_name().to_string_lossy()))
            .filter(|r| session.is_none_or(|s| r.session.as_deref() == Some(s)))
            .filter(|r| !running || r.status == ExecStatus::Running)
            .collect();
        rows.sort_by(|a, b| b.started.total_cmp(&a.started));
        rows
    }

    fn new_id(&self) -> String {
        let ms = (now() * 1000.0) as u64;
        format!("x{ms:x}{:x}", self.seq.fetch_add(1, Ordering::Relaxed))
    }

    async fn start(self: Arc<Self>, spec: ExecSpec) -> Result<String, Refusal> {
        if spec.argv.is_empty() || spec.argv[0].is_empty() {
            return Err(refusal("a job needs a command"));
        }
        if !spec.cwd.is_dir() {
            return Err(refusal(format!("{} is not a folder", spec.cwd.display())));
        }
        let id = self.new_id();
        let dir = self.dir(&id);
        std::fs::create_dir_all(&dir).map_err(|e| setup(format!("{}: {e}", dir.display())))?;
        let r = self.clone().launch(&id, &dir, spec).await;
        if r.is_err() {
            let _ = std::fs::remove_dir_all(&dir);
        }
        r.map(|()| id)
    }

    async fn launch(self: Arc<Self>, id: &str, dir: &Path, spec: ExecSpec) -> Result<(), Refusal> {
        let name = self.hooks.systemd.then(|| unit::unit_name(id));
        let (inner, status) = match &spec.starter {
            Starter::Session(sid) => {
                let plan = LaunchPlan {
                    argv: spec.argv.iter().map(OsString::from).collect(),
                    env: tool_env(),
                    session_meta: None,
                    protected_ro: vec![],
                    login_dir: None,
                    enforced: Enforced::Yes,
                };
                let shape = SessionShape {
                    sid: sid.clone(),
                    cwd: spec.cwd.clone(),
                    write: vec![spec.cwd.clone()],
                    read: vec![],
                    net: NetCell::ProviderAndPackages,
                };
                let l = launch::launch(&Env::process(), &plan, &shape)?;
                (l.spec, l.status)
            }
            Starter::User => (
                draugr::Spec {
                    program: PathBuf::from(&spec.argv[0]),
                    args: spec.argv[1..].iter().map(OsString::from).collect(),
                    env: draugr::env::build(
                        &[
                            "PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR", "SHELL",
                        ],
                        &["LC_", "CARGO", "RUST", "MISE_"],
                        &[],
                    ),
                    cwd: Some(spec.cwd.clone()),
                    stdin_null: true,
                    pass_fds: vec![],
                    new_session: false,
                },
                None,
            ),
        };
        let wrapped = unit::wrap(
            inner,
            dir,
            name.as_deref().map(|n| (n, self.hooks.memory.as_str())),
        );
        let child = draugr::spawn_pinned(wrapped)
            .await
            .map_err(|e| setup(format!("starting the job: {e}")))?;
        let pid = child.id();
        // The sandbox helper reports on a pipe; a launch whose status is not read hangs (Task 10).
        if let Some(fd) = status {
            let log = dir.join("log");
            let read = tokio::task::spawn_blocking(move || {
                gleipnir::read_status(
                    fd,
                    &|| {
                        std::fs::read_to_string(&log)
                            .map(|t| t.lines().next().unwrap_or("").to_string())
                            .unwrap_or_default()
                    },
                    Duration::from_secs(20),
                )
            })
            .await
            .map_err(|e| setup(format!("reading the sandbox status: {e}")))?;
            if let Err(e) = read {
                let _ =
                    draugr::kill_group(pid, Duration::from_secs(1), &draugr::RealSignaller).await;
                return Err(e);
            }
        }
        let started = now();
        let mut meta = Meta {
            id: id.to_string(),
            session: match &spec.starter {
                Starter::Session(s) => Some(s.clone()),
                Starter::User => None,
            },
            kind: spec.kind.name().to_string(),
            argv: spec.argv.clone(),
            cwd: spec.cwd.display().to_string(),
            started,
            timebox_s: spec.timebox.as_secs_f64().ceil() as u64,
            deadline: started + spec.timebox.as_secs_f64(),
            unit: name,
            pid: Some(pid),
            start_time: draugr::start_time(pid).ok(),
            entity: None,
        };
        self.save_meta(&meta)?;
        meta.entity = self.record_start(&meta).await;
        self.save_meta(&meta)?;
        let me = self.clone();
        let id = id.to_string();
        tokio::spawn(async move { me.watch(&id, Some(child)).await });
        Ok(())
    }

    /// The graph entity of a job that starts (best effort: a store that is not ready loses the record, not the job).
    async fn record_start(&self, m: &Meta) -> Option<String> {
        let w = self.hooks.writer.as_ref()?;
        let new = norn::write::exec::ExecNew {
            project: None,
            starter: m.session.clone(),
            argv: m.argv.clone(),
            cwd: m.cwd.clone(),
            kind: m.kind.clone(),
            timebox_s: m.timebox_s as i64,
            started: m.started,
        };
        let meta = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "exec/start");
        match w
            .db
            .write(meta, move |tx| norn::write::exec::create(tx, new))
            .await
        {
            Ok(id) => Some(id),
            Err(e) => {
                tracing::warn!("job {}: not recorded: {e}", m.id);
                None
            }
        }
    }

    /// Wait for the job to end (or its time box), then record the end.  CHILD is the process this hub started; none:
    /// a job re-attached after a restart, watched by polling.
    async fn watch(self: Arc<Self>, id: &str, child: Option<draugr::Child>) {
        let Some(meta) = self.meta(id) else { return };
        let dir = self.dir(id);
        let left = |m: &Meta| Duration::from_secs_f64((m.deadline - now()).max(0.0));
        match child {
            Some(mut c) => {
                tokio::select! {
                    _ = c.wait() => {}
                    () = tokio::time::sleep(left(&meta)) => {
                        let _ = std::fs::write(dir.join("why"), "timed-out");
                        let _ = draugr::kill_group(c.id(), Duration::from_secs(2), &draugr::RealSignaller).await;
                        let _ = c.wait().await;
                    }
                }
            }
            None => loop {
                let gone = match (meta.pid, meta.start_time) {
                    (Some(p), Some(t)) => !unit::same_process(p, t),
                    _ => true,
                };
                if gone || unit::read_exit(&dir).is_some() || self.end(id).is_some() {
                    break;
                }
                if now() >= meta.deadline {
                    let _ = std::fs::write(dir.join("why"), "timed-out");
                    if let Some(p) = meta.pid {
                        let _ =
                            draugr::kill_group(p, Duration::from_secs(2), &draugr::RealSignaller)
                                .await;
                    }
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            },
        }
        self.finish(id).await;
    }

    /// Write the job's result once: status from `why` and the exit file, the summary from the log; record it in the
    /// store; tell the subscribers.
    async fn finish(&self, id: &str) {
        if self.end(id).is_some() || !self.finishing.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let Some(meta) = self.meta(id) else { return };
        let dir = self.dir(id);
        let exit = unit::read_exit(&dir);
        let status = match std::fs::read_to_string(dir.join("why")).as_deref() {
            Ok("stopped") => ExecStatus::Stopped,
            Ok("timed-out") => ExecStatus::TimedOut,
            _ if exit.is_some() => ExecStatus::Done,
            _ => ExecStatus::Lost,
        };
        let text = tail_of(&dir.join("log"));
        let summary = summary::summarise(
            CheckKind::from_name(&meta.kind),
            exit,
            &text,
            &dir.join("log").display().to_string(),
        );
        let end = End {
            status,
            exit,
            ended: now(),
            summary,
        };
        let tmp = dir.join("result.tmp");
        let written = std::fs::write(&tmp, serde_json::to_vec(&end).unwrap_or_default())
            .and_then(|()| std::fs::rename(&tmp, dir.join("result.json")));
        if let Err(e) = written {
            tracing::warn!("job {id}: result not written: {e}");
        }
        if let (Some(w), Some(entity)) = (self.hooks.writer.as_ref(), meta.entity.clone()) {
            let word = match status {
                ExecStatus::Done => "done",
                ExecStatus::Stopped => "stopped",
                ExecStatus::TimedOut => "timed-out",
                _ => "lost",
            };
            let e = norn::write::exec::ExecEnd {
                status: word.into(),
                exit,
                ended: end.ended,
                summary: serde_json::to_value(&end.summary).ok(),
            };
            let tx = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "exec/end");
            if let Err(err) =
                w.db.write(tx, move |tx| norn::write::exec::finish(tx, &entity, e))
                    .await
            {
                tracing::warn!("job {id}: end not recorded: {err}");
            }
        }
        if let Some(ed) = &self.hooks.editors {
            let done = ExecDone {
                id: id.to_string(),
                session: meta.session,
                status,
                exit,
                summary: end.summary,
            };
            ed.broadcast("exec-done", json!(done));
        }
    }

    async fn stop(self: Arc<Self>, id: &str) -> Option<ExecRow> {
        let meta = self.meta(id)?;
        if self.end(id).is_none() {
            let _ = std::fs::write(self.dir(id).join("why"), "stopped");
            if let (Some(p), Some(t)) = (meta.pid, meta.start_time)
                && unit::same_process(p, t)
            {
                let _ = draugr::kill_group(p, Duration::from_secs(2), &draugr::RealSignaller).await;
            }
            for _ in 0..100 {
                if self.end(id).is_some() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        self.row(id)
    }

    /// Watch every job a hub before this one left without a result.
    fn reattach(self: &Arc<Self>) {
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return;
        };
        for e in rd.flatten() {
            let id = e.file_name().to_string_lossy().to_string();
            if self.meta(&id).is_some() && self.end(&id).is_none() {
                let me = self.clone();
                tokio::spawn(async move { me.watch(&id, None).await });
            }
        }
    }
}

/// The last megabyte of a log, as text.
fn tail_of(path: &Path) -> String {
    use std::io::{Read, Seek, SeekFrom};
    const MAX: u64 = 1 << 20;
    let Ok(mut f) = std::fs::File::open(path) else {
        return String::new();
    };
    let len = f.metadata().map_or(0, |m| m.len());
    let mut buf = Vec::new();
    if f.seek(SeekFrom::Start(len.saturating_sub(MAX))).is_err() || f.read_to_end(&mut buf).is_err()
    {
        return String::new();
    }
    String::from_utf8_lossy(&buf).into_owned()
}

/// The environment a session's job gets inside its sandbox: the tool paths, nothing else of the hub's.
fn tool_env() -> Vec<(String, String)> {
    ["PATH", "LANG", "TERM", "CARGO_HOME", "RUSTUP_HOME"]
        .iter()
        .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v)))
        .collect()
}

fn error(code: ErrorCode, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
        path: None,
    }
}

/// Open the runner on first use, from the front's folders, store and subscribers.
fn runner(f: &Front) -> Result<&Runner, Error> {
    let r = &f.core.exec;
    if r.inner.get().is_none() {
        let dirs = f
            .dirs
            .get()
            .ok_or_else(|| error(ErrorCode::Internal, "exec: the store is not open yet"))?;
        let mut hooks = Hooks {
            writer: Some(f.writer.clone()),
            editors: Some(f.editors.clone()),
            ..Hooks::default()
        };
        if let Some((serde_json::Value::String(m), _)) =
            f.settings.effective("drgnx-agents-job-memory", None)
        {
            hooks.memory = m;
        }
        r.open(dirs.hub.join("exec"), hooks);
    }
    Ok(r)
}

/// Part 1 runs jobs on this machine only (Calls made 3).
fn check_machine(p: &StartParams) -> Result<(), Error> {
    match &p.machine {
        Some(m) if m.as_str() != "local" => Err(error(
            ErrorCode::InvalidParams,
            format!("machine {}: jobs run on this machine only", m.as_str()),
        )),
        _ => Ok(()),
    }
}

pub async fn start(f: &Front, c: &Caller, p: StartParams) -> Result<Started, Error> {
    check_machine(&p)?;
    let kind = match p.kind.unwrap_or(ExecKind::Other) {
        ExecKind::Cargo => CheckKind::Cargo,
        ExecKind::Ert => CheckKind::Ert,
        ExecKind::Domr => CheckKind::Domr,
        ExecKind::Other => CheckKind::Other,
        ExecKind::Container => {
            return Err(crate::agent_core::not_yet("exec/start container", "11b"));
        }
    };
    let cwd = p
        .cwd
        .as_ref()
        .map(|c| PathBuf::from(c.as_str()))
        .ok_or_else(|| error(ErrorCode::InvalidParams, "cwd: the folder the job runs in"))?;
    let spec = ExecSpec {
        starter: c.sid.clone().map_or(Starter::User, Starter::Session),
        cwd,
        argv: p.argv.iter().map(|a| a.to_string()).collect(),
        timebox: Duration::from_secs(p.timebox_s.unwrap_or(3600)),
        kind,
    };
    let id = runner(f)?
        .start(spec)
        .await
        .map_err(|r| error(ErrorCode::InvalidParams, r.message))?;
    Ok(Started {
        text: format!(
            "job {id} runs; its end wakes you with the summary (job_result {id} for the rest)"
        ),
        id,
    })
}

fn no_job(id: &str) -> Error {
    error(ErrorCode::InvalidParams, format!("no job {id}"))
}

pub async fn get(f: &Front, _: &Caller, p: ById) -> Result<ExecRow, Error> {
    runner(f)?
        .get(p.id.as_str())
        .ok_or_else(|| no_job(p.id.as_str()))
}

pub async fn list(f: &Front, _: &Caller, p: ListParams) -> Result<Jobs, Error> {
    Ok(Jobs {
        jobs: runner(f)?.list(
            p.session.as_ref().map(|s| s.as_str()),
            p.running == Some(true),
        ),
    })
}

pub async fn stop(f: &Front, _: &Caller, p: ById) -> Result<ExecRow, Error> {
    runner(f)?
        .stop(p.id.as_str())
        .await
        .ok_or_else(|| no_job(p.id.as_str()))
}

pub async fn log(f: &Front, _: &Caller, p: LogParams) -> Result<LogSlice, Error> {
    let r = runner(f)?;
    let row = r.get(p.id.as_str()).ok_or_else(|| no_job(p.id.as_str()))?;
    let from = p.from.unwrap_or(0);
    let n = p.n.unwrap_or(200) as usize;
    let mut lines = r.log_slice(p.id.as_str(), from as usize, n + 1);
    let more = lines.len() > n;
    lines.truncate(n);
    Ok(LogSlice {
        id: row.id,
        from,
        next: more.then(|| from + n as u64),
        lines,
        running: row.status == ExecStatus::Running,
    })
}

#[cfg(test)]
mod tests;
