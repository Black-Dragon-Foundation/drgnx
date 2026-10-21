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
    let Mode::ReadWrite {
        file_mode,
        synchronous_full,
    } = spec.mode
    else {
        return open_readonly(&spec.path);
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
