//! Forecasts: what a plan, or one more run like a session, will take, from the history of similar tasks (docs/develop/
//! hub.md, "Forecasts").  Tokens, time and cost are ranges (a middle and a high end), cost by unit and never summed
//! across units, and each task says what it was forecast from.

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
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ForecastParams {
    pub job: Id,
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
            doc: "a job's forecast: tokens, time and cost per task and for the plan, from the history of similar tasks, with the effect on the week's pace",
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
