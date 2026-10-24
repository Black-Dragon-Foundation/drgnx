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
        if row.status != ExecStatus::Running {
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
    let d = tempfile::tempdir_in("/tmp").unwrap();
    let wt = d.path().join("wt");
    std::fs::create_dir_all(&wt).unwrap();
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

#[tokio::test]
async fn a_container_job_runs_the_fixed_podman_line() {
    use std::os::unix::fs::PermissionsExt;
    let d = tempfile::tempdir().unwrap();
    // a stand-in for podman: the image is "present", and `run` prints the line it was given
    let fake = d.path().join("podman");
    std::fs::write(
        &fake,
        "#!/bin/sh\nif [ \"$1\" = image ]; then exit 0; fi\nprintf '%s\\n' \"$@\"\n",
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
