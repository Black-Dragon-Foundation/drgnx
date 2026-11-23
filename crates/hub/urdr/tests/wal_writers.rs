//! Several connections write one WAL database while another checkpoints it (work.db has the hub's writer, the
//! coordination writer and the tracker): nothing is lost and the file passes `integrity_check`.

use std::sync::{Arc, Barrier};
use std::time::Duration;

use rusqlite::Connection;

const WRITERS: usize = 4;
const ROWS: usize = 300;

fn open(path: &std::path::Path) -> Connection {
    let c = Connection::open(path).unwrap();
    c.busy_timeout(Duration::from_secs(30)).unwrap();
    c.pragma_update(None, "journal_mode", "wal").unwrap();
    c.pragma_update(None, "synchronous", "NORMAL").unwrap();
    c
}

#[test]
fn several_writers_and_a_checkpointer_keep_the_wal_whole() {
    assert!(
        urdr::wal_reset_fixed(urdr::sqlite_version_number()),
        "the linked SQLite {} is in the WAL-reset bug range",
        urdr::sqlite_version_number()
    );
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("work.db");
    open(&path)
        .execute_batch("create table t(w integer, i integer, pad text)")
        .unwrap();
    let go = Arc::new(Barrier::new(WRITERS + 1));
    let mut all = Vec::new();
    for w in 0..WRITERS {
        let (path, go) = (path.clone(), go.clone());
        all.push(
            saman::spawn_thread("urdr-test-writer", move || {
                let c = open(&path);
                go.wait();
                for i in 0..ROWS {
                    c.execute(
                        "insert into t values (?1, ?2, ?3)",
                        (w as i64, i as i64, "x".repeat(2000)),
                    )
                    .unwrap();
                }
            })
            .unwrap(),
        );
    }
    let checkpointer = {
        let (path, go) = (path.clone(), go.clone());
        saman::spawn_thread("urdr-test-checkpointer", move || {
            let c = open(&path);
            go.wait();
            for _ in 0..60 {
                // BUSY while a writer holds the WAL is the point of the test: the checkpoint is tried again
                if let Err(e) = c.query_row("pragma wal_checkpoint(restart)", [], |_| Ok(())) {
                    assert!(
                        urdr::is_busy(&urdr::Error::Sqlite(e)),
                        "a checkpoint failed for another reason"
                    );
                }
                std::thread::yield_now();
            }
        })
        .unwrap()
    };
    for t in all {
        t.join().unwrap();
    }
    checkpointer.join().unwrap();
    let c = open(&path);
    let n: i64 = c
        .query_row("select count(*) from t", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, (WRITERS * ROWS) as i64);
    let ok: String = c
        .query_row("pragma integrity_check", [], |r| r.get(0))
        .unwrap();
    assert_eq!(ok, "ok");
}
