//! Read-only connections: they never write, and closing last never checkpoints.

use rusqlite::Connection;
use std::fs;
use urdr::open_readonly;

#[test]
fn a_read_only_connection_closing_last_never_checkpoints() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    let wal = dir.path().join("work.db-wal");
    let writer = Connection::open(&file).unwrap();
    writer.pragma_update(None, "journal_mode", "wal").unwrap();
    writer.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    writer
        .execute_batch("create table t(x); insert into t values (1);")
        .unwrap();
    let main = fs::read(&file).unwrap();

    let reader = open_readonly(&file).unwrap();
    let n: i64 = reader
        .query_row("select x from t", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 1);
    drop(writer); // the writer closes first: the reader still has the file open
    assert_eq!(fs::read(&file).unwrap(), main);
    assert!(fs::metadata(&wal).unwrap().len() > 0);
    drop(reader); // the reader closes last
    assert_eq!(fs::read(&file).unwrap(), main);
    assert!(fs::metadata(&wal).unwrap().len() > 0);
}

#[test]
fn writes_on_a_read_only_connection_fail() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("a.db");
    let w = Connection::open(&file).unwrap();
    w.execute_batch("create table t(x)").unwrap();
    drop(w);
    let r = open_readonly(&file).unwrap();
    assert!(r.execute("insert into t values (1)", []).is_err());
}
