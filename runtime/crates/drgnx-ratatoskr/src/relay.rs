//! The backend's events, relayed (design 8.2, review C5): the front subscribes to the backend once per backend start,
//! and each event the backend sends is decoded against the registry's event type of its name before the front's
//! subscribers get it.  Only the kinds main broadcasts that are still the backend's are relayed ([`RELAYED`]); an event
//! of another name, or one whose data does not decode, is dropped and logged (its name, cut, and the path where it
//! failed; never its data).
//!
//! - `events`, the event log, is the front's own since its writer writes the log ([`crate::coord`]; the backend's is
//!   dropped before it gets here).
//! - The gateway's events are the front's since Task 22 ([`crate::gateway`]): a backend's `request` and `budget` are
//!   dropped, and so is a `fallback` without a `job` (the Lisp gateway's).  A `fallback` with its `job` is the job
//!   runner's (a task moved to the next profile, `drgnx-job.el`) and is relayed.

use crate::front::Front;
use runstav::events;
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::mpsc;

/// The events the Lisp backend broadcasts on main (`drgnx-hub--broadcast`) that the front relays.
pub const RELAYED: [&str; 6] = [
    "agent",
    "agent-entries",
    "lease-released",
    "fallback",
    "card",
    "job",
];

/// The gateway's events, which the front sends itself: a backend's are dropped.
pub const THE_GATEWAYS: [&str; 3] = ["request", "budget", "fallback"];

/// How many backend events may wait for the relay.
pub const QUEUE: usize = 1024;

/// EVENT's DATA as the front relays it (decoded and encoded again), or why it is dropped.
pub fn check(event: &str, data: &Value) -> Result<Value, String> {
    let the_job_runners = event == "fallback" && data.get("job").is_some_and(Value::is_string);
    if THE_GATEWAYS.contains(&event) && !the_job_runners {
        return Err("the gateway's events are the front's".into());
    }
    if !RELAYED.contains(&event) {
        return Err("not an event the backend sends".into());
    }
    let t = events::event(event).ok_or("no such event type")?;
    (t.check)(data).map_err(|e| match e.path {
        Some(p) => format!("its data does not decode at {p}"),
        None => "its data does not decode".into(),
    })
}

/// Relay what the backend sends on EVENTS to FRONT's subscribers, until the backend side is gone.
pub async fn run(mut events: mpsc::Receiver<(String, Value)>, front: Arc<Front>) {
    while let Some((event, data)) = events.recv().await {
        match check(&event, &data) {
            Ok(data) => front.broadcast(&event, data),
            Err(why) => {
                let name: String = event.chars().take(64).collect();
                tracing::warn!(event = name, "dropped a backend event: {why}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// V with its `null`s left out and its numbers as floats: what a relay may change (an absent key and a null
    /// say the same; a number typed `f64` is encoded `120.0`).
    fn plain(v: &Value) -> Value {
        match v {
            Value::Object(o) => Value::Object(
                o.iter()
                    .filter(|(_, x)| !x.is_null())
                    .map(|(k, x)| (k.clone(), plain(x)))
                    .collect(),
            ),
            Value::Array(a) => Value::Array(a.iter().map(plain).collect()),
            Value::Number(n) => json!(n.as_f64()),
            other => other.clone(),
        }
    }

    fn fixture() -> Vec<Value> {
        let file = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/conformance/fixtures/backend-events.json"
        );
        serde_json::from_str(&std::fs::read_to_string(file).expect("the fixture"))
            .expect("the fixture's JSON")
    }

    #[test]
    fn every_kind_main_sends_is_relayed_as_the_fixture_has_it() {
        let all = fixture();
        let mut names: Vec<&str> = all.iter().map(|e| e["event"].as_str().unwrap()).collect();
        names.sort_unstable();
        let mut want = RELAYED.to_vec();
        want.extend(["events", "request", "budget"]);
        want.sort_unstable();
        assert_eq!(names, want, "one event of each kind");
        // the event log is the front's: a backend's `events` is never relayed
        let log = all.iter().find(|e| e["event"] == "events").unwrap();
        assert!(check("events", &log["data"]).is_err());
        for e in all.iter().filter(|e| e["event"] != "events") {
            let name = e["event"].as_str().unwrap();
            // the fixture's fallback is the Lisp gateway's (no job)
            if THE_GATEWAYS.contains(&name) {
                assert_eq!(
                    check(name, &e["data"]),
                    Err("the gateway's events are the front's".into()),
                    "{name}"
                );
                continue;
            }
            let relayed = check(name, &e["data"]).unwrap_or_else(|w| panic!("{name}: {w}"));
            assert_eq!(
                plain(&relayed),
                plain(&e["data"]),
                "the fixture's {name} is relayed as it is"
            );
        }
        // every relayed kind is a registry event
        for name in RELAYED {
            assert!(events::event(name).is_some(), "{name}");
        }
    }

    #[test]
    fn the_job_runners_fallback_is_relayed_and_the_gateways_is_not() {
        let runner = json!({"job": "j1", "task": "j1#2", "agent": "agent-3", "from": "claude", "to": "codex",
                            "why": "exit 1"});
        assert_eq!(
            check("fallback", &runner).map(|v| plain(&v)),
            Ok(plain(&runner))
        );
        let gateway =
            json!({"agent": "agent-2", "from": "openrouter", "to": "anthropic", "why": "HTTP 429"});
        assert!(check("fallback", &gateway).is_err());
        assert!(check("budget", &json!({"job": "j1", "spent": 2.5, "budget": 2.0})).is_err());
    }

    #[test]
    fn other_names_and_bad_data_are_dropped() {
        assert!(check("challenge", &json!({"nonce": "0".repeat(32)})).is_err());
        assert!(check("notice", &json!({})).is_err());
        assert!(check("no-such", &json!({})).is_err());
        assert!(check("gateway/need-keys", &json!({"providers": ["openrouter"]})).is_err());
        let e = check("job", &json!({"id": "j", "extra": 1})).unwrap_err();
        assert!(e.contains("extra"), "{e}");
        assert!(check("card", &json!({"id": "not a number"})).is_err());
        // null lists come out empty
        assert_eq!(
            check(
                "agent-entries",
                &json!({"id": "s", "seq": 1, "entries": null})
            ),
            Ok(json!({"id": "s", "seq": 1, "entries": []}))
        );
    }
}
