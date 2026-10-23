//! The store's one writer (Task 1; storage §7): one thread owns the only write connection (WAL, `synchronous=FULL`,
//! `busy_timeout` 5 s, `secure_delete=ON`). Requests arrive over a bounded channel (256) and are group-committed: up
//! to `max_batch` requests, or what arrives within `max_wait` of the first, in one `BEGIN IMMEDIATE … COMMIT`, each
//! in its own savepoint. No answer leaves before `COMMIT` returns. Maintenance runs between batches, outside any
//! transaction.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 1 removes this line.

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use rusqlite::Connection;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use super::guard::Guard;
use super::tx::{Tx, TxMeta};

/// How the writer runs.
#[derive(Clone)]
pub struct WriterOpts {
    /// At most this many requests in one transaction (256).
    pub max_batch: usize,
    /// A batch waits at most this long after its first request (10 ms).
    pub max_wait: Duration,
    /// `synchronous=FULL` (else `NORMAL`).
    pub synchronous_full: bool,
    /// The caller's class rules, handed to every [`Tx`] ([`super::guard`]; norn registers drgnx's).
    pub guard: Arc<Guard>,
}

impl Default for WriterOpts {
    fn default() -> Self {
        WriterOpts {
            max_batch: 256,
            max_wait: Duration::from_millis(10),
            synchronous_full: true,
            guard: Arc::new(Guard::default()),
        }
    }
}

/// What the caller's opening rule decided (call 18: `Failed` is never re-tried in this process).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OpenOutcome {
    Ready { schema: u32 },
    /// Re-tried at each [`WriterHandle::tick`]; writes answer [`WriteError::NotReady`] with the text.
    NotReady(String),
    /// A newer schema: writes answer [`WriteError::ReadOnly`].
    ReadOnly { schema: u32 },
    /// Never re-tried until the process restarts; writes answer [`WriteError::NotReady`] with the reason.
    Failed(String),
}

/// The caller's opening rule, so the generic writer knows no schema (norn's is `migrate7::open_rule`). It runs on
/// the writer thread with the write connection and the file's path, before the first request, again at each tick
/// while `NotReady`, and again after the file at the path was replaced (`(dev, inode)` changed). The writer makes a
/// missing file (0600, WAL, the options' `synchronous`, `secure_delete=ON`) before it calls the rule, so the rule sees
/// an empty database for a new file.
pub type OpenRule = Arc<dyn Fn(&mut Connection, &Path) -> OpenOutcome + Send + Sync>;

/// Why a write was not done.
#[derive(Clone, Debug, PartialEq)]
pub enum WriteError {
    /// The closure's own refusal, with its text (a rule, a guard).
    Refused(String),
    /// An optimistic-concurrency conflict, as the caller shapes it.
    Conflict(serde_json::Value),
    /// The batch's `COMMIT` failed: nothing of it was written; a retry may succeed.
    Retryable(String),
    /// The file is a newer schema: readable, never written.
    ReadOnly { schema: u32 },
    /// The store is not open (the rule's text), or its opening failed for good (the reason).
    NotReady(String),
    /// The writer thread is gone.
    Closed,
    Sql(String),
}

impl fmt::Display for WriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WriteError::Refused(text) | WriteError::NotReady(text) => f.write_str(text),
            WriteError::Conflict(v) => write!(f, "conflict: {v}"),
            WriteError::Retryable(text) => write!(f, "the write was not committed ({text}); retry"),
            WriteError::ReadOnly { schema } => {
                write!(f, "the store is schema {schema}, newer than this drgnx: read-only")
            }
            WriteError::Closed => f.write_str("the store is closed"),
            WriteError::Sql(text) => write!(f, "sql: {text}"),
        }
    }
}

impl std::error::Error for WriteError {}

impl From<rusqlite::Error> for WriteError {
    fn from(e: rusqlite::Error) -> Self {
        WriteError::Sql(e.to_string())
    }
}

/// A committed write's answer: its tx, the closure's value, and whether it was replayed from a stored answer.
#[derive(Clone, Debug, PartialEq)]
pub struct Written<R> {
    pub tx: i64,
    pub value: R,
    pub replayed: bool,
}

/// Work the writer thread runs between batches, outside a transaction (never a second write connection).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Maintenance {
    /// `VACUUM`, then `wal_checkpoint(TRUNCATE)` (Task 8's `scrub`).
    Scrub,
    /// `wal_checkpoint(TRUNCATE)` only.
    Checkpoint,
}

/// What kept a `TRUNCATE` checkpoint from completing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Blocker {
    Readers,
    Writer,
}

/// What a [`Maintenance`] run did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubReport {
    pub vacuumed: bool,
    pub wal_truncated: bool,
    pub blocked_by: Option<Blocker>,
}

/// The writer as `status.store` shows it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WriterStatus {
    pub open: bool,
    /// `0` while nothing is open.
    pub schema: u32,
    pub batches: u64,
    pub writes: u64,
    pub replays: u64,
    pub last_commit_ms: Option<f64>,
    /// The opening rule's last answer (`failed` and `not_ready` texts come from here).
    pub last_open: Option<OpenOutcome>,
}

/// Owns the writer thread; [`Writer::shutdown`] (or drop) stops it, and pending requests answer [`WriteError::Closed`].
pub struct Writer {
    thread: Option<std::thread::JoinHandle<()>>,
}

/// A cheap, cloneable way to send writes to the writer thread.
#[derive(Clone)]
pub struct WriterHandle {
    path: Arc<PathBuf>,
}

impl Writer {
    /// Start the writer thread on PATH; it opens the file and runs OPEN before the first request.
    pub fn spawn(
        path: impl Into<PathBuf>,
        opts: WriterOpts,
        open: OpenRule,
    ) -> crate::Result<(Writer, WriterHandle)> {
        todo!("Task 1")
    }

    /// Stop the thread and wait for it, which closes the connection. Blocking: not for an async worker.
    pub fn shutdown(self) {
        todo!("Task 1")
    }
}

impl WriterHandle {
    /// Run F in its own savepoint of the next batch, after the `tx` row from META. With `meta.req` set, a repeat of
    /// `(actor, req)` answers the first answer (`replayed: true`) and runs nothing. Never runs SQLite on the caller's
    /// thread; never answers before `COMMIT`.
    pub async fn write<R, F>(&self, meta: TxMeta, f: F) -> Result<Written<R>, WriteError>
    where
        R: Serialize + DeserializeOwned + Send + 'static,
        F: for<'t, 'c> FnOnce(&'t mut Tx<'c>) -> Result<R, WriteError> + Send + 'static,
    {
        todo!("Task 1")
    }

    /// Run M on the writer thread between batches, outside a transaction.
    pub async fn maintain(&self, m: Maintenance) -> Result<ScrubReport, WriteError> {
        todo!("Task 1")
    }

    /// The hub's schema tick: run the opening rule again while `NotReady`, and re-open when the file at the path is
    /// another file than the one opened.
    pub async fn tick(&self) {
        todo!("Task 1")
    }

    pub fn status(&self) -> WriterStatus {
        todo!("Task 1")
    }

    /// The database file the writer owns.
    pub fn path(&self) -> &Path {
        &self.path
    }
}
