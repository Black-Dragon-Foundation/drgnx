//! urdr: a small SQLite store.
//!
//! One thread owns the connection(s) and runs closures sent over a bounded channel, so SQLite never runs on an async
//! worker (`thread`). Read-only connections never checkpoint (`open`). Schema migrations are data (`migrate`). The
//! public API carries no application types.
//!
//! [`graph`] is the graph store of `work.db` schema 7 (docs/develop/store.md). The graph layer is generic: kinds, link
//! names and policy are the caller's.

pub mod graph;
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
    /// `Mode::ReadWriteExisting`: the file does not exist.
    Missing,
    /// `Mode::ReadWriteExisting`: `meta.schema` is not the expected one; nothing was written.
    Schema {
        found: u32,
    },
    /// A write closure asked for a rollback with an error of its own, which the caller keeps.
    Aborted,
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
            Error::Missing => write!(f, "the database file does not exist"),
            Error::Schema { found } => {
                write!(f, "the database is schema {found}, not the expected one")
            }
            Error::Aborted => write!(f, "the write was rolled back"),
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

/// SQLite's own error type, for callers that convert it (`From<SqliteError>`).
pub use rusqlite::Error as SqliteError;

/// Whether `e` is SQLite saying the database is busy or locked (another writer held it past the busy timeout).
pub fn is_busy(e: &Error) -> bool {
    matches!(
        e,
        Error::Sqlite(rusqlite::Error::SqliteFailure(f, _))
            if matches!(f.code, rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked)
    )
}

/// `sqlite3_libversion_number()` of the linked (bundled) SQLite, e.g. 3051003.
pub fn sqlite_version_number() -> i32 {
    rusqlite::version_number()
}

/// Whether SQLite version number N (`sqlite3_libversion_number()`) has the WAL-reset corruption fix: 3.51.3,
/// 3.50.7 and 3.44.6 carry it, as does every release after 3.51.
pub fn wal_reset_fixed(n: i32) -> bool {
    let (minor, patch) = (n / 1000 % 1000, n % 1000);
    n / 1_000_000 > 3
        || (n / 1_000_000 == 3
            && match minor {
                44 => patch >= 6,
                50 => patch >= 7,
                51 => patch >= 3,
                m => m > 51,
            })
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
    fn the_wal_reset_fix_is_judged_by_release() {
        for (n, fixed) in [
            (3_051_002, false),
            (3_051_003, true),
            (3_050_006, false),
            (3_050_007, true),
            (3_044_005, false),
            (3_044_006, true),
            (3_045_000, false),
            (3_053_002, true),
        ] {
            assert_eq!(crate::wal_reset_fixed(n), fixed, "{n}");
        }
        assert!(crate::wal_reset_fixed(crate::sqlite_version_number()));
    }

    #[test]
    fn floor_check() {
        assert!(crate::check_floor(3051003).is_ok());
        assert!(crate::check_floor(99999999).is_err());
    }
}
