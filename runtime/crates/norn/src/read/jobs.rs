//! The jobs readers (Task 6): `drgnx-coord-job` and `drgnx-coord-jobs`.

use super::tasks::opt;
use crate::store::{CoordError, Tx};

/// One `job` row; `data` is the JSON the writer stored.
#[derive(Debug, Clone, PartialEq)]
pub struct Job {
    pub id: String,
    pub title: Option<String>,
    pub plan: Option<String>,
    pub repo: Option<String>,
    pub status: Option<String>,
    pub created: Option<f64>,
    pub data: Option<serde_json::Value>,
}

/// Job ID, or `None` (`drgnx-coord-job`).  Data that is not JSON reads as absent (the column has a check).
pub fn job(conn: &Tx, id: &str) -> Result<Option<Job>, CoordError> {
    opt(conn.query_row(
        "select id, title, plan, repo, status, created, data from job where id = ?1",
        [id],
        |r| {
            let data: Option<String> = r.get(6)?;
            Ok(Job {
                id: r.get(0)?,
                title: r.get(1)?,
                plan: r.get(2)?,
                repo: r.get(3)?,
                status: r.get(4)?,
                created: r.get(5)?,
                data: data.and_then(|d| serde_json::from_str(&d).ok()),
            })
        },
    ))
}

/// Every job's id (with STATUS when given), newest first (`drgnx-coord-jobs`).
pub fn jobs(conn: &Tx, status: Option<&str>) -> Result<Vec<String>, CoordError> {
    let sql = format!(
        "select id from job{} order by created desc",
        if status.is_some() {
            " where status = ?1"
        } else {
            ""
        }
    );
    let mut st = conn.prepare(&sql)?;
    let rows = match status {
        Some(s) => st.query_map([s], |r| r.get(0))?.collect::<Result<_, _>>(),
        None => st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>(),
    };
    Ok(rows?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn jobs_newest_first_and_by_status() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into job values ('old', 't', null, null, 'proposed', 1.0, null);
             insert into job values ('new', 't', null, null, 'running', 2.0, '{\"a\":1}');",
        )
        .unwrap();
        assert_eq!(jobs(&c, None).unwrap(), ["new", "old"]);
        assert_eq!(jobs(&c, Some("proposed")).unwrap(), ["old"]);
        let j = job(&c, "new").unwrap().unwrap();
        assert_eq!(j.data, Some(serde_json::json!({"a": 1})));
        assert_eq!(job(&c, "nope").unwrap(), None);
    }
}
