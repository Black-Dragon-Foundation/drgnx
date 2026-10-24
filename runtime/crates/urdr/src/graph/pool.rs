//! The read pool: 2–4 `mode=ro` connections from [`crate::open_readonly`] (never checkpoint), handed out one at a
//! time on a blocking thread, never held across an await by callers (Task 6).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::Connection;
use tokio::sync::Semaphore;

use crate::{Error, open_readonly};

/// Read-only connections to one database file; cheap to clone.
#[derive(Clone)]
pub struct ReadPool {
    path: Arc<PathBuf>,
    /// Connections not in use. At most `size` exist at once: a call holds a permit while it holds one.
    idle: Arc<Mutex<Vec<Connection>>>,
    permits: Arc<Semaphore>,
    size: usize,
}

impl ReadPool {
    /// A pool of SIZE connections (at least one) to PATH, opened when first used.
    pub fn open(path: impl Into<PathBuf>, size: usize) -> ReadPool {
        let size = size.max(1);
        ReadPool {
            path: Arc::new(path.into()),
            idle: Arc::new(Mutex::new(Vec::with_capacity(size))),
            permits: Arc::new(Semaphore::new(size)),
            size,
        }
    }

    /// The connections in use now (`status.store.readers`).
    pub fn in_use(&self) -> usize {
        self.size.saturating_sub(self.permits.available_permits())
    }

    /// Run F with one connection, off the async workers, and give the connection back. `Err` when no connection
    /// could be opened. A connection F leaves inside a transaction (holding a snapshot that would block
    /// checkpoints) is closed instead of given back.
    pub async fn with<R, F>(&self, f: F) -> crate::Result<R>
    where
        R: Send + 'static,
        F: FnOnce(&Connection) -> R + Send + 'static,
    {
        let permit = Arc::clone(&self.permits)
            .acquire_owned()
            .await
            .map_err(|_| Error::Closed)?;
        let path = Arc::clone(&self.path);
        let idle = Arc::clone(&self.idle);
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let conn = match lock(&idle).pop() {
                Some(conn) => conn,
                None => open_readonly(&path)?,
            };
            let out = f(&conn);
            if conn.is_autocommit() {
                lock(&idle).push(conn);
            }
            Ok(out)
        })
        .await
        .map_err(|_| Error::Panicked)?
    }

    /// The database file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// The idle list; a panic elsewhere never leaves it unusable (it holds no invariant a panic could break).
fn lock(idle: &Mutex<Vec<Connection>>) -> MutexGuard<'_, Vec<Connection>> {
    idle.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::limits::Limit;

    fn fixture() -> (tempfile::TempDir, ReadPool) {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let w = Connection::open(&file).unwrap();
        w.pragma_update(None, "journal_mode", "wal").unwrap();
        w.execute_batch("create table t(x); insert into t values (1);")
            .unwrap();
        drop(w);
        let pool = ReadPool::open(file, 1);
        (dir, pool)
    }

    #[tokio::test]
    async fn connections_are_read_only() {
        let (_dir, pool) = fixture();
        let n: i64 = pool
            .with(|c| c.query_row("select x from t", [], |r| r.get(0)).unwrap())
            .await
            .unwrap();
        assert_eq!(n, 1);
        for sql in [
            "insert into t values (2)",
            "update t set x = 3",
            "delete from t",
            "create table u(y)",
        ] {
            let r = pool.with(move |c| c.execute(sql, [])).await.unwrap();
            assert!(r.is_err(), "{sql} wrote through a pool connection");
        }
        let n: i64 = pool
            .with(|c| {
                c.query_row("select count(*) from t", [], |r| r.get(0))
                    .unwrap()
            })
            .await
            .unwrap();
        assert_eq!(n, 1);
    }

    #[tokio::test]
    async fn with_returns_the_connection() {
        let (_dir, pool) = fixture();
        // A mark on the connection (a lowered limit) is still there on the next call: the same connection came back.
        let default = pool
            .with(|c| {
                c.set_limit(Limit::SQLITE_LIMIT_VARIABLE_NUMBER, 77)
                    .unwrap()
            })
            .await
            .unwrap();
        assert_ne!(default, 77);
        let seen = pool
            .with(|c| c.limit(Limit::SQLITE_LIMIT_VARIABLE_NUMBER).unwrap())
            .await
            .unwrap();
        assert_eq!(seen, 77);
        // Calls beyond the pool's size wait for the one connection, and all finish.
        let calls: Vec<_> = (0..4)
            .map(|_| {
                let pool = pool.clone();
                tokio::spawn(async move {
                    pool.with(|c| c.limit(Limit::SQLITE_LIMIT_VARIABLE_NUMBER).unwrap())
                        .await
                        .unwrap()
                })
            })
            .collect();
        for call in calls {
            assert_eq!(call.await.unwrap(), 77);
        }
        // A connection left inside a transaction is closed, not given back: the next call gets a fresh one.
        pool.with(|c| c.execute_batch("begin; select x from t;").unwrap())
            .await
            .unwrap();
        let (fresh, autocommit) = pool
            .with(|c| {
                (
                    c.limit(Limit::SQLITE_LIMIT_VARIABLE_NUMBER).unwrap(),
                    c.is_autocommit(),
                )
            })
            .await
            .unwrap();
        assert_eq!(fresh, default);
        assert!(autocommit);
        // A missing file is an error, not a panic.
        let gone = ReadPool::open(pool.path().with_file_name("missing.db"), 2);
        assert!(gone.with(|_| ()).await.is_err());
    }
}
