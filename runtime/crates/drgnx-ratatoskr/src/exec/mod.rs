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

pub mod container;
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
use std::collections::{HashSet, VecDeque};
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
    Container,
}

impl CheckKind {
    fn name(self) -> &'static str {
        match self {
            CheckKind::Cargo => "cargo",
            CheckKind::Ert => "ert",
            CheckKind::Domr => "domr",
            CheckKind::Other => "other",
            CheckKind::Container => "container",
        }
    }

    fn from_name(s: &str) -> CheckKind {
        match s {
            "cargo" => CheckKind::Cargo,
            "ert" => CheckKind::Ert,
            "container" => CheckKind::Container,
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
    /// The session's worktree (a session's job: its `cwd` must be this folder or inside it; a user's job: none).
    pub worktree: Option<PathBuf>,
    pub argv: Vec<String>,
    pub timebox: Duration,
    pub kind: CheckKind,
    /// A container job: `argv` is the command inside the image (kind [`CheckKind::Container`]).
    pub container: Option<ContainerJob>,
}

/// What makes a job a container job: the allow-list name, the caps from settings, the network the matrix granted.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContainerJob {
    pub image: String,
    pub caps: container::Caps,
    pub net: Option<NetCell>,
}

/// What the hub hears of the jobs: a job's end.  (`Queued` and `Admitted` are no longer sent: a job that finds the
/// machine full is recorded as queued and its starter told at once, so no turn waits in the queue.)
#[derive(Clone, Debug)]
pub enum JobEvent {
    /// The job ID of SESSION waits for a free machine slot.
    Queued { session: Option<String>, id: String },
    /// ... and has one now.
    Admitted { session: Option<String>, id: String },
    /// The job ended (its result is written, and it no longer counts as running).
    Done(ExecDone),
}

/// The jobs running now, by the session that started each (a session waits for its own, in the hub's memory).
#[derive(Default)]
pub struct Live(Mutex<std::collections::HashMap<String, Option<String>>>);

impl Live {
    fn add(&self, id: &str, session: Option<String>) {
        self.0.lock().unwrap().insert(id.to_string(), session);
    }

    fn remove(&self, id: &str) {
        self.0.lock().unwrap().remove(id);
    }

    /// The running jobs SESSION started.
    pub fn ids(&self, session: &str) -> Vec<String> {
        let mut ids: Vec<String> = self
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, s)| s.as_deref() == Some(session))
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }
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
    /// `podman`, found on the PATH when the hub started; none: container jobs are refused.
    pub podman: Option<PathBuf>,
    /// `drgnx-fwd` (next to the hub, else on the PATH): the forwarder a container job granted network runs.
    pub forwarder: Option<PathBuf>,
    /// Jobs running at once on this machine; the next waits for a slot (the session's step is a machine-queue wait).
    pub slots: usize,
}

impl Default for Hooks {
    fn default() -> Hooks {
        Hooks {
            writer: None,
            editors: None,
            memory: "4G".into(),
            systemd: unit::systemd_user(),
            podman: unit::find_on_path("podman"),
            forwarder: std::env::current_exe()
                .ok()
                .and_then(|e| e.parent().map(|d| d.join("drgnx-fwd")))
                .filter(|f| f.is_file())
                .or_else(|| unit::find_on_path("drgnx-fwd")),
            slots: 4,
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
    live: Arc<Live>,
    events: tokio::sync::broadcast::Sender<JobEvent>,
    slots: Arc<tokio::sync::Semaphore>,
    /// Jobs recorded as queued, oldest first; each starts when a slot frees ([`Inner::pump`]).
    queue: Mutex<VecDeque<String>>,
}

/// What a queued job is started from, saved as `<dir>/pending.json` (the hub may restart before its turn).
#[derive(Serialize, Deserialize)]
struct Pending {
    session: Option<String>,
    cwd: PathBuf,
    worktree: Option<PathBuf>,
    argv: Vec<String>,
    timebox_s: f64,
    kind: String,
    container: Option<ContainerJob>,
}

impl Pending {
    fn of(spec: &ExecSpec) -> Pending {
        Pending {
            session: match &spec.starter {
                Starter::Session(s) => Some(s.clone()),
                Starter::User => None,
            },
            cwd: spec.cwd.clone(),
            worktree: spec.worktree.clone(),
            argv: spec.argv.clone(),
            timebox_s: spec.timebox.as_secs_f64(),
            kind: spec.kind.name().to_string(),
            container: spec.container.clone(),
        }
    }

    fn into_spec(self) -> ExecSpec {
        ExecSpec {
            starter: self.session.map_or(Starter::User, Starter::Session),
            cwd: self.cwd,
            worktree: self.worktree,
            argv: self.argv,
            timebox: Duration::from_secs_f64(self.timebox_s),
            kind: CheckKind::from_name(&self.kind),
            container: self.container,
        }
    }
}

/// Finished job folders kept: the newest this many, and none older than [`KEEP_DAYS`] (the graph row stays).  A job
/// that ended in the last [`KEEP_GRACE_S`] is never pruned, so its wake can still read the result.
const KEEP_JOBS: usize = 200;
const KEEP_DAYS: f64 = 14.0;
const KEEP_GRACE_S: f64 = 3600.0;

/// The jobs the hub runs.
pub struct Runner {
    inner: OnceLock<Arc<Inner>>,
    live: Arc<Live>,
    events: tokio::sync::broadcast::Sender<JobEvent>,
}

impl Default for Runner {
    fn default() -> Runner {
        Runner {
            inner: OnceLock::new(),
            live: Arc::default(),
            events: tokio::sync::broadcast::channel(256).0,
        }
    }
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
                slots: Arc::new(tokio::sync::Semaphore::new(hooks.slots.max(1))),
                hooks,
                seq: AtomicU64::new(0),
                queue: Mutex::new(VecDeque::new()),
                finishing: Mutex::new(HashSet::new()),
                live: self.live.clone(),
                events: self.events.clone(),
            })
        });
        if fresh {
            inner.reattach();
        }
    }

    /// The running jobs, by starter.
    pub fn live(&self) -> Arc<Live> {
        self.live.clone()
    }

    /// Queue waits and ends, as they happen (a slow receiver lags; it never holds a job up).
    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<JobEvent> {
        self.events.subscribe()
    }

    fn inner(&self) -> Result<&Arc<Inner>, Refusal> {
        self.inner
            .get()
            .ok_or_else(|| setup("jobs are not open yet"))
    }

    /// Start a job; answers its id.  A session's job runs in that session's sandbox (its worktree, writable, is the
    /// only folder it writes; its CWD must be the worktree or inside it; no sandbox here is a refusal); the user's
    /// runs with the user's rights.  On a full machine the job is recorded as queued and the id answered at once.
    pub async fn start(&self, spec: ExecSpec) -> Result<String, Refusal> {
        self.inner()?.clone().start(spec).await
    }

    /// Whether job ID waits for a machine slot.
    pub fn is_queued(&self, id: &str) -> bool {
        self.inner
            .get()
            .and_then(|i| i.meta(id))
            .is_some_and(|m| m.queued)
    }

    pub fn get(&self, id: &str) -> Option<ExecRow> {
        self.inner.get()?.row(id)
    }

    /// How job ID ended, as the event that announced it said; none while it runs (or when it is unknown).
    pub fn done(&self, id: &str) -> Option<ExecDone> {
        let i = self.inner.get()?;
        let (m, end) = (i.meta(id)?, i.end(id)?);
        Some(ExecDone {
            id: id.to_string(),
            session: m.session,
            status: end.status,
            exit: end.exit,
            summary: end.summary,
        })
    }

    /// Whether the job's row says running but its process is gone (the supervisor's `dead-wait`).
    pub fn process_gone(&self, id: &str) -> bool {
        let Some(i) = self.inner.get() else {
            return false;
        };
        match i.meta(id) {
            Some(m) => match (m.pid, m.start_time) {
                (Some(p), Some(t)) => i.end(id).is_none() && !unit::same_process(p, t),
                _ => false,
            },
            None => true,
        }
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
            image: m.image,
            status: end.as_ref().map_or(
                if m.queued {
                    ExecStatus::Queued
                } else {
                    ExecStatus::Running
                },
                |e| e.status,
            ),
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
            .filter(|r| !running || matches!(r.status, ExecStatus::Running | ExecStatus::Queued))
            .collect();
        rows.sort_by(|a, b| b.started.total_cmp(&a.started));
        rows
    }

    fn new_id(&self) -> String {
        let ms = (now() * 1000.0) as u64;
        format!("x{ms:x}{:x}", self.seq.fetch_add(1, Ordering::Relaxed))
    }

    /// The spec with its folders made true names, and a session's job confined: its CWD is the session's worktree or
    /// inside it (a link out of it is resolved first), else refused.  A user's job works in the CWD it names.
    fn confine(mut spec: ExecSpec) -> Result<ExecSpec, Refusal> {
        let cwd = std::fs::canonicalize(&spec.cwd)
            .ok()
            .filter(|c| c.is_dir())
            .ok_or_else(|| refusal(format!("{} is not a folder", spec.cwd.display())))?;
        match (&spec.starter, spec.worktree.take()) {
            (Starter::Session(_), Some(wt)) => {
                let wt = std::fs::canonicalize(&wt)
                    .map_err(|_| refusal(format!("{} is not a folder", wt.display())))?;
                if !cwd.starts_with(&wt) {
                    return Err(refusal(format!(
                        "{} is outside your worktree {}: a job runs in your worktree or a folder inside it",
                        spec.cwd.display(),
                        wt.display()
                    )));
                }
                spec.worktree = Some(wt);
            }
            (Starter::Session(_), None) => {
                return Err(refusal("a session's job needs its worktree"));
            }
            (Starter::User, _) => spec.worktree = Some(cwd.clone()),
        }
        spec.cwd = cwd;
        Ok(spec)
    }

    async fn start(self: Arc<Self>, spec: ExecSpec) -> Result<String, Refusal> {
        if spec.argv.is_empty() || spec.argv[0].is_empty() {
            return Err(refusal("a job needs a command"));
        }
        let spec = Self::confine(spec)?;
        let id = self.new_id();
        let dir = self.dir(&id);
        std::fs::create_dir_all(&dir).map_err(|e| setup(format!("{}: {e}", dir.display())))?;
        let Ok(permit) = self.slots.clone().try_acquire_owned() else {
            if let Err(e) = self.enqueue(&id, &dir, &spec) {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(e);
            }
            // a slot may have freed between the failed try and the queue entry
            self.pump();
            return Ok(id);
        };
        let r = self.clone().launch(&id, &dir, spec, permit).await;
        if r.is_err() {
            let _ = std::fs::remove_dir_all(&dir);
            self.pump();
        }
        r.map(|()| id)
    }

    /// Record job ID as queued: what to start (`pending.json`), a meta saying it waits, a place in the queue.
    fn enqueue(&self, id: &str, dir: &Path, spec: &ExecSpec) -> Result<(), Refusal> {
        let write = |name: &str, bytes: Vec<u8>| {
            let tmp = dir.join(format!("{name}.tmp"));
            std::fs::write(&tmp, bytes)
                .and_then(|()| std::fs::rename(&tmp, dir.join(name)))
                .map_err(|e| setup(format!("{}: {e}", dir.display())))
        };
        write(
            "pending.json",
            serde_json::to_vec(&Pending::of(spec)).unwrap_or_default(),
        )?;
        let started = now();
        let session = match &spec.starter {
            Starter::Session(s) => Some(s.clone()),
            Starter::User => None,
        };
        self.save_meta(&Meta {
            id: id.to_string(),
            session: session.clone(),
            kind: spec.kind.name().to_string(),
            argv: spec.argv.clone(),
            cwd: spec.cwd.display().to_string(),
            started,
            timebox_s: spec.timebox.as_secs_f64().ceil() as u64,
            deadline: started + spec.timebox.as_secs_f64(),
            unit: None,
            pid: None,
            start_time: None,
            entity: None,
            image: spec.container.as_ref().map(|c| c.image.clone()),
            queued: true,
        })?;
        self.live.add(id, session);
        self.queue.lock().unwrap().push_back(id.to_string());
        Ok(())
    }

    /// Start queued jobs while slots are free.
    fn pump(self: &Arc<Self>) {
        loop {
            let Ok(permit) = self.slots.clone().try_acquire_owned() else {
                return;
            };
            let Some(id) = self.queue.lock().unwrap().pop_front() else {
                return;
            };
            let me = self.clone();
            tokio::spawn(async move { me.run_queued(id, permit).await });
        }
    }

    /// A queued job got its slot: start it, or end it when it cannot start (stopped while it waited, its spec gone,
    /// the launch refused); the reason is in its log and its end is the usual `exec-done`.
    async fn run_queued(self: Arc<Self>, id: String, permit: tokio::sync::OwnedSemaphorePermit) {
        let dir = self.dir(&id);
        let pending = std::fs::read_to_string(dir.join("pending.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Pending>(&t).ok());
        let mut permit = Some(permit);
        let failed = if dir.join("why").exists() {
            None
        } else {
            match pending {
                None => Some("its start request is gone".to_string()),
                Some(p) => {
                    let slot = permit.take().expect("the slot");
                    match self.clone().launch(&id, &dir, p.into_spec(), slot).await {
                        Ok(()) => return,
                        Err(e) => Some(e.message),
                    }
                }
            }
        };
        drop(permit);
        if let Some(why) = failed {
            let _ = std::fs::write(dir.join("log"), format!("could not start: {why}\n"));
        }
        self.finish(&id).await;
        self.pump();
    }

    /// The `podman run` of a container job.  The container is the sandbox, so the starter's Gleipnir spec is not used;
    /// the hub pulls the image first, the job never does.
    async fn container_spec(
        &self,
        id: &str,
        dir: &Path,
        spec: &ExecSpec,
    ) -> Result<(draugr::Spec, Option<container::JobProxy>), Refusal> {
        let job = spec.container.as_ref().expect("a container job");
        let podman = self
            .hooks
            .podman
            .clone()
            .ok_or_else(container::podman_missing)?;
        let mut caps = job.caps.clone();
        // A granted network is this job's own proxy: a socket on a short path under the runtime dir and a copy of the
        // forwarder in the job's folder, both mounted read-only.  One that cannot be given refuses the job.
        let mut proxy = None;
        if let Some(n) = job.net {
            let forwarder = self.hooks.forwarder.clone().ok_or_else(|| {
                setup("this job was granted network access, but drgnx-fwd (the forwarder) is not installed beside the hub")
            })?;
            let run_dir = runstav::paths::socket_path(&Env::process())
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(std::env::temp_dir);
            let jp = container::prepare_proxy(id, dir, &run_dir, &forwarder, n, &caps.net_hosts)?;
            caps.proxy = Some(jp.mounts.clone());
            proxy = Some(jp);
        }
        // the mount is the session's worktree, never a folder the request names; the command runs in its CWD inside
        let worktree = spec.worktree.clone().unwrap_or_else(|| spec.cwd.clone());
        let subdir = spec
            .cwd
            .strip_prefix(&worktree)
            .map(Path::to_path_buf)
            .map_err(|_| refusal("the job's folder is outside its worktree"))?;
        let req = container::ContainerReq {
            image: job.image.clone(),
            argv: spec.argv.clone(),
            worktree,
            subdir,
            job: id.to_string(),
            net: job.net,
        };
        let args = container::argv(&req, &caps)?;
        let (p, reference) = (
            podman.clone(),
            container::resolve(&caps, &job.image)?.to_string(),
        );
        tokio::task::spawn_blocking(move || {
            container::ensure_image(&p, &reference, container::PULL_TIMEOUT)
        })
        .await
        .map_err(|e| setup(format!("pulling the image: {e}")))??;
        Ok((
            draugr::Spec {
                program: podman,
                args,
                env: draugr::env::build(
                    &["PATH", "HOME", "USER", "LOGNAME", "LANG", "XDG_RUNTIME_DIR"],
                    &[],
                    &[],
                ),
                cwd: Some(spec.cwd.clone()),
                stdin_null: true,
                pass_fds: vec![],
                new_session: false,
            },
            proxy,
        ))
    }

    async fn launch(
        self: Arc<Self>,
        id: &str,
        dir: &Path,
        spec: ExecSpec,
        permit: tokio::sync::OwnedSemaphorePermit,
    ) -> Result<(), Refusal> {
        let name = self.hooks.systemd.then(|| unit::unit_name(id));
        let mut proxy = None;
        let (inner, status) = match &spec.starter {
            _ if spec.container.is_some() => {
                let (s, p) = self.container_spec(id, dir, &spec).await?;
                proxy = p;
                (s, None)
            }
            // the conformance lane has no sandbox for a job: its jobs run as the user's do
            Starter::Session(_) if unsandboxed_for_tests() => (plain_spec(&spec), None),
            Starter::Session(sid) => {
                let worktree = spec
                    .worktree
                    .clone()
                    .ok_or_else(|| refusal("a session's job needs its worktree"))?;
                // the lock's protected files stay read-only for a job as for the session itself
                let plan = LaunchPlan {
                    argv: spec.argv.iter().map(OsString::from).collect(),
                    env: tool_env(),
                    session_meta: None,
                    protected_ro: crate::agents::lock::PROTECTED_RO
                        .iter()
                        .map(|p| worktree.join(p))
                        .collect(),
                    login_dir: None,
                    enforced: Enforced::Yes,
                };
                let shape = SessionShape {
                    sid: sid.clone(),
                    cwd: spec.cwd.clone(),
                    write: vec![worktree],
                    read: vec![],
                    net: NetCell::ProviderAndPackages,
                };
                let l = launch::launch(&Env::process(), &plan, &shape)?;
                (l.spec, l.status)
            }
            Starter::User => (plain_spec(&spec), None),
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
            image: spec.container.as_ref().map(|c| c.image.clone()),
            queued: false,
        };
        self.save_meta(&meta)?;
        meta.entity = self.record_start(&meta).await;
        self.save_meta(&meta)?;
        let me = self.clone();
        let id = id.to_string();
        // counted as running before the starter hears of its id
        self.live.add(&id, meta.session.clone());
        tokio::spawn(async move {
            // a container job's proxy answers for as long as the job runs
            let _proxy = proxy;
            me.clone().watch(&id, Some(child)).await;
            drop(permit);
            me.pump();
        });
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
            None => {
                let gone = async {
                    if let (Some(p), Some(t)) = (meta.pid, meta.start_time) {
                        wait_gone(p, t).await;
                    }
                };
                tokio::select! {
                    () = gone => {}
                    () = tokio::time::sleep(left(&meta)) => {
                        let _ = std::fs::write(dir.join("why"), "timed-out");
                        if let Some(p) = meta.pid {
                            let _ = draugr::kill_group(p, Duration::from_secs(2), &draugr::RealSignaller)
                                .await;
                        }
                    }
                }
            }
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
        let done = ExecDone {
            id: id.to_string(),
            session: meta.session,
            status,
            exit,
            summary: end.summary,
        };
        if let Some(ed) = &self.hooks.editors {
            ed.broadcast("exec-done", json!(done));
        }
        self.live.remove(id);
        let _ = self.events.send(JobEvent::Done(done));
        self.prune();
    }

    /// Remove the folders of finished jobs past the retention ([`KEEP_JOBS`], [`KEEP_DAYS`]); the graph row stays.
    fn prune(&self) {
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return;
        };
        let mut done: Vec<(f64, PathBuf)> = rd
            .flatten()
            .filter_map(|e| {
                let t = std::fs::metadata(e.path().join("result.json"))
                    .and_then(|m| m.modified())
                    .ok()?
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()?
                    .as_secs_f64();
                Some((t, e.path()))
            })
            .collect();
        done.sort_by(|a, b| b.0.total_cmp(&a.0));
        let now = now();
        for (rank, (t, dir)) in done.iter().enumerate() {
            let age = now - t;
            if age > KEEP_GRACE_S && (rank >= KEEP_JOBS || age > KEEP_DAYS * 86400.0) {
                let _ = std::fs::remove_dir_all(dir);
            }
        }
    }

    async fn stop(self: Arc<Self>, id: &str) -> Option<ExecRow> {
        let meta = self.meta(id)?;
        if meta.queued && self.end(id).is_none() {
            // still waiting for a slot: it never starts
            let _ = std::fs::write(self.dir(id).join("why"), "stopped");
            self.queue.lock().unwrap().retain(|q| q != id);
            self.finish(id).await;
            return self.row(id);
        }
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
        let mut running = HashSet::new();
        let mut waiting: Vec<(f64, String)> = Vec::new();
        for e in rd.flatten() {
            let id = e.file_name().to_string_lossy().to_string();
            if let Some(m) = self.meta(&id)
                && self.end(&id).is_none()
            {
                self.live.add(&id, m.session.clone());
                if m.queued {
                    waiting.push((m.started, id));
                    continue;
                }
                running.insert(id.clone());
                let me = self.clone();
                tokio::spawn(async move { me.watch(&id, None).await });
            }
        }
        // jobs that waited for a slot when the last hub ended wait again, oldest first
        waiting.sort_by(|a, b| a.0.total_cmp(&b.0));
        self.queue
            .lock()
            .unwrap()
            .extend(waiting.into_iter().map(|(_, id)| id));
        self.pump();
        self.prune();
        // a podman client that died with the last hub leaves its container: remove those no running job owns
        if let Some(podman) = self.hooks.podman.clone() {
            tokio::task::spawn_blocking(move || container::remove_leftovers(&podman, &running));
        }
    }
}

/// Wait until the process PID that started at START_TIME is gone: on Linux for the pidfd's event (no polling), else (or
/// where a pidfd cannot be had) by looking every 100 ms.
async fn wait_gone(pid: i32, start_time: u64) {
    #[cfg(target_os = "linux")]
    if let Some(fd) = rustix::process::Pid::from_raw(pid)
        .and_then(|p| rustix::process::pidfd_open(p, rustix::process::PidfdFlags::empty()).ok())
    {
        // checked once the descriptor is held, so a reused pid is never waited on
        if !unit::same_process(pid, start_time) {
            return;
        }
        // SAFETY: `fd` is an open pidfd that the `AsyncFd` now owns for as long as it lives.
        let registered = unsafe {
            tokio::io::unix::AsyncFd::register_with_interest(fd, tokio::io::Interest::READABLE)
        };
        if let Ok(a) = registered {
            let _ = a.readable().await;
            return;
        }
    }
    while unit::same_process(pid, start_time) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A job run with the user's rights: the same for a user's job and (in the conformance lane) a session's.
fn plain_spec(spec: &ExecSpec) -> draugr::Spec {
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
    }
}

/// Tests and `test-hooks` builds with `DRGNX_TEST_PLAIN_JOBS` set: the conformance container has no sandbox helper.
fn unsandboxed_for_tests() -> bool {
    cfg!(any(test, feature = "test-hooks")) && std::env::var_os("DRGNX_TEST_PLAIN_JOBS").is_some()
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
/// Open the runner now (at the hub's start), so the jobs a hub before this one left running are watched again and
/// their ends reach the sessions that started them.
pub fn ensure_open(f: &Front) {
    if let Err(e) = runner(f) {
        tracing::warn!("jobs not re-attached: {}", e.message);
    }
}

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
        #[cfg(feature = "test-hooks")]
        if let Some(n) = std::env::var("DRGNX_TEST_JOB_SLOTS")
            .ok()
            .and_then(|n| n.parse().ok())
        {
            hooks.slots = n;
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

/// A session's job runs commands in its worktree: the matrix's `code.edit` decides, as for the session's own tool
/// calls.  An ask is refused here with its card, so the agent tries again once the user said yes.
async fn gate_session_job(
    f: &Front,
    sid: &str,
    cwd: &std::path::Path,
    argv: &[String],
    action: norn::matrix::Action,
) -> Result<(), Error> {
    use crate::matrix_gate::Gate;
    match decide_session_job(f, sid, cwd, argv, action).await {
        Gate::Allow => Ok(()),
        Gate::Never(why) => Err(error(ErrorCode::NotAllowed, why)),
        Gate::Ask(card) => Err(error(
            ErrorCode::NotAllowed,
            format!("running this job needs the user's yes (matrix card {card})"),
        )),
    }
}

/// The matrix's verdict on ACTION for the job SID starts.
async fn decide_session_job(
    f: &Front,
    sid: &str,
    cwd: &std::path::Path,
    argv: &[String],
    action: norn::matrix::Action,
) -> crate::matrix_gate::Gate {
    use crate::matrix_gate::ActionCtx;
    let who = f.core.agents.who(sid).unwrap_or(norn::matrix::Who {
        role: Some(runstav::methods::matrix::Role::Worker),
        ..Default::default()
    });
    let command = argv.join(" ");
    let ctx = ActionCtx {
        facts: serde_json::from_value(
            serde_json::json!({"command": command, "paths": [cwd.to_string_lossy()]}),
        )
        .unwrap_or_default(),
        ..ActionCtx::of_session(&f.core.runs.scopes(), sid)
    };
    f.core
        .matrix
        .decide(&f.settings, &f.writer, who, action, ctx)
        .await
}

pub async fn start(f: &Front, c: &Caller, p: StartParams) -> Result<Started, Error> {
    check_machine(&p)?;
    let kind = match p.kind.unwrap_or(ExecKind::Other) {
        ExecKind::Cargo => CheckKind::Cargo,
        ExecKind::Ert => CheckKind::Ert,
        ExecKind::Domr => CheckKind::Domr,
        ExecKind::Other => CheckKind::Other,
        ExecKind::Container => CheckKind::Container,
    };
    let action = if kind == CheckKind::Container {
        norn::matrix::Action::JobContainer
    } else {
        norn::matrix::Action::CodeEdit
    };
    let cwd = p
        .cwd
        .as_ref()
        .map(|c| PathBuf::from(c.as_str()))
        .ok_or_else(|| error(ErrorCode::InvalidParams, "cwd: the folder the job runs in"))?;
    // A session's job works in the session's own worktree (or a folder inside it), whatever folder the request names.
    let worktree = match &c.sid {
        Some(sid) => Some(f.core.agents.worktree(sid).ok_or_else(|| {
            error(
                ErrorCode::NotAllowed,
                format!("session {sid} is not held by this hub"),
            )
        })?),
        None => None,
    };
    let cwd = match &worktree {
        Some(wt) => confined(&cwd, wt)?,
        None => cwd,
    };
    if let Some(sid) = &c.sid {
        let argv: Vec<String> = p.argv.iter().map(|a| a.to_string()).collect();
        gate_session_job(f, sid, &cwd, &argv, action).await?;
    }
    // The Network cell: an Allow gives the job its proxy (never a network of its own), a Never leaves it with none, an
    // Ask refuses the start with the card (the matrix keeps one open card per question, so a start while it is open
    // finds it and makes no second).  A job the user starts has no cell: it gets the proxy only when it asks.
    let net = match (&c.sid, kind) {
        (Some(sid), CheckKind::Container) => {
            use crate::matrix_gate::Gate;
            let argv: Vec<String> = p.argv.iter().map(|a| a.to_string()).collect();
            match decide_session_job(f, sid, &cwd, &argv, norn::matrix::Action::Network).await {
                Gate::Allow => Some(NetCell::ProviderAndPackages),
                Gate::Never(_) => None,
                Gate::Ask(card) => {
                    return Err(error(
                        ErrorCode::NotAllowed,
                        format!("this job's network needs the user's yes (matrix card {card})"),
                    ));
                }
            }
        }
        (None, CheckKind::Container) => {
            (p.network == Some(true)).then_some(NetCell::ProviderAndPackages)
        }
        _ => None,
    };
    let container = match (&p.image, kind) {
        (Some(image), CheckKind::Container) => Some(ContainerJob {
            image: image.to_string(),
            caps: crate::settings::containers::caps(&f.settings.current().loaded.values),
            net,
        }),
        (None, CheckKind::Container) => {
            return Err(error(
                ErrorCode::InvalidParams,
                "image: a container job names an image",
            ));
        }
        _ => None,
    };
    let spec = ExecSpec {
        starter: c.sid.clone().map_or(Starter::User, Starter::Session),
        cwd,
        worktree,
        argv: p.argv.iter().map(|a| a.to_string()).collect(),
        timebox: Duration::from_secs(p.timebox_s.unwrap_or(3600)),
        kind,
        container,
    };
    let r = runner(f)?;
    let id = r
        .start(spec)
        .await
        .map_err(|r| error(ErrorCode::InvalidParams, r.message))?;
    let text = if r.is_queued(&id) {
        format!(
            "job {id} is queued (the machine is full); it starts when a slot frees: end your turn, you will be woken with the result"
        )
    } else {
        format!("job {id} runs: end your turn; you will be woken with the result")
    };
    Ok(Started { text, id })
}

/// CWD (a true name) when it is WORKTREE or inside it, else a refusal that says so.
fn confined(cwd: &Path, worktree: &Path) -> Result<PathBuf, Error> {
    let real = |p: &Path| {
        std::fs::canonicalize(p).map_err(|_| {
            error(
                ErrorCode::InvalidParams,
                format!("{} is not a folder", p.display()),
            )
        })
    };
    let (c, w) = (real(cwd)?, real(worktree)?);
    if c.starts_with(&w) {
        Ok(c)
    } else {
        Err(error(
            ErrorCode::NotAllowed,
            format!(
                "{} is outside your worktree {}: a job runs in your worktree or a folder inside it",
                cwd.display(),
                w.display()
            ),
        ))
    }
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
        running: matches!(row.status, ExecStatus::Running | ExecStatus::Queued),
    })
}

#[cfg(test)]
mod tests;
