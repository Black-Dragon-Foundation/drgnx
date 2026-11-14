//! Size, expiry and compaction.  The history is capped ([`DEFAULT_CAP`], 2 GiB per project).  Branches that are set
//! aside (an undone set, a frozen worktree, a dropped fork) expire after [`EXPIRY_SECS`] (90 days) unless pinned.  Over the cap,
//! each document is cut shallow at the oldest live reference: an anchor, or another branch of the document (live,
//! frozen, or undone) that has not expired.  A record at or before the cut can no longer be reverted, and the revert
//! says so.  Nothing here reads a clock: `now` is a parameter.

use crate::store::{History, Kind, Record, put_op_tx, put_update};
use crate::{BranchId, DocId, Error, Frontier, OpId, PeerId, Result, loro};
use ::loro::{ExportMode, Frontiers};
use rusqlite::OptionalExtension;
use std::collections::HashMap;

/// The cap on `history.db` per project, in bytes.
pub const DEFAULT_CAP: u64 = 2 << 30;

/// How long a set-aside branch lives, in seconds.
pub const EXPIRY_SECS: f64 = 90.0 * 86_400.0;

/// What keeps `history.db` big.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PinKind {
    /// A branch the user pinned.
    Pinned,
    /// A branch a roll back set aside, until it expires.
    Undone,
    /// A frozen worktree's branch, until it expires.
    Frozen,
    /// The anchors of one owner (they hold the history from their record on).
    Anchors,
}

/// One thing that pins size: its kind, its name, and the bytes of the documents it holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pin {
    pub kind: PinKind,
    pub name: String,
    pub bytes: u64,
}

/// What a compaction did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Compacted {
    /// The documents (per branch) cut.
    pub cuts: usize,
    pub before: u64,
    pub after: u64,
}

impl History {
    /// `history.db`'s size in bytes (pages in use, the write-ahead log included).
    pub fn size(&self) -> Result<u64> {
        let pages: i64 = self
            .conn
            .pragma_query_value(None, "page_count", |r| r.get(0))?;
        let page: i64 = self
            .conn
            .pragma_query_value(None, "page_size", |r| r.get(0))?;
        Ok((pages * page) as u64)
    }

    /// Pin BRANCH (it never expires) or let it go.
    pub fn pin(&mut self, branch: BranchId, pinned: bool) -> Result<()> {
        let n = self.conn.execute(
            "update branch set pinned = ?2 where id = ?1",
            rusqlite::params![branch.0, pinned],
        )?;
        if n == 0 {
            return Err(Error::NotFound(format!("branch {}", branch.0)));
        }
        Ok(())
    }

    /// BRANCH (a worktree that went away, a fork dropped) starts its 90 days at AT.
    pub fn freeze(&mut self, branch: BranchId, at: f64) -> Result<()> {
        let n = self.conn.execute(
            "update branch set frozen_at = ?2 where id = ?1",
            rusqlite::params![branch.0, at],
        )?;
        if n == 0 {
            return Err(Error::NotFound(format!("branch {}", branch.0)));
        }
        Ok(())
    }

    /// BRANCH's worktree is the folder ROOT.  The first folder named stays.
    pub fn set_root(&mut self, branch: BranchId, root: &str) -> Result<()> {
        self.conn.execute(
            "update branch set root = ?2 where id = ?1 and root is null",
            rusqlite::params![branch.0, root],
        )?;
        Ok(())
    }

    /// The worktree branches not frozen yet, each with the folder it was made for (those never told one are left out).
    pub fn roots(&self) -> Result<Vec<(BranchId, String)>> {
        let mut st = self.conn.prepare(
            "select id, root from branch where kind = 'wt' and root is not null and frozen_at is null order by id",
        )?;
        let rows = st
            .query_map([], |r| Ok((BranchId(r.get(0)?), r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Remove the undone branches, frozen worktrees and dropped forks set aside 90 days or more before NOW, unless
    /// pinned, with their documents and anchors.  The branches removed.
    pub fn expire(&mut self, now: f64) -> Result<Vec<BranchId>> {
        let gone: Vec<BranchId> = {
            let mut st = self.conn.prepare(
                "select id from branch where frozen_at is not null and frozen_at <= ?1 and pinned = 0 \
                 and kind in ('undone', 'wt', 'fork') order by id",
            )?;
            st.query_map([now - EXPIRY_SECS], |r| Ok(BranchId(r.get(0)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        if gone.is_empty() {
            return Ok(gone);
        }
        let tx = self.conn.transaction()?;
        for b in &gone {
            for sql in [
                "delete from anchor where branch = ?1",
                "delete from doc_cut where branch = ?1",
                "delete from doc_update where branch = ?1",
                "delete from doc_snapshot where branch = ?1",
                "delete from preview where branch = ?1",
                "update peer set branch = null where branch = ?1",
                "delete from branch where id = ?1",
            ] {
                tx.execute(sql, [b.0])?;
            }
        }
        tx.commit()?;
        let active = self.active_docs();
        for (d, b) in active {
            if gone.contains(&b) {
                self.forget(d, b);
            }
        }
        self.conn.execute_batch("vacuum")?;
        Ok(gone)
    }

    /// Where compaction cut DOC on BRANCH: records up to and including this one are past it.
    pub fn cut(&self, doc: DocId, branch: BranchId) -> Result<Option<OpId>> {
        Ok(self
            .conn
            .query_row(
                "select op from doc_cut where doc = ?1 and branch = ?2",
                [doc.0, branch.0],
                |r| Ok(OpId(r.get(0)?)),
            )
            .optional()?)
    }

    /// Refuse a revert of a SCOPE record on BRANCH that is at or before a cut.
    pub(crate) fn refuse_past_cut(&self, branch: BranchId, scope: &[OpId]) -> Result<()> {
        for id in scope {
            for (doc, _) in self.op(*id)?.spans {
                if let Some(c) = self.cut(doc, branch)?
                    && *id <= c
                {
                    return Err(Error::Refused(format!(
                        "{} was compacted: its history up to record {} is gone, so record {} cannot be reverted",
                        self.path_of(doc)?,
                        c.0,
                        id.0
                    )));
                }
            }
        }
        Ok(())
    }

    /// What pins size, the biggest first: pinned and set-aside branches with the bytes of their documents, and each
    /// owner's anchors.
    pub fn pins(&self) -> Result<Vec<Pin>> {
        let mut out = Vec::new();
        let mut st = self.conn.prepare(
            "select b.name, b.kind, b.pinned, b.frozen_at is not null, \
             (select coalesce(sum(length(bytes)), 0) from doc_update where branch = b.id) \
             + (select coalesce(sum(length(bytes)), 0) from doc_snapshot where branch = b.id) \
             from branch b order by b.id",
        )?;
        let rows = st
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, bool>(3)?,
                    r.get::<_, i64>(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        for (name, kind, pinned, frozen, bytes) in rows {
            let kind = if pinned {
                PinKind::Pinned
            } else if kind == "undone" {
                PinKind::Undone
            } else if frozen {
                PinKind::Frozen
            } else {
                continue;
            };
            out.push(Pin {
                kind,
                name,
                bytes: bytes as u64,
            });
        }
        let mut st = self
            .conn
            .prepare("select owner, count(*) from anchor group by owner order by owner")?;
        let anchors = st
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        for (owner, n) in anchors {
            out.push(Pin {
                kind: PinKind::Anchors,
                name: format!("{owner} ({n} anchors)"),
                bytes: 0,
            });
        }
        out.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.name.cmp(&b.name)));
        Ok(out)
    }

    /// When the history is over CAP ([`DEFAULT_CAP`]; under it nothing is done), cut every document shallow at the
    /// oldest live reference (an anchor, or another branch of the document that has not expired: live, frozen or
    /// undone), or just before its newest record when nothing pins it.  A `compact` record by AUTHOR at NOW; the
    /// records stay.
    pub fn compact(&mut self, cap: u64, author: PeerId, now: f64) -> Result<Compacted> {
        let before = self.size()?;
        let nothing = Compacted {
            cuts: 0,
            before,
            after: before,
        };
        if before <= cap {
            return Ok(nothing);
        }
        let pairs: Vec<(DocId, BranchId)> = {
            let mut st = self
                .conn
                .prepare("select distinct doc, branch from doc_update order by doc, branch")?;
            st.query_map([], |r| Ok((DocId(r.get(0)?), BranchId(r.get(1)?))))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        type View = Vec<(DocId, BranchId, Frontier)>;
        let ops: Vec<(OpId, View)> = {
            let mut st = self
                .conn
                .prepare("select id, view_blob from op order by id")?;
            let rows = st
                .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            let mut v = Vec::new();
            for (id, blob) in rows {
                v.push((OpId(id), crate::store::decode_view(&blob)?));
            }
            v
        };
        let pair_map = |sql: &str| -> Result<HashMap<(i64, i64), i64>> {
            let mut st = self.conn.prepare(sql)?;
            let rows = st
                .query_map([], |r| Ok(((r.get(0)?, r.get(1)?), r.get(2)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            Ok(rows.into_iter().collect())
        };
        // an anchor needs the history from its record on (0: from before any record, so no cut at all)
        let limits = pair_map("select doc, branch, min(op) from anchor group by doc, branch")?;
        let done = pair_map("select doc, branch, op from doc_cut")?;
        let names: HashMap<i64, String> = {
            let mut st = self.conn.prepare("select id, name from branch")?;
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<std::result::Result<_, _>>()?
        };
        let pair_list = pairs.clone();
        let mut cuts = Vec::new();
        for (doc, b) in pairs {
            let list: Vec<(OpId, &Frontier)> = ops
                .iter()
                .filter_map(|(id, v)| {
                    v.iter()
                        .find(|(d, bb, _)| *d == doc && *bb == b)
                        .map(|(_, _, f)| (*id, f))
                })
                .collect();
            // the oldest live reference: an anchor's record, or another branch of the document (live, frozen or
            // undone, none of them expired) from its first record on, or from its roll back's record
            let mut limit = limits.get(&(doc.0, b.0)).copied().unwrap_or(i64::MAX);
            for (d2, c) in &pair_list {
                if *d2 != doc || *c == b {
                    continue;
                }
                let first = ops
                    .iter()
                    .find(|(_, v)| v.iter().any(|(d, bb, _)| *d == doc && bb == c))
                    .map(|(id, _)| id.0);
                let rolled_back = names
                    .get(&c.0)
                    .and_then(|n| n.strip_prefix("undone/"))
                    .and_then(|n| n.parse::<i64>().ok());
                limit = limit.min(first.or(rolled_back).unwrap_or(0));
            }
            let past = done.get(&(doc.0, b.0)).copied().unwrap_or(0);
            // the newest record stays revertable
            let Some((op, f)) = list[..list.len().saturating_sub(1)]
                .iter()
                .rev()
                .find(|(id, _)| id.0 <= limit && id.0 > past)
            else {
                continue;
            };
            let at = Frontiers::decode(&f.0).map_err(loro)?;
            let bytes = self
                .live(doc, b)?
                .export(ExportMode::shallow_snapshot(&at))
                .map_err(loro)?;
            cuts.push((doc, b, *op, bytes));
        }
        if cuts.is_empty() {
            return Ok(nothing);
        }
        let view = self.view()?;
        let tx = self.conn.transaction()?;
        for (doc, b, op, bytes) in &cuts {
            tx.execute(
                "delete from doc_update where doc = ?1 and branch = ?2",
                [doc.0, b.0],
            )?;
            tx.execute(
                "delete from doc_snapshot where doc = ?1 and branch = ?2",
                [doc.0, b.0],
            )?;
            put_update(&tx, *doc, *b, bytes)?;
            tx.execute(
                "insert or replace into doc_cut (doc, branch, op) values (?1, ?2, ?3)",
                [doc.0, b.0, op.0],
            )?;
        }
        put_op_tx(
            &tx,
            &Record {
                kind: Kind::Compact,
                author,
                cause: Default::default(),
                spans: Vec::new(),
                parents: Vec::new(),
                git: None,
                summary: format!("compacted {} documents", cuts.len()),
                at: now,
            },
            &view,
            &[],
        )?;
        tx.commit()?;
        for (doc, b, _, _) in &cuts {
            self.forget(*doc, *b);
        }
        self.conn.execute_batch("vacuum")?;
        Ok(Compacted {
            cuts: cuts.len(),
            before,
            after: self.size()?,
        })
    }
}
