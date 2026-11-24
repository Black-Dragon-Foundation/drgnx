//! `write_in_place` (a control file written where it stands) and `rename_socket` (a bound socket's path moved).

use std::os::unix::fs::{MetadataExt, symlink};
use std::os::unix::net::UnixListener;

use std::io::Write;

use eitri::{FsError, open_append, rename_file, rename_socket, replace_via, write_in_place};

#[test]
fn a_write_in_place_keeps_the_file_and_never_makes_one() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("cpuset.cpus");
    std::fs::write(&file, "longer old content\n").unwrap();
    let before = std::fs::metadata(&file).unwrap().ino();
    write_in_place(&file, b"0-3\n").unwrap();
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "0-3\n");
    assert_eq!(
        std::fs::metadata(&file).unwrap().ino(),
        before,
        "the same file, not a replacement"
    );
    let e = write_in_place(&dir.path().join("absent"), b"x").unwrap_err();
    assert!(
        matches!(&e, FsError::Io(io) if io.kind() == std::io::ErrorKind::NotFound),
        "{e:?}"
    );
    assert!(!dir.path().join("absent").exists(), "never created");
}

#[test]
fn a_write_in_place_refuses_a_link_and_what_is_not_a_regular_file() {
    let dir = tempfile::tempdir().unwrap();
    let (target, link) = (dir.path().join("target"), dir.path().join("link"));
    std::fs::File::create(&target).unwrap();
    symlink(&target, &link).unwrap();
    assert!(matches!(
        write_in_place(&link, b"x"),
        Err(FsError::Link { .. })
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "");
    let sub = dir.path().join("dir");
    std::fs::create_dir(&sub).unwrap();
    assert!(write_in_place(&sub, b"x").is_err());
}

#[test]
fn a_socket_is_renamed_by_rename_socket_and_not_by_rename_file() {
    let dir = tempfile::tempdir().unwrap();
    let (from, to) = (dir.path().join("a.sock"), dir.path().join("b.sock"));
    let _bound = UnixListener::bind(&from).unwrap();
    assert!(
        matches!(rename_file(&from, &to), Err(FsError::NotRegular)),
        "a socket is not a regular file"
    );
    rename_socket(&from, &to).unwrap();
    assert!(!from.exists() && to.exists());
    let plain = dir.path().join("plain");
    std::fs::File::create(&plain).unwrap();
    assert!(matches!(
        rename_socket(&plain, &from),
        Err(FsError::NotRegular)
    ));
    let (target, link) = (dir.path().join("t.sock"), dir.path().join("l.sock"));
    let _other = UnixListener::bind(&target).unwrap();
    symlink(&target, &link).unwrap();
    assert!(matches!(
        rename_socket(&link, &from),
        Err(FsError::Link { .. })
    ));
}

#[test]
fn an_append_adds_to_the_end_makes_the_file_only_when_asked_and_refuses_a_link() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("log");
    let e = open_append(&log, None).unwrap_err();
    assert!(
        matches!(&e, FsError::Io(io) if io.kind() == std::io::ErrorKind::NotFound),
        "{e:?}"
    );
    open_append(&log, Some(0o600))
        .unwrap()
        .write_all(b"one\n")
        .unwrap();
    open_append(&log, None)
        .unwrap()
        .write_all(b"two\n")
        .unwrap();
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "one\ntwo\n");
    assert_eq!(std::fs::metadata(&log).unwrap().mode() & 0o777, 0o600);
    let link = dir.path().join("link");
    symlink(&log, &link).unwrap();
    assert!(matches!(
        open_append(&link, None),
        Err(FsError::Link { .. })
    ));
    assert!(open_append(&dir.path().join("big"), Some(0o1777)).is_err());
}

#[test]
fn replace_via_writes_the_named_temporary_and_renames_it_over_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let (dest, tmp) = (
        dir.path().join("a.json"),
        dir.path().join("a.json.drgnx-tmp"),
    );
    std::fs::write(&dest, "old").unwrap();
    replace_via(&tmp, &dest, b"new").unwrap();
    assert_eq!(std::fs::read_to_string(&dest).unwrap(), "new");
    assert!(!tmp.exists(), "the temporary was renamed away");
    // a link at the temporary's name is refused, and nothing is written through it
    let target = dir.path().join("target");
    std::fs::write(&target, "kept").unwrap();
    symlink(&target, &tmp).unwrap();
    assert!(matches!(
        replace_via(&tmp, &dest, b"x"),
        Err(FsError::Link { .. })
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "kept");
}
