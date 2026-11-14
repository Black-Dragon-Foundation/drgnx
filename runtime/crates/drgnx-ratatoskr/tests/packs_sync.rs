//! `ratatoskr packs sync --plan` (language packs Task 2b): the plan's grammars are fetched, hash-checked, built and
//! load-checked in a child of the same binary, and the answer is an `.eld` plist. The fixture grammar is skald's
//! vendored tree-sitter-json in a throwaway git repository.
//!
//! test-pattern: pure (D).

use std::path::{Path, PathBuf};
use std::process::Command;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_ratatoskr")
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}");
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let (src, dst) = (e.path(), to.join(e.file_name()));
        if e.file_type().unwrap().is_dir() {
            copy_dir(&src, &dst);
        } else {
            std::fs::copy(&src, &dst).unwrap();
        }
    }
}

/// The fixture repository: (folder, commit).
fn repo(root: &Path) -> (PathBuf, String) {
    let repo = root.join("repo");
    copy_dir(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("../skald/tests/fixtures/json-grammar"),
        &repo.join("src"),
    );
    git(&repo, &["init", "-q"]);
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "json"]);
    let commit = git(&repo, &["rev-parse", "HEAD"]);
    (repo, commit)
}

fn plan(root: &Path, repo: &Path, commit: &str, tree: &str, query: &str) -> PathBuf {
    let q = root.join("tags.scm");
    std::fs::write(&q, query).unwrap();
    let p = root.join("plan.eld");
    std::fs::write(
        &p,
        format!(
            "(:version 1 :staging \"{}\" :min-abi 14\n :units ((:name \"json\" :repo \"{}\" :commit \"{commit}\" :tree-sha256 \"{tree}\"))\n :queries ((:grammar \"json\" :file \"queries/tags.scm\" :path \"{}\")))",
            root.join("staging").display(),
            repo.display(),
            q.display()
        ),
    )
    .unwrap();
    p
}

fn sync(plan: &Path) -> (i32, String) {
    let out = plan.with_extension("out");
    let status = Command::new(bin())
        .args(["packs", "sync", "--plan"])
        .arg(plan)
        .arg("--out")
        .arg(&out)
        .status()
        .unwrap();
    (
        status.code().unwrap(),
        std::fs::read_to_string(out).unwrap(),
    )
}

/// The tree hash by `skald`, the way the job computes it.
fn tree(repo: &Path) -> String {
    skald::job::tree_hash(repo).unwrap()
}

#[test]
fn a_plan_stages_the_grammar_and_answers_in_eld() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit) = repo(d.path());
    let (code, answer) = sync(&plan(
        d.path(),
        &repo,
        &commit,
        &tree(&repo),
        "(object) @definition.module",
    ));
    assert_eq!(code, 0, "{answer}");
    assert!(
        answer.starts_with("(:ok t :staged ((:name \"json\""),
        "{answer}"
    );
    assert!(
        answer.contains(&format!("grammars/json/{commit}/libtree-sitter-json.so")),
        "{answer}"
    );
    assert!(answer.contains(":abi 14"), "{answer}");
    assert!(
        d.path()
            .join(format!("staging/grammars/json/{commit}"))
            .is_dir()
    );
}

#[test]
fn a_wrong_hash_or_query_answers_not_ok_and_stages_nothing() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit) = repo(d.path());
    let (code, answer) = sync(&plan(d.path(), &repo, &commit, &"0".repeat(64), ""));
    assert_eq!(code, 1);
    assert!(
        answer.starts_with("(:ok nil :error \"the json tree hash"),
        "{answer}"
    );
    assert!(!d.path().join("staging/grammars").exists());
    let (code, answer) = sync(&plan(
        d.path(),
        &repo,
        &commit,
        &tree(&repo),
        "(no_such_node) @x",
    ));
    assert_eq!(code, 1);
    assert!(
        answer.contains("queries/tags.scm") && answer.contains("no_such_node"),
        "{answer}"
    );
    assert!(!d.path().join("staging/grammars").exists());
}

#[test]
fn a_bad_plan_is_an_error_answer() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("plan.eld");
    std::fs::write(&p, "(:version 1 :staging \"/x\" :bogus 1)").unwrap();
    let (code, answer) = sync(&p);
    assert_eq!(code, 1);
    assert!(answer.contains("bogus"), "{answer}");
}

#[test]
fn load_check_answers_one_line_and_a_crash_is_the_childs() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit) = repo(d.path());
    let (code, _) = sync(&plan(d.path(), &repo, &commit, &tree(&repo), ""));
    assert_eq!(code, 0);
    let lib = d.path().join(format!(
        "staging/grammars/json/{commit}/libtree-sitter-json.so"
    ));
    let out = Command::new(bin())
        .args(["packs", "load-check"])
        .arg(&lib)
        .args(["json", "14"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "ok 14");
    let out = Command::new(bin())
        .args(["packs", "load-check"])
        .arg(&lib)
        .args(["json", "15"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "abi 14 15");
    // a file that is no library is a load answer, not a crash
    let junk = d.path().join("junk.so");
    std::fs::write(&junk, "not a library").unwrap();
    let out = Command::new(bin())
        .args(["packs", "load-check"])
        .arg(&junk)
        .args(["json", "14"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(4));
    assert!(String::from_utf8_lossy(&out.stdout).starts_with("load "));
}

#[test]
fn pin_prints_a_grammar_entry_and_refuses_a_commit_without_a_parser() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit) = repo(d.path());
    let out = Command::new(bin())
        .args(["packs", "pin"])
        .arg(&repo)
        .arg(&commit)
        .output()
        .unwrap();
    let line = String::from_utf8_lossy(&out.stdout).to_string();
    assert!(out.status.success(), "{line}");
    assert!(
        line.contains(&format!(
            ":commit \"{commit}\" :tree-sha256 \"{}\"",
            tree(&repo)
        )),
        "{line}"
    );
    assert!(line.trim_end().ends_with("; ABI 14"), "{line}");
    let out = Command::new(bin())
        .args(["packs", "pin"])
        .arg(&repo)
        .arg(&commit)
        .args(["--src", "elsewhere"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("parser.c"));
}
