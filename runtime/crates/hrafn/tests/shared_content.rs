//! Schema V3 (H16 overlay design §3, §9): the migration from V2 keeps every row and vector, chunks and symbols are
//! keyed by `(path, blob)` and shared, a base write leaves content another tree still names, and the last row to let
//! go of a pair takes its chunks, FTS rows and symbols with it.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::query::{Query, Scope, search};
use hrafn::{ChunkIn, CodeStore, Door, FileRow, MIGRATIONS, SymbolIn, View, vec_key};
use rusqlite::params;

fn chunk(text: &str, symbols: &str, body: &str) -> ChunkIn {
    ChunkIn {
        start: 0,
        end: text.len() as u32,
        line_start: 1,
        line_end: 1,
        symbol: None,
        key: vec_key(1, text),
        embed: true,
        embed_text: text.into(),
        symbols: symbols.into(),
        doc: String::new(),
        body: body.into(),
    }
}

fn sym(name: &str) -> SymbolIn {
    SymbolIn {
        name: name.into(),
        kind: "function".into(),
        start: 0,
        end: 1,
        chunk: 0,
        definer: "defun".into(),
        doc1: None,
    }
}

fn row(path: &str, blob: &str) -> FileRow {
    FileRow {
        path: path.into(),
        blob: blob.into(),
        class: "code".into(),
        lang: "elisp".into(),
        generated: false,
        size: 3,
        indexed_at: 1,
    }
}

async fn count(s: &CodeStore, sql: &str) -> i64 {
    let sql = sql.to_string();
    s.handle()
        .read(move |c| Ok(c.query_row(&sql, [], |r| r.get::<_, i64>(0))?))
        .await
        .unwrap()
}

async fn rows(s: &urdr::Handle, sql: &'static str) -> Vec<Vec<String>> {
    s.read(move |c| {
        let mut st = c.prepare(sql)?;
        let n = st.column_count();
        let out = st
            .query_map([], |r| {
                (0..n)
                    .map(|i| {
                        Ok(match r.get_ref(i)? {
                            rusqlite::types::ValueRef::Null => "NULL".to_string(),
                            rusqlite::types::ValueRef::Integer(v) => v.to_string(),
                            rusqlite::types::ValueRef::Real(v) => v.to_string(),
                            rusqlite::types::ValueRef::Text(t) => {
                                String::from_utf8_lossy(t).into_owned()
                            }
                            rusqlite::types::ValueRef::Blob(b) => format!("{b:?}"),
                        })
                    })
                    .collect::<Result<Vec<_>, rusqlite::Error>>()
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(out)
    })
    .await
    .unwrap()
}

/// What the migration must keep: chunk ids with their paths, symbol ids with their names and chunks, the FTS hits of
/// both tables, and every vector.
const KEPT: &[&str] = &[
    "select id, path, start, line_start, key, embed_text from chunk order by id",
    "select rowid, name, kind, path, chunk from symbol order by rowid",
    "select rowid from chunk_fts where chunk_fts match 'body:alpha OR body:gamma' order by rowid",
    "select rowid from symbol_fts where symbol_fts match '\"timer\"' order by rowid",
    "select model, key, vec, scale from vec order by model, key",
    "select path, blob, class from file order by path",
];

/// Pattern D. A V2 store opens as V3 with no re-chunk and no re-embed: chunk ids, symbol ids, the FTS hits and the
/// vectors are as they were, `chunk.blob` and `symbol.blob` are filled from the file's row, and a query finds the same
/// chunks.
#[tokio::test]
async fn v2_store_migrates_keeping_rows_and_vectors() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("p.db");
    let (store, h) = urdr::Store::spawn(urdr::StoreSpec {
        path: path.clone(),
        mode: urdr::Mode::ReadWrite {
            file_mode: 0o600,
            synchronous_full: false,
        },
        migrations: &MIGRATIONS[..2],
    })
    .unwrap();
    // the rows as the V2 code wrote them
    h.write(|c| {
        for (p, b) in [("a.el", "blob-a"), ("b.el", "blob-b")] {
            c.execute(
                "insert into file(path, blob, class, lang, generated, size, indexed_at)
                 values (?1, ?2, 'code', 'elisp', 0, 10, 1)",
                params![p, b],
            )?;
        }
        let chunks = [
            ("a.el", "(defun drgnx-timer-fire ())", "drgnx-timer-fire", "alpha timer"),
            ("a.el", "(defun drgnx-timer-stop ())", "drgnx-timer-stop", "beta"),
            ("b.el", "(defvar drgnx-other)", "drgnx-other", "gamma"),
        ];
        for (i, (p, text, s, body)) in chunks.iter().enumerate() {
            let key = vec_key(1, text);
            c.execute(
                "insert into chunk(path, start, end, line_start, line_end, symbol, key, embed, embed_text)
                 values (?1, 0, 5, ?2, ?2, ?3, ?4, 1, ?5)",
                params![p, i as i64 + 1, s, key.as_slice(), text],
            )?;
            let id = c.last_insert_rowid();
            c.execute(
                "insert into chunk_fts(rowid, path, symbols, doc, body) values (?1, ?2, ?3, '', ?4)",
                params![id, p, hrafn::encode_symbol(s), body],
            )?;
            c.execute(
                "insert into symbol(name, kind, path, start, end, chunk, definer, doc1)
                 values (?1, 'function', ?2, 0, 5, ?3, 'defun', null)",
                params![s, p, id],
            )?;
            c.execute(
                "insert into vec(model, dims, key, bits, vec, scale, last_used)
                 values ('m', 4, ?1, 8, ?2, 0.5, ?3)",
                params![key.as_slice(), vec![i as u8; 5], i as i64],
            )?;
        }
        // a gap in the symbol rowids, so a renumbering would show
        c.execute("delete from symbol where name = 'drgnx-timer-stop'", [])?;
        Ok(())
    })
    .await
    .unwrap();
    let mut before = Vec::new();
    for q in KEPT {
        before.push(rows(&h, q).await);
    }
    // shutdown blocks: off the runtime's thread
    std::thread::spawn(move || store.shutdown()).join().unwrap();

    let s = CodeStore::open(&path).unwrap();
    assert_eq!(s.meta_get("schema").await.unwrap().as_deref(), Some("3"));
    for (q, b) in KEPT.iter().zip(&before) {
        assert_eq!(&rows(s.handle(), q).await, b, "{q}");
    }
    assert_eq!(
        rows(s.handle(), "select path, blob from chunk order by id").await,
        [["a.el", "blob-a"], ["a.el", "blob-a"], ["b.el", "blob-b"]]
    );
    assert_eq!(
        rows(s.handle(), "select name, blob from symbol order by id").await,
        [["drgnx-timer-fire", "blob-a"], ["drgnx-other", "blob-b"]]
    );
    assert_eq!(
        count(&s, "select count(*) from file where tree = 0").await,
        2
    );
    // the same query finds the same chunk: the symbol route, the keyword route, and the FTS link of a symbol
    let a = search(
        &s,
        &Query {
            text: "drgnx-timer-fire".into(),
            scope: Scope::All,
            k: 5,
        },
        None,
        &|_| None,
    )
    .await
    .unwrap();
    assert_eq!(a.hits[0].path, "a.el");
    assert_eq!(a.hits[0].line_start, 1);
    let a = search(
        &s,
        &Query {
            text: "gamma".into(),
            scope: Scope::All,
            k: 5,
        },
        None,
        &|_| None,
    )
    .await
    .unwrap();
    assert_eq!(a.hits.len(), 1);
    assert_eq!((a.hits[0].path.as_str(), a.hits[0].line_start), ("b.el", 3));
    // the rebuilt symbol table keeps its FTS triggers on the kept ids
    s.remove_file(View::Base, "a.el").await.unwrap();
    assert_eq!(
        count(
            &s,
            "select count(*) from symbol_fts where symbol_fts match '\"timer\"'"
        )
        .await,
        0
    );
    assert_eq!(count(&s, "select count(*) from chunk").await, 1);
}

/// The ids of PATH's chunks whose text is TEXT.
async fn chunks_of(s: &CodeStore, path: &str, text: &str) -> i64 {
    let (p, t) = (path.to_string(), text.to_string());
    s.handle()
        .read(move |c| {
            Ok(c.query_row(
                "select count(*) from chunk where path = ?1 and embed_text = ?2",
                [p, t],
                |r| r.get::<_, i64>(0),
            )?)
        })
        .await
        .unwrap()
}

/// Pattern D. A tree's row names `(p, X)`; the base rewrites p to Y: the chunks of `(p, X)` stay, the base's old
/// content goes.
#[tokio::test]
async fn base_write_keeps_overlay_content() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    let t = s
        .tree_open("wt-1", "/w/t", "/w/.git/worktrees/t", Door::Cli)
        .await
        .unwrap();
    s.write_file(
        View::Base,
        row("p.el", "W"),
        vec![chunk("w-text", "", "w")],
        vec![],
    )
    .await
    .unwrap();
    s.write_file(
        View::Tree(t),
        row("p.el", "X"),
        vec![chunk("x-text", "", "x")],
        vec![],
    )
    .await
    .unwrap();
    s.write_file(
        View::Base,
        row("p.el", "Y"),
        vec![chunk("y-text", "", "y")],
        vec![],
    )
    .await
    .unwrap();
    assert_eq!(chunks_of(&s, "p.el", "x-text").await, 1, "T's content kept");
    assert_eq!(
        chunks_of(&s, "p.el", "y-text").await,
        1,
        "the base's new content"
    );
    assert_eq!(
        chunks_of(&s, "p.el", "w-text").await,
        0,
        "the base's old content swept"
    );
    assert_eq!(
        count(
            &s,
            "select count(*) from chunk_fts where chunk_fts match 'body:x'"
        )
        .await,
        1
    );
}

/// Pattern D. The last row naming `(p, b)` goes: its chunks, FTS rows and symbols go with it; content another row
/// names stays, and a pair two trees share is written once and outlives the first tree's row.
#[tokio::test]
async fn unreferenced_content_is_swept() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    let t1 = s
        .tree_open("wt-1", "/w/1", "/g/1", Door::Cli)
        .await
        .unwrap();
    let t2 = s
        .tree_open("wt-2", "/w/2", "/g/2", Door::Gix)
        .await
        .unwrap();
    assert_ne!(t1, t2);
    s.write_file(
        View::Base,
        row("p.el", "B"),
        vec![chunk("base-text", "base-fn", "basebody")],
        vec![sym("base-fn")],
    )
    .await
    .unwrap();
    let first = s
        .write_file(
            View::Tree(t1),
            row("p.el", "X"),
            vec![chunk("x-text", "x-fn", "xbody")],
            vec![sym("x-fn")],
        )
        .await
        .unwrap();
    let second = s
        .write_file(
            View::Tree(t2),
            row("p.el", "X"),
            vec![chunk("x-text", "x-fn", "xbody")],
            vec![sym("x-fn")],
        )
        .await
        .unwrap();
    assert_eq!(first, second, "a shared pair is written once");
    assert_eq!(chunks_of(&s, "p.el", "x-text").await, 1);
    s.remove_file(View::Tree(t1), "p.el").await.unwrap();
    assert_eq!(
        chunks_of(&s, "p.el", "x-text").await,
        1,
        "t2 still names it"
    );
    s.remove_file(View::Tree(t2), "p.el").await.unwrap();
    assert_eq!(chunks_of(&s, "p.el", "x-text").await, 0);
    assert_eq!(
        count(
            &s,
            "select count(*) from chunk_fts where chunk_fts match 'body:xbody'"
        )
        .await,
        0
    );
    assert_eq!(
        count(&s, "select count(*) from symbol where name = 'x-fn'").await,
        0
    );
    assert_eq!(
        count(
            &s,
            "select count(*) from symbol_fts where symbol_fts match '\"x-fn\"'"
        )
        .await,
        0
    );
    // the base's content was never touched
    assert_eq!(chunks_of(&s, "p.el", "base-text").await, 1);
    assert_eq!(
        count(&s, "select count(*) from symbol where name = 'base-fn'").await,
        1
    );
}
