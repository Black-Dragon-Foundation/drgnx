//! The store thread: it owns the connection and runs closures sent over a bounded channel (design 5.2).

use crate::{Connection, Error, Mode, Result, StoreSpec, open_store};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use stund::Instant;
use tokio::sync::{mpsc, oneshot};

const QUEUE: usize = 256;

enum Job {
    /// A request: where it was asked from (the `read` or `write` call's place), and what to run.
    Run(
        &'static std::panic::Location<'static>,
        Box<dyn FnOnce(&Connection) + Send>,
    ),
    Stop,
}

/// What the store thread runs now: where its request came from and since when.
type Running = Arc<Mutex<Option<(&'static std::panic::Location<'static>, Instant)>>>;

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
    running: Running,
}

impl Store {
    /// Open the file (migrating a read-write one) on the caller, then move the connection to its own thread.
    pub fn spawn(spec: StoreSpec) -> Result<(Store, Handle)> {
        let writable = !matches!(spec.mode, Mode::ReadOnly);
        let conn = open_store(&spec)?;
        let (tx, mut rx) = mpsc::channel::<Job>(QUEUE);
        let running: Running = Arc::default();
        let seen = running.clone();
        let thread = saman::spawn_thread("urdr", move || {
            while let Some(Job::Run(at, job)) = rx.blocking_recv() {
                *saman::lock(&seen) = Some((at, Instant::now()));
                job(&conn);
                *saman::lock(&seen) = None;
            }
        })
        .map_err(|e| Error::Io(std::io::Error::other(e.to_string())))?;
        let handle = Handle {
            tx: tx.clone(),
            writable,
            running,
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
        saman::delivered(self.tx.blocking_send(Job::Stop), "urdr store stop");
        if let Some(t) = self.thread.take()
            && t.join().is_err()
        {
            tracing::warn!("the urdr store thread panicked outside a request");
        }
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        if self.thread.is_some() {
            saman::delivered(self.tx.try_send(Job::Stop), "urdr store stop");
        }
    }
}

impl Handle {
    /// How many requests wait on the channel now (the one running is not counted).
    pub fn queued(&self) -> usize {
        self.tx.max_capacity() - self.tx.capacity()
    }

    /// What the store thread runs now: the place its request was asked from (`file:line`) and for how long; none when it
    /// is idle.  For a hub that says what holds its store.
    pub fn running(&self) -> Option<(String, Duration)> {
        let r = saman::lock(&self.running);
        r.map(|(at, since)| (format!("{}:{}", at.file(), at.line()), since.elapsed()))
    }

    /// Run `f` on the store thread with the connection.
    #[track_caller]
    pub fn read<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
    ) -> impl std::future::Future<Output = Result<R>> + Send {
        let at = std::panic::Location::caller();
        self.submit(at, f, false)
    }

    /// Run `f` on the store thread inside `BEGIN IMMEDIATE`; committed on `Ok`, rolled back on `Err` or panic.
    #[track_caller]
    pub fn write<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
    ) -> impl std::future::Future<Output = Result<R>> + Send {
        let at = std::panic::Location::caller();
        let writable = self.writable;
        async move {
            if !writable {
                return Err(Error::ReadOnly);
            }
            self.submit(at, f, true).await
        }
    }

    async fn submit<R: Send + 'static>(
        &self,
        at: &'static std::panic::Location<'static>,
        f: impl FnOnce(&Connection) -> Result<R> + Send + 'static,
        in_txn: bool,
    ) -> Result<R> {
        #[cfg(feature = "test-hooks")]
        let _waiting = crate::wait::begin();
        let (reply, answer) = oneshot::channel();
        let job = Job::Run(
            at,
            Box::new(move |conn: &Connection| {
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
                                rollback(conn);
                            }
                            Error::from(e)
                        }),
                        Err(e) => {
                            rollback(conn);
                            Err(e)
                        }
                    }
                }));
                if out.is_err() && in_txn {
                    rollback(conn);
                }
                saman::delivered(
                    reply.send(out.unwrap_or(Err(Error::Panicked))),
                    "urdr store reply",
                );
            }),
        );
        self.tx.send(job).await.map_err(|_| Error::Closed)?;
        answer.await.map_err(|_| Error::Closed)?
    }
}

/// ROLLBACK after a failed request; a rollback that itself fails leaves SQLite's own state (no open transaction).
pub(crate) fn rollback(conn: &Connection) {
    if let Err(e) = conn.execute_batch("ROLLBACK") {
        tracing::debug!(error = %e, "urdr: ROLLBACK found nothing to roll back");
    }
}

#[cfg(test)]
mod tests {
    /// The store thread says what it runs now: the place its request was asked from and how long it has run; idle
    /// when nothing runs.
    #[test]
    fn the_thread_says_what_it_runs_and_since_when() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let spec = StoreSpec {
                path: dir.path().join("t.db"),
                mode: Mode::ReadWrite {
                    file_mode: 0o600,
                    synchronous_full: false,
                },
                migrations: &[(1, "create table t(x);")],
            };
            let (store, h) = Store::spawn(spec).unwrap();
            assert!(h.running().is_none(), "idle at first");
            let (held, holding) = std::sync::mpsc::channel::<()>();
            let (release, released) = std::sync::mpsc::channel::<()>();
            let h2 = h.clone();
            let job = saman::spawn("urdr-test", async move {
                h2.read(move |_| {
                    saman::delivered(held.send(()), "test: the job started");
                    released.recv().expect("the test releases the job");
                    Ok(())
                })
                .await
            });
            saman::spawn_blocking("urdr-test", move || holding.recv().unwrap())
                .await
                .unwrap();
            let (at, age) = h.running().expect("the job runs");
            // the request came from this file (`file!()` is the path `Location` reports, wherever the crate sits)
            assert!(at.starts_with(concat!(file!(), ":")), "{at}");
            assert!(age < std::time::Duration::from_secs(60));
            release.send(()).unwrap();
            job.await.unwrap().unwrap();
            // idle again once it ended (the thread notes it just after the reply)
            let h = saman::spawn_blocking("urdr-test", move || {
                skuld::wait_until("the thread is idle again", 30, || {
                    h.running().is_none().then_some(())
                });
                h
            })
            .await
            .unwrap();
            drop(h);
            saman::spawn_blocking("urdr-test", move || store.shutdown())
                .await
                .unwrap();
        })
    }

    use crate::{Mode, Store, StoreSpec};

    #[test]
    fn reads_never_run_on_the_caller_thread() {
        saman::block_on_current(async {
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
            saman::spawn_blocking("urdr-test", move || store.shutdown())
                .await
                .unwrap();
            assert!(handle.read(|_| Ok(())).await.is_err());
        })
    }

    /// Review m3: a COMMIT that fails with the transaction still open (SQLite keeps it open on a deferred
    /// foreign-key violation, as on BUSY) is rolled back, so the next write starts and commits.
    #[test]
    fn a_failed_commit_leaves_no_open_transaction() {
        saman::block_on_current(async {
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
            saman::spawn_blocking("urdr-test", move || store.shutdown())
                .await
                .unwrap();
        })
    }
}
