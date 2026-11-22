//! Opening connections: read-only (never writes, never checkpoints) and read-write (created, WAL, migrated).

use crate::{Error, Result, migrate};
use rusqlite::{Connection, OpenFlags};
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

const BUSY: Duration = Duration::from_secs(5);

pub enum Mode {
    ReadOnly,
    ReadWrite {
        file_mode: u32,
        synchronous_full: bool,
    },
    /// An existing file, read-write: never created, never migrated, journal mode untouched. A missing file is
    /// `Error::Missing`; a `meta.schema` other than `expect_schema` is `Error::Schema`, with nothing written.
    ReadWriteExisting {
        expect_schema: u32,
        synchronous_full: bool,
    },
}

pub struct StoreSpec {
    pub path: PathBuf,
    pub mode: Mode,
    /// `(version, sql)` in ascending version order; each batch runs once, under `BEGIN IMMEDIATE`.
    pub migrations: &'static [(u32, &'static str)],
}

/// Percent-encode what a SQLite URI filename treats specially.
fn uri_path(path: &Path) -> String {
    let mut out = String::from("file:");
    for c in path.to_string_lossy().chars() {
        match c {
            '%' | '?' | '#' => out.push_str(&format!("%{:02X}", c as u32)),
            _ => out.push(c),
        }
    }
    out.push_str("?mode=ro");
    out
}

/// A read-only connection (`file:PATH?mode=ro`). Closing it last never checkpoints the WAL.
pub fn open_readonly(path: &Path) -> Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_URI
        | OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(uri_path(path), flags)?;
    conn.busy_timeout(BUSY)?;
    Ok(conn)
}

/// Open per `spec`: a read-only connection, or a read-write one (file created with `file_mode`, WAL, migrated).
pub fn open_store(spec: &StoreSpec) -> Result<Connection> {
    let (file_mode, synchronous_full) = match spec.mode {
        Mode::ReadOnly => return open_readonly(&spec.path),
        Mode::ReadWriteExisting {
            expect_schema,
            synchronous_full,
        } => return open_existing(&spec.path, expect_schema, synchronous_full),
        Mode::ReadWrite {
            file_mode,
            synchronous_full,
        } => (file_mode, synchronous_full),
    };
    let known = spec.migrations.last().map_or(0, |m| m.0);
    // An existing file is judged read-only first, so a newer one is refused without a byte written.
    if spec.path.exists() {
        let found = migrate::schema(&open_readonly(&spec.path)?)?;
        if found > known {
            return Err(Error::NewerSchema { found, known });
        }
    } else {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(file_mode)
            .open(&spec.path)
        {
            Ok(f) => f.set_permissions(std::fs::Permissions::from_mode(file_mode))?,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(&spec.path, flags)?;
    conn.busy_timeout(BUSY)?;
    conn.pragma_update(None, "journal_mode", "wal")?;
    conn.pragma_update(
        None,
        "synchronous",
        if synchronous_full { "FULL" } else { "NORMAL" },
    )?;
    migrate::run(&conn, spec.migrations)?;
    Ok(conn)
}

/// An existing file, read-write, of exactly schema `expect`. Nothing is created, migrated or written: the schema is
/// read first, and a mismatch closes the connection untouched.
fn open_existing(path: &Path, expect: u32, synchronous_full: bool) -> Result<Connection> {
    // No SQLITE_OPEN_CREATE: a file that vanishes between the check and the open is `Missing` too.
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let missing = |e: rusqlite::Error| match e {
        rusqlite::Error::SqliteFailure(f, _) if f.code == rusqlite::ErrorCode::CannotOpen => {
            if path.exists() {
                Error::Sqlite(e)
            } else {
                Error::Missing
            }
        }
        e => Error::Sqlite(e),
    };
    if !path.exists() {
        return Err(Error::Missing);
    }
    let conn = Connection::open_with_flags(path, flags).map_err(missing)?;
    conn.busy_timeout(BUSY)?;
    let found = migrate::schema(&conn)?;
    if found != expect {
        return Err(Error::Schema { found });
    }
    conn.pragma_update(
        None,
        "synchronous",
        if synchronous_full { "FULL" } else { "NORMAL" },
    )?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(path: PathBuf, expect_schema: u32) -> StoreSpec {
        StoreSpec {
            path,
            mode: Mode::ReadWriteExisting {
                expect_schema,
                synchronous_full: false,
            },
            migrations: &[],
        }
    }

    #[test]
    fn read_write_existing_never_creates_or_migrates() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        // Missing: refused, and nothing is created.
        assert!(matches!(
            open_store(&spec(file.clone(), 6)),
            Err(Error::Missing)
        ));
        assert!(!file.exists());
        // Schema 5: refused, bytes unchanged.
        {
            let c = Connection::open(&file).unwrap();
            c.execute_batch(
                "create table meta(key text primary key, value text);
                 insert into meta values ('schema', '5');",
            )
            .unwrap();
        }
        let before = std::fs::read(&file).unwrap();
        assert!(matches!(
            open_store(&spec(file.clone(), 6)),
            Err(Error::Schema { found: 5 })
        ));
        assert_eq!(std::fs::read(&file).unwrap(), before);
        // Schema 6: opens read-write, and the data is writable.
        Connection::open(&file)
            .unwrap()
            .execute("update meta set value = '6' where key = 'schema'", [])
            .unwrap();
        let conn = open_store(&spec(file, 6)).unwrap();
        conn.execute("insert into meta values ('x', 'y')", [])
            .unwrap();
    }
}
