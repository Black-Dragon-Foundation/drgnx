//! The grammar registry (language packs Task 6a): the libraries a lock names, checked and loaded once, and a reason
//! when one is not available. A fixture grammar (tree-sitter-json, vendored) is built by the pack job.

use std::path::{Path, PathBuf};
use std::process::Command;

use skald::job::{Options, Unit, run, tree_hash};
use skald::registry::{Entry, from_lock, install, install_from, language, status};

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
    assert!(out.status.success(), "git {args:?}");
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// The fixture built by the pack job: (the data folder's `grammars/`, the lock text naming it).
fn built(root: &Path) -> (PathBuf, String) {
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
    let unit = Unit {
        name: "json".into(),
        repo: repo.display().to_string(),
        commit: commit.clone(),
        tree_sha256: tree,
        src: "src".into(),
    };
    let opts = Options::new(root.join("staging"), 14);
    let staged = run(&[unit], &[], &opts).unwrap();
    let s = &staged[0];
    let grammars = root.join("data/grammars");
    let dir = grammars.join("json").join(&commit);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::copy(&s.lib, dir.join(s.lib.file_name().unwrap())).unwrap();
    let lock = format!(
        "(:version 1 :packages nil :grammars ((json :commit \"{commit}\" :lib-sha256 \"{}\")))",
        s.lib_sha256
    );
    (grammars, lock)
}

/// One test: the registry is process-wide.
#[test]
fn the_registry_loads_what_the_lock_names_and_says_why_it_cannot_otherwise() {
    let dir = tempfile::tempdir().unwrap();
    let (grammars, lock) = built(dir.path());

    // nothing installed: a reason, no panic
    let e = language("json").unwrap_err();
    assert!(e.reason.contains("lock does not name"), "{e}");

    // the lock's grammars load, parse and are the same language the second time
    let lock_file = dir.path().join("drgnx.lock.eld");
    std::fs::write(&lock_file, &lock).unwrap();
    assert_eq!(install_from(&lock_file, &grammars).unwrap(), 1);
    let l = language("json").unwrap();
    let mut p = tree_sitter::Parser::new();
    p.set_language(&l).unwrap();
    assert!(
        !p.parse("{\"a\": [1, 2]}", None)
            .unwrap()
            .root_node()
            .has_error()
    );
    assert_eq!(language("json").unwrap(), l);
    assert_eq!(status().len(), 1);

    // a library that does not match the lock's hash is refused, and an absent one says where it should be
    let mut entries = from_lock(lock.as_bytes(), &grammars).unwrap();
    assert_eq!(entries.len(), 1);
    entries[0].sha256 = "0".repeat(64);
    install(entries.clone());
    let e = language("json").unwrap_err();
    assert!(e.reason.contains("hash"), "{e}");
    entries[0] = Entry {
        lib: grammars.join("json/none/libtree-sitter-json.so"),
        ..entries[0].clone()
    };
    install(entries);
    assert!(
        language("json")
            .unwrap_err()
            .reason
            .contains("does not exist")
    );

    // a lock with no :grammars names none; a missing lock file too
    assert!(
        from_lock(b"(:version 1 :packages nil)", &grammars)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        install_from(&dir.path().join("none.eld"), &grammars).unwrap(),
        0
    );
}
