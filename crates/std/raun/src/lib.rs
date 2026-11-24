//! raun (*raun*, a trial): the test harness (docs/develop/standards/test-harness.md).
//!
//! A test starts with `let sb = raun::Sandbox::new();`. Until `sb` drops: every stig directory is under a fresh temp
//! HOME with the `test` profile, so nothing reaches the user's files; and the process's clock is a [`VirtualClock`],
//! so every timer through `stund` waits on virtual time that [`Sandbox::advance`] moves. Sandboxes of one process
//! run one at a time (under nextest each test is its own process anyway). `cargo xtask test-sandbox` proves the rule:
//! it runs the tests with HOME pointed at an empty directory and fails if anything appears there.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

pub mod proc;

pub use stund::Manual as VirtualClock;

/// One sandbox at a time per process: the paths and the clock are process-wide.
static ONE: Mutex<()> = Mutex::new(());

/// A test's sandbox: a temp HOME holding the test profile's directories, and a virtual clock.
pub struct Sandbox {
    home: tempfile::TempDir,
    clock: VirtualClock,
    _one: MutexGuard<'static, ()>,
}

impl Sandbox {
    /// A fresh sandbox: the temp HOME made, stig's directories under it, the virtual clock installed. Panics when the
    /// temp directory can't be made (a test can't run without it).
    pub fn new() -> Sandbox {
        let one = saman::lock(&ONE);
        let home = tempfile::Builder::new()
            .prefix("raun-home-")
            .tempdir()
            .unwrap_or_else(|e| panic!("raun: no temp HOME: {e}"));
        stig::init_for_test(home.path());
        let clock = VirtualClock::default();
        stund::install(Arc::new(clock.clone()));
        Sandbox {
            home,
            clock,
            _one: one,
        }
    }

    /// The temp HOME (stig's directories are under it).
    pub fn home(&self) -> &Path {
        self.home.path()
    }

    /// The virtual clock every `stund` timer of the process waits on.
    pub fn clock(&self) -> &VirtualClock {
        &self.clock
    }

    /// Move the virtual clock by D: every timer due by then fires, with no real wait.
    pub fn advance(&self, d: Duration) {
        self.clock.advance(d);
    }
}

impl Default for Sandbox {
    fn default() -> Sandbox {
        Sandbox::new()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        stund::uninstall();
        stig::reset_for_test();
    }
}
