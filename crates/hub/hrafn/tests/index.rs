//! Tier 1 (the incremental index: chunks, FTS and symbols for the files whose blob changed) and the store side of
//! tier 2 (`missing`, the cache's `put`, `hold`, `lag`); in `fresh`, when tier 1 runs.
//!
//! test-pattern: the store tests and the git ones are pure (D): no clock and no timing; the store thread answers in
//! order and `git` runs to its exit. `fresh::git_event_waits_for_index_lock` is every-order (A) over the settle core.

use hrafn::{
    Class, CodeStore, KeyKind, Lang, Listed, Refresh, VectorCache, hold, lag, missing,
    missing_with, path_key, path_text, refresh,
};
use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};

/// The fingerprint every vector here is of.
const FP: &str = "5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed";
const DIMS: usize = 4;

fn el(path: &str, blob: &str) -> Listed {
    Listed {
        path: path.into(),
        blob: blob.into(),
        class: Class::Code,
        lang: Lang::Elisp,
        generated: false,
        embed: true,
        size: 1,
    }
}

/// The files' bytes by path, and how often each was read.
struct Tree {
    files: Mutex<HashMap<String, String>>,
    reads: AtomicU32,
}

impl Tree {
    fn new(files: &[(&str, &str)]) -> Tree {
        Tree {
            files: Mutex::new(
                files
                    .iter()
                    .map(|(p, t)| (p.to_string(), t.to_string()))
                    .collect(),
            ),
            reads: AtomicU32::new(0),
        }
    }

    fn set(&self, path: &str, text: &str) {
        self.files.lock().unwrap().insert(path.into(), text.into());
    }

    fn read(&self, path: &str) -> io::Result<Vec<u8>> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.files
            .lock()
            .unwrap()
            .get(path)
            .map(|t| t.clone().into_bytes())
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }

    fn reads(&self) -> u32 {
        self.reads.swap(0, Ordering::SeqCst)
    }
}

/// A repo store and the vector cache of [`FP`] beside it: `<dir>/code/a.db` and `<dir>/vectors/`.
struct Fx {
    dir: tempfile::TempDir,
    s: CodeStore,
    c: VectorCache,
}

impl std::ops::Deref for Fx {
    type Target = CodeStore;
    fn deref(&self) -> &CodeStore {
        &self.s
    }
}

async fn store() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("code")).unwrap();
    let s = CodeStore::open(&dir.path().join("code/a.db")).unwrap();
    let c = VectorCache::open_writer(&dir.path().join("vectors"), FP, "{}").unwrap();
    Fx { dir, s, c }
}

impl Fx {
    /// Another repo store over the same cache.
    fn other(&self, id: &str) -> CodeStore {
        CodeStore::open(&self.dir.path().join(format!("code/{id}.db"))).unwrap()
    }
}

async fn run(s: &Fx, tree: &Tree, listed: &[Listed]) -> Refresh {
    run_in(&s.s, &s.c, tree, listed).await
}

async fn run_in(s: &CodeStore, c: &VectorCache, tree: &Tree, listed: &[Listed]) -> Refresh {
    refresh(s, listed, &|p: &str| tree.read(p), &[c])
        .await
        .unwrap()
}

type Missing = Vec<(KeyKind, [u8; 32], String)>;

/// A unit vector per key of KIND, made from the key's first bytes: the store does not care what it holds.
fn vectors(keys: &Missing, kind: KeyKind) -> Vec<([u8; 32], Vec<f32>)> {
    keys.iter()
        .filter(|(k, _, _)| *k == kind)
        .map(|(_, k, _)| {
            let v: Vec<f32> = k[..DIMS].iter().map(|b| f32::from(*b) + 1.0).collect();
            let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            (*k, v.into_iter().map(|x| x / n).collect())
        })
        .collect()
}

/// Embeds everything tier 2 would: what `missing` gives goes back through the cache's `put`, each kind on its own.
/// How many chunk keys it embedded.
async fn embed_all(s: &Fx) -> usize {
    embed_all_in(&s.s, &s.c).await
}

async fn embed_all_in(s: &CodeStore, c: &VectorCache) -> usize {
    let keys = missing(s, c, 1000).await.unwrap();
    for kind in [KeyKind::Chunk, KeyKind::Path] {
        let rows = vectors(&keys, kind);
        if !rows.is_empty() {
            c.put(kind, DIMS as u32, &rows).await.unwrap();
        }
    }
    keys.iter().filter(|(k, _, _)| *k == KeyKind::Chunk).count()
}

/// The chunk keys tier 2 is offered (the path keys left out).
async fn chunk_keys(s: &Fx) -> Missing {
    chunk_keys_in(&s.s, &s.c).await
}

async fn chunk_keys_in(s: &CodeStore, c: &VectorCache) -> Missing {
    missing(s, c, 1000)
        .await
        .unwrap()
        .into_iter()
        .filter(|(k, _, _)| *k == KeyKind::Chunk)
        .collect()
}

/// The files and directories whose path keys tier 2 is offered: the first line of each path text.
fn offered_paths(keys: &Missing) -> Vec<String> {
    keys.iter()
        .filter(|(k, _, _)| *k == KeyKind::Path)
        .map(|(_, _, t)| t.lines().next().unwrap_or_default().to_string())
        .collect()
}

/// A row whose length is not the fingerprint's dims is an error, and nothing of the batch is written.
#[tokio::test]
async fn wrong_dims_are_refused_on_write() {
    let s = store().await;
    let tree = Tree::new(&[("a.el", "(defun a () 1)\n"), ("b.el", "(defun b () 2)\n")]);
    run(&s, &tree, &[el("a.el", "a1"), el("b.el", "b1")]).await;
    let keys = chunk_keys(&s).await;
    assert!(keys.len() >= 2);
    let mut rows = vectors(&keys, KeyKind::Chunk);
    rows[1].1.push(0.5); // one row of 5 in a batch of 4
    let err =
        s.c.put(KeyKind::Chunk, DIMS as u32, &rows)
            .await
            .unwrap_err();
    assert!(
        err.to_string().contains("5 dims") && err.to_string().contains("4"),
        "{err}"
    );
    assert_eq!(
        chunk_keys(&s).await.len(),
        keys.len(),
        "nothing of the batch was written"
    );
    s.c.put(KeyKind::Chunk, DIMS as u32, &vectors(&keys, KeyKind::Chunk))
        .await
        .unwrap();
    assert!(chunk_keys(&s).await.is_empty());
}

/// Pattern D (Task 12). Two repos with one identical file share its vectors through the cache: once the first has
/// embedded it, the second's tier 2 is offered no chunk of it, only its own file's chunks and its paths.
#[tokio::test]
async fn two_repos_share_one_vector() {
    let s = store().await;
    let shared = ";;; util.el --- shared helpers\n\n(defun util-clamp (x)\n  \"Clamp X.\"\n  x)\n";
    let tree = Tree::new(&[
        ("lisp/util.el", shared),
        ("a.el", A),
        ("util.el", shared),
        ("b.el", B),
    ]);
    run(&s, &tree, &[el("lisp/util.el", "u"), el("a.el", "a1")]).await;
    assert!(embed_all(&s).await >= 2);
    let b = s.other("b");
    let r = run_in(&b, &s.c, &tree, &[el("util.el", "u"), el("b.el", "b1")]).await;
    let b_only = keys_of(&b, "b.el").await;
    assert_eq!(
        r.keys_missing as usize,
        b_only.len(),
        "only b.el's chunks lack vectors: {r:?}"
    );
    let offered: Vec<[u8; 32]> = chunk_keys_in(&b, &s.c)
        .await
        .into_iter()
        .map(|(_, k, _)| k)
        .collect();
    let want: Vec<[u8; 32]> = b_only.iter().map(|(k, _)| *k).collect();
    assert_eq!(
        offered, want,
        "nothing of the shared file is embedded again"
    );
    let mut paths = offered_paths(&missing_with(&b, &s.c, 1000, false).await.unwrap());
    paths.sort();
    assert_eq!(paths, ["b.el", "util.el"], "the second repo's own paths");
    assert_eq!(embed_all_in(&b, &s.c).await, b_only.len());
    assert_eq!(
        lag(&b, Some(&s.c), hrafn::View::Base)
            .await
            .unwrap()
            .chunks_behind,
        0
    );
}

/// Pattern D (Task 12). A branch switch that changes one file and adds another embeds exactly their chunks: every
/// other key is in the cache already.
#[tokio::test]
async fn branch_switch_embeds_only_the_diff() {
    let s = store().await;
    let c_text = ";;; c.el\n(defun c-one () \"C.\" 3)\n";
    let tree = Tree::new(&[("a.el", A), ("b.el", B), ("c.el", c_text)]);
    run(
        &s,
        &tree,
        &[el("a.el", "a1"), el("b.el", "b1"), el("c.el", "c1")],
    )
    .await;
    embed_all(&s).await;
    assert!(missing(&s, &s.c, 1000).await.unwrap().is_empty());
    tree.set("b.el", ";;; b.el\n(defvar b-var 2 \"Another var.\")\n");
    tree.set("d.el", ";;; d.el\n(defun d-new () \"New.\" 4)\n");
    let r = run(
        &s,
        &tree,
        &[
            el("a.el", "a1"),
            el("b.el", "b2"),
            el("c.el", "c1"),
            el("d.el", "d1"),
        ],
    )
    .await;
    let mut want: Vec<[u8; 32]> = keys_of(&s, "b.el")
        .await
        .into_iter()
        .map(|(k, _)| k)
        .collect();
    want.extend(keys_of(&s, "d.el").await.into_iter().map(|(k, _)| k));
    want.sort();
    let mut offered: Vec<[u8; 32]> = chunk_keys(&s)
        .await
        .into_iter()
        .map(|(_, k, _)| k)
        .collect();
    offered.sort();
    assert_eq!(offered, want);
    assert_eq!(r.keys_missing as usize, want.len());
    assert_eq!(
        offered_paths(&missing_with(&s, &s.c, 1000, false).await.unwrap()),
        ["d.el"],
        "the one new path"
    );
}

/// Pattern D (Task 12). A schema-7 store (vectors in its own `vec` table) opens at schema 8 without that table, and
/// every key is embedded again into the cache.
#[tokio::test]
async fn v8_drops_vec_and_reembeds() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("old.db");
    {
        let c = rusqlite::Connection::open(&file).unwrap();
        c.execute_batch("create table meta(key text primary key, value text not null)")
            .unwrap();
        for (v, sql) in hrafn::MIGRATIONS.iter().filter(|(v, _)| *v <= 7) {
            c.execute_batch(sql).unwrap();
            c.execute(
                "insert or replace into meta(key, value) values ('schema', ?1)",
                [v.to_string()],
            )
            .unwrap();
        }
        c.execute(
            "insert into vec(model, kind, dims, key, bits, vec, scale, last_used)
             values ('m', 0, 4, x'00', 8, x'00', 1.0, 1)",
            [],
        )
        .unwrap();
    }
    let s = CodeStore::open(&file).unwrap();
    let (tables, schema): (i64, Option<String>) = s
        .handle()
        .read(|c| {
            Ok((
                c.query_row(
                    "select count(*) from sqlite_master where name = 'vec'",
                    [],
                    |r| r.get(0),
                )?,
                urdr::meta(c, "schema")?,
            ))
        })
        .await
        .unwrap();
    assert_eq!((tables, schema.as_deref()), (0, Some("8")));
    let cache = VectorCache::open_writer(&dir.path().join("vectors"), FP, "{}").unwrap();
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    let r = run_in(&s, &cache, &tree, &[el("a.el", "a1"), el("b.el", "b1")]).await;
    assert_eq!(r.keys_missing, r.chunks_written, "every chunk embeds again");
    assert_eq!(embed_all_in(&s, &cache).await as u32, r.chunks_written);
}

/// Pattern D (Task 13). `hold` reports the store's live key set to the cache as a diff: what a refresh added is held,
/// what it dropped is not, and a key another store holds stays held.
#[tokio::test]
async fn hold_reports_the_live_key_set() {
    let s = store().await;
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    run(&s, &tree, &[el("a.el", "a1"), el("b.el", "b1")]).await;
    embed_all(&s).await;
    let root = tempfile::tempdir().unwrap();
    hold(&s, &s.c, root.path(), 1000).await.unwrap();
    let a: Vec<[u8; 32]> = keys_of(&s, "a.el")
        .await
        .into_iter()
        .map(|(k, _)| k)
        .collect();
    let b: Vec<[u8; 32]> = keys_of(&s, "b.el")
        .await
        .into_iter()
        .map(|(k, _)| k)
        .collect();
    assert!(
        s.c.referenced(KeyKind::Chunk, &a)
            .await
            .unwrap()
            .iter()
            .all(|h| *h)
    );
    assert!(
        s.c.referenced(KeyKind::Chunk, &b)
            .await
            .unwrap()
            .iter()
            .all(|h| *h)
    );
    assert_eq!(
        s.c.referenced(KeyKind::Path, &[path_key("a.el"), path_key("b.el")])
            .await
            .unwrap(),
        [true, true]
    );
    // b.el goes: its keys are no one's after the next report
    run(&s, &tree, &[el("a.el", "a1")]).await;
    hold(&s, &s.c, root.path(), 2000).await.unwrap();
    assert!(
        s.c.referenced(KeyKind::Chunk, &b)
            .await
            .unwrap()
            .iter()
            .all(|h| !*h)
    );
    assert_eq!(
        s.c.referenced(KeyKind::Path, &[path_key("b.el")])
            .await
            .unwrap(),
        [false]
    );
    assert!(
        s.c.referenced(KeyKind::Chunk, &a)
            .await
            .unwrap()
            .iter()
            .all(|h| *h)
    );
    s.c.collect(0).await.unwrap();
    assert!(
        s.c.has(KeyKind::Chunk, &b)
            .await
            .unwrap()
            .iter()
            .all(|h| !*h)
    );
    assert!(
        s.c.has(KeyKind::Chunk, &a)
            .await
            .unwrap()
            .iter()
            .all(|h| *h)
    );
}

/// The `(key, embed_text)` of PATH's chunks, in order.
async fn keys_of(s: &CodeStore, path: &str) -> Vec<([u8; 32], String)> {
    let path = path.to_string();
    s.handle()
        .read(move |c| {
            let mut q =
                c.prepare("select key, embed_text from chunk where path = ?1 order by id")?;
            let rows = q
                .query_map([&path], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows
                .into_iter()
                .map(|(k, t)| (<[u8; 32]>::try_from(k.as_slice()).unwrap(), t))
                .collect())
        })
        .await
        .unwrap()
}

/// Pattern D (Hrafn redesign Task 8). One text under two paths is one chunk key, made of the text alone: tier 2 is
/// offered it once.
#[tokio::test]
async fn same_text_two_paths_one_key() {
    let s = store().await;
    let text = ";;; shared.el --- A helper both crates carry\n\n(defun shared-help ()\n  \"Help.\"\n  1)\n";
    let tree = Tree::new(&[("a/shared.el", text), ("b/lisp/copy.el", text)]);
    run(
        &s,
        &tree,
        &[el("a/shared.el", "same"), el("b/lisp/copy.el", "same")],
    )
    .await;
    let (a, b) = (
        keys_of(&s, "a/shared.el").await,
        keys_of(&s, "b/lisp/copy.el").await,
    );
    assert!(!a.is_empty());
    assert_eq!(a, b, "the same chunks, keys and texts under both paths");
    for (key, t) in &a {
        assert_eq!(*key, hrafn::chunk_key(t), "a key is its text's");
    }
    assert_eq!(chunk_keys(&s).await.len(), a.len(), "each key offered once");
}

/// Pattern D (Hrafn redesign Task 8). The path is no longer in a chunk's embedded text, but the FTS `path` column and
/// the path route still have it.
#[tokio::test]
async fn fts_path_column_still_holds_the_path() {
    let s = store().await;
    let tree = Tree::new(&[("core/drgnx-walrus.el", A)]);
    run(&s, &tree, &[el("core/drgnx-walrus.el", "w1")]).await;
    let hits: i64 = s
        .handle()
        .read(|c| {
            Ok(c.query_row(
                "select count(*) from chunk_fts where chunk_fts match 'path : \"drgnx walrus\"'",
                [],
                |r| r.get(0),
            )?)
        })
        .await
        .unwrap();
    let chunks = keys_of(&s, "core/drgnx-walrus.el").await;
    assert_eq!(
        hits as usize,
        chunks.len(),
        "every chunk's FTS row has the path"
    );
    for (_, t) in &chunks {
        assert!(!t.contains("walrus") && !t.contains("core/"), "{t:?}");
    }
    let a = hrafn::search(
        &s,
        &hrafn::Query {
            text: "drgnx-walrus.el".into(),
            scope: hrafn::Scope::All,
            k: 5,
            path_weight: hrafn::query::PATH_WEIGHT,
            dir_weight: hrafn::query::DIR_WEIGHT,
        },
        hrafn::View::Base,
        None,
        &|_: &str| None,
    )
    .await
    .unwrap();
    assert_eq!(a.hits[0].path, "core/drgnx-walrus.el", "{:?}", a.hits);
    assert!(a.hits[0].routes.contains(&"path"), "{:?}", a.hits[0].routes);
}

/// Pattern D (Hrafn redesign Task 9). The directories' keys are offered only when their weight counts: with none, no
/// directory is embedded; with them, each directory once, after its file's key. Every path key is its path text's.
#[tokio::test]
async fn dir_weight_zero_embeds_no_directories() {
    let s = store().await;
    let tree = Tree::new(&[("core/sub/a.el", A), ("b.el", B)]);
    run(&s, &tree, &[el("core/sub/a.el", "a1"), el("b.el", "b1")]).await;
    let without = missing_with(&s, &s.c, 1000, false).await.unwrap();
    let mut files = offered_paths(&without);
    files.sort();
    assert_eq!(files, ["b.el", "core/sub/a.el"]);
    let with = missing_with(&s, &s.c, 1000, true).await.unwrap();
    let mut all = offered_paths(&with);
    all.sort();
    assert_eq!(all, ["b.el", "core/", "core/sub/", "core/sub/a.el"]);
    for (kind, key, text) in &with {
        if *kind == KeyKind::Path {
            let p = text.lines().next().unwrap();
            assert_eq!(*text, path_text(p));
            assert_eq!(*key, path_key(p));
        }
    }
    // a limit is the batch's size, path keys counted: two files' chunk keys and path keys do not fit in two
    let two = missing_with(&s, &s.c, 2, true).await.unwrap();
    assert_eq!(two.len(), 2, "{two:?}");
    if hrafn::query::DIR_WEIGHT <= 0.0 {
        assert_eq!(missing(&s, &s.c, 1000).await.unwrap(), without);
    }
}

/// Pattern D (Hrafn redesign Task 9). A path's text keeps the path whole and adds its words: split on `/ _ - .` and
/// at camelCase boundaries.
#[test]
fn path_text_is_the_path_and_its_words() {
    assert_eq!(
        path_text("crates/hub/hrafn-embed/src/QueueTest_v2.rs"),
        "crates/hub/hrafn-embed/src/QueueTest_v2.rs\ncrates hub hrafn embed src Queue Test v2 rs"
    );
    assert_eq!(
        path_text("HTTPServer.java"),
        "HTTPServer.java\nHTTP Server java"
    );
    assert_eq!(path_text("core/"), "core/\ncore");
    assert_ne!(path_key("a/b.el"), path_key("a/c.el"));
    assert_ne!(path_key("a/b.el"), hrafn::chunk_key(&path_text("a/b.el")));
}

async fn ids_of(s: &CodeStore, path: &str) -> Vec<i64> {
    let path = path.to_string();
    s.handle()
        .read(move |c| {
            let mut q = c.prepare("select id from chunk where path = ?1 order by id")?;
            let ids = q
                .query_map([&path], |r| r.get(0))?
                .collect::<Result<Vec<i64>, _>>()?;
            Ok(ids)
        })
        .await
        .unwrap()
}

const A: &str = ";;; a.el\n(defun a-one () \"One.\" 1)\n\n(defun a-two () \"Two.\" 2)\n";
const B: &str = ";;; b.el\n(defvar b-var 1 \"A var.\")\n";

/// Pattern D.
#[tokio::test]
async fn second_refresh_touches_nothing() {
    let s = store().await;
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    let listed = [el("a.el", "blob-a"), el("b.el", "blob-b")];
    let first = run(&s, &tree, &listed).await;
    assert_eq!(first.files_changed, 2);
    assert!(first.chunks_written >= 2);
    assert_eq!(first.keys_missing, first.chunks_written);
    assert_eq!(tree.reads(), 2);
    let ids = ids_of(&s, "a.el").await;

    let second = run(&s, &tree, &listed).await;
    assert_eq!(
        (second.files_changed, second.chunks_written),
        (0, 0),
        "{second:?}"
    );
    assert_eq!(second.keys_missing, first.keys_missing);
    assert_eq!(tree.reads(), 0, "an unchanged blob is not even read");
    assert_eq!(ids_of(&s, "a.el").await, ids);
    let l = lag(&s, Some(&s.c), hrafn::View::Base).await.unwrap();
    assert_eq!(l.chunks_behind, first.keys_missing);
    assert_eq!(l.files_behind, 2);
}

/// Pattern D. A branch switch and back: content keys make the second switch embed nothing.
#[tokio::test]
async fn branch_back_and_forth_embeds_nothing() {
    let s = store().await;
    let tree = Tree::new(&[("a.el", A)]);
    run(&s, &tree, &[el("a.el", "main")]).await;
    let on_main = embed_all(&s).await;
    assert!(on_main >= 1);

    let other = ";;; a.el\n(defun a-other () \"Other.\" 3)\n";
    tree.set("a.el", other);
    let switched = run(&s, &tree, &[el("a.el", "topic")]).await;
    assert_eq!(switched.files_changed, 1);
    assert_eq!(embed_all(&s).await, 1, "only the topic branch's chunk");

    tree.set("a.el", A);
    let back = run(&s, &tree, &[el("a.el", "main")]).await;
    assert_eq!(back.files_changed, 1, "the rows are rebuilt");
    assert_eq!(back.keys_missing, 0, "and nothing is embedded again");
    assert!(missing(&s, &s.c, 1000).await.unwrap().is_empty());
    assert_eq!(
        lag(&s, Some(&s.c), hrafn::View::Base)
            .await
            .unwrap()
            .chunks_behind,
        0
    );
}

/// Pattern D.
#[tokio::test]
async fn changed_file_only_rewritten() {
    let s = store().await;
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    run(&s, &tree, &[el("a.el", "a1"), el("b.el", "b1")]).await;
    let b_ids = ids_of(&s, "b.el").await;
    let a_ids = ids_of(&s, "a.el").await;
    tree.reads();

    tree.set("a.el", ";;; a.el\n(defun a-one () \"One, changed.\" 1)\n");
    let r = run(&s, &tree, &[el("a.el", "a2"), el("b.el", "b1")]).await;
    assert_eq!(r.files_changed, 1);
    assert_eq!(tree.reads(), 1);
    assert_eq!(ids_of(&s, "b.el").await, b_ids, "b.el's rows untouched");
    assert_ne!(ids_of(&s, "a.el").await, a_ids);

    // a file gone from the list goes from the store
    let r = run(&s, &tree, &[el("a.el", "a2")]).await;
    assert_eq!(r.files_changed, 1);
    assert!(ids_of(&s, "b.el").await.is_empty());
}

/// The first lines of a file's chunks, as stored.
async fn line_starts(s: &CodeStore, path: &str) -> Vec<i64> {
    let path = path.to_string();
    s.handle()
        .read(move |c| {
            let mut st = c.prepare("select line_start from chunk where path = ?1 order by id")?;
            let rows = st
                .query_map([&path], |r| r.get(0))?
                .collect::<Result<Vec<i64>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap()
}

/// Pattern D. An index made by the chunker that numbered a chunk's first line one too early (version 1) is chunked
/// again, though no file changed: its lines are the corrected ones.
#[tokio::test]
async fn an_index_of_the_old_chunker_is_chunked_again() {
    let s = store().await;
    let text = ";;; a.el\n\n(defun a-one () \"One.\" 1)\n\n(defun a-two () \"Two.\" 2)\n";
    let tree = Tree::new(&[("a.el", text)]);
    let listed = [el("a.el", "a1")];
    run(&s, &tree, &listed).await;
    let right = line_starts(&s, "a.el").await;
    assert!(!right.is_empty());
    // the old chunker's rows: the same chunks, each first line one too early, under its version number
    s.handle()
        .write(|c| {
            c.execute("update chunk set line_start = line_start - 1", [])?;
            Ok(())
        })
        .await
        .unwrap();
    s.meta_set("chunker_version", "1").await.unwrap();
    assert_ne!(line_starts(&s, "a.el").await, right);

    run(&s, &tree, &listed).await;
    assert_eq!(line_starts(&s, "a.el").await, right);
}

mod fresh {
    use super::*;
    use hrafn::fresh::{Due, Fresh, Settle, diff};
    use hrafn::{Config, GitCli, list};
    use skuld::{Core, Partial, events};
    use std::path::Path;
    use std::process::Command;
    use std::time::Duration;

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

    /// Under the temp dir's real path: a root with a link in its path is refused (macOS's /var is one).
    fn repo(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        git(dir.path(), &["init", "-q"]);
        for (p, c) in files {
            std::fs::write(dir.path().join(p), c).unwrap();
        }
        git(dir.path(), &["add", "-A"]);
        git(dir.path(), &["commit", "-q", "-m", "one"]);
        dir
    }

    fn listed(dir: &Path, config: &Config) -> Vec<Listed> {
        list(dir, &GitCli, config, &|_: &str| true).unwrap()
    }

    async fn index(s: &Fx, dir: &Path, l: &[Listed]) -> Refresh {
        let read = |p: &str| std::fs::read(dir.join(p));
        refresh(s, l, &read, &[&s.c]).await.unwrap()
    }

    /// Pattern D.
    #[tokio::test]
    async fn uncommitted_edit_counts() {
        let d = repo(&[("a.el", A)]);
        let s = store().await;
        let first = listed(d.path(), &Config::default());
        index(&s, d.path(), &first).await;

        std::fs::write(d.path().join("a.el"), format!("{A}(defun a-three () 3)\n")).unwrap();
        let edited = listed(d.path(), &Config::default());
        assert_ne!(
            edited[0].blob, first[0].blob,
            "the working tree's content counts"
        );
        let r = index(&s, d.path(), &edited).await;
        assert_eq!(r.files_changed, 1);
        assert!(r.keys_missing > 0);
    }

    /// Sixty Lisp files: half with a `name.el --- Title` first line, half with only the file name and the cookie.
    fn sixty() -> Vec<(String, String)> {
        (0..60)
            .map(|i| {
                let first = if i % 2 == 0 {
                    format!(";;; f{i}.el --- Helpers number {i}  -*- lexical-binding: t; -*-")
                } else {
                    format!(";;; f{i}.el -*- lexical-binding: t; -*-")
                };
                (
                    format!("lisp/f{i}.el"),
                    format!("{first}\n\n(defun f{i}-run ()\n  \"Run helper {i}.\"\n  {i})\n"),
                )
            })
            .collect()
    }

    /// A repository of [`sixty`] files, indexed with every key embedded, then 50 of them moved by `git mv` (half into
    /// another directory under their name, half renamed too) and indexed again. The new paths.
    async fn moved() -> (tempfile::TempDir, Fx, Vec<String>) {
        let files = sixty();
        let refs: Vec<(&str, &str)> = files
            .iter()
            .map(|(p, t)| (p.as_str(), t.as_str()))
            .collect();
        let d = {
            let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
            git(dir.path(), &["init", "-q"]);
            for (p, c) in &refs {
                let f = dir.path().join(p);
                std::fs::create_dir_all(f.parent().unwrap()).unwrap();
                std::fs::write(f, c).unwrap();
            }
            git(dir.path(), &["add", "-A"]);
            git(dir.path(), &["commit", "-q", "-m", "one"]);
            dir
        };
        let s = store().await;
        index(&s, d.path(), &listed(d.path(), &Config::default())).await;
        assert!(embed_all(&s).await >= 60);
        assert!(missing(&s, &s.c, 1000).await.unwrap().is_empty());
        std::fs::create_dir_all(d.path().join("moved")).unwrap();
        let mut new = Vec::new();
        for i in 0..50 {
            let to = if i % 2 == 0 {
                format!("moved/f{i}.el")
            } else {
                format!("moved/renamed{i}.el")
            };
            git(d.path(), &["mv", &format!("lisp/f{i}.el"), &to]);
            new.push(to);
        }
        git(d.path(), &["commit", "-q", "-m", "move"]);
        let r = index(&s, d.path(), &listed(d.path(), &Config::default())).await;
        assert!(r.files_changed >= 50, "{r:?}");
        (d, s, new)
    }

    /// Pattern D (Hrafn redesign Task 8). 50 files moved: every chunk keeps its key, so no chunk is embedded again.
    #[tokio::test]
    async fn a_move_embeds_no_chunk() {
        let (_d, s, _new) = moved().await;
        assert_eq!(chunk_keys(&s).await.len(), 0);
        let behind = lag(&s, Some(&s.c), hrafn::View::Base)
            .await
            .unwrap()
            .chunks_behind;
        assert_eq!(behind, 0, "and the lag counts no chunk behind");
    }

    /// Pattern D (Hrafn redesign Task 9). 50 files moved: tier 2 is offered exactly one path key per new path, and
    /// nothing else (no chunk, no path that did not change).
    #[tokio::test]
    async fn a_move_embeds_one_path_key_per_new_path() {
        let (_d, s, new) = moved().await;
        let keys = missing_with(&s, &s.c, 1000, false).await.unwrap();
        let mut offered = offered_paths(&keys);
        offered.sort();
        let mut want = new.clone();
        want.sort();
        assert_eq!(offered, want);
        assert_eq!(keys.len(), 50, "path keys only");
    }

    /// Pattern D.
    #[tokio::test]
    async fn excluded_only_commit_is_not_stale() {
        let d = repo(&[("a.el", A), ("notes.txt", "one\n")]);
        let config = Config {
            user: hrafn::rules::RuleSet {
                ignore: vec!["*.txt".into()],
                ..Default::default()
            },
            ..Config::default()
        };
        let s = store().await;
        index(&s, d.path(), &listed(d.path(), &config)).await;

        std::fs::write(d.path().join("notes.txt"), "two\n").unwrap();
        git(d.path(), &["commit", "-q", "-am", "notes only"]);
        let now = listed(d.path(), &config);
        assert!(diff(&s, &now, 1000).await.unwrap().is_empty());
        assert_eq!(index(&s, d.path(), &now).await.files_changed, 0);
    }

    /// Pattern D. Without watches, the query's own diff of blobs finds the edit.
    #[tokio::test]
    async fn no_watches_falls_back_to_the_hash_diff() {
        let d = repo(&[("a.el", A), ("b.el", B)]);
        let s = store().await;
        index(&s, d.path(), &listed(d.path(), &Config::default())).await;
        assert!(
            diff(&s, &listed(d.path(), &Config::default()), 1000)
                .await
                .unwrap()
                .is_empty()
        );

        std::fs::write(d.path().join("b.el"), ";;; b.el\n(defvar b-var 2)\n").unwrap();
        std::fs::remove_file(d.path().join("a.el")).unwrap();
        let now = listed(d.path(), &Config::default());
        let changes = diff(&s, &now, 1000).await.unwrap();
        assert_eq!(changes.changed, ["b.el"]);
        assert_eq!(changes.gone, ["a.el"]);
        // the diff is bounded: past its limit it says so, and the caller refreshes everything
        let capped = diff(&s, &now, 1).await.unwrap();
        assert!(capped.capped);
        assert_eq!(index(&s, d.path(), &now).await.files_changed, 2);
    }

    const QUIET: Duration = Duration::from_millis(2000);

    #[derive(Clone, Debug)]
    enum Ev {
        /// A change under the gitdir (HEAD, index, refs).
        Git,
        /// `index.lock` appeared (true) or went (false).
        Lock(bool),
        /// The clock reads this many ms.
        At(u64),
    }
    events!(Ev { Git, Lock, At });

    /// The settle core, recording every refresh it calls for and the state it called for it in.
    struct Probe {
        settle: Settle,
        now: Duration,
        locked: bool,
        last_git: Option<Duration>,
        dues: Vec<(Duration, bool, Option<Duration>)>,
    }

    impl Core for Probe {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            let fed = match ev {
                Ev::Git => {
                    self.last_git = Some(self.now);
                    Fresh::Git
                }
                Ev::Lock(on) => {
                    self.locked = on;
                    Fresh::Lock(on)
                }
                Ev::At(ms) => {
                    self.now = Duration::from_millis(ms);
                    Fresh::At(self.now)
                }
            };
            if let Some(Due::All) = self.settle.feed(fed) {
                self.dues.push((self.now, self.locked, self.last_git));
                self.last_git = None;
            }
            vec![]
        }
    }

    /// Pattern A. A checkout writes HEAD and the index under `index.lock`: in every order of those writes, the lock and
    /// the clock, a refresh is called for only once the lock is gone and the gitdir has been quiet for the period, and
    /// the last write is always followed by one.
    #[test]
    fn git_event_waits_for_index_lock() {
        let mut p = Partial::new();
        let git = p.source("gitdir", vec![Ev::Git, Ev::Git]);
        let lock = p.source("lock", vec![Ev::Lock(true), Ev::Lock(false)]);
        let clock = p.source("clock", vec![Ev::At(500), Ev::At(1500), Ev::At(9000)]);
        // the shell's claims: git takes the lock before it writes, drops it after; the last reading comes last
        p.before((lock, 0), (git, 0))
            .before((git, 1), (lock, 1))
            .before((git, 1), (clock, 2))
            .before((lock, 1), (clock, 2));
        let report = skuld::every_order(
            &p,
            skuld::Bound::default(),
            || Probe {
                settle: Settle::new(QUIET, Duration::from_secs(30)),
                now: Duration::ZERO,
                locked: false,
                last_git: None,
                dues: vec![],
            },
            |probe, _| {
                for (at, locked, last) in &probe.dues {
                    if *locked {
                        return Err(format!("a refresh at {at:?} while index.lock is there"));
                    }
                    let last = last.ok_or(format!("a refresh at {at:?} with no git change"))?;
                    if *at < last + QUIET {
                        return Err(format!("a refresh at {at:?}, {last:?} + quiet not reached"));
                    }
                }
                if probe.last_git.is_some() {
                    return Err("the last change was never followed by a refresh".into());
                }
                Ok(())
            },
        );
        assert!(report.orders > 1, "{report:?}");
    }
}
