//! The spend reader (Task 22): `drgnx-work-db-spend` (`core/drgnx-work-db.el`).

use crate::store::{CoordError, Tx};

/// What the requests came to.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct SpendSum {
    pub input: u64,
    pub output: u64,
    /// US dollars.
    pub cost: f64,
    pub requests: u64,
}

/// The requests of JOB, TASK and AGENT (each when given; none: every request) summed.
pub fn spend_sum(
    conn: &Tx,
    job: Option<&str>,
    task: Option<&str>,
    agent: Option<&str>,
) -> Result<SpendSum, CoordError> {
    let n = |v: i64| u64::try_from(v).unwrap_or(0);
    Ok(conn.query_row(
        "select coalesce(sum(input), 0), coalesce(sum(output), 0), coalesce(sum(cost), 0.0), count(*) from spend \
         where (?1 is null or job = ?1) and (?2 is null or task = ?2) and (?3 is null or agent = ?3)",
        (job, task, agent),
        |r| {
        Ok(SpendSum {
            input: n(r.get(0)?),
            output: n(r.get(1)?),
            cost: r.get(2)?,
            requests: n(r.get(3)?),
        })
        },
    )?)
}
