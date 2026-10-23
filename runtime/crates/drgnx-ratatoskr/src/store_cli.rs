//! `ratatoskr store`: the two commands around the move of work.db to schema 7 (Urdr Task 11, storage §9 step 5).
//!
//! - `store migrate-check --db FILE --scratch DIR [--json]` migrates FILE, a copy, in place with the hub's own code
//!   (`norn::migrate7::check_copy`), its pre-migration copy in DIR, and prints the report: rows in and out per table,
//!   links per old and new kind, denied counts, entities without a project, transactions and the time.  Never a
//!   title, a body or a path of the user's content.  It refuses the configured live `work.db` (by path or by inode),
//!   and any file in the data dir of a hub that holds its lock.
//! - `store restore-pre7 [--yes]` puts the newest pre-migration copy (`<data>/backup/work-pre7-*.db`) that checks
//!   back as `work.db`, while no hub runs.  The copy is made and checked first (at a temporary name in the data dir);
//!   only then are `work.db`, `work.db-wal` and `work.db-shm` moved aside together, to `work.db.schema7-<unix>`,
//!   `…-wal` and `…-shm`, so no WAL of schema 7 is ever beside the restored file.  A copy that fails its check is
//!   skipped (an older one is tried); the backups themselves are never changed.  Without `--yes` it says what it
//!   would do and changes nothing.

use crate::lock::{self, Holder};
use runstav::paths::{self, Env};
use serde_json::Value;
use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// The live work.db's three files, in the order they are moved aside.
const SUFFIXES: [&str; 3] = ["", "-wal", "-shm"];

/// `store migrate-check`: 0 when the copy migrated, 1 otherwise (the reason on stderr).
pub fn migrate_check(env: &Env, db: &Path, scratch: &Path, json: bool) -> i32 {
    match check(env, db, scratch) {
        Ok(report) => {
            if json {
                println!("{report}");
            } else {
                print!("{}", text(&report));
            }
            0
        }
        Err(e) => {
            eprintln!("ratatoskr store migrate-check: {e}");
            1
        }
    }
}

/// The report of the migrated copy, as `meta.migrate-7` holds it.
fn check(env: &Env, db: &Path, scratch: &Path) -> Result<Value, String> {
    let data = paths::data_dir(env);
    let live = data.join("work.db");
    if same_file(db, &live) {
        return Err(format!(
            "{} is the live work.db: migrate-check moves a copy",
            db.display()
        ));
    }
    let parent = db
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    if same_file(parent, &data) && hub_running(env)? {
        return Err(format!(
            "{} is in the data dir of a running hub: copy it elsewhere first",
            db.display()
        ));
    }
    let home = home(env)?;
    let opts = norn::migrate7::MigrateOpts {
        backup_dir: scratch.to_path_buf(),
        home,
        config_dir: paths::config_dir(env),
    };
    norn::migrate7::check_copy(db, &opts).map(|r| r.to_json())
}

/// The report as lines: counts only.
fn text(report: &Value) -> String {
    let mut out = String::new();
    let n = |v: &Value| v.as_u64().unwrap_or(0);
    out.push_str("table: rows in -> rows out\n");
    if let Some(tables) = report["tables"].as_object() {
        for (name, io) in tables {
            out.push_str(&format!("  {name}: {} -> {}\n", n(&io[0]), n(&io[1])));
        }
    }
    out.push_str("links: old kind -> new kind\n");
    if let Some(links) = report["links"].as_object() {
        for (label, count) in links {
            out.push_str(&format!("  {label}: {}\n", n(count)));
        }
    }
    let d = &report["denied"];
    out.push_str(&format!(
        "denied: {} nodes, {} edges, {} files\n",
        n(&d["nodes"]),
        n(&d["edges"]),
        n(&d["files"])
    ));
    out.push_str(&format!(
        "without a project: {}\nretyped: {}\nduplicates: {}\ntransactions: {}\ntime: {:.0} ms\n",
        n(&report["no_project"]),
        n(&report["retyped"]),
        n(&report["duplicates"]),
        n(&report["txs"]),
        report["ms"].as_f64().unwrap_or(0.0)
    ));
    out
}

/// `store restore-pre7`: 0 when a copy was put back (or, without `--yes`, would be), 1 otherwise.
pub fn restore_pre7(env: &Env, yes: bool) -> i32 {
    match restore(env, yes) {
        Ok(said) => {
            print!("{said}");
            0
        }
        Err(e) => {
            eprintln!("ratatoskr store restore-pre7: {e}");
            1
        }
    }
}

/// What restore-pre7 did (or would do), as lines.
fn restore(env: &Env, yes: bool) -> Result<String, String> {
    if hub_running(env)? {
        return Err("the hub is running: stop it first (drgnx hub stop)".into());
    }
    let data = paths::data_dir(env);
    let copies = pre7_copies(&data.join("backup"))?;
    if copies.is_empty() {
        return Err(format!(
            "no work-pre7-*.db in {}",
            data.join("backup").display()
        ));
    }
    let live = data.join("work.db");
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let aside = aside_name(&data, stamp);
    let present: Vec<&str> = SUFFIXES
        .into_iter()
        .filter(|s| fs::symlink_metadata(with_suffix(&live, s)).is_ok())
        .collect();
    if !yes {
        let mut said = format!("would put back {} as work.db\n", file_name(&copies[0]));
        for s in &present {
            said.push_str(&format!(
                "would move work.db{s} to {}{s}\n",
                file_name(&aside)
            ));
        }
        said.push_str("nothing changed: run again with --yes\n");
        return Ok(said);
    }
    let mut said = String::new();
    // the copy first, checked at a name of its own: a failure leaves work.db as it was
    let tmp = data.join(format!("work.db.restore-{stamp}.tmp"));
    let mut put = None;
    for copy in &copies {
        match copy_checked(copy, &tmp) {
            Ok(()) => {
                put = Some(copy);
                break;
            }
            Err(e) => said.push_str(&format!("skipped {}: {e}\n", file_name(copy))),
        }
    }
    let Some(copy) = put else {
        return Err(format!("{said}no pre-migration copy checks"));
    };
    for s in &present {
        let to = with_suffix(&aside, s);
        fs::rename(with_suffix(&live, s), &to).map_err(|e| {
            format!(
                "cannot move work.db{s} aside: {e} (the copy is {})",
                tmp.display()
            )
        })?;
        said.push_str(&format!("moved work.db{s} to {}\n", file_name(&to)));
    }
    for s in &SUFFIXES[1..] {
        if fs::symlink_metadata(with_suffix(&live, s)).is_ok() {
            return Err(format!(
                "work.db{s} came back meanwhile: is a hub starting? (the copy is {})",
                tmp.display()
            ));
        }
    }
    fs::rename(&tmp, &live).map_err(|e| format!("cannot put the copy in place: {e}"))?;
    fs::File::open(&data)
        .and_then(|d| d.sync_all())
        .map_err(|e| format!("{}: {e}", data.display()))?;
    said.push_str(&format!("put back {} as work.db\n", file_name(copy)));
    Ok(said)
}

/// The `work-pre7-*.db` files in DIR, newest first (by modification time, then by name).
fn pre7_copies(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match fs::read_dir(dir) {
        Ok(d) => d,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    let mut copies: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("work-pre7-") && name.ends_with(".db")
        })
        .filter_map(|e| {
            let meta = e.metadata().ok().filter(|m| m.is_file())?;
            Some((meta.modified().ok()?, e.path()))
        })
        .collect();
    copies.sort();
    copies.reverse();
    Ok(copies.into_iter().map(|(_, p)| p).collect())
}

/// FROM copied to TO (made 0600, never over a file), synced, and checked (`urdr::graph::backup::check`, which
/// deletes TO when it fails); FROM is only read.
fn copy_checked(from: &Path, to: &Path) -> Result<(), String> {
    let mut src = fs::File::open(from).map_err(|e| e.to_string())?;
    let mut dst = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)
        .map_err(|e| format!("{}: {e}", to.display()))?;
    let copied = io::copy(&mut src, &mut dst).and_then(|_| dst.sync_all());
    drop(dst);
    if let Err(e) = copied {
        let _ = fs::remove_file(to);
        return Err(e.to_string());
    }
    let report = urdr::graph::backup::check(to);
    if !report.ok {
        return Err(report.error.unwrap_or_else(|| "the check failed".into()));
    }
    Ok(())
}

/// `<data>/work.db.schema7-<stamp>`, or `…-<stamp>-K` when a file of that name (or its `-wal`/`-shm`) is there.
fn aside_name(data: &Path, stamp: u64) -> PathBuf {
    let taken = |p: &Path| {
        SUFFIXES
            .iter()
            .any(|s| fs::symlink_metadata(with_suffix(p, s)).is_ok())
    };
    let first = data.join(format!("work.db.schema7-{stamp}"));
    if !taken(&first) {
        return first;
    }
    (1..)
        .map(|k| data.join(format!("work.db.schema7-{stamp}-{k}")))
        .find(|p| !taken(p))
        .unwrap_or(first)
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut p = path.as_os_str().to_owned();
    p.push(suffix);
    PathBuf::from(p)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

/// A and B name one file (or directory): the same path once resolved, or the same device and inode.
fn same_file(a: &Path, b: &Path) -> bool {
    if matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(x), Ok(y)) if x == y) {
        return true;
    }
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

/// A hub (a Ratatoskr, or a Lisp hub whose lock is respected) holds this data dir's lock.
fn hub_running(env: &Env) -> Result<bool, String> {
    let path = paths::lock_path(&paths::socket_path(env));
    match lock::holder(&path, &lock::System) {
        Ok(Holder::Nobody) => Ok(false),
        Ok(_) => Ok(true),
        Err(e) => Err(format!("cannot look at {}: {e}", path.display())),
    }
}

/// `HOME`, which the personal-notes deny-list is built from: absolute, or the command refuses.
fn home(env: &Env) -> Result<PathBuf, String> {
    env.vars
        .get("HOME")
        .filter(|h| h.starts_with('/'))
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set to an absolute path: the deny-list needs it".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DDL6: &str = include_str!("../../../../test/fixtures/work-db-6.sql");
    const SHAPED: &str = include_str!("../../../../test/fixtures/work-db-6-shaped.sql");

    /// A temporary HOME with its data, config and runtime dirs (never the user's).
    struct Root {
        _dir: tempfile::TempDir,
        home: PathBuf,
        data: PathBuf,
        env: Env,
    }

    fn root() -> Root {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let data = dir.path().join("data");
        let run = dir.path().join("run");
        for d in [&home, &data, &run] {
            fs::create_dir_all(d).unwrap();
        }
        let s = |p: &Path| p.to_str().unwrap().to_string();
        let (h, da, c, st, r) = (
            s(&home),
            s(&data),
            s(&dir.path().join("config")),
            s(&dir.path().join("state")),
            s(&run),
        );
        let env = Env::new(
            &[
                ("HOME", &h),
                ("DRGNX_DATA_DIR", &da),
                ("DRGNX_CONFIG_DIR", &c),
                ("XDG_STATE_HOME", &st),
                ("XDG_RUNTIME_DIR", &r),
            ],
            rustix::process::geteuid().as_raw(),
        );
        Root {
            _dir: dir,
            home,
            data,
            env,
        }
    }

    /// A schema-6 file at PATH from the shaped fixture.
    fn schema_6(path: &Path, home: &Path) {
        let c = urdr::Connection::open(path).unwrap();
        c.execute_batch(DDL6).unwrap();
        c.execute_batch(&SHAPED.replace("$HOME", home.to_str().unwrap()))
            .unwrap();
    }

    fn schema_of(path: &Path) -> String {
        let c = urdr::Connection::open(path).unwrap();
        urdr::meta(&c, "schema").unwrap().unwrap_or_default()
    }

    #[test]
    fn migrate_check_migrates_a_copy_and_prints_no_content() {
        let r = root();
        let copy = r.home.join("copy").join("work.db");
        fs::create_dir_all(copy.parent().unwrap()).unwrap();
        schema_6(&copy, &r.home);
        let scratch = r.home.join("copy").join("scratch");
        let report = check(&r.env, &copy, &scratch).unwrap();
        assert_eq!(schema_of(&copy), "7");
        assert_eq!(report["tables"]["node"], serde_json::json!([970, 967]));
        assert_eq!(report["denied"]["nodes"], 3);
        let names: Vec<_> = fs::read_dir(&scratch)
            .unwrap()
            .flatten()
            .map(|e| file_name(&e.path()))
            .collect();
        assert_eq!(names.len(), 1, "{names:?}");
        assert!(names[0].starts_with("work-pre7-"));
        // counts only: no title, body, project or content path, in either form
        let home = r.home.to_str().unwrap();
        for out in [report.to_string(), text(&report)] {
            for content in ["Spec ", "Plan ", "CANARY", "/w/alpha", "/org/", "notes.org"] {
                assert!(!out.contains(content), "{content:?} in {out}");
            }
            assert!(
                !out.contains(&format!("{home}/w")),
                "a project path in {out}"
            );
        }
        assert!(text(&report).contains("node: 970 -> 967"));
        // a copy that is already schema 7 is refused, and left as it is
        let again = check(&r.env, &copy, &scratch).unwrap_err();
        assert!(again.contains("schema 7"), "{again}");
    }

    #[test]
    fn migrate_check_refuses_the_live_work_db() {
        let r = root();
        let live = r.data.join("work.db");
        schema_6(&live, &r.home);
        let e = check(&r.env, &live, &r.home.join("scratch")).unwrap_err();
        assert!(e.contains("live work.db"), "{e}");
        // a hard link to it is the same file
        let link = r.home.join("link.db");
        fs::hard_link(&live, &link).unwrap();
        let e = check(&r.env, &link, &r.home.join("scratch")).unwrap_err();
        assert!(e.contains("live work.db"), "{e}");
        // another file in the data dir of a running hub
        let other = r.data.join("other.db");
        schema_6(&other, &r.home);
        let socket = paths::socket_path(&r.env);
        paths::private_dir(socket.parent().unwrap()).unwrap();
        let held = lock::acquire(&paths::lock_path(&socket), &lock::System).unwrap();
        let e = check(&r.env, &other, &r.home.join("scratch")).unwrap_err();
        assert!(e.contains("running hub"), "{e}");
        drop(held);
        assert_eq!(schema_of(&live), "6");
        assert_eq!(schema_of(&other), "6");
        assert!(!r.home.join("scratch").exists());
    }

    #[test]
    fn restore_pre7_moves_wal_and_shm_together() {
        let r = root();
        let live = r.data.join("work.db");
        schema_6(&live, &r.home);
        // the hub's migration: a checked copy in <data>/backup, then schema 7 with its WAL open
        let opts = norn::migrate7::MigrateOpts {
            backup_dir: r.data.join("backup"),
            home: r.home.clone(),
            config_dir: r.data.join("config"),
        };
        let mut c = urdr::Connection::open(&live).unwrap();
        c.pragma_update(None, "journal_mode", "wal").unwrap();
        norn::migrate7::run(&mut c, &live, &opts).unwrap();
        c.execute(
            "insert into event (at, kind, summary) values (2000000000, 'note', 'after')",
            [],
        )
        .unwrap();
        assert_eq!(schema_of(&live), "7");
        assert!(with_suffix(&live, "-wal").exists());
        assert!(with_suffix(&live, "-shm").exists());
        // a broken newer copy is skipped, and kept as it was
        let broken = r.data.join("backup").join("work-pre7-9999999999.db");
        fs::write(&broken, b"not a database").unwrap();
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(60);
        fs::File::options()
            .write(true)
            .open(&broken)
            .unwrap()
            .set_modified(later)
            .unwrap();
        // a running hub refuses it
        let socket = paths::socket_path(&r.env);
        paths::private_dir(socket.parent().unwrap()).unwrap();
        let held = lock::acquire(&paths::lock_path(&socket), &lock::System).unwrap();
        let e = restore(&r.env, true).unwrap_err();
        assert!(e.contains("running"), "{e}");
        drop(held);
        // without --yes nothing changes
        let said = restore(&r.env, false).unwrap();
        assert!(said.contains("run again with --yes"), "{said}");
        assert_eq!(schema_of(&live), "7");
        drop(c);
        // the hub's connection closed: SQLite checkpoints and removes the WAL; open one again to leave them
        let c = urdr::Connection::open(&live).unwrap();
        c.execute(
            "insert into event (at, kind, summary) values (2000000001, 'note', 'held')",
            [],
        )
        .unwrap();
        assert!(with_suffix(&live, "-wal").exists());
        let said = restore(&r.env, true).unwrap();
        assert!(said.contains("skipped work-pre7-9999999999.db"), "{said}");
        assert!(said.contains("moved work.db-wal"), "{said}");
        assert!(said.contains("moved work.db-shm"), "{said}");
        assert_eq!(fs::read(&broken).unwrap(), b"not a database");
        // the restored file has no WAL or shm beside it, and is the fixture's schema 6
        assert!(!with_suffix(&live, "-wal").exists());
        assert!(!with_suffix(&live, "-shm").exists());
        assert_eq!(fs::metadata(&live).unwrap().mode() & 0o777, 0o600);
        let restored = urdr::Connection::open(&live).unwrap();
        assert_eq!(urdr::meta(&restored, "schema").unwrap().unwrap(), "6");
        let nodes: i64 = restored
            .query_row("select count(*) from node", [], |r| r.get(0))
            .unwrap();
        assert_eq!(nodes, 970);
        drop(restored);
        // the three files moved aside together, under one name
        let aside: Vec<String> = fs::read_dir(&r.data)
            .unwrap()
            .flatten()
            .map(|e| file_name(&e.path()))
            .filter(|n| n.starts_with("work.db.schema7-"))
            .collect();
        assert_eq!(aside.len(), 3, "{aside:?}");
        let base = aside.iter().min_by_key(|n| n.len()).unwrap();
        assert!(aside.contains(&format!("{base}-wal")));
        assert!(aside.contains(&format!("{base}-shm")));
        // what the schema-7 file held is still there, its WAL beside it
        drop(c);
        let kept = urdr::Connection::open(r.data.join(base)).unwrap();
        assert_eq!(urdr::meta(&kept, "schema").unwrap().unwrap(), "7");
        let held: i64 = kept
            .query_row(
                "select count(*) from event where summary = 'held'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(held, 1);
    }
}
