//! Who wrote each line of one document on one branch, kept from the edit history's operations (pure;
//! `docs/develop/hub.md`, "The buffer view").
//!
//! [`AgentRanges`] holds, for each line of the text, the runs of characters each author wrote (`user`,
//! `agent:<session>`, …; text no author wrote is the base's). [`AgentRanges::apply_op`] follows one operation the
//! history applied, in time with it; [`AgentRanges::rebuild`] makes the same state from the text and its blame, after
//! a restart or when an operation was missed, off the tick. A line is an author's when one of its characters is
//! (its line break counts only on an empty line), and a line with the user's characters is never an agent's: the
//! user's edits are never drawn in an agent's colour. A deletion leaves no character: it marks the line the text
//! joined (its author's, kept in `Line::del`), so a pure deletion shows too; a rebuild from blame cannot know them.

use super::project::LineRange;
use std::ops::Range;

/// The user's author key.
pub const USER: &str = "user";

/// One operation on the text: OLD_LEN characters at START (character offsets) replaced by INSERTED, by AUTHOR.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Op<'a> {
    pub author: &'a str,
    pub start: usize,
    pub old_len: usize,
    pub inserted: &'a str,
}

/// A run of LEN characters by author index WHO (0: the base).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Run {
    len: u32,
    who: u16,
}

/// One line: its runs, its line break (when it has one) the last character of the last run.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Line {
    runs: Vec<Run>,
    newline: bool,
    /// Authors (indexes) of a deletion that joined this line, a mark and no character.
    del: Vec<u16>,
}

impl Line {
    fn len(&self) -> usize {
        self.runs.iter().map(|r| r.len as usize).sum()
    }

    fn push(&mut self, r: Run) {
        if r.len == 0 {
            return;
        }
        match self.runs.last_mut() {
            Some(l) if l.who == r.who => l.len += r.len,
            _ => self.runs.push(r),
        }
    }

    /// Whether author WHO deleted text here, or wrote a character of this line.
    fn marks(&self, who: u16) -> bool {
        self.has(who) || self.del.contains(&who)
    }

    /// The runs of characters FROM..TO.
    fn cut(&self, from: usize, to: usize) -> Vec<Run> {
        let mut out = Vec::new();
        let mut at = 0usize;
        for r in &self.runs {
            let (s, e) = (at, at + r.len as usize);
            at = e;
            let (lo, hi) = (s.max(from), e.min(to));
            if lo < hi {
                out.push(Run {
                    len: (hi - lo) as u32,
                    who: r.who,
                });
            }
        }
        out
    }

    /// Whether author WHO wrote this line: one of its characters, its line break only when it holds nothing else.
    fn has(&self, who: u16) -> bool {
        let body = self.len() - usize::from(self.newline);
        if body == 0 {
            return self.newline && self.runs.last().is_some_and(|r| r.who == who);
        }
        self.cut(0, body).iter().any(|r| r.who == who)
    }
}

/// See the module.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentRanges {
    /// Author keys by index; index 0 is the base.
    authors: Vec<String>,
    lines: Vec<Line>,
}

/// TEXT's lines, each with WHO_OF's author for each character (by offset).
fn lines_of(text: &str, mut who_of: impl FnMut(usize) -> u16) -> Vec<Line> {
    let mut lines = vec![Line::default()];
    for (i, c) in text.chars().enumerate() {
        let l = lines.last_mut().expect("one line at least");
        l.push(Run {
            len: 1,
            who: who_of(i),
        });
        if c == '\n' {
            l.newline = true;
            lines.push(Line::default());
        }
    }
    lines
}

impl AgentRanges {
    /// TEXT as the base's: no author yet.
    pub fn new(text: &str) -> AgentRanges {
        AgentRanges {
            authors: vec![String::new()],
            lines: lines_of(text, |_| 0),
        }
    }

    /// TEXT with BLAME (character ranges and their author keys) as [`AgentRanges::apply_op`] would have made it.
    pub fn rebuild(text: &str, blame: &[(Range<usize>, String)]) -> AgentRanges {
        let mut r = AgentRanges::new("");
        let n = text.chars().count();
        let mut who = vec![0u16; n];
        for (range, author) in blame {
            let w = r.index(author);
            for slot in who.iter_mut().take(range.end.min(n)).skip(range.start) {
                *slot = w;
            }
        }
        r.lines = lines_of(text, |i| who[i]);
        r
    }

    fn index(&mut self, author: &str) -> u16 {
        if let Some(i) = self.authors.iter().position(|a| a == author) {
            return i as u16;
        }
        self.authors.push(author.to_owned());
        (self.authors.len() - 1) as u16
    }

    /// Character offset AT as (line, column); past the end: the end.
    fn locate(&self, at: usize) -> (usize, usize) {
        let mut left = at;
        for (i, l) in self.lines.iter().enumerate() {
            let n = l.len();
            if left < n || (left == n && !l.newline) {
                return (i, left);
            }
            left -= n;
        }
        let last = self.lines.len() - 1;
        (last, self.lines[last].len())
    }

    /// The text's length in characters.
    pub fn chars(&self) -> usize {
        self.lines.iter().map(Line::len).sum()
    }

    /// OP, as the history applied it.  An operation outside the text is refused (false) and changes nothing: the
    /// caller rebuilds.
    pub fn apply_op(&mut self, op: Op<'_>) -> bool {
        let total = self.chars();
        if op.start > total || op.old_len > total - op.start {
            return false;
        }
        let who = self.index(op.author);
        let (l0, c0) = self.locate(op.start);
        let (l1, c1) = self.locate(op.start + op.old_len);
        let prefix = self.lines[l0].cut(0, c0);
        let tail = &self.lines[l1];
        let suffix = tail.cut(c1, tail.len());
        let tail_newline = tail.newline;
        let mut del: Vec<u16> = Vec::new();
        for d in self.lines[l0].del.iter().chain(&self.lines[l1].del) {
            if !del.contains(d) {
                del.push(*d);
            }
        }
        if op.old_len > 0 && op.inserted.is_empty() && who != 0 && !del.contains(&who) {
            del.push(who);
        }
        let mut new: Vec<Line> = Vec::new();
        let mut cur = Line::default();
        for r in prefix {
            cur.push(r);
        }
        let mut piece = 0u32;
        for c in op.inserted.chars() {
            piece += 1;
            if c == '\n' {
                cur.push(Run { len: piece, who });
                piece = 0;
                cur.newline = true;
                new.push(std::mem::take(&mut cur));
            }
        }
        cur.push(Run { len: piece, who });
        for r in suffix {
            cur.push(r);
        }
        cur.newline = tail_newline;
        new.push(cur);
        if let Some(first) = new.first_mut() {
            first.del = del;
        }
        self.lines.splice(l0..=l1, new);
        true
    }

    /// These ranges without the deletion marks: what a rebuild from the blame gives.
    #[cfg(test)]
    fn without_marks(&self) -> AgentRanges {
        let mut r = self.clone();
        r.lines.iter_mut().for_each(|l| l.del.clear());
        r
    }

    /// The lines AUTHOR wrote (1-based, merged); an agent's leave out every line with the user's characters.
    pub fn ranges(&self, author: &str) -> Vec<LineRange> {
        let Some(w) = self.authors.iter().position(|a| a == author) else {
            return Vec::new();
        };
        let user = self.authors.iter().position(|a| a == USER);
        let mut out: Vec<LineRange> = Vec::new();
        for (i, l) in self.lines.iter().enumerate() {
            if w == 0 || !l.marks(w as u16) {
                continue;
            }
            if author != USER && user.is_some_and(|u| l.has(u as u16)) {
                continue;
            }
            let n = u32::try_from(i + 1).unwrap_or(u32::MAX);
            match out.last_mut() {
                Some(r) if r.end + 1 == n => r.end = n,
                _ => out.push(LineRange { start: n, end: n }),
            }
        }
        out
    }

    /// The authors with a line now, sorted (the base left out).
    pub fn authors(&self) -> Vec<String> {
        let mut v: Vec<String> = self
            .authors
            .iter()
            .enumerate()
            .skip(1)
            .filter(|(i, _)| self.lines.iter().any(|l| l.marks(*i as u16)))
            .map(|(_, a)| a.clone())
            .collect();
        v.sort();
        v
    }
}

/// Author keys and the lines each wrote, sorted by key.
pub type LinesBy = Vec<(String, Vec<LineRange>)>;

/// The agents' lines in BY (author keys and their lines, as [`AgentRanges::ranges`] gives them): (session, lines) for
/// each `agent:<session>` author, in order.  On the user's checkout these are a paired agent's writes, drawn in its
/// identity; they are the user's side of every other agent's projection.
pub fn agent_lines(by: &[(String, Vec<LineRange>)]) -> Vec<(String, LineRange)> {
    by.iter()
        .filter_map(|(a, rs)| a.strip_prefix("agent:").map(|s| (s, rs)))
        .flat_map(|(s, rs)| rs.iter().map(move |r| (s.to_owned(), *r)))
        .collect()
}

#[cfg(test)]
mod tests;
