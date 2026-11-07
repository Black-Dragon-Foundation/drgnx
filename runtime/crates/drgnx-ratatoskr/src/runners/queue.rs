//! One queue for every machine (docs/develop/hub.md, "Runners: the queue"; design §6.8, §7.4): this machine (the local
//! runner) and the user's runners, kept in `runtime.db` and driven through `forseti` at every tick (every 2 s and on
//! every event).
//!
//! A tick orders the queued jobs (`effective_priorities`, `queue_order`, then fairness between projects with
//! `Drr::order`), places each (`forseti::pick` over this machine and the runners that may take it), and either starts
//! it here (the local runner's admission), offers it to a runner (a new attempt with a nonce: `runners::attempts`), or
//! writes why it waits. A runner's frames come back through [`Queue::on_link`]; its verdicts, losses and late results
//! go to the job layer as [`Outcome`]s.

use super::attempts::{self, Effect, Event as AEvent, Listed, Rows};
use super::health::{self, Facts, StrikeCtx, Strikes};
use super::keys::{self, Keys};
use super::link::{LinkEvent, Route, Session};
use super::local::LocalRunner;
use super::redact::{self, Redactor};
use super::sync::{self, Frozen, SyncPlan};
use crate::exec::Starter;
use forseti::{
    Accept, Candidate, Drr, Expect, Expected, HistRow, Job, JobId, JobSpec, JobState, JobTrust,
    Kind, Lane, Learned, Pick, PlaceCtx, Priority, Range, RunnerState, RunnerTrust, RunningJob,
    WaitReason, Warmth, Weight,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sleipnir::proto::{Frame, JobRef, ManifestEntry, Nonce, PROTO_VERSION, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::mpsc;

/// How often the queue ticks when nothing happens.
pub const TICK: Duration = Duration::from_secs(2);
/// This machine's name in rows and placement.
pub const LOCAL: &str = "local";
/// How much sooner a cloud machine must finish than the best own one (`runners-cloud-after`, phase 2).
const CLOUD_AFTER_S: f64 = 120.0;

/// What started a job, besides who: a request (the user's or an agent's), the splitter (F2), a plan's or gate's bulk,
/// or the hub's own upkeep (image builds, cache warm-ups).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Request,
    Splitter,
    Bulk,
    Upkeep,
}

/// A job's priority from who started it and how (design §6.8.1): 1 for the user's request, 2 for the splitter's
/// probes and reruns, 3 for an agent's `job_start`, 4 for a plan's or gate's bulk, 5 for `background` work and the
/// hub's upkeep. `background` only lowers.
pub fn priority_of(starter: &Starter, background: bool, from: Origin) -> Priority {
    if background {
        return Priority::P5;
    }
    match from {
        Origin::Splitter => Priority::P2,
        Origin::Bulk => Priority::P4,
        Origin::Upkeep => Priority::P5,
        Origin::Request => match starter {
            Starter::User => Priority::P1,
            Starter::Session(_) => Priority::P3,
        },
    }
}

/// Where a job may run: anywhere allowed (`auto`), this machine, or one runner.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Machine {
    #[default]
    Auto,
    Local,
    Runner(String),
}

impl Machine {
    /// `exec/start`'s `machine`: none or `auto`, `local`, or a runner's name.
    pub fn parse(s: Option<&str>) -> Machine {
        match s {
            None | Some("auto") => Machine::Auto,
            Some("local") => Machine::Local,
            Some(n) => Machine::Runner(n.into()),
        }
    }
}

/// A project's send mode (`drgnx-runners-send`): which of its jobs may leave this machine.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SendMode {
    All,
    #[default]
    Heavy,
    None,
}

impl SendMode {
    pub fn parse(s: &str) -> Option<SendMode> {
        match s {
            "all" => Some(SendMode::All),
            "heavy" => Some(SendMode::Heavy),
            "none" => Some(SendMode::None),
            _ => None,
        }
    }

    fn forseti(self) -> forseti::place::Send {
        match self {
            SendMode::All => forseti::place::Send::All,
            SendMode::Heavy => forseti::place::Send::Heavy,
            SendMode::None => forseti::place::Send::None,
        }
    }
}

/// Where and how a job is placed, as its start asked and its project's settings say.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Placement {
    pub machine: Machine,
    pub heavy: bool,
    /// The keys it needs, by name.
    pub keys: Vec<String>,
    pub local_only: bool,
    pub background: bool,
    pub writes: Vec<String>,
    /// The priority the user asked for (the user's connections only).
    pub priority: Option<u8>,
    pub send: SendMode,
    /// The starter's `machines` matrix cell allows sending it away.
    pub machines_cell: bool,
    /// The image a runner runs a command job in (`drgnx-runners-image`), or a container job's own.
    pub image: Option<String>,
    /// The project's weight in fairness (`drgnx-runners-weight`).
    pub weight: f64,
    /// The project's visibility (`drgnx-runners-project-visibility`): with the commit on the origin, what makes a job
    /// public.
    pub visibility: sync::Visibility,
    /// The project lets a shared runner have its overlay, once scanned (`drgnx-runners-shared-overlay`).
    pub shared_overlay: bool,
    /// The name of the project's read-only deploy key or token (`drgnx-runners-origin-key`): a `mine` or `my-cloud`
    /// runner fetches a private origin with it. A key like any other: held in memory, sent in a `key` frame.
    pub origin_key: Option<String>,
    /// A test job's rows, when its suite supports row selection: a requeue then runs only the rows without a result.
    pub suite: Option<Suite>,
    /// The hosts (`host:port`) the job's network grant reaches: a container job's matrix cell over
    /// `drgnx-agents-net-hosts`, as its proxy here would allow them. A runner's job proxy gets the same list; none: the
    /// job has no network.
    pub net_hosts: Vec<String>,
}

/// What a command takes in place of the selector of the rows an attempt runs (`forseti::split::selector`, an Emacs
/// regexp read from a string: `^\(a\|b\)$`).
pub const ROWS: &str = "{rows}";

/// A test job whose suite supports row selection: the row parser that reads its log (`ert`, `cargo-test`, `plist`),
/// and its rows in listing order. Its command holds [`ROWS`] where the selector goes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Suite {
    pub parser: String,
    pub listed: Vec<String>,
}

impl Default for Placement {
    fn default() -> Placement {
        Placement {
            machine: Machine::Auto,
            heavy: false,
            keys: vec![],
            local_only: false,
            background: false,
            writes: vec![],
            priority: None,
            send: SendMode::Heavy,
            machines_cell: true,
            image: None,
            weight: 1.0,
            visibility: sync::Visibility::Private,
            shared_overlay: false,
            origin_key: None,
            suite: None,
            net_hosts: vec![],
        }
    }
}

impl Placement {
    /// Whether a job placed so could leave this machine at all, so its inputs are frozen for a runner.
    pub fn may_leave(&self) -> bool {
        self.machine != Machine::Local && !self.local_only && self.send != SendMode::None
    }
}

/// A forseti job spec with nothing declared but its name: the shape a hub job starts from.
pub fn blank_spec(name: &str) -> JobSpec {
    JobSpec {
        name: name.into(),
        kind: Kind::Other,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::new(),
        cwd: PathBuf::new(),
        command: vec![],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range {
            min: 512,
            max: 4096,
        },
        disk_gib: 0,
        timeout_s: 3600,
        restartable: true,
        writes_tree: false,
        priority: None,
        for_user: None,
        gate: None,
        expect: Expect::default(),
        outputs: vec![],
        state: vec![],
        on: None,
        lane: Lane::Work,
        fresh: false,
        stop_on_red: false,
        project: String::new(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

/// A job entering the queue.
#[derive(Clone, Debug)]
pub struct Submit {
    pub id: String,
    /// The session that started it; none: the user.
    pub session: Option<String>,
    pub own: Priority,
    pub spec: JobSpec,
    pub place: Placement,
    /// What the job layer starts it from (its `Pending`), kept with it.
    pub pending: Value,
    /// Its inputs, frozen at submit: what a runner syncs. None: it can only run here, in its worktree as it is.
    pub inputs: Option<Frozen>,
}

/// A runner the queue may place on, as its registry record says (Task 19 fills these in).
#[derive(Clone, Debug)]
pub struct RemoteRunner {
    pub name: String,
    pub trust: RunnerTrust,
    pub accept: Accept,
    /// An attempt's grace there (`RunnerCfg::grace`).
    pub grace_s: u64,
    /// The image its health check's canary runs `true` in, by digest.
    pub image: Option<String>,
}

/// A runner as the queue sees it: `ready`, `benched: REASON (HH:MM, HH:MM)`, …; its strikes and the last one's reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerRow {
    pub state: String,
    pub strikes: u32,
    pub last: Option<String>,
}

/// What the queue tells the job layer.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// A runner's verdict for the job's current attempt (its `result.json`). SHARED: the runner's name when it is a
    /// `shared` one (its result is labelled and never counts for a gate).
    Done {
        id: String,
        attempt: u32,
        result: Value,
        shared: Option<String>,
        /// The runner it ran on, kept in the job's row once the queue has forgotten it.
        machine: Option<String>,
    },
    /// The job's runner is gone and the job isn't restartable.
    Lost { id: String },
    /// A late attempt's result, kept as that attempt's, never applied.
    Late {
        id: String,
        attempt: u32,
        result: Value,
    },
}

/// What a tick did: the jobs to start here now, and what ended.
#[derive(Debug, Default)]
pub struct Ticked {
    pub starts: Vec<String>,
    pub outcomes: Vec<Outcome>,
}

/// A job's row as the queue knows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub machine: Option<String>,
    pub attempt: Option<u32>,
    pub waiting: Option<String>,
    pub priority: u8,
}

/// A job the database kept (a hub restart).
#[derive(Clone, Debug)]
pub struct Stored {
    pub submit: Submit,
    pub submitted: u64,
    pub state: String,
    pub attempt: u32,
}

/// An attempt the database kept.
#[derive(Clone, Debug)]
pub struct StoredAttempt {
    pub job: String,
    pub attempt: u32,
    pub nonce: Nonce,
    pub runner: String,
    pub state: String,
    pub log_offset: u64,
}

#[derive(Clone, Debug, PartialEq)]
enum QState {
    Queued,
    Local,
    /// Offered to, or running on, a runner.
    Remote(String),
}

#[derive(Clone, Debug)]
struct QJob {
    s: Submit,
    submitted: u64,
    state: QState,
    waiting: Option<String>,
    attempt: u32,
    machine: Option<String>,
    /// Why a `shared` runner may not get its overlay (`sync::overlay_for`), scanned once at submit.
    shared_why: Option<String>,
}

impl QJob {
    fn new(s: Submit, submitted: u64, state: QState, attempt: u32) -> QJob {
        let shared_why = s
            .inputs
            .as_ref()
            .and_then(|f| sync::overlay_for(f, RunnerTrust::Shared).err());
        let machine = match &state {
            QState::Remote(r) => Some(r.clone()),
            QState::Local => Some(LOCAL.into()),
            QState::Queued => None,
        };
        QJob {
            s,
            submitted,
            state,
            waiting: None,
            attempt,
            machine,
            shared_why,
        }
    }
}

/// How many `sync-need` answers one attempt's sync may take before the hub gives it up.
const SYNC_ROUNDS: u32 = 6;

/// One attempt's sync under way (design §6.2): the answers so far, and the bundle the hub is sending it.
#[derive(Default)]
struct SyncSt {
    rounds: u32,
    bundle: Option<sync::BundleFile>,
    /// When the bundle went (the queue's clock): its answer times the link.
    sent_at: u64,
}

struct Remote {
    r: RemoteRunner,
    session: Session,
    state: RunnerState,
    strikes: Strikes,
    /// When the next health check is due (0: not yet set).
    next_check: u64,
    check: Option<Check>,
    /// The runner's clock minus the hub's at its last `ping`.
    skew_s: Option<i64>,
    /// What its last `hello` said of linger: without it the runner's jobs end with its login, so an attempt there gets
    /// no grace.
    linger: bool,
    /// Its last `ready`: what it can take now (less what the hub offered it since), and the slots and images it holds.
    ready: Option<ReadyNow>,
    /// The input keys its attempts synced, newest last (at most [`SYNCED_KEPT`]): their bytes are there.
    synced: Vec<String>,
}

impl Remote {
    /// An attempt's grace there: the registry's ([`RemoteRunner::grace_s`]) while its `hello` says it lingers, else 0.
    fn grace(&self) -> u64 {
        if self.linger { self.r.grace_s } else { 0 }
    }
}

/// How many synced input keys the queue remembers per runner.
const SYNCED_KEPT: usize = 64;

/// A runner's last `ready`.
struct ReadyNow {
    budget: forseti::Budget,
    slots: Vec<String>,
    images: Vec<String>,
}

/// A job offered to, or running on, a runner, as backfill counts it: since when (its offer, then its start), how long
/// it is expected to take there, and what it holds (its grant once admitted, its minimum until then).
#[derive(Clone, Debug)]
struct OnMachine {
    machine: String,
    since: u64,
    expected_s: f64,
    reserve_mib: u64,
    cores: u32,
    priority: Priority,
    restartable: bool,
    /// Its start was warm (its slot and image there): its history row says so.
    warm: bool,
}

/// A health check under way: its canary's attempt, and what it found.
struct Check {
    started: u64,
    /// The canary's job id, once offered; none until then, and again after a refusal.
    canary: Option<String>,
    last_offer: u64,
    facts: Facts,
}

/// A health check's canary job id on RUNNER: letters and digits, as a runner takes a job id, and never a job of the
/// job layer's (theirs start with `x`).
fn canary_id(runner: &str, now: u64) -> String {
    let name: String = runner.chars().filter(char::is_ascii_alphanumeric).collect();
    format!("health{name}{now}")
}

fn is_canary(job: &str) -> bool {
    job.starts_with("health")
}

/// A write to `runtime.db`, in order.
type DbOp = Box<dyn FnOnce(&urdr::Connection) -> Result<(), urdr::Error> + Send>;

enum Db {
    Op(DbOp),
    Flush(tokio::sync::oneshot::Sender<()>),
}

#[derive(Default)]
struct St {
    jobs: BTreeMap<String, QJob>,
    local_running: BTreeMap<String, RunningJob>,
    last_local_start: Option<u64>,
    drr: Drr,
    attempts: attempts::Core,
    runners: BTreeMap<String, Remote>,
    syncs: BTreeMap<(String, u32), SyncSt>,
    /// The started attempts of keyed jobs: the keys sent to each so far.
    keyed: BTreeMap<(String, u32), Vec<String>>,
    /// Each job's rows so far, by attempt (`rq_rows`).
    rows: BTreeMap<String, Rows>,
    /// Requeued attempts whose rows the next attempt reruns: cancelled when their runner lists them again, so a row
    /// never runs to its end twice.
    cancel_late: BTreeSet<(String, u32)>,
    /// The last runs of each history key on each machine (`rq_history`), and what placement learned from all of them.
    history: BTreeMap<String, BTreeMap<String, Vec<HistRow>>>,
    learned: Learned,
    /// The jobs on runners, as backfill counts them.
    on: BTreeMap<String, OnMachine>,
    /// This tick's head reservation (`forseti::backfill`): the head of the highest waiting priority that fits no
    /// machine now, and where and when it is to start.
    reservation: Option<forseti::backfill::Reservation>,
}

impl St {
    /// Learns from ROW, then keeps it among the last [`forseti::history::LAST_RUNS`] of its key on its machine.
    fn learn(&mut self, row: HistRow) {
        let all = self.history_of(&row.key);
        self.learned.observe_run(&row, &all);
        let runs = self
            .history
            .entry(row.key.clone())
            .or_default()
            .entry(row.machine.clone())
            .or_default();
        runs.push(row);
        if runs.len() > forseti::history::LAST_RUNS {
            runs.remove(0);
        }
    }

    /// The runs of KEY on every machine.
    fn history_of(&self, key: &str) -> Vec<HistRow> {
        self.history
            .get(key)
            .map(|m| m.values().flatten().cloned().collect())
            .unwrap_or_default()
    }
}

/// The spec an attempt of a job runs. With a suite that supports row selection ([`selects_rows`]), its command's
/// [`ROWS`] becomes the selector of the listed rows that have no result in ROWS (all of them on a first attempt), and
/// `select` is that selector. Otherwise the spec as it is: a requeue reruns the whole job.
pub fn attempt_spec(spec: &JobSpec, suite: Option<&Suite>, rows: Option<&Rows>) -> JobSpec {
    let mut out = spec.clone();
    let Some(suite) = suite.filter(|s| selects_rows(spec, Some(s))) else {
        return out;
    };
    let done = rows.map(Rows::done).unwrap_or_default();
    let sel = forseti::split::selector(&forseti::split::remaining_rows(&suite.listed, &done));
    for a in &mut out.command {
        *a = a.replace(ROWS, &sel);
    }
    out.select = Some(sel);
    out
}

/// Whether a job's suite supports row selection: a parser that reads rows, listed rows, and a command that takes the
/// selector.
pub fn selects_rows(spec: &JobSpec, suite: Option<&Suite>) -> bool {
    suite.is_some_and(|s| {
        !matches!(s.parser.as_str(), "" | "exit")
            && !s.listed.is_empty()
            && spec.command.iter().any(|a| a.contains(ROWS))
    })
}

/// The history row a runner's result leaves: a pass or a red, undisturbed (a disturbed run's time says little, and
/// `rq_history` keeps no mark for it); none otherwise. `rq_history` keeps no grant either.
fn hist_row(spec: &JobSpec, machine: &str, result: &Value, now: u64) -> Option<HistRow> {
    let verdict = verdict_of(result)?;
    let full_run = matches!(verdict, forseti::Verdict::Pass | forseti::Verdict::Red);
    if !full_run || result["disturbed"].as_bool() == Some(true) {
        return None;
    }
    Some(HistRow {
        key: forseti::history_key(spec),
        machine: machine.into(),
        grant: no_grant(),
        wall_s: result["wall_s"].as_f64()?,
        cpu_s: result["cpu_s"].as_f64().unwrap_or(0.0),
        mem_peak_mib: result["mem_peak_mib"].as_u64().unwrap_or(0),
        verdict,
        disturbed: false,
        at: now,
        // set by the queue for a runner's start it knew to be warm (its slot and image there)
        warm: result["warm"].as_bool() == Some(true),
    })
}

/// RESULT with the counts, rows and failing names of every attempt's ROWS (`attempts::union_result`, under SPEC's
/// `expect`), and the `split` line when they came from more than one attempt; RESULT as it is with no rows.
fn merged(result: &Value, rows: &Rows, spec: &JobSpec, suite: Option<&Suite>) -> Value {
    if rows.is_empty() {
        return result.clone();
    }
    let mut out = attempts::union_result(result, rows, &spec.expect);
    let split = suite.and_then(|s| crate::exec::summary::split_line(&s.listed, &rows.union()));
    if let (Some(line), Some(o)) = (split, out.as_object_mut()) {
        o.insert("split".into(), line.into());
    }
    out
}

fn no_grant() -> forseti::Grant {
    forseti::Grant {
        cores: 0,
        mem_cap_mib: 0,
        reserve_mib: 0,
    }
}

/// A row `rq_rows` kept.
#[derive(Clone, Debug)]
pub struct StoredRow {
    pub job: String,
    pub attempt: u32,
    pub row: String,
    pub verdict: String,
    pub machine: String,
}

/// The rows and the history `runtime.db` kept, for [`Queue::restore_kept`].
#[derive(Clone, Debug, Default)]
pub struct Kept {
    pub rows: Vec<StoredRow>,
    /// Oldest first, as they were learned from.
    pub history: Vec<HistRow>,
}

/// What `rq_rows` and `rq_history` hold.
pub async fn kept(db: &urdr::Handle) -> Kept {
    let rows = db
        .read(|c| {
            let mut st = c.prepare("select job, attempt, row, verdict, machine from rq_rows")?;
            let rows = st
                .query_map([], |r| {
                    Ok(StoredRow {
                        job: r.get(0)?,
                        attempt: r.get::<_, i64>(1)?.max(0) as u32,
                        row: r.get(2)?,
                        verdict: r.get(3)?,
                        machine: r.get(4)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_else(|e| {
            tracing::warn!("runners: the rows in runtime.db: {e}");
            vec![]
        });
    let history = db
        .read(|c| {
            let mut st = c.prepare(
                "select key, machine, warm, wall, cpu, peak_mib, verdict, at from rq_history order by at, rowid",
            )?;
            let rows = st
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, bool>(2)?,
                        r.get::<_, f64>(3)?,
                        r.get::<_, f64>(4)?,
                        r.get::<_, Option<i64>>(5)?,
                        r.get::<_, String>(6)?,
                        r.get::<_, f64>(7)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_else(|e| {
            tracing::warn!("runners: the history in runtime.db: {e}");
            vec![]
        })
        .into_iter()
        .filter_map(|(key, machine, warm, wall_s, cpu_s, peak, verdict, at)| {
            Some(HistRow {
                key,
                machine,
                grant: no_grant(),
                wall_s,
                cpu_s,
                mem_peak_mib: peak.unwrap_or(0).max(0) as u64,
                verdict: serde_json::from_str(&verdict).ok()?,
                disturbed: false,
                at: at.max(0.0) as u64,
                warm,
            })
        })
        .collect();
    Kept { rows, history }
}

/// A keyed attempt's log as the hub writes it: every key sent masked, and how far into the runner's log it has read.
struct Redacting {
    r: Redactor,
    /// The runner's offset the hub's copy has taken in (what it wrote, and what the redactor holds back).
    consumed: u64,
}

/// How the queue is made.
pub struct QueueCfg {
    /// The hub's id at a runner's `hello`.
    pub hub_id: String,
    /// `<state>/hub/exec`: each job's folder, where a runner's log frames go.
    pub exec_root: PathBuf,
    pub local: LocalRunner,
    /// `runtime.db`; none: the queue lives in memory only (unit tests).
    pub db: Option<urdr::Handle>,
}

/// The queue.
pub struct Queue {
    st: Mutex<St>,
    local: LocalRunner,
    hub_id: String,
    exec_root: PathBuf,
    db: Option<mpsc::UnboundedSender<Db>>,
    links: mpsc::UnboundedSender<LinkEvent>,
    /// Told when a job enters the queue, so an idle tick loop wakes.
    wake: tokio::sync::Notify,
    /// The job keys the hub holds, and their audit.
    keys: Arc<Keys>,
    /// The logs of keyed attempts, redacted as they are written (by attempt).
    redact: Mutex<HashMap<(String, u32), Redacting>>,
}

/// The log file of attempt R of a job whose current attempt is CURRENT.
fn log_file(root: &std::path::Path, r: &JobRef, late: bool) -> PathBuf {
    let dir = root.join(&r.job);
    if late {
        dir.join(format!("log.{}", r.attempt))
    } else {
        dir.join("log")
    }
}

/// The queue's [`Route`]: a frame counts only for an attempt placed on that runner with that nonce.
struct QRoute(Weak<Queue>);

impl Route for QRoute {
    fn log_path(&self, runner: &str, r: &JobRef) -> Option<PathBuf> {
        let q = self.0.upgrade()?;
        let late = q.lock().attempts.frame_ok(runner, r)?;
        let path = log_file(&q.exec_root, r, late);
        if let Some(dir) = path.parent()
            && let Err(e) = std::fs::create_dir_all(dir)
        {
            tracing::warn!("runners: {}: {e}", dir.display());
            return None;
        }
        Some(path)
    }

    /// A keyed job's log goes through its attempt's redactor: every key sent to it masked before the hub's copy holds
    /// it. One with no redactor (a hub restarted before its keys came back) keeps none of it.
    fn write_log(
        &self,
        runner: &str,
        r: &JobRef,
        offset: u64,
        bytes: &[u8],
    ) -> Option<std::io::Result<u64>> {
        let q = self.0.upgrade()?;
        let keyed = q
            .lock()
            .jobs
            .get(&r.job)
            .is_some_and(|j| !j.s.place.keys.is_empty());
        if !keyed {
            let path = self.log_path(runner, r)?;
            return Some(super::link::append_at(&path, offset, bytes));
        }
        // the path first: the queue's lock is never taken under the redactors' (the queue takes them in that order)
        let path = self.log_path(runner, r)?;
        let key = (r.job.clone(), r.attempt);
        let mut red = q.redact.lock().unwrap_or_else(|e| e.into_inner());
        let Some(rd) = red.get_mut(&key) else {
            tracing::info!(
                "runners: {runner}: the log of keyed job {} attempt {} is not kept: its keys aren't back yet",
                r.job,
                r.attempt
            );
            return None;
        };
        if offset > rd.consumed {
            return Some(Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "a log chunk at {offset}, past the copy's end at {}",
                    rd.consumed
                ),
            )));
        }
        let skip = (rd.consumed - offset) as usize;
        if skip < bytes.len() {
            let out = rd.r.redact(&bytes[skip..]);
            rd.consumed += (bytes.len() - skip) as u64;
            if let Err(e) = append_end(&path, &out) {
                return Some(Err(e));
            }
        }
        Some(Ok(rd.consumed))
    }
}

/// Appends BYTES at the end of the file at PATH.
fn append_end(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?
        .write_all(bytes)
}

fn nonce() -> Nonce {
    let mut b = [0u8; 16];
    use std::io::Read;
    if let Err(e) = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)) {
        panic!("runners: no random bytes for a nonce: {e}");
    }
    Nonce(b)
}

/// The words a waiting job shows.
pub fn wait_text(r: &WaitReason) -> String {
    match r {
        WaitReason::Needs(j) => format!("waits for job {j}"),
        WaitReason::Behind(p) => format!("behind priority {} work", p.number()),
        WaitReason::NoRoom { need_mib, free_mib } => {
            format!("needs {need_mib} MiB of memory; {free_mib} MiB is free for jobs")
        }
        WaitReason::HeadProtection(j) => format!("room is kept for job {j}"),
        WaitReason::State { dir, holder } => {
            format!("{} is held by job {holder}", dir.display())
        }
        WaitReason::IslandBusy => "the timing island is busy".into(),
        WaitReason::DrainWaits => "the machine is draining".into(),
        WaitReason::DesktopUnreachable { .. } => "its runner can't be reached".into(),
        WaitReason::SpillIn { minutes } => format!("may go to a runner in {minutes} min"),
        WaitReason::DiskLow => "the disk is below its floor".into(),
        WaitReason::OnBattery => "this machine is on battery".into(),
        WaitReason::Pressure { what, value, limit } => {
            format!("{what} pressure is {value:.0} % (the limit is {limit:.0} %)")
        }
        WaitReason::Gap { secs } => format!("the next start is in {secs} s"),
        WaitReason::Threads => "every job slot of the machine is in use".into(),
        WaitReason::Trust(why) => why.clone(),
        WaitReason::Pinned => "its machine can't take it now".into(),
        WaitReason::NeedsLogin => "its runner needs a login".into(),
        WaitReason::NeedsKeys => "its runner needs keys".into(),
        WaitReason::CloudCap(why) => why.clone(),
        WaitReason::Benched => "its runner is benched".into(),
        WaitReason::Mode => "the project's send mode keeps it on this machine".into(),
        WaitReason::Features(f) => format!("no machine has {}", f.join(", ")),
        WaitReason::Matrix => "the matrix keeps it on this machine".into(),
        WaitReason::AwaitingConfirm => "its runner waits for your confirm".into(),
        WaitReason::NoRunner => "no machine may take it".into(),
    }
}

/// The verdict in a runner's `result.json`.
pub fn verdict_of(result: &Value) -> Option<forseti::Verdict> {
    serde_json::from_value(result.get("verdict")?.clone()).ok()
}

impl Queue {
    /// The queue, and the receiver of its runners' link events (the job layer pumps them into [`Queue::on_link`]).
    pub fn new(cfg: QueueCfg) -> (Arc<Queue>, mpsc::UnboundedReceiver<LinkEvent>) {
        let db = cfg.db.map(|handle| {
            let (tx, mut rx) = mpsc::unbounded_channel::<Db>();
            crate::clock::spawn("runners:queue-db", async move {
                while let Some(op) = rx.recv().await {
                    match op {
                        Db::Op(op) => {
                            if let Err(e) = handle.write(op).await {
                                tracing::warn!("runners: the queue's runtime.db write: {e}");
                            }
                        }
                        Db::Flush(done) => {
                            let _ = done.send(());
                        }
                    }
                }
            });
            tx
        });
        let (links, rx) = mpsc::unbounded_channel();
        let q = Queue {
            st: Mutex::new(St::default()),
            local: cfg.local,
            hub_id: cfg.hub_id,
            exec_root: cfg.exec_root,
            db,
            links,
            wake: tokio::sync::Notify::new(),
            keys: Arc::default(),
            redact: Mutex::default(),
        };
        (Arc::new(q), rx)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, St> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn redactors(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u32), Redacting>> {
        self.redact.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The job keys the hub holds, and their audit.
    pub fn keys(&self) -> &Arc<Keys> {
        &self.keys
    }

    /// `runners/keys`: PAIRS held from now on. Started attempts still waiting for one get it now; a keyed attempt
    /// whose log waited for its keys (a hub restart) is attached again from where the hub's copy ends. The names now
    /// held.
    pub fn take_keys(
        &self,
        pairs: impl IntoIterator<Item = (String, secrecy::SecretString)>,
        now: u64,
    ) -> Vec<String> {
        let held = self.keys.take(pairs);
        let mut st = self.lock();
        let waiting: Vec<(String, u32)> = st.keyed.keys().cloned().collect();
        for (job, attempt) in waiting {
            self.send_keys(&mut st, &job, attempt, now);
        }
        // the keyed attempts on runners with no redactor yet: once every key of theirs is held, their logs are taken
        // in again
        let mut attach = vec![];
        for (id, j) in &st.jobs {
            let QState::Remote(runner) = &j.state else {
                continue;
            };
            if j.s.place.keys.is_empty() || !self.keys.missing(&j.s.place.keys).is_empty() {
                continue;
            }
            let Some((attempt, a)) = st.attempts.current(id) else {
                continue;
            };
            if !a.state.open() || self.redactors().contains_key(&(id.clone(), attempt)) {
                continue;
            }
            attach.push((id.clone(), attempt, a.nonce, runner.clone()));
        }
        for (job, attempt, nonce, runner) in attach {
            let r = JobRef {
                job: job.clone(),
                attempt,
                nonce,
            };
            let from = self.new_redactor(&st, &r, true);
            if let Some(rr) = st.runners.get(&runner) {
                rr.session.send(Frame::Attach {
                    r,
                    log_offset: from,
                });
            }
        }
        held
    }

    /// Attempt R's redactor, over every key of its job the hub holds; its log is taken in from where the hub's copy
    /// ends (FROM_COPY), or from the start (a new attempt). Where it starts.
    fn new_redactor(&self, st: &St, r: &JobRef, from_copy: bool) -> u64 {
        let names = st
            .jobs
            .get(&r.job)
            .map(|j| j.s.place.keys.clone())
            .unwrap_or_default();
        let values: Vec<secrecy::SecretString> =
            names.iter().filter_map(|n| self.keys.value(n)).collect();
        let late = st
            .attempts
            .current(&r.job)
            .is_some_and(|(n, _)| n != r.attempt);
        let consumed = if from_copy {
            std::fs::metadata(log_file(&self.exec_root, r, late)).map_or(0, |m| m.len())
        } else {
            0
        };
        self.redactors().insert(
            (r.job.clone(), r.attempt),
            Redacting {
                r: Redactor::new(&values),
                consumed,
            },
        );
        consumed
    }

    /// Sends JOB's started attempt ATTEMPT the keys it hasn't had yet (those the hub holds), and masks each in its log.
    fn send_keys(&self, st: &mut St, job: &str, attempt: u32, now: u64) {
        let Some(q) = st.jobs.get(job) else {
            st.keyed.remove(&(job.to_string(), attempt));
            return;
        };
        let names = q.s.place.keys.clone();
        let QState::Remote(runner) = q.state.clone() else {
            return;
        };
        let Some(a) = st.attempts.attempt(job, attempt) else {
            return;
        };
        let r = JobRef {
            job: job.to_string(),
            attempt,
            nonce: a.nonce,
        };
        let sent = st
            .keyed
            .get(&(job.to_string(), attempt))
            .cloned()
            .unwrap_or_default();
        let want: Vec<String> = names.into_iter().filter(|n| !sent.contains(n)).collect();
        if want.is_empty() {
            return;
        }
        let Some(rr) = st.runners.get(&runner) else {
            return;
        };
        // masked before it can reach the job, so before it can reach its log
        {
            let mut red = self.redactors();
            if let Some(rd) = red.get_mut(&(job.to_string(), attempt)) {
                for v in want.iter().filter_map(|n| self.keys.value(n)) {
                    rd.r.add(&v);
                }
            }
        }
        let link = |f: Frame| rr.session.send(f);
        let out = keys::send(&link, &runner, rr.r.trust, &[], &r, &want, &self.keys, now);
        if let Some(why) = out.refused {
            tracing::warn!("runners: {job}: {why}");
        }
        st.keyed
            .entry((job.to_string(), attempt))
            .or_default()
            .extend(out.sent);
    }

    fn persist(&self, op: DbOp) {
        if let Some(db) = &self.db {
            let _ = db.send(Db::Op(op));
        }
    }

    /// Waits until every write queued so far is done.
    pub async fn flush(&self) {
        if let Some(db) = &self.db {
            let (tx, rx) = tokio::sync::oneshot::channel();
            if db.send(Db::Flush(tx)).is_ok() {
                let _ = rx.await;
            }
        }
    }

    /// Where a runner's session sends its events.
    pub fn link_events(&self) -> mpsc::UnboundedSender<LinkEvent> {
        self.links.clone()
    }

    /// The [`Route`] runners' sessions write logs through.
    pub fn route(self: &Arc<Self>) -> Arc<dyn Route> {
        Arc::new(QRoute(Arc::downgrade(self)))
    }

    /// Whether a runner of that name is known.
    pub fn has_runner(&self, name: &str) -> bool {
        self.lock().runners.contains_key(name)
    }

    /// Runner NAME's row.
    pub fn runner(&self, name: &str) -> Option<RunnerRow> {
        let st = self.lock();
        let r = st.runners.get(name)?;
        let state = match &r.state {
            RunnerState::Ready => "ready".to_string(),
            RunnerState::Benched(why) => r
                .strikes
                .text()
                .unwrap_or_else(|| format!("benched: {why}")),
            RunnerState::NeedsLogin(cmd) => format!("needs a login: {cmd}"),
            RunnerState::NeedsKeys => "needs keys".into(),
            RunnerState::AwaitingConfirm => "waits for your confirm".into(),
            RunnerState::Unreachable { .. } => "unreachable".into(),
            RunnerState::Draining => "draining".into(),
            RunnerState::Preempting => "preempting".into(),
        };
        Some(RunnerRow {
            state,
            strikes: r.strikes.count(),
            last: r.strikes.last().map(String::from),
        })
    }

    /// Runner NAME's health check is due at the next tick.
    pub fn check_now(&self, name: &str) {
        if let Some(r) = self.lock().runners.get_mut(name) {
            r.next_check = 1;
        }
    }

    /// Whether runner NAME has no link and wants one: it is out of reach, or benched with its link gone (a benched
    /// runner returns by a health check, which needs a link). One that waits on a login or on its user does not.
    pub fn needs_redial(&self, name: &str) -> bool {
        self.lock().runners.get(name).is_some_and(|r| {
            matches!(
                r.state,
                RunnerState::Unreachable { .. } | RunnerState::Benched(_) | RunnerState::Ready
            ) && r.session.ended()
        })
    }

    /// How many runners are known.
    pub fn runners(&self) -> usize {
        self.lock().runners.len()
    }

    /// This machine's job slots, `(all, free)`: what it takes at once ([`LocalRunner::slots`], never fewer than run
    /// here now) and how many of them no queued job here holds.
    pub fn local_slots(&self) -> (usize, usize) {
        let running = self.lock().local_running.len();
        let all = self.local.slots().max(running);
        (all, all - running)
    }

    /// Whether a tick has work: a job waits, or an attempt is on a runner (its grace may end).
    pub fn busy(&self) -> bool {
        let st = self.lock();
        !st.runners.is_empty() || st.jobs.values().any(|j| j.state != QState::Local)
    }

    /// Returns once the queue may have become busy (a job entered it) since the last call.
    pub async fn woken(&self) {
        self.wake.notified().await
    }

    /// The room job ID holds here until the slot is dropped (its end, or a launch that failed).
    pub fn slot(self: &Arc<Self>, id: &str) -> Slot {
        Slot {
            q: self.clone(),
            id: id.into(),
        }
    }

    /// A runner the queue may place on, over SESSION: it says `hello` now and is ready at its `hello-ok`.
    pub fn add_runner(&self, r: RemoteRunner, session: Session) {
        session.send(Frame::Hello {
            version: PROTO_VERSION,
            hub_id: self.hub_id.clone(),
        });
        let name = r.name.clone();
        self.lock().runners.insert(
            name,
            Remote {
                r,
                session,
                state: RunnerState::Unreachable { since: 0 },
                strikes: Strikes::default(),
                next_check: 0,
                check: None,
                skew_s: None,
                linger: true,
                ready: None,
                synced: vec![],
            },
        );
    }

    /// Runner CFG linked over T: its sessions opened, `serve` started on them, the link the queue's (REMOTE is the
    /// runner a first link adds). A dial refused for a login the user must do, or for a changed host key, puts a
    /// runner the queue knows in `needs login` with the command its card shows, until its next `hello`; nothing is
    /// placed there meanwhile. Any other failure (a lost link) leaves its state as the loss made it.
    pub async fn dial(
        self: &Arc<Self>,
        t: &dyn super::transport::Transport,
        cfg: &super::RunnerCfg,
        remote: RemoteRunner,
    ) -> Result<(), super::transport::LinkError> {
        use super::transport::{LinkError, Login};
        let channels = match t.open(cfg).await {
            Ok(c) => c,
            Err(e) => {
                let login = match &e {
                    LinkError::HostKeyChanged => Some(Login::HostKeyChanged),
                    LinkError::NeedsLogin(l) => Some(l.clone()),
                    _ => None,
                };
                if let Some(l) = login
                    && let Some(r) = self.lock().runners.get_mut(&cfg.name)
                {
                    r.state = RunnerState::NeedsLogin(l.command(&cfg.host));
                }
                return Err(e);
            }
        };
        let session = Session::start(&cfg.name, channels, self.route(), self.link_events());
        if !self.set_session(&cfg.name, session.clone()) {
            self.add_runner(remote, session);
        }
        Ok(())
    }

    /// The user's `runners/unbench`: NAME back in rotation, with no strikes.
    pub fn unbench(&self, name: &str) {
        if let Some(r) = self.lock().runners.get_mut(name) {
            r.strikes.clear();
            if matches!(r.state, RunnerState::Benched(_)) {
                r.state = RunnerState::Ready;
            }
        }
    }

    /// Runner NAME's session now (to end it before a new link is made).
    pub fn session(&self, name: &str) -> Option<Session> {
        self.lock().runners.get(name).map(|r| r.session.clone())
    }

    /// Runner NAME on a new SESSION (a reconnect, or a changed profile): it says `hello` now and is ready at its
    /// `hello-ok`; its strikes stay. False when no runner of that name is known.
    pub fn set_session(&self, name: &str, session: Session) -> bool {
        let mut st = self.lock();
        let Some(r) = st.runners.get_mut(name) else {
            return false;
        };
        session.send(Frame::Hello {
            version: PROTO_VERSION,
            hub_id: self.hub_id.clone(),
        });
        r.session = session;
        r.state = RunnerState::Unreachable { since: 0 };
        true
    }

    /// Runner NAME's trust and accept as its registry record now says.
    pub fn set_runner(&self, name: &str, trust: RunnerTrust, accept: Accept) -> bool {
        match self.lock().runners.get_mut(name) {
            Some(r) => {
                r.r.trust = trust;
                r.r.accept = accept;
                true
            }
            None => false,
        }
    }

    /// How many jobs are offered to, or running on, runner NAME.
    pub fn runner_jobs(&self, name: &str) -> u32 {
        let st = self.lock();
        st.jobs
            .values()
            .filter(|j| matches!(&j.state, QState::Remote(r) if r == name))
            .count() as u32
    }

    /// Runner NAME forgotten (its session ends). Refused, with the reason, while a job is on it.
    pub fn remove_runner(&self, name: &str) -> Result<(), String> {
        let mut st = self.lock();
        let busy = st
            .jobs
            .values()
            .filter(|j| matches!(&j.state, QState::Remote(r) if r == name))
            .count();
        if busy > 0 {
            return Err(format!(
                "{busy} job(s) are on {name}: stop them or wait for them to end"
            ));
        }
        st.runners.remove(name);
        Ok(())
    }

    fn put_job(&self, j: &QJob, eff: Priority) {
        let id = j.s.id.clone();
        let spec = json!({
            "job": j.s.spec,
            "place": j.s.place,
            "pending": j.s.pending,
            "session": j.s.session,
            "inputs": j.s.inputs,
        })
        .to_string();
        let (own, eff) = (j.s.own.number(), eff.number());
        let trust = serde_json::to_value(j.s.spec.trust)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_default();
        let pin = match &j.s.place.machine {
            Machine::Auto => None,
            Machine::Local => Some(LOCAL.to_string()),
            Machine::Runner(n) => Some(n.clone()),
        };
        let project = j.s.spec.project.clone();
        let input_key = j.s.inputs.as_ref().map(|f| f.input_key.clone());
        let state = match j.state {
            QState::Queued => "queued",
            QState::Local | QState::Remote(_) => "running",
        };
        let (submitted, attempt) = (j.submitted as f64, j.attempt);
        self.persist(Box::new(move |c| {
            c.execute(
                "insert or replace into rq_job(id, spec, own, effective, trust, pin, project, input_key, state, \
                 submitted, attempt) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                (
                    id, spec, own, eff, trust, pin, project, input_key, state, submitted, attempt,
                ),
            )?;
            Ok(())
        }));
    }

    /// Writes frozen inputs F to `rq_input` (design §7.4), or marks them used again at NOW.
    fn put_input(&self, f: &Frozen, now: u64) {
        let manifest = serde_json::to_vec(&f.manifest).unwrap_or_default();
        let manifest_hash = {
            use sha2::Digest;
            sha2::Sha256::digest(&manifest)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        };
        let extras = serde_json::to_string(&f.extras).unwrap_or_default();
        let (key, commit, tree, at) = (
            f.input_key.clone(),
            f.commit.clone(),
            f.tree.clone(),
            now as f64,
        );
        self.persist(Box::new(move |c| {
            c.execute(
                "insert into rq_input(key, commit_sha, tree, manifest_hash, manifest, extras, created, last_used) \
                 values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7) on conflict(key) do update set last_used = excluded.last_used",
                (key, commit, tree, manifest_hash, manifest, extras, at),
            )?;
            Ok(())
        }));
    }

    fn drop_job(&self, id: &str) {
        let id = id.to_string();
        self.persist(Box::new(move |c| {
            for t in [
                "rq_job where id",
                "rq_attempt where job",
                "rq_offer where job",
                "rq_admission where job",
                "rq_detached where job",
                "rq_rows where job",
            ] {
                c.execute(&format!("delete from {t} = ?1"), [&id])?;
            }
            Ok(())
        }));
    }

    /// Writes JOB's attempts as the state machine has them, and the detached ones' graces.
    fn put_attempts(&self, st: &St, job: &str) {
        let rows: Vec<(u32, attempts::Attempt)> = st
            .attempts
            .attempts()
            .filter(|((j, _), _)| j == job)
            .map(|((_, n), a)| (*n, a.clone()))
            .collect();
        let job = job.to_string();
        self.persist(Box::new(move |c| {
            for (n, a) in rows {
                c.execute(
                    "insert into rq_attempt(job, attempt, nonce, runner, placed, grant, state, verdict, log_offset) \
                     values (?1, ?2, ?3, ?4, ?5, null, ?6, null, ?7) on conflict(job, attempt) do update set \
                     state = excluded.state, log_offset = excluded.log_offset",
                    (
                        &job,
                        n,
                        a.nonce.hex(),
                        &a.runner,
                        crate::clock::wall_secs(),
                        a.state.word(),
                        a.log_offset as i64,
                    ),
                )?;
                match a.state {
                    attempts::AttemptState::Detached { since, grace_until } => {
                        c.execute(
                            "insert or replace into rq_detached(job, attempt, runner, since, grace_until, reason) \
                             values (?1, ?2, ?3, ?4, ?5, 'runner not heard')",
                            (&job, n, &a.runner, since as f64, grace_until as f64),
                        )?;
                    }
                    _ => {
                        c.execute(
                            "delete from rq_detached where job = ?1 and attempt = ?2",
                            (&job, n),
                        )?;
                    }
                }
            }
            Ok(())
        }))
    }

    /// Attempt R on RUNNER gave ROW the result VERDICT: kept with its job's rows, and in `rq_rows`.
    fn record_row(&self, st: &mut St, r: &JobRef, row: &str, verdict: &str, runner: &str) {
        st.rows
            .entry(r.job.clone())
            .or_default()
            .record(r.attempt, row, verdict, runner);
        let (job, attempt, row, verdict, machine) = (
            r.job.clone(),
            r.attempt,
            row.to_string(),
            verdict.to_string(),
            runner.to_string(),
        );
        self.persist(Box::new(move |c| {
            c.execute(
                "insert or replace into rq_rows(job, attempt, row, verdict, machine) values (?1, ?2, ?3, ?4, ?5)",
                (job, attempt, row, verdict, machine),
            )?;
            Ok(())
        }));
    }

    /// The rows the hub's copy of attempt N's log at PATH shows, read with PARSER up to its last whole line, recorded
    /// as that attempt's: a runner sends its `row` frames at an attempt's end, and a lost attempt sends none.
    fn rows_from_log(&self, st: &mut St, job: &str, n: u32, parser: &str, path: &std::path::Path) {
        use sleipnir::linux::parse;
        let Some(a) = st.attempts.attempt(job, n) else {
            return;
        };
        let (r, runner) = (
            JobRef {
                job: job.into(),
                attempt: n,
                nonce: a.nonce,
            },
            a.runner.clone(),
        );
        let Ok(parser) = serde_json::from_value::<parse::Parser>(Value::String(parser.into()))
        else {
            return;
        };
        let mut log = std::fs::read(path).unwrap_or_default();
        log.truncate(log.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1));
        for (name, v) in parse::parse(parser, &log).rows {
            let verdict = serde_json::to_value(v)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_default();
            self.record_row(st, &r, &name, &verdict, &runner);
        }
    }

    /// RESULT, a runner's verdict for a job of SPEC on MACHINE at NOW, as the history placement learns from
    /// (`rq_history`).
    fn record_run(&self, st: &mut St, spec: &JobSpec, machine: &str, result: &Value, now: u64) {
        let Some(row) = hist_row(spec, machine, result, now) else {
            return;
        };
        let verdict = serde_json::to_string(&row.verdict).unwrap_or_default();
        let (key, machine, warm, wall, cpu, peak, at) = (
            row.key.clone(),
            row.machine.clone(),
            row.warm,
            row.wall_s,
            row.cpu_s,
            row.mem_peak_mib as i64,
            row.at as f64,
        );
        self.persist(Box::new(move |c| {
            c.execute(
                "insert into rq_history(key, machine, warm, wall, cpu, peak_mib, verdict, at) \
                 values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                (key, machine, warm, wall, cpu, peak, verdict, at),
            )?;
            Ok(())
        }));
        st.learn(row);
    }

    /// The rows and the history the database kept (a hub restart): each job's rows come back, and placement learns
    /// again from the runs, in the order it first did.
    pub fn restore_kept(&self, k: Kept) {
        let mut st = self.lock();
        for r in k.rows {
            st.rows
                .entry(r.job)
                .or_default()
                .record(r.attempt, &r.row, &r.verdict, &r.machine);
        }
        for h in k.history {
            st.learn(h);
        }
    }

    /// A job enters the queue at NOW. With frozen inputs, its trust is theirs (design §6.6: from what the public
    /// origin has, and the keys it names), whatever the spec said, and they are kept in `rq_input`.
    pub fn submit(&self, mut s: Submit, now: u64) {
        if let Some(f) = &s.inputs {
            s.spec.trust = f.trust(&s.place.keys);
            self.put_input(f, now);
        }
        let j = QJob::new(s, now, QState::Queued, 0);
        self.put_job(&j, j.s.own);
        self.lock().jobs.insert(j.s.id.clone(), j);
        self.wake.notify_one();
    }

    /// A job the database kept goes back into the queue (a hub restart). A queued one waits again; one that ran here
    /// is the job layer's to adopt; one on a runner keeps its attempts, detached until the runner's `hello`.
    pub fn restore(&self, jobs: Vec<Stored>, attempts: Vec<StoredAttempt>, now: u64) {
        let mut st = self.lock();
        for s in jobs {
            let remote = attempts
                .iter()
                .filter(|a| a.job == s.submit.id && a.attempt == s.attempt)
                .map(|a| a.runner.clone())
                .next();
            let state = match (s.state.as_str(), remote) {
                ("running", Some(r)) => QState::Remote(r),
                ("running", None) => continue,
                _ => QState::Queued,
            };
            st.jobs.insert(
                s.submit.id.clone(),
                QJob::new(s.submit, s.submitted, state, s.attempt),
            );
        }
        let mut jobs_with_attempts = Vec::new();
        for a in attempts {
            let Some(j) = st.jobs.get(&a.job) else {
                continue;
            };
            let state = match a.state.as_str() {
                "offered" => attempts::AttemptState::Offered,
                "running" | "detached" => attempts::AttemptState::Running,
                "finished" => attempts::AttemptState::Finished,
                "requeued" => attempts::AttemptState::Requeued,
                _ => attempts::AttemptState::Lost,
            };
            let grace_s = st.runners.get(&a.runner).map_or(600, Remote::grace);
            let (current, restartable) = (j.attempt == a.attempt, j.s.spec.restartable);
            // a requeued attempt whose rows the next one reruns still stops when its runner lists it
            if state == attempts::AttemptState::Requeued
                && selects_rows(&j.s.spec, j.s.place.suite.as_ref())
            {
                st.cancel_late.insert((a.job.clone(), a.attempt));
            }
            st.attempts.restore(
                &a.job,
                a.attempt,
                attempts::Attempt {
                    runner: a.runner,
                    nonce: a.nonce,
                    state,
                    grace_s,
                    log_offset: a.log_offset,
                },
                current,
                restartable,
            );
            jobs_with_attempts.push(a.job);
        }
        let effects = st.attempts.step(now, AEvent::HubRestarted);
        let mut out = vec![];
        self.apply(&mut st, effects, now, &mut out);
        for j in jobs_with_attempts {
            self.put_attempts(&st, &j);
        }
        drop(st);
        self.wake.notify_one();
    }

    /// A job that runs here since before a hub restart: it counts against this machine's room until it ends.
    pub fn adopt(&self, id: &str, own: Priority, now: u64) {
        let mut st = self.lock();
        st.local_running
            .insert(id.to_string(), running(id, own, now, 512, 1));
        let j = st.jobs.entry(id.to_string()).or_insert_with(|| {
            let s = Submit {
                id: id.into(),
                session: None,
                own,
                spec: blank_spec(id),
                place: Placement::default(),
                pending: Value::Null,
                inputs: None,
            };
            QJob::new(s, now, QState::Local, 0)
        });
        j.state = QState::Local;
        j.machine = Some(LOCAL.into());
    }

    /// Job ID ran here to RESULT at NOW (`{"verdict", "wall_s"}`): a pass or a red is this machine's history, as a
    /// runner's is (call it before [`Queue::release`]).
    pub fn ran_here(&self, id: &str, result: &Value, now: u64) {
        let mut st = self.lock();
        let Some(spec) = st
            .jobs
            .get(id)
            .filter(|j| j.state == QState::Local)
            .map(|j| j.s.spec.clone())
        else {
            return;
        };
        self.record_run(&mut st, &spec, LOCAL, result, now);
    }

    /// Job ID ended here, or never started: it leaves the queue and frees its room.
    pub fn release(&self, id: &str) {
        let mut st = self.lock();
        let ran_here = st.local_running.remove(id).is_some();
        let remote = st
            .jobs
            .get(id)
            .is_some_and(|j| matches!(j.state, QState::Remote(_)));
        if !remote {
            st.jobs.remove(id);
            st.attempts.forget(id);
            drop(st);
            self.drop_job(id);
        }
        if ran_here {
            self.local.release(id);
        }
    }

    /// A queued job is stopped before it started: it leaves the queue (true). One on a runner is cancelled there; its
    /// end comes back as an [`Outcome`] (false).
    pub fn remove(&self, id: &str, now: u64) -> (bool, Vec<Outcome>) {
        let mut st = self.lock();
        match st.jobs.get(id).map(|j| j.state.clone()) {
            Some(QState::Queued) => {
                st.jobs.remove(id);
                drop(st);
                self.drop_job(id);
                (true, vec![])
            }
            Some(QState::Remote(_)) => {
                let effects = st.attempts.step(now, AEvent::Cancel { job: id.into() });
                let mut out = vec![];
                self.apply(&mut st, effects, now, &mut out);
                (false, out)
            }
            _ => (false, vec![]),
        }
    }

    /// The cloud machine of RUNNER is gone (the sweeper ended it, or the cap did): its open attempts requeue at once,
    /// or end lost when they can't be restarted.
    pub fn cloud_gone(&self, runner: &str, now: u64) -> Vec<Outcome> {
        let mut st = self.lock();
        let effects = st.attempts.step(
            now,
            AEvent::CloudGone {
                runner: runner.into(),
            },
        );
        let mut out = vec![];
        self.apply(&mut st, effects, now, &mut out);
        out
    }

    /// Job ID is bumped to priority 1 (the user's `exec/bump`); false when the queue doesn't hold it.
    pub fn bump(&self, id: &str) -> bool {
        let mut st = self.lock();
        let Some(j) = st.jobs.get_mut(id) else {
            return false;
        };
        j.s.own = Priority::P1;
        let j = j.clone();
        drop(st);
        self.put_job(&j, Priority::P1);
        true
    }

    /// What job ID starts from (its `Pending`).
    pub fn pending(&self, id: &str) -> Option<Value> {
        self.lock()
            .jobs
            .get(id)
            .map(|j| j.s.pending.clone())
            .filter(|v| !v.is_null())
    }

    /// Job ID's row as the queue knows it.
    pub fn row(&self, id: &str) -> Option<Row> {
        let st = self.lock();
        let j = st.jobs.get(id)?;
        let remote = matches!(j.state, QState::Remote(_)) || j.attempt > 0;
        Some(Row {
            machine: j.machine.clone(),
            attempt: remote.then_some(j.attempt),
            waiting: (j.state == QState::Queued)
                .then(|| j.waiting.clone())
                .flatten(),
            priority: j.s.own.number(),
        })
    }

    fn forseti_job(j: &QJob) -> Job {
        let mut spec = j.s.spec.clone();
        spec.local_only |= j.s.place.local_only || j.s.place.machine == Machine::Local;
        if let Machine::Runner(n) = &j.s.place.machine {
            spec.on = Some(n.clone());
        }
        if j.s.place.heavy {
            spec.weight = Weight::Heavy;
        }
        spec.keys = j.s.place.keys.clone();
        spec.writes = j.s.place.writes.clone();
        Job {
            id: JobId(j.s.id.clone()),
            spec,
            own: j.s.own,
            submitted: j.submitted,
            state: JobState::Queued,
            attempt: j.attempt,
            evicted_once: false,
            disturbed: false,
            blocked_caller: false,
        }
    }

    /// One tick at NOW: graces that ended, then every queued job in the queue's order, placed or told why it waits.
    pub fn tick(&self, now: u64) -> Ticked {
        let mut st = self.lock();
        let mut t = Ticked::default();
        for (job, attempt) in st.attempts.graces_due(now) {
            let effects = st.attempts.step(
                now,
                AEvent::GraceEnded {
                    job: job.clone(),
                    attempt,
                },
            );
            self.apply(&mut st, effects, now, &mut t.outcomes);
            self.put_attempts(&st, &job);
        }
        let names: Vec<String> = st.runners.keys().cloned().collect();
        for name in names {
            self.health(&mut st, &name, now);
        }
        let queued: Vec<Job> = st
            .jobs
            .values()
            .filter(|j| j.state == QState::Queued)
            .map(Self::forseti_job)
            .collect();
        if queued.is_empty() {
            return t;
        }
        let eff = forseti::effective_priorities(&queued, &[], &[]);
        let exp = |_: &JobId| Expected {
            minutes: forseti::history::DEFAULT_MINUTES,
            cpu: 1.0,
            mem_p95_mib: None,
        };
        let order = forseti::queue_order(&queued, &eff, &exp, now);
        let project: HashMap<JobId, String> = queued
            .iter()
            .map(|j| (j.id.clone(), j.spec.project.clone()))
            .collect();
        let weights: HashMap<String, f64> = st
            .jobs
            .values()
            .map(|j| (j.s.spec.project.clone(), j.s.place.weight))
            .collect();
        let order = st.drr.order(
            &order,
            &eff,
            &|j| project.get(j).cloned().unwrap_or_default(),
            &HashMap::new(),
            &weights,
        );
        let by_id: HashMap<&JobId, &Job> = queued.iter().map(|j| (&j.id, j)).collect();
        st.reservation = self.head_reservation(&st, &order, &by_id, &eff, now);
        for id in &order {
            let job = by_id[id];
            let e = eff.get(id).copied().unwrap_or(job.own);
            self.place(&mut st, job, e, now, &mut t.starts);
        }
        st.reservation = None;
        t
    }

    /// The head's reservation this tick (`forseti::backfill::reservation`): the first queued job of the highest
    /// effective priority, when it fits none of the machines that may take it now, reserves the one where it can start
    /// soonest, from the expected ends of what runs there. Each machine's budget is its own: this machine's from its
    /// probe (none when it admits by count), a runner's from its last `ready`; a runner that sent none isn't counted.
    fn head_reservation(
        &self,
        st: &St,
        order: &[JobId],
        by_id: &HashMap<&JobId, &Job>,
        eff: &HashMap<JobId, Priority>,
        now: u64,
    ) -> Option<forseti::backfill::Reservation> {
        let needs: Vec<(JobId, forseti::Need)> = order
            .iter()
            .map(|id| (id.clone(), need_of(by_id[id])))
            .collect();
        let prio = |j: &JobId| eff.get(j).copied().unwrap_or(Priority::P5);
        let highest = needs.iter().map(|(j, _)| prio(j)).max()?;
        let head_id = &needs.iter().find(|(j, _)| prio(j) == highest)?.0;
        let head = by_id[head_id];
        let q = st.jobs.get(&head.id.0)?;
        let (cands, _, _) = Self::candidates(st, head, q, false);
        let (mut machines, mut ends) = (vec![], HashMap::new());
        for c in cands.iter().filter(|c| {
            forseti::filter(head, c, q.s.place.send.forseti(), q.s.place.machines_cell).is_ok()
        }) {
            if c.local {
                let running: Vec<RunningJob> = st.local_running.values().cloned().collect();
                for rj in &running {
                    let end = forseti::expected_end(rj.started, rj.expected.minutes * 60.0);
                    ends.insert(rj.id.clone(), end);
                }
                machines.extend(self.local.state(&running, st.last_local_start, now));
            } else if let Some(rd) = st.runners.get(&c.name).and_then(|r| r.ready.as_ref()) {
                let mut running = vec![];
                for (id, o) in st.on.iter().filter(|(_, o)| o.machine == c.name) {
                    ends.insert(
                        JobId(id.clone()),
                        forseti::expected_end(o.since, o.expected_s),
                    );
                    running.push(o.running(id));
                }
                machines.push((runner_state(&c.name, now, running), rd.budget));
            }
        }
        let m: Vec<(&forseti::MachineState, forseti::Budget)> =
            machines.iter().map(|(m, b)| (m, *b)).collect();
        forseti::reservation(&needs, eff, &m, &ends).filter(|r| r.at > now)
    }

    /// The machines that might take JOB (QJOB in the queue): this machine (none for a keyed job: its keys reach a
    /// runner's job only, and it never runs without them), then every runner but a `shared` one its overlay may not
    /// reach (the second value says why). Each runner's transfer counts its overlay's bytes unless an attempt there
    /// synced these inputs before. With FIT a runner whose last `ready` has no room for the job's need now is passed
    /// by too (the third value: why it waits there): the hub offers only what fits.
    fn candidates(
        st: &St,
        job: &Job,
        q: &QJob,
        fit: bool,
    ) -> (Vec<Candidate>, Option<String>, Option<WaitReason>) {
        // the job's runs on every machine: each candidate's estimate reads them, with what placement learned
        let history = st.history_of(&forseti::history_key(&job.spec));
        let mut cands = vec![];
        if job.spec.keys.is_empty() {
            cands.push(Candidate {
                name: LOCAL.into(),
                local: true,
                trust: RunnerTrust::Mine,
                keys_allowed: vec![],
                features: job.spec.features.clone(),
                state: RunnerState::Ready,
                accept: Accept::All,
                link_bps: None,
                missing_bytes: 0,
                start_s: 0.0,
                wait_s: 0.0,
                speed: 1.0,
                history: history.clone(),
                cloud: None,
            });
        }
        let need = need_of(job);
        let (mut held_off, mut no_room) = (None, None);
        for (name, r) in &st.runners {
            if r.r.trust == RunnerTrust::Shared
                && let Some(why) = &q.shared_why
            {
                held_off.get_or_insert_with(|| why.clone());
                continue;
            }
            if fit
                && let Some(rd) = &r.ready
                && !fits(&need, &rd.budget)
            {
                no_room.get_or_insert(WaitReason::NoRoom {
                    need_mib: need.mem_mib,
                    free_mib: rd.budget.mem_mib,
                });
                continue;
            }
            let missing_bytes = match &q.s.inputs {
                Some(f) if !r.synced.contains(&f.input_key) => overlay_bytes(f),
                _ => 0,
            };
            cands.push(Candidate {
                name: name.clone(),
                local: false,
                trust: r.r.trust,
                keys_allowed: vec![],
                features: job.spec.features.clone(),
                state: r.state.clone(),
                accept: r.r.accept,
                link_bps: None,
                missing_bytes,
                start_s: 0.0,
                wait_s: 0.0,
                speed: 1.0,
                history: history.clone(),
                cloud: None,
            });
        }
        (cands, held_off, no_room)
    }

    /// How a start of the job whose slot is SLOT, in IMAGE, would be on C: warm when C's last `ready` lists both.
    /// Unknown on this machine, and on a runner that sent no `ready`.
    fn warmth(st: &St, slot: &str, image: Option<&str>, c: &Candidate) -> Option<Warmth> {
        if c.local {
            return None;
        }
        let rd = st.runners.get(&c.name)?.ready.as_ref()?;
        Some(Warmth {
            slot_near: rd.slots.iter().any(|s| s == slot),
            images_present: image.is_some_and(|i| rd.images.iter().any(|x| x == i)),
        })
    }

    /// Places JOB: here (admitted: started), on a runner (offered), or not yet (why). The head's reservation holds a
    /// machine against a job that wouldn't end before the head's start there; that job may still go elsewhere.
    fn place(&self, st: &mut St, job: &Job, eff: Priority, now: u64, starts: &mut Vec<String>) {
        let id = job.id.0.clone();
        let Some(q) = st.jobs.get(&id) else {
            return;
        };
        let keyed = !job.spec.keys.is_empty();
        let (mut cands, held_off, no_room) = Self::candidates(st, job, q, true);
        let ctx = PlaceCtx {
            eff,
            send: q.s.place.send.forseti(),
            machines_cell_allows: q.s.place.machines_cell,
            gates_allowed: false,
            cloud_after_s: CLOUD_AFTER_S,
            now,
            commits_not_on_origin: q.s.inputs.as_ref().map_or(0, Frozen::commits_not_on_origin),
        };
        // the pick (with what placement learned and how warm each start would be; no history: the static rule), the
        // head's reservation, then this machine's own admission: held or refused on one machine, the job may still go
        // to another
        let slot = sleipnir::sync::slot::SlotKey::of(&job.spec).id();
        let image = q.s.place.image.clone();
        let warmth = |c: &Candidate| Self::warmth(st, &slot, image.as_deref(), c);
        let expect =
            |c: &Candidate| forseti::finish_with(job, c, now, &st.learned, warmth(c)).expected_s;
        let held = |c: &Candidate| {
            let r = st.reservation.as_ref();
            forseti::head_protection(&job.id, eff, &c.name, expect(c), r, now).err()
        };
        let (mut here, mut kept): (Option<WaitReason>, Option<WaitReason>) = (None, None);
        let placed = loop {
            match forseti::pick_with(job, &cands, &ctx, &st.learned, &warmth) {
                Pick::Local => {
                    let c = cands.iter().find(|c| c.local).expect("this machine");
                    if let Some(why) = held(c) {
                        kept.get_or_insert(why);
                        cands.retain(|c| !c.local);
                        continue;
                    }
                    let e = expect(c);
                    let running: Vec<RunningJob> = st.local_running.values().cloned().collect();
                    match self
                        .local
                        .admit(job, eff, &running, st.last_local_start, now)
                    {
                        Ok(g) => break Placed::Here(g, e),
                        Err(r) => {
                            here.get_or_insert(r);
                            cands.retain(|c| !c.local);
                        }
                    }
                }
                Pick::Runner(n) => {
                    let c = cands
                        .iter()
                        .find(|c| !c.local && c.name == n)
                        .expect("the runner");
                    if let Some(why) = held(c) {
                        kept.get_or_insert(why);
                        cands.retain(|c| c.local || c.name != n);
                        continue;
                    }
                    let warm = warmth(c).is_some_and(Warmth::warm);
                    break Placed::There(n, expect(c), warm);
                }
                Pick::Wait(r) => {
                    let why = kept.take().or(here.take()).or(no_room.clone());
                    break Placed::Wait(why.unwrap_or(r));
                }
            }
        };
        // the head is placed: nothing is held for it any more
        if !matches!(placed, Placed::Wait(_))
            && st.reservation.as_ref().is_some_and(|r| r.job == job.id)
        {
            st.reservation = None;
        }
        let q = st.jobs.get_mut(&id).expect("the job");
        match placed {
            Placed::Here(g, e) => {
                q.state = QState::Local;
                q.machine = Some(LOCAL.into());
                q.waiting = None;
                let j = q.clone();
                let mut rj = running(&id, eff, now, g.reserve_mib, g.cores);
                rj.expected.minutes = e / 60.0;
                st.local_running.insert(id.clone(), rj);
                st.last_local_start = Some(now);
                self.put_job(&j, eff);
                starts.push(id);
            }
            Placed::There(name, e, warm) => self.offer(st, job, eff, &name, (e, warm), now),
            Placed::Wait(r) => {
                let why = forseti::place::why_here(job, &cands, &ctx).or(held_off);
                if keyed {
                    let base = "waits for a runner: its keys reach no job on this machine";
                    q.waiting = Some(match (why, &r) {
                        (Some(w), _) => format!("{base} ({})", w.trim_start_matches("runs here: ")),
                        (None, WaitReason::NoRunner) => base.to_string(),
                        (None, r) => format!("{base} ({})", wait_text(r)),
                    });
                    return;
                }
                // trust alone keeps it off every runner: the design's "runs here: …" words say why
                if let Some(why) = why {
                    q.waiting = Some(why);
                    return;
                }
                // a runner's refusal stays shown until something else holds the job
                let refused = q.waiting.as_deref().is_some_and(|w| w.contains(": "));
                if !refused || !matches!(r, WaitReason::Mode | WaitReason::NoRunner) {
                    q.waiting = Some(wait_text(&r));
                }
            }
        }
    }

    /// Offers JOB to runner NAME, where it is expected to take EXPECTED_S (from a WARM start or not): a new attempt
    /// with a nonce. Until the runner's next `ready`, its budget counts the job's need as taken.
    fn offer(
        &self,
        st: &mut St,
        job: &Job,
        eff: Priority,
        name: &str,
        (expected_s, warm): (f64, bool),
        now: u64,
    ) {
        let id = job.id.0.clone();
        let Some(rr) = st.runners.get_mut(name) else {
            return;
        };
        let grace_s = rr.grace();
        let need = need_of(job);
        if let Some(rd) = rr.ready.as_mut() {
            rd.budget.mem_mib -= need.mem_mib as i64;
            rd.budget.cpu -= need.cpu;
        }
        st.on.insert(
            id.clone(),
            OnMachine {
                machine: name.into(),
                since: now,
                expected_s,
                reserve_mib: job.spec.mem_mib.min,
                cores: job.spec.cores.min,
                priority: eff,
                restartable: job.spec.restartable,
                warm,
            },
        );
        let q = st.jobs.get_mut(&id).expect("the job");
        q.attempt += 1;
        let r = JobRef {
            job: id.clone(),
            attempt: q.attempt,
            nonce: nonce(),
        };
        q.state = QState::Remote(name.into());
        q.machine = Some(name.into());
        q.waiting = None;
        let j = q.clone();
        st.attempts.step(
            now,
            AEvent::Placed {
                job: id.clone(),
                attempt: r.attempt,
                nonce: r.nonce,
                runner: name.into(),
                grace_s,
                restartable: job.spec.restartable,
            },
        );
        if let Some(rr) = st.runners.get(name) {
            // a requeue of a job whose suite selects rows runs only the rows without a result
            let spec = attempt_spec(&job.spec, j.s.place.suite.as_ref(), st.rows.get(&id));
            rr.session.send(Frame::Offer {
                r: r.clone(),
                spec: Box::new(spec),
                priority: eff,
                input_key: j
                    .s
                    .inputs
                    .as_ref()
                    .map(|f| f.input_key.clone())
                    .unwrap_or_default(),
                grant_hint: None,
                expected: None,
            });
        }
        self.put_job(&j, eff);
        self.put_attempts(st, &id);
        let (attempt, runner) = (r.attempt, name.to_string());
        self.persist(Box::new(move |c| {
            c.execute(
                "insert into rq_offer(job, attempt, runner, sent, expires) values (?1, ?2, ?3, ?4, ?5)",
                (id, attempt, runner, now as f64, (now + 60) as f64),
            )?;
            Ok(())
        }));
    }

    /// Runner NAME's health check at NOW: started when due (its probe asked, its canary offered, offered again after a
    /// refusal), judged once every answer is in or its wait has run out. A pass clears its strikes and returns it to
    /// rotation; a failure is a strike, which may bench it.
    fn health(&self, st: &mut St, name: &str, now: u64) {
        let Some(r) = st.runners.get_mut(name) else {
            return;
        };
        if r.next_check == 0 {
            r.next_check = now + health::CHECK_EVERY_S;
        }
        let up = matches!(r.state, RunnerState::Ready | RunnerState::Benched(_));
        if r.check.is_none() && up && now >= r.next_check {
            r.session.send(Frame::Probe);
            r.check = Some(Check {
                started: now,
                canary: None,
                last_offer: 0,
                facts: Facts::default(),
            });
        }
        let Some(c) = r.check.as_mut() else {
            return;
        };
        c.facts.skew_s = r.skew_s;
        let offer = c.canary.is_none() && now >= c.last_offer + 2 && c.facts.canary.is_none();
        let done = c.facts.complete() || now >= c.started + health::CHECK_WAIT_S;
        if offer && !done {
            let id = canary_id(name, now);
            c.canary = Some(id.clone());
            c.last_offer = now;
            let r = JobRef {
                job: id.clone(),
                attempt: 1,
                nonce: nonce(),
            };
            let mut spec = blank_spec("health check");
            spec.command = vec!["true".into()];
            spec.tree = PathBuf::from("/src/health");
            spec.cwd = PathBuf::from(".");
            spec.mem_mib = Range { min: 64, max: 256 };
            spec.timeout_s = 60;
            spec.restartable = false;
            st.attempts.step(
                now,
                AEvent::Placed {
                    job: id,
                    attempt: 1,
                    nonce: r.nonce,
                    runner: name.into(),
                    grace_s: 0,
                    restartable: false,
                },
            );
            if let Some(rr) = st.runners.get(name) {
                rr.session.send(Frame::Offer {
                    r,
                    spec: Box::new(spec),
                    priority: Priority::P1,
                    input_key: String::new(),
                    grant_hint: None,
                    expected: None,
                });
            }
            return;
        }
        if !done {
            return;
        }
        let Some(c) = r.check.take() else {
            return;
        };
        r.next_check = now + health::CHECK_EVERY_S;
        match health::judge(&c.facts) {
            Ok(()) => {
                r.strikes.clear();
                if matches!(r.state, RunnerState::Benched(_)) {
                    r.state = RunnerState::Ready;
                }
                tracing::info!("runners: {name}: the health check passed");
            }
            Err(why) => {
                tracing::info!("runners: {name}: the health check failed: {why}");
                let reason = format!("{}: {why}", health::CHECK);
                if r.strikes.strike(now, &reason) {
                    r.state = RunnerState::Benched(reason);
                }
            }
        }
        if let Some(job) = c.canary {
            st.attempts.forget(&job);
        }
    }

    /// The canary of a check on RUNNER ended: VERDICT, or none when it never ran (refused: offered again).
    fn canary_ended(st: &mut St, job: &str, verdict: Option<forseti::Verdict>) {
        for r in st.runners.values_mut() {
            if let Some(c) = r.check.as_mut()
                && c.canary.as_deref() == Some(job)
            {
                match verdict {
                    Some(v) => c.facts.canary = Some(v),
                    None => c.canary = None,
                }
                return;
            }
        }
    }

    /// The strike a verdict of RUNNER's is, if any: counted, and the runner benched at its second.
    fn strike_of(st: &mut St, runner: &str, v: &forseti::Verdict, now: u64) {
        let Some(r) = st.runners.get_mut(runner) else {
            return;
        };
        let ctx = StrikeCtx {
            link_lost_today: 0,
            link_stayed_up: !matches!(r.state, RunnerState::Unreachable { .. }),
        };
        if r.strikes.record(now, v, &ctx) {
            r.state = RunnerState::Benched(v.to_string());
            tracing::warn!("runners: {runner} is benched: {v}");
        }
    }

    /// A runner's link event at NOW: frames into the attempt state machine, its effects carried out.
    pub fn on_link(&self, ev: LinkEvent, now: u64) -> Vec<Outcome> {
        let mut st = self.lock();
        let mut out = vec![];
        match ev {
            LinkEvent::Logged { r, upto, .. } => st.attempts.logged(&r, upto),
            LinkEvent::Clock { runner, at } => {
                if let Some(r) = st.runners.get_mut(&runner) {
                    r.skew_s = Some(at as i64 - now as i64);
                }
            }
            LinkEvent::Lost { runner, why } => {
                tracing::info!("runners: {runner}: the link is lost ({why})");
                self.link_lost(&mut st, &runner, now, &mut out);
            }
            LinkEvent::Bye { runner } => self.link_lost(&mut st, &runner, now, &mut out),
            LinkEvent::Frame { runner, frame } => {
                self.frame(&mut st, &runner, frame, now, &mut out)
            }
        }
        out
    }

    fn link_lost(&self, st: &mut St, runner: &str, now: u64, out: &mut Vec<Outcome>) {
        // a link lost while jobs ran is a strike the second time in a day
        let ran = st
            .attempts
            .attempts()
            .any(|(_, a)| a.runner == runner && a.state.open());
        if let Some(r) = st.runners.get_mut(runner) {
            if ran {
                let ctx = StrikeCtx {
                    link_lost_today: r.strikes.lost_link(now),
                    link_stayed_up: false,
                };
                let lost = forseti::Verdict::Infra(forseti::classify::infra::RUNNER_LOST.into());
                if r.strikes.record(now, &lost, &ctx) {
                    tracing::warn!("runners: {runner} is benched: its link was lost twice today");
                }
            }
            r.state = match (r.strikes.benched(), &r.state) {
                (Some(why), _) => RunnerState::Benched(why.to_string()),
                // a login the user must do stays the reason until the runner's next hello
                (None, RunnerState::NeedsLogin(cmd)) => RunnerState::NeedsLogin(cmd.clone()),
                (None, _) => RunnerState::Unreachable { since: now },
            };
        }
        let effects = st.attempts.step(
            now,
            AEvent::LinkLost {
                runner: runner.into(),
            },
        );
        let jobs = jobs_of(&effects);
        self.apply(st, effects, now, out);
        for j in st.jobs.keys().cloned().collect::<Vec<_>>() {
            if st
                .attempts
                .current(&j)
                .is_some_and(|(_, a)| a.runner == runner)
                || jobs.contains(&j)
            {
                self.put_attempts(st, &j);
            }
        }
    }

    fn frame(&self, st: &mut St, runner: &str, f: Frame, now: u64, out: &mut Vec<Outcome>) {
        let ev = match f {
            Frame::HelloOk {
                attempts, linger, ..
            } => {
                if let Some(r) = st.runners.get_mut(runner) {
                    // a benched runner stays out of rotation until a check passes or the user unbenches it
                    r.state = match r.strikes.benched() {
                        Some(why) => RunnerState::Benched(why.to_string()),
                        None => RunnerState::Ready,
                    };
                    // linger is read again at every hello: without it the jobs there end with the login, so their
                    // attempts have no grace, from now on and for those placed before
                    r.linger = linger;
                    let grace = r.grace();
                    st.attempts.set_grace(runner, grace);
                }
                AEvent::Hello {
                    runner: runner.into(),
                    listed: attempts.iter().map(Listed::from).collect(),
                }
            }
            Frame::Admit { r, grant } => {
                if st.attempts.frame_ok(runner, &r) == Some(false) {
                    // backfill counts what the runner granted it
                    if let Some(o) = st.on.get_mut(&r.job) {
                        o.reserve_mib = grant.reserve_mib;
                        o.cores = grant.cores;
                    }
                    // a job with frozen inputs syncs them first; its start follows the last `sync-need`
                    let frozen = st.jobs.get(&r.job).and_then(|j| j.s.inputs.clone());
                    match frozen {
                        Some(f) if !is_canary(&r.job) => Self::sync_have(st, runner, &r, &f),
                        _ => self.start(st, runner, &r),
                    }
                    let (job, attempt, runner) = (r.job.clone(), r.attempt, runner.to_string());
                    let grant = serde_json::to_string(&grant).unwrap_or_default();
                    self.persist(Box::new(move |c| {
                        c.execute(
                            "insert or replace into rq_admission(job, attempt, runner, grant, admitted) \
                             values (?1, ?2, ?3, ?4, ?5)",
                            (job, attempt, runner, grant, now as f64),
                        )?;
                        Ok(())
                    }));
                }
                AEvent::FrameFrom {
                    runner: runner.into(),
                    r,
                }
            }
            Frame::Refuse { r, why, .. } => {
                let current = st.attempts.frame_ok(runner, &r) == Some(false);
                let job = r.job.clone();
                let effects = st.attempts.step(
                    now,
                    AEvent::Refused {
                        runner: runner.into(),
                        r,
                    },
                );
                self.apply(st, effects, now, out);
                self.put_attempts(st, &job);
                if is_canary(&job) {
                    // a check's canary refused (the runner busy): offered again
                    st.attempts.forget(&job);
                    Self::canary_ended(st, &job, None);
                    return;
                }
                if current && let Some(j) = st.jobs.get_mut(&job) {
                    j.waiting = Some(format!("{runner}: {why}"));
                }
                return;
            }
            Frame::SyncNeed {
                r,
                blobs,
                commit,
                refs,
            } => {
                if st.attempts.frame_ok(runner, &r) == Some(false) {
                    self.sync_need(st, runner, &r, &blobs, commit, &refs, now);
                }
                return;
            }
            Frame::ProbeResult {
                facts,
                missing,
                limits,
                key_socket,
                ..
            } => {
                if let Some(c) = st.runners.get_mut(runner).and_then(|r| r.check.as_mut()) {
                    c.facts.probed = true;
                    c.facts.missing = missing.iter().map(|m| m.what.clone()).collect();
                    c.facts.limits = limits;
                    c.facts.key_socket = key_socket;
                    // the probe's facts carry the free space only: the floor is its 20 GB part
                    if let Some(f) = facts {
                        c.facts.disk_free_gb = f.disk_free_gb;
                    }
                }
                return;
            }
            Frame::Started { r, .. } => {
                // a keyed job's keys go now, after `started` only, one frame each
                let keyed = st
                    .jobs
                    .get(&r.job)
                    .is_some_and(|j| !j.s.place.keys.is_empty());
                let current = st.attempts.frame_ok(runner, &r) == Some(false);
                if keyed && current {
                    st.keyed.entry((r.job.clone(), r.attempt)).or_default();
                    self.send_keys(st, &r.job, r.attempt, now);
                }
                // its expected end counts from its start
                if current && let Some(o) = st.on.get_mut(&r.job) {
                    o.since = now;
                }
                let job = r.job.clone();
                let effects = st.attempts.step(
                    now,
                    AEvent::Started {
                        runner: runner.into(),
                        r,
                    },
                );
                self.apply(st, effects, now, out);
                // the attempt runs: `runtime.db` says so, so a restart reads `running`, never `offered`
                self.put_attempts(st, &job);
                return;
            }
            Frame::Ready {
                free_mib,
                free_cpu,
                slots,
                images,
                ..
            } => {
                if let Some(r) = st.runners.get_mut(runner) {
                    r.ready = Some(ReadyNow {
                        budget: forseti::Budget {
                            mem_mib: free_mib,
                            cpu: free_cpu,
                        },
                        slots,
                        images,
                    });
                }
                return;
            }
            Frame::KeyUse { r, name, at } => {
                // the runner's word: recorded as runner-reported, for an attempt the hub placed there only
                if st.attempts.frame_ok(runner, &r).is_some()
                    && let Some(row) = keys::row(
                        runstav::methods::runners::AuditKind::Use,
                        &r,
                        &name,
                        runner,
                        if at > 0 { at } else { now },
                    )
                {
                    self.keys.record(row);
                }
                AEvent::FrameFrom {
                    runner: runner.into(),
                    r,
                }
            }
            Frame::Finished { r, result } => {
                let job = r.job.clone();
                self.end_redaction(st, runner, &r);
                let late = st.attempts.frame_ok(runner, &r) == Some(true)
                    || st
                        .attempts
                        .attempt(&r.job, r.attempt)
                        .is_some_and(|a| !a.state.open());
                let effects = st.attempts.step(
                    now,
                    AEvent::Finished {
                        runner: runner.into(),
                        r: r.clone(),
                        result: result.clone(),
                    },
                );
                if late && effects.iter().any(|e| matches!(e, Effect::KeepLate { .. })) {
                    let path = self
                        .exec_root
                        .join(&job)
                        .join(format!("result.{}.json", r.attempt));
                    if let Err(e) = std::fs::write(&path, result.to_string()) {
                        tracing::warn!("runners: {}: {e}", path.display());
                    }
                    out.push(Outcome::Late {
                        id: job.clone(),
                        attempt: r.attempt,
                        result,
                    });
                }
                // the result is recorded: the runner's folder of it may go
                let recorded = effects
                    .iter()
                    .any(|e| matches!(e, Effect::Verdict { .. } | Effect::KeepLate { .. }));
                if recorded && let Some(rr) = st.runners.get(runner) {
                    rr.session.send(Frame::Done { r });
                }
                self.put_attempts(st, &job);
                self.apply(st, effects, now, out);
                return;
            }
            Frame::Row { r, name, verdict } => {
                // a row counts for an attempt the hub placed there with that nonce, its job's current one or a late
                // one, until the job's verdict is recorded
                if st.attempts.frame_ok(runner, &r).is_some() && st.jobs.contains_key(&r.job) {
                    self.record_row(st, &r, &name, &verdict, runner);
                }
                AEvent::FrameFrom {
                    runner: runner.into(),
                    r,
                }
            }
            Frame::Preempting { .. } => {
                if let Some(r) = st.runners.get_mut(runner) {
                    r.state = RunnerState::Preempting;
                }
                AEvent::Preempting {
                    runner: runner.into(),
                }
            }
            Frame::Draining => {
                if let Some(r) = st.runners.get_mut(runner) {
                    r.state = RunnerState::Draining;
                }
                return;
            }
            f => match f.job() {
                Some(r) => AEvent::FrameFrom {
                    runner: runner.into(),
                    r: r.clone(),
                },
                None => return,
            },
        };
        let effects = st.attempts.step(now, ev);
        let jobs = jobs_of(&effects);
        self.apply(st, effects, now, out);
        for j in jobs {
            self.put_attempts(st, &j);
        }
    }

    /// Attempt R on RUNNER sent its result: its log's redactor gives back what it held, and the heuristic's notices
    /// (never a change to the log) go to the user, read off the queue's lock.
    fn end_redaction(&self, st: &mut St, runner: &str, r: &JobRef) {
        st.keyed.remove(&(r.job.clone(), r.attempt));
        let Some(late) = st.attempts.frame_ok(runner, r) else {
            return;
        };
        let path = log_file(&self.exec_root, r, late);
        if let Some(mut rd) = self.redactors().remove(&(r.job.clone(), r.attempt)) {
            let tail = rd.r.finish();
            if !tail.is_empty()
                && let Err(e) = append_end(&path, &tail)
            {
                tracing::warn!("runners: {}: {e}", path.display());
            }
        }
        if is_canary(&r.job) {
            return;
        }
        let (keys, job, attempt, runner) = (
            self.keys.clone(),
            r.job.clone(),
            r.attempt,
            runner.to_string(),
        );
        std::thread::spawn(move || {
            let log = std::fs::read(&path).unwrap_or_default();
            let found = redact::notices(&log);
            // one notice per log: the first line, and how many more
            if let Some(first) = found.first() {
                let text = match found.len() - 1 {
                    0 => first.clone(),
                    more => format!("{first} (and {more} more lines)"),
                };
                keys.tell_event(
                    "notice",
                    json!({
                        "source": "hub",
                        "severity": "warn",
                        "id": format!("runners-log-{job}-{attempt}"),
                        "life": "event",
                        "text": format!("job {job} on {runner}: {text}"),
                    }),
                );
            }
        });
    }

    /// Starts admitted attempt R on RUNNER ([`Queue::start_frame`]). A keyed job's log is redacted from its first byte.
    fn start(&self, st: &St, runner: &str, r: &JobRef) {
        let keyed = st
            .jobs
            .get(&r.job)
            .is_some_and(|j| !j.s.place.keys.is_empty());
        if keyed {
            self.new_redactor(st, r, false);
        }
        if let Some(rr) = st.runners.get(runner) {
            rr.session.send(Self::start_frame(st, runner, r));
        }
    }

    /// The `start` of attempt R on RUNNER: the job's image (a health check's canary's: the runner's own), the hosts its
    /// network grant reaches (its proxy there allows those), and the row parser of its suite.
    fn start_frame(st: &St, runner: &str, r: &JobRef) -> Frame {
        let image = if is_canary(&r.job) {
            st.runners.get(runner).and_then(|rr| rr.r.image.clone())
        } else {
            st.jobs.get(&r.job).and_then(|j| j.s.place.image.clone())
        };
        // a test job's rows come back as `row` frames when its suite names their parser
        let parser = st
            .jobs
            .get(&r.job)
            .and_then(|j| j.s.place.suite.as_ref())
            .map_or_else(|| "exit".to_string(), |s| s.parser.clone());
        let net_hosts = st
            .jobs
            .get(&r.job)
            .map(|j| j.s.place.net_hosts.clone())
            .unwrap_or_default();
        Frame::Start {
            r: r.clone(),
            image,
            env: vec![],
            net_hosts,
            // a runner's proxy connects only to public addresses and pins no name
            pins: vec![],
            parser,
        }
    }

    /// Tells RUNNER what attempt R's inputs F are, with the part of the overlay its trust may get; it answers with
    /// what it lacks (`sync-need`).
    fn sync_have(st: &mut St, runner: &str, r: &JobRef, f: &Frozen) {
        let Some(rr) = st.runners.get(runner) else {
            return;
        };
        match sync::overlay_for(f, rr.r.trust) {
            Ok(manifest) => {
                rr.session.send(Frame::SyncHave {
                    r: r.clone(),
                    repo: f.repo.clone(),
                    input_key: f.input_key.clone(),
                    commit: f.commit.clone(),
                    tree: f.tree.clone(),
                    manifest,
                });
                st.syncs.entry((r.job.clone(), r.attempt)).or_default();
            }
            Err(why) => Self::give_up(st, runner, r, &why),
        }
    }

    /// Attempt R's sync can't go on: RUNNER cancels the attempt (its reservation goes there), and why is logged.
    fn give_up(st: &mut St, runner: &str, r: &JobRef, why: &str) {
        tracing::warn!("runners: {}: the sync to {runner} stops: {why}", r.job);
        st.syncs.remove(&(r.job.clone(), r.attempt));
        if let Some(rr) = st.runners.get(runner) {
            rr.session.send(Frame::Cancel { r: r.clone() });
        }
    }

    /// RUNNER's answer for attempt R: it lacks the commit (an origin fetch, or a bundle), or these BLOBS of the
    /// overlay (sent, then asked again), or nothing (the attempt starts). Its mirror holds REFS.
    #[allow(clippy::too_many_arguments)]
    fn sync_need(
        &self,
        st: &mut St,
        runner: &str,
        r: &JobRef,
        blobs: &[Sha256],
        commit: bool,
        refs: &[String],
        now: u64,
    ) {
        let Some(f) = st.jobs.get(&r.job).and_then(|j| j.s.inputs.clone()) else {
            return;
        };
        let Some(trust) = st.runners.get(runner).map(|rr| rr.r.trust) else {
            return;
        };
        // the project's deploy key for a runner of the user's, when the hub holds it (one it doesn't is asked for, and
        // the commit goes another way meanwhile)
        let origin_key = st
            .jobs
            .get(&r.job)
            .and_then(|j| j.s.place.origin_key.clone())
            .filter(|_| commit && trust != RunnerTrust::Shared);
        let origin_cred = origin_key.as_ref().and_then(|n| {
            let v = self.keys.value(n);
            if v.is_none() {
                self.keys.ask(std::slice::from_ref(n));
            }
            v.map(|v| (n.clone(), v))
        });
        let key = (r.job.clone(), r.attempt);
        let s = st.syncs.entry(key.clone()).or_default();
        s.rounds += 1;
        // a bundle sent before has been taken in, or failed: its file goes, and a new one is made if still needed. One
        // taken in (the runner no longer lacks the commit) times the link: its bytes over the time to this answer
        let taken = s
            .bundle
            .take()
            .filter(|_| !commit)
            .map(|b| (b.size, now.saturating_sub(s.sent_at)));
        if let Some((bytes, secs)) = taken {
            st.learned.observe_transfer(runner, bytes, secs as f64);
        }
        let s = st.syncs.entry(key.clone()).or_default();
        if s.rounds > SYNC_ROUNDS {
            let why = format!("the runner still lacks the inputs after {SYNC_ROUNDS} rounds");
            return Self::give_up(st, runner, r, &why);
        }
        let Some(rr) = st.runners.get(runner) else {
            return;
        };
        let send = |fr: Frame| rr.session.send(fr);
        if commit {
            let missing = match trust {
                RunnerTrust::Shared => Ok(0),
                _ => sync::missing_bytes(&f.worktree, &f.commit, refs),
            };
            let key_name = origin_cred.as_ref().map(|(n, _)| n.clone());
            let done = missing.and_then(|m| match sync::plan(&f, trust, m, key_name.as_deref()) {
                SyncPlan::Origin { url, cred } => {
                    // the deploy key goes first, in a `key` frame like any key, and the fetch names it
                    let cred = match (cred, origin_cred) {
                        (Some(name), Some((_, value))) => {
                            let sent = send(Frame::Key(sleipnir::proto::Key {
                                r: r.clone(),
                                name: name.clone(),
                                value: sleipnir::proto::KeyValue::new(value),
                            }));
                            if sent
                                && let Some(row) = keys::row(
                                    runstav::methods::runners::AuditKind::Sent,
                                    r,
                                    &name,
                                    runner,
                                    now,
                                )
                            {
                                self.keys.record(row);
                            }
                            Some(name)
                        }
                        _ => None,
                    };
                    send(Frame::OriginFetch {
                        r: r.clone(),
                        repo: f.repo.clone(),
                        url,
                        commit: f.commit.clone(),
                        cred,
                    });
                    Ok(None)
                }
                // a push goes as a bundle too, until the hub pushes over the runner's master
                SyncPlan::Bundle { .. } | SyncPlan::Push => {
                    let b =
                        sync::make_bundle(&f.worktree, &f.commit, refs, &f.blobs.join("bundles"))?;
                    let id = format!("{}.{}", r.job, r.attempt);
                    sync::send_bundle(&send, r, &id, &b, 0)?;
                    Ok(Some(b))
                }
                SyncPlan::Never(why) => Err(why),
            });
            match done {
                Ok(b) => {
                    if let Some(s) = st.syncs.get_mut(&key) {
                        s.bundle = b;
                        s.sent_at = now;
                    }
                }
                Err(why) => Self::give_up(st, runner, r, &why),
            }
            return;
        }
        // only the blobs of this attempt's own overlay, in chunks
        let ours: Vec<[u8; 32]> = sync::overlay_for(&f, trust)
            .unwrap_or_default()
            .iter()
            .filter_map(|e| match e {
                ManifestEntry::File {
                    sha256: Sha256(s), ..
                } => Some(*s),
                ManifestEntry::Deleted { .. } => None,
            })
            .collect();
        let mut failed = None;
        for Sha256(sha) in blobs {
            if !ours.contains(sha) {
                tracing::warn!(
                    "runners: {runner} asked {} for a blob not in its overlay",
                    r.job
                );
                continue;
            }
            if let Err(e) = sync::send_blob(&send, r, &f, sha) {
                failed = Some(e);
                break;
            }
        }
        if let Some(why) = failed {
            return Self::give_up(st, runner, r, &why);
        }
        if !blobs.is_empty() {
            return Self::sync_have(st, runner, r, &f);
        }
        st.syncs.remove(&key);
        // the runner holds these inputs now: a later job of them sends it nothing
        if let Some(rr) = st.runners.get_mut(runner)
            && !rr.synced.contains(&f.input_key)
        {
            rr.synced.push(f.input_key.clone());
            if rr.synced.len() > SYNCED_KEPT {
                rr.synced.remove(0);
            }
        }
        self.start(st, runner, r);
    }

    /// Carries out the attempt state machine's EFFECTS.
    fn apply(&self, st: &mut St, effects: Vec<Effect>, now: u64, out: &mut Vec<Outcome>) {
        for e in effects {
            let mut was_on = None;
            // an attempt that ended, or went back to the queue, syncs no more (its bundle file goes), and holds nothing
            // on its runner as backfill counts it
            if let Effect::Verdict { job, .. }
            | Effect::Requeue { job, .. }
            | Effect::Lost { job } = &e
            {
                was_on = st.on.remove(job);
                st.syncs.retain(|(j, _), _| j != job);
                // and is sent no more keys; what its redactor held back goes with it (it could begin a key)
                st.keyed.retain(|(j, _), _| j != job);
                self.redactors().retain(|(j, _), _| j != job);
            }
            match e {
                Effect::Verdict {
                    job,
                    attempt,
                    result,
                } => {
                    let runner = st.attempts.attempt(&job, attempt).map(|a| a.runner.clone());
                    let shared = runner.clone().filter(|r| {
                        st.runners
                            .get(r)
                            .is_some_and(|x| x.r.trust == RunnerTrust::Shared)
                    });
                    let verdict = verdict_of(&result)
                        .unwrap_or_else(|| forseti::Verdict::Infra("no verdict".into()));
                    if is_canary(&job) {
                        Self::canary_ended(st, &job, Some(verdict));
                        continue;
                    }
                    if let Some(r) = &runner {
                        Self::strike_of(st, r, &verdict, now);
                    }
                    // the result counts every attempt's rows, a row's latest attempt winning, and says how they split
                    let mut result = result;
                    if let Some(j) = st.jobs.get(&job) {
                        let (spec, suite) = (j.s.spec.clone(), j.s.place.suite.clone());
                        let rows = st.rows.remove(&job).unwrap_or_default();
                        // a run of only some rows says nothing of the whole job's time; a warm start's says so
                        if let Some(r) = &runner
                            && !rows.before(attempt)
                        {
                            let mut ran = result.clone();
                            if let Some(o) = ran.as_object_mut() {
                                o.insert(
                                    "warm".into(),
                                    was_on.as_ref().is_some_and(|w| w.warm).into(),
                                );
                            }
                            self.record_run(st, &spec, r, &ran, now);
                        }
                        result = merged(&result, &rows, &spec, suite.as_ref());
                    }
                    st.jobs.remove(&job);
                    st.attempts.forget(&job);
                    self.drop_job(&job);
                    out.push(Outcome::Done {
                        id: job,
                        attempt,
                        result,
                        shared,
                        machine: runner,
                    });
                }
                Effect::Requeue { job, reason } => {
                    let Some(j) = st.jobs.get_mut(&job) else {
                        continue;
                    };
                    // the next attempt's log starts afresh; this one's is kept as its own
                    let (dir, n) = (self.exec_root.join(&job), j.attempt);
                    let kept = dir.join(format!("log.{n}"));
                    let _ = std::fs::rename(dir.join("log"), &kept);
                    j.state = QState::Queued;
                    j.machine = None;
                    j.waiting = Some(format!("requeued ({reason})"));
                    let j = j.clone();
                    self.put_job(&j, j.s.own);
                    // the rows its log shows have their results, so the next attempt runs only the rest; this one
                    // stops once its runner is heard from again
                    let Some(suite) = &j.s.place.suite else {
                        continue;
                    };
                    self.rows_from_log(st, &job, n, &suite.parser, &kept);
                    if !selects_rows(&j.s.spec, Some(suite)) {
                        continue;
                    }
                    st.cancel_late.insert((job.clone(), n));
                    // every listed row has its result already: the job ends from them, judged as a finish is, and
                    // nothing runs again
                    let done = st.rows.get(&job).map(Rows::done).unwrap_or_default();
                    if forseti::split::remaining_rows(&suite.listed, &done).is_empty() {
                        let rows = st.rows.remove(&job).unwrap_or_default();
                        let ran = json!({"verdict": "Pass"});
                        let result = merged(&ran, &rows, &j.s.spec, Some(suite));
                        let shared = st
                            .attempts
                            .attempt(&job, n)
                            .map(|a| a.runner.clone())
                            .filter(|r| {
                                st.runners
                                    .get(r)
                                    .is_some_and(|x| x.r.trust == RunnerTrust::Shared)
                            });
                        // requeued, so its row no longer names the runner: the attempt's does
                        let machine = st.attempts.attempt(&job, n).map(|a| a.runner.clone());
                        st.jobs.remove(&job);
                        st.attempts.forget(&job);
                        self.drop_job(&job);
                        out.push(Outcome::Done {
                            id: job,
                            attempt: n,
                            result,
                            shared,
                            machine,
                        });
                    }
                }
                Effect::Lost { job } if is_canary(&job) => {
                    let lost =
                        forseti::Verdict::Infra(forseti::classify::infra::RUNNER_LOST.into());
                    Self::canary_ended(st, &job, Some(lost));
                }
                Effect::Lost { job } => {
                    st.rows.remove(&job);
                    st.jobs.remove(&job);
                    st.attempts.forget(&job);
                    self.drop_job(&job);
                    out.push(Outcome::Lost { id: job });
                }
                Effect::Ignore { notice } => tracing::info!("runners: {notice}"),
                Effect::ResumeLog {
                    job,
                    attempt,
                    offset,
                } => {
                    let Some(a) = st.attempts.attempt(&job, attempt) else {
                        continue;
                    };
                    let r = JobRef {
                        job: job.clone(),
                        attempt,
                        nonce: a.nonce,
                    };
                    let runner = a.runner.clone();
                    // a keyed job's log is taken in again only through a redactor of all its keys, from where the
                    // hub's copy ends; with a key not back yet it waits for `runners/keys`
                    let keys = st
                        .jobs
                        .get(&job)
                        .map(|j| j.s.place.keys.clone())
                        .unwrap_or_default();
                    let copied = self
                        .redactors()
                        .get(&(job.clone(), attempt))
                        .map(|rd| rd.consumed);
                    let offset = if keys.is_empty() {
                        offset
                    } else if let Some(c) = copied {
                        c
                    } else if self.keys.missing(&keys).is_empty() {
                        self.new_redactor(st, &r, true)
                    } else {
                        // its log and result wait for the keys (a hub restart): the user is asked for them, a card
                        // that is never answered from the event
                        self.keys.ask(&self.keys.missing(&keys));
                        continue;
                    };
                    // a late attempt whose rows the next attempt reruns is stopped, its log and result kept: no row
                    // runs to its end twice
                    let stop = st.cancel_late.remove(&(job.clone(), attempt));
                    if let Some(rr) = st.runners.get(&runner) {
                        rr.session.send(Frame::Attach {
                            r: r.clone(),
                            log_offset: offset,
                        });
                        if stop {
                            rr.session.send(Frame::Cancel { r });
                        }
                    }
                }
                Effect::KeepLate { .. } => {}
                Effect::SendCancel { runner, r } => {
                    if let Some(rr) = st.runners.get(&runner) {
                        rr.session.send(Frame::Cancel { r });
                    }
                }
            }
        }
    }
}

/// A job's room on this machine: dropping it gives the room back ([`Queue::release`]).
pub struct Slot {
    q: Arc<Queue>,
    id: String,
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.q.release(&self.id);
    }
}

/// Where a placement put a job: here with its grant, or on a runner, each with the time it is expected to take there
/// (and on a runner whether the start is warm); or not yet, and why.
enum Placed {
    Here(forseti::Grant, f64),
    There(String, f64, bool),
    Wait(WaitReason),
}

/// What a job needs to start, as admission checks it (its minimum memory; its minimum cores, the hub knowing no CPU
/// history).
fn need_of(job: &Job) -> forseti::Need {
    let unknown = Expected {
        minutes: forseti::history::DEFAULT_MINUTES,
        cpu: f64::from(job.spec.cores.min),
        mem_p95_mib: None,
    };
    forseti::Need::of(job, &unknown)
}

/// Whether NEED fits budget B.
fn fits(need: &forseti::Need, b: &forseti::Budget) -> bool {
    b.mem_mib >= need.mem_mib as i64 && b.cpu >= need.cpu
}

/// The bytes of F's overlay and extras: what a runner that never synced these inputs lacks at least.
fn overlay_bytes(f: &Frozen) -> u64 {
    f.manifest
        .iter()
        .chain(&f.extras)
        .map(|e| match e {
            ManifestEntry::File { size, .. } => *size,
            ManifestEntry::Deleted { .. } => 0,
        })
        .sum()
}

/// Runner NAME as backfill reads it at NOW: what the hub runs there; its budget comes from its `ready`.
fn runner_state(name: &str, now: u64, running: Vec<RunningJob>) -> forseti::MachineState {
    forseti::MachineState {
        name: name.into(),
        profile: forseti::Profile::Dedicated,
        now,
        boot_id: String::new(),
        mem_total_mib: 0,
        mem_available_mib: 0,
        psi: forseti::Psi::default(),
        disk_free_gb: 0,
        disk_total_gb: 0,
        on_ac: true,
        last_start: None,
        running,
        features: vec![],
        reachable: true,
        others: vec![],
    }
}

impl OnMachine {
    /// The job ID as a running job of its machine: it holds what it was granted, all in use (the hub can't see its
    /// memory), and gives it back at its expected end.
    fn running(&self, id: &str) -> RunningJob {
        RunningJob {
            id: JobId(id.into()),
            priority: self.priority,
            started: self.since,
            reserve_mib: self.reserve_mib,
            current_mib: self.reserve_mib,
            cores: self.cores,
            expected: Expected {
                minutes: self.expected_s / 60.0,
                cpu: f64::from(self.cores),
                mem_p95_mib: None,
            },
            restartable: self.restartable,
            evicted_once: false,
            long_build: false,
        }
    }
}

/// The jobs EFFECTS are about.
fn jobs_of(effects: &[Effect]) -> Vec<String> {
    effects
        .iter()
        .filter_map(|e| match e {
            Effect::Verdict { job, .. }
            | Effect::Requeue { job, .. }
            | Effect::Lost { job }
            | Effect::ResumeLog { job, .. }
            | Effect::KeepLate { job, .. } => Some(job.clone()),
            Effect::SendCancel { r, .. } => Some(r.job.clone()),
            Effect::Ignore { .. } => None,
        })
        .collect()
}

/// A running job of the local runner's.
fn running(id: &str, eff: Priority, now: u64, reserve_mib: u64, cores: u32) -> RunningJob {
    RunningJob {
        id: JobId(id.into()),
        priority: eff,
        started: now,
        reserve_mib,
        current_mib: 0,
        cores,
        expected: Expected {
            minutes: forseti::history::DEFAULT_MINUTES,
            cpu: f64::from(cores),
            mem_p95_mib: None,
        },
        restartable: true,
        evicted_once: false,
        long_build: false,
    }
}

/// The jobs and attempts `runtime.db` kept, for [`Queue::restore`].
pub async fn stored(db: &urdr::Handle) -> (Vec<Stored>, Vec<StoredAttempt>) {
    let jobs = db
        .read(|c| {
            let mut st =
                c.prepare("select id, spec, own, state, submitted, attempt from rq_job")?;
            let rows = st
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, f64>(4)?,
                        r.get::<_, i64>(5)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_else(|e| {
            tracing::warn!("runners: the queue in runtime.db: {e}");
            vec![]
        });
    let jobs = jobs
        .into_iter()
        .filter_map(|(id, spec, own, state, submitted, attempt)| {
            let v: Value = serde_json::from_str(&spec).ok()?;
            Some(Stored {
                submit: Submit {
                    id,
                    session: v.get("session").and_then(Value::as_str).map(String::from),
                    own: Priority::from_number(own.clamp(1, 5) as u8),
                    spec: serde_json::from_value(v.get("job")?.clone()).ok()?,
                    place: serde_json::from_value(v.get("place")?.clone()).ok()?,
                    pending: v.get("pending").cloned().unwrap_or(Value::Null),
                    inputs: v
                        .get("inputs")
                        .and_then(|i| serde_json::from_value(i.clone()).ok()),
                },
                submitted: submitted as u64,
                state,
                attempt: attempt.max(0) as u32,
            })
        })
        .collect();
    let attempts = db
        .read(|c| {
            let mut st =
                c.prepare("select job, attempt, nonce, runner, state, log_offset from rq_attempt")?;
            let rows = st
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, i64>(5)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(job, attempt, nonce, runner, state, log_offset)| {
            Some(StoredAttempt {
                job,
                attempt: attempt.max(0) as u32,
                nonce: Nonce::from_hex(&nonce)?,
                runner,
                state,
                log_offset: log_offset.max(0) as u64,
            })
        })
        .collect();
    (jobs, attempts)
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure: a first attempt runs every listed row; a requeue only those without a result
    #[test]
    fn a_requeue_runs_only_the_rows_without_a_result() {
        let mut spec = blank_spec("x1");
        spec.command = vec!["sh".into(), "-c".into(), format!("run '{ROWS}'")];
        let listed: Vec<String> = (1..=5).map(|i| format!("t{i}")).collect();
        let suite = Suite {
            parser: "plist".into(),
            listed: listed.clone(),
        };
        let all = forseti::split::selector(&listed);
        let first = attempt_spec(&spec, Some(&suite), None);
        assert_eq!(first.command[2], format!("run '{all}'"));
        assert_eq!(first.select.as_deref(), Some(all.as_str()));
        let mut rows = Rows::default();
        rows.record(1, "t1", "pass", "desktop");
        rows.record(1, "t3", "fail", "desktop");
        let rest = forseti::split::selector(&["t2".into(), "t4".into(), "t5".into()]);
        let second = attempt_spec(&spec, Some(&suite), Some(&rows));
        assert_eq!(second.command[2], format!("run '{rest}'"));
        assert_eq!(second.select.as_deref(), Some(rest.as_str()));
        // the whole job again, as it is: no place for the selector, a parser that reads no rows, or no suite
        let mut no_place = spec.clone();
        no_place.command[2] = "run all".into();
        let exit = Suite {
            parser: "exit".into(),
            listed,
        };
        for (s, su) in [
            (&no_place, Some(&suite)),
            (&spec, Some(&exit)),
            (&spec, None),
        ] {
            assert!(!selects_rows(s, su));
            assert_eq!(attempt_spec(s, su, Some(&rows)), *s);
        }
        assert!(selects_rows(&spec, Some(&suite)));
    }

    // [D] pure (a runner's link fed by hand): attempt 1 is lost after every row is in the hub's copy of its log; the
    // job ends from those rows, judged as a finish is, and nothing runs again
    #[tokio::test]
    async fn a_requeue_with_every_row_done_finishes_from_the_rows() {
        use super::super::transport::{Channel, Channels};
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = Queue::new(QueueCfg {
            hub_id: "h".into(),
            exec_root: dir.path().to_path_buf(),
            local: LocalRunner::new(super::super::local::Admission::Fixed(1), dir.path()),
            db: None,
        });
        q.adopt("xbusy", Priority::P1, 100);
        let idle = || Channel::new(Box::new(tokio::io::sink()), Box::new(tokio::io::empty()));
        let session = Session::start(
            "r1",
            Channels {
                control: idle(),
                bulk_in: idle(),
                bulk_out: idle(),
            },
            q.route(),
            q.link_events(),
        );
        q.add_runner(
            RemoteRunner {
                name: "r1".into(),
                trust: RunnerTrust::Mine,
                accept: Accept::All,
                grace_s: 0,
                image: None,
            },
            session,
        );
        let hello = Frame::HelloOk {
            version: PROTO_VERSION,
            bundle: String::new(),
            hub_id: "h".into(),
            runner_id: String::new(),
            boot_id: String::new(),
            linger: false,
            attempts: vec![],
            missing: vec![],
        };
        q.on_link(
            LinkEvent::Frame {
                runner: "r1".into(),
                frame: hello,
            },
            100,
        );
        let listed: Vec<String> = ["t1", "t2", "t3"].map(String::from).to_vec();
        let mut spec = blank_spec("x1");
        spec.command = vec!["run".into(), ROWS.into()];
        q.submit(
            Submit {
                id: "x1".into(),
                session: Some("s1".into()),
                own: Priority::P3,
                spec,
                place: Placement {
                    heavy: true,
                    suite: Some(Suite {
                        parser: "plist".into(),
                        listed,
                    }),
                    ..Placement::default()
                },
                pending: Value::Null,
                inputs: None,
            },
            100,
        );
        q.tick(100);
        assert_eq!(q.row("x1").and_then(|r| r.machine), Some("r1".into()));
        // every listed row reached the hub's copy before the link was lost
        std::fs::create_dir_all(dir.path().join("x1")).unwrap();
        let rows = "(:name \"t1\" :verdict pass)\n(:name \"t2\" :verdict skip)\n(:name \"t3\" :verdict pass)\n";
        std::fs::write(dir.path().join("x1/log"), rows).unwrap();
        let out = q.on_link(
            LinkEvent::Lost {
                runner: "r1".into(),
                why: "test".into(),
            },
            110,
        );
        let [
            Outcome::Done {
                id,
                attempt: 1,
                result,
                shared: None,
                ..
            },
        ] = &out[..]
        else {
            panic!("the job didn't end from its rows: {out:?}");
        };
        assert_eq!(id, "x1");
        assert_eq!(result["verdict"], "Pass", "{result}");
        assert_eq!(
            result["counts"],
            json!({"ran": 2, "passed": 2, "failed": 0, "skipped": 1, "crashed": 0})
        );
        assert_eq!(q.row("x1"), None, "the job left the queue");
        assert!(q.tick(120).starts.is_empty());
    }

    // [D] pure (runtime.db in a folder): what placement learned comes back after a hub restart; with no history,
    // nothing is learned and placement is the static rule's
    #[tokio::test]
    async fn learned_placement_comes_back_after_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
        let queue = |db: Option<urdr::Handle>| {
            Queue::new(QueueCfg {
                hub_id: "h".into(),
                exec_root: dir.path().to_path_buf(),
                local: LocalRunner::new(super::super::local::Admission::Fixed(1), dir.path()),
                db,
            })
            .0
        };
        let fresh = queue(None);
        fresh.restore_kept(kept(&db).await);
        assert_eq!(fresh.lock().learned, Learned::default());
        assert!(fresh.lock().history.is_empty());
        let mut spec = blank_spec("x1");
        spec.command = vec!["make".into(), "check".into()];
        let ran = |verdict: &str, wall: f64, disturbed: bool| json!({"verdict": verdict, "wall_s": wall, "cpu_s": wall, "mem_peak_mib": 100, "disturbed": disturbed});
        let q = queue(Some(db.clone()));
        {
            let mut st = q.lock();
            q.record_run(&mut st, &spec, "desktop", &ran("Pass", 600.0, false), 10);
            q.record_run(&mut st, &spec, "laptop", &ran("Red", 900.0, false), 20);
            // a disturbed run and a timeout teach nothing
            q.record_run(&mut st, &spec, "laptop", &ran("Pass", 9000.0, true), 30);
            q.record_run(&mut st, &spec, "laptop", &ran("Timeout", 9000.0, false), 40);
        }
        q.flush().await;
        let live = q.lock().learned.clone();
        assert_eq!(live.ratio("laptop", "desktop"), Some(1.5));
        let again = queue(None);
        again.restore_kept(kept(&db).await);
        let st = again.lock();
        assert_eq!(st.learned, live);
        assert_eq!(st.history_of(&forseti::history_key(&spec)).len(), 2);
    }

    use super::super::transport::{Channel, Channels, LinkError, Login, Transport};

    fn idle() -> Channels {
        let c = || Channel::new(Box::new(tokio::io::sink()), Box::new(tokio::io::empty()));
        Channels {
            control: c(),
            bulk_in: c(),
            bulk_out: c(),
        }
    }

    const IMG: &str = "img@sha256:aa";

    /// A queue in memory (or on DB), whose one local slot a job holds when BUSY.
    fn test_queue(
        dir: &std::path::Path,
        db: Option<urdr::Handle>,
        busy: bool,
    ) -> (Arc<Queue>, mpsc::UnboundedReceiver<LinkEvent>) {
        let (q, rx) = Queue::new(QueueCfg {
            hub_id: "h".into(),
            exec_root: dir.to_path_buf(),
            local: LocalRunner::new(super::super::local::Admission::Fixed(1), dir),
            db,
        });
        if busy {
            q.adopt("xbusy", Priority::P1, 100);
        }
        (q, rx)
    }

    fn remote(name: &str, grace_s: u64) -> RemoteRunner {
        RemoteRunner {
            name: name.into(),
            trust: RunnerTrust::Mine,
            accept: Accept::All,
            grace_s,
            image: Some(IMG.into()),
        }
    }

    /// Runner NAME on a link that is fed by hand (what it is sent goes nowhere).
    fn add(q: &Arc<Queue>, name: &str, grace_s: u64) {
        q.add_runner(
            remote(name, grace_s),
            Session::start(name, idle(), q.route(), q.link_events()),
        );
    }

    fn frame(q: &Queue, runner: &str, f: Frame, now: u64) -> Vec<Outcome> {
        q.on_link(
            LinkEvent::Frame {
                runner: runner.into(),
                frame: f,
            },
            now,
        )
    }

    fn hello(q: &Queue, runner: &str, linger: bool, now: u64) {
        let f = Frame::HelloOk {
            version: PROTO_VERSION,
            bundle: String::new(),
            hub_id: "h".into(),
            runner_id: String::new(),
            boot_id: String::new(),
            linger,
            attempts: vec![],
            missing: vec![],
        };
        frame(q, runner, f, now);
    }

    fn ready(q: &Queue, runner: &str, free_mib: i64, slots: &[String], images: &[&str], now: u64) {
        let f = Frame::Ready {
            free_mib,
            free_cpu: 8.0,
            psi: Default::default(),
            running: vec![],
            slots: slots.to_vec(),
            images: images.iter().map(|i| i.to_string()).collect(),
        };
        frame(q, runner, f, now);
    }

    /// Job ID (its command `make ID`, so each job has its own history key) of priority OWN needing MEM_MIN MiB; any
    /// job may leave this machine.
    fn job(id: &str, own: Priority, mem_min: u64) -> Submit {
        let mut spec = blank_spec(id);
        spec.command = vec!["make".into(), id.into()];
        spec.mem_mib = Range {
            min: mem_min,
            max: mem_min.max(4096),
        };
        Submit {
            id: id.into(),
            session: Some("s1".into()),
            own,
            spec,
            place: Placement {
                send: SendMode::All,
                image: Some(IMG.into()),
                ..Placement::default()
            },
            pending: Value::Null,
            inputs: None,
        }
    }

    fn current(q: &Queue, id: &str) -> JobRef {
        let st = q.lock();
        let (attempt, a) = st.attempts.current(id).expect("an attempt");
        JobRef {
            job: id.into(),
            attempt,
            nonce: a.nonce,
        }
    }

    fn admitted(q: &Queue, runner: &str, r: &JobRef, reserve_mib: u64, now: u64) {
        let grant = forseti::Grant {
            cores: 1,
            mem_cap_mib: reserve_mib,
            reserve_mib,
        };
        frame(
            q,
            runner,
            Frame::Admit {
                r: r.clone(),
                grant,
            },
            now,
        );
    }

    fn started(q: &Queue, runner: &str, r: &JobRef, now: u64) {
        let f = Frame::Started {
            r: r.clone(),
            unit: "u".into(),
            at: now,
        };
        frame(q, runner, f, now);
    }

    fn lost(q: &Queue, runner: &str, now: u64) -> Vec<Outcome> {
        q.on_link(
            LinkEvent::Lost {
                runner: runner.into(),
                why: "test".into(),
            },
            now,
        )
    }

    // [D] pure (a link fed by hand, runtime.db in a folder): once its runner says `started`, the attempt is kept
    // `running` in runtime.db, not `offered`
    #[tokio::test]
    async fn a_started_attempt_is_kept_running_in_runtime_db() {
        let dir = tempfile::tempdir().unwrap();
        let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
        let (q, _rx) = test_queue(dir.path(), Some(db.clone()), true);
        add(&q, "r1", 600);
        hello(&q, "r1", true, 100);
        q.submit(job("x1", Priority::P3, 64), 100);
        q.tick(100);
        let r = current(&q, "x1");
        admitted(&q, "r1", &r, 64, 101);
        started(&q, "r1", &r, 102);
        q.flush().await;
        let state: String = db
            .read(|c| {
                Ok(c.query_row(
                    "select state from rq_attempt where job = 'x1' and attempt = 1",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap();
        assert_eq!(state, "running");
    }

    // [D] pure (a link fed by hand): a `hello` without linger says the runner's jobs end with its link, so a lost link
    // requeues its attempt at once; a later `hello` with linger gives the registry's grace back, and the next lost
    // link only detaches the attempt
    #[tokio::test]
    async fn a_hello_without_linger_ends_its_attempts_with_the_link() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        add(&q, "r1", 600);
        hello(&q, "r1", false, 100);
        q.submit(job("x1", Priority::P3, 64), 100);
        q.tick(100);
        let r = current(&q, "x1");
        started(&q, "r1", &r, 101);
        lost(&q, "r1", 110);
        let row = q.row("x1").unwrap();
        assert_eq!(row.machine, None, "{row:?}");
        assert_eq!(
            row.waiting.as_deref(),
            Some("requeued (infra: runner lost)")
        );
        assert!(q.set_session(
            "r1",
            Session::start("r1", idle(), q.route(), q.link_events())
        ));
        hello(&q, "r1", true, 120);
        q.tick(120);
        let r = current(&q, "x1");
        assert_eq!(r.attempt, 2);
        started(&q, "r1", &r, 121);
        lost(&q, "r1", 130);
        let row = q.row("x1").unwrap();
        assert_eq!(
            (row.machine.as_deref(), row.attempt),
            (Some("r1"), Some(2)),
            "{row:?}"
        );
        let st = q.lock();
        let a = st.attempts.attempt("x1", 2).unwrap();
        assert!(
            matches!(a.state, attempts::AttemptState::Detached { .. }),
            "{a:?}"
        );
    }

    // [D] pure: a runner's job gets the hosts its network grant reaches in its `start`, for its proxy there
    #[tokio::test]
    async fn a_runner_job_gets_its_grants_hosts() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        add(&q, "r1", 600);
        hello(&q, "r1", true, 100);
        let mut s = job("x1", Priority::P3, 64);
        s.place.net_hosts = vec!["crates.io:443".into()];
        q.submit(s, 100);
        q.tick(100);
        let r = current(&q, "x1");
        let st = q.lock();
        let Frame::Start { net_hosts, .. } = Queue::start_frame(&st, "r1", &r) else {
            panic!("not a start");
        };
        assert_eq!(net_hosts, vec!["crates.io:443".to_string()]);
    }

    /// A transport whose every dial fails with its error.
    struct Refusing(LinkError);

    impl Transport for Refusing {
        fn open<'a>(
            &'a self,
            _: &'a super::super::RunnerCfg,
        ) -> mimir::BoxFuture<'a, Result<Channels, LinkError>> {
            Box::pin(async move { Err(self.0.clone()) })
        }
        fn round_trip<'a>(
            &'a self,
            _: &'a str,
        ) -> mimir::BoxFuture<'a, Result<Duration, LinkError>> {
            Box::pin(async move { Err(LinkError::Lost) })
        }
        fn replace_master<'a>(&'a self, _: &'a str) -> mimir::BoxFuture<'a, Result<(), LinkError>> {
            Box::pin(async move { Err(LinkError::Lost) })
        }
        fn stop<'a>(&'a self, _: &'a str) -> mimir::BoxFuture<'a, ()> {
            Box::pin(async {})
        }
    }

    // [D] pure (a transport that refuses): a dial refused for a changed host key, or for a login the user must do,
    // puts the runner in `needs a login` with the command its card shows, and placement passes it by; a lost link on
    // its own does not; the runner's next `hello` puts it back
    #[tokio::test]
    async fn a_changed_host_key_puts_the_runner_in_needs_login() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        add(&q, "r1", 600);
        hello(&q, "r1", true, 100);
        let cfg = super::super::RunnerCfg {
            name: "r1".into(),
            host: "r1.example".into(),
            linger: true,
            cloud: None,
            remote: super::super::Remote {
                control: vec!["serve".into()],
                bulk_in: vec!["cat".into()],
                bulk_out: vec!["cat".into()],
            },
        };
        for e in [
            LinkError::HostKeyChanged,
            LinkError::NeedsLogin(Login::Passphrase),
        ] {
            hello(&q, "r1", true, 100);
            assert_eq!(
                q.dial(&Refusing(e.clone()), &cfg, remote("r1", 600)).await,
                Err(e.clone())
            );
            assert_eq!(
                q.runner("r1").unwrap().state,
                "needs a login: ssh r1.example true",
                "{e}"
            );
        }
        q.submit(job("x1", Priority::P3, 64), 100);
        q.tick(100);
        assert_eq!(q.row("x1").unwrap().machine, None);
        hello(&q, "r1", true, 110);
        assert_eq!(q.runner("r1").unwrap().state, "ready");
        assert_eq!(
            q.dial(&Refusing(LinkError::Lost), &cfg, remote("r1", 600))
                .await,
            Err(LinkError::Lost)
        );
        assert_eq!(q.runner("r1").unwrap().state, "ready");
    }

    // [D] pure (links fed by hand): the head (priority 1, 3,500 MiB) fits no machine now (r1 has 1,000 MiB free), so
    // it reserves r1 from when r1's running job is expected to end (+300 s). A priority-4 job expected to take 10
    // minutes would still run then, and waits for the head; one whose runs took 100 s ends first and backfills r1
    #[tokio::test]
    async fn the_head_reserves_a_runner_and_a_short_job_backfills_it() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        add(&q, "r1", 600);
        hello(&q, "r1", true, 100);
        ready(&q, "r1", 8000, &[], &[], 100);
        q.submit(job("xa", Priority::P4, 3000), 100);
        q.tick(100);
        let a = current(&q, "xa");
        admitted(&q, "r1", &a, 3000, 100);
        started(&q, "r1", &a, 100);
        ready(&q, "r1", 1000, &[], &[], 400);
        let short = job("xs2", Priority::P4, 512);
        {
            let mut st = q.lock();
            let ran = json!({"verdict": "Pass", "wall_s": 100.0});
            q.record_run(&mut st, &short.spec, "r1", &ran, 50);
        }
        q.submit(job("xh", Priority::P1, 3500), 400);
        q.submit(job("xs", Priority::P4, 512), 400);
        q.submit(short, 400);
        q.tick(400);
        let row = |id: &str| q.row(id).unwrap();
        assert_eq!(row("xh").machine, None, "{:?}", row("xh"));
        assert_eq!(row("xs").machine, None, "{:?}", row("xs"));
        assert_eq!(
            row("xs").waiting.as_deref(),
            Some("room is kept for job xh")
        );
        assert_eq!(row("xs2").machine.as_deref(), Some("r1"));
    }

    fn frozen(key: &str, size: u64) -> Frozen {
        Frozen {
            worktree: PathBuf::from("/src/p"),
            repo: "p".into(),
            commit: "c".repeat(40),
            tree: "t".repeat(40),
            manifest: vec![ManifestEntry::File {
                path: b"big".to_vec(),
                mode: 0o100644,
                sha256: Sha256([7; 32]),
                size,
            }],
            extras: vec![],
            input_key: key.into(),
            blobs: PathBuf::from("/nonexistent"),
            origin_url: None,
            not_on_origin: 0,
            visibility: sync::Visibility::Private,
            shared_overlay: false,
        }
    }

    fn sync_done(q: &Queue, runner: &str, r: &JobRef, now: u64) {
        let f = Frame::SyncNeed {
            r: r.clone(),
            blobs: vec![],
            commit: false,
            refs: vec![],
        };
        frame(q, runner, f, now);
    }

    // [D] pure (links fed by hand): a bundle's answer times the link (10 MiB in 10 s: 1 MiB/s to r1), and a job's
    // inputs r1 lacks (600 MiB at that rate) count in r1's estimate, so the job goes to r2, which synced them before
    #[tokio::test]
    async fn a_timed_bundle_teaches_the_link_and_placement_counts_the_transfer() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        for r in ["r1", "r2"] {
            add(&q, r, 600);
            hello(&q, r, true, 100);
            ready(&q, r, 8000, &[], &[], 100);
        }
        let mut j0 = job("x0", Priority::P3, 64);
        j0.place.machine = Machine::Runner("r2".into());
        j0.inputs = Some(frozen("K", 600 << 20));
        q.submit(j0, 100);
        q.tick(100);
        let r0 = current(&q, "x0");
        admitted(&q, "r2", &r0, 64, 100);
        sync_done(&q, "r2", &r0, 101);
        let mut j1 = job("x1", Priority::P3, 64);
        j1.place.machine = Machine::Runner("r1".into());
        j1.inputs = Some(frozen("K1", 0));
        q.submit(j1, 102);
        q.tick(102);
        let r1 = current(&q, "x1");
        admitted(&q, "r1", &r1, 64, 102);
        {
            let mut st = q.lock();
            let s = st.syncs.get_mut(&("x1".to_string(), 1)).expect("x1 syncs");
            s.bundle = Some(sync::BundleFile {
                path: dir.path().join("x1.bundle"),
                sha256: [0; 32],
                size: 10 << 20,
            });
            s.sent_at = 110;
        }
        sync_done(&q, "r1", &r1, 120);
        assert_eq!(
            q.lock().learned.link("r1"),
            Some((10u64 << 20) as f64 / 10.0)
        );
        let mut j2 = job("x2", Priority::P3, 64);
        j2.inputs = Some(frozen("K", 600 << 20));
        q.submit(j2, 130);
        q.tick(130);
        assert_eq!(q.row("x2").unwrap().machine.as_deref(), Some("r2"));
    }

    // [D] pure (links fed by hand): r2's `ready` lists the job's slot and image, r1's nothing; otherwise equal, the
    // warm start wins (by name alone it would be r1)
    #[tokio::test]
    async fn a_runner_with_the_jobs_slot_and_image_wins_a_tie() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, true);
        let j = job("x1", Priority::P3, 64);
        let slot = sleipnir::sync::slot::SlotKey::of(&j.spec).id();
        for r in ["r1", "r2"] {
            add(&q, r, 600);
            hello(&q, r, true, 100);
        }
        ready(&q, "r1", 8000, &[], &[], 100);
        ready(&q, "r2", 8000, &[slot], &[IMG], 100);
        q.submit(j, 100);
        q.tick(100);
        assert_eq!(q.row("x1").unwrap().machine.as_deref(), Some("r2"));
    }

    // [D] pure: a job that ran here is history placement learns from, as this machine's run
    #[tokio::test]
    async fn a_run_here_is_this_machines_history() {
        let dir = tempfile::tempdir().unwrap();
        let (q, _rx) = test_queue(dir.path(), None, false);
        let j = job("x1", Priority::P3, 64);
        let key = forseti::history_key(&j.spec);
        q.submit(j, 100);
        assert_eq!(q.tick(100).starts, vec!["x1".to_string()]);
        q.ran_here("x1", &json!({"verdict": "Pass", "wall_s": 42.0}), 150);
        let st = q.lock();
        let rows = st.history_of(&key);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!((rows[0].machine.as_str(), rows[0].wall_s), (LOCAL, 42.0));
    }

    // [D] pure: the design's table, row by row
    #[test]
    fn priority_of_is_the_designs_table() {
        let user = Starter::User;
        let agent = Starter::Session("s1".into());
        // a job the user starts (the UI, `drgnx job …`)
        assert_eq!(priority_of(&user, false, Origin::Request), Priority::P1);
        // the splitter's fail-fast probes and reruns of fresh reds
        assert_eq!(priority_of(&agent, false, Origin::Splitter), Priority::P2);
        // an agent's `job_start`
        assert_eq!(priority_of(&agent, false, Origin::Request), Priority::P3);
        // a plan run's or the merge gate's bulk
        assert_eq!(priority_of(&agent, false, Origin::Bulk), Priority::P4);
        // `background`, image builds, cache warm-ups
        assert_eq!(priority_of(&agent, true, Origin::Request), Priority::P5);
        assert_eq!(priority_of(&user, true, Origin::Request), Priority::P5);
        assert_eq!(priority_of(&user, false, Origin::Upkeep), Priority::P5);
        // background only lowers: never above what the rest of the table gives
        for from in [
            Origin::Request,
            Origin::Splitter,
            Origin::Bulk,
            Origin::Upkeep,
        ] {
            for s in [&user, &agent] {
                assert!(priority_of(s, true, from) <= priority_of(s, false, from));
            }
        }
    }
}
