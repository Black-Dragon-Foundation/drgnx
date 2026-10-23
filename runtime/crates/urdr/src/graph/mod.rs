//! The graph store: `work.db` schema 7's tables, written through one path (docs/develop/store.md).
//!
//! Generic: kinds, link names and policy are the caller's (norn holds drgnx's). Only this module's primitives write
//! `tx`, `entity`, `entity_hist`, `link`, `link_stat`, `entity_fts`, `entity_vec`, `project_alias` and `excise_log`,
//! each change with its version, FTS row and stat in the same transaction. No triggers, no foreign keys.
//!
//! This file is Task 0's: it declares every module, and the signatures in them are what the parallel tasks build
//! against. An owning task fills its own file's bodies; a signature changes only with the manager.
//!
//! - [`tx`], [`writer`] (Task 1): the one writer thread, group commit, a savepoint per request, request keys.
//! - [`schema`], [`entity`], [`link`], [`guard`] (Task 2): the tables, the entity and link primitives, the class guard.
//! - [`hist`] (Task 3): as-of reads, versions with their authors, revert, proposed txs.
//! - [`walk`] (Task 4): breadth-first walks and paths with budgets, scope per level.
//! - [`search`] (Task 5): full text, vectors, RRF.
//! - [`pool`], [`sqlro`] (Task 6): the read pool and `graph/sql`'s read-only runner.
//! - [`backup`], [`export`] (Task 7): `VACUUM INTO` backups, JSONL export and import.
//! - [`excise`] (Task 8): blanking a text everywhere it was kept, then scrubbing the file.

pub mod backup;
pub mod entity;
pub mod excise;
pub mod export;
pub mod guard;
pub mod hist;
pub mod link;
pub mod pool;
pub mod schema;
pub mod search;
pub mod sqlro;
pub mod tx;
pub mod walk;
pub mod writer;

pub use pool::ReadPool;
pub use tx::{Class, Tx, TxMeta, TxState};
pub use writer::{
    Maintenance, OpenOutcome, OpenRule, ScrubReport, WriteError, Writer, WriterHandle, WriterOpts,
    Written,
};
