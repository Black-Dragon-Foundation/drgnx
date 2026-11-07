//! A terminal's worker outlives its hub under systemd (docs/develop/terminal.md, "Lifetime"): the hub runs as a
//! transient unit with `KillMode=mixed`, whose stop SIGKILLs everything left in the unit's cgroup; the worker sits in a
//! scope of its own, so it survives, and the next hub adopts it by its unit. A runner-host row (`#[ignore = "fleet"]`):
//! it needs systemd as PID 1 and a user manager, which the fake runner has (test/runners/README.md):
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet --test term_scope --no-run   # and build drgnx-term beside it
//! fleet.sh up --runners 1
//! fleet.sh host <the test binary> worker_survives_hub_restart_under_kill_mode_mixed
//! ```
//!
//! The first hub is this binary again (`a_hub_that_opens_one_terminal`, a no-op unless `TERM_SCOPE_DIR` is set), run
//! by `systemd-run --user -p KillMode=mixed`; the test stops that unit, then adopts the terminal itself, as the
//! restarted hub does at its start.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::term::{Sink, Spawn, Terms};
use drgnx_term::proto::{In, Out};
use drgnx_term::registry::{self, Record};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

/// How long a row waits on any one state before it fails.
const WAIT: u64 = 60;

struct Nowhere;

impl Sink for Nowhere {
    fn send(&self, _: u64, _: &str, _: Value) -> bool {
        false
    }
}

fn worker_bin() -> String {
    std::env::var("DRGNX_TERM_BIN").unwrap_or_else(|_| "/fleet/share/drgnx-term".into())
}

fn systemctl(args: &[&str]) -> bool {
    Command::new("systemctl")
        .arg("--user")
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

/// The first hub: open one terminal in a scope, say so in `ready`, then serve until stopped.
#[tokio::test]
#[ignore = "fleet"]
async fn a_hub_that_opens_one_terminal() {
    let Some(dir) = std::env::var_os("TERM_SCOPE_DIR").map(PathBuf::from) else {
        return;
    };
    let terms = Terms::default();
    terms.open(dir.join("term"), Arc::new(Nowhere), 1).await;
    let spawn = Spawn {
        cwd: "/".into(),
        command: vec!["/bin/sh".into()],
        env: vec![
            ("PATH".into(), "/usr/bin:/bin".into()),
            ("PS1".into(), "$ ".into()),
        ],
        cols: 40,
        rows: 5,
        class: "gui".into(),
        window: 100,
        ..Spawn::default()
    };
    let rec = terms
        .spawn_as(1, Some("s1".into()), spawn, true)
        .await
        .expect("the terminal starts");
    std::fs::write(dir.join("ready"), &rec.id).unwrap();
    std::future::pending::<()>().await;
}

fn the_record(dir: &Path) -> Record {
    let mut all = registry::read_all(&dir.join("term"));
    assert_eq!(all.len(), 1, "one terminal recorded: {all:?}");
    all.remove(0)
}

// many threads: the row's waits block one, and the hub's tasks (the writer to the worker) run on the others
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "fleet"]
async fn worker_survives_hub_restart_under_kill_mode_mixed() {
    assert!(
        drgnx_ratatoskr::exec::unit::systemd_user(),
        "a user systemd (the fake runner's)"
    );
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let tmp = tempfile::tempdir_in(home).unwrap();
    let dir = tmp.path().to_path_buf();
    let unit = format!("drgnx-term-hub-{}", std::process::id());
    let me = std::env::current_exe().unwrap();
    let env = |k: &str| format!("{k}={}", std::env::var(k).unwrap_or_default());
    let ok = Command::new("systemd-run")
        .args([
            "--user",
            "--quiet",
            "--collect",
            "--unit",
            &unit,
            "-p",
            "KillMode=mixed",
        ])
        .arg(format!("--setenv=TERM_SCOPE_DIR={}", dir.display()))
        .arg(format!("--setenv=DRGNX_TERM_BIN={}", worker_bin()))
        .arg(format!("--setenv={}", env("XDG_RUNTIME_DIR")))
        .arg(format!("--setenv={}", env("DBUS_SESSION_BUS_ADDRESS")))
        .arg(format!("--setenv={}", env("PATH")))
        .arg("--")
        .arg(&me)
        .args(["--ignored", "--exact", "a_hub_that_opens_one_terminal"])
        .output()
        .expect("systemd-run runs");
    assert!(
        ok.status.success(),
        "the hub unit starts: {}",
        String::from_utf8_lossy(&ok.stderr)
    );
    let id = skuld::wait_until("the first hub's terminal", WAIT, || {
        std::fs::read_to_string(dir.join("ready")).ok()
    });
    let before = the_record(&dir);
    assert_eq!(before.id, id);
    let shell = before.shell_pid.expect("the shell's pid is recorded");

    // the hub's unit stops: SIGTERM to the hub, then SIGKILL to whatever is left in its cgroup
    assert!(systemctl(&["stop", &unit]), "the hub unit stops");
    skuld::wait_until("the hub unit gone", WAIT, || {
        (!systemctl(&["is-active", "--quiet", &unit])).then_some(())
    });
    assert!(
        drgnx_ratatoskr::term::adopt::alive(&before),
        "the worker outlived the hub's cgroup"
    );
    assert_eq!(
        before.unit.as_deref(),
        Some(format!("drgnx-term-{id}").as_str()),
        "in a scope of its own"
    );

    // the next hub adopts it by its unit: the same shell, and typing still reaches it
    let terms = Terms::default();
    terms.open(dir.join("term"), Arc::new(Nowhere), 2).await;
    let rec = terms.record(&id).expect("adopted");
    assert_eq!(rec.shell_pid, Some(shell), "the same shell");
    assert_eq!(terms.is_old(&id), Some(false));
    assert!(terms.send(
        &id,
        &In::Text {
            text: "echo `expr 6 \\* 7`x\r".into()
        }
    ));
    let found = skuld::wait_until_async("the echo in the adopted terminal", WAIT, || {
        let terms = terms.clone();
        let id = id.clone();
        async move {
            let ask = |req| In::Search {
                req,
                query: "42x".into(),
                dir: None,
            };
            match terms.ask(&id, ask, Duration::from_secs(5)).await {
                Ok(Out::Answer { result, .. }) => {
                    (result["matches"].as_array().is_some_and(|m| !m.is_empty())).then_some(result)
                }
                _ => None,
            }
        }
    })
    .await;
    assert_eq!(found["matches"][0][2], 3);
    terms.send(&id, &In::Close { signal: Some(9) });
    skuld::wait_until("the terminal's scope gone", WAIT, || {
        (!systemctl(&["is-active", "--quiet", &format!("drgnx-term-{id}.scope")])).then_some(())
    });
}
