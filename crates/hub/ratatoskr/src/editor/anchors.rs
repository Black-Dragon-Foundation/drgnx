//! Folds and pins remembered (`folds/save`, `folds/load`; the minimap and folding design, F7 and X5; docs/develop/hub.md,
//! "Folds remembered").  Each fold or pinned region of a file is one Urdr entity of kind `anchor`, its data the
//! anchor's fields plus `worktree`, `path` and `i` (its place in the file's list).  A save replaces the file's anchors
//! when they differ from the kept ones and writes nothing when they are the same, so the editor's idle saves add no
//! history.  The hub never matches anchors to text: the editor does, by kind and first-line hash within 50 lines.

use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::{CoordError, WTx};
use runstav::methods::folds::{Anchor, FoldsLoad, FoldsLoaded, FoldsSave};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use urdr::graph::entity::{self, EntityNew, Origin};

/// The entity kind of a remembered fold or pin (`norn::kinds::ENTITY_KINDS`).
pub const KIND: &str = "anchor";

fn store_err(e: CoordError) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: format!("{e:?}"),
        path: None,
    }
}

/// The live anchors of PATH in WORKTREE, in the order they were saved: (entity n, anchor) each.  A row whose data
/// is not an anchor (written by a newer hub) is left out.
pub(crate) fn kept(
    c: &urdr::Connection,
    worktree: &str,
    path: &str,
) -> Result<Vec<(i64, Anchor)>, CoordError> {
    let mut st = c.prepare(
        "select n, data from entity where kind = 'anchor' and retired_tx is null \
         and json_extract(data, '$.worktree') = ?1 and json_extract(data, '$.path') = ?2 \
         order by json_extract(data, '$.i'), n",
    )?;
    let rows = st.query_map([worktree, path], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (n, data) = row?;
        let Ok(Value::Object(mut m)) = serde_json::from_str::<Value>(&data) else {
            continue;
        };
        for k in ["worktree", "path", "i"] {
            m.remove(k);
        }
        if let Ok(a) = serde_json::from_value::<Anchor>(Value::Object(m)) {
            out.push((n, a));
        }
    }
    Ok(out)
}

/// Keep P's anchors as PATH's in WORKTREE: whether they changed (a save of the same anchors writes nothing).
pub(crate) fn save_in(tx: &mut WTx<'_>, p: &FoldsSave) -> Result<bool, CoordError> {
    let old = kept(tx.sql(), &p.worktree, &p.path)?;
    if old.len() == p.anchors.len() && old.iter().zip(&p.anchors).all(|((_, a), b)| a == b) {
        return Ok(false);
    }
    for (n, _) in old {
        entity::retire(tx, n)?;
    }
    for (i, a) in p.anchors.iter().enumerate() {
        let mut data = serde_json::to_value(a).unwrap_or_else(|_| json!({}));
        if let Value::Object(m) = &mut data {
            m.insert("worktree".into(), json!(p.worktree));
            m.insert("path".into(), json!(p.path));
            m.insert("i".into(), json!(i));
        }
        let id = norn::tracker::new_id(tx, KIND, None)?;
        entity::create(
            tx,
            EntityNew {
                id,
                kind: KIND.into(),
                project: None,
                title: a.name.clone(),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data,
                origin: Origin::Recorded,
                source: None,
            },
        )?;
    }
    Ok(true)
}

/// `folds/save`.  The kept anchors are read first: the same anchors (the editor's idle save of folds it already sent)
/// start no write, so they add no `tx` row either.
pub async fn save(f: &Front, c: &Caller, p: FoldsSave) -> Result<bool, Error> {
    let (w, path) = (p.worktree.clone(), p.path.clone());
    let old = f
        .writer
        .db
        .read(move |c| kept(c, &w, &path))
        .await
        .map_err(store_err)?;
    if old.len() == p.anchors.len() && old.iter().zip(&p.anchors).all(|((_, a), b)| a == b) {
        return Ok(false);
    }
    f.writer
        .write(c, "folds/save", move |tx| save_in(tx, &p))
        .await
        .map_err(store_err)
}

/// `folds/load`.
pub async fn load(f: &Front, _: &Caller, p: FoldsLoad) -> Result<FoldsLoaded, Error> {
    let anchors = f
        .writer
        .db
        .read(move |c| kept(c, &p.worktree, &p.path))
        .await
        .map_err(store_err)?;
    Ok(FoldsLoaded {
        anchors: anchors.into_iter().map(|(_, a)| a).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use norn::store::CoordDb;
    use runstav::methods::folds::AnchorKind;
    use urdr::graph::{Class, TxMeta};

    fn meta() -> TxMeta {
        TxMeta::new("t", Class::User, "test")
    }

    fn fold(start: u32, end: u32, name: Option<&str>) -> Anchor {
        Anchor {
            kind: AnchorKind::Fold,
            start,
            end,
            hash: format!("h{start}"),
            name: name.map(str::to_owned),
            fold_kind: Some("function".into()),
            open: false,
        }
    }

    fn save_params(path: &str, anchors: Vec<Anchor>) -> FoldsSave {
        FoldsSave {
            worktree: "/w".into(),
            path: path.into(),
            anchors,
        }
    }

    async fn saved(db: &CoordDb, p: FoldsSave) -> bool {
        db.write(meta(), move |tx| save_in(tx, &p)).await.unwrap()
    }

    async fn loaded(db: &CoordDb, path: &'static str) -> Vec<Anchor> {
        db.read(move |c| kept(c, "/w", path))
            .await
            .unwrap()
            .into_iter()
            .map(|(_, a)| a)
            .collect()
    }

    #[test]
    fn a_files_anchors_come_back_in_order_and_apart_from_other_files() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let db = CoordDb::spawn(dir.path().join("work.db"));
            let pin = Anchor {
                kind: AnchorKind::Pin,
                fold_kind: None,
                ..fold(40, 60, Some("the parser"))
            };
            let mine = vec![fold(10, 20, None), pin, fold(3, 8, Some("setup"))];
            assert!(saved(&db, save_params("a.rs", mine.clone())).await);
            assert!(saved(&db, save_params("b.rs", vec![fold(1, 2, None)])).await);
            assert_eq!(loaded(&db, "a.rs").await, mine);
            assert_eq!(loaded(&db, "b.rs").await, vec![fold(1, 2, None)]);
            assert_eq!(loaded(&db, "c.rs").await, vec![]);
        })
    }

    #[test]
    fn a_save_replaces_the_files_anchors_and_the_same_save_writes_nothing() {
        saman::Executor::new(2).unwrap().block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let db = CoordDb::spawn(dir.path().join("work.db"));
            assert!(
                saved(
                    &db,
                    save_params("a.rs", vec![fold(10, 20, None), fold(30, 40, None)])
                )
                .await
            );
            assert!(saved(&db, save_params("a.rs", vec![fold(12, 22, Some("n"))])).await);
            assert_eq!(loaded(&db, "a.rs").await, vec![fold(12, 22, Some("n"))]);
            assert!(!saved(&db, save_params("a.rs", vec![fold(12, 22, Some("n"))])).await);
            let live: i64 = db
                .read(|c| {
                    Ok(c.query_row(
                        "select count(*) from entity where kind = 'anchor' and retired_tx is null",
                        [],
                        |r| r.get(0),
                    )?)
                })
                .await
                .unwrap();
            assert_eq!(live, 1);
            // none: the file's anchors are forgotten
            assert!(saved(&db, save_params("a.rs", vec![])).await);
            assert_eq!(loaded(&db, "a.rs").await, vec![]);
        })
    }
}
