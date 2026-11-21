//! A job's disk watch (the job helper's on Linux, job-exec's on a Mac): every [`EVERY`] it reads the runner folder's free space; below the floor (the larger
//! of 20 GB and 10 % of the folder's filesystem, `forseti`'s disk guard) the job that grew most since its start is
//! stopped with `kill_reason("infra: disk")`.
//!
//! Each running job's helper does the same sum over the runner's `jobs/` folder: a job's growth is its attempt
//! folder's size now less its size when its helper started (`disk-start`), over the attempts that have a start record
//! and no `result.json`. Only the helper of the job that grew most acts, so one job is stopped per reading, and every
//! helper agrees which (ties go to the first folder by name).

use crate::linux::jobexec::{self, KILL_REASON};
use crate::linux::probe::Probe;
use crate::linux::result::RESULT;
use forseti::classify::infra;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How often the watch reads the disk.
pub const EVERY: Duration = Duration::from_secs(10);
/// The attempt folder's size when its helper started, in bytes.
pub const DISK_START: &str = "disk-start";

/// The bytes of the regular files under DIR, never following a link.
pub fn size(dir: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(dir) else { return 0 };
    let mut n = 0;
    for e in rd.flatten() {
        let Ok(m) = fs::symlink_metadata(e.path()) else {
            continue;
        };
        if m.is_dir() {
            n += size(&e.path());
        } else if m.is_file() {
            n += m.len();
        }
    }
    n
}

/// How much the running attempt in DIR grew since its helper started; none for an attempt that has no start record
/// or has ended.
pub fn growth(dir: &Path) -> Option<u64> {
    if dir.join(RESULT).exists() {
        return None;
    }
    let start: u64 = fs::read_to_string(dir.join(DISK_START))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    Some(size(dir).saturating_sub(start))
}

/// The running attempt under `<root>/jobs/` that grew most.
pub fn grew_most(root: &Path) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(root.join("jobs"))
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    let mut best: Option<(u64, PathBuf)> = None;
    for d in dirs {
        if let Some(g) = growth(&d)
            && best.as_ref().is_none_or(|(b, _)| g > *b)
        {
            best = Some((g, d));
        }
    }
    best.map(|(_, d)| d)
}

/// The runner folder ROOT's filesystem is below its floor, as PROBE reads it (a test build's facts file included).
pub fn below_floor(probe: &Probe) -> io::Result<bool> {
    let d = probe.disk_seen()?;
    let l = forseti::Limits::for_profile(forseti::Profile::Dedicated, 0, 1);
    let pct = (d.size_gb * u64::from(l.disk_guard_pct)).div_ceil(100);
    Ok(d.free_gb < l.disk_guard_gb.max(pct))
}

/// One reading: below the floor, and DIR's job grew most, it is stopped (its reason first, then its container).
/// True when it stopped DIR's job.
pub fn check(probe: &Probe, root: &Path, dir: &Path, container: Option<&str>) -> bool {
    if dir.join(KILL_REASON).exists() || !below_floor(probe).unwrap_or(false) {
        return false;
    }
    let Some(most) = grew_most(root) else {
        return false;
    };
    let same = fs::canonicalize(&most).ok() == fs::canonicalize(dir).ok();
    if !same {
        return false;
    }
    let _ = jobexec::kill_reason(dir, &format!("infra: {}", infra::DISK));
    if let Some(name) = container {
        let _ = crate::linux::run::limited(
            Path::new("podman"),
            &["kill", name],
            &[],
            crate::linux::run::SYSTEMCTL_LIMIT,
        );
    }
    true
}

#[cfg(target_os = "linux")]
/// Starts the watch of the job in DIR under the runner folder ROOT: its start size recorded now, a reading every
/// [`EVERY`].
pub fn watch(root: PathBuf, dir: PathBuf, container: Option<String>) {
    let _ = fs::write(dir.join(DISK_START), size(&dir).to_string());
    std::thread::spawn(move || {
        let Ok(probe) = Probe::system("", "", "drgnx-runner", &root, forseti::Profile::Dedicated)
        else {
            return;
        };
        loop {
            std::thread::sleep(EVERY);
            if check(&probe, &root, &dir, container.as_deref()) {
                crate::helper::say(
                    &dir,
                    "below the disk floor, this job grew most: stopped (infra: disk)",
                );
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] The attempt that grew most since its start is the one picked; ended attempts and ones without a start
    /// record don't count.
    #[test]
    fn the_job_that_grew_most_is_picked() {
        let t = tempfile::tempdir().unwrap();
        let jobs = t.path().join("jobs");
        let mk = |n: &str, start: Option<u64>, add: usize| {
            let d = jobs.join(n);
            fs::create_dir_all(d.join("target")).unwrap();
            fs::write(d.join("target/out"), vec![1u8; add]).unwrap();
            if let Some(s) = start {
                fs::write(d.join(DISK_START), s.to_string()).unwrap();
            }
            d
        };
        let a = mk("a1.1", Some(0), 1000);
        let b = mk("b2.1", Some(0), 5000);
        mk("c3.1", None, 90_000);
        let ended = mk("d4.1", Some(0), 80_000);
        fs::write(ended.join(RESULT), "{}").unwrap();
        // b's start record counts against it; the record itself is in its size
        assert_eq!(growth(&a), Some(1000 + 1));
        assert_eq!(grew_most(t.path()), Some(b.clone()));
        fs::write(b.join(DISK_START), "4000").unwrap();
        assert_eq!(grew_most(t.path()), Some(b));
        fs::write(jobs.join("b2.1").join(DISK_START), "4999").unwrap();
        assert_eq!(grew_most(t.path()), Some(a));
    }
}
