//! The transaction a write runs in: its `tx` row's metadata and the savepoint it writes through (Task 1; storage
//! §5.2 `tx`, §7).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 1 removes this line.

use std::sync::Arc;

use rusqlite::{Connection, Savepoint};
use serde::{Deserialize, Serialize};

use super::guard::Guard;

/// The class of a write's author, shown with every field it wrote (storage §5.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    User,
    Agent,
    Ext,
    System,
}

impl Class {
    /// The `tx.class` column's text.
    pub fn as_str(self) -> &'static str {
        match self {
            Class::User => "user",
            Class::Agent => "agent",
            Class::Ext => "ext",
            Class::System => "system",
        }
    }
}

/// `tx.state` (storage §6.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TxState {
    Committed,
    Proposed,
    Accepted,
    Reverted,
}

impl TxState {
    /// The `tx.state` column's text.
    pub fn as_str(self) -> &'static str {
        match self {
            TxState::Committed => "committed",
            TxState::Proposed => "proposed",
            TxState::Accepted => "accepted",
            TxState::Reverted => "reverted",
        }
    }
}

/// What the `tx` row records of a write: from the connection, never from a tool's arguments.
#[derive(Clone, Debug, PartialEq)]
pub struct TxMeta {
    /// `user`, `agent:<session>`, `ext:<session>`, `scan:<root>`, `hub`, `import`.
    pub actor: String,
    pub class: Class,
    pub session: Option<String>,
    pub profile: Option<String>,
    pub job: Option<String>,
    /// The entity `n` of the caller's project.
    pub project: Option<i64>,
    /// `mcp:task_write/claim`, `proto:cards/settle`, `scan`, `cli:graph-revert`, `import`.
    pub tool: String,
    /// The request key: a repeat of `(actor, req)` returns the first answer (call 3, call 7).
    pub req: Option<String>,
    pub state: TxState,
    pub reverts: Option<i64>,
    /// Synthesized at the migration from dated records: as-of answers are approximate.
    pub imported: bool,
    pub note: Option<String>,
}

impl TxMeta {
    /// A committed, unkeyed tx of ACTOR in CLASS through TOOL, every other field empty.
    pub fn new(actor: impl Into<String>, class: Class, tool: impl Into<String>) -> TxMeta {
        TxMeta {
            actor: actor.into(),
            class,
            session: None,
            profile: None,
            job: None,
            project: None,
            tool: tool.into(),
            req: None,
            state: TxState::Committed,
            reverts: None,
            imported: false,
            note: None,
        }
    }
}

/// One write's transaction: its `tx` row is inserted first, inside the request's own savepoint (Task 1).
pub struct Tx<'a> {
    id: i64,
    at: f64,
    meta: TxMeta,
    guard: Arc<Guard>,
    sp: Savepoint<'a>,
}

impl<'a> Tx<'a> {
    /// `tx.id`: the as-of bound.
    pub fn id(&self) -> i64 {
        self.id
    }

    /// `tx.at`: unix seconds, monotonic (`max(now, previous at)`).
    pub fn at(&self) -> f64 {
        self.at
    }

    pub fn meta(&self) -> &TxMeta {
        &self.meta
    }

    /// The class guard the primitives check before writing an entity or a `kv` key ([`super::guard`]).
    pub fn guard(&self) -> &Guard {
        &self.guard
    }

    /// The savepoint every statement of this write runs in (a `Connection` through `Deref`).
    pub fn sql(&self) -> &Savepoint<'a> {
        &self.sp
    }

    /// A tx outside the writer, for tests of the primitives (Task 2 builds against it): it opens a savepoint on
    /// CONN (which already holds `GRAPH_DDL`), inserts the `tx` row from META with `at` = now, and answers the `Tx`.
    /// Dropping it without a commit rolls the savepoint back, as the writer does on an error.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn for_test(conn: &'a mut Connection, meta: TxMeta, guard: Arc<Guard>) -> Tx<'a> {
        todo!("Task 1")
    }

    /// Release the savepoint (tests built on [`Tx::for_test`] keep what they wrote).
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn commit_for_test(self) -> rusqlite::Result<()> {
        todo!("Task 1")
    }
}
