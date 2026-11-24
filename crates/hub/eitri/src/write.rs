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
use crate::{FsError, Kind, open_beneath, open_path};

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
        if let Err(e) = unlinkat(parent, &tmp, AtFlags::empty()) {
            tracing::debug!(error = %e, "a temporary file was not removed");
        }
        return done;
    }
    sync_dir(parent)
}

/// `fsync` of the directory itself, so a crash cannot lose the rename (GL-T1-3). The held parent may be an `O_PATH`
/// fd, which cannot `fsync`: the directory is opened again through it. A filesystem with no directory sync
/// (`EINVAL`, `ENOTSUP`) is fine.
fn sync_dir(parent: BorrowedFd<'_>) -> Result<(), FsError> {
    #[cfg(test)]
    tests::DIR_SYNCS.with(|c| c.set(c.get() + 1));
    let dir = openat(
        parent,
        ".",
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    match fsync(&dir) {
        Ok(()) | Err(Errno::INVAL | Errno::NOTSUP) => Ok(()),
        Err(e) => Err(e.into()),
    }
}

/// The parent of `rel`, opened beneath `dir` with `open_beneath` (a link in it is refused), and `rel`'s last name.
fn parent_of<'r>(
    dir: BorrowedFd<'_>,
    rel: &'r Path,
) -> Result<(crate::Pinned, &'r OsStr), FsError> {
    checked_rel(rel)?;
    let raw = rel.as_os_str().as_bytes();
    let last = raw.rsplit(|b| *b == b'/').next().unwrap_or_default();
    if last.is_empty() || last == b"." {
        return Err(invalid("the path names no file"));
    }
    let parent = match &raw[..raw.len() - last.len()] {
        [] => Path::new("."),
        p => Path::new(OsStr::from_bytes(p)),
    };
    Ok((
        open_beneath(dir, parent, Kind::Dir)?,
        OsStr::from_bytes(last),
    ))
}

/// Removes the leaf `rel` beneath `dir`: every component before it through `open_beneath` (a link there is refused),
/// the leaf unlinked at the parent's held fd, so a leaf that is a link is removed as a link and what it names is never
/// touched.  A leaf that is gone already is done; a directory is `NotRegular`.
pub fn remove_beneath(dir: BorrowedFd<'_>, rel: &Path) -> Result<(), FsError> {
    let (parent, name) = parent_of(dir, rel)?;
    match unlinkat(parent.fd.as_fd(), name, AtFlags::empty()) {
        Ok(()) | Err(Errno::NOENT) => Ok(()),
        Err(Errno::ISDIR) => Err(FsError::NotRegular),
        Err(e) => Err(e.into()),
    }
}

/// Makes `rel` beneath `dir` a link holding the bytes `target`, never resolved: the parent through `open_beneath` (a
/// link in it is refused), the link made at a temporary name with `symlinkat` at the parent's held fd, then
/// `renameat`ed over `rel`.  An old leaf that is a link or a regular file is replaced, never followed; anything else is
/// `NotRegular`.  An empty target, or one with a NUL byte, is refused.
pub fn symlink_beneath(dir: BorrowedFd<'_>, rel: &Path, target: &[u8]) -> Result<(), FsError> {
    if target.is_empty() || target.contains(&0) {
        return Err(invalid("a link target that is empty or holds a NUL byte"));
    }
    let (parent, name) = parent_of(dir, rel)?;
    let parent = parent.fd.as_fd();
    let mut made = None;
    for _ in 0..16 {
        let tmp = temp_name();
        match rustix::fs::symlinkat(OsStr::from_bytes(target), parent, tmp.as_str()) {
            Ok(()) => {
                made = Some(tmp);
                break;
            }
            Err(Errno::EXIST) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    let tmp = made.ok_or_else(|| {
        FsError::Io(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "no free temporary name",
        ))
    })?;
    let done = replaceable(parent, name)
        .and_then(|()| renameat(parent, tmp.as_str(), parent, name).map_err(FsError::from));
    if done.is_err()
        && let Err(e) = unlinkat(parent, tmp.as_str(), AtFlags::empty())
    {
        tracing::debug!(error = %e, "a temporary symlink was not removed");
    }
    done
}

/// Replaces the file at the absolute path `abs` with `bytes`: the parent opened with `open_path` (a link in any
/// component is refused), then [`write_regular`] there, so a link at `abs` is replaced and never followed, and a
/// reader sees the old bytes or the new ones, never a part. An existing regular file keeps its permission bits; a new
/// file gets 0o666 less the umask (as `std::fs::write`). On an error the old file is left as it was.
pub fn replace_file(abs: &Path, bytes: &[u8]) -> Result<(), FsError> {
    let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
        return Err(invalid("the path names no file"));
    };
    let parent = open_path(parent, Kind::Dir)?;
    let dir = parent.fd.as_fd();
    let old = statat(dir, name, AtFlags::SYMLINK_NOFOLLOW)
        .ok()
        .filter(|st| FileType::from_raw_mode(st.st_mode) == FileType::RegularFile);
    #[allow(clippy::unnecessary_cast)] // st_mode is u16 on macOS, u32 on Linux and Android
    let mode = old.map_or(0o666, |st| st.st_mode as u32 & 0o777);
    write_regular(dir, Path::new(name), bytes, mode)
}

/// Creates the empty regular file at the absolute path `abs` with exactly `mode` (the umask does not narrow it; the
/// file is born with that mode, never widened first), for a file another program fills (a database). The parent is
/// opened with `open_path` (a link in any component is refused); the file is made with `O_CREAT | O_EXCL | O_NOFOLLOW`.
/// `Ok(true)` when it was made, `Ok(false)` when the name was taken already (whatever it is: it is not touched).
/// `mode` above 0o777 is refused.
pub fn create_new(abs: &Path, mode: u32) -> Result<bool, FsError> {
    if mode & !0o777 != 0 {
        return Err(invalid("a mode beyond 0o777"));
    }
    let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
        return Err(invalid("the path names no file"));
    };
    let parent = open_path(parent, Kind::Dir)?;
    let dir = parent.fd.as_fd();
    let flags = OFlags::WRONLY
        | OFlags::CREATE
        | OFlags::EXCL
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY;
    match openat(dir, name, flags, Mode::from_raw_mode(mode as RawMode)) {
        Ok(fd) => {
            // the umask may have narrowed the mode `openat` was given
            rustix::fs::fchmod(&fd, Mode::from_raw_mode(mode as RawMode))?;
            Ok(true)
        }
        Err(Errno::EXIST) => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Opens the regular file at the absolute path `abs` for reading and writing, creating it with `mode` (less the umask)
/// when it is absent, and never truncating it: the file a process holds a lock on (`File::try_lock`). The parent is
/// opened with `open_path` (a link in any component is refused); the open is `O_NOFOLLOW`, so a link at `abs` is
/// `Link`, and anything that is not a regular file is `NotRegular`. `mode` above 0o777 is refused.
pub fn open_lock(abs: &Path, mode: u32) -> Result<std::fs::File, FsError> {
    if mode & !0o777 != 0 {
        return Err(invalid("a mode beyond 0o777"));
    }
    let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
        return Err(invalid("the path names no file"));
    };
    let parent = open_path(parent, Kind::Dir)?;
    let flags = OFlags::RDWR
        | OFlags::CREATE
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY
        | OFlags::NONBLOCK;
    let fd = match openat(
        parent.fd.as_fd(),
        name,
        flags,
        Mode::from_raw_mode(mode as RawMode),
    ) {
        Ok(fd) => fd,
        Err(Errno::LOOP) => {
            return Err(FsError::Link {
                path: abs.to_path_buf(),
            });
        }
        Err(e) => return Err(e.into()),
    };
    let st = rustix::fs::fstat(&fd)?;
    if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
        return Err(FsError::NotRegular);
    }
    Ok(std::fs::File::from(fd))
}

/// Opens the regular file at the absolute path `abs` for appending (a log): made with `create` as its mode (less the
/// umask) when it is absent, and left as it is when it is not; never truncated. The parent is opened with `open_path`
/// (a link in any component is refused); the open is `O_NOFOLLOW`, so a link at `abs` is `Link`, and anything that is not a
/// regular file is `NotRegular`. With `create` `None` an absent file is an `Io` error of kind `NotFound`; a mode above
/// 0o777 is refused.
pub fn open_append(abs: &Path, create: Option<u32>) -> Result<std::fs::File, FsError> {
    if create.is_some_and(|m| m & !0o777 != 0) {
        return Err(invalid("a mode beyond 0o777"));
    }
    let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
        return Err(invalid("the path names no file"));
    };
    let parent = open_path(parent, Kind::Dir)?;
    let mut flags = OFlags::WRONLY
        | OFlags::APPEND
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY
        | OFlags::NONBLOCK;
    if create.is_some() {
        flags |= OFlags::CREATE;
    }
    let mode = Mode::from_raw_mode(create.unwrap_or(0) as RawMode);
    let fd = match openat(parent.fd.as_fd(), name, flags, mode) {
        Ok(fd) => fd,
        Err(Errno::LOOP) => {
            return Err(FsError::Link {
                path: abs.to_path_buf(),
            });
        }
        Err(e) => return Err(e.into()),
    };
    if FileType::from_raw_mode(rustix::fs::fstat(&fd)?.st_mode) != FileType::RegularFile {
        return Err(FsError::NotRegular);
    }
    Ok(std::fs::File::from(fd))
}

/// Renames the directory `from` to `to` (absolute paths, each parent opened with `open_path`, so a link in either is
/// refused). `from` must be a directory itself: a link (even to a directory) is `Link`, anything else `NotDir`. As
/// `rename(2)`, `to` is replaced when it is an empty directory; both parents are synced.
pub fn rename_dir(from: &Path, to: &Path) -> Result<(), FsError> {
    rename_entry(from, to, FileType::Directory, FsError::NotDir)
}

/// Renames the regular file `from` to `to` (absolute paths, each parent opened with `open_path`, so a link in either
/// is refused), for a file too large to rewrite through [`replace_file`]. `from` must be a regular file itself: a link
/// is `Link`, anything else `NotRegular`. As `rename(2)`, `to` is replaced; both parents are synced.
pub fn rename_file(from: &Path, to: &Path) -> Result<(), FsError> {
    rename_entry(from, to, FileType::RegularFile, FsError::NotRegular)
}

/// Replaces the file at `dest` with `bytes` through the temporary file `tmp` the caller names (its name is part of a
/// protocol: an editor's own save ignores `<file>.drgnx-tmp`, a test holds a pipe there to make the disk slow): `tmp` is
/// opened for writing (made when absent, emptied, a link at it refused; the open waits for what is there, a pipe
/// included), written whole, synced where the file system can, and renamed over `dest`. Both parents are opened with
/// `open_path` (a link in any component is refused) and synced. Where `tmp` stays is a failure's: it is not removed.
pub fn replace_via(tmp: &Path, dest: &Path, bytes: &[u8]) -> Result<(), FsError> {
    let (Some(tmp_parent), Some(tmp_name), Some(dest_parent), Some(dest_name)) = (
        tmp.parent(),
        tmp.file_name(),
        dest.parent(),
        dest.file_name(),
    ) else {
        return Err(invalid("a path names no file"));
    };
    let tmp_dir = open_path(tmp_parent, Kind::Dir)?;
    let dest_dir = open_path(dest_parent, Kind::Dir)?;
    let flags = OFlags::WRONLY
        | OFlags::CREATE
        | OFlags::TRUNC
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY;
    let fd = match openat(
        tmp_dir.fd.as_fd(),
        tmp_name,
        flags,
        Mode::from_raw_mode(0o644),
    ) {
        Ok(fd) => fd,
        Err(Errno::LOOP) => {
            return Err(FsError::Link {
                path: tmp.to_path_buf(),
            });
        }
        Err(e) => return Err(e.into()),
    };
    let mut rest = bytes;
    while !rest.is_empty() {
        match rustix::io::write(&fd, rest) {
            Ok(n) => rest = &rest[n..],
            Err(Errno::INTR) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    // a pipe or a file system with no sync says so with EINVAL: nothing to wait for there
    match fsync(&fd) {
        Ok(()) | Err(Errno::INVAL) => {}
        Err(e) => return Err(e.into()),
    }
    drop(fd);
    renameat(tmp_dir.fd.as_fd(), tmp_name, dest_dir.fd.as_fd(), dest_name)?;
    sync_dir(dest_dir.fd.as_fd())?;
    sync_dir(tmp_dir.fd.as_fd())
}

/// Renames the unix socket `from` to `to` (absolute paths, each parent opened with `open_path`, so a link in either is
/// refused): a bound socket's path moved to the name clients dial. `from` must be a socket itself: a link is `Link`,
/// anything else `NotRegular`. As `rename(2)`, `to` is replaced; both parents are synced.
pub fn rename_socket(from: &Path, to: &Path) -> Result<(), FsError> {
    rename_entry(from, to, FileType::Socket, FsError::NotRegular)
}

/// Writes `bytes` into the existing regular file at the absolute path `abs`, in place: no temporary file and no rename,
/// the file is neither created nor replaced (its inode, and any lock held on it, stay; its old content is emptied first). For a file that is a control (a cgroup's `cpuset.cpus`), where a temporary
/// file cannot be made beside it and one `write(2)` is the whole change. The parent is opened with `open_path` (a link
/// in any component is refused); the open is `O_NOFOLLOW`, so a link at `abs` is `Link`, a file that is not there is
/// an `Io` error of kind `NotFound`, and anything that is not a regular file is `NotRegular`.
pub fn write_in_place(abs: &Path, bytes: &[u8]) -> Result<(), FsError> {
    let (Some(parent), Some(name)) = (abs.parent(), abs.file_name()) else {
        return Err(invalid("the path names no file"));
    };
    let parent = open_path(parent, Kind::Dir)?;
    let flags = OFlags::WRONLY
        | OFlags::TRUNC
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY
        | OFlags::NONBLOCK;
    let fd = match openat(parent.fd.as_fd(), name, flags, Mode::empty()) {
        Ok(fd) => fd,
        Err(Errno::LOOP) => {
            return Err(FsError::Link {
                path: abs.to_path_buf(),
            });
        }
        Err(e) => return Err(e.into()),
    };
    if FileType::from_raw_mode(rustix::fs::fstat(&fd)?.st_mode) != FileType::RegularFile {
        return Err(FsError::NotRegular);
    }
    let mut rest = bytes;
    while !rest.is_empty() {
        match rustix::io::write(&fd, rest) {
            Ok(n) => rest = &rest[n..],
            Err(Errno::INTR) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// `from` renamed to `to` when `from` is itself of type WANT (else a link is `Link` and any other type REFUSED).
fn rename_entry(from: &Path, to: &Path, want: FileType, refused: FsError) -> Result<(), FsError> {
    let (Some(from_parent), Some(from_name), Some(to_parent), Some(to_name)) =
        (from.parent(), from.file_name(), to.parent(), to.file_name())
    else {
        return Err(invalid("a path names nothing to rename"));
    };
    let from_dir = open_path(from_parent, Kind::Dir)?;
    let to_dir = open_path(to_parent, Kind::Dir)?;
    let (from_fd, to_fd) = (from_dir.fd.as_fd(), to_dir.fd.as_fd());
    let st = statat(from_fd, from_name, AtFlags::SYMLINK_NOFOLLOW)?;
    match FileType::from_raw_mode(st.st_mode) {
        t if t == want => {}
        FileType::Symlink => {
            return Err(FsError::Link {
                path: from.to_path_buf(),
            });
        }
        _ => return Err(refused),
    }
    renameat(from_fd, from_name, to_fd, to_name)?;
    sync_dir(to_fd)?;
    sync_dir(from_fd)
}

/// A fresh `.eitri-<16 hex>` name.
fn temp_name() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut h = RandomState::new().build_hasher();
    h.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
    h.write_u32(std::process::id());
    format!(".eitri-{:016x}", h.finish())
}

/// `.eitri-<16 hex>`, made with `O_EXCL` (a name that exists, a link included, is never opened: another is tried).
fn create_temp(parent: BorrowedFd<'_>, mode: u32) -> Result<(String, OwnedFd), FsError> {
    let flags = OFlags::WRONLY
        | OFlags::CREATE
        | OFlags::EXCL
        | OFlags::NOFOLLOW
        | OFlags::CLOEXEC
        | OFlags::NOCTTY;
    for _ in 0..16 {
        let name = temp_name();
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

    thread_local! {
        /// How many times this thread synced a directory after a rename.
        pub(super) static DIR_SYNCS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
    }

    fn root() -> (tempfile::TempDir, OwnedFd) {
        let root = tempfile::tempdir().unwrap();
        let fd = fs::File::open(root.path()).unwrap().into();
        (root, fd)
    }

    #[test]
    fn a_write_syncs_the_parent_directory() {
        let (root, fd) = root();
        fs::create_dir(root.path().join("d")).unwrap();
        let before = DIR_SYNCS.with(std::cell::Cell::get);
        write_regular(fd.as_fd(), Path::new("d/f"), b"one", 0o600).unwrap();
        assert_eq!(DIR_SYNCS.with(std::cell::Cell::get), before + 1);
        // a refused write syncs nothing
        let r = write_regular(fd.as_fd(), Path::new("d"), b"x", 0o600);
        assert!(matches!(r, Err(FsError::NotRegular)), "{r:?}");
        assert_eq!(DIR_SYNCS.with(std::cell::Cell::get), before + 1);
    }

    #[test]
    fn rename_dir_moves_a_directory_with_its_contents() {
        let root = tempfile::tempdir().unwrap();
        let (from, to) = (root.path().join("a"), root.path().join("b"));
        fs::create_dir_all(from.join("sub")).unwrap();
        fs::write(from.join("sub/x"), b"x").unwrap();
        rename_dir(&from, &to).unwrap();
        assert!(!from.exists());
        assert_eq!(fs::read(to.join("sub/x")).unwrap(), b"x");
        // into another folder
        fs::create_dir(root.path().join("other")).unwrap();
        rename_dir(&to, &root.path().join("other/c")).unwrap();
        assert!(root.path().join("other/c/sub/x").is_file());
    }

    #[test]
    fn rename_dir_refuses_what_is_not_a_plain_directory() {
        let root = tempfile::tempdir().unwrap();
        let real = root.path().join("real");
        fs::create_dir(&real).unwrap();
        symlink(&real, root.path().join("l")).unwrap();
        fs::write(root.path().join("file"), b"f").unwrap();
        let r = rename_dir(&root.path().join("l"), &root.path().join("m"));
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert!(
            fs::symlink_metadata(root.path().join("l"))
                .unwrap()
                .is_symlink()
        );
        assert!(!root.path().join("m").exists());
        let r = rename_dir(&root.path().join("file"), &root.path().join("m"));
        assert!(matches!(r, Err(FsError::NotDir)), "{r:?}");
        let r = rename_dir(&root.path().join("absent"), &root.path().join("m"));
        assert!(
            matches!(&r, Err(FsError::Io(e)) if e.kind() == io::ErrorKind::NotFound),
            "{r:?}"
        );
    }

    #[test]
    fn rename_dir_refuses_a_link_in_either_parent() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::create_dir(outside.path().join("a")).unwrap();
        symlink(outside.path(), root.path().join("ldir")).unwrap();
        let r = rename_dir(&root.path().join("ldir/a"), &root.path().join("b"));
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        fs::create_dir(root.path().join("a")).unwrap();
        let r = rename_dir(&root.path().join("a"), &root.path().join("ldir/b"));
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert!(root.path().join("a").is_dir() && !outside.path().join("b").exists());
    }

    #[test]
    fn rename_file_moves_a_regular_file_and_refuses_the_rest() {
        let root = tempfile::tempdir().unwrap();
        let p = root.path();
        fs::write(p.join("part"), b"bytes").unwrap();
        fs::write(p.join("old"), b"old").unwrap();
        rename_file(&p.join("part"), &p.join("old")).unwrap();
        assert!(!p.join("part").exists());
        assert_eq!(
            fs::read(p.join("old")).unwrap(),
            b"bytes",
            "replaces the target"
        );
        fs::create_dir(p.join("d")).unwrap();
        let r = rename_file(&p.join("d"), &p.join("e"));
        assert!(matches!(r, Err(FsError::NotRegular)), "{r:?}");
        symlink(p.join("old"), p.join("l")).unwrap();
        let r = rename_file(&p.join("l"), &p.join("m"));
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert!(p.join("old").is_file() && !p.join("m").exists());
        fs::create_dir(p.join("sub")).unwrap();
        let r = rename_file(&p.join("sub/absent"), &p.join("x"));
        assert!(
            matches!(&r, Err(FsError::Io(e)) if e.kind() == io::ErrorKind::NotFound),
            "{r:?}"
        );
    }

    #[test]
    fn rename_dir_syncs_both_parents() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir_all(root.path().join("p/a")).unwrap();
        fs::create_dir(root.path().join("q")).unwrap();
        let before = DIR_SYNCS.with(std::cell::Cell::get);
        rename_dir(&root.path().join("p/a"), &root.path().join("q/a")).unwrap();
        assert_eq!(DIR_SYNCS.with(std::cell::Cell::get), before + 2);
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
            tracing::warn!(
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

    /// Pattern D. A link planted as the leaf is removed as a link (what it names is left); one planted as a middle
    /// component is refused, and nothing behind it is touched.
    #[test]
    fn remove_beneath_refuses_a_planted_link() {
        let (root, fd) = root();
        let outside = tempfile::tempdir().unwrap();
        let canary = outside.path().join("canary");
        fs::write(&canary, b"keep").unwrap();
        fs::write(outside.path().join("f"), b"keep too").unwrap();
        fs::create_dir(root.path().join("d")).unwrap();
        fs::write(root.path().join("d/plain"), b"x").unwrap();
        symlink(&canary, root.path().join("d/leaf")).unwrap();
        symlink(outside.path(), root.path().join("mid")).unwrap();

        remove_beneath(fd.as_fd(), Path::new("d/plain")).unwrap();
        assert!(fs::symlink_metadata(root.path().join("d/plain")).is_err());
        remove_beneath(fd.as_fd(), Path::new("d/leaf")).unwrap();
        assert!(fs::symlink_metadata(root.path().join("d/leaf")).is_err());
        assert_eq!(fs::read(&canary).unwrap(), b"keep");

        let r = remove_beneath(fd.as_fd(), Path::new("mid/f"));
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert_eq!(fs::read(outside.path().join("f")).unwrap(), b"keep too");
        // gone already: done
        remove_beneath(fd.as_fd(), Path::new("d/plain")).unwrap();
        let r = remove_beneath(fd.as_fd(), Path::new("../x"));
        assert!(matches!(r, Err(FsError::Escapes)), "{r:?}");
    }

    /// Pattern D. A link made over an old leaf that is itself a link replaces it: the old target is never written,
    /// and the new link holds the bytes given, unresolved.
    #[test]
    fn symlink_beneath_never_follows_the_old_leaf() {
        let (root, fd) = root();
        let outside = tempfile::tempdir().unwrap();
        let canary = outside.path().join("canary");
        fs::write(&canary, b"keep").unwrap();
        symlink(&canary, root.path().join("l")).unwrap();
        fs::write(root.path().join("r"), b"regular").unwrap();

        symlink_beneath(fd.as_fd(), Path::new("l"), b"../nowhere/\xffx").unwrap();
        assert_eq!(
            fs::read_link(root.path().join("l"))
                .unwrap()
                .as_os_str()
                .as_bytes(),
            b"../nowhere/\xffx"
        );
        assert_eq!(fs::read(&canary).unwrap(), b"keep");
        symlink_beneath(fd.as_fd(), Path::new("r"), b"l").unwrap();
        assert!(
            fs::symlink_metadata(root.path().join("r"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        symlink_beneath(fd.as_fd(), Path::new("new"), b"r").unwrap();
        assert_eq!(
            fs::read_link(root.path().join("new")).unwrap(),
            Path::new("r")
        );
        // a link in the parent is refused, and nothing is made behind it
        symlink(outside.path(), root.path().join("ldir")).unwrap();
        let r = symlink_beneath(fd.as_fd(), Path::new("ldir/x"), b"y");
        assert!(matches!(r, Err(FsError::Link { .. })), "{r:?}");
        assert!(fs::symlink_metadata(outside.path().join("x")).is_err());
        assert!(temps(root.path()).is_empty() && temps(outside.path()).is_empty());
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
