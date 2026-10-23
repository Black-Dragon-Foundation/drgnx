//! The spend writer (Task 22): `drgnx-work-db-add-spend` (`core/drgnx-work-db.el`), one row per request the gateway
//! carried.  The schema-6 columns; `job` is null for the editor's requests.

use crate::store::{CoordError, Tx};

/// One request the gateway carried.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SpendRow {
    pub job: Option<String>,
    pub task: Option<String>,
    pub agent: Option<String>,
    pub provider: String,
    pub model: Option<String>,
    pub input: u64,
    pub output: u64,
    /// US dollars.
    pub cost: f64,
    /// The provider's HTTP status, 0 when the client left before the head.
    pub status: u16,
}

/// Record ROW at NOW (seconds since the epoch, as `float-time`).
pub fn add_spend(tx: &Tx, row: &SpendRow, now: f64) -> Result<(), CoordError> {
    let int = |n: u64| i64::try_from(n).unwrap_or(i64::MAX);
    tx.execute(
        "insert into spend (at, job, task, agent, provider, model, input, output, cost, status) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        (
            now,
            &row.job,
            &row.task,
            &row.agent,
            &row.provider,
            &row.model,
            int(row.input),
            int(row.output),
            row.cost,
            i64::from(row.status),
        ),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::spend::spend_sum;
    use crate::store::tests::DDL;

    #[test]
    fn a_row_is_added_and_summed_and_the_editors_has_no_job() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        let row = SpendRow {
            job: Some("j1".into()),
            task: Some("j1#1".into()),
            agent: Some("agent-1".into()),
            provider: "openrouter".into(),
            model: Some("m".into()),
            input: 100,
            output: 20,
            cost: 0.5,
            status: 200,
        };
        add_spend(&c, &row, 1.0).unwrap();
        add_spend(&c, &row, 2.0).unwrap();
        let editor = SpendRow {
            agent: Some("editor".into()),
            provider: "ollama".into(),
            input: 7,
            ..SpendRow::default()
        };
        add_spend(&c, &editor, 3.0).unwrap();
        let j = spend_sum(&c, Some("j1"), None, None).unwrap();
        assert_eq!((j.input, j.output, j.requests), (200, 40, 2));
        assert!((j.cost - 1.0).abs() < 1e-9);
        let all = spend_sum(&c, None, None, None).unwrap();
        assert_eq!((all.input, all.requests), (207, 3));
        let ed = spend_sum(&c, None, None, Some("editor")).unwrap();
        assert_eq!((ed.input, ed.requests, ed.cost), (7, 1, 0.0));
        let null_job: i64 = c
            .query_row("select count(*) from spend where job is null", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(null_job, 1);
    }
}
