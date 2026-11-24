//! The slice tree under the user's systemd: `<root>.slice` holds all our work (one knob caps it), `<root>-work.slice`
//! the jobs, and each job its own `<root>-work-<id>.slice` with its job-exec service and its containers side by side.
//!
//! ```text
//! <root>.slice                 MemoryHigh / MemoryMax (the cap); workstation: CPUWeight=20 IOWeight=20
//!   <root>-work.slice          AllowedCPUs
//!     <root>-work-<id>.slice   one job: accounting, stop, kill
//!       <unit>.service         job-exec (OOM score 900), with the podman client and conmon
//!       libpod-<ctr>.scope     its containers (OOM score 1000, memory.oom.group=1), by --cgroup-parent
//! ```
//!
//! Properties change only through `set-property --runtime`, so nothing outlives a reboot. A user manager started
//! before cpuset was delegated accepts `AllowedCPUs` and never writes `cpuset.cpus`; for such a host
//! ([`super::probe::Probe::cpuset_by_systemd`] false) [`set_cpus`] writes the delegated files itself.

use super::run;
use crate::fsio;
use forseti::Profile;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// A slice root, a job id: plain words, so the slice names nest as systemd reads them.
fn plain(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Makes `<root>.slice` and `<root>-work.slice` (starting the child starts its parent), with the workstation's weights
/// on the root so the person at the machine comes first on CPU and IO.
pub fn ensure_tree(root: &str, profile: Profile) -> villa::Result<()> {
    if !plain(root) {
        return Err(villa::Error::invalid(format!(
            "the slice root {root:?} is not a plain name"
        )));
    }
    run::systemctl_ok(&["start", &format!("{root}-work.slice")])?;
    if profile == Profile::Workstation {
        set(
            &format!("{root}.slice"),
            &[("CPUWeight", "20".into()), ("IOWeight", "20".into())],
        )?;
    }
    Ok(())
}

/// Sets PROPS on UNIT for this boot only (`set-property --runtime`).
pub fn set(unit: &str, props: &[(&str, String)]) -> villa::Result<()> {
    let mut args = vec![
        "set-property".to_string(),
        "--runtime".into(),
        unit.to_string(),
    ];
    args.extend(props.iter().map(|(k, v)| format!("{k}={v}")));
    run::systemctl_ok(&args).map(|_| ())
}

/// The slice of job ID under ROOT: `<root>-work-<id>.slice`.
pub fn job_slice(root: &str, id: &str) -> villa::Result<String> {
    if !plain(root) || id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(villa::Error::invalid(format!(
            "a job slice needs a plain root and an id of letters and digits: {root:?} {id:?}"
        )));
    }
    Ok(format!("{root}-work-{id}.slice"))
}

/// Stops SLICE and everything in it (its services and its containers' scopes), without waiting.
pub fn stop(slice: &str) -> villa::Result<()> {
    run::systemctl_ok(&["stop", "--no-block", slice]).map(|_| ())
}

/// A job slice's memory properties from its grant (design §3 #3): `MemoryHigh` throttles at RESERVE plus a fifth (at
/// most the cap), `MemoryMax` kills at CAP; MiB each.
pub fn job_props(reserve_mib: u64, cap_mib: u64) -> [(&'static str, String); 2] {
    let high = (reserve_mib * 6 / 5).min(cap_mib);
    [
        ("MemoryHigh", format!("{high}M")),
        ("MemoryMax", format!("{cap_mib}M")),
    ]
}

/// A job's SLICE once the job ended: stopped, and the properties [`set`] gave it dropped (`revert` removes the
/// runtime drop-ins, which would otherwise pile up until the next boot, one per job).
pub fn forget(slice: &str) -> villa::Result<()> {
    stop(slice)?;
    revert(slice)
}

/// Drops the properties [`set`] gave SLICE (its runtime drop-ins).
pub fn revert(slice: &str) -> villa::Result<()> {
    run::systemctl_ok(&["revert", slice]).map(|_| ())
}

/// Pins SLICE (under the user manager's cgroup MANAGER) to CPUS (a kernel CPU list; empty: every CPU again). Every
/// running and new container under it follows at once. BY_SYSTEMD says whether systemd applies `AllowedCPUs` here;
/// when it does not, the property is still set (it takes over after a re-exec) and the delegated files are written
/// directly: `+cpuset` into each ancestor's `cgroup.subtree_control` from the manager down, then the slice's
/// `cpuset.cpus`. systemd keeps a direct write when it realizes the tree again.
pub fn set_cpus(manager: &Path, slice: &str, cpus: &str, by_systemd: bool) -> villa::Result<()> {
    set(slice, &[("AllowedCPUs", cpus.to_string())])?;
    if by_systemd {
        return Ok(());
    }
    direct_cpus(manager, slice, cpus)
}

/// The direct write of [`set_cpus`].
pub fn direct_cpus(manager: &Path, slice: &str, cpus: &str) -> villa::Result<()> {
    let path = super::probe::slice_path(slice);
    let mut dir = manager.to_path_buf();
    for part in path.components() {
        let control = dir.join("cgroup.subtree_control");
        let has = fsio::read_to_string(&control)
            .map_err(|e| villa::Error::io(format!("{}: {e}", control.display())))?;
        if !has.split_whitespace().any(|c| c == "cpuset") {
            std::fs::write(&control, "+cpuset").map_err(|e| {
                villa::Error::io(format!("enabling cpuset in {}: {e}", control.display()))
            })?;
        }
        dir.push(part);
    }
    let file = dir.join("cpuset.cpus");
    std::fs::write(&file, format!("{cpus}\n"))
        .map_err(|e| villa::Error::io(format!("{}: {e}", file.display())))
}

/// The timing slice under ROOT, `<root>-timing.slice`, for ISLAND (a kernel CPU list: the runner profile's `island`).
/// A timing job's own slice is `<root>-timing-<id>.slice` ([`timing_job_slice`]), so it runs on the island while the
/// work slice runs on the rest (design §5.6).
pub fn timing_slice(root: &str, island: &str) -> villa::Result<String> {
    if !plain(root) {
        return Err(villa::Error::invalid(format!(
            "the slice root {root:?} is not a plain name"
        )));
    }
    cpus_of(island)?;
    Ok(format!("{root}-timing.slice"))
}

/// The slice of timing job ID under ROOT: `<root>-timing-<id>.slice`.
pub fn timing_job_slice(root: &str, id: &str) -> villa::Result<String> {
    job_slice(root, id).map(|_| format!("{root}-timing-{id}.slice"))
}

/// CPUS as a kernel CPU list, ranges joined (`6-11,18-23`).
pub fn cpu_list(cpus: &[u32]) -> String {
    let mut sorted = cpus.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let mut parts: Vec<String> = vec![];
    let mut i = 0;
    while i < sorted.len() {
        let mut j = i;
        while j + 1 < sorted.len() && sorted[j + 1] == sorted[j] + 1 {
            j += 1;
        }
        parts.push(if i == j {
            sorted[i].to_string()
        } else {
            format!("{}-{}", sorted[i], sorted[j])
        });
        i = j + 1;
    }
    parts.join(",")
}

/// The CPUs of LIST (a kernel CPU list), or why it is none.
fn cpus_of(list: &str) -> villa::Result<Vec<u32>> {
    super::probe::parse_cpu_list(list)
        .ok()
        .filter(|c| !c.is_empty())
        .ok_or_else(|| {
            villa::Error::invalid(format!("{list:?} is not a CPU list (such as 0-5,12-17)"))
        })
}

/// What the timing slice became: an isolated partition (no scheduler balancing across it), a root partition, or a
/// plain member that only has `AllowedCPUs` (a user manager's delegated subtree has no partition root above it: the
/// expected case, design §0.3 R4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Partition {
    Isolated,
    Root,
    Member,
}

/// Makes SLICE (under the user manager's cgroup MANAGER) an isolated partition, else a root one, else leaves it a
/// member; a fallback is said once per runner (SAID).
pub fn set_partition(manager: &Path, slice: &str, said: &AtomicBool) -> Partition {
    let file = manager
        .join(super::probe::slice_path(slice))
        .join("cpuset.cpus.partition");
    // the kernel takes a write it can't honour and reads back "<mode> invalid (why)"
    let takes = |mode: &str| {
        std::fs::write(&file, mode).is_ok()
            && fsio::read_to_string(&file)
                .is_ok_and(|s| s.trim_start().starts_with(mode) && !s.contains("invalid"))
    };
    let p = if takes("isolated") {
        Partition::Isolated
    } else if takes("root") {
        Partition::Root
    } else {
        // a kernel that took neither mode may refuse this too; the slice is a member either way
        drop(std::fs::write(&file, "member"));
        Partition::Member
    };
    if p != Partition::Isolated && !said.swap(true, Ordering::Relaxed) {
        crate::eline!(
            "sleipnir: the timing slice {slice} is a {} partition, not isolated: the island has its CPUs, and the 
             scheduler may still balance across it",
            if p == Partition::Root { "root" } else { "plain member (AllowedCPUs only)" }
        );
    }
    p
}

/// Whether ISLAND (a CPU list) is whole L3 groups as CPU_DIR (`/sys/devices/system/cpu`) reads them: every CPU of an
/// L3 group it touches is in it, so the island never shares a cache with the work.
pub fn island_whole_l3(cpu_dir: &Path, island: &str) -> villa::Result<()> {
    let want = cpus_of(island)?;
    for cpu in &want {
        let file = cpu_dir.join(format!("cpu{cpu}/cache/index3/shared_cpu_list"));
        let text = fsio::read_to_string(&file).map_err(|e| {
            villa::Error::io(format!(
                "the island's CPU {cpu}: its L3 group ({}): {e}",
                file.display()
            ))
        })?;
        let group = cpus_of(text.trim())?;
        if let Some(out) = group.iter().find(|c| !want.contains(c)) {
            return Err(villa::Error::invalid(format!(
                "the island {island} splits the L3 group {} (CPU {out} is outside it): an island is whole L3 groups",
                text.trim()
            )));
        }
    }
    Ok(())
}

/// The island on or off: on (ISLAND, REST), the timing slice gets the island's CPUs (and its partition, said once
/// through SAID) and the work slice the rest, so every running work job moves at once; off, the work slice gets
/// every CPU again. BY_SYSTEMD as [`set_cpus`].
pub fn island_on(
    manager: &Path,
    root: &str,
    on: Option<(&str, &str)>,
    by_systemd: bool,
    said: &AtomicBool,
) -> villa::Result<Option<Partition>> {
    let work = format!("{root}-work.slice");
    let Some((island, rest)) = on else {
        return set_cpus(manager, &work, "", by_systemd).map(|()| None);
    };
    let timing = timing_slice(root, island)?;
    run::systemctl_ok(&["start", &timing])?;
    // work first, so the island is free before the timing job starts on it
    set_cpus(manager, &work, rest, by_systemd)?;
    set_cpus(manager, &timing, island, by_systemd)?;
    Ok(Some(set_partition(manager, &timing, said)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] pure (design §3 #3): a runner job's slice throttles at its reservation plus a fifth and is killed at its cap
    #[test]
    fn a_job_slice_gets_high_at_reserve_and_max_at_cap() {
        assert_eq!(
            job_props(4096, 6144),
            [
                ("MemoryHigh", "4915M".to_string()),
                ("MemoryMax", "6144M".to_string())
            ]
        );
        // a reservation above the cap throttles at the cap
        assert_eq!(
            job_props(8192, 6144)[0],
            ("MemoryHigh", "6144M".to_string())
        );
    }

    /// [D] pure (design §5.6, a fixture sysfs of a 7900X: CCD0 is CPUs 0-5 and 12-17): an island is whole L3 groups,
    /// else `runner check` refuses it and names the group it splits
    #[test]
    fn an_island_that_splits_an_l3_is_refused() {
        let d = tempfile::tempdir().unwrap();
        for cpu in 0..24u32 {
            let l3 = if cpu % 12 < 6 {
                "0-5,12-17"
            } else {
                "6-11,18-23"
            };
            let dir = d.path().join(format!("cpu{cpu}/cache/index3"));
            std::fs::create_dir_all(&dir).unwrap();
            fsio::write(dir.join("shared_cpu_list"), format!("{l3}\n")).unwrap();
        }
        island_whole_l3(d.path(), "0-5,12-17").unwrap();
        island_whole_l3(d.path(), "6-11,18-23").unwrap();
        let e = island_whole_l3(d.path(), "0-5").unwrap_err();
        assert!(e.message().contains("0-5,12-17"), "{e}");
        assert!(island_whole_l3(d.path(), "0-6,12-17").is_err());
        assert!(island_whole_l3(d.path(), "0-5,12-x").is_err());
        assert!(
            island_whole_l3(d.path(), "30").is_err(),
            "a CPU the machine hasn't"
        );
        assert_eq!(
            timing_slice("drgnx-runner", "0-5,12-17").unwrap(),
            "drgnx-runner-timing.slice"
        );
        assert!(timing_slice("drgnx-runner", "0-5;rm").is_err());
        assert_eq!(
            timing_job_slice("drgnx-runner", "a3f").unwrap(),
            "drgnx-runner-timing-a3f.slice"
        );
        assert_eq!(
            cpu_list(&[6, 7, 8, 9, 10, 11, 18, 19, 20, 21, 22, 23]),
            "6-11,18-23"
        );
        assert_eq!(cpu_list(&[0, 2, 3]), "0,2-3");
    }

    /// [D] pure (design §0.3 R4, a fixture cgroup tree): the timing slice becomes an isolated partition where the
    /// kernel takes it; where it takes neither isolated nor root (here: the file can't be written), it stays a member
    /// with `AllowedCPUs` only, and the runner says so once
    #[test]
    fn partition_falls_back_and_says_once() {
        let d = tempfile::tempdir().unwrap();
        let said = AtomicBool::new(false);
        let at = |s: &str| d.path().join(super::super::probe::slice_path(s));
        std::fs::create_dir_all(at("t-timing.slice")).unwrap();
        fsio::write(
            at("t-timing.slice").join("cpuset.cpus.partition"),
            "member\n",
        )
        .unwrap();
        assert_eq!(
            set_partition(d.path(), "t-timing.slice", &said),
            Partition::Isolated
        );
        assert!(!said.load(Ordering::Relaxed));
        // a directory where the file is: no write takes
        std::fs::create_dir_all(at("u-timing.slice").join("cpuset.cpus.partition")).unwrap();
        assert_eq!(
            set_partition(d.path(), "u-timing.slice", &said),
            Partition::Member
        );
        assert!(said.load(Ordering::Relaxed), "said");
        assert_eq!(
            set_partition(d.path(), "u-timing.slice", &said),
            Partition::Member
        );
    }

    /// [D] The direct write enables cpuset down to the slice's parent and writes its cpus, on a fixture tree.
    #[test]
    fn the_direct_cpuset_write_enables_the_path() {
        let d = tempfile::tempdir().unwrap();
        let m = d.path();
        let work = m.join("t.slice/t-work.slice");
        std::fs::create_dir_all(&work).unwrap();
        fsio::write(
            m.join("cgroup.subtree_control"),
            "cpuset cpu io memory pids\n",
        )
        .unwrap();
        fsio::write(
            m.join("t.slice/cgroup.subtree_control"),
            "cpu memory pids\n",
        )
        .unwrap();
        direct_cpus(m, "t-work.slice", "2-3").unwrap();
        // a real cgroup file takes "+cpuset" as an edit; the fixture file just holds what was written
        assert_eq!(
            fsio::read_to_string(m.join("t.slice/cgroup.subtree_control")).unwrap(),
            "+cpuset"
        );
        assert_eq!(
            fsio::read_to_string(m.join("cgroup.subtree_control")).unwrap(),
            "cpuset cpu io memory pids\n"
        );
        assert_eq!(
            fsio::read_to_string(work.join("cpuset.cpus")).unwrap(),
            "2-3\n"
        );
        assert_eq!(
            job_slice("drgnx-runner", "a3f").unwrap(),
            "drgnx-runner-work-a3f.slice"
        );
        for (r, i) in [
            ("", "a"),
            ("x", "a-b"),
            ("-x", "a"),
            ("x y", "a"),
            ("x", ""),
        ] {
            assert!(job_slice(r, i).is_err(), "{r:?} {i:?}");
        }
    }
}
