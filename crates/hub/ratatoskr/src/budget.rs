//! Budgets, units and pace (Task 20; `docs/guide/agents.md`, "Budgets"): limits on a project, spec, plan, run, task,
//! manager or worker, each in a named unit, the remaining amount the least over its ancestors; the gateway admits `usd` against
//! the nested minimum; subscription meters (`_claude/rateLimit`, Codex's window) as `limit-share` estimates; at a
//! limit the agent is paused with a `budget` card.  Methods `budget/get`, `budget/set`, `budget/raise`, `budget/tree`,
//! `pace/get`.
//!
//! - **Units never mix.**  A limit in one unit is only ever reduced by spend in that unit (`usd` is what the gateway
//!   measured, `usd-est` what an agent reported at API prices, `limit-share` a subscription window's share, `tokens`,
//!   `count`); nothing is converted.  `usd-est` and `limit-share` are estimates and are labelled so.  The one join:
//!   a plan's dollar budget on a plan with a subscription profile ([`Budgets::set_joint`]) binds `usd` and `usd-est`
//!   summed, one limit, reported as an estimate.
//! - **Nesting.**  A spend counts against the spending scope and every ancestor; what remains is the least over the
//!   chain.  The chain is worker → task → run → plan → spec → project ([`Budgets::link_up`]; a worker a manager started
//!   sits under the manager, a manager under its run).  A plan is the plan document: every run (one job) of it links
//!   under it, so a second run spends what the first left, and `budget/get` on a run gives that run's own share.  A
//!   plan with no spec sits under its project, a run with no plan too.  A session is a scope from its start; the plan
//!   runner links a worker's chain when it starts it and a run's when its job is approved, the manager role its own.
//! - **Reaching a limit counts** (as the gateway's `over`): every session at or below the scope is paused after its
//!   tool call (`Hub::cancel_after_tool`) and one `budget` card is made per scope and unit, until the limit is set
//!   again.  The gateway's registration of a session carries `job spend + remaining usd`, kept current as siblings
//!   spend, so a request over the nested minimum is refused with `budget_exceeded`.
//! - **Pace** is linear over the last 24 h of a meter's readings; the clock is an argument, never read here.

use crate::agents::HoldSource;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::{
    BudgetEvent, BudgetGetParams, BudgetHeld, BudgetNode, BudgetRaiseParams, BudgetRaised,
    BudgetScope, BudgetSetParams, BudgetState, BudgetTree, BudgetTreeParams, BudgetView, Pace,
    PaceParams, Paces,
};
use runstav::wire::Error;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use tokio::sync::mpsc;

/// The window a pace is read over, in seconds.
pub const PACE_WINDOW: f64 = 24.0 * 3600.0;

/// A scope reached a limit.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub scope: BudgetScope,
    pub unit: Unit,
    pub limit: f64,
    pub spent: f64,
}

/// What a cumulative reading booked: the rise it added (never negative) and the limits that rise reached.
#[derive(Clone, Debug, PartialEq)]
pub struct Booked {
    pub delta: f64,
    pub hits: Vec<Hit>,
}

impl Hit {
    pub fn estimate(&self) -> bool {
        is_estimate(self.unit)
    }
}

/// Whether amounts in UNIT are estimates (reported usage at API prices; a subscription window's share).
pub fn is_estimate(unit: Unit) -> bool {
    matches!(unit, Unit::UsdEst | Unit::LimitShare)
}

/// What the consumer ([`run`]) is told.
#[derive(Debug)]
pub enum Note {
    /// A limit was reached.
    Hit(Hit),
    /// Gateway spend of JOB: the registrations below the same ancestors are refreshed.
    Usd(String),
}

type Key = String;

/// The scope's key: `kind:id`.
pub fn key(s: &BudgetScope) -> Key {
    match s {
        BudgetScope::Project(i) => format!("project:{}", i.as_str()),
        BudgetScope::Spec(i) => format!("spec:{}", i.as_str()),
        BudgetScope::Plan(i) => format!("plan:{}", i.as_str()),
        BudgetScope::Run(i) => format!("run:{}", i.as_str()),
        BudgetScope::Task(i) => format!("task:{}", norn::write::tasks::task_key(i.as_str())),
        BudgetScope::Manager(i) => format!("manager:{}", i.as_str()),
        BudgetScope::Worker(i) => format!("worker:{}", i.as_str()),
    }
}

/// The session id of a manager or worker scope.
pub fn session_of(s: &BudgetScope) -> Option<&str> {
    match s {
        BudgetScope::Manager(i) | BudgetScope::Worker(i) => Some(i.as_str()),
        _ => None,
    }
}

/// How long a meter's thinned history is kept, in seconds (8 days).
const HISTORY_SPAN: f64 = 8.0 * 24.0 * 3600.0;

/// The thinned history keeps one reading in each slot of this many seconds (a quarter hour): at most 768 a provider.
const HISTORY_SLOT: f64 = 900.0;

/// The rise a meter made over READINGS, in time order: every rise added, a fall (the window reset) adds nothing and
/// starts a new segment.
pub fn rise_total(readings: &[(f64, f64)]) -> f64 {
    readings
        .windows(2)
        .map(|w| (w[1].1 - w[0].1).max(0.0))
        .sum()
}

/// A subscription meter: its readings of the last [`PACE_WINDOW`], and a thinned history of eight days.
#[derive(Clone, Debug, Default)]
struct Meter {
    /// `(at, share)` in time order.
    samples: VecDeque<(f64, f64)>,
    resets_at: Option<f64>,
    /// `(at, share)`: one reading for each [`HISTORY_SLOT`], the slot's first time and its latest share; a fall is
    /// kept (it is a reset, [`rise_total`] reads it so).
    history: VecDeque<(f64, f64)>,
}

impl Meter {
    /// Whether the reading started a new slot of the history (what is worth saving).
    fn read(&mut self, at: f64, share: f64, resets_at: Option<f64>) -> bool {
        let fresh = match self.history.back_mut() {
            Some((slot, latest)) if at - *slot < HISTORY_SLOT => {
                *latest = share;
                false
            }
            _ => {
                self.history.push_back((at, share));
                true
            }
        };
        while self
            .history
            .front()
            .is_some_and(|(t, _)| at - *t >= HISTORY_SPAN)
        {
            self.history.pop_front();
        }
        self.read_window(at, share, resets_at);
        fresh
    }

    fn read_window(&mut self, at: f64, share: f64, resets_at: Option<f64>) {
        // a share that fell is a new window: the earlier readings say nothing about it
        if self.samples.back().is_some_and(|(_, s)| share + 1e-9 < *s) {
            self.samples.clear();
        }
        self.samples.push_back((at, share));
        while self
            .samples
            .front()
            .is_some_and(|(t, _)| at - *t > PACE_WINDOW)
        {
            self.samples.pop_front();
        }
        if resets_at.is_some() {
            self.resets_at = resets_at;
        }
    }

    fn pace(&self, provider: &str, window: &str, now: f64, history: bool) -> Option<Pace> {
        let (_, used) = *self.samples.back()?;
        let (first_at, first) = *self.samples.iter().find(|(t, _)| now - *t <= PACE_WINDOW)?;
        let (last_at, _) = *self.samples.back()?;
        let hours = (last_at - first_at) / 3600.0;
        let rate = if hours > 0.0 {
            ((used - first) / hours).max(0.0)
        } else {
            0.0
        };
        let exhausted_at = if used >= 1.0 {
            Some(now)
        } else if rate > 0.0 {
            let at = now + (1.0 - used) / rate * 3600.0;
            // after the window resets the share starts over: no exhaustion to forecast
            self.resets_at.is_none_or(|r| at <= r).then_some(at)
        } else {
            None
        };
        Some(Pace {
            provider: provider.to_string(),
            window: window.to_string(),
            used_share: used,
            rate_per_hour: rate,
            exhausted_at,
            resets_at: self.resets_at,
            estimate: true,
            rate_7d_per_hour: (window == "week").then(|| self.rate_7d(now)).flatten(),
            history: if history {
                self.history
                    .iter()
                    .copied()
                    .filter(|(t, _)| now - *t < HISTORY_SPAN)
                    .collect()
            } else {
                Vec::new()
            },
        })
    }

    /// The mean rise per hour over the last seven days of readings, once there are 24 hours of them.
    fn rate_7d(&self, now: f64) -> Option<f64> {
        let week: Vec<(f64, f64)> = self
            .history
            .iter()
            .copied()
            .filter(|(t, _)| now - *t < 7.0 * 24.0 * 3600.0)
            .collect();
        let hours = (week.last()?.0 - week.first()?.0) / 3600.0;
        (hours >= 24.0).then(|| rise_total(&week) / hours)
    }
}

#[derive(Default)]
struct St {
    limits: BTreeMap<Key, Vec<Limit>>,
    spent: BTreeMap<Key, BTreeMap<Unit, f64>>,
    parent: BTreeMap<Key, Key>,
    scopes: BTreeMap<Key, BudgetScope>,
    /// The `(scope, unit)` pairs already reported.
    hit: BTreeSet<(Key, Unit)>,
    /// The gateway job a session's requests are booked under.
    jobs: BTreeMap<String, Key>,
    /// The last cumulative reading per `(session, what)`: a spend is the rise since.
    seen: BTreeMap<(Key, String), f64>,
    meters: BTreeMap<String, Meter>,
    /// The scopes whose `usd` and `usd-est` limits bind together ([`Budgets::set_joint`]).
    joint: BTreeSet<Key>,
    /// What each scope spent in the last hour, `(at, unit, amount)`, in memory only ([`Budgets::burn`]).
    ring: BTreeMap<Key, std::collections::VecDeque<(f64, Unit, f64)>>,
    /// The scopes whose spend moved since the last [`Budgets::take_changed`].
    changed: BTreeSet<Key>,
}

/// The version of [`Saved`] this build writes.  Before 2 a job with no plan had its own `plan` scope, `plan:JOB`: such
/// a state's are migrated on load to the job's `run` scope, with their limits, spend and links ([`old_run_scope`]). A
/// plan file's or graph plan's scope keeps its meaning (the plan across its runs).
const SAVED_VERSION: u32 = 2;

/// The `run` scope an old state's per-job `plan` scope (`plan:JOB`, the job ids being `job-…`) meant; none for every
/// other scope.
fn old_run_scope(sc: &BudgetScope) -> Option<BudgetScope> {
    let BudgetScope::Plan(id) = sc else {
        return None;
    };
    let job = id.as_str().strip_prefix("plan:")?;
    if !job.starts_with("job-") {
        return None;
    }
    runstav::types::Id::new(job).ok().map(BudgetScope::Run)
}

/// What `runtime.db` keeps.
#[derive(Default, Serialize, Deserialize)]
struct Saved {
    /// [`SAVED_VERSION`] when written; a row saved before has none.
    #[serde(default)]
    version: u32,
    limits: Vec<(BudgetScope, Vec<Limit>)>,
    spent: Vec<(BudgetScope, Vec<Limit>)>,
    parents: Vec<(BudgetScope, BudgetScope)>,
    /// The meters' thinned histories; a row saved before they were kept has none.
    #[serde(default)]
    meters: Vec<SavedMeter>,
    /// The scopes whose dollar limits bind together; a row saved before has none.
    #[serde(default)]
    joint: Vec<BudgetScope>,
}

#[derive(Serialize, Deserialize)]
struct SavedMeter {
    provider: String,
    history: Vec<(f64, f64)>,
    resets_at: Option<f64>,
}

struct Inner {
    st: Mutex<St>,
    tx: mpsc::UnboundedSender<Note>,
    rx: Mutex<Option<mpsc::UnboundedReceiver<Note>>>,
    db: std::sync::OnceLock<urdr::Handle>,
}

/// The budgets, their spend and the meters.  A handle: clones share one state.
#[derive(Clone)]
pub struct Budgets(Arc<Inner>);

impl Default for Budgets {
    fn default() -> Budgets {
        let (tx, rx) = mpsc::unbounded_channel();
        Budgets(Arc::new(Inner {
            st: Mutex::new(St::default()),
            tx,
            rx: Mutex::new(Some(rx)),
            db: std::sync::OnceLock::new(),
        }))
    }
}

const KV: &str = "budgets";

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// KEY and its ancestors, nearest first.
fn chain(st: &St, key: &str) -> Vec<Key> {
    let mut out = vec![key.to_string()];
    while let Some(p) = st.parent.get(out.last().expect("one")) {
        if out.contains(p) {
            break; // a cycle is not followed
        }
        out.push(p.clone());
    }
    out
}

/// How far back the burn ring remembers, in seconds (an hour).
const RING_SPAN: f64 = 3600.0;

/// How much spend the burn needs before it says anything, in seconds (ten minutes).
const BURN_MIN: f64 = 600.0;

/// The share of the binding limit spent from which a scope is `nearing`.
const NEARING: f64 = 0.8;

/// The key of a provider's meter for one of its windows.
fn meter_key(provider: &str, window: &str) -> String {
    format!("{provider}/{window}")
}

fn is_dollars(unit: Unit) -> bool {
    matches!(unit, Unit::Usd | Unit::UsdEst)
}

/// What KEY spent against a limit in UNIT: that unit's spend, or for a joint scope's dollar limit the measured and
/// the estimated dollars together.
fn spent_against(st: &St, key: &str, unit: Unit) -> f64 {
    let spent = |u: Unit| {
        st.spent
            .get(key)
            .and_then(|m| m.get(&u))
            .copied()
            .unwrap_or(0.0)
    };
    if is_dollars(unit) && st.joint.contains(key) {
        spent(Unit::Usd) + spent(Unit::UsdEst)
    } else {
        spent(unit)
    }
}

fn remaining_of(st: &St, key: &str) -> Vec<(Unit, f64)> {
    let mut least: BTreeMap<Unit, f64> = BTreeMap::new();
    for k in chain(st, key) {
        for l in st.limits.get(&k).into_iter().flatten() {
            let spent = spent_against(st, &k, l.unit);
            let left = (l.amount - spent).max(0.0);
            least
                .entry(l.unit)
                .and_modify(|m| *m = m.min(left))
                .or_insert(left);
        }
    }
    least.into_iter().collect()
}

/// The nearest of KEY and its ancestors whose own limit its spend has reached.
fn holder_of(st: &St, key: &str) -> Option<BudgetScope> {
    chain(st, key).into_iter().find_map(|k| {
        let reached = st
            .limits
            .get(&k)
            .into_iter()
            .flatten()
            .any(|l| spent_against(st, &k, l.unit) >= l.amount);
        reached.then(|| st.scopes.get(&k).cloned()).flatten()
    })
}

/// The limits KEY has that its spend has reached and that were not reported yet.  A joint scope's two dollar limits
/// are one: reported once, in `usd-est` (an estimate) when any of the spend was estimated.
fn reached(st: &mut St, key: &str, only: Option<Unit>) -> Vec<Hit> {
    let joint = st.joint.contains(key);
    let mut hits = Vec::new();
    for l in st.limits.get(key).cloned().into_iter().flatten() {
        if only.is_some_and(|u| u != l.unit && !(joint && is_dollars(u) && is_dollars(l.unit))) {
            continue;
        }
        let spent = spent_against(st, key, l.unit);
        let unit = if joint && is_dollars(l.unit) {
            let estimated = st
                .spent
                .get(key)
                .and_then(|m| m.get(&Unit::UsdEst))
                .is_some_and(|a| *a > 0.0);
            if estimated { Unit::UsdEst } else { Unit::Usd }
        } else {
            l.unit
        };
        if spent >= l.amount
            && let Some(scope) = st.scopes.get(key).cloned()
            && !st.hit.contains(&(key.to_string(), l.unit))
        {
            st.hit.insert((key.to_string(), l.unit));
            if joint && is_dollars(l.unit) {
                st.hit.insert((key.to_string(), Unit::Usd));
                st.hit.insert((key.to_string(), Unit::UsdEst));
            }
            hits.push(Hit {
                scope,
                unit,
                limit: l.amount,
                spent,
            });
        }
    }
    hits
}

/// The amount of a cost an agent's usage update carries: a bare number, or the object `{"amount": 0.01, "currency":
/// "USD"}` the agents send.  The one reader of every path that books or shows a session's cost.
pub fn cost_amount(cost: &Value) -> Option<f64> {
    cost.as_f64()
        .or_else(|| cost.get("amount").and_then(Value::as_f64))
        .filter(|a| a.is_finite())
}

impl Budgets {
    fn st(&self) -> MutexGuard<'_, St> {
        lock(&self.0.st)
    }

    /// The consumer's end of the notes (once).
    pub fn take_notes(&self) -> Option<mpsc::UnboundedReceiver<Note>> {
        lock(&self.0.rx).take()
    }

    /// Tell the consumer of HITS.
    pub fn notify(&self, hits: Vec<Hit>) {
        for h in hits {
            let _ = self.0.tx.send(Note::Hit(h));
        }
    }

    /// `runtime.db` (once): what it kept is read back.
    pub async fn open_store(&self, db: urdr::Handle) {
        if let Some(text) = crate::gateway::kv_get(&db, KV).await {
            match serde_json::from_str::<Saved>(&text) {
                Ok(s) => {
                    self.restore(s);
                }
                Err(e) => tracing::warn!("the saved budgets do not read: {e}"),
            }
        }
        let _ = self.0.db.set(db);
    }

    /// Read S back; the number of entries migrated (an old state's per-job `plan` scopes, now `run`).
    fn restore(&self, mut s: Saved) -> usize {
        let mut moved = 0;
        if s.version < SAVED_VERSION {
            let mut migrate = |sc: &mut BudgetScope| {
                if let Some(run) = old_run_scope(sc) {
                    *sc = run;
                    moved += 1;
                }
            };
            s.limits.iter_mut().for_each(|(sc, _)| migrate(sc));
            s.spent.iter_mut().for_each(|(sc, _)| migrate(sc));
            s.parents.iter_mut().for_each(|(c, p)| {
                migrate(c);
                migrate(p);
            });
            s.joint.iter_mut().for_each(&mut migrate);
            if moved > 0 {
                tracing::info!(
                    "the saved budgets kept {moved} entries of jobs under `plan` scopes: moved to their `run` scopes"
                );
            }
        }
        let mut st = self.st();
        for (scope, ls) in s.limits {
            let k = key(&scope);
            st.scopes.insert(k.clone(), scope);
            st.limits.insert(k, ls);
        }
        for (scope, ls) in s.spent {
            let k = key(&scope);
            st.scopes.insert(k.clone(), scope);
            st.spent
                .insert(k, ls.into_iter().map(|l| (l.unit, l.amount)).collect());
        }
        for (c, p) in s.parents {
            let (ck, pk) = (key(&c), key(&p));
            st.scopes.insert(ck.clone(), c);
            st.scopes.insert(pk.clone(), p);
            st.parent.insert(ck, pk);
        }
        for scope in s.joint {
            let k = key(&scope);
            st.scopes.insert(k.clone(), scope);
            st.joint.insert(k);
        }
        // the readings are replayed, so the 24 h window of the pace is rebuilt from the history
        for m in s.meters {
            // a meter saved by provider alone (before windows) is dropped
            if !m.provider.contains('/') {
                continue;
            }
            let mut meter = Meter::default();
            for (at, share) in m.history {
                meter.read(at, share, None);
            }
            meter.resets_at = m.resets_at;
            st.meters.insert(m.provider, meter);
        }
        moved
    }

    fn saved(&self) -> Saved {
        let st = self.st();
        let scope = |k: &Key| st.scopes.get(k).cloned();
        Saved {
            version: SAVED_VERSION,
            limits: st
                .limits
                .iter()
                .filter_map(|(k, v)| Some((scope(k)?, v.clone())))
                .collect(),
            spent: st
                .spent
                .iter()
                .filter_map(|(k, m)| {
                    let ls = m
                        .iter()
                        .map(|(u, a)| Limit {
                            amount: *a,
                            unit: *u,
                        })
                        .collect();
                    Some((scope(k)?, ls))
                })
                .collect(),
            parents: st
                .parent
                .iter()
                .filter_map(|(c, p)| Some((scope(c)?, scope(p)?)))
                .collect(),
            meters: st
                .meters
                .iter()
                .map(|(p, m)| SavedMeter {
                    provider: p.clone(),
                    history: m.history.iter().copied().collect(),
                    resets_at: m.resets_at,
                })
                .collect(),
            joint: st.joint.iter().filter_map(scope).collect(),
        }
    }

    /// Write the state to `runtime.db` in the background (a hub with no store keeps it in memory).
    pub fn save(&self) {
        let Some(db) = self.0.db.get().cloned() else {
            return;
        };
        let Ok(text) = serde_json::to_string(&self.saved()) else {
            return;
        };
        tokio::spawn(async move { crate::gateway::kv_set(&db, KV, &text).await });
    }

    /// SCOPE's limits are LIMITS (empty clears); the limits already reached are reported again.
    pub fn set(&self, scope: &BudgetScope, limits: Vec<Limit>) -> Vec<Hit> {
        self.set_limits(scope, limits, false)
    }

    /// [`Budgets::set`], with SCOPE's `usd` and `usd-est` limits binding together: each counts what the gateway
    /// measured and what agents estimated, summed, so a plan whose tasks run on a subscription and on a gateway is
    /// capped once, and what the gateway may still spend is what that sum leaves.  Reached, the two are one limit.
    pub fn set_joint(&self, scope: &BudgetScope, limits: Vec<Limit>) -> Vec<Hit> {
        self.set_limits(scope, limits, true)
    }

    fn set_limits(&self, scope: &BudgetScope, limits: Vec<Limit>, joint: bool) -> Vec<Hit> {
        let k = key(scope);
        let mut st = self.st();
        st.scopes.insert(k.clone(), scope.clone());
        if joint {
            st.joint.insert(k.clone());
        } else {
            st.joint.remove(&k);
        }
        st.hit.retain(|(hk, _)| *hk != k);
        if limits.is_empty() {
            st.limits.remove(&k);
            return Vec::new();
        }
        st.limits.insert(k.clone(), limits);
        reached(&mut st, &k, None)
    }

    /// SCOPE's LIMITS over its own: a unit LIMITS names is replaced, the others stay (a raise of `usd` keeps the
    /// `limit-share`), and a joint scope stays joint.  The limits it still reaches are returned, as by [`Budgets::set`].
    pub fn raise(&self, scope: &BudgetScope, limits: Vec<Limit>) -> Vec<Hit> {
        let (mut merged, joint) = {
            let st = self.st();
            let k = key(scope);
            (
                st.limits.get(&k).cloned().unwrap_or_default(),
                st.joint.contains(&k),
            )
        };
        merged.retain(|l| !limits.iter().any(|n| n.unit == l.unit));
        merged.extend(limits);
        self.set_limits(scope, merged, joint)
    }

    /// The nearest scope at or above SCOPE whose own limit its spend has reached: what holds SCOPE's sessions paused.
    pub fn holder(&self, scope: &BudgetScope) -> Option<BudgetScope> {
        holder_of(&self.st(), &key(scope))
    }

    /// [`Budgets::holder`] of session SID's scope (its worker or manager scope); none for a session with no scope.
    pub fn holder_of_session(&self, sid: &str) -> Option<BudgetScope> {
        let st = self.st();
        let k = st
            .scopes
            .iter()
            .find(|(_, s)| session_of(s) == Some(sid))
            .map(|(k, _)| k.clone())?;
        holder_of(&st, &k)
    }

    /// CHILD counts toward PARENT.
    pub fn link(&self, child: &BudgetScope, parent: &BudgetScope) {
        let (c, p) = (key(child), key(parent));
        let mut st = self.st();
        st.scopes.insert(c.clone(), child.clone());
        st.scopes.insert(p.clone(), parent.clone());
        st.parent.insert(c, p);
    }

    /// Each of SCOPES counts toward the next: a chain from the spender up, e.g. worker, task, run, plan, spec,
    /// project.  The last is enrolled (it may be a top).
    pub fn link_up(&self, scopes: &[BudgetScope]) {
        for w in scopes.windows(2) {
            self.link(&w[0], &w[1]);
        }
        if let Some(top) = scopes.last() {
            self.enroll(top);
        }
    }

    /// The session scope OLD continues as NEW (an agent moved to another session): NEW counts toward what OLD counted
    /// toward (its task, run and plan above), and the gateway jobs booked under OLD are booked under NEW.
    pub fn rekey(&self, old: &BudgetScope, new: &BudgetScope) {
        let (ok, nk) = (key(old), key(new));
        let mut st = self.st();
        st.scopes.insert(nk.clone(), new.clone());
        if let Some(p) = st.parent.get(&ok).cloned() {
            st.parent.insert(nk.clone(), p);
        }
        for k in st.jobs.values_mut() {
            if *k == ok {
                *k = nk.clone();
            }
        }
    }

    /// SCOPE exists (a session, from its start).
    pub fn enroll(&self, scope: &BudgetScope) {
        self.st().scopes.insert(key(scope), scope.clone());
    }

    /// SCOPE's own limits.
    pub fn limits(&self, scope: &BudgetScope) -> Vec<Limit> {
        self.st()
            .limits
            .get(&key(scope))
            .cloned()
            .unwrap_or_default()
    }

    /// What remains of each unit that SCOPE or an ancestor limits: the least over the chain, never below 0.
    pub fn remaining(&self, scope: &BudgetScope) -> Vec<(Unit, f64)> {
        remaining_of(&self.st(), &key(scope))
    }

    /// What SCOPE spent per hour over the last hour (or over what was seen, at least ten minutes of it), in each unit;
    /// empty before ten minutes of spend.  NOW is the time asked at.
    pub fn burn(&self, scope: &BudgetScope, now: f64) -> Vec<Limit> {
        let st = self.st();
        let Some(ring) = st.ring.get(&key(scope)) else {
            return Vec::new();
        };
        let from = now - RING_SPAN;
        let Some(first) = ring
            .iter()
            .map(|(t, ..)| *t)
            .filter(|t| *t >= from)
            .reduce(f64::min)
        else {
            return Vec::new();
        };
        let seen = now - first;
        if seen < BURN_MIN {
            return Vec::new();
        }
        let mut sums: BTreeMap<Unit, f64> = BTreeMap::new();
        for (t, unit, amount) in ring.iter().filter(|(t, ..)| *t >= from) {
            let _ = t;
            *sums.entry(*unit).or_default() += amount;
        }
        sums.into_iter()
            .map(|(unit, sum)| Limit {
                amount: sum / (seen / 3600.0),
                unit,
            })
            .collect()
    }

    /// The limit SCOPE (or an ancestor) holds that is closest to spent: `(unit, spent, limit)`, the unit whose remaining
    /// share is the least; none with no limit anywhere up the chain.
    pub fn binding(&self, scope: &BudgetScope) -> Option<(Unit, f64, f64)> {
        let st = self.st();
        let k = key(scope);
        let mut best: Option<(f64, Unit, f64, f64)> = None;
        for c in chain(&st, &k) {
            for l in st.limits.get(&c).into_iter().flatten() {
                let spent = spent_against(&st, &c, l.unit);
                let share = if l.amount > 0.0 {
                    ((l.amount - spent) / l.amount).max(0.0)
                } else {
                    0.0
                };
                if best.is_none_or(|(s, ..)| share < s) {
                    best = Some((share, l.unit, spent, l.amount));
                }
            }
        }
        best.map(|(_, unit, spent, limit)| (unit, spent, limit))
    }

    /// Where SCOPE stands: `reached` at or past the binding limit, `nearing` from 80 % of it, `none` with no limit up the
    /// chain.
    pub fn state(&self, scope: &BudgetScope) -> BudgetState {
        match self.binding(scope) {
            None => BudgetState::None,
            Some((_, spent, limit)) if limit <= 0.0 || spent >= limit => BudgetState::Reached,
            Some((_, spent, limit)) if spent / limit >= NEARING => BudgetState::Nearing,
            Some(_) => BudgetState::Ok,
        }
    }

    /// The scopes whose spend moved since the last call (each once).
    pub fn take_changed(&self) -> Vec<BudgetScope> {
        let mut st = self.st();
        let keys: Vec<Key> = std::mem::take(&mut st.changed).into_iter().collect();
        keys.iter()
            .filter_map(|k| st.scopes.get(k).cloned())
            .collect()
    }

    /// The scopes below ROOT (itself included; none: every scope with no parent) down to DEPTH levels, depth first, each
    /// with its parent; children in key order, so a page's `after` (a key) finds its place again.
    pub fn tree_scopes(
        &self,
        root: Option<&BudgetScope>,
        depth: Option<u8>,
    ) -> Vec<(Key, BudgetScope, Option<BudgetScope>)> {
        let st = self.st();
        let mut kids: BTreeMap<&Key, Vec<&Key>> = BTreeMap::new();
        for (c, p) in &st.parent {
            kids.entry(p).or_default().push(c);
        }
        let mut out = Vec::new();
        let roots: Vec<Key> = match root {
            Some(r) => vec![key(r)],
            None => st
                .scopes
                .keys()
                .filter(|k| !st.parent.contains_key(*k))
                .cloned()
                .collect(),
        };
        // an explicit stack: (key, level), children pushed in reverse so the least key is next
        let mut stack: Vec<(Key, u8)> = roots.into_iter().rev().map(|k| (k, 0)).collect();
        let mut seen = BTreeSet::new();
        while let Some((k, level)) = stack.pop() {
            if !seen.insert(k.clone()) {
                continue;
            }
            let Some(scope) = st
                .scopes
                .get(&k)
                .cloned()
                .or_else(|| root.filter(|r| key(r) == k).cloned())
            else {
                continue;
            };
            let parent = st.parent.get(&k).and_then(|p| st.scopes.get(p)).cloned();
            out.push((k.clone(), scope, parent));
            if depth.is_none_or(|d| level < d) {
                for c in kids.get(&k).into_iter().flatten().rev() {
                    stack.push(((*c).clone(), level + 1));
                }
            }
        }
        out
    }

    /// SCOPE's node: its view, state and burn at NOW, and, for a run under a plan, its share of the plan's spend in
    /// the plan's binding unit.
    pub fn node(
        &self,
        scope: &BudgetScope,
        parent: Option<&BudgetScope>,
        label: String,
        now: f64,
    ) -> BudgetNode {
        let v = self.view(scope);
        let share = match (scope, parent) {
            (BudgetScope::Run(_), Some(p @ BudgetScope::Plan(_))) => {
                self.binding(p).and_then(|(unit, spent, _)| {
                    let mine = v.spent.iter().find(|l| l.unit == unit)?.amount;
                    (spent > 0.0).then_some((mine / spent).clamp(0.0, 1.0))
                })
            }
            _ => None,
        };
        BudgetNode {
            scope: scope.clone(),
            parent: parent.cloned(),
            label,
            limits: v.limits,
            spent: v.spent,
            remaining: v.remaining,
            state: self.state(scope),
            burn_per_hour: self.burn(scope, now),
            share_of_parent: share,
        }
    }

    /// One flush: the events of every scope whose spend moved since the last flush, one each however many spends it
    /// took (the hub calls it once a second).
    pub fn flush(&self, now: f64) -> Vec<BudgetEvent> {
        self.take_changed()
            .iter()
            .map(|s| self.event_of(s, now))
            .collect()
    }

    /// SCOPE's `budget` event as of NOW.
    pub fn event_of(&self, scope: &BudgetScope, now: f64) -> BudgetEvent {
        let v = self.view(scope);
        BudgetEvent {
            scope: scope.clone(),
            spent: v.spent,
            remaining: v.remaining,
            state: self.state(scope),
            burn_per_hour: self.burn(scope, now),
        }
    }

    /// SCOPE's view and each ancestor's, nearest first: what the scope counts toward.
    pub fn views_along(&self, scope: &BudgetScope) -> Vec<BudgetView> {
        let scopes: Vec<BudgetScope> = {
            let st = self.st();
            chain(&st, &key(scope))
                .iter()
                .filter_map(|k| st.scopes.get(k).cloned())
                .collect()
        };
        let mut out: Vec<BudgetView> = scopes.iter().map(|s| self.view(s)).collect();
        if out.is_empty() {
            out.push(self.view(scope));
        }
        out
    }

    /// SCOPE's view: its limits, its spend, what remains.
    pub fn view(&self, scope: &BudgetScope) -> BudgetView {
        let st = self.st();
        let k = key(scope);
        let own = |m: Option<&BTreeMap<Unit, f64>>| -> Vec<Limit> {
            m.into_iter()
                .flatten()
                .map(|(u, a)| Limit {
                    amount: *a,
                    unit: *u,
                })
                .collect()
        };
        BudgetView {
            scope: scope.clone(),
            limits: st.limits.get(&k).cloned().unwrap_or_default(),
            spent: own(st.spent.get(&k)),
            remaining: remaining_of(&st, &k)
                .into_iter()
                .map(|(unit, amount)| Limit { amount, unit })
                .collect(),
        }
    }

    /// AMOUNT of UNIT spent by SCOPE: it and every ancestor count it.  The limits it reached are returned.
    pub fn spend(&self, scope: &BudgetScope, unit: Unit, amount: f64) -> Vec<Hit> {
        self.spend_at(scope, unit, amount, now())
    }

    /// [`Budgets::spend`] at time AT (the burn ring's clock).
    pub fn spend_at(&self, scope: &BudgetScope, unit: Unit, amount: f64, at: f64) -> Vec<Hit> {
        if !(amount.is_finite() && amount > 0.0) {
            return Vec::new();
        }
        let k = key(scope);
        let mut st = self.st();
        st.scopes.insert(k.clone(), scope.clone());
        let mut hits = Vec::new();
        for c in chain(&st, &k) {
            *st.spent
                .entry(c.clone())
                .or_default()
                .entry(unit)
                .or_default() += amount;
            let ring = st.ring.entry(c.clone()).or_default();
            ring.push_back((at, unit, amount));
            while ring.front().is_some_and(|(t, ..)| *t < at - RING_SPAN) {
                ring.pop_front();
            }
            st.changed.insert(c.clone());
            hits.extend(reached(&mut st, &c, Some(unit)));
        }
        hits
    }

    /// A cumulative reading TOTAL of WHAT for SCOPE (a session's cost so far) in its agent's CONVERSATION: the rise
    /// since the last reading of that conversation is spent.  A new conversation under the same session (a manager's
    /// rotation, a fresh start after a restart) counts from zero.
    pub fn spend_total_in(
        &self,
        scope: &BudgetScope,
        what: &str,
        conversation: &str,
        unit: Unit,
        total: f64,
    ) -> Booked {
        let delta = {
            let mut st = self.st();
            let reading = format!("{what} {conversation}");
            let seen = st.seen.entry((key(scope), reading)).or_insert(0.0);
            let d = total - *seen;
            *seen = total.max(*seen);
            d.max(0.0)
        };
        Booked {
            delta,
            hits: self.spend(scope, unit, delta),
        }
    }

    /// The session SCOPE's requests are booked under job JOB at the gateway.
    pub fn bind_job(&self, job: &str, scope: &BudgetScope) {
        let mut st = self.st();
        st.scopes.insert(key(scope), scope.clone());
        st.jobs.insert(job.to_string(), key(scope));
    }

    pub fn unbind_job(&self, job: &str) {
        self.st().jobs.remove(job);
    }

    /// The gateway booked AMOUNT USD under JOB.
    pub fn usd_spent(&self, job: &str, amount: f64) -> Vec<Hit> {
        let scope = {
            let st = self.st();
            st.jobs.get(job).and_then(|k| st.scopes.get(k)).cloned()
        };
        let Some(scope) = scope else {
            return Vec::new();
        };
        let hits = self.spend(&scope, Unit::Usd, amount);
        let _ = self.0.tx.send(Note::Usd(job.to_string()));
        hits
    }

    /// The USD JOB's session may still spend: the least over its chain (none: no `usd` limit anywhere above it).
    pub fn usd_left(&self, job: &str) -> Option<f64> {
        let st = self.st();
        let k = st.jobs.get(job)?;
        remaining_of(&st, k)
            .into_iter()
            .find_map(|(u, a)| (u == Unit::Usd).then_some(a))
    }

    /// The gateway jobs of the sessions at or below SCOPE's ancestors-of-JOB chain: every job whose remaining `usd`
    /// the spend of JOB may have changed.
    pub fn jobs_sharing(&self, job: &str) -> Vec<String> {
        let st = self.st();
        let Some(k) = st.jobs.get(job) else {
            return Vec::new();
        };
        let above: BTreeSet<Key> = chain(&st, k).into_iter().skip(1).collect();
        st.jobs
            .iter()
            .filter(|(_, jk)| chain(&st, jk).iter().any(|c| above.contains(c)))
            .map(|(j, _)| j.clone())
            .collect()
    }

    /// The manager and worker scopes at or below SCOPE.
    pub fn members(&self, scope: &BudgetScope) -> Vec<BudgetScope> {
        let st = self.st();
        let k = key(scope);
        st.scopes
            .iter()
            .filter(|(_, s)| session_of(s).is_some())
            .filter(|(sk, _)| chain(&st, sk).contains(&k))
            .map(|(_, s)| s.clone())
            .collect()
    }

    /// The jobs at or below SCOPE: the runs under it (linked at approval, before any session spends), and the
    /// gateway jobs bound under it.
    pub fn jobs_under(&self, scope: &BudgetScope) -> Vec<String> {
        let st = self.st();
        let k = key(scope);
        let runs = st.scopes.iter().filter_map(|(sk, s)| match s {
            BudgetScope::Run(j) if chain(&st, sk).contains(&k) => Some(j.as_str().to_owned()),
            _ => None,
        });
        let bound = st
            .jobs
            .iter()
            .filter(|(_, jk)| chain(&st, jk).contains(&k))
            .map(|(j, _)| j.clone());
        runs.chain(bound)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    /// The gateway job of session SID, if bound.
    pub fn job_of(&self, sid: &str) -> Vec<String> {
        let st = self.st();
        st.jobs
            .iter()
            .filter(|(_, k)| st.scopes.get(*k).and_then(session_of) == Some(sid))
            .map(|(j, _)| j.clone())
            .collect()
    }

    /// A meter reading by the session SCOPE: PROVIDER's WINDOW is at SHARE (0 to 1) at time NOW.  The rise since the
    /// session's last reading of that window is its `limit-share` spend when the window is the fullest of the
    /// provider's (the one that binds first); another window's rise is not added to it.
    pub fn reading(
        &self,
        scope: &BudgetScope,
        provider: &str,
        window: &str,
        share: f64,
        resets_at: Option<f64>,
        now: f64,
    ) -> Vec<Hit> {
        if !(0.0..=1.0 + 1e-9).contains(&share) {
            return Vec::new();
        }
        let mkey = meter_key(provider, window);
        let (fresh, binds) = {
            let mut st = self.st();
            let fresh = st
                .meters
                .entry(mkey.clone())
                .or_default()
                .read(now, share, resets_at);
            let fullest = st
                .meters
                .iter()
                .filter(|(k, _)| k.starts_with(&format!("{provider}/")))
                .filter_map(|(_, m)| m.samples.back().map(|(_, s)| *s))
                .fold(0.0_f64, f64::max);
            (fresh, share + 1e-9 >= fullest)
        };
        if fresh {
            self.save();
        }
        let what = format!("limit-share:{mkey}");
        let delta = {
            let mut st = self.st();
            let seen = st.seen.entry((key(scope), what)).or_insert(share);
            let d = share - *seen;
            // a window that reset starts the session's reading over
            *seen = share;
            d
        };
        if binds {
            self.spend(scope, Unit::LimitShare, delta)
        } else {
            Vec::new()
        }
    }

    /// PROVIDER's WINDOW meter readings of the last eight days as of NOW, one for each quarter hour at most, in time
    /// order.
    pub fn history(&self, provider: &str, window: &str, now: f64) -> Vec<(f64, f64)> {
        self.st()
            .meters
            .get(&meter_key(provider, window))
            .map(|m| {
                m.history
                    .iter()
                    .copied()
                    .filter(|(t, _)| now - *t < HISTORY_SPAN)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The pace of PROVIDER's meters (each window), or of every meter, as of NOW; with HISTORY, each carries its
    /// readings of the last eight days.
    pub fn pace(&self, provider: Option<&str>, now: f64) -> Vec<Pace> {
        self.pace_with(provider, now, false)
    }

    pub fn pace_with(&self, provider: Option<&str>, now: f64, history: bool) -> Vec<Pace> {
        self.st()
            .meters
            .iter()
            .filter_map(|(k, m)| {
                let (p, w) = k.split_once('/')?;
                provider
                    .is_none_or(|want| want == p)
                    .then(|| m.pace(p, w, now, history))?
            })
            .collect()
    }
}

/// `_claude/rateLimit`'s reading: `(share, resets_at)`.  `utilization` is the share; a rejection with none is a full
/// window.
pub fn parse_claude(params: &Value) -> Option<(f64, Option<f64>)> {
    let resets = params.get("resetsAt").and_then(Value::as_f64);
    match params.get("utilization").and_then(Value::as_f64) {
        Some(u) => Some((u, resets)),
        None => (params.get("status").and_then(Value::as_str) == Some("rejected"))
            .then_some((1.0, resets)),
    }
}

/// The window a Claude reading is of: `5h` for `five_hour`, `week` for `seven_day`, else the agent's own name for it
/// (a reading with none is the five-hour one, which is what the agent reported before it named them).
pub fn claude_window(params: &Value) -> String {
    match params.get("rateLimitType").and_then(Value::as_str) {
        Some("five_hour") | None => "5h".to_owned(),
        Some("seven_day") => "week".to_owned(),
        Some(other) => other.to_owned(),
    }
}

/// `_codex/rateLimits`' readings: each window the agent reports, named by its length (300 minutes `5h`, 10080 `week`;
/// else the agent's own name, `primary` or `secondary`), with its `usedPercent` as a share and when it resets.
pub fn parse_codex(params: &Value) -> Vec<(String, f64, Option<f64>)> {
    ["primary", "secondary"]
        .iter()
        .filter_map(|name| Some((*name, params.get(name)?)))
        .filter_map(|(name, w)| {
            let window = match w.get("windowMinutes").and_then(Value::as_u64) {
                Some(300) => "5h".to_owned(),
                Some(10080) => "week".to_owned(),
                _ => name.to_owned(),
            };
            Some((
                window,
                w.get("usedPercent").and_then(Value::as_f64)? / 100.0,
                w.get("resetsAt").and_then(Value::as_f64),
            ))
        })
        .collect()
}

/// An agent's extension notification as meter readings: `(provider, window, share, resets_at)` for each window it
/// reports.
pub fn meter_of(method: &str, params: &Value) -> Vec<(&'static str, String, f64, Option<f64>)> {
    match method {
        "_claude/rateLimit" => parse_claude(params)
            .map(|(s, r)| ("claude", claude_window(params), s, r))
            .into_iter()
            .collect(),
        "_codex/rateLimits" => parse_codex(params)
            .into_iter()
            .map(|(w, s, r)| ("codex", w, s, r))
            .collect(),
        _ => Vec::new(),
    }
}

pub async fn get(f: &Front, _: &Caller, p: BudgetGetParams) -> Result<BudgetView, Error> {
    Ok(f.core.budgets.view(&p.scope))
}

/// Nodes in a page of `budget/tree`.
const TREE_PAGE: usize = 200;

/// The slice of KEYS a page of SIZE after AFTER covers (the start when AFTER is none or unknown), and the `next` to ask
/// for the page after it.
fn page_of(
    keys: &[&str],
    after: Option<&str>,
    size: usize,
) -> (std::ops::Range<usize>, Option<String>) {
    let start = after
        .and_then(|a| keys.iter().position(|k| *k == a).map(|i| i + 1))
        .unwrap_or(0);
    let end = (start + size).min(keys.len());
    let next = (end < keys.len() && end > start).then(|| keys[end - 1].to_owned());
    (start..end, next)
}

/// The titles of the graph's specs, plans and tasks, by entity id.
async fn titles(f: &Front) -> BTreeMap<String, String> {
    f.writer
        .db
        .read(|c| {
            let mut q = c.prepare(
                "select id, coalesce(title, '') from entity where retired_tx is null and kind in ('spec', 'plan', 'task')",
            )?;
            let rows = q
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows.into_iter().collect())
        })
        .await
        .unwrap_or_default()
}

pub async fn tree(f: &Front, _: &Caller, p: BudgetTreeParams) -> Result<BudgetTree, Error> {
    let b = &f.core.budgets;
    let all = b.tree_scopes(p.root.as_ref(), p.depth);
    let titles = titles(f).await;
    let names: BTreeMap<String, String> = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| {
            (
                s.id.to_string(),
                s.snapshot().name.unwrap_or_else(|| s.id.to_string()),
            )
        })
        .collect();
    // "run N": a parent's runs in start order (the job ids sort by their start)
    let mut runs: BTreeMap<Option<Key>, Vec<Key>> = BTreeMap::new();
    for (k, s, parent) in &all {
        if matches!(s, BudgetScope::Run(_)) {
            runs.entry(parent.as_ref().map(key))
                .or_default()
                .push(k.clone());
        }
    }
    for v in runs.values_mut() {
        v.sort();
    }
    let label = |k: &Key, s: &BudgetScope, parent: &Option<BudgetScope>| -> String {
        match s {
            BudgetScope::Spec(i) | BudgetScope::Plan(i) | BudgetScope::Task(i) => titles
                .get(i.as_str())
                .filter(|t| !t.is_empty())
                .cloned()
                .unwrap_or_else(|| i.as_str().to_owned()),
            BudgetScope::Project(i) => i.as_str().to_owned(),
            BudgetScope::Run(_) => {
                let n = runs
                    .get(&parent.as_ref().map(key))
                    .and_then(|v| v.iter().position(|x| x == k))
                    .map_or(1, |i| i + 1);
                format!("run {n}")
            }
            BudgetScope::Manager(i) | BudgetScope::Worker(i) => names
                .get(i.as_str())
                .cloned()
                .unwrap_or_else(|| i.as_str().to_owned()),
        }
    };
    let keys: Vec<&str> = all.iter().map(|(k, ..)| k.as_str()).collect();
    let (range, next) = page_of(&keys, p.after.as_ref().map(|a| a.as_str()), TREE_PAGE);
    let page: Vec<_> = all[range].iter().collect();
    let at = now();
    Ok(BudgetTree {
        nodes: page
            .into_iter()
            .map(|(k, s, parent)| b.node(s, parent.as_ref(), label(k, s, parent), at))
            .collect(),
        next,
    })
}

pub async fn set(f: &Front, _: &Caller, p: BudgetSetParams) -> Result<BudgetView, Error> {
    let b = &f.core.budgets;
    let hits = b.set(&p.scope, p.limits.into_inner());
    b.save();
    b.notify(hits);
    refresh_scope(f, &p.scope).await;
    Ok(b.view(&p.scope))
}

/// `budget/raise`: card P.card (an open `budget` card) is settled as a raise; its scope (the one that hit, never
/// the run above it) gets P.limits over its other units.  With P.resume, a job's card resumes its job
/// ([`crate::runner::fallback::resume`]) and any other card sends each session it paused the continue ("resumed by
/// you"), except where a limit still holds them: those are named in `held`, with the scope that holds them.
pub async fn raise(f: &Front, c: &Caller, p: BudgetRaiseParams) -> Result<BudgetRaised, Error> {
    use crate::runner::invalid;
    let cid = i64::try_from(p.card).map_err(|_| invalid("card"))?;
    let card = f
        .writer
        .db
        .read(move |c| norn::read::cards::card(c, cid))
        .await
        .map_err(crate::coord::fail)?
        .ok_or_else(|| invalid(format!("No card {cid}")))?;
    if card.kind.as_deref() != Some("budget") {
        return Err(invalid(format!("Card {cid} is not a budget card")));
    }
    if card.state.as_deref() != Some("open") {
        return Err(invalid(format!("Card {cid} is already settled")));
    }
    let mut data = card.data.clone().unwrap_or(Value::Null);
    let scope: BudgetScope = data
        .get("scope")
        .cloned()
        .and_then(|s| serde_json::from_value(s).ok())
        .ok_or_else(|| invalid(format!("Card {cid} names no scope")))?;
    let limits = p.limits.into_inner();
    data["raised"] = json!(limits);
    let settled = f
        .writer
        .write(c, "cards/settle", move |tx| {
            let settled = norn::write::cards::card_settle(tx, cid, "raise", now())?;
            if settled {
                let set = norn::write::cards::CardSet {
                    title: None,
                    data: Some(data),
                    state: None,
                };
                norn::write::cards::card_set(tx, cid, set, now())?;
            }
            Ok(settled)
        })
        .await
        .map_err(crate::coord::fail)?;
    if !settled {
        return Err(invalid(format!("Card {cid} is already settled")));
    }
    let b = &f.core.budgets;
    let hits = b.raise(&scope, limits);
    b.save();
    b.notify(hits);
    refresh_scope(f, &scope).await;
    let paused: Vec<String> = card
        .data
        .as_ref()
        .and_then(|d| d.get("sessions"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let (mut resumed, mut held) = (Vec::new(), Vec::new());
    // each session the card paused: still held, or (with resume) sent the continue
    let mut go_on = |sid: String, resume: bool| match b.holder_of_session(&sid) {
        Some(by) => held.push(BudgetHeld { id: sid, by }),
        None => {
            // the raise lifts the budget's own hold on a turn running (not the supervisor's, a manager's, ...)
            let _ = f.core.agents.clear_hold(&sid, HoldSource::Budget);
            if resume && f.core.agents.resume_paused(&sid).unwrap_or(false) {
                resumed.push(sid);
            }
        }
    };
    match card.job.clone() {
        Some(job) => {
            let run = runstav::types::Id::new(job.clone())
                .map_err(|_| invalid(format!("Card {cid}: no job {job}")))?;
            let holder = b.holder(&BudgetScope::Run(run.clone()));
            // the job goes on only when nothing above its run holds it; its paused sessions get the continue first
            // (a pause cancels a turn: queued nothing, the session would wait idle)
            for sid in paused {
                go_on(sid, p.resume && holder.is_none());
            }
            match holder {
                Some(by) => held.insert(0, BudgetHeld { id: job, by }),
                None if p.resume => {
                    let w = runstav::methods::jobs::WithLimits {
                        id: run,
                        limits: None,
                    };
                    crate::runner::fallback::resume(f, c, w).await?;
                    resumed.insert(0, job);
                }
                None => {}
            }
        }
        None => {
            for sid in paused {
                go_on(sid, p.resume);
            }
        }
    }
    f.writer.signals.wrote();
    Ok(BudgetRaised {
        view: b.view(&scope),
        resumed,
        held,
    })
}

pub async fn pace(f: &Front, _: &Caller, p: PaceParams) -> Result<Paces, Error> {
    Ok(Paces {
        meters: f.core.budgets.pace_with(
            p.provider.as_ref().map(|s| s.as_str()),
            now(),
            p.history.unwrap_or(false),
        ),
    })
}

fn now() -> f64 {
    crate::clock::wall_secs()
}

/// The registrations of every session at or below SCOPE carry what is left of the nested `usd` limit.
pub async fn refresh_scope(f: &Front, scope: &BudgetScope) {
    let jobs: Vec<String> = f
        .core
        .budgets
        .members(scope)
        .iter()
        .filter_map(session_of)
        .flat_map(|sid| f.core.budgets.job_of(sid))
        .collect();
    for j in jobs {
        f.gate.follow_budget(&f.core.budgets, &j).await;
    }
}

/// The consumer of [`Note`]s (spawned once by the server): a limit reached pauses every session below it and makes
/// its card; gateway spend refreshes the registrations that share its ancestors.
pub async fn run(f: Arc<Front>, mut notes: mpsc::UnboundedReceiver<Note>) {
    while let Some(n) = notes.recv().await {
        match n {
            Note::Hit(h) => reached_limit(&f, &h).await,
            Note::Usd(job) => {
                for j in f.core.budgets.jobs_sharing(&job) {
                    f.gate.follow_budget(&f.core.budgets, &j).await;
                }
            }
        }
        f.core.budgets.save();
    }
}

/// Once a second, a `budget` event for every scope whose spend moved: a burst of spend is one event, the last value.
pub async fn broadcast_changes(f: Arc<Front>) {
    let mut tick = crate::clock::interval(std::time::Duration::from_secs(1));
    loop {
        tick.tick().await;
        for e in f.core.budgets.flush(now()) {
            f.broadcast("budget", serde_json::to_value(&e).unwrap_or(Value::Null));
        }
        // the map's items carry their budget: they read it again
        f.writer.signals.map.notify_one();
    }
}

async fn reached_limit(f: &Front, h: &Hit) {
    let sessions: Vec<String> = f
        .core
        .budgets
        .members(&h.scope)
        .iter()
        .filter_map(|s| session_of(s).map(str::to_string))
        .collect();
    for sid in &sessions {
        // a session that has exited or is unknown is not paused
        let _ = f.core.agents.cancel_after_tool(sid, HoldSource::Budget);
    }
    for sid in &sessions {
        for j in f.core.budgets.job_of(sid) {
            f.gate.follow_budget(&f.core.budgets, &j).await;
        }
    }
    let unit = serde_json::to_value(h.unit).unwrap_or(Value::Null);
    let data = json!({
        "scope": h.scope, "unit": unit, "limit": h.limit, "spent": h.spent,
        "estimate": h.estimate(), "sessions": sessions,
        "choices": ["raise", "stop"],
    });
    let title = format!(
        "{} reached its {} limit{}",
        key(&h.scope),
        unit.as_str().unwrap_or("?"),
        if h.estimate() { " (estimate)" } else { "" }
    );
    // below a run (a plan's, a spec's): each run pauses and the card is its job's
    let jobs = f.core.budgets.jobs_under(&h.scope);
    if !jobs.is_empty() {
        for j in jobs {
            if let Some(id) = crate::runner::fallback::pause_job(f, &j, &title, data.clone()).await
            {
                f.broadcast("budget-limit", json!({"card": id, "data": data}));
            }
        }
        return;
    }
    let card = norn::write::cards::NewCard {
        job: None,
        task: None,
        kind: Some("budget".into()),
        title: Some(title),
        data: Some(data.clone()),
    };
    let at = now();
    let made = f
        .writer
        .db
        .write(
            urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "budget"),
            move |tx| norn::write::cards::card_create(tx, card, at),
        )
        .await;
    match made {
        Ok(id) => {
            f.writer.signals.wrote();
            f.broadcast("budget-limit", json!({"card": id, "data": data}));
        }
        Err(e) => tracing::warn!("a budget card was not made: {e}"),
    }
}

#[cfg(test)]
mod tests;
