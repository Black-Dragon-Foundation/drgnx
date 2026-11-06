//! Documents and branches.  A document per tracked file (by its path in the project); a branch per worktree
//! (`wt/<id>`), fork (`fork/<id>`) or undone set (`undone/<op>`).  A branch is rows in `history.db`; an *active*
//! branch of a file is a Loro document in memory, built on its first touch from the branch's base commit (lazy).
//!
//! Every branch at one commit starts from the same seed: the base text inserted once, in chunks of about 300 bytes in
//! ascending order, by a peer derived from the document and the commit.  So branches share element ids up to their
//! base and merge without crossing.  Each change is stored as it is applied (`doc_update`); a current snapshot is
//! kept per document and branch, written again once the tail passes [`SNAPSHOT_TAIL`] updates, when a document is
//! parked and when the history closes, so a load is a snapshot and a short tail.

use crate::store::History;
use crate::{BranchId, DocId, Error, Frontier, PeerId, Result, Span, loro};
use ::loro::{ExportMode, LoroDoc, VersionVector};
use rusqlite::{OptionalExtension, params};
use std::collections::HashMap;

/// Updates after the snapshot before a new snapshot is written.
pub const SNAPSHOT_TAIL: i64 = 300;

/// The seed's chunk size, in bytes (a char boundary at or after it).
const SEED_CHUNK: usize = 300;

/// The text container's name in every document.
pub(crate) const TEXT: &str = "t";

/// One change to a document: OLD_LEN characters at START (character offsets in the LF text) replaced by INSERTED.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub start: usize,
    pub old_len: usize,
    pub inserted: String,
}

/// A document of one branch in memory.
pub(crate) struct Live {
    pub(crate) doc: LoroDoc,
    /// What `doc_update` holds already.
    saved: VersionVector,
    /// Updates after the stored snapshot.
    tail: i64,
    /// The use count when it was last used ([`History::park_idle`]).
    used: u64,
}

/// The active documents, and the marks [`History::park_idle`] measures idleness by.
#[derive(Default)]
pub(crate) struct Active {
    pub(crate) docs: HashMap<(DocId, BranchId), Live>,
    uses: u64,
    /// (time, use count then), one per `park_idle` call.
    marks: Vec<(f64, u64)>,
}

/// An active branch of a document: apply changes, read its text.
pub struct ActiveDoc<'h> {
    h: &'h mut History,
    key: (DocId, BranchId),
}

/// The peer the seed of DOC at BASE is written by: the top bit set, so it never meets a peer of [`History::peer`].
fn seed_peer(doc: DocId, base: Option<&str>) -> u64 {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(doc.0.to_le_bytes());
    h.update(base.unwrap_or("").as_bytes());
    let d = h.finalize();
    let n = u64::from_le_bytes(d[0..8].try_into().expect("width"));
    (n | (1 << 63)).min(u64::MAX - 1)
}

/// TEXT inserted into a fresh document by PEER in chunks of about [`SEED_CHUNK`] bytes, ascending.
fn seed(peer: u64, text: &str) -> Result<LoroDoc> {
    let d = LoroDoc::new();
    d.set_peer_id(peer).map_err(loro)?;
    let t = d.get_text(TEXT);
    let (mut at, mut chars, mut rest) = (0usize, 0usize, text);
    while !rest.is_empty() {
        let mut cut = SEED_CHUNK.min(rest.len());
        while !rest.is_char_boundary(cut) {
            cut += 1;
        }
        let (chunk, tail) = rest.split_at(cut);
        t.insert(at, chunk).map_err(loro)?;
        chars += chunk.chars().count();
        at = chars;
        rest = tail;
    }
    d.commit();
    Ok(d)
}

impl History {
    /// DOC on BRANCH, active: from memory, else from its rows, else built from TEXT_AT_BASE (the base commit's text,
    /// asked for only then, and not at all when another branch at the same commit has the seed).
    pub fn activate(
        &mut self,
        doc: DocId,
        branch: BranchId,
        text_at_base: impl FnOnce() -> Result<String>,
    ) -> Result<ActiveDoc<'_>> {
        if !self.active.docs.contains_key(&(doc, branch)) && !self.load(doc, branch)? {
            let base = self.base_of(branch)?;
            // the seed of another worktree branch at the same commit, so the two share element ids
            let shared: Option<Vec<u8>> = match &base {
                Some(c) => self
                    .conn
                    .query_row(
                        "select u.bytes from doc_update u join branch b on b.id = u.branch \
                         where u.doc = ?1 and u.seq = 1 and b.kind = 'wt' and b.base_commit = ?2 and b.id != ?3 \
                         limit 1",
                        params![doc.0, c, branch.0],
                        |r| r.get(0),
                    )
                    .optional()?,
                None => None,
            };
            let bytes = match shared {
                Some(b) => b,
                None => seed(seed_peer(doc, base.as_deref()), &text_at_base()?)?
                    .export(ExportMode::all_updates())
                    .map_err(loro)?,
            };
            crate::store::put_update(&self.conn, doc, branch, &bytes)?;
            if !self.load(doc, branch)? {
                return Err(Error::NotFound(format!(
                    "document {} on branch {}",
                    doc.0, branch.0
                )));
            }
        }
        self.touch(doc, branch);
        Ok(ActiveDoc {
            h: self,
            key: (doc, branch),
        })
    }

    /// DOC on BRANCH from its rows (snapshot, then the updates after it); false when it has none.
    pub(crate) fn load(&mut self, doc: DocId, branch: BranchId) -> Result<bool> {
        if self.active.docs.contains_key(&(doc, branch)) {
            return Ok(true);
        }
        let snap: Option<(i64, Vec<u8>)> = self
            .conn
            .query_row(
                "select upto_seq, bytes from doc_snapshot where doc = ?1 and branch = ?2",
                params![doc.0, branch.0],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let upto = snap.as_ref().map_or(0, |s| s.0);
        let mut st = self.conn.prepare(
            "select bytes from doc_update where doc = ?1 and branch = ?2 and seq > ?3 order by seq",
        )?;
        let tail = st
            .query_map(params![doc.0, branch.0, upto], |r| r.get::<_, Vec<u8>>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(st);
        if snap.is_none() && tail.is_empty() {
            return Ok(false);
        }
        let d = LoroDoc::new();
        if let Some((_, b)) = &snap {
            d.import(b).map_err(loro)?;
        }
        if !tail.is_empty() {
            d.import_batch(&tail).map_err(loro)?;
        }
        let live = Live {
            saved: d.oplog_vv(),
            doc: d,
            tail: tail.len() as i64,
            used: 0,
        };
        self.active.docs.insert((doc, branch), live);
        Ok(true)
    }

    fn touch(&mut self, doc: DocId, branch: BranchId) {
        self.active.uses += 1;
        let n = self.active.uses;
        if let Some(l) = self.active.docs.get_mut(&(doc, branch)) {
            l.used = n;
        }
    }

    /// Store DOC on BRANCH's current snapshot and drop it from memory.
    pub fn park(&mut self, doc: DocId, branch: BranchId) -> Result<()> {
        if self.active.docs.contains_key(&(doc, branch)) {
            self.snapshot(doc, branch)?;
            self.active.docs.remove(&(doc, branch));
        }
        Ok(())
    }

    /// Park every document unused for OLDER_THAN seconds at NOW (the hub's clock, called on its timer): unused
    /// since an earlier call at least that long ago.  The parked documents.
    pub fn park_idle(&mut self, older_than: f64, now: f64) -> Result<Vec<(DocId, BranchId)>> {
        let threshold = now - older_than;
        let cut = self
            .active
            .marks
            .iter()
            .filter(|(t, _)| *t <= threshold)
            .map(|(_, n)| *n)
            .max();
        let idle: Vec<(DocId, BranchId)> = match cut {
            Some(n) => self
                .active
                .docs
                .iter()
                .filter(|(_, l)| l.used < n)
                .map(|(k, _)| *k)
                .collect(),
            None => Vec::new(),
        };
        for (d, b) in &idle {
            self.park(*d, *b)?;
        }
        // a later call's cut is at least this one: the older marks are no longer needed
        self.active
            .marks
            .retain(|(t, n)| *t > threshold || Some(*n) == cut);
        self.active.uses += 1;
        let n = self.active.uses;
        self.active.marks.push((now, n));
        Ok(idle)
    }

    /// The documents active now.
    pub fn active_docs(&self) -> Vec<(DocId, BranchId)> {
        let mut v: Vec<_> = self.active.docs.keys().copied().collect();
        v.sort();
        v
    }

    /// Write every active document's snapshot (the hub stops).
    pub fn close(&mut self) -> Result<()> {
        for (d, b) in self.active_docs() {
            self.snapshot(d, b)?;
        }
        Ok(())
    }

    /// DOC on BRANCH's current snapshot, as `doc_snapshot` (replacing the last).
    pub(crate) fn snapshot(&mut self, doc: DocId, branch: BranchId) -> Result<()> {
        self.save(doc, branch)?;
        let Some(l) = self.active.docs.get_mut(&(doc, branch)) else {
            return Ok(());
        };
        let bytes = l.doc.export(ExportMode::Snapshot).map_err(loro)?;
        let upto: i64 = self.conn.query_row(
            "select coalesce(max(seq), 0) from doc_update where doc = ?1 and branch = ?2",
            params![doc.0, branch.0],
            |r| r.get(0),
        )?;
        self.conn.execute(
            "insert or replace into doc_snapshot (doc, branch, upto_seq, bytes) values (?1, ?2, ?3, ?4)",
            params![doc.0, branch.0, upto, bytes],
        )?;
        l.tail = 0;
        Ok(())
    }

    /// DOC on BRANCH's operations not stored yet, as one `doc_update` row; the snapshot follows a long tail.
    pub(crate) fn save(&mut self, doc: DocId, branch: BranchId) -> Result<()> {
        let Some(l) = self.active.docs.get_mut(&(doc, branch)) else {
            return Ok(());
        };
        if l.doc.oplog_vv() == l.saved {
            return Ok(());
        }
        let bytes = l.doc.export(ExportMode::updates(&l.saved)).map_err(loro)?;
        crate::store::put_update(&self.conn, doc, branch, &bytes)?;
        l.saved = l.doc.oplog_vv();
        l.tail += 1;
        if l.tail >= SNAPSHOT_TAIL {
            self.snapshot(doc, branch)?;
        }
        Ok(())
    }

    /// The operations not stored yet of DOC on BRANCH, for a record that writes them in its own transaction; the
    /// caller marks them stored with [`History::saved`] once that commits.
    pub(crate) fn unsaved(&self, doc: DocId, branch: BranchId) -> Result<Option<Vec<u8>>> {
        let Some(l) = self.active.docs.get(&(doc, branch)) else {
            return Ok(None);
        };
        if l.doc.oplog_vv() == l.saved {
            return Ok(None);
        }
        Ok(Some(
            l.doc.export(ExportMode::updates(&l.saved)).map_err(loro)?,
        ))
    }

    pub(crate) fn saved(&mut self, doc: DocId, branch: BranchId) {
        if let Some(l) = self.active.docs.get_mut(&(doc, branch)) {
            l.saved = l.doc.oplog_vv();
            l.tail += 1;
        }
    }

    /// DOC on BRANCH's document in memory (loaded from its rows when it is not).
    pub(crate) fn live(&mut self, doc: DocId, branch: BranchId) -> Result<&LoroDoc> {
        if !self.load(doc, branch)? {
            return Err(Error::NotFound(format!(
                "document {} on branch {}",
                doc.0, branch.0
            )));
        }
        self.touch(doc, branch);
        Ok(&self.active.docs[&(doc, branch)].doc)
    }

    /// Drop DOC on BRANCH from memory without storing it (its rows are the truth again).
    pub(crate) fn forget(&mut self, doc: DocId, branch: BranchId) {
        self.active.docs.remove(&(doc, branch));
    }

    /// DOC on BRANCH's version now.
    pub fn frontier(&mut self, doc: DocId, branch: BranchId) -> Result<Frontier> {
        Ok(Frontier(self.live(doc, branch)?.oplog_frontiers().encode()))
    }

    /// DOC on BRANCH's text now.
    pub fn text(&mut self, doc: DocId, branch: BranchId) -> Result<String> {
        Ok(self.live(doc, branch)?.get_text(TEXT).to_string())
    }
}

impl ActiveDoc<'_> {
    fn live(&self) -> &Live {
        &self.h.active.docs[&self.key]
    }

    /// Apply CH as PEER's operations, stored at once; the element ids they made (one span, or none for an empty
    /// change).
    pub fn apply(&mut self, peer: PeerId, ch: &Change) -> Result<Vec<Span>> {
        let d = &self.live().doc;
        let t = d.get_text(TEXT);
        let len = t.len_unicode();
        if ch.start > len || ch.old_len > len - ch.start {
            return Err(Error::Refused(format!(
                "a change at {} of {} characters in a text of {len}",
                ch.start, ch.old_len
            )));
        }
        d.commit();
        d.set_peer_id(peer.0).map_err(loro)?;
        let before = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
        if ch.old_len > 0 {
            t.delete(ch.start, ch.old_len).map_err(loro)?;
        }
        if !ch.inserted.is_empty() {
            t.insert(ch.start, &ch.inserted).map_err(loro)?;
        }
        d.commit();
        let after = d.oplog_vv().get(&peer.0).copied().unwrap_or(0);
        let (doc, branch) = self.key;
        self.h.save(doc, branch)?;
        self.h.touch(doc, branch);
        Ok(if after > before {
            vec![Span {
                peer,
                start: before as u32,
                end: after as u32,
            }]
        } else {
            Vec::new()
        })
    }

    /// The document's text.
    pub fn text(&self) -> String {
        self.live().doc.get_text(TEXT).to_string()
    }

    /// The document's version.
    pub fn frontier(&self) -> Frontier {
        Frontier(self.live().doc.oplog_frontiers().encode())
    }

    /// The document and branch.
    pub fn key(&self) -> (DocId, BranchId) {
        self.key
    }
}
