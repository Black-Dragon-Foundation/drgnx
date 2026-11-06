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
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::cloud::aws::{Aws, AwsCfg};
use drgnx_ratatoskr::runners::cloud::ca::{Agent, Ca, UserKey, pin};
use drgnx_ratatoskr::runners::cloud::creds::{Resolver, Source};
use drgnx_ratatoskr::runners::cloud::{InstanceState, Market, Provider, StartReq};
use drgnx_ratatoskr::runners::ssh_config;
use drgnx_ratatoskr::runners::transport::{LinkError, OpensshTransport, Transport};
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

/// `POST /__mock/NAME` with BODY to the fleet's mock.
fn knob(name: &str, body: &str) {
    let base = std::env::var("DRGNX_TEST_CLOUD_ENDPOINT_AWS")
        .expect("fleet.sh test passes the mock's endpoint");
    let addr = base.trim_start_matches("http://").trim_end_matches('/');
    let mut s = std::net::TcpStream::connect(addr).unwrap();
    let req = format!(
        "POST /__mock/{name} HTTP/1.1\r\nHost: mock\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    assert!(out.starts_with("HTTP/1.1 200"), "{name}: {out}");
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
    let runtime = tempfile::tempdir().unwrap();
    let (ca, ca_pub) = Ca::new();
    let aws = aws();
    let principal = format!("drgnx-{name}");
    let req = StartReq {
        token: format!("tok-{name}-{}", std::process::id()),
        name: principal.clone(),
        size: "m7g.large".into(),
        image: "ami-base0fedora45x86".into(),
        market: Market::OnDemand,
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
