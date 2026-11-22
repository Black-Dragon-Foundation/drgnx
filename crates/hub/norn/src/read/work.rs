//! The Work space's readers (agent system part 2, Task 1): a timeline step's detail, a worktree's base, and the asks
//! behind entities.

use crate::store::{CoordError, Tx};
use crate::write::work::{StepDetail, WorktreeBase};
use urdr::SqliteError;

fn opt<T>(r: Result<T, SqliteError>) -> Result<Option<T>, CoordError> {
    match r {
        Ok(v) => Ok(Some(v)),
        Err(SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// The detail of timeline step STEP, if it has one.
pub fn step_detail(conn: &Tx, step: i64) -> Result<Option<StepDetail>, CoordError> {
    opt(conn.query_row(
        "select step, tool, kind, path, line_start, line_end, query, url, title, origin, parent_tool \
         from step_detail where step = ?1",
        [step],
        |r| {
            Ok(StepDetail {
                step: r.get(0)?,
                tool: r.get(1)?,
                kind: r.get(2)?,
                path: r.get(3)?,
                line_start: r.get(4)?,
                line_end: r.get(5)?,
                query: r.get(6)?,
                url: r.get(7)?,
                title: r.get(8)?,
                origin: r.get(9)?,
                parent_tool: r.get(10)?,
            })
        },
    ))
}

/// A `read` step's (first line, last line, agent).
pub type Read = (Option<i64>, Option<i64>, Option<String>);

/// The most `read` steps [`reads_of`] gives, the newest kept.
pub const READS_MAX: i64 = 1 << 16;

/// The `read` steps' line ranges of a file, under any of PATHS (the names a step's detail may give it: absolute or
/// relative to its worktree), newest first: (first line, last line, the step's agent) each; at most [`READS_MAX`].
/// The minimap's agent-read heat layer.
pub fn reads_of(conn: &Tx, paths: &[&str]) -> Result<Vec<Read>, CoordError> {
    let mut st = conn.prepare(
        "select d.line_start, d.line_end, s.agent from step_detail d join step s on s.id = d.step \
         where d.kind = 'read' and d.path = ?1 order by d.step desc limit ?2",
    )?;
    let mut out = Vec::new();
    for p in paths {
        for r in st.query_map((p, READS_MAX), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))? {
            out.push(r?);
        }
    }
    Ok(out)
}

/// Where WORKTREE branched from, if the hub recorded it.
pub fn base(conn: &Tx, worktree: &str) -> Result<Option<WorktreeBase>, CoordError> {
    opt(conn.query_row(
        "select worktree, repo, base_branch, base_commit, base_tree, at from worktree_base where worktree = ?1",
        [worktree],
        |r| {
            Ok(WorktreeBase {
                worktree: r.get(0)?,
                repo: r.get(1)?,
                base_branch: r.get(2)?,
                base_commit: r.get(3)?,
                base_tree: r.get(4)?,
                at: r.get(5)?,
            })
        },
    ))
}

/// For each of IDS (entity ids) that a current `asked` link reaches, `(id, ask id)`, in the order of IDS then of
/// the asks' `n`.
pub fn asks_of(conn: &Tx, ids: &[&str]) -> Result<Vec<(String, String)>, CoordError> {
    let mut st = conn.prepare(
        "select a.id from link l join entity a on a.n = l.src join entity t on t.n = l.dst \
         where l.kind = 'asked' and l.tx_to = ?2 and t.id = ?1 and a.retired_tx is null order by a.n",
    )?;
    let mut out = Vec::new();
    for id in ids {
        let rows = st.query_map((id, urdr::graph::schema::SENTINEL), |r| {
            r.get::<_, String>(0)
        })?;
        for ask in rows {
            out.push((id.to_string(), ask?));
        }
    }
    Ok(out)
}
