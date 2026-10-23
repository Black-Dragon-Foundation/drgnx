//! Backups (Task 7; storage §8.1): `VACUUM INTO` from a read connection, an integrity check of the copy, rotation.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};

use super::pool::ReadPool;

/// What a backup or a check did, for the doctor.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub path: PathBuf,
    pub ok: bool,
    pub error: Option<String>,
    pub bytes: u64,
    pub ms: f64,
}

/// How many dated copies rotation keeps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Policy {
    pub daily: u32,
    /// The Sundays.
    pub weekly: u32,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            daily: 7,
            weekly: 4,
        }
    }
}

/// Make DIR (and its parents) if missing, and set DIR to 0700.
pub(crate) fn private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

/// DEST with `.tmp` appended to its file name.
pub(crate) fn tmp_of(dest: &Path) -> PathBuf {
    let mut name = dest.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    dest.with_file_name(name)
}

fn size(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |m| m.len())
}

fn report(path: PathBuf, started: Instant, result: Result<(), String>) -> Report {
    let ok = result.is_ok();
    Report {
        bytes: if ok { size(&path) } else { 0 },
        path,
        ok,
        error: result.err(),
        ms: started.elapsed().as_secs_f64() * 1000.0,
    }
}

/// `VACUUM INTO` DEST (through `DEST.tmp`, then renamed), from a pool connection. A copy already at DEST is replaced
/// only when the new one passed [`check`] (run on `DEST.tmp` before the rename); a failed check deletes the tmp and
/// leaves DEST as it was. DEST's directory is made 0700, the copy 0600.
pub async fn vacuum_into(pool: &ReadPool, dest: PathBuf) -> Report {
    vacuum_verified(pool, dest, check_inner).await
}

async fn vacuum_verified(
    pool: &ReadPool,
    dest: PathBuf,
    verify: fn(&Path) -> Result<(), String>,
) -> Report {
    let started = Instant::now();
    let target = dest.clone();
    let tmp = tmp_of(&dest);
    let done = pool
        .with(move |conn| -> Result<(), String> {
            if let Some(parent) = target.parent().filter(|p| !p.as_os_str().is_empty()) {
                private_dir(parent).map_err(|e| e.to_string())?;
            }
            match std::fs::remove_file(&tmp) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.to_string()),
            }
            let copied = conn
                .execute("VACUUM INTO ?1", [tmp.to_string_lossy().as_ref()])
                .map_err(|e| e.to_string())
                .and_then(|_| {
                    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
                        .map_err(|e| e.to_string())
                })
                .and_then(|_| verify(&tmp))
                .and_then(|_| std::fs::rename(&tmp, &target).map_err(|e| e.to_string()));
            if copied.is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
            copied
        })
        .await;
    let result = match done {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    };
    report(dest, started, result)
}

fn check_inner(dest: &Path) -> Result<(), String> {
    // Read-write on our own copy: FTS5's `integrity-check` is an INSERT, which a read-only connection refuses.
    let conn = Connection::open_with_flags(
        dest,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("pragma integrity_check")
        .map_err(|e| e.to_string())?;
    let lines: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string())?;
    if lines != ["ok"] {
        return Err(format!("integrity_check: {}", lines.join("; ")));
    }
    drop(stmt);
    conn.execute(
        "insert into entity_fts(entity_fts, rank) values('integrity-check', 0)",
        [],
    )
    .map_err(|e| format!("fts integrity-check: {e}"))?;
    Ok(())
}

/// `integrity_check` and the FTS index check of the copy DEST; a failed check deletes it (an older copy at another
/// name stays).
pub fn check(dest: &Path) -> Report {
    let started = Instant::now();
    let result = check_inner(dest);
    if result.is_err() {
        let _ = std::fs::remove_file(dest);
    }
    report(dest.to_path_buf(), started, result)
}

/// Days since 1970-01-01 of a civil date (Hinnant).
fn days(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `work-YYYYMMDD.db` → (date as a number, is a Sunday).
fn parse_name(name: &str) -> Option<(u32, bool)> {
    let digits = name.strip_prefix("work-")?.strip_suffix(".db")?;
    if digits.len() != 8 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u32 = digits.parse().ok()?;
    let (y, m, d) = (
        i64::from(n / 10_000),
        i64::from(n / 100 % 100),
        i64::from(n % 100),
    );
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // 1970-01-01 was a Thursday; 0 = Sunday.
    Some((n, (days(y, m, d) + 4).rem_euclid(7) == 0))
}

/// Keep POLICY's `work-YYYYMMDD.db` copies in DIR (made 0700), never touching `work-pre7-*.db`; the files removed.
/// Kept: the newest `daily` copies, and the newest `weekly` Sundays among the rest too.
pub fn rotate(dir: &Path, policy: Policy) -> std::io::Result<Vec<PathBuf>> {
    private_dir(dir)?;
    let mut copies: Vec<(u32, bool, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        if let Some((n, sunday)) = name.to_str().and_then(parse_name) {
            copies.push((n, sunday, entry.path()));
        }
    }
    copies.sort_by(|a, b| b.0.cmp(&a.0));
    let mut sundays = 0;
    let mut removed = Vec::new();
    for (i, (_, sunday, path)) in copies.iter().enumerate() {
        let mut keep = i < policy.daily as usize;
        if *sunday {
            if sundays < policy.weekly {
                keep = true;
            }
            sundays += 1;
        }
        if !keep {
            std::fs::remove_file(path)?;
            removed.push(path.clone());
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::tx::{Class, TxMeta};
    use crate::graph::writer::Writer;
    use crate::graph::writer::tests::{opts, rule};

    #[tokio::test]
    async fn vacuum_into_from_a_read_connection_under_writes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn(&path, opts(256, 1), rule()).unwrap();
        h.write(TxMeta::new("u", Class::User, "t"), |tx| {
            tx.sql().execute(
                "insert into t (v, tx) values (0, ?1)",
                rusqlite::params![tx.id()],
            )?;
            Ok(())
        })
        .await
        .unwrap();
        let pool = ReadPool::open(&path, 2);
        let writes = {
            let h = h.clone();
            tokio::spawn(async move {
                for i in 0..1_000i64 {
                    h.write(TxMeta::new("u", Class::User, "t"), move |tx| {
                        tx.sql().execute(
                            "insert into t (v, tx) values (?1, ?2)",
                            rusqlite::params![i, tx.id()],
                        )?;
                        Ok(())
                    })
                    .await
                    .unwrap();
                }
            })
        };
        let dest = dir.path().join("backup").join("work-20261023.db");
        let r = vacuum_into(&pool, dest.clone()).await;
        assert!(r.ok, "{r:?}");
        assert!(r.bytes > 0);
        writes.await.unwrap();
        let c = check(&dest);
        assert!(c.ok, "{c:?}");
        assert!(dest.exists());
        assert!(!tmp_of(&dest).exists());
        let mode = std::fs::metadata(dest.parent().unwrap())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o700);
        let copy = Connection::open(&dest).unwrap();
        let n: i64 = copy
            .query_row("select count(*) from t", [], |r| r.get(0))
            .unwrap();
        assert!((1..=1_001).contains(&n));
        drop(h);
        w.shutdown();
    }

    #[tokio::test]
    async fn a_failed_check_keeps_the_previous_copy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn(&path, opts(256, 1), rule()).unwrap();
        h.tick().await;
        let pool = ReadPool::open(&path, 1);
        let backups = dir.path().join("backup");
        let old = backups.join("work-20261022.db");
        let new = backups.join("work-20261023.db");
        assert!(vacuum_into(&pool, old.clone()).await.ok);
        assert!(check(&old).ok);
        assert!(vacuum_into(&pool, new.clone()).await.ok);
        // Damage the new copy: zero a run of pages after the header.
        {
            use std::io::{Seek, SeekFrom, Write};
            let mut f = std::fs::OpenOptions::new().write(true).open(&new).unwrap();
            f.seek(SeekFrom::Start(4096)).unwrap();
            f.write_all(&vec![0xAB; 8192]).unwrap();
        }
        let c = check(&new);
        assert!(!c.ok);
        assert!(c.error.is_some());
        assert!(!new.exists(), "the failed copy is deleted");
        assert!(old.exists(), "the previous copy stays");
        assert!(check(&old).ok);
        drop(h);
        w.shutdown();
    }

    #[tokio::test]
    async fn a_same_day_backup_that_fails_its_check_keeps_the_existing_copy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn(&path, opts(256, 1), rule()).unwrap();
        h.tick().await;
        let pool = ReadPool::open(&path, 1);
        let dest = dir.path().join("backup").join("work-20261023.db");
        assert!(vacuum_into(&pool, dest.clone()).await.ok);
        let before = std::fs::read(&dest).unwrap();
        let r = vacuum_verified(&pool, dest.clone(), |_| Err("bad copy".into())).await;
        assert!(!r.ok);
        assert_eq!(r.error.as_deref(), Some("bad copy"));
        assert_eq!(std::fs::read(&dest).unwrap(), before);
        assert!(!tmp_of(&dest).exists());
        drop(h);
        w.shutdown();
    }

    #[test]
    fn rotation_keeps_7_daily_4_weekly() {
        let dir = tempfile::tempdir().unwrap();
        let backups = dir.path().join("backup");
        std::fs::create_dir_all(&backups).unwrap();
        // 60 days from 2026-09-01 (a Tuesday) to 2026-10-30.
        let mut names = Vec::new();
        let mut d = days(2026, 9, 1);
        for _ in 0..60 {
            // back to civil: find y/m/d by search over month tables
            let (y, m, dd) = civil(d);
            names.push(format!("work-{y:04}{m:02}{dd:02}.db"));
            d += 1;
        }
        for n in &names {
            std::fs::write(backups.join(n), b"x").unwrap();
        }
        std::fs::write(backups.join("work-pre7-20261001.db"), b"x").unwrap();
        std::fs::write(backups.join("notes.txt"), b"x").unwrap();
        let removed = rotate(&backups, Policy::default()).unwrap();
        let mut left: Vec<String> = std::fs::read_dir(&backups)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        assert!(left.contains(&"work-pre7-20261001.db".to_string()));
        assert!(left.contains(&"notes.txt".to_string()));
        let dated: Vec<&String> = left.iter().filter(|n| parse_name(n).is_some()).collect();
        // The newest 7 days are all kept.
        for n in names.iter().rev().take(7) {
            assert!(left.contains(n), "{n} should stay");
        }
        // Plus the 4 newest Sundays; the dated set is exactly daily ∪ 4 Sundays.
        let sundays: Vec<&String> = names
            .iter()
            .rev()
            .filter(|n| parse_name(n).unwrap().1)
            .take(4)
            .collect();
        let mut want: Vec<&String> = names.iter().rev().take(7).chain(sundays).collect();
        want.sort();
        want.dedup();
        assert_eq!(dated, want);
        assert_eq!(removed.len(), 60 - want.len());
        // Idempotent.
        assert!(rotate(&backups, Policy::default()).unwrap().is_empty());
        let mode = std::fs::metadata(&backups).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }

    /// Days since the epoch back to (y, m, d) (Hinnant).
    fn civil(z: i64) -> (i64, i64, i64) {
        let z = z + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        (yoe + era * 400 + i64::from(m <= 2), m, d)
    }
}
