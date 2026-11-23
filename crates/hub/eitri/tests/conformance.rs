//! The files standard (docs/develop/standards/files.md): a file is replaced by a temporary file and a rename through
//! its parent's descriptor, never through a link, and a failed replace leaves the old file whole.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::Path;

use eitri::{FsError, replace_file};

fn temps(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(".eitri-"))
        .collect()
}

/// A link planted where the file is is replaced, never followed; a link in a parent component is refused.
#[test]
fn replace_file_never_follows_planted_link() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let canary = outside.path().join("canary");
    fs::write(&canary, b"keep").unwrap();
    let at = root.path().join("state.json");
    symlink(&canary, &at).unwrap();

    replace_file(&at, b"new").unwrap();
    assert!(fs::symlink_metadata(&at).unwrap().file_type().is_file());
    assert_eq!(fs::read(&at).unwrap(), b"new");
    assert_eq!(fs::read(&canary).unwrap(), b"keep");

    symlink(outside.path(), root.path().join("ldir")).unwrap();
    let r = replace_file(&root.path().join("ldir/canary"), b"over");
    assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
    assert_eq!(fs::read(&canary).unwrap(), b"keep");
    assert!(temps(root.path()).is_empty() && temps(outside.path()).is_empty());
}

/// A full disk, as RLIMIT_FSIZE gives it (EFBIG past the limit, SIGXFSZ ignored): the replace fails, the old file is
/// whole and keeps its mode, and no temporary file is left. Its own test binary is one process per test (nextest), so
/// the limit reaches no other test.
#[test]
fn replace_file_keeps_old_on_failure() {
    let root = tempfile::tempdir().unwrap();
    let at = root.path().join("ledger.md");
    fs::write(&at, b"old ledger").unwrap();
    fs::set_permissions(&at, fs::Permissions::from_mode(0o640)).unwrap();

    let mut old = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: plain syscalls on this process's own signal disposition and limits
    unsafe {
        libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
        assert_eq!(libc::getrlimit(libc::RLIMIT_FSIZE, &mut old), 0);
        let small = libc::rlimit {
            rlim_cur: 4096,
            rlim_max: old.rlim_max,
        };
        assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &small), 0);
    }
    let r = replace_file(&at, &vec![b'n'; 64 * 1024]);
    // SAFETY: as above
    unsafe { assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &old), 0) };

    assert!(r.is_err(), "a write past the limit succeeded");
    assert_eq!(fs::read(&at).unwrap(), b"old ledger");
    assert_eq!(
        fs::metadata(&at).unwrap().permissions().mode() & 0o777,
        0o640
    );
    assert!(temps(root.path()).is_empty(), "{:?}", temps(root.path()));

    replace_file(&at, b"new ledger").unwrap();
    assert_eq!(fs::read(&at).unwrap(), b"new ledger");
    assert_eq!(
        fs::metadata(&at).unwrap().permissions().mode() & 0o777,
        0o640
    );
}

/// `read_file` and `read_string` read a regular file by its absolute path, refuse a link in any component, a file
/// over the cap and text that is not UTF-8.
#[test]
fn read_file_never_follows_a_link_and_is_bounded() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let secret = outside.path().join("secret");
    fs::write(&secret, b"hidden").unwrap();
    let at = root.path().join("a.txt");
    fs::write(&at, "héllo").unwrap();

    assert_eq!(eitri::read_string(&at, 100).unwrap(), "héllo");
    assert_eq!(eitri::read_file(&at, 100).unwrap(), "héllo".as_bytes());
    assert!(matches!(
        eitri::read_file(&at, 2),
        Err(FsError::TooLarge { cap: 2 })
    ));

    symlink(&secret, root.path().join("link")).unwrap();
    assert!(eitri::read_file(&root.path().join("link"), 100).is_err());
    symlink(outside.path(), root.path().join("ldir")).unwrap();
    let r = eitri::read_file(&root.path().join("ldir/secret"), 100);
    assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");

    let bad = root.path().join("bad");
    fs::write(&bad, [0xff, 0xfe]).unwrap();
    assert!(matches!(eitri::read_string(&bad, 100), Err(FsError::Io(_))));
}
