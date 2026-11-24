//! The machine's jobserver (Task 10a): one GNU make fifo that every job taking part builds with.
//!
//! The pool holds [`forseti::jobserver::tokens`] tokens, recomputed on every admission tick. A rise writes tokens into
//! the fifo; a fall takes tokens back only as the jobs return them, never by killing work. A job gets the fifo
//! bind-mounted and `MAKEFLAGS`/`CARGO_MAKEFLAGS` naming it ([`FLAGS`]); cargo, rustc's codegen and `make` take a token
//! for every process they start beyond their first. The fifo is the `fifo:` form of `--jobserver-auth`.

use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};

use rustix::fs::{CWD, FileType, Mode, OFlags};

/// The fifo's name in the pool's folder.
pub const FIFO: &str = "pool";

/// Where a job sees the fifo.
pub const INSIDE: &str = "/jobserver";

/// What `MAKEFLAGS` and `CARGO_MAKEFLAGS` hold in a job that takes part.
pub const FLAGS: &str = "--jobserver-auth=fifo:/jobserver";

/// The pool: the fifo and how many tokens exist (in it, or held by the jobs that took them).
pub struct Pool {
    path: PathBuf,
    fd: OwnedFd,
    total: u32,
    target: u32,
}

fn io(what: &str, e: rustix::io::Errno) -> villa::Error {
    villa::Error::io(format!("the jobserver: {what}: {e}"))
}

impl Pool {
    /// The pool in DIR (made if need be): its fifo, emptied of tokens a `serve` before left, with none counted.
    pub fn open(dir: &Path) -> villa::Result<Pool> {
        std::fs::create_dir_all(dir).map_err(|e| {
            villa::Error::io(format!("the jobserver: {}: {e}", dir.display())).with_source(e)
        })?;
        let path = dir.join(FIFO);
        match rustix::fs::mknodat(CWD, &path, FileType::Fifo, Mode::from_raw_mode(0o600), 0) {
            Ok(()) | Err(rustix::io::Errno::EXIST) => {}
            Err(e) => return Err(io("make its fifo", e)),
        }
        // read and write at once, so the fifo is never closed under the jobs, and a read never blocks
        let fd = rustix::fs::open(
            &path,
            OFlags::RDWR | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|e| io("open its fifo", e))?;
        let mut pool = Pool {
            path,
            fd,
            total: 0,
            target: 0,
        };
        while pool.take_one()? {}
        Ok(pool)
    }

    /// The fifo's path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The tokens that exist: in the fifo, or taken by a job that has not returned them.
    pub fn total(&self) -> u32 {
        self.total
    }

    /// The pool should hold N tokens: settles at once as far as it can ([`Pool::settle`]).
    pub fn set_target(&mut self, n: u32) -> villa::Result<u32> {
        self.target = n;
        self.settle()
    }

    /// Moves the pool towards its target: writes tokens for a rise; for a fall reads out the tokens that are in the
    /// fifo now, and leaves the rest owed until their jobs return them (the next call). The tokens that exist after.
    pub fn settle(&mut self) -> villa::Result<u32> {
        while self.total < self.target {
            match rustix::io::write(&self.fd, b"+") {
                Ok(1) => self.total += 1,
                Ok(_) | Err(rustix::io::Errno::AGAIN) => break,
                Err(e) => return Err(io("write a token", e)),
            }
        }
        // a fall: only the tokens in the fifo now can be taken back; the rest are owed until their jobs return them
        while self.total > self.target && self.take_one()? {
            self.total -= 1;
        }
        Ok(self.total)
    }

    fn take_one(&mut self) -> villa::Result<bool> {
        let mut b = [0u8; 1];
        match rustix::io::read(&self.fd, &mut b) {
            Ok(1) => Ok(true),
            Ok(_) => Ok(false),
            Err(rustix::io::Errno::AGAIN) => Ok(false),
            Err(e) => Err(io("read a token", e)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A job's end of the fifo: takes tokens and returns them.
    struct Client(OwnedFd);

    impl Client {
        fn of(p: &Pool) -> Client {
            Client(
                rustix::fs::open(p.path(), OFlags::RDWR | OFlags::NONBLOCK, Mode::empty()).unwrap(),
            )
        }
        fn take(&self, n: usize) -> usize {
            (0..n)
                .filter(|_| rustix::io::read(&self.0, &mut [0u8; 1]) == Ok(1))
                .count()
        }
        fn give(&self, n: usize) {
            for _ in 0..n {
                assert_eq!(rustix::io::write(&self.0, b"+"), Ok(1));
            }
        }
    }

    /// [D] pure (a fifo in a folder) (Task 10a): a rise of the target is tokens in the fifo at once, which jobs take.
    #[test]
    fn a_rise_writes_tokens_a_job_can_take() {
        let d = tempfile::tempdir().unwrap();
        let mut pool = Pool::open(d.path()).unwrap();
        let job = Client::of(&pool);
        assert_eq!(job.take(1), 0, "an empty pool has none");
        assert_eq!(pool.set_target(1).unwrap(), 1);
        assert_eq!(job.take(5), 1);
        assert_eq!(pool.set_target(4).unwrap(), 4);
        assert_eq!(
            job.take(5),
            3,
            "the three the rise added; the first is still out"
        );
    }

    /// [D] pure (a fifo in a folder) (Task 10a): a fall takes back the tokens that are in the fifo, never one a job
    /// holds; the rest is owed, and comes back as the jobs return it.
    #[test]
    fn a_fall_takes_tokens_back_only_as_they_return() {
        let d = tempfile::tempdir().unwrap();
        let mut pool = Pool::open(d.path()).unwrap();
        pool.set_target(4).unwrap();
        let job = Client::of(&pool);
        assert_eq!(job.take(2), 2, "two jobs hold a token each");
        // the pool should hold 1: the two in the fifo go at once, the two held stay out
        assert_eq!(pool.set_target(1).unwrap(), 2);
        assert_eq!(job.take(1), 0, "nothing is left in the fifo to take");
        // one returns: the pool reads it out (one more is still owed no longer: 2 − 1 = 1 = the target)
        job.give(1);
        assert_eq!(pool.settle().unwrap(), 1);
        // the other returns: it stays in the fifo for the next job, the pool is at its target
        job.give(1);
        assert_eq!(pool.settle().unwrap(), 1);
        assert_eq!(job.take(2), 1, "the returned token is the pool's one");
        // a pool opened again never counts what a `serve` before left in the fifo
        job.give(3);
        let again = Pool::open(d.path()).unwrap();
        assert_eq!(again.total(), 0);
        assert_eq!(job.take(1), 0, "emptied");
    }
}
