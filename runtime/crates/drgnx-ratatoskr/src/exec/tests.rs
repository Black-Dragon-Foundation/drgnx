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
