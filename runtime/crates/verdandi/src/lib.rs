//! verdandi: the edit history (docs/develop/history.md).
//!
//! Every change to a project's text, by anyone, as operations on one Loro document per tracked file, in
//! `history.db` (one per project; the hub is its only writer).  No hub, editor or Urdr type appears here.
//!
//! - [`store`]: `history.db` on urdr's store (migrations as data in `schema`), the ids, the record rows.
//! - [`docs`]: a document per file, a branch per worktree or fork, a forked document in memory per active branch.
//! - [`text`]: what a document holds: UTF-8 with LF, or the snapshot class.
//! - [`log`]: the operation log's records, their causes, and the settle rule that groups typing into them.
//! - [`revert`]: span revert on element ids, the overlaps a user's later edits make, the 3-way check.

pub mod apply;
pub mod docs;
pub mod log;
mod merge;
pub mod revert;
#[cfg(test)]
mod revert_props;
mod schema;
pub mod store;
pub mod text;
mod threeway;

pub use apply::{FileDiff, Hunk, HunkRef};
pub use docs::{ActiveDoc, Change};
pub use log::{FlushReason, Settler};
pub use revert::{FilePreview, Mode, Overlap, OverlapChoice, RevertPreview};
pub use store::{BranchKind, Cause, DocUpdate, History, Kind, OpRecord, Record};
pub use text::{Coding, NotText};

use std::fmt;
use std::path::Path;

/// The schema `history.db` is at once opened.
pub const SCHEMA_VERSION: u32 = schema::MIGRATIONS[schema::MIGRATIONS.len() - 1].0;

/// A tracked file's document.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DocId(pub i64);

/// A record of the operation log.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct OpId(pub i64);

/// A Loro peer: one author on one branch (the user's session, an agent run, an external source).  Peer ids come from
/// [`History::peer`], so two branches never write under one id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PeerId(pub u64);

/// A branch: a worktree's, a fork's or an undone one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BranchId(pub i64);

/// A worktree, by the hex of its path and git's common folder.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WorktreeId(pub String);

impl WorktreeId {
    /// The id of the worktree at PATH whose git common folder is COMMON.
    pub fn of(path: &Path, common: &Path) -> WorktreeId {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(path.as_os_str().as_encoded_bytes());
        h.update([0]);
        h.update(common.as_os_str().as_encoded_bytes());
        WorktreeId(
            h.finalize()
                .iter()
                .take(16)
                .map(|b| format!("{b:02x}"))
                .collect(),
        )
    }
}

/// The element ids a record's operations created or deleted in one document: PEER's counters START up to END.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Span {
    pub peer: PeerId,
    pub start: u32,
    pub end: u32,
}

/// A document's version: encoded Loro frontiers.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Frontier(pub Vec<u8>);

/// What went wrong.
#[derive(Debug)]
pub enum Error {
    /// `history.db` could not be opened or moved to this schema.
    Store(urdr::Error),
    Sql(rusqlite::Error),
    /// Loro refused an operation, an import or an export.
    Loro(String),
    /// No such document, branch, record or preview.
    NotFound(String),
    /// The request cannot be done as asked (a stale preview, a revert with no target, …).
    Refused(String),
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Store(e) => write!(f, "history.db: {e}"),
            Error::Sql(e) => write!(f, "history.db: {e}"),
            Error::Loro(e) => write!(f, "document: {e}"),
            Error::NotFound(e) => write!(f, "not found: {e}"),
            Error::Refused(e) => write!(f, "refused: {e}"),
            Error::Io(e) => write!(f, "io: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Error {
        Error::Sql(e)
    }
}

impl From<urdr::Error> for Error {
    fn from(e: urdr::Error) -> Error {
        Error::Store(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Error {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// Loro's error as ours.
pub(crate) fn loro(e: impl fmt::Display) -> Error {
    Error::Loro(e.to_string())
}

/// Seconds since the epoch, for the rows' own stamps (a document's creation, a preview's).  Records and the settle
/// rule take the caller's time instead.
pub(crate) fn wall_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}
