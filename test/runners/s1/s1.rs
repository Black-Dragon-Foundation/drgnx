//! The fake runner's checks (pattern D, pure observation of a finished command: no waits, no sleeps). They run inside a
//! fake runner as the user `runner`, with the user manager's environment (`fleet.sh exec` sets it):
//!
//!   rustc --test -o s1 test/runners/s1/s1.rs && fleet.sh put s1 && fleet.sh exec 1 -- /fleet/share/s1 --ignored
//!
//! Plain std, no crate, so they move into the runner crate's tests unchanged.
use std::process::Command;

const BASE: &str = "registry.fedoraproject.org/fedora:45";

fn run(program: &str, args: &[&str]) -> String {
    let out = Command::new(program).args(args).output().expect("spawn");
    assert!(
        out.status.success(),
        "{program} {args:?}: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

#[test]
#[ignore = "runner-host"]
fn check_limits_passes_inside_a_fake_runner() {
    let info = run(
        "podman",
        &["info", "--format", "{{.Host.CgroupsVersion}}|{{.Host.CgroupManager}}|{{range .Host.CgroupControllers}}{{.}} {{end}}"],
    );
    let mut f = info.split('|');
    assert_eq!(f.next(), Some("v2"), "{info}");
    assert_eq!(f.next(), Some("systemd"), "{info}");
    let controllers: Vec<&str> = f.next().unwrap_or("").split_whitespace().collect();
    for c in ["memory", "pids", "cpu"] {
        assert!(controllers.contains(&c), "controller {c} is not delegated: {info}");
    }
}

#[test]
#[ignore = "runner-host"]
fn a_capped_container_runs_in_a_transient_slice() {
    // One synchronous unit in the slice: it starts a detached capped container with `--cgroup-parent` (without it
    // podman puts the container's scope under user.slice, outside the slice), prints the cgroup path and the cap, and
    // removes the container. The caller waits on the unit (`--wait`), not on time.
    let script = format!(
        "podman run -d --name s1-cap --cgroup-parent=s1-work-x.slice --memory=256m --memory-swap=256m {BASE} sleep 120 >/dev/null \
         && podman inspect -f '{{{{.State.CgroupPath}}}}' s1-cap; podman rm -f -t 0 s1-cap >/dev/null"
    );
    let path = run(
        "systemd-run",
        &["--user", "--pipe", "--wait", "--collect", "--slice=s1-work-x.slice", "sh", "-c", &script],
    );
    assert!(path.contains("/s1-work-x.slice/"), "the container's cgroup is outside the slice: {path}");
}

#[test]
#[ignore = "runner-host"]
fn the_container_gets_its_caps() {
    let out = run(
        "podman",
        &["run", "--rm", "--memory=256m", "--memory-swap=256m", "--pids-limit=100", BASE, "sh", "-c",
          "cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max"],
    );
    assert_eq!(out.split_whitespace().collect::<Vec<_>>(), ["268435456", "100"]);
}

#[test]
#[ignore = "runner-host"]
fn linger_keeps_a_unit_after_the_session_ends() {
    // The runner user lingers, so its manager outlives any login. The ssh half (log in, start a unit, log out, log in
    // again, the unit is active) is `fleet.sh check-linger`.
    let linger = run("loginctl", &["show-user", "runner", "-P", "Linger"]);
    assert_eq!(linger, "yes");
}
