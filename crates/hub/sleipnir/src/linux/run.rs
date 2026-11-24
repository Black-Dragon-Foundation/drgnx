//! Running the tools a runner asks (systemctl, podman, git, loginctl): stdin closed, output captured, a time limit
//! ([`crate::tool`]), and systemctl as the user's manager.

pub use crate::tool::{Output, limited, spec};
use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

/// How long one systemctl call may take.
pub const SYSTEMCTL_LIMIT: Duration = Duration::from_secs(30);

/// `systemctl --user --no-ask-password ARGS`: never a prompt, whoever calls.
pub fn systemctl<S: AsRef<OsStr>>(args: &[S]) -> villa::Result<Output> {
    let mut all: Vec<&OsStr> = vec![OsStr::new("--user"), OsStr::new("--no-ask-password")];
    all.extend(args.iter().map(AsRef::as_ref));
    limited(Path::new("systemctl"), &all, &[], SYSTEMCTL_LIMIT)
}

/// [`systemctl`], and its stderr as the error when it fails.
pub fn systemctl_ok<S: AsRef<OsStr>>(args: &[S]) -> villa::Result<String> {
    let out = systemctl(args)?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let said: Vec<String> = args
            .iter()
            .map(|a| a.as_ref().to_string_lossy().into_owned())
            .collect();
        Err(villa::Error::io(format!(
            "systemctl --user {}: {}",
            said.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}
