//! Agent sessions the hub holds, and their records 2 shapes (`core/drgnx-records.el`: `drgnx-records-session`,
//! `drgnx-records-entry`).

use super::graph::ParsedId;
use super::hub::EnvVar;
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
    /// How many turns this hub process has started for the session: an editor that saw the count rise and no `busy`
    /// knows whole turns went by between two snapshots (a turn can be shorter than the update throttle).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turns: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enforced: Option<bool>,
    /// Why the provider's lock is not enforced (shown "not enforced").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enforced_why: Option<String>,
    /// Why a session whose `browser` cell allows the agent browser started without it, and the fix (a host that
    /// cannot give one: no full sandbox tier, Landlock below ABI 9, no browser found).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser_why: Option<String>,
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
    /// A paired chat whose writes of one file were refused twice within a minute: it waits for the user (or asks)
    /// until a write of that file applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting: Option<Waiting>,
    /// A chat in a project: whether pair mode is on for it (its edits of your checkout go through the editor).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paired: Option<bool>,
    /// Who holds the session's wheel (`user`, from `agents/wheel/take` until the give): the agent stops after its
    /// step and nothing of it is written until the wheel is given back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held_by: Option<String>,
}

/// The file (and the user's lines in it) a paired chat waits on.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Waiting {
    pub file: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<[u64; 2]>,
}

/// Where a session's wheel is: `held` once the turn the take stopped has ended, `free` once it is given back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum WheelState {
    Held,
    Free,
}

/// `agent-wheel`: session ID's wheel is now in STATE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentWheel {
    pub id: String,
    pub state: WheelState,
}

/// `wheel-save`: the user gives back the wheel of session ID, which works in WORKTREE (a worktree of its own): the
/// editor saves its buffers there and answers `agents/wheel/saved` with the same REQ.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WheelSave {
    pub req: u64,
    pub id: String,
    pub worktree: String,
}

/// `agents/wheel/saved` (the editor): the answer to `wheel-save` REQ, with the files whose buffers stayed unsaved
/// (empty: everything there is on disk).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct WheelSaved {
    pub req: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub unsaved: Vec<AbsPath>,
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
    /// Variables an editor module adds to the agent's environment, after the profile's and the lock's.  A name must be
    /// on `drgnx-agents-start-env-names` and must not look like a credential, else `invalid-params` at `env[i].name`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<Bounded<Vec<EnvVar>, 8>>,
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
    /// Only when the session is free (idle, not paused by a Stop, nothing queued): else nothing is queued, steered or
    /// sent and the answer is `false` (busy).  For the editor's own deliveries, which never join a running turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub if_free: Option<bool>,
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

/// A session, for the entry subscription.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SessionRef {
    pub session: Id,
}

/// The change number a subscription to a session's entries continues from.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EntriesSubscribed {
    pub seq: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ToolInputParams {
    pub session: Id,
    /// The tool call's id (the `id` of its `tool` entry).
    pub tool_call: Bounded<String, 256>,
}

/// A tool call's raw input: the input, or (when `truncated`) its JSON text cut at 256 KiB.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ToolInput {
    pub raw_input: Value,
    pub truncated: bool,
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

/// Check that the agent of PROFILE starts and answers `initialize`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProbeParams {
    /// The agent profile's name.
    pub profile: Bounded<String, 128>,
    /// Seconds the agent has to answer (1 to 60; default 15).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_s: Option<u64>,
}

/// What an agent called itself in its `initialize` answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentInfo {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

/// The check's answer: the agent answered (`ok`, with `agent`), or why not (`why`, and the end of its stderr when it
/// ended first).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProbeResult {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// At most 2 KiB, secrets redacted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr_tail: Option<String>,
}

fn check_probe(p: &ProbeParams) -> Result<(), crate::wire::Error> {
    match p.wait_s {
        Some(n) if !(1..=60).contains(&n) => Err(invalid("wait_s", "1 to 60 seconds")),
        _ => Ok(()),
    }
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
            doc: "a prompt to the session (queued or steering as its mode says; with if_free, only when it is free, else false)",
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
        method!(
            "agents/move", AgentsMove(MoveParams) -> Started,
            classes: [User], writes: true,
            doc: "a session moved to another profile: stopped after its tool call, the new one started in the same worktree with a summary handoff",
        ),
        method!(
            "agents/role", AgentsRole(RoleParams) -> bool,
            classes: [User], writes: true,
            doc: "a session's role (its matrix column): the user's only, the one way to make a manager",
        ),
        method!(
            "agents/slice", AgentsSlice(SliceParams) -> Slice,
            classes: [User], writes: false,
            doc: "steps of a session's transcript with their entries (at most 50; never a whole transcript)",
            check: check_slice,
        ),
        method!(
            "agents/entries/subscribe", AgentsEntriesSubscribe(SessionRef) -> EntriesSubscribed,
            classes: [User], writes: false,
            doc: "this connection gets the session's `agent-entries` events from now on (they go to no one else); the change number to continue from",
        ),
        method!(
            "agents/entries/unsubscribe", AgentsEntriesUnsubscribe(SessionRef) -> bool,
            classes: [User], writes: false,
            doc: "this connection no longer gets the session's `agent-entries` events",
        ),
        method!(
            "agents/tool-input", AgentsToolInput(ToolInputParams) -> ToolInput,
            classes: [User], writes: false,
            doc: "a tool call's raw input, which no event carries (at most 256 KiB, else its JSON text cut and `truncated`)",
        ),
        method!(
            "agents/pause", AgentsPause(ById) -> bool,
            classes: [User], writes: true,
            doc: "the session's turn is cancelled once the tool call running now completes, and its queue is held",
        ),
        method!(
            "agents/wheel/take", AgentsWheelTake(ById) -> bool,
            classes: [User], writes: true,
            doc: "the user takes the session's wheel: it stops after its current step, and once that turn has ended (agent-wheel held) nothing of it is written until the give",
        ),
        method!(
            "agents/wheel/give", AgentsWheelGive(ById) -> bool,
            classes: [User], writes: true,
            doc: "the user gives the wheel back (refused until held, and while the editor has unsaved buffers in the session's own worktree): the user's changes since the take go to the agent first, then its queue",
        ),
        method!(
            "agents/wheel/saved", AgentsWheelSaved(WheelSaved) -> bool,
            classes: [User], writes: false,
            doc: "the editor's answer to wheel-save: the files it left unsaved (true when a give was waiting for it)",
        ),
        method!(
            "agents/probe", AgentsProbe(ProbeParams) -> ProbeResult,
            classes: [User], writes: false,
            doc: "whether a profile's agent starts and answers initialize (it is started in its sandbox, asked, and ended; no session is made)",
            check: check_probe,
        ),
    ]
}
