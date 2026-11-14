//! When an editor session's terminals end (pure; the caller passes the time in milliseconds). A session is gone when
//! the connection carrying it closed and no hello with its id came within [`GRACE_MS`]: the grace covers a reconnect
//! (the editor's socket dropped, the hub restarted), never a reattach after the editor itself ended. A clean exit
//! closes its terminals at once, without the grace.

use std::collections::HashMap;

pub const GRACE_MS: u64 = 60_000;

#[derive(Debug, Default)]
pub struct Life {
    /// Session → when its last connection closed.
    closed: HashMap<String, u64>,
}

impl Life {
    /// SESSION's connection closed at NOW.
    pub fn closed(&mut self, session: &str, now: u64) {
        self.closed.entry(session.to_owned()).or_insert(now);
    }

    /// SESSION said hello again: it lives.
    pub fn hello(&mut self, session: &str) {
        self.closed.remove(session);
    }

    /// The sessions gone at NOW (each once).
    pub fn due(&mut self, now: u64) -> Vec<String> {
        let mut gone: Vec<String> = self
            .closed
            .iter()
            .filter(|(_, t)| now.saturating_sub(**t) >= GRACE_MS)
            .map(|(s, _)| s.clone())
            .collect();
        gone.sort();
        for s in &gone {
            self.closed.remove(s);
        }
        gone
    }

    /// When the next session is due, if one waits.
    pub fn next_due(&self) -> Option<u64> {
        self.closed.values().map(|t| t + GRACE_MS).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_ends_after_the_grace_unless_it_comes_back() {
        let mut l = Life::default();
        l.closed("a", 1_000);
        l.closed("b", 2_000);
        assert!(l.due(60_999).is_empty());
        assert_eq!(l.next_due(), Some(61_000));
        l.hello("b");
        assert_eq!(l.due(61_000), ["a"]);
        assert!(l.due(200_000).is_empty(), "each once; b came back");
    }
}
