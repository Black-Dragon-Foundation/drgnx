//! The processes standard (docs/develop/standards/processes.md): a child gets exactly the environment it is given, and
//! a deadline kills its whole process group.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::time::Duration;

use draugr::{Spec, env, spawn};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};

fn spec(program: &str, args: &[&str], set: &[(&str, &OsStr)]) -> Spec {
    Spec {
        program: program.into(),
        args: args.iter().map(Into::into).collect(),
        env: env::build(&["PATH"], &[], set),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    }
}

#[tokio::test]
async fn spawn_env_is_explicit() {
    let mut child = spawn(spec(
        "/usr/bin/env",
        &[],
        &[("DRGNX_ONLY", OsStr::new("1"))],
    ))
    .await
    .unwrap();
    let mut out = String::new();
    child
        .take_stdout()
        .unwrap()
        .read_to_string(&mut out)
        .await
        .unwrap();
    assert!(child.wait().await.unwrap().unwrap().success());
    let names: BTreeSet<&str> = out
        .lines()
        .filter_map(|l| l.split_once('=').map(|(k, _)| k))
        .collect();
    let mut want = BTreeSet::from(["DRGNX_ONLY"]);
    if std::env::var_os("PATH").is_some() {
        want.insert("PATH");
    }
    assert_eq!(names, want, "{out}");
}

/// Whether PID is gone or a zombie (`/proc/PID/stat`'s state).
fn gone(pid: u32) -> bool {
    match std::fs::read(format!("/proc/{pid}/stat")) {
        Err(_) => true,
        Ok(b) => {
            let s = String::from_utf8_lossy(&b);
            s.rsplit_once(')')
                .is_some_and(|(_, rest)| rest.trim_start().starts_with('Z'))
        }
    }
}

#[tokio::test]
async fn spawn_deadline_kills_group() {
    // the shell starts a grandchild in its group, says its pid, and waits on it
    let mut child = spawn(spec("/bin/sh", &["-c", "sleep 300 & echo $!; wait"], &[]))
        .await
        .unwrap();
    let mut lines = BufReader::new(child.take_stdout().unwrap()).lines();
    let grandchild: u32 = lines
        .next_line()
        .await
        .unwrap()
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert!(!gone(grandchild));

    let status = child
        .wait_deadline(Duration::from_millis(300))
        .await
        .unwrap()
        .unwrap();
    assert!(!status.success(), "{status:?}");
    // the grandchild went with the group: SIGKILL is delivered at once, the reparented zombie reaped soon after
    for _ in 0..100 {
        if gone(grandchild) {
            return;
        }
        stund::sleep(Duration::from_millis(50)).await;
    }
    panic!("the grandchild {grandchild} outlived the deadline");
}
