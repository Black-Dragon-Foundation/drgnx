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
use serde_json::Value;

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

/// What a step read, searched or fetched (the `step_detail` table); never the content.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StepDetail {
    /// The tool's name as the provider sent it, when it sent one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// `read`, `search`, `fetch`, `edit` or `execute`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_start: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_end: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// A page's title (the agent browser's).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// The `Task` tool call of the subagent that made the step (Claude's `parentToolUseId`); absent: the session's
    /// own step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_tool: Option<String>,
    /// How the hub learned it: `acp`, `acp-title` (parsed from the title), `browser`, `command` or `opened`.
    pub origin: String,
}

/// A machine's slots: in use, and in all.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Slots {
    pub used: u32,
    pub total: u32,
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
    /// What the step read, searched or fetched (tool steps).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<StepDetail>,
    /// The machine the step ran on (none: the hub's own, or not known).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    /// A machine-queue step: the slots in use and in all when the wait began.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slots: Option<Slots>,
    /// The agent conversation (ACP session id) the step ran in: a session runs another one after a revert.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acp: Option<String>,
    /// The worktree's commit when the step's snapshot was taken, read from its ref files: the agent's claim, a hint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    /// The edit history's record the step anchors.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_op: Option<u64>,
    /// The revert record that abandoned the step (the session went back to a step before it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undone_by: Option<u64>,
    /// Whether "Revert to here" can act on the step: it has an edit history record and its checkpoint is kept.
    #[serde(default)]
    pub revertible: bool,
    /// The tool call the step ran (the transcript's tool entry `id`), on the `agent-step` event of a tool step; the
    /// `step` table keeps none, so `timeline/get` has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call: Option<String>,
    /// Its provenance: each hook point run on it, as the hub's own `hook` row records it (`{point, records:
    /// [{source, verdict, ms, reason?}], outcome, …}`), oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hooks: Vec<Value>,
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
    /// Page backwards: the last `limit` steps (1 to 500), newest last; with `before`, those before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// Steps before this one (a session's `seq`, else a step id); with `limit`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<u64>,
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
    /// The first step's start and the last step's end, seconds since the epoch; `last` is none while a step is open.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<f64>,
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
    /// A spec: every plan that derives from it counts toward it.
    Spec(ParsedId),
    /// A plan (the document's entity id): every run of it counts toward it.
    Plan(ParsedId),
    /// One run of a plan (a job id).
    Run(Id),
    /// A task (its entity id): the workers that worked on it count toward it.
    Task(ParsedId),
    /// A manager session.
    Manager(Id),
    /// A worker session.
    Worker(Id),
}

/// Where a scope stands against its limits (and those above it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum BudgetState {
    /// Within its limits.
    Ok,
    /// 80 % or more of the binding limit is spent: the unit whose remaining share is the least.
    Nearing,
    /// A limit is reached.
    Reached,
    /// No limit on the scope or above it.
    None,
}

/// The `budget` event: a scope's spend moved (at most once a second per scope; the last value wins).  `burn_per_hour`
/// is what it spent per hour over the last hour, in each unit, empty until 10 minutes of spend were seen.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BudgetEvent {
    pub scope: BudgetScope,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub spent: Vec<Limit>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub remaining: Vec<Limit>,
    pub state: BudgetState,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub burn_per_hour: Vec<Limit>,
}

/// `budget/tree`: the scopes the hub knows, depth first in chain order, a page at a time.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BudgetTreeParams {
    /// The scope to start at, itself included; none: every scope with no parent, in turn.
    #[serde(default)]
    pub root: Option<BudgetScope>,
    /// How many levels below the root (0: only the root); none: all.
    #[serde(default)]
    pub depth: Option<u8>,
    /// The `next` of the page before.
    #[serde(default)]
    pub after: Option<Bounded<String, 256>>,
}

/// One scope of the tree.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BudgetNode {
    pub scope: BudgetScope,
    pub parent: Option<BudgetScope>,
    /// What the user calls it: the entity's title, a session's name, "run N" for the runs of a parent in start order.
    pub label: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub limits: Vec<Limit>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub spent: Vec<Limit>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub remaining: Vec<Limit>,
    pub state: BudgetState,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub burn_per_hour: Vec<Limit>,
    /// A run's spend over its plan's, in the plan's binding unit (0 to 1); nothing else has one.
    #[serde(default)]
    pub share_of_parent: Option<f64>,
}

/// A page of the tree.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BudgetTree {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub nodes: Vec<BudgetNode>,
    /// Pass as `after` for the next page; none at the end.
    #[serde(default)]
    pub next: Option<String>,
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
    /// The 8-day quarter-hour readings of each meter too (`Pace.history`); off by default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<bool>,
    /// One provider's meter; none: every meter the hub reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Bounded<String, 64>>,
}

/// A subscription meter's pace, linear over the last 24 h (an estimate).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Pace {
    pub provider: String,
    /// Which of the provider's windows: `5h`, `week`, or the agent's own name for it.
    pub window: String,
    /// The share of the window's limit used, 0 to 1.
    pub used_share: f64,
    pub rate_per_hour: f64,
    /// When the share reaches 1 at this rate, if before the window resets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exhausted_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<f64>,
    pub estimate: bool,
    /// A weekly meter's mean rise per hour over its last seven days; none with under 24 hours of readings (or not a
    /// weekly meter).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_7d_per_hour: Option<f64>,
    /// `(at, share)`, one for each quarter hour of the last eight days; only with `PaceParams.history`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history: Vec<(f64, f64)>,
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
    /// A workflow task's agent past its rule pack's context share: rotated like a manager.
    Context,
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

/// A set of limits as a budget takes them: one per unit, each a finite amount of 0 or more.
pub(crate) fn check_limits(limits: &[Limit]) -> Result<(), Error> {
    let mut units: Vec<Unit> = limits.iter().map(|l| l.unit).collect();
    units.sort();
    units.dedup();
    if units.len() != limits.len() {
        return Err(invalid("limits", "one limit per unit"));
    }
    if limits
        .iter()
        .any(|l| !(l.amount.is_finite() && l.amount >= 0.0))
    {
        return Err(invalid("limits", "a limit: a finite amount, 0 or more"));
    }
    Ok(())
}

fn check_budget_set(p: &BudgetSetParams) -> Result<(), Error> {
    check_limits(&p.limits)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "timeline/get", TimelineGet(TimelineParams) -> Timeline,
            classes: [User], writes: false,
            doc: "the steps of a session, task, plan or project (500 a page), or their rollup: time by class, cost by unit, tokens",
        ),
        method!(
            "budget/get", BudgetGet(BudgetGetParams) -> BudgetView,
            classes: [User], writes: false,
            doc: "a scope's budget: its limits, spend and what remains (the least over its ancestors), by unit",
        ),
        method!(
            "budget/tree", BudgetTreePage(BudgetTreeParams) -> BudgetTree,
            classes: [User], writes: false,
            doc: "the budget scopes the hub knows as a tree (200 nodes a page, depth first): limits, spend, remaining, state, burn, and a run's share of its plan",
        ),
        method!(
            "budget/set", BudgetSet(BudgetSetParams) -> BudgetView,
            classes: [User], writes: true,
            doc: "a scope's limits, one per unit (empty clears); the gateway admits usd against the nested minimum",
            check: check_budget_set,
        ),
        method!(
            "pace/get", PaceGet(PaceParams) -> Paces,
            classes: [User], writes: false,
            doc: "the subscriptions' meters: share used, rate per hour and when it runs out at that rate (estimates)",
        ),
    ]
}
