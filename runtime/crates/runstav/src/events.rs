//! The events a hub sends unasked, `{event, data}`: the nine the Lisp backend broadcasts on main
//! (`core/drgnx-hub.el`, `drgnx-job.el`, `drgnx-gateway.el`) and the front's own `challenge` and `notice`.  The front
//! relays a backend event only when it decodes as its type (strict: an unknown key is an error with its path).

use crate::methods::agents::{Entry, Snapshot};
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
            "a session's entries new or changed since the last time"
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
        event!("challenge", Challenge, "the hub's nonce, sent on accept"),
        event!(
            "notice",
            Notice,
            "a message for the user from the hub itself"
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
    use std::path::Path;

    /// The names after `pattern` + `'` in `text`: `(drgnx-hub--broadcast 'card` → `card`.
    fn names_after(text: &str, pattern: &str, out: &mut BTreeSet<String>) {
        for (i, _) in text.match_indices(pattern) {
            let rest = &text[i + pattern.len()..];
            let name: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
                .collect();
            if !name.is_empty() {
                out.insert(name);
            }
        }
    }

    #[test]
    fn event_types_are_the_broadcast_names() {
        let core = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../core");
        let mut found = BTreeSet::new();
        for f in std::fs::read_dir(&core).unwrap() {
            let p = f.unwrap().path();
            if p.extension().is_some_and(|e| e == "el") {
                let text = std::fs::read_to_string(&p).unwrap();
                names_after(&text, "(drgnx-hub--broadcast '", &mut found);
                names_after(&text, "(drgnx-job--broadcast '", &mut found);
                // also `(apply #'drgnx-gateway--emit 'request row)`
                names_after(&text, "drgnx-gateway--emit '", &mut found);
            }
        }
        let ours: BTreeSet<String> = events()
            .iter()
            .map(|e| e.name.to_string())
            .filter(|n| n != "challenge" && n != "notice")
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
        assert_eq!(events().len(), 11);
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
