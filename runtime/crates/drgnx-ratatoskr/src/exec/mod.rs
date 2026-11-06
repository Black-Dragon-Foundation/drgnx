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
use crate::runners::local::{Admission, LocalRunner};
use crate::runners::queue::{
    self, Machine, Origin, Outcome, Placement, Queue, QueueCfg, Submit, priority_of,
};
use crate::runners::sync;
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
    /// What only the user's jobs carry (an agent's is always the default).
    pub user: UserJob,
    /// Where it may run, and how it is placed.
    pub place: Placement,
}

/// A user's job's own name, environment and limits (`exec/start`'s `name`, `env`, `memory_max`, `nice`).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct UserJob {
    pub name: Option<String>,
    /// Added to the base environment, replacing a variable of the same name.
    pub env: Vec<(String, String)>,
    /// `MemoryMax` of the unit, instead of `agents-job-memory`.
    pub memory_max: Option<String>,
    pub nice: Option<i8>,
    /// The job has no time box: `ExecSpec::timebox` is not used and the timer never ends it.
    #[serde(default)]
    pub no_timebox: bool,
}

impl ExecSpec {
    /// The job's time box, or none when it runs without one.
    fn time_box(&self) -> Option<Duration> {
        (!self.user.no_timebox).then_some(self.timebox)
    }
}

impl Meta {
    /// How long until the time box ends (none: it never does).
    fn time_left(&self) -> Option<Duration> {
        self.deadline
            .map(|d| Duration::from_secs_f64((d - now()).max(0.0)))
    }
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
    /// How this machine admits the queue's jobs (`runners::local`): live on Linux, else by count.  The user's servers
    /// (no time box) never queue.
    pub admission: Admission,
    /// `runtime.db`, where the queue is kept; none: in memory only.
    pub runtime: Option<urdr::Handle>,
    /// The login shell's variables (`env/set`): the base environment of every job and podman the hub starts.
    pub shell_env: crate::shell_env::ShellEnv,
    /// The providers' key variables (`key_env`) as the settings say now: never in a user's job's environment.
    pub key_envs: Arc<dyn Fn() -> Vec<String> + Send + Sync>,
    /// Unit tests: a session's job runs as the user's do (they have no sandbox helper).
    #[cfg(test)]
    pub plain_sessions: bool,
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
            // tests and the conformance lane admit by count, never by the machine they happen to run on
            admission: if cfg!(any(test, feature = "test-hooks")) {
                Admission::Fixed(crate::runners::local::FIXED_SLOTS)
            } else {
                Admission::default()
            },
            runtime: None,
            shell_env: crate::shell_env::ShellEnv::default(),
            key_envs: Arc::new(Vec::new),
            #[cfg(test)]
            plain_sessions: false,
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
    /// Every machine's queue (`runners::queue`): this machine's admission and the runners'.
    queue: Arc<Queue>,
}

/// What a queued job is started from, kept with it in the queue (`rq_job.spec`; an older hub wrote it as
/// `<dir>/pending.json`, read into the queue once).
#[derive(Serialize, Deserialize)]
struct Pending {
    session: Option<String>,
    cwd: PathBuf,
    worktree: Option<PathBuf>,
    argv: Vec<String>,
    timebox_s: f64,
    kind: String,
    container: Option<ContainerJob>,
    #[serde(default)]
    user: UserJob,
    #[serde(default)]
    place: Placement,
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
            user: spec.user.clone(),
            place: spec.place.clone(),
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
            user: self.user,
            place: self.place,
        }
    }
}

impl ExecSpec {
    /// The scheduler's view of this job: its command, folders, time box and memory range, its project (the
    /// worktree's folder name, until Urdr names projects to the hub) and its placement's marks.
    fn forseti_spec(&self, id: &str, memory: &str) -> forseti::JobSpec {
        let mut s = queue::blank_spec(id);
        s.command = self.argv.clone();
        s.cwd = self.cwd.clone();
        s.tree = self.worktree.clone().unwrap_or_else(|| self.cwd.clone());
        s.timeout_s = self.time_box().map_or(0, |t| t.as_secs());
        s.mem_mib.max =
            mem_mib(self.user.memory_max.as_deref().unwrap_or(memory)).max(s.mem_mib.min);
        s.project = s
            .tree
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        s.local_only = self.place.local_only;
        s.keys = self.place.keys.clone();
        s.writes = self.place.writes.clone();
        if self.place.heavy {
            s.weight = forseti::Weight::Heavy;
        }
        s
    }

    /// The priority the hub gives it: the user's own choice, else who started it and how.
    fn priority(&self) -> forseti::Priority {
        match self.place.priority {
            Some(n) if self.starter == Starter::User => forseti::Priority::from_number(n),
            _ => priority_of(&self.starter, self.place.background, Origin::Request),
        }
    }
}

/// A systemd size (`512M`, `4G`) in MiB; 4096 when it can't be read.
fn mem_mib(size: &str) -> u64 {
    let (digits, unit) = size.split_at(size.trim_end_matches(['K', 'M', 'G', 'T']).len());
    let n: u64 = digits.parse().unwrap_or(4096);
    match unit {
        "K" => n / 1024,
        "M" => n,
        "G" => n * 1024,
        "T" => n * 1024 * 1024,
        _ => n / (1024 * 1024),
    }
}

/// Finished job folders kept: the newest this many, and none older than [`KEEP_DAYS`] (the graph row stays).  A job
/// that ended in the last [`KEEP_GRACE_S`] is never pruned, so its wake can still read the result.
const KEEP_JOBS: usize = 200;
const KEEP_DAYS: f64 = 14.0;
const KEEP_GRACE_S: f64 = 3600.0;
/// How long a stop waits for the job's end to be recorded.
const STOP_WAIT: Duration = Duration::from_secs(5);
/// The job folder's file naming the `shared` runner the job ran on: its result is labelled and never counts for a gate.
const SHARED: &str = "shared";
/// The job folder's file with the line saying how the job's rows split over its attempts (`summary::split_line`).
const SPLIT: &str = "split";

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
    crate::clock::wall_secs()
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
        let mut fresh = None;
        let inner = self.inner.get_or_init(|| {
            let (queue, links) = Queue::new(QueueCfg {
                hub_id: "hub".into(),
                exec_root: root.clone(),
                local: LocalRunner::new(hooks.admission, &root),
                db: hooks.runtime.clone(),
            });
            let inner = Arc::new(Inner {
                root,
                hooks,
                seq: AtomicU64::new(0),
                queue,
                finishing: Mutex::new(HashSet::new()),
                live: self.live.clone(),
                events: self.events.clone(),
            });
            fresh = Some(links);
            inner
        });
        if let Some(links) = fresh {
            inner.reattach();
            Inner::run_queue(Arc::downgrade(inner), links);
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

    /// This machine's job slots in the queue: `(all, free)` ([`Queue::local_slots`]); none before the runner is open.
    pub fn slot_counts(&self) -> Option<(usize, usize)> {
        self.inner.get().map(|i| i.queue.local_slots())
    }

    /// Every machine's queue (the runners register in it); none before the runner is open.
    pub fn queue(&self) -> Option<Arc<Queue>> {
        self.inner.get().map(|i| i.queue.clone())
    }

    fn inner(&self) -> Result<&Arc<Inner>, Refusal> {
        self.inner
            .get()
            .ok_or_else(|| setup("jobs are not open yet"))
    }

    /// Start a job; answers its id.  A session's job runs in that session's sandbox (its worktree, writable, is the
    /// only folder it writes; its CWD must be the worktree or inside it; no sandbox here is a refusal); the user's
    /// runs with the user's rights.  A session's job on a full machine is recorded as queued and the id answered at
    /// once; the user's servers (no time box) never queue.
    pub async fn start(&self, spec: ExecSpec) -> Result<String, Refusal> {
        self.inner()?.clone().start(spec).await
    }

    /// Whether job ID is in the queue (here, or on a runner).
    pub fn is_queued(&self, id: &str) -> bool {
        self.inner
            .get()
            .and_then(|i| i.meta(id))
            .is_some_and(|m| m.queued)
    }

    pub fn get(&self, id: &str) -> Option<ExecRow> {
        self.inner.get()?.row(id)
    }

    /// Raises queued job ID to priority 1; its row, or none when no queue holds it.
    pub fn bump(&self, id: &str) -> Option<ExecRow> {
        let i = self.inner.get()?;
        if !i.queue.bump(id) {
            return None;
        }
        if let Some(mut m) = i.meta(id) {
            m.priority = Some(1);
            let _ = i.save_meta(&m);
        }
        i.pump();
        i.row(id)
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

    /// Whether job ID's result may count for a gate or a job's `needs`: the job is known and didn't run on a `shared`
    /// runner.
    pub fn counts_for_gates(&self, id: &str) -> bool {
        self.inner
            .get()
            .is_some_and(|i| i.meta(id).is_some() && !i.dir(id).join(SHARED).exists())
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
    pub async fn stop(&self, id: &str) -> Result<ExecRow, Error> {
        self.inner
            .get()
            .ok_or_else(|| no_job(id))?
            .clone()
            .stop(id)
            .await
    }

    /// N lines of the job's log from line FROM (0-based), read up to the last of them only; bytes that are not UTF-8
    /// are replaced.
    pub fn log_slice(&self, id: &str, from: usize, n: usize) -> Vec<String> {
        use std::io::BufRead;
        let Some(f) = self
            .inner
            .get()
            .and_then(|i| std::fs::File::open(i.dir(id).join("log")).ok())
        else {
            return vec![];
        };
        std::io::BufReader::new(f)
            .split(b'\n')
            .skip(from)
            .take(n)
            .map_while(Result::ok)
            .map(|l| String::from_utf8_lossy(l.strip_suffix(b"\r").unwrap_or(&l)).into_owned())
            .collect()
    }

    /// The end of the job's log, at most BYTES of it, as lines (the first may be cut); read from the file's end, a
    /// character cut at the start dropped and bytes that are not UTF-8 replaced.
    pub fn log_tail(&self, id: &str, bytes: u64) -> Vec<String> {
        let Some(i) = self.inner.get() else {
            return vec![];
        };
        let buf = tail_bytes(&i.dir(id).join("log"), bytes);
        // the rest of a character the cut began inside (continuation bytes, at most 3)
        let skip = buf
            .iter()
            .take(3)
            .take_while(|b| (0x80..0xc0).contains(*b))
            .count();
        String::from_utf8_lossy(&buf[skip..])
            .lines()
            .map(String::from)
            .collect()
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
        let q = self.queue.row(id);
        // a job on a runner has no process here: the queue says it runs there
        let remote = q
            .as_ref()
            .is_some_and(|q| q.machine.as_deref().is_some_and(|n| n != queue::LOCAL));
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
            name: m.name,
            status: end.as_ref().map_or(
                if m.queued && !remote {
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
            machine: q.as_ref().and_then(|q| q.machine.clone()).or(m.machine),
            attempt: q.as_ref().and_then(|q| q.attempt),
            waiting: q.as_ref().and_then(|q| q.waiting.clone()),
            priority: q.as_ref().map(|q| q.priority).or(m.priority),
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
        // The user's servers (no time box: the editor's, which run for days) never queue: they start at once and count
        // only in the memory the machine shows.  Every other job enters the queue.
        if spec.starter == Starter::User && spec.user.no_timebox {
            let r = self.clone().launch(&id, &dir, spec, None).await;
            if r.is_err() {
                let _ = std::fs::remove_dir_all(&dir);
            }
            return r.map(|()| id);
        }
        if let Err(e) = self.enqueue(&id, &dir, &spec) {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(e);
        }
        // admitted at once: started here, so a refused launch is the start's answer
        let t = self.queue.tick(now() as u64);
        let mut mine = None;
        for s in t.starts {
            if s == id {
                mine = Some(self.queue.slot(&s));
            } else {
                self.spawn_queued(s);
            }
        }
        self.outcomes(t.outcomes);
        let Some(slot) = mine else {
            return Ok(id);
        };
        let r = self.clone().launch(&id, &dir, spec, Some(slot)).await;
        if r.is_err() {
            self.live.remove(&id);
            let _ = std::fs::remove_dir_all(&dir);
            self.pump();
        }
        r.map(|()| id)
    }

    /// Record job ID as queued: a meta saying it waits, and its place in the queue (what to start is kept there).
    fn enqueue(&self, id: &str, dir: &Path, spec: &ExecSpec) -> Result<(), Refusal> {
        let _ = dir;
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
            timebox_s: spec.time_box().map(|t| t.as_secs_f64().ceil() as u64),
            deadline: spec.time_box().map(|t| started + t.as_secs_f64()),
            unit: None,
            pid: None,
            start_time: None,
            entity: None,
            image: spec.container.as_ref().map(|c| c.image.clone()),
            name: spec.user.name.clone(),
            queued: true,
            machine: None,
            priority: Some(spec.priority().number()),
        })?;
        self.live.add(id, session);
        self.queue.submit(self.submit_of(id, spec), started as u64);
        Ok(())
    }

    /// Job ID with SPEC as the queue takes it.
    fn submit_of(&self, id: &str, spec: &ExecSpec) -> Submit {
        let mut place = spec.place.clone();
        if place.image.is_none() {
            place.image = spec.container.as_ref().and_then(|c| {
                container::resolve(&c.caps, &c.image)
                    .ok()
                    .map(|r| r.to_string())
            });
        }
        let fspec = spec.forseti_spec(id, &self.hooks.memory);
        // inputs frozen at submit, for a job a runner could take: what it syncs, whatever the worktree holds later.
        // One that can't be frozen (not a git worktree, a submodule's change) stays on this machine.
        let mut inputs = None;
        if self.queue.runners() > 0 && place.may_leave() {
            let store = self.root.with_file_name("runner-store");
            match sync::freeze(
                &fspec.tree,
                &[],
                place.visibility,
                place.shared_overlay,
                &store,
            ) {
                Ok(f) => inputs = Some(f),
                Err(why) => {
                    tracing::info!("job {id} runs on this machine only: {why}");
                    place.local_only = true;
                }
            }
        }
        Submit {
            id: id.to_string(),
            session: match &spec.starter {
                Starter::Session(s) => Some(s.clone()),
                Starter::User => None,
            },
            own: spec.priority(),
            spec: fspec,
            place,
            pending: serde_json::to_value(Pending::of(spec)).unwrap_or_default(),
            inputs,
        }
    }

    /// The queue as `runtime.db` kept it, put back after a restart: the jobs that waited (WAITING, oldest first) wait
    /// again, and those on runners keep their attempts, detached until their runner's `hello`. A queued job an older
    /// hub left as `pending.json` is read into the queue once (the file goes once `rq_job` holds it).
    async fn restore(self: Arc<Self>, waiting: Vec<String>) {
        let (stored, attempts) = match &self.hooks.runtime {
            Some(db) => {
                self.queue.restore_kept(queue::kept(db).await);
                queue::stored(db).await
            }
            None => (vec![], vec![]),
        };
        let known: HashSet<String> = stored.iter().map(|s| s.submit.id.clone()).collect();
        let open: Vec<queue::Stored> = stored
            .into_iter()
            .filter(|s| self.meta(&s.submit.id).is_some() && self.end(&s.submit.id).is_none())
            .collect();
        self.queue.restore(open, attempts, now() as u64);
        for id in waiting {
            if known.contains(&id) {
                continue;
            }
            let dir = self.dir(&id);
            let file = dir.join("pending.json");
            let pending = std::fs::read_to_string(&file)
                .ok()
                .and_then(|t| serde_json::from_str::<Pending>(&t).ok());
            let Some(p) = pending else {
                let _ = std::fs::write(
                    dir.join("log"),
                    "could not start: its start request is gone\n",
                );
                self.finish(&id).await;
                continue;
            };
            let started = self.meta(&id).map_or(now(), |m| m.started);
            let spec = p.into_spec();
            self.queue
                .submit(self.submit_of(&id, &spec), started as u64);
            if self.hooks.runtime.is_some() {
                self.queue.flush().await;
                if let Err(e) = std::fs::remove_file(&file) {
                    tracing::warn!("job {id}: {}: {e}", file.display());
                }
            }
        }
        self.pump();
    }

    /// A tick of the queue: start what this machine admits, carry out what ended on runners.
    fn pump(self: &Arc<Self>) {
        let t = self.queue.tick(now() as u64);
        for id in t.starts {
            self.spawn_queued(id);
        }
        self.outcomes(t.outcomes);
    }

    fn spawn_queued(self: &Arc<Self>, id: String) {
        let me = self.clone();
        let slot = self.queue.slot(&id);
        crate::clock::spawn("exec:queued", async move { me.run_queued(id, slot).await });
    }

    /// The queue's tick every 2 s and its runners' events, for as long as the jobs are open.
    fn run_queue(
        inner: std::sync::Weak<Inner>,
        mut links: tokio::sync::mpsc::UnboundedReceiver<crate::runners::link::LinkEvent>,
    ) {
        let ticks = inner.clone();
        crate::clock::spawn("exec:queue-tick", async move {
            let mut every = crate::clock::interval(queue::TICK);
            loop {
                // an idle queue sets no timer: it waits for a job (or an attempt) to wait for
                let Some(q) = ticks.upgrade().map(|i| i.queue.clone()) else {
                    return;
                };
                if q.busy() {
                    every.tick().await;
                } else {
                    q.woken().await;
                    continue;
                }
                let Some(i) = ticks.upgrade() else { return };
                i.pump();
            }
        });
        crate::clock::spawn("exec:queue-links", async move {
            while let Some(ev) = links.recv().await {
                let Some(i) = inner.upgrade() else { return };
                let out = i.queue.on_link(ev, now() as u64);
                i.outcomes(out);
                i.pump();
            }
        });
    }

    /// What ended on a runner: its verdict becomes the job's end (`exit` and `why` as a job here writes them), a lost
    /// job ends lost, a late result stays in the folder as that attempt's. A `shared` runner's name goes to the job's
    /// [`SHARED`] file: its summary is labelled, and it never counts for a gate.
    fn outcomes(self: &Arc<Self>, outs: Vec<Outcome>) {
        for o in outs {
            let (id, verdict, shared, split) = match o {
                Outcome::Done {
                    id, result, shared, ..
                } => {
                    let split = result["split"].as_str().map(String::from);
                    (id, queue::verdict_of(&result), shared, split)
                }
                Outcome::Lost { id } => (id, None, None, None),
                Outcome::Late { id, attempt, .. } => {
                    tracing::info!(
                        "job {id}: attempt {attempt} finished late; its result is kept, not applied"
                    );
                    continue;
                }
            };
            let dir = self.dir(&id);
            let write = |name: &str, text: &str| {
                if let Err(e) = std::fs::write(dir.join(name), text) {
                    tracing::warn!("job {id}: {name} not written: {e}");
                }
            };
            match verdict {
                Some(forseti::Verdict::Pass) => write("exit", "0\n"),
                Some(forseti::Verdict::Red) => write("exit", "1\n"),
                Some(forseti::Verdict::Cancelled) => write("why", "stopped"),
                Some(forseti::Verdict::Timeout) => write("why", "timed-out"),
                Some(v) => write(
                    "exit",
                    if matches!(v, forseti::Verdict::Crash) {
                        "134\n"
                    } else {
                        "1\n"
                    },
                ),
                None => {}
            }
            if let Some(runner) = shared {
                write(SHARED, &runner);
            }
            if let Some(line) = split {
                write(SPLIT, &line);
            }
            let me = self.clone();
            crate::clock::spawn("exec:remote-end", async move { me.finish(&id).await });
        }
    }

    /// A queued job was admitted here: start it, or end it when it cannot start (stopped while it waited, its spec
    /// gone, the launch refused); the reason is in its log and its end is the usual `exec-done`.
    async fn run_queued(self: Arc<Self>, id: String, slot: queue::Slot) {
        let dir = self.dir(&id);
        let pending = self
            .queue
            .pending(&id)
            .and_then(|v| serde_json::from_value::<Pending>(v).ok());
        let mut permit = Some(slot);
        let failed = if dir.join("why").exists() {
            None
        } else {
            match pending {
                None => Some("its start request is gone".to_string()),
                Some(p) => {
                    let slot = permit.take().expect("the slot");
                    match self
                        .clone()
                        .launch(&id, &dir, p.into_spec(), Some(slot))
                        .await
                    {
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
            let jp = container::prepare_proxy(
                id,
                dir,
                &run_dir,
                &forwarder,
                n,
                &caps.net_hosts,
                &caps.pins,
            )?;
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
            net: job.net.is_some(),
            runner: None,
        };
        let args = container::argv(&req, &caps)?;
        let (p, reference) = (
            podman.clone(),
            container::resolve(&caps, &job.image)?.to_string(),
        );
        // caps podman cannot enforce refuse the job: a container without its limits is never run
        let shell = self.hooks.shell_env.clone();
        crate::clock::blocking(move || {
            container::check_limits(&shell, &p, Duration::from_secs(30))?;
            container::ensure_image(&shell, &p, &reference, container::PULL_TIMEOUT)
        })
        .await
        .map_err(|e| setup(format!("pulling the image: {e}")))??;
        Ok((
            draugr::Spec {
                program: podman,
                args,
                env: container::podman_env(&self.hooks.shell_env),
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
        permit: Option<queue::Slot>,
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
            Starter::Session(_) if unsandboxed_for_tests(&self.hooks) => (
                plain_spec(&spec, agent_plain_env(&self.hooks.shell_env)),
                None,
            ),
            Starter::Session(sid) => {
                let worktree = spec
                    .worktree
                    .clone()
                    .ok_or_else(|| refusal("a session's job needs its worktree"))?;
                // the lock's protected files stay read-only for a job as for the session itself
                let plan = LaunchPlan {
                    argv: spec.argv.iter().map(OsString::from).collect(),
                    env: tool_env(&self.hooks.shell_env),
                    session_meta: None,
                    protected_ro: crate::agents::lock::PROTECTED_RO
                        .iter()
                        .map(|p| worktree.join(p))
                        .collect(),
                    login_dir: None,
                    enforced: Enforced::Yes,
                    gateway: false,
                    trace: None,
                };
                let shape = SessionShape {
                    sid: sid.clone(),
                    cwd: spec.cwd.clone(),
                    write: vec![worktree],
                    read: vec![],
                    net: NetCell::ProviderAndPackages,
                    browser: None,
                };
                let l = launch::launch(&self.hooks.shell_env.paths_env(), &plan, &shape).await?;
                (l.spec, l.status)
            }
            Starter::User => (
                plain_spec(
                    &spec,
                    user_env(self.hooks.shell_env.vars_os(), &(self.hooks.key_envs)()),
                ),
                None,
            ),
        };
        let mut inner = inner;
        for (k, v) in &spec.user.env {
            inner.env.retain(|(n, _)| n != k.as_str());
            inner.env.push((k.into(), v.into()));
        }
        let memory = spec
            .user
            .memory_max
            .as_deref()
            .unwrap_or(self.hooks.memory.as_str());
        let wrapped = unit::wrap(
            inner,
            dir,
            name.as_deref().map(|n| (n, memory)),
            spec.user.nice,
            &self.hooks.shell_env,
        );
        let child = draugr::spawn_pinned(wrapped)
            .await
            .map_err(|e| setup(format!("starting the job: {e}")))?;
        let pid = child.id();
        // The sandbox helper reports on a pipe; a launch whose status is not read hangs (Task 10).
        if let Some(fd) = status {
            let log = dir.join("log");
            let read = crate::clock::blocking(move || {
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
            timebox_s: spec.time_box().map(|t| t.as_secs_f64().ceil() as u64),
            deadline: spec.time_box().map(|t| started + t.as_secs_f64()),
            unit: name,
            pid: Some(pid),
            start_time: draugr::start_time(pid).ok(),
            entity: None,
            image: spec.container.as_ref().map(|c| c.image.clone()),
            name: spec.user.name.clone(),
            queued: false,
            machine: Some(queue::LOCAL.into()),
            priority: Some(spec.priority().number()),
        };
        self.save_meta(&meta)?;
        meta.entity = self.record_start(&meta).await;
        self.save_meta(&meta)?;
        let me = self.clone();
        let id = id.to_string();
        // counted as running before the starter hears of its id
        self.live.add(&id, meta.session.clone());
        crate::clock::spawn("exec:watch", async move {
            // a container job's proxy answers for as long as the job runs
            let _proxy = proxy;
            // a real wait (the child's end): a test's barrier waits for a job that ends, and names one that does not;
            // an advance does not wait for it (the job's time box may be what ends it)
            crate::clock::real_long(me.clone().watch(&id, Some(child))).await;
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
            // 0: no time box
            timebox_s: m.timebox_s.unwrap_or(0) as i64,
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
        // a job without a time box has no timer arm: it ends only by itself or by a stop
        let time_up = async {
            match meta.time_left() {
                Some(left) => crate::clock::sleep(left).await,
                None => std::future::pending().await,
            }
        };
        match child {
            Some(mut c) => {
                tokio::select! {
                    _ = c.wait() => {}
                    () = time_up => {
                        let _ = std::fs::write(dir.join("why"), "timed-out");
                        // the kill ends by itself, within its grace: an advance past the time box waits for it
                        crate::clock::real(async {
                            let _ = draugr::kill_group(c.id(), Duration::from_secs(2), &draugr::RealSignaller).await;
                            let _ = c.wait().await;
                        })
                        .await;
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
                    () = time_up => {
                        let _ = std::fs::write(dir.join("why"), "timed-out");
                        if let Some(p) = meta.pid {
                            let _ = crate::clock::real(draugr::kill_group(
                                p,
                                Duration::from_secs(2),
                                &draugr::RealSignaller,
                            ))
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
        let mut summary = summary::summarise(
            CheckKind::from_name(&meta.kind),
            exit,
            &text,
            &dir.join("log").display().to_string(),
        );
        // rows that ran over several attempts: the split first
        if let Ok(line) = std::fs::read_to_string(dir.join(SPLIT)) {
            summary.lines.insert(0, line);
        }
        // a shared runner's output reaches the summary, and so the starter's wake, labelled untrusted
        if let Ok(runner) = std::fs::read_to_string(dir.join(SHARED)) {
            summary
                .lines
                .insert(0, crate::runners::returned::shared_label(runner.trim()));
        }
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
        self.queue.release(id);
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

    async fn stop(self: Arc<Self>, id: &str) -> Result<ExecRow, Error> {
        let meta = self.meta(id).ok_or_else(|| no_job(id))?;
        if meta.queued && self.end(id).is_none() {
            let (removed, outs) = self.queue.remove(id, now() as u64);
            if removed || self.queue.row(id).is_none() {
                // still waiting in the queue: it never starts
                let _ = std::fs::write(self.dir(id).join("why"), "stopped");
                self.finish(id).await;
                return self.row(id).ok_or_else(|| no_job(id));
            }
            // on a runner: cancelled there; its end comes back through the link (or at once when it can't be told)
            let mut events = self.events.subscribe();
            self.outcomes(outs);
            let _ = crate::clock::timeout(STOP_WAIT, async {
                while self.end(id).is_none() {
                    if let Err(tokio::sync::broadcast::error::RecvError::Closed) =
                        events.recv().await
                    {
                        break;
                    }
                }
            })
            .await;
            return self.row(id).ok_or_else(|| no_job(id));
        }
        if self.end(id).is_none() {
            // subscribed before the first look, so an end after it is an event this receiver holds
            let mut events = self.events.subscribe();
            let _ = std::fs::write(self.dir(id).join("why"), "stopped");
            if let (Some(p), Some(t)) = (meta.pid, meta.start_time)
                && unit::same_process(p, t)
            {
                let _ = draugr::kill_group(p, Duration::from_secs(2), &draugr::RealSignaller).await;
            }
            // the watcher records the end, then says so: wait for that, at most 5 s on the hub's clock
            let ended = crate::clock::timeout(STOP_WAIT, async {
                while self.end(id).is_none() {
                    if let Err(tokio::sync::broadcast::error::RecvError::Closed) =
                        events.recv().await
                    {
                        break;
                    }
                }
            });
            // test-hooks: the virtual clock stands still while the sequencer serves this step, so real time bounds
            // the wait too, and a wait that runs out fails the request, naming the job
            #[cfg(feature = "test-hooks")]
            if crate::clock::is_virtual() {
                if crate::clock::real_timeout(STOP_WAIT, ended).await.is_err() {
                    tracing::error!(
                        "job {id}: its end did not come within {STOP_WAIT:?} of real time of the stop"
                    );
                    return Err(error(
                        ErrorCode::Internal,
                        format!(
                            "job {id}: its end did not come within {} s of real time of the stop (the hub's clock \
                             stands still while a request is served)",
                            STOP_WAIT.as_secs()
                        ),
                    ));
                }
                return self.row(id).ok_or_else(|| no_job(id));
            }
            let _ = ended.await;
        }
        self.row(id).ok_or_else(|| no_job(id))
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
                // it still takes its room here
                if m.timebox_s.is_some() {
                    let own = forseti::Priority::from_number(m.priority.unwrap_or(1));
                    self.queue.adopt(&id, own, now() as u64);
                }
                let me = self.clone();
                crate::clock::spawn("exec:watch", async move {
                    crate::clock::real_long(me.watch(&id, None)).await;
                });
            }
        }
        // jobs that waited when the last hub ended wait again, oldest first
        waiting.sort_by(|a, b| a.0.total_cmp(&b.0));
        let me = self.clone();
        crate::clock::spawn(
            "exec:queue-restore",
            me.restore(waiting.into_iter().map(|(_, id)| id).collect()),
        );
        self.prune();
        // a podman client that died with the last hub leaves its container: remove those no running job owns
        if let Some(podman) = self.hooks.podman.clone() {
            let shell = self.hooks.shell_env.clone();
            crate::clock::blocking(move || container::remove_leftovers(&shell, &podman, &running));
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
        crate::clock::sleep(Duration::from_millis(100)).await;
    }
}

/// A job run with the user's rights in ENV: a user's job and (in the conformance lane) a session's.
fn plain_spec(spec: &ExecSpec, env: Vec<(OsString, OsString)>) -> draugr::Spec {
    draugr::Spec {
        program: PathBuf::from(&spec.argv[0]),
        args: spec.argv[1..].iter().map(OsString::from).collect(),
        env,
        cwd: Some(spec.cwd.clone()),
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    }
}

/// The base environment of a session's job run unsandboxed (the conformance lane): a short list of the hub's.
fn agent_plain_env(shell: &crate::shell_env::ShellEnv) -> Vec<(OsString, OsString)> {
    shell.build(
        &[
            "PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR", "SHELL",
        ],
        &["LC_", "CARGO", "RUST", "MISE_"],
        &[],
    )
}

/// The base environment of a user's job: SOURCE (the hub's environment with the login shell's overlay, as the editor's
/// jobs had the user manager's or Emacs's whole environment), less every name that looks like a key
/// (`refused_env_name`) and every provider's key variable (KEY_ENVS).
fn user_env(source: Vec<(OsString, OsString)>, key_envs: &[String]) -> Vec<(OsString, OsString)> {
    source
        .into_iter()
        .filter(|(k, _)| {
            k.to_str().is_some_and(|k| {
                !runstav::methods::hub::refused_env_name(k) && !key_envs.iter().any(|e| e == k)
            })
        })
        .collect()
}

/// Tests and `test-hooks` builds with `DRGNX_TEST_PLAIN_JOBS` set: the conformance container has no sandbox helper;
/// unit tests ask for it in their `Hooks`.
fn unsandboxed_for_tests(_hooks: &Hooks) -> bool {
    #[cfg(test)]
    if _hooks.plain_sessions {
        return true;
    }
    cfg!(any(test, feature = "test-hooks")) && std::env::var_os("DRGNX_TEST_PLAIN_JOBS").is_some()
}

/// The last megabyte of a log, as text.
fn tail_of(path: &Path) -> String {
    String::from_utf8_lossy(&tail_bytes(path, 1 << 20)).into_owned()
}

/// The last MAX bytes of the file at PATH (seeking from its end; nothing when it cannot be read).
fn tail_bytes(path: &Path, max: u64) -> Vec<u8> {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else {
        return Vec::new();
    };
    let len = f.metadata().map_or(0, |m| m.len());
    let mut buf = Vec::new();
    if f.seek(SeekFrom::Start(len.saturating_sub(max))).is_err()
        || f.take(max).read_to_end(&mut buf).is_err()
    {
        return Vec::new();
    }
    buf
}

/// The environment a session's job gets inside its sandbox: the tool paths, nothing else of the hub's.
fn tool_env(shell: &crate::shell_env::ShellEnv) -> Vec<(String, String)> {
    ["PATH", "LANG", "TERM", "CARGO_HOME", "RUSTUP_HOME"]
        .iter()
        .filter_map(|k| {
            shell
                .var_os(k)
                .and_then(|v| v.into_string().ok())
                .map(|v| (k.to_string(), v))
        })
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

/// The queue of every machine, opening the runner first when it is not open yet.
pub fn queue(f: &Front) -> Result<Arc<Queue>, Error> {
    runner(f)?
        .queue()
        .ok_or_else(|| error(ErrorCode::Internal, "exec: the queue is not open yet"))
}

fn runner(f: &Front) -> Result<&Runner, Error> {
    let r = &f.core.exec;
    if r.inner.get().is_none() {
        let dirs = f
            .dirs
            .get()
            .ok_or_else(|| error(ErrorCode::Internal, "exec: the store is not open yet"))?;
        let settings = f.settings.clone();
        let mut hooks = Hooks {
            writer: Some(f.writer.clone()),
            editors: Some(f.editors.clone()),
            shell_env: f.shell_env.clone(),
            // read at each start, so a provider added since is left out too (as `Front::provider_key_envs`)
            key_envs: Arc::new(move || {
                crate::settings::providers::effective(
                    &crate::settings::defaults().presets,
                    &settings.current().loaded.values.ai_providers,
                )
                .into_iter()
                .filter_map(|p| p.key_env.clone())
                .collect()
            }),
            ..Hooks::default()
        };
        if let Some((serde_json::Value::String(m), _)) =
            f.settings.effective("drgnx-agents-job-memory", None)
        {
            hooks.memory = m;
        }
        hooks.runtime = f.core.agents.db().cloned();
        // test-hooks: admission by this many slots (the fixed-slot path a macOS hub takes; 0: nothing is admitted)
        #[cfg(feature = "test-hooks")]
        if let Some(n) = std::env::var("DRGNX_TEST_JOB_SLOTS")
            .ok()
            .and_then(|n| n.parse().ok())
        {
            hooks.admission = Admission::Fixed(n);
        }
        r.open(dirs.hub.join("exec"), hooks);
        // the job keys' events go to the user's connections, their audit to the graph
        if let Some(q) = r.queue() {
            let editors = f.editors.clone();
            q.keys()
                .set_tell(move |event, data| editors.broadcast(event, data));
            q.keys()
                .set_sink(crate::runners::keys::graph_sink(f.writer.db.clone()));
        }
    }
    Ok(r)
}

/// The request's `machine`: `auto` (the default), `local`, or a runner the queue knows; any other name is refused.
fn machine(p: &StartParams, q: &Queue) -> Result<Machine, Error> {
    let m = Machine::parse(p.machine.as_ref().map(|m| m.as_str()));
    if let Machine::Runner(n) = &m
        && !q.has_runner(n)
    {
        return Err(error(
            ErrorCode::InvalidParams,
            format!("machine {n}: no runner {n} (`drgnx runner list` shows them)"),
        ));
    }
    Ok(m)
}

/// Where the request asks its job to run, and what its project's settings and the starter's `machines` cell say.
async fn placement(f: &Front, c: &Caller, p: &StartParams, m: Machine, runners: bool) -> Placement {
    let setting = |name: &str| f.settings.effective(name, None).map(|(v, _)| v);
    let send = setting("drgnx-runners-send")
        .and_then(|v| v.as_str().and_then(queue::SendMode::parse))
        .unwrap_or_default();
    let image = setting("drgnx-runners-image").and_then(|v| v.as_str().map(String::from));
    let weight = setting("drgnx-runners-weight")
        .and_then(|v| v.as_f64())
        .unwrap_or(1.0);
    let visibility = setting("drgnx-runners-project-visibility")
        .and_then(|v| v.as_str().map(crate::runners::sync::Visibility::parse))
        .unwrap_or_default();
    let shared_overlay =
        setting("drgnx-runners-shared-overlay").and_then(|v| v.as_bool()) == Some(true);
    let origin_key = setting("drgnx-runners-origin-key")
        .and_then(|v| v.as_str().map(String::from))
        .filter(|s| !s.is_empty());
    // the project's heavy patterns mark a job whose command line holds one; nothing else marks a job heavy
    let line = p
        .argv
        .iter()
        .map(|a| a.to_string())
        .collect::<Vec<_>>()
        .join(" ");
    let marked = setting("drgnx-runners-heavy")
        .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok())
        .unwrap_or_default()
        .iter()
        .any(|pat| !pat.is_empty() && line.contains(pat.as_str()));
    // the starter's `machines` cell: a session's job leaves this machine only on an Allow (an Ask keeps it here); the
    // user's always may. Asked only of a job that could leave at all, so a job that stays raises no card.
    let could_leave = runners
        && m != Machine::Local
        && p.local_only != Some(true)
        && (send == queue::SendMode::All
            || (send == queue::SendMode::Heavy && (p.heavy == Some(true) || marked)));
    let machines_cell = match &c.sid {
        None => true,
        Some(_) if !could_leave => true,
        Some(sid) => {
            let argv: Vec<String> = p.argv.iter().map(|a| a.to_string()).collect();
            let cwd = p
                .cwd
                .as_ref()
                .map(|c| PathBuf::from(c.as_str()))
                .unwrap_or_default();
            matches!(
                decide_session_job(f, sid, &cwd, &argv, norn::matrix::Action::Machines).await,
                crate::matrix_gate::Gate::Allow
            )
        }
    };
    Placement {
        machine: m,
        heavy: p.heavy == Some(true) || marked,
        keys: p
            .keys
            .iter()
            .flat_map(|k| k.iter())
            .map(|k| k.to_string())
            .collect(),
        local_only: p.local_only == Some(true),
        background: p.background == Some(true),
        writes: p
            .writes
            .iter()
            .flat_map(|w| w.iter())
            .map(|w| w.to_string())
            .collect(),
        priority: p.priority,
        send,
        machines_cell,
        image,
        weight,
        visibility,
        shared_overlay,
        origin_key,
        suite: None,
    }
}

/// The keys REQUESTED by name, when each is on the project's `drgnx-runners-job-keys` list and, for a session's job,
/// the matrix's `job.keys` allows it (an Ask refuses the start with its card, as `code.edit`'s does).
async fn job_keys(
    f: &Front,
    c: &Caller,
    p: &StartParams,
    cwd: &std::path::Path,
) -> Result<(), Error> {
    let names: Vec<String> = p
        .keys
        .iter()
        .flat_map(|k| k.iter())
        .map(|k| k.to_string())
        .collect();
    if names.is_empty() {
        return Ok(());
    }
    let list = f
        .settings
        .effective("drgnx-runners-job-keys", None)
        .and_then(|(v, _)| serde_json::from_value::<Vec<String>>(v).ok())
        .unwrap_or_default();
    crate::runners::keys::on_the_project_list(&names, &list)
        .map_err(|why| error(ErrorCode::InvalidParams, format!("keys: {why}")))?;
    if let Some(sid) = &c.sid {
        let argv: Vec<String> = p.argv.iter().map(|a| a.to_string()).collect();
        gate_session_job(f, sid, cwd, &argv, norn::matrix::Action::JobKeys).await?;
    }
    Ok(())
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
    // the hub sets an agent's job's priority; only the user's connections choose one
    if c.sid.is_some() && p.priority.is_some() {
        return Err(crate::agents::session::invalid(
            "priority",
            "only the user's connections set a job's priority (background lowers it)",
        ));
    }
    let r = runner(f)?;
    let q = r
        .inner()
        .map_err(|e| error(ErrorCode::Internal, e.message))?
        .queue
        .clone();
    let machine = machine(&p, &q)?;
    let runners = q.runners() > 0;
    let kind = match p.kind.unwrap_or(ExecKind::Other) {
        ExecKind::Cargo => CheckKind::Cargo,
        ExecKind::Ert => CheckKind::Ert,
        ExecKind::Domr => CheckKind::Domr,
        ExecKind::Other => CheckKind::Other,
        ExecKind::Container => CheckKind::Container,
    };
    let user = user_job(&c.sid, kind, &p)?;
    // a provider's key variable is refused as a key-like name is (the registry's check knows only the names)
    let key_envs = f.provider_key_envs();
    if let Some(i) = user.env.iter().position(|(n, _)| key_envs.contains(n)) {
        return Err(crate::agents::session::invalid(
            &format!("env[{i}].name"),
            format!(
                "{} is a provider's key variable and is not passed to a job",
                user.env[i].0
            ),
        ));
    }
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
    job_keys(f, c, &p, &cwd).await?;
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
    let place = placement(f, c, &p, machine, runners).await;
    let spec = ExecSpec {
        starter: c.sid.clone().map_or(Starter::User, Starter::Session),
        cwd,
        worktree,
        argv: p.argv.iter().map(|a| a.to_string()).collect(),
        timebox: requested_timebox(&p),
        kind,
        container,
        user,
        place,
    };
    let id = r
        .start(spec)
        .await
        .map_err(|r| error(ErrorCode::InvalidParams, r.message))?;
    let text = if r.is_queued(&id) {
        let why = r
            .get(&id)
            .and_then(|row| {
                row.waiting
                    .or(row.machine.map(|m| format!("it runs on {m}")))
            })
            .unwrap_or_else(|| "it waits for room".into());
        format!(
            "job {id} is queued ({why}); it starts when a machine admits it: end your turn, you will be woken with the result"
        )
    } else {
        format!("job {id} runs: end your turn; you will be woken with the result")
    };
    Ok(Started { text, id })
}

/// The time box a request asks for: its `timebox_s`, else an hour (a job that asked for none ignores it).
fn requested_timebox(p: &StartParams) -> Duration {
    Duration::from_secs(p.timebox_s.unwrap_or(3600))
}

/// What the user's request adds to its job.  An agent's request that sets any of it is refused (its job's limits are
/// the hub's); a container job takes no environment and no memory cap of its own (the image's caps apply); macOS has
/// no memory cap for a job.
fn user_job(sid: &Option<String>, kind: CheckKind, p: &StartParams) -> Result<UserJob, Error> {
    if sid.is_some()
        && let Some(field) = p.user_only_field()
    {
        return Err(error(
            ErrorCode::InvalidParams,
            format!("{field}: only the user sets this on a job"),
        ));
    }
    if kind == CheckKind::Container && (p.env.is_some() || p.memory_max.is_some()) {
        return Err(error(
            ErrorCode::InvalidParams,
            "a container job takes no env or memory_max: the image's caps apply",
        ));
    }
    if cfg!(target_os = "macos") && p.memory_max.is_some() {
        return Err(error(
            ErrorCode::InvalidParams,
            "memory_max: macOS has no memory cap for jobs",
        ));
    }
    Ok(UserJob {
        name: p.name.as_ref().map(|n| n.to_string()),
        env: p
            .env
            .iter()
            .flat_map(|v| v.iter())
            .map(|v| (v.name.as_str().to_string(), v.value.to_string()))
            .collect(),
        memory_max: p.memory_max.as_ref().map(|m| m.to_string()),
        nice: p.nice,
        no_timebox: p.no_timebox == Some(true),
    })
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

/// Job ID's row, when CALLER may see it: an agent only its own session's jobs (the user's hold the editor's argv, folders
/// and logs, and ids are easy to guess); the user and services every job.
fn visible(r: &Runner, c: &Caller, id: &str) -> Result<ExecRow, Error> {
    let row = r.get(id).ok_or_else(|| no_job(id))?;
    if matches!(c.class, runstav::registry::Class::Agent)
        && (c.sid.is_none() || row.session != c.sid)
    {
        return Err(error(
            ErrorCode::NotAllowed,
            format!("job {id} is not yours"),
        ));
    }
    Ok(row)
}

pub async fn get(f: &Front, c: &Caller, p: ById) -> Result<ExecRow, Error> {
    visible(runner(f)?, c, p.id.as_str())
}

pub async fn list(f: &Front, _: &Caller, p: ListParams) -> Result<Jobs, Error> {
    Ok(Jobs {
        jobs: runner(f)?.list(
            p.session.as_ref().map(|s| s.as_str()),
            p.running == Some(true),
        ),
    })
}

pub async fn stop(f: &Front, c: &Caller, p: ById) -> Result<ExecRow, Error> {
    let r = runner(f)?;
    visible(r, c, p.id.as_str())?;
    r.stop(p.id.as_str()).await
}

/// `exec/bump`: a queued job raised to priority 1 (classes `[User]`: the registry refuses every other connection).
pub async fn bump(f: &Front, _: &Caller, p: ById) -> Result<ExecRow, Error> {
    let id = p.id.as_str();
    runner(f)?.bump(id).ok_or_else(|| {
        error(
            ErrorCode::InvalidParams,
            format!("job {id} is not in the queue"),
        )
    })
}

pub async fn log(f: &Front, c: &Caller, p: LogParams) -> Result<LogSlice, Error> {
    let r = runner(f)?;
    let row = visible(r, c, p.id.as_str())?;
    let running = matches!(row.status, ExecStatus::Running | ExecStatus::Queued);
    if let Some(bytes) = p.tail_bytes {
        return Ok(LogSlice {
            lines: r.log_tail(p.id.as_str(), bytes),
            id: row.id,
            from: None,
            next: None,
            running,
        });
    }
    let from = p.from.unwrap_or(0);
    let n = p.n.unwrap_or(200) as usize;
    let mut lines = r.log_slice(p.id.as_str(), from as usize, n + 1);
    let more = lines.len() > n;
    lines.truncate(n);
    Ok(LogSlice {
        id: row.id,
        from: Some(from),
        next: more.then(|| from + n as u64),
        lines,
        running,
    })
}

#[cfg(test)]
mod tests;
