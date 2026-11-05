//! The hub's runner rows over real SSH to a real `sleipnir serve` in a fake runner (`#[ignore = "fleet"]`,
//! test/runners/): the link session, the queue's placement, the health check. They run in a fleet's harness only:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --test fleet_runners --no-run
//! cargo build -p sleipnir --features test-hooks        # the bundle each row installs (fleet.sh test shares it)
//! fleet.sh up --runners 1
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1
//! ```
//!
//! Each row installs the shared `sleipnir` (a `test-hooks` build) into a runner root of its own and writes the quiet
//! machine's figures there (`test-machine.json`), so admission reads the fake runner, not the desktop's load and
//! disk. Every row is [C]: a real `serve`, and the jobs it starts, announce their state in frames or files, and the
//! row waits on that state; a job that must stay running parks on a FIFO in its container until the row writes to it.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::link::{LinkEvent, Route, Session};
use drgnx_ratatoskr::runners::transport::{Channel, Channels};
use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, Weight};
use sleipnir::proto::{AttemptState, Frame, JobRef, Nonce, PROTO_VERSION};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;

/// How long a row waits on any one announced state before it fails.
const WAIT: u64 = 120;

/// The machine the rows' runners report to admission: idle, with room.
const QUIET_MACHINE: &str = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
"disk_free_gb": 100, "disk_total_gb": 200, "mem_available_mib": 8192}"#;

fn ssh_config() -> String {
    format!("{}/.ssh/config", std::env::var("HOME").unwrap())
}

fn ssh(runner: &str) -> Command {
    let mut c = Command::new("ssh");
    c.args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner]);
    c
}

/// SCRIPT's stdout on RUNNER; panics when it fails.
fn sh_bytes(runner: &str, script: &str) -> Vec<u8> {
    let out = ssh(runner).arg(script).output().expect("ssh");
    assert!(
        out.status.success(),
        "{runner}: {script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}

fn sh(runner: &str, script: &str) -> String {
    String::from_utf8_lossy(&sh_bytes(runner, script))
        .trim()
        .to_string()
}

/// A fresh runner root at ~/NAME on RUNNER: the shared `sleipnir` as bundle `test`, and the quiet machine.
fn root(runner: &str, name: &str) -> String {
    let share =
        std::env::var("DRGNX_FLEET_SHARE").expect("DRGNX_FLEET_SHARE: run through fleet.sh test");
    assert!(
        PathBuf::from(&share).join("sleipnir").exists(),
        "fleet.sh test puts sleipnir in the share"
    );
    let home = sh(runner, "echo $HOME");
    let root = format!("{home}/{name}");
    sh(
        runner,
        &format!(
            "rm -rf {root} && mkdir -p {root}/bin/test && cp /fleet/share/sleipnir {root}/bin/test/sleipnir \
             && printf %s '{QUIET_MACHINE}' > {root}/test-machine.json"
        ),
    );
    root
}

/// The fake runner's base image, by digest.
fn image(runner: &str) -> String {
    let d = sh(
        runner,
        "podman image inspect registry.fedoraproject.org/fedora:45 --format '{{.Digest}}'",
    );
    format!("registry.fedoraproject.org/fedora@{d}")
}

fn spec(script: &str) -> JobSpec {
    JobSpec {
        name: "fleet".into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/p"),
        cwd: PathBuf::from("."),
        command: vec!["sh".into(), "-c".into(), script.into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range { min: 64, max: 256 },
        disk_gib: 0,
        timeout_s: 600,
        restartable: true,
        writes_tree: false,
        priority: None,
        for_user: None,
        gate: None,
        expect: Expect::default(),
        outputs: vec![],
        state: vec![],
        on: None,
        lane: Lane::Work,
        fresh: false,
        stop_on_red: false,
        project: "p".into(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

/// The hub's log of one attempt: only frames about R (its nonce too) are written, to PATH.
struct OneLog {
    r: JobRef,
    path: PathBuf,
}

impl Route for OneLog {
    fn log_path(&self, _runner: &str, r: &JobRef) -> Option<PathBuf> {
        (*r == self.r).then(|| self.path.clone())
    }
}

/// A link to `serve` in ROOT on RUNNER over one `ssh` (its stdin and stdout are the control channel).
struct Link {
    session: Session,
    events: UnboundedReceiver<LinkEvent>,
    child: tokio::process::Child,
}

impl Link {
    fn open(runner: &str, root: &str, prefix: &str, hub: &str, route: Arc<dyn Route>) -> Link {
        let mut child = tokio::process::Command::new("ssh")
            .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
            .arg(format!(
                "{root}/bin/test/sleipnir serve --root {root} --prefix {prefix} --hub-id {hub} --profile dedicated"
            ))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .expect("ssh");
        let control = Channel::new(
            Box::new(child.stdin.take().unwrap()),
            Box::new(child.stdout.take().unwrap()),
        );
        let idle = || Channel::new(Box::new(tokio::io::sink()), Box::new(tokio::io::empty()));
        let channels = Channels {
            control,
            bulk_in: idle(),
            bulk_out: idle(),
        };
        let (tx, events) = tokio::sync::mpsc::unbounded_channel();
        Link {
            session: Session::start(runner, channels, route, tx),
            events,
            child,
        }
    }

    fn send(&self, f: Frame) {
        assert!(self.session.send(f), "the link has ended");
    }

    /// The first event PICK takes, within the wait.
    async fn next<T>(&mut self, what: &str, mut pick: impl FnMut(&LinkEvent) -> Option<T>) -> T {
        let events = &mut self.events;
        skuld::wait_until_async(what, WAIT, || {
            let mut got = None;
            while got.is_none() {
                match events.try_recv() {
                    Ok(e) => got = pick(&e),
                    Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                    Err(e) => panic!("the link's events ended while waiting for {what}: {e}"),
                }
            }
            std::future::ready(got)
        })
        .await
    }

    async fn frame<T>(&mut self, what: &str, mut pick: impl FnMut(&Frame) -> Option<T>) -> T {
        self.next(what, |e| match e {
            LinkEvent::Frame { frame, .. } => pick(frame),
            LinkEvent::Lost { why, .. } => panic!("the link was lost waiting for {what}: {why}"),
            _ => None,
        })
        .await
    }

    async fn hello(&mut self, hub: &str) -> Vec<sleipnir::proto::AttemptInfo> {
        self.send(Frame::Hello {
            version: PROTO_VERSION,
            hub_id: hub.into(),
        });
        self.frame("hello-ok", |f| match f {
            Frame::HelloOk { attempts, .. } => Some(attempts.clone()),
            _ => None,
        })
        .await
    }

    /// Cuts the channel: ssh killed, so `serve` sees an EOF without `bye`.
    async fn cut(mut self) {
        let _ = self.child.kill().await;
    }
}

mod link {
    use super::*;

    /// [C] A job writes a log of several chunks; the channel is cut mid-log; a new link reattaches at the hub's offset;
    /// after the job ends, the hub's copy equals the runner's file byte for byte (no chunk lost or doubled).
    #[tokio::test]
    #[ignore = "fleet"]
    async fn the_hubs_log_equals_the_runners_byte_for_byte_after_a_cut() {
        let (r1, prefix, hub) = ("r1", "flcut", "hubcut");
        let root = root(r1, "fl-cut");
        let img = image(r1);
        let dir = tempfile::tempdir().unwrap();
        let r = JobRef {
            job: "j1".into(),
            attempt: 1,
            nonce: Nonce([7; 16]),
        };
        let path = dir.path().join("log");
        let route = Arc::new(OneLog {
            r: r.clone(),
            path: path.clone(),
        });
        let mut a = Link::open(r1, &root, prefix, hub, route.clone());
        assert_eq!(a.hello(hub).await, []);
        // 3 MiB and more of log, then a line, then it parks until released
        let script = "head -c 3500000 /dev/zero | tr '\\0' x; echo; echo started; mkfifo /tmp/gate; \
                      read x < /tmp/gate; echo released";
        a.send(Frame::Offer {
            r: r.clone(),
            spec: Box::new(spec(script)),
            priority: Priority::P3,
            input_key: String::new(),
            grant_hint: None,
            expected: None,
        });
        let admitted = a
            .frame("admit or refuse", |f| match f {
                Frame::Admit { r: x, .. } if *x == r => Some(Ok(())),
                Frame::Refuse { r: x, why, .. } if *x == r => Some(Err(why.clone())),
                _ => None,
            })
            .await;
        assert_eq!(admitted, Ok(()));
        a.send(Frame::Start {
            r: r.clone(),
            image: Some(img),
            env: vec![],
            net_hosts: vec![],
            parser: "exit".into(),
        });
        a.frame("started", |f| {
            matches!(f, Frame::Started { r: x, .. } if *x == r).then_some(())
        })
        .await;
        // the cut: after the first chunk reached the hub's copy
        a.next("a first log chunk", |e| match e {
            LinkEvent::Logged { upto, .. } if *upto > 0 => Some(()),
            _ => None,
        })
        .await;
        a.cut().await;
        let held = std::fs::metadata(&path).map_or(0, |m| m.len());
        let mut b = Link::open(r1, &root, prefix, hub, route);
        let listed = b.hello(hub).await;
        assert_eq!(listed.len(), 1, "{listed:?}");
        assert_eq!((&listed[0].r, listed[0].state), (&r, AttemptState::Running));
        b.send(Frame::Attach {
            r: r.clone(),
            log_offset: held,
        });
        // the job parks after `started`: release it once the hub's copy shows it
        b.next("the log to show `started`", |e| match e {
            LinkEvent::Logged { .. } => std::fs::read(&path)
                .ok()
                .filter(|l| l.ends_with(b"started\n"))
                .map(|_| ()),
            _ => None,
        })
        .await;
        sh(
            r1,
            &format!("podman exec {prefix}-j1 sh -c 'echo go > /tmp/gate'"),
        );
        let result = b
            .frame("finished", |f| match f {
                Frame::Finished { r: x, result } if *x == r => Some(result.clone()),
                _ => None,
            })
            .await;
        assert_eq!(result["verdict"], "Pass", "{result}");
        let theirs = sh_bytes(r1, &format!("cat {root}/jobs/j1.1/log"));
        let ours = std::fs::read(&path).unwrap();
        assert!(theirs.len() > 3_500_000, "{}", theirs.len());
        assert!(
            ours == theirs,
            "the hub's copy ({} bytes) differs from the runner's ({} bytes)",
            ours.len(),
            theirs.len()
        );
        b.send(Frame::Done { r });
        b.send(Frame::Bye { why: "test".into() });
        b.next("bye", |e| matches!(e, LinkEvent::Bye { .. }).then_some(()))
            .await;
    }
}
