//! Narrowing: what a manager hands a worker, or a plan a project, is a subset of what it has.

use super::{Action, Cell, Effective, Verdict};

/// ASKED asked for more than PARENT has at ACTION.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Widening {
    pub action: Action,
}

impl std::fmt::Display for Widening {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} is wider than the parent allows", self.action.id())
    }
}

impl std::error::Error for Widening {}

/// Whether CHILD is no wider than PARENT: a verdict at least as restrictive and, when the parent limits the action
/// and the child does not refuse it, a limit in the same unit that is no greater.
fn within(child: Cell, parent: Cell) -> bool {
    if child.verdict == Verdict::Never {
        return true;
    }
    if child.verdict < parent.verdict {
        return false;
    }
    match (child.limit, parent.limit) {
        (_, None) => true,
        (None, Some(_)) => false,
        (Some(c), Some(p)) => c.unit == p.unit && c.amount <= p.amount,
    }
}

/// ASKED if it is nowhere wider than PARENT, else the first action that is.
pub fn narrow(parent: &Effective, asked: &Effective) -> Result<Effective, Widening> {
    for a in Action::ALL {
        if !within(asked.cell(a), parent.cell(a)) {
            return Err(Widening { action: a });
        }
    }
    Ok(asked.clone())
}
