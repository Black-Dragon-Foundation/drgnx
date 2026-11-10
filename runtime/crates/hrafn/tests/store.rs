use hrafn::{ChunkIn, CodeStore, FileRow, SymbolIn, VecRow, encode_symbol, vec_key};

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

async fn count(s: &CodeStore, sql: &'static str) -> i64 {
    s.handle()
        .read(move |c| Ok(c.query_row(sql, [], |r| r.get::<_, i64>(0))?))
        .await
        .unwrap()
}

fn file(path: &str) -> FileRow {
    FileRow {
        path: path.into(),
        blob: Some("b".into()),
        class: "code".into(),
        lang: "elisp".into(),
        generated: false,
        size: 3,
        indexed_at: 1,
    }
}

#[tokio::test]
async fn open_creates_v1() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    assert_eq!(s.meta_get("schema").await.unwrap().as_deref(), Some("5"));
    for t in [
        "tree",
        "file",
        "chunk",
        "chunk_fts",
        "symbol",
        "symbol_fts",
        "vec",
        "meta",
    ] {
        let n = s
            .handle()
            .read(move |c| {
                Ok(c.query_row(
                    "select count(*) from sqlite_master where name = ?1",
                    [t],
                    |r| r.get::<_, i64>(0),
                )?)
            })
            .await
            .unwrap();
        assert_eq!(n, 1, "{t}");
    }
    let mode: String = s
        .handle()
        .read(|c| Ok(c.pragma_query_value(None, "journal_mode", |r| r.get(0))?))
        .await
        .unwrap();
    assert_eq!(mode, "wal");
}

#[tokio::test]
async fn reopen_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("p.db");
    let s = CodeStore::open(&p).unwrap();
    s.put_file(file("a.el")).await.unwrap();
    s.meta_set("chunker_version", "1").await.unwrap();
    tokio::task::spawn_blocking(move || s.shutdown())
        .await
        .unwrap();
    let s = CodeStore::open(&p).unwrap();
    assert_eq!(count(&s, "select count(*) from file").await, 1);
    assert_eq!(s.meta_get("schema").await.unwrap().as_deref(), Some("5"));
    assert_eq!(
        s.meta_get("chunker_version").await.unwrap().as_deref(),
        Some("1")
    );
}

#[test]
fn vec_key_changes_with_each_field() {
    let a = vec_key(1, "text");
    assert_eq!(a, vec_key(1, "text"));
    assert_ne!(a, vec_key(2, "text"));
    assert_ne!(a, vec_key(1, "text2"));
}

#[tokio::test]
async fn two_models_share_a_key() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    s.put_file(file("a.el")).await.unwrap();
    let c = chunk("(defun a ())", "a", "defun a");
    let key = c.key;
    s.replace_chunks("a.el", "b", vec![c], vec![])
        .await
        .unwrap();
    for model in ["m1", "m2"] {
        s.put_vec(VecRow {
            model: model.into(),
            dims: 4,
            key,
            bits: 8,
            vec: vec![1, 2, 3, 4],
            scale: 1.0,
            last_used: 1,
        })
        .await
        .unwrap();
    }
    assert_eq!(count(&s, "select count(*) from vec").await, 2);
    assert_eq!(count(&s, "select count(distinct key) from vec").await, 1);
    assert_eq!(count(&s, "select count(*) from chunk").await, 1);
}

#[tokio::test]
async fn symbols_column_keeps_whole_names_and_body_splits_them() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    let c = chunk(
        "(defun drgnx-timer--fire ())",
        "drgnx-timer--fire",
        "defun drgnx-timer--fire",
    );
    s.replace_chunks("a.el", "b", vec![c], vec![])
        .await
        .unwrap();
    let whole = format!(
        "select count(*) from chunk_fts where chunk_fts match 'symbols:\"{}\"'",
        encode_symbol("drgnx-timer--fire")
    );
    let whole: &'static str = Box::leak(whole.into_boxed_str());
    assert_eq!(count(&s, whole).await, 1);
    assert_eq!(
        count(
            &s,
            "select count(*) from chunk_fts where chunk_fts match 'symbols:timer'"
        )
        .await,
        0
    );
    assert_eq!(
        count(
            &s,
            "select count(*) from chunk_fts where chunk_fts match 'body:timer'"
        )
        .await,
        1
    );
}

#[tokio::test]
async fn fts_row_deleted_with_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    s.put_file(file("a.el")).await.unwrap();
    let sym = SymbolIn {
        name: "foo-bar".into(),
        kind: "function".into(),
        start: 0,
        end: 5,
        chunk: 0,
        definer: "defun".into(),
        doc1: None,
        ..SymbolIn::default()
    };
    s.replace_chunks("a.el", "b", vec![chunk("x", "foo-bar", "alpha")], vec![sym])
        .await
        .unwrap();
    let match_alpha = "select count(*) from chunk_fts where chunk_fts match 'body:alpha'";
    assert_eq!(count(&s, match_alpha).await, 1);
    assert_eq!(
        count(
            &s,
            "select count(*) from symbol_fts where symbol_fts match '\"o-ba\"'"
        )
        .await,
        1
    );
    s.delete_file("a.el").await.unwrap();
    assert_eq!(count(&s, match_alpha).await, 0);
    assert_eq!(count(&s, "select count(*) from symbol").await, 0);
    assert_eq!(
        count(
            &s,
            "select count(*) from symbol_fts where symbol_fts match '\"o-ba\"'"
        )
        .await,
        0
    );
    // The replace path removes the old rows too.
    s.replace_chunks("b.el", "b", vec![chunk("y", "", "beta")], vec![])
        .await
        .unwrap();
    s.replace_chunks("b.el", "b", vec![chunk("z", "", "gamma")], vec![])
        .await
        .unwrap();
    assert_eq!(
        count(
            &s,
            "select count(*) from chunk_fts where chunk_fts match 'body:beta'"
        )
        .await,
        0
    );
    assert_eq!(count(&s, "select count(*) from chunk").await, 1);
}

#[tokio::test]
async fn vacuum_keeps_chunk_ids() {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
    let ids = s
        .replace_chunks(
            "a.el",
            "b",
            vec![
                chunk("1", "", "one"),
                chunk("2", "", "two"),
                chunk("3", "", "three"),
            ],
            vec![],
        )
        .await
        .unwrap();
    let first = ids[0];
    s.handle()
        .write(move |c| {
            c.execute("delete from chunk where id = ?1", [first])?;
            Ok(())
        })
        .await
        .unwrap();
    s.vacuum().await.unwrap();
    let left: Vec<i64> = s
        .handle()
        .read(|c| {
            let mut st = c.prepare("select id from chunk order by id")?;
            Ok(st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?)
        })
        .await
        .unwrap();
    assert_eq!(left, vec![ids[1], ids[2]]);
    let hit: i64 = s
        .handle()
        .read(|c| {
            Ok(c.query_row(
                "select rowid from chunk_fts where chunk_fts match 'body:three'",
                [],
                |r| r.get(0),
            )?)
        })
        .await
        .unwrap();
    assert_eq!(hit, ids[2]);
}
