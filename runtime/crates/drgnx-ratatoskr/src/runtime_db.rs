//! `<state>/hub/runtime.db`: the hub's own recovery state (design 3.3), through urdr (0600, WAL, `synchronous=FULL`).
//! Phase 1 keeps nothing in it that outlives a hub, so a file of a newer schema (left by a newer binary before an
//! `update --back`) is moved aside, with its `-wal` and `-shm`, as `runtime.db.newer-N-UNIXTIME`, and a new one made.

use std::path::Path;

/// The schema, as data.
pub const MIGRATIONS: &[(u32, &str)] = &[(
    1,
    "create table proc(id integer primary key, purpose text not null, pid integer, start_time integer, \
     pgid integer, boot_id text, at real);",
)];

/// Open (or make) `runtime.db` in HUB_DIR on its own store thread.
pub fn open(hub_dir: &Path) -> Result<(urdr::Store, urdr::Handle), String> {
    let path = hub_dir.join("runtime.db");
    let spec = || urdr::StoreSpec {
        path: path.clone(),
        mode: urdr::Mode::ReadWrite {
            file_mode: 0o600,
            synchronous_full: true,
        },
        migrations: MIGRATIONS,
    };
    let fail = |e: urdr::Error| format!("cannot open {}: {e}", path.display());
    match urdr::Store::spawn(spec()) {
        Err(urdr::Error::NewerSchema { found, .. }) => {
            let at = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let aside = hub_dir.join(format!("runtime.db.newer-{found}-{at}"));
            std::fs::rename(&path, &aside)
                .map_err(|e| format!("cannot move {} aside: {e}", path.display()))?;
            for ext in ["-wal", "-shm"] {
                let from = hub_dir.join(format!("runtime.db{ext}"));
                let to = hub_dir.join(format!("runtime.db.newer-{found}-{at}{ext}"));
                match std::fs::rename(&from, &to) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                        return Err(format!("cannot move {} aside: {e}", from.display()));
                    }
                    _ => {}
                }
            }
            tracing::warn!(
                schema = found,
                "runtime.db is of a newer schema (a newer Ratatoskr ran here): moved aside as {}",
                aside.display()
            );
            urdr::Store::spawn(spec()).map_err(fail)
        }
        other => other.map_err(fail),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn a_newer_file_is_moved_aside_and_a_new_one_made() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("runtime.db");
        {
            let c = rusqlite_like(&file);
            c.execute_batch(
                "create table meta(key text primary key, value text not null);
                 insert into meta values ('schema', '99');
                 create table future(x);",
            )
            .unwrap();
        }
        let (store, _h) = open(dir.path()).unwrap();
        store.shutdown();
        let names: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            names.iter().any(|n| n.starts_with("runtime.db.newer-99-")),
            "{names:?}"
        );
        let fresh = urdr::open_readonly(&file).unwrap();
        assert_eq!(urdr::meta(&fresh, "schema").unwrap().as_deref(), Some("1"));
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // the proc table is there
        fresh
            .query_row("select count(*) from proc", [], |r| r.get::<_, i64>(0))
            .unwrap();
    }

    fn rusqlite_like(path: &Path) -> urdr::Connection {
        urdr::Connection::open(path).unwrap()
    }
}
