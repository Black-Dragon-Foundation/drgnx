//! Plans in the graph, the briefs built from them, the structured reports agents end their work with, and what a
//! decision went on to touch (agent system part 1, Tasks 21, 22; `docs/develop/coordination.md`).  The report's
//! shape ([`ReportSubmit`]) is the `report_submit` tool's arguments and the fallback `drgnx-report` block's.

use super::graph::ParsedId;
use super::{invalid, method};
use crate::registry::Method;
use crate::types::{Bounded, Status, Text, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A prose field of a report: at most 2000 characters.
pub type Prose = Bounded<String, 2000>;
/// A task's number in its plan (`8`, `22b`).
pub type TaskNumber = Bounded<String, 16>;
/// A commit's hash.
pub type CommitId = Bounded<String, 64>;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ByPlan {
    pub plan: ParsedId,
}

/// One checkbox step of a task.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PlanStep {
    pub done: bool,
    pub text: String,
}

/// A plan's task as `plan_read` gives it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PlanTask {
    pub id: String,
    pub number: String,
    pub title: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The tasks it waits on (`blocks` links), by number.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub deps: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub steps: Vec<PlanStep>,
    /// Its reports' ids, newest first.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub reports: Vec<String>,
    /// What its latest report says it produced for later tasks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report_interfaces: Option<String>,
}

/// A plan in the graph.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PlanView {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    /// The graph version it was read at (`plans/write`'s `base_version`).
    pub version: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<PlanTask>,
}

/// One step of a task, written.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct StepWrite {
    pub done: bool,
    pub text: Bounded<String, 2000>,
}

/// One task, created or changed (by number); absent fields stay as they are.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TaskWrite {
    pub number: TaskNumber,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Bounded<String, 512>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<Bounded<String, 128>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steps: Option<Bounded<Vec<StepWrite>, 64>>,
    /// The tasks it waits on, by number (replaces its `blocks` links).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocks: Option<Bounded<Vec<TaskNumber>, 32>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct WriteParams {
    /// The plan; none creates one (then `title` and `project` are needed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<ParsedId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ParsedId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Bounded<String, 512>>,
    #[serde(default)]
    pub tasks: Bounded<Vec<TaskWrite>, 128>,
    /// The version the writer read (`plans/get`): a later change to the same records refuses the write.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_version: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskId {
    pub number: String,
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PlanWritten {
    pub plan: String,
    pub tx: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<TaskId>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ByTask {
    pub task: ParsedId,
}

/// A part of a brief, in the order the brief has them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum BriefPart {
    /// The plan's section for the task (by its heading).
    PlanSection,
    /// The project's AGENTS.md.
    AgentsMd,
    /// The matrix as it applies: one line per cell that is not Never.
    Matrix,
    BaseBranch,
    /// The interfaces earlier tasks' reports name.
    Interfaces,
    /// The check to run before reporting.
    Check,
    /// The view's path, for an agent without drgnx's tools.
    ViewPath,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BriefPartText {
    pub part: BriefPart,
    pub text: String,
}

/// A task's brief (at most 16 KiB; over it the plan section is cut at a heading with a pointer).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Brief {
    pub task: String,
    pub text: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub parts: Vec<BriefPartText>,
    /// The user's edited brief (a `brief` note) is used instead of the built one.
    pub edited: bool,
    /// The plan section was cut to fit.
    pub cut: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BriefSetParams {
    pub task: ParsedId,
    /// The brief as the user edited it (at most 16 KiB).
    pub text: Bounded<String, 16_384>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BriefSet {
    /// The `brief` note's id.
    pub note: String,
}

/// Where a decision a report lists came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum DecisionOrigin {
    /// The brief decided it.
    FromBrief,
    /// The agent decided it.
    Own,
    /// It needs the user.
    NeedsUser,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DecisionRef {
    pub id: Bounded<String, 128>,
    pub origin: DecisionOrigin,
}

/// A check the agent ran, with its counts.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CheckRun {
    pub name: Bounded<String, 256>,
    pub passed: u64,
    pub failed: u64,
}

/// A follow-up the report files (a task, or a DEFERRED row when the plan says so).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Followup {
    pub title: Bounded<String, 200>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<Bounded<String, 64>>,
}

/// A structured report: `report_submit`'s arguments and the fallback `drgnx-report` block.  Prose fields are at
/// most 2000 characters each; no free-form blob.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReportSubmit {
    /// The branch's tip commit.
    pub tip: CommitId,
    #[serde(default)]
    pub commits: Bounded<Vec<CommitId>, 64>,
    #[serde(default)]
    pub checks: Bounded<Vec<CheckRun>, 32>,
    #[serde(default)]
    pub decisions: Bounded<Vec<DecisionRef>, 64>,
    /// Where the work differs from the brief.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub differences: Option<Prose>,
    /// What the work produced that later tasks consume (types, functions, methods).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<Prose>,
    #[serde(default)]
    pub followups: Bounded<Vec<Followup>, 32>,
}

/// A report as the graph keeps it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Report {
    pub id: String,
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub at: f64,
    pub tip: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub commits: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub checks: Vec<CheckRun>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub decisions: Vec<DecisionRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub differences: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<String>,
    /// The follow-up tasks it filed.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub followups: Vec<String>,
    /// Decisions it lists that were never recorded (for the supervisor).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub unrecorded: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReportsParams {
    /// A task's reports, newest first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<ParsedId>,
    /// One report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<ParsedId>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Reports {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub reports: Vec<Report>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct EffectsParams {
    pub decision: ParsedId,
}

/// A later change that overlaps a decision's lines.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Hunk {
    pub commit: String,
    pub path: String,
    /// The first and last line of the hunk.
    pub lines: (u64, u64),
}

/// What a decision's commits went on to touch, computed from git (nothing inferred): labelled `computed`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Effects {
    pub decision: String,
    /// The commits that implement it.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub commits: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub later_hunks: Vec<Hunk>,
    pub label: String,
}

fn check_write(p: &WriteParams) -> Result<(), Error> {
    if p.plan.is_none() && (p.title.is_none() || p.project.is_none()) {
        return Err(invalid("title", "a new plan needs a title and a project"));
    }
    Ok(())
}

fn check_reports(p: &ReportsParams) -> Result<(), Error> {
    match (&p.task, &p.id) {
        (Some(_), None) | (None, Some(_)) => Ok(()),
        _ => Err(invalid("task", "reports of a task, or one report by id")),
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "plans/get", PlansGet(ByPlan) -> PlanView,
            classes: [User], writes: false, home: Front,
            doc: "a plan from the graph: its tasks with status, deps, interfaces, steps and their reports' interfaces",
        ),
        method!(
            "plans/write", PlansWrite(WriteParams) -> PlanWritten,
            classes: [User], writes: true, home: Front,
            doc: "a plan created or changed with its tasks, steps and blocks links, in one tx (refused when base_version is behind)",
            check: check_write,
        ),
        method!(
            "brief/build", BriefBuild(ByTask) -> Brief,
            classes: [User], writes: false, home: Front,
            doc: "a task's brief from the graph (plan section, AGENTS.md, the matrix as it applies, base branch, earlier interfaces, the check), or the user's edited one",
        ),
        method!(
            "brief/set", BriefSet(BriefSetParams) -> BriefSet,
            classes: [User], writes: true, home: Front,
            doc: "the user's edited brief for a task (a brief note the runner uses at dispatch)",
        ),
        method!(
            "reports/get", ReportsGet(ReportsParams) -> Reports,
            classes: [User], writes: false, home: Front,
            doc: "a task's structured reports, or one by id",
            check: check_reports,
        ),
        method!(
            "decisions/effects", DecisionsEffects(EffectsParams) -> Effects,
            classes: [User], writes: false, home: Front,
            doc: "a decision's commits and the later hunks that overlap its lines (computed from git)",
        ),
    ]
}
