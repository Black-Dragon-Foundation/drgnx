//! eitri: file access that never follows a link (design 6.2 rule 4; docs/develop/runtime.md, "eitri").
//!
//! Generic: no drgnx type and no drgnx path. Used by gleipnir and draugr, and later by the file service.
//!
//! - `open`: `open_path` and `open_beneath`, which refuse a link in any component and return the fd they checked.
//! - `read`: bounded reads of regular files only (a FIFO is never read).
//! - `write`: writes by a temporary file and a rename, never through a link.
//! - `trusted`: a program that only root can change, found by fixed candidates and never through `PATH`.

use std::fmt;
use std::io;
use std::path::PathBuf;

mod open;
mod read;
mod trusted;
mod write;

pub use open::{Kind, Pinned, open_beneath, open_path};
pub use read::read_regular;
pub use trusted::{TrustedProgram, trusted_program};
pub use write::write_regular;

/// Why an eitri call refused or failed. Nothing here is ever retried by resolving the path another way.
#[derive(Debug)]
pub enum FsError {
    /// A link in some component of `path` (or a magic link); it was not followed.
    Link {
        path: PathBuf,
    },
    /// The file is not a regular file (a FIFO, a socket, a device, a directory …), or a write target is
    /// neither absent, a link nor a regular file.
    NotRegular,
    /// A directory was wanted, or a component before the last is not a directory.
    NotDir,
    /// The file holds more than `cap` bytes.
    TooLarge {
        cap: u64,
    },
    /// A relative path that is absolute or has a `..` component (refused before any syscall), or a resolution
    /// that left the directory it started from.
    Escapes,
    /// No candidate is a program only root can change; `path` and `why` are the last candidate's.
    Untrusted {
        path: PathBuf,
        why: &'static str,
    },
    /// The platform cannot open without following links (Linux before 5.6, an OS with no such open).
    Unsupported(&'static str),
    Io(io::Error),
}

impl fmt::Display for FsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FsError::Link { path } => write!(
                f,
                "{}: a link in the path (links are never followed)",
                path.display()
            ),
            FsError::NotRegular => f.write_str("not a regular file"),
            FsError::NotDir => f.write_str("not a directory"),
            FsError::TooLarge { cap } => write!(f, "larger than {cap} bytes"),
            FsError::Escapes => {
                f.write_str("the path leaves its directory (absolute, or a `..` component)")
            }
            FsError::Untrusted { path, why } => {
                write!(f, "{}: not a trusted program: {why}", path.display())
            }
            FsError::Unsupported(why) => write!(f, "unsupported: {why}"),
            FsError::Io(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for FsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            FsError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for FsError {
    fn from(e: io::Error) -> Self {
        FsError::Io(e)
    }
}

impl From<rustix::io::Errno> for FsError {
    fn from(e: rustix::io::Errno) -> Self {
        FsError::Io(e.into())
    }
}
