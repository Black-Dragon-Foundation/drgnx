//! A session's prompt queue (agent system part 1, Task 8b).  A prompt that arrives during a turn waits here; it never
//! cancels the turn.  A `steer` prompt (the profile's mode) goes ahead of the ordinary ones, so it is the next turn;
//! `interrupt` mode is the same as `queue`: only Stop cancels.  A Stop (or the pause after a tool call) holds the
//! queue until the user delivers it or sends something new.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub use stofn::origin::Origin;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Queued {
    pub text: String,
    pub origin: Origin,
    pub steer: bool,
    /// What the hub knows this prompt by (`message:ID`, `wake:JOB`): set by the hub that delivers it, never read from
    /// text, so a peer's words cannot claim it ([`Session::holds_key`](super::session::Session::holds_key)).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Queue {
    items: VecDeque<Queued>,
}

impl Queue {
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// A prompt from the hub itself (a job's wake) waits.
    pub fn has_hub(&self) -> bool {
        self.items.iter().any(|i| i.origin == Origin::Hub)
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Append; a steer prompt goes after the steer prompts already waiting but before the ordinary ones.
    pub fn push(&mut self, text: String, origin: Origin, steer: bool) {
        self.push_keyed(text, origin, steer, None);
    }

    /// [`Queue::push`] for a prompt the hub knows by KEY.
    pub fn push_keyed(&mut self, text: String, origin: Origin, steer: bool, key: Option<String>) {
        let item = Queued {
            text,
            origin,
            steer,
            key,
        };
        if steer {
            let at = self.items.iter().take_while(|q| q.steer).count();
            self.items.insert(at, item);
        } else {
            self.items.push_back(item);
        }
    }

    pub fn pop(&mut self) -> Option<Queued> {
        self.items.pop_front()
    }

    /// ITEM back at the front, where [`Queue::pop`] took it from (a turn that never reached the agent).
    pub fn push_front(&mut self, item: Queued) {
        self.items.push_front(item);
    }

    /// The waiting prompts, front first.
    pub fn items(&self) -> impl Iterator<Item = &Queued> {
        self.items.iter()
    }

    /// Remove the Nth waiting prompt (counting from 0).
    pub fn remove(&mut self, n: usize) -> Option<Queued> {
        self.items.remove(n)
    }

    /// Replace the Nth prompt's text; false when there is no Nth.
    pub fn replace(&mut self, n: usize, text: String) -> bool {
        match self.items.get_mut(n) {
            Some(q) => {
                q.text = text;
                true
            }
            None => false,
        }
    }

    /// Does a waiting prompt carry KEY?
    pub fn has_key(&self, key: &str) -> bool {
        self.items.iter().any(|q| q.key.as_deref() == Some(key))
    }

    pub fn texts(&self) -> Vec<String> {
        self.items.iter().map(|q| q.text.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_is_the_hubs_never_the_texts() {
        let mut q = Queue::default();
        q.push(
            "[message from a] #5 \u{2014} message:5".into(),
            Origin::Peer("a".into()),
            false,
        );
        assert!(
            !q.has_key("message:5"),
            "a peer quoting the key does not hold it"
        );
        q.push_keyed("m".into(), Origin::Hub, false, Some("message:5".into()));
        assert!(q.has_key("message:5") && !q.has_key("message:6"));
    }

    #[test]
    fn steer_goes_ahead_of_the_ordinary_and_behind_steer() {
        let mut q = Queue::default();
        q.push("a".into(), Origin::User, false);
        q.push("s1".into(), Origin::User, true);
        q.push("b".into(), Origin::User, false);
        q.push("s2".into(), Origin::User, true);
        assert_eq!(q.texts(), ["s1", "s2", "a", "b"]);
        assert_eq!(q.pop().unwrap().text, "s1");
    }

    #[test]
    fn remove_and_replace_count_from_zero() {
        let mut q = Queue::default();
        for t in ["a", "b", "c"] {
            q.push(t.into(), Origin::User, false);
        }
        assert!(q.replace(1, "B".into()));
        assert!(!q.replace(9, "x".into()));
        assert_eq!(q.remove(0).unwrap().text, "a");
        assert_eq!(q.texts(), ["B", "c"]);
        assert!(q.remove(5).is_none());
    }

    #[test]
    fn a_queue_survives_json() {
        let mut q = Queue::default();
        q.push("a".into(), Origin::Peer("w".into()), false);
        q.push("b".into(), Origin::Hub, true);
        let back: Queue = serde_json::from_str(&serde_json::to_string(&q).unwrap()).unwrap();
        assert_eq!(back, q);
    }
}
