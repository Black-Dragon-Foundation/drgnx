//! `work.db` schema 12 → 13 (timeline and budget hub plan H7): the machine a step ran on and, for a step that waited
//! for a machine's slot, the slots used and in all when the wait began (`machine`, `slots_used`, `slots_total`), and an
//! index of a session's steps by start for the Timeline's windows.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the statements, then `schema = 13`.  A crash leaves schema 12 as
//! it was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 13;

const DDL: &str = "
alter table step add column machine text;
alter table step add column slots_used integer;
alter table step add column slots_total integer;
create index if not exists step_session_start on step(session, start);";

/// Move the schema-12 file on CONN to 13, in one transaction; `Ok(false)` when the file is not schema 12 when the
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
        if schema.as_deref().map(str::trim) != Some("12") {
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
                crate::rollback(conn);
            })?;
            Ok(done)
        }
        Err(e) => {
            crate::rollback(conn);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::db12;

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

    /// Pattern D. A schema-12 file's steps survive with the three columns empty, the index is there, and a second move
    /// changes nothing.
    #[test]
    fn migrate13_adds_the_columns_and_index() {
        let mut c = db12();
        c.execute_batch(
            "insert into step (session, seq, class, start) values ('session:s', 1, 'tool', 1.0), ('session:s', 2, 'think', 2.0)",
        )
        .unwrap();
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(schema(&c), "13");
        for col in ["machine", "slots_used", "slots_total"] {
            assert!(has_column(&c, "step", col), "{col}");
        }
        let idx: i64 = c
            .query_row(
                "select count(*) from sqlite_master where type = 'index' and name = 'step_session_start'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(idx, 1);
        let kept: i64 = c
            .query_row(
                "select count(*) from step where machine is null and slots_used is null",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(kept, 2);
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(schema(&c), "13");
    }

    /// A crash inside the move (a statement that fails) leaves schema 12 as it was and no column.
    #[test]
    fn a_failed_move_leaves_schema_12() {
        let mut c = db12();
        // the column already there: the second `alter` fails after the first one ran
        c.execute_batch("alter table step add column slots_used integer")
            .unwrap();
        assert!(upgrade(&mut c).is_err());
        assert_eq!(schema(&c), "12");
        assert!(!has_column(&c, "step", "machine"));
    }
}
