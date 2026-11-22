//! The repo map and the usages (`hrafn::map`): the most-referenced definitions within a token budget, and where a
//! name is used, in a view.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::map::{MapAsk, repo_map, usages};
use hrafn::{CodeStore, DoorKind, FileRow, Listed, Scope, TreeId, View, classify, refresh};
use std::collections::HashMap;
use std::io;

const CORE: &str = "\
pub fn core_engine_start() {
    core_engine_start();
}

fn restart() {
    core_engine_start();
}
";

const A: &str = "\
fn a_handler() {
    core_engine_start();
    helper_alpha_one();
}
";

const B: &str = "\
fn b_handler() {
    core_engine_start();
}
";

const HELPERS: &str = "pub fn helper_alpha_one() {}\n";

const TEST: &str = "\
fn core_test() {
    core_engine_start();
    core_engine_start();
}
";

const BASE: &[(&str, &str)] = &[
    ("src/core.rs", CORE),
    ("src/a.rs", A),
    ("src/b.rs", B),
    ("src/helpers.rs", HELPERS),
    ("tests/core_test.rs", TEST),
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

async fn index(s: &CodeStore, files: &[(String, String)]) {
    let l: Vec<Listed> = files.iter().map(|(p, t)| listed(p, t)).collect();
    let texts: HashMap<String, String> = files.iter().cloned().collect();
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

fn owned(files: &[(&str, &str)]) -> Vec<(String, String)> {
    files
        .iter()
        .map(|(p, t)| (p.to_string(), t.to_string()))
        .collect()
}

async fn store() -> (tempfile::TempDir, CodeStore, TreeId) {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    index(&s, &owned(BASE)).await;
    let t = s
        .tree_open("t", "/w/t", "/g/t", DoorKind::Cli)
        .await
        .unwrap();
    (dir, s, t)
}

/// TREE's version of PATH with TEXT, as the overlay writes it.
async fn put(s: &CodeStore, t: TreeId, path: &str, text: &str) {
    let l = listed(path, text);
    let (chunks, symbols, refs) = hrafn::index::built_refs(&l, text.as_bytes());
    let row = FileRow {
        path: path.into(),
        blob: Some(l.blob.clone()),
        class: l.class.as_str().into(),
        lang: l.lang.as_str().into(),
        generated: false,
        size: l.size,
        indexed_at: 1,
    };
    s.write_file_with_refs(View::Tree(t), row, chunks, symbols, refs)
        .await
        .unwrap();
}

fn ask(budget: usize) -> MapAsk {
    MapAsk {
        budget,
        focus: vec![],
        names: vec![],
        all: false,
    }
}

fn paths(m: &hrafn::map::RepoMap) -> Vec<&str> {
    m.files.iter().map(|f| f.path.as_str()).collect()
}

#[tokio::test]
async fn the_map_lists_the_most_referenced_definitions() {
    let (_d, s, _t) = store().await;
    let m = repo_map(&s, View::Base, &ask(2000)).await.unwrap();
    assert_eq!(paths(&m)[0], "src/core.rs", "{}", m.text);
    assert!(m.text.starts_with("src/core.rs:\n"), "{}", m.text);
    assert!(
        m.text.contains("   1│ pub fn core_engine_start()"),
        "{}",
        m.text
    );
    assert!(
        !m.text.contains("tests/"),
        "scope code leaves tests out:\n{}",
        m.text
    );
    assert_eq!(m.files_total, 4, "the code files");
    let last = m.text.lines().last().unwrap();
    assert_eq!(
        last,
        format!(
            "map: {} files of 4, ~{} tokens (estimate), budget 2,000",
            m.files.len(),
            m.tokens
        )
    );
    assert_eq!(m.tokens, m.text.chars().count().div_ceil(4));
}

/// Forty files in a chain, each defining a long function the next one calls: more than any small budget holds.
fn chain() -> Vec<(String, String)> {
    (0..40)
        .map(|i| {
            (
                format!("src/m{i:02}.rs"),
                format!(
                    "pub fn module_function_number_{i}(first_argument: u32, second_argument: &str) -> u32 {{\n    module_function_number_{}(1, \"x\")\n}}\n",
                    (i + 1) % 40
                ),
            )
        })
        .collect()
}

#[tokio::test]
async fn the_map_keeps_to_its_budget_and_grows_with_it() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    index(&s, &chain()).await;
    let mut rows = 0;
    for budget in [256, 512, 1024, 4000] {
        let m = repo_map(&s, View::Base, &ask(budget)).await.unwrap();
        assert!(m.tokens <= budget, "{budget}: {}", m.tokens);
        assert_eq!(m.tokens, m.text.chars().count().div_ceil(4));
        let n: usize = m.files.iter().map(|f| f.defs.len()).sum();
        assert!(n > rows || n == 40, "{budget}: {n} rows after {rows}");
        rows = n;
    }
    assert_eq!(rows, 40, "a large budget holds every definition");
}

/// Focus on a.rs: what it calls comes first, and a.rs itself is not listed.
#[tokio::test]
async fn focus_files_callees_come_first() {
    let (_d, s, _t) = store().await;
    let plain = repo_map(&s, View::Base, &ask(2000)).await.unwrap();
    let focus = MapAsk {
        focus: vec!["src/a.rs".into()],
        ..ask(2000)
    };
    let m = repo_map(&s, View::Base, &focus).await.unwrap();
    assert!(!paths(&m).contains(&"src/a.rs"), "{}", m.text);
    let at = |m: &hrafn::map::RepoMap, p: &str| paths(m).iter().position(|x| *x == p);
    // unfocused, core.rs (used by everyone) leads; focused on a.rs, its two callees are the first two
    assert_eq!(at(&plain, "src/core.rs"), Some(0), "{}", plain.text);
    assert!(at(&m, "src/helpers.rs").unwrap() <= 1, "{}", m.text);
    assert!(at(&m, "src/core.rs").unwrap() <= 1, "{}", m.text);
    // a name the request gives ranks its definitions higher
    let named = MapAsk {
        names: vec!["helper_alpha_one".into()],
        ..ask(2000)
    };
    let m = repo_map(&s, View::Base, &named).await.unwrap();
    assert_eq!(paths(&m)[0], "src/helpers.rs", "{}", m.text);
}

/// A tree's map shows its own new file and never a file it removed.
#[tokio::test]
async fn a_worktree_map_is_its_own() {
    let (_d, s, t) = store().await;
    put(&s, t, "src/new.rs", "pub fn new_tree_function() {}\n").await;
    put(
        &s,
        t,
        "src/a.rs",
        "fn a_handler() {\n    new_tree_function();\n    core_engine_start();\n}\n",
    )
    .await;
    s.write_file(
        View::Tree(t),
        FileRow::tombstone("src/helpers.rs"),
        vec![],
        vec![],
    )
    .await
    .unwrap();
    let m = repo_map(&s, View::Tree(t), &ask(2000)).await.unwrap();
    assert!(paths(&m).contains(&"src/new.rs"), "{}", m.text);
    assert!(!m.text.contains("helpers"), "{}", m.text);
    let base = repo_map(&s, View::Base, &ask(2000)).await.unwrap();
    assert!(!base.text.contains("new.rs"), "{}", base.text);
}

#[tokio::test]
async fn usages_are_grouped_by_their_definition_and_ranked() {
    let (_d, s, _t) = store().await;
    let u = usages(&s, View::Base, "core_engine_start", Scope::All, 20)
        .await
        .unwrap();
    assert_eq!(u.defined.len(), 1);
    assert_eq!(u.defined[0].path, "src/core.rs");
    let got: Vec<(&str, u32, Option<&str>, u32)> = u
        .usages
        .iter()
        .map(|x| (x.path.as_str(), x.line, x.enclosing.as_deref(), x.n))
        .collect();
    // core.rs: only restart's use (the definition's own call is inside its span); the test file last
    assert!(
        got.contains(&("src/core.rs", 6, Some("restart"), 1)),
        "{got:?}"
    );
    assert!(
        got.contains(&("src/a.rs", 2, Some("a_handler"), 1)),
        "{got:?}"
    );
    assert!(
        got.contains(&("src/b.rs", 2, Some("b_handler"), 1)),
        "{got:?}"
    );
    assert_eq!(
        got.last().unwrap(),
        &("tests/core_test.rs", 2, Some("core_test"), 2),
        "{got:?}"
    );
    assert_eq!(got.len(), 4, "{got:?}");
    for w in u.usages.windows(2) {
        // tests after code, then by rank
        let test = |c: &str| u8::from(c == "test");
        assert!(
            (test(&w[0].class), -w[0].rank) <= (test(&w[1].class), -w[1].rank),
            "{got:?}"
        );
    }
    // scope tests: only the test file's use
    let u = usages(&s, View::Base, "core_engine_start", Scope::Tests, 20)
        .await
        .unwrap();
    assert_eq!(u.usages.len(), 1);
    let u = usages(&s, View::Base, "core_engine_start", Scope::All, 2)
        .await
        .unwrap();
    assert_eq!(u.usages.len(), 2, "k");
}
