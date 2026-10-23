//! History: as-of reads, versions with their authors, revert, restore, proposed txs (Task 3; storage §5.2 "each kind
//! of query", §6.3, §6.5). Policy-free: the class check is the caller's.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 3 removes this line.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use super::entity::{Ent, Update};
use super::link::{Direction, Link};
use super::tx::{Class, Tx};
use super::writer::WriteError;

/// An entity as of a tx; `approximate` when that version's tx was synthesized at the migration (`imported = 1`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AsOf {
    pub ent: Ent,
    pub approximate: bool,
}

/// One version of an entity, with its tx's author.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Version {
    pub ver: i64,
    pub tx: i64,
    pub at: f64,
    pub actor: String,
    pub class: Class,
    pub tool: Option<String>,
    pub session: Option<String>,
    /// The fields this version changed.
    pub fields: Vec<String>,
    pub imported: bool,
}

/// What a revert (or a rejection of proposed txs) did.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Revert {
    /// The entities given a restoring version, and the links retired or re-added.
    Done { entities: Vec<i64>, links: Vec<i64> },
    /// A later tx changed an entity the target wrote: nothing written.
    Blocked { later: Vec<i64> },
}

/// `select max(id) from tx where at <= AT` (0 when none).
pub fn tx_at(conn: &Connection, at: f64) -> rusqlite::Result<i64> {
    todo!("Task 3")
}

/// Entity N as of TX: the current row if `updated_tx <= TX`, else the `entity_hist` row with `tx_from <= TX < tx_to`,
/// none if it was created after TX.
pub fn entity_as_of(conn: &Connection, n: i64, tx: i64) -> rusqlite::Result<Option<AsOf>> {
    todo!("Task 3")
}

/// The links of N in DIRECTION with a kind in KINDS (all when empty) that existed at TX.
pub fn links_as_of(
    conn: &Connection,
    n: i64,
    kinds: &[String],
    direction: Direction,
    tx: i64,
) -> rusqlite::Result<Vec<Link>> {
    todo!("Task 3")
}

/// Entity N's versions since tx SINCE, oldest first.
pub fn history(conn: &Connection, n: i64, since: Option<i64>) -> rusqlite::Result<Vec<Version>> {
    todo!("Task 3")
}

/// Revert TARGET as a new tx (`tx.reverts = target`), or answer `Blocked` writing nothing.
pub fn revert(tx: &mut Tx<'_>, target: i64) -> Result<Revert, WriteError> {
    todo!("Task 3")
}

/// Set entity N's fields to version VER's (a new version).
pub fn restore(tx: &mut Tx<'_>, n: i64, ver: i64) -> Result<Update, WriteError> {
    todo!("Task 3")
}

/// Accept (mark `accepted`) or reject (revert newest first, mark `reverted`) the proposed TXS.
pub fn settle_proposed(tx: &mut Tx<'_>, txs: &[i64], accept: bool) -> Result<Revert, WriteError> {
    todo!("Task 3")
}
