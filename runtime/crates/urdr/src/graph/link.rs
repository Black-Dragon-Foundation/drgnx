//! Links: immutable rows (a version records existence only; current `tx_to` = [`super::schema::SENTINEL`]) and the
//! unversioned `link_stat` counters (Task 2; storage §5.2, §5.4).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 2 removes this line.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::entity::Origin;
use super::tx::Tx;
use super::writer::WriteError;

/// Which way a link is followed from an entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Out,
    In,
    Both,
}

/// One `link` row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Link {
    pub id: i64,
    pub src: i64,
    pub kind: String,
    pub dst: i64,
    /// Set once at creation (e.g. `{"at": "<commit sha>"}`), never updated.
    pub data: Option<Value>,
    pub origin: Origin,
    pub source: Option<String>,
    pub tx_from: i64,
    pub tx_to: i64,
}

/// What [`add`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Added {
    pub id: i64,
    /// A current row `(src, kind, dst)` was already there; nothing was written.
    pub existed: bool,
}

/// Add the current link `(src, kind, dst)`; a retired end is refused.
pub fn add(
    tx: &mut Tx<'_>,
    src: i64,
    kind: &str,
    dst: i64,
    data: Option<Value>,
    origin: Origin,
    source: Option<&str>,
) -> Result<Added, WriteError> {
    todo!("Task 2")
}

/// Retire the current link `(src, kind, dst)` (`tx_to` = this tx); false when there was none.
pub fn retire(tx: &mut Tx<'_>, src: i64, kind: &str, dst: i64) -> Result<bool, WriteError> {
    todo!("Task 2")
}

/// Retire every current link whose `source` is SOURCE; the count.
pub fn retire_by_source(tx: &mut Tx<'_>, source: &str) -> Result<u64, WriteError> {
    todo!("Task 2")
}

/// `link_stat`: count + 1 and `last_tx`, keeping `first_tx`. Not versioned.
pub fn stat_bump(tx: &mut Tx<'_>, src: i64, kind: &str, dst: i64) -> Result<(), WriteError> {
    todo!("Task 2")
}
