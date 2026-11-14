//! The reference graph and its PageRank (`hrafn::graph`): files ranked by how the code refers to itself.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::graph::{RankAsk, file_ranks, weight};
use hrafn::{ChunkIn, CodeStore, FileRow, RefIn, SymbolIn, View};

fn row(path: &str, class: &str) -> FileRow {
    FileRow {
        path: path.into(),
        blob: Some(format!("b-{path}")),
        class: class.into(),
        lang: "rust".into(),
        generated: false,
        size: 1,
        indexed_at: 1,
    }
}

fn chunk() -> ChunkIn {
    ChunkIn {
        start: 0,
        end: 1,
        line_start: 1,
        line_end: 1,
        symbol: None,
        key: [0; 32],
        embed: false,
        embed_text: String::new(),
        symbols: String::new(),
        doc: String::new(),
        body: String::new(),
    }
}

fn sym(name: &str) -> SymbolIn {
    SymbolIn {
        name: name.into(),
        kind: "function".into(),
        start: 0,
        end: 1,
        chunk: 0,
        definer: "fn".into(),
        doc1: None,
        line_start: 1,
        line_end: 1,
        sig: format!("fn {name}()"),
    }
}

fn r(name: &str, n: u32) -> RefIn {
    RefIn {
        name: name.into(),
        n,
        lines: vec![1],
    }
}

/// PATH (CLASS) defining DEFS and referencing REFS, in the base.
async fn put(s: &CodeStore, path: &str, class: &str, defs: &[&str], refs: &[(&str, u32)]) {
    s.write_file_with_refs(
        View::Base,
        row(path, class),
        vec![chunk()],
        defs.iter().map(|d| sym(d)).collect(),
        refs.iter().map(|(n, k)| r(n, *k)).collect(),
    )
    .await
    .unwrap();
}

/// a → b (alpha ×4: 2), a → c (beta: 1), b → c (beta: 1), c → b (alpha ×9: 3); d defines delta and refers to
/// nothing (dangling); b's own use of alpha is dropped.
async fn four() -> (tempfile::TempDir, CodeStore) {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    put(&s, "a.rs", "code", &[], &[("alpha", 4), ("beta", 1)]).await;
    put(&s, "b.rs", "code", &["alpha"], &[("beta", 1), ("alpha", 4)]).await;
    put(&s, "c.rs", "code", &["beta"], &[("alpha", 9)]).await;
    put(&s, "d.rs", "code", &["delta"], &[]).await;
    (dir, s)
}

fn get(ranks: &[(String, f64)], path: &str) -> f64 {
    ranks.iter().find(|(p, _)| p == path).map_or(-1.0, |r| r.1)
}

/// The values come from an independent power iteration run to 1e-15 (the plan's ledger has the script).
#[tokio::test]
async fn pagerank_of_four_files_matches_hand_values() {
    let (_d, s) = four().await;
    let (ranks, _) = file_ranks(&s, View::Base, &RankAsk::default())
        .await
        .unwrap();
    for (p, want) in [
        ("a.rs", 0.047619048),
        ("b.rs", 0.456027456),
        ("c.rs", 0.448734449),
        ("d.rs", 0.047619048),
    ] {
        assert!((get(&ranks, p) - want).abs() < 1e-6, "{p}: {ranks:?}");
    }
    assert_eq!(ranks[0].0, "b.rs", "best first");
}

#[tokio::test]
async fn focus_moves_rank_to_its_neighbours() {
    let (_d, s) = four().await;
    let ask = RankAsk {
        focus: vec!["a.rs".into()],
        ..RankAsk::default()
    };
    let (ranks, _) = file_ranks(&s, View::Base, &ask).await.unwrap();
    for (p, want) in [
        ("a.rs", 0.15),
        ("b.rs", 0.436486486),
        ("c.rs", 0.413513514),
        ("d.rs", 0.0),
    ] {
        assert!((get(&ranks, p) - want).abs() < 1e-6, "{p}: {ranks:?}");
    }
}

#[test]
fn weights_follow_the_name() {
    let eq = |a: f64, b: f64| (a - b).abs() < 1e-9;
    assert!(eq(weight("alpha", 4, 1, false), 2.0));
    assert!(eq(weight("alpha", 4, 1, true), 20.0), "named");
    for long in ["long_snake_name", "kebab-case-name", "camelCaseName"] {
        assert!(eq(weight(long, 1, 1, false), 10.0), "{long}");
    }
    assert!(
        eq(weight("ab_cdef", 1, 1, false), 1.0),
        "7 characters is not long"
    );
    assert!(eq(weight("_priv", 1, 1, false), 0.1), "private");
    assert!(
        eq(weight("alpha", 1, 6, false), 0.1),
        "defined in more than 5 files"
    );
    assert!(eq(weight("alpha", 1, 5, false), 1.0));
}

/// Scope code leaves tests and docs out of the walk and the answer.
#[tokio::test]
async fn code_scope_leaves_tests_out() {
    let (_d, s) = four().await;
    put(&s, "tests/t.rs", "test", &[], &[("beta", 100)]).await;
    let (all, _) = file_ranks(&s, View::Base, &RankAsk::default())
        .await
        .unwrap();
    assert!(get(&all, "tests/t.rs") > 0.0);
    let code = RankAsk {
        code_only: true,
        ..RankAsk::default()
    };
    let (ranks, _) = file_ranks(&s, View::Base, &code).await.unwrap();
    assert_eq!(get(&ranks, "tests/t.rs"), -1.0);
    assert!(
        (get(&ranks, "b.rs") - 0.456027456).abs() < 1e-6,
        "{ranks:?}"
    );
}

/// The graph is built once per store state: reused until a write, built again after one.
#[tokio::test]
async fn the_graph_is_cached_until_the_store_changes() {
    let (_d, s) = four().await;
    let ask = RankAsk::default();
    assert!(file_ranks(&s, View::Base, &ask).await.unwrap().1, "built");
    assert!(!file_ranks(&s, View::Base, &ask).await.unwrap().1, "reused");
    put(&s, "e.rs", "code", &[], &[("delta", 1)]).await;
    let (ranks, built) = file_ranks(&s, View::Base, &ask).await.unwrap();
    assert!(built, "built again after a write");
    assert!(get(&ranks, "d.rs") > 0.047619048 + 1e-3, "{ranks:?}");
}
