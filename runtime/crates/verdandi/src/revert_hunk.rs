//! The selective revert of one record, per hunk, and who undid each hunk (docs/develop/history.md, "One hunk of a
//! record").
//!
//! **A record's hunks** are found on element ids at the record's own version: each element it inserted has the line
//! it sits on, each deletion the line of the point it left (after its nearest surviving left neighbour).  Effects
//! sorted by line, an unchanged line between two of them starts a new hunk, so a hunk is what `git diff -U0` would
//! show for that record alone.  **Reverting a hunk** is keep mine (`revert.rs`) on the hunk's part of the record's
//! scope: its elements still there are deleted, the text it deleted goes back after its surviving neighbour, and the
//! user's characters typed inside the agent's text are other elements, so they stay.  The deletes and inserts are
//! made on a fork and handed back as changes, which the caller applies to the live document or an editor applies in
//! its buffer: the same operations either way.  **A conflict** is a hunk that puts old text back where it has no
//! place: a neighbour it went between is gone, or someone else's text now sits beside it outside the agent's own text.
//!
//! **Who undid a hunk:** Loro names no deleter of an element, but each delete operation's position at its own version
//! names the elements it removed.  So the delete operations ordered after the record are read at their versions, and
//! the ones that removed the hunk's elements name their records; text the record deleted that is back at its place
//! names the record that inserted it again (an editor's undo re-inserts it as new elements).  Nothing is stored for
//! this: it holds for every history written before it.

use crate::apply::SEED_BIT;
use crate::docs::{Change, TEXT, version_of};
use crate::revert::{Deletion, Scope, char_ids, keep_mine, scope_of};
use crate::store::{History, Kind, Record};
use crate::{BranchId, DocId, Error, OpId, PeerId, Result, Span};
use ::loro::{ID, LoroDoc};
use std::collections::{BTreeSet, HashMap, HashSet};

/// How much of a hunk is still there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HunkState {
    /// Nothing of it was undone.
    Live,
    PartlyUndone,
    /// Its text is all gone and what it deleted is back.
    Undone,
}

/// One hunk of a record, as the text is now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpHunk {
    pub op: OpId,
    pub doc: DocId,
    pub path: String,
    /// Its order among the record's hunks in this document.
    pub index: usize,
    /// Its lines in the text now (1-based, inclusive); where its text was, when it is gone.
    pub start_line: usize,
    pub end_line: usize,
    /// The record's text of this hunk still there now.
    pub text: String,
    /// The text the record deleted here.
    pub deleted: String,
    pub state: HunkState,
    /// The records that deleted its text or put back what it deleted, oldest first.
    pub undone_by: Vec<OpId>,
}

/// A hunk whose old text has no place to go back to: its lines now, the other text there and the old text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HunkConflict {
    pub start_line: usize,
    pub end_line: usize,
    pub users: String,
    pub reverted: String,
}

/// What reverting a hunk would do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HunkPlan {
    /// The changes, in order, to the text now.
    Edits(Vec<Change>),
    Conflict(HunkConflict),
    /// Undone already, by these records.
    Undone(Vec<OpId>),
}

/// A deletion of the record, read once: the elements it removed (not the record's own inserts), their text, and the
/// point it left at the record's version.
struct Del {
    ids: Vec<ID>,
    text: String,
    point: usize,
}

/// One hunk: its inserted elements alive at the record's version, and its deletions (indexes into the scope's).
struct Part {
    inserted: HashSet<ID>,
    dels: Vec<usize>,
}

/// A document read for its hunks: the record's scope, its version's elements, its deletions, and the text now.
struct Read {
    sc: Scope,
    ids1: Vec<ID>,
    dels: Vec<Del>,
    parts: Vec<Part>,
    now: Vec<ID>,
    chars: Vec<char>,
    pos: HashMap<ID, usize>,
}

/// The 0-based line of each position of CHARS (one more than there are characters, for the end).
fn lines(chars: &[char]) -> Vec<usize> {
    let mut out = Vec::with_capacity(chars.len() + 1);
    let mut l = 0;
    for c in chars {
        out.push(l);
        if *c == '\n' {
            l += 1;
        }
    }
    out.push(l);
    out
}

fn read(d: &LoroDoc, spans: &[Span]) -> Result<Read> {
    let sc = scope_of(d, spans);
    let then = version_of(d, &sc.after)?;
    let t1 = then.get_text(TEXT);
    let ids1 = char_ids(&t1);
    let line1 = lines(&t1.to_string().chars().collect::<Vec<_>>());
    let pos1: HashMap<ID, usize> = ids1.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let mut dels = Vec::new();
    for del in &sc.deletions {
        let pre = version_of(d, &del.before)?.get_text(TEXT);
        let ids0 = char_ids(&pre);
        let ch0: Vec<char> = pre.to_string().chars().collect();
        let end = del.end.min(ids0.len());
        let start = del.start.min(end);
        let point = (0..start)
            .rev()
            .find_map(|k| pos1.get(&ids0[k]).map(|p| p + 1))
            .unwrap_or(0);
        let keep: Vec<usize> = (start..end)
            .filter(|i| !sc.inserted.contains(&ids0[*i]))
            .collect();
        dels.push(Del {
            ids: keep.iter().map(|i| ids0[*i]).collect(),
            text: keep.iter().map(|i| ch0[*i]).collect(),
            point,
        });
    }
    // the effects by line, grouped where no unchanged line lies between them
    let mut eff: Vec<(usize, Option<ID>, Option<usize>)> = Vec::new();
    for (i, id) in ids1.iter().enumerate() {
        if sc.inserted.contains(id) {
            eff.push((line1[i], Some(*id), None));
        }
    }
    for (k, d) in dels.iter().enumerate() {
        if !d.ids.is_empty() {
            eff.push((line1[d.point], None, Some(k)));
        }
    }
    eff.sort_by_key(|e| e.0);
    let mut parts: Vec<(usize, Part)> = Vec::new();
    for (line, ins, del) in eff {
        if !matches!(parts.last(), Some((last, _)) if line <= *last + 1) {
            parts.push((
                line,
                Part {
                    inserted: HashSet::new(),
                    dels: Vec::new(),
                },
            ));
        }
        let (last, p) = parts.last_mut().expect("pushed");
        *last = (*last).max(line);
        p.inserted.extend(ins);
        p.dels.extend(del);
    }
    let t = d.get_text(TEXT);
    let now = char_ids(&t);
    let pos = now.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    Ok(Read {
        sc,
        ids1,
        dels,
        parts: parts.into_iter().map(|(_, p)| p).collect(),
        now,
        chars: t.to_string().chars().collect(),
        pos,
    })
}

impl Read {
    /// Where the point at the record's version P is now: after the nearest element left of it that is still there.
    fn point_now(&self, p: usize) -> usize {
        (0..p)
            .rev()
            .find_map(|k| self.pos.get(&self.ids1[k]).map(|q| q + 1))
            .unwrap_or(0)
    }

    /// The deletions of PART whose text is back at their place now.
    fn restored(&self, part: &Part) -> Vec<usize> {
        part.dels
            .iter()
            .copied()
            .filter(|k| {
                let d = &self.dels[*k];
                let at = self.point_now(d.point);
                let want: Vec<char> = d.text.chars().collect();
                self.chars.get(at..at + want.len()) == Some(&want[..])
            })
            .collect()
    }

    /// The 1-based lines of PART now: its elements still there and the places of its deletions.
    fn lines_now(&self, part: &Part) -> (usize, usize) {
        let mut at: Vec<usize> = part
            .inserted
            .iter()
            .filter_map(|id| self.pos.get(id).copied())
            .collect();
        at.extend(
            part.dels
                .iter()
                .map(|k| self.point_now(self.dels[*k].point)),
        );
        let line = lines(&self.chars);
        let lo = at.iter().min().copied().unwrap_or(0);
        let hi = at.iter().max().copied().unwrap_or(0);
        (line[lo] + 1, line[hi] + 1)
    }

    /// The scope reverting PART takes: its live inserts, its deletions, and the record's other inserts that its own
    /// later deletes removed (gone then and now, so only skipped when old text goes back).
    fn sub_scope(&self, part: &Part) -> Scope {
        let alive_then: HashSet<ID> = self.ids1.iter().copied().collect();
        let mut inserted = part.inserted.clone();
        inserted.extend(
            self.sc
                .inserted
                .iter()
                .filter(|id| !alive_then.contains(id))
                .copied(),
        );
        Scope {
            inserted,
            deletions: part
                .dels
                .iter()
                .map(|k| self.sc.deletions[*k].clone())
                .collect::<Vec<Deletion>>(),
            after: self.sc.after.clone(),
            before: self.sc.before.clone(),
            first: self.sc.first,
        }
    }

    /// PART's conflict, if its old text has no place to go back to.
    fn conflict(&self, part: &Part) -> Option<HunkConflict> {
        let line = lines(&self.chars);
        for k in &part.dels {
            let d = &self.dels[*k];
            let mine = |id: &ID| part.inserted.contains(id);
            let left = self.ids1[..d.point].iter().rev().find(|id| !mine(id));
            let right = self.ids1[d.point..].iter().find(|id| !mine(id));
            let gone = |n: Option<&ID>| n.is_some_and(|id| !self.pos.contains_key(id));
            let lo = self.point_now(d.point);
            let hi = match right.and_then(|id| self.pos.get(id)) {
                Some(p) => (*p).max(lo),
                None if right.is_some() => lo,
                None => self.now.len(),
            };
            // the agent's own text there now, and the other text outside it
            let own: Vec<usize> = (lo..hi).filter(|i| mine(&self.now[*i])).collect();
            let users: String = (lo..hi)
                .filter(|i| !mine(&self.now[*i]))
                .map(|i| self.chars[i])
                .collect();
            let outside = (lo..hi).any(|i| {
                !mine(&self.now[i])
                    && !(own.first().is_some_and(|f| *f < i) && own.last().is_some_and(|l| *l > i))
            });
            if gone(left) || gone(right) || outside {
                return Some(HunkConflict {
                    start_line: line[lo] + 1,
                    end_line: line[hi.saturating_sub(1).max(lo)] + 1,
                    users,
                    reverted: d.text.clone(),
                });
            }
        }
        None
    }
}

impl History {
    /// The `edits` records of SESSION's agent on BRANCH (a paired chat's, on the user's branch), oldest first.
    pub fn records_of(&self, branch: BranchId, session: &str) -> Result<Vec<OpId>> {
        let mut st = self
            .conn
            .prepare("select id, author_json from peer where branch = ?1")?;
        let peers: Vec<i64> = st
            .query_map([branch.0], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|(_, j)| {
                serde_json::from_str::<serde_json::Value>(j)
                    .is_ok_and(|a| a["kind"] == "agent" && a["session"].as_str() == Some(session))
            })
            .map(|(id, _)| id)
            .collect();
        let mut out = Vec::new();
        let mut st = self
            .conn
            .prepare("select id from op where author = ?1 and kind = 'edits' order by id")?;
        for p in peers {
            for id in st.query_map([p], |r| r.get::<_, i64>(0))? {
                out.push(OpId(id?));
            }
        }
        out.sort();
        Ok(out)
    }

    /// OP's spans by document.
    fn spans_by_doc(&self, op: OpId) -> Result<Vec<(DocId, Vec<Span>)>> {
        let mut by: Vec<(DocId, Vec<Span>)> = Vec::new();
        for (d, s) in self.op(op)?.spans {
            match by.iter_mut().find(|(x, _)| *x == d) {
                Some((_, v)) => v.push(s),
                None => by.push((d, vec![s])),
            }
        }
        Ok(by)
    }

    /// The records other than OP that undid (part of) PART in D: the delete operations ordered after OP's first that
    /// removed its elements, and the records that put back the text it deleted.
    fn undone_by(
        &self,
        doc: DocId,
        d: &LoroDoc,
        r: &Read,
        part: &Part,
        op: OpId,
    ) -> Result<Vec<OpId>> {
        let index = self.op_index()?;
        let mut by = BTreeSet::new();
        let gone: HashSet<ID> = part
            .inserted
            .iter()
            .filter(|id| !r.pos.contains_key(id))
            .copied()
            .collect();
        if !gone.is_empty() {
            let spans: Vec<Span> = d
                .oplog_vv()
                .iter()
                .filter(|(p, c)| **p & SEED_BIT == 0 && **c > 0)
                .map(|(p, c)| Span {
                    peer: PeerId(*p),
                    start: 0,
                    end: *c as u32,
                })
                .collect();
            for del in scope_of(d, &spans).deletions {
                if r.sc.first.is_some_and(|f| del.order <= f) {
                    continue;
                }
                let ids0 = char_ids(&version_of(d, &del.before)?.get_text(TEXT));
                let end = del.end.min(ids0.len());
                if ids0[del.start.min(end)..end]
                    .iter()
                    .any(|id| gone.contains(id))
                    && let Some(o) = index.find(doc, del.id)
                {
                    by.insert(o);
                }
            }
        }
        for k in r.restored(part) {
            let at = r.point_now(r.dels[k].point);
            let n = r.dels[k].text.chars().count();
            for id in &r.now[at..at + n] {
                if let Some(o) = index.find(doc, *id) {
                    by.insert(o);
                }
            }
        }
        by.remove(&op);
        Ok(by.into_iter().collect())
    }

    /// The hunks of record OP on BRANCH, per document in the record's order.
    pub fn op_hunks(&mut self, branch: BranchId, op: OpId) -> Result<Vec<OpHunk>> {
        let mut out = Vec::new();
        for (doc, spans) in self.spans_by_doc(op)? {
            let path = self.path_of(doc)?;
            let d = self.live(doc, branch)?.clone();
            let r = read(&d, &spans)?;
            for (index, part) in r.parts.iter().enumerate() {
                let mut alive: Vec<usize> = part
                    .inserted
                    .iter()
                    .filter_map(|id| r.pos.get(id).copied())
                    .collect();
                alive.sort_unstable();
                let restored = r.restored(part).len();
                let gone = part.inserted.len() - alive.len();
                let state = if gone == part.inserted.len() && restored == part.dels.len() {
                    HunkState::Undone
                } else if gone == 0 && restored == 0 {
                    HunkState::Live
                } else {
                    HunkState::PartlyUndone
                };
                let (start_line, end_line) = r.lines_now(part);
                out.push(OpHunk {
                    op,
                    doc,
                    path: path.clone(),
                    index,
                    start_line,
                    end_line,
                    text: alive.iter().map(|i| r.chars[*i]).collect(),
                    deleted: part.dels.iter().map(|k| r.dels[*k].text.as_str()).collect(),
                    state,
                    undone_by: if state == HunkState::Live {
                        Vec::new()
                    } else {
                        self.undone_by(doc, &d, &r, part, op)?
                    },
                });
            }
        }
        Ok(out)
    }

    /// What reverting hunk INDEX of record OP in DOC on BRANCH would do (keep mine: the user's later typing stays).
    /// Changes nothing.
    pub fn plan_hunk_revert(
        &mut self,
        branch: BranchId,
        op: OpId,
        doc: DocId,
        index: usize,
    ) -> Result<HunkPlan> {
        let spans = self
            .spans_by_doc(op)?
            .into_iter()
            .find(|(d, _)| *d == doc)
            .map(|(_, s)| s)
            .ok_or_else(|| Error::NotFound(format!("record {} in document {}", op.0, doc.0)))?;
        let d = self.live(doc, branch)?.clone();
        let r = read(&d, &spans)?;
        let part = r.parts.get(index).ok_or_else(|| {
            Error::NotFound(format!(
                "hunk {index} of record {} ({} hunks)",
                op.0,
                r.parts.len()
            ))
        })?;
        let hunk = self
            .op_hunks(branch, op)?
            .into_iter()
            .find(|h| h.doc == doc && h.index == index)
            .ok_or_else(|| Error::NotFound(format!("hunk {index}")))?;
        if hunk.state == HunkState::Undone {
            return Ok(HunkPlan::Undone(hunk.undone_by));
        }
        if let Some(c) = r.conflict(part) {
            return Ok(HunkPlan::Conflict(c));
        }
        let fork = d.fork();
        let mut log = Vec::new();
        keep_mine(&fork, &r.sub_scope(part), &[], &[], &mut log)?;
        if log.is_empty() {
            return Ok(HunkPlan::Undone(hunk.undone_by));
        }
        Ok(HunkPlan::Edits(log))
    }

    /// CHANGES (a plan's edits) applied to DOC on BRANCH as PEER's operations, and one `revert` record naming OP.
    pub fn apply_hunk_revert(
        &mut self,
        branch: BranchId,
        op: OpId,
        doc: DocId,
        changes: &[Change],
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        let mut spans = Vec::new();
        {
            let mut ad = self.activate(doc, branch, || {
                Err(Error::NotFound(format!("document {}", doc.0)))
            })?;
            for c in changes {
                spans.extend(ad.apply(peer, c)?.into_iter().map(|s| (doc, s)));
            }
        }
        self.record_hunk_revert(op, spans, peer, at)
    }

    /// The `revert` record of a hunk of OP whose operations (SPANS, by PEER) are applied already: OP's cause, OP as
    /// its parent.
    pub fn record_hunk_revert(
        &mut self,
        op: OpId,
        spans: Vec<(DocId, Span)>,
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        let cause = self.op(op)?.cause;
        self.record(Record {
            kind: Kind::Revert,
            author: peer,
            cause,
            spans,
            parents: vec![op],
            git: None,
            summary: format!("revert of a hunk of record {}", op.0),
            at,
        })
    }
}
