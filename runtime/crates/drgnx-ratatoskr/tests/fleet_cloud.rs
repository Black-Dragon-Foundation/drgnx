//! Cloud machines' SSH over real sshd (`#[ignore = "fleet"]`, test/runners/README.md, "Cloud machines"): the hub
//! starts a machine through `ratatoskr-mock cloud`, which makes it a fake-runner container; the machine takes its CA
//! and principal from its user-data, makes new host keys and prints them on its console as cloud-init does. The hub
//! pins them from `GetConsoleOutput`, signs an hour's certificate for a fresh key in its own agent, and reaches the
//! machine with that and nothing else. They run in a cloud fleet's harness only:
//!
//! ```text
//! cargo build -p domr --bin ratatoskr-mock
//! cargo test -p drgnx-ratatoskr --features fleet,test-hooks --test fleet_cloud --no-run
//! fleet.sh up --runners 0 --cloud runtime/target/debug/ratatoskr-mock
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1
//! ```
//!
//! Every row is [C]: a real machine that announces its state (its host keys on its console) and real sshd answering;
//! the row waits on the announcement. The credentials are fake ones built in pieces; nothing leaves the fleet's
//! network.
//!
//! The drills (`mod cloud`) also install the shared `sleipnir` (a `test-hooks` build, from the share the mock mounts
//! into its machines) and run the machine's watchdog with a clock file, so its limits come due when a row writes the
//! time, and a power-off command that tells the mock the machine powered itself off (it ends, as it was started to).
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::cloud::aws::{Aws, AwsCfg};
use drgnx_ratatoskr::runners::cloud::ca::{Agent, Ca, UserKey, pin};
use drgnx_ratatoskr::runners::cloud::creds::{Resolver, Source};
use drgnx_ratatoskr::runners::cloud::{InstanceState, Market, Provider, StartReq};
use drgnx_ratatoskr::runners::ssh_config;
use drgnx_ratatoskr::runners::transport::{
    Channel, Channels, LinkError, OpensshTransport, Transport,
};
use drgnx_ratatoskr::runners::{CloudSsh, Remote, RunnerCfg};
use std::io::{Read, Write};
use std::sync::Arc;
use std::time::Duration;

/// How long a row waits for a machine to boot and print its host keys.
const WAIT: u64 = 180;
/// The hub id `fleet.sh up --cloud` starts the mock with.
const HUB: &str = "hub-fleet";

fn aws() -> Aws {
    let id = ["AS", "IA", "FAKEFAKEFAKE0003"].concat();
    let secret = ["fake", "/fleet", "0003"].concat();
    let json =
        format!("{{\"Version\":1,\"AccessKeyId\":\"{id}\",\"SecretAccessKey\":\"{secret}\"}}");
    let creds = Resolver::new(
        Source::Command(vec!["printf".into(), "%s".into(), json]),
        None,
    );
    let cfg = AwsCfg {
        region: "us-east-1".into(),
        hub_id: HUB.into(),
        probe: None,
    };
    // the endpoint is the fleet's mock: DRGNX_TEST_CLOUD_ENDPOINT_AWS, which `fleet.sh test` passes
    Aws::new(cfg, Arc::new(creds)).unwrap()
}

/// The fleet's mock, `http://HOST:PORT/`.
fn endpoint() -> String {
    std::env::var("DRGNX_TEST_CLOUD_ENDPOINT_AWS")
        .expect("fleet.sh test passes the mock's endpoint")
}

/// One request to the fleet's mock; its whole answer.
fn mock(method: &str, path: &str, body: &str) -> String {
    let base = endpoint();
    let addr = base.trim_start_matches("http://").trim_end_matches('/');
    let mut s = std::net::TcpStream::connect(addr).unwrap();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: mock\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    out
}

/// `POST /__mock/NAME` with BODY to the fleet's mock.
fn knob(name: &str, body: &str) {
    let out = mock("POST", &format!("/__mock/{name}"), body);
    assert!(out.starts_with("HTTP/1.1 200"), "{name}: {out}");
}

/// What the mock holds (`GET /__mock/resources`, which needs no credentials).
fn resources() -> serde_json::Value {
    let out = mock("GET", "/__mock/resources", "");
    let body = out.split_once("\r\n\r\n").map_or("", |(_, b)| b);
    serde_json::from_str(body).unwrap_or_else(|e| panic!("the mock's resources: {e}: {out}"))
}

/// Machine ID's state as the mock holds it (`running`, `shutting-down`, `terminated`, …).
fn state_of(id: &str) -> String {
    resources()["instances"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|i| i["id"] == id)
        .and_then(|i| i["state"].as_str())
        .unwrap_or_else(|| panic!("the mock holds no machine {id}"))
        .to_string()
}

/// Whether machine ID has ended: terminated, or on its way there.
fn ended(id: &str) -> bool {
    matches!(state_of(id).as_str(), "shutting-down" | "terminated")
}

/// A started machine and what reaches it: its pinned host keys, the hub's agent with a fresh key, its certificate.
struct Machine {
    aws: Aws,
    id: String,
    ca: Ca,
    key: UserKey,
    agent: Agent,
    cfg: RunnerCfg,
    runtime: tempfile::TempDir,
}

/// Starts the machine NAME and readies everything the transport needs for it.
async fn start(name: &str) -> Machine {
    start_on(name, Market::OnDemand).await
}

/// [`start`] on MARKET.
async fn start_on(name: &str, market: Market) -> Machine {
    let runtime = tempfile::tempdir().unwrap();
    let (ca, ca_pub) = Ca::new();
    let aws = aws();
    let principal = format!("drgnx-{name}");
    let req = StartReq {
        token: format!("tok-{name}-{}", std::process::id()),
        name: principal.clone(),
        size: "m7g.large".into(),
        image: "ami-base0fedora45x86".into(),
        market,
        user_data: format!(
            "drgnx-ca: {}\ndrgnx-principal: {principal}\n",
            ca_pub.to_openssh("drgnx-ca")
        ),
        security_group: None,
    };
    let inst = aws.start(&req).await.unwrap();
    let keys = skuld::wait_until_async("the machine's host keys on its console", WAIT, || {
        let (aws, id) = (&aws, inst.id.clone());
        async move { pin::from_console(&aws.console(&id).await.ok()?).ok() }
    })
    .await;
    let info = aws.describe(&inst.id).await.unwrap();
    assert_eq!(info.state, InstanceState::Running);
    let host = format!(
        "runner@{}",
        info.address.expect("a running machine has an address")
    );
    let rt = runtime.path();
    let known_hosts =
        ssh_config::write_in(rt, name, "known_hosts", &pin::known_hosts(&host, &keys)).unwrap();
    let agent = Agent::start(rt).unwrap();
    let key = UserKey::generate();
    agent.add(&key, Duration::from_secs(3600)).unwrap();
    let cert = ca.sign(&key.public(), &principal, Duration::from_secs(3600));
    let certificate = ssh_config::write_in(rt, name, "id-cert.pub", &cert.to_openssh()).unwrap();
    let identity_file = ssh_config::write_in(
        rt,
        name,
        "id.pub",
        &format!("{}\n", key.public().to_openssh("drgnx")),
    )
    .unwrap();
    let cat = vec!["cat".to_string()];
    let cfg = RunnerCfg {
        name: name.into(),
        host,
        linger: true,
        cloud: Some(CloudSsh {
            identity_agent: agent.socket().to_path_buf(),
            identity_file,
            certificate,
            known_hosts,
        }),
        remote: Remote {
            control: cat.clone(),
            bulk_in: cat.clone(),
            bulk_out: cat,
        },
    };
    Machine {
        aws,
        id: inst.id,
        ca,
        key,
        agent,
        cfg,
        runtime,
    }
}

/// The machine the drills' runner roots report to admission: idle, with room.
const QUIET_MACHINE: &str = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
"disk_free_gb": 100, "disk_total_gb": 200, "mem_available_mib": 8192}"#;

/// A watchdog's limits, in seconds.
#[derive(Clone, Copy)]
struct Limits {
    idle: u64,
    lifetime: u64,
    unattended: u64,
}

/// A machine's watchdog: its folder, its clock file, and the time it started at (its boot, by its clock).
struct Watchdog {
    dir: String,
    clock: String,
    t0: u64,
}

/// The design's: 15 min idle, an 8 h lifetime, a 2 h unattended lifetime.
const DESIGN: Limits = Limits {
    idle: 900,
    lifetime: 8 * 3600,
    unattended: 2 * 3600,
};

impl Machine {
    fn name(&self) -> &str {
        &self.cfg.name
    }

    /// The hub's ssh config for the machine as the transport writes it: its certificate, its pinned host keys, its
    /// own agent, and nothing of the user's.
    fn ssh_config(&self) -> std::path::PathBuf {
        ssh_config::write(
            self.runtime.path(),
            &self.cfg.name,
            &ssh_config::render(&self.cfg),
        )
        .unwrap()
    }

    /// SCRIPT's stdout on the machine, or its stderr as the error.
    fn try_sh(&self, script: &str) -> Result<String, String> {
        let out = std::process::Command::new("ssh")
            .arg("-F")
            .arg(self.ssh_config())
            .arg(&self.cfg.host)
            .arg(script)
            .output()
            .expect("ssh");
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        }
    }

    /// SCRIPT's stdout on the machine; panics when it fails.
    fn sh(&self, script: &str) -> String {
        self.try_sh(script)
            .unwrap_or_else(|e| panic!("{}: {script}: {e}", self.name()))
    }

    /// A fresh runner root ~/NAME: the shared `sleipnir` as bundle `test`, and the quiet machine.
    fn install(&self, name: &str) -> String {
        let home = self.sh("echo $HOME");
        let root = format!("{home}/{name}");
        self.sh(&format!(
            "rm -rf {root} && mkdir -p {root}/bin/test && cp /fleet/share/sleipnir {root}/bin/test/sleipnir \
             && printf %s '{QUIET_MACHINE}' > {root}/test-machine.json"
        ));
        root
    }

    /// The base image by digest, once the machine has loaded it at boot.
    fn base_image(&self) -> String {
        let d = skuld::wait_until("the base image loaded on the machine", WAIT, || {
            self.try_sh(
                "podman image inspect registry.fedoraproject.org/fedora:45 --format '{{.Digest}}'",
            )
            .ok()
            .filter(|d| d.starts_with("sha256:"))
        });
        format!("registry.fedoraproject.org/fedora@{d}")
    }

    /// The machine's watchdog for ROOT under LIMITS, as a user unit: AWS rules, the mock's metadata for this machine,
    /// its time the number in its clock file, its power-off a request that tells the mock this machine powered itself
    /// off. Waits for its own folder, which it makes as it starts, just before its first look at the clock.
    fn watchdog(&self, root: &str, l: Limits) -> Watchdog {
        let (dir, clock, ep, id) = (
            format!("{root}/watchdog"),
            format!("{root}/watchdog.clock"),
            endpoint(),
            &self.id,
        );
        let t0 = self.sh(&format!(
            "date +%s > {clock} && printf '%s' '{{\"id\": \"{id}\"}}' > {root}/poweroff.json \
             && printf '%s\\n' '#!/bin/sh' 'exec curl -fsS -X POST --data-binary @{root}/poweroff.json {ep}__mock/poweroff' \
             > {root}/poweroff && chmod +x {root}/poweroff \
             && systemd-run --user --collect --unit=fleet-watchdog {root}/bin/test/sleipnir watchdog --provider aws \
             --idle {} --lifetime {} --unattended {} --root {root} --dir {dir} --clock-file {clock} \
             --poweroff-cmd {root}/poweroff --metadata-url {ep}__metadata/{id} >/dev/null && cat {clock}",
            l.idle, l.lifetime, l.unattended
        ));
        skuld::wait_until("the watchdog's own folder", WAIT, || {
            self.try_sh(&format!("test -d {dir}")).ok()
        });
        Watchdog {
            dir,
            clock,
            t0: t0.parse().expect("the clock file's number"),
        }
    }

    /// W's time is T now.
    fn set_clock(&self, w: &Watchdog, t: u64) {
        let c = &w.clock;
        self.sh(&format!("printf %s {t} > {c}.new && mv {c}.new {c}"));
    }

    /// `serve --watchdog WD` in ROOT for HUB over one `ssh` of the hub's (its stdin and stdout are the control
    /// channel); killing the child is the hub dying with no `bye`.
    fn serve(&self, root: &str, hub: &str, wd: &str) -> (Channels, tokio::process::Child) {
        let mut child = tokio::process::Command::new("ssh")
            .arg("-F")
            .arg(self.ssh_config())
            .arg(&self.cfg.host)
            .arg(format!(
                "{root}/bin/test/sleipnir serve --root {root} --prefix fl{hub} --hub-id {hub} --profile dedicated \
                 --watchdog {wd}"
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
}

mod ca {
    use super::*;

    // [C] a real machine that announces its host keys; real sshd answers or refuses
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_cloud_machine_is_reached_by_certificate_only() {
        let m = start("c1").await;
        // the user's agent: a listener that records any connection
        let users = m.runtime.path().join("users-agent.sock");
        let fake = std::os::unix::net::UnixListener::bind(&users).unwrap();
        fake.set_nonblocking(true).unwrap();
        // SAFETY: the rows run one at a time (--test-threads=1); the ssh the transport starts inherits it
        unsafe { std::env::set_var("SSH_AUTH_SOCK", &users) };
        let t = OpensshTransport::new(m.runtime.path());
        let ch = t
            .open(&m.cfg)
            .await
            .expect("the machine takes the hub's certificate");
        // with the sessions closed a session is free, so the round trip is a real `true` on the machine (with all
        // three open it waits for the control channel's next ping, which these `cat` sessions never send)
        drop(ch);
        t.round_trip("c1").await.expect("a real round trip");
        t.stop("c1").await;

        // the same key in the same agent without its certificate: refused, the machine takes certificates only
        let mut plain = m.cfg.clone();
        plain.name = "c1-plain".into();
        plain.cloud.as_mut().unwrap().certificate = m.runtime.path().join("no-certificate.pub");
        match t.open(&plain).await {
            Err(LinkError::Refused(why)) => assert!(why.contains("Permission denied"), "{why}"),
            Err(e) => panic!("a plain key should be refused by sshd, not {e:?}"),
            Ok(_) => panic!("a plain key reached the machine"),
        }
        t.stop("c1-plain").await;

        // a certificate for another machine's principal: refused
        let mut other = m.cfg.clone();
        other.name = "c1-other".into();
        let cert = m.ca.sign(
            &m.key.public(),
            "drgnx-elsewhere",
            Duration::from_secs(3600),
        );
        let path = ssh_config::write_in(
            m.runtime.path(),
            "c1-other",
            "id-cert.pub",
            &cert.to_openssh(),
        )
        .unwrap();
        other.cloud.as_mut().unwrap().certificate = path;
        assert!(matches!(t.open(&other).await, Err(LinkError::Refused(_))));
        t.stop("c1-other").await;

        unsafe { std::env::remove_var("SSH_AUTH_SOCK") };
        match fake.accept() {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("the user's agent was asked: {other:?}"),
        }
        drop(m.agent);
        m.aws.end(&m.id).await.unwrap();
    }

    // [C] a real machine whose sshd is given new host keys after the pin
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_changed_host_key_is_refused() {
        let m = start("c2").await;
        let t = OpensshTransport::new(m.runtime.path());
        drop(
            t.open(&m.cfg)
                .await
                .expect("reached through the pinned key"),
        );
        t.stop("c2").await;
        // the machine's sshd restarts with new host keys (the knob returns once it has)
        knob("rotate-hostkey", &format!("{{\"id\": \"{}\"}}", m.id));
        match t.open(&m.cfg).await {
            Err(LinkError::HostKeyChanged) => {}
            Err(e) => panic!("a changed host key must be refused as one, not {e:?}"),
            Ok(_) => panic!("a host key that is not the pinned one was accepted"),
        }
        t.stop("c2").await;
        drop(m.agent);
        m.aws.end(&m.id).await.unwrap();
    }
}

/// Phase 2's exit drills on the mock (runners design §6.13): real machines the hub started through the mock, reached by
/// certificate only, each with its own watchdog.
mod cloud {
    use super::*;
    use drgnx_ratatoskr::runners::cloud::CloudError;
    use drgnx_ratatoskr::runners::cloud::meter::{CapState, Meter, Rates, needs_login_text};
    use drgnx_ratatoskr::runners::cloud::sweep::{Bounds, Ended, Pass, Sweeper};
    use drgnx_ratatoskr::runners::link::{LinkEvent, Session};
    use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
    use drgnx_ratatoskr::runners::queue::{
        Outcome, Placement, Queue, QueueCfg, RemoteRunner, SendMode, Submit,
    };
    use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, Weight};
    use std::path::{Path, PathBuf};
    use tokio::sync::mpsc::UnboundedReceiver;

    /// The wall clock as the queue takes it: a value, never waited on.
    fn now() -> u64 {
        skuld::host_now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    }

    /// Two watchdog looks: long enough for a limit that had come due to have acted.
    const TWO_LOOKS: Duration = Duration::from_secs(12);

    /// A queue on DIR whose one local slot is taken, so a requeued job has nowhere else to go.
    fn queue(dir: &Path, hub: &str) -> (Arc<Queue>, UnboundedReceiver<LinkEvent>) {
        let (q, events) = Queue::new(QueueCfg {
            hub_id: hub.into(),
            exec_root: dir.to_path_buf(),
            local: LocalRunner::new(Admission::Fixed(1), dir),
            db: None,
        });
        q.adopt("xbusy", Priority::P1, now());
        (q, events)
    }

    /// M as the queue's `my-cloud` runner, `serve` reached over the hub's own ssh; the child is that ssh.
    fn attach(
        q: &Arc<Queue>,
        m: &Machine,
        root: &str,
        hub: &str,
        wd: &str,
        img: &str,
    ) -> tokio::process::Child {
        let (channels, child) = m.serve(root, hub, wd);
        let session = Session::start(m.name(), channels, q.route(), q.link_events());
        q.add_runner(
            RemoteRunner {
                os: Default::default(),
                name: m.name().into(),
                trust: forseti::RunnerTrust::MyCloud,
                accept: forseti::Accept::All,
                grace_s: 120,
                image: Some(img.into()),
            },
            session,
        );
        child
    }

    /// A priority-3 job ID that parks in IMAGE until its FIFO is written, sent only to runners.
    fn parked(id: &str, img: &str) -> Submit {
        let spec = JobSpec {
            name: "fleet".into(),
            kind: Kind::Test,
            weight: Weight::Heavy,
            suite: None,
            tree: PathBuf::from("/src/p"),
            cwd: PathBuf::from("."),
            command: vec![
                "sh".into(),
                "-c".into(),
                "echo started; mkfifo /tmp/gate; read x < /tmp/gate".into(),
            ],
            select: None,
            needs: vec![],
            inputs_extra: vec![],
            inputs_outside: vec![],
            features: vec![],
            cores: Range { min: 1, max: 1 },
            mem_mib: Range { min: 64, max: 256 },
            disk_gib: 0,
            timeout_s: 3600,
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
        };
        Submit {
            id: id.into(),
            session: Some("s1".into()),
            own: Priority::P3,
            spec,
            place: Placement {
                heavy: true,
                send: SendMode::Heavy,
                image: Some(img.into()),
                ..Placement::default()
            },
            pending: serde_json::Value::Null,
            inputs: None,
        }
    }

    /// Feeds the queue its link events (a lost link too) and ticks it, until CHECK has an answer, within the wait.
    async fn drive<T>(
        q: &Queue,
        events: &mut UnboundedReceiver<LinkEvent>,
        outcomes: &mut Vec<Outcome>,
        what: &str,
        mut check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
    ) -> T {
        skuld::wait_until_async(what, WAIT, || {
            while let Ok(ev) = events.try_recv() {
                outcomes.extend(q.on_link(ev, now()));
            }
            outcomes.extend(q.tick(now()).outcomes);
            std::future::ready(check(q, outcomes))
        })
        .await
    }

    /// Waits until JOB runs on M and its log, the hub's copy, says it started.
    async fn running(
        q: &Queue,
        events: &mut UnboundedReceiver<LinkEvent>,
        outcomes: &mut Vec<Outcome>,
        dir: &Path,
        m: &Machine,
        job: &str,
    ) {
        let log = dir.join(job).join("log");
        drive(
            q,
            events,
            outcomes,
            "the job running on the cloud machine",
            |q, _| {
                let on = q.row(job)?.machine.as_deref() == Some(m.name());
                let started = std::fs::read(&log).is_ok_and(|l| l.ends_with(b"started\n"));
                (on && started).then_some(())
            },
        )
        .await;
    }

    fn verdict_for(outcomes: &[Outcome], job: &str) -> bool {
        outcomes
            .iter()
            .any(|o| matches!(o, Outcome::Done { id, .. } if id == job))
    }

    /// [C] A spot machine the hub started runs a job; the mock posts a spot notice. The machine's watchdog sees it
    /// within its 5 s look and `serve` sends `preempting`: the hub requeues the attempt at once, with no strike and
    /// no verdict. Then the provider takes the machine back (the mock's clock past the notice's 2 minutes): the machine
    /// is gone, its link is lost, and the hub's "machine gone" step finds nothing left to judge. Still no strike, no
    /// red: the job waits in the queue.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_spot_notice_requeues_with_no_strike_and_no_red() {
        let hub = "hubcspot";
        let m = start_on("cspot", Market::Spot).await;
        let root = m.install("fl-cspot");
        let img = m.base_image();
        let w = m.watchdog(&root, DESIGN);
        let dir = tempfile::tempdir().unwrap();
        let (q, mut events) = queue(dir.path(), hub);
        let _ssh = attach(&q, &m, &root, hub, &w.dir, &img);
        q.submit(parked("xcspot", &img), now());
        let mut outcomes = vec![];
        running(&q, &mut events, &mut outcomes, dir.path(), &m, "xcspot").await;

        knob(
            "spot-notice",
            &format!(r#"{{"id": "{}", "in_s": 0}}"#, m.id),
        );
        // the requeue's reason shows until the next tick says why the job waits now: each event is looked at as it
        // is taken in, before any tick
        let row = skuld::wait_until_async("the attempt requeued for the notice", WAIT, || {
            let mut got = None;
            while got.is_none()
                && let Ok(ev) = events.try_recv()
            {
                if let LinkEvent::Lost { why, .. } = &ev {
                    panic!("the link was lost before the notice was sent up: {why}");
                }
                outcomes.extend(q.on_link(ev, now()));
                got = q
                    .row("xcspot")
                    .filter(|r| r.waiting.as_deref().is_some_and(|w| w.contains("requeued")));
            }
            if got.is_none() {
                outcomes.extend(q.tick(now()).outcomes);
            }
            std::future::ready(got)
        })
        .await;
        assert_eq!(
            row.waiting.as_deref(),
            Some("requeued (infra: preempted)"),
            "{row:?}"
        );
        assert_eq!(row.machine, None, "{row:?}");
        let r = q.runner(m.name()).expect("the cloud runner");
        assert_eq!(
            (r.state.as_str(), r.strikes, r.last.as_deref()),
            ("preempting", 0, None),
            "a preemption is no strike: {r:?}"
        );
        assert!(
            !verdict_for(&outcomes, "xcspot"),
            "a preemption is no verdict: {outcomes:?}"
        );
        assert!(
            !m.sh(&format!("cat {}/preempting", w.dir)).is_empty(),
            "the watchdog's notice"
        );

        // the interruption, 2 minutes after the notice: the provider ends the machine
        knob("clock", r#"{"advance_s": 121}"#);
        skuld::wait_until("the machine taken back", WAIT, || {
            ended(&m.id).then_some(())
        });
        let mut lost = false;
        skuld::wait_until_async("the link to the ended machine lost", WAIT, || {
            while let Ok(ev) = events.try_recv() {
                lost |= matches!(ev, LinkEvent::Lost { .. });
                outcomes.extend(q.on_link(ev, now()));
            }
            outcomes.extend(q.tick(now()).outcomes);
            std::future::ready(lost.then_some(()))
        })
        .await;
        // the hub's step for a cloud machine that is gone (the sweeper's, or the cap's)
        outcomes.extend(q.cloud_gone(m.name(), now()));
        outcomes.extend(q.tick(now()).outcomes);
        let r = q.runner(m.name()).expect("the cloud runner");
        assert_eq!(
            r.strikes, 0,
            "a machine the provider took back is no strike: {r:?}"
        );
        assert!(
            !verdict_for(&outcomes, "xcspot"),
            "no red, no verdict: {outcomes:?}"
        );
        let row = q.row("xcspot").expect("the job is still the queue's");
        assert_eq!(row.machine, None, "{row:?}");
        assert!(row.waiting.is_some(), "it waits for a machine: {row:?}");
    }

    /// [C] With the hub gone, every AWS machine ends by its own watchdog. Two machines the hub started: one idle, and
    /// one running a job when the hub dies (its ssh killed: `serve` sees an end with no `bye`, the job runs on in its
    /// unit). With the watchdog's clock moved: the idle machine is still there 60 s before its idle time and ends at
    /// it; the busy one is still there past its idle time (it has a job) and 60 s before the unattended lifetime
    /// since the hub's last contact, and ends at it. Each end is the machine powering itself off, which the mock
    /// turns into a terminated instance, as AWS does for `InstanceInitiatedShutdownBehavior=terminate`.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn with_the_hub_gone_every_aws_machine_ends_by_its_watchdog() {
        let hub = "hubcgone";
        let idle = start("cidle").await;
        let idle_root = idle.install("fl-cidle");
        let iw = idle.watchdog(&idle_root, DESIGN);
        let busy = start("cbusy").await;
        let busy_root = busy.install("fl-cbusy");
        let img = busy.base_image();
        let bw = busy.watchdog(&busy_root, DESIGN);

        let dir = tempfile::tempdir().unwrap();
        let (q, mut events) = queue(dir.path(), hub);
        let mut ssh = attach(&q, &busy, &busy_root, hub, &bw.dir, &img);
        q.submit(parked("xcbusy", &img), now());
        let mut outcomes = vec![];
        running(&q, &mut events, &mut outcomes, dir.path(), &busy, "xcbusy").await;
        // the hub dies: its ssh killed, its queue gone
        ssh.kill().await.unwrap();
        drop(q);
        let hb: serde_json::Value =
            serde_json::from_str(&busy.sh(&format!("cat {busy_root}/heartbeat.json"))).unwrap();
        let contact = hb["contact"].as_u64().expect("the heartbeat's contact");
        assert!(contact >= bw.t0, "{hb}");
        let jobs = || {
            busy.sh(&format!(
                "podman ps --filter label=drgnx.runner={hub} --format '{{{{.Names}}}}'"
            ))
        };
        assert!(!jobs().is_empty(), "the job runs on with the hub gone");

        // the idle machine: 60 s before its idle time it stays, at it it ends
        idle.set_clock(&iw, iw.t0 + DESIGN.idle - 60);
        skuld::window(TWO_LOOKS, "the idle machine ending early");
        assert_eq!(state_of(&idle.id), "running");
        idle.set_clock(&iw, iw.t0 + DESIGN.idle);
        skuld::wait_until("the idle machine ended by its watchdog", WAIT, || {
            ended(&idle.id).then_some(())
        });

        // the busy machine: past its idle time it stays (it has a job), and 60 s before the unattended lifetime
        busy.set_clock(&bw, bw.t0 + DESIGN.idle + 60);
        skuld::window(TWO_LOOKS, "the busy machine ending while idle-timed");
        assert_eq!(state_of(&busy.id), "running");
        assert!(!jobs().is_empty(), "its job still runs");
        busy.set_clock(&bw, contact + DESIGN.unattended - 60);
        skuld::window(
            TWO_LOOKS,
            "the busy machine ending before its unattended lifetime",
        );
        assert_eq!(state_of(&busy.id), "running");
        busy.set_clock(&bw, contact + DESIGN.unattended);
        skuld::wait_until("the busy machine ended by its watchdog", WAIT, || {
            ended(&busy.id).then_some(())
        });
    }

    /// [C] The credentials expire (the mock answers every call `ExpiredToken`) while two machines run: one with its
    /// watchdog, one whose watchdog never came up. Nothing new starts (the start fails as a login, and the meter's gate
    /// gives the card's words); the sweeper pauses and ends nothing. The layers on the machines still work: the first
    /// machine's watchdog ends it at its lifetime. Once the user logs in (the mock takes the token again), the
    /// sweeper's next pass resumes and ends the second, past its lifetime by then.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn expired_credentials_card_no_starts_layers_end_sweeper_resumes() {
        let watched = start("cwatch").await;
        let root = watched.install("fl-cwatch");
        let w = watched.watchdog(&root, DESIGN);
        let unwatched = start("cbare").await;
        let aws = aws();
        let t_mock = resources()["now"].as_u64().expect("the mock's clock");
        let machines = || resources()["instances"].as_array().map_or(0, Vec::len);
        let before = machines();

        knob("expire", "{}");
        let req = StartReq {
            token: format!("tok-cnew-{}", std::process::id()),
            name: "drgnx-cnew".into(),
            size: "m7g.large".into(),
            image: "ami-base0fedora45x86".into(),
            market: Market::OnDemand,
            user_data: "drgnx-principal: drgnx-cnew\n".into(),
            security_group: None,
        };
        let cmd = match aws.start(&req).await {
            Err(CloudError::NeedsLogin(cmd)) => cmd,
            other => panic!("a start with expired credentials must ask for a login: {other:?}"),
        };
        let card = Meter::new(Rates::default(), 0.0)
            .gate(now(), 50.0, "m7g.large", 0.1, 600, 900, &[], Some(&cmd))
            .expect_err("the gate refuses every start while the credentials need a login");
        assert_eq!(card, needs_login_text(&cmd));
        assert!(card.ends_with("then Runners: Retry Cloud"), "{card}");

        let bounds = Bounds {
            lifetime_s: DESIGN.lifetime,
            unreachable_s: 300,
        };
        let mut sweeper = Sweeper::new(HUB, bounds);
        let late = t_mock + DESIGN.lifetime + 600;
        let reached = |_: &str| true;
        match sweeper.pass(&aws, late, &reached, CapState::Under).await {
            Pass::Paused(c) => assert_eq!(c, cmd),
            other => panic!("the sweeper must pause on expired credentials: {other:?}"),
        }
        for id in [&watched.id, &unwatched.id] {
            assert_eq!(state_of(id), "running", "a paused sweeper ends nothing");
        }
        assert_eq!(machines(), before, "nothing new started");

        // the machine's own layer: its watchdog ends it at its lifetime, credentials or not
        watched.set_clock(&w, w.t0 + DESIGN.lifetime);
        skuld::wait_until("the watched machine ended by its watchdog", WAIT, || {
            ended(&watched.id).then_some(())
        });
        assert_eq!(state_of(&unwatched.id), "running");

        // the user logs in: the next pass resumes and ends what is past its bound
        knob("token", "{}");
        let swept = match sweeper
            .pass(&aws, late + 600, &reached, CapState::Under)
            .await
        {
            Pass::Done(s) => s,
            other => panic!("the sweeper must resume once the credentials work: {other:?}"),
        };
        assert!(
            swept
                .ended
                .contains(&(unwatched.id.clone(), Ended::Lifetime)),
            "{swept:?}"
        );
        assert!(
            !swept.ended.iter().any(|(id, _)| *id == watched.id),
            "the watched machine had ended already: {swept:?}"
        );
        assert_eq!(sweeper.paused(), None);
        skuld::wait_until("the unwatched machine ended by the sweeper", WAIT, || {
            ended(&unwatched.id).then_some(())
        });
    }
}
