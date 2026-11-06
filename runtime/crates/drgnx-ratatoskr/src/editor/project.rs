//! Another worktree's agent on the user's checkout, mapped three-way (pure; `docs/develop/hub.md`, "The buffer
//! view"; agents-in-the-editor design §4.3).
//!
//! For one file: **base** is its text at the worktree's base, **agent** the agent's text now, **user** the user's.
//! base → agent gives what the agent changed (in base lines); base → user gives the line map onto the user's text and
//! what the user changed (their typing, and every commit their branch gained after the base). An agent change lands
//! on the user's lines only through lines both sides kept: one that meets a user change is a `conflict` there, and a
//! user change is never the agent's. Texts are compared with CRLF as LF.
//!
//! [`UserMap`] is the base → user half, shared by every agent projected onto one buffer from one base.

use similar::{Algorithm, DiffOp, DiffTag, TextDiff};
use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;

/// Lines START to END of the user's text, 1-based, inclusive.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LineRange {
    pub start: u32,
    pub end: u32,
}

/// A line of the agent's text (1-based): where its cursor is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pos {
    pub line: u32,
}

/// One agent's work on the user's text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Projection {
    /// Lines the agent changed, on the user's text, where the user changed nothing.
    pub agent_ranges: Vec<LineRange>,
    /// Lines the user changed since the base (theirs, never the agent's).
    pub user_ranges: Vec<LineRange>,
    /// Lines both changed.
    pub conflicts: Vec<LineRange>,
    /// The agent's cursor line on the user's text.
    pub cursor_on_user: Option<u32>,
}

fn lf(s: &str) -> std::borrow::Cow<'_, str> {
    if s.contains('\r') {
        std::borrow::Cow::Owned(s.replace("\r\n", "\n"))
    } else {
        std::borrow::Cow::Borrowed(s)
    }
}

fn ops(a: &str, b: &str) -> Vec<DiffOp> {
    TextDiff::configure()
        .algorithm(Algorithm::Myers)
        .diff_lines(a, b)
        .ops()
        .to_vec()
}

fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// The base → user half of a projection.
#[derive(Clone, Debug)]
pub struct UserMap {
    /// Each base line's user line (0-based), where the user kept it.
    kept: Vec<Option<usize>>,
    /// The user's changes: (base lines, user lines), 0-based half-open.
    changes: Vec<(std::ops::Range<usize>, std::ops::Range<usize>)>,
    user_lines: usize,
}

impl UserMap {
    pub fn new(base: &str, user: &str) -> UserMap {
        let (base, user) = (lf(base), lf(user));
        let base_lines = base.split_inclusive('\n').count();
        let user_lines = user.split_inclusive('\n').count();
        let mut kept = vec![None; base_lines];
        let mut changes = Vec::new();
        for op in ops(&base, &user) {
            let (o, n) = (op.old_range(), op.new_range());
            if op.tag() == DiffTag::Equal {
                for (i, b) in o.clone().enumerate() {
                    kept[b] = Some(n.start + i);
                }
            } else {
                changes.push((o, n));
            }
        }
        UserMap {
            kept,
            changes,
            user_lines,
        }
    }

    /// The user's changed lines, on their text (a deletion marks the line after it).
    pub fn user_ranges(&self) -> Vec<LineRange> {
        self.changes
            .iter()
            .map(|(_, n)| self.user_span(n))
            .collect()
    }

    /// User lines N (0-based, half-open) as a range; an empty one is the line at its place.
    fn user_span(&self, n: &std::ops::Range<usize>) -> LineRange {
        let last = self.user_lines.max(1);
        let start = n.start.min(last - 1);
        let end = if n.is_empty() { start } else { n.end - 1 };
        LineRange {
            start: to_u32(start + 1),
            end: to_u32(end + 1),
        }
    }

    /// The user's change that base lines B (half-open; empty: the place between two lines) meet, if any.
    fn meets(&self, b: &std::ops::Range<usize>) -> Option<&std::ops::Range<usize>> {
        self.changes.iter().find_map(|(o, n)| {
            let hit = match (b.is_empty(), o.is_empty()) {
                (false, false) => b.start < o.end && o.start < b.end,
                // an insertion by one side inside the other's changed lines
                (true, false) => o.start < b.start && b.start < o.end,
                (false, true) => b.start < o.start && o.start < b.end,
                (true, true) => b.start == o.start,
            };
            hit.then_some(n)
        })
    }

    /// Base line B (0-based) on the user's text: its kept place, else the place of the user change it is in.
    fn base_line(&self, b: usize) -> Option<usize> {
        if let Some(Some(u)) = self.kept.get(b) {
            return Some(*u);
        }
        self.changes
            .iter()
            .find(|(o, _)| o.contains(&b) || (o.is_empty() && o.start == b))
            .map(|(_, n)| n.start.min(self.user_lines.saturating_sub(1)))
            .or_else(|| (b >= self.kept.len()).then(|| self.user_lines.saturating_sub(1)))
    }

    /// AGENT (its text now) against BASE through this map, its cursor at AGENT_CURSOR.
    pub fn project(&self, base: &str, agent: &str, agent_cursor: Option<Pos>) -> Projection {
        let (base, agent) = (lf(base), lf(agent));
        let mut out = Projection {
            user_ranges: self.user_ranges(),
            ..Projection::default()
        };
        let agent_ops = ops(&base, &agent);
        for op in agent_ops.iter().filter(|op| op.tag() != DiffTag::Equal) {
            let o = op.old_range();
            if let Some(n) = self.meets(&o) {
                out.conflicts.push(self.user_span(n));
                continue;
            }
            // the agent's base lines, kept by the user, are where its change shows; an insertion shows on the line
            // before it (the first line at the top)
            let lines: Vec<usize> = if o.is_empty() {
                vec![o.start.saturating_sub(1)]
            } else {
                o.collect()
            };
            let mapped: Vec<usize> = lines.iter().filter_map(|b| self.base_line(*b)).collect();
            if let (Some(lo), Some(hi)) = (mapped.iter().min(), mapped.iter().max()) {
                out.agent_ranges.push(LineRange {
                    start: to_u32(lo + 1),
                    end: to_u32(hi + 1),
                });
            }
        }
        out.agent_ranges = merge(out.agent_ranges);
        out.conflicts = merge(out.conflicts);
        out.cursor_on_user = agent_cursor.and_then(|c| {
            let a = (c.line.max(1) - 1) as usize;
            // the agent's line in base lines: kept, else the start of the change it is in
            let b = agent_ops.iter().find_map(|op| {
                let n = op.new_range();
                let o = op.old_range();
                if n.contains(&a) {
                    Some(if op.tag() == DiffTag::Equal {
                        o.start + (a - n.start)
                    } else {
                        o.start
                    })
                } else {
                    None
                }
            });
            let b = b.unwrap_or_else(|| base.split_inclusive('\n').count());
            self.base_line(b).map(|u| to_u32(u + 1))
        });
        out
    }
}

/// Overlapping or touching ranges as one, sorted.
fn merge(mut v: Vec<LineRange>) -> Vec<LineRange> {
    v.sort();
    let mut out: Vec<LineRange> = Vec::new();
    for r in v {
        match out.last_mut() {
            Some(l) if r.start <= l.end.saturating_add(1) => l.end = l.end.max(r.end),
            _ => out.push(r),
        }
    }
    out
}

/// Where the user's text of a buffer came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UserSource {
    /// The file on disk: the user's unsaved changes are not in it (every buffer before the edit history's mirror, and
    /// remote and history-off buffers after it).
    Disk,
    /// The edit history's mirror of the buffer.
    Mirror,
}

impl UserSource {
    /// Whether a frame projected from it is marked `approximate`.
    pub fn approximate(self) -> bool {
        self == UserSource::Disk
    }
}

/// See the module: one agent's text projected onto the user's.
pub fn project(base: &str, agent: &str, user: &str, agent_cursor: Option<Pos>) -> Projection {
    UserMap::new(base, user).project(base, agent, agent_cursor)
}

/// The most base texts [`BaseCache`] keeps.
pub const BASE_CACHE: usize = 256;

/// Base texts by (commit, path), read once each: the least recently used goes past [`BASE_CACHE`].
#[derive(Debug, Default)]
pub struct BaseCache {
    texts: BTreeMap<(String, String), Arc<str>>,
    order: VecDeque<(String, String)>,
}

impl BaseCache {
    /// The text of PATH at COMMIT: the one kept, else READ's (kept; none when it has none: the file is not there).
    pub fn get_or(
        &mut self,
        commit: &str,
        path: &str,
        read: impl FnOnce() -> Option<String>,
    ) -> Option<Arc<str>> {
        let key = (commit.to_string(), path.to_string());
        if let Some(t) = self.texts.get(&key).cloned() {
            self.order.retain(|k| *k != key);
            self.order.push_back(key);
            return Some(t);
        }
        let t: Arc<str> = read()?.into();
        self.texts.insert(key.clone(), t.clone());
        self.order.push_back(key);
        while self.order.len() > BASE_CACHE {
            if let Some(old) = self.order.pop_front() {
                self.texts.remove(&old);
            }
        }
        Some(t)
    }

    pub fn len(&self) -> usize {
        self.texts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.texts.is_empty()
    }
}

#[cfg(test)]
mod tests;
