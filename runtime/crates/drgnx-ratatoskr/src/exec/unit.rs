//! A job's unit (Task 11): a `systemd-run --user` transient unit (MemoryMax from `agents-job-memory`, default 4G)
//! running the starter's Gleipnir spec on Linux, else its own session and process group; re-attached after a hub
//! restart by unit name, or pid and start time.
//!
//! The unit is a *scope* (`systemd-run --user --scope`): the command is exec'd in place, so it stays the hub's child
//! (the sandbox helper's status pipe reaches it) while systemd holds its memory cap.  A small shell wraps the
//! starter's command: it sends stdout and stderr to the job's log and writes the exit code to `exit` (through a rename,
//! so a half-written file is never read), which is what a hub that started later reads.

use draugr::Spec;
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// What a job is, saved as `<dir>/meta.json` when it starts (and `pid` / `start_time` once it runs).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Meta {
    pub id: String,
    pub session: Option<String>,
    pub kind: String,
    pub argv: Vec<String>,
    pub cwd: String,
    pub started: f64,
    pub timebox_s: u64,
    /// When the time box ends (seconds since the epoch).
    pub deadline: f64,
    pub unit: Option<String>,
    pub pid: Option<i32>,
    pub start_time: Option<u64>,
    /// The graph entity (`exec:…`), once recorded.
    pub entity: Option<String>,
}

/// The shell that wraps the command: `sh -c SCRIPT sh DIR PROGRAM ARGS…`.
const SCRIPT: &str = r#"d=$1; shift; exec >"$d/log" 2>&1; "$@"; c=$?; echo "$c" > "$d/exit.tmp"; mv "$d/exit.tmp" "$d/exit"; exit "$c""#;

/// Whether a user systemd answers here: its runtime dir exists and `systemd-run` is on the PATH.
pub fn systemd_user() -> bool {
    let rt = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    rt.is_some_and(|d| d.join("systemd").is_dir()) && on_path("systemd-run")
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(program).is_file()))
}

/// The unit's name for job ID.
pub fn unit_name(id: &str) -> String {
    format!("drgnx-exec-{id}")
}

/// Wrap INNER (the starter's launch, or the bare command) in the logging shell and, with `unit`, in a transient scope
/// with `MemoryMax=MEMORY`.  The child leads a session of its own either way.
pub fn wrap(inner: Spec, dir: &Path, unit: Option<(&str, &str)>) -> Spec {
    let mut args: Vec<OsString> = Vec::new();
    let program = match unit {
        Some((name, memory)) => {
            for a in [
                "--user",
                "--scope",
                "--quiet",
                "--collect",
                "--unit",
                name,
                "-p",
                &format!("MemoryMax={memory}"),
                "--",
                "sh",
            ] {
                args.push(a.into());
            }
            PathBuf::from("systemd-run")
        }
        None => PathBuf::from("sh"),
    };
    args.push("-c".into());
    args.push(SCRIPT.into());
    args.push("sh".into());
    args.push(dir.into());
    args.push(inner.program.into());
    args.extend(inner.args);
    let mut env = inner.env;
    if unit.is_some() {
        for k in [
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
            "PATH",
            "HOME",
        ] {
            if !env.iter().any(|(n, _)| n == k)
                && let Some(v) = std::env::var_os(k)
            {
                env.push((k.into(), v));
            }
        }
    }
    Spec {
        program,
        args,
        env,
        cwd: inner.cwd,
        stdin_null: true,
        pass_fds: inner.pass_fds,
        new_session: true,
    }
}

/// Whether PID is still the process that started at START_TIME (a reused pid is not).
pub fn same_process(pid: i32, start_time: u64) -> bool {
    draugr::alive(pid) && draugr::start_time(pid).is_ok_and(|t| t == start_time)
}

/// The exit code the wrapper wrote, if it got that far.
pub fn read_exit(dir: &Path) -> Option<i32> {
    std::fs::read_to_string(dir.join("exit"))
        .ok()?
        .trim()
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bare(args: &[&str]) -> Spec {
        Spec {
            program: "echo".into(),
            args: args.iter().map(OsString::from).collect(),
            env: vec![],
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        }
    }

    #[test]
    fn the_wrapper_keeps_the_command_and_names_the_scope() {
        let s = wrap(bare(&["a"]), Path::new("/d"), None);
        assert_eq!(s.program, PathBuf::from("sh"));
        assert!(s.new_session);
        assert_eq!(s.args.last().unwrap(), "a");
        let s = wrap(bare(&["a"]), Path::new("/d"), Some(("drgnx-exec-x", "4G")));
        assert_eq!(s.program, PathBuf::from("systemd-run"));
        let args: Vec<_> = s.args.iter().map(|a| a.to_string_lossy()).collect();
        assert!(args.contains(&"MemoryMax=4G".into()));
        assert!(args.contains(&"drgnx-exec-x".into()));
        assert_eq!(unit_name("x"), "drgnx-exec-x");
    }

    #[test]
    fn no_exit_file_is_no_exit() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_exit(d.path()), None);
        std::fs::write(d.path().join("exit"), "3\n").unwrap();
        assert_eq!(read_exit(d.path()), Some(3));
    }
}
