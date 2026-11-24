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
    tool_env_os(&set)
}

/// [`tool_env`] with values that are not text (paths).
pub fn tool_env_os(env: &[(&str, &OsStr)]) -> Vec<(OsString, OsString)> {
    draugr::env::build(&PASSED, &["LC_"], env)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of(extra: &[(&str, &str)]) -> String {
        let out = limited(
            Path::new("/usr/bin/env"),
            &[] as &[&str],
            extra,
            Duration::from_secs(30),
        )
        .unwrap();
        String::from_utf8(out.stdout).unwrap()
    }

    /// [D] A tool is given the passed variables, the locale and what the caller sets; any other variable of the runner's
    /// (a key's, a token's) never reaches it.
    #[test]
    fn a_variable_outside_the_passed_list_never_reaches_a_tool() {
        // SAFETY: nextest runs each test in a process of its own, and nothing else here reads the environment
        unsafe {
            std::env::set_var("OPENROUTER_API_KEY", "canary-secret");
            std::env::set_var("LC_ALL", "C.UTF-8");
        }
        let seen = env_of(&[("SLEIPNIR_TOOL_SET", "set")]);
        assert!(!seen.contains("canary-secret"), "{seen}");
        assert!(seen.lines().any(|l| l.starts_with("PATH=")), "{seen}");
        assert!(seen.contains("LC_ALL=C.UTF-8"), "{seen}");
        assert!(seen.contains("SLEIPNIR_TOOL_SET=set"), "{seen}");
    }

    /// [D] A tool that outlives its limit is killed with everything it started, and the error says it timed out.
    #[test]
    fn a_tool_over_its_limit_is_killed_with_its_whole_group() {
        let d = tempfile::tempdir().unwrap();
        let pid_file = d.path().join("grandchild.pid");
        let script = format!("sleep 600 & echo $! > {}; wait", pid_file.display());
        let e = limited(
            Path::new("/bin/sh"),
            &["-c", script.as_str()],
            &[],
            Duration::from_millis(500),
        )
        .unwrap_err();
        assert_eq!(e.kind(), villa::Kind::Timeout, "{e:?}");
        let pid: i32 = crate::fsio::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        skuld::wait_until("the grandchild is gone", 30, || {
            (!draugr::alive(pid)).then_some(())
        });
    }
}
