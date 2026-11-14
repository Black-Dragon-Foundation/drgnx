//! Row keys and the editor's buffer as the worker sees it (docs/develop/terminal.md, "The worker").
//!
//! The engine names each row with an id that stays the same while the row lives, however it scrolls (libghostty-vt's
//! render-state row identity: an id that disappears scrolled away or was rearranged, and is never reused). The worker
//! gives each row it sends a key from its own monotonic counter, so a key never changes while the row lives.
//!
//! The editor's buffer is the rows **above** the screen it holds (scrollback, oldest first) and the screen. When rows
//! scroll off the top of the primary screen they stay in the buffer and become the newest rows above it: a scroll is
//! only inserts of the new bottom rows. A row that disappears anywhere else (a scroll region, a clear) is removed. Rows
//! that scrolled past between two frames (a flood) are never sent by a frame; the backfill inserts them later, newest
//! first, each chunk after the row the editor holds above the gap.

use std::collections::{HashMap, HashSet, VecDeque};

/// The engine's id of a row.
pub type RowId = [u64; 2];
/// A row's key on the wire.
pub type Key = String;
/// A run of new rows and the key it goes after (none: the top of the buffer).
pub type Run = (Option<Key>, Vec<(RowId, Key)>);

/// What a frame changes in the editor's buffer, in the order the patch applies it.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// Keys of screen rows gone (not scrolled into the scrollback).
    pub remove: Vec<Key>,
    /// Screen rows kept whose content changed.
    pub replace: Vec<(RowId, Key)>,
    /// Runs of new screen rows, each after the key given (none: the top of the buffer).
    pub insert: Vec<Run>,
    /// The rows that scrolled off the top into the scrollback (the editor keeps them), top first.
    pub scrolled: Vec<(RowId, Key)>,
}

impl Plan {
    pub fn is_empty(&self) -> bool {
        self.remove.is_empty() && self.replace.is_empty() && self.insert.is_empty()
    }
}

#[derive(Debug)]
pub struct Tracker {
    next: u64,
    screen: Vec<(RowId, Key)>,
    above: VecDeque<(RowId, Key)>,
    held: HashSet<RowId>,
    /// The most rows kept above the screen (the buffer's window).
    above_max: usize,
    /// Keys of rows the window dropped (oldest first), for the next patch's `remove`.
    trimmed: Vec<Key>,
}

impl Tracker {
    pub fn new(above_max: usize) -> Self {
        Tracker {
            next: 0,
            screen: Vec::new(),
            above: VecDeque::new(),
            held: HashSet::new(),
            above_max,
            trimmed: Vec::new(),
        }
    }

    /// The keys the window dropped since the last call: the editor removes them.
    pub fn take_trimmed(&mut self) -> Vec<Key> {
        std::mem::take(&mut self.trimmed)
    }

    pub fn set_above_max(&mut self, n: usize) {
        self.above_max = n;
        self.trim();
    }

    fn key(&mut self) -> Key {
        self.next += 1;
        self.next.to_string()
    }

    /// The keys of the screen rows, top first.
    pub fn screen(&self) -> &[(RowId, Key)] {
        &self.screen
    }

    /// The rows above the screen the editor holds, oldest first.
    pub fn above(&self) -> impl Iterator<Item = &(RowId, Key)> {
        self.above.iter()
    }

    /// A reset: the editor's buffer becomes SCREEN alone, each row with a new key.
    pub fn reset(&mut self, screen: &[RowId]) -> Vec<(RowId, Key)> {
        self.above.clear();
        self.held.clear();
        self.trimmed.clear();
        self.screen = screen.iter().map(|id| (*id, self.key())).collect();
        self.screen.clone()
    }

    /// The plan that turns the editor's screen into SCREEN (`(id, dirty)` top first). PRIMARY: rows scrolling off the
    /// top stay in the buffer (the alternate screen has no scrollback). None when the kept rows changed order (the
    /// caller sends a reset).
    pub fn frame(&mut self, screen: &[(RowId, bool)], primary: bool) -> Option<Plan> {
        let now: HashMap<RowId, usize> = screen
            .iter()
            .enumerate()
            .map(|(i, (id, _))| (*id, i))
            .collect();
        let was: HashMap<RowId, Key> = self.screen.iter().map(|(id, k)| (*id, k.clone())).collect();
        let kept_old: Vec<RowId> = self
            .screen
            .iter()
            .map(|(id, _)| *id)
            .filter(|id| now.contains_key(id))
            .collect();
        let kept_new: Vec<RowId> = screen
            .iter()
            .map(|(id, _)| *id)
            .filter(|id| was.contains_key(id))
            .collect();
        if kept_old != kept_new {
            return None;
        }
        let mut plan = Plan::default();
        // the rows above the first kept one scrolled off the top (primary screen); every other gone row is removed
        let first_kept = self.screen.iter().position(|(id, _)| now.contains_key(id));
        let lead = if primary {
            first_kept.unwrap_or(if screen.is_empty() {
                0
            } else {
                self.screen.len()
            })
        } else {
            0
        };
        let old = std::mem::take(&mut self.screen);
        for (i, (id, key)) in old.iter().enumerate() {
            if now.contains_key(id) {
                continue;
            }
            if i < lead {
                self.above.push_back((*id, key.clone()));
                self.held.insert(*id);
                plan.scrolled.push((*id, key.clone()));
            } else {
                plan.remove.push(key.clone());
            }
        }
        self.trim();
        let mut keyed: Vec<(RowId, Key)> = Vec::with_capacity(screen.len());
        let mut i = 0;
        while i < screen.len() {
            let (id, dirty) = screen[i];
            if let Some(k) = was.get(&id) {
                if dirty {
                    plan.replace.push((id, k.clone()));
                }
                keyed.push((id, k.clone()));
                i += 1;
                continue;
            }
            let after = keyed
                .last()
                .map(|(_, k)| k.clone())
                .or_else(|| self.above.back().map(|(_, k)| k.clone()));
            let mut run = Vec::new();
            while i < screen.len() && !was.contains_key(&screen[i].0) {
                let row = (screen[i].0, self.key());
                run.push(row.clone());
                keyed.push(row);
                i += 1;
            }
            plan.insert.push((after, run));
        }
        self.screen = keyed;
        Some(plan)
    }

    /// The rows of KEYS above the screen leave the editor's buffer (their content went stale unseen); returns the keys
    /// it held.
    pub fn forget(&mut self, keys: &[Key]) -> Vec<Key> {
        let mut gone = Vec::new();
        self.above.retain(|(id, k)| {
            if keys.contains(k) {
                self.held.remove(id);
                gone.push(k.clone());
                false
            } else {
                true
            }
        });
        gone
    }

    /// Whether the editor holds the row ID (above the screen or on it).
    pub fn held(&self, id: &RowId) -> bool {
        self.held.contains(id) || self.screen.iter().any(|(s, _)| s == id)
    }

    /// The key a backfill chunk goes after when the rows it fills sit just above the held row BELOW (none: the screen's
    /// top): the row the editor holds before BELOW, or none for the top of the buffer.
    pub fn anchor_above(&self, below: Option<&RowId>) -> Option<Key> {
        match below {
            None => self.above.back().map(|(_, k)| k.clone()),
            Some(id) => {
                let i = self.above.iter().position(|(r, _)| r == id)?;
                i.checked_sub(1).map(|j| self.above[j].1.clone())
            }
        }
    }

    /// A backfill chunk went: ROWS (their engine ids, oldest first) now sit in the editor after ANCHOR (none: the top),
    /// each with a new key, returned in order.
    pub fn backfilled(&mut self, anchor: Option<&Key>, rows: &[RowId]) -> Vec<(RowId, Key)> {
        let keyed: Vec<(RowId, Key)> = rows.iter().map(|id| (*id, self.key())).collect();
        let at = match anchor {
            None => 0,
            Some(k) => self
                .above
                .iter()
                .position(|(_, a)| a == k)
                .map_or(self.above.len(), |i| i + 1),
        };
        for (n, row) in keyed.iter().enumerate() {
            self.above.insert(at + n, row.clone());
            self.held.insert(row.0);
        }
        self.trim();
        keyed
    }

    fn trim(&mut self) {
        while self.above.len() > self.above_max {
            if let Some((id, key)) = self.above.pop_front() {
                self.held.remove(&id);
                self.trimmed.push(key);
            }
        }
    }
}
