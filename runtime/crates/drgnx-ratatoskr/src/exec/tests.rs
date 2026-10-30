//! Task 11's rows: `exec/*` in this crate (the hub-level ones are `test/conformance/exec/*.jsonl`).

use super::*;
use std::time::Instant;

fn hooks() -> Hooks {
    Hooks {
        systemd: false,
        ..Hooks::default()
    }
}

fn spec(starter: Starter, cwd: &Path, script: &str, timebox: Duration) -> ExecSpec {
    ExecSpec {
        worktree: matches!(starter, Starter::Session(_)).then(|| cwd.to_path_buf()),
        starter,
        cwd: cwd.to_path_buf(),
        argv: vec!["sh".into(), "-c".into(), script.into()],
        timebox,
        kind: CheckKind::Other,
        container: None,
    }
}

async fn ended(r: &Runner, id: &str) -> ExecRow {
    let t = Instant::now();
    loop {
        let row = r.get(id).expect("the job");
        if !matches!(row.status, ExecStatus::Running | ExecStatus::Queued) {
            return row;
        }
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "job {id} never ended"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn open(root: &Path) -> Runner {
    let r = Runner::default();
    r.open(root.join("exec"), hooks());
    r
}

#[tokio::test]
async fn a_job_runs_logs_and_summarises() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let s = spec(
        Starter::User,
        d.path(),
        "echo one; echo two; exit 3",
        Duration::from_secs(30),
    );
    let id = r.start(s).await.unwrap();
    let row = ended(&r, &id).await;
    assert_eq!(row.status, ExecStatus::Done);
    let sum = row.summary.unwrap();
    assert_eq!(sum.exit, Some(3));
    assert_eq!(sum.lines, vec!["one".to_string(), "two".to_string()]);
    assert_eq!(r.log_slice(&id, 1, 5), vec!["two".to_string()]);
    assert_eq!(r.list(None, false).len(), 1);
    assert!(r.list(None, true).is_empty());
    assert!(r.list(Some("nobody"), false).is_empty());
}

#[tokio::test]
async fn exec_timebox_ends_it() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let id = r
        .start(spec(
            Starter::User,
            d.path(),
            "sleep 60",
            Duration::from_millis(400),
        ))
        .await
        .unwrap();
    let t = Instant::now();
    let row = ended(&r, &id).await;
    assert_eq!(row.status, ExecStatus::TimedOut);
    assert!(t.elapsed() < Duration::from_secs(10));
}

#[tokio::test]
async fn stop_ends_a_running_job() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let id = r
        .start(spec(
            Starter::User,
            d.path(),
            "sleep 60",
            Duration::from_secs(60),
        ))
        .await
        .unwrap();
    let row = r.stop(&id).await.unwrap();
    assert_eq!(row.status, ExecStatus::Stopped);
    // A second stop changes nothing.
    assert_eq!(r.stop(&id).await.unwrap().status, ExecStatus::Stopped);
    assert!(r.stop("nope").await.is_none());
}

#[tokio::test]
async fn bad_jobs_are_refused() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let mut s = spec(Starter::User, d.path(), "true", Duration::from_secs(5));
    s.argv.clear();
    assert!(r.start(s).await.is_err());
    let missing = d.path().join("missing");
    assert!(
        r.start(spec(
            Starter::User,
            &missing,
            "true",
            Duration::from_secs(5)
        ))
        .await
        .is_err()
    );
    assert!(
        r.list(None, false).is_empty(),
        "a refused job leaves no folder"
    );
}

#[test]
fn exec_survives_a_hub_restart() {
    let d = tempfile::tempdir().unwrap();
    let first = tokio::runtime::Runtime::new().unwrap();
    let id = first.block_on(async {
        let r = open(d.path());
        r.start(spec(
            Starter::User,
            d.path(),
            "sleep 1; echo survived",
            Duration::from_secs(60),
        ))
        .await
        .unwrap()
    });
    // The hub goes away: its monitor tasks end, the job's process does not.
    first.shutdown_background();
    let second = tokio::runtime::Runtime::new().unwrap();
    second.block_on(async {
        let r = open(d.path());
        assert_eq!(r.get(&id).unwrap().status, ExecStatus::Running);
        let row = ended(&r, &id).await;
        assert_eq!(row.status, ExecStatus::Done);
        assert_eq!(row.summary.unwrap().lines, vec!["survived".to_string()]);
    });
}

#[test]
fn a_job_whose_process_is_gone_is_lost() {
    let d = tempfile::tempdir().unwrap();
    let dir = d.path().join("exec/xdead");
    std::fs::create_dir_all(&dir).unwrap();
    let meta = Meta {
        id: "xdead".into(),
        session: None,
        kind: "other".into(),
        argv: vec!["true".into()],
        cwd: "/".into(),
        started: now(),
        timebox_s: 60,
        deadline: now() + 60.0,
        unit: None,
        pid: Some(i32::MAX - 1),
        start_time: Some(1),
        entity: None,
        image: None,
        queued: false,
    };
    std::fs::write(dir.join("meta.json"), serde_json::to_vec(&meta).unwrap()).unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let r = open(d.path());
        assert_eq!(ended(&r, "xdead").await.status, ExecStatus::Lost);
    });
}

fn start_params(machine: Option<&str>) -> StartParams {
    serde_json::from_value(match machine {
        Some(m) => json!({"argv": ["true"], "cwd": "/", "machine": m}),
        None => json!({"argv": ["true"], "cwd": "/"}),
    })
    .unwrap()
}

#[test]
fn exec_remote_machine_refused() {
    assert!(check_machine(&start_params(None)).is_ok());
    assert!(check_machine(&start_params(Some("local"))).is_ok());
    let e = check_machine(&start_params(Some("desktop"))).unwrap_err();
    assert_eq!(e.code, ErrorCode::InvalidParams);
    assert!(e.message.contains("this machine only"));
}

/// The row `exec/runs-in-the-starters-sandbox`: needs the real sandbox's bwrap tier, which the build container lacks
/// (run it on the desktop or in GitHub CI: `cargo test -p drgnx-ratatoskr exec::tests -- --ignored`).
#[tokio::test]
#[ignore = "needs bwrap (the real sandbox): desktop or GitHub CI lane"]
async fn exec_runs_in_the_starters_sandbox() {
    // The sandbox's helper is the process's own binary, here the test harness: the hub binary the same build made
    // (`<target>/<profile>/ratatoskr`, beside `deps/`) takes its place.
    let exe = std::env::current_exe().unwrap();
    let hub = exe.parent().unwrap().parent().unwrap().join("ratatoskr");
    assert!(
        hub.is_file(),
        "{} is not built (cargo test builds it with the package's tests)",
        hub.display()
    );
    crate::idle::pin_exe_for_test(std::fs::canonicalize(&hub).unwrap());
    let d = tempfile::tempdir_in("/tmp").unwrap();
    let wt = d.path().join("wt");
    std::fs::create_dir_all(&wt).unwrap();
    // the hub's dirs (state, runtime, tmp) are the tempdir's, never $HOME's; the session dir is made the way a
    // session start makes it. Only this test runs under `--ignored`, so nothing reads the environment meanwhile.
    unsafe {
        std::env::set_var("XDG_STATE_HOME", d.path().join("state"));
        std::env::set_var("TMPDIR", d.path());
        std::env::remove_var("XDG_RUNTIME_DIR");
    }
    let env = runstav::paths::Env::process();
    runstav::paths::make_session_dir(&env, &runstav::paths::socket_path(&env), "s1").unwrap();
    let r = open(d.path());
    let id = r
        .start(spec(
            Starter::Session("s1".into()),
            &wt,
            "touch ./inside && echo wrote-inside; touch /var/outside 2>/dev/null || echo denied-outside",
            Duration::from_secs(60),
        ))
        .await
        .unwrap();
    let row = ended(&r, &id).await;
    assert_eq!(row.status, ExecStatus::Done);
    let lines = row.summary.unwrap().lines;
    assert!(lines.contains(&"wrote-inside".to_string()), "{lines:?}");
    assert!(lines.contains(&"denied-outside".to_string()), "{lines:?}");
    assert!(wt.join("inside").exists());
}

const REF: &str = "registry.example/tools@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn container_spec(cwd: &Path) -> ExecSpec {
    ExecSpec {
        starter: Starter::User,
        cwd: cwd.to_path_buf(),
        worktree: None,
        argv: vec!["make".into(), "test".into()],
        timebox: Duration::from_secs(30),
        kind: CheckKind::Container,
        container: Some(ContainerJob {
            image: "tools".into(),
            caps: container::Caps {
                images: vec![crate::settings::ContainerImage {
                    name: "tools".into(),
                    image: REF.into(),
                }],
                memory: "1G".into(),
                cpus: 1,
                pids: container::PIDS,
                proxy: None,
                net_hosts: vec![],
            },
            net: None,
        }),
    }
}

#[tokio::test]
async fn container_jobs_without_podman_are_refused_with_a_doctor_hint() {
    let d = tempfile::tempdir().unwrap();
    let r = Runner::default();
    r.open(
        d.path().join("exec"),
        Hooks {
            podman: None,
            ..hooks()
        },
    );
    let e = r.start(container_spec(d.path())).await.unwrap_err();
    assert!(e.message.contains("drgnx doctor"), "{}", e.message);
    assert!(r.list(None, false).is_empty());
}

/// A fake podman's answer to `podman info`: cgroup v2, the systemd manager, the caps' controllers.
const INFO_ENFORCES: &str = "if [ \"$1\" = info ]; then echo '{\"host\":{\"cgroupVersion\":\"v2\",\
\"cgroupManager\":\"systemd\",\"cgroupControllers\":[\"cpu\",\"memory\",\"pids\"]}}'; exit 0; fi\n";

/// A podman that cannot enforce the caps (rootless, no systemd user session: cgroupfs) refuses the job, and nothing
/// is pulled or run.
#[tokio::test]
async fn a_container_job_whose_caps_podman_cannot_enforce_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let d = tempfile::tempdir().unwrap();
    let fake = d.path().join("podman");
    let ran = d.path().join("ran");
    std::fs::write(
        &fake,
        format!(
            "#!/bin/sh\nif [ \"$1\" = info ]; then echo '{{\"host\":{{\"cgroupVersion\":\"v2\",\
             \"cgroupManager\":\"cgroupfs\",\"cgroupControllers\":[\"cpu\",\"memory\",\"pids\"]}}}}'; exit 0; fi\n\
             echo \"$1\" >> {}\n",
            ran.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let r = Runner::default();
    r.open(
        d.path().join("exec"),
        Hooks {
            podman: Some(fake),
            ..hooks()
        },
    );
    let e = r.start(container_spec(d.path())).await.unwrap_err();
    assert!(e.message.contains("cgroupfs"), "{}", e.message);
    assert!(!ran.exists(), "podman was asked to pull or run");
}

#[tokio::test]
async fn a_container_job_runs_the_fixed_podman_line() {
    use std::os::unix::fs::PermissionsExt;
    let d = tempfile::tempdir().unwrap();
    // a stand-in for podman: it enforces limits, the image is "present", and `run` prints the line it was given
    let fake = d.path().join("podman");
    std::fs::write(
        &fake,
        format!("#!/bin/sh\n{INFO_ENFORCES}if [ \"$1\" = image ]; then exit 0; fi\nprintf '%s\\n' \"$@\"\n"),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let r = Runner::default();
    r.open(
        d.path().join("exec"),
        Hooks {
            podman: Some(fake),
            ..hooks()
        },
    );
    let id = r.start(container_spec(d.path())).await.unwrap();
    let row = ended(&r, &id).await;
    assert_eq!(row.status, ExecStatus::Done);
    assert_eq!(row.kind, ExecKind::Container);
    assert_eq!(row.image.as_deref(), Some("tools"));
    let log = r.log_slice(&id, 0, 100);
    assert_eq!(log.first().map(String::as_str), Some("run"));
    assert!(log.contains(&"--network=none".to_string()));
    assert_eq!(&log[log.len() - 3..], [REF, "make", "test"]);
}

fn one_slot(root: &Path) -> Runner {
    let r = Runner::default();
    r.open(
        root.join("exec"),
        Hooks {
            slots: 1,
            ..hooks()
        },
    );
    r
}

/// B1: a session's job runs in its worktree or inside it; any other folder is refused before anything starts.
#[tokio::test]
async fn a_session_job_outside_its_worktree_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let (wt, inside, outside) = (
        d.path().join("wt"),
        d.path().join("wt/sub"),
        d.path().join("other"),
    );
    for p in [&inside, &outside] {
        std::fs::create_dir_all(p).unwrap();
    }
    std::os::unix::fs::symlink(&outside, wt.join("escape")).unwrap();
    let session = || Starter::Session("S1".into());
    let mut s = spec(session(), &outside, "true", Duration::from_secs(30));
    s.worktree = Some(wt.clone());
    let e = r.start(s).await.unwrap_err();
    assert!(e.message.contains("outside your worktree"), "{}", e.message);
    // a link out of the worktree is resolved first
    let mut s = spec(
        session(),
        &wt.join("escape"),
        "true",
        Duration::from_secs(30),
    );
    s.worktree = Some(wt.clone());
    assert!(
        r.start(s)
            .await
            .unwrap_err()
            .message
            .contains("outside your worktree")
    );
    // a `..` out of it too
    let mut s = spec(
        session(),
        &inside.join("../../other"),
        "true",
        Duration::from_secs(30),
    );
    s.worktree = Some(wt.clone());
    assert!(
        r.start(s)
            .await
            .unwrap_err()
            .message
            .contains("outside your worktree")
    );
    // no worktree, no job
    let mut s = spec(session(), &inside, "true", Duration::from_secs(30));
    s.worktree = None;
    assert!(
        r.start(s)
            .await
            .unwrap_err()
            .message
            .contains("needs its worktree")
    );
    assert!(
        r.list(None, false).is_empty(),
        "a refused job leaves nothing"
    );
}

/// B1: a container job mounts the session's worktree, never the folder the request names, and works in the subfolder.
#[test]
fn a_container_job_in_a_subfolder_mounts_the_worktree() {
    let mut req = container::ContainerReq {
        image: "tools".into(),
        argv: vec!["ls".into()],
        worktree: "/work/tree".into(),
        subdir: "crates/x".into(),
        job: "x1a".into(),
        net: None,
    };
    let caps = container::Caps {
        images: vec![crate::settings::ContainerImage {
            name: "tools".into(),
            image: REF.into(),
        }],
        memory: "1G".into(),
        cpus: 1,
        pids: container::PIDS,
        proxy: None,
        net_hosts: vec![],
    };
    let a: Vec<String> = container::argv(&req, &caps)
        .unwrap()
        .into_iter()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    assert!(
        a.iter()
            .any(|s| s.starts_with("/work/tree:") && !s.contains("crates"))
    );
    let w = a.iter().position(|s| s == "-w").unwrap();
    assert!(a[w + 1].ends_with("/crates/x"), "{}", a[w + 1]);
    req.subdir = "".into();
    assert!(container::argv(&req, &caps).is_ok());
}

/// S6: a job that finds the machine full is recorded as queued and answered at once; it starts when the slot frees.
#[tokio::test]
async fn a_job_on_a_full_machine_is_queued_and_starts_when_a_slot_frees() {
    let d = tempfile::tempdir().unwrap();
    let r = one_slot(d.path());
    let gate = d.path().join("gate");
    let first = r
        .start(spec(
            Starter::User,
            d.path(),
            &format!("while [ ! -e {} ]; do sleep 0.05; done", gate.display()),
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    let t = Instant::now();
    let second = r
        .start(spec(
            Starter::User,
            d.path(),
            "echo second",
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    assert!(t.elapsed() < Duration::from_secs(2), "the start blocked");
    assert!(r.is_queued(&second) && !r.is_queued(&first));
    assert_eq!(r.get(&second).unwrap().status, ExecStatus::Queued);
    assert_eq!(r.get(&first).unwrap().status, ExecStatus::Running);
    assert_eq!(r.list(None, true).len(), 2, "queued counts as live");
    assert!(r.live().ids("nobody").is_empty());
    std::fs::write(&gate, "").unwrap();
    assert_eq!(ended(&r, &first).await.status, ExecStatus::Done);
    let row = ended(&r, &second).await;
    assert_eq!(row.status, ExecStatus::Done);
    assert_eq!(row.summary.unwrap().lines, vec!["second".to_string()]);
    assert!(!r.is_queued(&second));
}

/// S6: a queued job stopped while it waits never starts; one queued when the hub went away starts under the next.
#[tokio::test]
async fn a_queued_job_can_be_stopped_and_survives_a_restart() {
    let d = tempfile::tempdir().unwrap();
    let r = one_slot(d.path());
    let gate = d.path().join("gate");
    let first = r
        .start(spec(
            Starter::User,
            d.path(),
            &format!("while [ ! -e {} ]; do sleep 0.05; done", gate.display()),
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    let stopped = r
        .start(spec(
            Starter::User,
            d.path(),
            "touch ran-stopped",
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    let kept = r
        .start(spec(
            Starter::User,
            d.path(),
            "echo kept",
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    assert_eq!(r.stop(&stopped).await.unwrap().status, ExecStatus::Stopped);
    // the next hub: its own runner on the same folder, the first job's slot free again
    std::fs::write(&gate, "").unwrap();
    assert_eq!(ended(&r, &first).await.status, ExecStatus::Done);
    assert_eq!(ended(&r, &kept).await.status, ExecStatus::Done);
    assert!(!d.path().join("ran-stopped").exists());
    // a queued job on disk with no hub running it: a runner opened on the folder starts it
    let dir = d.path().join("exec/xwaiting");
    std::fs::create_dir_all(&dir).unwrap();
    let now = now();
    let meta = Meta {
        id: "xwaiting".into(),
        session: None,
        kind: "other".into(),
        argv: vec!["echo".into(), "late".into()],
        cwd: d.path().display().to_string(),
        started: now,
        timebox_s: 30,
        deadline: now + 30.0,
        unit: None,
        pid: None,
        start_time: None,
        entity: None,
        image: None,
        queued: true,
    };
    std::fs::write(dir.join("meta.json"), serde_json::to_vec(&meta).unwrap()).unwrap();
    let pending = Pending::of(&spec(
        Starter::User,
        d.path(),
        "echo late",
        Duration::from_secs(30),
    ));
    std::fs::write(
        dir.join("pending.json"),
        serde_json::to_vec(&pending).unwrap(),
    )
    .unwrap();
    let next = open(d.path());
    let row = ended(&next, "xwaiting").await;
    assert_eq!(row.status, ExecStatus::Done);
    assert_eq!(row.summary.unwrap().lines, vec!["late".to_string()]);
}

/// S7: finished job folders past the retention are removed (the newest kept, a fresh one never), running ones stay.
#[tokio::test]
async fn finished_job_folders_past_the_retention_are_pruned() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let root = d.path().join("exec");
    let ago = |secs: u64| std::time::SystemTime::now() - Duration::from_secs(secs);
    let make = |name: &str, age: u64| {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let f = std::fs::File::create(dir.join("result.json")).unwrap();
        f.set_modified(ago(age)).unwrap();
    };
    for i in 0..(KEEP_JOBS + 5) {
        make(&format!("xold{i:03}"), 7200 + i as u64);
    }
    make("xancient", (KEEP_DAYS * 86400.0) as u64 + 100);
    make("xfresh", 5);
    std::fs::create_dir_all(root.join("xrunning")).unwrap();
    r.inner.get().unwrap().prune();
    let left: Vec<String> = std::fs::read_dir(&root)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left.len(), KEEP_JOBS + 1, "{} left", left.len());
    assert!(left.contains(&"xfresh".to_string()) && left.contains(&"xrunning".to_string()));
    assert!(!left.contains(&"xancient".to_string()));
    assert!(!left.contains(&format!("xold{:03}", KEEP_JOBS + 4)));
    assert!(left.contains(&"xold000".to_string()));
}

/// N7: a re-attached job is waited on by the process's end, not by polling for it.
#[tokio::test]
async fn waiting_for_a_process_ends_with_the_process() {
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let pid = child.id() as i32;
    let start = draugr::start_time(pid).unwrap();
    let waiter = tokio::spawn(wait_gone(pid, start));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!waiter.is_finished());
    child.kill().unwrap();
    child.wait().unwrap();
    tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .expect("the wait ended with the process")
        .unwrap();
    // a pid that is not that process (reused) is not waited on
    tokio::time::timeout(
        Duration::from_secs(5),
        wait_gone(std::process::id() as i32, 1),
    )
    .await
    .expect("a reused pid is gone at once");
}
