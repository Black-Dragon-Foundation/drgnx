//! Opens that refuse every link (Task 1). Linux and Android: `openat2` with `RESOLVE_NO_SYMLINKS`
//! (`any(target_os = "linux", target_os = "android")`: a kernel fact); macOS: `O_NOFOLLOW_ANY`.

use std::io;
use std::os::fd::{BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};

use rustix::fs::{FileType, fstat};
use rustix::io::Errno;

use crate::FsError;

/// What `open_path` and `open_beneath` accept at the end of the path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Dir,
    File,
    Any,
}

/// An open file or directory and the identity it was checked under. The fd is what was checked: pass it on
/// (bind it by fd, read through it) instead of opening the path again.
#[derive(Debug)]
pub struct Pinned {
    pub fd: OwnedFd,
    pub dev: u64,
    pub ino: u64,
    pub is_dir: bool,
}

/// Opens the absolute path `abs` without following a link in any component, then checks the kind on the fd.
///
/// Linux and Android: `openat2(O_PATH | O_CLOEXEC [| O_DIRECTORY], RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)`.
/// macOS: `open(O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY | O_NOFOLLOW_ANY [| O_DIRECTORY])`. A kernel without
/// `openat2` gives `Unsupported`: there is never a fallback that resolves by path.
pub fn open_path(abs: &Path, kind: Kind) -> Result<Pinned, FsError> {
    no_nul(abs)?;
    if !abs.is_absolute() {
        return Err(invalid("open_path needs an absolute path"));
    }
    pin(raw_open(None, abs, How::Pin(kind))?, kind)
}

/// Opens `rel` beneath `dir` without following a link in any component and without leaving `dir`. An absolute
/// `rel`, or one with a `..` component, is `Escapes` before any syscall.
pub fn open_beneath(dir: BorrowedFd<'_>, rel: &Path, kind: Kind) -> Result<Pinned, FsError> {
    checked_rel(rel)?;
    pin(raw_open(Some(dir), rel, How::Pin(kind))?, kind)
}

/// `rel` stays beneath its directory (no root, no `..`; checked on the components, before any syscall) and holds
/// no NUL byte.
pub(crate) fn checked_rel(rel: &Path) -> Result<(), FsError> {
    if !rel
        .components()
        .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
    {
        return Err(FsError::Escapes);
    }
    no_nul(rel)
}

/// A NUL byte would end the C string early: refused here, so it is never mistaken for the kernel's `EINVAL`.
fn no_nul(p: &Path) -> Result<(), FsError> {
    if p.as_os_str().as_bytes().contains(&0) {
        Err(invalid("a NUL byte in the path"))
    } else {
        Ok(())
    }
}

pub(crate) fn invalid(why: &'static str) -> FsError {
    FsError::Io(io::Error::new(io::ErrorKind::InvalidInput, why))
}

fn pin(fd: OwnedFd, kind: Kind) -> Result<Pinned, FsError> {
    let st = fstat(&fd)?;
    let ft = FileType::from_raw_mode(st.st_mode);
    let is_dir = ft == FileType::Directory;
    #[allow(clippy::unnecessary_cast)] // st_dev is i32 on macOS, u64 on Linux and Android
    let (dev, ino) = (st.st_dev as u64, st.st_ino as u64);
    match kind {
        Kind::Dir if !is_dir => Err(FsError::NotDir),
        Kind::File if ft != FileType::RegularFile => Err(FsError::NotRegular),
        _ => Ok(Pinned {
            fd,
            dev,
            ino,
            is_dir,
        }),
    }
}

/// How `raw_open` opens: an fd that pins the file (`O_PATH` where there is one), or one to read a regular file.
#[derive(Clone, Copy)]
pub(crate) enum How {
    Pin(Kind),
    Read,
}

/// The errno of a refused open, as eitri's error.
fn refused(e: Errno, path: &Path) -> FsError {
    match e {
        Errno::LOOP => FsError::Link {
            path: path.to_path_buf(),
        },
        Errno::NOTDIR => FsError::NotDir,
        _ => FsError::from(e),
    }
}

/// The one platform function: open `path` (beneath `dir`, or absolute when `dir` is `None`) following no link.
/// Linux and Android: `openat2` (a Linux-kernel fact, so Android takes the same path).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn raw_open(
    dir: Option<BorrowedFd<'_>>,
    path: &Path,
    how: How,
) -> Result<OwnedFd, FsError> {
    use rustix::fs::{OFlags, ResolveFlags};
    // O_PATH takes only O_DIRECTORY, O_NOFOLLOW and O_CLOEXEC beside it (openat2 refuses the rest with EINVAL), so
    // no O_NOCTTY there: an O_PATH fd never opens the file, so never makes a controlling terminal.
    let oflags = match how {
        How::Pin(Kind::Dir) => OFlags::PATH | OFlags::CLOEXEC | OFlags::DIRECTORY,
        How::Pin(_) => OFlags::PATH | OFlags::CLOEXEC,
        How::Read => OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY,
    };
    let mut resolve = ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS;
    if dir.is_some() {
        resolve |= ResolveFlags::BENEATH;
    }
    // `path` is absolute when `dir` is None (open_path checks it), so the dirfd is not used then.
    openat2(dir.unwrap_or(rustix::fs::CWD), path, oflags, resolve).map_err(|e| match e {
        // No openat2 (ENOSYS), or one that does not know these flags (EINVAL): never a fallback by path.
        Errno::NOSYS | Errno::INVAL => FsError::Unsupported(
            "opening without following links needs openat2 (Linux 5.6 or later)",
        ),
        Errno::XDEV => FsError::Escapes,
        e => refused(e, path),
    })
}

/// The `openat2` call, with the test seam in front of it.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn openat2(
    dir: BorrowedFd<'_>,
    path: &Path,
    oflags: rustix::fs::OFlags,
    resolve: rustix::fs::ResolveFlags,
) -> Result<OwnedFd, Errno> {
    #[cfg(test)]
    if let Some(e) = seam::hit() {
        return Err(e);
    }
    rustix::fs::openat2(dir, path, oflags, rustix::fs::Mode::empty(), resolve)
}

/// macOS: `O_NOFOLLOW_ANY` refuses a link in any component (ELOOP). `..` and absolute paths are refused before
/// this for `open_beneath`, so with no link followed the path cannot leave `dir`. (Android takes the `openat2`
/// branch above.)
#[cfg(target_os = "macos")]
pub(crate) fn raw_open(
    dir: Option<BorrowedFd<'_>>,
    path: &Path,
    how: How,
) -> Result<OwnedFd, FsError> {
    use rustix::fs::{Mode, OFlags};
    let mut oflags =
        OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY | OFlags::NOFOLLOW_ANY;
    if matches!(how, How::Pin(Kind::Dir)) {
        oflags |= OFlags::DIRECTORY;
    }
    rustix::fs::openat(dir.unwrap_or(rustix::fs::CWD), path, oflags, Mode::empty())
        .map_err(|e| refused(e, path))
}

/// Every other OS: no open that refuses links, so nothing opens (fails closed). Android never gets here (it takes
/// the `openat2` branch).
#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
pub(crate) fn raw_open(
    dir: Option<BorrowedFd<'_>>,
    path: &Path,
    how: How,
) -> Result<OwnedFd, FsError> {
    let _ = (dir, path, how, refused);
    Err(FsError::Unsupported(
        "no open that refuses links on this OS",
    ))
}

/// The test seam on the `openat2` wrapper: an errno to return instead of making the call, and a count of the
/// calls made, per thread. Linux and Android only (the only `openat2` targets).
#[cfg(all(test, any(target_os = "linux", target_os = "android")))]
pub(crate) mod seam {
    use rustix::io::Errno;
    use std::cell::Cell;

    thread_local! {
        static INJECT: Cell<Option<Errno>> = const { Cell::new(None) };
        static CALLS: Cell<u32> = const { Cell::new(0) };
    }

    /// Sets the errno every later `openat2` on this thread returns (`None`: make real calls), and zeroes the count.
    pub(crate) fn inject(errno: Option<Errno>) {
        INJECT.with(|c| c.set(errno));
        CALLS.with(|c| c.set(0));
    }

    pub(crate) fn calls() -> u32 {
        CALLS.with(Cell::get)
    }

    /// Counts the call; `Some(errno)` when one is injected.
    pub(crate) fn hit() -> Option<Errno> {
        CALLS.with(|c| c.set(c.get() + 1));
        INJECT.with(Cell::get)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::fd::AsFd;
    use std::os::unix::fs::{MetadataExt, symlink};

    fn tree() -> (tempfile::TempDir, OwnedFd) {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("a")).unwrap();
        fs::create_dir(root.path().join("b")).unwrap();
        fs::write(root.path().join("b/f"), b"x").unwrap();
        symlink("../b", root.path().join("a/l")).unwrap();
        symlink("../b/f", root.path().join("a/lf")).unwrap();
        let fd = fs::File::open(root.path()).unwrap().into();
        (root, fd)
    }

    #[test]
    fn a_link_in_any_component_is_refused() {
        let (root, fd) = tree();
        // The temporary root's own path without links (macOS: /var → /private/var).
        let base = root.path().canonicalize().unwrap();
        // The control: the same file through no link opens, and is the file the link points at.
        let p = open_beneath(fd.as_fd(), Path::new("b/f"), Kind::File).unwrap();
        let m = fs::metadata(base.join("b/f")).unwrap();
        assert_eq!((p.dev, p.ino, p.is_dir), (m.dev(), m.ino(), false));
        let p = open_path(&base.join("b/f"), Kind::File).unwrap();
        assert_eq!((p.dev, p.ino), (m.dev(), m.ino()));

        for rel in ["a/l/f", "a/l", "a/lf"] {
            match open_beneath(fd.as_fd(), Path::new(rel), Kind::Any) {
                Err(FsError::Link { path }) => assert_eq!(path, Path::new(rel)),
                other => panic!("{rel}: {other:?}"),
            }
            let abs = base.join(rel);
            match open_path(&abs, Kind::Any) {
                Err(FsError::Link { path }) => assert_eq!(path, abs),
                other => panic!("{rel} (absolute): {other:?}"),
            }
        }
    }

    #[test]
    fn the_kind_is_checked() {
        let (_root, fd) = tree();
        assert!(matches!(
            open_beneath(fd.as_fd(), Path::new("b"), Kind::File),
            Err(FsError::NotRegular)
        ));
        assert!(matches!(
            open_beneath(fd.as_fd(), Path::new("b/f"), Kind::Dir),
            Err(FsError::NotDir)
        ));
        let d = open_beneath(fd.as_fd(), Path::new("b"), Kind::Dir).unwrap();
        assert!(d.is_dir);
        assert!(
            open_beneath(fd.as_fd(), Path::new("b"), Kind::Any)
                .unwrap()
                .is_dir
        );
        assert!(open_path(Path::new("/"), Kind::Dir).unwrap().is_dir);
    }

    #[test]
    fn open_path_needs_an_absolute_path() {
        assert!(matches!(
            open_path(Path::new("usr"), Kind::Any),
            Err(FsError::Io(_))
        ));
    }

    #[test]
    fn a_nul_byte_is_refused_not_unsupported() {
        use std::os::unix::ffi::OsStrExt;
        let (_root, fd) = tree();
        let bad = Path::new(std::ffi::OsStr::from_bytes(b"b/f\0x"));
        assert!(matches!(
            open_beneath(fd.as_fd(), bad, Kind::Any),
            Err(FsError::Io(_))
        ));
        let bad = Path::new(std::ffi::OsStr::from_bytes(b"/tmp\0x"));
        assert!(matches!(open_path(bad, Kind::Any), Err(FsError::Io(_))));
    }

    // The seam's tests: Linux and Android (openat2). Android: same kernel interface, same tests.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    mod no_link_syscall {
        use super::*;
        use crate::open::seam;
        use rustix::io::Errno;

        #[test]
        fn dotdot_is_escapes_before_any_syscall() {
            let (_root, fd) = tree();
            seam::inject(Some(Errno::IO));
            // The control: a path that passes the check reaches the (failing) syscall.
            assert!(matches!(
                open_beneath(fd.as_fd(), Path::new("b/f"), Kind::Any),
                Err(FsError::Io(_))
            ));
            assert_eq!(seam::calls(), 1);
            for rel in ["..", "a/../b", "b/f/..", "/etc", "/"] {
                let r = open_beneath(fd.as_fd(), Path::new(rel), Kind::Any);
                assert!(matches!(r, Err(FsError::Escapes)), "{rel}: {r:?}");
                let r = crate::read_regular(fd.as_fd(), Path::new(rel), 16);
                assert!(matches!(r, Err(FsError::Escapes)), "read {rel}: {r:?}");
                let r = crate::write_regular(fd.as_fd(), Path::new(rel), b"x", 0o644);
                assert!(matches!(r, Err(FsError::Escapes)), "write {rel}: {r:?}");
            }
            assert_eq!(seam::calls(), 1, "a refused path made a syscall");
            seam::inject(None);
        }

        #[test]
        fn no_openat2_is_unsupported_not_a_fallback() {
            let (root, fd) = tree();
            for errno in [Errno::NOSYS, Errno::INVAL] {
                seam::inject(Some(errno));
                let unsupported = |r: Result<(), FsError>, what: &str| match r {
                    Err(FsError::Unsupported(why)) => {
                        assert!(why.contains("openat2"), "{what}: {why}")
                    }
                    other => panic!("{what} with {errno:?}: {other:?}"),
                };
                unsupported(
                    open_path(&root.path().join("b/f"), Kind::File).map(drop),
                    "open_path",
                );
                unsupported(
                    open_path(Path::new("/"), Kind::Dir).map(drop),
                    "open_path /",
                );
                unsupported(
                    open_beneath(fd.as_fd(), Path::new("b/f"), Kind::File).map(drop),
                    "open_beneath",
                );
                unsupported(
                    crate::read_regular(fd.as_fd(), Path::new("b/f"), 16).map(drop),
                    "read_regular",
                );
                unsupported(
                    crate::write_regular(fd.as_fd(), Path::new("b/g"), b"x", 0o644),
                    "write_regular",
                );
                unsupported(
                    crate::trusted_program(&[Path::new("/usr/bin/env")]).map(drop),
                    "trusted_program",
                );
                assert!(
                    !root.path().join("b/g").exists(),
                    "a write went through another path"
                );
            }
            seam::inject(None);
            // The control: without the injected errno the same calls work.
            open_path(&root.path().join("b/f"), Kind::File).unwrap();
            assert_eq!(
                crate::read_regular(fd.as_fd(), Path::new("b/f"), 16).unwrap(),
                b"x"
            );
        }
    }
}
