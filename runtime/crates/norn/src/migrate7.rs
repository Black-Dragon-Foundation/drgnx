//! `work.db` schema 6 → 7 (Task 11; storage §9 step 5, calls 2, 4, 5, 6, 15, 18): the writer's opening rule, which
//! creates a fresh file at schema 7 or migrates a schema-6 one in one transaction after a checked `VACUUM INTO` copy,
//! with the deny-list at the migration's door, compat views with schema 6's columns, and `file`/`meta` behind
//! read-only views.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 11 removes this line.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use urdr::Connection;
use urdr::graph::OpenRule;

/// What the rule needs besides the connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MigrateOpts {
    /// Where `work-pre7-<unix>.db` goes (`<data>/backup/`, or migrate-check's scratch dir).
    pub backup_dir: PathBuf,
    /// For the deny-list.
    pub home: PathBuf,
    pub config_dir: PathBuf,
}

/// What a migration did: counts and times, never a path, title or body.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MigrateReport {
    /// Table → (rows in, rows out).
    pub tables: BTreeMap<String, (u64, u64)>,
    pub denied_nodes: u64,
    pub denied_edges: u64,
    pub no_project: u64,
    pub ms: f64,
    pub backup: Option<PathBuf>,
}

/// The writer's opening rule: missing → schema 7; 6 → [`run`]; 7 → ready; above → read-only; below 6 → not ready;
/// a failed run → `Failed` (never re-tried in this process).
pub fn open_rule(opts: MigrateOpts) -> OpenRule {
    todo!("Task 11")
}

/// Migrate the schema-6 file at PATH, open on CONN (the writer's connection).
pub fn run(
    conn: &mut Connection,
    path: &Path,
    opts: &MigrateOpts,
) -> Result<MigrateReport, String> {
    todo!("Task 11")
}

/// `ratatoskr store migrate-check`: migrate the copy DB in place, its pre-migration backup in SCRATCH.
pub fn check_copy(db: &Path, scratch: &Path) -> Result<MigrateReport, String> {
    todo!("Task 11")
}
