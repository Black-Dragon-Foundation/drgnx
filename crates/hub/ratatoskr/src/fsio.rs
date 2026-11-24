//! The hub's files, through `eitri`: `std::fs`-shaped calls (an `io::Result`, a path of any kind) over eitri's, so the hub's
//! reads and writes never follow a link in the path and a write is never seen half done (docs/develop/standards/files.md).
//!
//! A path may be relative: it is made absolute against the working directory first. A read is capped at [`MAX_TEXT`].

use std::io;
use std::path::{Path, PathBuf};

/// The most a text file read here may hold: a hub file this large is a mistake, never a document.
pub const MAX_TEXT: u64 = 256 << 20;

/// P made absolute, with `/proc/self` and `/proc/net` as the process's own pid names them: `eitri` follows no link, and
/// both are links.
fn absolute(p: &Path) -> io::Result<PathBuf> {
    let abs = std::path::absolute(p)?;
    if let Ok(rest) = abs.strip_prefix("/proc") {
        let mut parts = rest.components();
        if let Some(first) = parts.next()
            && (first.as_os_str() == "self" || first.as_os_str() == "net")
        {
            let pid = std::process::id().to_string();
            let mut out = PathBuf::from("/proc").join(&pid);
            if first.as_os_str() == "net" {
                out.push("net");
            }
            out.extend(parts);
            return Ok(out);
        }
    }
    Ok(abs)
}

fn io_of(e: eitri::FsError) -> io::Error {
    match e {
        eitri::FsError::Io(e) => e,
        other => io::Error::other(other),
    }
}

/// BYTES as the whole content of the file at PATH (a link there is replaced, never followed; a reader sees the old bytes
/// or the new ones).
pub fn write(path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> io::Result<()> {
    #[cfg(test)]
    disk::gate(path.as_ref());
    eitri::replace_file(&absolute(path.as_ref())?, bytes.as_ref()).map_err(io_of)
}

/// The file at PATH as text (at most [`MAX_TEXT`]; not UTF-8 is `InvalidData`).
pub fn read_to_string(path: impl AsRef<Path>) -> io::Result<String> {
    #[cfg(test)]
    disk::gate(path.as_ref());
    eitri::read_string(&absolute(path.as_ref())?, MAX_TEXT).map_err(io_of)
}

/// The file at PATH as bytes (at most [`MAX_TEXT`]).
pub fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    #[cfg(test)]
    disk::gate(path.as_ref());
    eitri::read_file(&absolute(path.as_ref())?, MAX_TEXT).map_err(io_of)
}

/// FROM renamed to TO: a folder, a socket or a regular file; a link is refused (`eitri` follows none).
pub fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    #[cfg(test)]
    disk::gate(to.as_ref());
    use std::os::unix::fs::FileTypeExt;
    let (from, to) = (absolute(from.as_ref())?, absolute(to.as_ref())?);
    let kind = std::fs::symlink_metadata(&from)?.file_type();
    let done = if kind.is_dir() {
        eitri::rename_dir(&from, &to)
    } else if kind.is_socket() {
        eitri::rename_socket(&from, &to)
    } else {
        eitri::rename_file(&from, &to)
    };
    done.map_err(io_of)
}

/// BYTES as the whole content of the existing file at PATH, written where it stands (its inode, and a lock held on it,
/// stay).
pub fn write_in_place(path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> io::Result<()> {
    #[cfg(test)]
    disk::gate(path.as_ref());
    eitri::write_in_place(&absolute(path.as_ref())?, bytes.as_ref()).map_err(io_of)
}

/// BYTES into the named pipe (FIFO) at PATH: the open waits for a reader. `eitri` writes regular files only, and a pipe
/// is the one thing a test of a job that waits for a line needs to write to.
pub fn write_pipe(path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> io::Result<()> {
    let fd = rustix::fs::open(
        absolute(path.as_ref())?.as_path(),
        rustix::fs::OFlags::WRONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )?;
    let mut rest = bytes.as_ref();
    while !rest.is_empty() {
        match rustix::io::write(&fd, rest) {
            Ok(n) => rest = &rest[n..],
            Err(rustix::io::Errno::INTR) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// BYTES to DEST through the temporary TMP the caller names (see `eitri::replace_via`).
pub fn write_via(
    tmp: impl AsRef<Path>,
    dest: impl AsRef<Path>,
    bytes: impl AsRef<[u8]>,
) -> io::Result<()> {
    #[cfg(test)]
    disk::gate(dest.as_ref());
    eitri::replace_via(
        &std::path::absolute(tmp.as_ref())?,
        &std::path::absolute(dest.as_ref())?,
        bytes.as_ref(),
    )
    .map_err(io_of)
}

/// The log at PATH opened for appending, made first (mode 0o644, less the umask) when CREATE and absent; a link at
/// PATH is refused.
pub fn append(path: impl AsRef<Path>, create: bool) -> io::Result<std::fs::File> {
    #[cfg(test)]
    disk::gate(path.as_ref());
    let abs = std::path::absolute(path.as_ref())?;
    eitri::open_append(&abs, create.then_some(0o644)).map_err(io::Error::from)
}

/// A slow disk for a test: while a [`disk::slow`] gate holds a path, every call of this module on it waits, so a test can
/// prove that nothing the hub needs runs on the thread that waits (no FIFO standing in for the disk: the files stay plain).
#[cfg(test)]
pub mod disk {
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Condvar, Mutex};

    #[derive(Default)]
    struct State {
        reached: bool,
        released: bool,
    }

    /// A held path: [`Slow::reached`] waits until a call is waiting on it, [`Slow::release`] lets every call go on.
    pub struct Slow {
        gate: Gate,
        path: PathBuf,
    }

    type Gate = Arc<(Mutex<State>, Condvar)>;

    static GATES: Mutex<Vec<(PathBuf, Gate)>> = Mutex::new(Vec::new());

    /// Hold PATH: calls on it wait until [`Slow::release`].
    pub fn slow(path: &Path) -> Slow {
        let gate = Arc::new((Mutex::new(State::default()), Condvar::new()));
        saman::lock(&GATES).push((path.to_path_buf(), gate.clone()));
        Slow {
            gate,
            path: path.to_path_buf(),
        }
    }

    pub(super) fn gate(path: &Path) {
        let held = saman::lock(&GATES)
            .iter()
            .find(|(p, _)| p == path)
            .map(|(_, g)| g.clone());
        if let Some(g) = held {
            let (m, cv) = &*g;
            let mut st = saman::lock(m);
            st.reached = true;
            cv.notify_all();
            while !st.released {
                st = cv.wait(st).unwrap_or_else(|e| e.into_inner());
            }
        }
    }

    impl Slow {
        /// Wait (this thread blocks) until a call is waiting on the path.
        pub fn reached(&self) {
            let (m, cv) = &*self.gate;
            let mut st = saman::lock(m);
            while !st.reached {
                st = cv.wait(st).unwrap_or_else(|e| e.into_inner());
            }
        }

        /// Let every call waiting on the path, and any later one, go on.
        pub fn release(&self) {
            let (m, cv) = &*self.gate;
            saman::lock(m).released = true;
            cv.notify_all();
        }
    }

    impl Drop for Slow {
        fn drop(&mut self) {
            self.release();
            saman::lock(&GATES).retain(|(p, _)| p != &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_is_read_back_and_replaces_what_was_there() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a");
        write(&file, "one").unwrap();
        write(&file, b"two".as_slice()).unwrap();
        assert_eq!(read_to_string(&file).unwrap(), "two");
        assert_eq!(read(&file).unwrap(), b"two");
    }

    #[test]
    fn a_write_replaces_a_link_and_never_follows_it() {
        let dir = tempfile::tempdir().unwrap();
        let (target, link) = (dir.path().join("target"), dir.path().join("link"));
        write(&target, "kept").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        write(&link, "through the link").unwrap();
        assert_eq!(read_to_string(&target).unwrap(), "kept");
        assert_eq!(read_to_string(&link).unwrap(), "through the link");
    }

    #[test]
    fn a_missing_file_is_not_found_and_a_rename_moves_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let e = read_to_string(dir.path().join("none")).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::NotFound);
        let (a, b) = (dir.path().join("a"), dir.path().join("b"));
        write(&a, "x").unwrap();
        rename(&a, &b).unwrap();
        assert_eq!(read_to_string(&b).unwrap(), "x");
        assert!(read_to_string(&a).is_err());
    }
}
