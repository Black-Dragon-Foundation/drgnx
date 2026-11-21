//! Forecasts: what a plan, or one more run like a session, will take, from the history of similar tasks (docs/develop/
//! hub.md, "Forecasts").  Tokens, time and cost are ranges (a middle and a high end), cost by unit and never summed
//! across units, and each task says what it was forecast from.

use super::graph::ParsedId;
use super::matrix::Unit;
use super::method;
use crate::registry::Method;
use crate::types::{Bounded, Id, Text, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A forecast's middle and its high end (the 90th percentile).
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Range {
    pub p50: f64,
    pub p90: f64,
}

impl Default for Range {
    fn default() -> Self {
        Range { p50: 0.0, p90: 0.0 }
    }
}

/// A cost range in one unit.  `estimate` is true for `usd-est`: tokens at API prices, not a measured bill.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CostRange {
    pub unit: Unit,
    pub p50: f64,
    pub p90: f64,
    pub estimate: bool,
}

/// How close the history a forecast comes from is to the task, closest first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum BasisLevel {
    /// The same role, profile and model on this project.
    Project,
    /// The same role, profile and model.
    Profile,
    /// The same role on any profile; tokens carried and repriced.
    Role,
    /// Any role.
    Any,
    /// No history to speak of: a labelled prior with a wide range.
    Prior,
}

/// What a task was forecast from, in numbers and in words.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Basis {
    pub level: BasisLevel,
    /// Finished tasks in the class; 0 for the prior.
    pub n: u32,
    /// Some of them ran on another model: their tokens are carried and repriced.
    pub other_model: bool,
    /// The p90 was scaled by past misses.
    pub calibrated: bool,
    /// "12 implement tasks on sonnet, this project", "no history: prior".
    pub label: String,
}

/// One task's forecast.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskForecast {
    /// The task's number in its plan.
    pub n: u64,
    pub role: String,
    pub profile: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    pub basis: Basis,
    /// Every token, cache reads included.
    pub tokens: Range,
    /// Seconds spent thinking or running tools.
    pub active_secs: Range,
    /// Empty for a profile with no price: unpriced, never zero.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cost: Vec<CostRange>,
    /// When the task starts and ends, in seconds from the run's start: its own distribution over the simulated runs
    /// (a manager's row has none: zeros).  With `remaining`, wall-clock times; a done task's are its actuals.
    #[serde(default)]
    pub start: Range,
    #[serde(default)]
    pub finish: Range,
    /// With `remaining`: where the task stands.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<TaskAt>,
}

/// Where a task of a running job stands, in a forecast of what remains.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum TaskAt {
    Done,
    Running,
    Waiting,
}

/// The cold wakes in a forecast: "of which", already inside the totals (the history holds its wakes).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WakeLine {
    pub cold_wakes: Range,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cost: Vec<CostRange>,
}

/// Which window a pace speaks of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PaceWindow {
    /// The meter resets more than a day away.
    Week,
    /// The meter resets within a day.
    Short,
}

/// A plan's effect on one subscription's meter (an estimate: the share includes the user's outside use).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PaceEffect {
    pub provider: String,
    /// The share of the window's limit used now, 0 to 1.
    pub used_share: f64,
    /// The share the plan adds; none while there is no pace yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added_share: Option<Range>,
    /// When the meter reaches 1 at the current rate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exhausted_at: Option<f64>,
    /// When it reaches 1 at the current rate once the plan's middle share is added.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exhausted_after: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<f64>,
    pub window: PaceWindow,
    pub estimate: bool,
    /// The used share plus the plan's high share reaches 1 before the reset.
    pub runs_out_p90: bool,
}

/// A plan's forecast, or one session's.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Forecast {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<TaskForecast>,
    pub tokens: Range,
    pub active_secs: Range,
    /// Wall time over the plan's dependencies and the runner's slots.
    pub wall_secs: Range,
    /// By unit, never summed across units.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cost: Vec<CostRange>,
    /// Profiles with no price.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub unpriced: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wake: Option<WakeLine>,
    /// A manager's own spend per task, beside the total and not in it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manager: Option<TaskForecast>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub pace: Vec<PaceEffect>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub warnings: Vec<String>,
    /// The date of the oldest shipped price row in use.
    pub prices_as_of: String,
    pub made_at: f64,
    /// What the forecast said when the job was proposed, kept for an approved job to be compared against; none for a
    /// proposal and for a forecast made before they were kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub baseline: Option<Baseline>,
}

/// When a job's tasks were forecast to start and end, offsets from the run's start (as a task's own `start`, `finish`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct Baseline {
    pub made_at: f64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<BaselineTask>,
    /// The plan's own finish (its wall time).
    pub finish: Range,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BaselineTask {
    pub n: u64,
    pub start: Range,
    pub finish: Range,
}

/// `forecast/plan`: the plans (entity ids) to forecast together.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ForecastPlanParams {
    pub plans: Bounded<Vec<ParsedId>, 32>,
}

/// A plan with a running job: its own forecast, not part of the joint draw.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RunningPlan {
    pub plan: String,
    pub job: String,
    pub remaining: Forecast,
}

/// The joint forecast of the plans not running (its `tasks` are numbered `plan index * 1000 + n`), and the plans that
/// are.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PlanForecast {
    pub forecast: Forecast,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub running: Vec<RunningPlan>,
}

/// `forecast/start`'s params: the proposed job whose start step is wanted.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StartParams {
    pub job: Id,
    /// Seconds east of UTC, for the weekday and time the week runs out at; none: UTC.
    #[serde(default)]
    pub utc_offset: i64,
}

/// A budget field of the start step: the plan's limit in UNIT, prefilled with the forecast's p90 rounded up (none: empty,
/// with the NOTE saying why).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StartField {
    pub unit: Unit,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefill: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// The start step of a proposed job: its budget fields (`% wk` for subscription tasks, `usd` for gateway tasks, both for a
/// mixed plan), the warning that the week runs out at p90 (never a block) and whether some task was forecast from the prior.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StartView {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub fields: Vec<StartField>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub week_warning: Option<String>,
    pub prior: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ForecastParams {
    pub job: Id,
    /// What remains of a running job: finished tasks at their actuals, a running one from the runs longer than it has
    /// been running, the rest from now; times are then wall-clock (seconds since the epoch), not offsets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SessionForecastParams {
    pub session: Id,
    /// Price it on another profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Bounded<String, 128>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct AccuracyParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Text>,
}

/// How past forecasts of one class fared against what the tasks took (tokens).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AccuracyRow {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub n: u32,
    /// The share of tasks that took no more than their p90.
    pub coverage: f64,
    /// The median of actual over p50.
    pub median_ratio: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Accuracy {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub rows: Vec<AccuracyRow>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "forecast/get", ForecastGet(ForecastParams) -> Forecast,
            classes: [User], writes: false,
            doc: "a job's forecast: tokens, time and cost per task and for the plan, from the history of similar tasks, with the effect on the week's pace; with remaining, what is left of a running job from now",
        ),
        method!(
            "forecast/start", ForecastStart(StartParams) -> StartView,
            classes: [User], writes: false,
            doc: "the start step of a proposed job: its budget fields prefilled with the forecast's p90 rounded up in the plan's unit (% wk, usd, or both), the warning that the week runs out at p90, whether a task rests on the prior",
        ),
        method!(
            "forecast/plan", ForecastPlan(ForecastPlanParams) -> PlanForecast,
            classes: [User], writes: false,
            doc: "one forecast over the plans given (up to 32), drawn together on the runner's slots (not a sum of each plan's p90); a plan with a running job is in `running`, with its own forecast, and not in the draw; nothing is recorded",
        ),
        method!(
            "forecast/session", ForecastSession(SessionForecastParams) -> Forecast,
            classes: [User], writes: false,
            doc: "what one more run like a session would take (one task of its role and profile); records nothing",
        ),
        method!(
            "forecast/accuracy", ForecastAccuracy(AccuracyParams) -> Accuracy,
            classes: [User], writes: false,
            doc: "how past forecasts fared against the finished tasks: coverage of the p90 and the median actual over p50, per role and profile",
        ),
    ]
}
