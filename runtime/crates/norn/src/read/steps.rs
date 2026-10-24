//! The step readers (agent system part 1, Task 4): a session's steps, and the roll-up of time, cost and tokens by
//! session, task, plan or project.

use crate::store::{CoordError, Tx};
use crate::write::steps::StepClass;
use std::collections::BTreeMap;

/// One `step` row.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub id: i64,
    pub session: String,
    pub task: Option<String>,
    pub plan: Option<String>,
    pub project: Option<String>,
    pub agent: Option<String>,
    pub provider: Option<String>,
    pub seq: i64,
    pub class: StepClass,
    pub start: f64,
    pub end: Option<f64>,
    pub tool: Option<String>,
    pub tool_kind: Option<String>,
    pub message_id: Option<String>,
    pub turn_id: Option<String>,
    pub snapshot: Option<String>,
    pub log_version: Option<i64>,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub cost: Option<f64>,
    pub cost_unit: Option<String>,
}

/// SESSION's steps with `seq` above SINCE_SEQ, in order.
pub fn for_session(conn: &Tx, session: &str, since_seq: i64) -> Result<Vec<Step>, CoordError> {
    for_scope(conn, Scope::Session, session, since_seq, i64::MAX)
}

/// The steps of SCOPE ID after SINCE (a session's `seq`, else a step id), in order, at most LIMIT.
pub fn for_scope(
    conn: &Tx,
    scope: Scope,
    id: &str,
    since: i64,
    limit: i64,
) -> Result<Vec<Step>, CoordError> {
    let (col, key) = match scope {
        Scope::Session => ("session", "seq"),
        Scope::Task => ("task", "id"),
        Scope::Plan => ("plan", "id"),
        Scope::Project => ("project", "id"),
    };
    let mut st = conn.prepare(&format!(
        "select id, session, task, plan, project, agent, provider, seq, class, start, end, tool, tool_kind, \
         message_id, turn_id, snapshot, log_version, tokens_in, tokens_out, cache_read, cache_write, cost, \
         cost_unit from step where {col} = ?1 and {key} > ?2 order by {key} limit ?3",
    ))?;
    let rows = st.query_map((id, since, limit), |r| {
        let class: String = r.get(8)?;
        Ok(Step {
            id: r.get(0)?,
            session: r.get(1)?,
            task: r.get(2)?,
            plan: r.get(3)?,
            project: r.get(4)?,
            agent: r.get(5)?,
            provider: r.get(6)?,
            seq: r.get(7)?,
            class: StepClass::parse(&class).unwrap_or(StepClass::Think),
            start: r.get(9)?,
            end: r.get(10)?,
            tool: r.get(11)?,
            tool_kind: r.get(12)?,
            message_id: r.get(13)?,
            turn_id: r.get(14)?,
            snapshot: r.get(15)?,
            log_version: r.get(16)?,
            tokens_in: r.get(17)?,
            tokens_out: r.get(18)?,
            cache_read: r.get(19)?,
            cache_write: r.get(20)?,
            cost: r.get(21)?,
            cost_unit: r.get(22)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// What a roll-up is over.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Session,
    Task,
    Plan,
    Project,
}

/// Token totals.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tokens {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
}

/// Seconds by class (closed steps only), cost by unit and tokens.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Rollup {
    pub secs_by_class: BTreeMap<String, f64>,
    pub cost_by_unit: BTreeMap<String, f64>,
    pub tokens: Tokens,
}

/// The roll-up of the steps of SCOPE ID.
pub fn rollup(conn: &Tx, scope: Scope, id: &str) -> Result<Rollup, CoordError> {
    let col = match scope {
        Scope::Session => "session",
        Scope::Task => "task",
        Scope::Plan => "plan",
        Scope::Project => "project",
    };
    let mut out = Rollup::default();
    let mut st = conn.prepare(&format!(
        "select class, coalesce(sum(end - start), 0.0), coalesce(sum(tokens_in), 0), coalesce(sum(tokens_out), 0), \
         coalesce(sum(cache_read), 0), coalesce(sum(cache_write), 0) from step where {col} = ?1 group by class"
    ))?;
    let rows = st.query_map([id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, f64>(1)?,
            [r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?],
        ))
    })?;
    for row in rows {
        let (class, secs, t): (String, f64, [i64; 4]) = row?;
        if secs > 0.0 {
            out.secs_by_class.insert(class, secs);
        }
        out.tokens.input += t[0];
        out.tokens.output += t[1];
        out.tokens.cache_read += t[2];
        out.tokens.cache_write += t[3];
    }
    let mut st = conn.prepare(&format!(
        "select cost_unit, sum(cost) from step where {col} = ?1 and cost is not null and cost_unit is not null \
         group by cost_unit"
    ))?;
    for row in st.query_map([id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))? {
        let (unit, cost) = row?;
        out.cost_by_unit.insert(unit, cost);
    }
    Ok(out)
}
