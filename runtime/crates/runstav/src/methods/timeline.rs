//! Time, cost and the supervisor: every agent's steps from the hub's stamps (the `step` table), their rollups,
//! nested budgets in named units, the subscriptions' pace, and the supervisor's pauses (agent system part 1, Tasks
//! 19, 20, 23; `docs/develop/hub.md`, "The timeline").

use super::graph::ParsedId;
use super::matrix::{Limit, Unit};
use super::{invalid, method};
use crate::registry::Method;
use crate::types::{Bounded, Id, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// What a step was spent on.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "kebab-case")]
pub enum StepClass {
    /// Thinking or generating: the updates between tool calls.
    Think,
    /// A tool call, from `in_progress` to `completed` (its permission wait split out).
    Tool,
    /// Waiting on a job (no model request).
    JobWait,
    /// Waiting for a machine.
    MachineQueue,
    /// Waiting for the user (a permission or a card).
    UserWait,
    Paused,
    Stalled,
}

/// One row of the `step` table.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Step {
    pub id: i64,
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// The step's place in its session.
    pub seq: u64,
    pub class: StepClass,
    /// When it started and ended (seconds since the epoch, the hub's stamps); none: still open.
    pub start: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// ACP's tool kind (`read`, `edit`, `execute`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_kind: Option<String>,
    /// The anchors (part 4's rewind): the message, the turn, the step snapshot (a tree id) and the decision log's
    /// version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_in: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_out: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_unit: Option<Unit>,
}

/// What a timeline covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    Session,
    Task,
    Plan,
    Project,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TimelineParams {
    pub scope: Scope,
    /// The session's id, or the task's, plan's or project's entity id.
    pub id: ParsedId,
    /// Steps after this one (a session's `seq`, else a step id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<u64>,
    /// The rollup only, no steps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollup: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ClassSecs {
    pub class: StepClass,
    pub secs: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Tokens {
    #[serde(rename = "in")]
    pub tokens_in: u64,
    pub out: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

/// Time by class, cost by unit (never summed across units) and tokens.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Rollup {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub secs: Vec<ClassSecs>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cost: Vec<Limit>,
    pub tokens: Tokens,
}

/// At most 500 steps a call; `next` continues.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Timeline {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub steps: Vec<Step>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollup: Option<Rollup>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<u64>,
}

/// The `agent-step` event: a step opened or closed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentStep {
    pub session: String,
    pub step: Step,
}

/// What a budget is set on (the limit is kept on the scope's entity); the remaining amount is the least over its
/// ancestors.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum BudgetScope {
    Project(ParsedId),
    Plan(ParsedId),
    /// A manager session.
    Manager(Id),
    /// A worker session.
    Worker(Id),
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BudgetGetParams {
    pub scope: BudgetScope,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BudgetSetParams {
    pub scope: BudgetScope,
    /// One limit per unit (at most 5); empty clears the scope's budget.
    #[serde(default)]
    pub limits: Bounded<Vec<Limit>, 5>,
}

/// A scope's budget: its own limits, what it spent and what remains (least over its ancestors), each by unit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BudgetView {
    pub scope: BudgetScope,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub limits: Vec<Limit>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub spent: Vec<Limit>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub remaining: Vec<Limit>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PaceParams {
    /// One provider's meter; none: every meter the hub reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Bounded<String, 64>>,
}

/// A subscription meter's pace, linear over the last 24 h (an estimate).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Pace {
    pub provider: String,
    /// The share of the window's limit used, 0 to 1.
    pub used_share: f64,
    pub rate_per_hour: f64,
    /// When the share reaches 1 at this rate, if before the window resets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exhausted_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<f64>,
    pub estimate: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Paces {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub meters: Vec<Pace>,
}

/// The supervisor's rules (thresholds are settings, per kind of work).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum SupervisorRule {
    Silent,
    Repeat,
    NoProgress,
    DeadWait,
    Lease,
    Refusals,
    Unrecorded,
    ManagerContext,
}

/// The `supervisor` event: an agent was paused by a rule, with its card.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SupervisorEvent {
    pub rule: SupervisorRule,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<u64>,
    pub text: String,
}

fn check_budget_set(p: &BudgetSetParams) -> Result<(), Error> {
    let mut units: Vec<Unit> = p.limits.iter().map(|l| l.unit).collect();
    units.sort();
    units.dedup();
    if units.len() != p.limits.len() {
        return Err(invalid("limits", "one limit per unit"));
    }
    if p.limits
        .iter()
        .any(|l| !(l.amount.is_finite() && l.amount >= 0.0))
    {
        return Err(invalid("limits", "a limit: a finite amount, 0 or more"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "timeline/get", TimelineGet(TimelineParams) -> Timeline,
            classes: [User], writes: false, home: Front,
            doc: "the steps of a session, task, plan or project (500 a page), or their rollup: time by class, cost by unit, tokens",
        ),
        method!(
            "budget/get", BudgetGet(BudgetGetParams) -> BudgetView,
            classes: [User], writes: false, home: Front,
            doc: "a scope's budget: its limits, spend and what remains (the least over its ancestors), by unit",
        ),
        method!(
            "budget/set", BudgetSet(BudgetSetParams) -> BudgetView,
            classes: [User], writes: true, home: Front,
            doc: "a scope's limits, one per unit (empty clears); the gateway admits usd against the nested minimum",
            check: check_budget_set,
        ),
        method!(
            "pace/get", PaceGet(PaceParams) -> Paces,
            classes: [User], writes: false, home: Front,
            doc: "the subscriptions' meters: share used, rate per hour and when it runs out at that rate (estimates)",
        ),
    ]
}
