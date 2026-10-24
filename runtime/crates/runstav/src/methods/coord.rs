//! Coordination: the front writes work.db's coordination and job tables (docs/develop/coordination.md, "Who writes
//! what").  Every method here is the front's own (`Home::Front`), so the Lisp backend may call them too:
//!
//! - `coord/notify`: a coordination server wrote; the front's events go out and the backend hears it (coalesced);
//! - the editor's five writes: `cards/settle`, `messages/send`, `messages/mark`, `events/add`, `review/mark`;
//! - the seam (`coord/*`): the Lisp job runner's writes, each one writer of `core/drgnx-coord.el`, until the job
//!   runner itself moves (phase 6).
//!
//! Params mirror the Lisp writers' keywords; results are the Lisp answers, typed.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AgentName, Bounded, Id, JsonObject, Status, TaskRef, Text, null_as_empty};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

// ---- the editor's methods ----

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SettleParams {
    pub card: u64,
    pub choice: Text,
}

/// `cards/settle`'s answer: false when the card was not open (nothing happens twice).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Settled {
    pub settled: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SendParams {
    /// `user`, an agent's id, or a job's task holder.
    pub recipient: AgentName,
    pub text: Text,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    /// Only the Lisp backend names a sender (its agents' messages); an editor always sends as the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender: Option<AgentName>,
    /// The decision-log version the sender last read: behind the log, nothing is sent and the answer is held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<u64>,
    /// The question to the user (a message's id) this message answers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answers: Option<u64>,
    /// A message to `user` that is a question (the `ask_user` tool).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub question: Option<bool>,
}

/// One decision as the log has it (`drgnx-coord--decision-plist`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Decision {
    pub n: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paths: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replaces: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ver: Option<i64>,
}

/// `messages/send`'s answer (`drgnx-coord-send`): `{ok, id, state}` (state `queued`, or `held` when the recipient's
/// queue is full or the two talk too much), or `{held, version, changes}` when the sender's `seen` is behind the log
/// (nothing was sent; `changes` are the decisions after `seen`, newest first).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SendResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<Vec<Decision>>,
}

/// The states a message moves on to (never back; `held` stands apart).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum MessageState {
    Delivered,
    Read,
    Acted,
}

impl MessageState {
    pub fn as_str(self) -> &'static str {
        match self {
            MessageState::Delivered => "delivered",
            MessageState::Read => "read",
            MessageState::Acted => "acted",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct MarkParams {
    pub id: u64,
    pub state: MessageState,
}

/// `messages/mark`'s answer: whether the message moved on.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Changed {
    pub changed: bool,
}

/// What an event can be (`drgnx-coord-event-kinds`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum EventKind {
    Start,
    Stop,
    Claim,
    Release,
    Status,
    Decision,
    Edit,
    Test,
    Question,
    Answer,
    Review,
    Message,
    Card,
    Accept,
    Revert,
    Comment,
    Job,
}

impl EventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EventKind::Start => "start",
            EventKind::Stop => "stop",
            EventKind::Claim => "claim",
            EventKind::Release => "release",
            EventKind::Status => "status",
            EventKind::Decision => "decision",
            EventKind::Edit => "edit",
            EventKind::Test => "test",
            EventKind::Question => "question",
            EventKind::Answer => "answer",
            EventKind::Review => "review",
            EventKind::Message => "message",
            EventKind::Card => "card",
            EventKind::Accept => "accept",
            EventKind::Revert => "revert",
            EventKind::Comment => "comment",
            EventKind::Job => "job",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct AddEventParams {
    pub kind: EventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentName>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    /// Cut to one line of at most 200 characters.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<Text>,
    /// Stored as `{"truncated": true, "size": N}` over 4096 characters; a start or stop with `turn: true` is a turn's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
    /// Telemetry: a busy work.db answers `{}`, not an error.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub best_effort: Option<bool>,
}

/// `events/add`'s answer: the event's id (none when a best-effort event met a busy work.db).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Added {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ReviewState {
    Accepted,
    Pending,
}

impl ReviewState {
    pub fn as_str(self) -> &'static str {
        match self {
            ReviewState::Accepted => "accepted",
            ReviewState::Pending => "pending",
        }
    }
}

/// The review's own event, written in the mark's transaction (its agent is the mark's).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReviewEvent {
    pub kind: EventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReviewMarkParams {
    pub agent: AgentName,
    pub path: Bounded<String, 4096>,
    pub state: ReviewState,
    /// The diff's hash the mark is for (the merge gate compares it).
    pub hash: Bounded<String, 128>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<ReviewEvent>,
}

// ---- the seam: the Lisp job runner's writes until phase 6 ----

/// One task of a new job: without `deps` it starts `ready`, else `pending`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NewTask {
    pub n: u64,
    pub title: Text,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Bounded<String, 64>>,
    /// The numbers of the job's tasks this one waits on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deps: Option<Bounded<Vec<u64>, 1000>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct JobCreateParams {
    pub id: Id,
    pub title: Text,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Bounded<String, 4096>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<Bounded<String, 4096>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks: Option<Bounded<Vec<NewTask>, 1000>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
}

/// The id of what was made: a job's.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct JobCreated {
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct JobSetParams {
    pub id: Id,
    /// A change leaves a `job` event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TaskStatusParams {
    pub task: TaskRef,
    pub status: Status,
    /// The holder; `null` (or none) leaves the task without one.
    #[serde(default)]
    pub agent: Option<AgentName>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct LeasesParams {
    /// These agents are alive: each one's claims are renewed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub renew: Option<Bounded<Vec<AgentName>, 1000>>,
    /// Then the claims whose lease ran out are released.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_stale: Option<bool>,
}

/// A claim whose lease ran out, released.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Released {
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Leases {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub released: Vec<Released>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DecideParams {
    /// `build`, `wait`, `wont-build` or `replaces`.
    pub kind: Bounded<String, 32>,
    pub subject: Text,
    pub author: AgentName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paths: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<u64>,
    /// A decision's number, marked replaced when this one is current.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replaces: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
}

/// `coord/decide`'s answer (`drgnx-coord-decide`): `{ok, n, status, version}`, `{held, version, changes}` or `{error}`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Decided {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<Vec<Decision>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// An agent's field `clear` sets to null.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum AgentField {
    Kind,
    Name,
    Cwd,
    Worktree,
    Branch,
    Base,
    Plan,
    Task,
    Pid,
}

impl AgentField {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentField::Kind => "kind",
            AgentField::Name => "name",
            AgentField::Cwd => "cwd",
            AgentField::Worktree => "worktree",
            AgentField::Branch => "branch",
            AgentField::Base => "base",
            AgentField::Plan => "plan",
            AgentField::Task => "task",
            AgentField::Pid => "pid",
        }
    }
}

/// An agent that works (again): what is given is stored, what is not is kept.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct AgentRow {
    pub id: AgentName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<Bounded<String, 64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Bounded<String, 256>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<Bounded<String, 4096>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<Bounded<String, 4096>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<Bounded<String, 256>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<Bounded<String, 256>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Bounded<String, 4096>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
    /// Fields set to null after the rest is stored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clear: Option<Bounded<Vec<AgentField>, 9>>,
}

/// `{register: AgentRow}` or `{seen: AgentName}`: one of the two.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct AgentParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub register: Option<AgentRow>,
    /// This agent is alive now: stamped (telemetry: a busy work.db answers `{}`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<AgentName>,
}

fn check_agent(p: &AgentParams) -> Result<(), Error> {
    match (&p.register, &p.seen) {
        (Some(_), None) | (None, Some(_)) => Ok(()),
        _ => Err(Error {
            code: ErrorCode::InvalidParams,
            message: "coord/agent takes one of register or seen".into(),
            path: None,
        }),
    }
}

/// `coord/agent`'s answer: the registered agent's `id`, or the `seen` stamp (none when it was never registered).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CardCreateParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    /// `ask` makes it a question to the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<Bounded<String, 64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
}

/// The id of what was made: a card's.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CardCreated {
    pub id: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CardSetParams {
    pub id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
    /// A change (a reopened card) leaves a `card` event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<Status>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HeldParams {
    pub agent: AgentName,
    /// The agent's write was held (its count goes up by one), or went through (the count is 0).
    pub held: bool,
}

/// `coord/prune`'s answer: whether the daily prune ran (the cap is held either way).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Pruned {
    pub pruned: bool,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "coord/notify", CoordNotify(Empty) -> bool,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "a coordination server wrote: the new events go out, and the backend hears it (coalesced: one a 0.25 s) and runs delivery (a notification; users too, SB-T12-4)",
        ),
        method!(
            "cards/settle", CardsSettle(SettleParams) -> Settled,
            classes: [User], writes: true, home: Front,
            doc: "an open card settled with a choice, once (drgnx-coord-card-settle)",
        ),
        method!(
            "messages/send", MessagesSend(SendParams) -> SendResult,
            classes: [User], writes: true, home: Front,
            doc: "a message, from the user (only the backend names another sender); held when seen is behind the decision log (drgnx-coord-send)",
        ),
        method!(
            "messages/mark", MessagesMark(MarkParams) -> Changed,
            classes: [User], writes: true, home: Front,
            doc: "a message moved on to delivered, read or acted, never back (drgnx-coord-mark)",
        ),
        method!(
            "events/add", EventsAdd(AddEventParams) -> Added,
            classes: [User], writes: true, home: Front,
            doc: "an event in the log (drgnx-coord-event-add; best_effort: a busy work.db is no error)",
        ),
        method!(
            "review/mark", ReviewMark(ReviewMarkParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "a review mark on an agent's change, and its event, in one transaction (drgnx-coord-review-mark)",
        ),
        method!(
            "coord/job-create", CoordJobCreate(JobCreateParams) -> JobCreated,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-job-create)",
        ),
        method!(
            "coord/job-set", CoordJobSet(JobSetParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-job-set)",
        ),
        method!(
            "coord/task-status", CoordTaskStatus(TaskStatusParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-force-status)",
        ),
        method!(
            "coord/leases", CoordLeases(LeasesParams) -> Leases,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-renew, drgnx-coord-release-stale)",
        ),
        method!(
            "coord/decide", CoordDecide(DecideParams) -> Decided,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-decide)",
        ),
        method!(
            "coord/agent", CoordAgent(AgentParams) -> AgentResult,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-agent-register, drgnx-coord-agent-seen)",
            check: check_agent,
        ),
        method!(
            "coord/card-create", CoordCardCreate(CardCreateParams) -> CardCreated,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-card-create)",
        ),
        method!(
            "coord/card-set", CoordCardSet(CardSetParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-card-set)",
        ),
        method!(
            "coord/held", CoordHeld(HeldParams) -> bool,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-note-held)",
        ),
        method!(
            "coord/prune", CoordPrune(Empty) -> Pruned,
            classes: [User], writes: true, home: Front,
            doc: "seam: the Lisp job runner's writes until phase 6 (drgnx-coord-events-prune-daily; never fails)",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn coord_agent_takes_one_of_register_or_seen() {
        let m = find("coord/agent").unwrap();
        assert!((m.decode)(&json!({"seen": "a1"})).is_ok());
        assert!((m.decode)(&json!({"register": {"id": "a1", "clear": ["pid"]}})).is_ok());
        for bad in [json!({}), json!({"seen": "a1", "register": {"id": "a1"}})] {
            let e = (m.decode)(&bad).err().unwrap();
            assert!(e.message.contains("one of register or seen"), "{e:?}");
        }
    }

    #[test]
    fn a_long_typed_answer_settles_a_card() {
        // review M1: an ask card's free answer is a paragraph, not a button's name
        let m = find("cards/settle").unwrap();
        let long = "a".repeat(1_000);
        let (p, _) = (m.decode)(&json!({"card": 7, "choice": long})).unwrap();
        assert_eq!(p.to_value(), json!({"card": 7, "choice": long}));
        let e = (m.decode)(&json!({"card": 7, "choice": "a".repeat(65_537)}))
            .err()
            .unwrap();
        assert_eq!(e.path.as_deref(), Some("choice"), "{e:?}");
    }

    #[test]
    fn task_status_agent_may_be_null() {
        let m = find("coord/task-status").unwrap();
        let (p, _) = (m.decode)(&json!({"task": "j#1", "status": "ready", "agent": null})).unwrap();
        assert_eq!(
            p.to_value(),
            json!({"task": "j#1", "status": "ready", "agent": null})
        );
        assert!((m.decode)(&json!({"task": "j#1", "status": "Ready"})).is_err());
    }

    #[test]
    fn results_encode_as_the_lisp_answers() {
        let send = find("messages/send").unwrap();
        let held =
            json!({"held": true, "version": 3, "changes": [{"n": 2, "kind": "build", "ver": 3}]});
        assert_eq!((send.check_result)(&held).unwrap(), held);
        let ok = json!({"ok": true, "id": 7, "state": "queued"});
        assert_eq!((send.check_result)(&ok).unwrap(), ok);
        let decide = find("coord/decide").unwrap();
        let e = json!({"error": "too many decisions in a minute (6): wait, or ask the user"});
        assert_eq!((decide.check_result)(&e).unwrap(), e);
        let leases = find("coord/leases").unwrap();
        assert_eq!(
            (leases.check_result)(&json!({"released": null})).unwrap(),
            json!({"released": []})
        );
    }
}
