//! Budgets, units and pace (Task 20; `docs/guide/agents.md`, "Budgets"): limits on a project, plan, manager or
//! worker, each in a named unit, the remaining amount the least over its ancestors; the gateway admits `usd` against
//! the nested minimum; subscription meters (`_claude/rateLimit`, Codex's window) as `limit-share` estimates; at a
//! limit the agent is paused with a `budget` card.  Methods `budget/get`, `budget/set`, `pace/get`.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::timeline::{BudgetGetParams, BudgetSetParams, BudgetView, PaceParams, Paces};
use runstav::wire::Error;

/// The meters' readings and the budgets as last read (Task 20 fills it).
#[derive(Default)]
pub struct Budgets {}

pub async fn get(_: &Front, _: &Caller, _: BudgetGetParams) -> Result<BudgetView, Error> {
    Err(not_yet("budget/get", "20"))
}

pub async fn set(_: &Front, _: &Caller, _: BudgetSetParams) -> Result<BudgetView, Error> {
    Err(not_yet("budget/set", "20"))
}

pub async fn pace(_: &Front, _: &Caller, _: PaceParams) -> Result<Paces, Error> {
    Err(not_yet("pace/get", "20"))
}
