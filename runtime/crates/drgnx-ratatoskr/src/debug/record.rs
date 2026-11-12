//! Recorded runs (spec §19.2, D1): every session the hub starts is recorded against a snapshot of the files that ran.
//!
//! - **The launch snapshot.** Before the adapter starts, the project's files on disk are written as a tree into its
//!   shadow repository (the checkpoint machinery agent steps use, `timeline::snapshot`; content-addressed, so unchanged
//!   files cost nothing) and kept as `refs/drgnx/debug/<run>`. Buffers the editor said were modified and unsaved are
//!   marked "not what ran".
//! - **Stops** are captured from what the session already fetched (its threads, frames, the selected frame's scopes
//!   and their first page of variables), capped at [`CAPTURE_MAX`] a stop ([`capture`]).
//! - **Probe hits** ([`super::probes`]) come out of the adapter's `output` events, are thinned above the adapter's rate
//!   cap (not in forks) and go to the editors batched (`debug-probe-hits`, at most 20 a second).
//! - **Storage.** The bulk goes to the run file ([`super::runfile`], `<state>/debug/runs/<run>.drun`); the run itself
//!   is a [`RunMeta`] beside it (`<run>.json`) and an Urdr record of kind `debug_run` ([`RunSink`]).
//! - **Retention** ([`Records::prune`]): 14 days after its end, unless pinned or linked to an open task, and at most
//!   2 GB of run files per project (the oldest go first).
//!
//! Run files hold the program's values unredacted: they are the user's, read only through the user-class `debug/run*`
//! methods.

use super::Sink;
use super::probes::{self, Probes, Rate};
use super::runfile::{self, Reader, RunFile};
pub use super::runfile::{Frame, RunHit, RunStop};
use super::runkey::{self, FileKey, SALT_LEN};
use super::session::{End, Op, Stop};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// The largest capture of one stop, in bytes of JSON.
pub const CAPTURE_MAX: usize = 64 * 1024;
/// How long an ended run is kept.
pub const RETENTION: Duration = Duration::from_secs(14 * 24 * 3600);
/// The run files one project keeps at most, in bytes.
pub const PROJECT_CAP: u64 = 2 * 1024 * 1024 * 1024;
/// How often the batched hits go to the editors.
pub const HITS_EVERY: Duration = Duration::from_millis(50);
/// The largest file text `debug/run/stop` sends.
pub const SOURCE_MAX: usize = 4 * 1024 * 1024;

/// The hash of a resolved configuration (`launch::substitute`'s output, before `adapter_arguments`): xxh3 of its JSON
/// with object keys sorted at every level. A fork re-resolves the configuration and refuses on a different hash.
pub fn config_hash(v: &Value) -> String {
    let mut bytes = Vec::new();
    canonical(v, &mut bytes);
    format!("{:016x}", xxhash_rust::xxh3::xxh3_64(&bytes))
}

/// V as compact JSON with object keys sorted (by their bytes), at every level.
fn canonical(v: &Value, out: &mut Vec<u8>) {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push(b'{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                let _ = serde_json::to_writer(&mut *out, k);
                out.push(b':');
                canonical(&m[k], out);
            }
            out.push(b'}');
        }
        Value::Array(a) => {
            out.push(b'[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                canonical(x, out);
            }
            out.push(b']');
        }
        _ => {
            let _ = serde_json::to_writer(&mut *out, v);
        }
    }
}

/// Where a run's launch snapshot is, as `timeline::snapshot::restore_into` takes it: the checkpoints folder, the
/// project (the shadow repository's worktree) and the tree.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunSnapshot {
    pub checkpoints: PathBuf,
    pub source: PathBuf,
    pub tree: String,
}

/// A probe as the run had it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunProbe {
    pub id: String,
    pub path: String,
    pub line: u32,
    pub expr: String,
}

/// Everything a fork (D2) needs of a run.
#[derive(Clone, Debug, PartialEq)]
pub struct RunInfo {
    pub id: String,
    pub root: String,
    /// The `debug/start` parameters as the editor sent them, without the input answers.
    pub start: Value,
    pub config_hash: Option<String>,
    pub adapter_id: String,
    /// `launch` or `attach`.
    pub request: String,
    pub snapshot: Option<RunSnapshot>,
    /// The `PYTHONHASHSEED` the run had.
    pub hash_seed: Option<u32>,
    /// From the launch to the first stop.
    pub to_stop_ms: Option<u64>,
    pub stops: Vec<RunStop>,
    pub probes: Vec<RunProbe>,
    pub hits: Vec<RunHit>,
}

/// The runs, by id.
pub trait Runs: Send + Sync {
    fn run(&self, id: &str) -> Option<RunInfo>;
    /// What run ID recorded at its stop INDEX (the capture: frames, scopes), when it has that stop.
    fn capture(&self, _id: &str, _index: u64) -> Option<Value> {
        None
    }
}

/// A run: its record (`<run>.json`, and the Urdr record's data).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RunMeta {
    pub id: String,
    /// Its number in the project ("Run 4").
    pub n: u64,
    pub root: String,
    pub session: String,
    pub name: String,
    pub adapter_id: String,
    pub request: String,
    #[serde(default)]
    pub config_hash: Option<String>,
    #[serde(default)]
    pub start: Value,
    #[serde(default)]
    pub snapshot: Option<RunSnapshot>,
    /// git HEAD at the launch.
    #[serde(default)]
    pub head: Option<String>,
    /// Files modified in the editor and unsaved at the launch: not what ran.
    #[serde(default)]
    pub unsaved: Vec<String>,
    #[serde(default)]
    pub hash_seed: Option<u32>,
    pub started: f64,
    #[serde(default)]
    pub ended: Option<f64>,
    #[serde(default)]
    pub outcome: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub to_stop_ms: Option<u64>,
    #[serde(default)]
    pub stops: u64,
    #[serde(default)]
    pub hits: u64,
    /// Hits over the rate cap, not kept.
    #[serde(default)]
    pub thinned: u64,
    /// Hits dropped to stay under the file's cap.
    #[serde(default)]
    pub dropped: u64,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub task: Option<String>,
    #[serde(default)]
    pub probes: Vec<RunProbe>,
    /// The adapter stops, evaluates and resumes at every hit (delve, lldb-dap): the lane says so.
    #[serde(default)]
    pub stops_to_probe: bool,
    /// A fork's run (no thinning).
    #[serde(default)]
    pub fork: bool,
    #[serde(default)]
    pub size: u64,
}

/// Where a run's record goes besides its file: the Urdr record (kind `debug_run`).
pub trait RunSink: Send + Sync {
    fn put(&self, meta: &RunMeta);
    fn gone(&self, _id: &str) {}
}

/// No record outside the runs folder.
pub struct NoRecords;

impl RunSink for NoRecords {
    fn put(&self, _: &RunMeta) {}
}

/// What a launch adds to its run.
#[derive(Clone, Debug, Default)]
pub struct Launch {
    pub config_hash: Option<String>,
    /// `debug/start`'s parameters, without the input answers.
    pub start: Value,
    pub unsaved: Vec<String>,
    /// A fork's run: no thinning.
    pub fork: bool,
    /// The `PYTHONHASHSEED` to use (a fork's, the run's it replays); none: the hub picks one.
    pub hash_seed: Option<u32>,
    /// The task the run is for (an agent working in the project): its run is kept while the task is open.
    pub task: Option<String>,
}

/// Where the records go.
pub struct Opts {
    /// `<state>/debug/runs`.
    pub runs: PathBuf,
    /// The checkpoints folder (`<state>/hub/checkpoints`).
    pub checkpoints: PathBuf,
    /// Where each project's probes are saved (none: memory only).
    pub probes: Option<PathBuf>,
    pub store: Arc<dyn RunSink>,
    /// Whether a task is still open (its runs are kept).
    pub task_open: Arc<dyn Fn(String) -> super::BoxFut<'static, bool> + Send + Sync>,
    /// A run file's cap.
    pub file_cap: u64,
    pub project_cap: u64,
    /// The runs' key (spec §19.2): the hub's is the user's keyring ([`super::runkey::os`]); by default one in
    /// memory, made on the first run (tests).
    pub key: Arc<dyn super::runkey::KeyStore>,
}

impl Opts {
    /// The defaults for a runs folder and a checkpoints folder.
    pub fn new(runs: PathBuf, checkpoints: PathBuf) -> Opts {
        Opts {
            runs,
            checkpoints,
            probes: None,
            store: Arc::new(NoRecords),
            task_open: Arc::new(|_| Box::pin(async { false })),
            file_cap: runfile::CAP,
            project_cap: PROJECT_CAP,
            key: Arc::new(super::runkey::Memory::default()),
        }
    }
}

/// A stop as the run keeps it: everything the session fetched for it, cut to CAPTURE_MAX (variables first, from the
/// last scope's end, then frames past the selected one, then threads); `cut` counts what was left out.
pub fn capture(stop: &Stop) -> Value {
    let mut scopes: Vec<(Value, Option<Vec<Value>>)> = stop
        .scopes
        .iter()
        .map(|s| (s.scope.clone(), s.variables.clone()))
        .collect();
    let mut frames = stop.frames.clone();
    let mut threads = stop.threads.clone();
    let build = |scopes: &[(Value, Option<Vec<Value>>)],
                 frames: &[Value],
                 threads: &[Value],
                 cut: u64| {
        json!({
            "epoch": stop.epoch,
            "thread": stop.thread,
            "reason": stop.reason,
            "description": stop.description,
            "threads": threads,
            "frames": frames,
            "total_frames": stop.total_frames,
            "frame": stop.frame,
            "scopes": scopes.iter().map(|(s, v)| json!({"scope": s, "variables": v})).collect::<Vec<_>>(),
            "cut": cut,
        })
    };
    let size = |v: &Value| serde_json::to_vec(v).map_or(0, |b| b.len());
    let mut cut = 0u64;
    let mut v = build(&scopes, &frames, &threads, cut);
    let mut over = size(&v).saturating_sub(CAPTURE_MAX);
    if over == 0 {
        return v;
    }
    // what each removal saves, estimated (its own JSON and a comma), then checked once at the end
    'vars: for (_, vars) in scopes.iter_mut().rev() {
        let Some(vars) = vars else { continue };
        while let Some(x) = vars.pop() {
            cut += 1;
            over = over.saturating_sub(size(&x) + 1);
            if over == 0 {
                break 'vars;
            }
        }
    }
    let keep = frames
        .iter()
        .position(|f| f.get("id").and_then(Value::as_i64) == Some(stop.frame))
        .unwrap_or(0)
        + 1;
    while over > 0 && frames.len() > keep {
        let f = frames.pop().unwrap_or_default();
        cut += 1;
        over = over.saturating_sub(size(&f) + 1);
    }
    while over > 0 && threads.len() > 1 {
        let t = threads.pop().unwrap_or_default();
        cut += 1;
        over = over.saturating_sub(size(&t) + 1);
    }
    v = build(&scopes, &frames, &threads, cut);
    // the estimate missed (escapes, the number's width): drop whole scopes' variables until it fits
    for i in (0..scopes.len()).rev() {
        if size(&v) <= CAPTURE_MAX {
            break;
        }
        if let Some(vars) = scopes[i].1.take() {
            cut += vars.len() as u64;
            v = build(&scopes, &frames, &threads, cut);
        }
    }
    v
}

/// The top frame's path and line of STOP.
fn top(stop: &Stop) -> (String, u32) {
    let f = stop.frames.first();
    (
        f.and_then(|f| f.pointer("/source/path"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        f.and_then(|f| f.get("line"))
            .and_then(Value::as_u64)
            .and_then(|l| u32::try_from(l).ok())
            .unwrap_or(0),
    )
}

/// A run being recorded.
struct Live {
    meta: RunMeta,
    file: RunFile,
    t0: tokio::time::Instant,
    seq: u64,
    rate: Rate,
    bp_hits: BTreeMap<(String, u32), u32>,
    steps: Vec<String>,
    /// (session, epoch) already recorded: a stop published again (a frame selected) is not a new stop.
    seen: BTreeSet<(String, u64)>,
}

impl Live {
    fn t_ms(&self) -> u64 {
        u64::try_from(crate::clock::now().duration_since(self.t0).as_millis()).unwrap_or(u64::MAX)
    }
}

/// The hub's recorded runs and its projects' probes.
pub struct Records {
    opts: Opts,
    sink: Arc<dyn Sink>,
    live: Mutex<BTreeMap<String, Live>>,
    /// Session → its run (children's sessions record into their root's).
    sessions: Mutex<BTreeMap<String, String>>,
    probes: Mutex<BTreeMap<String, Probes>>,
    /// Hits not yet sent to the editors, per run.
    pending: Mutex<BTreeMap<String, Vec<Value>>>,
    sending: AtomicBool,
    next: AtomicU64,
    /// One launch snapshot at a time (they share the shadow repository's index).
    snap: Arc<Mutex<()>>,
    /// The keyring's key, once read (none: the runs on disk cannot be read and nothing is recorded).
    key: Mutex<Option<runkey::Key>>,
    /// What the sessions' events record (stops, steps, hits, ends), in order and off the hub's workers: those write
    /// the run files.
    disk: crate::disk::Ordered,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A name safe as a file name and in a ref.
fn safe(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

impl Records {
    pub fn new(opts: Opts, sink: Arc<dyn Sink>) -> Arc<Records> {
        Arc::new(Records {
            opts,
            sink,
            live: Mutex::new(BTreeMap::new()),
            sessions: Mutex::new(BTreeMap::new()),
            probes: Mutex::new(BTreeMap::new()),
            pending: Mutex::new(BTreeMap::new()),
            sending: AtomicBool::new(false),
            next: AtomicU64::new(0),
            snap: Arc::new(Mutex::new(())),
            key: Mutex::new(None),
            disk: crate::disk::Ordered::reporting(
                "debug:record",
                |what, e| tracing::warn!(target: "drgnx::debug", "{what}: {e}"),
            ),
        })
    }

    /// F on the recorder after everything queued before it, off the hub's workers (it may write the run files).
    pub fn later(self: &Arc<Self>, what: &str, f: impl FnOnce(&Arc<Records>) + Send + 'static) {
        let me = self.clone();
        self.disk.push(what.to_owned(), move || {
            f(&me);
            Ok(())
        });
    }

    /// Everything queued for the recorder so far is done: what reads the runs sees it.
    pub async fn written(&self) {
        self.disk.written().await;
    }

    fn file(&self, id: &str, ext: &str) -> PathBuf {
        self.opts.runs.join(format!("{id}.{ext}"))
    }

    /// F on ROOT's probes.
    pub fn probes<R>(&self, root: &str, f: impl FnOnce(&mut Probes) -> R) -> R {
        let mut all = lock(&self.probes);
        let p = all.entry(root.to_owned()).or_insert_with(|| {
            Probes::open(self.opts.probes.as_ref().map(|d| {
                d.join(format!(
                    "{:016x}.json",
                    xxhash_rust::xxh3::xxh3_64(root.as_bytes())
                ))
            }))
        });
        f(p)
    }

    /// Start recording session SESSION of ROOT: the launch snapshot, the probes, `PYTHONHASHSEED` on a Python launch
    /// (in START's arguments); the run's id.
    pub async fn begin(
        self: &Arc<Self>,
        session: &str,
        root: &str,
        start: &mut super::session::Start,
        launch: Launch,
    ) -> String {
        let ms = (crate::clock::wall_secs() * 1000.0) as u64;
        let id = format!("r{ms}-{}", self.next.fetch_add(1, Ordering::Relaxed) + 1);
        // no key, no recording: nothing the program holds is written in the clear
        let key = match self.key_to_record().await {
            Ok(k) => k,
            Err(u) => {
                let why = u.why();
                tracing::info!(target: "drgnx::debug", "session {session} not recorded: {why}");
                self.sink.broadcast(
                    "debug-recording-off",
                    json!({"session": session, "root": root, "why": why}),
                    None,
                );
                return id;
            }
        };
        let n = self.list(root).iter().map(|m| m.n).max().unwrap_or(0) + 1;
        let snapshot = self.snapshot(root, &id).await;
        let hash_seed = if probes::lang(&start.adapter_id) == probes::Lang::Python
            && start.request == super::session::Request::Launch
        {
            Some(seed(&mut start.arguments, launch.hash_seed, &id))
        } else {
            None
        };
        let probes: Vec<RunProbe> = self.probes(root, |p| {
            p.list()
                .iter()
                .filter(|p| p.enabled)
                .map(|p| RunProbe {
                    id: p.id.clone(),
                    path: p.path.clone(),
                    line: p.line,
                    expr: p.expr.clone(),
                })
                .collect()
        });
        let meta = RunMeta {
            id: id.clone(),
            n,
            root: root.to_owned(),
            session: session.to_owned(),
            name: start.name.clone(),
            adapter_id: start.adapter_id.clone(),
            request: match start.request {
                super::session::Request::Launch => "launch".into(),
                super::session::Request::Attach => "attach".into(),
            },
            config_hash: launch.config_hash,
            start: launch.start,
            snapshot,
            head: crate::timeline::snapshot::head_of(Path::new(root)),
            unsaved: launch.unsaved,
            hash_seed,
            started: crate::clock::wall_secs(),
            task: launch.task,
            probes,
            stops_to_probe: probes::stops_to_probe(&start.adapter_id),
            fork: launch.fork,
            ..RunMeta::default()
        };
        let file = match RunFile::create(&self.file(&id, "drun"), self.opts.file_cap, &key) {
            Ok(f) => f,
            Err(e) => {
                tracing::warn!(target: "drgnx::debug", "run {id} not recorded: {e}");
                return id;
            }
        };
        self.write_meta(&meta);
        self.put(&meta);
        let rate = Rate::new((!launch.fork).then(|| probes::cap(&start.adapter_id)));
        lock(&self.live).insert(
            id.clone(),
            Live {
                meta,
                file,
                t0: crate::clock::now(),
                seq: 0,
                rate,
                bp_hits: BTreeMap::new(),
                steps: vec![],
                seen: BTreeSet::new(),
            },
        );
        lock(&self.sessions).insert(session.to_owned(), id.clone());
        self.publish(&id, None);
        id
    }

    /// The launch snapshot of ROOT for run ID, kept as `refs/drgnx/debug/<id>`.
    async fn snapshot(&self, root: &str, id: &str) -> Option<RunSnapshot> {
        let checkpoints = self.opts.checkpoints.clone();
        let source = PathBuf::from(root);
        let (c, s, name) = (
            checkpoints.clone(),
            source.clone(),
            format!("refs/drgnx/debug/{id}"),
        );
        let held = self.snap.clone();
        let r = crate::clock::blocking(move || {
            let _one = lock(&held);
            crate::timeline::snapshot::take_kept(&c, &s, "debug", &name)
        })
        .await;
        match r {
            Ok(Ok(tree)) => Some(RunSnapshot {
                checkpoints,
                source,
                tree,
            }),
            Ok(Err(e)) => {
                tracing::warn!(target: "drgnx::debug", "launch snapshot of {root}: {e}");
                None
            }
            Err(_) => None,
        }
    }

    /// CHILD (a `startDebugging` child of PARENT) records into PARENT's run.
    pub fn attach(&self, child: &str, parent: &str) {
        let mut s = lock(&self.sessions);
        if let Some(run) = s.get(parent).cloned() {
            s.insert(child.to_owned(), run);
        }
    }

    fn run_of(&self, session: &str) -> Option<String> {
        lock(&self.sessions).get(session).cloned()
    }

    /// The session asked for OP: steps are kept for the next stops (a fork repeats them).
    pub fn op(&self, session: &str, op: &Op) {
        let step = match op {
            Op::Next { .. } => "next",
            Op::StepIn { .. } => "in",
            Op::StepOut { .. } => "out",
            Op::Instruction { step: "in", .. } => "in-i",
            Op::Instruction { step: "out", .. } => "out-i",
            Op::Instruction { .. } => "next-i",
            _ => return,
        };
        let Some(run) = self.run_of(session) else {
            return;
        };
        if let Some(l) = lock(&self.live).get_mut(&run) {
            l.steps.push(step.to_owned());
        }
    }

    /// SESSION stopped (STOP): recorded once per stop.
    pub fn stop(&self, session: &str, stop: &Stop) {
        let Some(run) = self.run_of(session) else {
            return;
        };
        let rs = {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(&run) else { return };
            if !l.seen.insert((session.to_owned(), stop.epoch)) {
                return;
            }
            let (path, line) = top(stop);
            let t_ms = l.t_ms();
            l.seq += 1;
            let bp = stop.reason == "breakpoint";
            let bp_hit = bp.then(|| {
                let n = l.bp_hits.entry((path.clone(), line)).or_default();
                *n += 1;
                *n
            });
            let steps = if bp {
                std::mem::take(&mut l.steps)
            } else {
                l.steps.clone()
            };
            let rs = RunStop {
                index: l.seq,
                t_ms,
                reason: stop.reason.clone(),
                thread: stop.thread,
                path,
                line,
                bp_hit,
                steps: if bp { vec![] } else { steps },
                session: session.to_owned(),
            };
            if l.meta.to_stop_ms.is_none() {
                l.meta.to_stop_ms = Some(t_ms);
            }
            l.meta.stops += 1;
            l.file.append(Frame::Stop {
                stop: rs.clone(),
                capture: capture(stop),
            });
            // a stop is read back at once (the strip's newest): its block is written now
            l.file.flush();
            rs
        };
        self.publish(&run, Some(&rs));
    }

    /// SESSION's `output` event BODY: its probe hits are recorded; the event as the console should see it (none when
    /// every line was a hit).
    pub fn output(self: &Arc<Self>, session: &str, body: &Value) -> Option<Value> {
        let text = body
            .get("output")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (hits, rest) = probes::split(text);
        if hits.is_empty() {
            return Some(body.clone());
        }
        if let Some(run) = self.run_of(session) {
            self.later("probe hits", move |r| r.hits(&run, hits));
        }
        if rest.is_empty() {
            return None;
        }
        let mut b = body.clone();
        b["output"] = json!(rest);
        Some(b)
    }

    fn hits(self: &Arc<Self>, run: &str, hits: Vec<(String, String, String)>) {
        let mut sent = vec![];
        {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(run) else { return };
            for (probe, thread, value) in hits {
                let t_ms = l.t_ms();
                if !l.rate.admit(Duration::from_millis(t_ms)) {
                    l.meta.thinned = l.rate.thinned;
                    continue;
                }
                l.seq += 1;
                let h = RunHit {
                    probe,
                    thread,
                    value,
                    seq: l.seq,
                    t_ms,
                };
                if l.file.append(Frame::Hit(h.clone())) {
                    l.meta.hits += 1;
                    sent.push(json!({"probe": h.probe, "thread": h.thread, "value": h.value, "seq": h.seq, "t": h.t_ms}));
                } else {
                    l.meta.dropped += 1;
                }
            }
        }
        if sent.is_empty() {
            return;
        }
        lock(&self.pending)
            .entry(run.to_owned())
            .or_default()
            .extend(sent);
        if !self.sending.swap(true, Ordering::AcqRel) {
            let me = self.clone();
            crate::clock::spawn("debug:probe-hits", async move {
                crate::clock::sleep(HITS_EVERY).await;
                me.send_hits();
            });
        }
    }

    /// The batched hits go to the editors (`debug-probe-hits`), one event per run.
    fn send_hits(&self) {
        self.sending.store(false, Ordering::Release);
        let batches = std::mem::take(&mut *lock(&self.pending));
        for (run, hits) in batches {
            let (thinned, dropped) = lock(&self.live).get(&run).map_or((0, 0), |l| {
                (l.meta.thinned, l.meta.dropped + l.file.index().dropped)
            });
            self.sink.broadcast(
                "debug-probe-hits",
                json!({"run": run, "hits": hits, "thinned": thinned, "dropped": dropped}),
                None,
            );
        }
    }

    /// SESSION ended (END): a run's own session ends the run (and the runs past their time go).
    pub fn end(self: &Arc<Self>, session: &str, end: &End) {
        let Some(run) = lock(&self.sessions).remove(session) else {
            return;
        };
        let Some(mut l) = ({
            let mut live = lock(&self.live);
            if live.get(&run).is_some_and(|l| l.meta.session == session) {
                live.remove(&run)
            } else {
                None
            }
        }) else {
            return;
        };
        lock(&self.sessions).retain(|_, r| *r != run);
        self.send_hits();
        l.file.flush();
        l.meta.ended = Some(crate::clock::wall_secs());
        l.meta.outcome = Some(end.reason.clone());
        l.meta.exit_code = end.exit_code;
        l.meta.dropped += l.file.index().dropped;
        l.meta.size = l.file.size();
        self.write_meta(&l.meta);
        self.put(&l.meta);
        self.sink
            .broadcast("debug-run", run_event(&l.meta, "ended", None), None);
        let me = self.clone();
        crate::clock::spawn("debug:prune-runs", async move {
            me.prune(crate::clock::wall_secs()).await;
        });
    }

    fn publish(&self, run: &str, stop: Option<&RunStop>) {
        let ev = lock(&self.live)
            .get(run)
            .map(|l| run_event(&l.meta, "recording", stop));
        if let Some(ev) = ev {
            self.sink.broadcast("debug-run", ev, None);
        }
    }

    /// META to the graph, without its start (the launch's values stay sealed in the run's files).
    fn put(&self, meta: &RunMeta) {
        let mut m = meta.clone();
        m.start = Value::Null;
        self.opts.store.put(&m);
    }

    /// META to its record on disk; false: no key to seal it with.
    fn write_meta(&self, meta: &RunMeta) -> bool {
        let _ = std::fs::create_dir_all(&self.opts.runs);
        let Some(key) = lock(&self.key).clone() else {
            return false;
        };
        let mut sealed = meta.clone();
        sealed.start = seal_start(&key, &meta.start);
        let text = serde_json::to_string(&sealed).unwrap_or_default();
        if let Err(e) = crate::records::write_atomic(&self.file(&meta.id, "json"), &text) {
            tracing::warn!(target: "drgnx::debug", "run {}: {e}", meta.id);
        }
        true
    }

    fn read_meta(&self, id: &str) -> Option<RunMeta> {
        if !safe(id) {
            return None;
        }
        if let Some(l) = lock(&self.live).get(id) {
            return Some(l.meta.clone());
        }
        let t = std::fs::read_to_string(self.file(id, "json")).ok()?;
        serde_json::from_str(&t).ok().map(|m| self.opened(m))
    }

    /// META read from disk, its start opened (none: the key is not there).
    fn opened(&self, mut meta: RunMeta) -> RunMeta {
        meta.start = lock(&self.key)
            .as_ref()
            .and_then(|k| open_start(k, &meta.start))
            .unwrap_or(Value::Null);
        meta
    }

    /// Read the key for the runs on disk, never making one and never asking (none yet: nothing to read).
    pub async fn unlock(&self) -> Result<(), runkey::Unavailable> {
        if lock(&self.key).is_some() {
            return Ok(());
        }
        let k = self.opts.key.key(false).await?;
        *lock(&self.key) = Some(k);
        Ok(())
    }

    /// The key to record with: the one read, else the keyring's (made there if it has none: an unlocked keyring
    /// only).
    async fn key_to_record(&self) -> Result<runkey::Key, runkey::Unavailable> {
        if let Some(k) = lock(&self.key).clone() {
            return Ok(k);
        }
        let k = self.opts.key.key(true).await?;
        *lock(&self.key) = Some(k.clone());
        Ok(k)
    }

    /// Every run's record (ROOT's only, unless empty), newest first.
    pub fn list(&self, root: &str) -> Vec<RunMeta> {
        let live = lock(&self.live);
        let mut v: Vec<RunMeta> = std::fs::read_dir(&self.opts.runs)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| std::fs::read_to_string(e.path()).ok())
            .filter_map(|t| serde_json::from_str::<RunMeta>(&t).ok())
            .filter(|m| root.is_empty() || m.root == root)
            .map(|mut m| {
                // the summary: its start stays sealed
                m.start = Value::Null;
                live.get(&m.id).map_or(m, |l| l.meta.clone())
            })
            .collect();
        v.sort_by(|a, b| b.started.total_cmp(&a.started).then(b.n.cmp(&a.n)));
        v
    }

    /// Run ID's file read back (a live run's pending frames written first).
    fn reader(&self, id: &str) -> Result<Reader, String> {
        if !safe(id) {
            return Err(format!("no run {id}"));
        }
        if let Some(l) = lock(&self.live).get_mut(id) {
            l.file.flush();
        }
        let Some(key) = lock(&self.key).clone() else {
            return Err(format!("run {id} cannot be read until the keyring unlocks"));
        };
        Reader::open(&self.file(id, "drun"), &key).map_err(|e| match e {
            runfile::Unread::Io(_) => format!("run {id} has no file"),
            e @ runfile::Unread::Sealed => format!("run {id} {e}"),
        })
    }

    /// Pin or unpin run ID (a pinned run is kept past the retention).
    pub fn pin(&self, id: &str, pinned: bool) -> Result<(), String> {
        let mut meta = self.read_meta(id).ok_or_else(|| format!("no run {id}"))?;
        if lock(&self.key).is_none() {
            return Err(format!(
                "run {id} cannot be changed until the keyring unlocks"
            ));
        }
        meta.pinned = pinned;
        if let Some(l) = lock(&self.live).get_mut(id) {
            l.meta.pinned = pinned;
        }
        self.write_meta(&meta);
        self.put(&meta);
        Ok(())
    }

    /// Run ID for the strip: its record, its stops FROM (0-based) up to COUNT, and the probes' lanes with the hits
    /// between the first and the last of those stops (all of them when the page reaches the run's end), at most
    /// LANE_MAX a probe (the newest).
    pub fn get(&self, id: &str, from: usize, count: usize) -> Result<Value, String> {
        const LANE_MAX: usize = 2000;
        let meta = self.read_meta(id).ok_or_else(|| format!("no run {id}"))?;
        let r = self.reader(id)?;
        let all = &r.index.stops;
        let page: Vec<&RunStop> = all.iter().skip(from).take(count).collect();
        let lo = if from == 0 {
            0
        } else {
            page.first().map_or(u64::MAX, |s| s.index)
        };
        let hi = if from + page.len() >= all.len() {
            u64::MAX
        } else {
            page.last().map_or(0, |s| s.index)
        };
        let mut lanes: BTreeMap<String, Vec<Value>> =
            meta.probes.iter().map(|p| (p.id.clone(), vec![])).collect();
        for (i, b) in r.index.blocks.iter().enumerate() {
            if b.hits == 0 || b.last < lo || b.first > hi {
                continue;
            }
            for f in r.block(i).unwrap_or_default() {
                if let Frame::Hit(h) = f
                    && h.seq >= lo
                    && h.seq <= hi
                {
                    lanes.entry(h.probe.clone()).or_default().push(
                        json!({"seq": h.seq, "t": h.t_ms, "thread": h.thread, "value": h.value}),
                    );
                }
            }
        }
        let lanes: Vec<Value> = lanes
            .into_iter()
            .map(|(probe, mut hits)| {
                let total = hits.len();
                if total > LANE_MAX {
                    hits.drain(..total - LANE_MAX);
                }
                let p = meta.probes.iter().find(|p| p.id == probe);
                json!({"probe": probe, "expr": p.map(|p| &p.expr), "path": p.map(|p| &p.path),
                       "line": p.map(|p| p.line), "hits": hits, "shown_from": total.saturating_sub(LANE_MAX)})
            })
            .collect();
        Ok(json!({
            "run": meta,
            "stops": page,
            "total": all.len(),
            "lanes": lanes,
            "more": from + page.len() < all.len(),
        }))
    }

    /// Stop INDEX of run ID: its capture, the snapshot's tree, and FILE's text as it ran (the stop's top frame's file
    /// when none), marked when it was unsaved in the editor at the launch.
    pub fn past_stop(&self, id: &str, index: u64, file: Option<&str>) -> Result<Value, String> {
        let meta = self.read_meta(id).ok_or_else(|| format!("no run {id}"))?;
        let r = self.reader(id)?;
        let (stop, capture) = r
            .stop(index)
            .ok_or_else(|| format!("run {id} has no stop {index}"))?;
        let path = file.map_or_else(|| stop.path.clone(), str::to_owned);
        let source = meta.snapshot.as_ref().and_then(|s| {
            let rel = Path::new(&path).strip_prefix(&s.source).ok()?;
            let bytes = crate::timeline::snapshot::blob(
                &s.checkpoints,
                &s.source,
                &s.tree,
                &rel.to_string_lossy(),
            )
            .ok()?;
            (bytes.len() <= SOURCE_MAX).then(|| String::from_utf8_lossy(&bytes).into_owned())
        });
        Ok(json!({
            "run": id,
            "stop": stop,
            "capture": capture,
            "snapshot": meta.snapshot.as_ref().map(|s| &s.tree),
            "source": {"path": path, "text": source, "not_what_ran": meta.unsaved.contains(&path)},
        }))
    }

    /// Runs past their time, and a project's oldest past its cap, removed with their snapshot refs: NOW in seconds
    /// since the epoch. Live, pinned and open-task runs are kept.
    pub async fn prune(&self, now: f64) -> Vec<String> {
        let all = self.list("");
        let live: BTreeSet<String> = lock(&self.live).keys().cloned().collect();
        let tasks: BTreeSet<String> = all.iter().filter_map(|m| m.task.clone()).collect();
        let mut open = BTreeSet::new();
        for t in tasks {
            if (self.opts.task_open)(t.clone()).await {
                open.insert(t);
            }
        }
        let keep = |m: &RunMeta| {
            live.contains(&m.id)
                || m.ended.is_none()
                || m.pinned
                || m.task.as_ref().is_some_and(|t| open.contains(t))
        };
        let mut gone = vec![];
        let mut by_root: BTreeMap<String, Vec<&RunMeta>> = BTreeMap::new();
        for m in &all {
            if !keep(m) && m.ended.is_some_and(|e| now - e > RETENTION.as_secs_f64()) {
                gone.push(m.id.clone());
            } else {
                by_root.entry(m.root.clone()).or_default().push(m);
            }
        }
        for runs in by_root.values() {
            let size = |m: &RunMeta| {
                std::fs::metadata(self.file(&m.id, "drun")).map_or(m.size, |x| x.len())
            };
            let mut total: u64 = runs.iter().map(|m| size(m)).sum();
            // newest first: the oldest are at the end
            for m in runs.iter().rev() {
                if total <= self.opts.project_cap {
                    break;
                }
                if keep(m) {
                    continue;
                }
                total = total.saturating_sub(size(m));
                gone.push(m.id.clone());
            }
        }
        for id in &gone {
            let meta = all.iter().find(|m| &m.id == id);
            for ext in ["drun", "drun.idx", "json"] {
                let _ = std::fs::remove_file(self.file(id, ext));
            }
            if let Some(s) = meta.and_then(|m| m.snapshot.as_ref()) {
                let _ = crate::timeline::snapshot::drop_kept(
                    &s.checkpoints,
                    &s.source,
                    &format!("refs/drgnx/debug/{id}"),
                );
            }
            self.opts.store.gone(id);
        }
        gone
    }
}

impl Runs for Records {
    fn capture(&self, id: &str, index: u64) -> Option<Value> {
        self.reader(id).ok()?.stop(index).map(|(_, c)| c)
    }

    fn run(&self, id: &str) -> Option<RunInfo> {
        let r = self.reader(id).ok()?;
        let meta = self.read_meta(id)?;
        let hits = r
            .frames()
            .into_iter()
            .filter_map(|f| match f {
                Frame::Hit(h) => Some(h),
                Frame::Stop { .. } => None,
            })
            .collect();
        Some(RunInfo {
            id: meta.id,
            root: meta.root,
            start: meta.start,
            config_hash: meta.config_hash,
            adapter_id: meta.adapter_id,
            request: meta.request,
            snapshot: meta.snapshot,
            hash_seed: meta.hash_seed,
            to_stop_ms: meta.to_stop_ms,
            stops: r.index.stops.clone(),
            probes: meta.probes,
            hits,
        })
    }
}

const START_AAD: &[u8] = b"drun start";

/// A run's START sealed for its record on disk: `{"sealed": <hex of the salt, the nonce and the sealed JSON>}`.
fn seal_start(key: &runkey::Key, start: &Value) -> Value {
    let salt = runkey::new_salt();
    let sealed =
        FileKey::new(key, &salt).seal(START_AAD, &serde_json::to_vec(start).unwrap_or_default());
    let mut bytes = salt.to_vec();
    bytes.extend_from_slice(&sealed);
    json!({ "sealed": hex(&bytes) })
}

/// The start [`seal_start`] sealed, opened with KEY.
fn open_start(key: &runkey::Key, sealed: &Value) -> Option<Value> {
    let bytes = unhex(sealed.get("sealed")?.as_str()?)?;
    let (salt, rest) = bytes.split_at_checked(SALT_LEN)?;
    let plain = FileKey::new(key, salt.try_into().ok()?).open(START_AAD, rest)?;
    serde_json::from_slice(&plain).ok()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

/// `debug-run`'s data for META in STATE, with the stop just recorded.
fn run_event(meta: &RunMeta, state: &str, stop: Option<&RunStop>) -> Value {
    json!({
        "run": meta.id,
        "n": meta.n,
        "root": meta.root,
        "session": meta.session,
        "name": meta.name,
        "state": state,
        "stops": meta.stops,
        "hits": meta.hits,
        "thinned": meta.thinned,
        "dropped": meta.dropped,
        "stops_to_probe": meta.stops_to_probe,
        "outcome": meta.outcome,
        "stop": stop,
    })
}

/// The `PYTHONHASHSEED` of a Python launch whose arguments are ARGS: the configuration's own, else WANT, else one
/// picked from the run's ID; set in ARGS' `env`.
fn seed(args: &mut Value, want: Option<u32>, id: &str) -> u32 {
    let own = args
        .pointer("/env/PYTHONHASHSEED")
        .and_then(|v| {
            v.as_str()
                .map(str::to_owned)
                .or_else(|| v.as_u64().map(|n| n.to_string()))
        })
        .and_then(|s| s.parse::<u32>().ok());
    if let Some(s) = own {
        return s;
    }
    // 0 turns hashing's randomisation off, which no ordinary run has: a seed from 1
    let s = want.unwrap_or_else(|| {
        u32::try_from(xxhash_rust::xxh3::xxh3_64(id.as_bytes()) % u64::from(u32::MAX - 1))
            .unwrap_or(1)
            + 1
    });
    if let Value::Object(m) = args {
        let env = m.entry("env").or_insert_with(|| json!({}));
        if let Value::Object(e) = env {
            e.insert("PYTHONHASHSEED".into(), json!(s.to_string()));
        }
    }
    s
}
