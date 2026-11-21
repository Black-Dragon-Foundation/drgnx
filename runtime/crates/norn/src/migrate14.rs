//! `work.db` schema 13 → 14 (timeline and budget hub plan H9): what a forecast said of when a task starts and
//! ends, kept with the rest of `forecast_made` (`start_p50`, `start_p90`, `finish_p50`, `finish_p90`, seconds from the
//! run's start): the baseline an approved job is compared against.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the statements, then `schema = 14`.  A crash leaves schema 13 as
//! it was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 14;

const DDL: &str = "
alter table forecast_made add column start_p50 real;
alter table forecast_made add column start_p90 real;
alter table forecast_made add column finish_p50 real;
alter table forecast_made add column finish_p90 real;";

/// Move the schema-13 file on CONN to 14, in one transaction; `Ok(false)` when the file is not schema 13 when the
/// transaction holds the lock (another process moved it, or it is another schema): nothing is done.
pub fn upgrade(conn: &mut Connection) -> Result<bool, urdr::SqliteError> {
    conn.execute_batch("begin immediate")?;
    let out = (|| {
        let schema: Option<String> = conn
            .query_row("select value from kv where key = 'schema'", [], |r| {
                r.get(0)
            })
            .map(Some)
            .or_else(|e| match e {
                urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                e => Err(e),
            })?;
        if schema.as_deref().map(str::trim) != Some("13") {
            return Ok(false);
        }
        conn.execute_batch(DDL)?;
        conn.execute(
            "insert or replace into kv (key, value) values ('schema', ?1)",
            [SCHEMA.to_string()],
        )?;
        Ok(true)
    })();
    match out {
        Ok(done) => {
            conn.execute_batch("commit").inspect_err(|_| {
                let _ = conn.execute_batch("rollback");
            })?;
            Ok(done)
        }
        Err(e) => {
            let _ = conn.execute_batch("rollback");
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::db13;

    fn schema(c: &Connection) -> String {
        c.query_row("select value from kv where key = 'schema'", [], |r| {
            r.get(0)
        })
        .unwrap()
    }

    fn has_column(c: &Connection, table: &str, col: &str) -> bool {
        c.query_row(
            "select count(*) from pragma_table_info(?1) where name = ?2",
            (table, col),
            |r| r.get::<_, i64>(0),
        )
        .unwrap()
            > 0
    }

    /// Pattern D. A schema-13 file's forecasts survive with the four columns empty, and a second move changes nothing.
    #[test]
    fn migrate14_adds_the_columns() {
        let mut c = db13();
        c.execute_batch(
            "insert into forecast_made (job, task, made_at, tokens_p50, tokens_p90, secs_p50, secs_p90, basis, n) \
             values ('J', 'J#1', 1.0, 1, 2, 3, 4, 'b', 0)",
        )
        .unwrap();
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(schema(&c), "14");
        for col in ["start_p50", "start_p90", "finish_p50", "finish_p90"] {
            assert!(has_column(&c, "forecast_made", col), "{col}");
        }
        let kept: i64 = c
            .query_row(
                "select count(*) from forecast_made where start_p50 is null and finish_p90 is null",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(kept, 1);
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(schema(&c), "14");
    }

    /// A crash inside the move (a statement that fails) leaves schema 13 as it was and no column.
    #[test]
    fn a_failed_move_leaves_schema_13() {
        let mut c = db13();
        // the column already there: the second `alter` fails after the first one ran
        c.execute_batch("alter table forecast_made add column start_p90 real")
            .unwrap();
        assert!(upgrade(&mut c).is_err());
        assert_eq!(schema(&c), "13");
        assert!(!has_column(&c, "forecast_made", "start_p50"));
    }
}
