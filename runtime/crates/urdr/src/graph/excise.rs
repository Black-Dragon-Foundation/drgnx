//! Excise (Task 8; storage §8.3): blank a text in every version, the FTS and vector rows, the `tx` answers and notes,
//! and the caller's streams (blankers), in one tx; log what and why, never the content; then scrub the file.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 8 removes this line.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::tx::{Tx, TxMeta};
use super::writer::{ScrubReport, WriteError, WriterHandle};

/// What to excise.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    /// An entity by id: the named fields of every version.
    Entity(String),
    /// Every field a tx wrote, and the cards and notices it made.
    Tx(i64),
}

/// What a blanker is told: the entities and txs excised, and the marker text (`[excised <tx>]`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Excised {
    pub entities: Vec<i64>,
    pub txs: Vec<i64>,
    pub marker: String,
}

/// The caller's own tables that hold copies (norn's: events, messages, cards; Tasks 12 and 13).
pub trait Blanker: Send + Sync {
    /// Blank what this blanker keeps of EXCISED, in the excise's tx; the rows changed.
    fn blank(&self, tx: &mut Tx<'_>, excised: &Excised) -> Result<u64, WriteError>;
}

/// What an excise did. `needles` (the values removed) stay in memory for [`holding`]: never serialized.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ExciseReport {
    pub tx: i64,
    pub entities: u64,
    pub versions: u64,
    pub txs_blanked: u64,
    pub blanked: u64,
    #[serde(skip)]
    pub needles: Vec<Vec<u8>>,
}

/// Excise TARGET's FIELDS (default `title`, `body`, `data`) in one tx of META (the caller checks the class).
pub async fn excise(
    writer: &WriterHandle,
    meta: TxMeta,
    target: Target,
    fields: Option<Vec<String>>,
    reason: String,
    blankers: Vec<Arc<dyn Blanker>>,
) -> Result<ExciseReport, WriteError> {
    todo!("Task 8")
}

/// `VACUUM` and `wal_checkpoint(TRUNCATE)` through the writer's `maintain`, never a connection of its own.
pub async fn scrub(writer: &WriterHandle) -> Result<ScrubReport, WriteError> {
    todo!("Task 8")
}

/// The FILES that hold any of NEEDLES (a byte search over backups and exports).
pub fn holding(files: &[PathBuf], needles: &[Vec<u8>]) -> Vec<PathBuf> {
    todo!("Task 8")
}
