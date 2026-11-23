//! The children Hrafn starts (git, and the text searchers of `grep`), through draugr: an explicit environment, a
//! process group of their own and a deadline.

use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::time::Duration;

/// The longest a git call may take on the largest tree before its group is killed.
pub(crate) const GIT_DEADLINE: Duration = Duration::from_secs(600);

/// The most bytes of a small text file Hrafn reads for its own use (an ignore file, git's HEAD and refs).
pub(crate) const TEXT_CAP: u64 = 4 << 20;

/// The most bytes of git's `packed-refs` Hrafn reads (a repository with a million refs has about 80 MB).
pub(crate) const PACKED_REFS_CAP: u64 = 256 << 20;

/// What a child may see of the hub's environment.
fn env() -> Vec<(OsString, OsString)> {
    draugr::env::build(
        &[
            "PATH",
            stig::HOME_VAR,
            stig::Xdg::Config.var(),
            "LANG",
            "LC_ALL",
            "TMPDIR",
        ],
        &["GIT_"],
        &[("GIT_OPTIONAL_LOCKS", "0".as_ref())],
    )
}

/// PROGRAM with ARGS, started in CWD; its stdin is a pipe when `piped_stdin`, else `/dev/null`.
pub(crate) fn spec(
    program: &str,
    args: Vec<OsString>,
    cwd: Option<&Path>,
    piped_stdin: bool,
) -> draugr::Spec {
    draugr::Spec {
        program: program.into(),
        args,
        env: env(),
        cwd: cwd.map(Path::to_path_buf),
        stdin_null: !piped_stdin,
        pass_fds: vec![],
        new_session: false,
    }
}

/// `git ARGS` in ROOT (`git -C`), INPUT on its stdin, run to its end: its stdout, its exit status and the tail of its
/// stderr. Run on a thread of its own: the callers are often on a task of the hub's runtime, where a second runtime
/// cannot be started (the call blocked there before, too).
pub(crate) fn git(root: &Path, args: &[&str], input: Vec<u8>) -> io::Result<draugr::Output> {
    let mut all: Vec<OsString> = vec!["-C".into(), root.into()];
    all.extend(args.iter().map(OsString::from));
    let spec = spec("git", all, None, true);
    saman::spawn_thread("hrafn-git", move || {
        draugr::run_with_input(spec, input, GIT_DEADLINE)
    })
    .map_err(io::Error::other)?
    .join()
    .map_err(|_| io::Error::other("the git thread panicked"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A child sees the names git and the tools need, and nothing else of the hub's environment (its tokens).
    #[test]
    fn a_child_sees_only_the_allowed_names() {
        let names: Vec<String> = env()
            .into_iter()
            .map(|(k, _)| k.to_string_lossy().into_owned())
            .collect();
        let allowed = [
            "PATH",
            stig::HOME_VAR,
            stig::Xdg::Config.var(),
            "LANG",
            "LC_ALL",
            "TMPDIR",
        ];
        for n in &names {
            assert!(
                allowed.contains(&n.as_str()) || n.starts_with("GIT_"),
                "{n} reaches a child"
            );
        }
        assert!(names.iter().any(|n| n == "GIT_OPTIONAL_LOCKS"), "{names:?}");
    }

    #[test]
    fn git_runs_with_input_and_reports_its_failure_text() {
        let dir = tempfile::tempdir().unwrap();
        let out = git(dir.path(), &["hash-object", "--stdin"], b"abc".to_vec()).unwrap();
        assert!(out.status.success(), "{}", out.stderr);
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"
        );
        let bad = git(dir.path(), &["no-such-command"], Vec::new()).unwrap();
        assert!(!bad.status.success());
        assert!(bad.stderr.contains("no-such-command"), "{}", bad.stderr);
    }
}
