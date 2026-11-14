//! Definitions by name and a file's outline, in a view (`hrafn::symbols`): the symbol table as agents ask it.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::symbols::{Find, Match, SymbolsError, find, outline};
use hrafn::{CodeStore, DoorKind, FileRow, Listed, Scope, TreeId, View, classify, refresh};
use std::collections::HashMap;
use std::io;

const RS: &str = "\
/// Makes a widget.
pub fn make_widget(n: u32) -> Widget {
    Widget { n }
}

pub struct Widget {
    n: u32,
}

impl Widget {
    /// The size.
    pub fn size(&self) -> u32 {
        self.n
    }
}
";

const C: &str = "\
static int
widget_count (void)
{
  return 0;
}
";

const EL: &str = "(defun widget-mode-on ()\n  \"Turn it on.\"\n  1)\n";

const TEST: &str = "fn make_widget_test() {\n    assert!(true);\n}\n";

const BASE: &[(&str, &str)] = &[
    ("src/a.rs", RS),
    ("src/b.c", C),
    ("lisp/c.el", EL),
    ("tests/a_test.rs", TEST),
];

fn listed(path: &str, text: &str) -> Listed {
    let (lang, class) = classify(path, text.as_bytes());
    Listed {
        path: path.into(),
        blob: format!("b-{path}-{}", text.len()),
        class,
        lang,
        generated: false,
        size: text.len() as u64,
    }
}

async fn index(s: &CodeStore, files: &[(&str, &str)]) {
    let l: Vec<Listed> = files.iter().map(|(p, t)| listed(p, t)).collect();
    let texts: HashMap<String, String> = files
        .iter()
        .map(|(p, t)| (p.to_string(), t.to_string()))
        .collect();
    refresh(
        s,
        &l,
        &move |p: &str| {
            texts
                .get(p)
                .map(|t| t.as_bytes().to_vec())
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        },
        &[],
    )
    .await
    .unwrap();
}

async fn store() -> (tempfile::TempDir, CodeStore, TreeId) {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    index(&s, BASE).await;
    let t = s
        .tree_open("t", "/w/t", "/g/t", DoorKind::Cli)
        .await
        .unwrap();
    (dir, s, t)
}

/// TREE's version of PATH with TEXT, chunked as tier 1 chunks it.
async fn put(s: &CodeStore, tree: TreeId, path: &str, text: &str) {
    let l = listed(path, text);
    let (chunks, symbols) = hrafn::index::built(&l, text.as_bytes());
    let row = FileRow {
        path: path.into(),
        blob: Some(l.blob),
        class: l.class.as_str().into(),
        lang: l.lang.as_str().into(),
        generated: false,
        size: text.len() as u64,
        indexed_at: 1,
    };
    s.write_file(View::Tree(tree), row, chunks, symbols)
        .await
        .unwrap();
}

fn f(name: &str, mode: Match) -> Find {
    Find {
        name: name.into(),
        mode,
        kinds: vec![],
        glob: None,
        scope: Scope::All,
        k: 20,
    }
}

/// `(path, name)` of each hit.
async fn names(s: &CodeStore, view: View, q: &Find) -> (Match, Vec<(String, String)>) {
    let found = find(s, view, q).await.unwrap();
    (
        found.matched,
        found.hits.into_iter().map(|h| (h.path, h.name)).collect(),
    )
}

fn pairs(v: &[(&str, &str)]) -> Vec<(String, String)> {
    v.iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

#[tokio::test]
async fn exact_name_gives_lines_signature_and_doc() {
    let (_d, s, _t) = store().await;
    let found = find(&s, View::Base, &f("make_widget", Match::Exact))
        .await
        .unwrap();
    assert_eq!(found.matched, Match::Exact);
    assert_eq!(found.hits.len(), 1);
    let h = &found.hits[0];
    assert_eq!(
        (h.path.as_str(), h.kind.as_str(), h.line_start, h.line_end),
        ("src/a.rs", "function", 2, 4)
    );
    assert_eq!(h.sig, "pub fn make_widget(n: u32) -> Widget");
    assert_eq!(h.doc1.as_deref(), Some("Makes a widget."));
    assert_eq!(h.container, None);
}

#[tokio::test]
async fn auto_falls_through_to_prefix_then_contains() {
    let (_d, s, _t) = store().await;
    let (m, hits) = names(&s, View::Base, &f("make_wid", Match::Auto)).await;
    assert_eq!(m, Match::Prefix);
    // code before tests
    assert_eq!(
        hits,
        pairs(&[
            ("src/a.rs", "make_widget"),
            ("tests/a_test.rs", "make_widget_test")
        ])
    );
    let (m, hits) = names(&s, View::Base, &f("idget_cou", Match::Auto)).await;
    assert_eq!(m, Match::Contains);
    assert_eq!(hits, pairs(&[("src/b.c", "widget_count")]));
    let (m, hits) = names(&s, View::Base, &f("Widget", Match::Auto)).await;
    assert_eq!(m, Match::Exact);
    // the struct and the impl both carry the name
    assert_eq!(hits.len(), 2, "{hits:?}");
}

#[tokio::test]
async fn prefix_ignores_case_and_contains_finds_inner_parts() {
    let (_d, s, _t) = store().await;
    let (_, hits) = names(&s, View::Base, &f("WIDGET", Match::Prefix)).await;
    let got: Vec<&str> = hits.iter().map(|h| h.1.as_str()).collect();
    assert!(
        got.contains(&"widget_count") && got.contains(&"widget-mode-on") && got.contains(&"Widget"),
        "{got:?}"
    );
    let (_, hits) = names(&s, View::Base, &f("mode", Match::Contains)).await;
    assert_eq!(hits, pairs(&[("lisp/c.el", "widget-mode-on")]));
    // two characters: below the trigram index, still found
    let (_, hits) = names(&s, View::Base, &f("ze", Match::Contains)).await;
    assert_eq!(hits, pairs(&[("src/a.rs", "size")]));
}

#[tokio::test]
async fn regex_matches_names_and_a_bad_one_is_refused() {
    let (_d, s, _t) = store().await;
    let (m, mut hits) = names(&s, View::Base, &f("^widget[-_]", Match::Regex)).await;
    hits.sort();
    assert_eq!(m, Match::Regex);
    assert_eq!(
        hits,
        pairs(&[("lisp/c.el", "widget-mode-on"), ("src/b.c", "widget_count")])
    );
    let err = find(&s, View::Base, &f("(", Match::Regex))
        .await
        .unwrap_err();
    assert!(matches!(err, SymbolsError::BadRegex(_)), "{err:?}");
}

#[tokio::test]
async fn kind_glob_and_scope_filter() {
    let (_d, s, _t) = store().await;
    let mut q = f("size", Match::Exact);
    q.kinds = vec!["method".into()];
    let found = find(&s, View::Base, &q).await.unwrap();
    assert_eq!(found.hits.len(), 1);
    assert_eq!(found.hits[0].container.as_deref(), Some("Widget"));
    assert_eq!((found.hits[0].line_start, found.hits[0].line_end), (12, 14));
    q.kinds = vec!["function".into()];
    assert!(find(&s, View::Base, &q).await.unwrap().hits.is_empty());

    let mut q = f("widget", Match::Contains);
    q.glob = Some("src/*.c".into());
    assert_eq!(
        names(&s, View::Base, &q).await.1,
        pairs(&[("src/b.c", "widget_count")])
    );

    let mut q = f("make_widget", Match::Prefix);
    q.scope = Scope::Tests;
    assert_eq!(
        names(&s, View::Base, &q).await.1,
        pairs(&[("tests/a_test.rs", "make_widget_test")])
    );
    q.k = 1;
    q.scope = Scope::All;
    assert_eq!(
        names(&s, View::Base, &q).await.1,
        pairs(&[("src/a.rs", "make_widget")])
    );
}

#[tokio::test]
async fn a_signature_runs_to_the_line_with_the_name() {
    let (_d, s, _t) = store().await;
    let found = find(&s, View::Base, &f("widget_count", Match::Exact))
        .await
        .unwrap();
    assert_eq!(found.hits[0].sig, "static int widget_count (void)");
    let found = find(&s, View::Base, &f("widget-mode-on", Match::Exact))
        .await
        .unwrap();
    assert_eq!(found.hits[0].sig, "(defun widget-mode-on ()");
    assert_eq!(found.hits[0].doc1.as_deref(), Some("Turn it on."));
}

#[tokio::test]
async fn a_worktree_sees_its_own_definitions_and_not_its_deleted_ones() {
    let (_d, s, t) = store().await;
    put(&s, t, "src/new.rs", "fn tree_only() {}\n").await;
    s.write_file(
        View::Tree(t),
        FileRow::tombstone("src/a.rs"),
        vec![],
        vec![],
    )
    .await
    .unwrap();
    let only = f("tree_only", Match::Exact);
    assert_eq!(
        names(&s, View::Tree(t), &only).await.1,
        pairs(&[("src/new.rs", "tree_only")])
    );
    assert!(names(&s, View::Base, &only).await.1.is_empty());
    let made = f("make_widget", Match::Exact);
    assert!(names(&s, View::Tree(t), &made).await.1.is_empty());
    assert_eq!(names(&s, View::Base, &made).await.1.len(), 1);
    assert!(matches!(
        outline(&s, View::Tree(t), "src/a.rs").await,
        Err(SymbolsError::NotIndexed)
    ));
    assert_eq!(
        outline(&s, View::Tree(t), "src/new.rs")
            .await
            .unwrap()
            .entries
            .len(),
        1
    );
}

#[tokio::test]
async fn outline_is_in_file_order_with_nesting() {
    let (_d, s, _t) = store().await;
    let o = outline(&s, View::Base, "src/a.rs").await.unwrap();
    assert_eq!(o.lang, "rust");
    let got: Vec<(&str, &str, u32, u32, u32)> = o
        .entries
        .iter()
        .map(|e| {
            (
                e.name.as_str(),
                e.kind.as_str(),
                e.line_start,
                e.line_end,
                e.depth,
            )
        })
        .collect();
    assert_eq!(
        got,
        vec![
            ("make_widget", "function", 2, 4, 0),
            ("Widget", "struct", 6, 8, 0),
            ("Widget", "impl", 10, 15, 0),
            ("size", "method", 12, 14, 1),
        ]
    );
    assert_eq!(o.entries[3].doc1.as_deref(), Some("The size."));
    assert_eq!(o.entries[3].sig, "pub fn size(&self) -> u32");
    assert!(matches!(
        outline(&s, View::Base, "src/none.rs").await,
        Err(SymbolsError::NotIndexed)
    ));
}

/// A store built before lines and signatures were stored (an older parse) is parsed again by the next tier 1, and
/// every vector stays: the chunks' content keys do not change.
#[tokio::test]
async fn a_new_parse_version_re_derives_without_re_embedding() {
    let (_d, s, _t) = store().await;
    let keys = |s: &CodeStore| {
        let s = s.handle().clone();
        async move {
            s.read(|c| {
                let mut q = c.prepare("select key from chunk order by path, start")?;
                let v = q
                    .query_map([], |r| r.get::<_, Vec<u8>>(0))?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(v)
            })
            .await
            .unwrap()
        }
    };
    let before = keys(&s).await;
    s.handle()
        .write(|c| {
            c.execute(
                "update symbol set line_start = 0, line_end = 0, sig = ''",
                [],
            )?;
            c.execute(
                "update meta set value = '0' where key = 'parse_version'",
                [],
            )?;
            Ok(())
        })
        .await
        .unwrap();
    index(&s, BASE).await;
    assert_eq!(keys(&s).await, before);
    let found = find(&s, View::Base, &f("make_widget", Match::Exact))
        .await
        .unwrap();
    assert_eq!(
        (found.hits[0].line_start, found.hits[0].sig.as_str()),
        (2, "pub fn make_widget(n: u32) -> Widget")
    );
    assert_eq!(
        s.meta_get("parse_version").await.unwrap().as_deref(),
        Some(hrafn::chunk::PARSE_VERSION.to_string().as_str())
    );
}

#[cfg(feature = "host")]
mod listed {
    use super::*;
    use hrafn::{Config, GitCli, list};
    use std::path::Path;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }

    /// What the file list leaves out (a secret-looking name, the configuration's excludes) has no definitions and no
    /// outline: the tools answer from the index alone.
    #[tokio::test]
    async fn excluded_files_never_answer() {
        let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        git(dir.path(), &["init", "-q"]);
        std::fs::create_dir(dir.path().join("src")).unwrap();
        for (p, c) in [
            ("src/x.rs", "fn shown_fn() {}\n"),
            ("src/secret_key.rs", "fn hidden_fn() {}\n"),
            ("src/skip.rs", "fn skipped_fn() {}\n"),
        ] {
            std::fs::write(dir.path().join(p), c).unwrap();
        }
        git(dir.path(), &["add", "-A"]);
        git(dir.path(), &["commit", "-q", "-m", "one"]);
        let config = Config {
            exclude: vec!["src/skip.rs".into()],
            ..Config::default()
        };
        let l = list(dir.path(), &GitCli, &config, &|_: &str| true).unwrap();
        let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
        let root = dir.path().to_path_buf();
        refresh(&s, &l, &move |p: &str| std::fs::read(root.join(p)), &[])
            .await
            .unwrap();
        assert_eq!(
            names(&s, View::Base, &f("shown_fn", Match::Exact))
                .await
                .1
                .len(),
            1
        );
        for n in ["hidden_fn", "skipped_fn"] {
            assert!(
                names(&s, View::Base, &f(n, Match::Auto)).await.1.is_empty(),
                "{n}"
            );
        }
        for p in ["src/secret_key.rs", "src/skip.rs"] {
            assert!(matches!(
                outline(&s, View::Base, p).await,
                Err(SymbolsError::NotIndexed)
            ));
        }
    }
}
