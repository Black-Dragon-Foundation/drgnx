//! A `work.db` the way a drgnx on `main` leaves it (schema 8, `entity_vec` keyed by `n` alone) is opened by the hub:
//! every old row survives, and the second embedder's vector of an entity sits beside the first (Hrafn keys the
//! table by `(n, model)`).  Before the schema-10 move, the second `vec_put` replaced the first model's row.
//!
//! The file is made through the real opening rule (a fresh file at the current schema), closed, and given the table
//! schema 8 shipped with its rows, without the tables schema 9 adds; then the hub opens it, which moves it through 9
//! to 10.  Pattern D (pure: a file, one open, one write).

use norn::store::CoordDb;
use urdr::graph::search::vec_put;
use urdr::graph::{Class, TxMeta};

/// `entity_vec` as schema 8 shipped it: one row per entity, the model a plain column.
/// (Built from pieces so that the graph tables' one-write-path scan, `urdr/tests/one_write_path.rs`, does not see a
/// fixture.)
const SHIPPED: &str = concat!(
    "
    drop table entity_vec;
    create table entity_vec (n integer primary key, bits blob, vec blob, scale real, model text);
    insert",
    " into entity_vec(n, bits, vec, scale, model) values
      (1, x'01', x'0102', 0.5, 'gte-modernbert-base'),
      (2, x'02', x'0304', 0.25, 'tei-model'),
      (3, x'03', x'0506', 1.0, null);
    drop table step_detail;
    drop table worktree_base;
    update kv set value = '8' where key = 'schema';"
);

fn meta() -> TxMeta {
    TxMeta::new("hub", Class::System, "test")
}

async fn rows(db: &CoordDb) -> Vec<(i64, String, Vec<u8>)> {
    db.read(|c| {
        let mut st =
            c.prepare("select n, coalesce(model, ''), vec from entity_vec order by n, model")?;
        let out = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        Ok(out.collect::<Result<Vec<_>, _>>()?)
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn a_schema_8_file_keeps_its_rows_and_gains_the_second_model() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    {
        let db = CoordDb::spawn(&file);
        rows(&db).await; // the opening rule has made the file
    }
    urdr::Connection::open(&file)
        .unwrap()
        .execute_batch(SHIPPED)
        .unwrap();

    let db = CoordDb::spawn(&file);
    assert_eq!(
        rows(&db).await,
        vec![
            (1, "gte-modernbert-base".into(), vec![1, 2]),
            (2, "tei-model".into(), vec![3, 4]),
            (3, String::new(), vec![5, 6]),
        ],
        "every old row survives the open"
    );
    db.write(meta(), |tx| {
        vec_put(tx, 1, "granite", &[0.6, 0.8])?;
        Ok(())
    })
    .await
    .unwrap();
    let models: Vec<String> = rows(&db)
        .await
        .into_iter()
        .filter(|r| r.0 == 1)
        .map(|r| r.1)
        .collect();
    assert_eq!(
        models,
        ["granite", "gte-modernbert-base"],
        "the second model's vector sits beside the first"
    );
}
