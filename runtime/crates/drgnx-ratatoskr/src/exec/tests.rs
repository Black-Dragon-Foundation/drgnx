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
        place: Placement::default(),
    }
}

/// What a runner is told is the job's folder inside its tree ("." for the tree itself): a runner mounts its own
/// checkout, so the hub's absolute path would name a folder that does not exist there.
#[test]
fn a_runner_is_told_the_jobs_folder_inside_its_tree() {
    let user = spec(
        Starter::User,
        Path::new("/p/proj"),
        "true",
        Duration::from_secs(5),
    );
    let f = user.forseti_spec("x1", "1G");
    assert_eq!((f.tree, f.cwd), ("/p/proj".into(), ".".into()));

    let mut deep = spec(
        Starter::User,
        Path::new("/p/proj/crates/x"),
        "true",
        Duration::from_secs(5),
    );
    deep.worktree = Some("/p/proj".into());
    let f = deep.forseti_spec("x2", "1G");
    assert_eq!((f.tree, f.cwd), ("/p/proj".into(), "crates/x".into()));
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
    assert!(r.stop("nope").await.is_err());
}

/// On the test clock a stop whose first look finds no end still answers once the end is recorded, with no advance:
/// it waits for the job's end, never on the clock, which stands still inside a serving step. The watcher's end is held
/// (its id marked finishing) until the stop has looked and waits, then the test records it.
#[cfg(feature = "test-hooks")]
#[test]
fn a_stop_on_the_test_clock_answers_an_end_recorded_after_its_first_look() {
    crate::clock::on_virtual(async {
        let d = tempfile::tempdir().unwrap();
        let r = open(d.path());
        // no time box: the watcher registers no sleeper, so the first one is the stop's wait
        let mut s = spec(Starter::User, d.path(), "sleep 60", Duration::from_secs(60));
        s.user.no_timebox = true;
        let id = r.start(s).await.unwrap();
        let inner = r.inner.get().unwrap().clone();
        inner.finishing.lock().unwrap().insert(id.clone());
        let stop = tokio::spawn({
            let (inner, id) = (inner.clone(), id.clone());
            async move { inner.stop(&id).await }
        });
        skuld::wait_until_async("the stop looked and waits", 30, || async {
            (crate::clock::sleepers() > 0).then_some(())
        })
        .await;
        inner.finishing.lock().unwrap().remove(&id);
        inner.finish(&id).await;
        let row = tokio::time::timeout(Duration::from_secs(10), stop)
            .await
            .expect("the stop answers without an advance")
            .unwrap()
            .unwrap();
        assert_eq!(row.status, ExecStatus::Stopped);
    });
}

/// On the test clock, a stop whose end never comes (the watcher's end held for good) does not wait on the clock, which
/// stands still behind it: a real-time bound ends it, and its answer names the job.
#[cfg(feature = "test-hooks")]
#[test]
fn a_stop_on_the_test_clock_whose_end_never_comes_fails_naming_the_job() {
    crate::clock::on_virtual(async {
        let d = tempfile::tempdir().unwrap();
        let r = open(d.path());
        let mut s = spec(Starter::User, d.path(), "sleep 60", Duration::from_secs(60));
        s.user.no_timebox = true;
        let id = r.start(s).await.unwrap();
        let inner = r.inner.get().unwrap().clone();
        inner.finishing.lock().unwrap().insert(id.clone());
        let answer = tokio::time::timeout(Duration::from_secs(20), inner.clone().stop(&id))
            .await
            .expect("the stop answers once its real-time bound runs out");
        let e = answer.expect_err("no end came, so no row");
        assert!(e.message.contains(&format!("job {id}:")), "{e:?}");
    });
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
        machine: None,
        priority: None,
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

/// [D] `machine`: none or `auto`, `local`, or a runner the hub knows; any other name is refused before anything starts.
#[tokio::test]
async fn a_machine_the_hub_does_not_know_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let q = &r.inner.get().unwrap().queue;
    assert_eq!(machine(&start_params(None), q).unwrap(), Machine::Auto);
    assert_eq!(
        machine(&start_params(Some("auto")), q).unwrap(),
        Machine::Auto
    );
    assert_eq!(
        machine(&start_params(Some("local")), q).unwrap(),
        Machine::Local
    );
    let e = machine(&start_params(Some("desktop")), q).unwrap_err();
    assert_eq!(e.code, ErrorCode::InvalidParams);
    assert!(e.message.contains("no runner desktop"), "{}", e.message);
}

/// [D] pure: a container job granted a network reaches its cell's hosts (the settings' list), here and on a runner;
/// one with no grant, and a command job, none.
#[test]
fn a_container_jobs_grant_is_the_hosts_a_runner_gets() {
    let d = crate::settings::defaults();
    let caps = crate::settings::containers::caps(&d.values);
    let job = |net| ContainerJob {
        image: "fedora".into(),
        caps: caps.clone(),
        net,
    };
    let want =
        crate::sandbox::allowed_hosts(NetCell::ProviderAndPackages, &d.values.agents_net_hosts);
    assert_eq!(want.len(), 6);
    assert_eq!(
        net_hosts_of(Some(&job(Some(NetCell::ProviderAndPackages)))),
        want
    );
    assert!(net_hosts_of(Some(&job(None))).is_empty());
    assert!(net_hosts_of(None).is_empty());
}

/// [D] pure: `rows` reaches the queue as the job's suite; a run here takes every row in place of `{rows}`, and a
/// request without rows runs as it is.
#[test]
fn rows_reach_the_queue_and_a_run_here_runs_them_all() {
    let p = params(
        json!({"argv": ["run", "{rows}"], "rows": {"parser": "plist", "listed": ["t1", "t2"]}}),
    );
    let suite = suite_of(&p).expect("a suite");
    assert_eq!(
        suite,
        queue::Suite {
            parser: "plist".into(),
            listed: vec!["t1".into(), "t2".into()],
        }
    );
    let argv = vec!["run".to_string(), queue::ROWS.to_string()];
    assert_eq!(
        local_argv(&argv, Some(&suite)),
        vec!["run".to_string(), forseti::split::selector(&suite.listed)]
    );
    assert_eq!(local_argv(&argv, None), argv);
    assert_eq!(suite_of(&params(json!({}))), None);
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
        // the user may, but macOS has nothing to cap a job's memory with: refused there, saying so
        let user = user_job(&None, CheckKind::Other, &p);
        if cfg!(target_os = "macos") && p.memory_max.is_some() {
            let e = user.unwrap_err();
            assert_eq!(e.code, ErrorCode::InvalidParams);
            assert!(
                e.message.contains("macOS has no memory cap"),
                "{}",
                e.message
            );
        } else {
            assert!(user.is_ok());
        }
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
        machine: None,
        priority: None,
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
        // the shell's niceness, from `ps`: a bare `nice` prints it only with GNU's (BSD's needs a utility)
        "echo \"$JOB_VAR\"; echo $(ps -o nice= -p $$)",
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

/// A user's job starts from the hub's whole environment with the login shell's overlay (a variable outside the agents'
/// list reaches it), less a provider's key variable; an agent's job keeps the short list.
#[tokio::test]
async fn a_user_job_gets_the_shells_environment_and_an_agents_the_list() {
    let d = tempfile::tempdir().unwrap();
    let shell = crate::shell_env::ShellEnv::default();
    shell.set(
        vec![
            ("OLLAMA_MODELS".into(), "/models/here".into()),
            ("ACME_ACCESS".into(), "leak".into()),
        ],
        &[],
    );
    let r = Runner::default();
    r.open(
        d.path().join("exec"),
        Hooks {
            shell_env: shell,
            key_envs: Arc::new(|| vec!["ACME_ACCESS".to_string()]),
            plain_sessions: true,
            ..hooks()
        },
    );
    let script = "echo \"models=${OLLAMA_MODELS-unset} access=${ACME_ACCESS-unset}\"";
    let user = r
        .start(spec(
            Starter::User,
            d.path(),
            script,
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    let agent = r.start(agents(d.path(), script)).await.unwrap();
    let lines = |row: ExecRow| row.summary.unwrap().lines;
    assert_eq!(
        lines(ended(&r, &user).await),
        ["models=/models/here access=unset"]
    );
    assert_eq!(
        lines(ended(&r, &agent).await),
        ["models=unset access=unset"]
    );
}

/// The user's base environment drops what looks like a key, a provider's key variable and a name that is not text.
#[test]
fn a_user_jobs_base_environment_has_no_keys() {
    use std::os::unix::ffi::OsStringExt;
    let source: Vec<(OsString, OsString)> = [
        ("OLLAMA_MODELS", "m"),
        ("HTTPS_PROXY", "p"),
        ("GH_TOKEN", "t"),
        ("ANTHROPIC_API_KEY", "k"),
        ("ACME_ACCESS", "a"),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .chain([(OsString::from_vec(vec![0xff, b'X']), "x".into())])
    .collect();
    let names: Vec<OsString> = user_env(source, &["ACME_ACCESS".to_string()])
        .into_iter()
        .map(|(k, _)| k)
        .collect();
    assert_eq!(names, ["OLLAMA_MODELS", "HTTPS_PROXY"]);
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
                pins: vec![],
            },
            net: None,
        }),
        user: UserJob::default(),
        place: Placement::default(),
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

/// A runner whose sessions' jobs run unsandboxed (as the conformance lane's do).
fn plain(root: &Path, slots: u32) -> Runner {
    let r = Runner::default();
    r.open(
        root.join("exec"),
        Hooks {
            admission: crate::runners::local::Admission::Fixed(slots),
            plain_sessions: true,
            ..hooks()
        },
    );
    r
}

fn one_slot(root: &Path) -> Runner {
    plain(root, 1)
}

/// An agent's job, in the folder D.
fn agents(d: &Path, script: &str) -> ExecSpec {
    spec(
        Starter::Session("S1".into()),
        d,
        script,
        Duration::from_secs(30),
    )
}

/// The machine's slots are the agents': four of the editor's servers (no time box) run, and an agent's job still starts
/// at once, as does a fifth job of the user's.
#[tokio::test]
async fn the_users_servers_leave_the_agents_slots_free() {
    let d = tempfile::tempdir().unwrap();
    let r = plain(d.path(), 4);
    let mut servers = Vec::new();
    for _ in 0..4 {
        let mut s = spec(
            Starter::User,
            d.path(),
            "exec sleep 600",
            Duration::from_secs(30),
        );
        s.user.no_timebox = true;
        let id = r.start(s).await.unwrap();
        assert!(!r.is_queued(&id));
        servers.push(id);
    }
    let agent = r.start(agents(d.path(), "echo agent")).await.unwrap();
    assert!(
        !r.is_queued(&agent),
        "the agent's job waits behind the user's servers"
    );
    let fifth = r
        .start(spec(
            Starter::User,
            d.path(),
            "echo fifth",
            Duration::from_secs(30),
        ))
        .await
        .unwrap();
    assert!(!r.is_queued(&fifth));
    assert_eq!(ended(&r, &agent).await.status, ExecStatus::Done);
    assert_eq!(ended(&r, &fifth).await.status, ExecStatus::Done);
    for id in servers {
        assert_eq!(r.stop(&id).await.unwrap().status, ExecStatus::Stopped);
    }
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
        net: false,
        runner: None,
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
        pins: vec![],
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

/// S6: an agent's job that finds the machine full is recorded as queued and answered at once; it starts when the slot
/// frees.
#[tokio::test]
async fn a_job_on_a_full_machine_is_queued_and_starts_when_a_slot_frees() {
    let d = tempfile::tempdir().unwrap();
    let r = one_slot(d.path());
    let gate = d.path().join("gate");
    let first = r
        .start(agents(
            d.path(),
            &format!("while [ ! -e {} ]; do sleep 0.05; done", gate.display()),
        ))
        .await
        .unwrap();
    // the first job holds the only slot until the gate is written, below: a start that waited for the slot would wait
    // for ever (the deadline only bounds that failure)
    let second = tokio::time::timeout(
        Duration::from_secs(30),
        r.start(agents(d.path(), "echo second")),
    )
    .await
    .expect("the start blocked")
    .unwrap();
    assert!(r.is_queued(&second) && !r.is_queued(&first));
    assert_eq!(r.get(&second).unwrap().status, ExecStatus::Queued);
    assert_eq!(r.get(&first).unwrap().status, ExecStatus::Running);
    assert_eq!(r.list(None, true).len(), 2, "queued counts as live");
    assert_eq!(r.live().ids("S1").len(), 2);
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
        .start(agents(
            d.path(),
            &format!("while [ ! -e {} ]; do sleep 0.05; done", gate.display()),
        ))
        .await
        .unwrap();
    let stopped = r
        .start(agents(d.path(), "touch ran-stopped"))
        .await
        .unwrap();
    let kept = r.start(agents(d.path(), "echo kept")).await.unwrap();
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
        machine: None,
        priority: None,
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

/// [D] (files): a runner's verdict for a job that ran on a `shared` runner reaches the job's summary, and so its
/// starter's wake, labelled ("output from runner uni-box (shared)"), and the job never counts for a gate; a verdict
/// from a runner of yours has no label and counts. No slot here (fixed 0): both jobs stay queued until their verdicts.
#[tokio::test]
async fn a_shared_runners_result_is_labelled_and_never_counts_for_a_gate() {
    let d = tempfile::tempdir().unwrap();
    let r = plain(d.path(), 0);
    let shared = r.start(agents(d.path(), "true")).await.unwrap();
    let mine = r.start(agents(d.path(), "true")).await.unwrap();
    assert_eq!(r.get(&shared).unwrap().status, ExecStatus::Queued);
    let done = |id: &str, shared: Option<&str>| Outcome::Done {
        id: id.into(),
        attempt: 1,
        result: json!({"verdict": "Pass"}),
        shared: shared.map(String::from),
    };
    r.inner
        .get()
        .unwrap()
        .outcomes(vec![done(&shared, Some("uni-box")), done(&mine, None)]);
    let label = "output from runner uni-box (shared)";
    let row = ended(&r, &shared).await;
    assert_eq!(row.status, ExecStatus::Done);
    let lines = row.summary.unwrap().lines;
    assert_eq!(lines.first().map(String::as_str), Some(label), "{lines:?}");
    let wake = crate::agents::wake::wake_text(&r.done(&shared).unwrap());
    assert!(wake.contains(label), "{wake}");
    assert!(!r.counts_for_gates(&shared));
    let row = ended(&r, &mine).await;
    assert_eq!(row.status, ExecStatus::Done);
    assert!(
        !row.summary
            .unwrap()
            .lines
            .iter()
            .any(|l| l.contains("(shared)"))
    );
    assert!(r.counts_for_gates(&mine));
    assert!(!r.counts_for_gates("xunknown"));
}

/// [D] (files and a store): a queued job an older hub left as `pending.json` is read into `rq_job` once, its file
/// then gone, and a second open (the next hub) reads nothing twice. No slot here (fixed 0), so it stays queued.
#[tokio::test]
async fn a_queued_pending_json_is_read_once() {
    let d = tempfile::tempdir().unwrap();
    let dir = d.path().join("exec/xolder");
    std::fs::create_dir_all(&dir).unwrap();
    let now = now();
    let meta = Meta {
        id: "xolder".into(),
        session: Some("S1".into()),
        kind: "other".into(),
        argv: vec!["echo".into(), "older".into()],
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
        machine: None,
        priority: None,
    };
    std::fs::write(dir.join("meta.json"), serde_json::to_vec(&meta).unwrap()).unwrap();
    let pending = Pending::of(&agents(d.path(), "echo older"));
    std::fs::write(
        dir.join("pending.json"),
        serde_json::to_vec(&pending).unwrap(),
    )
    .unwrap();
    let (_store, db) = crate::runtime_db::open(d.path()).unwrap();
    let rows = || {
        let db = db.clone();
        async move {
            db.read(|c| {
                let mut st = c.prepare("select id, own, state, spec from rq_job")?;
                let rows = st
                    .query_map([], |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, String>(2)?,
                            r.get::<_, String>(3)?,
                        ))
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(rows)
            })
            .await
            .unwrap()
        }
    };
    let opened = |db: urdr::Handle| {
        let r = Runner::default();
        r.open(
            d.path().join("exec"),
            Hooks {
                runtime: Some(db),
                admission: crate::runners::local::Admission::Fixed(0),
                plain_sessions: true,
                ..hooks()
            },
        );
        r
    };
    let first = opened(db.clone());
    let got = skuld::wait_until_async("the pending job in rq_job", 30, || {
        let rows = rows();
        async move { Some(rows.await).filter(|r| !r.is_empty()) }
    })
    .await;
    assert_eq!(got.len(), 1, "{got:?}");
    let (id, own, state, spec) = &got[0];
    assert_eq!((id.as_str(), *own, state.as_str()), ("xolder", 3, "queued"));
    assert!(spec.contains("echo older"), "{spec}");
    skuld::wait_until_async("pending.json to go", 30, || {
        std::future::ready((!dir.join("pending.json").exists()).then_some(()))
    })
    .await;
    assert_eq!(first.get("xolder").unwrap().status, ExecStatus::Queued);
    drop(first);
    let second = opened(db.clone());
    // its queue holds it again (from rq_job: the file is gone), and says why it waits
    let row = skuld::wait_until_async("the next hub's queue to hold it", 30, || {
        std::future::ready(second.get("xolder").filter(|r| r.waiting.is_some()))
    })
    .await;
    assert_eq!(row.status, ExecStatus::Queued);
    assert_eq!(row.priority, Some(3));
    assert_eq!(rows().await.len(), 1);
    drop(second);
}

/// S7: finished job folders past the retention are removed (the newest kept, a fresh one never), running ones stay.
#[tokio::test]
async fn finished_job_folders_past_the_retention_are_pruned() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let root = d.path().join("exec");
    let ago = |secs: u64| skuld::host_now() - Duration::from_secs(secs);
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

/// A log with bytes that are not UTF-8 is read with replacement characters, never as nothing.
#[tokio::test]
async fn a_log_that_is_not_text_is_read_with_replacements() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let dir = d.path().join("exec/xbytes");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("log"), b"one\n\xff two\nthree\n").unwrap();
    assert_eq!(r.log_slice("xbytes", 1, 5), ["\u{fffd} two", "three"]);
    assert_eq!(r.log_slice("xbytes", 0, 1), ["one"]);
    // its end too
    assert_eq!(r.log_tail("xbytes", 100), ["one", "\u{fffd} two", "three"]);
}

/// The end of a log: its last bytes as lines, a character the cut began inside dropped, the whole log when it is
/// shorter, nothing for a job without a log.
#[tokio::test]
async fn the_end_of_a_log_is_its_last_bytes() {
    let d = tempfile::tempdir().unwrap();
    let r = open(d.path());
    let dir = d.path().join("exec/xtail");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("log"), "one\ntwo\nthree\nh\u{e9}llo\n").unwrap();
    assert_eq!(
        r.log_tail("xtail", 1000),
        ["one", "two", "three", "h\u{e9}llo"]
    );
    assert_eq!(r.log_tail("xtail", 13), ["three", "h\u{e9}llo"]);
    assert_eq!(r.log_tail("xtail", 12), ["hree", "h\u{e9}llo"]);
    // "\u{e9}" is two bytes: a cut after its first leaves its second, which is dropped
    assert_eq!(r.log_tail("xtail", 5), ["llo"]);
    assert!(r.log_tail("xnone", 100).is_empty());
}

#[test]
fn a_tail_takes_no_slice_and_a_bounded_size() {
    let m = runstav::registry::find("exec/log").expect("exec/log");
    assert!((m.decode)(&json!({"id": "x1", "tail_bytes": 4096})).is_ok());
    for bad in [
        json!({"id": "x1", "tail_bytes": 0}),
        json!({"id": "x1", "tail_bytes": 1_048_577}),
        json!({"id": "x1", "tail_bytes": 10, "from": 0}),
        json!({"id": "x1", "tail_bytes": 10, "n": 5}),
    ] {
        assert!((m.decode)(&bad).is_err(), "{bad}");
    }
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
