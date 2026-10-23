//! The writer's thread and its one read-write connection (docs/develop/coordination.md, "The writer").
//!
//! [`CoordDb`] opens `work.db` only when `meta.schema` is exactly [`SCHEMA`] (the Lisp side makes and migrates the
//! file; Ratatoskr never does).  Every statement runs on `urdr`'s store thread, never on the caller's.  The hub's 2 s
//! schema tick calls [`CoordDb::tick`], which opens the file when it is not open and opens it again when the file at
//! the path is another file than the one opened (a removed and re-made `work.db`).

use std::fmt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use urdr::{Handle, Mode, Store, StoreSpec};

/// The schema the writer opens.
pub const SCHEMA: u32 = 6;

/// What a write closure sees: the connection, already inside `BEGIN IMMEDIATE` (committed on `Ok`, rolled back on
/// `Err`).
pub type Tx = urdr::Connection;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoordError {
    /// The file is missing or below schema 6: the Lisp side makes it.
    NotReady { schema: u32 },
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
            CoordError::NotReady { schema } => {
                write!(f, "work.db is not ready (schema {schema}); the Lisp side makes it")
            }
            CoordError::ReadOnly { schema } => {
                write!(f, "work.db is schema {schema}, newer than this drgnx: read-only")
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
    /// Read-write, schema 6.
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
}

fn file_id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

fn open(path: &Path) -> Open {
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
            expect_schema: SCHEMA,
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
        Err(urdr::Error::Schema { found }) if found > SCHEMA => {
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
    /// A store on `path`; it tries to open once now (a short, blocking look), then at each [`tick`](Self::tick).
    pub fn spawn(path: impl Into<PathBuf>) -> CoordDb {
        let path = path.into();
        let state = open(&path);
        CoordDb {
            path: Arc::new(path),
            state: Arc::new(Mutex::new(state)),
        }
    }

    /// The hub's schema tick: open when not open; open again when the file at the path changed (dev, inode).  Blocking
    /// for the length of an open: call it from a blocking context.
    pub fn tick(&self) {
        let mut st = self.state.lock().unwrap();
        let now = file_id(&self.path);
        let keep = match st.held {
            Held::Closed { .. } => false,
            _ => st.id == now && now.is_some(),
        };
        if !keep {
            *st = open(&self.path);
        }
    }

    fn handle(&self, for_write: bool) -> Result<Handle, CoordError> {
        let st = self.state.lock().unwrap();
        match (&st.held, &st.handle) {
            (Held::Closed { schema }, _) => Err(CoordError::NotReady { schema: *schema }),
            (Held::Newer { schema }, _) if for_write => Err(CoordError::ReadOnly { schema: *schema }),
            (_, Some(h)) => Ok(h.clone()),
            _ => Err(CoordError::NotReady { schema: 0 }),
        }
    }

    /// Run `f` on the store thread inside one `BEGIN IMMEDIATE` transaction: committed on `Ok`, rolled back on `Err`.
    pub async fn write<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        let handle = self.handle(true)?;
        run(f, true, handle).await
    }

    /// Run `f` on the store thread, outside a transaction.
    pub async fn read<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Tx) -> Result<R, CoordError> + Send + 'static,
    ) -> Result<R, CoordError> {
        let handle = self.handle(false)?;
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
        c.execute("update meta set value = ?1 where key = 'schema'", [schema.to_string()])
            .unwrap();
    }

    #[tokio::test]
    async fn opens_only_schema_6_and_reopens_a_replaced_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let db = CoordDb::spawn(&file);
        // Missing: not ready, and nothing is created.
        let e = db.write(|_| Ok(())).await.unwrap_err();
        assert_eq!(e, CoordError::NotReady { schema: 0 });
        assert!(!file.exists());
        // Schema 5: not ready, with the text the design names.
        make(&file, 5);
        db.tick();
        let e = db.write(|_| Ok(())).await.unwrap_err();
        assert_eq!(e, CoordError::NotReady { schema: 5 });
        assert_eq!(
            e.to_string(),
            "work.db is not ready (schema 5); the Lisp side makes it"
        );
        // Schema 6: opens at the next tick.
        let next = dir.path().join("next.db");
        make(&next, 6);
        std::fs::rename(&next, &file).unwrap();
        db.tick();
        db.write(|c| Ok(c.execute("insert into meta values ('a', '1')", [])?))
            .await
            .unwrap();
        // A removed and re-made file: the old rows are gone after the tick.
        let next = dir.path().join("next.db");
        make(&next, 6);
        std::fs::rename(&next, &file).unwrap();
        db.tick();
        let n: i64 = db
            .read(|c| Ok(c.query_row("select count(*) from meta where key = 'a'", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 0, "the writer follows the new file");
        // A newer schema: readable, never written.
        make(&next, 7);
        std::fs::rename(&next, &file).unwrap();
        db.tick();
        assert_eq!(
            db.write(|_| Ok(())).await.unwrap_err(),
            CoordError::ReadOnly { schema: 7 }
        );
        db.read(|c| Ok(c.query_row("select count(*) from meta", [], |r| r.get::<_, i64>(0))?))
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
            .read(|c| Ok(c.query_row("select count(*) from meta where key = 'z'", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 0);
    }
}
