//! What waits on the user across the agent sessions, derived once in the hub: the pending permissions as "needs you"
//! items, and how many sessions are at work (busy, or waiting on a permission).  The editor takes the list as the hub
//! sends it (`agents-attention`) and walks no session to make it.

use std::collections::BTreeMap;

use serde_json::{Value, json};

/// One session's part: what the snapshot says of it.
struct Part {
    name: String,
    job: Option<String>,
    working: bool,
    asks: Vec<(Value, String)>,
}

/// The sessions' parts, from their snapshots, and the last data told.
#[derive(Default)]
pub struct Attention {
    parts: BTreeMap<String, Part>,
    last: Option<Value>,
}

impl Attention {
    /// Session SID's snapshot SESSION (the `agent` event's): the new `agents-attention` data when the derived list or
    /// count changed, else none.
    pub fn note(&mut self, sid: &str, session: &Value) -> Option<Value> {
        let exited = session["status"] == "exited";
        let asks: Vec<(Value, String)> = if exited {
            Vec::new()
        } else {
            session["permissions"]
                .as_array()
                .map(|ps| {
                    ps.iter()
                        .map(|p| {
                            let title = p["title"].as_str().unwrap_or("permission");
                            (p["id"].clone(), title.to_owned())
                        })
                        .collect()
                })
                .unwrap_or_default()
        };
        if exited {
            self.parts.remove(sid);
        } else {
            let part = Part {
                name: session["name"].as_str().unwrap_or("").to_owned(),
                job: session["job"].as_str().map(str::to_owned),
                working: session["status"] == "busy" || !asks.is_empty(),
                asks,
            };
            self.parts.insert(sid.to_owned(), part);
        }
        let now = self.derive();
        if self.last.as_ref().unwrap_or(&empty()) == &now {
            return None;
        }
        self.last = Some(now.clone());
        Some(now)
    }

    /// The data the editor needs to start from: none while nothing waits and no session works.
    pub fn current(&self) -> Option<Value> {
        self.last.clone().filter(|v| *v != empty())
    }

    fn derive(&self) -> Value {
        let at_work = self.parts.values().filter(|p| p.working).count();
        let items: Vec<Value> = self
            .parts
            .iter()
            .flat_map(|(sid, p)| {
                p.asks.iter().map(move |(id, title)| {
                    json!({"kind": "permission", "session": sid, "id": id,
                           "text": format!("{} asks: {}", p.name, title), "job": p.job})
                })
            })
            .collect();
        json!({"at_work": at_work, "items": items})
    }
}

/// Nothing at work, nothing waiting.
fn empty() -> Value {
    json!({"at_work": 0, "items": []})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(name: &str, status: &str, perms: Value) -> Value {
        json!({"id": "x", "name": name, "status": status, "job": "j1", "permissions": perms})
    }

    // pattern: D
    #[test]
    fn a_pending_permission_is_an_item_and_a_session_at_work() {
        let mut a = Attention::default();
        let got = a
            .note(
                "s-a",
                &snap(
                    "mock · proj",
                    "busy",
                    json!([{"id": 4, "title": "Run make"}]),
                ),
            )
            .expect("changed");
        assert_eq!(got["at_work"], 1);
        assert_eq!(
            got["items"],
            json!([{"kind": "permission", "session": "s-a", "id": 4,
                    "text": "mock · proj asks: Run make", "job": "j1"}])
        );
        assert_eq!(a.current(), Some(got));
    }

    // pattern: D
    #[test]
    fn an_unchanged_list_says_nothing_and_an_answer_empties_it() {
        let mut a = Attention::default();
        let busy = snap("a", "busy", json!([{"id": 1, "title": "x"}]));
        assert!(a.note("s-a", &busy).is_some());
        // a streamed chunk: the same permissions, the same count
        assert!(a.note("s-a", &busy).is_none());
        let idle = snap("a", "idle", json!([]));
        let got = a.note("s-a", &idle).expect("changed");
        assert_eq!(got["at_work"], 0);
        assert_eq!(got["items"], json!([]));
        assert_eq!(a.current(), None);
    }

    // pattern: D
    #[test]
    fn an_exited_session_waits_on_nothing() {
        let mut a = Attention::default();

        a.note("s-a", &snap("a", "busy", json!([{"id": 1, "title": "x"}])));
        let got = a
            .note("s-a", &snap("a", "exited", json!([])))
            .expect("changed");
        assert_eq!(got["at_work"], 0);
        assert_eq!(got["items"], json!([]));
    }

    // pattern: D
    #[test]
    fn a_permission_with_no_title_says_permission() {
        let mut a = Attention::default();
        let got = a
            .note("s-a", &snap("a", "idle", json!([{"id": 2}])))
            .expect("changed");
        assert_eq!(got["at_work"], 1);
        assert_eq!(got["items"][0]["text"], "a asks: permission");
    }
}
