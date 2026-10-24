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
pub mod git;
pub mod plan;
pub mod tick;

use crate::agent_core::not_yet;
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
use runstav::methods::jobs::{
    BlockParams, ByMessage, ByTask, CardParams, JobStatusResult, JobSummary, MergeGate,
    OrderParams, PlanRef, ProposeParams, ReassignParams, ReplyParams, StartTaskParams,
    StatusParams, TaskNo, WithBudget,
};
use runstav::registry::Class;
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
/// Agents that may end without finishing a task before the user decides (`drgnx-job-start-tries`).
pub const START_TRIES: i64 = 3;
/// The most characters of a blocked task's reason that are kept.
pub const BLOCK_REASON_MAX: usize = 500;
/// The tokens one task is estimated at: (input, output) (`drgnx-job-task-tokens`).
pub const TASK_TOKENS: (u64, u64) = (150_000, 15_000);

/// What Task 16b adds to the tick: reviews, the merge gate, fallback, the budget pause.  Set once by the server
/// ([`Runs::set_hooks`]); the runner calls it and knows nothing of what it does.
pub trait Hooks: std::marker::Send + Sync {
    /// After the step of running job JOB (the Lisp's `drgnx-job-tick-functions`).
    fn tick<'a>(&'a self, front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a>;
    /// JOB was stopped.
    fn stopped<'a>(&'a self, front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a>;
}

/// What a [`Hooks`] call answers.
pub type HookFuture<'a> = Pin<Box<dyn Future<Output = ()> + std::marker::Send + 'a>>;

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
    scopes: Mutex<HashMap<String, (String, Option<String>)>>,
    wake: Notify,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Runs {
    /// The git of the runner (Task 17 gives `HubGit`); until then [`tick::BasicGit`] makes worktrees only.
    pub fn set_git(&self, git: Arc<dyn RunGit>) {
        let _ = self.git.set(git);
    }

    pub fn set_hooks(&self, hooks: Arc<dyn Hooks>) {
        let _ = self.hooks.set(hooks);
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
        lock(&self.scopes).insert(sid.to_owned(), (plan, project));
    }

    /// The (plan, project) entity ids a plan run's session works under: what `step.plan` and `step.project` hold.
    /// Task 19's step writer calls this where it builds a `StepNew` (`plan: None, project: None` today), per step:
    /// the scope is set just after the session starts, so a `StepCtx` made at the start cannot hold it.
    pub fn scope_of(&self, sid: &str) -> Option<(String, Option<String>)> {
        lock(&self.scopes).get(sid).cloned()
    }

    /// The task session SID ended (its task done, dropped, or its agent failed): the checkpoint cap may prune its
    /// snapshots first.  The one line that connects it is here: Task 19 adds `Timeline::session_finished`, so the
    /// merge replaces the body by `front.core.timeline.session_finished(sid)`.
    pub fn session_finished(&self, front: &Front, sid: &str) {
        let _ = (front, sid);
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
            }
        }
    }

    fn busy_all(&self) -> HashMap<String, &'static str> {
        lock(&self.busy).clone()
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
}

// ---- small helpers ------------------------------------------------------------------------------------------

pub(crate) fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

pub(crate) fn invalid(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: None,
    }
}

pub(crate) fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
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
        backend: false,
    }
}

/// The user as a caller: starting a worker is the user's act, approved with the job.
pub(crate) fn user() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 0,
        backend: false,
    }
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

/// The profiles a role may use, in order (`drgnx-job-route`): the first runs it, the rest are its fallbacks.
pub(crate) fn route(front: &Front, role: &str) -> Vec<String> {
    let cur = front.settings.current();
    cur.loaded
        .values
        .agents_routes
        .iter()
        .find(|r| r.role == role)
        .map(|r| r.profiles.clone())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| vec!["claude".to_owned()])
}

/// The profile TASK gets an agent of: the one it was reassigned to, else its role's first.
pub(crate) fn profile_of(front: &Front, data: &Map<String, Value>, task: &Task) -> String {
    data_for(data, "profiles", &task.row.id)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| {
            route(front, task.row.role.as_deref().unwrap_or("implement"))
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
        budget: data.get("budget").and_then(Value::as_f64),
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
/// event (`drgnx-job--card`).  The card's id.
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
/// tasks it needs (Start as Job).
struct Proposal<'a> {
    plan: &'a PlanRef,
    repo: Option<&'a str>,
    budget: Option<f64>,
    auto: bool,
    gate: Option<MergeGate>,
    only: Option<i64>,
}

async fn propose_job(front: &Front, caller: &Caller, p: Proposal<'_>) -> Result<JobSummary, Error> {
    let Proposal {
        plan,
        repo,
        budget,
        auto,
        gate,
        only,
    } = p;
    let file = match plan {
        PlanRef::File(p) => PathBuf::from(p.as_str()),
        PlanRef::Entity(_) => return Err(not_yet("job/propose (a plan in the graph)", "21")),
    };
    let text = tokio::fs::read_to_string(&file)
        .await
        .map_err(|e| invalid(format!("{}: {e}", file.display())))?;
    let mut read = plan::read(&text, &file);
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
    let id = new_id(front).await?;
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
                json!(route(front, r).first().cloned().unwrap_or_default()),
            )
        })
        .collect();
    let mut unpriced: Vec<String> = Vec::new();
    for r in routes.values().filter_map(Value::as_str) {
        if !unpriced.iter().any(|u| u == r) {
            unpriced.push(r.to_owned());
        }
    }
    let per_task = TASK_TOKENS.0 + TASK_TOKENS.1;
    let estimate =
        json!({"usd": 0.0, "tokens": per_task * tasks.len() as u64, "unpriced": unpriced});
    let gate = match gate.unwrap_or(MergeGate::Review) {
        MergeGate::Review => "review",
        MergeGate::ReviewAccept => "review+accept",
    };
    let data = json!({
        "plan": file.to_string_lossy(), "hash": read.hash, "repo": repo, "title": read.title,
        "tasks": tasks.iter().map(|t| json!({"n": t.n, "title": t.title, "role": t.role,
                                              "deps": t.deps, "body": t.body})).collect::<Vec<_>>(),
        "routes": routes, "estimate": estimate, "budget": budget, "gate": gate,
    });
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
            write_jobs::job_create(tx, job.clone(), now())
        })
        .await
        .map_err(fail)?;
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
    } else {
        let usd = 0.0_f64;
        raise_card(
            front,
            caller,
            &created,
            None,
            "proposal",
            &format!(
                "{} tasks, about {usd:.2} USD{}: approve to start",
                tasks.len(),
                if unpriced.is_empty() {
                    ""
                } else {
                    " (some unpriced)"
                }
            ),
            json!({}),
        )
        .await?;
    }
    changed(front, &created).await;
    summary(front, &created, false).await
}

pub async fn propose(
    front: &Front,
    caller: &Caller,
    p: ProposeParams,
) -> Result<JobSummary, Error> {
    let proposal = Proposal {
        plan: &p.plan,
        repo: p.repo.as_ref().map(|r| r.as_str()),
        budget: p.budget.map(|b| b.get()),
        auto: p.auto.unwrap_or(false),
        gate: p.gate,
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
        budget: None,
        auto: p.auto.unwrap_or(false),
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
    budget: Option<f64>,
) -> Result<(), Error> {
    let l = load(front, id, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    let status = l.job.status.clone().unwrap_or_default();
    if status != "proposed" {
        return Err(invalid(format!("Job {id} is {status}, not proposed")));
    }
    settle_cards(front, caller, id, |c| {
        (c.kind.as_deref() == Some("proposal")).then_some("approve")
    })
    .await?;
    let mut data = data_of(&l.job);
    if let Some(b) = budget {
        data.insert("budget".into(), json!(b));
    }
    let jid = id.to_owned();
    front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            write_jobs::job_set(
                tx,
                &jid,
                Some("running"),
                Some(&Value::Object(data.clone())),
                now(),
            )
        })
        .await
        .map_err(fail)?;
    changed(front, id).await;
    front.core.runs.wake();
    Ok(())
}

pub async fn approve(front: &Front, caller: &Caller, p: WithBudget) -> Result<JobSummary, Error> {
    approve_job(front, caller, p.id.as_str(), p.budget.map(|b| b.get())).await?;
    summary(front, p.id.as_str(), false).await
}

/// Stop job ID: its agents end (their worktrees stay); `job/resume` starts its open tasks again.
pub async fn stop(front: &Front, caller: &Caller, p: ById) -> Result<JobSummary, Error> {
    let id = p.id.as_str();
    let l = load(front, id, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    settle_cards(front, caller, id, |c| {
        (c.kind.as_deref() == Some("proposal")).then_some("reject")
    })
    .await?;
    let jid = id.to_owned();
    front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            write_jobs::job_set(tx, &jid, Some("stopped"), None, now())
        })
        .await
        .map_err(fail)?;
    for t in &l.tasks {
        front.core.runs.set_busy(&t.row.id, None);
    }
    end_sessions(front, id).await;
    if let Some(h) = front.core.runs.hooks() {
        // the hooks take the shared front; the handler has a reference, the server an Arc: 16b's merges end on the
        // next tick, which sees the job stopped
        let _ = h;
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
            let _ = front.core.agents.kill(&s.id).await;
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
        .filter(|t| !matches!(t.row.status.as_deref(), Some("done" | "dropped")))
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

// ---- Task 16b ---------------------------------------------------------------------------------------------------

pub async fn card(_: &Front, _: &Caller, _: CardParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/card", "16b"))
}

pub async fn reply(_: &Front, _: &Caller, _: ReplyParams) -> Result<bool, Error> {
    Err(not_yet("job/reply", "16b"))
}

pub async fn dismiss(_: &Front, _: &Caller, _: ByMessage) -> Result<bool, Error> {
    Err(not_yet("job/dismiss", "16b"))
}

pub async fn reassign(_: &Front, _: &Caller, _: ReassignParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/reassign", "16b"))
}

pub async fn resume(_: &Front, _: &Caller, _: WithBudget) -> Result<JobSummary, Error> {
    Err(not_yet("job/resume", "16b"))
}
