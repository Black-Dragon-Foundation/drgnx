//! The writer's group commit (Task 20; storage §7): 8 concurrent writers x 500 writes through `Writer`, with
//! `synchronous=FULL`, once with the writer's `secure_delete=ON` and once with it off, so the cost of zeroing deleted
//! cells is a recorded number. Each write replaces one of 100 rows per writer (a delete and an insert), so there are
//! freed cells to zero. Ignored in normal runs; run it under the perf lock:
//! `cargo test -p urdr --bench group_commit --release -- --ignored --nocapture`.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use rusqlite::params;
use urdr::graph::schema::GRAPH_DDL;
use urdr::graph::writer::{OpenOutcome, OpenRule, Writer, WriterOpts};
use urdr::graph::{Class, Tx, TxMeta};

const WRITERS: usize = 8;
const WRITES: usize = 500;

/// Schema 7's graph tables and a table to write to; `secure_delete` as asked (the writer opens with it on).
fn rule(secure_delete: bool) -> OpenRule {
    Arc::new(move |c: &mut rusqlite::Connection, _: &Path| {
        c.execute_batch(GRAPH_DDL).unwrap();
        c.execute_batch("create table if not exists pad (k integer primary key, v blob not null)")
            .unwrap();
        c.pragma_update(
            None,
            "secure_delete",
            if secure_delete { "ON" } else { "OFF" },
        )
        .unwrap();
        OpenOutcome::Ready { schema: 7 }
    })
}

async fn round(secure_delete: bool) {
    let dir = tempfile::tempdir().unwrap();
    let (writer, handle) = Writer::spawn(
        dir.path().join("work.db"),
        WriterOpts::default(),
        rule(secure_delete),
    )
    .unwrap();
    let start = Instant::now();
    let mut jobs = Vec::new();
    for w in 0..WRITERS {
        let h = handle.clone();
        jobs.push(tokio::spawn(async move {
            for i in 0..WRITES {
                let key = (w * 100 + i % 100) as i64;
                h.write(
                    TxMeta::new(format!("agent:s{w}"), Class::Agent, "mcp:bench"),
                    move |tx: &mut Tx<'_>| {
                        tx.sql().execute(
                            "insert or replace into pad (k, v) values (?1, zeroblob(400))",
                            params![key],
                        )?;
                        Ok(())
                    },
                )
                .await
                .unwrap();
            }
        }));
    }
    for j in jobs {
        j.await.unwrap();
    }
    let took = start.elapsed().as_secs_f64();
    let status = handle.status();
    println!(
        "secure_delete {}: {} writes in {took:.3} s = {:.0} writes/s; {} commits (one fsync each) = {:.0} fsyncs/s; {:.1} writes per commit",
        if secure_delete { "ON " } else { "OFF" },
        status.writes,
        status.writes as f64 / took,
        status.batches,
        status.batches as f64 / took,
        status.writes as f64 / status.batches as f64,
    );
    tokio::task::spawn_blocking(move || writer.shutdown())
        .await
        .unwrap();
}

#[tokio::test]
#[ignore]
async fn group_commit_with_and_without_secure_delete() {
    round(true).await;
    round(false).await;
    round(true).await;
    round(false).await;
}
