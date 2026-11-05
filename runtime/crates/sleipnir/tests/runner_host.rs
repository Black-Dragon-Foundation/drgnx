//! Runner-host tests: they run inside a fake runner (`test/runners/`), as the user `runner` with its user manager,
//! never on a developer's machine:
//!
//! ```text
//! cargo test -p sleipnir --no-default-features --features linux --test runner_host --no-run
//! fleet.sh host <the test binary> [FILTER]      # --ignored, in every runner
//! ```
//!
//! Each names its pattern. A child the test starts is this binary again, running one of the `child_*` entries with
//! its orders in the environment; outside a test that starts it, a child entry does nothing.
#![cfg(target_os = "linux")]

use sleipnir::linux::reserve::{self, Reservation, Reservations};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::Duration;

/// Starts this test binary as child ENTRY with ENV.
fn child(entry: &str, env: &[(&str, &str)]) -> Child {
    Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", entry, "--test-threads=1", "--quiet"])
        .envs(env.iter().copied())
        .spawn()
        .unwrap()
}

fn exists(p: &Path) -> Option<()> {
    p.exists().then_some(())
}

fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .unwrap()
        .trim()
        .to_string()
}

fn now_s() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// A child of `two_admissions_in_one_second_cannot_both_fit`: under the admission lock it announces
/// `<name>.inside`, waits for `<name>.go`, counts the others against the budget and either writes its own reservation
/// (`<name>.admitted`) or not (`<name>.refused`); then it parks, alive, until `<name>.exit`.
#[test]
#[ignore = "runner-host"]
fn child_admits() {
    let Ok(dir) = std::env::var("SLEIPNIR_ADMIT_DIR") else {
        return;
    };
    let dir = PathBuf::from(dir);
    let name = std::env::var("SLEIPNIR_ADMIT_NAME").unwrap();
    let (budget, need): (u64, u64) = (3000, 2000);
    let rs = Reservations::at(&dir.join("run"));
    let me = std::process::id();
    let start = reserve::start_time(me).unwrap();
    let mark = |what: &str| std::fs::write(dir.join(format!("{name}.{what}")), b"").unwrap();
    rs.with_admit_lock(|| {
        mark("inside");
        skuld::wait_until("the test's go", 60, || {
            exists(&dir.join(format!("{name}.go")))
        });
        let others = rs.read_others(&name);
        let used = forseti::count_others(
            &others,
            &boot_id(),
            &|pid, t| reserve::alive(pid, t),
            &name,
            now_s(),
        );
        if used + need <= budget {
            rs.put(&Reservation {
                scheduler: name.clone(),
                pid: me,
                boot_id: boot_id(),
                start_time: start,
                job: "j1".into(),
                reserve_mib: need,
                current_mib: 0,
                expires: now_s() + 3600,
            })
            .unwrap();
            mark("admitted");
        } else {
            mark("refused");
        }
    })
    .unwrap();
    skuld::wait_until("the test's exit", 120, || {
        exists(&dir.join(format!("{name}.exit")))
    });
}

/// [C] Two schedulers admit against one budget that fits one job: the second can't even look while the first holds
/// the lock (a window shows it never gets inside), and once the first has written its reservation the second sees it
/// and refuses. The sum admitted stays within the budget.
#[test]
#[ignore = "runner-host"]
fn two_admissions_in_one_second_cannot_both_fit() {
    let d = tempfile::tempdir().unwrap();
    let dir = d.path().to_str().unwrap().to_string();
    let f = |n: &str| d.path().join(n);
    let mut a = child(
        "child_admits",
        &[
            ("SLEIPNIR_ADMIT_DIR", &dir),
            ("SLEIPNIR_ADMIT_NAME", "sched-a"),
        ],
    );
    skuld::wait_until("a inside the lock", 60, || exists(&f("sched-a.inside")));
    let mut b = child(
        "child_admits",
        &[
            ("SLEIPNIR_ADMIT_DIR", &dir),
            ("SLEIPNIR_ADMIT_NAME", "sched-b"),
        ],
    );
    skuld::window(
        Duration::from_millis(500),
        "b gets inside while a holds the lock",
    );
    assert!(
        !f("sched-b.inside").exists(),
        "b was inside the lock while a held it"
    );
    std::fs::write(f("sched-a.go"), b"").unwrap();
    skuld::wait_until("a decided", 60, || {
        exists(&f("sched-a.admitted")).or(exists(&f("sched-a.refused")))
    });
    skuld::wait_until("b inside the lock", 60, || exists(&f("sched-b.inside")));
    std::fs::write(f("sched-b.go"), b"").unwrap();
    skuld::wait_until("b decided", 60, || {
        exists(&f("sched-b.admitted")).or(exists(&f("sched-b.refused")))
    });
    let admitted: Vec<&str> = ["sched-a", "sched-b"]
        .into_iter()
        .filter(|n| f(&format!("{n}.admitted")).exists())
        .collect();
    assert_eq!(
        admitted,
        ["sched-a"],
        "one admission fits the budget, and it is the first"
    );
    assert!(f("sched-b.refused").exists());
    let held: u64 = Reservations::at(&f("run"))
        .read_others("nobody")
        .iter()
        .map(|r| r.reserve_mib)
        .sum();
    assert!(held <= 3000, "{held} MiB admitted against 3000");
    for n in ["sched-a", "sched-b"] {
        std::fs::write(f(&format!("{n}.exit")), b"").unwrap();
    }
    assert!(a.wait().unwrap().success() && b.wait().unwrap().success());
}

/// [C] A reservation counts while its process lives and stops counting once it is gone; a reused pid (another start
/// time) never counts.
#[test]
#[ignore = "runner-host"]
fn a_dead_pids_reservation_is_ignored() {
    let d = tempfile::tempdir().unwrap();
    let rs = Reservations::at(d.path());
    // a real process that parks on its stdin
    let mut p = Command::new("cat")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let pid = p.id();
    let start = reserve::start_time(pid).unwrap();
    let r = |start_time: u64, job: &str| Reservation {
        scheduler: "jobq".into(),
        pid,
        boot_id: boot_id(),
        start_time,
        job: job.into(),
        reserve_mib: 1024,
        current_mib: 2048,
        expires: now_s() + 3600,
    };
    rs.put(&r(start, "live")).unwrap();
    rs.put(&r(start + 1, "reused")).unwrap();
    let count = || {
        forseti::count_others(
            &rs.read_others("me"),
            &boot_id(),
            &|p, t| reserve::alive(p, t),
            "me",
            now_s(),
        )
    };
    assert_eq!(
        count(),
        2048,
        "the live one at max(reserve, current); the reused pid not at all"
    );
    drop(p.stdin.take());
    assert!(p.wait().unwrap().success());
    assert!(!reserve::alive(pid, start));
    assert_eq!(count(), 0);
}

// ---- the executor: the slice tree, units, job-exec ----

use sleipnir::linux::jobexec::JobExec;
use sleipnir::linux::parse::Parser;
use sleipnir::linux::podman::{self, Caps, ContainerImage, ContainerReq, RunnerArgs, RunnerMounts};
use sleipnir::linux::probe::Probe;
use sleipnir::linux::result::ResultJson;
use sleipnir::linux::{slices, unit};

/// The fake runner's base image, preloaded in its store.
const BASE: &str = "registry.fedoraproject.org/fedora:45";
/// The slice root and the container prefix of these tests: never a real runner's.
const ROOT: &str = "sltest";
const PREFIX: &str = "sltest-run";

/// Runs PROGRAM ARGS and answers its stdout; panics with its output when it fails.
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

/// The base image's reference pinned by digest, as the allow-list holds images.
fn base_ref() -> String {
    let d = run(
        "podman",
        &["image", "inspect", BASE, "--format", "{{.Digest}}"],
    );
    format!("registry.fedoraproject.org/fedora@{d}")
}

fn caps(memory: &str) -> Caps {
    Caps {
        images: vec![ContainerImage {
            name: "base".into(),
            image: base_ref(),
        }],
        memory: memory.into(),
        cpus: 1,
        pids: 100,
        proxy: None,
        net_hosts: vec![],
    }
}

/// `podman run …` for job ID in its slice, with CMD in the base image, through the shared argv builder.
fn podman_run(id: &str, source: &Path, target: &Path, memory: &str, cmd: &[&str]) -> Vec<String> {
    let req = ContainerReq {
        image: "base".into(),
        argv: cmd.iter().map(|s| s.to_string()).collect(),
        worktree: source.to_path_buf(),
        subdir: PathBuf::new(),
        job: id.into(),
        net: false,
        runner: Some(RunnerMounts {
            writes_tree: false,
            target: target.to_path_buf(),
            caches: vec![],
            keys: None,
        }),
    };
    let ra = RunnerArgs::runner(PREFIX, "hubtest", &slices::job_slice(ROOT, id).unwrap());
    let mut a = vec!["podman".to_string()];
    a.extend(
        podman::argv(&req, &caps(memory), &ra)
            .unwrap()
            .into_iter()
            .map(|s| s.into_string().unwrap()),
    );
    a
}

fn probe() -> Probe {
    Probe::system(
        "runner",
        "sltest",
        ROOT,
        Path::new("/tmp"),
        forseti::Profile::Dedicated,
    )
    .unwrap()
}

/// A job's folder, its source and target, under the runner's /tmp.
struct JobDir {
    _d: tempfile::TempDir,
    dir: PathBuf,
    source: PathBuf,
    target: PathBuf,
}

fn job_dir() -> JobDir {
    let d = tempfile::Builder::new()
        .prefix("sltest")
        .tempdir_in("/tmp")
        .unwrap();
    let (dir, source, target) = (
        d.path().join("job"),
        d.path().join("src"),
        d.path().join("target"),
    );
    for p in [&dir, &source, &target] {
        std::fs::create_dir_all(p).unwrap();
    }
    JobDir {
        dir,
        source,
        target,
        _d: d,
    }
}

/// The pid of our container NAME once podman says it runs.
fn running_pid(name: &str) -> u32 {
    skuld::wait_until(&format!("{name} running"), 120, || {
        let out = Command::new("podman")
            .args(["inspect", "-f", "{{.State.Pid}}", name])
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse::<u32>()
            .ok()
            .filter(|p| *p > 0)
    })
}

fn proc_file(pid: u32, f: &str) -> String {
    std::fs::read_to_string(format!("/proc/{pid}/{f}")).unwrap_or_default()
}

fn cgroup_of(pid: u32) -> String {
    proc_file(pid, "cgroup")
        .lines()
        .find_map(|l| l.strip_prefix("0::"))
        .unwrap_or("")
        .to_string()
}

fn status_field(pid: u32, key: &str) -> String {
    proc_file(pid, "status")
        .lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))
        .unwrap_or("")
        .trim()
        .to_string()
}

fn main_pid(unit: &str) -> u32 {
    run(
        "systemctl",
        &["--user", "show", "-p", "MainPID", "--value", unit],
    )
    .parse()
    .unwrap_or(0)
}

/// After a job slice was stopped: its container NAME stopped with it (conmon went too, so podman's `--rm` never ran
/// and the exited container is the runner's cleanup to remove); the test removes it.
fn stopped_with_its_slice(name: &str) {
    skuld::wait_until(&format!("{name} stopped with its slice"), 120, || {
        let out = Command::new("podman")
            .args(["inspect", "-f", "{{.State.Running}}", name])
            .output()
            .ok()?;
        let running = String::from_utf8_lossy(&out.stdout).trim() == "true";
        (!running).then_some(())
    });
    let _ = Command::new("podman")
        .args(["rm", "-f", "-t", "0", name])
        .output();
    skuld::wait_until(&format!("{name} removed"), 120, || gone(name));
}

fn gone(name: &str) -> Option<()> {
    let out = Command::new("podman")
        .args(["container", "exists", name])
        .output()
        .ok()?;
    (!out.status.success()).then_some(())
}

fn unit_req(name: &str, id: &str, log: &Path, argv: Vec<String>) -> unit::UnitReq {
    unit::UnitReq {
        unit: name.into(),
        id: id.into(),
        attempt: 1,
        slice: slices::job_slice(ROOT, id).unwrap(),
        runtime_max_s: 600,
        log: log.to_path_buf(),
        env: vec![],
        argv,
        binds_to: None,
    }
}

/// The sleipnir binary in the runner (`fleet.sh put` puts it in /fleet/share).
fn sleipnir_bin() -> String {
    std::env::var("SLEIPNIR_TEST_BIN")
        .unwrap_or_else(|_| env!("CARGO_BIN_EXE_sleipnir").to_string())
}

fn spec(id: &str, j: &JobDir, argv: Vec<String>) -> JobExec {
    JobExec {
        id: id.into(),
        attempt: 1,
        machine: "runner".into(),
        slice: slices::job_slice(ROOT, id).unwrap(),
        argv,
        env: vec![],
        cwd: None,
        log: j.dir.join(format!("{id}.1.log")),
        state_logs: vec![],
        keyed: false,
        parser: Parser::Exit,
        expect: forseti::Expect::default(),
        grant: forseti::Grant {
            cores: 1,
            mem_cap_mib: 256,
            reserve_mib: 128,
        },
        timeout_s: 300,
        helper: None,
    }
}

/// Starts SPEC as its unit running `sleipnir job-exec`.
fn start_job(name: &str, s: &JobExec, j: &JobDir) {
    s.write(&j.dir).unwrap();
    unit::start(&unit_req(
        name,
        &s.id,
        &s.log,
        vec![
            sleipnir_bin(),
            "job-exec".into(),
            j.dir.display().to_string(),
        ],
    ))
    .unwrap();
}

fn result_of(j: &JobDir) -> ResultJson {
    skuld::wait_until("result.json", 300, || ResultJson::read(&j.dir).ok())
}

/// [C] The slice tree takes the container (jobq spike 1's readings, on the runner's own tree): a container started
/// by a unit in the job's slice lands under `<root>-work-<id>.slice`; `AllowedCPUs` on the work slice reaches it,
/// through systemd or the direct write; `MemoryMax` on the root bounds it; it runs at OOM score 1000, while the podman
/// client and conmon stay in the unit at 900.
#[test]
#[ignore = "runner-host"]
fn slice_tree_takes_the_container() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Workstation).unwrap();
    let p = probe();
    let root_dir = p.slice_dir(&format!("{ROOT}.slice"));
    assert_eq!(
        std::fs::read_to_string(root_dir.join("cpu.weight"))
            .unwrap()
            .trim(),
        "20"
    );
    slices::set(&format!("{ROOT}.slice"), &[("MemoryMax", "1G".into())]).unwrap();
    let log = j.dir.join("s1.log");
    unit::start(&unit_req(
        "sltest-s1-1",
        "s1",
        &log,
        podman_run("s1", &j.source, &j.target, "256M", &["sleep", "600"]),
    ))
    .unwrap();
    let pid = running_pid("sltest-run-s1");
    // 1. under the job slice
    let cg = cgroup_of(pid);
    assert!(
        cg.contains("/sltest.slice/sltest-work.slice/sltest-work-s1.slice/"),
        "{cg}"
    );
    // 3. the root's cap
    assert_eq!(
        std::fs::read_to_string(root_dir.join("memory.max"))
            .unwrap()
            .trim(),
        "1073741824"
    );
    // 4. OOM scores: the container 1000; the podman client and conmon in the unit, at 900
    assert_eq!(proc_file(pid, "oom_score_adj").trim(), "1000");
    let conmon: u32 = run(
        "podman",
        &["inspect", "-f", "{{.State.ConmonPid}}", "sltest-run-s1"],
    )
    .parse()
    .unwrap();
    let client = main_pid("sltest-s1-1.service");
    for (who, q) in [("conmon", conmon), ("the podman client", client)] {
        assert!(
            cgroup_of(q).ends_with("/sltest-work-s1.slice/sltest-s1-1.service"),
            "{who}: {}",
            cgroup_of(q)
        );
        assert_eq!(proc_file(q, "oom_score_adj").trim(), "900", "{who}");
    }
    // 2. the cpuset, as the probe found systemd, and the direct write (the fallback) on its own
    // (a CPU the runner itself may use: a confined machine's online list is wider than its cpuset)
    let cpu = p.cpus_usable().unwrap()[0].to_string();
    let by_systemd = p.cpuset_by_systemd().unwrap();
    slices::set_cpus(&p.manager, &format!("{ROOT}-work.slice"), &cpu, by_systemd).unwrap();
    assert_eq!(
        status_field(pid, "Cpus_allowed_list"),
        cpu,
        "systemd writes cpusets: {by_systemd}"
    );
    slices::set_cpus(&p.manager, &format!("{ROOT}-work.slice"), "", by_systemd).unwrap();
    slices::direct_cpus(&p.manager, &format!("{ROOT}-work.slice"), &cpu).unwrap();
    assert_eq!(
        status_field(pid, "Cpus_allowed_list"),
        cpu,
        "the direct write"
    );
    slices::direct_cpus(&p.manager, &format!("{ROOT}-work.slice"), "").unwrap();
    slices::set_cpus(&p.manager, &format!("{ROOT}-work.slice"), "", true).unwrap();
    slices::stop(&slices::job_slice(ROOT, "s1").unwrap()).unwrap();
    stopped_with_its_slice("sltest-run-s1");
    slices::set(
        &format!("{ROOT}.slice"),
        &[("MemoryMax", "infinity".into())],
    )
    .unwrap();
}

/// [C] The cap's step against a job that holds memory it can't give back (tmpfs, no swap), as jobq spike 3 measured
/// it: `MemoryHigh` drops at once, `MemoryMax` comes down a step at a time, and the step that crosses the job's use
/// ends in a kernel OOM (`oom_kill` grows: the verdict is `oom`), while the slice's pressure stays below oomd's 80 %.
#[test]
#[ignore = "runner-host"]
fn throttle_stays_below_oomd() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Dedicated).unwrap();
    let p = probe();
    let root = format!("{ROOT}.slice");
    let js = slices::job_slice(ROOT, "s3").unwrap();
    let (mut high, mut max) = (2048u64, 2048u64);
    slices::set(
        &root,
        &[
            ("MemoryHigh", format!("{high}M")),
            ("MemoryMax", format!("{max}M")),
        ],
    )
    .unwrap();
    let fill = "head -c 768M /dev/zero > /tmp/fill && exec sleep 600";
    let log = j.dir.join("s3.log");
    unit::start(&unit_req(
        "sltest-s3-1",
        "s3",
        &log,
        podman_run("s3", &j.source, &j.target, "1G", &["sh", "-c", fill]),
    ))
    .unwrap();
    running_pid("sltest-run-s3");
    let before = skuld::wait_until("the job holds 768 MiB", 120, || {
        p.cgroup(&js).ok().filter(|s| s.current >= 768 << 20)
    });
    assert_eq!(before.oom_kill, 0);
    // the cap toward 128 MiB, one tick at a time, until the kernel steps in
    let target = 128;
    let mut steps = 0;
    while p.cgroup(&js).map(|s| s.oom_kill).unwrap_or(0) == 0 && steps < 8 {
        let w = forseti::safety::cap_step(high, max, target, 1024);
        assert!(w.max <= max && w.high == target, "{w:?}");
        slices::set(&root, &[("MemoryHigh", format!("{}M", w.high))]).unwrap();
        slices::set(&root, &[("MemoryMax", format!("{}M", w.max))]).unwrap();
        (high, max) = (w.high, w.max);
        steps += 1;
        if max < 768 {
            break;
        }
    }
    let after = skuld::wait_until("the kernel's OOM in the job slice", 60, || {
        p.cgroup(&js).ok().filter(|s| s.oom_kill > 0)
    });
    let full = p
        .cgroup(&root.replace(".slice", "-work.slice"))
        .ok()
        .and_then(|s| s.memory_pressure.full)
        .map(|f| f.avg10)
        .unwrap_or(0.0);
    assert!(
        full < 80.0,
        "the work slice's full pressure {full} reached oomd's limit"
    );
    assert_eq!(
        forseti::classify::classify(&forseti::classify::ExitEvidence {
            oom_kill_grew: after.oom_kill > 0,
            exit_code: Some(137),
            ..Default::default()
        }),
        forseti::Verdict::Oom
    );
    assert_eq!(
        steps, 2,
        "1 GiB steps from 2048 MiB: 1024, then 640 (target + 512), which crosses 768"
    );
    // the cap off first: under it the tmpfs the job still holds keeps the root slice at its limit, and podman's own
    // cleanup in it can't run
    slices::set(
        &root,
        &[
            ("MemoryHigh", "infinity".into()),
            ("MemoryMax", "infinity".into()),
        ],
    )
    .unwrap();
    slices::stop(&js).unwrap();
    // after the kernel's OOM under the root's cap podman kept reporting the container as running for minutes, so it
    // is removed by force here rather than waited on
    let _ = Command::new("podman")
        .args(["rm", "-f", "-t", "0", "sltest-run-s3"])
        .output();
    skuld::wait_until("sltest-run-s3 removed", 120, || gone("sltest-run-s3"));
}

/// [C] A job's unit runs job-exec in its own slice; job-exec runs the podman client inside its service, and the
/// container lands beside it in the same slice; when the job ends, `result.json` says so.
#[test]
#[ignore = "runner-host"]
fn a_job_runs_in_its_own_slice_with_its_containers() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Dedicated).unwrap();
    let wait = "until [ -e /work/go ]; do sleep 0.1; done; echo the job ran";
    let s = spec(
        "j1",
        &j,
        podman_run("j1", &j.source, &j.target, "256M", &["sh", "-c", wait]),
    );
    start_job("sltest-j1-1", &s, &j);
    let pid = running_pid("sltest-run-j1");
    let exec_pid = main_pid("sltest-j1-1.service");
    assert!(
        cgroup_of(exec_pid).ends_with("/sltest-work-j1.slice/sltest-j1-1.service"),
        "{}",
        cgroup_of(exec_pid)
    );
    assert_eq!(proc_file(exec_pid, "comm").trim(), "sleipnir");
    assert_eq!(proc_file(exec_pid, "oom_score_adj").trim(), "900");
    let conmon: u32 = run(
        "podman",
        &["inspect", "-f", "{{.State.ConmonPid}}", "sltest-run-j1"],
    )
    .parse()
    .unwrap();
    assert!(
        cgroup_of(conmon).ends_with("/sltest-j1-1.service"),
        "conmon: {}",
        cgroup_of(conmon)
    );
    assert!(
        cgroup_of(pid).contains("/sltest-work-j1.slice/libpod-"),
        "{}",
        cgroup_of(pid)
    );
    assert_eq!(proc_file(pid, "oom_score_adj").trim(), "1000");
    std::fs::write(j.source.join("go"), b"").unwrap();
    let r = result_of(&j);
    assert_eq!(r.verdict, forseti::Verdict::Pass, "{r:?}");
    assert!(
        std::fs::read_to_string(&s.log)
            .unwrap()
            .contains("the job ran")
    );
    assert!(r.wall_s > 0.0 && r.machine == "runner");
    skuld::wait_until("the container gone", 120, || gone("sltest-run-j1"));
}

/// [C] A container that runs out of its memory is the job's `oom`, never a crash, and the rest of the job's slice
/// goes with it.
#[test]
#[ignore = "runner-host"]
fn oom_in_a_job_is_oom() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Dedicated).unwrap();
    let s = spec(
        "o1",
        &j,
        podman_run(
            "o1",
            &j.source,
            &j.target,
            "128M",
            &["sh", "-c", "head -c 512M /dev/zero > /tmp/fill"],
        ),
    );
    start_job("sltest-o1-1", &s, &j);
    let r = result_of(&j);
    assert_eq!(r.verdict, forseti::Verdict::Oom, "{r:?}");
    skuld::wait_until("the job's unit stopped", 120, || {
        (!unit::active("sltest-o1-1.service")).then_some(())
    });
    stopped_with_its_slice("sltest-run-o1");
}

/// [C] A keyed job refuses to start unless its service can't swap: started without `MemorySwapMax=0` it is
/// `infra: setup` and its command never runs; through `unit::start` (which sets it) it runs.
#[test]
#[ignore = "runner-host"]
fn a_keyed_job_refuses_without_swap_max_0() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Dedicated).unwrap();
    let ran = j.dir.join("ran");
    let mut s = spec("k1", &j, vec!["touch".into(), ran.display().to_string()]);
    s.keyed = true;
    s.write(&j.dir).unwrap();
    let dir = j.dir.display().to_string();
    let bin = sleipnir_bin();
    run(
        "systemd-run",
        &[
            "--user",
            "--quiet",
            "--collect",
            "--unit=sltest-k1-0.service",
            &format!("--slice={}", s.slice),
            &bin,
            "job-exec",
            &dir,
        ],
    );
    let r = result_of(&j);
    assert_eq!(r.verdict, forseti::Verdict::Infra("setup".into()), "{r:?}");
    assert!(!ran.exists(), "the keyed command ran where it could swap");
    std::fs::remove_file(j.dir.join("result.json")).unwrap();
    start_job("sltest-k1-1", &s, &j);
    let r = result_of(&j);
    assert_eq!(r.verdict, forseti::Verdict::Pass, "{r:?}");
    assert!(ran.exists());
}

/// A child of `a_job_survives_its_starter`: starts the job, announces `started`, and parks until it is killed.
#[test]
#[ignore = "runner-host"]
fn child_starts_a_job() {
    let Ok(dir) = std::env::var("SLEIPNIR_STARTER_DIR") else {
        return;
    };
    let dir = PathBuf::from(dir);
    let s = JobExec::read(&dir).unwrap();
    unit::start(&unit_req(
        "sltest-v1-1",
        "v1",
        &s.log,
        vec![sleipnir_bin(), "job-exec".into(), dir.display().to_string()],
    ))
    .unwrap();
    std::fs::write(dir.join("started"), b"").unwrap();
    skuld::wait_until("the test kills the starter", 600, || None::<()>);
}

/// [C] A job outlives whoever started it: the starter is killed while the job waits, and the job still finishes and
/// writes its result.
#[test]
#[ignore = "runner-host"]
fn a_job_survives_its_starter() {
    let j = job_dir();
    slices::ensure_tree(ROOT, forseti::Profile::Dedicated).unwrap();
    let go = j.dir.join("go");
    let wait = format!(
        "until [ -e {} ]; do sleep 0.1; done; echo finished",
        go.display()
    );
    let s = spec("v1", &j, vec!["sh".into(), "-c".into(), wait]);
    s.write(&j.dir).unwrap();
    let mut starter = child(
        "child_starts_a_job",
        &[("SLEIPNIR_STARTER_DIR", j.dir.to_str().unwrap())],
    );
    skuld::wait_until("the job started", 60, || exists(&j.dir.join("started")));
    starter.kill().unwrap();
    starter.wait().unwrap();
    assert!(
        unit::active("sltest-v1-1.service"),
        "the job died with its starter"
    );
    std::fs::write(&go, b"").unwrap();
    let r = result_of(&j);
    assert_eq!(r.verdict, forseti::Verdict::Pass, "{r:?}");
    assert!(
        std::fs::read_to_string(&s.log)
            .unwrap()
            .contains("finished")
    );
}

// ---- the fake runner itself (moved from test/runners/s1): it passes the contract's checks ----

/// [D] podman there reports cgroup v2, the systemd manager and the `memory pids cpu` controllers, so the caps hold.
#[test]
#[ignore = "runner-host"]
fn check_limits_passes_inside_a_fake_runner() {
    let env: Vec<(std::ffi::OsString, std::ffi::OsString)> = [
        "PATH",
        "HOME",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
    ]
    .iter()
    .filter_map(|k| Some((k.into(), std::env::var_os(k)?)))
    .collect();
    podman::check_limits(Path::new("podman"), &env, Duration::from_secs(60)).unwrap();
    let facts = sleipnir::linux::probe::contract(&probe(), Path::new("podman")).unwrap();
    assert!(
        facts.linger
            && facts
                .podman_version
                .split('.')
                .next()
                .unwrap()
                .parse::<u32>()
                .unwrap()
                >= 5,
        "{facts:?}"
    );
}

/// [D] A container started in a unit with `--cgroup-parent` lands in the unit's slice (without it podman puts it
/// under `user.slice`). The caller waits on the unit (`--wait`), not on time.
#[test]
#[ignore = "runner-host"]
fn a_capped_container_runs_in_a_transient_slice() {
    let script = format!(
        "podman run -d --name s1-cap --cgroup-parent=s1-work-x.slice --memory=256m --memory-swap=256m {BASE} sleep 120 >/dev/null \
         && podman inspect -f '{{{{.State.CgroupPath}}}}' s1-cap; podman rm -f -t 0 s1-cap >/dev/null"
    );
    let path = run(
        "systemd-run",
        &[
            "--user",
            "--pipe",
            "--wait",
            "--collect",
            "--slice=s1-work-x.slice",
            "sh",
            "-c",
            &script,
        ],
    );
    assert!(
        path.contains("/s1-work-x.slice/"),
        "the container's cgroup is outside the slice: {path}"
    );
}

/// [D]
#[test]
#[ignore = "runner-host"]
fn the_container_gets_its_caps() {
    let out = run(
        "podman",
        &[
            "run",
            "--rm",
            "--memory=256m",
            "--memory-swap=256m",
            "--pids-limit=100",
            BASE,
            "sh",
            "-c",
            "cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max",
        ],
    );
    assert_eq!(
        out.split_whitespace().collect::<Vec<_>>(),
        ["268435456", "100"]
    );
}

/// [D] The runner user lingers, so its manager outlives any login (the ssh half is `fleet.sh check-linger`).
#[test]
#[ignore = "runner-host"]
fn linger_keeps_a_unit_after_the_session_ends() {
    assert_eq!(
        run("loginctl", &["show-user", "runner", "-P", "Linger"]),
        "yes"
    );
}

// ---- the bench (the runner's modes: the default features) ----

/// [C] The bench's workload runs in its capped container and reports its own readings: inside it `memory.max` is
/// 512 MiB and `cpu.max` one core; the run ends within the bench's 2-minute bound (past it the bench fails, so a
/// result is the proof), with a speed, the machine's cores and memory, and leaves no container behind.
#[cfg(feature = "runner")]
#[test]
#[ignore = "runner-host"]
fn bench_runs_capped_and_under_2_minutes() {
    let d = tempfile::tempdir_in(std::env::var("HOME").unwrap()).unwrap();
    let (result, t) = sleipnir::bench::run(d.path(), &base_ref()).unwrap();
    assert_eq!(
        (t.memory_max.as_str(), t.cpu_max.as_str()),
        ("536870912", "100000 100000"),
        "{t:?}"
    );
    assert!(t.cpu_s > 0.0 && t.io_s > 0.0, "{t:?}");
    assert!(
        result.speed > 0.0 && result.cores >= 1 && result.mem_mib > 0,
        "{result:?}"
    );
    assert_eq!(
        run(
            "podman",
            &[
                "ps",
                "-a",
                "--filter",
                "name=^drgnx-bench-",
                "--format",
                "{{.Names}}"
            ]
        ),
        "",
        "the bench's container is left"
    );
}
