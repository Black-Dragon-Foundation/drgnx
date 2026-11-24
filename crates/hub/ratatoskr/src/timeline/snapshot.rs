//! Step snapshots live in `eykt`; this module keeps the old paths.  `restore_into` stays here in its old shape: the
//! hub's own rule for what a restore may touch (`history::tree::restorable`) is passed to `eykt`'s.

use std::path::{Path, PathBuf};

pub use eykt::snapshot::*;

/// [`eykt::snapshot::restore_into`] with the hub's rule for the paths a restore never touches.
pub fn restore_into(
    root: &Path,
    source: &Path,
    target: &Path,
    to: &str,
    only: Option<&[PathBuf]>,
    extra: &[String],
) -> villa::Result<Restored> {
    eykt::snapshot::restore_into(root, source, target, to, only, extra, &|p| {
        crate::history::tree::restorable(p, extra)
    })
}
