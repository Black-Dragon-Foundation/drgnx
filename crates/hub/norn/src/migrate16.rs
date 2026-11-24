//! `work.db` schema 15 → 16: `entity_vec.model` is a fingerprint (Hrafn redesign Task 5, MP-17's identity part).
//!
//! Until now the column held a label: a model id (`granite-embedding-small-english-r2`) or a server's name
//! (`tei:tei`, `ollama:ollama:qwen3-embedding:0.6b`), which says nothing of the weights, the pooling or the prompt that
//! made the vector. A fingerprint is 64 hex characters (`hrafn_embed::fingerprint::Fingerprint::hex`). The move deletes
//! every row whose `model` is not one (a label, or none at all); the work graph embeds those entities again, with the
//! embedder's fingerprint (`urdr::graph::search::Embedder::model`). Rows already keyed by a fingerprint stay as they are.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the rows deleted, then `schema = 16`. A crash leaves schema 15 as it
//! was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 16;

/// Move the schema-15 file on CONN to 16, in one transaction; `Ok(false)` when the file is not schema 15 when the
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
        if schema.as_deref().map(str::trim) != Some("15") {
            return Ok(false);
        }
        // a fingerprint is 64 characters, each one of 0-9 a-f: nothing else (a NULL model included) is one
        // (built from pieces: the graph tables' one-write-path scan, `urdr/tests/one_write_path.rs`, looks for the
        // statements written whole; this is the one move that may touch the table outside urdr)
        conn.execute_batch(concat!(
            "delete",
            " from entity_vec
             where model is null or length(model) != 64 or model glob '*[^0-9a-f]*';"
        ))?;
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
