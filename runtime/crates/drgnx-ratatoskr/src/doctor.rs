//! The commands that ask a running hub (or the machine) something: `status`, `doctor --json` and `restart`.
//!
//! `doctor --json` is
//! `{binary: {path, commit, test_hooks}, running: {commit, pid}?, socket_dir: {path, mode, ok}, sqlite, job_agents}`.
//! `socket_dir.ok` is true when the directory is the user's own with mode 0700, and also while it does not exist yet
//! (the hub makes it private at its first start); `mode` is then null.

use crate::client::{self, Client};
use crate::front::JOB_AGENTS;
use drgnx_proto::paths::{self, Env};
use serde_json::{Value, json};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;

const ASK: Duration = Duration::from_secs(5);

/// The running hub's pid and commit, for the report.
pub struct Running {
    pub pid: u32,
    pub commit: Option<String>,
}

/// The socket directory's state.
fn socket_dir(socket: &Path, uid: u32) -> Value {
    let dir = socket.parent().unwrap_or(Path::new("/"));
    match std::fs::symlink_metadata(dir) {
        Ok(m) => {
            let mode = m.permissions().mode() & 0o777;
            json!({
                "path": dir,
                "mode": format!("{mode:04o}"),
                "ok": m.is_dir() && mode == 0o700 && m.uid() == uid,
            })
        }
        Err(_) => json!({"path": dir, "mode": null, "ok": true}),
    }
}

/// The doctor's report for ENV, with RUNNING when a hub answered.
pub fn report(env: &Env, binary: &Path, running: Option<Running>) -> Value {
    let socket = paths::socket_path(env);
    let mut v = json!({
        "binary": {
            "path": binary,
            "commit": crate::version::COMMIT,
            "test_hooks": cfg!(feature = "test-hooks"),
        },
        "socket_dir": socket_dir(&socket, env.uid),
        "sqlite": crate::version::sqlite(),
        "job_agents": JOB_AGENTS,
    });
    if let Some(r) = running {
        v["running"] = json!({"pid": r.pid, "commit": r.commit});
    }
    v
}

/// `status`: the hub's `status` (with `"running": true`), or `{"running": false}` and exit 1 when none answers.
pub fn status(env: &Env, json_out: bool) -> i32 {
    let socket = paths::socket_path(env);
    let asked = Client::user(env, ASK).and_then(|mut c| c.call("status", json!({}), ASK));
    match asked {
        Ok(mut v) => {
            if json_out {
                v["running"] = json!(true);
                println!("{v}");
            } else {
                println!("{}", summary(&v));
            }
            0
        }
        Err(e) => match client::ping(&socket, Duration::from_secs(1)) {
            // a hub answers but would not tell: say so rather than "not running"
            Some(pid) => {
                if json_out {
                    println!("{}", json!({"running": true, "pid": pid, "error": e}));
                } else {
                    println!("running (pid {pid}), but status failed: {e}");
                }
                1
            }
            None => {
                if json_out {
                    println!("{}", json!({"running": false}));
                } else {
                    println!("not running");
                }
                1
            }
        },
    }
}

/// The lines `status` prints without `--json`.
fn summary(v: &Value) -> String {
    let text = |p: &Value| p.as_str().unwrap_or("?").to_string();
    let mut out = format!(
        "running: pid {}, commit {}, socket {}",
        v["pid"],
        text(&v["runtime"]["commit"]),
        text(&v["socket"])
    );
    if let Some(b) = v.get("backend") {
        out.push_str(&format!("\nbackend: {}", text(&b["state"])));
        if let Some(pid) = b.get("pid") {
            out.push_str(&format!(" (pid {pid})"));
        }
    }
    if let Some(n) = v.get("read_only") {
        out.push_str(&format!(
            "\nread-only: work.db is schema {n}, newer than this hub's"
        ));
    }
    out.push_str(&format!("\njob agents: {}", text(&v["job_agents"])));
    out
}

/// `doctor --json`.
pub fn doctor(env: &Env) -> i32 {
    let socket = paths::socket_path(env);
    let binary = crate::idle::resolve_exe()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let running = Client::user(env, ASK)
        .and_then(|mut c| c.call("status", json!({}), ASK))
        .ok()
        .map(|s| Running {
            pid: s["pid"]
                .as_u64()
                .and_then(|p| u32::try_from(p).ok())
                .unwrap_or(0),
            commit: s["runtime"]["commit"].as_str().map(str::to_string),
        })
        .or_else(|| {
            client::ping(&socket, Duration::from_secs(1)).map(|pid| Running { pid, commit: None })
        });
    println!("{}", report(env, &binary, running));
    0
}

/// `restart`: ask the running hub to restart (it answers, then exits 75 or re-executes itself).
pub fn restart(env: &Env) -> i32 {
    match Client::user(env, ASK).and_then(|mut c| c.call("restart", json!({}), ASK)) {
        Ok(_) => {
            println!("restarting");
            0
        }
        Err(e) => {
            eprintln!("ratatoskr restart: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_report_has_every_key_and_judges_the_socket_dir() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("r");
        std::fs::create_dir(&run).unwrap();
        std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700)).unwrap();
        let uid = rustix::process::geteuid().as_raw();
        let p = |s: &str| dir.path().join(s).to_string_lossy().into_owned();
        let env = Env::new(
            &[
                ("XDG_RUNTIME_DIR", &p("r")),
                ("DRGNX_DATA_DIR", &p("d")),
                ("XDG_STATE_HOME", &p("s")),
                ("HOME", &p("h")),
            ],
            uid,
        );
        let sock_dir = paths::socket_path(&env).parent().unwrap().to_path_buf();
        std::fs::create_dir_all(&sock_dir).unwrap();
        std::fs::set_permissions(&sock_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let v = report(&env, Path::new("/opt/ratatoskr"), None);
        assert_eq!(v["binary"]["path"], "/opt/ratatoskr");
        assert_eq!(v["binary"]["commit"], crate::version::COMMIT);
        assert_eq!(v["binary"]["test_hooks"], cfg!(feature = "test-hooks"));
        assert_eq!(v["socket_dir"]["mode"], "0700");
        assert_eq!(v["socket_dir"]["ok"], true);
        assert!(v["sqlite"].as_str().unwrap().starts_with("3."));
        assert_eq!(v["job_agents"], JOB_AGENTS);
        assert!(v.get("running").is_none());
        // too open: not ok
        std::fs::set_permissions(&sock_dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let open = report(&env, Path::new("/b"), None);
        assert_eq!(open["socket_dir"]["ok"], false);
        assert_eq!(open["socket_dir"]["mode"], "0755");
        let up = report(
            &env,
            Path::new("/b"),
            Some(Running {
                pid: 7,
                commit: Some("abc".into()),
            }),
        );
        assert_eq!(up["running"], json!({"pid": 7, "commit": "abc"}));
    }

    #[test]
    fn a_missing_socket_dir_is_fine_until_the_first_start() {
        let env = Env::new(
            &[
                ("XDG_STATE_HOME", "/nonexistent/s"),
                ("HOME", "/nonexistent/h"),
            ],
            1000,
        );
        let v = report(&env, Path::new("/b"), None);
        assert_eq!(v["socket_dir"]["ok"], true);
        assert!(v["socket_dir"]["mode"].is_null());
    }

    #[test]
    fn the_summary_names_pid_commit_backend_and_job_agents() {
        let s = summary(&json!({
            "pid": 5, "socket": "/s", "runtime": {"commit": "c1"},
            "backend": {"state": "running", "pid": 9}, "job_agents": JOB_AGENTS,
        }));
        assert!(s.contains("pid 5, commit c1, socket /s"), "{s}");
        assert!(s.contains("backend: running (pid 9)"), "{s}");
        assert!(s.contains("unsandboxed (as on main"), "{s}");
    }
}
