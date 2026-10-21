//! The git runner against real repositories: planted hooks never run, and a repository whose git dir, common dir or
//! config lies in a ledger folder is refused. Needs `/usr/bin/git` (root-owned, as in the build container); on
//! macOS, xcode-select naming the Command Line Tools (Xcode under `/Applications` is refused; CI selects the CLT).

use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;

use draugr::git::{GitCall, GitRefusal, Place, check_trusted_repo, command, git_program};
use eitri::FsError;

/// A temporary root with no link in its path (macOS's `/var` is one), so eitri's opens accept it.
fn root() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::Builder::new().prefix("glp-").tempdir().unwrap();
    let path = fs::canonicalize(dir.path()).unwrap();
    (dir, path)
}

/// git for the fixtures themselves: no overrides, no system config, `HOME` in the temporary root.
fn plain_git(home: &Path, cwd: &Path, args: &[&str]) {
    let st = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

/// git through `command`, from `git_program`.
fn runner_git(home: &Path, cwd: &Path, args: &[&str]) {
    let (argv, env) = command(&GitCall {
        place: Place::Trusted { read_only: false },
        allow_protocols: vec!["file"],
        args: args.iter().map(OsString::from).collect(),
    })
    .unwrap();
    let st = Command::new(git_program().unwrap().path)
        .args(argv)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .envs(env)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A repository with one commit, a branch `b`, a post-checkout hook and an fsmonitor hook, each appending to
/// `canary`.
fn planted_repo(home: &Path, name: &str, canary: &Path) -> PathBuf {
    let repo = home.join(name);
    plain_git(
        home,
        home,
        &["-c", "init.defaultBranch=main", "init", "-q", name],
    );
    fs::write(repo.join("a"), "a\n").unwrap();
    plain_git(home, &repo, &["add", "a"]);
    plain_git(
        home,
        &repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "one",
        ],
    );
    plain_git(home, &repo, &["branch", "b"]);
    let c = canary.display();
    script(
        &repo.join(".git/hooks/post-checkout"),
        &format!("echo hook >> '{c}'"),
    );
    let fsmon = home.join(format!("{name}-fsmonitor"));
    script(&fsmon, &format!("echo fsmonitor >> '{c}'; exit 1"));
    plain_git(
        home,
        &repo,
        &["config", "core.fsmonitor", fsmon.to_str().unwrap()],
    );
    repo
}

#[test]
fn a_planted_fsmonitor_and_hook_never_run() {
    let (_dir, home) = root();
    // The control: plain git runs both.
    let canary = home.join("canary-control");
    let repo = planted_repo(&home, "control", &canary);
    plain_git(&home, &repo, &["status"]);
    plain_git(&home, &repo, &["checkout", "-q", "b"]);
    let ran = fs::read_to_string(&canary).unwrap_or_default();
    assert!(
        ran.contains("fsmonitor") && ran.contains("hook"),
        "control: {ran:?}"
    );

    let canary = home.join("canary");
    let repo = planted_repo(&home, "repo", &canary);
    runner_git(&home, &repo, &["status"]);
    runner_git(&home, &repo, &["checkout", "-q", "b"]);
    assert!(
        !canary.exists(),
        "{:?}",
        fs::read_to_string(&canary).unwrap_or_default()
    );
}

/// A bare-looking git dir: just a directory with a `config` file.
fn git_dir(path: &Path) {
    fs::create_dir_all(path).unwrap();
    fs::write(path.join("config"), "[core]\n").unwrap();
}

fn refused_in_ledger(r: Result<(), GitRefusal>) -> PathBuf {
    match r {
        Err(GitRefusal::InLedger { path }) => path,
        other => panic!("expected InLedger, got {other:?}"),
    }
}

#[test]
fn a_gitdir_file_into_a_ledger_folder_is_refused() {
    let (_dir, t) = root();
    let ledger = t.join("ledger");
    git_dir(&ledger.join("gd"));
    let in_ledger = |p: &Path| p == ledger;
    for line in [
        format!("gitdir: {}\n", ledger.join("gd").display()),
        "gitdir: ../ledger/gd\n".to_string(),
        "gitdir: ../repo/../ledger/gd".to_string(),
    ] {
        let repo = t.join("repo");
        fs::create_dir_all(&repo).unwrap();
        fs::write(repo.join(".git"), &line).unwrap();
        // The control: with no ledger folder, the same repository passes.
        check_trusted_repo(&repo, &|_| false).unwrap_or_else(|e| panic!("{line}: {e}"));
        assert_eq!(
            refused_in_ledger(check_trusted_repo(&repo, &in_ledger)),
            ledger.join("gd"),
            "{line}"
        );
    }
    // A `.git` directory inside a ledger folder.
    let repo = ledger.join("own");
    git_dir(&repo.join(".git"));
    check_trusted_repo(&repo, &|_| false).unwrap();
    assert_eq!(
        refused_in_ledger(check_trusted_repo(&repo, &in_ledger)),
        repo.join(".git")
    );
}

#[test]
fn a_commondir_in_a_ledger_folder_is_refused() {
    let (_dir, t) = root();
    let ledger = t.join("ledger");
    git_dir(&ledger.join("common"));
    let gd = t.join("outside/gd");
    git_dir(&gd);
    for line in [
        format!("{}\n", ledger.join("common").display()),
        "../../ledger/common\n".to_string(),
    ] {
        fs::write(gd.join("commondir"), &line).unwrap();
        let repo = t.join("repo");
        fs::create_dir_all(&repo).unwrap();
        fs::write(repo.join(".git"), format!("gitdir: {}\n", gd.display())).unwrap();
        check_trusted_repo(&repo, &|_| false).unwrap_or_else(|e| panic!("{line}: {e}"));
        assert_eq!(
            refused_in_ledger(check_trusted_repo(&repo, &|p: &Path| p == ledger)),
            ledger.join("common"),
            "{line}"
        );
    }
}

#[test]
fn a_real_worktree_passes_and_its_main_repository_in_a_ledger_is_refused() {
    let (_dir, home) = root();
    let canary = home.join("canary");
    let main = planted_repo(&home, "main", &canary);
    plain_git(&home, &main, &["worktree", "add", "-q", "../wt", "b"]);
    let wt = home.join("wt");
    // The worktree's own folder in the ledger: its git dir is in the main repository, which passes.
    check_trusted_repo(&wt, &|p: &Path| p == wt).unwrap();
    // The main repository in the ledger: the worktree's git dir lies inside it.
    assert_eq!(
        refused_in_ledger(check_trusted_repo(&wt, &|p: &Path| p == main)),
        main.join(".git/worktrees/wt")
    );
}

#[test]
fn links_in_the_git_metadata_are_refused() {
    let (_dir, t) = root();
    let ledger = t.join("ledger");
    git_dir(&ledger);
    // `config` a link (it could point into a ledger folder).
    let gd = t.join("gd");
    fs::create_dir_all(&gd).unwrap();
    symlink(ledger.join("config"), gd.join("config")).unwrap();
    let repo = t.join("repo");
    fs::create_dir_all(&repo).unwrap();
    fs::write(repo.join(".git"), format!("gitdir: {}\n", gd.display())).unwrap();
    assert!(
        matches!(
            check_trusted_repo(&repo, &|_| false),
            Err(GitRefusal::Fs {
                err: FsError::Link { .. },
                ..
            })
        ),
        "{:?}",
        check_trusted_repo(&repo, &|_| false)
    );
    // A worktree's `config.worktree` a link.
    fs::remove_file(gd.join("config")).unwrap();
    fs::write(gd.join("config"), "[core]\n").unwrap();
    check_trusted_repo(&repo, &|_| false).unwrap();
    fs::create_dir_all(gd.join("worktrees/w")).unwrap();
    symlink(
        ledger.join("config"),
        gd.join("worktrees/w/config.worktree"),
    )
    .unwrap();
    assert!(matches!(
        check_trusted_repo(&repo, &|_| false),
        Err(GitRefusal::Fs {
            err: FsError::Link { .. },
            ..
        })
    ));
    // `worktrees` itself a link, then `commondir` a link: neither is read as absent.
    fs::remove_dir_all(gd.join("worktrees")).unwrap();
    check_trusted_repo(&repo, &|_| false).unwrap();
    fs::create_dir_all(ledger.join("wts")).unwrap();
    symlink(ledger.join("wts"), gd.join("worktrees")).unwrap();
    assert!(matches!(
        check_trusted_repo(&repo, &|_| false),
        Err(GitRefusal::Fs {
            err: FsError::Link { .. },
            ..
        })
    ));
    fs::remove_file(gd.join("worktrees")).unwrap();
    fs::write(ledger.join("commondir"), "../gd\n").unwrap();
    symlink(ledger.join("commondir"), gd.join("commondir")).unwrap();
    assert!(matches!(
        check_trusted_repo(&repo, &|_| false),
        Err(GitRefusal::Fs {
            err: FsError::Link { .. },
            ..
        })
    ));
    // `.git` itself a link.
    let repo2 = t.join("repo2");
    fs::create_dir_all(&repo2).unwrap();
    symlink(&gd, repo2.join(".git")).unwrap();
    assert!(matches!(
        check_trusted_repo(&repo2, &|_| false),
        Err(GitRefusal::Fs {
            err: FsError::Link { .. },
            ..
        })
    ));
}

#[test]
fn a_tramp_looking_gitdir_is_just_a_missing_path() {
    let (_dir, t) = root();
    let repo = t.join("repo");
    fs::create_dir_all(&repo).unwrap();
    fs::write(repo.join(".git"), "gitdir: /ssh:canary:/x\n").unwrap();
    match check_trusted_repo(&repo, &|_| false) {
        Err(GitRefusal::Fs {
            path,
            err: FsError::Io(e),
        }) => {
            assert_eq!(path, Path::new("/ssh:canary:/x"));
            assert_eq!(e.kind(), std::io::ErrorKind::NotFound);
        }
        other => panic!("{other:?}"),
    }
    // A `.git` file without a `gitdir:` line, and an empty one.
    for text in ["", "gitdir:\n", "worktree: /x\n"] {
        fs::write(repo.join(".git"), text).unwrap();
        assert!(
            matches!(
                check_trusted_repo(&repo, &|_| false),
                Err(GitRefusal::Malformed { .. })
            ),
            "{text:?}"
        );
    }
}
