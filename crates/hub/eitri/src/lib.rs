//! eitri: file access that never follows a link (design 6.2 rule 4; docs/develop/runtime.md, "eitri").
//!
//! Generic: no drgnx type and no drgnx path. Used by gleipnir and draugr, and later by the file service.
//!
//! - `open`: `open_path` and `open_beneath`, which refuse a link in any component and return the fd they checked;
//!   `stat_beneath` and `stat_in`, the status of a file resolved the same way.
//! - `read`: bounded reads of regular files only (a FIFO is never read): `read_regular` beneath a directory fd,
//!   `read_file` and `read_string` at an absolute path.
//! - `write`: writes by a temporary file and a rename, never through a link (`write_regular` beneath a directory fd,
//!   `replace_file` at an absolute path: the files standard's way to replace a file, docs/develop/standards/files.md);
//!   a leaf removed or made a link at the parent's held fd.
//! - `trusted`: a program that only root can change, found by fixed candidates and never through `PATH`; and
//!   `root_only_file`, the same checks for a data file without the execute bit.

use std::fmt;
use std::io;
use std::path::PathBuf;

mod open;
mod read;
mod trusted;
mod write;

pub use open::{Kind, Meta, Pinned, open_beneath, open_path, stat_beneath, stat_in};
pub use read::{read_file, read_regular, read_string};
pub use trusted::{
    TrustedProgram, pin_system_owned_file, root_only_file, system_owned_file, trusted_program,
};
pub use write::{
    create_new, open_lock, remove_beneath, rename_dir, rename_file, replace_file, symlink_beneath,
    write_regular,
};

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

impl From<FsError> for villa::Error {
    /// A link, an escape and an untrusted program are `refused`; a file that is not the kind wanted or is too large
    /// is `invalid`; no way to open without links is `unavailable`; an io error is villa's own conversion of it.
    /// The user's sentence names the file's trouble, the error underneath is the source.
    fn from(e: FsError) -> villa::Error {
        match e {
            FsError::Io(e) => villa::Error::from(e),
            FsError::Link { .. } | FsError::Escapes | FsError::Untrusted { .. } => {
                villa::Error::refused(e.to_string()).with_source(e)
            }
            FsError::NotRegular | FsError::NotDir | FsError::TooLarge { .. } => {
                villa::Error::invalid(e.to_string()).with_source(e)
            }
            FsError::Unsupported(_) => villa::Error::unavailable(e.to_string()).with_source(e),
        }
    }
}
