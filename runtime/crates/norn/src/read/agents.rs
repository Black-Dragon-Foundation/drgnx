//! The agent registry readers (Task 5): `drgnx-coord-agent` and `drgnx-coord-agents`.

use crate::store::{CoordError, Tx};
use serde::Serialize;

const COLS: &str = "id, kind, name, cwd, worktree, branch, base, plan, task, pid, started, seen";

/// One registered agent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Agent {
    pub id: String,
    pub kind: Option<String>,
    pub name: Option<String>,
    pub cwd: Option<String>,
    pub worktree: Option<String>,
    pub branch: Option<String>,
    pub base: Option<String>,
    pub plan: Option<String>,
    pub task: Option<String>,
    pub pid: Option<i64>,
    pub started: Option<f64>,
    pub seen: Option<f64>,
}

/// The row mapper (a macro: `norn` does not name rusqlite's `Row` type).
macro_rules! row {
    () => {
        |r| {
            Ok(Agent {
                id: r.get(0)?,
                kind: r.get(1)?,
                name: r.get(2)?,
                cwd: r.get(3)?,
                worktree: r.get(4)?,
                branch: r.get(5)?,
                base: r.get(6)?,
                plan: r.get(7)?,
                task: r.get(8)?,
                pid: r.get(9)?,
                started: r.get(10)?,
                seen: r.get(11)?,
            })
        }
    };
}

/// Agent `id`, or `None`.
pub fn agent(conn: &Tx, id: &str) -> Result<Option<Agent>, CoordError> {
    match conn.query_row(
        &format!("select {COLS} from agent where id = ?1"),
        [id],
        row!(),
    ) {
        Ok(a) => Ok(Some(a)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Every registered agent, the first to start first.
pub fn agents(conn: &Tx) -> Result<Vec<Agent>, CoordError> {
    let mut st = conn.prepare(&format!("select {COLS} from agent order by started, id"))?;
    let rows = st.query_map([], row!())?;
    Ok(rows.collect::<Result<_, _>>()?)
}
