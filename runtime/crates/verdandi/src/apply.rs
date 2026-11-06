//! Text applied by diff, with where it came from: redo (a revert of a revert, or part of what a roll back set aside),
//! a fork from a record, the hunks two branches differ by and the whole hunks taken from one into the other.
//!
//! Two branches of one file share the element ids of everything up to where they parted, so a **hunk** is found
//! exactly: the elements only one of them holds, between two elements both hold.  A hunk is taken whole or not at all.
//! New text applied from another branch is written as new operations by the taker, and the record keeps the source
//! element ids (`provenance`), so the history can say where the text came from.

use crate::docs::TEXT;
use crate::revert::{Mode, OverlapChoice, char_ids, set_text_range};
use crate::store::{DocUpdate, History, Kind, Record, decode_spans, encode_spans, put_op_tx};
use crate::{BranchId, DocId, Error, OpId, PeerId, Result, Span, loro};
use ::loro::{ExportMode, Frontiers, ID};
use rusqlite::{OptionalExtension, params};
use std::collections::HashMap;
use std::ops::Range;

/// The peers of a document's seed have the top bit set: nobody wrote their text.
const SEED_BIT: u64 = 1 << 63;

/// One place two branches of a file differ.  OURS is the first branch of the comparison, THEIRS the second.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub doc: DocId,
    /// Character offsets in each branch's text (empty when that branch has nothing there).
    pub ours_start: usize,
    pub ours_end: usize,
    pub theirs_start: usize,
    pub theirs_end: usize,
    pub ours_text: String,
    pub theirs_text: String,
    /// Who wrote THEIRS' text and in which record; none for a deletion (an element id does not name its deleter).
    pub author: Option<PeerId>,
    pub step: Option<OpId>,
}

impl Hunk {
    /// The reference [`History::take`] takes it by.
    pub fn as_ref(&self) -> HunkRef {
        HunkRef {
            doc: self.doc,
            theirs_start: self.theirs_start,
            theirs_end: self.theirs_end,
        }
    }
}

/// A hunk to take: the file and its exact range in the source branch's text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HunkRef {
    pub doc: DocId,
    pub theirs_start: usize,
    pub theirs_end: usize,
}

/// A file's hunks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileDiff {
    pub doc: DocId,
    pub path: String,
    pub hunks: Vec<Hunk>,
}

/// Where two element lists differ: OURS' range and THEIRS' range between two shared elements.
struct Seg {
    ours: Range<usize>,
    theirs: Range<usize>,
}

/// The segments OURS and THEIRS differ by.  The elements both hold keep one order in both.
fn align(ours: &[ID], theirs: &[ID]) -> Vec<Seg> {
    let pos: HashMap<ID, usize> = theirs.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let (mut pi, mut pj) = (0usize, 0usize);
    let mut out = Vec::new();
    for (i, id) in ours.iter().enumerate() {
        let Some(&j) = pos.get(id) else { continue };
        if j < pj {
            continue;
        }
        if i > pi || j > pj {
            out.push(Seg {
                ours: pi..i,
                theirs: pj..j,
            });
        }
        pi = i + 1;
        pj = j + 1;
    }
    if ours.len() > pi || theirs.len() > pj {
        out.push(Seg {
            ours: pi..ours.len(),
            theirs: pj..theirs.len(),
        });
    }
    out
}

/// IDS as spans: runs of one peer's consecutive counters.
pub(crate) fn spans_of(ids: &[ID]) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    for id in ids {
        let c = id.counter as u32;
        match out.last_mut() {
            Some(l) if l.peer.0 == id.peer && l.end == c => l.end = c + 1,
            _ => out.push(Span {
                peer: PeerId(id.peer),
                start: c,
                end: c + 1,
            }),
        }
    }
    out
}

/// The record each element was made in: (document, span, record), oldest first.
pub(crate) struct OpIndex(Vec<(DocId, Span, OpId)>);

impl OpIndex {
    pub(crate) fn find(&self, doc: DocId, id: ID) -> Option<OpId> {
        self.0
            .iter()
            .find(|(d, s, _)| {
                *d == doc
                    && s.peer.0 == id.peer
                    && s.start <= id.counter as u32
                    && (id.counter as u32) < s.end
            })
            .map(|(_, _, o)| *o)
    }
}

impl History {
    pub(crate) fn op_index(&self) -> Result<OpIndex> {
        let mut st = self
            .conn
            .prepare("select id, spans_blob from op order by id")?;
        let rows = st
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut out = Vec::new();
        for (id, blob) in rows {
            for (d, s) in decode_spans(&blob)? {
                out.push((d, s, OpId(id)));
            }
        }
        Ok(OpIndex(out))
    }

    /// Write R, with the operations DOCS hold on BRANCH not stored yet, and PROV (where applied text came from) in one
    /// transaction.  A failure leaves the documents in memory dropped: their rows are the truth again.
    pub(crate) fn commit_record(
        &mut self,
        r: Record,
        branch: BranchId,
        docs: &[DocId],
        prov: &[(DocId, Span)],
    ) -> Result<OpId> {
        let mut updates = Vec::new();
        for d in docs {
            if let Some(bytes) = self.unsaved(*d, branch)? {
                updates.push(DocUpdate {
                    doc: *d,
                    branch,
                    bytes,
                });
            }
        }
        let view = self.view()?;
        let written = (|| -> Result<OpId> {
            let tx = self.conn.transaction()?;
            let id = put_op_tx(&tx, &r, &view, &updates)?;
            if !prov.is_empty() {
                tx.execute(
                    "insert into provenance (op, spans_blob) values (?1, ?2)",
                    params![id.0, encode_spans(prov)],
                )?;
            }
            tx.commit()?;
            Ok(id)
        })();
        match written {
            Ok(id) => {
                for d in docs {
                    self.saved(*d, branch);
                }
                Ok(id)
            }
            Err(e) => {
                for d in docs {
                    self.forget(*d, branch);
                }
                Err(e)
            }
        }
    }

    /// The source element ids of RECORD's applied text, by document (empty for a record that applied none).
    pub fn provenance(&self, op: OpId) -> Result<Vec<(DocId, Span)>> {
        let blob: Option<Vec<u8>> = self
            .conn
            .query_row(
                "select spans_blob from provenance where op = ?1",
                [op.0],
                |r| r.get(0),
            )
            .optional()?;
        blob.map_or(Ok(Vec::new()), |b| decode_spans(&b))
    }

    /// Redo REVERT on BRANCH: a revert of the revert (keep mine), as PEER's operations at AT.
    pub fn redo(
        &mut self,
        revert: OpId,
        branch: BranchId,
        choices: &[OverlapChoice],
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        self.must_be_a_revert(revert)?;
        let p = self.preview_revert(branch, &[revert])?;
        self.apply_scope(Kind::Redo, p.id, choices, Mode::KeepMine, peer, at)
    }

    fn must_be_a_revert(&self, revert: OpId) -> Result<()> {
        if self.op(revert)?.kind != Kind::Revert {
            return Err(Error::Refused("only a revert can be redone".into()));
        }
        Ok(())
    }

    /// Redo only DOCS of REVERT (a roll back mine too): each file takes the text it had before the revert, applied by
    /// diff over its text now, with the source element ids as the record's provenance.
    pub fn redo_part(
        &mut self,
        revert: OpId,
        branch: BranchId,
        docs: &[DocId],
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        self.must_be_a_revert(revert)?;
        let name = format!("undone/{}", revert.0);
        let undone: Option<i64> = self
            .conn
            .query_row("select id from branch where name = ?1", [&name], |r| {
                r.get(0)
            })
            .optional()?;
        let Some(undone) = undone.map(BranchId) else {
            return Err(Error::Refused(
                "that revert kept your later edits and set nothing aside to redo from".into(),
            ));
        };
        let (mut spans, mut prov, mut done) = (Vec::new(), Vec::new(), Vec::new());
        for doc in docs {
            let src = self.live(*doc, undone)?.get_text(TEXT);
            let (target, ids) = (src.to_string(), char_ids(&src));
            let d = self.live(*doc, branch)?.clone();
            d.commit();
            d.set_peer_id(peer.0).map_err(loro)?;
            let before = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
            let (pos, n) = set_text_range(&d, &target)?;
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
            prov.extend(spans_of(&ids[pos..pos + n]).into_iter().map(|s| (*doc, s)));
            done.push(*doc);
        }
        self.commit_record(
            Record {
                kind: Kind::Redo,
                author: peer,
                cause: Default::default(),
                spans,
                parents: vec![revert],
                git: None,
                summary: format!("redo in {} files", done.len()),
                at,
            },
            branch,
            &done,
            &prov,
        )
    }

    /// A new fork branch NAME holding FROM's documents as they were after record AT, and a `fork` record naming AT.
    pub fn fork(
        &mut self,
        at: OpId,
        from: BranchId,
        name: &str,
        author: PeerId,
        now: f64,
    ) -> Result<BranchId> {
        let rec = self.op(at)?;
        let base = self.base_of(from)?;
        let mut docs = Vec::new();
        for (doc, b, frontier) in &rec.view {
            if *b != from {
                continue;
            }
            let src = self.live(*doc, from)?.clone();
            let f = Frontiers::decode(&frontier.0).map_err(loro)?;
            let then = src.fork_at(&f).map_err(loro)?;
            docs.push((*doc, then.export(ExportMode::all_updates()).map_err(loro)?));
        }
        if docs.is_empty() {
            return Err(Error::Refused(
                "that record holds no document of that branch".into(),
            ));
        }
        let view = self.view()?;
        let tx = self.conn.transaction()?;
        tx.execute(
            "insert into branch (name, kind, base_commit) values (?1, 'fork', ?2)",
            params![name, base],
        )?;
        let branch = BranchId(tx.last_insert_rowid());
        for (doc, bytes) in &docs {
            crate::store::put_update(&tx, *doc, branch, bytes)?;
        }
        put_op_tx(
            &tx,
            &Record {
                kind: Kind::Fork,
                author,
                cause: Default::default(),
                spans: Vec::new(),
                parents: vec![at],
                git: None,
                summary: format!("fork {name}"),
                at: now,
            },
            &view,
            &[],
        )?;
        tx.commit()?;
        Ok(branch)
    }

    /// The documents both A and B hold.
    fn shared_docs(&self, a: BranchId, b: BranchId) -> Result<Vec<DocId>> {
        let mut st = self.conn.prepare(
            "select doc from doc_update where branch = ?1 intersect \
             select doc from doc_update where branch = ?2 order by doc",
        )?;
        let v = st
            .query_map([a.0, b.0], |r| Ok(DocId(r.get(0)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(v)
    }

    /// The hunks B has that A does not, per file, with who wrote each and in which record.
    pub fn compare(&mut self, a: BranchId, b: BranchId) -> Result<Vec<FileDiff>> {
        let index = self.op_index()?;
        let mut out = Vec::new();
        for doc in self.shared_docs(a, b)? {
            let (ta, tb) = (
                self.live(doc, a)?.get_text(TEXT),
                self.live(doc, b)?.get_text(TEXT),
            );
            let (ia, ib) = (char_ids(&ta), char_ids(&tb));
            let (ca, cb): (Vec<char>, Vec<char>) = (
                ta.to_string().chars().collect(),
                tb.to_string().chars().collect(),
            );
            // text taken from the other branch is new elements with the same characters: no difference left
            let hunks: Vec<Hunk> = align(&ia, &ib)
                .into_iter()
                .filter(|s| ca[s.ours.clone()] != cb[s.theirs.clone()])
                .map(|s| {
                    let first = ib.get(s.theirs.start).filter(|_| !s.theirs.is_empty());
                    Hunk {
                        doc,
                        ours_start: s.ours.start,
                        ours_end: s.ours.end,
                        theirs_start: s.theirs.start,
                        theirs_end: s.theirs.end,
                        ours_text: ca[s.ours.clone()].iter().collect(),
                        theirs_text: cb[s.theirs.clone()].iter().collect(),
                        author: first
                            .filter(|id| id.peer & SEED_BIT == 0)
                            .map(|id| PeerId(id.peer)),
                        step: first.and_then(|id| index.find(doc, *id)),
                    }
                })
                .collect();
            if !hunks.is_empty() {
                out.push(FileDiff {
                    path: self.path_of(doc)?,
                    doc,
                    hunks,
                });
            }
        }
        Ok(out)
    }

    /// Take HUNKS of FROM into TO as PEER's new operations at AT, one `merge` record whose provenance is the source
    /// element ids.  Every hunk is taken whole: a range that is not exactly one of the branches' hunks is refused and
    /// nothing is changed.
    pub fn take(
        &mut self,
        from: BranchId,
        to: BranchId,
        hunks: &[HunkRef],
        peer: PeerId,
        at: f64,
    ) -> Result<OpId> {
        if hunks.is_empty() {
            return Err(Error::Refused("nothing to take".into()));
        }
        let mut docs: Vec<DocId> = Vec::new();
        for h in hunks {
            if !docs.contains(&h.doc) {
                docs.push(h.doc);
            }
        }
        // find every hunk before changing anything
        let mut plan = Vec::new();
        for doc in &docs {
            let (src, dst) = (
                self.live(*doc, from)?.get_text(TEXT),
                self.live(*doc, to)?.get_text(TEXT),
            );
            let (is, id) = (char_ids(&src), char_ids(&dst));
            let text: Vec<char> = src.to_string().chars().collect();
            let mut segs = align(&id, &is);
            let mut chosen = Vec::new();
            for h in hunks.iter().filter(|h| h.doc == *doc) {
                let Some(i) = segs
                    .iter()
                    .position(|s| s.theirs == (h.theirs_start..h.theirs_end))
                else {
                    return Err(Error::Refused(format!(
                        "{}..{} is not one whole hunk of {}: a hunk is taken whole or not at all",
                        h.theirs_start,
                        h.theirs_end,
                        self.path_of(*doc)?
                    )));
                };
                chosen.push(segs.swap_remove(i));
            }
            // from the end, so the offsets above stay true
            chosen.sort_by_key(|s| std::cmp::Reverse(s.ours.start));
            plan.push((*doc, chosen, is, text));
        }
        let (mut spans, mut prov) = (Vec::new(), Vec::new());
        for (doc, chosen, is, text) in plan {
            let d = self.live(doc, to)?.clone();
            let t = d.get_text(TEXT);
            d.commit();
            d.set_peer_id(peer.0).map_err(loro)?;
            let before = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
            for s in chosen {
                if !s.ours.is_empty() {
                    t.delete(s.ours.start, s.ours.len()).map_err(loro)?;
                }
                if !s.theirs.is_empty() {
                    let ins: String = text[s.theirs.clone()].iter().collect();
                    t.insert(s.ours.start, &ins).map_err(loro)?;
                    prov.extend(spans_of(&is[s.theirs]).into_iter().map(|p| (doc, p)));
                }
            }
            d.commit();
            let after = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
            if after > before {
                spans.push((
                    doc,
                    Span {
                        peer,
                        start: before as u32,
                        end: after as u32,
                    },
                ));
            }
        }
        self.commit_record(
            Record {
                kind: Kind::Merge,
                author: peer,
                cause: Default::default(),
                spans,
                parents: vec![],
                git: None,
                summary: format!("took {} hunks from another branch", hunks.len()),
                at,
            },
            to,
            &docs,
            &prov,
        )
    }
}
