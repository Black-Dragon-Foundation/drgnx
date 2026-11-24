use super::*;

/// Run the shell SCRIPT in DIR (a fresh repository's git config names its author), panicking on failure.
fn sh(dir: &Path, script: &str) {
    let out = crate::proc::Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A repository in a new folder of TMP called NAME with one commit of a.txt and b.txt.
fn repo(tmp: &Path, name: &str) -> PathBuf {
    let d = tmp.join(name);
    std::fs::create_dir_all(&d).unwrap();
    sh(
        &d,
        "git init -q -b main && git config user.name t && git config user.email t@example.com \
         && git config commit.gpgsign false && printf 'one\\n' > a.txt && printf 'two\\n' > b.txt \
         && git add . && git commit -q -m init",
    );
    d
}

/// [D] A commit with nothing staged is git's refusal, its text the error; the message goes on stdin, and the
/// repository's own pre-commit hook runs (the user's commit, unlike draugr's reads, keeps the hooks).
#[test]
fn commit_takes_the_message_on_stdin_and_runs_the_hooks() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    let none = run::git(
        &r,
        As::User,
        &["commit", "-q", "-F", "-"],
        Some(b"nothing"),
        Some(LOCAL),
        None,
    );
    assert!(none.is_err());
    sh(
        &r,
        "printf '#!/bin/sh\\necho ran > .git/hook-ran\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit \
         && printf 'x\\n' >> a.txt && git add a.txt",
    );
    run::git(
        &r,
        As::User,
        &["commit", "-q", "-F", "-"],
        Some("subject\n\nbody".as_bytes()),
        Some(LOCAL),
        None,
    )
    .unwrap();
    assert!(r.join(".git/hook-ran").exists(), "the pre-commit hook ran");
    let log = run::git(
        &r,
        As::Reader,
        &["log", "-1", "--format=%B"],
        None,
        Some(LOCAL),
        None,
    )
    .unwrap();
    assert_eq!(String::from_utf8_lossy(&log).trim(), "subject\n\nbody");
}

/// [D] A git that outlives its deadline is stopped with its group and says so; a cancelled one says `stopped`.
#[test]
fn deadline_and_cancel_stop_a_hung_git() {
    let tmp = tempfile::tempdir().unwrap();
    let mut c = crate::proc::Command::new("/bin/sh");
    c.args(["-c", "sleep 30"]);
    // the deadline stopped it: the command would run 30 s, and the error says it was cut at the deadline
    let e = run::run(c, tmp.path(), None, Some(Duration::from_millis(200)), None).unwrap_err();
    assert!(e.message().contains("longer than"), "{e}");
    // a cancel already set: the run stops at its first look instead of running the 30 s
    let cancel = Arc::new(AtomicBool::new(true));
    let mut c = crate::proc::Command::new("/bin/sh");
    c.args(["-c", "sleep 30"]);
    assert_eq!(
        run::run(c, tmp.path(), None, None, Some(&cancel))
            .unwrap_err()
            .kind(),
        villa::Kind::Cancelled
    );
}

/// [D] The branch picker's list: local branches first (the current one marked), then remote ones without
/// `origin/HEAD`.
#[test]
fn branches_local_then_remote() {
    let out = "refs/heads/main\x001700\x00*\nrefs/remotes/origin/HEAD\x001700\x00 \n\
               refs/remotes/origin/main\x001600\x00 \nrefs/heads/dev\x001500\x00 \n";
    let b = parse_branches(out.as_bytes());
    let names: Vec<(&str, bool, bool)> = b
        .iter()
        .map(|b| (b.name.as_str(), b.remote, b.current))
        .collect();
    assert_eq!(
        names,
        [
            ("main", false, true),
            ("dev", false, false),
            ("origin/main", true, false)
        ]
    );
}

/// [D] A commit answers its sha, with the message on stdin and `all` staging first.
#[test]
fn commit_answers_the_sha_of_the_commit_it_made() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let r = repo(tmp.path(), "app");
        sh(&r, "printf 'edited\\n' > a.txt");
        let p: Commit = serde_json::from_value(serde_json::json!({
            "root": r.to_string_lossy(), "message": "edit a", "all": true
        }))
        .unwrap();
        let done = commit_quiet(&r, &p).await.unwrap();
        let head = run::git(
            &r,
            As::Reader,
            &["rev-parse", "HEAD"],
            None,
            Some(LOCAL),
            None,
        )
        .unwrap();
        assert_eq!(done.sha, String::from_utf8_lossy(&head).trim());
    })
}
