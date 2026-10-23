//! The writer's thread and its one read-write connection (docs/develop/coordination.md, "The writer").
//!
//! [`CoordDb`] opens `work.db` only when `meta.schema` is exactly the schema it expects.  The hub's
//! ([`CoordDb::with_graph`]) expects schema 7, which the graph writer makes or migrates to at start
//! ([`crate::migrate7`]); [`CoordDb::spawn`] expects [`SCHEMA`] 6, the file the Lisp side made, for the p2–p3 tests
//! until Urdr's Task 12 moves the writers onto the graph writer.  Every statement runs on `urdr`'s store thread, never
//! on the caller's.  The hub's 2 s schema tick calls [`CoordDb::tick`], which opens the file when it is not open and
//! opens it again when the file at the path is another file than the one opened (a removed and re-made `work.db`).
//! A read or write that finds the file not open runs the tick's open once itself first (the graph writer's tick
//! first), so a work.db made or migrated between two ticks is used at once.

use std::fmt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use urdr::graph::{OpenOutcome, WriterHandle};
use urdr::{Handle, Mode, Store, StoreSpec};

/// The schema [`CoordDb::spawn`] opens (the Lisp side's file).
pub const SCHEMA: u32 = 6;

/// What a write closure sees: the connection, already inside `BEGIN IMMEDIATE` (committed on `Ok`, rolled back on
/// `Err`).
pub type Tx = urdr::Connection;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoordError {
    /// The store is not open, with the text that says why: the graph writer's opening rule's text (a busy file, a
    /// schema below 6, a failed migration's reason), or for [`CoordDb::spawn`] a file missing or below schema 6.
    NotReady(String),
    /// The file is a newer schema than this writer knows: readable, never written.
    ReadOnly { schema: u32 },
    /// Another writer held the database past the busy timeout.
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

/// How the file at the path is held.
enum Held {
    /// Not open: the file is missing (0) or at this schema.
    Closed { schema: u32 },
    /// Read-write, at the expected schema.
    Writable,
    /// A newer schema, opened read-only.
    Newer { schema: u32 },
}

struct Open {
    held: Held,
    /// `(dev, inode)` of the file when it was opened.
    id: Option<(u64, u64)>,
    /// Owns the thread; dropping it stops the thread and closes the connection.
    _store: Option<Store>,
    handle: Option<Handle>,
}

/// The coordination store: cheap to clone.
#[derive(Clone)]
pub struct CoordDb {
    path: Arc<PathBuf>,
    state: Arc<Mutex<Open>>,
    /// The schema opened read-write.
    expect: u32,
    /// The hub's graph writer, which makes or migrates the file (its rule's answer is the not-ready text).
    graph: Option<WriterHandle>,
}

/// The not-ready text of a file at SCHEMA (0: missing).
fn not_ready(schema: u32) -> CoordError {
    CoordError::NotReady(format!(
        "work.db is not ready (schema {schema}); the Lisp side makes it"
    ))
}

fn file_id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

fn open(path: &Path, expect: u32) -> Open {
    let id = file_id(path);
    let closed = |schema| Open {
        held: Held::Closed { schema },
        id: None,
        _store: None,
        handle: None,
    };
    let rw = StoreSpec {
        path: path.to_path_buf(),
        mode: Mode::ReadWriteExisting {
            expect_schema: expect,
            synchronous_full: false,
        },
        migrations: &[],
    };
    match Store::spawn(rw) {
        Ok((store, handle)) => Open {
            held: Held::Writable,
            id,
            _store: Some(store),
            handle: Some(handle),
        },
        Err(urdr::Error::Schema { found }) if found > expect => {
            let ro = StoreSpec {
                path: path.to_path_buf(),
                mode: Mode::ReadOnly,
                migrations: &[],
            };
            match Store::spawn(ro) {
                Ok((store, handle)) => Open {
                    held: Held::Newer { schema: found },
                    id,
                    _store: Some(store),
                    handle: Some(handle),
                },
                Err(_) => closed(found),
            }
        }
        Err(urdr::Error::Schema { found }) => closed(found),
        Err(urdr::Error::Missing) => closed(0),
        Err(e) => {
            tracing::warn!("work.db: cannot open for writing: {e}");
            closed(0)
        }
    }
}

impl CoordDb {
    /// A store on `path` at [`SCHEMA`] 6, the file the Lisp side made (the p2–p3 tests; the hub uses
    /// [`with_graph`](Self::with_graph)); it tries to open once now (a short, blocking look), then at each
    /// [`tick`](Self::tick).
    pub fn spawn(path: impl Into<PathBuf>) -> CoordDb {
        let path = path.into();
        let state = open(&path, SCHEMA);
        CoordDb {
            path: Arc::new(path),
            state: Arc::new(Mutex::new(state)),
            expect: SCHEMA,
            graph: None,
        }
    }

    /// The hub's store on the graph writer's file, at schema 7: the writer's opening rule makes or migrates it
    /// ([`crate::migrate7::open_rule`]); while it has not, a write answers the rule's text. Opens once now (blocking).
    pub fn with_graph(writer: WriterHandle) -> CoordDb {
        let path = writer.path().to_path_buf();
        let expect = crate::migrate7::SCHEMA;
        let state = open(&path, expect);
        CoordDb {
            path: Arc::new(path),
            state: Arc::new(Mutex::new(state)),
            expect,
            graph: Some(writer),
        }
    }

    /// The graph writer [`with_graph`](Self::with_graph) was given.
    pub fn graph_writer(&self) -> Option<&WriterHandle> {
        self.graph.as_ref()
    }

    /// The hub's schema tick: open when not open; open again when the file at the path changed (dev, inode).  Blocking
    /// for the length of an open: call it from a blocking context (the graph writer's own tick first).
    pub fn tick(&self) {
        let mut st = self.state.lock().unwrap();
        let now = file_id(&self.path);
        let keep = match st.held {
            Held::Closed { .. } => false,
            _ => st.id == now && now.is_some(),
        };
        if !keep {
            *st = open(&self.path, self.expect);
        }
    }

    /// Why the file is not open: the graph writer's rule says (a migration that failed or waits, a newer file), else
    /// the schema found.
    fn closed(&self, schema: u32) -> CoordError {
        match self.graph.as_ref().and_then(|w| w.status().last_open) {
            Some(OpenOutcome::NotReady(text) | OpenOutcome::Failed(text)) => {
                CoordError::NotReady(text)
            }
            Some(OpenOutcome::ReadOnly { schema }) => CoordError::ReadOnly { schema },
            Some(OpenOutcome::Ready { .. }) | None if self.graph.is_some() => {
                CoordError::NotReady(format!("work.db is not open yet (schema {schema})"))
            }
            _ => not_ready(schema),
        }
    }

    fn handle(&self, for_write: bool) -> Result<Handle, CoordError> {
        let st = self.state.lock().unwrap();
        match (&st.held, &st.handle) {
            (Held::Closed { schema }, _) => Err(self.closed(*schema)),
            (Held::Newer { schema }, _) if for_write => {
                Err(CoordError::ReadOnly { schema: *schema })
            }
            (_, Some(h)) => Ok(h.clone()),
            _ => Err(self.closed(0)),
        }
    }

    /// [`handle`](Self::handle), but a file that is not open is looked at once more first (the graph writer's tick,
    /// then the tick's open, on a blocking thread): a work.db made or migrated since the last tick is used at once,
    /// not at the next tick.  Every write and read goes through here, the front's methods and the coordination tools
    /// alike.
    async fn ready(&self, for_write: bool) -> Result<Handle, CoordError> {
        match self.handle(for_write) {
            Err(CoordError::NotReady(_)) => {
                if let Some(w) = &self.graph {
                    w.tick().await;
                }
                let db = self.clone();
                let _ = tokio::task::spawn_blocking(move || db.tick()).await;
                self.handle(for_write)
            }
            r => r,
        }
    }

    /// Run `f` on the store thread inside one `BEGIN IMMEDIATE` transaction: committed on `Ok`, rolled back on `Err`.
    pub async fn write<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        let handle = self.ready(true).await?;
        run(f, true, handle).await
    }

    /// Run `f` on the store thread, outside a transaction.
    pub async fn read<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        let handle = self.ready(false).await?;
        run(f, false, handle).await
    }
}

/// Carry `f`'s own error out of urdr (which knows only its own): urdr rolls back on `Aborted`, the error waits in a
/// slot.
async fn run<R: Send + 'static>(
    f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    write: bool,
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
    let out = if write {
        handle.write(job).await
    } else {
        handle.read(job).await
    };
    match out {
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
        db.write(|c| Ok(c.execute("insert into event (at, kind) values (1.0, 'x')", [])?))
            .await
            .unwrap();
        // A schema-6 write on schema 7 fails (the view refuses it, until Task 12's writers).
        assert!(
            db.write(|c| Ok(c.execute("insert into meta values ('a', '1')", [])?))
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
        let e = db.write(|_| Ok(())).await.unwrap_err();
        assert_eq!(
            e.to_string(),
            "work.db is schema 5; open it once with drgnx 6 first, or remove it (installs are disposable)"
        );
        // A newer schema: readable, never written.
        make(&next, 8);
        replace(&next);
        handle.tick().await;
        db.tick();
        assert_eq!(
            db.write(|_| Ok(())).await.unwrap_err(),
            CoordError::ReadOnly { schema: 8 }
        );
        db.read(|c| Ok(c.query_row("select count(*) from meta", [], |r| r.get::<_, i64>(0))?))
            .await
            .unwrap();
        tokio::task::spawn_blocking(move || writer.shutdown())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn spawn_still_opens_only_schema_6() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let db = CoordDb::spawn(&file);
        // Missing: not ready, and nothing is created.
        assert_eq!(db.write(|_| Ok(())).await.unwrap_err(), not_ready(0));
        assert!(!file.exists());
        make(&file, 6);
        db.tick();
        db.write(|c| Ok(c.execute("insert into meta values ('a', '1')", [])?))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn writes_never_run_on_the_callers_thread() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        make(&file, 6);
        let db = CoordDb::spawn(&file);
        let me = std::thread::current().id();
        let there = db.write(|_| Ok(std::thread::current().id())).await.unwrap();
        assert_ne!(there, me);
        // A refusal rolls back and comes out as itself.
        let e = db
            .write(|c| {
                c.execute("insert into meta values ('z', '1')", [])?;
                Err::<(), _>(CoordError::Refused("no".into()))
            })
            .await
            .unwrap_err();
        assert_eq!(e, CoordError::Refused("no".into()));
        let n: i64 = db
            .read(|c| {
                Ok(
                    c.query_row("select count(*) from meta where key = 'z'", [], |r| {
                        r.get(0)
                    })?,
                )
            })
            .await
            .unwrap();
        assert_eq!(n, 0);
    }
}
