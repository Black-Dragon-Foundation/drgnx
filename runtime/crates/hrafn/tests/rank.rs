//! The ranked file query: the name list a root gives (a repository's `git ls-files`, a walk elsewhere) and the ranking
//! of a query over it.

use hrafn::grep::Ignore;
use hrafn::rank::{NameList, names};
use std::path::Path;
use std::process::Command;
use std::sync::atomic::AtomicBool;

fn write(root: &Path, rel: &str, bytes: &[u8]) {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

fn repo() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    let ok = Command::new("git")
        .args(["init", "-q"])
        .current_dir(d.path())
        .status()
        .unwrap()
        .success();
    assert!(ok, "git init");
    d
}

fn top(list: &NameList, query: &str, n: usize) -> Vec<String> {
    list.top(query, n, &AtomicBool::new(false))
        .unwrap()
        .into_iter()
        .map(|r| r.path)
        .collect()
}

fn list(paths: &[&str]) -> NameList {
    NameList::new(paths.iter().map(|p| p.to_string()).collect())
}

/// Pattern D. A basename that starts with the query first, then one that holds it, then a path that holds it; the
/// words of a query must all be there; a row's runs are where the words matched.
#[test]
fn ranks_basename_prefix_first() {
    let l = list(&["map/a.rs", "z/roadmap.rs", "src/map.rs", "src/xmap.rs"]);
    assert_eq!(
        top(&l, "map", 10),
        ["src/map.rs", "src/xmap.rs", "z/roadmap.rs", "map/a.rs"]
    );
    assert_eq!(top(&l, "MAP src", 10), ["src/map.rs", "src/xmap.rs"]);
    let r = l.top("map", 1, &AtomicBool::new(false)).unwrap();
    assert_eq!(r[0].runs, [(4, 7)]);
    let r = l.top("rs src", 1, &AtomicBool::new(false)).unwrap();
    assert_eq!(r[0].runs, [(0, 3), (8, 10)]);
}

/// Pattern D. In a repository the list is git's: `.gitignore` leaves files out, and the exclude globs do too.
#[test]
fn respects_ignore_rules() {
    let d = repo();
    write(d.path(), ".gitignore", b"build/\n*.log\n");
    for f in ["a.rs", "build/out.rs", "x.log", "vendor/v.rs"] {
        write(d.path(), f, b"x\n");
    }
    let got = names(d.path(), Ignore::Index, &["vendor/**".into()]).unwrap();
    assert_eq!(got, ["a.rs"]);
}

/// Pattern D. Nothing is read: a binary file and one over the index's size limit are names like any other.
#[test]
fn lists_binary_and_large_files() {
    let d = repo();
    write(d.path(), "bin.dat", b"\0\x01\x02\0");
    write(
        d.path(),
        "big.txt",
        &vec![b'a'; 2 * hrafn::files::MAX_FILE_BYTES as usize],
    );
    assert_eq!(
        names(d.path(), Ignore::Index, &[]).unwrap(),
        ["big.txt", "bin.dat"]
    );
}

/// Pattern D. A link is a name: to a file or to a folder, it is listed and never followed.
#[test]
fn lists_links_without_following() {
    let d = tempfile::tempdir().unwrap();
    write(d.path(), "d/f.rs", b"x\n");
    std::os::unix::fs::symlink(d.path().join("d"), d.path().join("ld")).unwrap();
    std::os::unix::fs::symlink(d.path().join("d/f.rs"), d.path().join("lf")).unwrap();
    std::os::unix::fs::symlink("/", d.path().join("root")).unwrap();
    assert_eq!(
        names(d.path(), Ignore::Index, &[]).unwrap(),
        ["d/f.rs", "ld", "lf", "root"]
    );
}

/// Pattern D. Outside a repository the walk applies every `.gitignore` it meets (a deeper file's rules first, the last
/// matching line of a file wins, `!` keeps), and skips `.git` folders.
#[test]
fn non_git_root_lists_files() {
    let d = tempfile::tempdir().unwrap();
    write(
        d.path(),
        ".gitignore",
        b"# built\ntarget/\n*.log\n!keep.log\n/top.rs\n",
    );
    write(d.path(), "sub/.gitignore", b"gen.rs\n!x.log\n");
    for f in [
        "a.rs",
        "gen.rs",
        "keep.log",
        "x.log",
        "top.rs",
        "target/t.rs",
        "sub/b.rs",
        "sub/gen.rs",
        "sub/top.rs",
        "sub/x.log",
        "inner/.git/HEAD",
        "inner/c.rs",
    ] {
        write(d.path(), f, b"x\n");
    }
    assert_eq!(
        names(d.path(), Ignore::Index, &[]).unwrap(),
        [
            "a.rs",
            "gen.rs",
            "inner/c.rs",
            "keep.log",
            "sub/b.rs",
            "sub/top.rs",
            "sub/x.log"
        ]
    );
}

/// Pattern D. Only the N best come back, and the shortest win among equals.
#[test]
fn top_n_only() {
    let paths: Vec<String> = (0..100).map(|i| format!("f{i}.rs")).collect();
    let l = NameList::new(paths);
    assert_eq!(
        top(&l, "f", 5),
        ["f0.rs", "f1.rs", "f2.rs", "f3.rs", "f4.rs"]
    );
}

/// Pattern D. A query whose cancel flag a newer one set gives nothing.
#[test]
fn cancels_stale_query() {
    let l = NameList::new((0..10_000).map(|i| format!("f{i}.rs")).collect());
    assert!(l.top("f", 5, &AtomicBool::new(true)).is_none());
    assert!(l.top("f", 5, &AtomicBool::new(false)).is_some());
}

fn dotted() -> tempfile::TempDir {
    let d = repo();
    for f in [".github/ci.yml", ".env", "id_rsa.pem", "a.rs"] {
        write(d.path(), f, b"x\n");
    }
    d
}

/// Pattern D. `search.ignore-rules` = real: dot paths and secret-looking names are listed.
#[test]
fn search_setting_real_lists_dot_paths() {
    let d = dotted();
    assert_eq!(
        names(d.path(), Ignore::Real, &[]).unwrap(),
        [".env", ".github/ci.yml", "a.rs", "id_rsa.pem"]
    );
}

/// Pattern D. `search.ignore-rules` = index (the default): the index's filters leave them out.
#[test]
fn search_setting_index_hides_them() {
    let d = dotted();
    assert_eq!(names(d.path(), Ignore::Index, &[]).unwrap(), ["a.rs"]);
}
