//! The commands that ask a running hub (or the machine) something: `status`, `doctor --json` and `restart`.
//!
//! `doctor --json` is
//! `{binary: {path, commit, test_hooks}, running: {commit, pid}?, gateway: {port, registrations, providers, keys_held,
//! warnings}?, socket_dir: {path, mode, ok}, sqlite, job_agents, sandbox: {backend, version, ok, reason, fix,
//! landlock_abi, in_use}}`.  `gateway` is the running hub's (its `status`): `keys_held` names providers only, and
//! `warnings` are its clear-text providers (`config/providers`). `sandbox` is the job sandbox's check
//! (`gleipnir::check`), `in_use` false until phase 6.
//! `socket_dir.ok` is true when the directory is the user's own with mode 0700, and also while it does not exist yet
//! (the hub makes it private at its first start); `mode` is then null.

use crate::client::{self, Client};
use crate::front::JOB_AGENTS;
use crate::sandbox;
use gleipnir::Tier;
use gleipnir::check::Check;
use runstav::paths::{self, Env};
use serde_json::{Value, json};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;

const ASK: Duration = Duration::from_secs(5);

/// `doctor`'s whole ask of a running hub (the user connection and its `status`),
/// and the least a ping after it gets: together under the 2 s the editor's doctor waits for the report (review M2),
/// so a slow hub is reported as running, not as a binary that gave no answer.
const DOCTOR_ASK: Duration = Duration::from_millis(1500);
const DOCTOR_PING: Duration = Duration::from_millis(300);
/// The sandbox check inside `doctor`, run beside the hub ask: a slow probe is reported as one that did not finish.
const DOCTOR_CHECK: Duration = Duration::from_millis(1400);
// core/drgnx-doctor.el waits 2 s for `doctor --json`
const _: () = assert!(DOCTOR_ASK.as_millis() + DOCTOR_PING.as_millis() < 2000);

/// The running hub's pid and commit, and its `status`'s `gateway`, for the report.
pub struct Running {
    pub pid: u32,
    pub commit: Option<String>,
    pub gateway: Option<Value>,
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

/// The job sandbox section: what the check found. `in_use` is false until jobs run in it (phase 6).
fn sandbox_section(c: &Check) -> Value {
    json!({
        "backend": c.backend.name(),
        "version": c.version,
        "ok": c.ok,
        "reason": c.reason,
        "fix": c.fix,
        "landlock_abi": c.landlock_abi,
        "in_use": false,
    })
}

/// The doctor's text line about the sandbox. It says what works here and that jobs do not use it yet; it never says a
/// job is "sandboxed".
pub fn sandbox_line(c: &Check) -> String {
    if c.ok {
        let name = match &c.version {
            Some(v) => format!("{} {v}", c.backend.name()),
            None => c.backend.name().to_string(),
        };
        format!(
            "job sandbox backend: {name} works here ({}); job agents do not use it yet (phase 6)",
            c.layers_text()
        )
    } else {
        let mut out = format!(
            "job sandbox backend: not available here: {}",
            c.reason.as_deref().unwrap_or("unknown")
        );
        if let Some(fix) = &c.fix {
            out.push_str(&format!(" \u{2014} {fix}"));
        }
        out
    }
}

/// The doctor's report for ENV, with RUNNING when a hub answered.
pub fn report(env: &Env, binary: &Path, running: Option<Running>, sandbox: &Check) -> Value {
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
        "sandbox": sandbox_section(sandbox),
    });
    if let Some(r) = running {
        v["running"] = json!({"pid": r.pid, "commit": r.commit});
        if let Some(g) = r.gateway {
            v["gateway"] = json!({
                "port": g["port"],
                "registrations": g["registrations"],
                "providers": g["providers"],
                "keys_held": g.get("keys_held").cloned().unwrap_or_else(|| json!([])),
                "warnings": g.get("warnings").cloned().unwrap_or_else(|| json!([])),
            });
        }
    }
    v
}

/// `status`: the hub's `status` (with `"running": true`), or `{"running": false}` and exit 1 when none answers.
pub fn status(env: &Env, json_out: bool) -> i32 {
    let socket = paths::socket_path(env);
    if let Some(why) = client::refused(&socket) {
        if json_out {
            println!("{}", json!({"running": false, "error": why}));
        }
        eprintln!("ratatoskr status: {why}");
        return 1;
    }
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

/// `doctor`: `--json` is the report; without it, a few lines of text. The sandbox check runs beside the hub ask, so
/// the two together stay under the editor's 2 s.
pub fn doctor(env: &Env, json_out: bool) -> i32 {
    let socket = paths::socket_path(env);
    let binary = crate::idle::resolve_exe()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let deadline = std::time::Instant::now() + DOCTOR_ASK;
    let left = || deadline.saturating_duration_since(std::time::Instant::now());
    let (running, sandbox) = std::thread::scope(|s| {
        let check = s.spawn(|| sandbox::check_blocking(Tier::Full, None, DOCTOR_CHECK));
        let running = Client::user(env, left())
            .and_then(|mut c| c.call("status", json!({}), left()))
            .ok()
            .map(|s| Running {
                pid: s["pid"]
                    .as_u64()
                    .and_then(|p| u32::try_from(p).ok())
                    .unwrap_or(0),
                commit: s["runtime"]["commit"].as_str().map(str::to_string),
                gateway: s.get("gateway").cloned(),
            })
            .or_else(|| {
                client::ping(&socket, left().max(DOCTOR_PING))
                    .map(|pid| Running {
                        pid,
                        commit: None,
                        gateway: None,
                    })
            });
        let check = check
            .join()
            .unwrap_or_else(|_| Check::failed("the check panicked".into(), None));
        (running, check)
    });
    let v = report(env, &binary, running, &sandbox);
    if json_out {
        println!("{v}");
    } else {
        println!("{}", text(&v, &sandbox));
    }
    0
}

/// The lines `doctor` prints without `--json`.
fn text(v: &Value, sandbox: &Check) -> String {
    let t = |p: &Value| p.as_str().unwrap_or("?").to_string();
    let mut out = format!(
        "binary: {} (commit {})\nsocket dir: {} (mode {}, {})",
        t(&v["binary"]["path"]),
        t(&v["binary"]["commit"]),
        t(&v["socket_dir"]["path"]),
        t(&v["socket_dir"]["mode"]),
        if v["socket_dir"]["ok"] == true {
            "ok"
        } else {
            "not private"
        },
    );
    if let Some(r) = v.get("running") {
        out.push_str(&format!("\nrunning: pid {}", r["pid"]));
    }
    out.push_str(&format!("\njob agents: {}", t(&v["job_agents"])));
    out.push_str(&format!("\n{}", sandbox_line(sandbox)));
    out
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
        let v = report(&env, Path::new("/opt/ratatoskr"), None, &working());
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
        let open = report(&env, Path::new("/b"), None, &working());
        assert_eq!(open["socket_dir"]["ok"], false);
        assert_eq!(open["socket_dir"]["mode"], "0755");
        let up = report(
            &env,
            Path::new("/b"),
            Some(Running {
                pid: 7,
                commit: Some("abc".into()),
                gateway: Some(json!({"port": 4100, "registrations": 2, "requests": 9, "providers": 3,
                    "keys_held": ["openrouter"],
                    "warnings": [{"provider": "lan", "text": "lan's key travels in clear text over http://192.0.2.10; use https"}]})),
            }),
            &working(),
        );
        assert_eq!(up["running"], json!({"pid": 7, "commit": "abc"}));
        // the gateway's ids and warnings only, never its traffic
        assert_eq!(
            up["gateway"],
            json!({"port": 4100, "registrations": 2, "providers": 3, "keys_held": ["openrouter"],
                   "warnings": [{"provider": "lan", "text": "lan's key travels in clear text over http://192.0.2.10; use https"}]})
        );
        assert!(open.get("gateway").is_none());
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
        let v = report(&env, Path::new("/b"), None, &working());
        assert_eq!(v["socket_dir"]["ok"], true);
        assert!(v["socket_dir"]["mode"].is_null());
    }

    fn working() -> Check {
        Check {
            backend: gleipnir::BackendKind::Bwrap,
            program: Some("/usr/bin/bwrap".into()),
            version: Some("0.12.0".into()),
            ok: true,
            reason: None,
            fix: None,
            layers: Some(gleipnir::LayersReport {
                landlock_abi: 10,
                landlock: "enforced".into(),
                seccomp: true,
                no_new_privs: true,
                new_session: true,
                relay: true,
                seatbelt: false,
            }),
            landlock_abi: 10,
            container: false,
            stderr: None,
        }
    }

    fn broken() -> Check {
        Check {
            ok: false,
            backend: gleipnir::BackendKind::None,
            reason: Some(
                "AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later)".into(),
            ),
            fix: Some("load the profile".into()),
            layers: None,
            ..working()
        }
    }

    fn report_of(c: &Check) -> Value {
        let env = Env::new(&[("HOME", "/nonexistent/h")], 1000);
        report(&env, Path::new("/b"), None, c)
    }

    #[test]
    fn sandbox_section_shape() {
        let v = report_of(&working());
        assert_eq!(
            v["sandbox"],
            json!({
                "backend": "bwrap", "version": "0.12.0", "ok": true, "reason": null, "fix": null,
                "landlock_abi": 10, "in_use": false,
            })
        );
        let v = report_of(&broken());
        assert_eq!(v["sandbox"]["backend"], "none");
        assert_eq!(v["sandbox"]["ok"], false);
        assert!(
            v["sandbox"]["reason"]
                .as_str()
                .unwrap()
                .starts_with("AppArmor")
        );
        assert_eq!(v["sandbox"]["fix"], "load the profile");
        assert_eq!(v["sandbox"]["in_use"], false);
        assert_eq!(
            sandbox_line(&working()),
            "job sandbox backend: bwrap 0.12.0 works here (Landlock ABI 10, seccomp); job agents do not use it yet (phase 6)"
        );
        assert_eq!(
            sandbox_line(&broken()),
            "job sandbox backend: not available here: AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later) \u{2014} load the profile"
        );
    }

    /// Nothing runs in the sandbox yet, so no state of the check says a job is sandboxed: not the line, not the section.
    #[test]
    fn sandbox_line_never_says_sandboxed() {
        let seatbelt = Check {
            backend: gleipnir::BackendKind::Seatbelt,
            version: None,
            layers: Some(gleipnir::LayersReport::seatbelt()),
            ..working()
        };
        for c in [
            working(),
            broken(),
            seatbelt,
            Check::failed("x".into(), None),
        ] {
            let line = sandbox_line(&c);
            let section = report_of(&c)["sandbox"].to_string();
            let text = text(&report_of(&c), &c);
            for s in [&line, &section] {
                assert!(!s.to_lowercase().contains("sandboxed"), "{s}");
            }
            // the text as a whole may say what job agents do today ("unsandboxed"), but never claims otherwise
            assert!(
                text.lines()
                    .all(|l| !l.contains("sandboxed") || l.starts_with("job agents: unsandboxed")),
                "{text}"
            );
        }
        assert!(sandbox_line(&working()).contains("job agents do not use it yet"));
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
