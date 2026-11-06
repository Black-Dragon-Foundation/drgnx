//! `history.db` (one per project, `<dir>/history.db`, WAL, `0600`) on urdr's store: the records, their parents,
//! the documents, the branches and the peers.  A record and the document updates it carries are written in one
//! transaction, so a multi-file action is all there or not at all.

use crate::{BranchId, DocId, Error, Frontier, OpId, PeerId, Result, Span};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// A branch's kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BranchKind {
    Worktree,
    Fork,
    Undone,
}

impl BranchKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            BranchKind::Worktree => "wt",
            BranchKind::Fork => "fork",
            BranchKind::Undone => "undone",
        }
    }
}

/// What a record is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Edits,
    AgentStep,
    Decision,
    Save,
    Revert,
    Restore,
    Redo,
    Fork,
    Merge,
    Rename,
    External,
    Compact,
    Excise,
}

impl Kind {
    pub const ALL: [Kind; 13] = [
        Kind::Edits,
        Kind::AgentStep,
        Kind::Decision,
        Kind::Save,
        Kind::Revert,
        Kind::Restore,
        Kind::Redo,
        Kind::Fork,
        Kind::Merge,
        Kind::Rename,
        Kind::External,
        Kind::Compact,
        Kind::Excise,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Edits => "edits",
            Kind::AgentStep => "agent_step",
            Kind::Decision => "decision",
            Kind::Save => "save",
            Kind::Revert => "revert",
            Kind::Restore => "restore",
            Kind::Redo => "redo",
            Kind::Fork => "fork",
            Kind::Merge => "merge",
            Kind::Rename => "rename",
            Kind::External => "external",
            Kind::Compact => "compact",
            Kind::Excise => "excise",
        }
    }

    pub fn parse(s: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// A revert, a restore and a redo act on records they name: they need a parent.
    pub fn names_a_target(self) -> bool {
        matches!(self, Kind::Revert | Kind::Restore | Kind::Redo)
    }
}

/// Why a record was made: the agent conversation, message, turn and step, the Urdr decision and the task.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cause {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
}

/// A record to write.
#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    pub kind: Kind,
    pub author: PeerId,
    pub cause: Cause,
    pub spans: Vec<(DocId, Span)>,
    pub parents: Vec<OpId>,
    /// The commit this state matches, when there is one.
    pub git: Option<String>,
    /// Generated text for the timeline; never secret text.
    pub summary: String,
    /// Seconds since the epoch (the caller's clock).
    pub at: f64,
}

/// A record as it is stored.
#[derive(Clone, Debug, PartialEq)]
pub struct OpRecord {
    pub id: OpId,
    pub kind: Kind,
    pub author: PeerId,
    pub cause: Cause,
    pub spans: Vec<(DocId, Span)>,
    /// Each document's version on each branch after the action.
    pub view: Vec<(DocId, BranchId, Frontier)>,
    pub git: Option<String>,
    pub summary: String,
    pub at: f64,
    pub parents: Vec<OpId>,
}

/// A document's update on a branch, written with a record.
#[derive(Clone, Debug, PartialEq)]
pub struct DocUpdate {
    pub doc: DocId,
    pub branch: BranchId,
    pub bytes: Vec<u8>,
}

/// One project's edit history.
pub struct History {
    pub(crate) conn: rusqlite::Connection,
    pub(crate) active: crate::docs::Active,
}

impl History {
    /// `DIR/history.db`, made at the current schema or moved to it; a newer file is refused untouched.
    pub fn open(dir: &Path) -> Result<History> {
        History::open_with(dir, true)
    }

    /// [`History::open`] without a sync at each commit, for the property tests' many thousand records.
    #[cfg(test)]
    pub(crate) fn open_fast(dir: &Path) -> Result<History> {
        History::open_with(dir, false)
    }

    fn open_with(dir: &Path, synchronous_full: bool) -> Result<History> {
        std::fs::create_dir_all(dir)?;
        let conn = urdr::open_store(&urdr::StoreSpec {
            path: dir.join("history.db"),
            mode: urdr::Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full,
            },
            migrations: crate::schema::MIGRATIONS,
        })?;
        conn.pragma_update(None, "foreign_keys", "on")?;
        Ok(History {
            conn,
            active: Default::default(),
        })
    }

    /// The store's schema.
    pub fn schema(&self) -> Result<u32> {
        Ok(urdr::meta(&self.conn, "schema")?
            .and_then(|s| s.parse().ok())
            .unwrap_or(0))
    }

    /// A new peer for AUTHOR (the user's session, an agent run, `external:<source>`) writing on BRANCH: a peer id is
    /// never shared by two branches, so element ids never collide when branches merge.
    pub fn peer(&mut self, author: &serde_json::Value, branch: Option<BranchId>) -> Result<PeerId> {
        self.conn.execute(
            "insert into peer (author_json, branch) values (?1, ?2)",
            params![author.to_string(), branch.map(|b| b.0)],
        )?;
        Ok(PeerId(self.conn.last_insert_rowid() as u64))
    }

    /// The document of the file at PATH (relative to the project), made on first use.
    pub fn doc_for(&mut self, path: &str) -> Result<DocId> {
        if let Some(id) = self
            .conn
            .query_row("select id from doc where path = ?1", [path], |r| r.get(0))
            .optional()?
        {
            return Ok(DocId(id));
        }
        self.conn.execute(
            "insert into doc (path, created) values (?1, ?2)",
            params![path, crate::wall_secs()],
        )?;
        Ok(DocId(self.conn.last_insert_rowid()))
    }

    /// DOC's path.
    pub fn path_of(&self, doc: DocId) -> Result<String> {
        self.conn
            .query_row("select path from doc where id = ?1", [doc.0], |r| r.get(0))
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("document {}", doc.0)))
    }

    /// The branch NAME, made on first use with KIND and BASE_COMMIT (the commit its documents start from).
    pub fn branch(
        &mut self,
        name: &str,
        kind: BranchKind,
        base_commit: Option<&str>,
    ) -> Result<BranchId> {
        if let Some(id) = self
            .conn
            .query_row("select id from branch where name = ?1", [name], |r| {
                r.get(0)
            })
            .optional()?
        {
            return Ok(BranchId(id));
        }
        self.conn.execute(
            "insert into branch (name, kind, base_commit) values (?1, ?2, ?3)",
            params![name, kind.as_str(), base_commit],
        )?;
        Ok(BranchId(self.conn.last_insert_rowid()))
    }

    /// BRANCH's base commit.
    pub fn base_of(&self, branch: BranchId) -> Result<Option<String>> {
        self.conn
            .query_row(
                "select base_commit from branch where id = ?1",
                [branch.0],
                |r| r.get(0),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("branch {}", branch.0)))
    }

    /// The author PEER was made for.
    pub fn author_of(&self, peer: PeerId) -> Result<Option<serde_json::Value>> {
        let json: Option<String> = self
            .conn
            .query_row(
                "select author_json from peer where id = ?1",
                [peer.0 as i64],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json.and_then(|j| serde_json::from_str(&j).ok()))
    }

    /// Write record R with its VIEW and the document UPDATES it carries, in one transaction: a failure leaves no row.
    pub fn put_op(
        &mut self,
        r: &Record,
        view: &[(DocId, BranchId, Frontier)],
        updates: &[DocUpdate],
    ) -> Result<OpId> {
        let tx = self.conn.transaction()?;
        let id = put_op_tx(&tx, r, view, updates)?;
        tx.commit()?;
        Ok(id)
    }
}

/// [`History::put_op`] inside the caller's transaction TX.
pub(crate) fn put_op_tx(
    tx: &rusqlite::Connection,
    r: &Record,
    view: &[(DocId, BranchId, Frontier)],
    updates: &[DocUpdate],
) -> Result<OpId> {
    if r.kind.names_a_target() && r.parents.is_empty() {
        return Err(Error::Refused(format!(
            "a {} record names the record it acts on",
            r.kind.as_str()
        )));
    }
    tx.execute(
        "insert into op (kind, author, cause_json, spans_blob, view_blob, git, summary, at) \
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            r.kind.as_str(),
            r.author.0 as i64,
            serde_json::to_string(&r.cause).map_err(|e| Error::Refused(e.to_string()))?,
            encode_spans(&r.spans),
            encode_view(view),
            r.git,
            r.summary,
            r.at,
        ],
    )?;
    let id = tx.last_insert_rowid();
    for p in &r.parents {
        tx.execute(
            "insert into op_parent (op, parent) values (?1, ?2)",
            params![id, p.0],
        )?;
    }
    for u in updates {
        put_update(tx, u.doc, u.branch, &u.bytes)?;
    }
    Ok(OpId(id))
}

impl History {
    /// Record ID as stored.
    pub fn op(&self, id: OpId) -> Result<OpRecord> {
        let row = self
            .conn
            .query_row(
                "select kind, author, cause_json, spans_blob, view_blob, git, summary, at from op where id = ?1",
                [id.0],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, Vec<u8>>(3)?,
                        r.get::<_, Vec<u8>>(4)?,
                        r.get::<_, Option<String>>(5)?,
                        r.get::<_, String>(6)?,
                        r.get::<_, f64>(7)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("record {}", id.0)))?;
        let mut st = self
            .conn
            .prepare("select parent from op_parent where op = ?1 order by parent")?;
        let parents = st
            .query_map([id.0], |r| Ok(OpId(r.get(0)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(OpRecord {
            id,
            kind: Kind::parse(&row.0)
                .ok_or_else(|| Error::Refused(format!("unknown record kind {}", row.0)))?,
            author: PeerId(row.1 as u64),
            cause: serde_json::from_str(&row.2).unwrap_or_default(),
            spans: decode_spans(&row.3)?,
            view: decode_view(&row.4)?,
            git: row.5,
            summary: row.6,
            at: row.7,
            parents,
        })
    }

    /// How many rows TABLE has (doctor, tests).
    pub fn count(&self, table: &str) -> Result<i64> {
        const TABLES: &[&str] = &[
            "op",
            "op_parent",
            "doc",
            "doc_update",
            "doc_snapshot",
            "peer",
            "branch",
            "pending",
            "preview",
            "provenance",
            "anchor",
        ];
        if !TABLES.contains(&table) {
            return Err(Error::Refused(format!("no table {table}")));
        }
        Ok(self
            .conn
            .query_row(&format!("select count(*) from {table}"), [], |r| r.get(0))?)
    }
}

/// Append BYTES as the next update of DOC on BRANCH; its sequence number.
pub(crate) fn put_update(
    c: &rusqlite::Connection,
    doc: DocId,
    branch: BranchId,
    bytes: &[u8],
) -> Result<i64> {
    let seq: i64 = c.query_row(
        "select coalesce(max(seq), 0) + 1 from doc_update where doc = ?1 and branch = ?2",
        params![doc.0, branch.0],
        |r| r.get(0),
    )?;
    c.execute(
        "insert into doc_update (doc, branch, seq, bytes) values (?1, ?2, ?3, ?4)",
        params![doc.0, branch.0, seq, bytes],
    )?;
    Ok(seq)
}

/// Spans as 24 bytes each: doc, peer, start, end (little-endian).
pub(crate) fn encode_spans(spans: &[(DocId, Span)]) -> Vec<u8> {
    let mut out = Vec::with_capacity(spans.len() * 24);
    for (d, s) in spans {
        out.extend_from_slice(&d.0.to_le_bytes());
        out.extend_from_slice(&s.peer.0.to_le_bytes());
        out.extend_from_slice(&s.start.to_le_bytes());
        out.extend_from_slice(&s.end.to_le_bytes());
    }
    out
}

fn bad(what: &str) -> Error {
    Error::Refused(format!("history.db holds a malformed {what}"))
}

pub(crate) fn decode_spans(b: &[u8]) -> Result<Vec<(DocId, Span)>> {
    if !b.len().is_multiple_of(24) {
        return Err(bad("span list"));
    }
    Ok(b.as_chunks::<24>()
        .0
        .iter()
        .map(|c| {
            let w8 = |r: std::ops::Range<usize>| -> [u8; 8] { c[r].try_into().expect("width") };
            let w4 = |r: std::ops::Range<usize>| -> [u8; 4] { c[r].try_into().expect("width") };
            (
                DocId(i64::from_le_bytes(w8(0..8))),
                Span {
                    peer: PeerId(u64::from_le_bytes(w8(8..16))),
                    start: u32::from_le_bytes(w4(16..20)),
                    end: u32::from_le_bytes(w4(20..24)),
                },
            )
        })
        .collect())
}

/// A view as (doc, branch, length, frontier bytes) entries (little-endian).
pub(crate) fn encode_view(view: &[(DocId, BranchId, Frontier)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (d, b, f) in view {
        out.extend_from_slice(&d.0.to_le_bytes());
        out.extend_from_slice(&b.0.to_le_bytes());
        out.extend_from_slice(&(f.0.len() as u32).to_le_bytes());
        out.extend_from_slice(&f.0);
    }
    out
}

pub(crate) fn decode_view(mut b: &[u8]) -> Result<Vec<(DocId, BranchId, Frontier)>> {
    let mut out = Vec::new();
    while !b.is_empty() {
        if b.len() < 20 {
            return Err(bad("view"));
        }
        let d = i64::from_le_bytes(b[0..8].try_into().expect("width"));
        let br = i64::from_le_bytes(b[8..16].try_into().expect("width"));
        let n = u32::from_le_bytes(b[16..20].try_into().expect("width")) as usize;
        if b.len() < 20 + n {
            return Err(bad("view"));
        }
        out.push((DocId(d), BranchId(br), Frontier(b[20..20 + n].to_vec())));
        b = &b[20 + n..];
    }
    Ok(out)
}
