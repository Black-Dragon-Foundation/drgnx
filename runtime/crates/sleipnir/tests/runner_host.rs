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
