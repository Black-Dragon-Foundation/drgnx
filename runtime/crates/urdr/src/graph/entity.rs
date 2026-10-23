//! Entities: create, update (versions in `entity_hist`, `field_tx`, the FTS row, all in the caller's tx), retire, and
//! the current-state readers (Task 2; storage §5.2).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 2 removes this line.

use std::collections::BTreeMap;

use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::tx::{Class, Tx};
use super::writer::WriteError;

/// `entity.origin`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    Recorded,
    Parsed,
    Inferred,
    Imported,
}

impl Origin {
    /// The column's text.
    pub fn as_str(self) -> &'static str {
        match self {
            Origin::Recorded => "recorded",
            Origin::Parsed => "parsed",
            Origin::Inferred => "inferred",
            Origin::Imported => "imported",
        }
    }
}

/// The lease columns (`lease_holder`, `lease_epoch`, `lease_until`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Lease {
    pub holder: Option<String>,
    pub epoch: i64,
    pub until: Option<f64>,
}

/// A new entity. `kind` is a string here; the closed list is the caller's.
#[derive(Clone, Debug, PartialEq)]
pub struct EntityNew {
    pub id: String,
    pub kind: String,
    pub project: Option<i64>,
    pub title: Option<String>,
    pub status: Option<String>,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub assignee: Option<String>,
    /// A JSON object.
    pub data: Value,
    pub origin: Origin,
    pub source: Option<String>,
}

/// An entity's current row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ent {
    pub n: i64,
    pub id: String,
    pub kind: String,
    pub project: Option<i64>,
    pub title: Option<String>,
    pub status: Option<String>,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub assignee: Option<String>,
    pub lease: Lease,
    pub data: Value,
    /// Field → the tx that last set it.
    pub field_tx: BTreeMap<String, i64>,
    pub origin: Origin,
    pub source: Option<String>,
    pub ver: i64,
    pub created_tx: i64,
    pub updated_tx: i64,
    pub retired_tx: Option<i64>,
}

/// An update's fields: `None` leaves a field alone; for a nullable field `Some(None)` clears it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Changes {
    pub project: Option<Option<i64>>,
    pub title: Option<Option<String>>,
    pub status: Option<Option<String>>,
    pub body: Option<Option<String>>,
    pub priority: Option<Option<i64>>,
    pub assignee: Option<Option<String>>,
    /// Merged into `data` with JSON merge-patch rules (RFC 7396).
    pub data_patch: Option<Value>,
    pub lease: Option<Lease>,
}

/// A field changed since the version a caller had: its new value, who set it and in which tx.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FieldChange {
    pub field: String,
    pub to: Value,
    pub by: String,
    pub class: Class,
    pub tx: i64,
}

/// What an update did.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Update {
    Done {
        ver: i64,
    },
    /// `expect_ver` was stale: nothing written.
    Conflict {
        ver: i64,
        changed_since: Vec<FieldChange>,
    },
}

/// Insert a new entity at `ver = 1` with its `field_tx` and FTS row; a duplicate `id` is `Refused("id exists")`.
/// The guard is checked first.
pub fn create(tx: &mut Tx<'_>, new: EntityNew) -> Result<Ent, WriteError> {
    todo!("Task 2")
}

/// Change entity N: with EXPECT_VER stale, a conflict listing the newer fields; else the old row to `entity_hist`,
/// the changes, `ver + 1`, `field_tx`, `updated_tx`, the FTS row when title or body changed. A change of nothing
/// writes nothing. The guard is checked first.
pub fn update(
    tx: &mut Tx<'_>,
    n: i64,
    expect_ver: Option<i64>,
    changes: Changes,
) -> Result<Update, WriteError> {
    todo!("Task 2")
}

/// Set `retired_tx` (a new version); the row stays and `n` is never reused.
pub fn retire(tx: &mut Tx<'_>, n: i64) -> Result<(), WriteError> {
    todo!("Task 2")
}

/// The current row of the entity ID, retired or not.
pub fn by_id(conn: &Connection, id: &str) -> rusqlite::Result<Option<Ent>> {
    todo!("Task 2")
}

/// The current row of entity N, retired or not.
pub fn by_n(conn: &Connection, n: i64) -> rusqlite::Result<Option<Ent>> {
    todo!("Task 2")
}
