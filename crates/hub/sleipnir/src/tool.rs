//! Running a tool a runner asks (systemctl, podman, git, loginctl, id): stdin closed, output captured, a time limit,
//! and an environment of its own, through `draugr`.

use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::process::ExitStatus;
use std::time::Duration;

/// What a tool printed and how it ended: its stdout, and the tail of its stderr.
#[derive(Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// The variables a tool is given from the runner's own environment: where to find programs and the user's session
/// bus and runtime folder (`systemctl --user`, rootless podman), and the locale.
const PASSED: [&str; 8] = [
    "PATH",
    stig::HOME_VAR,
    stig::SYSTEM_RUNTIME_VAR,
    "DBUS_SESSION_BUS_ADDRESS",
    "USER",
    "LOGNAME",
    "LANG",
    "TMPDIR",
];

/// The environment of a tool: [`PASSED`] and the locale from this process's, then ENV.
pub fn tool_env(env: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    let set: Vec<(&str, &OsStr)> = env.iter().map(|(k, v)| (*k, OsStr::new(*v))).collect();
    draugr::env::build(&PASSED, &["LC_"], &set)
}

/// A [`draugr::Spec`] for PROGRAM ARGS with ENV added to [`tool_env`] and stdin closed.
pub fn spec<S: AsRef<OsStr>>(program: &Path, args: &[S], env: &[(&str, &str)]) -> draugr::Spec {
    draugr::Spec {
        program: program.to_path_buf(),
        args: args.iter().map(|a| a.as_ref().to_os_string()).collect(),
        env: tool_env(env),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    }
}

/// Runs PROGRAM ARGS with ENV added; kills it and says so when it outlives LIMIT. The error names the program.
pub fn limited<S: AsRef<OsStr>>(
    program: &Path,
    args: &[S],
    env: &[(&str, &str)],
    limit: Duration,
) -> villa::Result<Output> {
    let name = program.display().to_string();
    match draugr::run(spec(program, args, env), limit) {
        Ok(o) => Ok(Output {
            status: o.status,
            stdout: o.stdout,
            stderr: o.stderr.into_bytes(),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::TimedOut => Err(villa::Error::timeout(format!(
            "{name} took longer than {}s",
            limit.as_secs()
        ))
        .with_source(e)),
        Err(e) => Err(villa::Error::from(e).with_detail(format!("running {name}"))),
    }
}
