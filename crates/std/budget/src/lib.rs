//! Measures the editor against its resource budgets (D9): PSS over a process tree, per-thread wakeups, and JSON
//! reports that compare to an earlier build of our own. Plain `/proc` parsing; Linux only.
//!
//! `cargo xtask measure` is the command-line front end. Every metric is lower-is-better.

mod proc;
mod report;

pub use proc::{ThreadWakeups, pss_kib, pss_kib_at, wakeups, wakeups_at};
pub use report::{Regression, Report};

use std::fmt;
use std::path::PathBuf;

/// What can go wrong while measuring or reading a report.
#[derive(Debug)]
pub enum Error {
    /// A `/proc` entry or a report file could not be read or written (a pid that is gone reads as `NotFound`).
    Io {
        path: PathBuf,
        source: std::io::Error,
    },
    /// A report file is not valid report JSON.
    Json {
        path: PathBuf,
        source: serde_json::Error,
    },
    /// A `/proc` file did not have the expected shape.
    Parse { path: PathBuf, what: &'static str },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Error::Json { path, source } => write!(f, "{}: {source}", path.display()),
            Error::Parse { path, what } => write!(f, "{}: expected {what}", path.display()),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io { source, .. } => Some(source),
            Error::Json { source, .. } => Some(source),
            Error::Parse { .. } => None,
        }
    }
}
