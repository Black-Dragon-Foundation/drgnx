//! The events a hub sends unasked, `{event, data}`: the nine the old Lisp backend broadcast and the front's own `challenge`, `notice`,
//! `gateway/need-keys`, `gateway/keys-changed`, `settings/proposed` and `settings/explain` (the agents' settings tools, to the editor),
//! and the agent core's `agent-step`, `exec-done`, `supervisor`, `view-written` and `view-proposal` (agent system
//! part 1).  The hub sends them all; `card` and `lease-released` were the Lisp backend's, and no one sends them now.

use crate::methods::agents::{Entry, Snapshot};
use crate::methods::gateway::KeysHeld;
use crate::methods::hub::EventsPage;
use crate::registry::{check_as, schema_of};
use crate::types::{Nonce, null_as_empty};
use crate::wire::Error;
use schemars::{JsonSchema, Schema};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::LazyLock;

/// One event: its name, a line of doc, the JSON Schema of its `data` and its check (decode, then re-encode).
pub struct EventType {
    pub name: &'static str,
    pub doc: &'static str,
    pub data: fn() -> Schema,
    pub check: fn(&Value) -> Result<Value, Error>,
}

/// A session's snapshot changed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentEvent {
    pub id: String,
    pub seq: u64,
    pub session: Snapshot,
}

/// Entries new or changed since the last time, `[index, Entry]` each.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentEntries {
    pub id: String,
    pub seq: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entries: Vec<(u64, Entry)>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LeaseReleased {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
}

/// A request or a task moved to the next provider or profile: the gateway's `{agent, from, to, why}`, a job's with
/// `job` and `task` too.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Fallback {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Card {
    pub id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// A card that lists its answers (a browser row's matrix card): the ids `cards/settle` takes, with their labels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub choices: Option<Vec<CardChoice>>,
    /// What the user should know before answering, in one line (the hub's text).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
}

/// One answer a card lists.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CardChoice {
    pub id: String,
    pub label: String,
}

/// A job's status, tasks or open cards changed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct JobChanged {
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Budget {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<f64>,
}

/// One request the gateway forwarded, and what it cost.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Request {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
}

/// Providers whose key the hub does not hold, though a registration needs it: an editor hands its keys over.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct NeedKeys {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub providers: Vec<String>,
}

/// The front's nonce, sent on accept: the client's proof covers it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Challenge {
    pub nonce: Nonce,
}

/// A message for the user from the hub itself (the notices' shape).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Notice {
    pub source: String,
    pub severity: String,
    pub id: String,
    pub life: String,
    pub text: String,
    /// The command that acts on it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

macro_rules! event {
    ($name:literal, $ty:ty, $doc:literal) => {
        EventType {
            name: $name,
            doc: $doc,
            data: schema_of::<$ty>,
            check: check_as::<$ty>,
        }
    };
}

static EVENTS: LazyLock<Vec<EventType>> = LazyLock::new(|| {
    let mut v = vec![
        event!(
            "agent",
            AgentEvent,
            "a session's snapshot changed (at most one per session per 50 ms)"
        ),
        event!(
            "agent-entries",
            AgentEntries,
            "a session's entries new or changed since the last time, without `rawInput`, only to the connections that subscribed to the session (`agents/entries/subscribe`)"
        ),
        event!(
            "events",
            EventsPage,
            "the event log's new rows (at most 200 a time, every 0.25 s at most)"
        ),
        event!("lease-released", LeaseReleased, "a task's claim ran out"),
        event!(
            "fallback",
            Fallback,
            "a request or a task moved to the next provider or profile"
        ),
        event!("card", Card, "a job's card needs the user"),
        event!(
            "job",
            JobChanged,
            "a job's status, tasks or open cards changed"
        ),
        event!("budget", Budget, "a job's spend reached its budget"),
        event!(
            "request",
            Request,
            "the gateway forwarded a request: its tokens and cost"
        ),
        event!(
            "gateway/need-keys",
            NeedKeys,
            "a registration needs keys the hub does not hold (to user connections)"
        ),
        event!(
            "gateway/keys-changed",
            KeysHeld,
            "the providers whose key the hub holds changed: their ids, never a key (to user connections)"
        ),
        event!("challenge", Challenge, "the hub's nonce, sent on accept"),
        event!(
            "notice",
            Notice,
            "a message for the user from the hub itself"
        ),
        event!(
            "settings/proposed",
            crate::methods::settings::Proposed,
            "an agent's granted settings change, as a proposed tx: the editor checks it, writes the file and answers settings/confirm"
        ),
        event!(
            "settings/explain",
            crate::methods::settings::Explain,
            "an agent's settings_get: the editor answers settings/explained with the same req"
        ),
        event!(
            "agent-step",
            crate::methods::timeline::AgentStep,
            "a session's step opened or closed, with its class, stamps and anchors (to subscribers that asked)"
        ),
        event!(
            "machines-changed",
            crate::methods::work::MachinesList,
            "the machines the hub lists changed (a report, an expiry, a local slot): the whole list"
        ),
        event!(
            "runners-changed",
            crate::methods::runners::Runners,
            "the runners changed (one added, removed, benched or back in rotation, its trust or state, its load): the whole list"
        ),
        event!(
            "plugin",
            crate::methods::plugins::PluginChanged,
            "a plugin's state changed (installed, approved, changed on disk, disabled, broken or removed): its name and new state"
        ),
        event!(
            "runners/need-keys",
            crate::methods::runners::KeyNames,
            "a job needs keys the hub does not hold (names only; to user connections): answered only by a command the user runs"
        ),
        event!(
            "agent-buffer",
            crate::methods::editor::BufferFrame,
            "a watched buffer view's frame changed: the agents in it and the gutter, at most once per view per 50 ms of the hub's clock, to the watching connection only (agents/buffer/watch)"
        ),
        event!(
            "agent-presence",
            crate::methods::work::FilePresence,
            "who is in a file now changed: its entries, at most once per file per 100 ms, to the connections that asked (agents/presence/subscribe)"
        ),
        event!(
            "work-map",
            crate::methods::work::WorkMap,
            "what changed in one Work map view since its version base, to that view's connection only (work/map/subscribe): at most one delta per 100 ms, a full frame on a relayout, a stale mark for a hidden view"
        ),
        event!(
            "exec-done",
            crate::methods::exec::ExecDone,
            "a job ended: its status, exit and summary"
        ),
        event!(
            "supervisor",
            crate::methods::timeline::SupervisorEvent,
            "the supervisor paused an agent by a rule, with its card"
        ),
        event!(
            "view-written",
            crate::methods::records::ViewWritten,
            "the hub wrote a record view file (never committed)"
        ),
        event!(
            "view-proposal",
            crate::methods::records::ViewProposal,
            "a hand edit to a view became a proposal (Records: Review Proposal)"
        ),
        event!(
            "say-proposal",
            crate::methods::say::SayProposal,
            "a planning session's proposal is a job, waiting for the user's OK or started by the Autonomous preset"
        ),
        event!(
            "say-message",
            crate::methods::say::SayMessage,
            "a planning session asks the user something (agent-written text)"
        ),
        event!(
            "say-failed",
            crate::methods::say::SayFailed,
            "a planning session gave up: its blocks did not hold, with the reasons"
        ),
        event!(
            "agent-wheel",
            crate::methods::agents::AgentWheel,
            "the user's hold on a session's wheel: held once the turn the take stopped has ended (a step snapshot is taken first), free once it is given back"
        ),
        event!(
            "huddle",
            crate::methods::agents::Huddle,
            "a huddle opened or changed: its record (the replies are agent text, quoted, never instructions)"
        ),
        event!(
            "wheel-save",
            crate::methods::agents::WheelSave,
            "the user gives back the wheel of a session in a worktree of its own: the editor saves its buffers there and answers agents/wheel/saved with the files left unsaved"
        ),
        event!(
            "pair-apply",
            crate::methods::pair::PairApply,
            "a paired chat's write, to the editor that has the file open: it applies it whole or refuses it whole and answers pair/answer; ttl_ms counts from its arrival"
        ),
        event!(
            "pair-read",
            crate::methods::pair::PairRead,
            "a paired chat's read of a file the editor may have open: the editor answers pair/read-answer with the buffer's text and version"
        ),
        event!(
            "pair-drop",
            crate::methods::pair::PairDrop,
            "the user turned pair off for a chat or took its wheel: the editor drops that session's queued writes, answering each pair/answer dropped with the reason"
        ),
        event!(
            "pair-reconcile",
            crate::methods::pair::PairReconcile,
            "a pair write whose answer did not come in its time to live: the editor answers pair/answer from what it applied"
        ),
        event!(
            "view-model",
            crate::methods::view::ViewModel,
            "what changed in one hub-fed view's model, to its connection only: one JSON string the editor's replica takes whole (a reset first, after a hidden view is shown again and on view/resync with model), written before the rows built from it, which name its version"
        ),
        event!(
            "view-patch",
            crate::methods::view::Patch,
            "what changed in one (view, display class) of a hub-fed view, to its connection only: a reset first and after every new env epoch, then ops against the version base; every patch names the hub's instance id and the editor's epoch"
        ),
        event!(
            "term/exit",
            crate::methods::term::TermExit,
            "a terminal's program ended (its code, or the signal), to the connection of the editor session that opened it; the terminal is gone"
        ),
        event!(
            "term/title",
            crate::methods::term::TermTitle,
            "a terminal's program set its title, to its editor session's connection"
        ),
        event!(
            "term/cwd",
            crate::methods::term::TermCwd,
            "a terminal's shell reported its working directory (OSC 7), to its editor session's connection"
        ),
        event!(
            "term/bell",
            crate::methods::term::TermBell,
            "a terminal's program rang the bell, to its editor session's connection"
        ),
        event!(
            "term/notify",
            crate::methods::term::TermNotify,
            "a terminal's program asked for a notification (OSC 9, 777), to its editor session's connection"
        ),
        event!(
            "term/progress",
            crate::methods::term::TermProgress,
            "a terminal's program reported progress (OSC 9;4), to its editor session's connection"
        ),
        event!(
            "term/clipboard-write",
            crate::methods::term::TermClipboardWrite,
            "a terminal's program wrote the clipboard (OSC 52; only when clipboard-write allows), to its editor session's connection"
        ),
        event!(
            "term/prompt",
            crate::methods::term::TermPrompt,
            "a terminal's shell sent an OSC 133 mark (prompt, input, output, command end with its status), to its editor session's connection"
        ),
        event!(
            "view-glyphs",
            crate::methods::view::ViewGlyphsAsk,
            "the hub asks the editor for advances it cannot read from a font file, [role, char] each: answered by view/glyphs"
        ),
        event!(
            "search-grep-done",
            crate::methods::search::GrepDone,
            "a text search (search/grep) ended: its query number, the files and matches it found, or why it could not run; to the searching connection only; a search a newer one stopped says nothing"
        ),
        event!(
            "agent-follow",
            crate::methods::editor::AgentFollow,
            "where the session a follow view follows is now, to that view's connection only (agents/follow): at most one move per 200 ms, a read's file switch after a 500 ms dwell, a search never switches; the line is the agent's own plan entry or step title"
        ),
    ];
    v.sort_by_key(|e| e.name);
    v
});

/// Every event type, sorted by name.
pub fn events() -> &'static [EventType] {
    &EVENTS
}

/// The event type called `name`.
pub fn event(name: &str) -> Option<&'static EventType> {
    let all = events();
    all.binary_search_by_key(&name, |e| e.name)
        .ok()
        .map(|i| &all[i])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeSet;

    #[test]
    fn event_types_are_the_broadcast_names() {
        // what the old Lisp backend broadcast, frozen when the Lisp runtime was deleted
        let found: BTreeSet<String> = [
            "agent",
            "agent-entries",
            "budget",
            "card",
            "events",
            "fallback",
            "job",
            "lease-released",
            "request",
        ]
        .iter()
        .map(|n| (*n).to_owned())
        .collect();
        let ours: BTreeSet<String> = events()
            .iter()
            .map(|e| e.name.to_string())
            .filter(|n| {
                ![
                    "challenge",
                    "notice",
                    "gateway/need-keys",
                    "gateway/keys-changed",
                    "settings/proposed",
                    "settings/explain",
                    // the agent core's (agent system part 1): the Lisp never sends them
                    "agent-step",
                    "exec-done",
                    "supervisor",
                    "view-written",
                    "view-proposal",
                    // agent system part 2
                    "machines-changed",
                    "runners-changed",
                    "plugin",
                    "runners/need-keys",
                    "agent-presence",
                    "work-map",
                    // agent system part 3
                    "agent-buffer",
                    // agent system part 5
                    "say-proposal",
                    "say-message",
                    "say-failed",
                    // agent system part 3: take the wheel
                    "agent-wheel",
                    "wheel-save",
                    // agent system part 3: huddles
                    "huddle",
                    // agent system part 3: pair mode
                    "pair-apply",
                    "pair-drop",
                    "pair-read",
                    "pair-reconcile",
                    // agent system part 3: the follow feed
                    "agent-follow",
                    // hub-built rows (the render offload)
                    "view-patch",
                    "view-glyphs",
                    "search-grep-done",
                    // the native view model
                    "view-model",
                    // the terminals
                    "term/exit",
                    "term/title",
                    "term/cwd",
                    "term/bell",
                    "term/notify",
                    "term/progress",
                    "term/clipboard-write",
                    "term/prompt",
                ]
                .contains(&n.as_str())
            })
            .collect();
        assert_eq!(ours, found);
        assert_eq!(found.len(), 9, "{found:?}");
    }

    #[test]
    fn events_are_sorted_and_found() {
        let names: Vec<&str> = events().iter().map(|e| e.name).collect();
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
        assert_eq!(events().len(), 50);
        // names only: a value-shaped name is no key name, and nothing but `names` is taken
        let need = event("runners/need-keys").unwrap();
        assert_eq!(
            (need.check)(&json!({"names": ["CRATES_IO_TOKEN"]})).unwrap(),
            json!({"names": ["CRATES_IO_TOKEN"]})
        );
        assert!((need.check)(&json!({"names": ["sk or-v1 x"]})).is_err());
        assert!((need.check)(&json!({"names": [], "keys": {"a": "k"}})).is_err());
        assert!(event("settings/proposed").is_some());
        // ids only: a key-shaped value is no id, and nothing but `providers` is taken
        let changed = event("gateway/keys-changed").unwrap();
        assert_eq!(
            (changed.check)(&json!({"providers": ["anthropic", "openrouter"]})).unwrap(),
            json!({"providers": ["anthropic", "openrouter"]})
        );
        assert!((changed.check)(&json!({"providers": ["sk or-v1 x"]})).is_err());
        assert!((changed.check)(&json!({"providers": [], "keys": {"a": "k"}})).is_err());
        assert!(event("request").is_some());
        assert_eq!(
            (event("gateway/need-keys").unwrap().check)(&json!({"providers": ["openrouter"]}))
                .unwrap(),
            json!({"providers": ["openrouter"]})
        );
        assert!(event("agent-entries").is_some());
        assert!(event("nope").is_none());
    }

    #[test]
    fn an_event_is_checked_strictly() {
        let card = event("card").unwrap();
        assert_eq!(
            (card.check)(
                &json!({"id": 3, "job": "j", "task": null, "kind": "review", "title": "t"})
            )
            .unwrap(),
            json!({"id": 3, "job": "j", "kind": "review", "title": "t"})
        );
        let e = (card.check)(&json!({"id": 3, "surprise": 1})).unwrap_err();
        assert!(e.message.contains("surprise"), "{e:?}");
        let entries = event("agent-entries").unwrap();
        assert_eq!(
            (entries.check)(
                &json!({"id": "s", "seq": 2, "entries": [[0, {"type": "tool", "id": "t1"}]]})
            )
            .unwrap(),
            json!({"id": "s", "seq": 2, "entries": [[0, {"type": "tool", "id": "t1"}]]})
        );
        let e = (entries.check)(&json!({"id": "s", "seq": 2, "entries": [[0, {"type": "dance"}]]}))
            .unwrap_err();
        assert_eq!(e.path.as_deref(), Some("entries[0][1].type"), "{e:?}");
        let page = event("events").unwrap();
        assert_eq!(
            (page.check)(&json!({"since": 0, "last": 0, "events": null})).unwrap(),
            json!({"since": 0, "last": 0, "events": []})
        );
    }
}
