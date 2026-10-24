//! Plan runs: the review hand-off, the merge flow, the stalled nudge and the cards the user answers (Task 16b; the
//! Lisp `drgnx-job--start-review`, `--verdict`, `--reviewed`, `--merge`, `--nudge`, `drgnx-job-card-act` and the
//! clash reviewers of `drgnx-job-clash.el` are the oracle).
//!
//! [`PlanHooks`] is the runner's [`Hooks`]: after each step of a running job it looks, with no git on the tick (git
//! runs in tasks of its own, with deadlines), at
//!
//! - **workers** whose turn ended with the task open: a provider at its limit hands the task to the next profile
//!   ([`super::fallback`]); any other end is a reminder, then a `stalled` card;
//! - **tasks in review**: once the worker's turn is over a reviewer starts on the first profile of the `review`
//!   route (any provider; the clash rules may hold the review, [`clash::before_review`]), its last line `VERDICT:`
//!   decides ([`verdict`]): a pass is accepted for every file at its current diff and the task merges into the job's
//!   branch (the gate, [`super::RunGit::merge_gate`]; a `Gate::Ask` waits for its card and, answered yes, clears the
//!   branch and merges), a fail sends the task back to a worker with the reasons (the user after
//!   [`REVIEW_TRIES`]), no verdict is the user's;
//! - **tasks waiting for input** whose agent is gone: they go back to where they were;
//! - **clash cards** without a recommendation: a reviewer reads the card ([`clash::start_reviewers`]).

use super::clash::{self, Clash, ReviewerHook};
use super::fallback::{self, Ended, quote, said, set_status};
use super::{
    Caller, Error, HookFuture, Hooks, Loaded, TaskTree, changed, data_for, data_of, internal,
    invalid, load, now, put_in, raise_card, route, service, settle_cards, summary, tick,
    update_data, user,
};
use crate::agents::Origin;
use crate::coord::fail;
use crate::front::Front;
use crate::matrix_gate::Gate;
use norn::read::cards::Card;
use norn::read::tasks::Task;
use norn::write::cards::{CardSet, card_set, card_settle};
use norn::write::decisions::{Decide, decide};
use norn::write::event::{Event, EventKind, event};
use norn::write::messages::{Send, mark, send};
use norn::write::review::review_mark;
use runstav::methods::agents::{SessionStatus, Snapshot, StartParams};
use runstav::methods::jobs::{ByMessage, CardParams, JobSummary, ReassignParams, ReplyParams};
use runstav::methods::matrix::Role;
use runstav::types::{AbsPath, Bounded, Id, StringOrNumber, TaskRef};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// Failed reviews after which the user decides (`drgnx-job-review-tries`).
pub const REVIEW_TRIES: i64 = 3;
/// Seconds a task may stay in review while its agent's turn goes on (`drgnx-job-review-turn-limit`).
pub const REVIEW_TURN_LIMIT: f64 = 600.0;
/// Times a lost clash reviewer is started (once, then once more).
const CLASH_STARTS: i64 = 2;

/// A reviewer session of a task.
#[derive(Clone, Debug)]
struct Reviewer {
    sid: String,
}

#[derive(Default)]
struct State {
    /// Task id → its reviewer.
    reviewers: HashMap<String, Reviewer>,
    /// Task ids (and `clash:<card>`) with a task of ours in flight: git or a start, off the tick.
    working: HashSet<String>,
    /// Session id → the entries looked at: a turn is read once.
    seen: HashMap<String, u64>,
    /// Task id → the matrix card its merge waits on (CI or build files changed).
    gates: HashMap<String, i64>,
    /// Task id → when it began to wait for its agent's turn to end.
    since: HashMap<String, f64>,
}

/// The runner's hooks for review, fallback, nudges and the clash reviewers.
#[derive(Clone, Default)]
pub struct PlanHooks(Arc<Mutex<State>>);

impl PlanHooks {
    fn st(&self) -> MutexGuard<'_, State> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn busy(&self, key: &str) -> bool {
        self.st().working.contains(key)
    }

    /// Run F as a task of its own, with KEY marked in flight meanwhile.
    fn spawn<F>(&self, key: String, f: F)
    where
        F: std::future::Future<Output = ()> + std::marker::Send + 'static,
    {
        self.st().working.insert(key.clone());
        let me = self.clone();
        tokio::spawn(async move {
            f.await;
            me.st().working.remove(&key);
        });
    }
}

impl Hooks for PlanHooks {
    fn tick<'a>(&'a self, front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a> {
        Box::pin(async move {
            if let Err(e) = self.drive(front, job).await {
                tracing::warn!("plan run {job}: review: {}", e.message);
            }
        })
    }

    fn stopped<'a>(&'a self, _front: &'a Arc<Front>, job: &'a str) -> HookFuture<'a> {
        Box::pin(async move {
            let prefix = format!("{job}#");
            let mut st = self.st();
            st.reviewers.retain(|t, _| !t.starts_with(&prefix));
            st.gates.retain(|t, _| !t.starts_with(&prefix));
        })
    }

    fn carded<'a>(
        &'a self,
        front: &'a Arc<Front>,
        job: &'a str,
        clashes: Vec<Clash>,
    ) -> HookFuture<'a> {
        Box::pin(async move {
            struct Collect(Vec<Clash>);
            impl ReviewerHook for Collect {
                fn start(&mut self, clash: &Clash, _long: bool) {
                    self.0.push(clash.clone());
                }
            }
            let mut c = Collect(Vec::new());
            clash::start_reviewers(&mut c, &clashes);
            let Ok(Some(l)) = load(front, job, false).await else {
                return;
            };
            for k in c.0 {
                let Some(card) = l.open_cards.iter().find(|x| {
                    x.kind.as_deref() == Some("clash")
                        && x.data
                            .as_ref()
                            .and_then(|d| d.get("key"))
                            .and_then(Value::as_str)
                            == Some(k.key.as_str())
                }) else {
                    continue;
                };
                self.start_clash(front, job, card.id);
            }
        })
    }
}

/// Between turns with nothing queued (a failed turn leaves the session paused: it is idle all the same).
fn is_idle(s: &Snapshot) -> bool {
    s.status == Some(SessionStatus::Idle) && s.queue.is_empty()
}

/// Idle and not held (a budget pause holds a session after its turn).
fn is_free(s: &Snapshot) -> bool {
    is_idle(s) && s.paused != Some(true)
}

fn is_alive(s: &Snapshot) -> bool {
    s.status != Some(SessionStatus::Exited)
}

fn count(data: &Map<String, Value>, bucket: &str, task: &str) -> i64 {
    data_for(data, bucket, task)
        .and_then(Value::as_i64)
        .unwrap_or(0)
}

async fn set_count(
    front: &Front,
    job: &str,
    bucket: &'static str,
    task: &str,
    n: Option<i64>,
) -> Result<(), Error> {
    let t = task.to_owned();
    update_data(front, &service(), job, move |d| {
        put_in(d, bucket, &t, n.map(|n| json!(n)));
    })
    .await
}

async fn add_event(
    front: &Front,
    job: &str,
    task: &str,
    agent: Option<String>,
    kind: EventKind,
    summary: String,
    data: Option<Value>,
) {
    let (job, task) = (job.to_owned(), task.to_owned());
    let w = front
        .writer
        .write(&service(), "job/event", move |tx| {
            event(
                tx,
                Event {
                    at: now(),
                    agent: agent.clone(),
                    job: Some(job.clone()),
                    task: Some(task.clone()),
                    kind,
                    summary: summary.clone(),
                    data: data.clone(),
                    turn: false,
                },
            )
            .map(|_| ())
        })
        .await;
    if let Err(e) = w {
        tracing::debug!("plan run event not written: {e:?}");
    }
}

/// A reviewer's answer: its last non-empty line, without the Markdown marks a model puts round it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Pass,
    Fail(String),
}

/// The verdict in TEXT (`VERDICT: pass`, `VERDICT: fail: what to change`), or none (`drgnx-job--verdict`).
pub fn verdict(text: &str) -> Option<Verdict> {
    let line = text.lines().map(str::trim).rfind(|l| !l.is_empty())?;
    let line = line.trim_matches(|c: char| "*_`> \t".contains(c));
    let rest = line.strip_prefix("VERDICT:")?.trim_start();
    if rest.starts_with("pass") {
        Some(Verdict::Pass)
    } else {
        rest.strip_prefix("fail")
            .map(|r| Verdict::Fail(r.trim_start_matches(':').trim().to_owned()))
    }
}

/// The side a clash reviewer recommends in TEXT: its last `RECOMMEND:` line, `(side, why)` (`neither` has no side).
pub fn recommendation(text: &str) -> Option<(Option<String>, String)> {
    text.lines().rev().find_map(|l| {
        let rest = l.trim().strip_prefix("RECOMMEND:")?.trim_start();
        let (word, why) = rest
            .split_once(|c: char| c == ':' || c == ',' || c.is_whitespace())
            .unwrap_or((rest, ""));
        let why = why.trim_start_matches([':', ',', ' ']).trim().to_owned();
        match word {
            "A" | "B" => Some((Some(word.to_owned()), why)),
            "neither" => Some((None, why)),
            _ => None,
        }
    })
}

/// The git error as the runner's.
fn git_error(e: super::GitError) -> Error {
    internal(format!("{}: {}", e.what, e.stderr))
}

impl PlanHooks {
    async fn drive(&self, front: &Arc<Front>, job: &str) -> Result<(), Error> {
        let Some(l) = load(front, job, false).await? else {
            return Ok(());
        };
        if l.job.status.as_deref() != Some("running") {
            return Ok(());
        }
        let data = data_of(&l.job);
        let sessions: Vec<Snapshot> = front
            .core
            .agents
            .snapshots()
            .into_iter()
            .filter(|s| s.job.as_deref() == Some(job))
            .collect();
        for t in &l.tasks {
            let tid = t.row.id.as_str();
            if front.core.runs.busy_of(tid).is_some() || self.busy(tid) {
                continue;
            }
            let status = t.row.status.as_deref().unwrap_or("");
            if status != "needs-input" && data_for(&data, "waiting", tid).is_some() {
                let t2 = tid.to_owned();
                update_data(front, &service(), job, move |d| {
                    put_in(d, "waiting", &t2, None)
                })
                .await?;
            }
            match status {
                "claimed" | "running" => self.worker(front, job, t, &sessions, &data).await?,
                "in-review" => self.review(front, job, t, &sessions, &l, &data).await?,
                "needs-input" => self.recover(front, job, t, &sessions, &l, &data).await?,
                _ => {}
            }
        }
        self.clash_cards(front, job, &l).await
    }

    // ---- workers: fallback and the nudge ------------------------------------------------------------------

    async fn worker(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        sessions: &[Snapshot],
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let Some(s) = t
            .row
            .agent
            .as_deref()
            .and_then(|a| sessions.iter().find(|s| s.id == a))
        else {
            return Ok(());
        };
        let n = s.entries_count.unwrap_or(0);
        if !is_idle(s) || self.st().seen.get(&s.id) == Some(&n) {
            return Ok(());
        }
        let tr = front.core.agents.get(&s.id)?;
        let Some(end) = fallback::ended(&tr) else {
            return Ok(());
        };
        // a budget pause is not a stall
        if end == Ended::Stopped && s.paused == Some(true) {
            return Ok(());
        }
        self.st().seen.insert(s.id.clone(), n);
        match end {
            Ended::Limit(why) => {
                let (f, job2, task, snap) = (front.clone(), job.to_owned(), t.clone(), s.clone());
                self.spawn(t.row.id.clone(), async move {
                    if let Err(e) = fallback::worker(&f, &job2, &task, &snap, &tr, &why).await {
                        tracing::warn!("plan run {job2}: fallback: {}", e.message);
                    }
                });
            }
            Ended::Stopped => self.nudge(front, job, t, s, data).await?,
        }
        Ok(())
    }

    /// The agent's turn ended with its task open: once a reminder, then a card.
    async fn nudge(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        s: &Snapshot,
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        if count(data, "nudged", tid) == 0 {
            set_count(front, job, "nudged", tid, Some(1)).await?;
            let text = format!(
                "[drgnx] Your turn ended but task {tid} is not finished. Finish it and call complete_task; if \
                 something blocks you, say what and call update_task with needs-input."
            );
            front.core.agents.prompt(&s.id, text, Origin::Hub)?;
        } else {
            raise_card(
                front,
                &service(),
                job,
                Some(tid),
                "stalled",
                "its agent's turns end without complete_task",
                json!({}),
            )
            .await?;
        }
        Ok(())
    }

    // ---- needs-input: the request's agent is gone -----------------------------------------------------------

    async fn recover(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        sessions: &[Snapshot],
        l: &Loaded,
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        let alive = |sid: &str| sessions.iter().any(|s| s.id == sid && is_alive(s));
        match data_for(data, "waiting", tid) {
            Some(w) => {
                let sid = w.get("sid").and_then(Value::as_str).unwrap_or("");
                if alive(sid) {
                    return Ok(());
                }
                let back: &'static str = match w.get("back").and_then(Value::as_str) {
                    Some("in-review") => "in-review",
                    Some("claimed") => "claimed",
                    _ => "running",
                };
                let agent = (back == "in-review").then(|| t.row.agent.clone()).flatten();
                let t2 = tid.to_owned();
                update_data(front, &service(), job, move |d| {
                    put_in(d, "waiting", &t2, None)
                })
                .await?;
                set_status(front, tid, back, agent).await?;
                front.core.runs.wake();
            }
            None => {
                // the agent said it needs input (no card of ours): remember who waits, to free the task if it dies
                let carded = l.open_cards.iter().any(|c| c.task.as_deref() == Some(tid));
                if let Some(a) = t
                    .row
                    .agent
                    .as_deref()
                    .filter(|a| alive(a))
                    .filter(|_| !carded)
                {
                    let (t2, sid) = (tid.to_owned(), a.to_owned());
                    update_data(front, &service(), job, move |d| {
                        put_in(
                            d,
                            "waiting",
                            &t2,
                            Some(json!({"sid": sid, "back": "running"})),
                        );
                    })
                    .await?;
                }
            }
        }
        Ok(())
    }

    // ---- review ---------------------------------------------------------------------------------------------------

    async fn review(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        sessions: &[Snapshot],
        l: &Loaded,
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        let reviewer = self.st().reviewers.get(tid).cloned();
        if let Some(r) = reviewer {
            return self.reviewer_turn(front, job, t, &r, sessions, data).await;
        }
        if data_for(data, "passed", tid).is_some() {
            return self.merge_task(front, job, t, l);
        }
        // finished, but its agent's turn goes on (complete_task comes mid-turn): the review waits - not for ever
        let worker = t
            .row
            .agent
            .as_deref()
            .and_then(|a| sessions.iter().find(|s| s.id == a && is_alive(s)));
        if let Some(w) = worker {
            if !is_free(w) {
                return self.review_wait(front, job, tid).await;
            }
            let _ = front.core.agents.kill(&w.id).await;
            front.core.runs.session_finished(front, &w.id);
        }
        self.st().since.remove(tid);
        // a clash about the task holds its review (a card is open)
        if l.open_cards
            .iter()
            .any(|c| c.kind.as_deref() == Some("clash") && c.task.as_deref() == Some(tid))
        {
            return Ok(());
        }
        let (f, job2, tid2, me) = (front.clone(), job.to_owned(), tid.to_owned(), self.clone());
        self.spawn(tid.to_owned(), async move {
            if let Err(e) = me.begin_review(&f, &job2, &tid2).await {
                tracing::warn!("plan run {job2}: review of {tid2}: {}", e.message);
            }
        });
        Ok(())
    }

    /// The task's agent finished it but its turn has not ended: after [`REVIEW_TURN_LIMIT`] a card.
    async fn review_wait(&self, front: &Arc<Front>, job: &str, tid: &str) -> Result<(), Error> {
        let since = *self.st().since.entry(tid.to_owned()).or_insert_with(now);
        if now() - since > REVIEW_TURN_LIMIT {
            self.st().since.remove(tid);
            raise_card(
                front,
                &service(),
                job,
                Some(tid),
                "stalled",
                &format!(
                    "its agent's turn has not ended {} minutes after it finished the task",
                    (REVIEW_TURN_LIMIT / 60.0).round()
                ),
                json!({"review": true}),
            )
            .await?;
        }
        Ok(())
    }

    /// The tree of task T, made when it is not (it is, for a task that began): off the tick.
    async fn tree_of(
        &self,
        front: &Front,
        repo: &Path,
        job: &str,
        t: &Task,
        data: &Map<String, Value>,
    ) -> Result<TaskTree, Error> {
        let base = data_for(data, "bases", &t.row.id)
            .and_then(Value::as_str)
            .ok_or_else(|| internal(format!("no base recorded for {}", t.row.id)))?;
        front
            .core
            .runs
            .git()
            .task_worktree(repo, job, &t.row.n.to_string(), base)
            .await
            .map_err(git_error)
    }

    /// Start the reviewer of task TID of job JOB: the task's changes are looked at in the trusted repository (none:
    /// a card), the clash rules may hold the review, then an agent of the `review` route reads the work.
    async fn begin_review(&self, front: &Arc<Front>, job: &str, tid: &str) -> Result<(), Error> {
        let Some(l) = load(front, job, true).await? else {
            return Ok(());
        };
        let Some(t) = l.tasks.iter().find(|t| t.row.id == tid) else {
            return Ok(());
        };
        if l.job.status.as_deref() != Some("running")
            || t.row.status.as_deref() != Some("in-review")
        {
            return Ok(());
        }
        let data = data_of(&l.job);
        let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
        let tree = self.tree_of(front, &repo, job, t, &data).await?;
        let git = front.core.runs.git();
        git.prepare(&tree).await.map_err(git_error)?;
        let files = git.diffs(&repo, &tree).await.map_err(git_error)?;
        if files.is_empty() {
            raise_card(
                front,
                &service(),
                job,
                Some(tid),
                "review",
                "finished with no commits: nothing to review",
                json!({}),
            )
            .await?;
            return Ok(());
        }
        // the clash rules: a new against-decision clash holds the review
        let sessions: Vec<Snapshot> = front
            .core
            .agents
            .snapshots()
            .into_iter()
            .filter(|s| s.job.as_deref() == Some(job))
            .collect();
        let mut index = clash::DiffIndex::new();
        index.insert(tid.to_owned(), files);
        let run = tick::run_state(&l, &data, &sessions, &BTreeMap::new(), &[], &index);
        let gate = clash::before_review(&run, &tick::decisions_of(&l), &index, tid);
        for c in &gate.clashes {
            tick::card_clash(front, job, c).await?;
        }
        if !gate.clashes.is_empty() {
            self.carded(front, job, gate.clashes.clone()).await;
        }
        if gate.wait {
            return Ok(());
        }
        self.start_review_agent(front, job, t, &tree, None).await
    }

    /// A reviewer agent for TASK, in the task's tree, on PROFILE (the first of the `review` route by default).
    async fn start_review_agent(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        tree: &TaskTree,
        profile: Option<String>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        let profile = profile
            .or_else(|| route(front, "review").into_iter().next())
            .unwrap_or_else(|| "claude".into());
        let started = front
            .core
            .agents
            .start(
                front,
                StartParams {
                    profile: Bounded(profile.clone()),
                    cwd: AbsPath::new(tree.path.to_string_lossy().into_owned()).ok(),
                    task: TaskRef::new(tid).ok(),
                    job: Id::new(job).ok(),
                    role: Some(Role::Worker),
                    about: None,
                    document: None,
                },
                &user(),
            )
            .await;
        let sid = match started {
            Ok(s) => s.id,
            Err(e) => {
                raise_card(
                    front,
                    &service(),
                    job,
                    Some(tid),
                    "review",
                    &format!("no reviewer on {profile}: {}", e.message),
                    json!({"profile": profile}),
                )
                .await?;
                return Ok(());
            }
        };
        self.st()
            .reviewers
            .insert(tid.to_owned(), Reviewer { sid: sid.clone() });
        let prompt = format!(
            "[drgnx review {tid}] {}\n\nReview the changes: git diff job/{job}...HEAD.  Answer with a last line \
             VERDICT: pass, or VERDICT: fail: what to change.",
            t.row.title.as_deref().unwrap_or("")
        );
        front.core.agents.prompt(&sid, prompt, Origin::Hub)?;
        changed(front, job).await;
        Ok(())
    }

    /// The reviewer of T: its turn is over (a verdict), at its provider's limit (the next profile), or it is gone.
    async fn reviewer_turn(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        r: &Reviewer,
        sessions: &[Snapshot],
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        let Some(s) = sessions
            .iter()
            .find(|s| s.id == r.sid)
            .filter(|s| is_alive(s))
        else {
            // lost (the job was stopped, the hub restarted): once more, then the user
            self.st().reviewers.remove(tid);
            let n = count(data, "review-restarts", tid) + 1;
            set_count(front, job, "review-restarts", tid, Some(n)).await?;
            if n >= REVIEW_TRIES {
                raise_card(
                    front,
                    &service(),
                    job,
                    Some(tid),
                    "review",
                    "the reviewer was lost",
                    json!({}),
                )
                .await?;
            }
            return Ok(());
        };
        let n = s.entries_count.unwrap_or(0);
        if !is_idle(s) || self.st().seen.get(&s.id) == Some(&n) {
            return Ok(());
        }
        let tr = front.core.agents.get(&s.id)?;
        let Some(end) = fallback::ended(&tr) else {
            return Ok(());
        };
        if end == Ended::Stopped && s.paused == Some(true) {
            return Ok(());
        }
        self.st().seen.insert(s.id.clone(), n);
        let _ = front.core.agents.kill(&s.id).await;
        self.st().reviewers.remove(tid);
        match end {
            Ended::Limit(why) => {
                // starts again on the next profile of the review route, else the user
                let from = s.profile.clone().unwrap_or_default();
                let routes = route(front, "review");
                let to = routes
                    .iter()
                    .position(|p| *p == from)
                    .and_then(|i| routes.get(i + 1))
                    .cloned();
                match to {
                    Some(to) => {
                        let (f, job2, task, me) =
                            (front.clone(), job.to_owned(), t.clone(), self.clone());
                        self.spawn(tid.to_owned(), async move {
                            let r = async {
                                let l = load(&f, &job2, false).await?;
                                let l = l.ok_or_else(|| internal("the job is gone"))?;
                                let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
                                let tree = me
                                    .tree_of(&f, &repo, &job2, &task, &data_of(&l.job))
                                    .await?;
                                me.start_review_agent(&f, &job2, &task, &tree, Some(to))
                                    .await
                            };
                            if let Err(e) = r.await {
                                tracing::warn!("plan run {job2}: review fallback: {}", e.message);
                            }
                        });
                    }
                    None => {
                        raise_card(
                            front,
                            &service(),
                            job,
                            Some(tid),
                            "review",
                            &format!(
                                "the reviewer ({from}) failed ({why}); no other review profile on the route"
                            ),
                            json!({}),
                        )
                        .await?;
                    }
                }
            }
            Ended::Stopped => {
                let v = verdict(&fallback::last_said(&tr));
                self.reviewed(front, job, t, v, &s.id, data).await?;
            }
        }
        Ok(())
    }

    /// Task T was reviewed by session REVIEWER: a pass is accepted and merges; a fail goes back to a worker with the
    /// reasons (the user after [`REVIEW_TRIES`]); no verdict is the user's.
    async fn reviewed(
        &self,
        front: &Arc<Front>,
        job: &str,
        t: &Task,
        v: Option<Verdict>,
        reviewer: &str,
        data: &Map<String, Value>,
    ) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        let (summary_text, kind_data) = match &v {
            Some(Verdict::Pass) => ("pass".to_owned(), Some(json!({"verdict": "pass"}))),
            Some(Verdict::Fail(r)) => (format!("fail: {r}"), Some(json!({"verdict": "fail"}))),
            None => ("the reviewer gave no verdict".to_owned(), None),
        };
        add_event(
            front,
            job,
            tid,
            Some(reviewer.to_owned()),
            EventKind::Review,
            summary_text,
            kind_data,
        )
        .await;
        match v {
            Some(Verdict::Pass) => {
                let t2 = tid.to_owned();
                update_data(front, &service(), job, move |d| {
                    put_in(d, "passed", &t2, Some(json!(true)));
                })
                .await?;
            }
            Some(Verdict::Fail(reasons)) => {
                let fails = count(data, "fails", tid) + 1;
                let (t2, r2) = (tid.to_owned(), reasons.clone());
                update_data(front, &service(), job, move |d| {
                    put_in(d, "fails", &t2, Some(json!(fails)));
                    put_in(d, "notes", &t2, Some(json!(r2)));
                })
                .await?;
                if fails >= REVIEW_TRIES {
                    raise_card(
                        front,
                        &service(),
                        job,
                        Some(tid),
                        "review",
                        &format!("failed review {fails} times: {reasons}"),
                        json!({}),
                    )
                    .await?;
                } else {
                    set_status(front, tid, "ready", None).await?;
                }
            }
            None => {
                raise_card(
                    front,
                    &service(),
                    job,
                    Some(tid),
                    "review",
                    "the reviewer gave no verdict",
                    json!({}),
                )
                .await?;
            }
        }
        front.core.runs.wake();
        changed(front, job).await;
        Ok(())
    }

    // ---- the merge flow -----------------------------------------------------------------------------------------

    /// Merge T (passed review) into the job's branch: one merge at a time in a job; git in a task of its own.
    fn merge_task(&self, front: &Arc<Front>, job: &str, t: &Task, l: &Loaded) -> Result<(), Error> {
        let runs = &front.core.runs;
        if l.tasks
            .iter()
            .any(|o| runs.busy_of(&o.row.id) == Some("merging"))
        {
            return Ok(());
        }
        let (f, job2, tid, me) = (
            front.clone(),
            job.to_owned(),
            t.row.id.clone(),
            self.clone(),
        );
        self.spawn(t.row.id.clone(), async move {
            if let Err(e) = me.merge(&f, &job2, &tid).await {
                tracing::warn!("plan run {job2}: merge of {tid}: {}", e.message);
            }
            f.core.runs.set_busy(&tid, None);
            changed(&f, &job2).await;
        });
        Ok(())
    }

    /// The gate, then the merge: accepted files at their current diffs (the reviewer's pass, unless the job's gate is
    /// `review+accept`: then the user's marks), `Gate::Ask` waits for its card and, answered yes, clears the branch,
    /// then `merge --no-ff` of exactly the tip checked.  Done, a conflict card, or a failure card.
    async fn merge(&self, front: &Arc<Front>, job: &str, tid: &str) -> Result<(), Error> {
        let Some(l) = load(front, job, false).await? else {
            return Ok(());
        };
        let Some(t) = l.tasks.iter().find(|t| t.row.id == tid) else {
            return Ok(());
        };
        if l.job.status.as_deref() != Some("running")
            || t.row.status.as_deref() != Some("in-review")
        {
            return Ok(());
        }
        let data = data_of(&l.job);
        let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
        let git = front.core.runs.git();
        let tree = self.tree_of(front, &repo, job, t, &data).await?;
        let job_tree = job_tree(&repo, job, &tree).await?;
        if tick::git(
            &job_tree,
            &["merge-base", "--is-ancestor", &tree.branch, "HEAD"],
        )
        .await
        .is_ok()
        {
            return self.merged(front, job, t).await;
        }
        git.prepare(&tree).await.map_err(git_error)?;
        // the card a CI or build change waits on: answered yes, the branch is cleared
        let waiting = self.st().gates.get(tid).copied();
        let answer = match waiting {
            Some(card) => {
                let (m, at) = (front.core.matrix.clone(), now());
                match front
                    .writer
                    .db
                    .read(move |c| Ok(m.recheck(c, card, at)))
                    .await
                    .map_err(fail)?
                {
                    Gate::Allow => {
                        self.st().gates.remove(tid);
                        git.clear_gate(&tree.branch);
                        Gate::Allow
                    }
                    Gate::Never(why) => {
                        self.st().gates.remove(tid);
                        Gate::Never(why)
                    }
                    ask @ Gate::Ask(_) => ask,
                }
            }
            None => {
                if data.get("gate").and_then(Value::as_str) != Some("review+accept") {
                    self.accept_all(front, &repo, &tree, t).await?;
                }
                git.merge_gate(&repo, &tree).await.map_err(git_error)?
            }
        };
        match answer {
            Gate::Ask(card) => {
                self.st().gates.insert(tid.to_owned(), card);
                Ok(())
            }
            // the user accepts file by file: not all accepted yet is waiting, not a failure
            Gate::Never(why) if why.contains("files accepted") => Ok(()),
            Gate::Never(why) => raise_card(
                front,
                &service(),
                job,
                Some(tid),
                "review",
                &format!("the merge was refused: {why}"),
                json!({}),
            )
            .await
            .map(|_| ()),
            Gate::Allow => {
                front.core.runs.set_busy(tid, Some("merging"));
                changed(front, job).await;
                match git.merge_into(&job_tree, &tree).await {
                    Ok(super::git::MergeOutcome::Merged) => self.merged(front, job, t).await,
                    Ok(super::git::MergeOutcome::Conflict(files)) => {
                        let names: Vec<_> = files.iter().map(|f| f.display().to_string()).collect();
                        raise_card(
                            front,
                            &service(),
                            job,
                            Some(tid),
                            "merge-conflict",
                            &format!("merging into job/{job} conflicts in: {}", names.join(", ")),
                            json!({}),
                        )
                        .await
                        .map(|_| ())
                    }
                    Err(e) => {
                        // no conflict (a lock another git held, a hook): once more, then the user
                        let tries = count(&data, "merge-tries", tid) + 1;
                        if tries < 2 {
                            set_count(front, job, "merge-tries", tid, Some(tries)).await
                        } else {
                            set_count(front, job, "merge-tries", tid, None).await?;
                            raise_card(
                                front,
                                &service(),
                                job,
                                Some(tid),
                                "merge-failed",
                                &format!("merge failed: {}", e.stderr),
                                json!({}),
                            )
                            .await
                            .map(|_| ())
                        }
                    }
                }
            }
        }
    }

    /// The reviewer's pass accepts every file of T at the diff it has now (the gate checks the marks against it).
    async fn accept_all(
        &self,
        front: &Arc<Front>,
        repo: &Path,
        tree: &TaskTree,
        t: &Task,
    ) -> Result<(), Error> {
        let Some(agent) = t.row.agent.clone() else {
            return Err(internal(format!(
                "task {} has no agent to accept for",
                t.row.id
            )));
        };
        let files = front
            .core
            .runs
            .git()
            .diffs(repo, tree)
            .await
            .map_err(git_error)?;
        front
            .writer
            .write(&service(), "job/review-mark", move |tx| {
                for (path, f) in &files {
                    review_mark(tx, &agent, path, "accepted", &f.hash, now(), None)?;
                }
                Ok(())
            })
            .await
            .map_err(fail)
    }

    /// T's branch is in the job's: done, and its dependents may start.
    async fn merged(&self, front: &Arc<Front>, job: &str, t: &Task) -> Result<(), Error> {
        let tid = t.row.id.as_str();
        set_status(front, tid, "done", t.row.agent.clone()).await?;
        let t2 = tid.to_owned();
        update_data(front, &service(), job, move |d| {
            put_in(d, "passed", &t2, None);
            put_in(d, "merge-tries", &t2, None);
        })
        .await?;
        if let Some(a) = &t.row.agent {
            front.core.runs.session_finished(front, a);
        }
        self.st().gates.remove(tid);
        add_event(
            front,
            job,
            tid,
            t.row.agent.clone(),
            EventKind::Status,
            format!("{tid} merged into job/{job}"),
            Some(json!({"status": "merged", "into": format!("job/{job}")})),
        )
        .await;
        front.core.runs.wake();
        Ok(())
    }

    // ---- clash reviewers ----------------------------------------------------------------------------------------

    /// Every open clash card of JOB without a recommendation has a reviewer (started at most twice); an answer is read
    /// onto its card.
    async fn clash_cards(&self, front: &Arc<Front>, job: &str, l: &Loaded) -> Result<(), Error> {
        for c in l
            .open_cards
            .iter()
            .filter(|c| c.kind.as_deref() == Some("clash"))
        {
            if self.busy(&format!("clash:{}", c.id)) {
                continue;
            }
            let d = c.data.clone().unwrap_or(Value::Null);
            let alive = d.get("reviewer").and_then(Value::as_str).and_then(|sid| {
                front
                    .core
                    .agents
                    .snapshots()
                    .into_iter()
                    .find(|s| s.id == sid && is_alive(s))
            });
            match alive {
                Some(s) => {
                    let n = s.entries_count.unwrap_or(0);
                    let seen = d.get("seen").and_then(Value::as_u64).unwrap_or(0);
                    if !is_free(&s) || n == seen {
                        continue;
                    }
                    let tr = front.core.agents.get(&s.id)?;
                    if fallback::ended(&tr) != Some(Ended::Stopped) {
                        continue;
                    }
                    let rec = recommendation(&said(&tr));
                    patch_card(front, c.id, move |m| {
                        m.insert("seen".into(), json!(n));
                        match &rec {
                            Some((side, why)) => {
                                m.insert(
                                    "recommendation".into(),
                                    json!({"side": side, "why": why}),
                                );
                                m.remove("no_recommendation");
                            }
                            None if m.contains_key("recommendation") => {}
                            None => {
                                m.insert("no_recommendation".into(), json!(true));
                            }
                        }
                    })
                    .await?;
                    changed(front, job).await;
                }
                None if d.get("recommendation").is_none_or(Value::is_null) => {
                    if d.get("starts").and_then(Value::as_i64).unwrap_or(0) < CLASH_STARTS {
                        self.start_clash(front, job, c.id);
                    } else if d.get("reviewer_gone").is_none() {
                        patch_card(front, c.id, |m| {
                            m.insert("reviewer_gone".into(), json!(true));
                        })
                        .await?;
                        changed(front, job).await;
                    }
                }
                None => {}
            }
        }
        Ok(())
    }

    /// A reviewer for clash card CARD, off the tick.
    fn start_clash(&self, front: &Arc<Front>, job: &str, card: i64) {
        let key = format!("clash:{card}");
        if self.busy(&key) {
            return;
        }
        let (f, job2) = (front.clone(), job.to_owned());
        self.spawn(key, async move {
            if let Err(e) = start_clash_reviewer(&f, &job2, card, None).await {
                tracing::warn!("plan run {job2}: clash reviewer: {}", e.message);
            }
        });
    }
}

/// The job's own tree, where its branch is checked out (made beside the task trees when absent).
async fn job_tree(repo: &Path, job: &str, tree: &TaskTree) -> Result<PathBuf, Error> {
    let path = tree.path.with_file_name("_job");
    if !path.exists() {
        let p = path.to_string_lossy().into_owned();
        tick::git(repo, &["worktree", "add", "-q", &p, &format!("job/{job}")])
            .await
            .map_err(git_error)?;
    }
    Ok(path)
}

/// Merge DATA into card ID's data.
async fn patch_card(
    front: &Front,
    id: i64,
    f: impl Fn(&mut Map<String, Value>) + std::marker::Send + Sync + 'static,
) -> Result<(), Error> {
    front
        .writer
        .write(&service(), "job/card", move |tx| {
            let Some(card) = norn::read::cards::card(tx.sql(), id)? else {
                return Ok(());
            };
            let mut data = match card.data {
                Some(Value::Object(m)) => m,
                _ => Map::new(),
            };
            f(&mut data);
            card_set(
                tx,
                id,
                CardSet {
                    title: None,
                    data: Some(Value::Object(data)),
                    state: None,
                },
                now(),
            )
        })
        .await
        .map_err(fail)
}

/// A reviewer for clash card CARD of JOB, in the job's tree: role `review-long` for a long clash when the settings
/// route it, else `review`.  ASKS: what the user wants to discuss.
async fn start_clash_reviewer(
    front: &Front,
    job: &str,
    card: i64,
    asks: Option<&str>,
) -> Result<(), Error> {
    let Some(l) = load(front, job, false).await? else {
        return Ok(());
    };
    let Some(c) = front
        .writer
        .db
        .read(move |c| norn::read::cards::card(c, card))
        .await
        .map_err(fail)?
    else {
        return Ok(());
    };
    let data = data_of(&l.job);
    let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
    let git = front.core.runs.git();
    // the job's tree sits beside the task trees: any started task shows where
    let Some(t) = l
        .tasks
        .iter()
        .find(|t| data_for(&data, "bases", &t.row.id).is_some())
    else {
        return Ok(());
    };
    let base = data_for(&data, "bases", &t.row.id)
        .and_then(Value::as_str)
        .unwrap_or_default();
    let tree = git
        .task_worktree(&repo, job, &t.row.n.to_string(), base)
        .await
        .map_err(git_error)?;
    let cwd = job_tree(&repo, job, &tree).await?;
    let d = c.data.clone().unwrap_or(Value::Null);
    let long = d.get("size").and_then(Value::as_str) == Some("long");
    let has_long = front
        .settings
        .current()
        .loaded
        .values
        .agents_routes
        .iter()
        .any(|r| r.role == "review-long");
    let role = if long && has_long {
        "review-long"
    } else {
        "review"
    };
    let profile = route(front, role)
        .into_iter()
        .next()
        .unwrap_or_else(|| "claude".into());
    let starts = d.get("starts").and_then(Value::as_i64).unwrap_or(0) + 1;
    let started = front
        .core
        .agents
        .start(
            front,
            StartParams {
                profile: Bounded(profile.clone()),
                cwd: AbsPath::new(cwd.to_string_lossy().into_owned()).ok(),
                task: None,
                job: Id::new(job).ok(),
                role: Some(Role::Worker),
                about: None,
                document: None,
            },
            &user(),
        )
        .await;
    let sid = match started {
        Ok(s) => s.id,
        Err(e) => {
            patch_card(front, card, move |m| {
                m.insert("starts".into(), json!(starts));
            })
            .await?;
            return Err(internal(format!(
                "no clash reviewer on {profile}: {}",
                e.message
            )));
        }
    };
    let sid2 = sid.clone();
    patch_card(front, card, move |m| {
        m.insert("starts".into(), json!(starts));
        m.insert("reviewer".into(), json!(sid2));
        m.remove("reviewer_gone");
    })
    .await?;
    front
        .core
        .agents
        .prompt(&sid, clash_prompt(&c, asks), Origin::Hub)?;
    changed(front, job).await;
    Ok(())
}

/// Clash card C as its reviewer reads it.
fn clash_prompt(c: &Card, asks: Option<&str>) -> String {
    let d = c.data.clone().unwrap_or(Value::Null);
    let sides = d
        .get("sides")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|s| {
                    let text = |k: &str| s.get(k).and_then(Value::as_str);
                    format!(
                        "{}: {}{}",
                        text("label").unwrap_or("?"),
                        text("text").unwrap_or(""),
                        text("reason")
                            .map(|r| format!("\nIts reason:\n{}", quote(r)))
                            .unwrap_or_default()
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    format!(
        "[drgnx clash {}] {}: {}\n\n{sides}{}\n\nRecommend one side. Answer with a last line RECOMMEND: A, \
         RECOMMEND: B, or RECOMMEND: neither: why.",
        c.id,
        d.get("rule").and_then(Value::as_str).unwrap_or(""),
        c.title.as_deref().unwrap_or(""),
        asks.map(|a| format!("\n\nThe user asks:\n{}", quote(a)))
            .unwrap_or_default()
    )
}

// ---- the user's answers: cards, replies, reassigning -----------------------------------------------------------

/// The actions of a card as names (`drgnx-job-card-actions`).
fn actions_of(kind: &str, data: &Value) -> Vec<String> {
    super::card_actions(kind, data)
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|p| p.get(0).and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// A task's live sessions end (its worker, its reviewer).
async fn end_task_sessions(front: &Front, job: &str, task: &str) {
    for s in front.core.agents.snapshots() {
        if s.job.as_deref() == Some(job) && s.task.as_deref() == Some(task) && is_alive(&s) {
            let _ = front.core.agents.kill(&s.id).await;
            front.core.runs.session_finished(front, &s.id);
        }
    }
}

/// TASK of JOB goes back to a new agent, its counts reset (NOTE: what it is told).
pub(crate) async fn retry(
    front: &Front,
    job: &str,
    task: &str,
    note: Option<String>,
) -> Result<(), Error> {
    let t = task.to_owned();
    update_data(front, &service(), job, move |d| {
        for bucket in [
            "fails",
            "exits",
            "nudged",
            "waiting",
            "passed",
            "review-restarts",
            "merge-tries",
        ] {
            put_in(d, bucket, &t, None);
        }
        put_in(d, "notes", &t, note.map(Value::String));
    })
    .await?;
    end_task_sessions(front, job, task).await;
    set_status(front, task, "ready", None).await?;
    front.core.runs.wake();
    Ok(())
}

fn arg_f64(arg: &Option<StringOrNumber>) -> Option<f64> {
    match arg {
        Some(StringOrNumber::Num(n)) => n.as_f64(),
        Some(StringOrNumber::Str(s)) => s.trim().parse().ok(),
        None => None,
    }
}

fn arg_text(arg: &Option<StringOrNumber>) -> String {
    match arg {
        Some(StringOrNumber::Num(n)) => n.to_string(),
        Some(StringOrNumber::Str(s)) => s.clone(),
        None => String::new(),
    }
}

/// The user's ACTION on a card: done once (a card acted on before refuses).  The job's summary.
pub async fn card_act(front: &Front, caller: &Caller, p: CardParams) -> Result<JobSummary, Error> {
    let cid = i64::try_from(p.card).map_err(|_| invalid("card"))?;
    let card = front
        .writer
        .db
        .read(move |c| norn::read::cards::card(c, cid))
        .await
        .map_err(fail)?
        .ok_or_else(|| invalid(format!("No card {cid}")))?;
    let job = card
        .job
        .clone()
        .ok_or_else(|| invalid(format!("Card {cid} is not a job's")))?;
    let action = p.action.as_str().to_owned();
    let kind = card.kind.clone().unwrap_or_default();
    let data = card.data.clone().unwrap_or(Value::Null);
    if !actions_of(&kind, &data).contains(&action) {
        return Err(invalid(format!("Card {cid} has no action {action}")));
    }
    if card.state.as_deref() != Some("open") {
        return Err(invalid(format!("Card {cid} is already settled")));
    }
    let l = load(front, &job, true)
        .await?
        .ok_or_else(|| invalid(format!("No job {job}")))?;
    let task = card.task.clone();
    if let Some(t) = &task
        && matches!(action.as_str(), "retry" | "drop" | "merge" | "accept")
        && l.tasks
            .iter()
            .any(|x| x.row.id == *t && matches!(x.row.status.as_deref(), Some("done" | "dropped")))
    {
        return Err(invalid(format!("Task {t} is finished already")));
    }
    // these show or ask: the card stays
    if matches!(action.as_str(), "open" | "edits") {
        return summary(front, &job, false).await;
    }
    if kind == "clash" && action == "discuss" {
        discuss(front, &job, &card, &arg_text(&p.arg)).await?;
        return summary(front, &job, false).await;
    }
    let settled = front
        .writer
        .write(caller, "cards/settle", {
            let action = action.clone();
            move |tx| card_settle(tx, cid, &action, now())
        })
        .await
        .map_err(fail)?;
    if !settled {
        return Err(invalid(format!("Card {cid} is already settled")));
    }
    if let Err(e) = act(front, caller, &l, &card, &action, &p.arg).await {
        // it did not happen: still the user's
        let _ = front
            .writer
            .write(caller, "cards/settle", move |tx| {
                card_set(
                    tx,
                    cid,
                    CardSet {
                        title: None,
                        data: None,
                        state: Some("open".into()),
                    },
                    now(),
                )
            })
            .await;
        return Err(e);
    }
    if let Some(m) = data.get("message").and_then(Value::as_i64) {
        let _ = front
            .writer
            .write(caller, "messages/mark", move |tx| {
                mark(tx, m, "acted", now())
            })
            .await;
    }
    front.core.runs.wake();
    changed(front, &job).await;
    summary(front, &job, false).await
}

async fn act(
    front: &Front,
    caller: &Caller,
    l: &Loaded,
    card: &Card,
    action: &str,
    arg: &Option<StringOrNumber>,
) -> Result<(), Error> {
    let job = l.job.id.as_str();
    let kind = card.kind.as_deref().unwrap_or("");
    let task = card.task.as_deref();
    let need_task = || task.ok_or_else(|| invalid("This card is about no task"));
    let agent_of = |t: &str| {
        l.tasks
            .iter()
            .find(|x| x.row.id == t)
            .and_then(|x| x.row.agent.clone())
    };
    match action {
        "approve" => super::approve_job(front, caller, job, arg_f64(arg)).await,
        "reject" if matches!(kind, "permission" | "write") => Err(invalid(
            "A permission is answered with the agent's request, not here",
        )),
        "allow" => Err(invalid(
            "A permission is answered with the agent's request, not here",
        )),
        "reject" | "stop" => {
            let p =
                serde_json::from_value(json!({"id": job})).map_err(|e| invalid(e.to_string()))?;
            super::stop(front, caller, p).await.map(|_| ())
        }
        "retry" => {
            let note = (kind == "merge-conflict").then(|| {
                format!(
                    "Merging your branch into job/{job} conflicted ({}). Merge job/{job} into your branch, resolve \
                     the conflicts, commit, then call complete_task.",
                    card.title.as_deref().unwrap_or("")
                )
            });
            retry(front, job, need_task()?, note).await
        }
        // merge as it is: the tick merges it (the reviewer's pass counts)
        "merge" | "accept" if kind != "clash" => {
            let tid = need_task()?;
            let t2 = tid.to_owned();
            update_data(front, &service(), job, move |d| {
                put_in(d, "passed", &t2, Some(json!(true)));
            })
            .await?;
            end_task_sessions(front, job, tid).await;
            set_status(front, tid, "in-review", agent_of(tid)).await
        }
        // as if its turn had ended
        "review" => {
            let tid = need_task()?;
            end_task_sessions(front, job, tid).await;
            set_status(front, tid, "in-review", agent_of(tid)).await
        }
        "drop" => {
            let tid = need_task()?;
            end_task_sessions(front, job, tid).await;
            set_status(front, tid, "dropped", None).await
        }
        "resume" => {
            let p = serde_json::from_value(json!({"id": job, "budget": arg_f64(arg)}))
                .map_err(|e| invalid(e.to_string()))?;
            fallback::resume(front, caller, p).await.map(|_| ())
        }
        "accept" | "pick-a" | "pick-b" => {
            let side = match action {
                "pick-a" => "A".to_owned(),
                "pick-b" => "B".to_owned(),
                _ => card
                    .data
                    .as_ref()
                    .and_then(|d| d.pointer("/recommendation/side"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| invalid("The reviewer has not recommended a side"))?,
            };
            settle_clash(front, l, card, &side).await
        }
        _ => Ok(()),
    }
}

/// The user chose SIDE (`A` or `B`) of clash CARD: a decision of the user's, which every agent of the job hears; its
/// reviewer ends (`drgnx-job-clash--settle`).
async fn settle_clash(front: &Front, l: &Loaded, card: &Card, side: &str) -> Result<(), Error> {
    let job = l.job.id.as_str();
    let d = card.data.clone().unwrap_or(Value::Null);
    let sides = d
        .get("sides")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let label = |s: &Value| s.get("label").and_then(Value::as_str).map(str::to_owned);
    let other = sides.iter().find(|s| label(s).as_deref() != Some(side));
    let first = sides.first();
    let decision_of = |s: Option<&Value>| s.and_then(|s| s.get("decision")).and_then(Value::as_i64);
    let subject = d
        .get("subject")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let user_decision = |kind: &str, subject: String, replaces: Option<i64>, reason: &str| Decide {
        kind: kind.to_owned(),
        subject,
        task: None,
        paths: None,
        reason: Some(reason.to_owned()),
        author: "user".into(),
        seen: None,
        replaces,
        job: Some(job.to_owned()),
    };
    let mut decisions = Vec::new();
    match d.get("rule").and_then(Value::as_str) {
        Some("contradiction") => decisions.push(user_decision(
            "replaces",
            subject,
            decision_of(other),
            &format!("the user chose {side}"),
        )),
        Some("proposed") => {
            if let Some(p) = l.decisions.iter().find(|x| Some(x.n) == decision_of(first)) {
                if side == "A" {
                    let mut x = user_decision(
                        p.kind.as_deref().unwrap_or("build"),
                        p.subject.clone().unwrap_or_default(),
                        Some(p.n),
                        "the user recorded it",
                    );
                    x.task = p.task.clone();
                    x.paths = p.paths.clone();
                    decisions.push(x);
                } else {
                    decisions.push(user_decision(
                        "replaces",
                        p.subject.clone().unwrap_or_default(),
                        Some(p.n),
                        "the user left it out",
                    ));
                }
            }
        }
        Some("against-decision") => {
            if side == "A" {
                let files: Vec<&str> = d
                    .get("files")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).collect())
                    .unwrap_or_default();
                if let Some(t) = card.task.as_deref() {
                    let note = format!(
                        "Your branch changes what decision #{} says will not be built ({subject}): revert your \
                         changes to {}, commit, then call complete_task.",
                        decision_of(first).unwrap_or(0),
                        files.join(", ")
                    );
                    retry(front, job, t, Some(note)).await?;
                }
            } else {
                decisions.push(user_decision(
                    "replaces",
                    subject,
                    decision_of(first),
                    "the user let the change stand",
                ));
            }
        }
        _ => {}
    }
    for x in decisions {
        front
            .writer
            .write(&user(), "decisions/decide", move |tx| {
                decide(tx, x.clone(), now()).map(|_| ())
            })
            .await
            .map_err(fail)?;
    }
    if let Some(sid) = d.get("reviewer").and_then(Value::as_str) {
        let _ = front.core.agents.kill(sid).await;
    }
    Ok(())
}

/// The user discusses clash CARD: the reviewer is asked (or a new one starts with the question).
async fn discuss(front: &Front, job: &str, card: &Card, asks: &str) -> Result<(), Error> {
    let alive = card
        .data
        .as_ref()
        .and_then(|d| d.get("reviewer"))
        .and_then(Value::as_str)
        .filter(|sid| {
            front
                .core
                .agents
                .snapshots()
                .iter()
                .any(|s| s.id == *sid && is_alive(s))
        });
    match alive {
        Some(sid) => front.core.agents.prompt(
            sid,
            format!("The user asks:\n{}", quote(asks)),
            Origin::User,
        ),
        None => start_clash_reviewer(front, job, card.id, Some(asks)).await,
    }
}

/// `job/reply`: the user answers message MID (from an agent) with TEXT; MID is acted on.
pub async fn reply(front: &Front, caller: &Caller, p: ReplyParams) -> Result<bool, Error> {
    let mid = i64::try_from(p.message).map_err(|_| invalid("message"))?;
    let m = front
        .writer
        .db
        .read(move |c| norn::read::messages::message(c, mid))
        .await
        .map_err(fail)?
        .ok_or_else(|| invalid(format!("No message {mid}")))?;
    let s = Send {
        job: m.job.clone(),
        sender: Some("user".into()),
        recipient: m.sender.clone().unwrap_or_default(),
        text: p.text.as_str().to_owned(),
        seen: None,
        answers: Some(mid),
        question: false,
    };
    front
        .writer
        .write(caller, "messages/send", move |tx| {
            send(tx, s.clone(), now())?;
            mark(tx, mid, "acted", now())
        })
        .await
        .map_err(fail)?;
    if let Some(j) = &m.job {
        changed(front, j).await;
    }
    Ok(true)
}

/// `job/dismiss`: the user dismisses message MID - a job's message to the user that needs no answer.
pub async fn dismiss(front: &Front, caller: &Caller, p: ByMessage) -> Result<bool, Error> {
    let mid = i64::try_from(p.message).map_err(|_| invalid("message"))?;
    let m = front
        .writer
        .db
        .read(move |c| norn::read::messages::message(c, mid))
        .await
        .map_err(fail)?
        .ok_or_else(|| invalid(format!("No message {mid}")))?;
    if m.recipient.as_deref() != Some("user") || m.job.is_none() {
        return Err(invalid("Not a message of a job to the user"));
    }
    front
        .writer
        .write(caller, "messages/mark", move |tx| {
            mark(tx, mid, "acted", now())
        })
        .await
        .map_err(fail)?;
    if let Some(j) = &m.job {
        changed(front, j).await;
    }
    Ok(true)
}

/// `job/reassign`: task TASK goes to an agent of PROFILE from now on; one working on it now (or a card it waits on)
/// ends and the task is ready for a new agent.  A task in review is refused: its reviewer would answer about the
/// next agent's work.
pub async fn reassign(
    front: &Front,
    caller: &Caller,
    p: ReassignParams,
) -> Result<JobSummary, Error> {
    let tid = p.task.as_str().to_owned();
    let (job, task) = super::open_task(front, &tid, true).await?;
    if let Some(what) = front.core.runs.busy_of(&tid) {
        return Err(invalid(format!(
            "Task {tid} is {what}: try again in a moment"
        )));
    }
    let status = task.row.status.clone().unwrap_or_default();
    if status == "in-review" {
        return Err(invalid(format!(
            "Task {tid} is in review: reassign it once its review is over (from its card, or here)"
        )));
    }
    let profile = p.profile.as_str().to_owned();
    let (t2, p2) = (tid.clone(), profile.clone());
    update_data(front, caller, &job, move |d| {
        put_in(d, "profiles", &t2, Some(json!(p2)));
    })
    .await?;
    if !matches!(status.as_str(), "pending" | "ready") {
        settle_cards(front, caller, &job, |c| {
            (c.task.as_deref() == Some(tid.as_str())
                && !matches!(c.kind.as_deref(), Some("proposal" | "overlap" | "clash")))
            .then_some("reassign")
        })
        .await?;
        retry(front, &job, &tid, None).await?;
    }
    changed(front, &job).await;
    summary(front, &job, false).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_line_is_the_verdict() {
        assert_eq!(verdict("Looks fine.\nVERDICT: pass"), Some(Verdict::Pass));
        assert_eq!(verdict("VERDICT: pass\n\n"), Some(Verdict::Pass));
        assert_eq!(verdict("**VERDICT: pass**"), Some(Verdict::Pass));
        assert_eq!(verdict("> `VERDICT: PASS`"), None);
        assert_eq!(
            verdict("no\n**VERDICT: fail: add a test**"),
            Some(Verdict::Fail("add a test".into()))
        );
        assert_eq!(verdict("VERDICT: fail"), Some(Verdict::Fail(String::new())));
        // only the last line counts, and it must be the verdict
        assert_eq!(verdict("VERDICT: pass\nbut see the notes"), None);
        assert_eq!(verdict("Answer with a last line VERDICT: pass"), None);
        assert_eq!(verdict(""), None);
    }

    #[test]
    fn a_clash_reviewers_recommendation_is_read() {
        assert_eq!(
            recommendation("thinking\nRECOMMEND: A: it was decided"),
            Some((Some("A".into()), "it was decided".into()))
        );
        assert_eq!(
            recommendation("RECOMMEND: B, simpler"),
            Some((Some("B".into()), "simpler".into()))
        );
        assert_eq!(
            recommendation("RECOMMEND: neither: ask the user"),
            Some((None, "ask the user".into()))
        );
        assert_eq!(recommendation("I recommend A"), None);
    }
}
