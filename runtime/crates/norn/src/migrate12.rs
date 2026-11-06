//! `work.db` schema 11 → 12 (agent system part 4, the timeline): four nullable `step` columns.  `acp` names the agent
//! conversation the step ran in (a revert keeps the hub session and starts another conversation under it, so several
//! share a session), `head` the worktree's commit when the step's snapshot was taken (read from ref files: an
//! agent's claim, checked before use), `history_op` the edit history's record the step anchors, and `undone_by` the
//! record of the revert that abandoned the step.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the statements, then `schema = 12`.  A crash leaves schema 11 as
//! it was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 12;

const DDL: &str = "
alter table step add column acp text;
alter table step add column head text;
alter table step add column history_op integer;
alter table step add column undone_by integer;";

/// Move the schema-11 file on CONN to 12, in one transaction; `Ok(false)` when the file is not schema 11 when the
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
        if schema.as_deref().map(str::trim) != Some("11") {
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
    use crate::store::tests::db11;

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

    /// Pattern D. A schema-11 file's steps survive the move with the four columns empty, and a second move changes
    /// nothing.
    #[test]
    fn upgrade_keeps_rows_and_is_idempotent() {
        let mut c = db11();
        c.execute_batch(
            "insert into step (session, seq, class, start, message_id, snapshot, log_version, context) \
             values ('session:s', 1, 'tool', 1.0, 'm1', 'tree1', 4, 900), \
                    ('session:s', 2, 'think', 2.0, null, null, 5, null)",
        )
        .unwrap();
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(schema(&c), "12");
        for col in ["acp", "head", "history_op", "undone_by"] {
            assert!(has_column(&c, "step", col), "{col}");
        }
        type Row = (
            i64,
            Option<String>,
            Option<String>,
            Option<i64>,
            Option<String>,
        );
        let rows: Vec<Row> = c
            .prepare("select seq, message_id, snapshot, context, acp from step order by seq")
            .unwrap()
            .query_map([], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(
            rows,
            [
                (1, Some("m1".into()), Some("tree1".into()), Some(900), None),
                (2, None, None, None, None)
            ]
        );
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(schema(&c), "12");
    }

    /// Pattern D. A file at schema 7 goes through every step to the top.
    #[test]
    fn a_schema_7_file_goes_through_to_the_top() {
        let mut c = crate::store::tests::db7_only();
        for f in [
            crate::migrate8::upgrade,
            crate::migrate9::upgrade,
            crate::migrate10::upgrade,
            crate::migrate11::upgrade,
            upgrade,
        ] {
            assert!(f(&mut c).unwrap());
        }
        assert_eq!(schema(&c), SCHEMA.to_string());
        assert!(has_column(&c, "step", "context"));
        assert!(has_column(&c, "step", "undone_by"));
    }
}
