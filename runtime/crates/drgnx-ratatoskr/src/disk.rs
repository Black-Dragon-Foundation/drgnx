//! Files written in order, off the hub's two async workers.
//!
//! A write that waits on the disk (a btrfs commit held an `openat` 280 ms under load) must hold no worker, and no
//! lock that another task waits for.  An [`Ordered`] belongs to whatever owns its files (a session, a debug root):
//! its writes are queued as closures, so taken under the owner's lock they queue in the order of the states they
//! read, and one task runs them one at a time on the blocking pool.  A write's error reaches the owner's report
//! (a log line by default), never dropped.  The paths that need the files to have landed (a turn's prompt, a close,
//! a reader of the file) await [`Ordered::written`].  A write keeps its own durability (a temp file, its fsync, the
//! rename): the queue only moves where it runs.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

type Job = Box<dyn FnOnce() -> std::io::Result<()> + Send>;
type Report = Arc<dyn Fn(&str, std::io::Error) + Send + Sync>;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Default)]
struct Pending {
    jobs: VecDeque<(String, Job)>,
    /// The task is running them.
    running: bool,
    /// Writes queued so far.
    queued: u64,
}

pub(crate) struct Ordered {
    /// The task's name (the stall watchdog's).
    task: &'static str,
    report: Report,
    pending: Arc<Mutex<Pending>>,
    /// Writes done so far, in queue order (a failed or panicked one too).
    done: Arc<tokio::sync::watch::Sender<u64>>,
}

impl Ordered {
    /// Writes run by the task named TASK; a failed one is logged as "WHAT: error".
    pub(crate) fn new(task: &'static str) -> Ordered {
        Ordered::reporting(task, |what, e| tracing::warn!("{what}: {e}"))
    }

    /// Writes run by the task named TASK; a failed one goes to REPORT with its WHAT.
    pub(crate) fn reporting(
        task: &'static str,
        report: impl Fn(&str, std::io::Error) + Send + Sync + 'static,
    ) -> Ordered {
        Ordered {
            task,
            report: Arc::new(report),
            pending: Arc::default(),
            done: Arc::new(tokio::sync::watch::channel(0).0),
        }
    }

    /// WRITE after every write queued before it; WHAT names it in a report of its error.
    pub(crate) fn push(
        &self,
        what: impl Into<String>,
        write: impl FnOnce() -> std::io::Result<()> + Send + 'static,
    ) {
        let mut p = lock(&self.pending);
        p.jobs.push_back((what.into(), Box::new(write)));
        p.queued += 1;
        if p.running {
            return;
        }
        p.running = true;
        drop(p);
        let (pending, done, report) =
            (self.pending.clone(), self.done.clone(), self.report.clone());
        crate::clock::spawn(self.task, async move {
            loop {
                let (what, job) = {
                    let mut p = lock(&pending);
                    match p.jobs.pop_front() {
                        Some(j) => j,
                        None => {
                            p.running = false;
                            return;
                        }
                    }
                };
                match crate::clock::blocking(job).await {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => report(&what, e),
                    Err(e) => report(
                        &what,
                        std::io::Error::other(format!("the write failed: {e}")),
                    ),
                }
                done.send_modify(|d| *d += 1);
            }
        });
    }

    /// Every write queued until now has landed (or failed).
    pub(crate) async fn written(&self) {
        let target = lock(&self.pending).queued;
        let _ = self.done.subscribe().wait_for(|d| *d >= target).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type Seen<T> = Arc<Mutex<Vec<T>>>;

    /// What the writes did, what was reported, and the queue.
    fn order() -> (Seen<u32>, Seen<String>, Ordered) {
        let (seen, failed) = (
            Arc::<Mutex<Vec<u32>>>::default(),
            Arc::<Mutex<Vec<String>>>::default(),
        );
        let f = failed.clone();
        let o = Ordered::reporting("test:disk", move |what, e| {
            lock(&f).push(format!("{what}: {e}"))
        });
        (seen, failed, o)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn writes_land_in_the_order_they_were_queued() {
        let (seen, failed, o) = order();
        for i in 0..64 {
            let s = seen.clone();
            o.push(format!("write {i}"), move || {
                lock(&s).push(i);
                Ok(())
            });
        }
        o.written().await;
        assert_eq!(*lock(&seen), (0..64).collect::<Vec<_>>());
        assert!(lock(&failed).is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_failed_write_is_reported_and_the_next_still_lands() {
        let (seen, failed, o) = order();
        o.push("the queue", || Err(std::io::Error::other("disk full")));
        let s = seen.clone();
        o.push("the meta", move || {
            lock(&s).push(1);
            Ok(())
        });
        o.written().await;
        assert_eq!(*lock(&failed), vec!["the queue: disk full".to_string()]);
        assert_eq!(*lock(&seen), vec![1]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_write_that_panics_stops_neither_the_queue_nor_its_waiters() {
        let (seen, failed, o) = order();
        o.push("the panic", || panic!("a write's bug"));
        let s = seen.clone();
        o.push("after", move || {
            lock(&s).push(2);
            Ok(())
        });
        o.written().await;
        assert_eq!(*lock(&seen), vec![2]);
        let failed = lock(&failed);
        assert!(
            failed.len() == 1 && failed[0].starts_with("the panic: "),
            "{failed:?}"
        );
    }
}
