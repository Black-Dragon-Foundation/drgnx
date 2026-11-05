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
use forseti::Profile;
use std::fs;
use std::path::Path;

/// A slice root, a job id: plain words, so the slice names nest as systemd reads them.
fn plain(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Makes `<root>.slice` and `<root>-work.slice` (starting the child starts its parent), with the workstation's weights
/// on the root so the person at the machine comes first on CPU and IO.
pub fn ensure_tree(root: &str, profile: Profile) -> Result<(), String> {
    if !plain(root) {
        return Err(format!("the slice root {root:?} is not a plain name"));
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
pub fn set(unit: &str, props: &[(&str, String)]) -> Result<(), String> {
    let mut args = vec![
        "set-property".to_string(),
        "--runtime".into(),
        unit.to_string(),
    ];
    args.extend(props.iter().map(|(k, v)| format!("{k}={v}")));
    run::systemctl_ok(&args).map(|_| ())
}

/// The slice of job ID under ROOT: `<root>-work-<id>.slice`.
pub fn job_slice(root: &str, id: &str) -> Result<String, String> {
    if !plain(root) || id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(format!(
            "a job slice needs a plain root and an id of letters and digits: {root:?} {id:?}"
        ));
    }
    Ok(format!("{root}-work-{id}.slice"))
}

/// Stops SLICE and everything in it (its services and its containers' scopes), without waiting.
pub fn stop(slice: &str) -> Result<(), String> {
    run::systemctl_ok(&["stop", "--no-block", slice]).map(|_| ())
}

/// Pins SLICE (under the user manager's cgroup MANAGER) to CPUS (a kernel CPU list; empty: every CPU again). Every
/// running and new container under it follows at once. BY_SYSTEMD says whether systemd applies `AllowedCPUs` here;
/// when it does not, the property is still set (it takes over after a re-exec) and the delegated files are written
/// directly: `+cpuset` into each ancestor's `cgroup.subtree_control` from the manager down, then the slice's
/// `cpuset.cpus`. systemd keeps a direct write when it realizes the tree again.
pub fn set_cpus(manager: &Path, slice: &str, cpus: &str, by_systemd: bool) -> Result<(), String> {
    set(slice, &[("AllowedCPUs", cpus.to_string())])?;
    if by_systemd {
        return Ok(());
    }
    direct_cpus(manager, slice, cpus)
}

/// The direct write of [`set_cpus`].
pub fn direct_cpus(manager: &Path, slice: &str, cpus: &str) -> Result<(), String> {
    let path = super::probe::slice_path(slice);
    let mut dir = manager.to_path_buf();
    for part in path.components() {
        let control = dir.join("cgroup.subtree_control");
        let has =
            fs::read_to_string(&control).map_err(|e| format!("{}: {e}", control.display()))?;
        if !has.split_whitespace().any(|c| c == "cpuset") {
            fs::write(&control, "+cpuset")
                .map_err(|e| format!("enabling cpuset in {}: {e}", control.display()))?;
        }
        dir.push(part);
    }
    let file = dir.join("cpuset.cpus");
    fs::write(&file, format!("{cpus}\n")).map_err(|e| format!("{}: {e}", file.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] The direct write enables cpuset down to the slice's parent and writes its cpus, on a fixture tree.
    #[test]
    fn the_direct_cpuset_write_enables_the_path() {
        let d = tempfile::tempdir().unwrap();
        let m = d.path();
        let work = m.join("t.slice/t-work.slice");
        fs::create_dir_all(&work).unwrap();
        fs::write(
            m.join("cgroup.subtree_control"),
            "cpuset cpu io memory pids\n",
        )
        .unwrap();
        fs::write(
            m.join("t.slice/cgroup.subtree_control"),
            "cpu memory pids\n",
        )
        .unwrap();
        direct_cpus(m, "t-work.slice", "2-3").unwrap();
        // a real cgroup file takes "+cpuset" as an edit; the fixture file just holds what was written
        assert_eq!(
            fs::read_to_string(m.join("t.slice/cgroup.subtree_control")).unwrap(),
            "+cpuset"
        );
        assert_eq!(
            fs::read_to_string(m.join("cgroup.subtree_control")).unwrap(),
            "cpuset cpu io memory pids\n"
        );
        assert_eq!(
            fs::read_to_string(work.join("cpuset.cpus")).unwrap(),
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
