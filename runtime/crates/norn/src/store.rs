//! The coordination store over the graph writer (docs/develop/coordination.md, "The writer").
//!
//! [`CoordDb`] is a thin wrapper over [`urdr::graph::WriterHandle`]: every write is one request of the graph writer,
//! so it runs on the writer thread in its own savepoint after its `tx` row (the author comes from the caller's
//! [`TxMeta`], never from an argument), and is answered after `COMMIT`.  The writer's opening rule
//! ([`crate::migrate7::open_rule`]) makes a missing `work.db` at schema 7 or migrates a schema-6 one; while it has
//! not, a write answers the rule's text ([`CoordError::NotReady`]).  The hub hands its writer to
//! [`CoordDb::with_graph`]; [`CoordDb::spawn`] starts one of its own on a path (tests).
//!
//! Reads run on a read-only connection of their own ([`CoordDb::read`]); the hub's 2 s schema tick calls
//! [`CoordDb::tick`], which opens it when it is not open and opens it again when the file at the path is another file
//! than the one opened (a removed and re-made `work.db`).  A read or write that finds the store not open runs the
//! writer's tick (and the read connection's open) once itself first, so a work.db made or migrated between two ticks
//! is used at once.

use std::fmt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use urdr::graph::{OpenOutcome, Writer, WriterHandle, WriterOpts};
use urdr::graph::{TxMeta, WriteError};
use urdr::{Handle, Mode, Store, StoreSpec};

/// The schema the store writes (schema 8).
pub const SCHEMA: u32 = crate::migrate8::SCHEMA;

/// What a read closure sees: the connection (read-only).
pub type Tx = urdr::Connection;

/// What a write closure sees: the writer's transaction, inside its request's savepoint (committed on `Ok`, rolled
/// back on `Err`).  Its SQL runs through [`urdr::graph::Tx::sql`].
pub use urdr::graph::Tx as WTx;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoordError {
    /// The store is not open, with the text that says why: the graph writer's opening rule's text (a busy file, a
    /// schema below 6, a failed migration's reason).
    NotReady(String),
    /// The file is a newer schema than this writer knows: readable, never written.
    ReadOnly { schema: u32 },
    /// Another writer held the database past the busy timeout, or a batch's `COMMIT` failed (retry).
    Busy,
    /// The request is refused (a writer's own rule), with its text.
    Refused(String),
    /// SQLite or the store thread failed.
    Sql(String),
}

impl fmt::Display for CoordError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoordError::NotReady(text) => f.write_str(text),
            CoordError::ReadOnly { schema } => {
                write!(
                    f,
                    "work.db is schema {schema}, newer than this drgnx: read-only"
                )
            }
            CoordError::Busy => write!(f, "work.db is busy"),
            CoordError::Refused(text) => f.write_str(text),
            CoordError::Sql(text) => write!(f, "sql: {text}"),
        }
    }
}

impl std::error::Error for CoordError {}

impl From<urdr::Error> for CoordError {
    fn from(e: urdr::Error) -> Self {
        if urdr::is_busy(&e) {
            CoordError::Busy
        } else {
            CoordError::Sql(e.to_string())
        }
    }
}

impl From<urdr::SqliteError> for CoordError {
    fn from(e: urdr::SqliteError) -> Self {
        urdr::Error::Sqlite(e).into()
    }
}

impl From<WriteError> for CoordError {
    fn from(e: WriteError) -> Self {
        match e {
            WriteError::Refused(text) => CoordError::Refused(text),
            WriteError::Conflict(v) => CoordError::Refused(format!("conflict: {v}")),
            WriteError::Retryable(_) => CoordError::Busy,
            WriteError::ReadOnly { schema } => CoordError::ReadOnly { schema },
            WriteError::NotReady(text) => CoordError::NotReady(text),
            WriteError::Closed => CoordError::Sql("the store is closed".into()),
            WriteError::Sql(text) => CoordError::Sql(text),
        }
    }
}

fn file_id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// The read connection.
struct Open {
    /// `(dev, inode)` of the file when it was opened; `None` while not open.
    id: Option<(u64, u64)>,
    /// Owns the thread; dropping it stops the thread and closes the connection.
    _store: Option<Store>,
    handle: Option<Handle>,
}

fn open(path: &Path) -> Open {
    let id = file_id(path);
    let ro = StoreSpec {
        path: path.to_path_buf(),
        mode: Mode::ReadOnly,
        migrations: &[],
    };
    match Store::spawn(ro) {
        Ok((store, handle)) => Open {
            id,
            _store: Some(store),
            handle: Some(handle),
        },
        Err(_) => Open {
            id: None,
            _store: None,
            handle: None,
        },
    }
}

/// The coordination store: cheap to clone.
#[derive(Clone)]
pub struct CoordDb {
    path: Arc<PathBuf>,
    state: Arc<Mutex<Open>>,
    /// The graph writer: it makes or migrates the file (its rule's answer is the not-ready text) and runs every write.
    graph: WriterHandle,
    /// The writer [`CoordDb::spawn`] started (its thread stops with the last clone).
    _owner: Option<Arc<Writer>>,
}

impl CoordDb {
    /// A store with a graph writer of its own on `path` (the hub uses [`with_graph`](Self::with_graph)): the file is
    /// made at schema 7, or migrated from 6 (its backup, deny-list and config beside it), by the writer's opening
    /// rule, which has run when the first request is served.  For tests.
    pub fn spawn(path: impl Into<PathBuf>) -> CoordDb {
        let path = path.into();
        let dir = path
            .parent()
            .map_or_else(|| PathBuf::from("."), Path::to_path_buf);
        let opts = crate::migrate7::MigrateOpts {
            backup_dir: dir.join("backup"),
            home: dir.join("home"),
            config_dir: dir.join("config"),
        };
        let mut guard = urdr::graph::guard::Guard::default();
        crate::grants::register(&mut guard);
        let (writer, handle) = Writer::spawn(
            &path,
            WriterOpts {
                guard: Arc::new(guard),
                synchronous_full: false,
                ..WriterOpts::default()
            },
            crate::migrate7::open_rule(opts),
        )
        .expect("the writer thread starts");
        let mut db = CoordDb::with_graph(handle);
        db._owner = Some(Arc::new(writer));
        db
    }

    /// The hub's store on the graph writer's file: writes go through WRITER; reads through a connection of this
    /// store.  Opens the read connection once now (blocking).
    pub fn with_graph(writer: WriterHandle) -> CoordDb {
        let path = writer.path().to_path_buf();
        let state = open(&path);
        CoordDb {
            path: Arc::new(path),
            state: Arc::new(Mutex::new(state)),
            graph: writer,
            _owner: None,
        }
    }

    /// The graph writer.
    pub fn graph_writer(&self) -> Option<&WriterHandle> {
        Some(&self.graph)
    }

    /// The hub's schema tick: open the read connection when not open; open it again when the file at the path
    /// changed (dev, inode).  Blocking for the length of an open: call it from a blocking context (the graph writer's
    /// own tick first).
    pub fn tick(&self) {
        let mut st = self.state.lock().unwrap();
        let now = file_id(&self.path);
        let keep = st.id.is_some() && st.id == now;
        if !keep {
            *st = open(&self.path);
        }
    }

    /// Why the store is not open: the writer's rule says (a migration that failed or waits).
    fn closed(&self) -> CoordError {
        match self.graph.status().last_open {
            Some(OpenOutcome::NotReady(text) | OpenOutcome::Failed(text)) => {
                CoordError::NotReady(text)
            }
            Some(OpenOutcome::ReadOnly { schema }) => CoordError::ReadOnly { schema },
            Some(OpenOutcome::Ready { .. }) | None => {
                CoordError::NotReady("work.db is not open yet".into())
            }
        }
    }

    /// Whether the writer has opened the file (or found it newer: readable).
    fn open_for(&self, for_write: bool) -> bool {
        let s = self.graph.status();
        match s.last_open {
            Some(OpenOutcome::Ready { .. }) => s.open,
            Some(OpenOutcome::ReadOnly { .. }) => !for_write,
            _ => false,
        }
    }

    /// The store is open for FOR_WRITE, else the writer's tick (its opening rule again) and a look once more: a
    /// work.db made or migrated since the last tick is used at once, not at the next tick.  Every write and read goes
    /// through here, the front's methods and the coordination tools alike.
    async fn gate(&self, for_write: bool) -> Result<(), CoordError> {
        if !self.open_for(for_write) {
            self.graph.tick().await;
        }
        if self.open_for(for_write) {
            return Ok(());
        }
        if for_write && let Some(OpenOutcome::ReadOnly { schema }) = self.graph.status().last_open {
            return Err(CoordError::ReadOnly { schema });
        }
        Err(self.closed())
    }

    async fn reader(&self) -> Result<Handle, CoordError> {
        self.gate(false).await?;
        let got = self.state.lock().unwrap().handle.clone();
        if let Some(h) = got {
            return Ok(h);
        }
        let db = self.clone();
        let _ = tokio::task::spawn_blocking(move || db.tick()).await;
        let got = self.state.lock().unwrap().handle.clone();
        got.ok_or_else(|| CoordError::NotReady("work.db is not open yet".into()))
    }

    /// Run `f` in one request of the graph writer: its `tx` row first (from META), then `f` in its own savepoint,
    /// committed on `Ok` and rolled back on `Err`, answered after `COMMIT`.  A request with `meta.req` set whose key
    /// was answered before runs nothing and answers `Refused` ("already done"): a caller that replays a stored answer
    /// uses [`graph_writer`](Self::graph_writer) directly.
    pub async fn write<R: Send + 'static>(
        &self,
        meta: TxMeta,
        f: impl FnOnce(&mut WTx<'_>) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        self.gate(true).await?;
        let slot: Arc<Mutex<Option<Result<R, CoordError>>>> = Arc::new(Mutex::new(None));
        let theirs = slot.clone();
        let out = self
            .graph
            .write(meta, move |tx| match f(tx) {
                Ok(v) => {
                    *theirs.lock().unwrap() = Some(Ok(v));
                    Ok(())
                }
                Err(e) => {
                    let text = e.to_string();
                    *theirs.lock().unwrap() = Some(Err(e));
                    Err(WriteError::Refused(text))
                }
            })
            .await;
        let theirs = slot.lock().unwrap().take();
        match (out, theirs) {
            (_, Some(r)) => r,
            (Ok(_), None) => Err(CoordError::Refused(
                "this request was already done (its key was answered before)".into(),
            )),
            (Err(e), None) => Err(e.into()),
        }
    }

    /// Run `f` on the read connection's thread, outside a transaction.
    pub async fn read<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        let handle = self.reader().await?;
        run(f, handle).await
    }
}

/// Carry `f`'s own error out of urdr (which knows only its own): urdr rolls back on `Aborted`, the error waits in a
/// slot.
async fn run<R: Send + 'static>(
    f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    handle: Handle,
) -> Result<R, CoordError> {
    let slot: Arc<Mutex<Option<CoordError>>> = Arc::new(Mutex::new(None));
    let theirs = slot.clone();
    let job = move |c: &Tx| {
        f(c).map_err(|e| {
            *theirs.lock().unwrap() = Some(e);
            urdr::Error::Aborted
        })
    };
    match handle.read(job).await {
        Ok(v) => Ok(v),
        Err(urdr::Error::Aborted) => Err(slot
            .lock()
            .unwrap()
            .take()
            .unwrap_or_else(|| CoordError::Sql("rolled back".into()))),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use urdr::graph::Class;

    /// The schema-6 DDL as the Lisp migration makes it (`test/fixtures/work-db-6.sql`).
    pub(crate) const DDL: &str = include_str!("../../../../test/fixtures/work-db-6.sql");

    /// A schema-6 file at `path`; `schema` replaces the `meta.schema` row.
    pub(crate) fn make(path: &Path, schema: u32) {
        let c = urdr::Connection::open(path).unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute(
            "update meta set value = ?1 where key = 'schema'",
            [schema.to_string()],
        )
        .unwrap();
    }

    /// A fresh in-memory database as the opening rule leaves it (schema 8) for a writer's unit tests (`tx_of`
    /// makes the transaction).  The name is from schema 7.
    pub(crate) fn db7() -> urdr::Connection {
        let mut c = db7_only();
        assert!(crate::migrate8::upgrade(&mut c).unwrap());
        c
    }

    /// A fresh in-memory database at schema 7, before the step table.
    pub(crate) fn db7_only() -> urdr::Connection {
        let mut c = urdr::Connection::open_in_memory().unwrap();
        crate::migrate7::make_fresh(&mut c).unwrap();
        c
    }

    /// The author of the unit tests' writes.
    pub(crate) fn hub_meta() -> TxMeta {
        TxMeta::new("hub", Class::System, "test")
    }

    /// A transaction on C (it holds schema 7): dropping it without `commit_for_test` rolls its writes back.
    pub(crate) fn tx_of(c: &mut urdr::Connection) -> WTx<'_> {
        let mut guard = urdr::graph::guard::Guard::default();
        crate::grants::register(&mut guard);
        WTx::for_test(c, hub_meta(), Arc::new(guard))
    }

    /// The jobs task ids of the file, through schema 7's `jtask` view.
    async fn jtasks(db: &CoordDb) -> Vec<String> {
        db.read(|c| {
            let mut stmt = c.prepare("select id from jtask order by id")?;
            let rows = stmt.query_map([], |r| r.get(0))?;
            Ok(rows.collect::<Result<Vec<String>, _>>()?)
        })
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn opens_6_by_migrating_and_reopens_a_replaced_file() {
        use urdr::graph::{Writer, WriterOpts};
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let opts = crate::migrate7::MigrateOpts {
            backup_dir: dir.path().join("backup"),
            home: dir.path().join("home"),
            config_dir: dir.path().join("config"),
        };
        let six = |path: &Path, task: &str| {
            make(path, 6);
            let c = urdr::Connection::open(path).unwrap();
            c.execute(
                "insert into jtask (id, job, n, title, status) values (?1, 'j', 1, 't', 'open')",
                [task],
            )
            .unwrap();
        };
        // A schema-6 file: the graph writer migrates it at start, and the store opens schema 7 with its rows.
        six(&file, "j#1");
        let (writer, handle) = Writer::spawn(
            &file,
            WriterOpts::default(),
            crate::migrate7::open_rule(opts),
        )
        .unwrap();
        handle.tick().await;
        let db = CoordDb::with_graph(handle.clone());
        assert_eq!(jtasks(&db).await, ["j#1"]);
        db.write(hub_meta(), |tx| {
            Ok(tx
                .sql()
                .execute("insert into event (at, kind) values (1.0, 'x')", [])?)
        })
        .await
        .unwrap();
        // A schema-6 write on schema 7 fails: `meta` is a read-only view.
        assert!(
            db.write(hub_meta(), |tx| Ok(tx
                .sql()
                .execute("insert into meta values ('a', '1')", [])?))
                .await
                .is_err()
        );
        // A replaced file: migrated and opened again at the next tick; the old rows are gone. Its `-wal` and `-shm`
        // go with it (a WAL left beside a new file would be read into it; connections to the old file never remove
        // the new one's, as SQLite sees their file moved).
        let next = dir.path().join("next.db");
        let replace = |next: &Path| {
            for ext in ["-wal", "-shm"] {
                let _ = std::fs::remove_file(dir.path().join(format!("work.db{ext}")));
            }
            std::fs::rename(next, &file).unwrap();
        };
        six(&next, "j#2");
        replace(&next);
        handle.tick().await;
        db.tick();
        assert_eq!(jtasks(&db).await, ["j#2"], "the store follows the new file");
        // Schema 5: the rule's text, from the store as from the writer.
        make(&next, 5);
        replace(&next);
        handle.tick().await;
        db.tick();
        let e = db.write(hub_meta(), |_| Ok(())).await.unwrap_err();
        assert_eq!(
            e.to_string(),
            "work.db is schema 5; open it once with drgnx 6 first, or remove it (installs are disposable)"
        );
        // A newer schema: readable, never written.
        make(&next, 9);
        replace(&next);
        handle.tick().await;
        db.tick();
        assert_eq!(
            db.write(hub_meta(), |_| Ok(())).await.unwrap_err(),
            CoordError::ReadOnly { schema: 9 }
        );
        db.read(|c| Ok(c.query_row("select count(*) from meta", [], |r| r.get::<_, i64>(0))?))
            .await
            .unwrap();
        tokio::task::spawn_blocking(move || writer.shutdown())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn spawn_makes_a_missing_file_schema_7_and_moves_a_6() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let db = CoordDb::spawn(&file);
        db.write(hub_meta(), |tx| {
            Ok(tx
                .sql()
                .execute("insert into event (at, kind) values (1.0, 'x')", [])?)
        })
        .await
        .unwrap();
        assert!(file.exists());
        let kv: String = db
            .read(|c| {
                Ok(
                    c.query_row("select value from kv where key = 'schema'", [], |r| {
                        r.get(0)
                    })?,
                )
            })
            .await
            .unwrap();
        assert_eq!(kv, "8");
        let other = dir.path().join("other").join("work.db");
        std::fs::create_dir_all(other.parent().unwrap()).unwrap();
        make(&other, 6);
        let db = CoordDb::spawn(&other);
        assert_eq!(jtasks(&db).await.len(), 0);
        db.write(hub_meta(), |_| Ok(())).await.unwrap();
    }

    #[tokio::test]
    async fn writes_never_run_on_the_callers_thread_and_carry_their_author() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let db = CoordDb::spawn(&file);
        let me = std::thread::current().id();
        let there = db
            .write(hub_meta(), |_| Ok(std::thread::current().id()))
            .await
            .unwrap();
        assert_ne!(there, me);
        // A refusal rolls back and comes out as itself.
        let e = db
            .write(hub_meta(), |tx| {
                tx.sql().execute("insert into kv values ('z', '1')", [])?;
                Err::<(), _>(CoordError::Refused("no".into()))
            })
            .await
            .unwrap_err();
        assert_eq!(e, CoordError::Refused("no".into()));
        let n: i64 = db
            .read(|c| Ok(c.query_row("select count(*) from kv where key = 'z'", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 0);
        // The tx row of a write holds its author.
        let mut meta = TxMeta::new("agent:s-1", Class::Agent, "mcp:report_edit");
        meta.session = Some("s-1".into());
        db.write(meta, |tx| {
            Ok(tx.sql().execute(
                "insert into event (at, kind, tx) values (1.0, 'x', ?1)",
                [tx.id()],
            )?)
        })
        .await
        .unwrap();
        let (actor, class, tool, session): (String, String, String, Option<String>) = db
            .read(|c| {
                Ok(c.query_row(
                    "select actor, class, tool, session from tx where id = (select tx from event)",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )?)
            })
            .await
            .unwrap();
        assert_eq!(
            (
                actor.as_str(),
                class.as_str(),
                tool.as_str(),
                session.as_deref()
            ),
            ("agent:s-1", "agent", "mcp:report_edit", Some("s-1"))
        );
    }
}
