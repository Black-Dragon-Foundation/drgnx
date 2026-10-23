//! The transaction a write runs in: its `tx` row's metadata and the savepoint it writes through (Task 1; storage
//! §5.2 `tx`, §7).

use std::sync::Arc;

use rusqlite::{Connection, Savepoint, params};
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
    /// An entity's text (its FTS row) was put: [`super::search::fts_put`] sets it.
    text: bool,
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
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        Tx::begin(conn, meta, at, guard)
            .expect("Tx::for_test: the savepoint and the tx row (does CONN hold GRAPH_DDL?)")
    }

    /// Release the savepoint (tests built on [`Tx::for_test`] keep what they wrote).
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn commit_for_test(self) -> rusqlite::Result<()> {
        self.release()
    }

    /// A tx inside an opening rule's own transaction (norn's migration, Task 11): the rule runs on the writer thread
    /// with the write connection before the first batch, opens `BEGIN IMMEDIATE` itself, and makes one `Tx` per
    /// backfilled time with its AT (the writer reads the file's newest `at` as its floor once the rule answers
    /// `Ready`). Released with [`Tx::release_in_rule`]; dropped, it rolls back as a request's does. Nothing else calls
    /// it: requests get their `Tx` from the writer.
    pub fn in_rule(
        conn: &'a mut Connection,
        meta: TxMeta,
        at: f64,
        guard: Arc<Guard>,
    ) -> rusqlite::Result<Tx<'a>> {
        Tx::begin(conn, meta, at, guard)
    }

    /// Release a [`Tx::in_rule`]: what it wrote joins the rule's transaction.
    pub fn release_in_rule(self) -> rusqlite::Result<()> {
        self.release()
    }

    /// Open the request's savepoint on CONN and insert its `tx` row from META at AT. An error rolls the savepoint
    /// back (its `Drop`), so nothing of the request stays.
    pub(super) fn begin(
        conn: &'a mut Connection,
        meta: TxMeta,
        at: f64,
        guard: Arc<Guard>,
    ) -> rusqlite::Result<Tx<'a>> {
        let sp = Savepoint::with_name(conn, SAVEPOINT)?;
        sp.execute(
            "insert into tx (at, actor, class, session, profile, job, project, tool, req, state, reverts, imported, \
             note) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                at,
                meta.actor,
                meta.class.as_str(),
                meta.session,
                meta.profile,
                meta.job,
                meta.project,
                meta.tool,
                meta.req,
                meta.state.as_str(),
                meta.reverts,
                meta.imported,
                meta.note,
            ],
        )?;
        let id = sp.last_insert_rowid();
        Ok(Tx {
            id,
            at,
            meta,
            guard,
            sp,
            text: false,
        })
    }

    /// This write put an entity's text (what the entity embedder may have to send).
    pub(super) fn put_text(&mut self) {
        self.text = true;
    }

    /// Whether this write put an entity's text ([`super::writer::WriterStatus::texts`] counts those writes).
    pub(super) fn wrote_text(&self) -> bool {
        self.text
    }

    /// Release the savepoint: what the request wrote joins the batch's transaction. Dropping a `Tx` instead rolls
    /// the savepoint back (`ROLLBACK TO`, then `RELEASE`), leaving the batch's other requests as they were.
    pub(super) fn release(self) -> rusqlite::Result<()> {
        self.sp.commit()
    }
}

/// The savepoint every request runs in (nested in the batch's `BEGIN IMMEDIATE`).
const SAVEPOINT: &str = "urdr_req";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::schema::GRAPH_DDL;

    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(GRAPH_DDL).unwrap();
        c
    }

    fn txs(c: &Connection) -> i64 {
        c.query_row("select count(*) from tx", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn for_test_keeps_only_what_is_committed() {
        let mut c = db();
        let mut meta = TxMeta::new("agent:s1", Class::Agent, "mcp:task_write/create");
        meta.req = Some("r-1".into());
        meta.note = Some("why".into());
        {
            let tx = Tx::for_test(&mut c, meta.clone(), Arc::default());
            assert!(tx.id() > 0);
            assert!(tx.at() > 0.0);
            assert_eq!(tx.meta(), &meta);
            // Dropped without a commit: rolled back.
        }
        assert_eq!(txs(&c), 0);
        let tx = Tx::for_test(&mut c, meta, Arc::default());
        let id = tx.id();
        tx.commit_for_test().unwrap();
        let row: (
            String,
            String,
            String,
            Option<String>,
            String,
            i64,
            Option<String>,
        ) = c
            .query_row(
                "select actor, class, tool, req, state, imported, note from tx where id = ?1",
                [id],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            row,
            (
                "agent:s1".into(),
                "agent".into(),
                "mcp:task_write/create".into(),
                Some("r-1".into()),
                "committed".into(),
                0,
                Some("why".into())
            )
        );
    }
}
