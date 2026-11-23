//! `cargo xtask wit-check` against a throwaway git repository: the file at the last tag against the file now.

use std::path::Path;
use std::process::Command;

const V1: &str = "package acme:api@0.1.0;\ninterface i {\n  f: func();\n}\nworld w { import i; }\n";

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.org",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .env("HOME", dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn check(dir: &Path) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_xtask"))
        .arg("wit-check")
        .arg("--root")
        .arg(dir)
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    )
}

fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let wit = dir.path().join("crates/ext/mal/drgnx.wit");
    std::fs::create_dir_all(wit.parent().unwrap()).unwrap();
    std::fs::write(&wit, V1).unwrap();
    git(dir.path(), &["init", "-q"]);
    git(dir.path(), &["add", "."]);
    git(dir.path(), &["commit", "-q", "-m", "api"]);
    git(dir.path(), &["tag", "api-v0.1.0"]);
    dir
}

#[test]
fn wit_check_reads_the_last_tag() {
    let dir = repo();
    let wit = dir.path().join("crates/ext/mal/drgnx.wit");
    let (code, out) = check(dir.path());
    assert_eq!(code, 0, "{out}");

    // an added function, no bump
    std::fs::write(&wit, V1.replace("f: func();", "f: func();\n  g: func();")).unwrap();
    let (code, out) = check(dir.path());
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("patch bump"), "{out}");

    // the bump
    let bumped = V1
        .replace("0.1.0", "0.1.1")
        .replace("f: func();", "f: func();\n  g: func();");
    std::fs::write(&wit, bumped).unwrap();
    let (code, out) = check(dir.path());
    assert_eq!(code, 0, "{out}");
}

#[test]
fn wit_check_passes_without_a_tag() {
    let dir = tempfile::tempdir().unwrap();
    let wit = dir.path().join("crates/ext/mal/drgnx.wit");
    std::fs::create_dir_all(wit.parent().unwrap()).unwrap();
    std::fs::write(&wit, V1).unwrap();
    git(dir.path(), &["init", "-q"]);
    let (code, out) = check(dir.path());
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("nothing to compare"), "{out}");
}

#[test]
fn wit_check_ignores_other_tags_and_fails_when_the_baseline_lacks_the_file() {
    // a tag that is not an API release tag is not a baseline: the check passes with nothing to compare
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("README"), "x").unwrap();
    git(dir.path(), &["init", "-q"]);
    git(dir.path(), &["add", "."]);
    git(dir.path(), &["commit", "-q", "-m", "first"]);
    git(dir.path(), &["tag", "v9.9.9"]);
    let wit = dir.path().join("crates/ext/mal/drgnx.wit");
    std::fs::create_dir_all(wit.parent().unwrap()).unwrap();
    std::fs::write(&wit, V1).unwrap();
    let (code, out) = check(dir.path());
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("no api-v* tag"), "{out}");
    // an API tag on a tree without the file fails closed
    git(dir.path(), &["tag", "api-v0.0.1"]);
    let (code, out) = check(dir.path());
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("the baseline must hold the API file"), "{out}");
}
