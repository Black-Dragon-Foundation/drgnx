//! A Mac runner end to end (design §10's macOS CI rows, `#[ignore = "macos-runner"]`): the hub's own registry and
//! queue add the CI host's `drgnx-runner` account over its localhost `sshd` (the own-machine refusal is the hub's boot
//! id, which these rows set apart), copy the bundle, link `serve`, run host jobs under the build profile, survive the
//! link's `-O stop` and a killed `serve`, see the watchdog kill a job past its grant with its double-forked child, and
//! `remove` the runner leaving nothing. The macOS lane makes the account, its Remote Login and a key, names the host
//! in `DRGNX_TEST_MAC_RUNNER` (an ssh alias for `drgnx-runner@localhost`) and the bundle's `sleipnir` in
//! `DRGNX_TEST_MAC_BUNDLE`, and runs `cargo test --test mac_runner -- --ignored --test-threads=1`
//! (docs/develop/ci.md, "macOS").
//!
//! Every row is [C]: a real `serve` and its jobs announce their state in frames, the queue's rows say where each job
//! is, and the row waits on that. No sleeps in the rows, no widened deadlines. The rows build on any unix (so Linux
//! type-checks them); only the macOS lane runs them.
#![cfg(all(unix, not(target_os = "android")))]

use drgnx_ratatoskr::runners::link::LinkEvent;
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{Outcome, Placement, Queue, QueueCfg, SendMode, Submit};
use drgnx_ratatoskr::runners::registry::{Cfg, MAC_BUNDLE, MemStore, Registry};
use drgnx_ratatoskr::runners::sync::{self, Frozen, Visibility};
use drgnx_ratatoskr::runners::transport::{OpensshTransport, Transport};
use forseti::{Expect, JobSpec, Kind, Lane, Priority, Range, Weight};
use runstav::methods::runners::AddParams;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;

/// How long a row waits on any one announced state before it fails.
const WAIT: u64 = 120;

fn host() -> String {
    std::env::var("DRGNX_TEST_MAC_RUNNER").expect("DRGNX_TEST_MAC_RUNNER: the macOS lane sets it")
}

/// SCRIPT's stdout as the runner account; panics when it fails.
fn sh(script: &str) -> String {
    let out = Command::new("ssh")
        .args(["-o", "BatchMode=yes", &host(), script])
        .output()
        .expect("ssh");
    assert!(
        out.status.success(),
        "{script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// The hub of a row: a registry and its queue on DIR, the bundle from the lane, and the queue's link events.
struct Hub {
    reg: Registry,
    q: Arc<Queue>,
    events: UnboundedReceiver<LinkEvent>,
    outcomes: Vec<Outcome>,
}

impl Hub {
    fn new(dir: &Path) -> Hub {
        let bundle = std::env::var("DRGNX_TEST_MAC_BUNDLE")
            .expect("DRGNX_TEST_MAC_BUNDLE: the lane sets it");
        let bundles = dir.join("bundles");
        std::fs::create_dir_all(bundles.join(MAC_BUNDLE)).unwrap();
        std::fs::copy(&bundle, bundles.join(MAC_BUNDLE).join("sleipnir")).unwrap();
        let run = dir.join("run");
        std::fs::create_dir_all(&run).unwrap();
        let (q, events) = Queue::new(QueueCfg {
            hub_id: "hub-mac-ci".into(),
            exec_root: dir.join("exec"),
            local: LocalRunner::new(Admission::Fixed(1), dir),
            db: None,
        });
        let reg = Registry::new(Cfg {
            transport: Arc::new(OpensshTransport::new(&run)),
            store: Arc::new(MemStore::default()),
            queue: q.clone(),
            hub_id: "hub-mac-ci".into(),
            // the CI host is the hub's own machine: a boot id of its own lets it be added as a runner
            hub_boot_id: "a-hub-elsewhere".into(),
            runtime_dir: run,
            bundles,
            images: Arc::new(Vec::new),
            toolchains: Arc::new(Vec::new),
        });
        Hub {
            reg,
            q,
            events,
            outcomes: vec![],
        }
    }

    /// The runner added as NAME with its root at ROOT (under the account's home), in rotation.
    async fn add(&mut self, name: &str, root: &str) -> serde_json::Value {
        let p: AddParams = serde_json::from_value(json!({
            "host": host(), "trust": "mine", "name": name, "profile": "workstation", "root": root,
        }))
        .unwrap();
        let view = self.reg.add(p).await.expect("the Mac is added");
        let view = serde_json::to_value(view).unwrap();
        self.drive(&format!("{name} ready"), |q, _| {
            q.runner(name).filter(|r| r.state == "ready").map(|_| ())
        })
        .await;
        view
    }

    /// Drains the link events into the queue, ticks it, and returns what CHECK makes of it, within the wait. A lost
    /// link fails the row.
    async fn drive<T>(
        &mut self,
        what: &str,
        check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
    ) -> T {
        self.drive_lost(what, false, check).await
    }

    /// [`Self::drive`]; with LOST_OK a lost link is taken into the queue too.
    async fn drive_lost<T>(
        &mut self,
        what: &str,
        lost_ok: bool,
        mut check: impl FnMut(&Queue, &[Outcome]) -> Option<T>,
    ) -> T {
        let (q, events, outcomes) = (&self.q, &mut self.events, &mut self.outcomes);
        skuld::wait_until_async(what, WAIT, || {
            while let Ok(ev) = events.try_recv() {
                if let LinkEvent::Lost { why, .. } = &ev {
                    assert!(lost_ok, "the link was lost waiting for {what}: {why}");
                }
                outcomes.extend(q.on_link(ev, now()));
            }
            outcomes.extend(q.tick(now()).outcomes);
            std::future::ready(check(q, outcomes))
        })
        .await
    }

    /// Job ID's result, once its runner sent it.
    async fn result(&mut self, id: &str) -> serde_json::Value {
        self.drive(&format!("{id}'s result"), |_, o| {
            o.iter().find_map(|o| match o {
                Outcome::Done { id: x, result, .. } if x == id => Some(result.clone()),
                _ => None,
            })
        })
        .await
    }

    /// Waits until job ID runs on NAME.
    async fn running(&mut self, id: &str, name: &str) {
        self.drive(&format!("{id} running on {name}"), |q, _| {
            q.row(id)
                .filter(|r| r.machine.as_deref() == Some(name) && r.attempt.is_some())
                .map(|_| ())
        })
        .await;
    }
}

/// A private project in DIR with one committed file.
fn project(dir: &Path) -> (PathBuf, PathBuf) {
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    git(&work, &["init", "-q"]);
    std::fs::write(work.join("hello.txt"), "hello from the hub\n").unwrap();
    git(&work, &["add", "-A"]);
    git(&work, &["commit", "-qm", "hello"]);
    (work, dir.join("blobs"))
}

fn freeze(work: &Path, blobs: &Path) -> Frozen {
    sync::freeze(work, &[], Visibility::Private, false, blobs).expect("the inputs freeze")
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

/// Job ID: SCRIPT on a Mac, in the project's tree, with a grant of MEM_MIB.
fn job(id: &str, script: &str, frozen: Frozen, mem_mib: u64) -> Submit {
    let trust = frozen.trust(&[]);
    let spec = JobSpec {
        name: id.into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: frozen.worktree.clone(),
        cwd: PathBuf::from("."),
        command: vec!["/bin/sh".into(), "-c".into(), script.into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range {
            min: 64,
            max: mem_mib,
        },
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
        trust,
        keys: vec![],
        local_only: false,
        writes: vec![],
        os: forseti::Os::Macos,
    };
    Submit {
        id: id.into(),
        session: Some("s1".into()),
        own: Priority::P3,
        spec,
        place: Placement {
            send: SendMode::All,
            ..Placement::default()
        },
        pending: serde_json::Value::Null,
        inputs: Some(frozen),
    }
}

fn log(dir: &Path, id: &str) -> String {
    std::fs::read_to_string(dir.join("exec").join(id).join("log")).unwrap_or_default()
}

/// The account's home, and a root of the row's own under it.
fn root(name: &str) -> String {
    let home = sh("printf %s \"$HOME\"");
    let root = format!("{home}/.drgnx-mr-{name}.noindex");
    sh(&format!("rm -rf '{root}'"));
    root
}

mod mac_runner {
    use super::*;

    /// [C] `runner add` of the Mac (the contract passes, the bundle is copied into its root, `serve` linked) shows it
    /// as macOS; a private host job reads its committed file on Darwin under the build profile and passes; a job's
    /// `brew --prefix` gets the shim's answer; `remove` leaves no root and no process of the hub behind.
    #[tokio::test]
    #[ignore = "macos-runner"]
    async fn add_a_host_job_and_remove() {
        let dir = tempfile::tempdir().unwrap();
        let root = root("e2e");
        let mut hub = Hub::new(dir.path());
        let view = hub.add("mac", &root).await;
        assert!(view.to_string().contains("macos"), "{view}");
        assert!(!sh(&format!("ls '{root}/bin'")).is_empty());
        let (work, blobs) = project(dir.path());
        hub.q.submit(
            job(
                "xhello",
                "uname -s; cat hello.txt; brew --prefix --installed mise",
                freeze(&work, &blobs),
                512,
            ),
            now(),
        );
        let r = hub.result("xhello").await;
        let log = log(dir.path(), "xhello");
        assert_eq!(r["verdict"], "Pass", "{r} {log}");
        for want in ["Darwin", "hello from the hub", "/opt/homebrew/opt/mise"] {
            assert!(log.contains(want), "{want}: {log}");
        }
        hub.reg.remove("mac").await.expect("removed");
        assert_eq!(
            sh(&format!("test -e '{root}' && echo left || echo gone")),
            "gone"
        );
        // serve ends at its link's end, which remove closed
        skuld::wait_until_async("no serve or job-exec left", WAIT, || {
            let left = sh("pgrep -fl 'sleipnir (serve|job-exec)' || true");
            std::future::ready(left.is_empty().then_some(()))
        })
        .await;
    }

    /// [C] A job past its 512 MiB grant, with a double-forked child holding as much outside its group, is killed by
    /// the watchdog: the verdict is `oom` (the job's own, no strike), and neither process is left.
    #[tokio::test]
    #[ignore = "macos-runner"]
    async fn the_watchdog_kills_a_job_past_its_grant_and_its_escapee() {
        let dir = tempfile::tempdir().unwrap();
        let root = root("oom");
        let mut hub = Hub::new(dir.path());
        hub.add("mac", &root).await;
        let (work, blobs) = project(dir.path());
        let hog = "/usr/bin/perl -e '$x = q(a) x (400*1024*1024); sleep 300'";
        let script = format!("( {hog} & ) ; {hog}");
        hub.q
            .submit(job("xhog", &script, freeze(&work, &blobs), 512), now());
        let r = hub.result("xhog").await;
        assert_eq!(r["verdict"], "Oom", "{r} {}", log(dir.path(), "xhog"));
        assert_eq!(sh("pgrep -fl 'q\\(a\\) x' || true"), "");
        hub.reg.remove("mac").await.expect("removed");
    }

    /// [C] A running job outlives its link: the ssh master stopped (`-O stop`), then `serve` killed; each time
    /// `runner check` links it again and the job's result arrives, a pass.
    #[tokio::test]
    #[ignore = "macos-runner"]
    async fn a_job_survives_the_link_stopped_and_serve_killed() {
        let dir = tempfile::tempdir().unwrap();
        let root = root("link");
        let mut hub = Hub::new(dir.path());
        hub.add("mac", &root).await;
        let (work, blobs) = project(dir.path());
        // the job runs until the row writes `go` into its attempt's folder (the job's own TMPDIR's parent)
        let script = "touch \"$TMPDIR/../started\"; while [ ! -e \"$TMPDIR/../go\" ]; do /bin/sleep 0.2; done; echo survived";
        hub.q
            .submit(job("xlink", script, freeze(&work, &blobs), 512), now());
        hub.running("xlink", "mac").await;
        let started = |root: &str| {
            sh(&format!(
                "ls -d '{root}'/jobs/*/started 2>/dev/null | head -n 1"
            ))
        };
        skuld::wait_until_async("the job started", WAIT, || {
            let s = started(&root);
            std::future::ready((!s.is_empty()).then_some(()))
        })
        .await;

        // the ssh master stopped: the link is lost, the job runs on
        OpensshTransport::new(dir.path().join("run"))
            .stop("mac")
            .await;
        hub.drive_lost("the link lost", true, |q, _| {
            q.runner("mac").filter(|r| r.state != "ready").map(|_| ())
        })
        .await;
        hub.reg.check("mac").await.expect("linked again");
        hub.running("xlink", "mac").await;

        // serve killed: the link is lost again, the job still runs
        sh("pkill -f 'sleipnir serve' || true");
        hub.drive_lost("the link lost again", true, |q, _| {
            q.runner("mac").filter(|r| r.state != "ready").map(|_| ())
        })
        .await;
        hub.reg.check("mac").await.expect("linked again");
        let s = started(&root);
        let attempt = Path::new(&s).parent().unwrap().display().to_string();
        sh(&format!("touch '{attempt}/go'"));
        let r = hub.result("xlink").await;
        let log = log(dir.path(), "xlink");
        assert_eq!(r["verdict"], "Pass", "{r} {log}");
        assert!(log.contains("survived"), "{log}");
        hub.reg.remove("mac").await.expect("removed");
    }
}
