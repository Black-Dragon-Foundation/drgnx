//! The fixtures' git (and the few other programs a test runs), started through draugr like every child. A module of the
//! `it` binary, and of each test that needs a process of its own (`#[path = "gitfx.rs"] mod gitfx;`).

use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

/// A fixture command ends within this, or its group is killed.
const DEADLINE: Duration = Duration::from_secs(120);

/// PROGRAM with ARGS in DIR (a child of a thread of its own: some tests call this inside a runtime), with the
/// environment a fixture needs plus ENV.
pub fn run(
    program: &str,
    dir: Option<&Path>,
    args: &[&str],
    env: &[(&str, &str)],
    input: Vec<u8>,
) -> draugr::Output {
    let mut vars = draugr::env::build(
        &["PATH", stig::HOME_VAR, "LANG", "LC_ALL", "TMPDIR"],
        &["GIT_"],
        &[],
    );
    for (k, v) in env {
        vars.retain(|(name, _)| name != k);
        vars.push((OsString::from(k), OsString::from(v)));
    }
    let spec = draugr::Spec {
        program: program.into(),
        args: args.iter().map(OsString::from).collect(),
        env: vars,
        cwd: dir.map(Path::to_path_buf),
        stdin_null: false,
        pass_fds: vec![],
        new_session: false,
    };
    saman::spawn_thread("hrafn-fixture", move || {
        draugr::run_with_input(spec, input, DEADLINE)
    })
    .unwrap()
    .join()
    .unwrap()
    .unwrap_or_else(|e| panic!("{program}: {e}"))
}

/// `git -C DIR ARGS` as a test author (no signing), with ENV added and INPUT on stdin.
pub fn out_with(dir: &Path, args: &[&str], env: &[(&str, &str)], input: Vec<u8>) -> draugr::Output {
    let dir_text = dir.to_string_lossy();
    let mut all = vec![
        "-C",
        &dir_text,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
    ];
    all.extend_from_slice(args);
    run("git", None, &all, env, input)
}

/// `git -C DIR ARGS`.
pub fn out(dir: &Path, args: &[&str]) -> draugr::Output {
    out_with(dir, args, &[], Vec::new())
}

/// `git -C DIR ARGS`, which must succeed: its stdout, trimmed.
pub fn git(dir: &Path, args: &[&str]) -> String {
    let o = out(dir, args);
    assert!(o.status.success(), "git {args:?}: {}", o.stderr.trim());
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}
