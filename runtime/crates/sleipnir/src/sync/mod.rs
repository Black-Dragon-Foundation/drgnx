//! Getting the code to a runner (docs/develop/sleipnir.md, "Sync").
//!
//! - `capture`: a job's inputs frozen at submit: the commit, its tree, an overlay manifest of every uncommitted
//!   change and the declared gitignored extras, all as raw bytes; and the input key over them.
//! - `git`: `Git::cmd`, the only way sleipnir runs git. Hooks and fsmonitor are off, no system or global config is
//!   read, received objects are checked, and no inherited `GIT_*` variable reaches git.
//! - `slot`: one checkout per slot key, updated in place through a git dir outside the slot; private copies for
//!   jobs that write the tree; the locks; the prune of slots unused for 7 days.

use std::error::Error;
use std::fmt;
use std::io;
use std::path::PathBuf;

pub mod capture;
pub mod git;
pub mod slot;

#[cfg(test)]
mod testutil;

/// Why a sync step refused or failed. Nothing here is retried another way.
#[derive(Debug)]
pub enum SyncError {
    /// Declared inputs that are not there, each as it was declared.
    Missing(Vec<PathBuf>),
    /// A path that is never sent or written (raw bytes, exactly as found), and why.
    Refused {
        path: Vec<u8>,
        why: &'static str,
    },
    /// A git command that failed: what it was run for, its exit code and the end of its stderr.
    Git {
        what: &'static str,
        code: Option<i32>,
        stderr: String,
    },
    Io(io::Error),
}

impl fmt::Display for SyncError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SyncError::Missing(paths) => {
                write!(f, "declared inputs are missing:")?;
                for p in paths {
                    write!(f, " {}", p.display())?;
                }
                Ok(())
            }
            SyncError::Refused { path, why } => {
                write!(
                    f,
                    "{}: refused ({why})",
                    String::from_utf8_lossy(path).escape_debug()
                )
            }
            SyncError::Git { what, code, stderr } => match code {
                Some(c) => write!(f, "git ({what}) exited {c}: {stderr}"),
                None => write!(f, "git ({what}): {stderr}"),
            },
            SyncError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl Error for SyncError {}

impl From<io::Error> for SyncError {
    fn from(e: io::Error) -> Self {
        SyncError::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, SyncError>;

/// Why a repository-relative path (raw bytes) is never sent or written, or `Ok` when it may be. A path is relative,
/// has no empty, `.` or `..` component and no `.git` component in any case.
pub(crate) fn check_path(path: &[u8]) -> std::result::Result<(), &'static str> {
    if path.is_empty() {
        return Err("an empty path");
    }
    if path[0] == b'/' {
        return Err("an absolute path");
    }
    if path.contains(&0) {
        return Err("a NUL byte");
    }
    for c in path.split(|&b| b == b'/') {
        match c {
            b"" => return Err("an empty component"),
            b"." | b".." => return Err("a . or .. component"),
            c if c.eq_ignore_ascii_case(b".git") => return Err("a .git component"),
            _ => {}
        }
    }
    Ok(())
}

pub(crate) fn refused(path: &[u8], why: &'static str) -> SyncError {
    SyncError::Refused {
        path: path.to_vec(),
        why,
    }
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 15) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure
    #[test]
    fn paths_that_are_never_written() {
        for bad in [
            &b""[..],
            b"/etc/passwd",
            b"a/../b",
            b"./a",
            b"a//b",
            b"a/",
            b".git/hooks/post-checkout",
            b"sub/.GIT/config",
            b"a\0b",
        ] {
            assert!(
                check_path(bad).is_err(),
                "{:?} was allowed",
                String::from_utf8_lossy(bad)
            );
        }
        for good in [
            &b"a b"[..],
            b"new\nline",
            b"\xff\xfe.bin",
            b".gitignore",
            b"a/.github/x",
            b"..a",
        ] {
            assert_eq!(check_path(good), Ok(()));
        }
    }
}
