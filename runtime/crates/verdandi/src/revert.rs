//! Revert to here, on element ids (design §4.3).  The scope is records; their spans name the element ids their
//! operations made.  **Keep mine:** each element the scope inserted that is still there is deleted, and each element
//! it deleted is inserted again after its nearest surviving left neighbour (later deletions first, so a run deleted
//! after its neighbour lands beside it).  **Overlaps** are found by adjacency at the scope's own version: two scoped
//! characters next to each other then and not now (the user typed between them), or a scoped character there then and
//! gone now (the user deleted it).  Each overlap is a hunk the user decides.  The result is compared with git's
//! 3-way merge (base: after the scope, ours: now, theirs: before it); a difference with no overlap means the span
//! revert is wrong, and the preview carries the 3-way text instead.  **Roll back mine too:** the text before the
//! scope, applied as new operations, with the document as it was kept on `undone/<record>`.
//!
//! Loro's public API only: the scope's operations come from `export_json_in_id_span`, element ids from cursors.

use crate::docs::TEXT;
use crate::store::{BranchKind, DocUpdate, History, Kind, Record};
use crate::{BranchId, DocId, Error, Frontier, OpId, PeerId, Result, Span, loro};
use ::loro::cursor::Side;
use ::loro::json::{JsonOpContent, TextOp};
use ::loro::{Frontiers, ID, IdSpan, LoroDoc, LoroText};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// How the user's own later edits are treated.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Mode {
    /// Only the scope's operations are undone; the user's stay.
    KeepMine,
    /// The text goes back to before the scope; the user's later edits move to `undone/<record>`.
    RollBackMine,
}

/// The user's answer to one overlap.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OverlapChoice {
    /// Keep the user's text in the hunk.
    KeepUsers,
    /// The reverted text: the user's text inside the scope's insert goes with it.
    TakeReverted,
    /// This text in place of the hunk.
    Edited(String),
}

/// One file of a preview.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilePreview {
    pub doc: DocId,
    pub path: String,
    /// The text now.
    pub now: String,
    /// The text after the revert (the 3-way text when the check differed).
    pub after: String,
    /// The 3-way check differed from the span revert in this file.
    pub threeway_differs: bool,
}

/// A user's later edit that cuts the scope's text: a hunk to decide.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Overlap {
    pub doc: DocId,
    pub path: String,
    /// Where it is in the text now (a character offset).
    pub at: usize,
    /// The user's text there (empty when the user deleted the scope's text).
    pub users: String,
}

/// What a revert would do, kept until it is applied or the documents move.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RevertPreview {
    pub id: i64,
    pub files: Vec<FilePreview>,
    pub overlaps: Vec<Overlap>,
    pub threeway_differs: bool,
}

/// The stored part of a preview.
#[derive(Serialize, Deserialize)]
struct Stored {
    scope: Vec<i64>,
    /// Per document: the 3-way text when the check differed.
    threeway: Vec<(i64, Option<String>)>,
}

/// The element id of each character of T, in order.
pub(crate) fn char_ids(t: &LoroText) -> Vec<ID> {
    (0..t.len_unicode())
        .map(|i| {
            t.get_cursor(i, Side::Right)
                .and_then(|c| c.id)
                .expect("a character has an id")
        })
        .collect()
}

/// A deletion the scope made: the version before it and the range it deleted then.
struct Deletion {
    order: (i64, u64),
    before: Frontiers,
    start: usize,
    end: usize,
}

/// What the scope's operations did in one document.
struct Scope {
    inserted: HashSet<ID>,
    deletions: Vec<Deletion>,
    /// The version right after the scope, and right before its first operation.
    after: Frontiers,
    before: Frontiers,
}

fn scope_of(d: &LoroDoc, spans: &[Span]) -> Scope {
    let mut inserted = HashSet::new();
    let mut deletions = Vec::new();
    let mut first: Option<((i64, u64), Frontiers)> = None;
    let mut ends = Vec::new();
    for s in spans {
        if s.end > s.start {
            ends.push(ID::new(s.peer.0, s.end as i32 - 1));
        }
        for ch in d.export_json_in_id_span(IdSpan::new(s.peer.0, s.start as i32, s.end as i32)) {
            for op in &ch.ops {
                if op.counter < s.start as i32 || op.counter >= s.end as i32 {
                    continue;
                }
                let lamport = i64::from(ch.lamport) + i64::from(op.counter - ch.id.counter);
                let before = if op.counter > ch.id.counter {
                    Frontiers::from(ID::new(ch.id.peer, op.counter - 1))
                } else {
                    Frontiers::from(ch.deps.clone())
                };
                if first
                    .as_ref()
                    .is_none_or(|(o, _)| (lamport, ch.id.peer) < *o)
                {
                    first = Some(((lamport, ch.id.peer), before.clone()));
                }
                match &op.content {
                    JsonOpContent::Text(TextOp::Insert { text, .. }) => {
                        for i in 0..text.chars().count() as i32 {
                            inserted.insert(ID::new(ch.id.peer, op.counter + i));
                        }
                    }
                    JsonOpContent::Text(TextOp::Delete { pos, len, .. }) => {
                        let (start, end) = if *len > 0 {
                            (*pos, *pos + *len)
                        } else {
                            (*pos + 1 + *len, *pos + 1)
                        };
                        deletions.push(Deletion {
                            order: (lamport, ch.id.peer),
                            before,
                            start: start.max(0) as usize,
                            end: end.max(0) as usize,
                        });
                    }
                    _ => {}
                }
            }
        }
    }
    // collected, not `From<Vec<ID>>`: two ends of one peer would make a one-entry map, which Loro's own comparisons
    // cannot meet (they panic on it)
    let ends: Frontiers = ends.into_iter().collect();
    let after = d
        .minimize_frontiers(&ends)
        .unwrap_or_else(|_| d.oplog_frontiers());
    Scope {
        inserted,
        deletions,
        after,
        before: first.map_or_else(Frontiers::default, |f| f.1),
    }
}

/// An overlap as found: the scope's characters it sits between (or the run it deleted) and the user's characters.
struct Found {
    /// The user's characters inside the scope's insert, alive now.
    users: Vec<ID>,
    /// Where it is now.
    at: usize,
}

/// The overlaps in D (adjacency at the scope's version), in document order.
fn overlaps(d: &LoroDoc, sc: &Scope) -> Result<Vec<Found>> {
    let now = char_ids(&d.get_text(TEXT));
    let pos: HashMap<ID, usize> = now.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let then = d.fork_at(&sc.after).map_err(loro)?;
    let ids1 = char_ids(&then.get_text(TEXT));
    let mut out = Vec::new();
    // the user typed between two scoped characters that were neighbours
    for w in ids1.windows(2) {
        if sc.inserted.contains(&w[0])
            && sc.inserted.contains(&w[1])
            && let (Some(p0), Some(p1)) = (pos.get(&w[0]), pos.get(&w[1]))
            && *p1 != *p0 + 1
            && p1 > p0
        {
            out.push(Found {
                users: now[p0 + 1..*p1]
                    .iter()
                    .filter(|id| !sc.inserted.contains(id))
                    .copied()
                    .collect(),
                at: p0 + 1,
            });
        }
    }
    // the user deleted scoped characters: one hunk per run, where the run was
    let mut in_run = false;
    let mut last_alive = 0usize;
    for id in &ids1 {
        if let Some(p) = pos.get(id) {
            last_alive = p + 1;
            in_run = false;
        } else if sc.inserted.contains(id) && !in_run {
            in_run = true;
            out.push(Found {
                users: Vec::new(),
                at: last_alive,
            });
        } else if !sc.inserted.contains(id) {
            in_run = false;
        }
    }
    out.sort_by_key(|f| f.at);
    Ok(out)
}

/// Keep mine on D, with CHOICES for its overlaps (missing ones keep the user's text), as PEER's operations.
fn keep_mine(d: &LoroDoc, sc: &Scope, found: &[Found], choices: &[OverlapChoice]) -> Result<()> {
    let t = d.get_text(TEXT);
    let now = char_ids(&t);
    // where an edited hunk goes, as a cursor that follows the edits below
    let mut edits = Vec::new();
    let mut drop: HashSet<ID> = HashSet::new();
    for (i, f) in found.iter().enumerate() {
        match choices.get(i).unwrap_or(&OverlapChoice::KeepUsers) {
            OverlapChoice::KeepUsers => {}
            OverlapChoice::TakeReverted => drop.extend(f.users.iter().copied()),
            OverlapChoice::Edited(s) => {
                drop.extend(f.users.iter().copied());
                edits.push((t.get_cursor(f.at, Side::Left), s.clone()));
            }
        }
    }
    // 1. the scope's characters still there, and the user's the choices drop, deleted in runs from the right
    let gone: Vec<usize> = now
        .iter()
        .enumerate()
        .filter(|(_, id)| sc.inserted.contains(id) || drop.contains(id))
        .map(|(i, _)| i)
        .collect();
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for p in gone {
        match runs.last_mut() {
            Some((s, l)) if *s + *l == p => *l += 1,
            _ => runs.push((p, 1)),
        }
    }
    for (s, l) in runs.iter().rev() {
        t.delete(*s, *l).map_err(loro)?;
    }
    // 2. what the scope deleted, inserted again after its surviving left neighbour, the latest deletion first; a
    // character inserted again stands in for the one it replaces when a later run looks for its neighbour
    let mut again: HashMap<ID, ID> = HashMap::new();
    let mut dels: Vec<&Deletion> = sc.deletions.iter().collect();
    dels.sort_by_key(|a| std::cmp::Reverse(a.order));
    for del in dels {
        let pre = d.fork_at(&del.before).map_err(loro)?;
        let pt = pre.get_text(TEXT);
        let ids0 = char_ids(&pt);
        let chars: Vec<char> = pt.to_string().chars().collect();
        let end = del.end.min(ids0.len());
        // the deleted characters that were not the scope's own inserts, in runs
        let mut kept: Vec<(usize, usize)> = Vec::new();
        for (i, id) in ids0.iter().enumerate().take(end).skip(del.start) {
            if sc.inserted.contains(id) {
                continue;
            }
            match kept.last_mut() {
                Some((s, l)) if *s + *l == i => *l += 1,
                _ => kept.push((i, 1)),
            }
        }
        for (s, l) in kept.iter().rev() {
            let cur = char_ids(&t);
            let at_now: HashMap<ID, usize> =
                cur.iter().enumerate().map(|(i, id)| (*id, i)).collect();
            let mut at = 0;
            for k in (0..*s).rev() {
                let id = again.get(&ids0[k]).unwrap_or(&ids0[k]);
                if let Some(p) = at_now.get(id) {
                    at = p + 1;
                    break;
                }
            }
            let txt: String = chars[*s..*s + *l].iter().collect();
            t.insert(at, &txt).map_err(loro)?;
            for i in 0..*l {
                if let Some(new) = t.get_cursor(at + i, Side::Right).and_then(|c| c.id) {
                    again.insert(ids0[*s + i], new);
                }
            }
        }
    }
    // 3. the edited hunks' text
    for (c, s) in edits {
        let at = c
            .and_then(|c| d.get_cursor_pos(&c).ok())
            .map_or(0, |p| p.current.pos);
        t.insert(at.min(t.len_unicode()), &s).map_err(loro)?;
    }
    Ok(())
}

/// Replace D's text with TARGET as one edit over the part that differs.
fn set_text(d: &LoroDoc, target: &str) -> Result<()> {
    set_text_range(d, target).map(|_| ())
}

/// [`set_text`], and where the inserted part of TARGET sits in it: (character offset, characters).
pub(crate) fn set_text_range(d: &LoroDoc, target: &str) -> Result<(usize, usize)> {
    let t = d.get_text(TEXT);
    let now: Vec<char> = t.to_string().chars().collect();
    let want: Vec<char> = target.chars().collect();
    let pre = now.iter().zip(&want).take_while(|(a, b)| a == b).count();
    let max_suf = now.len().min(want.len()) - pre;
    let suf = now
        .iter()
        .rev()
        .zip(want.iter().rev())
        .take(max_suf)
        .take_while(|(a, b)| a == b)
        .count();
    let del = now.len() - pre - suf;
    if del > 0 {
        t.delete(pre, del).map_err(loro)?;
    }
    let ins: String = want[pre..want.len() - suf].iter().collect();
    if !ins.is_empty() {
        t.insert(pre, &ins).map_err(loro)?;
    }
    Ok((pre, ins.chars().count()))
}

/// The text of D at version F.
fn text_at(d: &LoroDoc, f: &Frontiers) -> Result<String> {
    Ok(d.fork_at(f).map_err(loro)?.get_text(TEXT).to_string())
}

impl History {
    /// The spans of SCOPE's records, by document.
    fn scope_spans(&self, scope: &[OpId]) -> Result<Vec<(DocId, Vec<Span>)>> {
        if scope.is_empty() {
            return Err(Error::Refused("a revert needs at least one record".into()));
        }
        let mut by: Vec<(DocId, Vec<Span>)> = Vec::new();
        for id in scope {
            for (d, s) in self.op(*id)?.spans {
                match by.iter_mut().find(|(x, _)| *x == d) {
                    Some((_, v)) => v.push(s),
                    None => by.push((d, vec![s])),
                }
            }
        }
        Ok(by)
    }

    /// The versions of BRANCH's documents in BY, as a preview checks them.
    fn versions(
        &mut self,
        branch: BranchId,
        by: &[(DocId, Vec<Span>)],
    ) -> Result<Vec<(DocId, BranchId, Frontier)>> {
        let mut v = Vec::new();
        for (d, _) in by {
            v.push((*d, branch, self.frontier(*d, branch)?));
        }
        Ok(v)
    }

    /// What reverting SCOPE on BRANCH would do (keep mine, the user's text kept in every overlap), stored for
    /// [`History::apply_revert`].  Changes no document.
    pub fn preview_revert(&mut self, branch: BranchId, scope: &[OpId]) -> Result<RevertPreview> {
        let by = self.scope_spans(scope)?;
        let mut files = Vec::new();
        let mut all = Vec::new();
        let mut stored = Vec::new();
        for (doc, spans) in &by {
            let path = self.path_of(*doc)?;
            let d = self.live(*doc, branch)?.fork();
            let sc = scope_of(&d, spans);
            let found = overlaps(&d, &sc)?;
            let now = d.get_text(TEXT).to_string();
            let chars: Vec<char> = now.chars().collect();
            let at: HashMap<ID, usize> = char_ids(&d.get_text(TEXT))
                .into_iter()
                .enumerate()
                .map(|(i, id)| (id, i))
                .collect();
            for f in &found {
                all.push(Overlap {
                    doc: *doc,
                    path: path.clone(),
                    at: f.at,
                    users: f
                        .users
                        .iter()
                        .filter_map(|id| at.get(id).map(|p| chars[*p]))
                        .collect(),
                });
            }
            keep_mine(&d, &sc, &found, &[])?;
            let mut after = d.get_text(TEXT).to_string();
            let mut differs = false;
            if found.is_empty() {
                let base = text_at(&d, &sc.after)?;
                let theirs = text_at(&d, &sc.before)?;
                let (clean, merged) = crate::threeway::merge(&base, &now, &theirs)?;
                if clean && merged != after {
                    differs = true;
                    after = merged;
                }
            }
            stored.push((doc.0, differs.then(|| after.clone())));
            files.push(FilePreview {
                doc: *doc,
                path,
                now,
                after,
                threeway_differs: differs,
            });
        }
        let versions = self.versions(branch, &by)?;
        let json = serde_json::to_string(&Stored {
            scope: scope.iter().map(|o| o.0).collect(),
            threeway: stored,
        })
        .map_err(|e| Error::Refused(e.to_string()))?;
        self.conn.execute(
            "insert into preview (branch, frontier_blob, json, at) values (?1, ?2, ?3, ?4)",
            params![
                branch.0,
                crate::store::encode_view(&versions),
                json,
                crate::wall_secs()
            ],
        )?;
        let threeway_differs = files.iter().any(|f| f.threeway_differs);
        Ok(RevertPreview {
            id: self.conn.last_insert_rowid(),
            files,
            overlaps: all,
            threeway_differs,
        })
    }

    /// Apply preview PREVIEW (refused as stale when a document moved since) with CHOICES for its overlaps, in MODE,
    /// as PEER's operations at AT: one `revert` record naming the scope, written with every document's operations in
    /// one transaction.
    pub fn apply_revert(
        &mut self,
        preview: i64,
        choices: &[OverlapChoice],
        mode: Mode,
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        self.apply_scope(Kind::Revert, preview, choices, mode, peer, at)
    }

    /// [`History::apply_revert`] writing a record of KIND (a redo is a revert of a revert).
    pub(crate) fn apply_scope(
        &mut self,
        kind: Kind,
        preview: i64,
        choices: &[OverlapChoice],
        mode: Mode,
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        let (branch, versions, json): (i64, Vec<u8>, String) = self
            .conn
            .query_row(
                "select branch, frontier_blob, json from preview where id = ?1",
                [preview],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("preview {preview}")))?;
        let branch = BranchId(branch);
        let stored: Stored =
            serde_json::from_str(&json).map_err(|e| Error::Refused(e.to_string()))?;
        let scope: Vec<OpId> = stored.scope.iter().map(|o| OpId(*o)).collect();
        let by = self.scope_spans(&scope)?;
        if self.versions(branch, &by)? != crate::store::decode_view(&versions)? {
            return Err(Error::Refused(
                "stale: a document changed since the preview".into(),
            ));
        }
        let mut spans = Vec::new();
        let mut keep = Vec::new();
        // the choices are in the preview's overlap order: each document takes its own
        let mut next = 0usize;
        for (doc, sp) in &by {
            let undone = match mode {
                Mode::RollBackMine => Some(
                    self.live(*doc, branch)?
                        .export(loro::ExportMode::Snapshot)
                        .map_err(loro)?,
                ),
                Mode::KeepMine => None,
            };
            let three = stored
                .threeway
                .iter()
                .find(|(d, _)| *d == doc.0)
                .and_then(|(_, t)| t.clone());
            let d = self.live(*doc, branch)?;
            d.commit();
            d.set_peer_id(peer.0).map_err(loro)?;
            let before = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
            let sc = scope_of(d, sp);
            let found = overlaps(d, &sc)?;
            let mine = choices
                .get(next..(next + found.len()).min(choices.len()))
                .unwrap_or(&[]);
            next += found.len();
            match (mode, three) {
                (Mode::RollBackMine, _) => set_text(d, &text_at(d, &sc.before)?)?,
                (Mode::KeepMine, Some(t)) => set_text(d, &t)?,
                (Mode::KeepMine, None) => keep_mine(d, &sc, &found, mine)?,
            }
            d.commit();
            let after = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
            if after > before {
                spans.push((
                    *doc,
                    Span {
                        peer,
                        start: before as u32,
                        end: after as u32,
                    },
                ));
            }
            keep.push((*doc, undone));
        }
        let mut updates = Vec::new();
        for (doc, _) in &keep {
            if let Some(bytes) = self.unsaved(*doc, branch)? {
                updates.push(DocUpdate {
                    doc: *doc,
                    branch,
                    bytes,
                });
            }
        }
        let view = self.view()?;
        let r = Record {
            kind,
            author: peer,
            cause: Default::default(),
            spans,
            parents: scope,
            git: None,
            summary: format!("{} in {} files", kind.as_str(), keep.len()),
            at,
        };
        let written = (|| -> Result<OpId> {
            let tx = self.conn.transaction()?;
            let id = crate::store::put_op_tx(&tx, &r, &view, &updates)?;
            if mode == Mode::RollBackMine {
                let name = format!("undone/{}", id.0);
                tx.execute(
                    "insert into branch (name, kind, base_commit) values (?1, ?2, null)",
                    params![name, BranchKind::Undone.as_str()],
                )?;
                let ub = BranchId(tx.last_insert_rowid());
                for (doc, bytes) in &keep {
                    if let Some(b) = bytes {
                        crate::store::put_update(&tx, *doc, ub, b)?;
                    }
                }
            }
            tx.execute("delete from preview where id = ?1", [preview])?;
            tx.commit()?;
            Ok(id)
        })();
        match written {
            Ok(id) => {
                for (doc, _) in &keep {
                    self.saved(*doc, branch);
                }
                Ok(id)
            }
            Err(e) => {
                // the documents in memory are ahead of their rows: the rows are the truth again
                for (doc, _) in &keep {
                    self.forget(*doc, branch);
                }
                Err(e)
            }
        }
    }
}
