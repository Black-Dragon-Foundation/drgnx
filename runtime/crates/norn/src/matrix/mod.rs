//! The permissions matrix: rows (actions) by columns (roles, named agents, providers), three shipped presets,
//! combination (layers, then the most restrictive matching column) and narrowing (a child's grants are a subset of
//! its parent's).  The words are `runstav::methods::matrix`'s; this module is the policy on them (`docs/develop/
//! coordination.md`, "The permissions matrix").  The hub's gate (Task 12) calls [`effective`] and [`decide`].

mod narrow;
mod presets;
#[cfg(test)]
mod tests;

pub use narrow::{Widening, narrow};
pub use presets::preset;
pub use runstav::methods::matrix::{
    Action, Cell, Column, Limit, Preset, Role, TimePreset, Unit, Verdict, When,
};

use runstav::methods::matrix::WhoParam;
use runstav::types::Bounded;
use std::collections::BTreeMap;

/// One layer of cells: ACTION in COLUMN.  A preset, the user's overrides, a project's or a plan's are each a `Matrix`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Matrix {
    pub cells: BTreeMap<(Action, Column), Cell>,
}

impl Matrix {
    /// Set the cell of ACTION in COLUMN.
    pub fn set(&mut self, action: Action, column: Column, cell: Cell) {
        self.cells.insert((action, column), cell);
    }
}

/// A column named by an agent profile.
pub fn agent_column(name: &str) -> Column {
    Column::Agent(Bounded(name.to_string()))
}

/// A column named by a provider.
pub fn provider_column(name: &str) -> Column {
    Column::Provider(Bounded(name.to_string()))
}

/// Who acts: the columns that match it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Who {
    pub role: Option<Role>,
    pub agent: Option<String>,
    pub provider: Option<String>,
}

impl From<&WhoParam> for Who {
    fn from(w: &WhoParam) -> Who {
        Who {
            role: w.role,
            agent: w.agent.as_ref().map(|a| a.0.clone()),
            provider: w.provider.as_ref().map(|p| p.0.clone()),
        }
    }
}

impl Who {
    fn matches(&self, c: &Column) -> bool {
        match c {
            Column::Role(r) => self.role == Some(*r),
            Column::Agent(a) => self.agent.as_deref() == Some(a.0.as_str()),
            Column::Provider(p) => self.provider.as_deref() == Some(p.0.as_str()),
        }
    }
}

/// What one session may do: a cell per action; an action without a cell is Never.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Effective {
    pub cells: BTreeMap<Action, Cell>,
}

impl Effective {
    /// ACTION's cell (Never when there is none).
    pub fn cell(&self, a: Action) -> Cell {
        self.cells.get(&a).copied().unwrap_or(NEVER)
    }
}

pub(crate) const NEVER: Cell = Cell {
    verdict: Verdict::Never,
    limit: None,
};

/// The rows no layer, column or override can open.
pub(crate) fn always_never(a: Action) -> bool {
    matches!(a, Action::Unsandboxed | Action::UserPrivate)
}

/// The more restrictive of two cells.  A greater verdict wins; at the same verdict a limit beats none, and limits in
/// one unit take the smaller amount.  Limits in different units do not compare: the cell becomes Ask (at least) with
/// no limit, so the user is asked rather than a guess widening anything.
fn tighter(x: Cell, y: Cell) -> Cell {
    if x.verdict != y.verdict {
        return if x.verdict > y.verdict { x } else { y };
    }
    let limit = match (x.limit, y.limit) {
        (None, l) | (l, None) => l,
        (Some(a), Some(b)) if a.unit == b.unit => Some(if b.amount < a.amount { b } else { a }),
        _ => {
            return Cell {
                verdict: x.verdict.max(Verdict::Ask),
                limit: None,
            };
        }
    };
    Cell {
        verdict: x.verdict,
        limit,
    }
}

/// The cells WHO gets from LAYERS (preset, user overrides, project, plan; a later layer replaces a cell), the most
/// restrictive of the matching columns.  `unsandboxed` and `user.private` are Never whatever the layers say.
pub fn effective(layers: &[&Matrix], who: &Who) -> Effective {
    let mut merged: BTreeMap<&(Action, Column), Cell> = BTreeMap::new();
    for layer in layers {
        for (k, c) in &layer.cells {
            merged.insert(k, *c);
        }
    }
    let mut cells: BTreeMap<Action, Cell> = BTreeMap::new();
    for ((a, col), c) in merged {
        if who.matches(col) {
            cells
                .entry(*a)
                .and_modify(|e| *e = tighter(*e, c))
                .or_insert(c);
        }
    }
    for a in Action::ALL {
        if always_never(a) {
            cells.insert(a, NEVER);
        }
    }
    Effective { cells }
}

/// The more restrictive of X and Y at every action (a delegated worker: its own cells, its delegation and its
/// manager's cells now).
pub fn meet(x: &Effective, y: &Effective) -> Effective {
    Effective {
        cells: Action::ALL
            .into_iter()
            .map(|a| (a, tighter(x.cell(a), y.cell(a))))
            .collect(),
    }
}

/// The verdict for ACTION with AMOUNT (in the cell's unit).  Over the cell's limit the answer is Ask when
/// `spend.over` allows asking, else Never; a limit with no amount is not exceeded.
pub fn decide(e: &Effective, a: Action, amount: Option<f64>) -> Verdict {
    let cell = e.cell(a);
    if cell.verdict == Verdict::Never || always_never(a) {
        return Verdict::Never;
    }
    if let (Some(limit), Some(amount)) = (cell.limit, amount)
        && (amount.is_nan() || amount > limit.amount)
    {
        return if e.cell(Action::SpendOver).verdict == Verdict::Never {
            Verdict::Never
        } else {
            Verdict::Ask
        };
    }
    cell.verdict
}

/// Minute-of-day MINUTE inside WHEN's range (`from > to` wraps past midnight; `from == to` is empty).
fn between(from: u16, to: u16, minute: u16) -> bool {
    if from < to {
        (from..to).contains(&minute)
    } else {
        from > to && (minute >= from || minute < to)
    }
}

/// The preset in force: while AWAY the first `Away` time preset, else the first `Between` that holds at MINUTE, else
/// BASE.
pub fn active(base: Preset, t: &[TimePreset], away: bool, minute: u16) -> Preset {
    if away && let Some(p) = t.iter().find(|p| p.when == When::Away) {
        return p.preset;
    }
    t.iter()
        .find(|p| matches!(p.when, When::Between(f, to) if between(f, to, minute)))
        .map_or(base, |p| p.preset)
}
