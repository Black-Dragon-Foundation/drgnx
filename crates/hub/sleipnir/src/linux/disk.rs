//! A job's disk watch (the job helper's on Linux, job-exec's on a Mac): every [`EVERY`] it reads the runner folder's
//! free space; below the stop floor (§4.8's `stop_below_gb`, 20 GB: `forseti::disk::DiskRules`) the job that grew most
//! since its start is stopped with `kill_reason("infra: disk")`.
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
    let start: u64 = crate::fsio::read_to_string(dir.join(DISK_START))
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

/// The runner folder ROOT's filesystem is below the stop floor (§4.8's `stop_below_gb`, 20 GB), as PROBE reads it (a
/// test build's facts file included).
pub fn below_floor(probe: &Probe) -> io::Result<bool> {
    let d = probe.disk_seen()?;
    Ok(d.free_gb < forseti::disk::DiskRules::standard().stop_below_gb)
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
    // the job is going down either way: a reason or a kill that did not take is only worth a line
    if let Err(e) = jobexec::kill_reason(dir, &format!("infra: {}", infra::DISK)) {
        tracing::warn!(error = %e, "the disk watch could not record its reason");
    }
    if let Some(name) = container
        && let Err(e) = crate::linux::run::limited(
            Path::new("podman"),
            &["kill", name],
            &[],
            crate::linux::run::SYSTEMCTL_LIMIT,
        )
    {
        tracing::warn!(error = %e, "the disk watch could not kill the container");
    }
    true
}

#[cfg(target_os = "linux")]
/// Starts the watch of the job in DIR under the runner folder ROOT: its start size recorded now, a reading every
/// [`EVERY`].
pub fn watch(root: PathBuf, dir: PathBuf, container: Option<String>) {
    if let Err(e) = crate::fsio::write(dir.join(DISK_START), size(&dir).to_string()) {
        tracing::warn!(error = %e, "the disk watch could not record its start size");
    }
    let watch = saman::spawn_thread("sleipnir-disk-watch", move || {
        let Ok(probe) = Probe::system("", "", "drgnx-runner", &root, forseti::Profile::Dedicated)
        else {
            return;
        };
        loop {
            stund::sleep_blocking(EVERY);
            if check(&probe, &root, &dir, container.as_deref()) {
                crate::helper::say(
                    &dir,
                    "below the disk floor, this job grew most: stopped (infra: disk)",
                );
            }
        }
    });
    if let Err(e) = watch {
        tracing::warn!(error = %e, "the disk watch did not start");
    }
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
            crate::fsio::write(d.join("target/out"), vec![1u8; add]).unwrap();
            if let Some(s) = start {
                crate::fsio::write(d.join(DISK_START), s.to_string()).unwrap();
            }
            d
        };
        let a = mk("a1.1", Some(0), 1000);
        let b = mk("b2.1", Some(0), 5000);
        mk("c3.1", None, 90_000);
        let ended = mk("d4.1", Some(0), 80_000);
        crate::fsio::write(ended.join(RESULT), "{}").unwrap();
        // b's start record counts against it; the record itself is in its size
        assert_eq!(growth(&a), Some(1000 + 1));
        assert_eq!(grew_most(t.path()), Some(b.clone()));
        crate::fsio::write(b.join(DISK_START), "4000").unwrap();
        assert_eq!(grew_most(t.path()), Some(b));
        crate::fsio::write(jobs.join("b2.1").join(DISK_START), "4999").unwrap();
        assert_eq!(grew_most(t.path()), Some(a));
    }

    /// [D] §4.8: below the stop floor (20 GB free; the runner folder's facts file sets the disk) the job that grew most
    /// is stopped with `infra: disk`, the others are not; at 21 GB free nothing is stopped.
    #[cfg(feature = "test-hooks")]
    #[test]
    fn below_the_stop_floor_the_job_that_grew_most_is_stopped_as_infra_disk() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        let probe = Probe {
            name: "runner".into(),
            proc_root: root.join("proc"),
            sys_root: root.join("sys"),
            manager: root.join("manager"),
            runtime_dir: root.join("run"),
            folder: root.to_path_buf(),
            slice_root: "t".into(),
            scheduler: "drgnx-hubA".into(),
            profile: forseti::Profile::Dedicated,
        };
        let mk = |n: &str, add: usize| {
            let d = root.join("jobs").join(n);
            fs::create_dir_all(&d).unwrap();
            crate::fsio::write(d.join(DISK_START), "0").unwrap();
            crate::fsio::write(d.join("out"), vec![1u8; add]).unwrap();
            d
        };
        let small = mk("a1.1", 10);
        let big = mk("b2.1", 9000);
        let free = |gb: u64| {
            crate::fsio::write(
                root.join(crate::linux::probe::TEST_MACHINE),
                format!(r#"{{"disk_free_gb": {gb}, "disk_total_gb": 1000}}"#),
            )
            .unwrap()
        };
        free(21);
        assert!(!check(&probe, root, &big, None), "above the floor");
        assert!(!big.join(KILL_REASON).exists());
        free(19);
        assert!(
            !check(&probe, root, &small, None),
            "not the one that grew most"
        );
        assert!(check(&probe, root, &big, None));
        let reason = crate::fsio::read_to_string(big.join(KILL_REASON)).unwrap();
        assert_eq!(reason.trim(), format!("infra: {}", infra::DISK));
        assert!(!small.join(KILL_REASON).exists());
    }
}
