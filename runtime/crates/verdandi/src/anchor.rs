//! Anchors, who wrote this, and the hunks view.  An **anchor** is a Loro cursor on an element id plus the version it was
//! made at, so it follows every edit (and a reload from the rows), says when its text was deleted, and can show the text
//! as it was written.  **Blame** reads the element ids of a range and the record each was made in.  **Hunks** are the
//! changes of a branch since a record, as `git diff --unified=0` numbers them: the review view and the edits ledger
//! read them from here instead of keeping lists of their own.

use crate::apply::SEED_BIT;
use crate::docs::TEXT;
use crate::revert::char_ids;
use crate::store::{History, decode_view};
use crate::{BranchId, DocId, Error, OpId, PeerId, Result, loro};
use ::loro::cursor::{Cursor, Side as LoroSide};
use ::loro::{Frontiers, LoroDoc};
use rusqlite::{OptionalExtension, params};
use std::collections::HashSet;
use std::ops::Range;

/// An anchor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AnchorId(pub i64);

/// Which neighbour of the position the anchor holds on to: the character after it (`Right`) or before it (`Left`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// Where to look an anchor up: in the text now, or in the text as it was when the anchor was made.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum When {
    Now,
    Then,
}

/// Where an anchor is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    /// A character offset.  For a deleted anchor, where its text was.
    pub pos: usize,
    /// The text the anchor held on to is gone.
    pub deleted: bool,
    /// The line it was on when it was made: for [`When::Then`], and for a deleted anchor.
    pub text_then: Option<String>,
}

/// A range of one author's text and the record it was made in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blame {
    pub range: Range<usize>,
    pub peer: PeerId,
    pub op: OpId,
}

/// One hunk, with git's numbers (`@@ -old_start,old_count +new_start,new_count @@`, unified 0).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineHunk {
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
}

/// A file's hunks since a record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileHunks {
    pub doc: DocId,
    pub path: String,
    pub hunks: Vec<LineHunk>,
}

/// The line of TEXT that holds character POS.
fn line_at(text: &str, pos: usize) -> String {
    let ch: Vec<char> = text.chars().collect();
    let p = pos.min(ch.len());
    let start = ch[..p]
        .iter()
        .rposition(|c| *c == '\n')
        .map_or(0, |i| i + 1);
    let end = ch[p..]
        .iter()
        .position(|c| *c == '\n')
        .map_or(ch.len(), |i| p + i);
    ch[start..end].iter().collect()
}

impl History {
    /// An anchor at character POS of DOC on BRANCH for OWNER (the review, the ledger, a gutter).
    pub fn anchor(
        &mut self,
        doc: DocId,
        branch: BranchId,
        pos: usize,
        side: Side,
        owner: &str,
    ) -> Result<AnchorId> {
        let d = self.live(doc, branch)?.clone();
        let t = d.get_text(TEXT);
        if pos > t.len_unicode() {
            return Err(Error::Refused(format!(
                "position {pos} in a text of {}",
                t.len_unicode()
            )));
        }
        let cursor = t
            .get_cursor(
                pos,
                match side {
                    Side::Left => LoroSide::Left,
                    Side::Right => LoroSide::Right,
                },
            )
            .ok_or_else(|| Error::Refused("an empty text holds no anchor".into()))?;
        let op: i64 = self
            .conn
            .query_row("select coalesce(max(id), 0) from op", [], |r| r.get(0))?;
        self.conn.execute(
            "insert into anchor (doc, branch, cursor_blob, frontier_blob, op, owner) \
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                doc.0,
                branch.0,
                cursor.encode(),
                d.oplog_frontiers().encode(),
                op,
                owner
            ],
        )?;
        Ok(AnchorId(self.conn.last_insert_rowid()))
    }

    /// Where ANCHOR is WHEN.
    pub fn resolve(&mut self, anchor: AnchorId, when: When) -> Result<Resolved> {
        let (doc, branch, cursor, frontier): (i64, i64, Vec<u8>, Vec<u8>) = self
            .conn
            .query_row(
                "select doc, branch, cursor_blob, frontier_blob from anchor where id = ?1",
                [anchor.0],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("anchor {}", anchor.0)))?;
        let (doc, branch) = (DocId(doc), BranchId(branch));
        let c = Cursor::decode(&cursor).map_err(loro)?;
        let d = self.live(doc, branch)?.clone();
        let then = |d: &LoroDoc| -> Result<(usize, String)> {
            let f = Frontiers::decode(&frontier).map_err(loro)?;
            let old = crate::docs::version_of(d, &f)?;
            let pos = old.get_cursor_pos(&c).map_err(loro)?.current.pos;
            Ok((pos, line_at(&old.get_text(TEXT).to_string(), pos)))
        };
        match when {
            When::Then => {
                let (pos, line) = then(&d)?;
                Ok(Resolved {
                    pos,
                    deleted: false,
                    text_then: Some(line),
                })
            }
            When::Now => {
                let pos = d.get_cursor_pos(&c).map_err(loro)?.current.pos;
                let alive: HashSet<_> = char_ids(&d.get_text(TEXT)).into_iter().collect();
                let deleted = c.id.is_some_and(|id| !alive.contains(&id));
                Ok(Resolved {
                    pos,
                    deleted,
                    text_then: if deleted { Some(then(&d)?.1) } else { None },
                })
            }
        }
    }

    /// Who wrote each part of RANGE of DOC on BRANCH, and in which record.  Text of the base (no author) and typing no
    /// record holds yet are left out.
    pub fn blame(
        &mut self,
        doc: DocId,
        branch: BranchId,
        range: Range<usize>,
    ) -> Result<Vec<Blame>> {
        let ids = char_ids(&self.live(doc, branch)?.get_text(TEXT));
        let index = self.op_index()?;
        let mut out: Vec<Blame> = Vec::new();
        for (i, id) in ids.iter().enumerate().take(range.end).skip(range.start) {
            if id.peer & SEED_BIT != 0 {
                continue;
            }
            let Some(op) = index.find(doc, *id) else {
                continue;
            };
            let peer = PeerId(id.peer);
            match out.last_mut() {
                Some(l) if l.range.end == i && l.peer == peer && l.op == op => l.range.end = i + 1,
                _ => out.push(Blame {
                    range: i..i + 1,
                    peer,
                    op,
                }),
            }
        }
        Ok(out)
    }

    /// The text of DOC on BRANCH as it was after record SINCE: that record's version when it holds the document, else
    /// the newest earlier record's, else the document as first stored.
    pub fn text_after(&mut self, doc: DocId, branch: BranchId, since: OpId) -> Result<String> {
        let mut st = self
            .conn
            .prepare("select view_blob from op where id <= ?1 order by id desc")?;
        let views = st
            .query_map([since.0], |r| r.get::<_, Vec<u8>>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(st);
        for v in views {
            if let Some((_, _, f)) = decode_view(&v)?
                .into_iter()
                .find(|(d, b, _)| *d == doc && *b == branch)
            {
                let live = self.live(doc, branch)?;
                let f = Frontiers::decode(&f.0).map_err(loro)?;
                return Ok(crate::docs::version_of(live, &f)?
                    .get_text(TEXT)
                    .to_string());
            }
        }
        let seed: Vec<u8> = self.conn.query_row(
            "select bytes from doc_update where doc = ?1 and branch = ?2 and seq = 1",
            params![doc.0, branch.0],
            |r| r.get(0),
        )?;
        let d = LoroDoc::new();
        d.import(&seed).map_err(loro)?;
        Ok(d.get_text(TEXT).to_string())
    }

    /// What changed on BRANCH since record SINCE: per file, the hunks from its text then to its text now, numbered as
    /// `git diff --unified=0` numbers them.  Files that did not change are left out.  Record 0 is before every record:
    /// each document as first stored.
    pub fn hunks(&mut self, branch: BranchId, since: OpId) -> Result<Vec<FileHunks>> {
        if since.0 != 0 {
            self.op(since)?;
        }
        let mut st = self
            .conn
            .prepare("select distinct doc from doc_update where branch = ?1 order by doc")?;
        let docs = st
            .query_map([branch.0], |r| Ok(DocId(r.get(0)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(st);
        let mut out = Vec::new();
        for doc in docs {
            let old = self.text_after(doc, branch, since)?;
            let now = self.text(doc, branch)?;
            let hunks: Vec<LineHunk> = crate::threeway::diff_hunks(&old, &now)?
                .into_iter()
                .map(|(old_start, old_count, new_start, new_count)| LineHunk {
                    old_start,
                    old_count,
                    new_start,
                    new_count,
                })
                .collect();
            if !hunks.is_empty() {
                out.push(FileHunks {
                    path: self.path_of(doc)?,
                    doc,
                    hunks,
                });
            }
        }
        Ok(out)
    }
}
