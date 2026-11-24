//! Coordination: the hub, the one writer, writes work.db's coordination and job tables (docs/develop/coordination.md,
//! "Who writes what"):
//!
//! - `coord/notify`: a coordination server wrote; the front's events go out and delivery runs (coalesced);
//! - the editor's five writes: `cards/settle`, `messages/send`, `messages/mark`, `events/add`, `review/mark`;
//!
//! Params mirror the Lisp writers' keywords; results are the Lisp answers, typed.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AgentName, Bounded, Id, JsonObject, TaskRef, Text};
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
    /// Refused from every caller (`invalid-params`): a message's sender is its connection's, so an editor always
    /// sends as the user.
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

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RetractParams {
    /// The message's id.
    pub id: u64,
}

/// `messages/retract`'s answer: taken back only while it was still queued; else the status it had.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Retracted {
    pub retracted: bool,
    pub status: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "messages/retract", MessagesRetract(RetractParams) -> Retracted,
            classes: [User], writes: true,
            doc: "the user's message taken back while it is still queued (never once delivered)",
        ),
        method!(
            "coord/notify", CoordNotify(Empty) -> bool,
            classes: [User, Agent, Service], writes: false,
            doc: "a coordination server wrote: the new events go out (coalesced: one a 0.25 s) and delivery runs (a notification; users too, SB-T12-4)",
        ),
        method!(
            "cards/settle", CardsSettle(SettleParams) -> Settled,
            classes: [User], writes: true,
            doc: "an open card settled with a choice, once (drgnx-coord-card-settle)",
        ),
        method!(
            "messages/send", MessagesSend(SendParams) -> SendResult,
            classes: [User], writes: true,
            doc: "a message, from the user (a sender param is refused); held when seen is behind the decision log (drgnx-coord-send)",
        ),
        method!(
            "messages/mark", MessagesMark(MarkParams) -> Changed,
            classes: [User], writes: true,
            doc: "a message moved on to delivered, read or acted, never back (drgnx-coord-mark)",
        ),
        method!(
            "events/add", EventsAdd(AddEventParams) -> Added,
            classes: [User], writes: true,
            doc: "Emacs-era, re-decide at B1: an event in the log (drgnx-coord-event-add; best_effort: a busy work.db is no error)",
        ),
        method!(
            "review/mark", ReviewMark(ReviewMarkParams) -> bool,
            classes: [User], writes: true,
            doc: "Emacs-era, re-decide at B1: a review mark on an agent's change, and its event, in one transaction (drgnx-coord-review-mark)",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::find;
    use serde_json::json;

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
    fn results_encode_as_the_lisp_answers() {
        let send = find("messages/send").unwrap();
        let held =
            json!({"held": true, "version": 3, "changes": [{"n": 2, "kind": "build", "ver": 3}]});
        assert_eq!((send.check_result)(&held).unwrap(), held);
        let ok = json!({"ok": true, "id": 7, "state": "queued"});
        assert_eq!((send.check_result)(&ok).unwrap(), ok);
    }
}
