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
    /// The time box in seconds; none: the job has no time box (a user's server).
    pub timebox_s: Option<u64>,
    /// When the time box ends (seconds since the epoch); none: never.
    pub deadline: Option<f64>,
    pub unit: Option<String>,
    pub pid: Option<i32>,
    pub start_time: Option<u64>,
    /// The graph entity (`exec:…`), once recorded.
    pub entity: Option<String>,
    /// A container job's image name (`agents-container-images`).
    #[serde(default)]
    pub image: Option<String>,
    /// A user's job's name.
    #[serde(default)]
    pub name: Option<String>,
    /// The job is in the queue (`runtime.db`'s `rq_job` holds what to start); it has no process here yet.
    #[serde(default)]
    pub queued: bool,
    /// Where it runs: `local`, or a runner's name; none while it waits.
    #[serde(default)]
    pub machine: Option<String>,
    /// Its priority, 1 to 5, as the hub set it.
    #[serde(default)]
    pub priority: Option<u8>,
    /// A networked job's sidecar (its container name), written before the job starts: a restarted hub ends such a job
    /// rather than adopting it (it can't keep its relay).
    #[serde(default)]
    pub relay: Option<String>,
}

/// The shell that wraps the command: `sh -c SCRIPT sh DIR PROGRAM ARGS…`.
const SCRIPT: &str = r#"d=$1; shift; exec >"$d/log" 2>&1; "$@"; c=$?; echo "$c" > "$d/exit.tmp"; mv "$d/exit.tmp" "$d/exit"; exit "$c""#;

/// Whether a user systemd answers here: its runtime dir exists and `systemd-run` is on the PATH.
pub fn systemd_user() -> bool {
    let rt = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    rt.is_some_and(|d| d.join("systemd").is_dir()) && on_path("systemd-run")
}

fn on_path(program: &str) -> bool {
    find_on_path(program).is_some()
}

/// PROGRAM's file on the PATH.
pub fn find_on_path(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join(program))
        .find(|f| f.is_file())
}

/// The unit's name for job ID.
pub fn unit_name(id: &str) -> String {
    format!("drgnx-exec-{id}")
}

/// Wrap INNER (the starter's launch, or the bare command) in the logging shell and, with `unit`, in a transient scope
/// with `MemoryMax=MEMORY`.  The child leads a session of its own either way.  NICE runs the command under `nice -n`
/// (a scope takes no `Nice=`; the same line works with and without a unit).
pub fn wrap(
    inner: Spec,
    dir: &Path,
    unit: Option<(&str, &str)>,
    nice: Option<i8>,
    shell: &crate::shell_env::ShellEnv,
) -> Spec {
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
    if let Some(n) = nice {
        args.push("nice".into());
        args.push("-n".into());
        args.push(n.to_string().into());
    }
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
                && let Some(v) = shell.var_os(k)
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

/// The most tasks a browser session's scope may hold: Chromium and a Node agent together pass 512 easily.
pub const SESSION_TASKS_MAX: u32 = 4096;

/// The scope's name for session SID.
pub fn session_unit_name(sid: &str) -> String {
    format!("drgnx-session-{sid}")
}

/// A browser session's launch SPEC (the sandbox's) in a transient scope of its own: `systemd-run --user --scope
/// --quiet --collect --unit drgnx-session-SID -p MemoryMax=MEMORY -p TasksMax=4096 -- PROGRAM ARGS…`, so the session
/// and its browser share one memory cap.  The scope runs the command in place: it stays the hub's child with the same
/// fds.  Its environment is the spec's with `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` (`systemd-run` reaches
/// the user manager through them; bwrap's `--clearenv` keeps them from the sandbox).  Use it only where
/// [`systemd_user`] holds.
pub fn session_scope(spec: Spec, sid: &str, memory: &str) -> Spec {
    let unit = session_unit_name(sid);
    let mut args: Vec<OsString> = [
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--unit",
        unit.as_str(),
        "-p",
        &format!("MemoryMax={memory}"),
        "-p",
        &format!("TasksMax={SESSION_TASKS_MAX}"),
        "--",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    args.push(spec.program.into());
    args.extend(spec.args);
    let mut env = spec.env;
    for k in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
        if !env.iter().any(|(n, _)| n == k)
            && let Some(v) = std::env::var_os(k)
        {
            env.push((k.into(), v));
        }
    }
    Spec {
        program: find_on_path("systemd-run").unwrap_or_else(|| PathBuf::from("systemd-run")),
        args,
        env,
        cwd: spec.cwd,
        stdin_null: spec.stdin_null,
        pass_fds: spec.pass_fds,
        new_session: spec.new_session,
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
        let shell = crate::shell_env::ShellEnv::default();
        let s = wrap(bare(&["a"]), Path::new("/d"), None, None, &shell);
        assert_eq!(s.program, PathBuf::from("sh"));
        assert!(s.new_session);
        assert_eq!(s.args.last().unwrap(), "a");
        let s = wrap(
            bare(&["a"]),
            Path::new("/d"),
            Some(("drgnx-exec-x", "4G")),
            None,
            &shell,
        );
        assert_eq!(s.program, PathBuf::from("systemd-run"));
        let args: Vec<_> = s.args.iter().map(|a| a.to_string_lossy()).collect();
        assert!(args.contains(&"MemoryMax=4G".into()));
        assert!(args.contains(&"drgnx-exec-x".into()));
        assert_eq!(unit_name("x"), "drgnx-exec-x");
    }

    #[test]
    fn session_scope_argv() {
        let mut inner = bare(&["--die-with-parent", "x"]);
        inner.program = "/usr/bin/bwrap".into();
        inner.env = vec![("A".into(), "1".into())];
        inner.stdin_null = false;
        inner.pass_fds = vec![draugr::PassFd {
            fd: std::sync::Arc::new(std::os::fd::OwnedFd::from(
                std::fs::File::open("/dev/null").unwrap(),
            )),
            target: 5,
        }];
        let s = session_scope(inner, "S1", "4G");
        assert!(s.program.ends_with("systemd-run"), "{:?}", s.program);
        let args: Vec<String> = s
            .args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            [
                "--user",
                "--scope",
                "--quiet",
                "--collect",
                "--unit",
                "drgnx-session-S1",
                "-p",
                "MemoryMax=4G",
                "-p",
                "TasksMax=4096",
                "--",
                "/usr/bin/bwrap",
                "--die-with-parent",
                "x"
            ]
        );
        // the sandbox's own environment and fds, stdin as the session has it
        assert_eq!(s.env[0], ("A".into(), "1".into()));
        assert!(
            s.env.iter().all(|(k, _)| k == "A"
                || k == "XDG_RUNTIME_DIR"
                || k == "DBUS_SESSION_BUS_ADDRESS")
        );
        assert!(!s.stdin_null);
        assert_eq!(s.pass_fds.len(), 1);
        assert_eq!(s.pass_fds[0].target, 5);
    }

    #[test]
    fn no_exit_file_is_no_exit() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_exit(d.path()), None);
        std::fs::write(d.path().join("exit"), "3\n").unwrap();
        assert_eq!(read_exit(d.path()), Some(3));
    }
}
