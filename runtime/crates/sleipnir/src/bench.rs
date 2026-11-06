//! `sleipnir bench --root DIR --image DIGEST`: how fast this runner is, for placement's finish-time estimates.
//!
//! A fixed workload runs in one capped container (1 core, 512 MiB, no network, the shared argv in its own job slice):
//! sha256 over 256 MiB (CPU), then 128 MiB written and synced into the runner folder (IO). The container times both
//! parts itself, so podman's start-up isn't counted. The speed is [`REFERENCE_S`] over the measured seconds: 1.0 is
//! the reference machine, 2.0 twice as fast. The whole run is bounded at [`LIMIT`]; past it the bench fails and its
//! container is removed. The hub records the result in the runner's registry record.

use crate::linux::podman::{self, Caps, ContainerImage, ContainerReq, RunnerArgs, RunnerMounts};
use crate::linux::probe::Probe;
use crate::linux::{run, slices};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The workload's seconds on the reference machine (one current desktop core and an NVMe disk).
pub const REFERENCE_S: f64 = 2.0;
/// The most a bench may take, start-up included.
pub const LIMIT: Duration = Duration::from_secs(120);
/// The bench container's caps.
pub const MEMORY: &str = "512M";
pub const CPUS: u32 = 1;
/// The bench container's name and its slice's id.
pub const ID: &str = "bench";
pub const PREFIX: &str = "drgnx-bench-";

/// The workload. Its last line is `bench <cpu ns> <io ns> <memory.max> <cpu.max>`.
pub const SCRIPT: &str = "set -e; t0=$(date +%s%N); head -c 268435456 /dev/zero | sha256sum >/dev/null; \
     t1=$(date +%s%N); dd if=/dev/zero of=/target/bench.io bs=1M count=128 conv=fsync status=none; \
     t2=$(date +%s%N); rm -f /target/bench.io; \
     echo \"bench $((t1 - t0)) $((t2 - t1)) $(cat /sys/fs/cgroup/memory.max) $(tr ' ' _ < /sys/fs/cgroup/cpu.max)\"";

/// What the bench reports.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BenchResult {
    /// Relative to the reference machine: higher is faster.
    pub speed: f64,
    pub cores: u32,
    pub mem_mib: u64,
    /// The default route's interface speed in Mbit/s, when the kernel knows it (the hub measures the link itself).
    pub link_hint: Option<u64>,
}

/// The workload's own readings.
#[derive(Clone, Debug, PartialEq)]
pub struct Timings {
    pub cpu_s: f64,
    pub io_s: f64,
    /// `memory.max` and `cpu.max` inside the container: the caps it ran under.
    pub memory_max: String,
    pub cpu_max: String,
}

/// The workload's readings from its output (its last `bench` line).
pub fn parse(out: &str) -> Option<Timings> {
    let line = out.lines().rev().find(|l| l.starts_with("bench "))?;
    let w: Vec<&str> = line.split_whitespace().collect();
    let [_, cpu, io, mem, cpu_max] = w[..] else {
        return None;
    };
    let ns = |s: &str| s.parse::<u64>().ok().map(|n| n as f64 / 1e9);
    Some(Timings {
        cpu_s: ns(cpu)?,
        io_s: ns(io)?,
        memory_max: mem.to_string(),
        cpu_max: cpu_max.replace('_', " "),
    })
}

/// The result from the readings and the machine's size.
pub fn result(t: &Timings, cores: u32, mem_mib: u64, link_hint: Option<u64>) -> BenchResult {
    let total = (t.cpu_s + t.io_s).max(1e-3);
    BenchResult {
        speed: REFERENCE_S / total,
        cores,
        mem_mib,
        link_hint,
    }
}

/// The `podman run` arguments for the workload in IMAGE, with SRC and TARGET as its mounts.
pub fn argv(image: &str, src: &Path, target: &Path) -> Result<Vec<String>, String> {
    let caps = Caps {
        images: vec![ContainerImage {
            name: "bench".into(),
            image: image.into(),
        }],
        memory: MEMORY.into(),
        cpus: CPUS,
        pids: podman::PIDS,
        proxy: None,
        net_hosts: vec![],
        pins: vec![],
    };
    let req = ContainerReq {
        image: "bench".into(),
        argv: vec!["sh".into(), "-c".into(), SCRIPT.into()],
        worktree: src.to_path_buf(),
        subdir: PathBuf::new(),
        job: ID.into(),
        net: false,
        runner: Some(RunnerMounts {
            writes_tree: false,
            target: target.to_path_buf(),
            caches: vec![],
            keys: None,
        }),
    };
    let ra = RunnerArgs {
        cgroup_parent: Some(slices::job_slice(crate::serve::SLICE_ROOT, ID)?),
        label: None,
        name_prefix: PREFIX.into(),
    };
    podman::argv(&req, &caps, &ra)
        .map_err(|r| r.message)?
        .into_iter()
        .map(|a| {
            a.into_string()
                .map_err(|_| "a podman argument is not UTF-8".to_string())
        })
        .collect()
}

/// The default route's interface speed (`/sys/class/net/<if>/speed`), in Mbit/s.
fn link_hint() -> Option<u64> {
    let routes = fs::read_to_string("/proc/net/route").ok()?;
    let iface = routes.lines().skip(1).find_map(|l| {
        let w: Vec<&str> = l.split_whitespace().collect();
        (w.get(1) == Some(&"00000000")).then(|| w[0].to_string())
    })?;
    let speed: i64 = fs::read_to_string(format!("/sys/class/net/{iface}/speed"))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    u64::try_from(speed).ok().filter(|s| *s > 0)
}

/// Runs the bench with ROOT as the runner folder and IMAGE as its image; the result and the caps it ran under.
pub fn run(root: &Path, image: &str) -> Result<(BenchResult, Timings), String> {
    let dir = root.join("bench");
    let (src, target) = (dir.join("src"), dir.join("target"));
    for d in [&src, &target] {
        fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
    }
    slices::ensure_tree(crate::serve::SLICE_ROOT, forseti::Profile::Dedicated)?;
    let args = argv(image, &src, &target)?;
    let name = format!("{PREFIX}{ID}");
    let out = run::limited(Path::new("podman"), &args, &[], LIMIT);
    let out = match out {
        Ok(o) => o,
        Err(e) => {
            let _ = run::limited(
                Path::new("podman"),
                &["rm", "-f", "-t", "0", &name],
                &[],
                run::SYSTEMCTL_LIMIT,
            );
            return Err(format!("the bench: {e}"));
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    if !out.status.success() {
        return Err(format!(
            "the bench container failed: {}{}",
            stdout.trim(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let t = parse(&stdout).ok_or_else(|| format!("the bench printed no readings: {stdout}"))?;
    let probe = Probe::system(
        "runner",
        "drgnx-bench",
        crate::serve::SLICE_ROOT,
        root,
        forseti::Profile::Dedicated,
    )
    .map_err(|e| format!("the probe: {e}"))?;
    let cores = probe.cpus_usable().map(|c| c.len() as u32).unwrap_or(0);
    let mem = probe.memory().map(|m| m.total_mib).unwrap_or(0);
    Ok((result(&t, cores, mem, link_hint()), t))
}

#[cfg(test)]
mod tests {
    use super::*;

    const IMG: &str = "registry.example/fedora@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    /// [D] The readings come from the workload's last line; the speed is the reference over their sum; the result
    /// reads and writes as the registry keeps it; the container is capped at one core and 512 MiB, with no network,
    /// in the bench's own job slice, and runs exactly the workload.
    #[test]
    fn bench_result_shape() {
        let out = "noise\nbench 1500000000 500000000 536870912 100000_100000\n";
        let t = parse(out).unwrap();
        assert_eq!(
            t,
            Timings {
                cpu_s: 1.5,
                io_s: 0.5,
                memory_max: "536870912".into(),
                cpu_max: "100000 100000".into(),
            }
        );
        assert_eq!(parse("bench 1 2\n"), None);
        assert_eq!(parse("nothing\n"), None);
        let r = result(&t, 16, 65536, Some(1000));
        assert_eq!(r.speed, REFERENCE_S / 2.0);
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"speed": 1.0, "cores": 16, "mem_mib": 65536, "link_hint": 1000})
        );
        assert_eq!(serde_json::from_value::<BenchResult>(json).unwrap(), r);
        // twice as fast as the reference
        let fast = Timings {
            cpu_s: 0.75,
            io_s: 0.25,
            ..t
        };
        assert_eq!(result(&fast, 1, 1, None).speed, 2.0);

        let a = argv(IMG, Path::new("/r/bench/src"), Path::new("/r/bench/target")).unwrap();
        let has = |pair: [&str; 2]| a.windows(2).any(|w| w == pair);
        assert!(
            has(["--memory", MEMORY]) && has(["--memory-swap", MEMORY]),
            "{a:?}"
        );
        assert!(has(["--cpus", "1"]), "{a:?}");
        assert!(a.contains(&"--network=none".to_string()));
        assert!(a.contains(&"--cgroup-parent=drgnx-runner-work-bench.slice".to_string()));
        assert!(has(["--name", "drgnx-bench-bench"]));
        assert!(has(["-v", "/r/bench/target:/target:rw,Z"]), "{a:?}");
        let img = a.iter().position(|s| s == IMG).unwrap();
        assert_eq!(&a[img + 1..], ["sh", "-c", SCRIPT]);
    }
}
