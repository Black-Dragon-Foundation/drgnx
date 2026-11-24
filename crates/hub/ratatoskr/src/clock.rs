//! The hub's clock lives in `eykt` (one process-wide virtual clock); this module keeps the old paths.

pub use eykt::clock::*;

/// The virtual clock for the whole process (`serve --test-clock`), once.  A unit test of this crate takes its own
/// (`on_virtual`), never the process's.
#[cfg(feature = "test-hooks")]
pub fn install_virtual() {
    #[cfg(test)]
    panic!("a unit test runs on its own virtual clock (clock::on_virtual), never the process's");
    #[cfg(not(test))]
    eykt::clock::install_virtual();
}
