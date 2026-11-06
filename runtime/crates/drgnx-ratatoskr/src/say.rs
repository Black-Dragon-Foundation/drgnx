//! Say it (docs/develop/hub.md, "Say it"): one prompt becomes a proposed plan.
//!
//! `say/start` starts a planning chat in a scratch folder of its own: no repository, no graph, only a digest of the
//! profiles, routes and roles (this keeps repository and graph text, the injection surface, out of the session that
//! shapes the plan).  The chat answers with one fenced `drgnx-proposal` block; the hub parses it ([`parse`]: a key the
//! format does not have is refused, so a block carries no grants, approval or repository), checks it ([`check`]) and
//! writes the plan and proposes the job as the user would, with the repository `say/start` named.  The job then waits
//! for the user's OK like any proposal (its card's title is the hub's), unless the Autonomous preset's cells hold all
//! of it ([`rule`]): then it starts, and a decision says so.  A block that does not hold is answered with
//! the reasons, twice at most; a turn with no block is a question for the user (`say-message`).
//!
//! The order of one planning session is a pure core ([`SayCore`]): turn ends, the user's revisions, a stop and an end
//! arrive in any order, and at most one prompt is ever in flight.  [`run`] is its shell.  Say's state is memory only:
//! after a restart the planning is gone (`say/revise` says so), and a proposal it made is a job, which stays.

use crate::agents::Origin;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::runner::plan::{self, PlanTask};
use crate::settings::AgentProfile;
use norn::matrix::Who;
use norn::store::{CoordError, Tx};
use runstav::methods::agents::{ById, StartParams};
use runstav::methods::forecast::{Forecast, PaceWindow};
use runstav::methods::jobs::{MergeGate, PlanRef};
use runstav::methods::matrix::{Action, Limit, Preset, Role, Unit, Verdict};
use runstav::methods::plans::WriteParams;
use runstav::methods::say::{SayById, SayRevise, SayStart, SayStarted};
use runstav::wire::Error;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::sync::mpsc;

/// The fence a proposal comes in.
const FENCE: &str = "```drgnx-proposal";
/// The most tasks a proposal may have.
pub const MAX_TASKS: usize = 32;
/// A task's body is its brief: at most this many bytes.
pub const BODY_MAX: usize = 16_384;
/// The longest title a plan or a task may have.
const TITLE_MAX: usize = 512;
/// The roles a proposal's task may have: a job's, never a manager's or a chat's.
pub const ROLES: [&str; 5] = ["implement", "test", "docs", "review", "review-long"];
/// How many times a block that does not hold is answered with its reasons before the planning fails.
pub const RETRIES: u32 = 2;

/// The planning session's instructions, before the digest and the user's words.  The block is the one form a proposal
/// takes.
const INSTRUCTIONS: &str = "You plan work for drgnx; you do not do it, and you have no repository and no tools for \
it. Answer with the plan as one fenced block in exactly this form:

```drgnx-proposal
{\"title\": \"...\", \"tasks\": [{\"n\": 1, \"title\": \"...\", \"role\": \"review\", \"profile\": \"opus\", \"deps\": [], \"body\": \"...\"}],
 \"budget\": [{\"amount\": 20, \"unit\": \"usd\"}], \"gate\": \"review\"}
```

Each task's body is its brief: what to do and how to check it (at most 16 KiB). deps lists the numbers of the tasks it \
waits on. profile is optional: with none, the role's route runs it. budget is in usd or usd-est; gate is review or \
review+accept. No other keys: the repository, the grants and the approval are not yours to give. Nothing starts until \
the user approves. If you need to know more first, ask one question instead, with no block.";

// ---- the block ----------------------------------------------------------------------------------------------------

/// A proposal as the planning session drew it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Drawn {
    pub title: String,
    pub tasks: Vec<DrawnTask>,
    #[serde(default)]
    pub budget: Vec<Limit>,
    #[serde(default)]
    pub gate: Option<MergeGate>,
}

/// One task of a proposal.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DrawnTask {
    pub n: i64,
    pub title: String,
    pub role: String,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub deps: Vec<i64>,
    pub body: String,
}

/// The `drgnx-proposal` block of MESSAGE: none when there is no block (a question); an error when the block is not a
/// proposal, or there is more than one (which the agent meant is not guessed).
pub fn parse(message: &str) -> Option<Result<Drawn, String>> {
    let blocks = message.matches(FENCE).count();
    if blocks == 0 {
        return None;
    }
    if blocks > 1 {
        return Some(Err(format!("one drgnx-proposal block, not {blocks}")));
    }
    let start = message.find(FENCE)? + FENCE.len();
    let rest = &message[start..];
    let body = rest.split("```").next().unwrap_or(rest);
    Some(
        serde_json::from_str::<Drawn>(body.trim())
            .map_err(|e| format!("the drgnx-proposal block is not a proposal: {e}")),
    )
}

/// The tasks of D as a plan's, for `plan::check`.
fn tasks_of(d: &Drawn) -> Vec<PlanTask> {
    d.tasks
        .iter()
        .map(|t| PlanTask {
            n: t.n,
            title: t.title.clone(),
            role: t.role.clone(),
            deps: t.deps.clone(),
            body: t.body.clone(),
            profile: t.profile.clone(),
            model: None,
        })
        .collect()
}

/// Every problem of D, the profiles found by FIND: a title, 1 to 32 tasks, each with a job role, a profile a job may
/// run on, a body within the brief's cap, dependencies that are there and go round in no cycle; a budget of positive
/// dollars, exact or estimated.
pub fn check_in(d: &Drawn, find: impl Fn(&str) -> Option<AgentProfile>) -> Result<(), Vec<String>> {
    let mut bad: Vec<String> = Vec::new();
    let title = |s: &str| !s.trim().is_empty() && s.chars().count() <= TITLE_MAX;
    if !title(&d.title) {
        bad.push(format!(
            "the plan needs a title of 1 to {TITLE_MAX} characters"
        ));
    }
    if d.tasks.is_empty() {
        bad.push("the plan has no tasks".into());
    }
    if d.tasks.len() > MAX_TASKS {
        bad.push(format!(
            "{} tasks: a plan has at most {MAX_TASKS}",
            d.tasks.len()
        ));
    }
    for t in &d.tasks {
        let n = t.n;
        if n < 1 {
            bad.push(format!("task {n}: a task's number is 1 or more"));
        }
        if !title(&t.title) {
            bad.push(format!("task {n}: a title of 1 to {TITLE_MAX} characters"));
        }
        if !ROLES.contains(&t.role.as_str()) {
            bad.push(format!(
                "task {n}: no role {:?} (implement, test, docs, review, review-long)",
                t.role
            ));
        }
        if let Some(p) = &t.profile
            && let Some(why) = crate::runner::review::profile_refusal(p, find(p).as_ref())
        {
            bad.push(format!("task {n}: {why}"));
        }
        if t.body.len() > BODY_MAX {
            bad.push(format!(
                "task {n}: its body is {} bytes, over the brief's {BODY_MAX}",
                t.body.len()
            ));
        }
    }
    if let Err(e) = plan::check(&tasks_of(d)) {
        bad.push(e);
    }
    for l in &d.budget {
        if !(l.amount.is_finite() && l.amount > 0.0) {
            bad.push(format!("a budget is a positive amount, not {}", l.amount));
        }
        if !matches!(l.unit, Unit::Usd | Unit::UsdEst) {
            bad.push(format!(
                "a plan's budget is in usd or usd-est, not {}",
                json!(l.unit)
            ));
        }
    }
    if bad.is_empty() { Ok(()) } else { Err(bad) }
}

/// [`check_in`] with the hub's profiles.
pub fn check(front: &Front, d: &Drawn) -> Result<(), Vec<String>> {
    check_in(d, |name| crate::agents::session::find_profile(front, name))
}

/// What the planning session is told of drgnx: the profiles a task may name, each role's route, the roles and the
/// project's id.  Settings only: nothing of the graph (no plan's title, no task's text) and no repository.
pub fn digest(front: &Front, project: Option<&str>) -> String {
    let cur = front.settings.current();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut out = String::from("Profiles a task may name (name: provider, model):\n");
    for p in cur
        .loaded
        .values
        .agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
    {
        if !seen.insert(p.name.as_str())
            || crate::runner::review::profile_refusal(&p.name, Some(p)).is_some()
        {
            continue;
        }
        let provider = p.provider().map_or_else(
            || "another CLI".to_owned(),
            |v| json!(v).as_str().unwrap_or("").to_owned(),
        );
        out.push_str(&format!(
            "- {}: {provider}{}, {}\n",
            p.name,
            if p.ai.is_some() {
                " through the gateway"
            } else {
                ""
            },
            p.model.as_deref().unwrap_or("its default model")
        ));
    }
    out.push_str("Routes (a task that names no profile runs on its role's first):\n");
    for role in ROLES {
        out.push_str(&format!(
            "- {role}: {}\n",
            crate::runner::route(front, role).join(", ")
        ));
    }
    out.push_str(&format!("Roles: {}.\n", ROLES.join(", ")));
    out.push_str(&format!("Project: {}.\n", project.unwrap_or("none named")));
    out
}

/// The first prompt: the instructions, the digest and the user's words.
fn planning_prompt(digest: &str, text: &str) -> String {
    format!("{INSTRUCTIONS}\n\n{digest}\nThe user's request:\n{text}")
}

/// The answer to a block that does not hold.
fn reprompt(why: &[String]) -> String {
    let mut s = String::from("Your drgnx-proposal block was refused:\n");
    for w in why {
        s.push_str(&format!("- {w}\n"));
    }
    s.push_str(
        "Answer again with one corrected drgnx-proposal block, or ask a question with no block.",
    );
    s
}

/// The planning session's start: a chat on PROFILE in its own scratch folder (no `cwd`), with no task, job, topic or
/// document.
pub(crate) fn start_params(profile: &str) -> StartParams {
    serde_json::from_value(json!({"profile": profile, "role": "chat"}))
        .expect("a profile name and a role are start params")
}

/// The planning session SID's own use, numbers only: its tokens and what its steps cost, by unit.  Shown on the
/// proposal, never budgeted.
pub(crate) fn planning_of(conn: &Tx, sid: &str) -> Result<Value, CoordError> {
    let (tokens, usd_est, usd): (i64, Option<f64>, Option<f64>) = conn.query_row(
        "select coalesce(sum(tokens_in + tokens_out + cache_read + cache_write), 0), \
         sum(case when cost_unit = 'usd-est' then cost end), sum(case when cost_unit = 'usd' then cost end) \
         from step where session = ?1 or session = ?2",
        (sid, format!("session:{sid}")),
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let mut m = Map::new();
    m.insert("tokens".into(), json!(tokens));
    if let Some(c) = usd_est {
        m.insert("usd_est".into(), json!(c));
    }
    if let Some(c) = usd {
        m.insert("usd".into(), json!(c));
    }
    Ok(Value::Object(m))
}

// ---- the Autonomous rule ------------------------------------------------------------------------------------------

/// Whether a proposal of TASKS tasks with forecast F starts without the user's OK, under G's matrix now, about CTX's
/// project and plan; else why it waits, the first that fails of:
/// 1. the preset is Autonomous;
/// 2. the manager's `agents.start` cell allows TASKS agents;
/// 3. its `spend` cell allows the plan's p90 in `usd` plus its p90 in `usd-est`, an estimate counted as dollars;
/// 4. nothing is unpriced;
/// 5. no week's meter would run out at the plan's p90 before it resets, and each provider in SUBSCRIPTIONS (a task's
///    subscription) has a pace: without one the week cannot be checked.
///
/// Nothing the user or the planning chat wrote is an input.
pub(crate) fn rule(
    g: &crate::matrix_gate::MatrixGate,
    conn: &Tx,
    f: &Forecast,
    tasks: usize,
    subscriptions: &[String],
    ctx: &crate::matrix_gate::ActionCtx,
    now: f64,
) -> Result<(), String> {
    let preset = g.active_preset(now);
    if preset != Preset::Autonomous {
        return Err(format!(
            "the matrix preset is {}, not autonomous",
            format!("{preset:?}").to_lowercase()
        ));
    }
    let manager = Who {
        role: Some(Role::Manager),
        ..Who::default()
    };
    let cell = |a: Action, amount: f64| {
        let ctx = crate::matrix_gate::ActionCtx {
            amount: Some(amount),
            ..ctx.clone()
        };
        g.dry(conn, &manager, a, &ctx, now)
    };
    let agents = cell(
        Action::AgentsStart,
        f64::from(u32::try_from(tasks).unwrap_or(u32::MAX)),
    );
    if agents.verdict != Verdict::Allow {
        return Err(format!(
            "{tasks} agents: {}",
            agents.why.unwrap_or_default()
        ));
    }
    let spend: f64 = f
        .cost
        .iter()
        .filter(|c| matches!(c.unit, Unit::Usd | Unit::UsdEst))
        .map(|c| c.p90)
        .sum();
    let s = cell(Action::Spend, spend);
    if s.verdict != Verdict::Allow {
        return Err(format!(
            "a spend of ${spend:.2} at p90: {}",
            s.why.unwrap_or_default()
        ));
    }
    if !f.unpriced.is_empty() {
        return Err(format!("no price for {}", f.unpriced.join(", ")));
    }
    if let Some(p) = f
        .pace
        .iter()
        .find(|p| p.window == PaceWindow::Week && p.runs_out_p90)
    {
        return Err(format!(
            "the {} week: the plan's p90 would use it up before it resets",
            p.provider
        ));
    }
    if let Some(s) = subscriptions.iter().find(|s| {
        !f.pace
            .iter()
            .any(|p| &p.provider == *s && p.added_share.is_some())
    }) {
        return Err(format!("{s}: no pace yet, so its week cannot be checked"));
    }
    Ok(())
}

/// The subscriptions F's tasks run on: each task's provider whose profile has no API key.
fn subscriptions(front: &Front, f: &Forecast) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for t in &f.tasks {
        if let Some(p) = &t.provider
            && crate::agents::session::find_profile(front, &t.profile)
                .is_some_and(|p| p.ai.is_none())
            && !out.contains(p)
        {
            out.push(p.clone());
        }
    }
    out
}

/// [`rule`] for a proposal of TASKS tasks with forecast F about CTX, under the matrix the settings hold now.
pub(crate) async fn may_start_alone(
    front: &Front,
    f: &Forecast,
    tasks: usize,
    ctx: crate::matrix_gate::ActionCtx,
) -> Result<(), String> {
    front.core.matrix.refresh(front);
    let subs = subscriptions(front, f);
    let (g, f, now) = (
        front.core.matrix.clone(),
        f.clone(),
        crate::clock::wall_secs(),
    );
    front
        .writer
        .db
        .read(move |c| Ok(rule(&g, c, &f, tasks, &subs, &ctx, now)))
        .await
        .unwrap_or_else(|e| Err(format!("the store: {e:?}")))
}

// ---- the order of one planning session, pure ----------------------------------------------------------------------

/// What a check of a turn's message found.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Checked {
    /// No block: the agent asks the user something.
    NoBlock(String),
    /// A block that does not hold, and why.
    Bad(Vec<String>),
    Good,
}

/// What reaches a planning session's core: the agent's turn ends and the shell's answers to its effects, the user's
/// revision, a stop (the planning session stopped by the user) and an end (`say/end`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum SayEvent {
    TurnEnded {
        message: String,
    },
    Checked(Checked),
    /// The proposal made, and whether it started at once (the Autonomous preset's cells held it).
    Proposed {
        job: Result<String, String>,
        started: bool,
    },
    /// The answer to [`SayEffect::Withdraw`]: the job had started (the user approved it), so it was not withdrawn.
    Withdrawn {
        started: bool,
    },
    Revise {
        text: String,
    },
    Stop,
    End,
}

/// What the core asks its shell to do.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum SayEffect {
    /// Check the turn's message (answered by [`SayEvent::Checked`]).
    Parse(String),
    /// Prompt the planning session.
    Prompt(String),
    /// The agent's question to the user (`say-message`).
    Ask(String),
    /// Stop that proposal, if it is still one.
    StopJob(String),
    /// Stop that proposal for a revision, if it is still one (answered by [`SayEvent::Withdrawn`]).
    Withdraw(String),
    /// That job started: the planning is done, and a revision is refused with its id.
    Started(String),
    /// Write the plan and propose the job (answered by [`SayEvent::Proposed`]).
    Propose,
    /// The planning failed (`say-failed`).
    Fail(Vec<String>),
    /// Stop the planning session and forget it.
    Forget,
}

/// One planning session's order: at most one prompt in flight; a revision that comes while a prompt, a check or a
/// proposal is under way waits for it and replaces what it would have done; after a stop nothing is prompted or
/// proposed and no proposal of it stands; the session is forgotten once.  A say has at most one live job: once its
/// proposal has started (approved by the user, or by the Autonomous preset), the planning is done, and a revision is
/// refused rather than proposing a second job beside it (a revision never stops running work).
#[derive(Debug, Default)]
pub(crate) struct SayCore {
    /// A prompt sent whose turn has not ended.
    in_flight: bool,
    checking: bool,
    proposing: bool,
    /// The standing proposal is being withdrawn for the pending revision.
    withdrawing: bool,
    /// The user's revision, waiting for what is under way.
    pending: Option<String>,
    /// The proposal standing now.
    job: Option<String>,
    /// Blocks refused since the last good one.
    tries: u32,
    /// The user stopped the planning: a proposal that lands after it is stopped too.
    stopped: bool,
    /// It failed or was ended: a proposal that lands after an end stays (it is a job).
    ended: bool,
}

impl SayCore {
    /// A planning session whose first prompt is TEXT.
    pub(crate) fn start(text: String) -> (SayCore, Vec<SayEffect>) {
        let mut core = SayCore::default();
        let fx = core.prompt(text);
        (core, vec![fx])
    }

    /// Stopped, failed or ended: nothing more is prompted or proposed.
    pub(crate) fn ended(&self) -> bool {
        self.stopped || self.ended
    }

    fn busy(&self) -> bool {
        self.in_flight || self.checking || self.proposing || self.withdrawing
    }

    fn prompt(&mut self, text: String) -> SayEffect {
        self.in_flight = true;
        SayEffect::Prompt(text)
    }

    /// Job J started: the planning is done; a revision waiting for it is refused.
    fn started(&mut self, j: String) -> Vec<SayEffect> {
        self.ended = true;
        let mut fx = vec![SayEffect::Started(j.clone())];
        if self.pending.take().is_some() {
            fx.push(SayEffect::Fail(vec![started_why(&j)]));
        }
        self.job = Some(j);
        fx.push(SayEffect::Forget);
        fx
    }

    pub(crate) fn step(&mut self, ev: SayEvent) -> Vec<SayEffect> {
        use SayEffect as F;
        match ev {
            SayEvent::TurnEnded { message } => {
                if !self.in_flight {
                    return Vec::new();
                }
                self.in_flight = false;
                if self.ended() {
                    return Vec::new();
                }
                // the turn answered what the revision replaces
                if let Some(t) = self.pending.take() {
                    return vec![self.prompt(t)];
                }
                self.checking = true;
                vec![F::Parse(message)]
            }
            SayEvent::Checked(c) => {
                if !self.checking {
                    return Vec::new();
                }
                self.checking = false;
                if self.ended() {
                    return Vec::new();
                }
                if let Some(t) = self.pending.take() {
                    return vec![self.prompt(t)];
                }
                match c {
                    Checked::NoBlock(m) => vec![F::Ask(m)],
                    Checked::Bad(why) => {
                        self.tries += 1;
                        if self.tries <= RETRIES {
                            vec![self.prompt(reprompt(&why))]
                        } else {
                            self.ended = true;
                            vec![F::Fail(why), F::Forget]
                        }
                    }
                    Checked::Good => {
                        self.tries = 0;
                        self.proposing = true;
                        vec![F::Propose]
                    }
                }
            }
            SayEvent::Proposed { job, started } => {
                if !self.proposing {
                    return Vec::new();
                }
                self.proposing = false;
                match job {
                    Err(why) if !self.ended() => {
                        self.ended = true;
                        vec![F::Fail(vec![why]), F::Forget]
                    }
                    Err(_) => Vec::new(),
                    Ok(j) if self.stopped => vec![F::StopJob(j)],
                    Ok(j) if self.ended => {
                        self.job = Some(j);
                        Vec::new()
                    }
                    Ok(j) if started => self.started(j),
                    Ok(j) => {
                        self.job = Some(j.clone());
                        if self.pending.is_some() {
                            self.withdrawing = true;
                            vec![F::Withdraw(j)]
                        } else {
                            Vec::new()
                        }
                    }
                }
            }
            SayEvent::Withdrawn { started } => {
                if !self.withdrawing {
                    return Vec::new();
                }
                self.withdrawing = false;
                if self.ended() {
                    return Vec::new();
                }
                match self.job.take() {
                    Some(j) if started => self.started(j),
                    _ => match self.pending.take() {
                        Some(t) => vec![self.prompt(t)],
                        None => Vec::new(),
                    },
                }
            }
            SayEvent::Revise { text } => {
                if self.ended() {
                    return Vec::new();
                }
                if self.busy() {
                    self.pending = Some(text);
                    return Vec::new();
                }
                match self.job.clone() {
                    // the standing proposal goes first; the user may have approved it since
                    Some(j) => {
                        self.pending = Some(text);
                        self.withdrawing = true;
                        vec![F::Withdraw(j)]
                    }
                    None => vec![self.prompt(text)],
                }
            }
            SayEvent::Stop => {
                if self.ended() {
                    return Vec::new();
                }
                self.stopped = true;
                self.pending = None;
                let mut fx: Vec<SayEffect> = self.job.take().map(F::StopJob).into_iter().collect();
                fx.push(F::Forget);
                fx
            }
            SayEvent::End => {
                if self.ended() {
                    return Vec::new();
                }
                self.ended = true;
                self.pending = None;
                vec![F::Forget]
            }
        }
    }
}

// ---- the shell ----------------------------------------------------------------------------------------------------

/// What reaches [`run`].
#[derive(Debug)]
pub(crate) enum Input {
    Start {
        sid: String,
        repo: String,
        project: Option<String>,
        prompt: String,
    },
    Turn {
        sid: String,
        message: String,
    },
    Revise {
        sid: String,
        text: String,
    },
    Stop {
        sid: String,
    },
    End {
        sid: String,
    },
}

/// How many planning sessions whose job started are remembered, so `say/revise` names the job.
const STARTED_KEPT: usize = 64;

/// Why a revision of a planning session whose job JOB started is refused.
fn started_why(job: &str) -> String {
    format!("{job} has started: stop it, then say it again")
}

/// The planning sessions the hub holds (their ids, so a chat that is not Say's pays one lookup at its turn's end), the
/// latest ones whose job started (session, job), and the channel to [`run`].
pub struct Say {
    live: Arc<Mutex<BTreeSet<String>>>,
    started: Mutex<VecDeque<(String, String)>>,
    tx: mpsc::UnboundedSender<Input>,
    rx: Mutex<Option<mpsc::UnboundedReceiver<Input>>>,
}

impl Default for Say {
    fn default() -> Say {
        let (tx, rx) = mpsc::unbounded_channel();
        Say {
            live: Arc::default(),
            started: Mutex::default(),
            tx,
            rx: Mutex::new(Some(rx)),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// What a session holds of [`Say`]: its turn's end goes to [`run`] when it is a planning session.
#[derive(Clone)]
pub struct SayTx {
    live: Arc<Mutex<BTreeSet<String>>>,
    tx: mpsc::UnboundedSender<Input>,
}

impl SayTx {
    /// Session SID's turn ended with MESSAGE (its last agent message; empty when the turn failed).
    pub(crate) fn turn_ended(&self, sid: &str, message: &str) {
        if lock(&self.live).contains(sid) {
            let _ = self.tx.send(Input::Turn {
                sid: sid.to_owned(),
                message: message.to_owned(),
            });
        }
    }
}

impl Say {
    pub fn handle(&self) -> SayTx {
        SayTx {
            live: self.live.clone(),
            tx: self.tx.clone(),
        }
    }

    /// Whether SID is a planning session.
    pub fn has(&self, sid: &str) -> bool {
        lock(&self.live).contains(sid)
    }

    /// The user stopped session SID (`agents/stop`, `agents/kill`): a planning session's planning stops.
    pub fn stopped(&self, sid: &str) {
        if self.has(sid) {
            let _ = self.tx.send(Input::Stop {
                sid: sid.to_owned(),
            });
        }
    }

    fn begin(&self, input: Input) {
        if let Input::Start { sid, .. } = &input {
            lock(&self.live).insert(sid.clone());
        }
        let _ = self.tx.send(input);
    }

    fn send(&self, input: Input) {
        let _ = self.tx.send(input);
    }

    fn forget(&self, sid: &str) {
        lock(&self.live).remove(sid);
    }

    /// Session SID's job JOB started (the latest [`STARTED_KEPT`] are kept).
    fn mark_started(&self, sid: &str, job: &str) {
        let mut s = lock(&self.started);
        s.retain(|(k, _)| k != sid);
        s.push_back((sid.to_owned(), job.to_owned()));
        while s.len() > STARTED_KEPT {
            s.pop_front();
        }
    }

    /// The job session SID made that started, if it is remembered.
    fn started_job(&self, sid: &str) -> Option<String> {
        lock(&self.started)
            .iter()
            .find(|(k, _)| k == sid)
            .map(|(_, j)| j.clone())
    }
}

/// One planning session as [`run`] holds it.
struct Planning {
    core: SayCore,
    repo: String,
    project: Option<String>,
    /// The last block that held, until it is proposed.
    drawn: Option<Drawn>,
}

/// Say's shell: each input through its session's core, and the I/O its effects ask for, one input at a time.
pub async fn run(front: Arc<Front>) {
    let Some(mut rx) = lock(&front.core.say.rx).take() else {
        return;
    };
    let mut live: BTreeMap<String, Planning> = BTreeMap::new();
    while let Some(input) = rx.recv().await {
        let (sid, ev) = match input {
            Input::Start {
                sid,
                repo,
                project,
                prompt,
            } => {
                let (core, fx) = SayCore::start(prompt);
                live.insert(
                    sid.clone(),
                    Planning {
                        core,
                        repo,
                        project,
                        drawn: None,
                    },
                );
                perform(&front, &mut live, &sid, fx).await;
                continue;
            }
            Input::Turn { sid, message } => (sid, SayEvent::TurnEnded { message }),
            Input::Revise { sid, text } => (sid, SayEvent::Revise { text }),
            Input::Stop { sid } => (sid, SayEvent::Stop),
            Input::End { sid } => (sid, SayEvent::End),
        };
        let Some(p) = live.get_mut(&sid) else {
            continue;
        };
        let fx = p.core.step(ev);
        perform(&front, &mut live, &sid, fx).await;
    }
}

/// What MESSAGE, a planning turn's last message, holds; the proposal when it holds.
fn classify(front: &Front, message: &str) -> (Checked, Option<Drawn>) {
    if message.trim().is_empty() {
        return (
            Checked::Bad(vec!["the turn ended with no answer".into()]),
            None,
        );
    }
    match parse(message) {
        None => (Checked::NoBlock(message.to_owned()), None),
        Some(Err(e)) => (Checked::Bad(vec![e]), None),
        Some(Ok(d)) => match check(front, &d) {
            Ok(()) => (Checked::Good, Some(d)),
            Err(why) => (Checked::Bad(why), None),
        },
    }
}

/// Session SID's effects FX, and the events they answer, in order.
async fn perform(
    front: &Arc<Front>,
    live: &mut BTreeMap<String, Planning>,
    sid: &str,
    fx: Vec<SayEffect>,
) {
    let mut todo: VecDeque<SayEffect> = fx.into();
    while let Some(e) = todo.pop_front() {
        let Some(p) = live.get_mut(sid) else {
            return;
        };
        let next = match e {
            SayEffect::Prompt(text) => {
                if let Err(e) = front.core.agents.prompt(sid, text, Origin::Hub) {
                    tracing::warn!(
                        sid,
                        "say: the planning session took no prompt: {}",
                        e.message
                    );
                }
                Vec::new()
            }
            SayEffect::Parse(message) => {
                let (c, drawn) = classify(front, &message);
                p.drawn = drawn;
                p.core.step(SayEvent::Checked(c))
            }
            SayEffect::Ask(text) => {
                front.broadcast("say-message", json!({"id": sid, "text": text}));
                Vec::new()
            }
            SayEffect::Propose => {
                let made = propose(front, sid, p).await;
                let started = matches!(made, Ok((_, true)));
                let job = made.map(|(j, _)| j);
                if let Ok(j) = &job {
                    // before the event: a revision the event prompts is refused with the job's id
                    if started {
                        front.core.say.mark_started(sid, j);
                    }
                    front.broadcast("say-proposal", json!({"id": sid, "job": j}));
                }
                p.core.step(SayEvent::Proposed { job, started })
            }
            SayEffect::StopJob(job) => {
                stop_proposal(front, &job).await;
                Vec::new()
            }
            SayEffect::Withdraw(job) => {
                let started = !stop_proposal(front, &job).await;
                p.core.step(SayEvent::Withdrawn { started })
            }
            SayEffect::Started(job) => {
                front.core.say.mark_started(sid, &job);
                Vec::new()
            }
            SayEffect::Fail(why) => {
                front.broadcast("say-failed", json!({"id": sid, "why": why.join("; ")}));
                Vec::new()
            }
            SayEffect::Forget => {
                live.remove(sid);
                front.core.say.forget(sid);
                let by_id: ById =
                    serde_json::from_value(json!({ "id": sid })).expect("a session id is an id");
                let _ = crate::agents::session::stop(front, &crate::runner::user(), by_id).await;
                return;
            }
        };
        todo.extend(next);
    }
}

/// Job JOB stopped while it is still a proposal, decided in the store's write (a job the user approved, even just
/// now, runs on): whether it never started (it was a proposal, or one the user rejected, or it is gone).
async fn stop_proposal(front: &Front, job: &str) -> bool {
    match crate::runner::withdraw(front, &crate::runner::user(), job).await {
        Ok(true) => return true,
        Ok(false) => {}
        Err(e) => tracing::warn!(job, "say: the proposal was not withdrawn: {}", e.message),
    }
    // not a proposal: never one again, so what it is now is what it will stay
    crate::runner::load(front, job, false)
        .await
        .ok()
        .flatten()
        .is_none_or(|l| {
            l.job
                .data
                .as_ref()
                .is_some_and(|d| d.get(crate::runner::NEVER_APPROVED).is_some())
        })
}

/// The plan P's last block drew, written and proposed as the user would, in the repository `say/start` named: the
/// job's id, and whether it started at once (the Autonomous preset).  The dollar budget is the smallest of the block's
/// (`usd` or `usd-est`); the planning session's own use goes in `data.planning`, as numbers.
async fn propose(front: &Front, sid: &str, p: &Planning) -> Result<(String, bool), String> {
    let d = p.drawn.as_ref().ok_or("no proposal to make")?;
    let tasks: Vec<Value> = d
        .tasks
        .iter()
        .map(|t| {
            json!({"number": t.n.to_string(), "title": t.title, "role": t.role, "profile": t.profile,
                   "body": t.body, "blocks": t.deps.iter().map(i64::to_string).collect::<Vec<_>>()})
        })
        .collect();
    let mut w = json!({"title": d.title, "tasks": tasks});
    if let Some(project) = &p.project {
        w["project"] = json!(project);
    }
    let w: WriteParams = serde_json::from_value(w).map_err(|e| e.to_string())?;
    let user = crate::runner::user();
    let written = crate::runner::effects::plans_write(front, &user, w)
        .await
        .map_err(|e| e.message)?;
    let plan: PlanRef = serde_json::from_value(json!(written.plan)).map_err(|e| e.to_string())?;
    let budget = d
        .budget
        .iter()
        .filter(|l| matches!(l.unit, Unit::Usd | Unit::UsdEst))
        .map(|l| l.amount)
        .reduce(f64::min);
    let s = crate::runner::propose_graph(front, &user, &plan, &p.repo, budget, d.gate)
        .await
        .map_err(|e| e.message)?;
    let s_id = sid.to_owned();
    if let Ok(line) = front.writer.db.read(move |c| planning_of(c, &s_id)).await {
        let _ = crate::runner::update_data(front, &user, &s.id, move |data| {
            data.insert("planning".into(), line);
        })
        .await;
    }
    let started = s.status.as_deref() != Some("proposed");
    Ok((s.id, started))
}

// ---- the methods --------------------------------------------------------------------------------------------------

/// `say/start`: the planning session on P's profile (else the `say` route, which defaults to the first `implement`
/// route's), prompted with the instructions, the digest and the user's words.
pub async fn start(front: &Front, _caller: &Caller, p: SayStart) -> Result<SayStarted, Error> {
    front.refresh_settings().await;
    let profile = match &p.profile {
        Some(n) => n.as_str().to_owned(),
        None => crate::runner::route(front, "say")
            .into_iter()
            .next()
            .unwrap_or_else(|| "claude".into()),
    };
    let started = front
        .core
        .agents
        .start(front, start_params(&profile), &crate::runner::user())
        .await?;
    let project = p.project.as_ref().map(|i| i.as_str().to_owned());
    let prompt = planning_prompt(&digest(front, project.as_deref()), p.text.as_str());
    front.core.say.begin(Input::Start {
        sid: started.id.clone(),
        repo: p.repo.as_str().to_owned(),
        project,
        prompt,
    });
    Ok(SayStarted { id: started.id })
}

/// `say/revise`: the user's change, to a planning session the hub still holds; refused once its job has started
/// (the revision would be a second job beside it).
pub async fn revise(front: &Front, _caller: &Caller, p: SayRevise) -> Result<bool, Error> {
    let sid = p.id.as_str();
    if let Some(job) = front.core.say.started_job(sid) {
        return Err(crate::runner::invalid(started_why(&job)));
    }
    if !front.core.say.has(sid) {
        return Err(crate::runner::invalid("the planning stopped: say it again"));
    }
    front.core.say.send(Input::Revise {
        sid: sid.to_owned(),
        text: p.text.as_str().to_owned(),
    });
    Ok(true)
}

/// `say/end`: the planning session stopped and forgotten; false for one the hub does not hold.
pub async fn end(front: &Front, _caller: &Caller, p: SayById) -> Result<bool, Error> {
    let sid = p.id.as_str();
    if !front.core.say.has(sid) {
        return Ok(false);
    }
    front.core.say.send(Input::End {
        sid: sid.to_owned(),
    });
    Ok(true)
}

#[cfg(test)]
mod tests;
