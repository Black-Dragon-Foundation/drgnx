//! Running the tools a runner asks (systemctl, podman, git, loginctl): stdin closed, output captured, a time limit.

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Runs PROGRAM ARGS with ENV added; kills it and says so when it outlives LIMIT. The error names the program.
pub fn limited<S: AsRef<OsStr>>(
    program: &Path,
    args: &[S],
    env: &[(&str, &str)],
    limit: Duration,
) -> Result<Output, String> {
    let name = program.display().to_string();
    let mut cmd = Command::new(program);
    cmd.args(args)
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("{name}: {e}"))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| format!("{name}: {e}")),
            Ok(None) if start.elapsed() < limit => std::thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{name} took longer than {}s", limit.as_secs()));
            }
            Err(e) => return Err(format!("{name}: {e}")),
        }
    }
}

/// How long one systemctl call may take.
pub const SYSTEMCTL_LIMIT: Duration = Duration::from_secs(30);

/// `systemctl --user --no-ask-password ARGS`: never a prompt, whoever calls.
pub fn systemctl<S: AsRef<OsStr>>(args: &[S]) -> Result<Output, String> {
    let mut all: Vec<&OsStr> = vec![OsStr::new("--user"), OsStr::new("--no-ask-password")];
    all.extend(args.iter().map(AsRef::as_ref));
    limited(Path::new("systemctl"), &all, &[], SYSTEMCTL_LIMIT)
}

/// [`systemctl`], and its stderr as the error when it fails.
pub fn systemctl_ok<S: AsRef<OsStr>>(args: &[S]) -> Result<String, String> {
    let out = systemctl(args)?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let said: Vec<String> = args
            .iter()
            .map(|a| a.as_ref().to_string_lossy().into_owned())
            .collect();
        Err(format!(
            "systemctl --user {}: {}",
            said.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}
