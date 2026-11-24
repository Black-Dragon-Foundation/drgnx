//! `replace_file_mode`, `create_exclusive`, `open_read` and `open_following`: the opens the hub's callers need beyond
//! the first set (a private file, a streamed new file, a file read with its checks on the open one).

use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, symlink};

use eitri::{FsError, create_exclusive, open_following, open_read, replace_file_mode};

#[test]
fn a_private_file_is_replaced_with_its_mode_even_over_a_wider_one() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("token");
    std::fs::write(&file, b"old").unwrap();
    std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o644)).unwrap();
    replace_file_mode(&file, b"new", 0o600).unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), b"new");
    assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
    assert!(replace_file_mode(&file, b"x", 0o1777).is_err());
}

#[test]
fn an_exclusive_file_is_made_once_with_its_mode_and_a_name_taken_is_not_touched() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("out");
    let mut f = create_exclusive(&file, 0o600).unwrap();
    f.write_all(b"streamed").unwrap();
    drop(f);
    assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
    match create_exclusive(&file, 0o600).unwrap_err() {
        FsError::Io(e) => assert_eq!(e.kind(), std::io::ErrorKind::AlreadyExists),
        other => panic!("{other}"),
    }
    assert_eq!(std::fs::read(&file).unwrap(), b"streamed");
    // a link is a name taken: its target is not made nor written
    let target = dir.path().join("target");
    let link = dir.path().join("link");
    symlink(&target, &link).unwrap();
    assert!(create_exclusive(&link, 0o600).is_err());
    assert!(!target.exists());
}

#[test]
fn a_regular_file_is_read_and_a_link_a_parent_link_and_a_fifo_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let file = real.join("f");
    std::fs::write(&file, b"text").unwrap();
    let mut text = String::new();
    open_read(&file).unwrap().read_to_string(&mut text).unwrap();
    assert_eq!(text, "text");
    let link = real.join("l");
    symlink(&file, &link).unwrap();
    assert!(matches!(
        open_read(&link).unwrap_err(),
        FsError::Link { .. }
    ));
    symlink(&real, dir.path().join("via")).unwrap();
    assert!(matches!(
        open_read(&dir.path().join("via").join("f")).unwrap_err(),
        FsError::Link { .. }
    ));
    let pipe = dir.path().join("pipe");
    let name = std::ffi::CString::new(pipe.to_str().unwrap()).unwrap();
    // SAFETY: NAME is a valid C string for the call.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(matches!(open_read(&pipe).unwrap_err(), FsError::NotRegular));
    match open_read(&real.join("absent")).unwrap_err() {
        FsError::Io(e) => assert_eq!(e.kind(), std::io::ErrorKind::NotFound),
        other => panic!("{other}"),
    }
}

#[test]
fn a_file_the_user_linked_is_followed_and_a_fifo_is_opened_without_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("f");
    std::fs::write(&file, b"kept elsewhere").unwrap();
    let link = dir.path().join("l");
    symlink(&file, &link).unwrap();
    let mut text = String::new();
    open_following(&link)
        .unwrap()
        .read_to_string(&mut text)
        .unwrap();
    assert_eq!(text, "kept elsewhere");
    let pipe = dir.path().join("pipe");
    let name = std::ffi::CString::new(pipe.to_str().unwrap()).unwrap();
    // SAFETY: NAME is a valid C string for the call.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let open = open_following(&pipe).unwrap();
    assert!(!open.metadata().unwrap().is_file());
    match open_following(&dir.path().join("absent")).unwrap_err() {
        FsError::Io(e) => assert_eq!(e.kind(), std::io::ErrorKind::NotFound),
        other => panic!("{other}"),
    }
}
