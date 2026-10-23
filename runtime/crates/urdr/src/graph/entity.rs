//! Entities: create, update (versions in `entity_hist`, `field_tx`, the FTS row, all in the caller's tx), retire, and
//! the current-state readers (Task 2; storage §5.2).

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::guard;
use super::search::fts_put;
use super::tx::{Class, Tx};
use super::writer::WriteError;

/// `entity.origin`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    Recorded,
    Parsed,
    Inferred,
    Imported,
}

impl Origin {
    /// The column's text.
    pub fn as_str(self) -> &'static str {
        match self {
            Origin::Recorded => "recorded",
            Origin::Parsed => "parsed",
            Origin::Inferred => "inferred",
            Origin::Imported => "imported",
        }
    }

    /// The column's text back to the value; `None` for an unknown word.
    pub fn parse(text: &str) -> Option<Origin> {
        match text {
            "recorded" => Some(Origin::Recorded),
            "parsed" => Some(Origin::Parsed),
            "inferred" => Some(Origin::Inferred),
            "imported" => Some(Origin::Imported),
            _ => None,
        }
    }
}

/// The lease columns (`lease_holder`, `lease_epoch`, `lease_until`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Lease {
    pub holder: Option<String>,
    pub epoch: i64,
    pub until: Option<f64>,
}

/// A new entity. `kind` is a string here; the closed list is the caller's.
#[derive(Clone, Debug, PartialEq)]
pub struct EntityNew {
    pub id: String,
    pub kind: String,
    pub project: Option<i64>,
    pub title: Option<String>,
    pub status: Option<String>,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub assignee: Option<String>,
    /// A JSON object.
    pub data: Value,
    pub origin: Origin,
    pub source: Option<String>,
}

/// An entity's current row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ent {
    pub n: i64,
    pub id: String,
    pub kind: String,
    pub project: Option<i64>,
    pub title: Option<String>,
    pub status: Option<String>,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub assignee: Option<String>,
    pub lease: Lease,
    pub data: Value,
    /// Field → the tx that last set it.
    pub field_tx: BTreeMap<String, i64>,
    pub origin: Origin,
    pub source: Option<String>,
    pub ver: i64,
    pub created_tx: i64,
    pub updated_tx: i64,
    pub retired_tx: Option<i64>,
}

/// An update's fields: `None` leaves a field alone; for a nullable field `Some(None)` clears it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Changes {
    pub project: Option<Option<i64>>,
    pub title: Option<Option<String>>,
    pub status: Option<Option<String>>,
    pub body: Option<Option<String>>,
    pub priority: Option<Option<i64>>,
    pub assignee: Option<Option<String>>,
    /// Merged into `data` with JSON merge-patch rules (RFC 7396).
    pub data_patch: Option<Value>,
    pub lease: Option<Lease>,
}

/// A field changed since the version a caller had: its new value, who set it and in which tx.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FieldChange {
    pub field: String,
    pub to: Value,
    pub by: String,
    pub class: Class,
    pub tx: i64,
}

/// What an update did.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Update {
    Done {
        ver: i64,
    },
    /// `expect_ver` was stale: nothing written.
    Conflict {
        ver: i64,
        changed_since: Vec<FieldChange>,
    },
}

/// The `entity` columns [`from_row`] reads, in its order.
pub(crate) const COLS: &str = "n, id, kind, project, title, status, body, priority, assignee, lease_holder, \
     lease_epoch, lease_until, data, field_tx, origin, source, ver, created_tx, updated_tx, retired_tx";

fn bad(col: usize, what: &str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        col,
        rusqlite::types::Type::Text,
        what.to_string().into(),
    )
}

/// An `entity` row selected with [`COLS`].
pub(crate) fn from_row(r: &Row<'_>) -> rusqlite::Result<Ent> {
    let data: String = r.get(12)?;
    let field_tx: String = r.get(13)?;
    let origin: String = r.get(14)?;
    Ok(Ent {
        n: r.get(0)?,
        id: r.get(1)?,
        kind: r.get(2)?,
        project: r.get(3)?,
        title: r.get(4)?,
        status: r.get(5)?,
        body: r.get(6)?,
        priority: r.get(7)?,
        assignee: r.get(8)?,
        lease: Lease {
            holder: r.get(9)?,
            epoch: r.get(10)?,
            until: r.get(11)?,
        },
        data: serde_json::from_str(&data).map_err(|e| bad(12, &e.to_string()))?,
        field_tx: serde_json::from_str(&field_tx).map_err(|e| bad(13, &e.to_string()))?,
        origin: Origin::parse(&origin).ok_or_else(|| bad(14, "unknown origin"))?,
        source: r.get(15)?,
        ver: r.get(16)?,
        created_tx: r.get(17)?,
        updated_tx: r.get(18)?,
        retired_tx: r.get(19)?,
    })
}

/// RFC 7396.
fn merge_patch(target: &mut Value, patch: &Value) {
    match patch {
        Value::Object(p) => {
            if !target.is_object() {
                *target = json!({});
            }
            let t = target.as_object_mut().expect("just made an object");
            for (k, v) in p {
                if v.is_null() {
                    t.remove(k);
                } else {
                    merge_patch(t.entry(k.clone()).or_insert(Value::Null), v);
                }
            }
        }
        other => *target = other.clone(),
    }
}

fn is_empty_object(v: &Value) -> bool {
    v.as_object().is_some_and(|o| o.is_empty())
}

fn text_json(v: &Option<String>) -> Value {
    v.as_ref().map_or(Value::Null, |s| json!(s))
}

/// A field's current value as the conflict shows it.
fn field_value(e: &Ent, field: &str) -> Value {
    match field {
        "project" => json!(e.project),
        "title" => text_json(&e.title),
        "status" => text_json(&e.status),
        "body" => text_json(&e.body),
        "priority" => json!(e.priority),
        "assignee" => text_json(&e.assignee),
        "data" => e.data.clone(),
        "lease" => json!(e.lease),
        _ => Value::Null,
    }
}

/// Copy entity E's current row to `entity_hist`, valid until this tx.
fn to_hist(tx: &Tx<'_>, e: &Ent) -> Result<(), WriteError> {
    tx.sql().execute(
        "insert into entity_hist (n, ver, tx_from, tx_to, kind, project, title, status, body, priority, assignee, \
         data, field_tx) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        params![
            e.n,
            e.ver,
            e.updated_tx,
            tx.id(),
            e.kind,
            e.project,
            e.title,
            e.status,
            e.body,
            e.priority,
            e.assignee,
            e.data.to_string(),
            serde_json::to_string(&e.field_tx).expect("a map of integers"),
        ],
    )?;
    Ok(())
}

/// Insert a new entity at `ver = 1` with its `field_tx` and FTS row; a duplicate `id` is `Refused("id exists")`.
/// The guard is checked first.
pub fn create(tx: &mut Tx<'_>, new: EntityNew) -> Result<Ent, WriteError> {
    guard::check(tx.guard(), tx.meta(), &new.kind)?;
    if !new.data.is_object() {
        return Err(WriteError::Refused("data must be a JSON object".into()));
    }
    let exists: Option<i64> = tx
        .sql()
        .query_row("select n from entity where id = ?1", [&new.id], |r| {
            r.get(0)
        })
        .optional()?;
    if exists.is_some() {
        return Err(WriteError::Refused("id exists".into()));
    }
    let id = tx.id();
    let mut field_tx = BTreeMap::new();
    if new.project.is_some() {
        field_tx.insert("project".to_string(), id);
    }
    if new.title.is_some() {
        field_tx.insert("title".to_string(), id);
    }
    if new.status.is_some() {
        field_tx.insert("status".to_string(), id);
    }
    if new.body.is_some() {
        field_tx.insert("body".to_string(), id);
    }
    if new.priority.is_some() {
        field_tx.insert("priority".to_string(), id);
    }
    if new.assignee.is_some() {
        field_tx.insert("assignee".to_string(), id);
    }
    if !is_empty_object(&new.data) {
        field_tx.insert("data".to_string(), id);
    }
    tx.sql().execute(
        "insert into entity (id, kind, project, title, status, body, priority, assignee, data, field_tx, origin, \
         source, ver, created_tx, updated_tx) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1, ?13, ?13)",
        params![
            new.id,
            new.kind,
            new.project,
            new.title,
            new.status,
            new.body,
            new.priority,
            new.assignee,
            new.data.to_string(),
            serde_json::to_string(&field_tx).expect("a map of integers"),
            new.origin.as_str(),
            new.source,
            id,
        ],
    )?;
    let n = tx.sql().last_insert_rowid();
    fts_put(tx, n, new.title.as_deref(), new.body.as_deref())?;
    Ok(Ent {
        n,
        id: new.id,
        kind: new.kind,
        project: new.project,
        title: new.title,
        status: new.status,
        body: new.body,
        priority: new.priority,
        assignee: new.assignee,
        lease: Lease::default(),
        data: new.data,
        field_tx,
        origin: new.origin,
        source: new.source,
        ver: 1,
        created_tx: id,
        updated_tx: id,
        retired_tx: None,
    })
}

/// The fields changed since the version EXPECT: the base is the tx that wrote it (its `entity_hist` row's
/// `tx_from`); a version no longer in history counts everything as newer.
fn changed_since(tx: &Tx<'_>, cur: &Ent, expect: i64) -> Result<Vec<FieldChange>, WriteError> {
    let base: i64 = tx
        .sql()
        .query_row(
            "select tx_from from entity_hist where n = ?1 and ver = ?2",
            params![cur.n, expect],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0);
    let mut out = Vec::new();
    for (field, &txid) in &cur.field_tx {
        if txid <= base {
            continue;
        }
        let who: Option<(String, String)> = tx
            .sql()
            .query_row("select actor, class from tx where id = ?1", [txid], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()?;
        let (by, class) = who.unwrap_or_else(|| ("unknown".into(), "system".into()));
        out.push(FieldChange {
            field: field.clone(),
            to: field_value(cur, field),
            by,
            class: serde_json::from_value(Value::String(class)).unwrap_or(Class::System),
            tx: txid,
        });
    }
    Ok(out)
}

/// Change entity N: with EXPECT_VER stale, a conflict listing the newer fields; else the old row to `entity_hist`,
/// the changes, `ver + 1`, `field_tx`, `updated_tx`, the FTS row when title or body changed. A change of nothing
/// writes nothing. The guard is checked first.
pub fn update(
    tx: &mut Tx<'_>,
    n: i64,
    expect_ver: Option<i64>,
    changes: Changes,
) -> Result<Update, WriteError> {
    let cur = by_n(tx.sql(), n)?.ok_or_else(|| WriteError::Refused(format!("no entity {n}")))?;
    guard::check(tx.guard(), tx.meta(), &cur.kind)?;
    if let Some(v) = expect_ver
        && v != cur.ver
    {
        return Ok(Update::Conflict {
            ver: cur.ver,
            changed_since: changed_since(tx, &cur, v)?,
        });
    }
    let mut new = cur.clone();
    let mut changed: Vec<&str> = Vec::new();
    if let Some(v) = changes.project
        && v != cur.project
    {
        new.project = v;
        changed.push("project");
    }
    if let Some(v) = changes.title
        && v != cur.title
    {
        new.title = v;
        changed.push("title");
    }
    if let Some(v) = changes.status
        && v != cur.status
    {
        new.status = v;
        changed.push("status");
    }
    if let Some(v) = changes.body
        && v != cur.body
    {
        new.body = v;
        changed.push("body");
    }
    if let Some(v) = changes.priority
        && v != cur.priority
    {
        new.priority = v;
        changed.push("priority");
    }
    if let Some(v) = changes.assignee
        && v != cur.assignee
    {
        new.assignee = v;
        changed.push("assignee");
    }
    if let Some(patch) = &changes.data_patch {
        if !patch.is_object() {
            return Err(WriteError::Refused(
                "a data patch must be a JSON object".into(),
            ));
        }
        let mut merged = cur.data.clone();
        merge_patch(&mut merged, patch);
        if merged != cur.data {
            new.data = merged;
            changed.push("data");
        }
    }
    if let Some(l) = changes.lease
        && l != cur.lease
    {
        new.lease = l;
        changed.push("lease");
    }
    if changed.is_empty() {
        return Ok(Update::Done { ver: cur.ver });
    }
    let id = tx.id();
    for f in &changed {
        new.field_tx.insert((*f).to_string(), id);
    }
    to_hist(tx, &cur)?;
    new.ver = cur.ver + 1;
    tx.sql().execute(
        "update entity set project = ?2, title = ?3, status = ?4, body = ?5, priority = ?6, assignee = ?7, \
         lease_holder = ?8, lease_epoch = ?9, lease_until = ?10, data = ?11, field_tx = ?12, ver = ?13, \
         updated_tx = ?14 where n = ?1",
        params![
            n,
            new.project,
            new.title,
            new.status,
            new.body,
            new.priority,
            new.assignee,
            new.lease.holder,
            new.lease.epoch,
            new.lease.until,
            new.data.to_string(),
            serde_json::to_string(&new.field_tx).expect("a map of integers"),
            new.ver,
            id,
        ],
    )?;
    if changed.contains(&"title") || changed.contains(&"body") {
        fts_put(tx, n, new.title.as_deref(), new.body.as_deref())?;
    }
    Ok(Update::Done { ver: new.ver })
}

/// Set `retired_tx` (a new version); the row stays and `n` is never reused. Retiring a retired entity is a no-op.
/// The guard is checked, as for [`update`].
pub fn retire(tx: &mut Tx<'_>, n: i64) -> Result<(), WriteError> {
    let cur = by_n(tx.sql(), n)?.ok_or_else(|| WriteError::Refused(format!("no entity {n}")))?;
    guard::check(tx.guard(), tx.meta(), &cur.kind)?;
    if cur.retired_tx.is_some() {
        return Ok(());
    }
    to_hist(tx, &cur)?;
    let id = tx.id();
    tx.sql().execute(
        "update entity set retired_tx = ?2, updated_tx = ?2, ver = ver + 1 where n = ?1",
        params![n, id],
    )?;
    Ok(())
}

/// The current row of the entity ID, retired or not.
pub fn by_id(conn: &Connection, id: &str) -> rusqlite::Result<Option<Ent>> {
    conn.query_row(
        &format!("select {COLS} from entity where id = ?1"),
        [id],
        from_row,
    )
    .optional()
}

/// The current row of entity N, retired or not.
pub fn by_n(conn: &Connection, n: i64) -> rusqlite::Result<Option<Ent>> {
    conn.query_row(
        &format!("select {COLS} from entity where n = ?1"),
        [n],
        from_row,
    )
    .optional()
}

/// Point SLUG at the project entity PROJECT in `project_alias` (a new slug, or one that moves), stamped with this
/// tx. Which slugs a project may take is the caller's policy (norn's `project::register`); an entity that is not of
/// kind `project` is refused.
pub fn set_alias(tx: &mut Tx<'_>, slug: &str, project: i64) -> Result<(), WriteError> {
    let kind: Option<String> = tx
        .sql()
        .query_row("select kind from entity where n = ?1", [project], |r| {
            r.get(0)
        })
        .optional()?;
    if kind.as_deref() != Some("project") {
        return Err(WriteError::Refused(format!(
            "entity {project} is not a project"
        )));
    }
    tx.sql().execute(
        "insert into project_alias (slug, project, tx) values (?1, ?2, ?3) \
         on conflict(slug) do update set project = excluded.project, tx = excluded.tx",
        params![slug, project, tx.id()],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::guard::Guard;
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::TxMeta;
    use std::sync::Arc;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        conn
    }

    fn meta(actor: &str, class: Class) -> TxMeta {
        TxMeta::new(actor, class, "test")
    }

    fn tx<'a>(conn: &'a mut Connection, actor: &str, class: Class) -> Tx<'a> {
        Tx::for_test(conn, meta(actor, class), Arc::new(Guard::default()))
    }

    fn new_task(id: &str) -> EntityNew {
        EntityNew {
            id: id.into(),
            kind: "task".into(),
            project: None,
            title: Some("first title".into()),
            status: Some("open".into()),
            body: Some("first body".into()),
            priority: None,
            assignee: None,
            data: json!({}),
            origin: Origin::Recorded,
            source: None,
        }
    }

    fn title(t: &str) -> Changes {
        Changes {
            title: Some(Some(t.into())),
            ..Changes::default()
        }
    }

    #[test]
    fn create_sets_field_tx() {
        let mut conn = db();
        let mut t = tx(&mut conn, "user", Class::User);
        let e = create(&mut t, new_task("task:a")).unwrap();
        let id = t.id();
        assert_eq!(e.ver, 1);
        assert_eq!((e.created_tx, e.updated_tx), (id, id));
        let want: BTreeMap<String, i64> = [("title", id), ("status", id), ("body", id)]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        assert_eq!(e.field_tx, want);
        assert_eq!(by_id(t.sql(), "task:a").unwrap().unwrap(), e);
        assert_eq!(
            create(&mut t, new_task("task:a")).unwrap_err(),
            WriteError::Refused("id exists".into())
        );
    }

    #[test]
    fn update_keeps_the_old_version_in_hist() {
        let mut conn = db();
        let (n, tx1) = {
            let mut t = tx(&mut conn, "user", Class::User);
            let e = create(&mut t, new_task("task:a")).unwrap();
            let id = t.id();
            t.commit_for_test().unwrap();
            (e.n, id)
        };
        let mut t = tx(&mut conn, "agent:s1", Class::Agent);
        let tx2 = t.id();
        assert_eq!(
            update(&mut t, n, Some(1), title("second")).unwrap(),
            Update::Done { ver: 2 }
        );
        let (ver, from, to, old): (i64, i64, i64, String) = t
            .sql()
            .query_row(
                "select ver, tx_from, tx_to, title from entity_hist where n = ?1",
                [n],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!((ver, from, to, old.as_str()), (1, tx1, tx2, "first title"));
        let e = by_n(t.sql(), n).unwrap().unwrap();
        assert_eq!(
            (e.ver, e.updated_tx, e.title.as_deref()),
            (2, tx2, Some("second"))
        );
        assert_eq!(e.field_tx["title"], tx2);
        assert_eq!(e.field_tx["body"], tx1);
    }

    #[test]
    fn a_stale_ver_is_a_conflict_listing_newer_fields() {
        let mut conn = db();
        let n = {
            let mut t = tx(&mut conn, "user", Class::User);
            let e = create(&mut t, new_task("task:a")).unwrap();
            t.commit_for_test().unwrap();
            e.n
        };
        {
            let mut t = tx(&mut conn, "user", Class::User);
            update(&mut t, n, Some(1), title("second")).unwrap();
            t.commit_for_test().unwrap();
        }
        let tx3 = {
            let mut t = tx(&mut conn, "agent:s1", Class::Agent);
            let body = Changes {
                body: Some(Some("agent body".into())),
                ..Changes::default()
            };
            update(&mut t, n, Some(2), body).unwrap();
            let id = t.id();
            t.commit_for_test().unwrap();
            id
        };
        // A caller who read version 2 now writes with ver 2: only the body is newer than what it saw.
        let mut t = tx(&mut conn, "user", Class::User);
        let got = update(&mut t, n, Some(2), title("mine")).unwrap();
        assert_eq!(
            got,
            Update::Conflict {
                ver: 3,
                changed_since: vec![FieldChange {
                    field: "body".into(),
                    to: json!("agent body"),
                    by: "agent:s1".into(),
                    class: Class::Agent,
                    tx: tx3,
                }]
            }
        );
        // Nothing was written.
        assert_eq!(
            by_n(t.sql(), n).unwrap().unwrap().title.as_deref(),
            Some("second")
        );
    }

    #[test]
    fn a_no_op_update_writes_nothing() {
        let mut conn = db();
        let mut t = tx(&mut conn, "user", Class::User);
        let n = create(&mut t, new_task("task:a")).unwrap().n;
        let before = by_n(t.sql(), n).unwrap().unwrap();
        let same = Changes {
            title: Some(Some("first title".into())),
            data_patch: Some(json!({})),
            ..Changes::default()
        };
        assert_eq!(
            update(&mut t, n, None, same).unwrap(),
            Update::Done { ver: 1 }
        );
        assert_eq!(by_n(t.sql(), n).unwrap().unwrap(), before);
        let hist: i64 = t
            .sql()
            .query_row("select count(*) from entity_hist", [], |r| r.get(0))
            .unwrap();
        assert_eq!(hist, 0);
    }

    #[test]
    fn retire_keeps_n() {
        let mut conn = db();
        let mut t = tx(&mut conn, "user", Class::User);
        let a = create(&mut t, new_task("task:a")).unwrap().n;
        retire(&mut t, a).unwrap();
        let e = by_n(t.sql(), a).unwrap().unwrap();
        assert_eq!((e.retired_tx, e.ver), (Some(t.id()), 2));
        let b = create(&mut t, new_task("task:b")).unwrap().n;
        assert_ne!(a, b);
        assert!(by_id(t.sql(), "task:a").unwrap().is_some());
        let hist: i64 = t
            .sql()
            .query_row("select count(*) from entity_hist where n = ?1", [a], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(hist, 1);
    }

    fn fts_hits(conn: &Connection, word: &str) -> Vec<i64> {
        let mut stmt = conn
            .prepare("select rowid from entity_fts where entity_fts match ?1 order by rowid")
            .unwrap();
        stmt.query_map([word], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    }

    #[test]
    fn fts_follows_title_and_body() {
        let mut conn = db();
        let mut t = tx(&mut conn, "user", Class::User);
        let n = create(&mut t, new_task("task:a")).unwrap().n;
        assert_eq!(fts_hits(t.sql(), "first"), vec![n]);
        let c = Changes {
            title: Some(Some("renamed".into())),
            body: Some(Some("other words".into())),
            ..Changes::default()
        };
        update(&mut t, n, None, c).unwrap();
        assert!(fts_hits(t.sql(), "first").is_empty());
        assert_eq!(fts_hits(t.sql(), "renamed"), vec![n]);
        assert_eq!(fts_hits(t.sql(), "words"), vec![n]);
        // A change that touches neither leaves the row alone.
        let c = Changes {
            status: Some(Some("done".into())),
            ..Changes::default()
        };
        update(&mut t, n, None, c).unwrap();
        assert_eq!(fts_hits(t.sql(), "renamed"), vec![n]);
    }

    /// Checkpoint CONN's WAL into PATH (truncating it), then scan PATH's bytes for TOKEN.
    fn in_file(conn: &Connection, path: &std::path::Path, token: &str) -> bool {
        conn.query_row("pragma wal_checkpoint(truncate)", [], |_| Ok(()))
            .unwrap();
        let bytes = std::fs::read(path).unwrap();
        bytes.windows(token.len()).any(|w| w == token.as_bytes())
    }

    #[test]
    fn fts_delete_by_rowid_leaves_no_token() {
        use crate::graph::search::fts_delete;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fts.db");
        let mut conn = Connection::open(&path).unwrap();
        // As the writer runs: WAL and `secure_delete=ON`.
        conn.execute_batch("pragma journal_mode = wal; pragma secure_delete = on;")
            .unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        // One token in a version that an update replaced, one in the version that is deleted. They share no prefix
        // with each other or the other words, so FTS5's prefix compression stores each whole (the scan can see it).
        let old = format!("old{nanos:x}");
        let cur = format!("cur{nanos:x}");
        let put = |conn: &mut Connection, n: i64, body: &str| {
            let mut t = tx(conn, "user", Class::User);
            fts_put(&mut t, n, Some("a title"), Some(body)).unwrap();
            t.commit_for_test().unwrap();
        };
        put(&mut conn, 2, "a keeper row");
        put(&mut conn, 1, &format!("some {old} body"));
        // The controls: each token is in the file once written, so the scan can see it.
        assert!(
            in_file(&conn, &path, &old),
            "the old token after the insert"
        );
        put(&mut conn, 1, &format!("some {cur} body"));
        assert!(in_file(&conn, &path, &cur), "the token after the update");
        {
            let mut t = tx(&mut conn, "user", Class::User);
            fts_delete(&mut t, 1).unwrap();
            t.commit_for_test().unwrap();
        }
        assert!(
            !in_file(&conn, &path, &cur),
            "the deleted row's token is still in the file"
        );
        assert!(
            !in_file(&conn, &path, &old),
            "a replaced version's token is still in the file"
        );
        // The other row survives the rewrite.
        assert_eq!(fts_hits(&conn, "keeper"), vec![2]);
    }
}
