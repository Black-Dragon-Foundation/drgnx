//! The store thread: it owns the connection and runs closures sent over a bounded channel (design 5.2).

use crate::{Connection, Error, Mode, Result, StoreSpec, open_store};
use std::panic::{AssertUnwindSafe, catch_unwind};
use tokio::sync::{mpsc, oneshot};

const QUEUE: usize = 256;

enum Job {
    Run(Box<dyn FnOnce(&Connection) + Send>),
    Stop,
}

/// Owns the store thread. `shutdown` (or drop) stops it; pending requests fail with `Error::Closed`.
pub struct Store {
    tx: mpsc::Sender<Job>,
    thread: Option<std::thread::JoinHandle<()>>,
}

/// A cheap, cloneable way to send closures to the store thread.
#[derive(Clone)]
pub struct Handle {
    tx: mpsc::Sender<Job>,
    writable: bool,
}

impl Store {
    /// Open the file (migrating a read-write one) on the caller, then move the connection to its own thread.
    pub fn spawn(spec: StoreSpec) -> Result<(Store, Handle)> {
        let writable = !matches!(spec.mode, Mode::ReadOnly);
        let conn = open_store(&spec)?;
        let (tx, mut rx) = mpsc::channel::<Job>(QUEUE);
        let thread = std::thread::Builder::new()
            .name("urdr".into())
            .spawn(move || {
                while let Some(Job::Run(job)) = rx.blocking_recv() {
                    job(&conn);
                }
            })?;
        let handle = Handle {
            tx: tx.clone(),
            writable,
        };
        Ok((
            Store {
                tx,
                thread: Some(thread),
            },
            handle,
        ))
    }

    /// Stop the thread and wait for it, which closes the connection. Blocking: not for an async worker.
    pub fn shutdown(mut self) {
        let _ = self.tx.blocking_send(Job::Stop);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        if self.thread.is_some() {
            let _ = self.tx.try_send(Job::Stop);
        }
    }
}

impl Handle {
    /// Run `f` on the store thread with the connection.
    pub async fn read<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
    ) -> Result<R> {
        self.submit(f, false).await
    }

    /// Run `f` on the store thread inside `BEGIN IMMEDIATE`; committed on `Ok`, rolled back on `Err` or panic.
    pub async fn write<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
    ) -> Result<R> {
        if !self.writable {
            return Err(Error::ReadOnly);
        }
        self.submit(f, true).await
    }

    async fn submit<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
        in_txn: bool,
    ) -> Result<R> {
        let (reply, answer) = oneshot::channel();
        let job = Job::Run(Box::new(move |conn: &Connection| {
            let out = catch_unwind(AssertUnwindSafe(|| {
                if !in_txn {
                    return f(conn);
                }
                conn.execute_batch("BEGIN IMMEDIATE")?;
                match f(conn) {
                    // A failed COMMIT (BUSY, FULL, IOERR, a deferred constraint) may leave the transaction open:
                    // roll it back, or every later BEGIN IMMEDIATE fails and the write lock stays held.
                    Ok(v) => conn.execute_batch("COMMIT").map(|()| v).map_err(|e| {
                        if !conn.is_autocommit() {
                            let _ = conn.execute_batch("ROLLBACK");
                        }
                        Error::from(e)
                    }),
                    Err(e) => {
                        let _ = conn.execute_batch("ROLLBACK");
                        Err(e)
                    }
                }
            }));
            if out.is_err() && in_txn {
                let _ = conn.execute_batch("ROLLBACK");
            }
            let _ = reply.send(out.unwrap_or(Err(Error::Panicked)));
        }));
        self.tx.send(job).await.map_err(|_| Error::Closed)?;
        answer.await.map_err(|_| Error::Closed)?
    }
}

#[cfg(test)]
mod tests {
    use crate::{Mode, Store, StoreSpec};

    #[tokio::test]
    async fn reads_never_run_on_the_caller_thread() {
        let dir = tempfile::tempdir().unwrap();
        let spec = StoreSpec {
            path: dir.path().join("a.db"),
            mode: Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: false,
            },
            migrations: &[(1, "create table t(x);")],
        };
        let (store, handle) = Store::spawn(spec).unwrap();
        let me = std::thread::current().id();
        let r = handle
            .read(|_| Ok(std::thread::current().id()))
            .await
            .unwrap();
        let w = handle
            .write(|c| {
                c.execute("insert into t values (1)", [])?;
                Ok(std::thread::current().id())
            })
            .await
            .unwrap();
        assert_ne!(r, me);
        assert_eq!(r, w, "one store thread owns the connection");
        let n: i64 = handle
            .read(|c| Ok(c.query_row("select count(*) from t", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 1);
        // A failing write rolls back.
        let e = handle
            .write(|c| {
                c.execute("insert into t values (2)", [])?;
                Err::<(), _>(crate::Error::Closed)
            })
            .await;
        assert!(e.is_err());
        let n: i64 = handle
            .read(|c| Ok(c.query_row("select count(*) from t", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 1);
        tokio::task::spawn_blocking(move || store.shutdown())
            .await
            .unwrap();
        assert!(handle.read(|_| Ok(())).await.is_err());
    }

    /// Review m3: a COMMIT that fails with the transaction still open (SQLite keeps it open on a deferred
    /// foreign-key violation, as on BUSY) is rolled back, so the next write starts and commits.
    #[tokio::test]
    async fn a_failed_commit_leaves_no_open_transaction() {
        let dir = tempfile::tempdir().unwrap();
        let spec = StoreSpec {
            path: dir.path().join("a.db"),
            mode: Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: false,
            },
            migrations: &[(
                1,
                "create table p(id integer primary key);
                 create table c(p integer references p(id) deferrable initially deferred);",
            )],
        };
        let (store, handle) = Store::spawn(spec).unwrap();
        handle
            .read(|c| Ok(c.execute_batch("pragma foreign_keys = on")?))
            .await
            .unwrap();
        let e = handle
            .write(|c| Ok(c.execute("insert into c values (9)", [])?))
            .await;
        assert!(e.is_err(), "the COMMIT must fail: {e:?}");
        assert!(handle.read(|c| Ok(c.is_autocommit())).await.unwrap());
        handle
            .write(|c| Ok(c.execute("insert into p values (1)", [])?))
            .await
            .unwrap();
        let n: i64 = handle
            .read(|c| Ok(c.query_row("select count(*) from p", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 1);
        let n: i64 = handle
            .read(|c| Ok(c.query_row("select count(*) from c", [], |r| r.get(0))?))
            .await
            .unwrap();
        assert_eq!(n, 0, "the refused write is gone");
        tokio::task::spawn_blocking(move || store.shutdown())
            .await
            .unwrap();
    }
}
