//! Migrations as data: `(version, sql)` batches applied in order under `BEGIN IMMEDIATE`, the version in `meta.schema`.

use crate::{Error, Result, meta};
use rusqlite::Connection;

/// `meta.schema` as a number; 0 for a file without one.
pub(crate) fn schema(conn: &Connection) -> Result<u32> {
    Ok(meta(conn, "schema")?
        .and_then(|s| s.parse().ok())
        .unwrap_or(0))
}

pub(crate) fn run(conn: &Connection, migrations: &[(u32, &str)]) -> Result<()> {
    let known = migrations.last().map_or(0, |m| m.0);
    conn.execute_batch("BEGIN IMMEDIATE")?;
    let applied = (|| -> Result<()> {
        conn.execute_batch(
            "create table if not exists meta(key text primary key, value text not null)",
        )?;
        let found = schema(conn)?;
        if found > known {
            return Err(Error::NewerSchema { found, known });
        }
        for (version, sql) in migrations.iter().filter(|m| m.0 > found) {
            conn.execute_batch(sql)?;
            conn.execute(
                "insert or replace into meta(key, value) values ('schema', ?1)",
                [version.to_string()],
            )?;
        }
        Ok(())
    })();
    match applied {
        Ok(()) => Ok(conn.execute_batch("COMMIT")?),
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::{Error, Mode, StoreSpec, meta, open_readonly, open_store};
    use std::os::unix::fs::PermissionsExt;

    const M: &[(u32, &str)] = &[(1, "create table a(x);"), (2, "create table b(y);")];

    fn spec(path: &std::path::Path, migrations: &'static [(u32, &'static str)]) -> StoreSpec {
        StoreSpec {
            path: path.to_path_buf(),
            mode: Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: true,
            },
            migrations,
        }
    }

    #[test]
    fn a_new_file_is_0600_wal_and_migrated() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("runtime.db");
        let conn = open_store(&spec(&file, M)).unwrap();
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let mode: String = conn
            .pragma_query_value(None, "journal_mode", |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        assert_eq!(meta(&conn, "schema").unwrap().as_deref(), Some("2"));
        conn.execute("insert into b values (1)", []).unwrap();
        // Opening again migrates nothing and keeps the data.
        drop(conn);
        let again = open_store(&spec(&file, M)).unwrap();
        assert_eq!(meta(&again, "schema").unwrap().as_deref(), Some("2"));
        let n: i64 = again
            .query_row("select count(*) from b", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn a_newer_file_is_refused_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("runtime.db");
        drop(open_store(&spec(&file, M)).unwrap());
        {
            let c = rusqlite::Connection::open(&file).unwrap();
            c.execute("update meta set value = '9' where key = 'schema'", [])
                .unwrap();
        }
        let before = std::fs::read(&file).unwrap();
        match open_store(&spec(&file, M)) {
            Err(Error::NewerSchema { found: 9, known: 2 }) => {}
            other => panic!("expected NewerSchema, got {:?}", other.map(|_| ())),
        }
        assert_eq!(std::fs::read(&file).unwrap(), before);
        // A read-only store of the same file still reads it.
        assert_eq!(
            meta(&open_readonly(&file).unwrap(), "schema")
                .unwrap()
                .as_deref(),
            Some("9")
        );
    }
}
