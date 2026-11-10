//! The view-aware query (H16 overlay design §4): a query names the base or a worktree's view, and every route sees
//! only the rows of that view, before its `limit`; the lag is the view's.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::query::{Query, Scope, search};
use hrafn::{
    Class, CodeStore, DoorKind, FileRow, Lang, Listed, TreeId, View, lag, put_vectors, refresh,
};
use std::collections::HashMap;
use std::io;

const MODEL: &str = "m";
const DIMS: usize = 4;

/// The base's files: path and text.
const BASE: &[(&str, &str)] = &[
    (
        "src/p.rs",
        "fn base_only_fn() {\n    zebra();\n}\n\nfn shared_fn() {\n    giraffe();\n}\n",
    ),
    ("src/q.rs", "fn other_fn() {\n    okapi();\n}\n"),
];

fn listed(path: &str, text: &str) -> Listed {
    Listed {
        path: path.into(),
        blob: format!("b-{}", text.len()),
        class: Class::Code,
        lang: Lang::Rust,
        generated: false,
        size: text.len() as u64,
    }
}

/// A store with the base built from BASE, and two trees.
async fn store() -> (tempfile::TempDir, CodeStore, TreeId, TreeId) {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let l: Vec<Listed> = BASE.iter().map(|(p, t)| listed(p, t)).collect();
    let texts: HashMap<&str, &str> = BASE.iter().copied().collect();
    refresh(
        &s,
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
    let t = s
        .tree_open("t", "/w/t", "/g/t", DoorKind::Cli)
        .await
        .unwrap();
    let t2 = s
        .tree_open("t2", "/w/t2", "/g/t2", DoorKind::Cli)
        .await
        .unwrap();
    (dir, s, t, t2)
}

/// TREE's version of PATH with TEXT, written the way the overlay writes it (tier 1's own chunker).
async fn put(s: &CodeStore, tree: TreeId, path: &str, text: &str) {
    let l = listed(path, text);
    let (chunks, symbols) =
        hrafn::chunk::chunk_file(path, Lang::Rust, false, text, hrafn::chunk::BUDGET);
    let chunks: Vec<hrafn::ChunkIn> = chunks
        .into_iter()
        .map(|c| hrafn::ChunkIn {
            start: c.start,
            end: c.end,
            line_start: c.line_start,
            line_end: c.line_end,
            symbol: c.symbol,
            key: hrafn::vec_key(hrafn::chunk::CHUNKER_VERSION, &c.embed_text),
            embed: c.embed,
            embed_text: c.embed_text,
            symbols: c.fts.symbols,
            doc: c.fts.doc,
            body: c.fts.body,
        })
        .collect();
    let symbols: Vec<hrafn::SymbolIn> = symbols
        .into_iter()
        .map(|y| hrafn::SymbolIn {
            name: y.name,
            kind: y.kind,
            start: y.start,
            end: y.end,
            chunk: y.chunk as usize,
            definer: y.definer,
            doc1: y.doc1,
            line_start: y.line_start,
            line_end: y.line_end,
            sig: y.sig,
        })
        .collect();
    let row = FileRow {
        path: path.into(),
        blob: Some(l.blob),
        class: "code".into(),
        lang: "rust".into(),
        generated: false,
        size: text.len() as u64,
        indexed_at: 1,
    };
    s.write_file(View::Tree(tree), row, chunks, symbols)
        .await
        .unwrap();
}

async fn tombstone(s: &CodeStore, tree: TreeId, path: &str) {
    s.write_file(View::Tree(tree), FileRow::tombstone(path), vec![], vec![])
        .await
        .unwrap();
}

fn q(text: &str) -> Query {
    Query {
        text: text.into(),
        scope: Scope::All,
        k: 10,
    }
}

const NONE: fn(&str) -> Option<String> = |_| None;

/// The (path, preview) of each hit of TEXT in VIEW.
async fn hits(s: &CodeStore, view: View, text: &str) -> Vec<(String, String)> {
    search(s, &q(text), view, None, &NONE)
        .await
        .unwrap()
        .hits
        .into_iter()
        .map(|h| (h.path, h.preview))
        .collect()
}

/// Whether a hit is in PATH with TEXT in its preview.
fn in_file(hits: &[(String, String)], path: &str, text: &str) -> bool {
    hits.iter()
        .any(|(p, preview)| p == path && preview.contains(text))
}

/// Pattern D. A query in T finds T's text of p, never the base's; the base view is as it was.
#[tokio::test]
async fn overlay_shadows_base_path() {
    let (_d, s, t, _t2) = store().await;
    put(&s, t, "src/p.rs", "fn tree_only_fn() {\n    yak();\n}\n").await;
    let tv = View::Tree(t);
    assert!(hits(&s, tv, "zebra").await.is_empty(), "the base's keyword");
    // `fn` alone matches every file's body: what matters is which file and which text
    assert!(
        !in_file(&hits(&s, tv, "base_only_fn").await, "src/p.rs", "zebra"),
        "the base's symbol"
    );
    assert!(hits(&s, tv, "giraffe").await.is_empty());
    let y = hits(&s, tv, "yak").await;
    assert_eq!(y.len(), 1, "{y:?}");
    assert!(y[0].1.contains("yak"));
    let n = hits(&s, tv, "tree_only_fn").await;
    assert!(n.first().is_some_and(|h| h.0 == "src/p.rs"), "{n:?}");
    assert_eq!(
        hits(&s, tv, "okapi").await.len(),
        1,
        "an unshadowed base file"
    );
    // the base view
    assert!(hits(&s, View::Base, "yak").await.is_empty());
    assert!(!in_file(
        &hits(&s, View::Base, "tree_only_fn").await,
        "src/p.rs",
        "yak"
    ));
    assert_eq!(hits(&s, View::Base, "zebra").await.len(), 1);
    assert_eq!(hits(&s, View::Base, "base_only_fn").await[0].0, "src/p.rs");
}

/// The ranked file query's paths for TEXT in VIEW.
async fn ranked(s: &CodeStore, view: View, text: &str) -> Vec<String> {
    hrafn::rank::files(s, view, text, 10).await.unwrap()
}

/// Pattern D. p deleted in T (a tombstone): no hit, no path row and no ranked file in T; the base still has it.
#[tokio::test]
async fn tombstone_hides_base_file() {
    let (_d, s, t, _t2) = store().await;
    tombstone(&s, t, "src/p.rs").await;
    let tv = View::Tree(t);
    assert!(hits(&s, tv, "zebra").await.is_empty());
    assert!(!in_file(
        &hits(&s, tv, "base_only_fn").await,
        "src/p.rs",
        ""
    ));
    assert!(hits(&s, tv, "src/p.rs").await.is_empty(), "the path route");
    assert_eq!(hits(&s, tv, "src/q.rs").await.len(), 1);
    assert!(!hits(&s, View::Base, "src/p.rs").await.is_empty());
    assert_eq!(ranked(&s, tv, "rs").await, ["src/q.rs"]);
    assert_eq!(ranked(&s, View::Base, "rs").await, ["src/p.rs", "src/q.rs"]);
}

/// Pattern D. A new untracked file is found in its tree, not in the base or in another tree.
#[tokio::test]
async fn untracked_file_only_in_its_tree() {
    let (_d, s, t, t2) = store().await;
    put(
        &s,
        t,
        "src/new.rs",
        "fn brand_new_fn() {\n    narwhal();\n}\n",
    )
    .await;
    assert_eq!(hits(&s, View::Tree(t), "narwhal").await.len(), 1);
    assert_eq!(hits(&s, View::Tree(t), "src/new.rs").await.len(), 1);
    for v in [View::Base, View::Tree(t2)] {
        assert!(hits(&s, v, "narwhal").await.is_empty(), "{v:?}");
        assert!(
            !in_file(&hits(&s, v, "brand_new_fn").await, "src/new.rs", ""),
            "{v:?}"
        );
        assert!(hits(&s, v, "src/new.rs").await.is_empty(), "{v:?}");
        assert!(
            !ranked(&s, v, "new")
                .await
                .contains(&"src/new.rs".to_string()),
            "{v:?}"
        );
    }
    assert_eq!(ranked(&s, View::Tree(t), "new").await, ["src/new.rs"]);
}

/// Pattern D. The ranked file query: a basename that starts with the query first, then one that holds it, then a
/// path that holds it; shorter first among equals; at most N.
#[test]
fn ranks_basename_prefix_first() {
    let base: Vec<String> = [
        "lib/xmap.rs",
        "map/a.rs",
        "src/map.rs",
        "src/mapping/x.rs",
        "z/roadmap.rs",
    ]
    .iter()
    .map(|p| p.to_string())
    .collect();
    let d = hrafn::rank::Delta::default();
    assert_eq!(
        hrafn::rank::rank(&base, &d, "map", 10),
        [
            "src/map.rs",
            "lib/xmap.rs",
            "z/roadmap.rs",
            "map/a.rs",
            "src/mapping/x.rs"
        ]
    );
    assert_eq!(
        hrafn::rank::rank(&base, &d, "MAP", 2),
        ["src/map.rs", "lib/xmap.rs"]
    );
}

/// Pattern D. A vector whose key only the base's shadowed p uses gives no hit in T (the vector route takes the first
/// visible chunk of a key, and there is none); in the base, T's content gives no hit.
#[tokio::test]
async fn vector_hit_resolves_to_a_visible_chunk() {
    let (_d, s, t, _t2) = store().await;
    put(&s, t, "src/p.rs", "fn tree_only_fn() {\n    yak();\n}\n").await;
    let keys: Vec<([u8; 32], Vec<f32>)> = hrafn::missing(&s, MODEL, 100)
        .await
        .unwrap()
        .into_iter()
        .enumerate()
        .map(|(i, (k, _))| {
            let mut v = vec![0.0; DIMS];
            v[i % DIMS] = 1.0;
            (k, v)
        })
        .collect();
    put_vectors(&s, MODEL, &keys).await.unwrap();
    for (_, v) in &keys {
        let base = search(
            &s,
            &q("unrelated words"),
            View::Base,
            Some((MODEL, v)),
            &NONE,
        )
        .await
        .unwrap();
        let tree = search(
            &s,
            &q("unrelated words"),
            View::Tree(t),
            Some((MODEL, v)),
            &NONE,
        )
        .await
        .unwrap();
        for h in &tree.hits {
            assert!(
                !(h.path == "src/p.rs" && h.preview.contains("zebra")),
                "a shadowed base chunk in T: {:?}",
                tree.hits
            );
            assert!(!h.preview.contains("giraffe"), "{:?}", tree.hits);
        }
        assert!(!base.hits.iter().any(|h| h.preview.contains("yak")));
    }
}

/// Pattern D. A hit in T is found again in T's file as it is now (the caller's reader of T's root), at T's lines.
#[tokio::test]
async fn reanchor_reads_the_tree_root() {
    let (_d, s, t, _t2) = store().await;
    let tree_text = "fn tree_only_fn() {\n    yak();\n}\n";
    put(&s, t, "src/p.rs", tree_text).await;
    let now_t = format!("// moved\n// down\n{tree_text}");
    let read_t = move |p: &str| (p == "src/p.rs").then(|| now_t.clone());
    let a = search(&s, &q("tree_only_fn"), View::Tree(t), None, &read_t)
        .await
        .unwrap();
    assert!(!a.hits.is_empty(), "T's symbol found in T");
    let h = &a.hits[0];
    assert_eq!(h.path, "src/p.rs");
    assert!(h.reanchored, "{h:?}");
    assert_eq!(h.line_start, 3, "{h:?}");
}

/// Pattern D. The lag is the view's: the base's does not count a tree's content; a tree's counts its own rows'
/// chunks and leaves out the base chunks it shadows, and says how many files differ.
#[tokio::test]
async fn view_lag_counts_the_views_content() {
    let (_d, s, t, _t2) = store().await;
    // every base chunk embedded
    let keys: Vec<([u8; 32], Vec<f32>)> = hrafn::missing(&s, MODEL, 100)
        .await
        .unwrap()
        .into_iter()
        .map(|(k, _)| (k, vec![1.0; DIMS]))
        .collect();
    put_vectors(&s, MODEL, &keys).await.unwrap();
    let base_total = lag(&s, Some(MODEL), View::Base).await.unwrap().chunks_total;
    put(
        &s,
        t,
        "src/new.rs",
        "fn brand_new_fn() {\n    narwhal();\n}\n",
    )
    .await;
    tombstone(&s, t, "src/q.rs").await;
    let b = lag(&s, Some(MODEL), View::Base).await.unwrap();
    assert_eq!(
        (b.chunks_total, b.chunks_behind, b.files_behind),
        (base_total, 0, 0)
    );
    assert_eq!(b.differing_files, None);
    let l = lag(&s, Some(MODEL), View::Tree(t)).await.unwrap();
    assert_eq!(l.files_behind, 1, "{l:?}");
    assert!(l.chunks_behind >= 1, "{l:?}");
    assert_eq!(l.differing_files, Some(2));
    // q.rs's chunks are not in T's total
    assert!(l.chunks_total < base_total + l.chunks_behind, "{l:?}");
}

/// The plan of SQL, one line per step, with BINDS parameters bound (text, then the view's tree).
async fn plan_of(s: &CodeStore, sql: &'static str, binds: usize) -> String {
    s.handle()
        .read(move |c| {
            let mut st = c.prepare(&format!("explain query plan {sql}"))?;
            let n = st.parameter_count().max(binds);
            let vals: Vec<rusqlite::types::Value> = (0..n)
                .map(|i| {
                    if i + 1 == n {
                        rusqlite::types::Value::Integer(1)
                    } else {
                        rusqlite::types::Value::Text("x".into())
                    }
                })
                .collect();
            let rows = st
                .query_map(rusqlite::params_from_iter(vals), |r| r.get::<_, String>(3))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows.join("\n"))
        })
        .await
        .unwrap()
}

/// Pattern D (plan). Every route, in both views, the view's lag and the references read `chunk`, `symbol`, `ref` and
/// `file` by an index:
/// no line scans one of them (a virtual table's scan is the FTS index; a covering index scan reads no row), and
/// `file` is reached by its primary key `(tree, path)`.
#[tokio::test]
async fn overlay_predicates_use_indexes() {
    let (_d, s, t, _t2) = store().await;
    put(&s, t, "src/new.rs", "fn brand_new_fn() {}\n").await;
    let routes = [
        hrafn::query::PINNED_SQL,
        hrafn::query::NAME_EXACT_SQL,
        hrafn::query::NAME_PREFIX_SQL,
        hrafn::query::NAME_TRIGRAM_SQL,
        hrafn::query::PATH_ANY_SQL,
        hrafn::query::PATH_NAME_SQL,
        hrafn::query::VISIBLE_SQL,
        hrafn::query::FIRST_CHUNK_SQL,
        hrafn::query::META_SQL,
        hrafn::refs::REFS_SQL,
        hrafn::index::LAG_TOTAL_SQL,
        hrafn::index::LAG_BEHIND_SQL,
        hrafn::index::LAG_FILES_SQL,
        hrafn::index::LAG_TREE_SQL,
    ];
    for sql in routes {
        let plan = plan_of(&s, sql, 0).await;
        for line in plan.lines() {
            let line = line.trim();
            // a scan of a table (by its name or the routes' aliases) that no covering index serves
            let table = line
                .strip_prefix("SCAN ")
                .and_then(|r| r.split_whitespace().next());
            let scans = matches!(
                table,
                Some("chunk" | "symbol" | "file" | "ref" | "c" | "s" | "f" | "o" | "t" | "b" | "r")
            ) && !line.contains("COVERING INDEX");
            assert!(!scans, "{line}\n{plan}\n{sql}");
        }
        assert!(
            plan.contains("PRIMARY KEY (tree=")
                || plan.contains("file_path_blob (path=? AND blob=? AND tree=?)"),
            "file by (tree, path):\n{plan}\n{sql}"
        );
    }
    let plan = plan_of(&s, hrafn::refs::REFS_SQL, 0).await;
    assert!(
        plan.contains("ref_name (name=?)"),
        "references by name:\n{plan}"
    );
    // the keyword ranking reads the FTS index only; the view is applied to its candidates by VISIBLE_SQL
    let plan = plan_of(&s, hrafn::query::KEYWORD_RANK_SQL, 0).await;
    assert!(
        plan.lines()
            .filter(|l| l.contains("SCAN ") || l.contains("SEARCH "))
            .all(|l| l.contains("chunk_fts VIRTUAL TABLE")),
        "{plan}"
    );
}
