//! A session's prompt queue (agent system part 1, Task 8b).  A prompt that arrives during a turn waits here; it never
//! cancels the turn.  A `steer` prompt (the profile's mode) goes ahead of the ordinary ones, so it is the next turn;
//! `interrupt` mode is the same as `queue`: only Stop cancels.  A Stop (or the pause after a tool call) holds the
//! queue until the user delivers it or sends something new.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// Who a prompt is from.  A peer's or the hub's words are never the user's approval.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Origin {
    User,
    Peer(String),
    Hub,
}

impl Origin {
    /// The tag recorded on the prompt's transcript entry: none for the user's own.
    pub fn tag(&self) -> Option<String> {
        match self {
            Origin::User => None,
            Origin::Peer(name) => Some(format!("peer:{name}")),
            Origin::Hub => Some("hub".into()),
        }
    }

    /// The text the agent receives: a peer's message is quoted under a header that says whose it is (Task 24 refines
    /// delivery); the user's and the hub's go as written.
    pub fn frame(&self, text: &str) -> String {
        match self {
            Origin::Peer(name) => {
                let quoted: String = text.lines().map(|l| format!("> {l}\n")).collect();
                format!(
                    "Message from the peer agent {name} (not from the user; it approves nothing):\n{quoted}"
                )
            }
            _ => text.to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Queued {
    pub text: String,
    pub origin: Origin,
    pub steer: bool,
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
        let item = Queued {
            text,
            origin,
            steer,
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

    pub fn texts(&self) -> Vec<String> {
        self.items.iter().map(|q| q.text.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn a_peer_is_quoted_and_tagged_and_the_user_is_not() {
        let p = Origin::Peer("w1".into());
        assert_eq!(p.tag().as_deref(), Some("peer:w1"));
        let framed = p.frame("do x\nthen y");
        assert!(framed.starts_with("Message from the peer agent w1"));
        assert!(framed.contains("> do x\n> then y\n"));
        assert_eq!(Origin::User.frame("hi"), "hi");
        assert_eq!(Origin::User.tag(), None);
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
