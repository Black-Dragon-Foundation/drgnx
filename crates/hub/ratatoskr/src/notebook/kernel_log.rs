//! A notebook's kernel log: what the kernel sent that answered no cell (`notebook/log`).

use std::collections::VecDeque;

use super::output::LOG_ENTRIES;

/// One message the kernel sent that answered no cell: SEQ counts from 1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEntry {
    pub seq: u64,
    pub msg_type: String,
    pub text: String,
}

/// A notebook's kernel log: the last [`LOG_ENTRIES`] entries (each already cut by the router), kept across a kernel's restarts.
#[derive(Debug, Default)]
pub struct KernelLog {
    last: u64,
    entries: VecDeque<LogEntry>,
}

impl KernelLog {
    /// File an entry; its number.
    pub fn push(&mut self, msg_type: &str, text: &str) -> u64 {
        self.last += 1;
        if self.entries.len() >= LOG_ENTRIES {
            self.entries.pop_front();
        }
        self.entries.push_back(LogEntry {
            seq: self.last,
            msg_type: msg_type.to_owned(),
            text: text.to_owned(),
        });
        self.last
    }

    /// The number of the newest entry (0: none yet).
    pub fn last_seq(&self) -> u64 {
        self.last
    }

    /// The entries numbered above AFTER, and how many of those are no longer held.
    pub fn since(&self, after: u64) -> (Vec<LogEntry>, u64) {
        let oldest = self.entries.front().map_or(self.last + 1, |e| e.seq);
        let lost = oldest.saturating_sub(after.saturating_add(1));
        (
            self.entries
                .iter()
                .filter(|e| e.seq > after)
                .cloned()
                .collect(),
            lost,
        )
    }
}
