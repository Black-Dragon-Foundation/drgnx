//! A `work.db` the way a drgnx on `main` leaves it (schema 8, `entity_vec` keyed by `n` alone) is opened by the hub:
//! every old row survives, and the second embedder's vector of an entity sits beside the first (Hrafn keys the
//! table by `(n, model)`).  Before the schema-10 move, the second `vec_put` replaced the first model's row.
//!
//! The file is made through the real opening rule (a fresh file at the current schema), closed, and given the table
//! schema 8 shipped with its rows, without the tables schema 9 adds; then the hub opens it, which moves it through 9
//! and 10 to 12.  Pattern D (pure: a file, one open, one write).

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
      (1, x'01', x'0102', 0.5, '00000000000000000000000000000000000000000000000000000000000000a1'),
      (2, x'02', x'0304', 0.25, 'tei-model'),
      (3, x'03', x'0506', 1.0, null);
    drop table step_detail;
    drop table worktree_base;
    drop table forecast_sample;
    drop table forecast_made;
    drop index entity_manager_job;
    alter table step drop column context;
    alter table step drop column acp;
    alter table step drop column head;
    alter table step drop column history_op;
    alter table step drop column undone_by;
    drop index step_session_start;
    alter table step drop column machine;
    alter table step drop column slots_used;
    alter table step drop column slots_total;
    update kv set value = '8' where key = 'schema';"
);

/// Two fingerprints (64 hex characters), as `entity_vec.model` holds them since schema 16.
const HEX_A: &str = "00000000000000000000000000000000000000000000000000000000000000a1";
const HEX_B: &str = "00000000000000000000000000000000000000000000000000000000000000b2";

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
    // schema 16 keys the vectors by fingerprint: the row of a fingerprint survives the open, the rows of a label (and of
    // no model) are dropped for the work graph to embed again (`entity_vec_fingerprint.rs`)
    assert_eq!(
        rows(&db).await,
        vec![(1, HEX_A.into(), vec![1, 2])],
        "the fingerprint row survives the open"
    );
    db.write(meta(), |tx| {
        vec_put(tx, 1, HEX_B, &[0.6, 0.8])?;
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
        [HEX_A, HEX_B],
        "the second model's vector sits beside the first"
    );
}
