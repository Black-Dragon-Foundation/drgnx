//! Temporary repositories, the real git.

use super::*;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "protocol.file.allow=always",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn write(dir: &Path, name: &str, text: &str) {
    let p = dir.join(name);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

/// A repository on `main` with one commit: a.txt, b.txt, c.txt, old.txt (four lines each) and an ignore rule.
fn repo() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    let p = d.path();
    git(p, &["init", "-q", "-b", "main"]);
    for f in ["a.txt", "b.txt", "c.txt", "old.txt"] {
        write(p, f, "one\ntwo\nthree\nfour\n");
    }
    write(p, ".gitignore", "*.log\n");
    git(p, &["add", "-A"]);
    git(p, &["commit", "-q", "-m", "base"]);
    d
}

fn names(l: &FileList) -> Vec<String> {
    l.files
        .iter()
        .map(|f| {
            f.strip_prefix(&l.top)
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect()
}

fn top(d: &tempfile::TempDir) -> PathBuf {
    d.path().canonicalize().unwrap()
}

#[test]
fn changed_lists_modified_added_and_untracked_counts_deleted_and_follows_renames() {
    let d = repo();
    let p = d.path();
    write(p, "a.txt", "one\nTWO\nthree\nfour\n"); // modified
    write(p, "new.txt", "new\n");
    git(p, &["add", "new.txt"]); // added
    write(p, "sub/untracked.txt", "u\n"); // untracked, in a folder
    write(p, "noise.log", "ignored\n");
    std::fs::remove_file(p.join("b.txt")).unwrap(); // deleted
    git(p, &["mv", "old.txt", "renamed.txt"]); // renamed
    let l = files(p, ScopeKind::Changed, None).unwrap();
    assert_eq!(l.top, top(&d));
    assert_eq!(
        names(&l),
        vec!["a.txt", "new.txt", "renamed.txt", "sub/untracked.txt"]
    );
    assert_eq!((l.deleted, l.submodules), (1, 0));
    assert_eq!(l.against.as_deref(), Some("HEAD"));
    assert!(l.new.contains(&l.top.join("sub/untracked.txt")));
    assert!(l.new.contains(&l.top.join("new.txt")));
    assert!(!l.new.contains(&l.top.join("a.txt")));
}

#[test]
fn staged_lists_only_what_the_index_changed() {
    let d = repo();
    let p = d.path();
    write(p, "a.txt", "one\nTWO\nthree\nfour\n");
    git(p, &["add", "a.txt"]);
    write(p, "a.txt", "one\nTWO\nthree\nFOUR\n"); // and unstaged on top
    write(p, "c.txt", "only in the tree\n");
    write(p, "untracked.txt", "u\n");
    let l = files(p, ScopeKind::Staged, None).unwrap();
    assert_eq!(names(&l), vec!["a.txt"]);
    assert_eq!(l.against, None);
    assert!(l.unstaged.contains(&l.top.join("a.txt")));
}

#[test]
fn an_empty_scope_says_why() {
    let d = repo();
    let l = files(d.path(), ScopeKind::Staged, None).unwrap();
    assert!(l.files.is_empty());
    assert!(l.why_empty.as_deref().unwrap().contains("staged"), "{l:?}");
    let l = files(d.path(), ScopeKind::Changed, None).unwrap();
    assert!(l.why_empty.is_some());
}

#[test]
fn branch_is_taken_against_the_merge_base_with_the_upstream() {
    let d = repo();
    let p = d.path();
    git(p, &["checkout", "-q", "-b", "feature"]);
    git(p, &["branch", "--set-upstream-to=main"]);
    write(p, "a.txt", "one\ntwo\nthree\nfour\nfive\n");
    git(p, &["commit", "-q", "-am", "on feature"]);
    git(p, &["checkout", "-q", "main"]);
    write(p, "c.txt", "changed on main after the fork\n");
    git(p, &["commit", "-q", "-am", "on main"]);
    git(p, &["checkout", "-q", "feature"]);
    write(p, "b.txt", "uncommitted\n"); // the working tree's changes count too
    write(p, "fresh.txt", "untracked\n");
    let l = files(p, ScopeKind::Branch, None).unwrap();
    assert_eq!(l.base.as_deref(), Some("main"));
    assert_eq!(names(&l), vec!["a.txt", "b.txt", "fresh.txt"]);
    let mb = git(p, &["merge-base", "HEAD", "main"]);
    assert_eq!(l.against.as_deref(), Some(mb.as_str()));
    // a chosen base wins
    let l = files(p, ScopeKind::Branch, Some("HEAD~1")).unwrap();
    assert_eq!(names(&l), vec!["a.txt", "b.txt", "fresh.txt"]);
}

#[test]
fn branch_with_no_upstream_main_or_master_asks() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path();
    git(p, &["init", "-q", "-b", "trunk"]);
    write(p, "a.txt", "a\n");
    git(p, &["add", "-A"]);
    git(p, &["commit", "-q", "-m", "x"]);
    assert!(matches!(
        files(p, ScopeKind::Branch, None),
        Err(ScopeError::NeedsBase(_))
    ));
    let b = bases(p).unwrap();
    assert_eq!(b.current.as_deref(), Some("trunk"));
    assert_eq!(
        (b.upstream.clone(), b.default.clone(), b.detached),
        (None, None, false)
    );
}

#[test]
fn branch_without_an_upstream_defaults_to_main() {
    let d = repo();
    let p = d.path();
    git(p, &["checkout", "-q", "-b", "topic"]);
    write(p, "c.txt", "topic\n");
    git(p, &["commit", "-q", "-am", "topic"]);
    let l = files(p, ScopeKind::Branch, None).unwrap();
    assert_eq!(l.base.as_deref(), Some("main"));
    assert_eq!(names(&l), vec!["c.txt"]);
}

#[test]
fn a_detached_head_asks_for_a_base_and_takes_a_chosen_one() {
    let d = repo();
    let p = d.path();
    write(p, "a.txt", "next\n");
    git(p, &["commit", "-q", "-am", "next"]);
    git(p, &["checkout", "-q", "--detach", "HEAD"]);
    assert!(matches!(
        files(p, ScopeKind::Branch, None),
        Err(ScopeError::NeedsBase(_))
    ));
    let b = bases(p).unwrap();
    assert!(b.detached);
    assert_eq!((b.current, b.default), (None, None));
    assert!(b.recent.contains(&"main".to_string()), "{:?}", b.recent);
    let l = files(p, ScopeKind::Branch, Some("HEAD~1")).unwrap();
    assert_eq!(names(&l), vec!["a.txt"]);
}

#[test]
fn an_unborn_branch_lists_every_untracked_file_and_branch_asks() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path();
    git(p, &["init", "-q", "-b", "main"]);
    write(p, "x.txt", "x\n");
    write(p, "y/z.txt", "z\n");
    let l = files(p, ScopeKind::Changed, None).unwrap();
    assert_eq!(names(&l), vec!["x.txt", "y/z.txt"]);
    assert!(matches!(
        files(p, ScopeKind::Branch, None),
        Err(ScopeError::NeedsBase(_))
    ));
    let added = added_lines(&l, ScopeKind::Changed).unwrap();
    assert!(added[&l.top.join("x.txt")].whole);
}

#[test]
fn a_linked_worktree_is_its_own_top_level() {
    let d = repo();
    let p = d.path();
    let wt = tempfile::tempdir().unwrap();
    let w = wt.path().join("wt");
    git(
        p,
        &["worktree", "add", "-q", "-b", "wt", w.to_str().unwrap()],
    );
    write(&w, "c.txt", "in the worktree\n");
    write(p, "a.txt", "in the main checkout\n");
    let l = files(&w.join("."), ScopeKind::Changed, None).unwrap();
    assert_eq!(l.top, w.canonicalize().unwrap());
    assert_eq!(names(&l), vec!["c.txt"]);
}

#[test]
fn a_submodule_is_skipped_and_counted() {
    let inner = repo();
    let d = repo();
    let p = d.path();
    git(
        p,
        &[
            "submodule",
            "add",
            "-q",
            inner.path().to_str().unwrap(),
            "sub",
        ],
    );
    let l = files(p, ScopeKind::Changed, None).unwrap();
    assert_eq!(names(&l), vec![".gitmodules"]);
    assert_eq!(l.submodules, 1);
}

#[test]
fn files_outside_a_repository_are_not_a_scope() {
    let d = tempfile::tempdir().unwrap();
    assert_eq!(
        files(d.path(), ScopeKind::Changed, None),
        Err(ScopeError::NotARepo)
    );
}

#[test]
fn changed_lines_keep_a_match_in_an_added_hunk_and_drop_one_in_a_deleted_only_hunk() {
    let d = repo();
    let p = d.path();
    // a.txt: line 2 replaced, a line added after 4; c.txt: line 3 deleted only
    write(p, "a.txt", "one\nTWO\nthree\nfour\nfive\n");
    write(p, "c.txt", "one\ntwo\nfour\n");
    let l = files(p, ScopeKind::Changed, None).unwrap();
    let added = added_lines(&l, ScopeKind::Changed).unwrap();
    let a = &added[&l.top.join("a.txt")];
    assert_eq!(a.ranges, vec![(2, 2), (5, 5)]);
    assert!(a.keeps(2, 2) && a.keeps(5, 5) && a.keeps(1, 2) && a.keeps(4, 6));
    assert!(!a.keeps(1, 1) && !a.keeps(3, 4));
    let c = added.get(&l.top.join("c.txt")).cloned().unwrap_or_default();
    assert!(c.ranges.is_empty() && !c.whole);
    assert!(!c.keeps(2, 3));
}

#[test]
fn staged_lines_fall_back_to_the_working_tree_for_a_file_with_unstaged_changes() {
    let d = repo();
    let p = d.path();
    write(p, "a.txt", "one\nTWO\nthree\nfour\n");
    write(p, "c.txt", "one\ntwo\nTHREE\nfour\n");
    git(p, &["add", "a.txt", "c.txt"]);
    write(p, "c.txt", "one\ntwo\nTHREE\nFOUR\n"); // unstaged on top
    let l = files(p, ScopeKind::Staged, None).unwrap();
    let added = added_lines(&l, ScopeKind::Staged).unwrap();
    let a = &added[&l.top.join("a.txt")];
    assert_eq!((a.ranges.clone(), a.fell_back), (vec![(2, 2)], false));
    let c = &added[&l.top.join("c.txt")];
    assert_eq!((c.ranges.clone(), c.fell_back), (vec![(3, 4)], true));
}

#[test]
fn branch_lines_are_against_the_merge_base() {
    let d = repo();
    let p = d.path();
    git(p, &["checkout", "-q", "-b", "feature"]);
    write(p, "a.txt", "one\ntwo\nthree\nfour\nfive\n");
    git(p, &["commit", "-q", "-am", "on feature"]);
    write(p, "a.txt", "ONE\ntwo\nthree\nfour\nfive\n");
    let l = files(p, ScopeKind::Branch, None).unwrap();
    let added = added_lines(&l, ScopeKind::Branch).unwrap();
    assert_eq!(added[&l.top.join("a.txt")].ranges, vec![(1, 1), (5, 5)]);
}

#[test]
fn bases_name_the_upstream_and_recent_branches() {
    let d = repo();
    let p = d.path();
    git(p, &["branch", "older"]);
    git(p, &["checkout", "-q", "-b", "feature"]);
    git(p, &["branch", "--set-upstream-to=main"]);
    let b = bases(p).unwrap();
    assert_eq!(b.current.as_deref(), Some("feature"));
    assert_eq!(b.upstream.as_deref(), Some("main"));
    assert_eq!(b.default.as_deref(), Some("main"));
    assert!(!b.detached);
    assert!(b.recent.contains(&"older".to_string()));
    assert!(
        !b.recent.contains(&"feature".to_string()),
        "the current branch is no base"
    );
}
