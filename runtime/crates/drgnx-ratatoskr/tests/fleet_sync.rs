//! Sync's rows over real SSH to a real `sleipnir serve` in a fake runner (`#[ignore = "fleet"]`, test/runners/): a
//! job's trust from what the public origin has (unpushed commits keep it private), a `shared` runner fetching from
//! the origin itself, and the overlay a `shared` runner gets only when the project allows it and it passes the scan.
//! They run in a fleet's harness only:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet --test fleet_sync --no-run
//! cargo build -p sleipnir --features test-hooks        # the bundle each row installs (fleet.sh test shares it)
//! fleet.sh up --runners 1
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1
//! ```
//!
//! Each row installs the shared `sleipnir` (a `test-hooks` build, which alone fetches from a plain `http://` origin)
//! into a runner root of its own and writes the quiet machine's figures there. The origin is git's own `http-backend`
//! served by the row from the harness. Every row is [C]: a real `serve` announces its state in frames, the queue's
//! rows say where each job is and why, and the row waits on that.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::link::{LinkEvent, Session};
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{
    Outcome, Placement, Queue, QueueCfg, RemoteRunner, SendMode, Submit,
};
use drgnx_ratatoskr::runners::sync::{self, Frozen, Visibility};
use drgnx_ratatoskr::runners::transport::{Channel, Channels};
use forseti::{Expect, JobSpec, Kind, Lane, Priority, Range, RunnerTrust, Weight};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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

/// The wall clock as the queue takes it: a value, never waited on.
fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
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

/// The user's git in DIR: no system or global config, a fixed identity.
fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// This harness's address on the fleet network, as RUNNER reaches it.
fn harness_addr(runner: &str) -> IpAddr {
    let s = UdpSocket::bind("0.0.0.0:0").unwrap();
    s.connect((runner, 22)).unwrap();
    s.local_addr().unwrap().ip()
}

/// A smart-HTTP origin on this harness (git's own `http-backend` behind a minimal HTTP/1.1 server) over the
/// repositories in ROOT: its port.
fn origin_server(root: PathBuf) -> u16 {
    let l = TcpListener::bind("0.0.0.0:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            serve_one(s, &root);
        }
    });
    port
}

fn serve_one(mut s: TcpStream, root: &Path) {
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    r.read_line(&mut line).unwrap();
    let mut words = line.split_whitespace();
    let (method, target) = (
        words.next().unwrap_or("").to_string(),
        words.next().unwrap_or("").to_string(),
    );
    let mut headers = BTreeMap::new();
    loop {
        let mut h = String::new();
        if r.read_line(&mut h).unwrap() == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let mut body = Vec::new();
    if let Some(n) = headers.get("content-length") {
        body.resize(n.parse().unwrap(), 0);
        r.read_exact(&mut body).unwrap();
    } else if headers
        .get("transfer-encoding")
        .is_some_and(|v| v.eq_ignore_ascii_case("chunked"))
    {
        loop {
            let mut size = String::new();
            r.read_line(&mut size).unwrap();
            let n = usize::from_str_radix(size.trim().split(';').next().unwrap(), 16).unwrap();
            let mut chunk = vec![0; n + 2];
            r.read_exact(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..n]);
        }
    }
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let mut cgi = Command::new("git");
    cgi.arg("http-backend")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_PROJECT_ROOT", root)
        .env("GIT_HTTP_EXPORT_ALL", "1")
        .env("PATH_INFO", path)
        .env("QUERY_STRING", query)
        .env("REQUEST_METHOD", &method)
        .env("REMOTE_ADDR", "127.0.0.1")
        .env("CONTENT_LENGTH", body.len().to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    for (h, var) in [
        ("content-type", "CONTENT_TYPE"),
        ("content-encoding", "HTTP_CONTENT_ENCODING"),
        ("git-protocol", "GIT_PROTOCOL"),
    ] {
        if let Some(v) = headers.get(h) {
            cgi.env(var, v);
        }
    }
    let mut child = cgi.spawn().unwrap();
    child.stdin.take().unwrap().write_all(&body).unwrap();
    let out = child.wait_with_output().unwrap();
    let o = out.stdout;
    let split = o
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| (i, 4))
        .or_else(|| o.windows(2).position(|w| w == b"\n\n").map(|i| (i, 2)))
        .unwrap();
    let head = String::from_utf8_lossy(&o[..split.0]).to_string();
    let rest = &o[split.0 + split.1..];
    let mut status = "200 OK".to_string();
    let mut reply = Vec::new();
    for h in head.lines() {
        match h.strip_prefix("Status:") {
            Some(st) => status = st.trim().to_string(),
            None => reply.extend_from_slice(format!("{h}\r\n").as_bytes()),
        }
    }
    let mut msg = format!("HTTP/1.1 {status}\r\n").into_bytes();
    msg.extend_from_slice(&reply);
    msg.extend_from_slice(
        format!(
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
            rest.len()
        )
        .as_bytes(),
    );
    msg.extend_from_slice(rest);
    s.write_all(&msg).unwrap();
}

/// The project: a public origin (a bare repository served over HTTP to the runner) and the user's worktree of it
/// with one commit pushed.
struct Project {
    origin: PathBuf,
    work: PathBuf,
    blobs: PathBuf,
}

impl Project {
    fn new(dir: &Path, runner: &str) -> Project {
        let served = dir.join("served");
        std::fs::create_dir_all(&served).unwrap();
        let origin = served.join("origin.git");
        git(dir, &["init", "-q", "--bare", origin.to_str().unwrap()]);
        let work = dir.join("work");
        std::fs::create_dir_all(&work).unwrap();
        git(&work, &["init", "-q"]);
        let port = origin_server(served);
        let url = format!("http://{}:{port}/origin.git", harness_addr(runner));
        git(&work, &["remote", "add", "origin", &url]);
        let p = Project {
            origin,
            work,
            blobs: dir.join("blobs"),
        };
        p.commit("hello.txt", "hello from origin\n");
        p.push();
        p
    }

    fn commit(&self, file: &str, text: &str) {
        std::fs::write(self.work.join(file), text).unwrap();
        git(&self.work, &["add", "-A"]);
        git(&self.work, &["commit", "-qm", file]);
    }

    /// Pushes to the origin, and the worktree's refs/remotes/origin follow, as after a `git push`.
    fn push(&self) {
        let o = self.origin.to_str().unwrap();
        git(&self.work, &["push", "-q", o, "HEAD:main"]);
        git(
            &self.work,
            &["fetch", "-q", o, "+refs/heads/*:refs/remotes/origin/*"],
        );
    }

    fn freeze(&self, shared_overlay: bool) -> Frozen {
        sync::freeze(
            &self.work,
            &[],
            Visibility::Public,
            shared_overlay,
            &self.blobs,
        )
        .expect("the inputs freeze")
    }
}

/// A queue on DIR whose one local slot a job holds, and the `shared` runner r1 (serve in ROOT).
fn queue_shared(
    dir: &Path,
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
        exec_root: dir.join("exec"),
        local: LocalRunner::new(Admission::Fixed(1), dir),
        db: None,
    });
    q.adopt("xbusy", Priority::P1, now());
    let (channels, child) = serve("r1", root, prefix, hub);
    let session = Session::start("r1", channels, q.route(), q.link_events());
    q.add_runner(
        RemoteRunner {
            name: "r1".into(),
            trust: RunnerTrust::Shared,
            accept: forseti::Accept::All,
            grace_s: 600,
            image: Some(img.into()),
        },
        session,
    );
    (q, events, child)
}

/// Job ID running SCRIPT in the project's tree (in IMAGE), with its inputs FROZEN.
fn job(id: &str, script: &str, frozen: Frozen, image: &str) -> Submit {
    let spec = JobSpec {
        name: id.into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: frozen.worktree.clone(),
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
        trust: frozen.trust(&[]),
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
            send: SendMode::All,
            image: Some(image.into()),
            ..Placement::default()
        },
        pending: serde_json::Value::Null,
        inputs: Some(frozen),
    }
}

/// Waits until r1 is in rotation (its `hello-ok`).
async fn ready(q: &Queue, events: &mut UnboundedReceiver<LinkEvent>, outcomes: &mut Vec<Outcome>) {
    drive(q, events, outcomes, "r1 ready", |q, _| {
        q.runner("r1").filter(|r| r.state == "ready").map(|_| ())
    })
    .await;
}

/// Ticks the queue a few times with r1 ready: job ID is offered nowhere, and waits saying WHY (a part of it).
fn stays_here(q: &Queue, id: &str, why: &str) {
    for _ in 0..5 {
        q.tick(now());
        let row = q.row(id).expect("the row");
        assert_eq!(
            (row.machine.as_deref(), row.attempt),
            (None, None),
            "{row:?}"
        );
        let w = row.waiting.unwrap_or_default();
        assert!(w.contains(why), "{id}: {w:?} doesn't say {why:?}");
    }
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

mod sync_rows {
    use super::*;

    /// [C] a public project's job with one commit the origin lacks is `private`, so it never goes to the shared
    /// runner, and its row says "runs here: 1 commit not on origin". Once pushed, a new job of the project is
    /// public and is offered to it; the first job's inputs stay as they were frozen.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn one_unpushed_commit_keeps_a_public_job_off_shared() {
        let (prefix, hub) = ("flh7", "hubh7");
        let root = root("r1", "fl-h7");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let p = Project::new(dir.path(), "r1");
        p.commit("ahead.txt", "not pushed\n");
        let (q, mut events, _child) = queue_shared(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        let ahead = p.freeze(false);
        assert_eq!(ahead.trust(&[]), forseti::JobTrust::Private);
        q.submit(job("xahead", "true", ahead, &img), now());
        stays_here(&q, "xahead", "runs here: 1 commit not on origin");
        p.push();
        q.submit(job("xpushed", "true", p.freeze(false), &img), now());
        let row = drive(&q, &mut events, &mut outcomes, "xpushed offered", |q, _| {
            q.row("xpushed").filter(|r| r.machine.is_some())
        })
        .await;
        assert_eq!((row.machine.as_deref(), row.attempt), (Some("r1"), Some(1)));
        stays_here(&q, "xahead", "runs here: 1 commit not on origin");
    }

    /// [C] A public job on the shared runner: the runner fetches the commit from the origin itself (into its mirror,
    /// with no bundle from the hub), checks its slot out, and the job reads the committed file.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn the_shared_runner_fetches_from_origin() {
        let (prefix, hub) = ("florigin", "huborigin");
        let root = root("r1", "fl-origin");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let p = Project::new(dir.path(), "r1");
        let (q, mut events, _child) = queue_shared(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        let f = p.freeze(false);
        let repo = f.repo.clone();
        q.submit(job("xorigin", "cat hello.txt", f, &img), now());
        let r = result(&q, &mut events, &mut outcomes, "xorigin").await;
        assert_eq!(r["verdict"], "Pass", "{r}");
        let log = std::fs::read_to_string(dir.path().join("exec/xorigin/log")).unwrap_or_default();
        assert!(log.contains("hello from origin"), "{log}");
        let refs = sh(
            "r1",
            &format!("git --git-dir {root}/git/{repo} for-each-ref --format='%(refname)'"),
        );
        assert!(refs.contains("refs/origin/heads/main"), "{refs}");
        assert!(
            !refs.contains("refs/hub/"),
            "nothing came from the hub: {refs}"
        );
    }

    /// [C] An uncommitted file keeps a public job off the shared runner while the project's
    /// `drgnx-runners-shared-overlay` is off; on, a file that looks like a secret still does, naming it; a clean
    /// overlay goes, the job reads it, and its result comes back as the shared runner's.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn shared_overlay_off_by_default_and_scanned_when_on() {
        let (prefix, hub) = ("flover", "hubover");
        let root = root("r1", "fl-over");
        let img = image("r1");
        let dir = tempfile::tempdir().unwrap();
        let p = Project::new(dir.path(), "r1");
        std::fs::write(p.work.join("note.txt"), "overlay!\n").unwrap();
        let (q, mut events, _child) = queue_shared(dir.path(), &root, prefix, hub, &img);
        let mut outcomes = vec![];
        ready(&q, &mut events, &mut outcomes).await;
        q.submit(job("xoff", "cat note.txt", p.freeze(false), &img), now());
        stays_here(&q, "xoff", "drgnx-runners-shared-overlay");
        // split, so the repository's own secret check passes this file
        let key = concat!("AKIA", "IOSFODNN7EXAMPLE");
        std::fs::write(
            p.work.join("leak.txt"),
            format!("aws_access_key_id = {key}\n"),
        )
        .unwrap();
        q.submit(job("xleak", "cat note.txt", p.freeze(true), &img), now());
        stays_here(&q, "xleak", "leak.txt");
        std::fs::remove_file(p.work.join("leak.txt")).unwrap();
        q.submit(job("xon", "cat note.txt", p.freeze(true), &img), now());
        let r = result(&q, &mut events, &mut outcomes, "xon").await;
        assert_eq!(r["verdict"], "Pass", "{r}");
        // a shared runner's result comes back named as the shared runner's, so it is labelled and never counts for a
        // gate
        let shared = outcomes.iter().find_map(|o| match o {
            Outcome::Done { id, shared, .. } if id == "xon" => Some(shared.clone()),
            _ => None,
        });
        assert_eq!(shared, Some(Some("r1".to_string())), "{outcomes:?}");
        let log = std::fs::read_to_string(dir.path().join("exec/xon/log")).unwrap_or_default();
        assert!(log.contains("overlay!"), "{log}");
        stays_here(&q, "xoff", "drgnx-runners-shared-overlay");
    }
}
