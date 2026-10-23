//! The store's one writer (Task 1; storage §7): one thread owns the only write connection (WAL, `synchronous=FULL`,
//! `busy_timeout` 5 s, `secure_delete=ON`). Requests arrive over a bounded channel (256) and are group-committed: up
//! to `max_batch` requests, or what arrives within `max_wait` of the first, in one `BEGIN IMMEDIATE … COMMIT`, each
//! in its own savepoint. No answer leaves before `COMMIT` returns. Maintenance runs between batches, outside any
//! transaction.

use std::fmt;
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, oneshot};

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
    Ready {
        schema: u32,
    },
    /// Re-tried at each [`WriterHandle::tick`]; writes answer [`WriteError::NotReady`] with the text.
    NotReady(String),
    /// A newer schema: writes answer [`WriteError::ReadOnly`].
    ReadOnly {
        schema: u32,
    },
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
    ReadOnly {
        schema: u32,
    },
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
                write!(
                    f,
                    "the store is schema {schema}, newer than this drgnx: read-only"
                )
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
    /// How long the last batch's `COMMIT` took, in milliseconds.
    pub last_commit_ms: Option<f64>,
    /// The opening rule's last answer (`failed` and `not_ready` texts come from here).
    pub last_open: Option<OpenOutcome>,
}

/// Owns the writer thread; [`Writer::shutdown`] (or drop) stops it, and pending requests answer [`WriteError::Closed`].
pub struct Writer {
    thread: Option<std::thread::JoinHandle<()>>,
    stop: mpsc::Sender<Msg>,
}

/// A cheap, cloneable way to send writes to the writer thread.
#[derive(Clone)]
pub struct WriterHandle {
    path: Arc<PathBuf>,
    tx: mpsc::Sender<Msg>,
    /// The channel's bound: a write holds a permit until the writer thread takes it off the channel.
    permits: Arc<Semaphore>,
    status: Arc<Mutex<WriterStatus>>,
}

/// A clock answering unix seconds.
pub type Clock = Arc<dyn Fn() -> f64 + Send + Sync>;

/// Test seams of the writer thread ([`Writer::spawn_with_hooks`]); the binary runs with none.
#[derive(Clone, Default)]
pub struct Hooks {
    /// Replaces the system clock for `tx.at`.
    pub clock: Option<Clock>,
    /// Runs on the writer thread right before a batch's `COMMIT`, with the batch's request count.
    pub before_commit: Option<Arc<dyn Fn(usize) + Send + Sync>>,
    /// Runs on the writer thread right after `COMMIT` returned, before any answer is sent.
    pub after_commit: Option<Arc<dyn Fn() + Send + Sync>>,
}

/// The bounded channel's size.
const QUEUE: usize = 256;
/// SQLite's busy timeout on the write connection.
const BUSY: Duration = Duration::from_secs(5);
/// A stored answer above this many bytes is kept as [`TRUNCATED`] (call 3).
const ANSWER_MAX: usize = 64 * 1024;
/// What `tx.answer` holds for an answer over [`ANSWER_MAX`].
const TRUNCATED: &str = r#"{"truncated":true}"#;

impl Writer {
    /// Start the writer thread on PATH; it opens the file and runs OPEN before the first request.
    pub fn spawn(
        path: impl Into<PathBuf>,
        opts: WriterOpts,
        open: OpenRule,
    ) -> crate::Result<(Writer, WriterHandle)> {
        spawn(path.into(), opts, open, Hooks::default())
    }

    /// [`Writer::spawn`] with test seams.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn spawn_with_hooks(
        path: impl Into<PathBuf>,
        opts: WriterOpts,
        open: OpenRule,
        hooks: Hooks,
    ) -> crate::Result<(Writer, WriterHandle)> {
        spawn(path.into(), opts, open, hooks)
    }

    /// Stop the thread and wait for it, which closes the connection. Blocking: not for an async worker.
    pub fn shutdown(mut self) {
        let _ = self.stop.send(Msg::Stop);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        if self.thread.is_some() {
            let _ = self.stop.send(Msg::Stop);
        }
    }
}

fn spawn(
    path: PathBuf,
    opts: WriterOpts,
    rule: OpenRule,
    hooks: Hooks,
) -> crate::Result<(Writer, WriterHandle)> {
    let status = Arc::new(Mutex::new(WriterStatus {
        open: false,
        schema: 0,
        batches: 0,
        writes: 0,
        replays: 0,
        last_commit_ms: None,
        last_open: None,
    }));
    let (tx, rx) = mpsc::channel::<Msg>();
    let mut state = State {
        path: path.clone(),
        opts,
        rule,
        hooks,
        conn: None,
        outcome: None,
        id: None,
        last_at: 0.0,
        status: status.clone(),
    };
    let thread = std::thread::Builder::new()
        .name("urdr-writer".into())
        .spawn(move || {
            state.open();
            state.serve(rx);
        })?;
    let handle = WriterHandle {
        path: Arc::new(path),
        tx: tx.clone(),
        permits: Arc::new(Semaphore::new(QUEUE)),
        status,
    };
    Ok((
        Writer {
            thread: Some(thread),
            stop: tx,
        },
        handle,
    ))
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
        let permit = self
            .permits
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| WriteError::Closed)?;
        let (reply, answer) = oneshot::channel();
        let job = Box::new(Req {
            f: Some(f),
            value: None,
            reply: Some(reply),
        });
        self.tx
            .send(Msg::Write {
                meta: Box::new(meta),
                job,
                _permit: permit,
            })
            .map_err(|_| WriteError::Closed)?;
        answer.await.map_err(|_| WriteError::Closed)?
    }

    /// Run M on the writer thread between batches, outside a transaction.
    pub async fn maintain(&self, m: Maintenance) -> Result<ScrubReport, WriteError> {
        let (reply, answer) = oneshot::channel();
        self.tx
            .send(Msg::Maintain(m, reply))
            .map_err(|_| WriteError::Closed)?;
        answer.await.map_err(|_| WriteError::Closed)?
    }

    /// The hub's schema tick: run the opening rule again while `NotReady`, and re-open when the file at the path is
    /// another file than the one opened.
    pub async fn tick(&self) {
        let (reply, answer) = oneshot::channel();
        if self.tx.send(Msg::Tick(reply)).is_ok() {
            let _ = answer.await;
        }
    }

    pub fn status(&self) -> WriterStatus {
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// The database file the writer owns.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

enum Msg {
    Write {
        /// Boxed: `TxMeta` makes the variant far larger than the others (clippy `large_enum_variant`).
        meta: Box<TxMeta>,
        job: Box<dyn Job>,
        /// Released when the writer thread takes the request off the channel.
        _permit: OwnedSemaphorePermit,
    },
    Maintain(
        Maintenance,
        oneshot::Sender<Result<ScrubReport, WriteError>>,
    ),
    Tick(oneshot::Sender<()>),
    Stop,
}

/// One request with its type erased: the writer thread runs it, or replays a stored answer into it, then answers.
trait Job: Send {
    /// Run the closure in TX and keep its value; with KEYED, also answer the JSON to store in `tx.answer`.
    fn run(&mut self, tx: &mut Tx<'_>, keyed: bool) -> Result<Option<String>, WriteError>;
    /// Take the value from a stored answer (`None`: the column is null).
    fn replay(&mut self, answer: Option<&str>) -> Result<(), WriteError>;
    /// Send the answer: `(tx, replayed)` with the kept value, or the error.
    fn finish(self: Box<Self>, out: Result<(i64, bool), WriteError>);
}

struct Req<R, F> {
    f: Option<F>,
    value: Option<R>,
    reply: Option<oneshot::Sender<Result<Written<R>, WriteError>>>,
}

impl<R, F> Job for Req<R, F>
where
    R: Serialize + DeserializeOwned + Send + 'static,
    F: for<'t, 'c> FnOnce(&'t mut Tx<'c>) -> Result<R, WriteError> + Send + 'static,
{
    fn run(&mut self, tx: &mut Tx<'_>, keyed: bool) -> Result<Option<String>, WriteError> {
        let f = self
            .f
            .take()
            .ok_or_else(|| WriteError::Sql("a request ran twice".into()))?;
        let value = f(tx)?;
        let answer = if keyed {
            let text = serde_json::to_string(&value)
                .map_err(|e| WriteError::Sql(format!("the answer cannot be stored: {e}")))?;
            Some(if text.len() > ANSWER_MAX {
                TRUNCATED.to_string()
            } else {
                text
            })
        } else {
            None
        };
        self.value = Some(value);
        Ok(answer)
    }

    fn replay(&mut self, answer: Option<&str>) -> Result<(), WriteError> {
        match answer {
            None => Err(WriteError::Refused(
                "the first answer is no longer kept; read the entity".into(),
            )),
            Some(TRUNCATED) => Err(WriteError::Refused(
                "the first answer was too large to replay; read the entity".into(),
            )),
            // `[excised <tx>]` (Task 8) is no JSON value, so it can never be a stored answer.
            Some(text) if text.starts_with(super::excise::MARKER_PREFIX) => Err(
                WriteError::Refused("this answer was excised; read the entity".into()),
            ),
            Some(text) => {
                let value = serde_json::from_str(text).map_err(|e| {
                    WriteError::Refused(format!(
                        "the first answer cannot be read back ({e}); read the entity"
                    ))
                })?;
                self.value = Some(value);
                Ok(())
            }
        }
    }

    fn finish(mut self: Box<Self>, out: Result<(i64, bool), WriteError>) {
        let answer = out.and_then(|(tx, replayed)| {
            self.value
                .take()
                .map(|value| Written {
                    tx,
                    value,
                    replayed,
                })
                .ok_or_else(|| WriteError::Sql("a request finished without a value".into()))
        });
        if let Some(reply) = self.reply.take() {
            let _ = reply.send(answer);
        }
    }
}

/// A request taken off the channel for the current batch.
struct Item {
    meta: TxMeta,
    job: Box<dyn Job>,
}

/// A request run in the open batch, waiting for `COMMIT`.
struct Ran {
    job: Box<dyn Job>,
    out: Result<(i64, bool), WriteError>,
    /// Answered from a stored answer: if the batch fails, the answer may have been this batch's own.
    replay: bool,
}

/// The writer thread's state; only the thread touches it.
struct State {
    path: PathBuf,
    opts: WriterOpts,
    rule: OpenRule,
    hooks: Hooks,
    conn: Option<Connection>,
    outcome: Option<OpenOutcome>,
    /// `(dev, inode)` of the file opened.
    id: Option<(u64, u64)>,
    /// The last `tx.at` given out (or read from the file at open): `at` never goes back.
    last_at: f64,
    status: Arc<Mutex<WriterStatus>>,
}

fn file_id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// The write connection: a missing file is made 0600 first; WAL, `synchronous`, `secure_delete=ON`, busy timeout.
fn open_conn(path: &Path, synchronous_full: bool) -> Result<Connection, String> {
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(f) => f
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?,
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.to_string()),
    }
    let s = |e: rusqlite::Error| e.to_string();
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(path, flags).map_err(s)?;
    conn.busy_timeout(BUSY).map_err(s)?;
    conn.pragma_update(None, "journal_mode", "wal").map_err(s)?;
    conn.pragma_update(
        None,
        "synchronous",
        if synchronous_full { "FULL" } else { "NORMAL" },
    )
    .map_err(s)?;
    conn.pragma_update(None, "secure_delete", "ON").map_err(s)?;
    Ok(conn)
}

fn panic_text(p: &(dyn std::any::Any + Send)) -> String {
    p.downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| p.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "a panic without a message".into())
}

fn is_busy(e: &rusqlite::Error) -> bool {
    matches!(e, rusqlite::Error::SqliteFailure(f, _)
        if matches!(f.code, rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked))
}

/// `max(now, previous at)`: a clock stepping back never reorders time.
fn next_at(last_at: &mut f64, clock: Option<&Clock>) -> f64 {
    let now = match clock {
        Some(c) => c(),
        None => SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64()),
    };
    *last_at = last_at.max(now);
    *last_at
}

/// One request inside the open batch: a stored answer for a repeated `(actor, req)`, else the closure in its own
/// savepoint after its `tx` row. Answers the outcome and whether it was a replay.
fn one(
    conn: &mut Connection,
    guard: &Arc<Guard>,
    last_at: &mut f64,
    clock: Option<&Clock>,
    meta: TxMeta,
    job: &mut dyn Job,
) -> (Result<(i64, bool), WriteError>, bool) {
    if let Some(req) = &meta.req {
        let hit = conn
            .query_row(
                "select id, answer from tx where actor = ?1 and req = ?2",
                params![meta.actor, req],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?)),
            )
            .optional();
        match hit {
            Err(e) => return (Err(e.into()), false),
            Ok(Some((id, answer))) => {
                return (job.replay(answer.as_deref()).map(|()| (id, true)), true);
            }
            Ok(None) => {}
        }
    }
    let at = next_at(last_at, clock);
    let keyed = meta.req.is_some();
    let mut tx = match Tx::begin(conn, meta, at, guard.clone()) {
        Ok(tx) => tx,
        Err(e) => return (Err(e.into()), false),
    };
    let id = tx.id();
    // An `Err` or a panic drops `tx`, which rolls its savepoint back: the batch's other requests stay.
    let answer = match catch_unwind(AssertUnwindSafe(|| job.run(&mut tx, keyed))) {
        Ok(Ok(answer)) => answer,
        Ok(Err(e)) => return (Err(e), false),
        Err(p) => {
            let text = panic_text(&*p);
            return (
                Err(WriteError::Sql(format!("the write panicked: {text}"))),
                false,
            );
        }
    };
    if let Some(answer) = answer
        && let Err(e) = tx.sql().execute(
            "update tx set answer = ?1 where id = ?2",
            params![answer, id],
        )
    {
        return (Err(e.into()), false);
    }
    match tx.release() {
        Ok(()) => (Ok((id, false)), false),
        Err(e) => (Err(e.into()), false),
    }
}

/// Answer every request of a batch that was not committed: what would have been written (and every replay, which
/// may have come from this batch) is `Retryable`; a request that failed on its own keeps its error.
fn fail(ran: Vec<Ran>, text: &str) {
    for r in ran {
        let out = match r.out {
            Err(e) if !r.replay => Err(e),
            _ => Err(WriteError::Retryable(text.to_string())),
        };
        r.job.finish(out);
    }
}

impl State {
    fn set_status(&self, f: impl FnOnce(&mut WriterStatus)) {
        f(&mut self.status.lock().unwrap_or_else(|e| e.into_inner()));
    }

    /// Open the file at the path and run the rule; keep the connection only when it answers `Ready`.
    fn open(&mut self) {
        self.conn = None;
        let outcome = match open_conn(&self.path, self.opts.synchronous_full) {
            Err(e) => {
                self.id = None;
                OpenOutcome::NotReady(format!("{}: cannot open: {e}", self.path.display()))
            }
            Ok(mut conn) => {
                self.id = file_id(&self.path);
                let rule = self.rule.clone();
                let path = self.path.clone();
                let out =
                    catch_unwind(AssertUnwindSafe(|| rule(&mut conn, &path))).unwrap_or_else(|p| {
                        OpenOutcome::Failed(format!(
                            "the opening rule panicked: {}",
                            panic_text(&*p)
                        ))
                    });
                if let OpenOutcome::Ready { .. } = out {
                    // `at` is read once per open: the file's last time is the floor.
                    if let Ok(Some(max)) =
                        conn.query_row("select max(at) from tx", [], |r| r.get::<_, Option<f64>>(0))
                    {
                        self.last_at = self.last_at.max(max);
                    }
                    self.conn = Some(conn);
                }
                out
            }
        };
        let schema = match outcome {
            OpenOutcome::Ready { schema } | OpenOutcome::ReadOnly { schema } => schema,
            _ => 0,
        };
        let open = matches!(outcome, OpenOutcome::Ready { .. });
        let last = outcome.clone();
        self.set_status(|s| {
            s.open = open;
            s.schema = schema;
            s.last_open = Some(last);
        });
        self.outcome = Some(outcome);
    }

    /// The schema tick: re-run the rule while not ready (never after `Failed`), re-open a replaced file.
    fn tick(&mut self) {
        match &self.outcome {
            Some(OpenOutcome::Failed(_)) => {}
            Some(OpenOutcome::Ready { .. } | OpenOutcome::ReadOnly { .. }) => {
                let now = file_id(&self.path);
                if now.is_none() || now != self.id {
                    self.open();
                }
            }
            Some(OpenOutcome::NotReady(_)) | None => self.open(),
        }
    }

    /// Whether writes may run now, else the error every write answers.
    fn writable(&self) -> Result<(), WriteError> {
        match (&self.outcome, &self.conn) {
            (Some(OpenOutcome::Ready { .. }), Some(_)) => Ok(()),
            (Some(OpenOutcome::ReadOnly { schema }), _) => {
                Err(WriteError::ReadOnly { schema: *schema })
            }
            (Some(OpenOutcome::NotReady(text) | OpenOutcome::Failed(text)), _) => {
                Err(WriteError::NotReady(text.clone()))
            }
            _ => Err(WriteError::NotReady("the store is not open".into())),
        }
    }

    /// The thread's loop: a batch per first write (drained up to `max_batch`, or until `max_wait` after it), and
    /// ticks and maintenance between batches. A non-write message that arrives mid-batch closes the batch first.
    fn serve(&mut self, rx: mpsc::Receiver<Msg>) {
        let max_batch = self.opts.max_batch.max(1);
        let mut pending: Option<Msg> = None;
        loop {
            let first = match pending.take() {
                Some(m) => m,
                None => match rx.recv() {
                    Ok(m) => m,
                    Err(_) => return,
                },
            };
            match first {
                Msg::Stop => return,
                Msg::Tick(reply) => {
                    self.tick();
                    let _ = reply.send(());
                }
                Msg::Maintain(m, reply) => {
                    let _ = reply.send(self.maintain(m));
                }
                Msg::Write {
                    meta,
                    job,
                    _permit: permit,
                } => {
                    drop(permit);
                    let mut batch = vec![Item { meta: *meta, job }];
                    let deadline = Instant::now() + self.opts.max_wait;
                    while batch.len() < max_batch {
                        let left = deadline.saturating_duration_since(Instant::now());
                        let next = if left.is_zero() {
                            rx.try_recv().map_err(|e| match e {
                                TryRecvError::Empty => RecvTimeoutError::Timeout,
                                TryRecvError::Disconnected => RecvTimeoutError::Disconnected,
                            })
                        } else {
                            rx.recv_timeout(left)
                        };
                        match next {
                            Ok(Msg::Write {
                                meta,
                                job,
                                _permit: permit,
                            }) => {
                                drop(permit);
                                batch.push(Item { meta: *meta, job });
                            }
                            Ok(other) => {
                                pending = Some(other);
                                break;
                            }
                            Err(_) => break,
                        }
                    }
                    self.batch(batch);
                }
            }
        }
    }

    /// One `BEGIN IMMEDIATE … COMMIT` over the batch, a savepoint per request; every answer after `COMMIT`.
    fn batch(&mut self, items: Vec<Item>) {
        if let Err(e) = self.writable() {
            for it in items {
                it.job.finish(Err(e.clone()));
            }
            return;
        }
        let guard = self.opts.guard.clone();
        let clock = self.hooks.clock.clone();
        let Some(conn) = self.conn.as_mut() else {
            return;
        };
        if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE") {
            for it in items {
                it.job.finish(Err(WriteError::Retryable(e.to_string())));
            }
            return;
        }
        let n = items.len();
        let mut ran: Vec<Ran> = Vec::with_capacity(n);
        let mut items = items.into_iter();
        for Item { meta, mut job } in items.by_ref() {
            let (out, replay) = one(
                conn,
                &guard,
                &mut self.last_at,
                clock.as_ref(),
                meta,
                &mut *job,
            );
            ran.push(Ran { job, out, replay });
            if conn.is_autocommit() {
                // SQLite rolled the whole transaction back (a full disk, an I/O error): nothing of the batch stays.
                for Item { job, .. } in items {
                    ran.push(Ran {
                        job,
                        out: Err(WriteError::Retryable(String::new())),
                        replay: true,
                    });
                }
                fail(ran, "SQLite rolled the batch back");
                return;
            }
        }
        if let Some(h) = &self.hooks.before_commit {
            h(n);
        }
        let started = Instant::now();
        if let Err(e) = conn.execute_batch("COMMIT") {
            // A failed COMMIT can leave the transaction open (a deferred constraint): end it.
            let _ = conn.execute_batch("ROLLBACK");
            fail(ran, &e.to_string());
            return;
        }
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        if let Some(h) = &self.hooks.after_commit {
            h();
        }
        let writes = ran
            .iter()
            .filter(|r| matches!(r.out, Ok((_, false))))
            .count() as u64;
        let replays = ran
            .iter()
            .filter(|r| matches!(r.out, Ok((_, true))))
            .count() as u64;
        self.set_status(|s| {
            s.batches += 1;
            s.writes += writes;
            s.replays += replays;
            s.last_commit_ms = Some(ms);
        });
        for r in ran {
            r.job.finish(r.out);
        }
    }

    /// `VACUUM` (Scrub only), then `wal_checkpoint(TRUNCATE)`, outside any transaction.
    fn maintain(&mut self, m: Maintenance) -> Result<ScrubReport, WriteError> {
        self.writable()?;
        let Some(conn) = self.conn.as_ref() else {
            return Err(WriteError::NotReady("the store is not open".into()));
        };
        let mut vacuumed = false;
        let mut blocked_by = None;
        if m == Maintenance::Scrub {
            match conn.execute_batch("VACUUM") {
                Ok(()) => vacuumed = true,
                // VACUUM needs the write lock: another process's writer holds it.
                Err(e) if is_busy(&e) => blocked_by = Some(Blocker::Writer),
                Err(e) => return Err(e.into()),
            }
        }
        let busy: i64 = conn.query_row("pragma wal_checkpoint(TRUNCATE)", [], |r| r.get(0))?;
        let wal_truncated = busy == 0;
        if !wal_truncated && blocked_by.is_none() {
            blocked_by = Some(Blocker::Readers);
        }
        Ok(ScrubReport {
            vacuumed,
            wal_truncated,
            blocked_by,
        })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::Class;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// What the tests write besides the graph tables: `t` rows carry their tx; `child` → `parent` is a deferred
    /// foreign key, so a violation fails the batch's `COMMIT` itself.
    const TEST_DDL: &str = "create table t (v integer, tx integer);
        create table parent (id integer primary key);
        create table child (p integer references parent(id) deferrable initially deferred);";

    /// The tests' opening rule: an empty file gets the graph tables and the test tables; foreign keys on.
    pub(crate) fn rule() -> OpenRule {
        Arc::new(|c: &mut Connection, _: &Path| {
            let v: i64 = c
                .query_row("pragma user_version", [], |r| r.get(0))
                .unwrap();
            if v == 0 {
                c.execute_batch(GRAPH_DDL).unwrap();
                c.execute_batch(TEST_DDL).unwrap();
                c.pragma_update(None, "user_version", 7).unwrap();
            }
            c.pragma_update(None, "foreign_keys", "ON").unwrap();
            OpenOutcome::Ready { schema: 7 }
        })
    }

    pub(crate) fn opts(max_batch: usize, max_wait_ms: u64) -> WriterOpts {
        WriterOpts {
            max_batch,
            max_wait: Duration::from_millis(max_wait_ms),
            synchronous_full: false,
            guard: Arc::default(),
        }
    }

    pub(crate) fn keyed(actor: &str, req: &str) -> TxMeta {
        let mut m = TxMeta::new(actor, Class::Agent, "mcp:test");
        m.req = Some(req.into());
        m
    }

    fn meta() -> TxMeta {
        TxMeta::new("agent:s1", Class::Agent, "mcp:test")
    }

    /// Insert V into `t` with the request's tx; answers V.
    fn put(
        v: i64,
    ) -> impl for<'t, 'c> FnOnce(&'t mut Tx<'c>) -> Result<i64, WriteError> + Send + 'static {
        move |tx: &mut Tx<'_>| {
            tx.sql()
                .execute("insert into t (v, tx) values (?1, ?2)", params![v, tx.id()])?;
            Ok(v)
        }
    }

    pub(crate) fn count(path: &Path, sql: &str) -> i64 {
        crate::open_readonly(path)
            .unwrap()
            .query_row(sql, [], |r| r.get(0))
            .unwrap()
    }

    fn values(path: &Path) -> Vec<i64> {
        let c = crate::open_readonly(path).unwrap();
        let mut st = c.prepare("select v from t order by v").unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .map(|v| v.unwrap())
            .collect()
    }

    pub(crate) async fn stop(w: Writer) {
        tokio::task::spawn_blocking(move || w.shutdown())
            .await
            .unwrap();
    }

    /// Holds the first batch at its `COMMIT` until released, and records every batch's size.
    struct Gate {
        armed: AtomicBool,
        reached: Mutex<mpsc::Sender<()>>,
        release: Mutex<mpsc::Receiver<()>>,
        sizes: Mutex<Vec<usize>>,
    }

    /// A gate's hooks, the "reached" receiver and the "release" sender.
    fn gate() -> (Arc<Gate>, Hooks, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let (reached_tx, reached_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let g = Arc::new(Gate {
            armed: AtomicBool::new(true),
            reached: Mutex::new(reached_tx),
            release: Mutex::new(release_rx),
            sizes: Mutex::new(Vec::new()),
        });
        let h = g.clone();
        let hooks = Hooks {
            before_commit: Some(Arc::new(move |n| {
                h.sizes.lock().unwrap().push(n);
                if h.armed.swap(false, Ordering::SeqCst) {
                    h.reached.lock().unwrap().send(()).unwrap();
                    h.release.lock().unwrap().recv().unwrap();
                }
            })),
            ..Hooks::default()
        };
        (g, hooks, reached_rx, release_tx)
    }

    /// Wait on a std channel without blocking the test's runtime (spawned writes still get to run).
    async fn reached(rx: mpsc::Receiver<()>) {
        tokio::task::spawn_blocking(move || rx.recv().unwrap())
            .await
            .unwrap();
    }

    /// Let spawned writes reach the channel.
    async fn settle() {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    fn spawn_at(
        dir: &tempfile::TempDir,
        opts: WriterOpts,
        hooks: Hooks,
    ) -> (Writer, WriterHandle, PathBuf) {
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn_with_hooks(&path, opts, rule(), hooks).unwrap();
        (w, h, path)
    }

    #[tokio::test]
    async fn no_answer_before_commit() {
        let dir = tempfile::tempdir().unwrap();
        let (_g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(256, 5), hooks);
        let write = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(1)).await }
        });
        reached(at_commit).await;
        settle().await;
        assert!(!write.is_finished(), "answered before COMMIT");
        assert_eq!(
            count(&path, "select count(*) from t"),
            0,
            "not committed yet"
        );
        release.send(()).unwrap();
        let done = write.await.unwrap().unwrap();
        assert_eq!(done.value, 1);
        assert!(!done.replayed);
        assert_eq!(count(&path, "select count(*) from t"), 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn a_failed_request_rolls_back_only_its_savepoint() {
        let dir = tempfile::tempdir().unwrap();
        let (g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(3, 2000), hooks);
        // Hold a first batch so the next three share one.
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let a = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(1)).await }
        });
        let b = tokio::spawn({
            let h = h.clone();
            async move {
                h.write(meta(), |tx: &mut Tx<'_>| {
                    tx.sql()
                        .execute("insert into t (v, tx) values (2, ?1)", [tx.id()])?;
                    Err::<i64, _>(WriteError::Refused("no".into()))
                })
                .await
            }
        });
        let c = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(3)).await }
        });
        settle().await;
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        assert_eq!(a.await.unwrap().unwrap().value, 1);
        assert_eq!(b.await.unwrap(), Err(WriteError::Refused("no".into())));
        assert_eq!(c.await.unwrap().unwrap().value, 3);
        assert_eq!(*g.sizes.lock().unwrap(), vec![1, 3], "one batch of three");
        assert_eq!(values(&path), vec![0, 1, 3]);
        assert_eq!(
            count(&path, "select count(*) from tx"),
            3,
            "the failed request's tx row is gone too"
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn a_panicking_request_is_its_own_error() {
        let dir = tempfile::tempdir().unwrap();
        let (g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(3, 2000), hooks);
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let a = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(1)).await }
        });
        let b = tokio::spawn({
            let h = h.clone();
            async move {
                h.write(meta(), |tx: &mut Tx<'_>| -> Result<i64, WriteError> {
                    tx.sql()
                        .execute("insert into t (v, tx) values (2, ?1)", [tx.id()])?;
                    panic!("boom")
                })
                .await
            }
        });
        let c = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(3)).await }
        });
        settle().await;
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        assert_eq!(a.await.unwrap().unwrap().value, 1);
        match b.await.unwrap() {
            Err(WriteError::Sql(text)) => assert!(text.contains("panicked: boom"), "{text}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(c.await.unwrap().unwrap().value, 3);
        assert_eq!(*g.sizes.lock().unwrap(), vec![1, 3]);
        assert_eq!(values(&path), vec![0, 1, 3]);
        // The writer thread survived the panic.
        assert_eq!(h.write(meta(), put(4)).await.unwrap().value, 4);
        stop(w).await;
    }

    #[tokio::test]
    async fn a_failed_commit_fails_the_whole_batch_retryable() {
        let dir = tempfile::tempdir().unwrap();
        let (g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(4, 2000), hooks);
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let mut writes = Vec::new();
        for v in 1..=3 {
            let h = h.clone();
            writes.push(tokio::spawn(async move { h.write(meta(), put(v)).await }));
        }
        // A deferred foreign-key violation: every statement succeeds, COMMIT fails.
        let orphan = tokio::spawn({
            let h = h.clone();
            async move {
                h.write(meta(), |tx: &mut Tx<'_>| {
                    tx.sql().execute("insert into child (p) values (99)", [])?;
                    Ok(())
                })
                .await
            }
        });
        settle().await;
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        for j in writes {
            assert!(
                matches!(j.await.unwrap(), Err(WriteError::Retryable(t)) if t.contains("FOREIGN KEY")),
                "every request of the batch is retryable"
            );
        }
        assert!(matches!(
            orphan.await.unwrap(),
            Err(WriteError::Retryable(_))
        ));
        assert_eq!(*g.sizes.lock().unwrap(), vec![1, 4]);
        assert_eq!(values(&path), vec![0], "nothing of the batch was written");
        assert_eq!(count(&path, "select count(*) from tx"), 1);
        // The transaction was ended: the next batch commits.
        assert_eq!(h.write(meta(), put(5)).await.unwrap().value, 5);
        assert_eq!(values(&path), vec![0, 5]);
        stop(w).await;
    }

    #[tokio::test]
    async fn batches_are_bounded_by_size_and_time() {
        let dir = tempfile::tempdir().unwrap();
        let (g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(4, 300), hooks);
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let mut writes = Vec::new();
        for v in 1..=10 {
            let h = h.clone();
            writes.push(tokio::spawn(async move { h.write(meta(), put(v)).await }));
        }
        settle().await;
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        for j in writes {
            j.await.unwrap().unwrap();
        }
        // Size: ten queued requests go in batches of at most four.
        assert_eq!(*g.sizes.lock().unwrap(), vec![1, 4, 4, 2]);
        // Time: a lone request waits for company at most max_wait, then commits alone.
        let started = Instant::now();
        h.write(meta(), put(11)).await.unwrap();
        let took = started.elapsed();
        assert!(took >= Duration::from_millis(300), "{took:?}");
        assert!(took < Duration::from_secs(5), "{took:?}");
        assert_eq!(g.sizes.lock().unwrap().last(), Some(&1));
        assert_eq!(count(&path, "select count(*) from t"), 12);
        assert_eq!(h.status().batches, 5);
        assert_eq!(h.status().writes, 12);
        stop(w).await;
    }

    #[tokio::test]
    async fn tx_at_is_monotonic_under_a_clock_step_back() {
        let dir = tempfile::tempdir().unwrap();
        let times = Arc::new(Mutex::new(vec![100.0, 200.0, 150.0, 50.0, 300.0]));
        let t = times.clone();
        let hooks = Hooks {
            clock: Some(Arc::new(move || t.lock().unwrap().remove(0))),
            ..Hooks::default()
        };
        let (w, h, path) = spawn_at(&dir, opts(1, 0), hooks);
        for v in 0..5 {
            h.write(meta(), put(v)).await.unwrap();
        }
        let c = crate::open_readonly(&path).unwrap();
        let ats: Vec<f64> = c
            .prepare("select at from tx order by id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|v| v.unwrap())
            .collect();
        assert_eq!(ats, vec![100.0, 200.0, 200.0, 200.0, 300.0]);
        drop(c);
        stop(w).await;
        // A new writer reads the file's last time once at open: a clock behind it never goes back.
        let hooks = Hooks {
            clock: Some(Arc::new(|| 10.0)),
            ..Hooks::default()
        };
        let (w, h, path) = spawn_at(&dir, opts(1, 0), hooks);
        let done = h.write(meta(), put(5)).await.unwrap();
        let at: f64 = crate::open_readonly(&path)
            .unwrap()
            .query_row("select at from tx where id = ?1", [done.tx], |r| r.get(0))
            .unwrap();
        assert_eq!(at, 300.0);
        stop(w).await;
    }

    #[tokio::test]
    async fn a_repeated_req_returns_the_first_answer() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        let first = h.write(keyed("agent:s1", "r-1"), put(1)).await.unwrap();
        assert!(!first.replayed);
        let again = h.write(keyed("agent:s1", "r-1"), put(2)).await.unwrap();
        assert_eq!(
            again,
            Written {
                tx: first.tx,
                value: 1,
                replayed: true
            }
        );
        assert_eq!(values(&path), vec![1], "the repeat ran nothing");
        // The key is the actor's: another actor's same key is its own request.
        let other = h.write(keyed("agent:s2", "r-1"), put(3)).await.unwrap();
        assert!(!other.replayed);
        assert_ne!(other.tx, first.tx);
        // A failed request leaves no answer: its repeat runs.
        let failed = h
            .write(keyed("agent:s1", "r-2"), |_: &mut Tx<'_>| {
                Err::<i64, _>(WriteError::Refused("not now".into()))
            })
            .await;
        assert!(failed.is_err());
        let retried = h.write(keyed("agent:s1", "r-2"), put(4)).await.unwrap();
        assert!(!retried.replayed);
        assert_eq!(values(&path), vec![1, 3, 4]);
        assert_eq!(h.status().replays, 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn the_same_req_twice_in_one_batch_writes_once() {
        let dir = tempfile::tempdir().unwrap();
        let (g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(256, 200), hooks);
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let a = tokio::spawn({
            let h = h.clone();
            async move { h.write(keyed("agent:s1", "r-1"), put(1)).await }
        });
        let b = tokio::spawn({
            let h = h.clone();
            async move { h.write(keyed("agent:s1", "r-1"), put(2)).await }
        });
        settle().await;
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        let (a, b) = (a.await.unwrap().unwrap(), b.await.unwrap().unwrap());
        assert_eq!(*g.sizes.lock().unwrap(), vec![1, 2], "both in one batch");
        assert_eq!(a.tx, b.tx);
        assert_eq!(a.value, b.value);
        assert!(
            a.replayed != b.replayed,
            "one ran, one was answered from it"
        );
        assert_eq!(count(&path, "select count(*) from t where v in (1, 2)"), 1);
        assert_eq!(count(&path, "select count(*) from tx where req = 'r-1'"), 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn an_answer_over_64k_replays_as_refused() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        let big = "x".repeat(70_000);
        let first = h
            .write(keyed("agent:s1", "big"), {
                let big = big.clone();
                move |_: &mut Tx<'_>| Ok(big)
            })
            .await
            .unwrap();
        assert_eq!(first.value, big, "the first answer is whole");
        let stored: String = crate::open_readonly(&path)
            .unwrap()
            .query_row("select answer from tx where req = 'big'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, TRUNCATED);
        let again = h
            .write(keyed("agent:s1", "big"), |_: &mut Tx<'_>| {
                Ok("ran again".to_string())
            })
            .await;
        assert_eq!(
            again,
            Err(WriteError::Refused(
                "the first answer was too large to replay; read the entity".into()
            ))
        );
        assert_eq!(count(&path, "select count(*) from tx"), 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn writes_never_run_on_the_callers_thread() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, _path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        let me = std::thread::current().id();
        let seen = Arc::new(Mutex::new(None));
        let s = seen.clone();
        let name = h
            .write(meta(), move |_: &mut Tx<'_>| {
                *s.lock().unwrap() = Some(std::thread::current().id());
                Ok(std::thread::current().name().map(str::to_string))
            })
            .await
            .unwrap();
        assert_eq!(name.value.as_deref(), Some("urdr-writer"));
        assert_ne!(seen.lock().unwrap().unwrap(), me);
        stop(w).await;
    }

    #[tokio::test]
    async fn no_req_stores_no_answer() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        let done = h.write(meta(), put(1)).await.unwrap();
        let (req, answer): (Option<String>, Option<String>) = crate::open_readonly(&path)
            .unwrap()
            .query_row("select req, answer from tx where id = ?1", [done.tx], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((req, answer), (None, None));
        let keyed_done = h.write(keyed("agent:s1", "k"), put(2)).await.unwrap();
        let answer: Option<String> = crate::open_readonly(&path)
            .unwrap()
            .query_row(
                "select answer from tx where id = ?1",
                [keyed_done.tx],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(answer.as_deref(), Some("2"));
        stop(w).await;
    }

    #[tokio::test]
    async fn secure_delete_is_on() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn_at(&dir, WriterOpts::default(), Hooks::default());
        let pragmas = h
            .write(meta(), |tx: &mut Tx<'_>| {
                let q = |p: &str| -> Result<String, WriteError> {
                    Ok(tx
                        .sql()
                        .query_row(&format!("pragma {p}"), [], |r| {
                            r.get::<_, rusqlite::types::Value>(0)
                        })
                        .map(|v| match v {
                            rusqlite::types::Value::Integer(i) => i.to_string(),
                            rusqlite::types::Value::Text(t) => t,
                            other => format!("{other:?}"),
                        })?)
                };
                Ok((q("secure_delete")?, q("journal_mode")?, q("synchronous")?))
            })
            .await
            .unwrap()
            .value;
        // secure_delete on; WAL; synchronous FULL (2) by default.
        assert_eq!(pragmas, ("1".into(), "wal".into(), "2".into()));
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "a file the writer makes is the user's only");
        stop(w).await;
    }

    #[tokio::test]
    async fn maintain_runs_between_batches() {
        let dir = tempfile::tempdir().unwrap();
        let (_g, hooks, at_commit, release) = gate();
        let (w, h, path) = spawn_at(&dir, opts(256, 50), hooks);
        let first = tokio::spawn({
            let h = h.clone();
            async move { h.write(meta(), put(0)).await }
        });
        reached(at_commit).await;
        let scrub = tokio::spawn({
            let h = h.clone();
            async move { h.maintain(Maintenance::Scrub).await }
        });
        settle().await;
        assert!(!scrub.is_finished(), "maintenance waits for the open batch");
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        // VACUUM fails inside a transaction: vacuumed means it ran between batches.
        assert_eq!(
            scrub.await.unwrap().unwrap(),
            ScrubReport {
                vacuumed: true,
                wal_truncated: true,
                blocked_by: None
            }
        );
        assert_eq!(values(&path), vec![0]);
        // A checkpoint alone vacuums nothing. (A reader blocking TRUNCATE is Task 8's
        // `a_reader_blocks_truncate_and_the_report_says_so`: it waits out the 5 s busy timeout.)
        h.write(meta(), put(1)).await.unwrap();
        assert_eq!(
            h.maintain(Maintenance::Checkpoint).await.unwrap(),
            ScrubReport {
                vacuumed: false,
                wal_truncated: true,
                blocked_by: None
            }
        );
        assert_eq!(values(&path), vec![0, 1]);
        stop(w).await;
    }

    #[tokio::test]
    async fn failed_open_is_not_retried() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let c = calls.clone();
        let rule: OpenRule = Arc::new(move |_: &mut Connection, _: &Path| {
            c.fetch_add(1, Ordering::SeqCst);
            OpenOutcome::Failed("the migration failed: disk full".into())
        });
        let (w, h) = Writer::spawn(dir.path().join("work.db"), opts(256, 1), rule).unwrap();
        let e = h.write(meta(), put(1)).await;
        assert_eq!(
            e,
            Err(WriteError::NotReady(
                "the migration failed: disk full".into()
            ))
        );
        for _ in 0..3 {
            h.tick().await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1, "Failed is never re-tried");
        assert!(matches!(
            h.maintain(Maintenance::Checkpoint).await,
            Err(WriteError::NotReady(_))
        ));
        let st = h.status();
        assert!(!st.open);
        assert_eq!(
            st.last_open,
            Some(OpenOutcome::Failed(
                "the migration failed: disk full".into()
            ))
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn not_ready_is_retried_at_each_tick() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let c = calls.clone();
        let inner = rule();
        let rule: OpenRule = Arc::new(move |conn: &mut Connection, p: &Path| {
            if c.fetch_add(1, Ordering::SeqCst) < 2 {
                OpenOutcome::NotReady("not yet".into())
            } else {
                inner(conn, p)
            }
        });
        let (w, h) = Writer::spawn(dir.path().join("work.db"), opts(256, 1), rule).unwrap();
        assert_eq!(
            h.write(meta(), put(1)).await,
            Err(WriteError::NotReady("not yet".into()))
        );
        h.tick().await;
        assert!(!h.status().open);
        h.tick().await;
        assert!(h.status().open);
        assert_eq!(h.status().schema, 7);
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        // Ready and unchanged: the tick runs nothing.
        h.tick().await;
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        assert_eq!(h.write(meta(), put(1)).await.unwrap().value, 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn a_replaced_file_is_opened_again_at_the_tick() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        h.write(meta(), put(1)).await.unwrap();
        // Moved aside together, as `restore-pre7` does: a WAL never meets another file's database.
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::rename(
                dir.path().join(format!("work.db{suffix}")),
                dir.path().join(format!("old.db{suffix}")),
            );
        }
        h.tick().await;
        assert!(h.status().open);
        h.write(meta(), put(2)).await.unwrap();
        assert_eq!(
            values(&path),
            vec![2],
            "the new file at the path is written"
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn a_newer_schema_is_read_only() {
        let dir = tempfile::tempdir().unwrap();
        let rule: OpenRule =
            Arc::new(|_: &mut Connection, _: &Path| OpenOutcome::ReadOnly { schema: 8 });
        let (w, h) = Writer::spawn(dir.path().join("work.db"), opts(256, 1), rule).unwrap();
        assert_eq!(
            h.write(meta(), put(1)).await,
            Err(WriteError::ReadOnly { schema: 8 })
        );
        assert_eq!(h.status().schema, 8);
        assert!(!h.status().open);
        stop(w).await;
    }

    #[tokio::test]
    async fn a_stopped_writer_answers_closed() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, _path) = spawn_at(&dir, opts(256, 1), Hooks::default());
        stop(w).await;
        assert_eq!(h.write(meta(), put(1)).await, Err(WriteError::Closed));
        assert_eq!(
            h.maintain(Maintenance::Checkpoint).await,
            Err(WriteError::Closed)
        );
    }

    /// xorshift64: the random cases without a dependency.
    fn next(state: &mut u64) -> u64 {
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        *state
    }

    #[tokio::test]
    async fn random_batches_commit_exactly_the_ok_requests() {
        for seed in 1..=24u64 {
            let dir = tempfile::tempdir().unwrap();
            let (w, h, path) = spawn_at(&dir, opts(8, 20), Hooks::default());
            let mut rng = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
            let n = 1 + next(&mut rng) % 40;
            let mut ok = Vec::new();
            let mut writes = Vec::new();
            for v in 0..n as i64 {
                let kind = next(&mut rng) % 3;
                if kind == 0 {
                    ok.push(v);
                }
                let h = h.clone();
                writes.push((
                    kind,
                    tokio::spawn(async move {
                        h.write(meta(), move |tx: &mut Tx<'_>| {
                            tx.sql().execute(
                                "insert into t (v, tx) values (?1, ?2)",
                                params![v, tx.id()],
                            )?;
                            match kind {
                                0 => Ok(v),
                                1 => Err(WriteError::Refused("refused".into())),
                                _ => panic!("random panic"),
                            }
                        })
                        .await
                    }),
                ));
                if next(&mut rng).is_multiple_of(4) {
                    tokio::task::yield_now().await;
                }
            }
            for (kind, j) in writes {
                assert_eq!(j.await.unwrap().is_ok(), kind == 0, "seed {seed}");
            }
            assert_eq!(values(&path), ok, "seed {seed}");
            assert_eq!(
                count(&path, "select count(*) from tx") as usize,
                ok.len(),
                "seed {seed}: one tx row per ok request"
            );
            assert_eq!(
                count(
                    &path,
                    "select count(distinct t.tx) from t join tx on tx.id = t.tx"
                ) as usize,
                ok.len(),
                "seed {seed}"
            );
            stop(w).await;
        }
    }
}

/// `kill_between_commit_and_answer`: the test binary re-executes itself as a child that commits a keyed write and is
/// `SIGKILL`ed after `COMMIT`, before it answers; the parent repeats the same `(actor, req)` and gets the first answer.
#[cfg(test)]
mod crash {
    use super::tests::{keyed, opts, rule, stop};
    use super::*;
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Command, Stdio};

    const CHILD: &str = "URDR_WRITER_CRASH_CHILD";
    const NAME: &str = "graph::writer::crash::kill_between_commit_and_answer";

    /// Rows of `t`, through a read-write connection: the killed child's WAL may need recovery, which a read-only
    /// connection cannot run.
    fn count(path: &Path) -> i64 {
        Connection::open(path)
            .unwrap()
            .query_row("select count(*) from t", [], |r| r.get(0))
            .unwrap()
    }

    fn first(tx: &mut Tx<'_>, text: &str) -> Result<String, WriteError> {
        tx.sql()
            .execute("insert into t (v, tx) values (1, ?1)", [tx.id()])?;
        Ok(text.to_string())
    }

    #[test]
    fn kill_between_commit_and_answer() {
        if let Some(dir) = std::env::var_os(CHILD) {
            child(PathBuf::from(dir));
        }
        let dir = tempfile::tempdir().unwrap();
        let status = Command::new(std::env::current_exe().unwrap())
            .args([NAME, "--exact", "--test-threads=1"])
            .env(CHILD, dir.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert_eq!(
            status.signal(),
            Some(9),
            "the child is killed after COMMIT, before it answers ({status:?})"
        );
        let path = dir.path().join("work.db");
        assert_eq!(count(&path), 1, "the write committed");
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (w, h) = Writer::spawn(&path, opts(256, 1), rule()).unwrap();
            let again = h
                .write(keyed("agent:s1", "r-1"), |tx: &mut Tx<'_>| {
                    first(tx, "second")
                })
                .await
                .unwrap();
            assert!(again.replayed);
            assert_eq!(again.value, "first");
            stop(w).await;
        });
        assert_eq!(count(&path), 1, "the repeat wrote nothing");
    }

    /// The child: one keyed write; the after-COMMIT hook kills this process before any answer is sent.
    fn child(dir: PathBuf) -> ! {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let hooks = Hooks {
                after_commit: Some(Arc::new(|| {
                    let _ = Command::new("sh")
                        .arg("-c")
                        .arg(format!("kill -KILL {}", std::process::id()))
                        .status();
                    // Not killed: exit plainly, so the parent's signal check fails instead of hanging.
                    std::process::exit(3);
                })),
                ..Hooks::default()
            };
            let (_w, h) =
                Writer::spawn_with_hooks(dir.join("work.db"), opts(256, 1), rule(), hooks).unwrap();
            let _ = h
                .write(keyed("agent:s1", "r-1"), |tx: &mut Tx<'_>| {
                    first(tx, "first")
                })
                .await;
        });
        std::process::exit(4)
    }
}
