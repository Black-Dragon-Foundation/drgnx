//! `create_new`: a file born with exactly its mode, never over a name that is taken, never through a link.

use std::os::unix::fs::{MetadataExt, symlink};

use eitri::{FsError, create_new};

#[test]
fn a_new_file_has_exactly_its_mode_whatever_the_umask() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    assert!(create_new(&file, 0o666).unwrap());
    let meta = std::fs::metadata(&file).unwrap();
    assert_eq!(meta.mode() & 0o777, 0o666);
    assert_eq!(meta.len(), 0);
}

#[test]
fn a_name_that_is_taken_is_left_as_it_is() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    eitri::replace_file(&file, b"mine").unwrap();
    assert!(!create_new(&file, 0o600).unwrap());
    assert_eq!(eitri::read_string(&file, 64).unwrap(), "mine");
    // a link at the name is taken too: it is not followed and not replaced
    let link = dir.path().join("link");
    symlink(&file, &link).unwrap();
    assert!(!create_new(&link, 0o600).unwrap());
    assert!(std::fs::symlink_metadata(&link).unwrap().is_symlink());
}

#[test]
fn a_link_in_the_parent_is_refused_and_a_wide_mode_too() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir(&real).unwrap();
    symlink(&real, dir.path().join("via")).unwrap();
    let e = create_new(&dir.path().join("via").join("f"), 0o600).unwrap_err();
    assert!(matches!(e, FsError::Link { .. }), "{e}");
    assert!(!real.join("f").exists());
    let e = create_new(&real.join("f"), 0o1777).unwrap_err();
    assert!(matches!(e, FsError::Io(_)), "{e}");
    assert!(!real.join("f").exists());
}
