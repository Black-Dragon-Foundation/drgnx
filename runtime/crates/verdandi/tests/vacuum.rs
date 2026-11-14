//! A checked copy of history.db for the nightly backup.  Pattern D (pure: a temporary folder, no process, no clock).

use std::os::unix::fs::PermissionsExt;
use verdandi::{History, vacuum_file};

fn integrity(db: &std::path::Path) -> String {
    rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap()
        .query_row("pragma integrity_check", [], |r| r.get(0))
        .unwrap()
}

#[test]
fn vacuum_into_makes_a_checked_private_copy_and_replaces_the_old_one() {
    let d = tempfile::tempdir().unwrap();
    let h = History::open(&d.path().join("p")).unwrap();
    let dest = d.path().join("backup/history-p.db");
    let bytes = h.vacuum_into(&dest).unwrap();
    assert!(bytes > 0);
    assert_eq!(std::fs::metadata(&dest).unwrap().len(), bytes);
    assert_eq!(
        std::fs::metadata(&dest).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(integrity(&dest), "ok");
    // a second night replaces it: one file, no temporary copy left beside it
    h.vacuum_into(&dest).unwrap();
    let names: Vec<_> = std::fs::read_dir(d.path().join("backup"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["history-p.db"]);
}

#[test]
fn vacuum_file_copies_a_store_nobody_has_open() {
    let d = tempfile::tempdir().unwrap();
    drop(History::open(&d.path().join("p")).unwrap());
    let dest = d.path().join("copy.db");
    assert!(vacuum_file(&d.path().join("p/history.db"), &dest).unwrap() > 0);
    assert_eq!(integrity(&dest), "ok");
}

#[test]
fn a_copy_that_cannot_land_leaves_nothing_and_the_old_copy_stands() {
    let d = tempfile::tempdir().unwrap();
    let h = History::open(&d.path().join("p")).unwrap();
    let dest = d.path().join("history-p.db");
    h.vacuum_into(&dest).unwrap();
    let before = std::fs::read(&dest).unwrap();
    // the destination's place is taken by a folder: the rename fails
    let blocked = d.path().join("blocked.db");
    std::fs::create_dir_all(blocked.join("inner")).unwrap();
    assert!(h.vacuum_into(&blocked).is_err());
    assert!(!d.path().join("blocked.db.tmp").exists());
    assert_eq!(std::fs::read(&dest).unwrap(), before);
}
