//! The spend writer (Task 22; Urdr Task 12b): `drgnx-work-db-add-spend` (`core/drgnx-work-db.el`), one row per request
//! the gateway carried, written inside a graph transaction (class `system`, tool `gateway`): the row carries that
//! transaction's id in `tx`.  `job` is null for the editor's requests.

use crate::store::{CoordError, WTx};

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
pub fn add_spend(tx: &WTx<'_>, row: &SpendRow, now: f64) -> Result<(), CoordError> {
    let int = |n: u64| i64::try_from(n).unwrap_or(i64::MAX);
    tx.sql().execute(
        "insert into spend (at, job, task, agent, provider, model, input, output, cost, status, tx) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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
            tx.id(),
        ),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::spend::spend_sum;
    use crate::store::tests::{db7, tx_of};

    #[test]
    fn a_row_is_added_and_summed_and_the_editors_has_no_job() {
        let mut c = db7();
        let tx = tx_of(&mut c);
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
        add_spend(&tx, &row, 1.0).unwrap();
        add_spend(&tx, &row, 2.0).unwrap();
        let editor = SpendRow {
            agent: Some("editor".into()),
            provider: "ollama".into(),
            input: 7,
            ..SpendRow::default()
        };
        add_spend(&tx, &editor, 3.0).unwrap();
        let j = spend_sum(tx.sql(), Some("j1"), None, None).unwrap();
        assert_eq!((j.input, j.output, j.requests), (200, 40, 2));
        assert!((j.cost - 1.0).abs() < 1e-9);
        let all = spend_sum(tx.sql(), None, None, None).unwrap();
        assert_eq!((all.input, all.requests), (207, 3));
        let ed = spend_sum(tx.sql(), None, None, Some("editor")).unwrap();
        assert_eq!((ed.input, ed.requests, ed.cost), (7, 1, 0.0));
        let null_job: i64 = tx
            .sql()
            .query_row("select count(*) from spend where job is null", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(null_job, 1);
    }

    #[test]
    fn a_row_carries_the_tx_that_wrote_it() {
        let mut c = db7();
        let tx = tx_of(&mut c);
        let row = SpendRow {
            provider: "tei".into(),
            ..SpendRow::default()
        };
        add_spend(&tx, &row, 1.0).unwrap();
        let by: i64 = tx
            .sql()
            .query_row("select tx from spend", [], |r| r.get(0))
            .unwrap();
        assert_eq!(by, tx.id());
        let (class, tool): (String, String) = tx
            .sql()
            .query_row("select class, tool from tx where id = ?1", [by], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((class.as_str(), tool.as_str()), ("system", "test"));
    }
}
