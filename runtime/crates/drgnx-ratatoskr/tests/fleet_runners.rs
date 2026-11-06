//! The hub's runner rows over real SSH to a real `sleipnir serve` in a fake runner (`#[ignore = "fleet"]`,
//! test/runners/): the link session, the queue's placement, the health check. They run in a fleet's harness only:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet --test fleet_runners --no-run
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
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{
    Outcome, Placement, Queue, QueueCfg, RemoteRunner, SendMode, Submit,
};
use drgnx_ratatoskr::runners::transport::{Channel, Channels};
use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, Weight};
use serde_json::json;
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
        let (channels, child) = serve(runner, root, prefix, hub);
        let (tx, events) = tokio::sync::mpsc::unbounded_channel();
        Link {
            session: Session::start(runner, channels, route, tx),
            events,
            child,
        }
    }
}

/// `serve` in ROOT on RUNNER over one `ssh`: its stdin and stdout are the control channel.
fn serve(runner: &str, root: &str, prefix: &str, hub: &str) -> (Channels, tokio::process::Child) {
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
    (channels, child)
}

impl Link {
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

/// Drains the queue's link events into it, ticks it, and returns what CHECK makes of it, within the wait. The queue's
/// own loop does this in the hub.
async fn drive<T>(
    q: &Queue,
    events: &mut UnboundedReceiver<LinkEvent>,
    outcomes: &mut Vec<Outcome>,
    what: &str,
    check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
) -> T {
    drive_at(q, events, outcomes, what, 0, check).await
}

/// [`drive`] with the hub's clock OFFSET seconds off the runner's.
async fn drive_at<T>(
    q: &Queue,
    events: &mut UnboundedReceiver<LinkEvent>,
    outcomes: &mut Vec<Outcome>,
    what: &str,
    offset: u64,
    mut check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
) -> T {
    skuld::wait_until_async(what, WAIT, || {
        while let Ok(ev) = events.try_recv() {
            if let LinkEvent::Lost { why, .. } = &ev {
                panic!("the link was lost waiting for {what}: {why}");
            }
            outcomes.extend(q.on_link(ev, now() + offset));
        }
        outcomes.extend(q.tick(now() + offset).outcomes);
        std::future::ready(check(q, outcomes))
    })
    .await
}

/// A queue on a temporary folder whose one local slot JOB holds, and runner r1 (serve in ROOT) added with IMAGE for its
/// health check's canary.
fn queue_with_r1(
    dir: &std::path::Path,
    root: &str,
    prefix: &str,
    hub: &str,
    img: &str,
) -> (
    Arc<Queue>,
    UnboundedReceiver<LinkEvent>,
    tokio::process::Child,
) {
    let (q, events) = Queue::new(QueueCfg {
        hub_id: hub.into(),
        exec_root: dir.to_path_buf(),
        local: LocalRunner::new(Admission::Fixed(1), dir),
        db: None,
    });
    q.adopt("xbusy", Priority::P1, now());
    let (channels, child) = serve("r1", root, prefix, hub);
    let session = Session::start("r1", channels, q.route(), q.link_events());
    q.add_runner(
        RemoteRunner {
            name: "r1".into(),
            trust: forseti::RunnerTrust::Mine,
            accept: forseti::Accept::All,
            grace_s: 600,
            image: Some(img.into()),
        },
        session,
    );
    (q, events, child)
}

/// A heavy job ID for any runner, run in IMAGE (none: the runner can't start it).
fn heavy_job(id: &str, image: Option<&str>) -> Submit {
    let mut s = spec(&format!("echo {id}"));
    s.weight = Weight::Heavy;
    Submit {
        id: id.into(),
        session: Some("s1".into()),
        own: Priority::P3,
        spec: s,
        place: Placement {
            heavy: true,
            send: SendMode::Heavy,
            image: image.map(String::from),
            ..Placement::default()
        },
        pending: serde_json::Value::Null,
        inputs: None,
    }
}

/// Benches r1: two jobs it can't start (`infra: setup`, its strikes); waits for both verdicts.
async fn bench_r1(
    q: &Queue,
    events: &mut UnboundedReceiver<LinkEvent>,
    outcomes: &mut Vec<Outcome>,
) {
    for id in ["xbad1", "xbad2"] {
        q.submit(heavy_job(id, None), now());
    }
    drive(q, events, outcomes, "both jobs' verdicts", |_, o| {
        let done = o
            .iter()
            .filter(|o| matches!(o, Outcome::Done { id, .. } if id.starts_with("xbad")))
            .count();
        (done == 2).then_some(())
    })
    .await;
    for o in outcomes.iter() {
        if let Outcome::Done { id, result, .. } = o {
            assert_eq!(
                result["verdict"],
                json!({"Infra": "setup"}),
                "{id}: {result}"
            );
        }
    }
}

mod health {
    use super::*;

    /// [C] Two jobs r1 can't start (no image to run them in: `infra: setup`, a strike each) bench it; with this machine
    /// free again the next heavy job runs here, never on the benched runner.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_broken_image_twice_benches_and_jobs_run_elsewhere() {
        let (prefix, hub) = ("flbench", "hubbench");
        let root = root("r1", "fl-bench");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events, _child) = queue_with_r1(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        bench_r1(&q, &mut events, &mut outcomes).await;
        let r1 = q.runner("r1").expect("r1");
        assert!(r1.state.starts_with("benched: infra: setup ("), "{r1:?}");
        assert_eq!(r1.strikes, 2);
        q.release("xbusy");
        q.submit(heavy_job("xgood", Some(&img)), now());
        let row = drive(
            &q,
            &mut events,
            &mut outcomes,
            "the next job placed",
            |q, _| q.row("xgood").filter(|r| r.machine.is_some()),
        )
        .await;
        assert_eq!(row.machine.as_deref(), Some("local"), "{row:?}");
    }

    /// [C] A benched runner whose health check passes (the probe and the contract, the canary `true` in its image under
    /// the caps, disk above the guard, its clock within 2 s) is back in rotation with no strikes.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_passing_check_returns_with_zero_strikes() {
        let (prefix, hub) = ("flcheck", "hubcheck");
        let root = root("r1", "fl-check");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events, _child) = queue_with_r1(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        bench_r1(&q, &mut events, &mut outcomes).await;
        assert!(q.runner("r1").unwrap().state.starts_with("benched"));
        q.check_now("r1");
        // judged: back in rotation, or a third strike naming what failed
        let r1 = drive(
            &q,
            &mut events,
            &mut outcomes,
            "r1's check judged",
            |q, _| {
                q.runner("r1")
                    .filter(|r| r.state == "ready" || r.strikes > 2)
            },
        )
        .await;
        assert_eq!(r1.state, "ready", "{r1:?}");
        assert_eq!((r1.strikes, r1.last.as_deref()), (0, None), "{r1:?}");
    }

    /// [C] A runner whose clock is more than 2 s off the hub's fails its health check: a strike, saying so.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn clock_skew_over_2s_fails_the_check() {
        let (prefix, hub) = ("flskew", "hubskew");
        let root = root("r1", "fl-skew");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events, _child) = queue_with_r1(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        q.check_now("r1");
        // the hub's clock 5 s ahead of the runner's
        let r1 = drive_at(
            &q,
            &mut events,
            &mut outcomes,
            "r1's check judged",
            5,
            |q, _| q.runner("r1").filter(|r| r.strikes > 0),
        )
        .await;
        assert_eq!(r1.strikes, 1, "{r1:?}");
        let last = r1.last.unwrap_or_default();
        assert!(last.contains("clock is -5 s off the hub's"), "{last}");
    }
}

/// The wall clock as the queue takes it: a value, never waited on.
fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

mod queue {
    use super::*;

    /// [C] The project sends only heavy jobs (`drgnx-runners-send heavy`), and this machine's one slot is taken: the
    /// heavy job is offered to the runner and runs there, the light one waits here, saying why. A real `serve` admits
    /// and runs the heavy one; its result comes back through the link.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_job_marked_heavy_goes_to_the_runner_with_send_heavy() {
        let (r1, prefix, hub) = ("r1", "flheavy", "hubheavy");
        let root = root(r1, "fl-heavy");
        let img = image(r1);
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events) = Queue::new(QueueCfg {
            hub_id: hub.into(),
            exec_root: dir.path().to_path_buf(),
            local: LocalRunner::new(Admission::Fixed(1), dir.path()),
            db: None,
        });
        q.adopt("xbusy", Priority::P1, now());
        let (channels, _child) = serve(r1, &root, prefix, hub);
        let session = Session::start(r1, channels, q.route(), q.link_events());
        q.add_runner(
            RemoteRunner {
                name: r1.into(),
                trust: forseti::RunnerTrust::Mine,
                accept: forseti::Accept::All,
                grace_s: 600,
                image: Some(img.clone()),
            },
            session,
        );
        let place = |heavy: bool| Placement {
            heavy,
            send: SendMode::Heavy,
            image: Some(img.clone()),
            ..Placement::default()
        };
        let mut heavy = spec("echo heavy");
        heavy.weight = Weight::Heavy;
        for (id, spec, heavy) in [
            ("xheavy", heavy, true),
            ("xlight", spec("echo light"), false),
        ] {
            q.submit(
                Submit {
                    id: id.into(),
                    session: Some("s1".into()),
                    own: Priority::P3,
                    spec,
                    place: place(heavy),
                    pending: serde_json::Value::Null,
                    inputs: None,
                },
                now(),
            );
        }
        let mut outcomes = vec![];
        let heavy = drive(
            &q,
            &mut events,
            &mut outcomes,
            "the heavy job offered to r1",
            |q, _| q.row("xheavy").filter(|r| r.machine.is_some()),
        )
        .await;
        assert_eq!(
            (heavy.machine.as_deref(), heavy.attempt),
            (Some("r1"), Some(1))
        );
        let (attempt, result) = drive(
            &q,
            &mut events,
            &mut outcomes,
            "the heavy job's result",
            |_, o| {
                o.iter().find_map(|o| match o {
                    Outcome::Done {
                        id,
                        attempt,
                        result,
                        ..
                    } if id == "xheavy" => Some((*attempt, result.clone())),
                    _ => None,
                })
            },
        )
        .await;
        assert_eq!(
            (attempt, &result["verdict"]),
            (1, &json!("Pass")),
            "{result}"
        );
        let light = q.row("xlight").expect("the light job's row");
        assert_eq!(light.machine, None, "the light job left this machine");
        assert!(
            light.waiting.as_deref().is_some_and(|w| !w.is_empty()),
            "{light:?}"
        );
        let log = std::fs::read_to_string(dir.path().join("xheavy/log")).unwrap_or_default();
        assert!(log.contains("heavy"), "{log}");
    }
}

mod drill {
    use super::*;
    use drgnx_ratatoskr::runners::queue::{ROWS, Suite};

    /// [`drive`], with a lost link handed to the queue as the hub's own loop does.
    async fn drive_through_losses<T>(
        q: &Queue,
        events: &mut UnboundedReceiver<LinkEvent>,
        outcomes: &mut Vec<Outcome>,
        what: &str,
        mut check: impl FnMut(&[Outcome]) -> Option<T>,
    ) -> T {
        skuld::wait_until_async(what, WAIT, || {
            while let Ok(ev) = events.try_recv() {
                outcomes.extend(q.on_link(ev, now()));
            }
            outcomes.extend(q.tick(now()).outcomes);
            std::future::ready(check(outcomes))
        })
        .await
    }

    /// [C] A job of 240 rows (plist lines; a row runs when the selector the hub puts in its command picks it) runs on
    /// r1, a runner with no grace. It parks after row 150; once the hub's copy of its log shows that row, the link is
    /// cut. The hub takes rows 1–150 from its copy and requeues the job, and attempt 2 runs only rows 151–240, on r2.
    /// When r1 is back its late attempt 1 is stopped, so no row runs to its end twice. The result counts all 240 rows
    /// and says how they split.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_dropped_link_at_row_150_of_240_reruns_only_the_rest() {
        let (prefix, hub) = ("fldrill", "hubdrill");
        let (root1, root2) = (root("r1", "fl-drill"), root("r2", "fl-drill"));
        let img = image("r1");
        assert_eq!(image("r2"), img, "both runners hold the same base image");
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events) = Queue::new(QueueCfg {
            hub_id: hub.into(),
            exec_root: dir.path().to_path_buf(),
            local: LocalRunner::new(Admission::Fixed(1), dir.path()),
            db: None,
        });
        q.adopt("xbusy", Priority::P1, now());
        let runner = |name: &str, grace_s: u64| RemoteRunner {
            name: name.into(),
            trust: forseti::RunnerTrust::Mine,
            accept: forseti::Accept::All,
            grace_s,
            image: Some(img.clone()),
        };
        let (channels, mut child1) = serve("r1", &root1, prefix, hub);
        q.add_runner(
            runner("r1", 0),
            Session::start("r1", channels, q.route(), q.link_events()),
        );
        let script = format!(
            "sel='{ROWS}'; for i in $(seq 1 240); do printf 't%s\\n' $i | grep -q -- \"$sel\" || continue; \
             echo \"(:name \\\"t$i\\\" :verdict pass)\"; \
             if [ $i = 150 ]; then mkfifo /tmp/gate; read x < /tmp/gate; fi; done"
        );
        let mut s = spec(&script);
        s.weight = Weight::Heavy;
        q.submit(
            Submit {
                id: "xdrill".into(),
                session: Some("s1".into()),
                own: Priority::P3,
                spec: s,
                place: Placement {
                    heavy: true,
                    send: SendMode::Heavy,
                    image: Some(img.clone()),
                    suite: Some(Suite {
                        parser: "plist".into(),
                        listed: (1..=240).map(|i| format!("t{i}")).collect(),
                    }),
                    ..Placement::default()
                },
                pending: serde_json::Value::Null,
                inputs: None,
            },
            now(),
        );
        let mut outcomes = vec![];
        let log = dir.path().join("xdrill/log");
        drive(
            &q,
            &mut events,
            &mut outcomes,
            "row 150 in the hub's copy of the log",
            |_, _| {
                std::fs::read_to_string(&log)
                    .ok()
                    .filter(|l| l.contains("\"t150\""))
                    .map(|_| ())
            },
        )
        .await;
        let (channels, _child2) = serve("r2", &root2, prefix, hub);
        q.add_runner(
            runner("r2", 600),
            Session::start("r2", channels, q.route(), q.link_events()),
        );
        // the cut: r1's link is lost, and with no grace attempt 1 ends at once
        let _ = child1.kill().await;
        let (attempt, result) =
            drive_through_losses(&q, &mut events, &mut outcomes, "attempt 2's result", |o| {
                o.iter().find_map(|o| match o {
                    Outcome::Done {
                        id,
                        attempt,
                        result,
                        ..
                    } if id == "xdrill" => Some((*attempt, result.clone())),
                    _ => None,
                })
            })
            .await;
        assert_eq!(
            (attempt, &result["verdict"]),
            (2, &json!("Pass")),
            "{result}"
        );
        assert_eq!(
            result["counts"],
            json!({"ran": 240, "passed": 240, "failed": 0, "skipped": 0, "crashed": 0})
        );
        assert_eq!(
            result["split"],
            "rows 1–150 on r1 (attempt 1), 151–240 on r2 (attempt 2)"
        );
        let rows = |text: &str| -> Vec<String> {
            text.lines()
                .filter(|l| l.starts_with("(:name"))
                .map(String::from)
                .collect()
        };
        let first = rows(&std::fs::read_to_string(dir.path().join("xdrill/log.1")).unwrap());
        let second = rows(&std::fs::read_to_string(&log).unwrap());
        assert_eq!(first.len(), 150, "{first:?}");
        assert_eq!(
            second.len(),
            90,
            "attempt 2 reran only the rest: {second:?}"
        );
        assert!(second[0].contains("\"t151\"") && second[89].contains("\"t240\""));
        // r1 is back: its attempt 1, late, is stopped where it parked
        let (channels, _child1) = serve("r1", &root1, prefix, hub);
        assert!(q.set_session(
            "r1",
            Session::start("r1", channels, q.route(), q.link_events())
        ));
        let late = drive_through_losses(
            &q,
            &mut events,
            &mut outcomes,
            "attempt 1's late result",
            |o| {
                o.iter().find_map(|o| match o {
                    Outcome::Late {
                        id,
                        attempt: 1,
                        result,
                    } if id == "xdrill" => Some(result.clone()),
                    _ => None,
                })
            },
        )
        .await;
        assert_eq!(late["verdict"], "Cancelled", "{late}");
        let late_rows = late["rows"].as_array().map_or(0, Vec::len);
        assert!(late_rows <= 150, "attempt 1 ran on past row 150: {late}");
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
            pins: vec![],
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
