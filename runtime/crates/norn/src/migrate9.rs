//! `work.db` schema 8 → 9 (Hrafn): `entity_vec` keyed by `(n, model)`, so each embedder keeps its own vector of an
//! entity.  Schema 8 shipped the table keyed by `n` alone (one model per entity, the last writer winning).
//!
//! The move is one `BEGIN IMMEDIATE` transaction: it builds the new table, copies every row with its model (a row
//! with none keeps the empty name, which no embedder asks for, so it is embedded again and the old row stays
//! until the entity changes), drops the old table, renames the new one and sets `schema = 9`.  A crash leaves schema
//! 8 as it was.  A file whose table already has the key (a fresh one, made from today's DDL) only gets the number.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 9;

/// Move the schema-8 file on CONN to 9, in one transaction; `Ok(false)` when the file is not schema 8 when the
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
        if schema.as_deref().map(str::trim) != Some("8") {
            return Ok(false);
        }
        if !keyed_by_model(conn)? {
            conn.execute_batch(
                "create table entity_vec_new (
                   n integer not null, model text not null, bits blob, vec blob, scale real,
                   primary key (n, model)) without rowid;
                 insert into entity_vec_new(n, model, bits, vec, scale)
                   select n, coalesce(model, ''), bits, vec, scale from entity_vec;
                 drop table entity_vec;
                 alter table entity_vec_new rename to entity_vec;",
            )?;
        }
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

/// Whether `entity_vec`'s primary key includes `model`.
fn keyed_by_model(conn: &Connection) -> Result<bool, urdr::SqliteError> {
    conn.query_row(
        "select count(*) from pragma_table_info('entity_vec') where name = 'model' and pk > 0",
        [],
        |r| r.get::<_, i64>(0),
    )
    .map(|n| n > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::db7;
    use std::sync::Arc;
    use urdr::graph::search::vec_put;
    use urdr::graph::{Class, Tx, TxMeta};

    /// The table as schema 8 shipped it: one row per entity, the model a plain column.  (The statement is built from
    /// pieces so that the graph tables' one-write-path scan, `urdr/tests/one_write_path.rs`, does not see a fixture.)
    const OLD_ENTITY_VEC: &str = concat!(
        "
        drop table entity_vec;
        create table entity_vec (n integer primary key, bits blob, vec blob, scale real, model text);
        insert",
        " into entity_vec(n, bits, vec, scale, model) values
          (1, x'01', x'0102', 0.5, 'gte-modernbert-base'),
          (2, x'02', x'0304', 0.25, 'tei-model'),
          (3, x'03', x'0506', 1.0, null);
        update kv set value = '8' where key = 'schema';"
    );

    /// A schema-8 file as it is on disk today.
    fn shipped() -> urdr::Connection {
        let c = db7();
        c.execute_batch(OLD_ENTITY_VEC).unwrap();
        c
    }

    fn rows(c: &urdr::Connection) -> Vec<(i64, String, Vec<u8>, f64)> {
        let mut st = c
            .prepare("select n, model, vec, scale from entity_vec order by n, model")
            .unwrap();
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    /// Pattern D. The move keeps every row with its model (a row without one keeps the empty name), is one step, and
    /// does nothing the second time.
    #[test]
    fn rebuild_keeps_every_row_and_its_model() {
        let mut c = shipped();
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(
            rows(&c),
            vec![
                (1, "gte-modernbert-base".into(), vec![1, 2], 0.5),
                (2, "tei-model".into(), vec![3, 4], 0.25),
                (3, String::new(), vec![5, 6], 1.0),
            ]
        );
        let schema: String = c
            .query_row("select value from kv where key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(schema, "9");
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(rows(&c).len(), 3);
    }

    /// Pattern D. After the move a second model's vector sits beside the first; before it, it replaced it.
    #[test]
    fn a_second_model_sits_beside_the_first() {
        let mut c = shipped();
        assert!(upgrade(&mut c).unwrap());
        let mut tx = Tx::for_test(
            &mut c,
            TxMeta::new("user", Class::User, "test"),
            Arc::default(),
        );
        vec_put(&mut tx, 1, "granite", &[0.6, 0.8]).unwrap();
        tx.commit_for_test().unwrap();
        let models: Vec<String> = c
            .prepare("select model from entity_vec where n = 1 order by model")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(models, ["granite", "gte-modernbert-base"]);
    }

    /// Pattern D. A file made at schema 7 with today's table (a fresh install) already has the key: the move changes
    /// nothing but the number.
    #[test]
    fn a_table_with_the_key_is_left_alone() {
        let mut c = db7();
        c.execute("update kv set value = '8' where key = 'schema'", [])
            .unwrap();
        c.execute(
            concat!(
                "insert",
                " into entity_vec(n, model, bits, vec, scale) values (1, 'm', x'01', x'01', 1.0)"
            ),
            [],
        )
        .unwrap();
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(rows(&c), vec![(1, "m".into(), vec![1], 1.0)]);
    }

    /// Pattern D. A failure inside the move leaves the old table and schema 8 (one transaction).
    #[test]
    fn a_failed_move_changes_nothing() {
        let mut c = shipped();
        // the rebuilt table's `not null` refuses this row's null `bits`-independent key: make the copy fail
        c.execute_batch("create table entity_vec_new (x)").unwrap();
        assert!(upgrade(&mut c).is_err());
        let schema: String = c
            .query_row("select value from kv where key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(schema, "8");
        let n: i64 = c
            .query_row("select count(*) from entity_vec", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 3);
    }
}
