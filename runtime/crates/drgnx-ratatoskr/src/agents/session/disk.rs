//! A session's files (its transcript, held queue, wheel and meta) written in order, off the hub's two async workers.
//!
//! A write is taken as a closure under the session's state lock, so writes queue in the order of the states they read,
//! and one `session:disk` task runs them one at a time on the blocking pool.  A write that waits on the disk (a btrfs
//! commit held an `openat` 280 ms under load) then holds no worker, and no lock that another task waits for.  The
//! paths that need the files to have landed (a turn's prompt, a close, the hub's end) await [`Disk::written`].

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

type Job = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct Pending {
    jobs: VecDeque<Job>,
    /// The `session:disk` task is running them.
    running: bool,
    /// Writes queued so far.
    queued: u64,
}

pub(crate) struct Disk {
    pending: Arc<Mutex<Pending>>,
    /// Writes done so far, in queue order.
    done: Arc<tokio::sync::watch::Sender<u64>>,
}

impl Default for Disk {
    fn default() -> Disk {
        Disk {
            pending: Arc::default(),
            done: Arc::new(tokio::sync::watch::channel(0).0),
        }
    }
}

impl Disk {
    /// WRITE after every write queued before it.
    pub(crate) fn push(&self, write: impl FnOnce() + Send + 'static) {
        let mut p = super::lock(&self.pending);
        p.jobs.push_back(Box::new(write));
        p.queued += 1;
        if p.running {
            return;
        }
        p.running = true;
        drop(p);
        let (pending, done) = (self.pending.clone(), self.done.clone());
        crate::clock::spawn("session:disk", async move {
            loop {
                let job = {
                    let mut p = super::lock(&pending);
                    match p.jobs.pop_front() {
                        Some(j) => j,
                        None => {
                            p.running = false;
                            return;
                        }
                    }
                };
                let _ = crate::clock::blocking(job).await;
                done.send_modify(|d| *d += 1);
            }
        });
    }

    /// Every write queued until now has landed.
    pub(crate) async fn written(&self) {
        let target = super::lock(&self.pending).queued;
        let _ = self.done.subscribe().wait_for(|d| *d >= target).await;
    }
}
