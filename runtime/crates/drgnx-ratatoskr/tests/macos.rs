//! The hub on macOS (the macOS lane runs the whole workspace, so these rows run there; every row but the sshd one
//! also runs on Linux, which is where they are written): placement and the trust filter, the generated ssh config
//! against a localhost `sshd`, a sync into a local mirror, an agent's job with no eligible runner, and `runner add` of
//! a macOS host. A Mac is a hub here and never a runner. The sshd row is `#[ignore = "macos-sshd"]`: the lane turns
//! on Remote Login with a throwaway key and a `localhost` entry in `~/.ssh/config`, names the host in
//! `DRGNX_TEST_SSHD_HOST` and runs `cargo test --test macos -- --ignored` (docs/develop/ci.md, "macOS").
//!
//! Every row says its pattern: [D] pure (real git or ssh in a temp dir where it names them), [C] a real child whose
//! announced end the row waits on. No sleeps, no widened deadlines.
#![cfg(all(unix, not(target_os = "android")))]

use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{Placement, Queue, QueueCfg, Submit};
use drgnx_ratatoskr::runners::registry::{Cfg, MemStore, RegError, Registry};
use drgnx_ratatoskr::runners::transport::{
    Channel, Channels, LinkError, OpensshTransport, Transport,
};
use drgnx_ratatoskr::runners::{Remote, RunnerCfg, ssh_config};
use forseti::place::{
    Accept, Candidate, Pick, PlaceCtx, RunnerState, Send, filter, pick, trust_ok, why_here,
};
use forseti::{
    Expect, Job, JobId, JobSpec, JobState, JobTrust, Kind, Lane, Priority, Range, RunnerTrust,
    WaitReason, Weight,
};
use mimir::BoxFuture;
use runstav::methods::runners::AddParams;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

fn spec(trust: JobTrust, keys: &[&str]) -> JobSpec {
    JobSpec {
        name: "j".into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/p"),
        cwd: PathBuf::from("."),
        command: vec!["true".into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range { min: 64, max: 256 },
        disk_gib: 0,
        timeout_s: 60,
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
        project: "alpha".into(),
        trust,
        keys: keys.iter().map(|k| k.to_string()).collect(),
        local_only: false,
        writes: vec![],
    }
}

fn job(trust: JobTrust, keys: &[&str]) -> Job {
    Job {
        id: JobId("j".into()),
        spec: spec(trust, keys),
        own: Priority::P3,
        submitted: 0,
        state: JobState::Queued,
        attempt: 1,
        evicted_once: false,
        disturbed: false,
        blocked_caller: false,
    }
}

fn cand(name: &str, local: bool, trust: RunnerTrust) -> Candidate {
    Candidate {
        name: name.into(),
        local,
        trust,
        keys_allowed: vec![],
        features: vec!["podman".into()],
        state: RunnerState::Ready,
        accept: Accept::All,
        link_bps: None,
        missing_bytes: 0,
        start_s: 0.0,
        wait_s: 0.0,
        speed: 1.0,
        history: vec![],
        cloud: None,
    }
}

fn ctx() -> PlaceCtx {
    PlaceCtx {
        eff: Priority::P3,
        send: Send::All,
        machines_cell_allows: true,
        gates_allowed: false,
        cloud_after_s: 120.0,
        now: 1_000_000,
        commits_not_on_origin: 0,
    }
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
        .expect("git");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn commit(dir: &Path, file: &str, text: &str) -> String {
    std::fs::write(dir.join(file), text).unwrap();
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-qm", file]);
    git(dir, &["rev-parse", "HEAD"])
}

mod macos {
    use super::*;

    /// [D] The trust filter and the pick on a Mac hub (it is the local candidate): a public job may go to any runner, a
    /// private one never to `shared`, a keyed one to `my-cloud` only when every key is on its list; and a job the
    /// filter keeps off `shared` is never picked for it, however much sooner it would finish there.
    #[test]
    fn placement_and_trust_filter() {
        let (c, send) = (ctx(), Send::All);
        let shared = cand("box", false, RunnerTrust::Shared);
        let cloud = cand("aws", false, RunnerTrust::MyCloud);
        let mine = cand("desk", false, RunnerTrust::Mine);
        let public = job(JobTrust::Public, &[]);
        let private = job(JobTrust::Private, &[]);
        for r in [&shared, &cloud, &mine] {
            assert_eq!(
                filter(&public, r, send, c.machines_cell_allows),
                Ok(()),
                "{}",
                r.name
            );
        }
        assert!(matches!(
            filter(&private, &shared, send, true),
            Err(WaitReason::Trust(_))
        ));
        assert_eq!(filter(&private, &cloud, send, true), Ok(()));
        assert_eq!(filter(&private, &mine, send, true), Ok(()));
        let keyed = job(JobTrust::Public, &["TOKEN"]);
        assert!(!trust_ok(
            JobTrust::Public,
            &keyed.spec.keys,
            RunnerTrust::MyCloud,
            &[]
        ));
        assert!(trust_ok(
            JobTrust::Public,
            &keyed.spec.keys,
            RunnerTrust::MyCloud,
            &["TOKEN".to_string()]
        ));
        let mut slow_local = cand("local", true, RunnerTrust::Mine);
        slow_local.wait_s = 3600.0;
        assert_ne!(
            pick(&private, &[slow_local, shared], &c),
            Pick::Runner("box".into()),
            "a private job never goes to a shared runner"
        );
    }

    /// [D] A job no runner may take runs on the Mac, and says why: placement picks the local machine with the design's
    /// words, and a queue with no runner at all starts it here (its row names the local machine).
    #[test]
    fn an_agents_job_with_no_runner_runs_here_with_its_reason() {
        let local = cand("local", true, RunnerTrust::Mine);
        let j = job(JobTrust::Private, &[]);
        let cands = [local.clone(), cand("box", false, RunnerTrust::Shared)];
        assert_eq!(pick(&j, &cands, &ctx()), Pick::Local);
        assert_eq!(
            why_here(&j, &cands, &ctx()).as_deref(),
            Some("runs here: project alpha is private; the only free runner is shared")
        );
        let keyed = job(JobTrust::PrivateKeys, &["TOKEN"]);
        assert_eq!(
            why_here(&keyed, &cands, &ctx()).as_deref(),
            Some("runs here: needs key `TOKEN`, which no runner may get")
        );
        let dir = tempfile::tempdir().unwrap();
        let (q, _events) = Queue::new(QueueCfg {
            hub_id: "hub".into(),
            exec_root: dir.path().join("exec"),
            local: LocalRunner::new(Admission::Fixed(1), dir.path()),
            db: None,
        });
        q.submit(
            Submit {
                id: "xagent".into(),
                session: Some("s1".into()),
                own: Priority::P3,
                spec: spec(JobTrust::Private, &[]),
                place: Placement::default(),
                pending: serde_json::Value::Null,
                inputs: None,
            },
            1_000_000,
        );
        let t = q.tick(1_000_000);
        assert_eq!(t.starts, vec!["xagent".to_string()]);
        let row = q.row("xagent").expect("its row");
        assert_eq!(row.machine.as_deref(), Some("local"), "{row:?}");
    }

    /// [D] A commit reaches a local mirror (real git): the mirror lacks it, the hub measures the gap, a push puts the
    /// commit there, the gap is 0 and a later commit's gap is small enough for a push again.
    #[test]
    fn sync_into_a_local_mirror() {
        use drgnx_ratatoskr::runners::sync::{SyncPlan, Visibility, freeze, missing_bytes, plan};
        let t = tempfile::tempdir().unwrap();
        let origin = t.path().join("origin.git");
        git(
            t.path(),
            &["init", "-q", "--bare", origin.to_str().unwrap()],
        );
        git(t.path(), &["clone", "-q", origin.to_str().unwrap(), "work"]);
        let work = t.path().join("work");
        let a = commit(&work, "a", "a\n");
        git(&work, &["push", "-q", "origin", "HEAD:main"]);
        git(&work, &["fetch", "-q", "origin"]);
        let root = t.path().join("runner");
        let mirror = sleipnir::sync::mirror::Mirror::ensure(&root, "p").unwrap();
        assert!(!mirror.has_commit(&a).unwrap());
        let tips = mirror.ref_tips().unwrap();
        assert!(tips.is_empty());
        assert!(missing_bytes(&work, &a, &tips).unwrap() > 0);
        let mirror_dir = root.join("git").join("p");
        git(
            &work,
            &[
                "push",
                "-q",
                mirror_dir.to_str().unwrap(),
                "HEAD:refs/heads/main",
            ],
        );
        assert!(mirror.has_commit(&a).unwrap());
        let tips = mirror.ref_tips().unwrap();
        assert_eq!(tips, vec![a.clone()]);
        assert_eq!(missing_bytes(&work, &a, &tips).unwrap(), 0);
        let b = commit(&work, "b", "b\n");
        let gap = missing_bytes(&work, &b, &tips).unwrap();
        assert!(gap > 0, "the next commit is missing");
        let frozen = freeze(
            &work,
            &[],
            Visibility::Private,
            false,
            &t.path().join("blobs"),
        )
        .unwrap();
        assert_eq!(frozen.commit, b);
        assert_eq!(plan(&frozen, RunnerTrust::Mine, gap, None), SyncPlan::Push);
    }

    /// A transport that runs each session's command on this machine, with `uname` saying Darwin: what `runner add`
    /// sees when the host it was given is a Mac, whatever the machine under the test.
    struct MacHost {
        bin: PathBuf,
    }

    impl Transport for MacHost {
        fn open<'a>(&'a self, r: &'a RunnerCfg) -> BoxFuture<'a, Result<Channels, LinkError>> {
            Box::pin(async move {
                let path = format!(
                    "{}:{}",
                    self.bin.display(),
                    std::env::var("PATH").unwrap_or_default()
                );
                let mut child = tokio::process::Command::new(&r.remote.control[0])
                    .args(&r.remote.control[1..])
                    .env("PATH", path)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .kill_on_drop(true)
                    .spawn()
                    .map_err(|e| LinkError::Refused(e.to_string()))?;
                let mut control = Channel::new(
                    Box::new(child.stdin.take().unwrap()),
                    Box::new(child.stdout.take().unwrap()),
                );
                control.err = Some(Box::new(child.stderr.take().unwrap()));
                tokio::spawn(async move {
                    let _ = child.wait().await;
                });
                let idle =
                    || Channel::new(Box::new(tokio::io::sink()), Box::new(tokio::io::empty()));
                Ok(Channels {
                    control,
                    bulk_in: idle(),
                    bulk_out: idle(),
                })
            })
        }
        fn round_trip<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Duration, LinkError>> {
            Box::pin(async { Ok(Duration::ZERO) })
        }
        fn replace_master<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<(), LinkError>> {
            Box::pin(async { Ok(()) })
        }
        fn stop<'a>(&'a self, _: &'a str) -> BoxFuture<'a, ()> {
            Box::pin(async {})
        }
    }

    /// [C] `runner add` of a Mac: the host's `uname` says Darwin, so the add is refused with what a runner is (a Linux
    /// machine with a systemd user manager and rootless podman), nothing is recorded and no bundle is looked for.
    #[tokio::test]
    async fn runner_add_of_a_macos_host_is_refused_with_the_contract() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let uname = bin.join("uname");
        std::fs::write(
            &uname,
            "#!/bin/sh\ncase \"$1\" in -m) echo arm64 ;; -s) echo Darwin ;; esac\n",
        )
        .unwrap();
        std::fs::set_permissions(&uname, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let (queue, _events) = Queue::new(QueueCfg {
            hub_id: "hub".into(),
            exec_root: dir.path().join("exec"),
            local: LocalRunner::new(Admission::Fixed(1), dir.path()),
            db: None,
        });
        let store = Arc::new(MemStore::default());
        let reg = Registry::new(Cfg {
            transport: Arc::new(MacHost { bin }),
            store: store.clone(),
            queue,
            hub_id: "hub".into(),
            hub_boot_id: "boot".into(),
            runtime_dir: dir.path().to_path_buf(),
            bundles: dir.path().join("bundles"),
            images: Arc::new(Vec::new),
        });
        let p: AddParams =
            serde_json::from_value(json!({"host": "a-mac", "trust": "mine", "name": "mac"}))
                .unwrap();
        let Err(RegError::Refused(why)) = reg.add(p).await else {
            panic!("a Mac was taken as a runner");
        };
        for want in ["a-mac", "Darwin", "Linux", "systemd", "podman"] {
            assert!(why.contains(want), "{want}: {why}");
        }
        use drgnx_ratatoskr::runners::registry::Store;
        assert!(store.list().await.unwrap().is_empty());
    }

    /// [C] The generated ssh config against a localhost `sshd` (the lane's Remote Login, a throwaway key): the forced
    /// options win over the user's file (`ssh -G` shows no agent and no forwards), and the transport opens a session
    /// whose command's output comes back whole. The lane sets `DRGNX_TEST_SSHD_HOST`; a row that finds it unset fails.
    #[tokio::test]
    #[ignore = "macos-sshd"]
    async fn the_generated_config_against_a_localhost_sshd() {
        use tokio::io::AsyncReadExt;
        let host =
            std::env::var("DRGNX_TEST_SSHD_HOST").expect("DRGNX_TEST_SSHD_HOST: the lane sets it");
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("run");
        std::fs::create_dir_all(&run).unwrap();
        let cfg = RunnerCfg {
            name: "localsshd".into(),
            host: host.clone(),
            linger: true,
            cloud: None,
            remote: Remote {
                control: vec!["echo".into(), "from-sshd".into()],
                bulk_in: vec!["true".into()],
                bulk_out: vec!["true".into()],
            },
        };
        cfg.check().unwrap();
        let config = ssh_config::write(&run, &cfg.name, &ssh_config::render(&cfg)).unwrap();
        let effective = drgnx_ratatoskr::runners::transport::effective(&config, &host)
            .await
            .unwrap();
        assert!(!effective.forward_agent, "{effective:?}");
        assert!(effective.forwards.is_empty(), "{effective:?}");
        let transport = OpensshTransport::new(&run);
        let channels = transport.open(&cfg).await.expect("the session opens");
        let (_tx, mut rx, _err, _hold) = channels.control.split();
        let mut out = String::new();
        rx.read_to_string(&mut out).await.unwrap();
        assert_eq!(out.trim(), "from-sshd");
        transport.stop(&cfg.name).await;
    }
}
