//! Vector packs (Hrafn redesign Task 20, `hrafn::vector_pack`): the file format an index's vectors travel in. A pack
//! holds keys and vectors only, is the same file for the same rows, and refuses what it did not write.
//!
//! test-pattern: pure (D): the store and the cache answer in order, nothing here has a clock.

use hrafn::vector_pack::{
    ExportScope, PACK_FORMAT, PackHeader, export_keys, read_pack, write_pack,
};
use hrafn::{
    Class, CodeStore, DoorKind, FileRow, KeyKind, Lang, Listed, QuantRow, VectorCache, View,
    missing, path_key, refresh,
};
use rusqlite::types::ValueRef;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;

const FP: &str = "5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed";
const DIMS: usize = 4;

const SECRET_PATH: &str = "src/secret_dir/alpha_widget.el";
const SECRET_TEXT: &str = "(defun alpha-widget-frobnicate (x)\n  \"Frobnicate X.\"\n  (* x 2))\n";

fn header(created_at: i64) -> PackHeader {
    PackHeader {
        format: PACK_FORMAT,
        record: r#"{"model_id":"m","dims":4}"#.to_string(),
        created_at,
        tool_version: "0.1.0".to_string(),
        repo_url: Some("https://example.invalid/r.git".to_string()),
        commit: Some("abc123".to_string()),
    }
}

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

struct Fx {
    dir: tempfile::TempDir,
    s: CodeStore,
    c: VectorCache,
}

/// A store over FILES (path, text; blob "b" plus the path) refreshed, and a cache holding a vector for every key.
async fn fixture(files: &[(&str, &str)]) -> Fx {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("code")).unwrap();
    let s = CodeStore::open(&dir.path().join("code/a.db")).unwrap();
    let c = VectorCache::open_writer(&dir.path().join("vectors"), FP, "{}").unwrap();
    let texts: HashMap<String, String> = files
        .iter()
        .map(|(p, t)| (p.to_string(), t.to_string()))
        .collect();
    let listed: Vec<Listed> = files
        .iter()
        .map(|(p, _)| el(p, &format!("b-{p}")))
        .collect();
    refresh(
        &s,
        &listed,
        &|p: &str| {
            texts
                .get(p)
                .map(|t| t.clone().into_bytes())
                .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))
        },
        &[&c],
    )
    .await
    .unwrap();
    embed_all(&s, &c).await;
    Fx { dir, s, c }
}

/// A unit vector per key of KIND, made from the key's first bytes.
async fn embed_all(s: &CodeStore, c: &VectorCache) {
    let todo = missing(s, c, 10_000).await.unwrap();
    for kind in [KeyKind::Chunk, KeyKind::Path] {
        let rows: Vec<([u8; 32], Vec<f32>)> = todo
            .iter()
            .filter(|(k, _, _)| *k == kind)
            .map(|(_, k, _)| {
                let v: Vec<f32> = k[..DIMS].iter().map(|b| f32::from(*b) + 1.0).collect();
                let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                (*k, v.into_iter().map(|x| x / n).collect())
            })
            .collect();
        if !rows.is_empty() {
            c.put(kind, DIMS as u32, &rows).await.unwrap();
        }
    }
}

/// The cache's rows of KEYS, as a pack takes them.
async fn rows_of(c: &VectorCache, keys: &[(KeyKind, [u8; 32])]) -> Vec<(KeyKind, QuantRow)> {
    let mut out = Vec::new();
    for kind in [KeyKind::Chunk, KeyKind::Path] {
        let ks: Vec<[u8; 32]> = keys
            .iter()
            .filter(|(k, _)| *k == kind)
            .map(|(_, k)| *k)
            .collect();
        out.extend(
            c.get(kind, &ks)
                .await
                .unwrap()
                .into_iter()
                .map(|r| (kind, r)),
        );
    }
    out
}

async fn pack_of(fx: &Fx, out: &Path, created_at: i64) -> [u8; 32] {
    let keys = export_keys(&fx.s, ExportScope::AllTrees).await.unwrap();
    write_pack(
        out,
        &header(created_at),
        rows_of(&fx.c, &keys).await.into_iter(),
    )
    .unwrap()
}

fn sha_of(p: &Path) -> [u8; 32] {
    Sha256::digest(std::fs::read(p).unwrap()).into()
}

/// Pattern D (§9: no paths, no chunk text). Every cell of every table of the pack, and the file's bytes, are searched
/// for the fixture's path, its words and its code.
#[tokio::test]
async fn pack_holds_no_path_or_text() {
    let fx = fixture(&[(SECRET_PATH, SECRET_TEXT), ("b.el", "(defun b () 1)\n")]).await;
    let out = fx.dir.path().join("p.pack");
    pack_of(&fx, &out, 1).await;
    let needles = [
        "secret_dir",
        "alpha_widget",
        "frobnicate",
        "Frobnicate",
        "defun",
    ];
    let c = rusqlite::Connection::open_with_flags(&out, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    let tables: Vec<String> = c
        .prepare("select name from sqlite_master where type = 'table'")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut cells = 0;
    for t in &tables {
        let mut st = c.prepare(&format!("select * from \"{t}\"")).unwrap();
        let n = st.column_count();
        let mut rows = st.query([]).unwrap();
        while let Some(r) = rows.next().unwrap() {
            for i in 0..n {
                let bytes: Vec<u8> = match r.get_ref(i).unwrap() {
                    ValueRef::Text(b) | ValueRef::Blob(b) => b.to_vec(),
                    ValueRef::Integer(v) => v.to_string().into_bytes(),
                    ValueRef::Real(v) => v.to_string().into_bytes(),
                    ValueRef::Null => Vec::new(),
                };
                cells += 1;
                for needle in needles {
                    assert!(
                        !String::from_utf8_lossy(&bytes).contains(needle),
                        "{t}: a cell holds {needle:?}"
                    );
                }
            }
        }
    }
    assert!(cells > 10, "the scan saw the pack's cells ({cells})");
    let raw = String::from_utf8_lossy(&std::fs::read(&out).unwrap()).into_owned();
    for needle in needles {
        assert!(!raw.contains(needle), "the file holds {needle:?}");
    }
    let (h, reader) = read_pack(&out).unwrap();
    assert_eq!(h, header(1));
    assert!(reader.len() > 2, "chunk and path vectors are in it");
}

/// Pattern D (MP-11). The same rows and header make the same file, whose sha is what is returned; another header
/// (the time) is another file.
#[tokio::test]
async fn pack_is_content_addressed() {
    let fx = fixture(&[(SECRET_PATH, SECRET_TEXT), ("b.el", "(defun b () 1)\n")]).await;
    let (a, b, c) = (
        fx.dir.path().join("a.pack"),
        fx.dir.path().join("b.pack"),
        fx.dir.path().join("c.pack"),
    );
    let sa = pack_of(&fx, &a, 7).await;
    let sb = pack_of(&fx, &b, 7).await;
    assert_eq!(sa, sb, "two exports of one tree are one sha");
    assert_eq!(std::fs::read(&a).unwrap(), std::fs::read(&b).unwrap());
    assert_eq!(sa, sha_of(&a), "the sha is the file's");
    let sc = pack_of(&fx, &c, 8).await;
    assert_ne!(sa, sc);
    assert_eq!(sc, sha_of(&c));
}

/// Pattern D. A pack of another format is refused, naming the format, and so is a file that is not a pack at all.
#[tokio::test]
async fn unknown_format_is_refused() {
    let fx = fixture(&[("a.el", "(defun a () 1)\n")]).await;
    let out = fx.dir.path().join("p.pack");
    let keys = export_keys(&fx.s, ExportScope::AllTrees).await.unwrap();
    let mut h = header(1);
    h.format = PACK_FORMAT + 1;
    write_pack(&out, &h, rows_of(&fx.c, &keys).await.into_iter()).unwrap();
    let err = read_pack(&out).err().expect("refused").to_string();
    assert!(err.contains("format"), "{err}");
    let junk = fx.dir.path().join("junk");
    std::fs::write(&junk, b"not a database at all, just text").unwrap();
    assert!(read_pack(&junk).is_err());
    assert!(read_pack(&fx.dir.path().join("missing.pack")).is_err());
}

/// Pattern D. A pack with a table or a column it does not define is refused: nothing rides along (no path, no text).
#[tokio::test]
async fn extra_table_is_refused() {
    let fx = fixture(&[("a.el", "(defun a () 1)\n")]).await;
    let ok = fx.dir.path().join("ok.pack");
    pack_of(&fx, &ok, 1).await;
    read_pack(&ok).unwrap();
    let table = |p: &Path| -> String {
        let c = rusqlite::Connection::open(p).unwrap();
        c.query_row(
            "select name from sqlite_master where type = 'table' and name != 'meta'",
            [],
            |r| r.get(0),
        )
        .unwrap()
    };
    let t = table(&ok);
    let with_table = fx.dir.path().join("table.pack");
    std::fs::copy(&ok, &with_table).unwrap();
    rusqlite::Connection::open(&with_table)
        .unwrap()
        .execute_batch("create table files(path text, body text)")
        .unwrap();
    assert!(read_pack(&with_table).is_err(), "an extra table");
    let with_column = fx.dir.path().join("column.pack");
    std::fs::copy(&ok, &with_column).unwrap();
    rusqlite::Connection::open(&with_column)
        .unwrap()
        .execute_batch(&format!("alter table \"{t}\" add column path text"))
        .unwrap();
    assert!(read_pack(&with_column).is_err(), "an extra column");
}

/// Pattern D. A tree's view exports the keys that tree sees (the base's, its own files' and not those it removed); a
/// view of the base does not see the tree's own files; all trees give the union. Path keys are the base's.
#[tokio::test]
async fn export_branch_covers_that_tree() {
    let fx = fixture(&[
        ("a.el", "(defun a () 1)\n"),
        ("c.el", "(defun c-only-in-base () 3)\n"),
    ])
    .await;
    let t =
        fx.s.tree_open("wt-t", "/nowhere", "/nowhere/.git", DoorKind::Cli)
            .await
            .unwrap();
    let b_text = "(defun b-only-in-tree () 2)\n";
    let l = el("b.el", "b-tree");
    let (chunks, symbols) = hrafn::index::built(&l, b_text.as_bytes());
    let b_keys: Vec<[u8; 32]> = chunks.iter().map(|c| c.key).collect();
    assert!(!b_keys.is_empty());
    fx.s.write_file(
        View::Tree(t),
        FileRow {
            path: "b.el".into(),
            blob: Some("b-tree".into()),
            class: "code".into(),
            lang: "elisp".into(),
            generated: false,
            size: 1,
            indexed_at: 0,
        },
        chunks,
        symbols,
    )
    .await
    .unwrap();
    fx.s.write_file(
        View::Tree(t),
        FileRow::tombstone("c.el"),
        Vec::new(),
        Vec::new(),
    )
    .await
    .unwrap();
    let chunk_keys = |ks: &[(KeyKind, [u8; 32])]| -> Vec<[u8; 32]> {
        ks.iter()
            .filter(|(k, _)| *k == KeyKind::Chunk)
            .map(|(_, k)| *k)
            .collect()
    };
    let in_tree = export_keys(&fx.s, ExportScope::View(View::Tree(t)))
        .await
        .unwrap();
    let in_base = export_keys(&fx.s, ExportScope::View(View::Base))
        .await
        .unwrap();
    let all = export_keys(&fx.s, ExportScope::AllTrees).await.unwrap();
    let (tree_chunks, base_chunks, all_chunks) =
        (chunk_keys(&in_tree), chunk_keys(&in_base), chunk_keys(&all));
    for k in &b_keys {
        assert!(tree_chunks.contains(k), "the tree's own file");
        assert!(!base_chunks.contains(k), "the base does not see it");
        assert!(all_chunks.contains(k), "all trees have it");
    }
    // c.el's chunks: in the base and in all trees, not in the tree that removed it
    let c_only: Vec<[u8; 32]> = base_chunks
        .iter()
        .filter(|k| !tree_chunks.contains(k))
        .copied()
        .collect();
    assert!(!c_only.is_empty(), "the tree does not see what it removed");
    for k in &c_only {
        assert!(all_chunks.contains(k));
    }
    // a.el is seen by both
    assert!(base_chunks.iter().any(|k| tree_chunks.contains(k)));
    // every key once, and the path keys are the base's in each view
    for ks in [&in_tree, &in_base, &all] {
        let once: std::collections::HashSet<_> = ks.iter().collect();
        assert_eq!(once.len(), ks.len(), "each key once");
        assert!(ks.contains(&(KeyKind::Path, path_key("a.el"))));
    }
}
