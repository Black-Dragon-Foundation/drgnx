//! The orphan reaper against real children of this test, each in its own process group. Only those groups are ever
//! signalled for real; the guard tests use a spy that sends nothing but `0` probes.

use draugr::reap::GRACE;
use draugr::{
    Child, RealSignaller, ReapOutcome, Record, Signaller, Skip, Spec, boot_id, env, kill_group,
    reap, spawn, start_time,
};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::time::timeout;

/// No reap in these tests may take longer (SIGKILL after 2 s, a 5 s wait after that).
const LIMIT: Duration = Duration::from_secs(20);

/// Records every call. Probes (signal 0, which sends nothing) go to the real `kill`; other signals only when `real`.
struct Spy {
    real: bool,
    calls: Mutex<Vec<(i32, i32)>>,
}

impl Spy {
    fn probes_only() -> Self {
        Spy {
            real: false,
            calls: Mutex::new(vec![]),
        }
    }
    fn real() -> Self {
        Spy {
            real: true,
            calls: Mutex::new(vec![]),
        }
    }
    fn calls(&self) -> Vec<(i32, i32)> {
        self.calls.lock().unwrap().clone()
    }
    /// The calls that were not probes.
    fn sent(&self) -> Vec<(i32, i32)> {
        self.calls().into_iter().filter(|&(_, s)| s != 0).collect()
    }
}

impl Signaller for Spy {
    fn kill(&self, target: i32, sig: i32) -> std::io::Result<()> {
        self.calls.lock().unwrap().push((target, sig));
        if sig == 0 || self.real {
            RealSignaller.kill(target, sig)
        } else {
            Ok(())
        }
    }
}

/// `sh -c SCRIPT`, a child of this test leading its own group. Dropping it SIGKILLs that group while it exists
/// (POSIX does not reuse a group id while the group exists, so a live group with this id is still ours).
struct Group {
    child: Child,
    pgid: i32,
}

impl Group {
    async fn start(script: &str) -> Group {
        let child = spawn(Spec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: env::build(&["PATH"], &[], &[]),
            cwd: None,
            stdin_null: false,
        })
        .await
        .unwrap();
        let pgid = child.id();
        assert!(pgid > 1);
        Group { child, pgid }
    }

    /// Wait for the script's `echo ready`.
    async fn ready(&mut self) {
        let mut lines = BufReader::new(self.child.take_stdout().unwrap()).lines();
        assert_eq!(lines.next_line().await.unwrap().as_deref(), Some("ready"));
    }

    /// The row the hub would have written for this child.
    fn record(&self) -> Record {
        Record {
            pid: Some(self.pgid),
            start_time: Some(start_time(self.pgid).unwrap()),
            pgid: Some(self.pgid),
            boot_id: Some(boot_id().unwrap()),
        }
    }

    fn exists(&self) -> bool {
        unsafe { libc::kill(-self.pgid, 0) == 0 }
    }

    fn leader_alive(&self) -> bool {
        unsafe { libc::kill(self.pgid, 0) == 0 }
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        if self.exists() {
            unsafe { libc::kill(-self.pgid, libc::SIGKILL) };
        }
    }
}

/// A `sleep 60` in this test's own process group (not its own), killed by pid when dropped.
struct Sentinel(std::process::Child);

impl Drop for Sentinel {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn recorded_live_group_is_killed() {
    let mut g = Group::start("sleep 60 & sleep 60 & echo ready; wait").await;
    g.ready().await;
    let recs = [g.record()];
    let spy = Spy::real();
    let (out, status) = tokio::join!(timeout(LIMIT, reap(&recs, &spy)), g.child.wait());
    assert_eq!(out.unwrap(), vec![ReapOutcome::Killed]);
    assert!(!status.unwrap().unwrap().success());
    assert!(!g.exists(), "both sleeps are gone");
    assert_eq!(spy.sent(), vec![(-g.pgid, libc::SIGTERM)]);
}

#[tokio::test]
async fn a_reused_pid_is_left_alone() {
    let g = Group::start("exec sleep 60").await;
    let mut rec = g.record();
    rec.start_time = rec.start_time.map(|t| t - 1);
    let spy = Spy::probes_only();
    assert_eq!(
        timeout(LIMIT, reap(&[rec], &spy)).await.unwrap(),
        vec![ReapOutcome::Reused]
    );
    assert_eq!(spy.sent(), vec![]);
    assert!(g.leader_alive());
}

#[tokio::test]
async fn a_term_ignoring_group_gets_kill_after_2s() {
    let mut g = Group::start("trap '' TERM; sleep 60 & echo ready; wait").await;
    g.ready().await;
    let recs = [g.record()];
    let spy = Spy::real();
    let began = Instant::now();
    let (out, _) = tokio::join!(timeout(LIMIT, reap(&recs, &spy)), g.child.wait());
    assert_eq!(out.unwrap(), vec![ReapOutcome::Killed]);
    assert!(began.elapsed() >= GRACE, "{:?}", began.elapsed());
    assert!(!g.exists());
    assert_eq!(
        spy.sent(),
        vec![(-g.pgid, libc::SIGTERM), (-g.pgid, libc::SIGKILL)]
    );
}

#[tokio::test]
async fn a_row_without_a_pid_kills_nothing() {
    let g = Group::start("exec sleep 60").await;
    let full = g.record();
    let mut sentinel = Sentinel(
        std::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .unwrap(),
    );
    let rows = [
        Record {
            pid: None,
            ..full.clone()
        },
        Record {
            pgid: None,
            ..full.clone()
        },
        Record {
            pgid: Some(0),
            ..full.clone()
        },
        Record {
            start_time: None,
            ..full.clone()
        },
        Record {
            boot_id: None,
            ..full.clone()
        },
        Record::default(),
    ];
    let spy = Spy::probes_only();
    let out = timeout(LIMIT, reap(&rows, &spy)).await.unwrap();
    use ReapOutcome::Skipped;
    assert_eq!(
        out,
        vec![
            Skipped(Skip::NoPid),
            Skipped(Skip::NoPid),
            Skipped(Skip::Refused),
            Skipped(Skip::NoPid),
            Skipped(Skip::NoPid),
            Skipped(Skip::NoPid)
        ]
    );
    assert_eq!(spy.calls(), vec![]);
    assert!(
        sentinel.0.try_wait().unwrap().is_none(),
        "the sentinel in our own group is alive"
    );
    assert!(g.leader_alive());
}

#[tokio::test]
async fn pgid_one_and_own_group_are_refused() {
    let g = Group::start("exec sleep 60").await;
    let full = g.record();
    let me = std::process::id() as i32;
    let rows = [
        Record {
            pgid: Some(1),
            ..full.clone()
        },
        Record {
            pgid: Some(unsafe { libc::getpgrp() }),
            ..full.clone()
        },
        Record {
            pgid: Some(unsafe { libc::getsid(0) }),
            ..full.clone()
        },
        Record {
            pid: Some(me),
            start_time: Some(start_time(me).unwrap()),
            ..full.clone()
        },
    ];
    let spy = Spy::probes_only();
    let out = timeout(LIMIT, reap(&rows, &spy)).await.unwrap();
    assert_eq!(out, vec![ReapOutcome::Skipped(Skip::Refused); 4]);
    assert_eq!(spy.calls(), vec![]);
    assert!(g.leader_alive());
}

#[tokio::test]
async fn a_dead_leaders_live_group_is_killed() {
    let mut g = Group::start("sleep 60 & read x; exit").await;
    let rec = g.record();
    drop(g.child.take_stdin());
    assert!(
        g.child.wait().await.unwrap().is_some(),
        "the leader is reaped"
    );
    assert!(!g.leader_alive());
    assert!(g.exists(), "its sleep still holds the group");
    let spy = Spy::real();
    assert_eq!(
        timeout(LIMIT, reap(&[rec], &spy)).await.unwrap(),
        vec![ReapOutcome::Killed]
    );
    assert!(!g.exists());
}

#[tokio::test]
async fn another_boots_row_is_left_alone() {
    let g = Group::start("exec sleep 60").await;
    let rec = Record {
        boot_id: Some("other".into()),
        ..g.record()
    };
    let spy = Spy::probes_only();
    assert_eq!(
        timeout(LIMIT, reap(&[rec], &spy)).await.unwrap(),
        vec![ReapOutcome::Skipped(Skip::OtherBoot)]
    );
    assert_eq!(spy.calls(), vec![]);
    assert!(g.exists() && g.leader_alive());
}

#[tokio::test]
async fn kill_group_refuses_like_reap_and_kills_our_group() {
    let mut g = Group::start("exec sleep 60").await;
    let spy = Spy::probes_only();
    for pgid in [0, 1, -5, unsafe { libc::getpgrp() }, unsafe {
        libc::getsid(0)
    }] {
        assert_eq!(
            timeout(LIMIT, kill_group(pgid, GRACE, &spy)).await.unwrap(),
            ReapOutcome::Skipped(Skip::Refused),
            "pgid {pgid}"
        );
    }
    assert_eq!(spy.calls(), vec![]);
    let spy = Spy::real();
    let (out, _) = tokio::join!(
        timeout(LIMIT, kill_group(g.pgid, GRACE, &spy)),
        g.child.wait()
    );
    assert_eq!(out.unwrap(), ReapOutcome::Killed);
    assert!(!g.exists());
}

#[test]
fn alive_says_whether_one_process_exists() {
    let me = std::process::id() as i32;
    assert!(draugr::alive(me));
    // pid 1 exists; for a user it is someone else's (EPERM counts as alive)
    assert!(draugr::alive(1));
    // a group (negative), every process (-1) or our own group (0) is never one process
    for not_a_pid in [0, -1, -me, i32::MIN] {
        assert!(!draugr::alive(not_a_pid), "{not_a_pid}");
    }
    assert!(!draugr::alive(i32::MAX), "above any pid_max");
}
