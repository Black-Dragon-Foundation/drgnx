//! `work.db` schema 10 → 11 (forecasts): `step.context` (the session's context size when the step closed) and the two
//! forecast tables.  `forecast_sample` holds one row per finished task, derived from the `step` and `spend` tables;
//! `forecast_made` holds what a forecast said when a job was proposed, to calibrate later ones.  Both hold numbers
//! and ids only: no prompt, brief or transcript text.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the statements, then `schema = 11`.  A crash leaves schema 10 as
//! it was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 11;

const DDL: &str = "
alter table step add column context integer;
create table forecast_sample(
  task text primary key, job text not null, project text, role text not null,
  profile text, provider text, model text, brief_bytes integer not null, tasks integer not null default 1,
  tokens_in integer not null, tokens_out integer not null, cache_read integer not null, cache_write integer not null,
  turns integer not null, active_secs real not null, wall_secs real not null, job_wait_secs real not null,
  wakes integer not null, cold_wakes integer not null, context integer,
  cost real, cost_unit text, outcome text not null, last_step integer not null, at real not null);
create index forecast_sample_class on forecast_sample(role, profile);
create table forecast_made(
  job text not null, task text not null, made_at real not null, role text, profile text, model text,
  tokens_p50 real not null, tokens_p90 real not null, secs_p50 real not null, secs_p90 real not null,
  cost_p50 real, cost_p90 real, cost_unit text, basis text not null, n integer not null,
  primary key (job, task));";

/// Move the schema-10 file on CONN to 11, in one transaction; `Ok(false)` when the file is not schema 10 when the
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
        if schema.as_deref().map(str::trim) != Some("10") {
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
    use crate::store::tests::db10;

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

    /// Pattern D. The previous top moves to 11, and a second open changes nothing.
    #[test]
    fn the_previous_top_moves_to_11_and_a_second_open_changes_nothing() {
        let mut c = db10();
        assert_eq!(schema(&c), "10");
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(schema(&c), "11");
        assert!(has_column(&c, "step", "context"));
        assert!(has_column(&c, "forecast_sample", "last_step"));
        assert!(has_column(&c, "forecast_made", "basis"));
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(schema(&c), "11");
    }

    /// Pattern D. A file at schema 7 goes through every step to the top.
    #[test]
    fn a_schema_7_file_goes_through_to_the_top() {
        let mut c = crate::store::tests::db7_only();
        for f in [
            crate::migrate8::upgrade,
            crate::migrate9::upgrade,
            crate::migrate10::upgrade,
            upgrade,
        ] {
            assert!(f(&mut c).unwrap());
        }
        assert_eq!(schema(&c), SCHEMA.to_string());
        assert!(has_column(&c, "step", "context"));
    }

    /// Pattern D. A failure inside the move leaves schema 10 (one transaction).
    #[test]
    fn a_failed_move_changes_nothing() {
        let mut c = db10();
        c.execute_batch("create table forecast_made (x)").unwrap();
        assert!(upgrade(&mut c).is_err());
        assert_eq!(schema(&c), "10");
        assert!(!has_column(&c, "step", "context"), "the column rolled back");
    }
}
