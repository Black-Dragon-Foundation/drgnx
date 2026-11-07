//! The per-tree git door (`TreeGit`): the `GitCli` door of user trees and the read-only `GixDoor` of touched trees
//! answer the same questions; the gix door runs no filter, hook or fsmonitor and writes nothing.
use hrafn::{Blob, GitCli, GixDoor, Head, Obj, Status, TreeChange, TreeGit};
use std::path::{Path, PathBuf};
use std::process::Command;

fn git_cmd(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .arg("-C")
        .arg(dir)
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
        .unwrap()
}

fn git(dir: &Path, args: &[&str]) {
    let o = git_cmd(dir, args);
    assert!(
        o.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
}

fn out(dir: &Path, args: &[&str]) -> String {
    let o = git_cmd(dir, args);
    assert!(
        o.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

fn tmp() -> tempfile::TempDir {
    tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap()
}

fn write(root: &Path, files: &[(&str, &str)]) {
    for (p, c) in files {
        let f = root.join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, c).unwrap();
    }
}

/// Set every file's mtime an hour back, so the index written after it is not racy (file times sit on 1 ms ticks).
fn backdate(root: &Path, paths: &[&str]) {
    let then = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000);
    for p in paths {
        let f = std::fs::File::options()
            .write(true)
            .open(root.join(p))
            .unwrap();
        f.set_modified(then).unwrap();
    }
}

fn init(root: &Path) {
    git(root, &["init", "-q", "-b", "main"]);
}

fn commit(root: &Path, msg: &str) -> String {
    git(root, &["add", "-A"]);
    git(root, &["commit", "-q", "--allow-empty", "-m", msg]);
    out(root, &["rev-parse", "HEAD"])
}

fn doors() -> Vec<(&'static str, Box<dyn TreeGit>)> {
    vec![("cli", Box::new(GitCli)), ("gix", Box::new(GixDoor))]
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

#[test]
fn head_reads_symref_and_detached() {
    for (name, d) in doors() {
        let t = tmp();
        let r = t.path();
        init(r);
        assert_eq!(
            d.head(r).unwrap(),
            Head {
                id: None,
                symref: Some("refs/heads/main".into())
            },
            "{name}: unborn"
        );
        write(r, &[("a.txt", "a\n")]);
        let c = commit(r, "one");
        assert_eq!(
            d.head(r).unwrap(),
            Head {
                id: Some(c.clone()),
                symref: Some("refs/heads/main".into())
            },
            "{name}: on a branch"
        );
        git(r, &["checkout", "-q", "--detach"]);
        assert_eq!(
            d.head(r).unwrap(),
            Head {
                id: Some(c),
                symref: None
            },
            "{name}: detached"
        );
    }
}

/// A gitlink of a commit that is not in the repository (a submodule entry without its clone).
fn add_gitlink(r: &Path, path: &str) {
    let sha = "1111111111111111111111111111111111111111";
    git(
        r,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            &format!("160000,{sha},{path}"),
        ],
    );
}

#[test]
fn ls_tree_lists_blobs_and_skips_gitlinks() {
    for (name, d) in doors() {
        let t = tmp();
        let r = t.path();
        init(r);
        write(r, &[("a.txt", "a\n"), ("d/e/b.rs", "fn b() {}\n")]);
        std::os::unix::fs::symlink("a.txt", r.join("ln")).unwrap();
        git(r, &["add", "-A"]);
        add_gitlink(r, "sub");
        git(r, &["commit", "-q", "-m", "one"]);
        let c = out(r, &["rev-parse", "HEAD"]);
        let got = d.ls_tree(r, &c).unwrap();
        let want: Vec<(String, u32, String)> = ["a.txt", "d/e/b.rs", "ln"]
            .iter()
            .map(|p| {
                let mode = if *p == "ln" { 0o120000 } else { 0o100644 };
                (
                    p.to_string(),
                    mode,
                    out(r, &["rev-parse", &format!("HEAD:{p}")]),
                )
            })
            .collect();
        let got: Vec<(String, u32, String)> =
            got.into_iter().map(|e| (e.path, e.mode, e.blob)).collect();
        assert_eq!(got, want, "{name}");
    }
}

#[test]
fn gitlinks_and_renames_handled() {
    for (name, d) in doors() {
        let t = tmp();
        let r = t.path();
        init(r);
        write(
            r,
            &[
                ("a.txt", "same\n"),
                ("d/b.txt", "one\n"),
                ("k.txt", "keep\n"),
            ],
        );
        let c1 = commit(r, "one");
        let a = out(r, &["rev-parse", "HEAD:a.txt"]);
        let b1 = out(r, &["rev-parse", "HEAD:d/b.txt"]);
        git(r, &["mv", "a.txt", "c.txt"]);
        write(r, &[("d/b.txt", "two\n")]);
        git(r, &["add", "-A"]);
        add_gitlink(r, "sub");
        git(r, &["commit", "-q", "-m", "two"]);
        let c2 = out(r, &["rev-parse", "HEAD"]);
        let b2 = out(r, &["rev-parse", "HEAD:d/b.txt"]);
        let f = |blob: &str| {
            Some(Obj {
                mode: 0o100644,
                blob: blob.to_string(),
            })
        };
        assert_eq!(
            d.tree_diff(r, &c1, &c2).unwrap(),
            vec![
                TreeChange {
                    path: "a.txt".into(),
                    old: f(&a),
                    new: None
                },
                TreeChange {
                    path: "c.txt".into(),
                    old: None,
                    new: f(&a)
                },
                TreeChange {
                    path: "d/b.txt".into(),
                    old: f(&b1),
                    new: f(&b2)
                },
            ],
            "{name}: a rename is a deletion and an addition; the gitlink gives nothing"
        );
        assert_eq!(
            d.tree_diff(r, &c2, &c2).unwrap(),
            vec![],
            "{name}: same commit"
        );
    }
}

#[test]
fn stat_status_reports_dirty_and_untracked() {
    for (name, d) in doors() {
        let t = tmp();
        let r = t.path();
        init(r);
        let files = ["a.txt", "b.txt", "c.txt", "e.txt", ".gitignore"];
        write(
            r,
            &[
                ("a.txt", "a\n"),
                ("b.txt", "b\n"),
                ("c.txt", "c\n"),
                ("e.txt", "e\n"),
                (".gitignore", "*.log\n"),
            ],
        );
        backdate(r, &files);
        commit(r, "one");
        write(
            r,
            &[
                ("a.txt", "a changed\n"),
                ("u.txt", "u\n"),
                ("i.log", "i\n"),
                ("n/x.txt", "x\n"),
            ],
        );
        std::fs::remove_file(r.join("b.txt")).unwrap();
        write(r, &[("c.txt", "c staged\n")]);
        git(r, &["add", "c.txt"]);
        backdate(r, &["c.txt"]);
        // `c.txt` is staged with a backdated stat: only index-against-HEAD finds it; a re-add keeps the index stat right
        git(r, &["add", "c.txt"]);
        std::fs::create_dir(r.join("inner")).unwrap();
        init(&r.join("inner"));
        write(r, &[("inner/z.txt", "z\n")]);
        assert_eq!(
            d.stat_status(r).unwrap(),
            Status {
                dirty: s(&["a.txt", "b.txt", "c.txt"]),
                untracked: s(&["n/x.txt", "u.txt"])
            },
            "{name}"
        );
    }
}

/// `.gitattributes` naming each conversion, and paths that have none.
const ATTRS: &str = "a.txt filter=mark\nb.txt text\nc.txt eol=crlf\nd.txt ident\ne.txt -text\n\
                     g.txt working-tree-encoding=UTF-16\nh.txt text=auto\n*.rs linguist-generated\n";

#[test]
fn filtered_names_conversion_attributes() {
    for (name, d) in doors() {
        let t = tmp();
        let r = t.path();
        init(r);
        write(r, &[(".gitattributes", ATTRS)]);
        let all = s(&[
            "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt", "g.txt", "h.txt", "x.rs",
        ]);
        assert_eq!(
            d.filtered(r, &all).unwrap(),
            s(&["a.txt", "b.txt", "c.txt", "d.txt", "g.txt", "h.txt"]),
            "{name}"
        );
    }
}

/// A marker script: appends its name to `marker` and passes stdin through (a clean or smudge filter must answer).
fn marker_script(dir: &Path, name: &str, marker: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let p = dir.join(name);
    std::fs::write(
        &p,
        format!("#!/bin/sh\necho {name} >> '{}'\ncat\n", marker.display()),
    )
    .unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

fn git_dir_snapshot(r: &Path) -> Vec<(PathBuf, std::time::SystemTime, u64)> {
    let mut v = Vec::new();
    let mut stack = vec![r.join(".git")];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let e = e.unwrap();
            let m = e.metadata().unwrap();
            if m.is_dir() {
                stack.push(e.path());
            } else {
                v.push((e.path(), m.modified().unwrap(), m.len()));
            }
        }
    }
    v.sort();
    v
}

#[test]
fn gix_door_runs_no_filters_or_hooks() {
    let t = tmp();
    let r = t.path().join("repo");
    let bin = t.path().join("bin");
    std::fs::create_dir_all(&r).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let marker = t.path().join("marker");
    let r = r.as_path();
    init(r);
    write(
        r,
        &[
            (".gitattributes", "*.txt filter=mark\n"),
            ("f.txt", "x\n"),
            ("p.rs", "fn p() {}\n"),
        ],
    );
    commit(r, "one");
    let clean = marker_script(&bin, "clean", &marker);
    let smudge = marker_script(&bin, "smudge", &marker);
    let process = marker_script(&bin, "process", &marker);
    let fsmonitor = marker_script(&bin, "fsmonitor", &marker);
    for (k, v) in [
        ("filter.mark.clean", &clean),
        ("filter.mark.smudge", &smudge),
        ("filter.mark.process", &process),
        ("core.fsmonitor", &fsmonitor),
    ] {
        git(r, &["config", k, v.to_str().unwrap()]);
    }
    git(r, &["config", "filter.mark.required", "true"]);
    for hook in [
        "pre-commit",
        "post-checkout",
        "post-index-change",
        "reference-transaction",
        "pre-auto-gc",
        "fsmonitor-watchman",
    ] {
        marker_script(&r.join(".git/hooks"), hook, &marker);
    }
    // a dirty, a new and a racy file, so a status or a refresh would have to read and filter them
    write(r, &[("f.txt", "x dirty\n"), ("n.txt", "new\n")]);
    let _ = std::fs::remove_file(&marker);
    let before = git_dir_snapshot(r);
    let index_before = std::fs::read(r.join(".git/index")).unwrap();

    let d = GixDoor;
    let head = d.head(r).unwrap();
    let c = head.id.clone().unwrap();
    d.ls_tree(r, &c).unwrap();
    d.tree_diff(r, &c, &c).unwrap();
    let st = d.stat_status(r).unwrap();
    assert!(st.dirty.contains(&"f.txt".to_string()), "{st:?}");
    let paths = s(&["f.txt", "n.txt", "p.rs"]);
    let blobs = d.blobs(r, &paths).unwrap();
    d.filtered(r, &paths).unwrap();
    let g = d.as_git();
    g.ls_files(r).unwrap();
    g.blobs(r, &paths).unwrap();
    g.nested(r).unwrap();
    g.generated(r, &paths).unwrap();
    g.head(r).unwrap();

    assert!(
        !marker.exists(),
        "ran: {}",
        std::fs::read_to_string(&marker).unwrap_or_default()
    );
    assert_eq!(git_dir_snapshot(r), before, "the gitdir is unchanged");
    assert_eq!(std::fs::read(r.join(".git/index")).unwrap(), index_before);
    assert!(
        blobs[0].uncertain && blobs[1].uncertain,
        "filtered paths are uncertain: {blobs:?}"
    );
    assert!(!blobs[2].uncertain, "{blobs:?}");

    // the marker works: git itself runs the filter on the same file (and fails: the marker is no filter protocol)
    let _ = git_cmd(r, &["hash-object", "f.txt"]);
    assert!(
        marker.exists(),
        "the clean filter writes the marker when git runs it"
    );
}

#[test]
fn raw_hash_equals_hash_object_no_filters() {
    let t = tmp();
    let r = t.path();
    init(r);
    git(r, &["config", "filter.up.clean", "tr a-z A-Z"]);
    git(r, &["config", "core.autocrlf", "false"]);
    write(
        r,
        &[
            (
                ".gitattributes",
                "f.txt filter=up\nc.txt text eol=crlf\nk.txt ident\n",
            ),
            ("f.txt", "lower\n"),
            ("c.txt", "one\r\ntwo\r\n"),
            ("k.txt", "$Id$\n"),
            ("p.rs", "fn p() {}\n"),
        ],
    );
    std::os::unix::fs::symlink("p.rs", r.join("ln")).unwrap();
    let paths = s(&["f.txt", "c.txt", "k.txt", "p.rs", "ln"]);
    let got = GixDoor.blobs(r, &paths).unwrap();
    for (p, b) in paths.iter().zip(&got) {
        let want = if p == "ln" {
            // a link's blob is its target, as git stores it
            let o = Command::new("git")
                .arg("-C")
                .arg(r)
                .args(["hash-object", "--no-filters", "--stdin"])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .and_then(|mut c| {
                    use std::io::Write;
                    c.stdin.take().unwrap().write_all(b"p.rs")?;
                    c.wait_with_output()
                })
                .unwrap();
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        } else {
            out(r, &["hash-object", "--no-filters", p])
        };
        assert_eq!(b.id, want, "{p}");
    }
    assert_eq!(
        got.iter().map(|b| b.uncertain).collect::<Vec<_>>(),
        [true, true, true, false, false],
        "{got:?}"
    );
    // the cli door hashes with filters, as the base does; its blobs are never uncertain
    let cli: Vec<Blob> = GitCli.blobs(r, &s(&["f.txt", "p.rs"])).unwrap();
    assert_eq!(cli[0].id, out(r, &["hash-object", "f.txt"]));
    assert_ne!(cli[0].id, got[0].id, "the filter changes the cli blob");
    assert!(cli.iter().all(|b| !b.uncertain));
}
