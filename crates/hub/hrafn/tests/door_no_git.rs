//! A touched tree's door works with no `git` on PATH: it is in-process (gix), and the cli door that a user tree gets
//! fails on every call here. Its own test binary, because it empties PATH for the whole process.
use hrafn::{Config, DoorKind, door, list};

#[path = "gitfx.rs"]
mod gitfx;
use gitfx::git;

#[test]
fn touched_tree_seeds_without_git_cli() {
    assert_eq!(DoorKind::for_tree(true), DoorKind::Gix);
    assert_eq!(DoorKind::for_tree(false), DoorKind::Cli);
    assert_eq!(
        (DoorKind::Gix.as_str(), DoorKind::Cli.as_str()),
        ("gix", "cli")
    );
    assert_eq!(DoorKind::parse("gix"), Some(DoorKind::Gix));

    let t = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let r = t.path();
    git(r, &["init", "-q", "-b", "main"]);
    eitri::replace_file(&r.join("a.rs"), b"fn a() {}\n").unwrap();
    eitri::replace_file(&r.join("b.rs"), b"fn b() {}\n").unwrap();
    git(r, &["add", "-A"]);
    git(r, &["commit", "-q", "-m", "one"]);
    let c1 = git(r, &["rev-parse", "HEAD"]);
    eitri::replace_file(&r.join("b.rs"), b"fn b2() {}\n").unwrap();
    git(r, &["commit", "-q", "-am", "two"]);
    let c2 = git(r, &["rev-parse", "HEAD"]);
    eitri::replace_file(&r.join("u.rs"), b"fn u() {}\n").unwrap();

    let empty = tempfile::tempdir().unwrap();
    // SAFETY: this binary has one test; nothing else reads the environment while it runs.
    unsafe { std::env::set_var("PATH", empty.path()) };

    let cli = door(DoorKind::Cli);
    assert!(cli.head(r).is_err(), "no git on PATH: the cli door fails");

    let d = door(DoorKind::for_tree(true));
    assert_eq!(d.kind(), DoorKind::Gix);
    let h = d.head(r);
    assert!(
        matches!(&h, Ok(h) if h.id.as_deref() == Some(c2.as_str())),
        "{h:?}"
    );
    let ls = d.ls_tree(r, &c2);
    assert!(matches!(&ls, Ok(v) if v.len() == 2), "{ls:?}");
    let diff = d.tree_diff(r, &c1, &c2);
    assert!(
        matches!(&diff, Ok(v) if v.len() == 1 && v[0].path == "b.rs"),
        "{diff:?}"
    );
    let st = d.stat_status(r);
    assert!(matches!(&st, Ok(s) if s.untracked == ["u.rs"]), "{st:?}");
    let b = d.blobs(r, &["u.rs".to_string()]);
    assert!(
        matches!(&b, Ok(v) if v.len() == 1 && !v[0].uncertain),
        "{b:?}"
    );
    let f = d.filtered(r, &["u.rs".to_string()]);
    assert!(matches!(&f, Ok(v) if v.is_empty()), "{f:?}");
    // the fallback: the file list on the gix door's listing
    let l = list(r, d.as_git(), &Config::default(), &|_| true);
    let paths: Vec<String> = l
        .map(|v| v.into_iter().map(|x| x.path).collect())
        .unwrap_or_default();
    assert_eq!(paths, ["a.rs", "b.rs", "u.rs"]);
}
