//! Agent sessions the hub holds, and their records 2 shapes (`core/drgnx-records.el`: `drgnx-records-session`,
//! `drgnx-records-entry`).

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Id, Prompt, RequestId, TaskRef, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Starting,
    Idle,
    Busy,
    Exited,
}

/// Whether a session's traffic goes through the gateway.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Via {
    Gateway,
    Direct,
}

/// What a message sent while the session works does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Queue,
    Steer,
    Interrupt,
}

/// A JSON-RPC id, as the agent chose it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum RpcId {
    Int(i64),
    Str(String),
}

/// A permission request the agent waits on.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Permission {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<RpcId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub options: Vec<Value>,
}

/// A write held for the user's review.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Review {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<RpcId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Usage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<Value>,
}

/// What an editor mirrors of a session, everything but its transcript.  A `service` or `agent` caller of
/// `agents/list` gets only `{id, name, job, task}`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<SessionStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<Via>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<Mode>,
    /// Messages waiting for the turn to end.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub queue: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<bool>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub permissions: Vec<Permission>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub reviews: Vec<Review>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Usage>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub commands: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Value>,
    /// The agent process's exit status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
    #[serde(
        rename = "entries-count",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub entries_count: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enforced: Option<bool>,
}

/// What a transcript entry is (`usage`, `notice` and `compaction` are reserved).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum EntryType {
    User,
    Agent,
    Thought,
    Tool,
    Plan,
    Stop,
    Error,
    Usage,
    Notice,
    Compaction,
}

/// One transcript entry: its `type`, and the rest as the backend sent it (ACP's fields; phase 5 types them).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct Entry {
    #[serde(rename = "type")]
    pub kind: EntryType,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ById {
    pub id: Id,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct StartParams {
    /// The agent profile's name.
    pub profile: Bounded<String, 128>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Started {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Sessions {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub sessions: Vec<Snapshot>,
}

/// A session, its whole transcript and its change number.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Transcript {
    pub session: Snapshot,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entries: Vec<Entry>,
    pub seq: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SendParams {
    pub id: Id,
    pub text: Prompt,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PermissionParams {
    pub id: Id,
    pub request: RequestId,
    /// The option chosen; none rejects.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub option: Option<Bounded<String, 256>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum AgentOp {
    DeliverQueue,
    Unqueue,
    Requeue,
    Review,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DoParams {
    pub id: Id,
    pub op: AgentOp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<Prompt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<RequestId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reject: Option<bool>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/list", AgentsList(Empty) -> Sessions,
            classes: [User, Agent, Service], writes: false,
            doc: "the sessions: snapshots for the user, {id, name, job, task} for the others (an agent: its own job's)",
        ),
        method!(
            "agents/start", AgentsStart(StartParams) -> Started,
            classes: [User], writes: true,
            doc: "a session the hub holds",
        ),
        method!(
            "agents/get", AgentsGet(ById) -> Transcript,
            classes: [User], writes: false,
            doc: "a session's snapshot, whole transcript and change number",
        ),
        method!(
            "agents/send", AgentsSend(SendParams) -> bool,
            classes: [User], writes: true,
            doc: "a prompt to the session (queued or steering as its mode says)",
        ),
        method!(
            "agents/stop", AgentsStop(ById) -> bool,
            classes: [User], writes: true,
            doc: "the session's turn stops",
        ),
        method!(
            "agents/kill", AgentsKill(ById) -> bool,
            classes: [User], writes: true,
            doc: "the session ends",
        ),
        method!(
            "agents/permission", AgentsPermission(PermissionParams) -> bool,
            classes: [User], writes: true,
            doc: "the user's answer to a permission request: the only way one is answered",
        ),
        method!(
            "agents/do", AgentsDo(DoParams) -> bool,
            classes: [User], writes: true,
            doc: "the user's other actions on a session: deliver-queue, unqueue, requeue, review",
        ),
    ]
}
