//! Links: immutable rows (a version records existence only; current `tx_to` = [`super::schema::SENTINEL`]) and the
//! unversioned `link_stat` counters (Task 2; storage §5.2, §5.4).

use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::entity::Origin;
use super::schema::SENTINEL;
use super::tx::Tx;
use super::writer::WriteError;

/// Which way a link is followed from an entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Out,
    In,
    Both,
}

/// One `link` row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Link {
    pub id: i64,
    pub src: i64,
    pub kind: String,
    pub dst: i64,
    /// Set once at creation (e.g. `{"at": "<commit sha>"}`), never updated.
    pub data: Option<Value>,
    pub origin: Origin,
    pub source: Option<String>,
    pub tx_from: i64,
    pub tx_to: i64,
}

/// What [`add`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Added {
    pub id: i64,
    /// A current row `(src, kind, dst)` was already there; nothing was written.
    pub existed: bool,
}

/// Refuse an end that is missing or retired.
fn check_end(tx: &Tx<'_>, n: i64) -> Result<(), WriteError> {
    let retired: Option<Option<i64>> = tx
        .sql()
        .query_row("select retired_tx from entity where n = ?1", [n], |r| {
            r.get(0)
        })
        .optional()?;
    match retired {
        None => Err(WriteError::Refused(format!("no entity {n}"))),
        Some(Some(_)) => Err(WriteError::Refused(format!("entity {n} is retired"))),
        Some(None) => Ok(()),
    }
}

/// Add the current link `(src, kind, dst)`; a retired end is refused.
pub fn add(
    tx: &mut Tx<'_>,
    src: i64,
    kind: &str,
    dst: i64,
    data: Option<Value>,
    origin: Origin,
    source: Option<&str>,
) -> Result<Added, WriteError> {
    check_end(tx, src)?;
    check_end(tx, dst)?;
    let current: Option<i64> = tx
        .sql()
        .query_row(
            "select id from link where src = ?1 and kind = ?2 and dst = ?3 and tx_to = ?4",
            params![src, kind, dst, SENTINEL],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = current {
        return Ok(Added { id, existed: true });
    }
    let data = data.map(|v| v.to_string());
    tx.sql().execute(
        "insert into link (src, kind, dst, data, origin, source, tx_from) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![src, kind, dst, data, origin.as_str(), source, tx.id()],
    )?;
    Ok(Added {
        id: tx.sql().last_insert_rowid(),
        existed: false,
    })
}

/// Retire the current link `(src, kind, dst)` (`tx_to` = this tx); false when there was none.
pub fn retire(tx: &mut Tx<'_>, src: i64, kind: &str, dst: i64) -> Result<bool, WriteError> {
    let changed = tx.sql().execute(
        "update link set tx_to = ?1 where src = ?2 and kind = ?3 and dst = ?4 and tx_to = ?5",
        params![tx.id(), src, kind, dst, SENTINEL],
    )?;
    Ok(changed > 0)
}

/// Retire every current link whose `source` is SOURCE; the count.
pub fn retire_by_source(tx: &mut Tx<'_>, source: &str) -> Result<u64, WriteError> {
    let changed = tx.sql().execute(
        "update link set tx_to = ?1 where source = ?2 and tx_to = ?3",
        params![tx.id(), source, SENTINEL],
    )?;
    Ok(changed as u64)
}

/// `link_stat`: count + 1 and `last_tx`, keeping `first_tx`. Not versioned.
pub fn stat_bump(tx: &mut Tx<'_>, src: i64, kind: &str, dst: i64) -> Result<(), WriteError> {
    tx.sql().execute(
        "insert into link_stat (src, kind, dst, count, first_tx, last_tx) values (?1, ?2, ?3, 1, ?4, ?4)
         on conflict (src, kind, dst) do update set count = count + 1, last_tx = excluded.last_tx",
        params![src, kind, dst, tx.id()],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::entity::{self, EntityNew};
    use crate::graph::guard::Guard;
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::{Class, TxMeta};
    use rusqlite::Connection;
    use std::sync::Arc;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        conn
    }

    fn meta() -> TxMeta {
        TxMeta::new("user", Class::User, "test")
    }

    fn ent(tx: &mut Tx<'_>, id: &str) -> i64 {
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "task".into(),
                project: None,
                title: Some(id.into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: serde_json::json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap()
        .n
    }

    fn setup(conn: &mut Connection) -> (i64, i64) {
        let mut tx = Tx::for_test(conn, meta(), Arc::new(Guard::default()));
        let a = ent(&mut tx, "task:a");
        let b = ent(&mut tx, "task:b");
        tx.commit_for_test().unwrap();
        (a, b)
    }

    #[test]
    fn links_are_immutable() {
        let mut conn = db();
        let (a, b) = setup(&mut conn);
        let mut tx = Tx::for_test(&mut conn, meta(), Arc::new(Guard::default()));
        let first = add(
            &mut tx,
            a,
            "blocks",
            b,
            Some(serde_json::json!({"at": "abc"})),
            Origin::Recorded,
            None,
        )
        .unwrap();
        assert!(!first.existed);
        // A second add with other data changes nothing.
        let again = add(
            &mut tx,
            a,
            "blocks",
            b,
            Some(serde_json::json!({"at": "zzz"})),
            Origin::Recorded,
            None,
        )
        .unwrap();
        assert_eq!(
            again,
            Added {
                id: first.id,
                existed: true
            }
        );
        let data: String = tx
            .sql()
            .query_row("select data from link where id = ?1", [first.id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(data, r#"{"at":"abc"}"#);
    }

    #[test]
    fn re_add_after_retire_is_a_new_row() {
        let mut conn = db();
        let (a, b) = setup(&mut conn);
        let mut tx = Tx::for_test(&mut conn, meta(), Arc::new(Guard::default()));
        let first = add(&mut tx, a, "blocks", b, None, Origin::Recorded, Some("s")).unwrap();
        assert!(retire(&mut tx, a, "blocks", b).unwrap());
        assert!(!retire(&mut tx, a, "blocks", b).unwrap());
        let second = add(&mut tx, a, "blocks", b, None, Origin::Recorded, Some("s")).unwrap();
        assert!(!second.existed);
        assert_ne!(first.id, second.id);
        let rows: i64 = tx
            .sql()
            .query_row(
                "select count(*) from link where src = ?1 and dst = ?2",
                [a, b],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(rows, 2);
        assert_eq!(retire_by_source(&mut tx, "s").unwrap(), 1);
    }

    #[test]
    fn a_link_to_a_retired_entity_is_refused() {
        let mut conn = db();
        let (a, b) = setup(&mut conn);
        let mut tx = Tx::for_test(&mut conn, meta(), Arc::new(Guard::default()));
        entity::retire(&mut tx, b).unwrap();
        let err = add(&mut tx, a, "blocks", b, None, Origin::Recorded, None).unwrap_err();
        assert!(matches!(err, WriteError::Refused(_)), "{err:?}");
        let err = add(&mut tx, b, "blocks", a, None, Origin::Recorded, None).unwrap_err();
        assert!(matches!(err, WriteError::Refused(_)), "{err:?}");
    }

    #[test]
    fn stat_bump_is_not_versioned() {
        let mut conn = db();
        let (a, b) = setup(&mut conn);
        let mut tx = Tx::for_test(&mut conn, meta(), Arc::new(Guard::default()));
        let first_tx = tx.id();
        stat_bump(&mut tx, a, "touched", b).unwrap();
        stat_bump(&mut tx, a, "touched", b).unwrap();
        let (count, first, last): (i64, i64, i64) = tx
            .sql()
            .query_row("select count, first_tx, last_tx from link_stat", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!((count, first, last), (2, first_tx, first_tx));
        let links: i64 = tx
            .sql()
            .query_row("select count(*) from link", [], |r| r.get(0))
            .unwrap();
        assert_eq!(links, 0);
    }
}
