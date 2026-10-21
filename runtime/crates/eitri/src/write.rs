//! Writes by a temporary file, `fsync` and `renameat`; a link at the target is replaced, never followed (Task 1).

use std::collections::hash_map::RandomState;
use std::ffi::OsStr;
use std::hash::{BuildHasher, Hasher};
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{
    AtFlags, FileType, Mode, OFlags, RawMode, fsync, openat, renameat, statat, unlinkat,
};
use rustix::io::Errno;

use crate::open::{checked_rel, invalid};
use crate::{FsError, Kind, open_beneath};

/// Writes `bytes` to `rel` beneath `dir` through a temporary file and a rename.
///
/// The parent is opened with `open_beneath` (a link in it is refused); `.eitri-<16 hex>` is created in it with
/// `O_CREAT | O_EXCL | O_NOFOLLOW` and `mode` (less the umask), written, `fsync`ed and `renameat`ed over `rel`. An
/// existing `rel` that is neither absent, a link nor a regular file is `NotRegular`; a link at `rel` is replaced,
/// never followed. The temporary file is removed on every error. `mode` above 0o777 is refused.
pub fn write_regular(
    dir: BorrowedFd<'_>,
    rel: &Path,
    bytes: &[u8],
    mode: u32,
) -> Result<(), FsError> {
    checked_rel(rel)?;
    if mode & !0o777 != 0 {
        return Err(invalid("a mode beyond 0o777"));
    }
    // The last segment of the bytes as given (Path::components would drop a trailing `.` or `/`).
    let raw = rel.as_os_str().as_bytes();
    let last = raw.rsplit(|b| *b == b'/').next().unwrap_or_default();
    if last.is_empty() || last == b"." {
        return Err(invalid("the path names no file"));
    }
    let name = OsStr::from_bytes(last);
    let parent = match &raw[..raw.len() - last.len()] {
        [] => Path::new("."),
        p => Path::new(OsStr::from_bytes(p)),
    };
    let parent = open_beneath(dir, parent, Kind::Dir)?;
    let parent = parent.fd.as_fd();
    let (tmp, file) = create_temp(parent, mode)?;
    let done = write_all(&file, bytes)
        .and_then(|()| fsync(&file).map_err(FsError::from))
        .and_then(|()| replaceable(parent, name))
        .and_then(|()| renameat(parent, &tmp, parent, name).map_err(FsError::from));
    if done.is_err() {
        let _ = unlinkat(parent, &tmp, AtFlags::empty());
    }
    done
}

/// `.eitri-<16 hex>`, made with `O_EXCL` (a name that exists, a link included, is never opened: another is tried).
fn create_temp(parent: BorrowedFd<'_>, mode: u32) -> Result<(String, OwnedFd), FsError> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let flags = OFlags::WRONLY
        | OFlags::CREATE
        | OFlags::EXCL
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY;
    for _ in 0..16 {
        let mut h = RandomState::new().build_hasher();
        h.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
        h.write_u32(std::process::id());
        let name = format!(".eitri-{:016x}", h.finish());
        match openat(parent, &name, flags, Mode::from_raw_mode(mode as RawMode)) {
            Ok(fd) => return Ok((name, fd)),
            Err(Errno::EXIST) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    Err(FsError::Io(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "no free temporary name",
    )))
}

fn write_all(fd: &OwnedFd, mut bytes: &[u8]) -> Result<(), FsError> {
    while !bytes.is_empty() {
        match rustix::io::write(fd, bytes) {
            Ok(0) => return Err(FsError::Io(io::ErrorKind::WriteZero.into())),
            Ok(n) => bytes = &bytes[n..],
            Err(Errno::INTR) => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// What is at `name` now may be replaced: nothing, a link (replaced, not followed) or a regular file.
fn replaceable(parent: BorrowedFd<'_>, name: &OsStr) -> Result<(), FsError> {
    match statat(parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(st) => match FileType::from_raw_mode(st.st_mode) {
            FileType::RegularFile | FileType::Symlink => Ok(()),
            _ => Err(FsError::NotRegular),
        },
        Err(Errno::NOENT) => Ok(()),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::fd::{AsFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{FileTypeExt, PermissionsExt, symlink};

    fn root() -> (tempfile::TempDir, OwnedFd) {
        let root = tempfile::tempdir().unwrap();
        let fd = fs::File::open(root.path()).unwrap().into();
        (root, fd)
    }

    /// The names in `dir` that look like eitri's temporary files.
    fn temps(dir: &Path) -> Vec<String> {
        fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(".eitri-"))
            .collect()
    }

    #[test]
    fn writes_create_and_replace_a_regular_file() {
        let (root, fd) = root();
        fs::create_dir(root.path().join("d")).unwrap();
        write_regular(fd.as_fd(), Path::new("d/f"), b"one", 0o600).unwrap();
        assert_eq!(fs::read(root.path().join("d/f")).unwrap(), b"one");
        let mode = fs::metadata(root.path().join("d/f"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        write_regular(fd.as_fd(), Path::new("d/f"), b"two!", 0o600).unwrap();
        assert_eq!(fs::read(root.path().join("d/f")).unwrap(), b"two!");
        write_regular(fd.as_fd(), Path::new("top"), b"", 0o644).unwrap();
        assert_eq!(fs::read(root.path().join("top")).unwrap(), b"");
        assert!(temps(root.path()).is_empty() && temps(&root.path().join("d")).is_empty());
    }

    #[test]
    fn write_replaces_a_link_without_following_it() {
        let (root, fd) = root();
        let outside = tempfile::tempdir().unwrap();
        let canary = outside.path().join("canary");
        let text = format!("canary-{}", std::process::id());
        fs::write(&canary, &text).unwrap();
        symlink(&canary, root.path().join("rel")).unwrap();
        symlink(outside.path(), root.path().join("ldir")).unwrap();

        write_regular(fd.as_fd(), Path::new("rel"), b"bytes", 0o644).unwrap();
        let m = fs::symlink_metadata(root.path().join("rel")).unwrap();
        assert!(m.file_type().is_file(), "{m:?}");
        assert_eq!(fs::read(root.path().join("rel")).unwrap(), b"bytes");
        assert_eq!(fs::read_to_string(&canary).unwrap(), text);

        // A link in the parent is refused, and nothing is made behind it.
        let r = write_regular(fd.as_fd(), Path::new("ldir/new"), b"bytes", 0o644);
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert!(!outside.path().join("new").exists());
        assert!(temps(outside.path()).is_empty() && temps(root.path()).is_empty());
    }

    #[test]
    fn a_target_that_is_not_regular_is_refused() {
        let (root, fd) = root();
        fs::create_dir(root.path().join("d")).unwrap();
        let r = write_regular(fd.as_fd(), Path::new("d"), b"x", 0o644);
        assert!(matches!(r, Err(FsError::NotRegular)), "{r:?}");
        let c = std::ffi::CString::new(root.path().join("p").as_os_str().as_bytes()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let r = write_regular(fd.as_fd(), Path::new("p"), b"x", 0o644);
        assert!(matches!(r, Err(FsError::NotRegular)), "{r:?}");
        assert!(
            fs::symlink_metadata(root.path().join("p"))
                .unwrap()
                .file_type()
                .is_fifo()
        );
        assert!(
            fs::symlink_metadata(root.path().join("d"))
                .unwrap()
                .is_dir()
        );
    }

    #[test]
    fn write_leaves_no_temp_on_error() {
        let (root, fd) = root();
        // A target that is a directory: the write fails after the temporary file exists.
        fs::create_dir(root.path().join("d")).unwrap();
        fs::write(root.path().join("d/keep"), b"k").unwrap();
        assert!(write_regular(fd.as_fd(), Path::new("d"), b"x", 0o644).is_err());
        assert!(temps(root.path()).is_empty(), "{:?}", temps(root.path()));

        // A read-only parent: uid 0 writes through it (CAP_DAC_OVERRIDE), so only as another user.
        if rustix::process::geteuid().is_root() {
            eprintln!(
                "write_leaves_no_temp_on_error: the read-only parent needs a uid other than 0; skipped"
            );
        } else {
            let ro = root.path().join("ro");
            fs::create_dir(&ro).unwrap();
            fs::set_permissions(&ro, fs::Permissions::from_mode(0o555)).unwrap();
            let r = write_regular(fd.as_fd(), Path::new("ro/f"), b"x", 0o644);
            fs::set_permissions(&ro, fs::Permissions::from_mode(0o755)).unwrap();
            assert!(matches!(r, Err(FsError::Io(_))), "{r:?}");
            assert!(fs::read_dir(&ro).unwrap().next().is_none());
        }
    }

    #[test]
    fn a_mode_beyond_0o777_or_a_name_that_is_no_file_is_refused() {
        let (root, fd) = root();
        for mode in [0o4755, 0o2755, 0o1777] {
            let r = write_regular(fd.as_fd(), Path::new("f"), b"x", mode);
            assert!(matches!(r, Err(FsError::Io(_))), "{mode:o}: {r:?}");
        }
        for rel in ["", "."] {
            let r = write_regular(fd.as_fd(), Path::new(rel), b"x", 0o644);
            assert!(matches!(r, Err(FsError::Io(_))), "{rel:?}: {r:?}");
        }
        assert!(fs::read_dir(root.path()).unwrap().next().is_none());
    }
}
