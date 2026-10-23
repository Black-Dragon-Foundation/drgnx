//! The decision log's readers (Task 6): `drgnx-coord-decisions-since` and the per-agent `seen` and `held` counters.

use crate::store::{CoordError, Tx};

pub use crate::write::meta::{held, seen, version};

/// One `decision` row (`drgnx-coord--decision-plist`).
#[derive(Debug, Clone, PartialEq)]
pub struct Decision {
    pub n: i64,
    pub kind: Option<String>,
    pub subject: Option<String>,
    pub task: Option<String>,
    pub paths: Option<String>,
    pub reason: Option<String>,
    pub author: Option<String>,
    pub status: Option<String>,
    pub replaces: Option<i64>,
    pub at: Option<f64>,
    pub ver: Option<i64>,
    pub job: Option<String>,
}

const COLS: &str = "n, kind, subject, task, paths, reason, author, status, replaces, at, ver, job";

/// The row closure for [`COLS`] (a macro: `urdr` does not export SQLite's row type).
macro_rules! from_row {
    () => {
        |r| {
            Ok(Decision {
                n: r.get(0)?,
                kind: r.get(1)?,
                subject: r.get(2)?,
                task: r.get(3)?,
                paths: r.get(4)?,
                reason: r.get(5)?,
                author: r.get(6)?,
                status: r.get(7)?,
                replaces: r.get(8)?,
                at: r.get(9)?,
                ver: r.get(10)?,
                job: r.get(11)?,
            })
        }
    };
}

/// Decisions recorded, or whose status changed, after version V (newest first); JOB's only, when given
/// (`drgnx-coord-decisions-since`).
pub fn decisions_since(
    conn: &Tx,
    v: u64,
    job: Option<&str>,
) -> Result<Vec<Decision>, CoordError> {
    let sql = format!(
        "select {COLS} from decision where ver > ?1{} order by n desc",
        if job.is_some() { " and job = ?2" } else { "" }
    );
    let mut st = conn.prepare(&sql)?;
    let rows = match job {
        Some(j) => st
            .query_map((v as i64, j), from_row!())?
            .collect::<Result<_, _>>(),
        None => st
            .query_map([v as i64], from_row!())?
            .collect::<Result<_, _>>(),
    };
    Ok(rows?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn decisions_since_a_version_newest_first() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into decision (n, kind, subject, status, at, ver, job) values (1, 'build', 'a', 'current', 1.0, 1, 'j');
             insert into decision (n, kind, subject, status, at, ver, job) values (2, 'wait', 'b', 'current', 2.0, 2, 'k');",
        )
        .unwrap();
        let all = decisions_since(&c, 0, None).unwrap();
        assert_eq!(all.iter().map(|d| d.n).collect::<Vec<_>>(), [2, 1]);
        assert_eq!(decisions_since(&c, 1, None).unwrap().len(), 1);
        assert_eq!(decisions_since(&c, 0, Some("j")).unwrap()[0].n, 1);
    }
}
