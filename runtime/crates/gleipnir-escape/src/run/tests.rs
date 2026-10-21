use super::*;
use crate::row::Row;
use serde_json::json;

fn row(v: Value) -> Row {
    let r: Row = serde_json::from_value(v).unwrap();
    r.check().unwrap();
    r
}

fn line(probe: &str, result: &str, errno: Option<&str>, detail: Option<&str>) -> ProbeLine {
    ProbeLine {
        probe: probe.into(),
        arg: "x".into(),
        result: result.into(),
        errno: errno.map(Into::into),
        detail: detail.map(Into::into),
        out_bytes: None,
    }
}

fn canaries() -> Vec<Canary> {
    vec![Canary {
        name: "ssh-key",
        text: "glp-canary-0123456789ab".into(),
    }]
}

fn ok_data(lines: Vec<ProbeLine>) -> RunData {
    RunData {
        result_file: Some(json!({"refused": null, "exit": 0, "layers": {}})),
        lines,
        ..RunData::default()
    }
}

fn blocked_row() -> Row {
    row(json!({
        "row": "r", "control": true,
        "probes": [["read", "/x"]],
        "expect": [{"result": "blocked", "errno": ["ENOENT"]}],
    }))
}

#[test]
fn control_not_reached_fails_the_row() {
    let r = blocked_row();
    let e = judge_control(&r, &[line("read", "blocked", Some("ENOENT"), None)]).unwrap_err();
    assert!(e.starts_with("control did not reach"), "{e}");
    judge_control(&r, &[line("read", "reached", None, Some("5"))]).unwrap();
    // No line at all is not a reach either.
    assert!(
        judge_control(&r, &[])
            .unwrap_err()
            .starts_with("control did not reach")
    );
}

#[test]
fn control_expect_replaces_reached() {
    let r = row(json!({
        "row": "r", "control": true,
        "probes": [["syscall", "mount-missing"]],
        "expect": [{"result": "blocked", "errno": ["EPERM"]}],
        "control_expect": [{"result": "blocked", "errno": ["ENOENT"]}],
    }));
    judge_control(&r, &[line("syscall", "blocked", Some("ENOENT"), None)]).unwrap();
    assert!(judge_control(&r, &[line("syscall", "reached", None, None)]).is_err());
}

#[test]
fn an_unlisted_skip_reason_is_a_fail() {
    // The skip reasons are a closed enum with the plan's words.
    let all = [
        (Skip::InContainer, "inside a container"),
        (Skip::NeedsMacos, "needs macos"),
        (Skip::NeedsLinux, "needs linux"),
        (Skip::NeedsX86_64, "needs x86_64"),
        (Skip::X32Off, "x32 is off"),
        (Skip::NeedsRoot, "needs root"),
        (
            Skip::LandlockBelow { have: 7, need: 9 },
            "Landlock ABI 7 below 9",
        ),
    ];
    for (s, text) in all {
        assert_eq!(s.to_string(), text);
    }
    // A sandbox refusal is a fail, with or without `--require-all`, not a skip.
    let r = row(json!({"row": "r", "probes": [["fds"]], "expect": [{"result": "reached"}]}));
    let mut d = ok_data(vec![]);
    d.result_file =
        Some(json!({"refused": {"rule": "Setup", "message": "no bwrap"}, "exit": null}));
    let e = judge_run(&r, &d, &canaries()).unwrap_err();
    assert!(e.contains("the sandbox refused the run"), "{e}");
    // And a host that has everything skips nothing.
    let host = Host {
        in_container: false,
        root: true,
        landlock_abi: 9,
        x32: true,
    };
    let needy = row(
        json!({"row": "r", "needs": ["bwrap", "reduced", "root"], "probes": [["fds"]], "expect": [{"result": "reached"}]}),
    );
    assert_eq!(skip_reason(&needy, &host), None);
    let host = Host {
        in_container: true,
        ..host
    };
    assert_eq!(skip_reason(&needy, &host), Some(Skip::InContainer));
    let host = Host {
        in_container: false,
        landlock_abi: 7,
        ..host
    };
    assert_eq!(
        skip_reason(&needy, &host),
        Some(Skip::LandlockBelow { have: 7, need: 9 })
    );
}

#[test]
fn a_row_without_result_asserts_exit_0_and_one_line_per_probe() {
    let r = row(json!({
        "row": "r", "probes": [["fds"], ["fds"]],
        "expect": [{"result": "reached"}, {"result": "reached"}],
    }));
    let two = vec![
        line("fds", "reached", None, Some("0,1,2")),
        line("fds", "reached", None, Some("0,1,2")),
    ];
    judge_run(&r, &ok_data(two.clone()), &canaries()).unwrap();
    // One line short.
    let e = judge_run(&r, &ok_data(two[..1].to_vec()), &canaries()).unwrap_err();
    assert!(e.contains("1 lines for 2 probes"), "{e}");
    // A non-zero exit, judged from the result file.
    let mut d = ok_data(two.clone());
    d.result_file = Some(json!({"refused": null, "exit": 3}));
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("exited 3")
    );
    // No result file at all.
    let mut d = ok_data(two);
    d.result_file = None;
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("no result file")
    );
}

#[test]
fn a_row_with_result_compares_a_subset() {
    let r = row(json!({
        "row": "r", "probes": [["fds"]],
        "result": {"refused": {"rule": "Setup", "message_contains": "ABI 8, needs 9"}},
    }));
    let mut d = ok_data(vec![]);
    d.result_file = Some(
        json!({"refused": {"rule": "Setup", "message": "Landlock is at ABI 8, needs 9", "path": null}, "exit": null}),
    );
    judge_run(&r, &d, &canaries()).unwrap();
    d.result_file = Some(json!({"refused": {"rule": "Setup", "message": "other"}}));
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("lacks")
    );
    d.result_file = Some(json!({"refused": null}));
    assert!(judge_run(&r, &d, &canaries()).is_err());
}

/// Gate review S12: a refused row passes only when nothing ran. The program printing a line (it ran after all) fails
/// the row even when the result file says refused, and `{"refused": {}}` needs a refusal, not `null`.
#[test]
fn a_refused_row_needs_silence_and_a_refusal() {
    let r = row(json!({
        "row": "r", "probes": [["status-field", "Seccomp"]],
        "result": {"refused": {}},
    }));
    let refused = json!({"refused": {"rule": "Setup", "message": "no"}, "exit": null});
    let mut d = ok_data(vec![]);
    d.result_file = Some(refused.clone());
    judge_run(&r, &d, &canaries()).unwrap();
    // It ran: a probe line on stdout.
    let ran = r#"{"probe":"status-field","arg":"Seccomp","result":"reached","detail":"0"}"#;
    d.stdout = ran.into();
    d.lines = vec![line("status-field", "reached", None, Some("0"))];
    let e = judge_run(&r, &d, &canaries()).unwrap_err();
    assert!(e.contains("to print nothing"), "{e}");
    // Not refused at all: `{}` does not match `null`.
    let mut d = ok_data(vec![]);
    d.result_file = Some(json!({"refused": null, "exit": 0}));
    let e = judge_run(&r, &d, &canaries()).unwrap_err();
    assert!(e.contains("wanted an object"), "{e}");
    assert!(subset(&json!({"refused": null}), &json!({"refused": {}})).is_err());
    assert!(subset(&json!({"refused": "x"}), &json!({"refused": {}})).is_err());
    subset(&refused, &json!({"refused": {}})).unwrap();
}

#[test]
fn canary_in_output_fails_the_row() {
    let r = row(json!({"row": "r", "probes": [["fds"]], "expect": [{"result": "reached"}]}));
    let l = vec![line("fds", "reached", None, None)];
    judge_run(&r, &ok_data(l.clone()), &canaries()).unwrap();
    for field in 0..3 {
        let mut d = ok_data(l.clone());
        let leak = "found glp-canary-0123456789ab here".to_string();
        match field {
            0 => d.stdout = leak,
            1 => d.stderr = leak,
            _ => d.result_text = leak,
        }
        let e = judge_run(&r, &d, &canaries()).unwrap_err();
        assert!(e.contains("canary text (ssh-key)"), "{e}");
    }
}

#[test]
fn expectations_check_errno_and_detail() {
    let r = blocked_row();
    judge_run(
        &r,
        &RunData {
            direct: false,
            ..ok_data(vec![line("read", "blocked", Some("ENOENT"), None)])
        },
        &canaries(),
    )
    .unwrap();
    let e = judge_run(
        &r,
        &ok_data(vec![line("read", "blocked", Some("EACCES"), None)]),
        &canaries(),
    )
    .unwrap_err();
    assert!(e.contains("wanted errno"), "{e}");
    let e = judge_run(
        &r,
        &ok_data(vec![line("read", "reached", None, None)]),
        &canaries(),
    )
    .unwrap_err();
    assert!(e.contains("wanted blocked"), "{e}");
    let d = row(
        json!({"row": "d", "probes": [["http-connect", "x:1"]], "expect": [{"result": "reached", "detail": "200"}]}),
    );
    assert!(
        judge_run(
            &d,
            &ok_data(vec![line("http-connect", "reached", None, Some("403"))]),
            &canaries()
        )
        .is_err()
    );
}

/// The judge's line count and listener checks bite where the gate's mutants found no test (gate review fix round):
/// a listener that saw nothing passes, a control run with a line missing fails, and a row that kills its run is
/// judged without the exit or the line count a plain run needs.
#[test]
fn quiet_listeners_missing_control_lines_and_killed_runs() {
    let r = row(json!({
        "row": "r", "probes": [["fds"], ["fds"]],
        "expect": [{"result": "reached"}, {"result": "reached"}],
        "listeners_silent": ["hub"],
    }));
    let two = vec![
        line("fds", "reached", None, None),
        line("fds", "reached", None, None),
    ];
    let mut d = ok_data(two.clone());
    d.silent = vec![("hub".into(), 0)];
    judge_run(&r, &d, &canaries()).unwrap();
    let direct = RunData {
        direct: true,
        result_file: None,
        lines: two[..1].to_vec(),
        ..RunData::default()
    };
    let e = judge_run(&r, &direct, &canaries()).unwrap_err();
    assert!(e.contains("1 lines for 2 probes"), "{e}");
    let killed = row(json!({
        "row": "k", "probes": [["spawn-sleep", "9"], ["run", "sleep", "3"]],
        "expect": [{"result": "reached"}],
        "after": {"after_lines": 1, "kill": "group", "gone": {"match": "spawn-sleep 9", "within_ms": 1500}},
    }));
    let mut d = ok_data(vec![line("spawn-sleep", "reached", None, Some("7"))]);
    d.result_file = Some(json!({"refused": null, "exit": 137}));
    judge_run(&killed, &d, &canaries()).unwrap();
}

#[test]
fn silent_listeners_events_and_files() {
    let r = row(json!({
        "row": "r", "probes": [["fds"]], "expect": [{"result": "reached"}],
        "listeners_silent": ["hub"], "proxy_events": ["Denied b.test:443", "Denied a.test:443"],
        "files_absent": ["${MARKER}"],
    }));
    let l = vec![line("fds", "reached", None, None)];
    let mut d = ok_data(l);
    d.events = vec!["Denied a.test:443".into(), "Denied b.test:443".into()];
    judge_run(&r, &d, &canaries()).unwrap();
    d.silent = vec![("hub".into(), 1)];
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("listener hub saw 1")
    );
    d.silent = vec![];
    d.events.pop();
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("proxy events")
    );
    d.events = vec!["Denied a.test:443".into(), "Denied b.test:443".into()];
    d.present = vec!["/tmp/glp-x/marker".into()];
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("exists after the run")
    );
}

#[test]
fn proxy_events_are_judged_with_placeholders_filled() {
    let r = row(json!({
        "row": "r", "probes": [["fds"]], "expect": [{"result": "reached"}],
        "proxy_events": ["Refused Private ${TCP_LO}"],
    }));
    let mut d = ok_data(vec![line("fds", "reached", None, None)]);
    d.events = vec!["Refused Private 127.0.0.1:4000".into()];
    d.events_wanted = Some(vec!["Refused Private 127.0.0.1:4000".into()]);
    judge_run(&r, &d, &canaries()).unwrap();
    d.events_wanted = Some(vec!["Refused Private 127.0.0.1:4001".into()]);
    assert!(
        judge_run(&r, &d, &canaries())
            .unwrap_err()
            .contains("proxy events")
    );
}

#[test]
fn a_killed_run_needs_no_result_file_but_its_lines_still_count() {
    let r = row(json!({
        "row": "r", "probes": [["spawn-sleep", "61"], ["run", "sleep", "30"]],
        "expect": [{"result": "reached"}],
        "after": {"after_lines": 1, "kill": "run", "gone": {"match": "spawn-sleep 61", "within_ms": 1000}},
    }));
    let d = RunData {
        lines: vec![line("spawn-sleep", "reached", None, Some("7"))],
        ..RunData::default()
    };
    judge_run(&r, &d, &canaries()).unwrap();
    let blocked = RunData {
        lines: vec![line("spawn-sleep", "blocked", Some("EPERM"), None)],
        ..RunData::default()
    };
    assert!(judge_run(&r, &blocked, &canaries()).is_err());
    let gone = RunData {
        gone_failure: Some("still there".into()),
        ..d
    };
    assert!(judge_run(&r, &gone, &canaries()).is_err());
    // Killing the sandbox's group leaves `sandbox run` alive: its result file is still required.
    let g = row(json!({
        "row": "g", "probes": [["spawn-sleep", "61"], ["run", "sleep", "30"]],
        "expect": [{"result": "reached"}],
        "after": {"after_lines": 1, "kill": "group"},
    }));
    let none = RunData {
        lines: vec![line("spawn-sleep", "reached", None, Some("7"))],
        ..RunData::default()
    };
    assert!(
        judge_run(&g, &none, &canaries())
            .unwrap_err()
            .contains("no result file")
    );
}

#[test]
fn subset_rules() {
    let a = json!({"ok": false, "reason": "inside a container", "fix": null, "n": [1, 2]});
    subset(&a, &json!({"ok": false, "fix": null})).unwrap();
    subset(&a, &json!({"reason_contains": "container"})).unwrap();
    assert!(subset(&a, &json!({"ok": true})).is_err());
    assert!(subset(&a, &json!({"missing": 1})).is_err());
    assert!(
        subset(&a, &json!({"n": [1]})).is_err(),
        "arrays are compared whole"
    );
}

#[test]
fn spec_defaults_and_the_probe_dir() {
    let fx = Fixture::new().unwrap();
    let r = row(
        json!({"row": "r", "tier": "reduced", "spec": {"write": ["${W}"]}, "probes": [["fds"]], "expect": [{"result": "reached"}]}),
    );
    let bin = fx.path("bin");
    let spec = build_spec(&fx, &r, &bin).unwrap();
    assert_eq!(spec["chdir"], fx.path("w").to_string_lossy().as_ref());
    assert_eq!(spec["tmp"], fx.path("t").to_string_lossy().as_ref());
    assert_eq!(spec["layers"]["landlock_min_abi"], 9);
    assert_eq!(spec["read"], json!([bin.to_string_lossy()]));
    let relay = &spec["net"]["isolated"]["relay"][0];
    assert_eq!(
        relay["socket"],
        fx.path("run/drgnx/s/S1/proxy.sock")
            .to_string_lossy()
            .as_ref()
    );
    assert!(relay["port"].as_u64().unwrap() > 0);
    assert_eq!(spec["run"]["source"], spec["run"]["dest"]);
    // A row that says `net` itself gets no relay, run or sockets.
    let r = row(
        json!({"row": "r", "spec": {"net": "shared"}, "probes": [["fds"]], "expect": [{"result": "reached"}]}),
    );
    let spec = build_spec(&fx, &r, &bin).unwrap();
    assert_eq!(spec["net"], "shared");
    assert!(spec.get("run").is_none() && spec.get("sockets").is_none());
    // The spec the harness builds is one gleipnir parses.
    serde_json::from_value::<gleipnir::Spec>(spec).unwrap();
}

#[test]
fn the_pause_dance_swaps_a_path_for_a_link() {
    let dir = tempfile::tempdir().unwrap();
    let fifo = dir.path().join("f");
    let c = std::ffi::CString::new(fifo.to_string_lossy().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let (task, target) = (dir.path().join("task"), dir.path().join("elsewhere"));
    std::fs::create_dir(&task).unwrap();
    std::fs::create_dir(&target).unwrap();
    // A stand-in for `ratatoskr --pause-before-spawn`: writes "opened", waits for a line.
    let f2 = fifo.clone();
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "echo opened > '{0}'; read line < '{0}'; echo got-$line",
            f2.display()
        ))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    pause_dance(&fifo, &[(task.clone(), target.clone())], &mut child).unwrap();
    let mut out = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .unwrap();
    assert_eq!(out.trim(), "got-go");
    assert!(task.is_symlink());
    assert!(dir.path().join("task.orig").is_dir());
}

fn mac_rows() -> Vec<Row> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("rows/macos");
    crate::row::load_dir(&dir).unwrap()
}

#[test]
fn macos_rows_cover_mac_sb_10_and_skip_elsewhere() {
    let rows = mac_rows();
    let names: Vec<&str> = rows.iter().map(|r| r.row.as_str()).collect();
    // The plan's table (Task 16) and the Mac checklist's (a)-(j): one row at least for each.
    for want in [
        "mac-profile-accepted",
        "mac-works",
        "mac-works-git",
        "mac-devices",
        "mac-tmp-metadata-only",
        "mac-home-closed",
        "mac-users-shared-closed",
        "mac-fds-closed",
        "mac-writes",
        "mac-case",
        "mac-rename-hidden-dir",
        "mac-rename-task-out",
        "mac-rename-over-root",
        "mac-rename-binds-out",
        "mac-link-hidden-pinned",
        "mac-swap-and-dir-clone",
        "mac-renames-still-work",
        "mac-sockets",
        "mac-net-shared",
        "mac-net-isolated",
        "mac-env-clean",
        "mac-k1",
        "mac-k2",
        "mac-k8",
        "mac-no-controlling-tty",
        "mac-leaves-group-the-gap",
    ] {
        assert!(names.contains(&want), "no row {want}");
    }
    let host = Host {
        in_container: false,
        root: false,
        landlock_abi: 0,
        x32: false,
    };
    for r in &rows {
        assert_eq!(r.platform(), Platform::Macos, "{}", r.row);
        if !cfg!(target_os = "macos") {
            assert_eq!(skip_reason(r, &host), Some(Skip::NeedsMacos), "{}", r.row);
        }
        // Every refusing expectation names Seatbelt's errnos or none; a Linux-only errno would never match there.
        // The one exception is the kernel's own answer for a process without a controlling terminal.
        for e in &r.expect {
            assert!(
                e.errno.iter().all(|n| n == "EPERM"
                    || n == "EACCES"
                    || (n == "ENXIO" && r.row == "mac-no-controlling-tty")),
                "{}",
                r.row
            );
        }
    }
}

/// `rows/any` runs on macOS with `--require-all` (gate review B1): none of its rows may need Linux, or the macOS job
/// fails on a skip.
#[test]
fn any_rows_run_on_macos() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("rows/any");
    let rows = crate::row::load_dir(&dir).unwrap();
    assert!(!rows.is_empty());
    let linux_only = [
        Need::Linux,
        Need::Bwrap,
        Need::Reduced,
        Need::Landlock,
        Need::Seccomp,
        Need::Netns,
        Need::X32,
    ];
    for r in &rows {
        assert_eq!(r.platform(), Platform::Any, "{}", r.row);
        assert!(
            !r.needs.iter().any(|n| linux_only.contains(n)),
            "{} needs Linux but sits in rows/any",
            r.row
        );
    }
}

/// The specs the macOS rows carry are ones gleipnir accepts for the macOS target and turns into a profile. This is
/// what Linux CI can know about them; whether Seatbelt behaves as they say is the macOS run's.
#[test]
fn macos_row_specs_validate_and_make_a_profile() {
    for r in mac_rows() {
        let mut fx = Fixture::new().unwrap();
        setup(&mut fx, &r, false).unwrap();
        let spec = build_spec_for(&fx, &r, &fx.path("bin"), false).unwrap();
        let spec: gleipnir::Spec =
            serde_json::from_value(spec).unwrap_or_else(|e| panic!("{}: {e}", r.row));
        let p = |rel: &str| fx.path(rel);
        let ctx = gleipnir::Context {
            home: p("home"),
            closed: vec![p("data"), p("config")],
            user_sockets: vec![
                p("run/drgnx/hub-0000.sock"),
                p("run/emacs/server"),
                p("run/bus"),
                p("run/ssh-agent.sock"),
            ],
            run_parents: vec![p("run/drgnx/s")],
            program_dirs: vec!["/usr/bin".into()],
            ..gleipnir::Context::default()
        };
        let valid = gleipnir::validate(spec, &ctx, gleipnir::Target::Macos)
            .unwrap_or_else(|e| panic!("{}: {e}", r.row));
        let profile = gleipnir::sbpl::profile(&valid, &gleipnir::sbpl::MacContext::default())
            .unwrap_or_else(|e| panic!("{}: {e}", r.row));
        if r.row == "mac-case" {
            // The case-insensitive denies the row exists to test.
            for want in [
                "[Cc][Oo][Mm][Mm][Oo][Nn][Dd][Ii][Rr]",
                "[Ee][Nn][Vv]",
                "[Gg][Ii][Tt]",
            ] {
                assert!(profile.contains(want), "mac-case: no deny for {want}");
            }
        }
        if r.row == "mac-net-isolated" {
            let port = fx.addrs.proxy_tcp.port();
            assert!(
                profile.contains(&format!("localhost:{port}")),
                "the proxy port is listed"
            );
        }
    }
}
