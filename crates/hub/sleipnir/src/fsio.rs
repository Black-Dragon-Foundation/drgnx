//! The crate's file reads, writes and renames, through `eitri`, in the shapes the callers here already have
//! (`io::Result`): a link in a path is refused, a read is bounded and a write replaces the file whole.

use std::io;
use std::path::Path;

/// The most any file read here may hold (the files are small: `/proc` and `/sys` figures, state records, scripts).
const CAP: u64 = 16 << 20;

fn io_error(e: eitri::FsError) -> io::Error {
    match e {
        eitri::FsError::Io(e) => e,
        other => io::Error::other(other),
    }
}

/// PATH's text, as `std::fs::read_to_string` gave it, except that a link in the path or a file that is not regular is
/// refused.
pub fn read_to_string(path: impl AsRef<Path>) -> io::Result<String> {
    eitri::read_string(path.as_ref(), CAP).map_err(io_error)
}

/// PATH's bytes, as [`read_to_string`].
pub fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    eitri::read_file(path.as_ref(), CAP).map_err(io_error)
}

/// PATH holding exactly CONTENTS (a temporary file and a rename: a reader sees the old file or the new one).
pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
    eitri::replace_file(path.as_ref(), contents.as_ref()).map_err(io_error)
}

/// CONTENTS written into the existing file at PATH in place (a cgroup's control file: the kernel takes one write, and no
/// temporary file can be made beside it); a link at PATH is refused.
pub fn write_in_place(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
    eitri::write_in_place(path.as_ref(), contents.as_ref()).map_err(io_error)
}

/// The unix socket FROM moved to TO (replacing it).
pub fn rename_socket(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    eitri::rename_socket(from.as_ref(), to.as_ref()).map_err(io_error)
}

/// The file FROM moved to TO (replacing it).
pub fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    eitri::rename_file(from.as_ref(), to.as_ref()).map_err(io_error)
}
/// The folder FROM moved to TO (absolute paths; a link in either is refused; TO is replaced only when empty).
pub fn rename_dir(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    eitri::rename_dir(from.as_ref(), to.as_ref()).map_err(io_error)
}
/// The log at PATH opened for appending, made first (mode 0o644, less the umask) when CREATE and absent; a link at
/// PATH is refused.
pub fn append(path: impl AsRef<Path>, create: bool) -> io::Result<std::fs::File> {
    let abs = std::path::absolute(path.as_ref())?;
    eitri::open_append(&abs, create.then_some(0o644)).map_err(io::Error::from)
}

/// The existing file at PATH (a kernel pressure file, or a file made a step ago), open for reading and writing and
/// never blocking or truncating; a link at PATH is refused.
pub fn open_existing(path: impl AsRef<Path>) -> io::Result<std::fs::File> {
    eitri::open_existing(path.as_ref()).map_err(io_error)
}

/// A new file at PATH (mode MODE exactly), open for writing; `AlreadyExists` when the name is taken.
pub fn create_new(path: impl AsRef<Path>, mode: u32) -> io::Result<std::fs::File> {
    if !eitri::create_new(path.as_ref(), mode).map_err(io_error)? {
        return Err(io::ErrorKind::AlreadyExists.into());
    }
    open_existing(path)
}

/// The lock file at PATH, open for reading and writing and made (mode MODE, less the umask) when absent, never
/// truncated; a link at PATH is refused.
pub fn open_lock(path: impl AsRef<Path>, mode: u32) -> io::Result<std::fs::File> {
    eitri::open_lock(path.as_ref(), mode).map_err(io_error)
}
