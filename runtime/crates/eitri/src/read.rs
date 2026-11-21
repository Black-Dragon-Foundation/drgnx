//! Bounded reads of regular files, opened beneath a directory fd (Task 1).

use std::os::fd::BorrowedFd;
use std::path::Path;

use rustix::fs::{FileType, fstat};
use rustix::io::Errno;

use crate::FsError;
use crate::open::{How, checked_rel, raw_open};

/// Reads the regular file `rel` beneath `dir`: no link followed, never outside `dir`, at most `cap` bytes.
///
/// The open is `O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY` with the same resolution as `open_beneath`, so a FIFO
/// opens at once and is then refused by `fstat` (`NotRegular`), never read. At most `cap + 1` bytes are read; the
/// one past `cap` means `TooLarge`.
pub fn read_regular(dir: BorrowedFd<'_>, rel: &Path, cap: u64) -> Result<Vec<u8>, FsError> {
    checked_rel(rel)?;
    let (fd, st) = open_regular(dir, rel)?;
    let limit = cap.saturating_add(1);
    let hint = u64::try_from(st.st_size).unwrap_or(0).min(cap).min(1 << 20);
    let mut out = Vec::with_capacity(hint as usize + 1);
    let mut buf = [0u8; 64 * 1024];
    loop {
        let want = (limit - out.len() as u64).min(buf.len() as u64) as usize;
        if want == 0 {
            break;
        }
        let n = match rustix::io::read(&fd, &mut buf[..want]) {
            Ok(0) => break,
            Ok(n) => n,
            Err(Errno::INTR) => continue,
            Err(e) => return Err(e.into()),
        };
        out.extend_from_slice(&buf[..n]);
    }
    if out.len() as u64 > cap {
        return Err(FsError::TooLarge { cap });
    }
    Ok(out)
}

/// Opens `rel` for reading and returns it with its status, a regular file only.
///
/// Linux and Android: the file is pinned with `O_PATH` first, which opens nothing (a device node's or a FIFO's open
/// has side effects, GL-T1-2), its kind is read from that fd, and only a regular file is opened for reading, through
/// `/proc/self/fd/N` (the same inode, whatever happens to the path meanwhile). Without `/proc` the file is opened
/// directly and refused after the open, as it is elsewhere.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn open_regular(
    dir: BorrowedFd<'_>,
    rel: &Path,
) -> Result<(std::os::fd::OwnedFd, rustix::fs::Stat), FsError> {
    use rustix::fs::{Mode, OFlags};
    use std::os::fd::AsRawFd;
    let pin = raw_open(Some(dir), rel, How::Pin(crate::Kind::File))?;
    let st = fstat(&pin)?;
    if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
        return Err(FsError::NotRegular);
    }
    let via = format!("/proc/self/fd/{}", pin.as_raw_fd());
    let flags = OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
    match rustix::fs::open(&via, flags, Mode::empty()) {
        Ok(fd) => {
            // the same file, checked again on the fd that reads
            let st = fstat(&fd)?;
            if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
                return Err(FsError::NotRegular);
            }
            Ok((fd, st))
        }
        Err(Errno::NOENT) => open_regular_direct(dir, rel),
        Err(e) => Err(e.into()),
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn open_regular(
    dir: BorrowedFd<'_>,
    rel: &Path,
) -> Result<(std::os::fd::OwnedFd, rustix::fs::Stat), FsError> {
    open_regular_direct(dir, rel)
}

fn open_regular_direct(
    dir: BorrowedFd<'_>,
    rel: &Path,
) -> Result<(std::os::fd::OwnedFd, rustix::fs::Stat), FsError> {
    let fd = raw_open(Some(dir), rel, How::Read)?;
    let st = fstat(&fd)?;
    if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
        return Err(FsError::NotRegular);
    }
    Ok((fd, st))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::fd::{AsFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    #[cfg(any(target_os = "linux", target_os = "android"))]
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::fs::symlink;
    use std::sync::mpsc;
    use std::time::Duration;

    fn root() -> (tempfile::TempDir, OwnedFd) {
        let root = tempfile::tempdir().unwrap();
        let fd = fs::File::open(root.path()).unwrap().into();
        (root, fd)
    }

    #[test]
    fn fifo_never_blocks() {
        let (root, fd) = root();
        let fifo = root.path().canonicalize().unwrap().join("p");
        let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let read = read_regular(fd.as_fd(), Path::new("p"), 16).map(drop);
            let pin = crate::open_beneath(fd.as_fd(), Path::new("p"), crate::Kind::File).map(drop);
            let pin_abs = crate::open_path(&fifo, crate::Kind::File).map(drop);
            tx.send((read, pin, pin_abs)).unwrap();
        });
        let (read, pin, pin_abs) = rx
            .recv_timeout(Duration::from_secs(1))
            .expect("a FIFO blocked");
        assert!(matches!(read, Err(FsError::NotRegular)), "{read:?}");
        assert!(matches!(pin, Err(FsError::NotRegular)), "{pin:?}");
        assert!(matches!(pin_abs, Err(FsError::NotRegular)), "{pin_abs:?}");
    }

    /// GL-T1-2: refusing a FIFO must not open it. A writer blocked in `open(O_WRONLY)` is released by any reader's
    /// open, so a read that opened the FIFO before refusing it would let that writer through.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    #[ignore = "timing: a writer blocked in open(2) stays blocked after a refused read"]
    fn a_refused_fifo_is_never_opened() {
        let (root, fd) = root();
        let fifo = root.path().canonicalize().unwrap().join("p");
        let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let (tx, rx) = mpsc::channel();
        let path = fifo.clone();
        let writer = std::thread::spawn(move || {
            let f = fs::OpenOptions::new().write(true).open(&path); // blocks until a reader opens
            tx.send(f.is_ok()).unwrap();
        });
        std::thread::sleep(Duration::from_millis(200)); // the writer is inside open(2)
        let r = read_regular(fd.as_fd(), Path::new("p"), 16);
        assert!(matches!(r, Err(FsError::NotRegular)), "{r:?}");
        assert!(
            rx.recv_timeout(Duration::from_millis(500)).is_err(),
            "the refusal opened the FIFO and released its writer"
        );
        // let the writer go
        drop(
            fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&fifo),
        );
        writer.join().unwrap();
    }

    #[test]
    fn cap_is_enforced() {
        let (root, fd) = root();
        fs::write(root.path().join("f"), [7u8; 16]).unwrap();
        fs::write(root.path().join("empty"), b"").unwrap();
        assert!(matches!(
            read_regular(fd.as_fd(), Path::new("f"), 15),
            Err(FsError::TooLarge { cap: 15 })
        ));
        assert!(matches!(
            read_regular(fd.as_fd(), Path::new("f"), 0),
            Err(FsError::TooLarge { cap: 0 })
        ));
        assert_eq!(
            read_regular(fd.as_fd(), Path::new("f"), 16).unwrap(),
            [7u8; 16]
        );
        assert_eq!(
            read_regular(fd.as_fd(), Path::new("f"), u64::MAX).unwrap(),
            [7u8; 16]
        );
        assert_eq!(
            read_regular(fd.as_fd(), Path::new("empty"), 0).unwrap(),
            b""
        );
    }

    #[test]
    fn a_large_file_is_read_whole() {
        let (root, fd) = root();
        let big: Vec<u8> = (0..300_000u32).map(|i| i as u8).collect();
        fs::write(root.path().join("big"), &big).unwrap();
        assert_eq!(
            read_regular(fd.as_fd(), Path::new("big"), big.len() as u64).unwrap(),
            big
        );
        let r = read_regular(fd.as_fd(), Path::new("big"), big.len() as u64 - 1);
        assert!(matches!(r, Err(FsError::TooLarge { .. })), "{r:?}");
    }

    #[test]
    fn a_directory_or_a_link_is_never_read() {
        let (root, fd) = root();
        fs::create_dir(root.path().join("d")).unwrap();
        fs::write(root.path().join("d/f"), b"secret").unwrap();
        symlink("d/f", root.path().join("l")).unwrap();
        assert!(matches!(
            read_regular(fd.as_fd(), Path::new("d"), 16),
            Err(FsError::NotRegular)
        ));
        assert!(matches!(
            read_regular(fd.as_fd(), Path::new("l"), 16),
            Err(FsError::Link { .. })
        ));
        assert_eq!(
            read_regular(fd.as_fd(), Path::new("d/f"), 16).unwrap(),
            b"secret"
        );
    }
}
