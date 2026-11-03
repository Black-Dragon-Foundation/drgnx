//! Task 11's rows: `exec/*` in this crate (the hub-level ones are `test/conformance/exec/*.jsonl`).

use super::*;

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
        user: UserJob::default(),
    }
}

/// The row of job `id` once it has ended. A job's result is written before the runner says `Done`, so: subscribe, look,
/// and while it has not ended wait for the next event (any job's) and look again. An end between the look and the wait
/// is an event the subscription already holds. The deadline only bounds a failure.
async fn ended(r: &Runner, id: &str) -> ExecRow {
    let mut events = r.subscribe();
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let row = r.get(id).expect("the job");
            if !matches!(row.status, ExecStatus::Running | ExecStatus::Queued) {
                return row;
            }
            match events.recv().await {
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(e) => panic!("the runner's events ended: {e}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("job {id} never ended"))
}

/// A named pipe at `path`: a shell's `read x < path` waits there until something is written to it.
fn fifo(path: &Path) {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: mkfifo(3) on a path we own.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
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
    let row = ended(&r, &id).await;
    assert_eq!(row.status, ExecStatus::TimedOut);
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
    // The job waits for the test to write to this pipe: it is running for exactly as long as the test wants.
    let go = d.path().join("go");
    fifo(&go);
    let first = tokio::runtime::Runtime::new().unwrap();
    let id = first.block_on(async {
        let r = open(d.path());
        r.start(spec(
            Starter::User,
            d.path(),
            &format!("read x < {}; echo survived", go.display()),
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
        // opens the pipe once the job's shell is reading it
        std::fs::write(&go, "go\n").unwrap();
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
        timebox_s: Some(60),
        deadline: Some(now() + 60.0),
        unit: None,
        pid: Some(i32::MAX - 1),
        start_time: Some(1),
        entity: None,
        image: None,
        name: None,
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

fn params(extra: serde_json::Value) -> StartParams {
    let mut v = json!({"argv": ["true"], "cwd": "/"});
    v.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    serde_json::from_value(v).unwrap()
}

#[test]
fn agent_cannot_set_memory_max() {
    for extra in [
        json!({"memory_max": "1G"}),
        json!({"nice": 5}),
        json!({"name": "mine"}),
        json!({"env": [{"name": "A", "value": "1"}]}),
        json!({"no_timebox": true}),
    ] {
        let p = params(extra);
        let e = user_job(&Some("s1".into()), CheckKind::Other, &p).unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidParams);
        assert!(e.message.contains("only the user"), "{}", e.message);
        assert!(user_job(&None, CheckKind::Other, &p).is_ok());
    }
    // an agent that sends none of them is untouched
    let none = user_job(&Some("s1".into()), CheckKind::Other, &params(json!({}))).unwrap();
    assert!(none.name.is_none() && none.env.is_empty() && none.nice.is_none());
}

#[test]
fn an_agent_cannot_ask_for_no_time_box_and_names_the_field() {
    let p = params(json!({"no_timebox": true}));
    let e = user_job(&Some("s1".into()), CheckKind::Other, &p).unwrap_err();
    assert_eq!(e.code, ErrorCode::InvalidParams);
    assert!(e.message.starts_with("no_timebox:"), "{}", e.message);
    // the user may; `false` is what an absent field means, for anyone
    assert!(user_job(&None, CheckKind::Other, &p).unwrap().no_timebox);
    let off = params(json!({"no_timebox": false}));
    assert!(
        !user_job(&Some("s1".into()), CheckKind::Other, &off)
            .unwrap()
            .no_timebox
    );
}

#[test]
fn no_time_box_and_a_time_box_together_are_refused() {
    let m = runstav::registry::find("exec/start").expect("exec/start");
    let both = json!({"argv": ["true"], "cwd": "/", "no_timebox": true, "timebox_s": 60});
    let e = (m.decode)(&both).err().expect("refused");
    assert_eq!(e.code, ErrorCode::InvalidParams);
    assert_eq!(e.path.as_deref(), Some("no_timebox"));
    let alone = json!({"argv": ["true"], "cwd": "/", "no_timebox": true});
    assert!((m.decode)(&alone).is_ok());
}

#[test]
fn a_missing_time_box_is_an_hour() {
    assert_eq!(
        requested_timebox(&params(json!({}))),
        Duration::from_secs(3600)
    );
    assert_eq!(
        requested_timebox(&params(json!({"timebox_s": 90}))),
        Duration::from_secs(90)
    );
}

#[test]
fn a_job_without_a_time_box_has_no_deadline() {
    let mut s = spec(
        Starter::User,
        Path::new("/"),
        "true",
        Duration::from_secs(5),
    );
    assert_eq!(s.time_box(), Some(Duration::from_secs(5)));
    s.user.no_timebox = true;
    assert_eq!(s.time_box(), None);
    let mut meta = Meta {
        id: "x".into(),
        session: None,
        kind: "other".into(),
        argv: vec![],
        cwd: "/".into(),
        started: now(),
        timebox_s: None,
        deadline: None,
        unit: None,
        pid: None,
        start_time: None,
        entity: None,
        image: None,
        name: None,
        queued: false,
    };
    // the timer path has nothing to wait for
    assert_eq!(meta.time_left(), None);
    meta.deadline = Some(now() - 10.0);
    assert_eq!(meta.time_left(), Some(Duration::ZERO));
    // an old meta.json (numbers) still reads
    let old = r#"{"id":"x","session":null,"kind":"other","argv":[],"cwd":"/","started":1.0,"timebox_s":60,"deadline":61.0,"unit":null,"pid":null,"start_time":null,"entity":null}"#;
    let m: Meta = serde_json::from_str(old).unwrap();
    assert_eq!((m.timebox_s, m.deadline), (Some(60), Some(61.0)));
}

#[tokio::test]
async fn a_user_job_without_a_time_box_is_recorded_without_one_and_stop_ends_it() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let gate = d.path().join("gate");
    fifo(&gate);
    // a one millisecond box that must not apply: with the timer armed the job would end `TimedOut` at once
    let mut s = spec(
        Starter::User,
        d.path(),
        &format!("read x < {}", gate.display()),
        Duration::from_millis(1),
    );
    s.user.no_timebox = true;
    let id = r.start(s).await.unwrap();
    let row = r.get(&id).unwrap();
    assert_eq!(row.timebox_s, None);
    assert_eq!(r.inner.get().unwrap().meta(&id).unwrap().deadline, None);
    assert_eq!(r.stop(&id).await.unwrap().status, ExecStatus::Stopped);
    assert_eq!(ended(&r, &id).await.status, ExecStatus::Stopped);
}

#[test]
fn env_names_refused() {
    use runstav::methods::hub::refused_env_name;
    for bad in [
        "OPENAI_API_KEY",
        "gh_token",
        "DB_PASSWORD",
        "MY_SECRET",
        "AWS_CREDENTIALS",
    ] {
        assert!(refused_env_name(bad), "{bad}");
    }
    for ok in ["PATH", "PLAYWRIGHT_MCP_CDP_ENDPOINT", "LANG", "HF_HOME"] {
        assert!(!refused_env_name(ok), "{ok}");
    }
    // the same check runs when a request is decoded and checked
    let m = runstav::registry::find("exec/start").expect("exec/start");
    let bad = json!({"argv": ["true"], "cwd": "/", "env": [{"name": "GH_TOKEN", "value": "x"}]});
    assert!((m.decode)(&bad).is_err());
    let good = json!({"argv": ["true"], "cwd": "/", "env": [{"name": "PATH", "value": "/bin"}]});
    assert!((m.decode)(&good).is_ok());
}

#[test]
fn unit_has_memory_max_and_nice() {
    let inner = draugr::Spec {
        program: "echo".into(),
        args: vec!["a".into()],
        env: vec![],
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    };
    let s = unit::wrap(
        inner,
        Path::new("/d"),
        Some(("drgnx-exec-x", "512M")),
        Some(7),
        &crate::shell_env::ShellEnv::default(),
    );
    let args: Vec<String> = s
        .args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    assert!(args.contains(&"MemoryMax=512M".to_string()), "{args:?}");
    let at = args.iter().position(|a| a == "nice").expect("nice");
    assert_eq!(args[at..], ["nice", "-n", "7", "echo", "a"]);
}

#[tokio::test]
async fn a_user_job_gets_its_name_env_and_nice() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let mut s = spec(
        Starter::User,
        d.path(),
        "echo \"$JOB_VAR\"; nice",
        Duration::from_secs(30),
    );
    s.user = UserJob {
        name: Some("grammars".into()),
        env: vec![("JOB_VAR".into(), "from-the-request".into())],
        memory_max: None,
        nice: Some(7),
        no_timebox: false,
    };
    let id = r.start(s).await.unwrap();
    let row = ended(&r, &id).await;
    assert_eq!(row.name.as_deref(), Some("grammars"));
    // `nice -n` adds to the hub's own niceness
    // SAFETY: getpriority(2) reads this process's niceness.
    let base = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) };
    assert_eq!(
        row.summary.unwrap().lines,
        vec![
            "from-the-request".to_string(),
            (base + 7).min(19).to_string()
        ]
    );
    assert_eq!(r.list(None, false)[0].name.as_deref(), Some("grammars"));
}

/// The row `exec/runs-in-the-starters-sandbox`: needs the real sandbox's bwrap tier, which the build container lacks
/// (run it on a host with bwrap or in GitHub CI: `cargo test -p drgnx-ratatoskr exec::tests -- --ignored`).
#[tokio::test]
#[ignore = "needs bwrap (the real sandbox): a host with bwrap or the GitHub CI lane"]
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
        user: UserJob::default(),
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
    // the first job holds the only slot until the gate is written, below: a start that waited for the slot would wait
    // for ever (the deadline only bounds that failure)
    let second = tokio::time::timeout(
        Duration::from_secs(30),
        r.start(spec(
            Starter::User,
            d.path(),
            "echo second",
            Duration::from_secs(30),
        )),
    )
    .await
    .expect("the start blocked")
    .unwrap();
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
        timebox_s: Some(30),
        deadline: Some(now + 30.0),
        unit: None,
        pid: None,
        start_time: None,
        entity: None,
        image: None,
        name: None,
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
    // The waiter runs, on this single-threaded runtime, as soon as this task waits, up to its first wait: the process's
    // end (everything before that is synchronous). So after a yield it is waiting, and the process is alive.
    tokio::task::yield_now().await;
    assert!(!waiter.is_finished());
    child.kill().unwrap();
    child.wait().unwrap();
    // the deadlines here only bound a failure
    tokio::time::timeout(Duration::from_secs(30), waiter)
        .await
        .expect("the wait ended with the process")
        .unwrap();
    // a pid that is not that process (reused) is not waited on
    tokio::time::timeout(
        Duration::from_secs(30),
        wait_gone(std::process::id() as i32, 1),
    )
    .await
    .expect("a reused pid is gone at once");
}
