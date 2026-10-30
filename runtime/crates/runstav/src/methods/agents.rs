//! Agent sessions the hub holds, and their records 2 shapes (`core/drgnx-records.el`: `drgnx-records-session`,
//! `drgnx-records-entry`).

use super::graph::ParsedId;
use super::matrix::Role;
use super::{Empty, invalid, method};
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
    /// Waiting on a job it started (no model request until the wake).
    Waiting,
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
    /// Why the provider's lock is not enforced (shown "not enforced").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enforced_why: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// The manager session that started it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// A brainstorm's topic note.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    /// The job it waits on.
    #[serde(
        rename = "waiting-on",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub waiting_on: Option<String>,
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
    /// Its matrix column (default: `worker` with a task or job, else `chat`); `manager` only through `agents/role`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    /// A brainstorm session: its topic note (the project read-only, only `document` writable).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub about: Option<ParsedId>,
    /// A brainstorm's design document.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<AbsPath>,
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

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct MoveParams {
    pub id: Id,
    /// The profile it moves to (same worktree, from its last step snapshot, with a summary handoff).
    pub profile: Bounded<String, 128>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RoleParams {
    pub id: Id,
    pub role: Role,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SliceParams {
    pub id: Id,
    /// The first step (its `seq`).
    pub from_step: u64,
    /// At most 50 steps (default 20).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<u64>,
}

/// A slice of a session's transcript by steps (never a whole transcript): the steps and their entries.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Slice {
    pub id: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub steps: Vec<super::timeline::Step>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entries: Vec<(u64, Entry)>,
    /// The step after the slice, when there is more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<u64>,
}

fn check_slice(p: &SliceParams) -> Result<(), crate::wire::Error> {
    match p.n {
        Some(n) if !(1..=50).contains(&n) => Err(invalid("n", "1 to 50 steps")),
        _ => Ok(()),
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/list", AgentsList(Empty) -> Sessions,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "the sessions: snapshots for the user, {id, name, job, task} for the others (an agent: its own job's)",
        ),
        method!(
            "agents/start", AgentsStart(StartParams) -> Started,
            classes: [User], writes: true, home: Front,
            doc: "a session the hub holds",
        ),
        method!(
            "agents/get", AgentsGet(ById) -> Transcript,
            classes: [User], writes: false, home: Front,
            doc: "a session's snapshot, whole transcript and change number",
        ),
        method!(
            "agents/send", AgentsSend(SendParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "a prompt to the session (queued or steering as its mode says)",
        ),
        method!(
            "agents/stop", AgentsStop(ById) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "the session's turn stops",
        ),
        method!(
            "agents/kill", AgentsKill(ById) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "the session ends",
        ),
        method!(
            "agents/permission", AgentsPermission(PermissionParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "the user's answer to a permission request: the only way one is answered",
        ),
        method!(
            "agents/do", AgentsDo(DoParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "the user's other actions on a session: deliver-queue, unqueue, requeue, review",
        ),
        method!(
            "agents/move", AgentsMove(MoveParams) -> Started,
            classes: [User], writes: true, home: Front,
            doc: "a session moved to another profile: stopped after its tool call, the new one started in the same worktree with a summary handoff",
        ),
        method!(
            "agents/role", AgentsRole(RoleParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "a session's role (its matrix column): the user's only, the one way to make a manager",
        ),
        method!(
            "agents/slice", AgentsSlice(SliceParams) -> Slice,
            classes: [User], writes: false, home: Front,
            doc: "steps of a session's transcript with their entries (at most 50; never a whole transcript)",
            check: check_slice,
        ),
    ]
}
