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

/// The file FROM moved to TO (replacing it).
pub fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    eitri::rename_file(from.as_ref(), to.as_ref()).map_err(io_error)
}
/// The log at PATH opened for appending, made first (mode 0o644, less the umask) when CREATE and absent; a link at
/// PATH is refused.
pub fn append(path: impl AsRef<Path>, create: bool) -> io::Result<std::fs::File> {
    let abs = std::path::absolute(path.as_ref())?;
    eitri::open_append(&abs, create.then_some(0o644)).map_err(io::Error::from)
}
