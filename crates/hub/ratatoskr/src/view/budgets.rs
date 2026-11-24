//! The Budgets page (Flow Task 22c; timeline and budget spec §7.5): the subscription meters with their paces, then the
//! scope tree as kit rows built in the hub, with a limit cell that edits in place and a run's share of its plan.  The
//! rows come from `budget/tree` (hub H6, `BudgetNode.share_of_parent`), read a page at a time, `pace/get` with history
//! (H13) and each plan's `forecast/plan` (H10).

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views};
use rodd::kit::{self, Comp, KitEnv, MeterSize, MeterState, MeterUnit, ProgressKind};
use rodd::{Row, RowBuilder};
use runstav::methods::budgets_page::{Set, Subscribe, ViewId};
use runstav::methods::forecast::{CostRange, ForecastPlanParams};
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::{
    BudgetNode, BudgetScope, BudgetState, BudgetTree, BudgetTreeParams, Pace, PaceParams,
};
use runstav::types::Bounded;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, MutexGuard};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    saman::lock(m)
}

/// What a page shows: the tree read so far, the meters, and the plans' forecasts (a plan's id → its cost range).
#[derive(Clone)]
pub struct Shown {
    pub tree: BudgetTree,
    pub paces: Vec<Pace>,
    pub forecasts: BTreeMap<String, CostRange>,
}

impl Default for Shown {
    fn default() -> Self {
        Shown {
            tree: BudgetTree {
                nodes: Vec::new(),
                next: None,
            },
            paces: Vec::new(),
            forecasts: BTreeMap::new(),
        }
    }
}

/// The Budgets pages shown, by connection and view.
#[derive(Default)]
pub struct Pages {
    views: Mutex<HashMap<(u64, String), Shown>>,
}

impl Pages {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }
}

impl Views {
    /// The rows of KEY's Budgets page for its class; false when the view is none.
    pub(super) fn budgets_build(&self, f: &Front, key: &Key) -> bool {
        let Some(shown) = lock(&self.budget_pages.views)
            .get(&(key.0, key.1.clone()))
            .cloned()
        else {
            return false;
        };
        self.publish_built(f, key, |env, _| {
            (
                rows_with(
                    &shown.tree,
                    &shown.paces,
                    &shown.forecasts,
                    &super::kit_env(env),
                ),
                Vec::new(),
            )
        });
        true
    }

    fn budgets_show(&self, f: &Front, conn: u64, view: &str, shown: Shown) {
        lock(&self.budget_pages.views).insert((conn, view.to_owned()), shown);
        for class in self.classes(conn, view) {
            self.budgets_build(f, &(conn, view.to_owned(), class));
        }
    }
}

/// How many plans a page asks a forecast for (`forecast/plan`'s bound).
const FORECASTS: usize = 32;

/// Read the meters and the tree for CONN's VIEW: the first page of the tree is shown as soon as it is read, then each
/// later page is added to it (the tree is never fetched unpaged).
async fn load(f: &Front, c: &Caller, view: &str) -> Result<(), Error> {
    let paces = crate::budget::pace(
        f,
        c,
        PaceParams {
            history: Some(true),
            provider: None,
        },
    )
    .await
    .map(|p| p.meters)
    .unwrap_or_default();
    let mut shown = Shown {
        paces,
        ..Shown::default()
    };
    let mut after: Option<String> = None;
    loop {
        let page = crate::budget::tree(
            f,
            c,
            BudgetTreeParams {
                root: None,
                depth: None,
                after: after.take().map(Bounded),
            },
        )
        .await?;
        let first = shown.tree.nodes.is_empty();
        shown.tree.nodes.extend(page.nodes);
        shown.tree.next = page.next.clone();
        if first {
            self_forecasts(f, &mut shown).await;
        }
        f.core.views.budgets_show(f, c.conn_id, view, shown.clone());
        match page.next {
            Some(n)
                if lock(&f.core.views.budget_pages.views)
                    .contains_key(&(c.conn_id, view.to_owned())) =>
            {
                after = Some(n)
            }
            _ => return Ok(()),
        }
    }
}

/// Each plan of the first page gets its own forecast (a plan alone in the draw), its dollar range at API prices.
async fn self_forecasts(f: &Front, shown: &mut Shown) {
    let plans: Vec<runstav::methods::graph::ParsedId> = shown
        .tree
        .nodes
        .iter()
        .filter_map(|n| match &n.scope {
            BudgetScope::Plan(p) => Some(p.clone()),
            _ => None,
        })
        .take(FORECASTS)
        .collect();
    for p in plans {
        let id = scope_id(&BudgetScope::Plan(p.clone()));
        let Ok(fc) = crate::forecast::plan(
            f,
            ForecastPlanParams {
                plans: Bounded(vec![p]),
            },
        )
        .await
        else {
            continue;
        };
        let cost = fc
            .running
            .first()
            .map(|r| r.remaining.cost.clone())
            .unwrap_or(fc.forecast.cost);
        if let Some(c) = cost
            .into_iter()
            .find(|c| matches!(c.unit, Unit::Usd | Unit::UsdEst))
        {
            shown.forecasts.insert(id, c);
        }
    }
}

/// `budgets/page/subscribe`.
pub async fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    lock(&f.core.views.budget_pages.views).insert((c.conn_id, p.view.clone()), Shown::default());
    load(f, c, &p.view).await?;
    Ok(true)
}

/// `budgets/page/set`: refresh reads the tree and the meters again.
pub async fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    if !lock(&f.core.views.budget_pages.views).contains_key(&(c.conn_id, p.view.clone())) {
        return Err(Error {
            code: ErrorCode::InvalidParams,
            message: "not a Budgets page view (budgets/page/subscribe first)".into(),
            path: Some("view".into()),
        });
    }
    if p.refresh {
        load(f, c, &p.view).await?;
    }
    Ok(true)
}

/// `budgets/page/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    Ok(lock(&f.core.views.budget_pages.views)
        .remove(&(c.conn_id, p.view))
        .is_some())
}

/// A scope's kind and id as the wire says them: `{"plan": "p1"}` → ("plan", "p1").
fn scope_parts(s: &BudgetScope) -> (String, String) {
    match serde_json::to_value(s) {
        Ok(Value::Object(m)) => m
            .into_iter()
            .next()
            .map(|(k, v)| {
                (
                    k,
                    v.as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| v.to_string()),
                )
            })
            .unwrap_or_default(),
        _ => Default::default(),
    }
}

fn scope_id(s: &BudgetScope) -> String {
    let (k, id) = scope_parts(s);
    format!("{k}:{id}")
}

fn unit_wire(u: Unit) -> &'static str {
    match u {
        Unit::Count => "count",
        Unit::Usd => "usd",
        Unit::UsdEst => "usd-est",
        Unit::Tokens => "tokens",
        Unit::LimitShare => "limit-share",
    }
}

fn meter_unit(u: Unit) -> MeterUnit {
    match u {
        Unit::Count => MeterUnit::Count,
        Unit::Usd => MeterUnit::Usd,
        Unit::UsdEst => MeterUnit::UsdEst,
        Unit::Tokens => MeterUnit::Tokens,
        Unit::LimitShare => MeterUnit::Share,
    }
}

/// An amount as its unit says it: "$12.40", "~$12.40" for an estimate, "1.2M tok", "3", "41 %" for a share.
fn amount(l: &Limit) -> String {
    match l.unit {
        Unit::Usd => format!("${:.2}", l.amount),
        Unit::UsdEst => format!("~${:.2}", l.amount),
        Unit::Tokens if l.amount >= 1e6 => format!("{:.1}M tok", l.amount / 1e6),
        Unit::Tokens if l.amount >= 1e3 => format!("{:.0}k tok", l.amount / 1e3),
        Unit::Tokens => format!("{:.0} tok", l.amount),
        Unit::Count => format!("{:.0}", l.amount),
        Unit::LimitShare => format!("{:.0} %", l.amount * 100.0),
    }
}

fn state_word(s: BudgetState) -> &'static str {
    match s {
        BudgetState::Ok => "ok",
        BudgetState::Nearing => "nearing",
        BudgetState::Reached => "reached",
        BudgetState::None => "no limit",
    }
}

fn meter_state(s: BudgetState) -> MeterState {
    match s {
        BudgetState::Nearing => MeterState::Nearing,
        BudgetState::Reached => MeterState::Reached,
        _ => MeterState::Ok,
    }
}

/// The width of a scope's meter and a subscription's wide meter, logical px.
const METER_PX: u16 = 96;
const WIDE_PX: u16 = 240;

/// The sort: reached, nearing, ok, no limit; within a state the larger spend first.
fn rank(n: &BudgetNode) -> (u8, i64) {
    let s = match n.state {
        BudgetState::Reached => 0,
        BudgetState::Nearing => 1,
        BudgetState::Ok => 2,
        BudgetState::None => 3,
    };
    let spent = n.spent.first().map(|l| l.amount).unwrap_or(0.0);
    (s, -(spent * 1e6) as i64)
}

/// The page's rows without forecasts (the tests' interface).
pub fn rows(tree: &BudgetTree, paces: &[Pace], env: &KitEnv) -> Vec<Row> {
    rows_with(tree, paces, &BTreeMap::new(), env)
}

/// One subscription meter's row: "Claude · week 41 % used · +3.2 %/h · resets … · at the 7-day pace 78 % at reset",
/// a wide meter, and "estimate" when the pace is one; then its 8-day history as one row of bars.
fn pace_rows(p: &Pace, env: &KitEnv, out: &mut Vec<Row>) {
    let key = format!("pace:{}:{}", p.provider, p.window);
    let mut b = RowBuilder::new(key.clone());
    let mut name = p.provider.clone();
    if let Some(c) = name.get_mut(0..1) {
        c.make_ascii_uppercase();
    }
    let mut line = format!(
        "{name} · {} {:.0} % used · {:+.1} %/h",
        p.window,
        p.used_share * 100.0,
        p.rate_per_hour * 100.0
    );
    if let (Some(r7), Some(reset)) = (p.rate_7d_per_hour, p.resets_at) {
        let now = crate::clock::wall_secs();
        let at = (p.used_share + r7 * ((reset - now).max(0.0) / 3600.0)).min(9.99);
        line.push_str(&format!(
            " · at the 7-day pace {:.0} % at reset",
            at * 100.0
        ));
    }
    if p.estimate {
        line.push_str(" · estimate");
    }
    b.push(&line, None);
    b.push("  ", None);
    let state = if p.used_share >= 1.0 {
        MeterState::Reached
    } else if p.used_share >= 0.8 {
        MeterState::Nearing
    } else {
        MeterState::Ok
    };
    kit::expand(
        &mut b,
        env,
        &Comp::Meter {
            spent: p.used_share,
            limit: Some(1.0),
            unit: MeterUnit::Share,
            forecast: None,
            state,
            size: MeterSize::Wide,
            width: WIDE_PX,
            text: String::new(),
        },
    );
    out.push(b.finish());
    if !p.history.is_empty() {
        // the 8 days as one row: a bar per day, its last reading
        let mut h = RowBuilder::new(format!("{key}:history"));
        h.push("  ", None);
        let day = 86_400.0;
        let start = p.history.first().map(|x| x.0).unwrap_or(0.0);
        let mut days: BTreeMap<i64, f64> = BTreeMap::new();
        for (at, share) in &p.history {
            days.insert(((at - start) / day) as i64, *share);
        }
        for share in days.values() {
            kit::expand(
                &mut h,
                env,
                &Comp::Progress {
                    kind: ProgressKind::Bar,
                    value: share.clamp(0.0, 1.0),
                    width: 24,
                },
            );
            h.push(" ", None);
        }
        out.push(h.finish());
    }
}

/// One scope's row: indent by depth, label, meter, spent per unit (never summed), the limit cell (a kit input that sets
/// the limit in place: `drgnx-action` ["budget-limit", KIND, ID, UNIT]), the forecast, the burn, the state, and a run's
/// share of its plan.
fn scope_row(n: &BudgetNode, depth: usize, forecast: Option<&CostRange>, env: &KitEnv) -> Row {
    let (kind, id) = scope_parts(&n.scope);
    let mut b = RowBuilder::new(format!("scope:{kind}:{id}"));
    b.push(&format!("{}{}  ", "  ".repeat(depth), n.label), None);
    let binding = n.limits.first().copied();
    if let Some(l) = binding {
        let spent = n
            .spent
            .iter()
            .find(|s| s.unit == l.unit)
            .map(|s| s.amount)
            .unwrap_or(0.0);
        kit::expand(
            &mut b,
            env,
            &Comp::Meter {
                spent,
                limit: Some(l.amount),
                unit: meter_unit(l.unit),
                forecast: forecast.map(|c| (c.p50, c.p90)),
                state: meter_state(n.state),
                size: MeterSize::Row,
                width: METER_PX,
                text: String::new(),
            },
        );
        b.push("  ", None);
    }
    let spent: Vec<String> = n.spent.iter().map(amount).collect();
    b.push(&spent.join(" · "), None);
    b.push("  limit ", None);
    let unit = binding.map(|l| l.unit).unwrap_or(Unit::UsdEst);
    let from = b.pos();
    kit::expand(
        &mut b,
        env,
        &Comp::TextInput {
            text: binding.map(|l| format!("{}", l.amount)).unwrap_or_default(),
            placeholder: "none".into(),
            lines: Default::default(),
            chips: Vec::new(),
            focused: false,
            state: kit::State::Rest,
        },
    );
    let to = b.pos();
    b.prop(
        from,
        to,
        "drgnx-action",
        json!(["budget-limit", kind, id, unit_wire(unit)]),
    );
    if let Some(c) = forecast {
        b.push(&format!("  forecast ${:.0}–${:.0}", c.p50, c.p90), None);
    }
    if let Some(burn) = n.burn_per_hour.first() {
        b.push(&format!("  {}/h", amount(burn)), None);
    }
    b.push(&format!("  {}", state_word(n.state)), None);
    if let Some(share) = n.share_of_parent {
        b.push(&format!("  {:.0} % of plan", share * 100.0), None);
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-budget-scope", json!([kind, id]));
    b.finish()
}

/// Every row of the page: "Subscriptions" and its meters, then "Scopes" and the tree, each level sorted by state then
/// spend, children under their parent.
pub fn rows_with(
    tree: &BudgetTree,
    paces: &[Pace],
    forecasts: &BTreeMap<String, CostRange>,
    env: &KitEnv,
) -> Vec<Row> {
    let mut out = Vec::new();
    let header = |key: &str, title: &str, out: &mut Vec<Row>| {
        let mut h = RowBuilder::new(key);
        kit::expand(
            &mut h,
            env,
            &Comp::SectionHeader {
                title: title.into(),
                collapsible: false,
                collapsed: false,
                count: None,
                state: kit::State::Rest,
                action: None,
            },
        );
        out.push(h.finish());
    };
    if !paces.is_empty() {
        header("subscriptions", "Subscriptions", &mut out);
        for p in paces {
            pace_rows(p, env, &mut out);
        }
    }
    header("scopes", "Scopes", &mut out);
    let ids: Vec<String> = tree.nodes.iter().map(|n| scope_id(&n.scope)).collect();
    let mut children: BTreeMap<Option<String>, Vec<usize>> = BTreeMap::new();
    for (i, n) in tree.nodes.iter().enumerate() {
        // a parent not on the pages read so far: the node shows at the top level
        let parent = n.parent.as_ref().map(scope_id).filter(|p| ids.contains(p));
        children.entry(parent).or_default().push(i);
    }
    for v in children.values_mut() {
        v.sort_by_key(|&i| rank(&tree.nodes[i]));
    }
    let mut stack: Vec<(usize, usize)> = children
        .get(&None)
        .map(|v| v.iter().rev().map(|&i| (i, 0)).collect())
        .unwrap_or_default();
    while let Some((i, depth)) = stack.pop() {
        let n = &tree.nodes[i];
        out.push(scope_row(n, depth, forecasts.get(&ids[i]), env));
        if let Some(kids) = children.get(&Some(ids[i].clone())) {
            stack.extend(kids.iter().rev().map(|&k| (k, depth + 1)));
        }
    }
    out
}

#[cfg(test)]
#[path = "budgets/tests.rs"]
mod tests;
