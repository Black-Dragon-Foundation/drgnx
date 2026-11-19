//! The Budgets page (Flow Task 22c; timeline and budget spec §7.5): the scope tree as kit rows built in the hub, the
//! subscription meters with their paces, a limit cell that edits in place, and a run's share of its plan.  The rows
//! come from `budget/tree` (hub H6, `BudgetNode.share_of_parent`) and `pace/get` with history (H13).
//!
//! This module holds the page's tests until the page is built: `rows(&BudgetTree, &[Pace], &KitEnv)` is the interface
//! they are written against.

#[cfg(test)]
#[path = "budgets/tests.rs"]
mod tests;
