//! Job keys' rows over real SSH to a real `sleipnir serve` in a fake runner (`#[ignore = "fleet"]`, test/runners/):
//! the queue sends a keyed job's keys after `started`, one `key` frame each, never to a `shared` runner; the job reads
//! them through `drgnx-key`; the hub's copy of its log has them masked; nothing of them stays on the runner's disk.
//! They run in a fleet's harness only:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet --test fleet_keys --no-run
//! cargo build -p sleipnir --features test-hooks --bin sleipnir --bin drgnx-key   # fleet.sh test shares both
//! fleet.sh up --runners 1
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1
//! ```
//!
//! Every key is a throwaway value made by the row. Every row is [C]: a real `serve` and the jobs it starts announce
//! their state in frames and in the log, the queue's rows and audit say where each key went, and the row waits on
//! that; a job that must stay running parks on a FIFO in its container until the row writes to it.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::link::{LinkEvent, Session};
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{
    Outcome, Placement, Queue, QueueCfg, RemoteRunner, SendMode, Submit,
};
use drgnx_ratatoskr::runners::transport::{Channel, Channels};
use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, RunnerTrust, Weight};
use runstav::methods::runners::AuditKind;
use secrecy::SecretString;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;

/// How long a row waits on any one announced state before it fails (a key that never comes takes 60 s to say so).
const WAIT: u64 = 120;

/// The machine the rows' runners report to admission: idle, with room.
const QUIET_MACHINE: &str = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
"disk_free_gb": 100, "disk_total_gb": 200, "mem_available_mib": 8192}"#;

fn ssh_config() -> String {
    format!("{}/.ssh/config", std::env::var("HOME").unwrap())
}

/// SCRIPT's stdout on RUNNER; panics when it fails.
fn sh(runner: &str, script: &str) -> String {
    let out = Command::new("ssh")
        .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
        .arg(script)
        .output()
        .expect("ssh");
    assert!(
        out.status.success(),
        "{runner}: {script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A fresh runner root at ~/NAME on RUNNER: the shared `sleipnir` and `drgnx-key` as bundle `test`, and the quiet
/// machine.
fn root(runner: &str, name: &str) -> String {
    let share =
        std::env::var("DRGNX_FLEET_SHARE").expect("DRGNX_FLEET_SHARE: run through fleet.sh test");
    for b in ["sleipnir", "drgnx-key"] {
        assert!(
            PathBuf::from(&share).join(b).exists(),
            "fleet.sh test puts {b} in the share"
        );
    }
    let home = sh(runner, "echo $HOME");
    let root = format!("{home}/{name}");
    sh(
        runner,
        &format!(
            "rm -rf {root} && mkdir -p {root}/bin/test && cp /fleet/share/sleipnir /fleet/share/drgnx-key \
             {root}/bin/test/ && printf %s '{QUIET_MACHINE}' > {root}/test-machine.json"
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

/// `serve` in ROOT on RUNNER over one `ssh`: its stdin and stdout are the control channel.
fn serve(runner: &str, root: &str, prefix: &str, hub: &str) -> (Channels, tokio::process::Child) {
    let mut child = tokio::process::Command::new("ssh")
            .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
            .arg(format!(
                "{root}/bin/test/sleipnir serve --root {root} --prefix {prefix} --hub-id {hub} --profile dedicated"
            ))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
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

/// Whether the filter of [`without_key_frames`] holds back a frame of type T.
fn swallowed(t: &str) -> bool {
    t == "key"
}

/// W with every `key` frame held back: the hub sends it (its audit says so) and the link stays up (pings, offers and
/// everything else go through), but the runner never sees it. Lines and length-prefixed chunks are copied whole.
fn without_key_frames(
    mut w: drgnx_ratatoskr::runners::transport::Writer,
) -> drgnx_ratatoskr::runners::transport::Writer {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
    #[derive(serde::Deserialize)]
    struct Head {
        t: String,
        len: Option<u64>,
    }
    let (tx, rx) = tokio::io::duplex(1 << 20);
    tokio::spawn(async move {
        let mut rx = tokio::io::BufReader::new(rx);
        let mut line = Vec::new();
        loop {
            line.clear();
            if !matches!(rx.read_until(b'\n', &mut line).await, Ok(n) if n > 0) {
                break;
            }
            let head: Option<Head> = serde_json::from_slice(&line).ok();
            let mut chunk = Vec::new();
            if let Some(len) = head.as_ref().and_then(|h| h.len) {
                chunk.resize(4 + len as usize, 0);
                if rx.read_exact(&mut chunk).await.is_err() {
                    break;
                }
            }
            if head.as_ref().is_some_and(|h| swallowed(&h.t)) {
                continue;
            }
            if w.write_all(&line).await.is_err()
                || w.write_all(&chunk).await.is_err()
                || w.flush().await.is_err()
            {
                break;
            }
        }
    });
    Box::new(tx)
}

/// The wall clock as the queue takes it: a value, never waited on.
fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// A throwaway key value no other row or run shares: `flk-` and 32 hex digits.
fn throwaway() -> String {
    let word = || {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(now());
        h.finish()
    };
    format!("flk-{:016x}{:016x}", word(), word())
}

/// V in standard base64, padded (the form a job's `base64` prints).
fn base64(v: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in v.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Drains the queue's link events into it, ticks it, and returns what CHECK makes of it, within the wait.
async fn drive<T>(
    q: &Queue,
    events: &mut UnboundedReceiver<LinkEvent>,
    outcomes: &mut Vec<Outcome>,
    what: &str,
    mut check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
) -> T {
    skuld::wait_until_async(what, WAIT, || {
        while let Ok(ev) = events.try_recv() {
            if let LinkEvent::Lost { why, .. } = &ev {
                panic!("the link was lost waiting for {what}: {why}");
            }
            outcomes.extend(q.on_link(ev, now()));
        }
        outcomes.extend(q.tick(now()).outcomes);
        std::future::ready(check(q, outcomes))
    })
    .await
}

/// A queue on DIR whose one local slot a job holds, and runner r1 of TRUST (serve in ROOT).
fn queue_r1(
    dir: &Path,
    root: &str,
    prefix: &str,
    hub: &str,
    img: &str,
    trust: RunnerTrust,
) -> (
    Arc<Queue>,
    UnboundedReceiver<LinkEvent>,
    tokio::process::Child,
) {
    queue_r1_with(dir, root, prefix, hub, img, trust, false)
}

/// [`queue_r1`], with the `key` frames the hub sends held back on the way when DROP_KEYS.
fn queue_r1_with(
    dir: &Path,
    root: &str,
    prefix: &str,
    hub: &str,
    img: &str,
    trust: RunnerTrust,
    drop_keys: bool,
) -> (
    Arc<Queue>,
    UnboundedReceiver<LinkEvent>,
    tokio::process::Child,
) {
    let (q, events) = Queue::new(QueueCfg {
        hub_id: hub.into(),
        exec_root: dir.join("exec"),
        local: LocalRunner::new(Admission::Fixed(1), dir),
        db: None,
    });
    q.adopt("xbusy", Priority::P1, now());
    let (mut channels, child) = serve("r1", root, prefix, hub);
    if drop_keys {
        channels.control.tx = without_key_frames(channels.control.tx);
    }
    let session = Session::start("r1", channels, q.route(), q.link_events());
    q.add_runner(
        RemoteRunner {
            os: Default::default(),
            name: "r1".into(),
            trust,
            accept: forseti::Accept::All,
            grace_s: 600,
            image: Some(img.into()),
        },
        session,
    );
    (q, events, child)
}

/// Job ID running SCRIPT in IMAGE with the keys KEYS (each read into the variable of its name).
fn job(id: &str, script: &str, keys: &[&str], image: &str) -> Submit {
    let keys: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
    let spec = JobSpec {
        name: id.into(),
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
        restartable: false,
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
        trust: JobTrust::PrivateKeys,
        keys: keys.clone(),
        local_only: false,
        writes: vec![],
        os: Default::default(),
    };
    Submit {
        id: id.into(),
        session: Some("s1".into()),
        own: Priority::P3,
        spec,
        place: Placement {
            send: SendMode::All,
            image: Some(image.into()),
            keys,
            ..Placement::default()
        },
        pending: serde_json::Value::Null,
        inputs: None,
    }
}

/// Waits until r1 is in rotation (its `hello-ok`).
async fn ready(q: &Queue, events: &mut UnboundedReceiver<LinkEvent>, outcomes: &mut Vec<Outcome>) {
    drive(q, events, outcomes, "r1 ready", |q, _| {
        q.runner("r1").filter(|r| r.state == "ready").map(|_| ())
    })
    .await;
}

/// Job ID's result, once its runner sent it.
async fn result(
    q: &Queue,
    events: &mut UnboundedReceiver<LinkEvent>,
    outcomes: &mut Vec<Outcome>,
    id: &str,
) -> serde_json::Value {
    drive(q, events, outcomes, &format!("{id}'s result"), |_, o| {
        o.iter().find_map(|o| match o {
            Outcome::Done { id: x, result, .. } if x == id => Some(result.clone()),
            _ => None,
        })
    })
    .await
}

fn hold(q: &Queue, pairs: &[(&str, &str)]) {
    q.take_keys(
        pairs
            .iter()
            .map(|(n, v)| (n.to_string(), SecretString::from(v.to_string()))),
        now(),
    );
}

/// The hub's copy of job ID's log.
fn hub_log(dir: &Path, id: &str) -> String {
    std::fs::read_to_string(dir.join("exec").join(id).join("log")).unwrap_or_default()
}

/// The sha256 of V as `sha256sum` prints it.
fn sha256(v: &str) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(v.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

mod keys {
    use super::*;

    /// [C] Two keys: one `key` frame and one `key_sent` row each, after `started`; the job's one read of each through
    /// `drgnx-key` comes back as one runner-reported `key_use` row each; the job had the right values (their hashes);
    /// and once it is done no file under the runner's root holds either value.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn one_key_sent_per_key_and_key_use_per_read_and_no_key_bytes_on_the_runner() {
        let (prefix, hub) = ("flkeys", "hubkeys");
        let root = root("r1", "fl-keys");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let (a, b) = (throwaway(), throwaway());
        let (q, mut events, _child) =
            queue_r1(dir.path(), &root, prefix, hub, &img, RunnerTrust::Mine);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        hold(&q, &[("FLEET_A", &a), ("FLEET_B", &b)]);
        let script = "printf %s \"$FLEET_A\" | sha256sum; printf %s \"$FLEET_B\" | sha256sum";
        q.submit(job("xkeys", script, &["FLEET_A", "FLEET_B"], &img), now());
        let r = result(&q, &mut events, &mut outcomes, "xkeys").await;
        assert_eq!(r["verdict"], "Pass", "{r}");
        let log = hub_log(dir.path(), "xkeys");
        assert!(
            log.contains(&sha256(&a)) && log.contains(&sha256(&b)),
            "{log}"
        );
        let audit = q.keys().audit(Some("xkeys"), None);
        let count = |kind: AuditKind, key: &str| {
            audit
                .iter()
                .filter(|x| x.kind == kind && x.key.as_str() == key)
                .count()
        };
        for k in ["FLEET_A", "FLEET_B"] {
            assert_eq!(count(AuditKind::Sent, k), 1, "{k}: {audit:?}");
            assert_eq!(count(AuditKind::Use, k), 1, "{k}: {audit:?}");
        }
        assert!(
            audit
                .iter()
                .all(|x| x.runner == "r1" && x.runner_reported == (x.kind == AuditKind::Use))
        );
        // fixed strings, so neither value is a pattern; grep's status 1 (nothing found) is what the row wants
        for v in [&a, &b] {
            let found = sh(
                "r1",
                &format!("grep -rlF -- '{v}' {root} /tmp 2>/dev/null; true"),
            );
            assert_eq!(found, "", "a key's bytes stayed on the runner");
        }
    }

    /// [C] A job that prints its key raw and in base64: the hub's copy of the log holds neither form, and the raw one
    /// is masked where it was (the line keeps its length).
    #[tokio::test]
    #[ignore = "fleet"]
    async fn the_keys_bytes_are_redacted_from_the_returned_log() {
        let (prefix, hub) = ("flredact", "hubredact");
        let root = root("r1", "fl-redact");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let v = throwaway();
        let (q, mut events, _child) =
            queue_r1(dir.path(), &root, prefix, hub, &img, RunnerTrust::Mine);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        hold(&q, &[("FLEET_TOKEN", &v)]);
        let script =
            "echo \"raw=$FLEET_TOKEN.\"; printf %s \"$FLEET_TOKEN\" | base64 -w0; echo; echo end";
        q.submit(job("xredact", script, &["FLEET_TOKEN"], &img), now());
        let r = result(&q, &mut events, &mut outcomes, "xredact").await;
        assert_eq!(r["verdict"], "Pass", "{r}");
        let log = hub_log(dir.path(), "xredact");
        assert!(log.ends_with("end\n"), "the whole log came back: {log}");
        assert!(!log.contains(&v), "the raw value: {log}");
        assert!(!log.contains(&base64(v.as_bytes())), "its base64: {log}");
        let mask = "*".repeat(v.len());
        assert!(log.contains(&format!("raw={mask}.")), "{log}");
    }

    /// [C] A `shared` runner never gets a keyed job, so never a `key` frame: the job waits and says why, and the
    /// audit has no row.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_shared_runner_never_receives_a_key_frame() {
        let (prefix, hub) = ("flshared", "hubshared");
        let root = root("r1", "fl-kshared");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let v = throwaway();
        let (q, mut events, _child) =
            queue_r1(dir.path(), &root, prefix, hub, &img, RunnerTrust::Shared);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        hold(&q, &[("FLEET_TOKEN", &v)]);
        q.submit(job("xshared", "true", &["FLEET_TOKEN"], &img), now());
        for _ in 0..5 {
            q.tick(now());
            let row = q.row("xshared").expect("the row");
            assert_eq!(
                (row.machine.as_deref(), row.attempt),
                (None, None),
                "{row:?}"
            );
            let w = row.waiting.unwrap_or_default();
            assert!(w.contains("waits for a runner"), "{w:?}");
        }
        assert!(q.keys().audit(None, None).is_empty());
    }

    /// [C] A key the hub held and sent, that didn't arrive on a link that stayed up (its `key` frame is held back on
    /// the way; pings and everything else go through): the job's `drgnx-key` gives up after its 60 s, which pass on
    /// the runner while the row waits on the announced result; the verdict is infra (`key not delivered`), never red;
    /// the audit has the send and no read; the link was never lost (a lost link fails the row inside `drive`).
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_key_that_never_arrives_is_infra_not_red() {
        let (prefix, hub) = ("flnokey", "hubnokey");
        let root = root("r1", "fl-nokey");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let v = throwaway();
        let (q, mut events, _child) = queue_r1_with(
            dir.path(),
            &root,
            prefix,
            hub,
            &img,
            RunnerTrust::Mine,
            true,
        );
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        hold(&q, &[("FLEET_LOST", &v)]);
        q.submit(job("xnokey", "true", &["FLEET_LOST"], &img), now());
        let r = result(&q, &mut events, &mut outcomes, "xnokey").await;
        assert_eq!(
            r["verdict"],
            serde_json::json!({"Infra": forseti::classify::infra::KEY_NOT_DELIVERED}),
            "{r}"
        );
        let audit = q.keys().audit(Some("xnokey"), None);
        let count = |kind: AuditKind| audit.iter().filter(|x| x.kind == kind).count();
        assert_eq!(count(AuditKind::Sent), 1, "the hub sent it: {audit:?}");
        assert_eq!(count(AuditKind::Use), 0, "the job never read it: {audit:?}");
        assert_eq!(
            q.runner("r1").map(|r| r.state),
            Some("ready".to_string()),
            "the link stayed up"
        );
    }

    /// [C] While a keyed job runs (parked on a FIFO after it read its key), `podman inspect` of its container holds
    /// the key's name and never its value, and the container's cgroup has `memory.swap.max` 0.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn podman_inspect_shows_names_only_and_memory_swap_max_is_0() {
        let (prefix, hub) = ("flinsp", "hubinsp");
        let root = root("r1", "fl-insp");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let v = throwaway();
        let (q, mut events, _child) =
            queue_r1(dir.path(), &root, prefix, hub, &img, RunnerTrust::Mine);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        hold(&q, &[("FLEET_TOKEN", &v)]);
        let script = "test -n \"$FLEET_TOKEN\" && echo parked; mkfifo /tmp/gate; read x < /tmp/gate; echo released";
        q.submit(job("xinsp", script, &["FLEET_TOKEN"], &img), now());
        drive(&q, &mut events, &mut outcomes, "the job parks", |_, _| {
            hub_log(dir.path(), "xinsp")
                .contains("parked\n")
                .then_some(())
        })
        .await;
        let c = format!("{prefix}-xinsp");
        let inspect = sh("r1", &format!("podman inspect {c}"));
        assert!(inspect.contains("FLEET_TOKEN"), "the name is there");
        assert!(!inspect.contains(&v), "the value is not");
        let swap = sh(
            "r1",
            &format!("podman exec {c} cat /sys/fs/cgroup/memory.swap.max"),
        );
        assert_eq!(swap, "0");
        sh(
            "r1",
            &format!("podman exec {c} sh -c 'echo go > /tmp/gate'"),
        );
        let r = result(&q, &mut events, &mut outcomes, "xinsp").await;
        assert_eq!(r["verdict"], "Pass", "{r}");
    }
}
