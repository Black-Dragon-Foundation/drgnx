//! JSONL export and idempotent import (Task 7; storage §8.2). The caller's ALLOW filters every entity (norn's
//! deny-list: door 5 for export, door 2 for import).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 7 removes this line.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::entity::Ent;
use super::pool::ReadPool;
use super::writer::WriterHandle;

/// The caller's filter: true lets the entity through.
pub type Allow = Arc<dyn Fn(&Ent) -> bool + Send + Sync>;

/// What an export writes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Opts {
    /// `tx.jsonl` from this tx on (else all).
    pub since: Option<i64>,
    /// Also `history.jsonl`.
    pub history: bool,
    /// Also `touched` links, `link_stat` and sessions.
    pub with_activity: bool,
}

/// What an export or an import did.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub dir: PathBuf,
    pub entities: u64,
    pub links: u64,
    pub txs: u64,
    /// Filtered out by ALLOW, or (import) already present at that version or later.
    pub skipped: u64,
    /// Import: `(line, why)` of the records refused.
    pub refused: Vec<(u64, String)>,
    pub error: Option<String>,
}

/// Export into DIR (through `DIR.tmp`, then renamed; `<data>/export/` made 0700).
pub async fn export(pool: &ReadPool, dir: PathBuf, opts: Opts, allow: Allow) -> Report {
    todo!("Task 7")
}

/// Import DIR: idempotent by `id` and `ver`, one tx per 500 records (`actor: "import"`, `tool: "import"`).
pub async fn import(writer: &WriterHandle, dir: PathBuf, allow: Allow) -> Report {
    todo!("Task 7")
}
