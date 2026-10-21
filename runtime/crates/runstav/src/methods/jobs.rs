//! Jobs (`core/drgnx-job.el`): every change answers the job as `drgnx-job-summary` has it.

use super::agents::ById;
use super::method;
use crate::registry::Method;
use crate::types::{
    AbsPath, Bounded, CardAction, Delta, Id, Prompt, StringOrNumber, TaskRef, Text, Usd,
    null_as_empty,
};
use schemars::JsonSchema;
use serde::de::{self, Deserializer};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// What gates a job's merge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub enum MergeGate {
    #[serde(rename = "review")]
    Review,
    #[serde(rename = "review+accept")]
    ReviewAccept,
}

/// A job as `drgnx-job-summary` has it.  Its lists are `[]` when empty, also when the backend sent `null`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct JobSummary {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    /// US dollars.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate: Option<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub warnings: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<Value>,
    /// The run order: task numbers.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub order: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub agents: Vec<Value>,
    /// Open cards.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cards: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub messages: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub decisions: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub permissions: Vec<Value>,
}

/// `job/status`'s answer: one job, or every job.
#[derive(Clone, Debug, PartialEq, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum JobStatusResult {
    One(Box<JobSummary>),
    All {
        #[serde(default, deserialize_with = "null_as_empty")]
        jobs: Vec<JobSummary>,
    },
}

impl<'de> Deserialize<'de> for JobStatusResult {
    /// An object with `jobs` is every job; anything else must be one.  What does not fit says where, in its message.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct All {
            #[serde(default, deserialize_with = "null_as_empty")]
            jobs: Vec<JobSummary>,
        }
        fn at<E: de::Error>(e: serde_path_to_error::Error<serde_json::Error>) -> E {
            E::custom(format!("{}: {}", e.path(), e.inner()))
        }
        let v = Value::deserialize(d)?;
        if v.get("jobs").is_some() {
            serde_path_to_error::deserialize::<_, All>(&v)
                .map(|a| JobStatusResult::All { jobs: a.jobs })
                .map_err(at)
        } else {
            serde_path_to_error::deserialize::<_, JobSummary>(&v)
                .map(|j| JobStatusResult::One(Box::new(j)))
                .map_err(at)
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProposeParams {
    /// The plan's file.
    pub plan: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<Usd>,
    /// Approve at once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<MergeGate>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct StartTaskParams {
    pub plan: AbsPath,
    /// The task's number in the plan.
    pub n: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<MergeGate>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReassignParams {
    pub task: TaskRef,
    pub profile: Bounded<String, 128>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BlockParams {
    pub task: TaskRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<Text>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ByTask {
    pub task: TaskRef,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct OrderParams {
    pub task: TaskRef,
    pub delta: Delta,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct WithBudget {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<Usd>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CardParams {
    pub card: u64,
    pub action: CardAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arg: Option<StringOrNumber>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReplyParams {
    pub message: u64,
    pub text: Prompt,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ByMessage {
    pub message: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct StatusParams {
    /// One job; every job without it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Id>,
    /// With its decision log.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decisions: Option<bool>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "job/propose", JobPropose(ProposeParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "a job from a plan, proposed (approved at once with auto)",
        ),
        method!(
            "job/start-task", JobStartTask(StartTaskParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "Start as Job: task n of a plan and the tasks it needs, proposed; the plan is only read",
        ),
        method!(
            "job/reassign", JobReassign(ReassignParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "a task goes to another profile (the Work graph)",
        ),
        method!(
            "job/block", JobBlock(BlockParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "a task waits for the user, with a reason (the Work graph)",
        ),
        method!(
            "job/unblock", JobUnblock(ByTask) -> JobSummary,
            classes: [User], writes: true,
            doc: "a blocked task may run again (the Work graph)",
        ),
        method!(
            "job/order", JobOrder(OrderParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "a task moves in its job's run order (the Work graph)",
        ),
        method!(
            "job/approve", JobApprove(WithBudget) -> JobSummary,
            classes: [User], writes: true,
            doc: "a proposed job runs, with an optional budget",
        ),
        method!(
            "job/stop", JobStop(ById) -> JobSummary,
            classes: [User], writes: true,
            doc: "a job's agents stop and it waits",
        ),
        method!(
            "job/resume", JobResume(WithBudget) -> JobSummary,
            classes: [User], writes: true,
            doc: "a stopped job runs again, with an optional new budget",
        ),
        method!(
            "job/card", JobCard(CardParams) -> JobSummary,
            classes: [User], writes: true,
            doc: "the user's action on a card (once: a settled card is an error)",
        ),
        method!(
            "job/reply", JobReply(ReplyParams) -> bool,
            classes: [User], writes: true,
            doc: "the user's answer to an agent's message",
        ),
        method!(
            "job/dismiss", JobDismiss(ByMessage) -> bool,
            classes: [User], writes: true,
            doc: "a message acted on without an answer",
        ),
        method!(
            "job/status", JobStatus(StatusParams) -> JobStatusResult,
            classes: [User], writes: false,
            doc: "one job (with its decision log when asked), or every job",
        ),
    ]
}
