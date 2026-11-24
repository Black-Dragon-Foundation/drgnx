//! Plan runs in the hub (`job/*` with `drgnx-job-summary` shapes; V2 runtime phase 6; `docs/develop/coordination.md`,
//! "Plan runs"): propose, approve, the 2 s tick (no git on it), start a task (Task 16a); review hand-off, fallback,
//! budget pause, cards (Task 16b).  The Lisp runner is the oracle for each rule.
//!
//! - [`plan`]: a plan file read as a job.
//! - [`tick`]: the 2 s step and starting a task's worker.
//! - [`git`]: [`RunGit`] for the hub: worktree and snapshot modes, the merge gate, trial merges (Task 17).
//! - [`clash`]: the five clash rules (Task 18).
//! - [`effects`]: `plans/*`, `reports/get`, `decisions/effects` (Task 21).
//!
//! A job is a row of work.db's `job` table (its tasks `jtask` rows, the `blocks` links between them) and a JSON
//! `data` object the runner keeps: `plan`, `hash`, `repo`, `title`, `tasks` (the plan's text per task), `routes`,
//! `estimate`, `budget`, `gate`, and by task id `blocked` (a reason), `profiles` (a reassignment), `bases` (where the
//! task's tree started), `exits` (agents that ended without finishing it), `notes` (what a reviewer asked for) and
//! the run `order` (task ids).  The summary the cockpit and `bin/drgnx job` read is built from the rows, the open
//! cards and the hub's sessions of the job; nothing of it lives in memory but "a worktree is being made".

pub mod clash;
pub mod effects;
pub mod fallback;
pub mod git;
pub mod huddle;
pub mod plan;
pub mod predict;
pub mod review;
pub mod tick;

use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::Gate;
use norn::read::cards::{self as read_cards, Card};
use norn::read::decisions::{self as read_decisions, Decision};
use norn::read::jobs::{self as read_jobs, Job};
use norn::read::messages::{self as read_messages, Message};
use norn::read::spend::spend_sum;
use norn::read::tasks::{self as read_tasks, Task};
use norn::write::cards::{self as write_cards, CardSet, NewCard};
use norn::write::decisions::{self as write_decisions, Decide};
use norn::write::jobs::{self as write_jobs, NewJob, NewTask};
use norn::write::messages::{self as write_messages, Send, SendResult};
use norn::write::tasks as write_tasks;
use runstav::methods::agents::ById;
use runstav::methods::forecast::Forecast;
use runstav::methods::jobs::{
    BlockParams, ByMessage, ByTask, CardParams, JobStatusResult, JobSummary, MergeGate,
    OrderParams, PlanRef, ProposeParams, ReassignParams, ReplyParams, StartTaskParams,
    StatusParams, TaskNo, WithLimits,
};
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::BudgetScope;
use runstav::registry::Class;
use runstav::types::{Bounded, Id};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tokio::sync::Notify;

/// Agents of one job working at once (`drgnx-job-max-agents`).
pub const MAX_AGENTS: usize = 3;
/// How many agents of one job work at once: the tick starts up to this many, and a forecast schedules on this many
/// slots, so the two cannot disagree.
pub(crate) fn agent_slots(_front: &Front) -> usize {
    MAX_AGENTS
}
/// Agents that may end without finishing a task before the user decides (`drgnx-job-start-tries`).
pub const START_TRIES: i64 = 3;
/// The most characters of a blocked task's reason that are kept.
pub const BLOCK_REASON_MAX: usize = 500;
/// The price the user configured for PROFILE's gateway provider (`drgnx-ai-providers` `:price`); none for a profile
/// without a gateway or a provider without a price (a subscription profile stays unpriced).
pub(crate) fn profile_price(front: &Front, profile: &str) -> Option<(f64, f64)> {
    let p = crate::agents::session::find_profile(front, profile)?;
    p.ai.as_ref()?;
    let (provider, _) = crate::agents::session::gateway_chain(front, &p)
        .into_iter()
        .next()?;
    let cur = front.settings.current();
    cur.loaded
        .providers
        .iter()
        .find(|c| c.id.as_str() == provider)
        .and_then(|c| c.price)
        .map(|p| (p.input.get(), p.output.get()))
}

// ---- the forecast on a proposal ------------------------------------------------------------------------------------

/// 40000000 as `40M`, 1200 as `1k`.
fn tokens_text(n: f64) -> String {
    if n >= 1e6 {
        format!("{:.0}M", n / 1e6)
    } else if n >= 1e3 {
        format!("{:.0}k", n / 1e3)
    } else {
        format!("{n:.0}")
    }
}

/// US dollars: whole from 10, else to the cent, and "<0.01" for what rounds to nothing (as the editor prints it).
fn money_text(x: f64) -> String {
    if x >= 10.0 {
        format!("{x:.0}")
    } else if x >= 0.005 {
        format!("{x:.2}")
    } else {
        "<0.01".to_owned()
    }
}

/// 7800 s as `2 h 10`, 14400 as `4 h`, 600 as `10 min`.
fn duration_text(secs: f64) -> String {
    let m = (secs / 60.0).round() as u64;
    match (m / 60, m % 60) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m}"),
    }
}

/// A..B in TEXT's words; one value when both read alike.
fn range_text(r: &runstav::methods::forecast::Range, text: fn(f64) -> String) -> String {
    let (a, b) = (text(r.p50), text(r.p90));
    if a == b { a } else { format!("{a}–{b}") }
}

/// The proposal card's title: the tasks, the cost range (an estimate when it is one), the tokens and the time, or
/// the word `unpriced` where there is no price.  Never `0.00`: a cost of nothing is left off, as the editor leaves it.
pub(crate) fn card_title(n: usize, f: &Forecast) -> String {
    let mut parts = vec![format!("{n} task{}", if n == 1 { "" } else { "s" })];
    let costs: Vec<_> = f.cost.iter().filter(|c| c.p90 > 0.0).collect();
    if !costs.is_empty() {
        let mut notes: Vec<&str> = Vec::new();
        if costs.iter().any(|c| c.estimate) {
            notes.push("estimate");
        }
        if !f.unpriced.is_empty() {
            notes.push("some unpriced");
        }
        let amounts: Vec<String> = costs
            .iter()
            .map(|c| {
                range_text(
                    &runstav::methods::forecast::Range {
                        p50: c.p50,
                        p90: c.p90,
                    },
                    money_text,
                )
            })
            .collect();
        parts.push(format!(
            "about {} USD{}",
            amounts.join(" + "),
            if notes.is_empty() {
                String::new()
            } else {
                format!(" ({})", notes.join(", "))
            }
        ));
    }
    parts.push(format!("{} tokens", range_text(&f.tokens, tokens_text)));
    parts.push(range_text(&f.wall_secs, duration_text));
    if costs.is_empty() && !f.unpriced.is_empty() {
        parts.push("unpriced".to_owned());
    }
    format!("{}: approve to start", parts.join(", "))
}

/// A proposal's `estimate`: `usd` (the middle of the priced units), `unit`, `tokens` (the middle) and `unpriced` keep
/// their keys and types; `forecast` holds the ranges.  With no forecast the tokens are the prior's, and `forecast`
/// is null.
pub(crate) fn estimate_of(f: Option<&Forecast>, tasks: usize) -> Value {
    let Some(f) = f else {
        let per_task = norn::forecast::model::prior()
            .get(2)
            .map_or(0, |o| o.usage.total());
        return json!({"usd": 0.0, "unit": "usd-est", "tokens": per_task * tasks as u64,
                      "unpriced": [], "forecast": null});
    };
    let mut basis: Vec<&str> = Vec::new();
    for t in &f.tasks {
        if !basis.contains(&t.basis.label.as_str()) {
            basis.push(&t.basis.label);
        }
    }
    json!({
        "usd": f.cost.iter().map(|c| c.p50).sum::<f64>(),
        "unit": if f.cost.iter().all(|c| !c.estimate) && !f.cost.is_empty() { "usd" } else { "usd-est" },
        "tokens": f.tokens.p50.round() as u64,
        "unpriced": f.unpriced,
        "forecast": {
            "tokens": f.tokens, "active_secs": f.active_secs, "wall_secs": f.wall_secs, "cost": f.cost,
            "basis": basis, "wake": f.wake, "manager": f.manager, "prices_as_of": f.prices_as_of,
            "made_at": f.made_at,
        },
    })
}

/// A warning when the plan's p90 in dollars, `usd` and `usd-est` summed as the budget binds them, is over BUDGET.
/// The user decides; nothing is refused.
pub(crate) fn budget_warnings(f: &Forecast, budget: Option<f64>) -> Vec<String> {
    let Some(budget) = budget else {
        return Vec::new();
    };
    let dollars: Vec<_> = f
        .cost
        .iter()
        .filter(|c| matches!(c.unit, Unit::Usd | Unit::UsdEst))
        .collect();
    let p90: f64 = dollars.iter().map(|c| c.p90).sum();
    if dollars.is_empty() || p90 <= budget {
        return Vec::new();
    }
    vec![format!(
        "the plan's p90 cost, {} USD{}, is over the budget of {} USD",
        money_text(p90),
        if dollars.iter().any(|c| c.estimate) {
            " (estimate)"
        } else {
            ""
        },
        money_text(budget)
    )]
}

/// The `usd` limit among LIMITS: the dollars the gateway's per-job cap and the warnings read.
pub(crate) fn usd_of(limits: &[Limit]) -> Option<f64> {
    limits
        .iter()
        .find(|l| l.unit == Unit::Usd)
        .map(|l| l.amount)
}

/// The limits to set on a plan from LIMITS as the user gave them, and whether the dollars bind jointly: a `usd` limit
/// on a plan with a subscription profile also limits `usd-est` by the same amount (a subscription's spend lands
/// there, and a `usd` limit alone would never fire), and the two bind together
/// ([`crate::budget::Budgets::set_joint`]), so the plan's dollars are capped once.  Every other unit is as given.
pub(crate) fn joint_limits(mut limits: Vec<Limit>, subscription: bool) -> (Vec<Limit>, bool) {
    let joint = subscription && usd_of(&limits).is_some();
    if joint && !limits.iter().any(|l| l.unit == Unit::UsdEst) {
        let amount = usd_of(&limits).unwrap_or(0.0);
        limits.push(Limit {
            amount,
            unit: Unit::UsdEst,
        });
    }
    (limits, joint)
}

/// Whether any profile JOB may run a task on (a route, its fallbacks, a reassignment) is a subscription's.
pub(crate) fn has_subscription_profile(front: &Front, job: &Job) -> bool {
    let data = data_of(job);
    let mut names: Vec<String> = Vec::new();
    for key in ["routes", "profiles"] {
        if let Some(m) = data.get(key).and_then(Value::as_object) {
            names.extend(m.values().filter_map(Value::as_str).map(str::to_owned));
            if key == "routes" {
                for role in m.keys() {
                    names.extend(route(front, role));
                }
            }
        }
    }
    names
        .iter()
        .any(|n| crate::agents::session::find_profile(front, n).is_some_and(|p| p.ai.is_none()))
}

/// The job, its tasks and what was forecast for them, in one write: no approval can see one without the other.
pub(crate) fn create_with_forecast(
    tx: &mut norn::store::WTx<'_>,
    job: NewJob,
    made: &[norn::forecast::sample::Made],
    at: f64,
) -> Result<String, norn::store::CoordError> {
    let id = write_jobs::job_create(tx, job, at)?;
    norn::forecast::sample::record_made(tx, made)?;
    Ok(id)
}

/// What Task 16b adds to the tick: reviews, the merge gate, fallback, the budget pause.  Set once by the server
/// ([`Runs::set_hooks`]); the runner calls it and knows nothing of what it does.
pub trait Hooks: std::marker::Send + Sync {
    /// After the step of running job JOB (the Lisp's `drgnx-job-tick-functions`).
    fn tick<'a>(&'a self, front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a>;
    /// JOB was stopped.
    fn stopped<'a>(&'a self, front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a>;
    /// CLASHES were just carded in JOB: their reviewers start (Task 18's `ReviewerHook`).
    fn carded<'a>(
        &'a self,
        _front: &'a Arc<Front>,
        _job: &'a str,
        _clashes: Vec<clash::Clash>,
    ) -> HookFuture<'a> {
        Box::pin(async {})
    }
}

/// What a [`Hooks`] call answers.
pub type HookFuture<'a> = Pin<Box<dyn Future<Output = ()> + std::marker::Send + 'a>>;

/// Session id → (its plan's entity id, its project's entity id); shared with the step writers.
#[derive(Clone, Default)]
pub struct Scopes(Arc<Mutex<HashMap<String, Scope>>>);

/// A plan's entity id and its project's.
type Scope = (String, Option<String>);

impl Scopes {
    pub fn get(&self, sid: &str) -> Option<Scope> {
        lock(&self.0).get(sid).cloned()
    }
}

/// The plan runs the hub holds: the git behind them, the hooks of 16b, the worktrees being made and what each job
/// last showed its subscribers.
#[derive(Default)]
pub struct Runs {
    git: OnceLock<Arc<dyn RunGit>>,
    hooks: OnceLock<Arc<dyn Hooks>>,
    /// Task id → what is being done to it (`starting`, `merging`): shown as its status.
    busy: Mutex<HashMap<String, &'static str>>,
    /// Job id → the signature of what its last `job` event showed.
    seen: Mutex<HashMap<String, String>>,
    /// Session id → (its plan's entity id, its project's entity id): what the step writer files the session's steps
    /// under (`step.plan`, `step.project`).
    scopes: Scopes,
    wake: Notify,
    /// A busy mark was cleared ([`Runs::settled`]).
    idle: Notify,
    /// The hub is resuming the sessions it held (Task 24): a task whose agent is not back yet is not a dead one, so
    /// the tick waits.
    recovering: std::sync::atomic::AtomicBool,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    saman::lock(m)
}

impl Runs {
    /// The sessions of a hub before this one are being resumed (ON) or are back: the runs go on from the store, with
    /// the same workers, once they are.
    pub fn set_recovering(&self, on: bool) {
        self.recovering
            .store(on, std::sync::atomic::Ordering::SeqCst);
        if !on {
            self.wake.notify_one();
        }
    }

    pub fn recovering(&self) -> bool {
        self.recovering.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// The git of the runner (Task 17 gives `HubGit`); until then [`tick::BasicGit`] makes worktrees only.
    pub fn set_git(&self, git: Arc<dyn RunGit>) {
        crate::soft::done(self.git.set(git), "mod");
    }

    pub fn set_hooks(&self, hooks: Arc<dyn Hooks>) {
        crate::soft::done(self.hooks.set(hooks), "mod");
    }

    pub fn git(&self) -> Arc<dyn RunGit> {
        self.git
            .get()
            .cloned()
            .unwrap_or_else(|| Arc::new(tick::BasicGit))
    }

    pub fn hooks(&self) -> Option<Arc<dyn Hooks>> {
        self.hooks.get().cloned()
    }

    /// Step the running jobs now, not at the next tick.
    pub fn wake(&self) {
        self.wake.notify_one();
    }

    pub(crate) async fn woken(&self) {
        self.wake.notified().await;
    }

    /// Session SID works for PLAN (an entity id) in PROJECT: the step writer reads it ([`Runs::scope_of`]).
    pub fn set_scope(&self, sid: &str, plan: String, project: Option<String>) {
        lock(&self.scopes.0).insert(sid.to_owned(), (plan, project));
    }

    /// The (plan, project) entity ids a plan run's session works under: what `step.plan` and `step.project` hold.
    /// The step writer reads it per step (through [`Runs::scopes`]): the scope is set just after the session starts,
    /// so a `StepCtx` made at the start cannot hold it.
    pub fn scope_of(&self, sid: &str) -> Option<(String, Option<String>)> {
        self.scopes.get(sid)
    }

    /// The shared scope table, for the step writers.
    pub fn scopes(&self) -> Scopes {
        self.scopes.clone()
    }

    /// The task session SID ended (its task done, dropped, or its agent failed): the checkpoint cap may prune its
    /// snapshots first.
    pub fn session_finished(&self, front: &Front, sid: &str) {
        front.core.timeline.session_finished(sid);
    }

    pub fn busy_of(&self, task: &str) -> Option<&'static str> {
        lock(&self.busy).get(task).copied()
    }

    pub fn set_busy(&self, task: &str, what: Option<&'static str>) {
        let mut b = lock(&self.busy);
        match what {
            Some(w) => {
                b.insert(task.to_owned(), w);
            }
            None => {
                b.remove(task);
                drop(b);
                self.idle.notify_waiters();
            }
        }
    }

    /// Once no task of JOB is busy: its work in flight (a start writing its tree, a merge) has ended, each clearing
    /// its own mark.
    pub async fn settled(&self, job: &str) {
        let prefix = format!("{job}#");
        loop {
            let woke = self.idle.notified();
            tokio::pin!(woke);
            woke.as_mut().enable();
            if !lock(&self.busy).keys().any(|k| k.starts_with(&prefix)) {
                return;
            }
            woke.await;
        }
    }

    fn busy_all(&self) -> HashMap<String, &'static str> {
        lock(&self.busy).clone()
    }
}

/// A task's busy mark ([`Runs::set_busy`]) held by the work it marks: cleared when dropped, so a start or merge
/// that returns early or panics never leaves `job/stop` waiting on it.
pub struct BusyMark {
    front: Arc<Front>,
    task: String,
}

impl BusyMark {
    pub fn set(front: &Arc<Front>, task: &str, what: &'static str) -> BusyMark {
        front.core.runs.set_busy(task, Some(what));
        BusyMark {
            front: front.clone(),
            task: task.to_owned(),
        }
    }
}

impl Drop for BusyMark {
    fn drop(&mut self) {
        self.front.core.runs.set_busy(&self.task, None);
    }
}

/// What a [`RunGit`] call answers.
pub type GitFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, GitError>> + std::marker::Send + 'a>>;

/// A git step that failed (or ran past its deadline): what was run and what it said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitError {
    pub what: String,
    pub stderr: String,
}

/// How a task's tree is kept: a worktree of the trusted repository, or a snapshot (a bare store per run, a reflink
/// copy per task, its bundle verified with fsck; V2 runtime §5.10).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeMode {
    Worktree,
    Snapshot,
}

/// A task's tree, made for its worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskTree {
    pub path: PathBuf,
    pub branch: String,
    /// The commit it starts from.
    pub base: String,
    pub mode: TreeMode,
}

/// A trial merge's outcome, in a scratch worktree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrialResult {
    pub clean: bool,
    pub conflicts: Vec<PathBuf>,
}

/// The runner's git, behind a trait so Task 16a runs on a fake while Task 17 writes `HubGit` ([`git`]).  Every call
/// is async with a deadline; none runs on the tick.
pub trait RunGit: std::marker::Send + Sync {
    /// The tree for TASK of RUN, branched from BASE in REPO.
    fn task_worktree<'a>(
        &'a self,
        repo: &'a Path,
        run: &'a str,
        task: &'a str,
        base: &'a str,
    ) -> GitFuture<'a, TaskTree>;
    /// TASK's merge gate: the changed set from `git diff --raw` in the trusted repository, every path checked against
    /// the current diff hash; CI and build files and the protected paths ask (`code.ci-config`); `Allow` merges
    /// exactly the tip checked (`merge --no-ff`).
    fn merge_gate<'a>(&'a self, repo: &'a Path, tree: &'a TaskTree) -> GitFuture<'a, Gate>;
    /// BRANCHES merged in order into a scratch worktree of REPO.
    fn trial_merge<'a>(
        &'a self,
        repo: &'a Path,
        branches: &'a [String],
    ) -> GitFuture<'a, TrialResult>;
    /// The changed paths of TREE's task, the hash of each diff and the lines it touches (the clash rules' input;
    /// none for a git that cannot tell).
    fn diffs<'a>(
        &'a self,
        _repo: &'a Path,
        _tree: &'a TaskTree,
    ) -> GitFuture<'a, std::collections::BTreeMap<String, clash::FileDiff>> {
        Box::pin(async { Ok(Default::default()) })
    }
    /// TREE's work is done: a snapshot task's bundle is written to `<task folder>.bundle` for the gate to import.
    fn prepare<'a>(&'a self, _tree: &'a TaskTree) -> GitFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    /// How this git keeps its trees (a fake git has worktrees).
    fn mode(&self) -> TreeMode {
        TreeMode::Worktree
    }
    /// TREE's branch is made known to the trusted REPO (a snapshot task: its bundle is written and imported, fsck'd,
    /// the branch written compare-and-swap), so branch names alone can be merged (`trial_merge`).  A worktree's
    /// branch is there already.
    fn import<'a>(&'a self, _repo: &'a Path, _tree: &'a TaskTree) -> GitFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    /// The base of the tree at PATH when its `TaskTree` is made again (after a restart): the merge-base of its
    /// BRANCH and REPO's UPSTREAM branch as REPO has it now.  A worktree shares REPO's refs; a snapshot's run store
    /// is fetched from REPO first (AS1-SNAP-STALE-1).
    fn rebuilt_base<'a>(
        &'a self,
        _repo: &'a Path,
        path: &'a Path,
        branch: &'a str,
        upstream: &'a str,
    ) -> GitFuture<'a, String> {
        Box::pin(async move { tick::git(path, &["merge-base", branch, upstream]).await })
    }
    /// The gate's card for BRANCH was answered yes: its checked tip may merge.
    fn clear_gate(&self, _branch: &str) {}
    /// The tip the gate checked and cleared for BRANCH: the commit the hub's gates judge (none: they read the branch).
    fn checked_tip(&self, _branch: &str) -> Option<String> {
        None
    }
    /// Merge exactly the tip the gate checked into the job's tree (`merge --no-ff`), with MESSAGE as its commit message
    /// (none: `Merge BRANCH`); with JUDGED, only when the checked tip is that commit.
    fn merge_into<'a>(
        &'a self,
        _job_tree: &'a Path,
        _tree: &'a TaskTree,
        _message: Option<&'a str>,
        _judged: Option<&'a str>,
    ) -> GitFuture<'a, git::MergeOutcome> {
        Box::pin(async {
            Err(GitError {
                what: "merge".into(),
                stderr: "this git cannot merge".into(),
            })
        })
    }
    /// A sandboxed session started in FOLDER: plain git never runs there again (the touched-folder ledger).
    fn touched<'a>(&'a self, _folder: &'a Path) -> GitFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    /// Whether a sandboxed agent worked in FOLDER (plain git never runs there).
    fn is_touched<'a>(&'a self, _folder: &'a Path) -> GitFuture<'a, bool> {
        Box::pin(async { Ok(false) })
    }
}

// ---- small helpers ------------------------------------------------------------------------------------------

pub(crate) fn now() -> f64 {
    crate::clock::wall_secs()
}

pub(crate) fn invalid(message: impl ToString) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.to_string(),
        path: None,
    }
}

pub(crate) fn internal(message: impl ToString) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.to_string(),
        path: None,
    }
}

/// The hub itself as a caller: the tick's writes (actor `hub`, class `system`).
pub(crate) fn service() -> Caller {
    Caller {
        class: Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// The user as a caller: starting a worker is the user's act, approved with the job.
pub(crate) fn user() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// The job's data key `job/stop` sets on a proposal (a rejected one): it never started, `job/resume` refuses it.
pub(crate) const NEVER_APPROVED: &str = "never_approved";

/// The plan JOB's steps are filed under (`step.plan`): a graph plan's id already carries `plan:`, a plan file's path
/// does not (its parsed entity's id is `plan:PATH`), and a job with no plan has its own.
pub(crate) fn plan_id(job: &Job) -> String {
    match job.plan.as_deref() {
        Some(p) if p.starts_with("plan:") => p.to_string(),
        Some(p) => format!("plan:{p}"),
        None => format!("plan:{}", job.id),
    }
}

/// JOB's own budget scope: one run of its plan.
pub(crate) fn run_scope(job: &Job) -> BudgetScope {
    BudgetScope::Run(Id::new(&job.id).expect("a job id is an id"))
}

/// The budget scope of JOB's plan (the plan document, across its runs); none for a job with no plan.
pub(crate) fn plan_scope(job: &Job) -> Option<BudgetScope> {
    job.plan
        .is_some()
        .then(|| BudgetScope::Plan(Bounded(plan_id(job))))
}

/// The budget chain above JOB's sessions, from its run up: run, plan, the spec the plan derives from (its `derives`
/// link in the store), PROJECT.  A plan with no spec sits under the project; a job with no plan has its run alone
/// under it.
pub(crate) async fn budget_chain(
    front: &Front,
    job: &Job,
    project: Option<String>,
) -> Vec<BudgetScope> {
    let mut chain = vec![run_scope(job)];
    if let Some(plan) = plan_scope(job) {
        let id = plan_id(job);
        let spec = front
            .writer
            .db
            .read(move |c| {
                c.query_row(
                    "select b.id from link l join entity a on a.n = l.src join entity b on b.n = l.dst \
                     where a.id = ?1 and l.kind = 'derives' and l.tx_to = ?2 \
                     and a.retired_tx is null and b.retired_tx is null order by b.id limit 1",
                    (id, urdr::graph::schema::SENTINEL),
                    |r| r.get::<_, String>(0),
                )
                .map(Some)
                .or_else(|e| match e {
                    urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                    e => Err(e.into()),
                })
            })
            .await;
        chain.push(plan);
        match spec {
            Ok(Some(s)) => chain.push(BudgetScope::Spec(Bounded(s))),
            Ok(None) => {}
            // the plan then sits under its project, and the log says why
            Err(e) => tracing::warn!(job = job.id, "the spec of the job's plan: {e:?}"),
        }
    }
    chain.extend(project.map(|p| BudgetScope::Project(Bounded(p))));
    chain
}

/// JOB's run is linked into the budget chain (at its approval and at a manager's start): its plan, spec and project,
/// the project read from the job's repository.
pub(crate) async fn link_run(front: &Front, job: &Job) {
    let project = match job.repo.as_deref() {
        Some(r) => match crate::graph::project_of(Path::new(r)).await {
            Ok(p) => p.map(|p| p.id),
            Err(e) => {
                tracing::warn!(job = job.id, "the run's budget scope: {e}");
                None
            }
        },
        None => None,
    };
    let chain = budget_chain(front, job, project).await;
    front.core.budgets.link_up(&chain);
}

fn data_of(job: &Job) -> Map<String, Value> {
    match &job.data {
        Some(Value::Object(m)) => m.clone(),
        _ => Map::new(),
    }
}

/// What the job's data KEY (an object by task id) says of TASK.
pub(crate) fn data_for<'a>(
    data: &'a Map<String, Value>,
    key: &str,
    task: &str,
) -> Option<&'a Value> {
    data.get(key)?.get(task)
}

/// Job ID's data after F changed it, in the transaction (a missing job is refused).
pub(crate) async fn update_data(
    front: &Front,
    caller: &Caller,
    id: &str,
    f: impl FnOnce(&mut Map<String, Value>) + std::marker::Send + 'static,
) -> Result<(), Error> {
    let id = id.to_owned();
    front
        .writer
        .write(caller, "job/data", move |tx| {
            let job = read_jobs::job(tx.sql(), &id)?
                .ok_or_else(|| norn::store::CoordError::Refused(format!("No job {id}")))?;
            let mut data = data_of(&job);
            f(&mut data);
            write_jobs::job_set(tx, &id, None, Some(&Value::Object(data)), now())
        })
        .await
        .map_err(fail)
}

/// Set KEY of the object under data[BUCKET] to VALUE (none removes it).
pub(crate) fn put_in(data: &mut Map<String, Value>, bucket: &str, key: &str, value: Option<Value>) {
    let entry = data
        .entry(bucket.to_owned())
        .or_insert_with(|| Value::Object(Map::new()));
    if !entry.is_object() {
        *entry = Value::Object(Map::new());
    }
    if let Value::Object(m) = entry {
        match value {
            Some(v) => {
                m.insert(key.to_owned(), v);
            }
            None => {
                m.remove(key);
            }
        }
    }
}

// ---- reading a job --------------------------------------------------------------------------------------------

/// Everything a summary shows, read in one go.
pub(crate) struct Loaded {
    pub job: Job,
    pub tasks: Vec<Task>,
    pub open_cards: Vec<Card>,
    pub messages: Vec<Message>,
    pub decisions: Vec<Decision>,
    pub spent: f64,
}

pub(crate) async fn load(
    front: &Front,
    id: &str,
    decisions: bool,
) -> Result<Option<Loaded>, Error> {
    let id = id.to_owned();
    front
        .writer
        .db
        .read(move |c| {
            let Some(job) = read_jobs::job(c, &id)? else {
                return Ok(None);
            };
            Ok(Some(Loaded {
                tasks: read_tasks::tasks(c, &id)?,
                open_cards: read_cards::cards(c, &id, Some("open"))?,
                messages: read_messages::inbox(c, "user", &[])?
                    .into_iter()
                    .filter(|m| {
                        m.job.as_deref() == Some(id.as_str())
                            && m.sender.as_deref() != Some("drgnx")
                    })
                    .collect(),
                decisions: if decisions {
                    read_decisions::decisions_since(c, 0, Some(&id))?
                } else {
                    Vec::new()
                },
                spent: spend_sum(c, Some(&id), None, None)?.cost,
                job,
            }))
        })
        .await
        .map_err(fail)
}

/// The profiles a role may use, in order (`drgnx-job-route`): the first runs it, the rest are its fallbacks.  `say`
/// (the planning session of Say it) with no route of its own is `implement`'s, so nothing new needs configuring.
pub(crate) fn route(front: &Front, role: &str) -> Vec<String> {
    let cur = front.settings.current();
    let found = cur
        .loaded
        .values
        .agents_routes
        .iter()
        .find(|r| r.role == role)
        .map(|r| r.profiles.clone())
        .filter(|p| !p.is_empty());
    match found {
        Some(p) => p,
        None if role == "say" => route(front, "implement"),
        None => vec!["claude".to_owned()],
    }
}

/// The paths a task's BODY names: its backticked words with a `/` in them (what a pack's path routes match).
pub(crate) fn body_paths(body: &str) -> Vec<&str> {
    body.split('`')
        .skip(1)
        .step_by(2)
        .filter(|w| w.contains('/') && !w.contains(char::is_whitespace))
        .collect()
}

/// The profile TASK gets an agent of: the one it was reassigned to (or its plan line named), else the first its job's
/// pack routes its role (and its body's paths) to, else its role's route in the settings.
pub(crate) fn profile_of(front: &Front, data: &Map<String, Value>, task: &Task) -> String {
    let role = task.row.role.as_deref().unwrap_or("implement");
    data_for(data, "profiles", &task.row.id)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            let pack: vordr::pack::Pack = serde_json::from_value(data.get("pack")?.clone()).ok()?;
            let body = data
                .get("tasks")?
                .as_array()?
                .iter()
                .find(|t| t.get("n").and_then(Value::as_i64) == Some(task.row.n))
                .and_then(|t| t.get("body"))
                .and_then(Value::as_str)
                .unwrap_or("");
            pack.profiles_for(role, &body_paths(body))?.first().cloned()
        })
        .unwrap_or_else(|| {
            route(front, role)
                .into_iter()
                .next()
                .unwrap_or_else(|| "claude".into())
        })
}

/// TASKS in the job's run order: the task ids of its data's `order` first, in that order, then the rest by number.
pub(crate) fn ordered<'a>(tasks: &'a [Task], data: &Map<String, Value>) -> Vec<&'a Task> {
    let order: Vec<&str> = data
        .get("order")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut v: Vec<&Task> = tasks.iter().collect();
    if !order.is_empty() {
        v.sort_by_key(|t| {
            order
                .iter()
                .position(|o| *o == t.row.id)
                .unwrap_or(order.len())
        });
    }
    v
}

/// A card's actions: `[[ACTION, LABEL], …]` (`drgnx-job-card-actions`).
pub(crate) fn card_actions(kind: &str, data: &Value) -> Value {
    let a = |pairs: &[(&str, &str)]| pairs.iter().map(|(a, l)| json!([a, l])).collect::<Vec<_>>();
    let mut out = match kind {
        "proposal" => a(&[("approve", "Approve"), ("reject", "Reject")]),
        "permission" => a(&[("allow", "Allow"), ("reject", "Reject")]),
        "write" => a(&[("reject", "Reject")]),
        "merge-conflict" => a(&[
            ("retry", "Let the agent resolve it"),
            ("merge", "Merge again (I resolved it)"),
            ("drop", "Drop the task"),
            ("open", "Open the job's worktree"),
        ]),
        "hook" if data.get("manager").is_some() => a(&[
            ("retry", "Merge again"),
            ("dismiss", "Dismiss and let it merge"),
            ("stop", "Withdraw the card"),
        ]),
        "hook" => {
            let retry = match data.get("point").and_then(Value::as_str) {
                Some("at-review") => ("review", "Review again"),
                _ => ("merge", "Retry the merge"),
            };
            a(&[
                retry,
                ("dismiss", "Dismiss and carry on"),
                ("stop", "Stop the job"),
            ])
        }
        // the gates hold the merge (docs/develop/orchestration.md): a waiver is the user's alone
        "gate" => a(&[
            ("merge", "Check again"),
            ("retry", "Tell the agent"),
            ("waive", "Waive once…"),
            ("drop", "Drop the task"),
        ]),
        "merge-failed" => a(&[
            ("merge", "Merge again"),
            ("drop", "Drop the task"),
            ("open", "Open the job's worktree"),
        ]),
        "review" => {
            let mut v = Vec::new();
            if data.get("gate").is_some_and(|g| !g.is_null()) {
                v.extend(a(&[("edits", "Open its edits")]));
            }
            v.extend(a(&[
                ("accept", "Merge as it is"),
                ("retry", "Back to an agent"),
                ("drop", "Drop the task"),
            ]));
            v
        }
        "fallback" | "agent" | "stalled" => {
            let mut v = Vec::new();
            if data.get("review").is_some_and(|g| !g.is_null()) {
                v.extend(a(&[("review", "Review now")]));
            }
            v.extend(a(&[("retry", "Retry"), ("drop", "Drop the task")]));
            v
        }
        "budget" => a(&[
            ("resume", "Resume with a budget…"),
            ("stop", "Stop the job"),
        ]),
        "clash" => {
            let mut v = Vec::new();
            if data
                .pointer("/recommendation/side")
                .is_some_and(|s| !s.is_null())
            {
                v.extend(a(&[("accept", "Accept the reviewer")]));
            }
            v.extend(a(&[
                ("pick-a", "Pick A"),
                ("pick-b", "Pick B"),
                ("discuss", "Discuss with the reviewer…"),
            ]));
            v
        }
        _ => a(&[("dismiss", "Dismiss")]),
    };
    Value::Array(std::mem::take(&mut out))
}

/// The job as `drgnx-job-summary` has it.
pub(crate) fn summarize(front: &Front, l: &Loaded) -> JobSummary {
    let data = data_of(&l.job);
    let id = l.job.id.as_str();
    let sessions: Vec<_> = front
        .core
        .agents
        .snapshots()
        .into_iter()
        .filter(|s| {
            s.job.as_deref() == Some(id)
                && s.status != Some(runstav::methods::agents::SessionStatus::Exited)
        })
        .collect();
    let busy = front.core.runs.busy_all();
    let tasks = l
        .tasks
        .iter()
        .map(|t| {
            let profile = t
                .row
                .agent
                .as_ref()
                .and_then(|a| sessions.iter().find(|s| &s.id == a))
                .and_then(|s| s.profile.clone())
                .unwrap_or_else(|| profile_of(front, &data, t));
            let mut o = Map::new();
            o.insert("n".into(), json!(t.row.n));
            o.insert("title".into(), json!(t.row.title));
            o.insert("role".into(), json!(t.row.role));
            o.insert("profile".into(), json!(profile));
            if let Some(b) = data_for(&data, "blocked", &t.row.id) {
                o.insert("blocked".into(), b.clone());
            }
            let status = busy
                .get(&t.row.id)
                .map(|s| (*s).to_owned())
                .or_else(|| t.row.status.clone());
            o.insert("status".into(), json!(status));
            if let Some(a) = &t.row.agent {
                o.insert("agent".into(), json!(a));
            }
            o.insert("deps".into(), json!(t.deps));
            Value::Object(o)
        })
        .collect();
    JobSummary {
        id: l.job.id.clone(),
        title: l.job.title.clone(),
        status: l.job.status.clone(),
        repo: l.job.repo.clone(),
        plan: l.job.plan.clone(),
        limits: data
            .get("limits")
            .and_then(|l| serde_json::from_value(l.clone()).ok())
            .unwrap_or_default(),
        spent: Some(l.spent),
        estimate: data.get("estimate").cloned(),
        warnings: data
            .get("warnings")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        tasks,
        order: ordered(&l.tasks, &data)
            .iter()
            .map(|t| json!(t.row.n))
            .collect(),
        agents: sessions
            .iter()
            .map(|s| {
                json!({"id": s.id, "profile": s.profile, "task": s.task, "status": s.status,
                       "review": false})
            })
            .collect(),
        cards: l
            .open_cards
            .iter()
            .map(|c| {
                let d = c.data.clone().unwrap_or(Value::Null);
                json!({"id": c.id, "kind": c.kind, "task": c.task, "title": c.title,
                       "actions": card_actions(c.kind.as_deref().unwrap_or(""), &d), "data": d})
            })
            .collect(),
        messages: l
            .messages
            .iter()
            .map(|m| json!({"id": m.id, "sender": m.sender, "text": m.text, "state": m.state}))
            .collect(),
        decisions: l
            .decisions
            .iter()
            .map(|d| {
                json!({"n": d.n, "kind": d.kind, "subject": d.subject, "author": d.author,
                       "status": d.status})
            })
            .collect(),
        permissions: sessions
            .iter()
            .flat_map(|s| {
                s.permissions
                    .iter()
                    .map(|p| json!({"agent": s.id, "title": p.title}))
            })
            .collect(),
    }
}

/// Job ID's summary now.
pub(crate) async fn summary(front: &Front, id: &str, decisions: bool) -> Result<JobSummary, Error> {
    let l = load(front, id, decisions)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    Ok(summarize(front, &l))
}

/// Tell the subscribers (a `job` event) when job ID's status, its tasks (what is blocked, the run order, the profiles
/// they were reassigned to too) or its open cards changed since the last time they were told.
pub(crate) async fn changed(front: &Front, id: &str) {
    let Ok(Some(l)) = load(front, id, false).await else {
        return;
    };
    let data = data_of(&l.job);
    let busy = front.core.runs.busy_all();
    let sig = json!([
        l.job.status,
        [data.get("blocked"), data.get("order"), data.get("profiles")],
        l.tasks
            .iter()
            .map(|t| json!([t.row.status, t.row.agent, busy.get(&t.row.id)]))
            .collect::<Vec<_>>(),
        l.open_cards
            .iter()
            .map(|c| json!([c.id, c.title, c.data]))
            .collect::<Vec<_>>(),
    ])
    .to_string();
    let new = {
        let mut seen = lock(&front.core.runs.seen);
        if seen.get(id) == Some(&sig) {
            false
        } else {
            seen.insert(id.to_owned(), sig);
            true
        }
    };
    if new {
        front.broadcast("job", json!({"id": id}));
    }
}

// ---- cards ------------------------------------------------------------------------------------------------------

const ADVISORY: [&str; 3] = ["proposal", "overlap", "clash"];

/// Something of JOB's TASK needs the user: a card (one open per task, kind and `key`: a second updates it) with
/// DATA; the task waits (`needs-input`, unless KIND is advisory), the user gets a message and the subscribers a `card`
/// event.  The card's id.
pub(crate) async fn raise_card(
    front: &Front,
    caller: &Caller,
    job: &str,
    task: Option<&str>,
    kind: &str,
    title: &str,
    data: Value,
) -> Result<i64, Error> {
    let title: String = title.replace(['\n', '\r'], " ");
    if let Some(t) = task
        && !ADVISORY.contains(&kind)
    {
        let t = t.to_owned();
        front
            .writer
            .write(caller, "job/card", move |tx| {
                let agent = read_tasks::task_row(tx.sql(), &t)?.and_then(|r| r.agent);
                write_tasks::force_status(tx, &t, "needs-input", agent.as_deref(), now())?;
                Ok(())
            })
            .await
            .map_err(fail)?;
    }
    let key = data.get("key").cloned();
    let old = {
        let (job, task, kind, key) = (
            job.to_owned(),
            task.map(str::to_owned),
            kind.to_owned(),
            key,
        );
        front
            .writer
            .db
            .read(move |c| {
                Ok(read_cards::cards(c, &job, Some("open"))?
                    .into_iter()
                    .find(|x| {
                        x.task == task
                            && x.kind.as_deref() == Some(kind.as_str())
                            && x.data.as_ref().and_then(|d| d.get("key")).cloned() == key
                    }))
            })
            .await
            .map_err(fail)?
    };
    let cid = match old {
        Some(old) => {
            let mut merged = match &data {
                Value::Object(m) => m.clone(),
                _ => Map::new(),
            };
            if let Some(Value::Object(o)) = &old.data {
                for (k, v) in o {
                    merged.entry(k.clone()).or_insert_with(|| v.clone());
                }
            }
            let (id, t) = (old.id, title.clone());
            front
                .writer
                .write(caller, "job/card", move |tx| {
                    write_cards::card_set(
                        tx,
                        id,
                        CardSet {
                            title: Some(t.clone()),
                            data: Some(Value::Object(merged.clone())),
                            state: None,
                        },
                        now(),
                    )
                })
                .await
                .map_err(fail)?;
            id
        }
        None => {
            let s = Send {
                job: Some(job.to_owned()),
                sender: Some("drgnx".into()),
                recipient: "user".into(),
                text: format!("[{kind}] {}: {title}", task.unwrap_or(job)),
                seen: None,
                answers: None,
                question: false,
            };
            let message = match front
                .writer
                .write(caller, "messages/send", move |tx| {
                    write_messages::send(tx, s.clone(), now())
                })
                .await
                .map_err(fail)?
            {
                SendResult::Ok { id, .. } => Some(id),
                SendResult::Held { .. } => None,
            };
            let mut d = match &data {
                Value::Object(m) => m.clone(),
                _ => Map::new(),
            };
            if let Some(m) = message {
                d.insert("message".into(), json!(m));
            }
            let card = NewCard {
                job: Some(job.to_owned()),
                task: task.map(str::to_owned),
                kind: Some(kind.to_owned()),
                title: Some(title.clone()),
                data: Some(Value::Object(d)),
            };
            front
                .writer
                .write(caller, "coord/card-create", move |tx| {
                    write_cards::card_create(tx, card.clone(), now())
                })
                .await
                .map_err(fail)?
        }
    };
    front.broadcast(
        "card",
        json!({"id": cid, "job": job, "task": task, "kind": kind, "title": title}),
    );
    changed(front, job).await;
    Ok(cid)
}

/// JOB's open cards that CHOOSE settles (a choice per card), and the messages they came with marked acted.
pub(crate) async fn settle_cards(
    front: &Front,
    caller: &Caller,
    job: &str,
    choose: impl Fn(&Card) -> Option<&'static str>,
) -> Result<(), Error> {
    let open = {
        let job = job.to_owned();
        front
            .writer
            .db
            .read(move |c| read_cards::cards(c, &job, Some("open")))
            .await
            .map_err(fail)?
    };
    for c in open {
        let Some(choice) = choose(&c) else { continue };
        let id = c.id;
        let settled = front
            .writer
            .write(caller, "cards/settle", move |tx| {
                write_cards::card_settle(tx, id, choice, now())
            })
            .await
            .map_err(fail)?;
        if let Some(m) = c
            .data
            .as_ref()
            .and_then(|d| d.get("message"))
            .and_then(Value::as_i64)
            .filter(|_| settled)
        {
            front
                .writer
                .write(caller, "messages/mark", move |tx| {
                    write_messages::mark(tx, m, "acted", now())
                })
                .await
                .map_err(fail)?;
        }
    }
    Ok(())
}

// ---- propose ----------------------------------------------------------------------------------------------------

/// `job-YYYYMMDD-HHMMSS` (UTC) for T seconds since the epoch.
fn id_at(t: f64) -> String {
    let secs = t as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil from days (H. Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "job-{y:04}{m:02}{d:02}-{:02}{:02}{:02}",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

async fn new_id(front: &Front) -> Result<String, Error> {
    let base = id_at(now());
    let (mut id, mut n) = (base.clone(), 1);
    loop {
        let probe = id.clone();
        let taken = front
            .writer
            .db
            .read(move |c| Ok(read_jobs::job(c, &probe)?.is_some()))
            .await
            .map_err(fail)?;
        if !taken {
            return Ok(id);
        }
        n += 1;
        id = format!("{base}-{n}");
    }
}

/// A job from a plan, proposed (approved at once with `auto`).  ONLY: a task's number, the job is that task and the
/// tasks it needs (Start as Job).  ALONE: Say's proposal, which starts without the OK when the Autonomous rule holds
/// (`say::may_start_alone`).
struct Proposal<'a> {
    plan: &'a PlanRef,
    repo: Option<&'a str>,
    limits: Option<Vec<Limit>>,
    auto: bool,
    alone: bool,
    gate: Option<MergeGate>,
    only: Option<i64>,
}

async fn propose_job(front: &Front, caller: &Caller, p: Proposal<'_>) -> Result<JobSummary, Error> {
    let Proposal {
        plan,
        repo,
        limits,
        auto,
        alone,
        gate,
        only,
    } = p;
    // each stage's end on the hub's clock, for the debug line at the end (a slow proposal names its stage)
    let mut stages = Stages::start();
    let (file, mut read) = match plan {
        PlanRef::File(p) => {
            let file = PathBuf::from(p.as_str());
            let text = tokio::fs::read_to_string(&file)
                .await
                .map_err(|e| invalid(format!("{}: {e}", file.display())))?;
            let read = plan::read(&text, &file);
            (file, read)
        }
        PlanRef::Entity(id) => effects::plan_for_job(front, id.as_str()).await?,
    };
    stages.mark("plan");
    let tasks = match only {
        Some(n) => {
            read.title = format!("{} — Task {n}", read.title);
            plan::needs(&read.tasks, n).map_err(invalid)?
        }
        None => read.tasks.clone(),
    };
    if tasks.is_empty() {
        return Err(invalid(format!(
            "{} has no `### Task N:' headings",
            file.display()
        )));
    }
    plan::check(&tasks).map_err(invalid)?;
    // the rule pack the gates read: the plan's, or the one drgnx ships; frozen in the proposal the user approves
    let pack = match &read.pack {
        Some(f) => {
            let text = tokio::fs::read_to_string(f)
                .await
                .map_err(|e| invalid(format!("{}: {e}", f.display())))?;
            let mut pack = crate::orch::policy::read_pack(&text)
                .map_err(|e| invalid(format!("{}: {e}", f.display())))?;
            // the procedures' text, read beside the pack and frozen with it
            let dir = f.parent().unwrap_or(Path::new("."));
            for p in &mut pack.procedures {
                let at = dir.join(&p.path);
                p.text = tokio::fs::read_to_string(&at)
                    .await
                    .map_err(|e| invalid(format!("procedure {}: {}: {e}", p.name, at.display())))?;
                if p.text.len() > crate::orch::policy::PROCEDURE_CAP {
                    return Err(invalid(format!(
                        "procedure {}: {} is over {} bytes",
                        p.name,
                        at.display(),
                        crate::orch::policy::PROCEDURE_CAP
                    )));
                }
            }
            pack
        }
        None => crate::orch::policy::default_pack(),
    };
    // a task's plan line narrows its role's route in the pack, never widens it
    for t in &tasks {
        if let Some(p) = &t.profile
            && let Some(allowed) = pack.profiles_for(&t.role, &body_paths(&t.body))
            && !allowed.contains(p)
        {
            return Err(invalid(format!(
                "task {}: profile {p} is not one the pack routes {} work to ({})",
                t.n,
                t.role,
                allowed.join(", ")
            )));
        }
    }
    // a task's profile, which a plan an agent wrote may name, goes through the check `job/reassign` and Say make
    for t in &tasks {
        if let Some(p) = &t.profile
            && let Some(why) =
                review::profile_refusal(p, crate::agents::session::find_profile(front, p).as_ref())
        {
            return Err(invalid(format!("task {}: {why}", t.n)));
        }
    }
    let repo = read
        .repo
        .clone()
        .or_else(|| {
            repo.map(|r| {
                if r.ends_with('/') {
                    r.to_owned()
                } else {
                    format!("{r}/")
                }
            })
        })
        .or_else(|| plan::dominating_repo(&file))
        .ok_or_else(|| {
            invalid("No repository for this job: give one, or a **Repo:** line in the plan")
        })?;
    stages.mark("pack");
    let id = new_id(front).await?;
    stages.mark("id");
    let mut roles: Vec<&str> = Vec::new();
    for t in &tasks {
        if !roles.contains(&t.role.as_str()) {
            roles.push(&t.role);
        }
    }
    let routes: Map<String, Value> = roles
        .iter()
        .map(|r| {
            (
                (*r).to_owned(),
                // the pack's route for the role first, then the settings'
                json!(
                    pack.profiles_for(r, &[])
                        .and_then(|p| p.first().cloned())
                        .or_else(|| route(front, r).first().cloned())
                        .unwrap_or_default()
                ),
            )
        })
        .collect();
    let gate = match gate.unwrap_or(MergeGate::Review) {
        MergeGate::Review => "review",
        MergeGate::ReviewAccept => "review+accept",
    };
    // a task that names its profile runs on it (the job's reassignment for it), and one that is not its role's
    // route's is said, so the user sees it before the OK; its model is then only a hint, and one that differs from
    // what the profile runs is said, never silently dropped
    let mut profiles = Map::new();
    let mut said: Vec<String> = Vec::new();
    for t in &tasks {
        let Some(p) = &t.profile else { continue };
        profiles.insert(format!("{id}#{}", t.n), json!(p));
        let default = routes.get(&t.role).and_then(Value::as_str).unwrap_or("");
        if p != default {
            said.push(format!(
                "task {} runs on {p}, not the {} route's {default}",
                t.n, t.role
            ));
        }
        let runs = crate::agents::session::find_profile(front, p).and_then(|p| p.model);
        if let Some(m) = t.model.as_ref().filter(|m| runs.as_ref() != Some(*m)) {
            said.push(format!(
                "task {}: model {m} ignored, profile {p} runs {}",
                t.n,
                runs.as_deref().unwrap_or("its own default model")
            ));
        }
    }
    let mut data = json!({
        "plan": file.to_string_lossy(), "hash": read.hash, "repo": repo, "title": read.title,
        "tasks": tasks.iter().map(|t| {
            let mut o = json!({"n": t.n, "title": t.title, "role": t.role, "deps": t.deps, "body": t.body});
            if let Some(m) = &t.model {
                o["model"] = json!(m);
            }
            o
        }).collect::<Vec<_>>(),
        "routes": routes, "gate": gate, "pack": pack,
    });
    if let Some(l) = &limits {
        norn::write::jobs::set_limits_in(data.as_object_mut().expect("an object"), &json!(l));
    }
    if !profiles.is_empty() {
        data["profiles"] = Value::Object(profiles);
    }
    // the forecast: from the history of similar tasks, before the write; a forecast that fails never blocks a
    // proposal (the estimate then has the prior's tokens and no range)
    let project = crate::graph::project_of(Path::new(&repo))
        .await
        .map_err(internal)?
        .map(|p| p.id);
    stages.mark("project");
    if let Some(p) = &project {
        data["project"] = json!(p);
    }
    let wants = match &data {
        Value::Object(m) => crate::forecast::wants_from(front, &id, m),
        _ => Vec::new(),
    };
    let (forecast, made) = match crate::forecast::for_job(front, &id, wants).await {
        Ok((f, made)) => (Some(f), made),
        Err(e) => {
            tracing::warn!("job {id}: no forecast: {}", e.message);
            (None, Vec::new())
        }
    };
    stages.mark("forecast");
    let mut warnings: Vec<String> = forecast
        .as_ref()
        .map_or_else(Vec::new, |f| f.warnings.clone());
    if let Some(f) = &forecast {
        warnings.extend(budget_warnings(f, limits.as_deref().and_then(usd_of)));
    }
    warnings.extend(said);
    data["estimate"] = estimate_of(forecast.as_ref(), tasks.len());
    data["warnings"] = json!(warnings);
    // Say's proposal starts alone only inside the Autonomous preset's cells; why it waits is the job's
    let starts_alone = if alone {
        let ctx = crate::matrix_gate::ActionCtx {
            project: project.clone(),
            plan: match plan {
                PlanRef::Entity(id) => Some(id.as_str().to_owned()),
                PlanRef::File(_) => None,
            },
            ..crate::matrix_gate::ActionCtx::default()
        };
        let verdict = match &forecast {
            Some(f) => crate::say::may_start_alone(front, f, tasks.len(), ctx).await,
            None => Err(villa::Error::unavailable("no forecast")),
        };
        if let Err(why) = &verdict {
            data["waits"] = json!(why.message());
        }
        verdict.is_ok()
    } else {
        false
    };
    stages.mark("say");
    let title = match &forecast {
        Some(f) => card_title(tasks.len(), f),
        None => format!("{} tasks, no forecast: approve to start", tasks.len()),
    };
    let job = NewJob {
        id: id.clone(),
        title: read.title.clone(),
        plan: Some(file.to_string_lossy().into_owned()),
        repo: Some(repo),
        tasks: tasks
            .iter()
            .map(|t| NewTask {
                n: t.n,
                title: t.title.clone(),
                role: Some(t.role.clone()),
                deps: t.deps.clone(),
            })
            .collect(),
        data: Some(data),
    };
    let created = front
        .writer
        .write(caller, "coord/job-create", move |tx| {
            create_with_forecast(tx, job.clone(), &made, now())
        })
        .await
        .map_err(fail)?;
    stages.mark("write");
    // the write's whole wait (its queue, its batch's run and COMMIT) beside the last batch's COMMIT alone
    let commit_ms = front
        .tools
        .graph()
        .and_then(|g| g.writer.status().last_commit_ms);
    for subject in read.wont_build {
        let d = Decide {
            kind: "wont-build".into(),
            subject,
            task: None,
            paths: None,
            reason: Some("the plan says so".into()),
            author: "user".into(),
            seen: None,
            replaces: None,
            job: Some(created.clone()),
        };
        front
            .writer
            .write(caller, "coord/decide", move |tx| {
                write_decisions::decide(tx, d.clone(), now())
            })
            .await
            .map_err(fail)?;
    }
    if auto {
        approve_job(front, caller, &created, None).await?;
    } else if starts_alone {
        approve_job(front, caller, &created, None).await?;
        // the timeline says who decided: the preset the user chose, not a word of the plan's
        let d = Decide {
            kind: "build".into(),
            subject: "start the job".into(),
            task: None,
            paths: None,
            reason: Some("started by the Autonomous preset within its cells".into()),
            author: "user".into(),
            seen: None,
            replaces: None,
            job: Some(created.clone()),
        };
        front
            .writer
            .write(caller, "coord/decide", move |tx| {
                write_decisions::decide(tx, d.clone(), now())
            })
            .await
            .map_err(fail)?;
    } else {
        raise_card(front, caller, &created, None, "proposal", &title, json!({})).await?;
    }
    changed(front, &created).await;
    let out = summary(front, &created, false).await;
    stages.mark("after");
    tracing::debug!(
        target: "ratatoskr::runner::propose",
        job = %created,
        stages = %stages.said(),
        commit_ms = ?commit_ms,
        "job proposed"
    );
    out
}

/// The ends of a call's stages on the hub's clock (`clock::now`: virtual under a test clock), as milliseconds each.
struct Stages {
    last: tokio::time::Instant,
    took: Vec<(&'static str, f64)>,
}

impl Stages {
    fn start() -> Self {
        Stages {
            last: crate::clock::now(),
            took: Vec::new(),
        }
    }

    /// Stage NAME ended now.
    fn mark(&mut self, name: &'static str) {
        let now = crate::clock::now();
        self.took
            .push((name, (now - self.last).as_secs_f64() * 1000.0));
        self.last = now;
    }

    /// `plan=1.2 pack=0.3 …` (milliseconds).
    fn said(&self) -> String {
        self.took
            .iter()
            .map(|(n, ms)| format!("{n}={ms:.1}"))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

pub async fn propose(
    front: &Front,
    caller: &Caller,
    p: ProposeParams,
) -> Result<JobSummary, Error> {
    let proposal = Proposal {
        plan: &p.plan,
        repo: p.repo.as_ref().map(|r| r.as_str()),
        limits: p.limits.map(|l| l.0),
        auto: p.auto.unwrap_or(false),
        alone: false,
        gate: p.gate,
        only: None,
    };
    propose_job(front, caller, proposal).await
}

/// A graph plan PLAN proposed in REPO with a dollar BUDGET and GATE (Say it's proposal): the user's OK starts it, or
/// the Autonomous preset's cells when they hold all of it.
pub(crate) async fn propose_graph(
    front: &Front,
    caller: &Caller,
    plan: &PlanRef,
    repo: &str,
    limits: Option<Vec<Limit>>,
    gate: Option<MergeGate>,
) -> Result<JobSummary, Error> {
    let proposal = Proposal {
        plan,
        repo: Some(repo),
        limits,
        auto: false,
        alone: true,
        gate,
        only: None,
    };
    propose_job(front, caller, proposal).await
}

pub async fn start_task(
    front: &Front,
    caller: &Caller,
    p: StartTaskParams,
) -> Result<JobSummary, Error> {
    let n = match &p.n {
        TaskNo::Num(n) => i64::try_from(*n).map_err(|_| invalid("Not a task number"))?,
        TaskNo::Name(s) => return Err(invalid(format!("Not a task number: {:?}", s.as_str()))),
    };
    let proposal = Proposal {
        plan: &p.plan,
        repo: None,
        limits: None,
        auto: p.auto.unwrap_or(false),
        alone: false,
        gate: p.gate,
        only: Some(n),
    };
    propose_job(front, caller, proposal).await
}

// ---- approve, stop, status, block, order -----------------------------------------------------------------------

async fn approve_job(
    front: &Front,
    caller: &Caller,
    id: &str,
    limits: Option<Vec<Limit>>,
) -> Result<(), Error> {
    let l = load(front, id, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    let status = l.job.status.clone().unwrap_or_default();
    if status != "proposed" {
        return Err(invalid(format!("Job {id} is {status}, not proposed")));
    }
    let mut data = data_of(&l.job);
    if let Some(l) = &limits {
        norn::write::jobs::set_limits_in(&mut data, &json!(l));
    }
    let limits: Option<Vec<Limit>> = data
        .get("limits")
        .and_then(|l| serde_json::from_value(l.clone()).ok());
    // the rule pack the proposal carried is the job's, recorded with the approval: the gates read that record
    let pack: Option<vordr::pack::Pack> = data
        .get("pack")
        .and_then(|p| serde_json::from_value(p.clone()).ok());
    // only while it is still a proposal, in the write itself: a withdrawal that came first wins
    let jid = id.to_owned();
    let approved = front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            let ok = write_jobs::approve_proposal(tx, &jid, &Value::Object(data.clone()), now())?;
            if ok && let Some(p) = &pack {
                norn::write::evidence::rule_pack(tx, &jid, p, None)?;
            }
            Ok(ok)
        })
        .await
        .map_err(fail)?;
    if !approved {
        return Err(invalid(format!("Job {id} is no longer proposed")));
    }
    // the run counts toward its plan, the plan toward its spec or project, from now on
    link_run(front, &l.job).await;
    // the job's limits are its plan's: reaching one pauses the run (Task 16b)
    if let Some(lim) = limits {
        fallback::set_limits(front, &l.job, lim, true);
    }
    settle_cards(front, caller, id, |c| {
        (c.kind.as_deref() == Some("proposal")).then_some("approve")
    })
    .await?;
    changed(front, id).await;
    front.core.runs.wake();
    Ok(())
}

/// Job ID's proposal withdrawn (a revision replaces it): stopped as a rejected proposal, its card settled reject, only
/// while it is still proposed, decided in the write itself, so an approval that came first runs on.  Whether it was.
pub(crate) async fn withdraw(front: &Front, caller: &Caller, id: &str) -> Result<bool, Error> {
    let jid = id.to_owned();
    let withdrawn = front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            write_jobs::withdraw_proposal(tx, &jid, NEVER_APPROVED, now())
        })
        .await
        .map_err(fail)?;
    if withdrawn {
        settle_cards(front, caller, id, |c| {
            (c.kind.as_deref() == Some("proposal")).then_some("reject")
        })
        .await?;
        changed(front, id).await;
    }
    Ok(withdrawn)
}

pub async fn approve(front: &Front, caller: &Caller, p: WithLimits) -> Result<JobSummary, Error> {
    approve_job(front, caller, p.id.as_str(), p.limits.map(|l| l.0)).await?;
    summary(front, p.id.as_str(), false).await
}

/// Stop job ID: its agents end (their worktrees stay); `job/resume` starts its open tasks again.
pub async fn stop(front: &Front, caller: &Caller, p: ById) -> Result<JobSummary, Error> {
    let id = p.id.as_str();
    load(front, id, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    // a proposal that is stopped was rejected: the job's data says it was never approved, so `job/resume` refuses it.
    // Whether it still is one is read in the write itself: an approval that landed first is stopped like any running
    // job, never marked, so its work can be resumed
    let jid = id.to_owned();
    let withdrawn = front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            write_jobs::stop_job(tx, &jid, NEVER_APPROVED, now())
        })
        .await
        .map_err(fail)?;
    // the proposal card is settled by whichever won: the approval's own settle says `approve`
    if withdrawn {
        settle_cards(front, caller, id, |c| {
            (c.kind.as_deref() == Some("proposal")).then_some("reject")
        })
        .await?;
    }
    // a hook card is the job's to answer while it runs: stopped, it is withdrawn
    settle_cards(front, caller, id, |c| {
        (c.kind.as_deref() == Some("hook")).then_some("stop")
    })
    .await?;
    // the job's work in flight sees it stopped and ends (a start writing its tree, a merge); nothing of it writes after
    // the answer, and an agent such a start made is ended with the rest
    front.core.runs.settled(id).await;
    end_sessions(front, id).await;
    if let Some(h) = front.core.runs.hooks() {
        // the hooks take the shared front; the handler has a reference, the server an Arc: 16b's merges end on the
        // next tick, which sees the job stopped
        let _only_when_used_elsewhere = &h;
    }
    changed(front, id).await;
    summary(front, id, false).await
}

/// Every live session of job ID ends.
pub(crate) async fn end_sessions(front: &Front, id: &str) {
    for s in front.core.agents.snapshots() {
        if s.job.as_deref() == Some(id)
            && s.status != Some(runstav::methods::agents::SessionStatus::Exited)
        {
            crate::soft::done(front.core.agents.kill(&s.id).await, "mod");
        }
    }
}

pub async fn status(front: &Front, _: &Caller, p: StatusParams) -> Result<JobStatusResult, Error> {
    let decisions = p.decisions.unwrap_or(false);
    if let Some(id) = &p.id {
        return Ok(JobStatusResult::One(Box::new(
            summary(front, id.as_str(), decisions).await?,
        )));
    }
    let ids = front
        .writer
        .db
        .read(|c| read_jobs::jobs(c, None))
        .await
        .map_err(fail)?;
    let mut jobs = Vec::with_capacity(ids.len());
    for id in ids {
        if let Ok(s) = summary(front, &id, decisions).await {
            jobs.push(s);
        }
    }
    Ok(JobStatusResult::All { jobs })
}

/// The job of TASK (an id), when the task is there and not done or dropped: else why not.
async fn open_task(front: &Front, tid: &str, open_only: bool) -> Result<(String, Task), Error> {
    let t = tid.to_owned();
    let found = front
        .writer
        .db
        .read(move |c| {
            read_tasks::task(c, &t)?
                .map(|task| read_tasks::task_job(c, &t).map(|j| (j, task)))
                .transpose()
        })
        .await
        .map_err(fail)?;
    let Some((Some(job), task)) = found else {
        return Err(invalid(format!("No task {tid}")));
    };
    let status = task.row.status.clone().unwrap_or_default();
    if open_only && (status == "done" || status == "dropped") {
        return Err(invalid(format!("Task {tid} is {status} already")));
    }
    Ok((job, task))
}

pub async fn block(front: &Front, caller: &Caller, p: BlockParams) -> Result<JobSummary, Error> {
    let tid = p.task.as_str().to_owned();
    let (job, _) = open_task(front, &tid, true).await?;
    let why: String = p
        .reason
        .as_ref()
        .map(|r| {
            r.as_str()
                .chars()
                .map(|c| {
                    if c.is_control()
                        || matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
                    {
                        ' '
                    } else {
                        c
                    }
                })
                .take(BLOCK_REASON_MAX)
                .collect()
        })
        .unwrap_or_default();
    let why = if why.trim().is_empty() {
        "blocked".to_owned()
    } else {
        why
    };
    let t = tid.clone();
    update_data(front, caller, &job, move |d| {
        put_in(d, "blocked", &t, Some(json!(why)));
    })
    .await?;
    changed(front, &job).await;
    summary(front, &job, false).await
}

pub async fn unblock(front: &Front, caller: &Caller, p: ByTask) -> Result<JobSummary, Error> {
    let tid = p.task.as_str().to_owned();
    let (job, _) = open_task(front, &tid, false).await?;
    update_data(front, caller, &job, move |d| {
        put_in(d, "blocked", &tid, None)
    })
    .await?;
    changed(front, &job).await;
    front.core.runs.wake();
    summary(front, &job, false).await
}

/// Move task TID delta places in its job's run order (negative: earlier), among the tasks not done or dropped.
pub async fn order(front: &Front, caller: &Caller, p: OrderParams) -> Result<JobSummary, Error> {
    let tid = p.task.as_str().to_owned();
    let (job, _) = open_task(front, &tid, true).await?;
    let l = load(front, &job, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {job}")))?;
    let data = data_of(&l.job);
    let all: Vec<String> = ordered(&l.tasks, &data)
        .iter()
        .map(|t| t.row.id.clone())
        .collect();
    let open: Vec<String> = ordered(&l.tasks, &data)
        .iter()
        .filter(|t| {
            !matches!(
                t.row.status.as_deref(),
                Some("done" | "dropped" | "accepted" | "parked" | "superseded")
            )
        })
        .map(|t| t.row.id.clone())
        .collect();
    let at = open.iter().position(|x| *x == tid).unwrap_or(0) as i64;
    let to = (at + p.delta.get()).clamp(0, open.len() as i64 - 1) as usize;
    let mut rest: Vec<String> = open.iter().filter(|x| **x != tid).cloned().collect();
    rest.insert(to.min(rest.len()), tid.clone());
    // the open tasks take their new order in the places open tasks had; finished ones keep theirs
    let mut moved = rest.into_iter();
    let new: Vec<Value> = all
        .iter()
        .map(|id| {
            if open.contains(id) {
                json!(moved.next().unwrap_or_else(|| id.clone()))
            } else {
                json!(id)
            }
        })
        .collect();
    update_data(front, caller, &job, move |d| {
        d.insert("order".into(), Value::Array(new));
    })
    .await?;
    changed(front, &job).await;
    summary(front, &job, false).await
}

// ---- Task 16b: cards, replies, reassigning, resuming (the review hand-off and the pauses are [`review`] and
// [`fallback`]) ---------------------------------------------------------------------------------------------------

pub async fn card(front: &Front, caller: &Caller, p: CardParams) -> Result<JobSummary, Error> {
    review::card_act(front, caller, p).await
}

pub async fn reply(front: &Front, caller: &Caller, p: ReplyParams) -> Result<bool, Error> {
    review::reply(front, caller, p).await
}

pub async fn dismiss(front: &Front, caller: &Caller, p: ByMessage) -> Result<bool, Error> {
    review::dismiss(front, caller, p).await
}

pub async fn reassign(
    front: &Front,
    caller: &Caller,
    p: ReassignParams,
) -> Result<JobSummary, Error> {
    review::reassign(front, caller, p).await
}

pub async fn resume(front: &Front, caller: &Caller, p: WithLimits) -> Result<JobSummary, Error> {
    fallback::resume(front, caller, p).await
}

#[cfg(test)]
mod price_tests {
    use super::*;

    /// Pure (D).
    #[test]
    fn a_held_gates_card_offers_a_waiver_and_telling_the_agent() {
        let names = |v: Value| -> Vec<String> {
            v.as_array()
                .unwrap()
                .iter()
                .map(|p| p[0].as_str().unwrap().to_owned())
                .collect()
        };
        assert_eq!(
            names(card_actions("gate", &json!({"key": "gates", "tip": "T"}))),
            vec!["merge", "retry", "waive", "drop"]
        );
    }

    /// Pure (D).
    #[test]
    fn plan_id_does_not_double_the_prefix() {
        let job = |plan: Option<&str>| Job {
            id: "JOB".into(),
            title: None,
            plan: plan.map(str::to_string),
            repo: None,
            status: None,
            created: None,
            data: None,
        };
        assert_eq!(plan_id(&job(Some("plan:ab-1"))), "plan:ab-1");
        assert_eq!(plan_id(&job(Some("/p/x.md"))), "plan:/p/x.md");
        assert_eq!(plan_id(&job(None)), "plan:JOB");
        // the budget: the plan document, across runs, and the run apart
        assert_eq!(
            plan_scope(&job(Some("/p/x.md"))),
            Some(BudgetScope::Plan(Bounded("plan:/p/x.md".into())))
        );
        assert_eq!(plan_scope(&job(None)), None);
        assert_eq!(
            run_scope(&job(None)),
            BudgetScope::Run(Id::new("JOB").unwrap())
        );
    }

    use runstav::methods::forecast::{CostRange, Forecast, Range};
    use runstav::methods::matrix::{Limit, Unit};

    fn range(p50: f64, p90: f64) -> Range {
        Range { p50, p90 }
    }

    /// A forecast of 40M to 130M tokens in 2 h 10 to 4 h, costing the amounts COST (unit, p50, p90).
    fn forecast(cost: &[(Unit, f64, f64)], unpriced: &[&str]) -> Forecast {
        Forecast {
            tasks: Vec::new(),
            tokens: range(40.0e6, 130.0e6),
            active_secs: range(3600.0, 7200.0),
            wall_secs: range(7800.0, 14400.0),
            cost: cost
                .iter()
                .map(|&(unit, p50, p90)| CostRange {
                    unit,
                    p50,
                    p90,
                    estimate: unit == Unit::UsdEst,
                })
                .collect(),
            unpriced: unpriced.iter().map(|s| (*s).to_owned()).collect(),
            wake: None,
            manager: None,
            pace: Vec::new(),
            warnings: Vec::new(),
            prices_as_of: "2026-11-01".into(),
            made_at: 0.0,
            baseline: None,
        }
    }

    /// Pure (D).
    #[test]
    fn the_card_shows_the_range_not_zero() {
        let f = forecast(&[(Unit::UsdEst, 12.4, 41.2)], &[]);
        assert_eq!(
            card_title(3, &f),
            "3 tasks, about 12–41 USD (estimate), 40M–130M tokens, 2 h 10–4 h: approve to start"
        );
    }

    /// Pure (D).
    #[test]
    fn an_unpriced_profile_shows_tokens_and_never_zero() {
        let f = forecast(&[], &["local"]);
        let title = card_title(3, &f);
        assert_eq!(
            title,
            "3 tasks, 40M–130M tokens, 2 h 10–4 h, unpriced: approve to start"
        );
        assert!(!title.contains("0.00"));
    }

    /// Pure (D).
    #[test]
    fn some_unpriced_is_said() {
        let f = forecast(&[(Unit::Usd, 1.5, 4.0)], &["local"]);
        let title = card_title(1, &f);
        assert!(
            title.starts_with("1 task, about 1.50–4.00 USD (some unpriced), "),
            "{title}"
        );
    }

    /// Pure (D): `usd`, `unit`, `tokens` and `unpriced` keep their keys and types for the frozen reader.
    #[test]
    fn the_estimate_keeps_its_keys() {
        let f = forecast(&[(Unit::UsdEst, 12.4, 41.2)], &["x"]);
        let e = estimate_of(Some(&f), 3);
        assert!(e["usd"].is_number());
        assert_eq!(e["unit"], "usd-est");
        assert_eq!(e["tokens"], 40_000_000);
        assert_eq!(e["unpriced"], json!(["x"]));
        assert_eq!(e["forecast"]["wall_secs"]["p50"], 7800.0);
        // no forecast: the prior's tokens, a null forecast, never a zero price
        let none = estimate_of(None, 2);
        assert!(none["forecast"].is_null());
        assert!(none["tokens"].as_u64().unwrap() > 0);
    }

    /// Pure (D): a dollar limit on a plan with a subscription profile binds the estimate too (and is joint).
    #[test]
    fn a_dollar_limit_on_a_subscription_plan_is_joint() {
        let usd = Limit {
            amount: 20.0,
            unit: Unit::Usd,
        };
        let (limits, joint) = joint_limits(vec![usd], true);
        assert!(joint);
        assert_eq!(
            limits,
            [
                usd,
                Limit {
                    amount: 20.0,
                    unit: Unit::UsdEst
                }
            ]
        );
    }

    /// Pure (D): a gateway-only plan keeps its one limit, and a limit-share is never turned into dollars.
    #[test]
    fn a_gateway_only_plan_keeps_its_limits_as_given() {
        let usd = Limit {
            amount: 20.0,
            unit: Unit::Usd,
        };
        let share = Limit {
            amount: 0.15,
            unit: Unit::LimitShare,
        };
        assert_eq!(joint_limits(vec![usd], false), (vec![usd], false));
        // a share alone, even on a subscription plan: no dollar limit, no joint pair
        assert_eq!(joint_limits(vec![share], true), (vec![share], false));
    }

    /// Pure (D): a p90 over the budget is a warning, never a refusal.
    #[test]
    fn p90_over_budget_warns_and_does_not_block() {
        let f = forecast(&[(Unit::UsdEst, 12.0, 41.0)], &[]);
        let w = budget_warnings(&f, Some(20.0));
        assert_eq!(w.len(), 1, "{w:?}");
        assert!(w[0].contains("41") && w[0].contains("20"), "{}", w[0]);
        assert!(budget_warnings(&f, Some(50.0)).is_empty());
        assert!(budget_warnings(&f, None).is_empty());
    }

    /// Pure (D): a mixed plan's budget binds the measured and the estimated dollars together, so its warning reads
    /// their sum: $15 of each at p90 is over $20.
    #[test]
    fn a_mixed_plans_p90_is_warned_on_the_sum() {
        let f = forecast(&[(Unit::Usd, 5.0, 15.0), (Unit::UsdEst, 5.0, 15.0)], &[]);
        let w = budget_warnings(&f, Some(20.0));
        assert_eq!(w.len(), 1, "{w:?}");
        assert!(
            w[0].contains("30") && w[0].contains("estimate") && w[0].contains("20"),
            "{}",
            w[0]
        );
        assert!(budget_warnings(&f, Some(31.0)).is_empty());
    }

    /// Pure (D): a cheap task's cost under a cent reads "<0.01", never "0.00", and a cost of nothing is left off.
    #[test]
    fn a_cost_under_a_cent_is_never_zero() {
        let f = forecast(&[(Unit::Usd, 0.002, 0.004)], &[]);
        let title = card_title(1, &f);
        assert!(title.starts_with("1 task, about <0.01 USD, "), "{title}");
        let f = forecast(&[(Unit::Usd, 0.002, 0.02)], &[]);
        assert!(card_title(1, &f).contains("about <0.01–0.02 USD"));
        let free = forecast(&[(Unit::Usd, 0.0, 0.0)], &[]);
        assert!(
            !card_title(1, &free).contains("0.00"),
            "{}",
            card_title(1, &free)
        );
        for title in [card_title(1, &f), card_title(2, &forecast(&[], &["x"]))] {
            assert!(!title.contains("0.00"), "{title}");
        }
    }

    fn made(job: &str, task: &str, p50: f64) -> norn::forecast::sample::Made {
        norn::forecast::sample::Made {
            job: job.into(),
            task: task.into(),
            made_at: 1.0,
            role: Some("implement".into()),
            profile: Some("claude".into()),
            model: None,
            tokens_p50: p50,
            tokens_p90: p50 * 2.0,
            secs_p50: 1.0,
            secs_p90: 2.0,
            cost_p50: None,
            cost_p90: None,
            cost_unit: None,
            basis: "no history: prior".into(),
            n: 0,
            start_p50: 0.0,
            start_p90: 0.0,
            finish_p50: 1.0,
            finish_p90: 2.0,
        }
    }

    fn new_job(id: &str) -> NewJob {
        NewJob {
            id: id.into(),
            title: "t".into(),
            plan: None,
            repo: None,
            tasks: vec![],
            data: None,
        }
    }

    fn front(dir: &Path) -> Front {
        Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            crate::store::WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
        )
    }

    /// Pure (D): a temp store.  One forecast row per task and one for the plan are written with the job.
    #[test]
    fn every_forecast_made_is_recorded() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let rows = vec![
                made("J", "J#1", 10.0),
                made("J", "J#2", 20.0),
                made("J", "J", 30.0),
            ];
            f.writer
                .write(&user(), "coord/job-create", move |tx| {
                    create_with_forecast(tx, new_job("J"), &rows, 1.0)
                })
                .await
                .unwrap();
            let n = f
                .writer
                .db
                .read(|c| {
                    Ok(c.query_row(
                        "select count(*) from forecast_made where job = 'J'",
                        [],
                        |r| r.get::<_, i64>(0),
                    )?)
                })
                .await
                .unwrap();
            assert_eq!(n, 3);
        })
    }

    /// Pure (D): when the forecast rows do not write, the job is not made either.
    #[test]
    fn the_job_and_its_forecast_are_one_write() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            f.writer
                .write(&user(), "coord/job-create", |tx| {
                    create_with_forecast(tx, new_job("K"), &[], 1.0)
                })
                .await
                .unwrap();
            // a NaN is stored as NULL, which the not-null column refuses
            let bad = vec![made("J", "J#1", f64::NAN)];
            let got = f
                .writer
                .write(&user(), "coord/job-create", move |tx| {
                    create_with_forecast(tx, new_job("J"), &bad, 1.0)
                })
                .await;
            assert!(got.is_err());
            assert!(load(&f, "J", false).await.unwrap().is_none());
        })
    }
}

/// What a graph plan's tasks name (their role, profile, model and body) reaching the proposal.
#[cfg(test)]
pub(crate) mod graph_plan_tests {
    use super::*;
    use crate::store::WorkDb;
    use runstav::proof::Cap;

    pub(crate) fn front(dir: &Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
        )
    }

    /// The user's profiles: PROFILES, an object of name → plist as JSON.
    pub(crate) async fn set_profiles(f: &Front, profiles: Value) {
        f.settings
            .set_overrides(
                None,
                vec![crate::settings::overrides::Override {
                    name: "drgnx-agents-profiles".into(),
                    value: profiles,
                    source: "test".into(),
                }],
            )
            .await
            .unwrap();
    }

    /// A graph plan of TASKS proposed by the user for REPO: the job's id and data.
    pub(crate) async fn proposed(
        f: &Front,
        repo: &Path,
        tasks: Value,
    ) -> (String, Map<String, Value>) {
        let w = effects::plans_write(
            f,
            &user(),
            serde_json::from_value(json!({"title": "P", "tasks": tasks})).unwrap(),
        )
        .await
        .unwrap();
        let p: ProposeParams =
            serde_json::from_value(json!({"plan": w.plan, "repo": repo.to_string_lossy()}))
                .unwrap();
        let s = propose(f, &user(), p).await.unwrap();
        let l = load(f, &s.id, false).await.unwrap().unwrap();
        (s.id, data_of(&l.job))
    }

    /// Pure (D): a temp store.  A plan that names no pack carries the one drgnx ships in its proposal, and its
    /// approval records it as the job's `rule_pack`, which the gates read from then on.
    #[test]
    fn the_approved_proposals_pack_is_the_jobs() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let (id, data) = proposed(
                &f,
                dir.path(),
                json!([{"number": "1", "title": "a", "body": "x"}]),
            )
            .await;
            assert_eq!(data["pack"]["name"], json!("drgnx-default"));
            let jid = id.clone();
            let read = |f: &Front| {
                let jid = jid.clone();
                let db = f.writer.db.clone();
                async move {
                    db.read(move |c| norn::read::evidence::pack_of_job(c, &jid))
                        .await
                        .unwrap()
                }
            };
            assert_eq!(read(&f).await, None, "nothing before the approval");
            approve_job(&f, &user(), &id, None).await.unwrap();
            assert_eq!(read(&f).await, Some(crate::orch::policy::default_pack()));
        })
    }

    /// Pure (D): a temp store.  A plan under a pack with `:models` and `:procedures`: the procedures' text is read
    /// beside the pack and frozen in the proposal; a task runs on its role's (and its paths') first profile; a plan
    /// line's `**Profile:**` narrows that, and one outside the role's profiles is refused.
    #[test]
    fn the_pack_routes_roles_and_carries_its_procedures() {
        saman::Executor::new(2).unwrap().block_on(async move {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        set_profiles(
            &f,
            json!({"sonnet": {"command": ["claude-agent-acp"]}, "opus": {"command": ["claude-agent-acp"]}}),
        )
        .await;
        std::fs::create_dir(dir.path().join("procedures")).unwrap();
        crate::fsio::write(
            dir.path().join("procedures/red-first.md"),
            "Write the failing test first.\n",
        )
        .unwrap();
        crate::fsio::write(
            dir.path().join("pack.eld"),
            "(:name \"t\" :version 1 :rules ((:id \"red-first\" :kind \"enforced\" :doc \"d\"))
              :models ((:role \"implement\" :profiles (\"sonnet\" \"opus\"))
                       (:role \"implement\" :paths (\"runtime/*\") :profiles (\"opus\")))
              :procedures ((:name \"red-first\" :path \"procedures/red-first.md\" :roles (\"implement\"))))\n",
        )
        .unwrap();
        let plan = |profile: &str| {
            format!(
                "# P\n\n**Pack:** pack.eld\n\n### Task 1: a\n\nTouch `wb/a.el`.\n\n### Task 2: b\n\nTouch \
                 `runtime/x.rs`.\n{profile}\n"
            )
        };
        let propose_file = |text: String| {
            let f = &f;
            let dir = dir.path().to_owned();
            async move {
                let file = dir.join("plan.md");
                crate::fsio::write(&file, text).unwrap();
                let p: ProposeParams = serde_json::from_value(
                    json!({"plan": file.to_string_lossy(), "repo": dir.to_string_lossy()}),
                )
                .unwrap();
                propose(f, &user(), p).await
            }
        };
        let refused = propose_file(plan("\n**Profile:** sonnet")).await;
        let why = refused.expect_err("refused").message;
        assert!(why.contains("task 2") && why.contains("sonnet"), "{why}");
        let s = propose_file(plan("")).await.unwrap();
        let l = load(&f, &s.id, false).await.unwrap().unwrap();
        let data = data_of(&l.job);
        assert_eq!(
            data["pack"]["procedures"][0]["text"],
            json!("Write the failing test first.\n")
        );
        assert_eq!(data["routes"]["implement"], json!("sonnet"));
        let task = |n: i64| {
            l.tasks
                .iter()
                .find(|t| t.row.id == format!("{}#{n}", s.id))
                .unwrap()
        };
        assert_eq!(profile_of(&f, &data, task(1)), "sonnet");
        assert_eq!(profile_of(&f, &data, task(2)), "opus");
})
    }

    /// Pure (D): a temp store.  A task's named profile is the job's reassignment for it, which `profile_of` answers.
    #[test]
    fn a_proposed_task_runs_on_its_named_profile() {
        saman::Executor::new(2).unwrap().block_on(async move {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        set_profiles(&f, json!({"opus": {"command": ["claude-agent-acp"]}})).await;
        let (id, data) = proposed(
            &f,
            dir.path(),
            json!([{"number": "1", "title": "a", "body": "x"},
                   {"number": "2", "title": "b", "role": "review", "profile": "opus", "blocks": ["1"], "body": "y"}]),
        )
        .await;
        assert_eq!(
            data_for(&data, "profiles", &format!("{id}#2")),
            Some(&json!("opus"))
        );
        assert_eq!(data_for(&data, "profiles", &format!("{id}#1")), None);
        let l = load(&f, &id, false).await.unwrap().unwrap();
        let t2 = l
            .tasks
            .iter()
            .find(|t| t.row.id == format!("{id}#2"))
            .unwrap();
        assert_eq!(t2.row.role.as_deref(), Some("review"));
        assert_eq!(profile_of(&f, &data, t2), "opus");
})
    }

    /// Pure (D): a temp store.  A model beside a profile is not what runs: the profile does, and the proposal says
    /// the model was ignored.
    #[test]
    fn a_task_with_model_and_profile_runs_on_the_profile() {
        saman::Executor::new(2).unwrap().block_on(async move {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        set_profiles(
            &f,
            json!({"opus": {"command": ["claude-agent-acp"], "model": "claude-opus-5-5"}}),
        )
        .await;
        let (id, data) = proposed(
            &f,
            dir.path(),
            json!([{"number": "1", "title": "a", "model": "claude-haiku-5-5", "profile": "opus", "body": "x"}]),
        )
        .await;
        assert_eq!(
            data_for(&data, "profiles", &format!("{id}#1")),
            Some(&json!("opus"))
        );
        let warnings: Vec<&str> = data
            .get("warnings")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        assert!(
            warnings.contains(
                &"task 1: model claude-haiku-5-5 ignored, profile opus runs claude-opus-5-5"
            ),
            "{warnings:?}"
        );
        let wants = crate::forecast::wants_from(&f, &id, &data);
        assert_eq!(wants[0].profile, "opus");
        assert_eq!(wants[0].model.as_deref(), Some("claude-opus-5-5"));
})
    }

    /// A graph plan of TASKS proposed by the user for REPO: the job's summary, or why it was refused.
    async fn try_propose(f: &Front, repo: &Path, tasks: Value) -> Result<JobSummary, Error> {
        let w = effects::plans_write(
            f,
            &user(),
            serde_json::from_value(json!({"title": "P", "tasks": tasks})).unwrap(),
        )
        .await?;
        let p: ProposeParams =
            serde_json::from_value(json!({"plan": w.plan, "repo": repo.to_string_lossy()}))
                .unwrap();
        propose(f, &user(), p).await
    }

    /// Pure (D): a temp store.  A plan an agent wrote names the profile a task runs on: one a job may not run on
    /// (Codex, whose lock is not proven) or one that is not there is refused at the proposal, as `job/reassign` and
    /// Say refuse it, and no job is made.
    #[test]
    fn a_plan_tasks_profile_goes_through_the_jobs_refusal() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            set_profiles(&f, json!({"codex": {"command": ["codex-acp"]}})).await;
            for (profile, why) in [
                ("codex", "lock is not proven"),
                ("nope", "no agent profile"),
            ] {
                let e = try_propose(
                    &f,
                    dir.path(),
                    json!([{"number": "1", "title": "a", "body": "x"},
                       {"number": "3", "title": "c", "profile": profile, "body": "z"}]),
                )
                .await
                .unwrap_err();
                assert!(
                    e.message.contains("task 3") && e.message.contains(why),
                    "{}",
                    e.message
                );
            }
            let jobs = f
                .writer
                .db
                .read(|c| read_jobs::jobs(c, None))
                .await
                .unwrap();
            assert!(jobs.is_empty(), "{jobs:?}");
        })
    }

    /// Pure (D): a temp store.  A task that runs on a profile other than its role's route says so on the proposal,
    /// where the user reads it before the OK; a task on its route's profile adds nothing.
    #[test]
    fn a_tasks_own_profile_is_shown_beside_its_routes() {
        saman::Executor::new(2).unwrap().block_on(async move {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        set_profiles(&f, json!({"opus": {"command": ["claude-agent-acp"]}})).await;
        let (_, data) = proposed(
            &f,
            dir.path(),
            json!([{"number": "1", "title": "a", "profile": "claude", "body": "x"},
                   {"number": "2", "title": "b", "role": "review", "profile": "opus", "body": "y"}]),
        )
        .await;
        let warnings: Vec<&str> = data["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert!(
            warnings.contains(&"task 2 runs on opus, not the review route's claude"),
            "{warnings:?}"
        );
        assert!(
            !warnings.iter().any(|w| w.starts_with("task 1 ")),
            "{warnings:?}"
        );
})
    }

    /// Pure (D): a temp store.  "$20" on a plan with a subscription profile and a gateway one: what the gateway
    /// measured and what the subscription's agent estimated count together, so $19 of each reaches the limit (and the
    /// gateway may spend nothing more); the limit reached says it is an estimate.
    #[test]
    fn a_dollar_budget_on_a_mixed_plan_binds_the_sum() {
        saman::Executor::new(2).unwrap().block_on(async move {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let (id, _) = proposed(
            &f,
            dir.path(),
            json!([{"number": "1", "title": "a", "profile": "claude", "body": "x"},
                   {"number": "2", "title": "b", "role": "review", "profile": "claude (OpenRouter)", "body": "y"}]),
        )
        .await;
        let l = load(&f, &id, false).await.unwrap().unwrap();
        fallback::set_limits(
            &f,
            &l.job,
            vec![Limit {
                amount: 20.0,
                unit: Unit::Usd,
            }],
            true,
        );
        let scope = plan_scope(&l.job).unwrap();
        let b = &f.core.budgets;
        assert!(b.spend(&scope, Unit::UsdEst, 19.0).is_empty());
        let hits = b.spend(&scope, Unit::Usd, 19.0);
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert!(
            hits[0].estimate() && (hits[0].spent - 38.0).abs() < 1e-9,
            "{hits:?}"
        );
        assert_eq!(b.usd_left(&id), Some(0.0));
        // one card for the plan, not one per unit
        assert!(b.spend(&scope, Unit::UsdEst, 1.0).is_empty());
})
    }

    /// Pure (D): a temp store.  A job approved with a limit by unit has that limit on its plan's scope as given: a share
    /// of the week is no dollar limit.
    #[test]
    fn approve_sets_limit_share_on_the_plan_scope() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let (id, _) = proposed(
                &f,
                dir.path(),
                json!([{"number": "1", "title": "a", "body": "x"}]),
            )
            .await;
            let p: WithLimits = serde_json::from_value(
                json!({"id": id, "limits": [{"amount": 0.15, "unit": "limit-share"}]}),
            )
            .unwrap();
            approve(&f, &user(), p).await.unwrap();
            let l = load(&f, &id, false).await.unwrap().unwrap();
            let scope = plan_scope(&l.job).unwrap();
            assert_eq!(
                f.core.budgets.limits(&scope),
                [Limit {
                    amount: 0.15,
                    unit: Unit::LimitShare
                }]
            );
            assert!(
                f.core
                    .budgets
                    .limits(&scope)
                    .iter()
                    .all(|l| l.unit != Unit::Usd),
                "no dollar limit is made"
            );
            let s = summary(&f, &id, false).await.unwrap();
            assert_eq!(s.limits.len(), 1);
        })
    }

    /// Pure (D): a temp store.  A resume without limits leaves the plan's as they are; an empty list clears them.
    #[test]
    fn resume_without_limits_keeps_them_and_empty_limits_clear() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let (id, _) = proposed(
                &f,
                dir.path(),
                json!([{"number": "1", "title": "a", "body": "x"}]),
            )
            .await;
            let with = |v: Value| -> WithLimits { serde_json::from_value(v).unwrap() };
            approve(
                &f,
                &user(),
                with(json!({"id": id, "limits": [{"amount": 7.0, "unit": "usd"}]})),
            )
            .await
            .unwrap();
            let l = load(&f, &id, false).await.unwrap().unwrap();
            let scope = plan_scope(&l.job).unwrap();
            // the plan has a subscription profile: the dollars bind the estimate too (joint)
            let want = [
                Limit {
                    amount: 7.0,
                    unit: Unit::Usd,
                },
                Limit {
                    amount: 7.0,
                    unit: Unit::UsdEst,
                },
            ];
            assert_eq!(f.core.budgets.limits(&scope), want);
            // stop, then resume with no limits: untouched
            let me: ById = serde_json::from_value(json!({"id": id})).unwrap();
            stop(&f, &user(), me.clone()).await.unwrap();
            resume(&f, &user(), with(json!({"id": id}))).await.unwrap();
            assert_eq!(f.core.budgets.limits(&scope), want);
            // empty limits: cleared
            stop(&f, &user(), me).await.unwrap();
            resume(&f, &user(), with(json!({"id": id, "limits": []})))
                .await
                .unwrap();
            assert!(f.core.budgets.limits(&scope).is_empty());
        })
    }

    /// Pure (D): a temp store.  With no profile named, the task's model is what the forecast prices.
    #[test]
    fn a_model_without_a_profile_is_the_forecasts_model() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let (id, data) = proposed(
                &f,
                dir.path(),
                json!([{"number": "1", "title": "a", "model": "claude-haiku-5-5", "body": "x"}]),
            )
            .await;
            assert_eq!(data_for(&data, "profiles", &format!("{id}#1")), None);
            let wants = crate::forecast::wants_from(&f, &id, &data);
            assert_eq!(wants[0].model.as_deref(), Some("claude-haiku-5-5"));
        })
    }
}

#[cfg(test)]
mod resume_tests {
    use super::*;
    use crate::store::WorkDb;
    use runstav::proof::Cap;

    const JOB: &str = "job-20261103-100000";

    fn front(dir: &Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
        )
    }

    fn user() -> Caller {
        Caller {
            class: Class::User,
            sid: None,
            job: None,
            conn_id: 1,
        }
    }

    async fn propose(front: &Front, caller: &Caller) {
        front
            .writer
            .write(caller, "coord/job-create", |tx| {
                write_jobs::job_create(
                    tx,
                    NewJob {
                        id: JOB.into(),
                        title: "t".into(),
                        plan: None,
                        repo: None,
                        tasks: vec![],
                        data: None,
                    },
                    now(),
                )
            })
            .await
            .unwrap();
    }

    fn by_id() -> ById {
        serde_json::from_value(json!({ "id": JOB })).unwrap()
    }

    fn with_budget() -> WithLimits {
        serde_json::from_value(json!({ "id": JOB })).unwrap()
    }

    async fn status_of(front: &Front) -> String {
        let l = load(front, JOB, false).await.unwrap().unwrap();
        l.job.status.unwrap_or_default()
    }

    #[test]
    fn a_rejected_proposal_does_not_resume() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let c = user();
            propose(&f, &c).await;
            stop(&f, &c, by_id()).await.unwrap();
            assert_eq!(status_of(&f).await, "stopped");
            let e = resume(&f, &c, with_budget()).await.unwrap_err();
            assert!(e.message.contains("was never approved"), "{}", e.message);
            assert_eq!(status_of(&f).await, "stopped");
        })
    }

    #[test]
    fn a_stopped_approved_job_resumes() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = front(dir.path());
            let c = user();
            propose(&f, &c).await;
            approve_job(&f, &c, JOB, None).await.unwrap();
            stop(&f, &c, by_id()).await.unwrap();
            assert_eq!(status_of(&f).await, "stopped");
            resume(&f, &c, with_budget()).await.unwrap();
            assert_eq!(status_of(&f).await, "running");
        })
    }

    /// [D] A stop answers only once the job's work in flight ended: a task still starting (its tree being written)
    /// keeps its mark until its own work clears it, and `job/stop` waits for that, so nothing of the job writes after
    /// the answer (say-test's teardown removed a tree the start was still writing).
    #[test]
    fn a_stop_waits_for_the_jobs_work_in_flight() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = Arc::new(front(dir.path()));
            let c = user();
            propose(&f, &c).await;
            approve_job(&f, &c, JOB, None).await.unwrap();
            let task = format!("{JOB}#1");
            f.core.runs.set_busy(&task, Some("starting"));
            let (f2, c2) = (f.clone(), c.clone());
            let stopping = crate::clock::spawn_untracked(module_path!(), async move {
                stop(&f2, &c2, by_id()).await
            });
            // the stop's write lands; then it has every chance to answer early (counted yields, no clock)
            while status_of(&f).await != "stopped" {
                tokio::task::yield_now().await;
            }
            for _ in 0..10_000 {
                if stopping.is_finished() {
                    break;
                }
                tokio::task::yield_now().await;
            }
            assert!(
                !stopping.is_finished(),
                "the stop answered while the task was still starting"
            );
            assert_eq!(
                f.core.runs.busy_of(&task),
                Some("starting"),
                "the start's own mark stays"
            );
            // the start ends: the stop answers
            f.core.runs.set_busy(&task, None);
            stopping.await.unwrap().unwrap();
        })
    }

    /// A start or merge that panics still clears its mark (`BusyMark` drops on the unwind), so `job/stop` answers
    /// instead of waiting for a mark no one will clear.
    #[test]
    fn a_mark_whose_work_panicked_is_cleared() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let f = Arc::new(front(dir.path()));
            let task = format!("{JOB}#1");
            let mark = BusyMark::set(&f, &task, "merging");
            assert_eq!(f.core.runs.busy_of(&task), Some("merging"));
            let died = crate::clock::spawn_untracked(module_path!(), async move {
                let _mark = mark;
                panic!("a merge that panics");
            })
            .await;
            assert!(died.is_err());
            assert_eq!(f.core.runs.busy_of(&task), None);
            f.core.runs.settled(JOB).await;
        })
    }
}
