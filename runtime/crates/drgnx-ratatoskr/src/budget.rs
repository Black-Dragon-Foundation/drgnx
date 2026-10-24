//! Budgets, units and pace (Task 20; `docs/guide/agents.md`, "Budgets"): limits on a project, plan, manager or
//! worker, each in a named unit, the remaining amount the least over its ancestors; the gateway admits `usd` against
//! the nested minimum; subscription meters (`_claude/rateLimit`, Codex's window) as `limit-share` estimates; at a
//! limit the agent is paused with a `budget` card.  Methods `budget/get`, `budget/set`, `pace/get`.
//!
//! - **Units never mix.**  A limit in one unit is only ever reduced by spend in that unit (`usd` is what the gateway
//!   measured, `usd-est` what an agent reported at API prices, `limit-share` a subscription window's share, `tokens`,
//!   `count`); nothing is converted.  `usd-est` and `limit-share` are estimates and are labelled so.
//! - **Nesting.**  A spend counts against the spending scope and every ancestor (`link`: worker under manager, manager
//!   or worker under plan, plan under project); what remains is the least over the chain.  A session is a scope from
//!   its start; the plan runner (Task 16a) and the manager role (Task 25) link the upper levels.
//! - **Reaching a limit counts** (as the gateway's `over`): every session at or below the scope is paused after its
//!   tool call (`Hub::cancel_after_tool`) and one `budget` card is made per scope and unit, until the limit is set
//!   again.  The gateway's registration of a session carries `job spend + remaining usd`, kept current as siblings
//!   spend, so a request over the nested minimum is refused with `budget_exceeded`.
//! - **Pace** is linear over the last 24 h of a meter's readings; the clock is an argument, never read here.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::{
    BudgetGetParams, BudgetScope, BudgetSetParams, BudgetView, Pace, PaceParams, Paces,
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
        BudgetScope::Plan(i) => format!("plan:{}", i.as_str()),
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

/// A subscription meter: its readings of the last [`PACE_WINDOW`].
#[derive(Clone, Debug, Default)]
struct Meter {
    /// `(at, share)` in time order.
    samples: VecDeque<(f64, f64)>,
    resets_at: Option<f64>,
}

impl Meter {
    fn read(&mut self, at: f64, share: f64, resets_at: Option<f64>) {
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

    fn pace(&self, provider: &str, now: f64) -> Option<Pace> {
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
            used_share: used,
            rate_per_hour: rate,
            exhausted_at,
            resets_at: self.resets_at,
            estimate: true,
        })
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
}

/// What `runtime.db` keeps.
#[derive(Default, Serialize, Deserialize)]
struct Saved {
    limits: Vec<(BudgetScope, Vec<Limit>)>,
    spent: Vec<(BudgetScope, Vec<Limit>)>,
    parents: Vec<(BudgetScope, BudgetScope)>,
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

fn remaining_of(st: &St, key: &str) -> Vec<(Unit, f64)> {
    let mut least: BTreeMap<Unit, f64> = BTreeMap::new();
    for k in chain(st, key) {
        for l in st.limits.get(&k).into_iter().flatten() {
            let spent = st
                .spent
                .get(&k)
                .and_then(|m| m.get(&l.unit))
                .copied()
                .unwrap_or(0.0);
            let left = (l.amount - spent).max(0.0);
            least
                .entry(l.unit)
                .and_modify(|m| *m = m.min(left))
                .or_insert(left);
        }
    }
    least.into_iter().collect()
}

/// The limits KEY has that its spend has reached and that were not reported yet.
fn reached(st: &mut St, key: &str, only: Option<Unit>) -> Vec<Hit> {
    let mut hits = Vec::new();
    for l in st.limits.get(key).cloned().into_iter().flatten() {
        if only.is_some_and(|u| u != l.unit) {
            continue;
        }
        let spent = st
            .spent
            .get(key)
            .and_then(|m| m.get(&l.unit))
            .copied()
            .unwrap_or(0.0);
        if spent >= l.amount
            && let Some(scope) = st.scopes.get(key).cloned()
            && st.hit.insert((key.to_string(), l.unit))
        {
            hits.push(Hit {
                scope,
                unit: l.unit,
                limit: l.amount,
                spent,
            });
        }
    }
    hits
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
                Ok(s) => self.restore(s),
                Err(e) => tracing::warn!("the saved budgets do not read: {e}"),
            }
        }
        let _ = self.0.db.set(db);
    }

    fn restore(&self, s: Saved) {
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
    }

    fn saved(&self) -> Saved {
        let st = self.st();
        let scope = |k: &Key| st.scopes.get(k).cloned();
        Saved {
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
        let k = key(scope);
        let mut st = self.st();
        st.scopes.insert(k.clone(), scope.clone());
        st.hit.retain(|(hk, _)| *hk != k);
        if limits.is_empty() {
            st.limits.remove(&k);
            return Vec::new();
        }
        st.limits.insert(k.clone(), limits);
        reached(&mut st, &k, None)
    }

    /// CHILD counts toward PARENT.
    pub fn link(&self, child: &BudgetScope, parent: &BudgetScope) {
        let (c, p) = (key(child), key(parent));
        let mut st = self.st();
        st.scopes.insert(c.clone(), child.clone());
        st.scopes.insert(p.clone(), parent.clone());
        st.parent.insert(c, p);
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
            hits.extend(reached(&mut st, &c, Some(unit)));
        }
        hits
    }

    /// A cumulative reading TOTAL of WHAT for SCOPE (a session's cost so far): the rise since the last is spent.
    pub fn spend_total(&self, scope: &BudgetScope, what: &str, unit: Unit, total: f64) -> Vec<Hit> {
        let delta = {
            let mut st = self.st();
            let seen = st.seen.entry((key(scope), what.to_string())).or_insert(0.0);
            let d = total - *seen;
            *seen = total.max(*seen);
            d
        };
        self.spend(scope, unit, delta)
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

    /// The gateway jobs bound at or below SCOPE.
    pub fn jobs_under(&self, scope: &BudgetScope) -> Vec<String> {
        let st = self.st();
        let k = key(scope);
        st.jobs
            .iter()
            .filter(|(_, jk)| chain(&st, jk).contains(&k))
            .map(|(j, _)| j.clone())
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

    /// A meter reading by the session SCOPE: PROVIDER's window is at SHARE (0 to 1) at time NOW.  The rise since the
    /// session's last reading is its `limit-share` spend.
    pub fn reading(
        &self,
        scope: &BudgetScope,
        provider: &str,
        share: f64,
        resets_at: Option<f64>,
        now: f64,
    ) -> Vec<Hit> {
        if !(0.0..=1.0 + 1e-9).contains(&share) {
            return Vec::new();
        }
        self.st()
            .meters
            .entry(provider.to_string())
            .or_default()
            .read(now, share, resets_at);
        let what = format!("limit-share:{provider}");
        let delta = {
            let mut st = self.st();
            let seen = st.seen.entry((key(scope), what)).or_insert(share);
            let d = share - *seen;
            // a window that reset starts the session's reading over
            *seen = share;
            d
        };
        self.spend(scope, Unit::LimitShare, delta)
    }

    /// The pace of PROVIDER's meter, or of every meter, as of NOW.
    pub fn pace(&self, provider: Option<&str>, now: f64) -> Vec<Pace> {
        self.st()
            .meters
            .iter()
            .filter(|(p, _)| provider.is_none_or(|w| w == p.as_str()))
            .filter_map(|(p, m)| m.pace(p, now))
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

/// `_codex/rateLimits`' reading: the fullest window's `usedPercent` as a share.
pub fn parse_codex(params: &Value) -> Option<(f64, Option<f64>)> {
    ["primary", "secondary"]
        .iter()
        .filter_map(|w| params.get(w))
        .filter_map(|w| {
            Some((
                w.get("usedPercent").and_then(Value::as_f64)? / 100.0,
                w.get("resetsAt").and_then(Value::as_f64),
            ))
        })
        .max_by(|a, b| a.0.total_cmp(&b.0))
}

/// An agent's extension notification as a meter reading: `(provider, share, resets_at)`.
pub fn meter_of(method: &str, params: &Value) -> Option<(&'static str, f64, Option<f64>)> {
    match method {
        "_claude/rateLimit" => parse_claude(params).map(|(s, r)| ("claude", s, r)),
        "_codex/rateLimits" => parse_codex(params).map(|(s, r)| ("codex", s, r)),
        _ => None,
    }
}

pub async fn get(f: &Front, _: &Caller, p: BudgetGetParams) -> Result<BudgetView, Error> {
    Ok(f.core.budgets.view(&p.scope))
}

pub async fn set(f: &Front, _: &Caller, p: BudgetSetParams) -> Result<BudgetView, Error> {
    let b = &f.core.budgets;
    let hits = b.set(&p.scope, p.limits.into_inner());
    b.save();
    b.notify(hits);
    refresh_scope(f, &p.scope).await;
    Ok(b.view(&p.scope))
}

pub async fn pace(f: &Front, _: &Caller, p: PaceParams) -> Result<Paces, Error> {
    let _ = not_yet;
    Ok(Paces {
        meters: f
            .core
            .budgets
            .pace(p.provider.as_ref().map(|s| s.as_str()), now()),
    })
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
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
        let _ = f.core.agents.cancel_after_tool(sid);
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
    // below a plan run: the run pauses and the card is the job's
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
