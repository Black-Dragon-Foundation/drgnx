//! Backups (Task 7; storage §8.1): `VACUUM INTO` from a read connection, an integrity check of the copy, rotation.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 7 removes this line.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::pool::ReadPool;

/// What a backup or a check did, for the doctor.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub path: PathBuf,
    pub ok: bool,
    pub error: Option<String>,
    pub bytes: u64,
    pub ms: f64,
}

/// How many dated copies rotation keeps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Policy {
    pub daily: u32,
    /// The Sundays.
    pub weekly: u32,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            daily: 7,
            weekly: 4,
        }
    }
}

/// `VACUUM INTO` DEST (through `DEST.tmp`, then renamed), from a pool connection.
pub async fn vacuum_into(pool: &ReadPool, dest: PathBuf) -> Report {
    todo!("Task 7")
}

/// `integrity_check` and the FTS index check of the copy DEST; a failed check deletes it.
pub fn check(dest: &Path) -> Report {
    todo!("Task 7")
}

/// Keep POLICY's `work-YYYYMMDD.db` copies in DIR (made 0700), never touching `work-pre7-*.db`; the files removed.
pub fn rotate(dir: &Path, policy: Policy) -> std::io::Result<Vec<PathBuf>> {
    todo!("Task 7")
}
