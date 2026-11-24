//! The programs the rows start (ssh, git, cat, sleep, podman, the binary under test), through `draugr`: a row's child gets
//! the row's own environment with what the row sets over it, and its streams as the row says.

#![allow(dead_code)]

use draugr::{Opts, Output, Redirect, Spec};
use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::process::Child;
use std::time::Duration;

/// How long a row waits for a program that runs to its end.
const RUN_LIMIT: Duration = Duration::from_secs(600);

/// The row's own environment with EXTRA set over it (a name in EXTRA replaces the row's).
pub fn env_with(extra: &[(&str, &OsStr)]) -> Vec<(OsString, OsString)> {
    let mut env: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(k, _)| !extra.iter().any(|(n, _)| k == n))
        .collect();
    env.extend(
        extra
            .iter()
            .map(|(k, v)| (OsString::from(k), v.to_os_string())),
    );
    env
}

/// PROGRAM ARGS with the row's environment and EXTRA over it, stdin closed.
pub fn spec<S: AsRef<OsStr>>(
    program: impl AsRef<Path>,
    args: &[S],
    extra: &[(&str, &OsStr)],
) -> Spec {
    Spec {
        program: program.as_ref().to_path_buf(),
        args: args.iter().map(|a| a.as_ref().to_os_string()).collect(),
        env: env_with(extra),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    }
}

/// SPEC started as a std child: stdin a pipe when STDIN, stdout and stderr as OUT and ERR say.
pub fn start(spec: &Spec, stdin: bool, out: Redirect, err: Redirect) -> Child {
    let mut spec = spec.clone();
    spec.stdin_null = !stdin;
    let opts = Opts {
        stdout: out,
        stderr: err,
        ..Opts::default()
    };
    draugr::spawn_std(&spec, &opts).unwrap_or_else(|e| panic!("{}: {e}", spec.program.display()))
}

/// SPEC run to its end: its status, its stdout and the tail of its stderr.
pub fn run(spec: Spec) -> Output {
    let name = spec.program.display().to_string();
    draugr::run(spec, RUN_LIMIT).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// SPEC run to its end with INPUT on its stdin.
pub fn run_with_input(mut spec: Spec, input: &[u8]) -> Output {
    spec.stdin_null = false;
    let name = spec.program.display().to_string();
    draugr::run_with_input(spec, input.to_vec(), RUN_LIMIT)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
}
