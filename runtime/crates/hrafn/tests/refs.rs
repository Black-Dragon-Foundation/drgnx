//! References: the names a file uses (calls, types, macros, commands, Lisp atoms), counted per file with their first
//! lines, from the parse the chunker already made; stored per `(path, blob)` like chunks and symbols, so a view sees
//! them through its `file` rows, the sweep and the reset take them with the pair.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::chunk::{BUDGET, Ref, chunk_file_refs};
use hrafn::refs::{RefRow, references};
use hrafn::{Class, CodeStore, DoorKind, FileRow, Lang, Listed, RefIn, View, refresh, reset};
use std::collections::HashMap;
use std::io;

/// PATH's references in LANG, by name.
fn refs(path: &str, lang: Lang, text: &str) -> HashMap<String, Ref> {
    let (_, _, refs) = chunk_file_refs(path, lang, false, text, BUDGET);
    refs.into_iter().map(|r| (r.name.clone(), r)).collect()
}

/// The names, sorted.
fn names(r: &HashMap<String, Ref>) -> Vec<&str> {
    let mut v: Vec<&str> = r.keys().map(String::as_str).collect();
    v.sort();
    v
}

#[test]
fn each_language_gives_its_references() {
    let rust = refs(
        "src/a.rs",
        Lang::Rust,
        "fn a() {\n    bb();\n    s.cee();\n    mac!();\n    f();\n    bb();\n}\n",
    );
    assert_eq!(
        names(&rust),
        ["bb", "cee", "mac"],
        "a one-letter name is dropped"
    );
    assert_eq!((rust["bb"].n, rust["bb"].lines.clone()), (2, vec![2, 6]));
    let c = refs(
        "a.c",
        Lang::C,
        "int a(void) {\n  return bee(1) + bee(2);\n}\n",
    );
    assert_eq!(names(&c), ["bee"]);
    assert_eq!(
        (c["bee"].n, c["bee"].lines.clone()),
        (2, vec![2]),
        "one line, counted twice"
    );
    let py = refs("a.py", Lang::Python, "def a():\n    bee()\n    x.cee()\n");
    assert_eq!(names(&py), ["bee", "cee"]);
    let js = refs(
        "a.js",
        Lang::JavaScript,
        "function a() {\n  bee();\n  x.cee(1);\n  new Dee();\n}\n",
    );
    assert_eq!(names(&js), ["Dee", "bee", "cee"]);
    let ts = refs(
        "a.ts",
        Lang::TypeScript,
        "function a(x: Foo): void {\n  bee();\n  x.cee(1);\n  new Dee();\n}\n",
    );
    assert_eq!(names(&ts), ["Dee", "Foo", "bee", "cee"]);
    let tsx = refs(
        "a.tsx",
        Lang::Tsx,
        "const A = () => {\n  bee();\n  return <div />;\n};\n",
    );
    assert_eq!(names(&tsx), ["bee"]);
    let go = refs(
        "a.go",
        Lang::Go,
        "package p\n\nfunc a() {\n\tbee()\n\tx.Cee()\n}\n",
    );
    assert!(
        go.contains_key("bee") && go.contains_key("Cee"),
        "{:?}",
        names(&go)
    );
    let java = refs(
        "A.java",
        Lang::Java,
        "class A {\n  void a() {\n    bee(1);\n    new Dee();\n  }\n}\n",
    );
    assert_eq!(names(&java), ["Dee", "bee"]);
    let sh = refs("a.sh", Lang::Shell, "a() {\n  grep -q x f\n}\nbee\n");
    assert_eq!(names(&sh), ["bee", "grep"]);
    let el = refs(
        "a.el",
        Lang::Elisp,
        "(defun my-a (x)\n  (my-b x :key 1)\n  (when t (my-c-d nil)))\n",
    );
    assert_eq!(
        names(&el),
        ["my-b", "my-c-d"],
        "not its own name, keywords, t, nil or special forms"
    );
    for (path, lang) in [
        ("a.org", Lang::Org),
        ("a.md", Lang::Markdown),
        ("a.txt", Lang::Text),
    ] {
        assert!(refs(path, lang, "* bee()\ncall(x)\n").is_empty(), "{path}");
    }
}

/// A name used on many lines keeps its count and its first 8 lines.
#[test]
fn a_reference_keeps_its_first_eight_lines() {
    let mut text = String::from("fn a() {\n");
    for _ in 0..12 {
        text.push_str("    bee();\n");
    }
    text.push_str("}\n");
    let r = refs("src/a.rs", Lang::Rust, &text);
    assert_eq!(r["bee"].n, 12);
    assert_eq!(r["bee"].lines, (2..10).collect::<Vec<u32>>());
}

fn row(path: &str, blob: &str) -> FileRow {
    FileRow {
        path: path.into(),
        blob: Some(blob.into()),
        class: "code".into(),
        lang: "rust".into(),
        generated: false,
        size: 1,
        indexed_at: 1,
    }
}

fn r(name: &str, n: u32, lines: &[u32]) -> RefIn {
    RefIn {
        name: name.into(),
        n,
        lines: lines.to_vec(),
    }
}

/// `(path, n, lines)` of NAME's references in VIEW.
async fn seen(s: &CodeStore, view: View, name: &str) -> Vec<(String, u32, Vec<u32>)> {
    references(s, view, name)
        .await
        .unwrap()
        .into_iter()
        .map(|RefRow { path, n, lines }| (path, n, lines))
        .collect()
}

#[tokio::test]
async fn a_view_sees_its_own_references_and_the_sweep_takes_them() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let t = s
        .tree_open("t", "/w/t", "/g/t", DoorKind::Cli)
        .await
        .unwrap();
    s.write_file_with_refs(
        View::Base,
        row("a.rs", "A"),
        vec![],
        vec![],
        vec![r("bee", 2, &[3, 9])],
    )
    .await
    .unwrap();
    s.write_file_with_refs(
        View::Base,
        row("b.rs", "B"),
        vec![],
        vec![],
        vec![r("bee", 1, &[4])],
    )
    .await
    .unwrap();
    // T changed a.rs (bee three times now) and removed b.rs
    s.write_file_with_refs(
        View::Tree(t),
        row("a.rs", "A2"),
        vec![],
        vec![],
        vec![r("bee", 3, &[1, 2, 3])],
    )
    .await
    .unwrap();
    s.write_file(View::Tree(t), FileRow::tombstone("b.rs"), vec![], vec![])
        .await
        .unwrap();
    assert_eq!(
        seen(&s, View::Base, "bee").await,
        [("a.rs".into(), 2, vec![3, 9]), ("b.rs".into(), 1, vec![4])]
    );
    assert_eq!(
        seen(&s, View::Tree(t), "bee").await,
        [("a.rs".into(), 3, vec![1, 2, 3])]
    );
    // the base lets go of b.rs: its pair is named by nothing, and its references go with it
    s.delete_file("b.rs").await.unwrap();
    let left: i64 = s
        .handle()
        .read(|c| {
            Ok(
                c.query_row("select count(*) from ref where path = 'b.rs'", [], |r| {
                    r.get(0)
                })?,
            )
        })
        .await
        .unwrap();
    assert_eq!(left, 0);
    // the tree's own pair stays while T names it
    s.remove_file(View::Tree(t), "a.rs").await.unwrap();
    assert_eq!(
        seen(&s, View::Tree(t), "bee").await,
        [("a.rs".into(), 2, vec![3, 9])]
    );
}

/// Tier 1 writes a file's references, and the reset clears them with everything else.
#[tokio::test]
async fn tier1_writes_references_and_the_reset_clears_them() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let text = "fn a() {\n    bee();\n}\n\nfn bee() {}\n";
    let l = vec![Listed {
        path: "src/a.rs".into(),
        blob: "b1".into(),
        class: Class::Code,
        lang: Lang::Rust,
        generated: false,
        size: text.len() as u64,
    }];
    let read = move |_: &str| Ok::<_, io::Error>(text.as_bytes().to_vec());
    refresh(&s, &l, &read, &[]).await.unwrap();
    assert_eq!(
        seen(&s, View::Base, "bee").await,
        [("src/a.rs".into(), 1, vec![2])]
    );
    reset(&s).await.unwrap();
    assert!(seen(&s, View::Base, "bee").await.is_empty());
    let rows: i64 = s
        .handle()
        .read(|c| Ok(c.query_row("select count(*) from ref", [], |r| r.get(0))?))
        .await
        .unwrap();
    assert_eq!(rows, 0);
}
