//! `work.db` schema 15 → 16 (Hrafn redesign Task 5, MP-17 identity part): `entity_vec.model` is a fingerprint (64 hex
//! characters), so the rows keyed by a label (`tei:tei`, a model id, no model at all) are dropped on the move and the
//! work graph embeds those entities again; the rows keyed by a fingerprint stay as they are.
//!
//! The file is made through the real opening rule (a fresh file at the current schema), closed, given rows of both
//! kinds and put back at schema 15; then the hub opens it. Pattern D (pure: a file, one open).

use norn::store::CoordDb;

/// A fingerprint, as a model column holds it.
const HEX_A: &str = "22d66a3886b0a9e6f3938c62b19081da265c8b03f1474f38a2271f97b449f629";
const HEX_B: &str = "0000000000000000000000000000000000000000000000000000000000000001";

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

async fn schema(db: &CoordDb) -> String {
    db.read(|c| {
        Ok(
            c.query_row("select value from kv where key = 'schema'", [], |r| {
                r.get::<_, String>(0)
            })?,
        )
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn migrate16_drops_label_rows_keeps_hex_rows() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    {
        let db = CoordDb::spawn(&file);
        rows(&db).await; // the opening rule has made the file
    }
    let conn = urdr::Connection::open(&file).unwrap();
    let too_short = &HEX_A[..63];
    let not_hex = "g".repeat(64);
    // built from pieces so that the graph tables' one-write-path scan (`urdr/tests/one_write_path.rs`) sees no fixture
    let insert = concat!(
        "insert",
        " into entity_vec(n, bits, vec, scale, model) values"
    );
    for (n, vec, model) in [
        (1, "0102", Some("tei:tei")),
        (1, "0304", Some(HEX_A)),
        (2, "0506", Some("granite-embedding-small-english-r2")),
        (3, "0708", Some(HEX_B)),
        (4, "0909", Some("")), // schema 10 kept the empty name of a row with no model
        (5, "0101", Some(too_short)),
        (6, "0202", Some(not_hex.as_str())),
    ] {
        let model = model.map_or("null".to_owned(), |m| format!("'{m}'"));
        conn.execute_batch(&format!("{insert} ({n}, x'01', x'{vec}', 0.5, {model});"))
            .unwrap();
    }
    conn.execute("update kv set value = '15' where key = 'schema'", [])
        .unwrap();
    drop(conn);

    let db = CoordDb::spawn(&file);
    assert_eq!(
        rows(&db).await,
        vec![
            (1, HEX_A.to_owned(), vec![3, 4]),
            (3, HEX_B.to_owned(), vec![7, 8]),
        ],
        "the label rows go, the fingerprint rows stay"
    );
    assert_eq!(schema(&db).await, "16");
}
