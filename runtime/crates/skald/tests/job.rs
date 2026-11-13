//! The pack job (Task 2a): fetch a grammar at a commit, check its tree hash, build it for runtime, check that it loads
//! and its ABI, hash the library, compile the pack's queries against it, and stage the result. A fixture grammar
//! (tree-sitter-json, vendored, no scanner) in a throwaway git repo stands for a pack's repository.

use std::path::{Path, PathBuf};
use std::process::Command;

use skald::job::{JobError, Options, Query, Unit, load, run, tree_hash, verify_lib};

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
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// A repository holding the fixture grammar in `src/`: (its folder, its commit, its tree hash).
fn fixture_repo(root: &Path) -> (PathBuf, String, String) {
    let repo = root.join("repo");
    copy_dir(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/json-grammar"),
        &repo.join("src"),
    );
    git(&repo, &["init", "-q"]);
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "json"]);
    let commit = git(&repo, &["rev-parse", "HEAD"]);
    let tree = tree_hash(&repo).unwrap();
    (repo, commit, tree)
}

fn unit(repo: &Path, commit: &str, tree: &str) -> Unit {
    Unit {
        name: "json".into(),
        repo: repo.display().to_string(),
        commit: commit.into(),
        tree_sha256: tree.into(),
        src: "src".into(),
    }
}

fn opts(root: &Path, min_abi: u32) -> Options {
    Options {
        staging: root.join("staging"),
        min_abi,
    }
}

fn tags(text: &str) -> Vec<Query> {
    vec![Query {
        grammar: "json".into(),
        file: "queries/tags.scm".into(),
        text: text.into(),
    }]
}

#[test]
fn the_tree_hash_is_over_modes_paths_and_blob_hashes() {
    let d = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(d.path().join("a")).unwrap();
    std::fs::write(d.path().join("a/b.txt"), "hi\n").unwrap();
    std::fs::write(d.path().join("c.sh"), "x\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        d.path().join("c.sh"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    // a .git folder is not part of the tree
    std::fs::create_dir_all(d.path().join(".git")).unwrap();
    std::fs::write(d.path().join(".git/HEAD"), "ref").unwrap();
    assert_eq!(
        tree_hash(d.path()).unwrap(),
        "516c92587f97152e1089d58248b0bac1062d8b2203d1d64e2e51bb98d208facf"
    );
}

#[test]
fn a_symlink_in_the_tree_is_refused() {
    let d = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink("/etc/passwd", d.path().join("x")).unwrap();
    assert!(matches!(tree_hash(d.path()), Err(JobError::Tree(_))));
}

#[test]
fn a_fixture_grammar_builds_loads_and_stages() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit, tree) = fixture_repo(d.path());
    let staged = run(
        &[unit(&repo, &commit, &tree)],
        &tags("(object) @definition.module\n(pair key: (string) @name)"),
        &opts(d.path(), 14),
    )
    .unwrap();
    let s = &staged[0];
    assert_eq!(
        (s.name.as_str(), s.commit.as_str(), s.abi),
        ("json", commit.as_str(), 14)
    );
    assert_eq!(s.tree_sha256, tree);
    assert_eq!(
        s.lib,
        d.path().join(format!(
            "staging/grammars/json/{commit}/libtree-sitter-json.{}",
            skald::job::LIB_EXT
        ))
    );
    // the library hash is its file's, and the local load check passes on it and refuses any other
    assert_eq!(s.lib_sha256, skald::job::file_sha256(&s.lib).unwrap());
    assert_eq!(verify_lib(&s.lib, "json", &s.lib_sha256, 14).unwrap(), 14);
    assert!(matches!(
        verify_lib(&s.lib, "json", &"0".repeat(64), 14),
        Err(JobError::LibHash { .. })
    ));
    // it parses
    let (_lib, language) = load(&s.lib, "json").unwrap();
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language).unwrap();
    let t = parser.parse("{\"a\": [1, 2]}", None).unwrap();
    assert_eq!(t.root_node().kind(), "document");
    assert!(!t.root_node().has_error());
}

#[test]
fn a_wrong_tree_hash_changes_nothing() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit, _) = fixture_repo(d.path());
    let e = run(
        &[unit(&repo, &commit, &"0".repeat(64))],
        &[],
        &opts(d.path(), 14),
    )
    .unwrap_err();
    assert!(matches!(e, JobError::TreeHash { .. }), "{e}");
    assert!(!d.path().join("staging/grammars").exists());
}

#[test]
fn a_commit_the_repository_lacks_is_a_fetch_failure() {
    let d = tempfile::tempdir().unwrap();
    let (repo, _, tree) = fixture_repo(d.path());
    let e = run(
        &[unit(&repo, &"1".repeat(40), &tree)],
        &[],
        &opts(d.path(), 14),
    )
    .unwrap_err();
    assert!(matches!(e, JobError::Fetch(_)), "{e}");
    assert!(!d.path().join("staging/grammars").exists());
}

#[test]
fn a_query_naming_a_missing_node_fails_the_job() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit, tree) = fixture_repo(d.path());
    let e = run(
        &[unit(&repo, &commit, &tree)],
        &tags("(no_such_node) @x"),
        &opts(d.path(), 14),
    )
    .unwrap_err();
    match e {
        JobError::Query { file, message } => {
            assert_eq!(file, "queries/tags.scm");
            assert!(message.contains("no_such_node"), "{message}");
        }
        other => panic!("{other}"),
    }
    assert!(
        !d.path().join("staging/grammars").exists(),
        "a failed query stages nothing"
    );
}

#[test]
fn a_grammar_below_the_abi_floor_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit, tree) = fixture_repo(d.path());
    let e = run(&[unit(&repo, &commit, &tree)], &[], &opts(d.path(), 15)).unwrap_err();
    assert!(
        matches!(
            e,
            JobError::Abi {
                found: 14,
                min: 15,
                ..
            }
        ),
        "{e}"
    );
    assert!(!d.path().join("staging/grammars").exists());
}

#[test]
fn a_source_folder_without_a_parser_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let (repo, commit, tree) = fixture_repo(d.path());
    let mut u = unit(&repo, &commit, &tree);
    u.src = "nowhere".into();
    let e = run(&[u], &[], &opts(d.path(), 14)).unwrap_err();
    assert!(matches!(e, JobError::Build(_)), "{e}");
}
