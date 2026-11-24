//! `open_lock`: the file a lock is taken on: made when absent, never truncated, never through a link.

use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, symlink};

use eitri::{FsError, open_lock};

#[test]
fn an_absent_file_is_made_with_its_mode_and_an_existing_one_is_not_truncated() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("x.lock");
    let mut f = open_lock(&file, 0o600).unwrap();
    assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
    f.write_all(b"4242").unwrap();
    drop(f);
    let mut again = open_lock(&file, 0o600).unwrap();
    let mut text = String::new();
    again.read_to_string(&mut text).unwrap();
    assert_eq!(text, "4242");
}

#[test]
fn the_lock_can_be_taken_and_a_second_taker_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("x.lock");
    let a = open_lock(&file, 0o600).unwrap();
    a.try_lock().unwrap();
    let b = open_lock(&file, 0o600).unwrap();
    assert!(matches!(
        b.try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
}

#[test]
fn a_link_a_link_in_the_parent_and_a_directory_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let target = real.join("t");
    eitri::replace_file(&target, b"mine").unwrap();
    let link = real.join("l");
    symlink(&target, &link).unwrap();
    let e = open_lock(&link, 0o600).unwrap_err();
    assert!(matches!(e, FsError::Link { .. }), "{e}");
    symlink(&real, dir.path().join("via")).unwrap();
    let e = open_lock(&dir.path().join("via").join("f"), 0o600).unwrap_err();
    assert!(matches!(e, FsError::Link { .. }), "{e}");
    assert!(open_lock(&real, 0o600).is_err());
    let e = open_lock(&real.join("w"), 0o1777).unwrap_err();
    assert!(matches!(e, FsError::Io(_)), "{e}");
}

#[test]
fn a_file_that_is_not_regular_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let pipe = dir.path().join("pipe");
    let name = std::ffi::CString::new(pipe.to_str().unwrap()).unwrap();
    // SAFETY: NAME is a valid C string for the call.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let e = open_lock(&pipe, 0o600).unwrap_err();
    assert!(matches!(e, FsError::NotRegular), "{e}");
}
