//! urdr: a small SQLite store.
//!
//! One thread owns the connection(s) and runs closures sent over a bounded channel, so SQLite never runs on an async
//! worker (`thread`). Read-only connections never checkpoint (`open`). Schema migrations are data (`migrate`). The
//! public API carries no application types.

mod migrate;
mod open;
mod thread;

use std::fmt;

pub use open::{Mode, StoreSpec, open_readonly, open_store};
pub use rusqlite::Connection;
pub use thread::{Handle, Store};

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    Sqlite(rusqlite::Error),
    Io(std::io::Error),
    /// The file's `meta.schema` is above the last known migration; nothing was written.
    NewerSchema {
        found: u32,
        known: u32,
    },
    /// The linked SQLite is older than the caller requires.
    SqliteTooOld {
        have: i32,
        need: i32,
    },
    /// A write was asked of a read-only store.
    ReadOnly,
    /// The store thread is gone (shut down, or a request was dropped unanswered).
    Closed,
    /// The closure panicked on the store thread.
    Panicked,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Sqlite(e) => write!(f, "sqlite: {e}"),
            Error::Io(e) => write!(f, "io: {e}"),
            Error::NewerSchema { found, known } => {
                write!(f, "database schema {found} is newer than the known {known}")
            }
            Error::SqliteTooOld { have, need } => {
                write!(f, "SQLite {have} is older than the required {need}")
            }
            Error::ReadOnly => write!(f, "the store is read-only"),
            Error::Closed => write!(f, "the store is closed"),
            Error::Panicked => write!(f, "a store closure panicked"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Sqlite(e) => Some(e),
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Sqlite(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

/// `sqlite3_libversion_number()` of the linked (bundled) SQLite, e.g. 3051003.
pub fn sqlite_version_number() -> i32 {
    rusqlite::version_number()
}

/// Refuse when the linked SQLite is older than `min`.
pub fn check_floor(min: i32) -> Result<()> {
    let have = sqlite_version_number();
    if have < min {
        return Err(Error::SqliteTooOld { have, need: min });
    }
    Ok(())
}

/// One value of the `meta(key, value)` table, `None` when the key (or the table) is absent.
pub fn meta(conn: &Connection, key: &str) -> Result<Option<String>> {
    match conn.query_row("select value from meta where key = ?1", [key], |r| r.get(0)) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(rusqlite::Error::SqliteFailure(_, Some(m))) if m.starts_with("no such table") => {
            Ok(None)
        }
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn floor_check() {
        assert!(crate::check_floor(3051003).is_ok());
        assert!(crate::check_floor(99999999).is_err());
    }
}
