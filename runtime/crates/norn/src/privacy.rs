//! The personal-file opt-in applied (Task 9b; answer 2, call 8): on `graph/privacy {reload}`, at start and when the
//! file changes. A removed opt-in excises what came in. Until Task 9b, [`apply`] answers "not built yet" and [`tick`]
//! does nothing.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's stub: Task 9b removes this line.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use urdr::graph::WriterHandle;

use crate::deny::{DenyList, SharedDeny};

/// What applying a change of the opt-ins did.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PrivacyReport {
    pub added: Vec<PathBuf>,
    pub removed: Vec<PathBuf>,
    /// Entries the hard tier or the shape rules rejected.
    pub ignored: Vec<String>,
    pub excised: u64,
    pub backups_holding: Vec<PathBuf>,
}

/// The opt-in file as last seen by [`tick`]: its `(mtime, size)`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Watch {
    pub seen: Option<(SystemTime, u64)>,
}

/// Apply the change from the opt-ins OLD to the opt-ins of DENY (the list just loaded).
pub async fn apply(
    writer: &WriterHandle,
    deny: &DenyList,
    old: &[PathBuf],
    new: &[PathBuf],
) -> Result<PrivacyReport, String> {
    Err("not built yet".into())
}

/// The hub's tick: when `CONFIG_DIR/personal-notes-allow.json`'s `(mtime, size)` moved, reload DENY and apply.
pub async fn tick(
    watch: &mut Watch,
    writer: &WriterHandle,
    deny: &SharedDeny,
    home: &Path,
    config_dir: &Path,
) -> Option<PrivacyReport> {
    None
}
