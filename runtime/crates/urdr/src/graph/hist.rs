//! History: as-of reads, versions with their authors, revert, restore, proposed txs (Task 3; storage §5.2 "each kind
//! of query", §6.3, §6.5). Policy-free: the class check is the caller's.
//!
//! A version of an entity is the current `entity` row or an `entity_hist` row; version V of entity N was written by
//! tx `tx_from` and lasts until `tx_to`. `entity_hist` keeps each version's lease, origin and `retired_tx` too, so an
//! old version answers them as they were (URDR-HIST-RETIRED-1); its `source` is the entity's (it never changes).

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::entity::{self, Ent, Lease, Origin, Snap, Update};
use super::link::{self, Direction, Link};
use super::schema::SENTINEL;
use super::tx::{Class, Tx, TxState};
use super::writer::WriteError;

/// An entity as of a tx; `approximate` when that version's tx was synthesized at the migration (`imported = 1`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AsOf {
    pub ent: Ent,
    pub approximate: bool,
}

/// One version of an entity, with its tx's author.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Version {
    pub ver: i64,
    pub tx: i64,
    pub at: f64,
    pub actor: String,
    pub class: Class,
    pub tool: Option<String>,
    pub session: Option<String>,
    /// The fields this version changed.
    pub fields: Vec<String>,
    pub imported: bool,
}

/// A link row with the authors of the txs that added and retired it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LinkVersion {
    pub link: Link,
    pub added_by: String,
    pub added_class: Class,
    /// `None` while the link is current.
    pub retired_by: Option<String>,
    pub retired_class: Option<Class>,
}

/// What a revert (or a rejection of proposed txs) did.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Revert {
    /// The entities given a restoring version, and the links retired or re-added.
    Done { entities: Vec<i64>, links: Vec<i64> },
    /// A later tx changed an entity the target wrote: nothing written.
    Blocked { later: Vec<i64> },
}

fn class_of(text: &str) -> Class {
    match text {
        "user" => Class::User,
        "agent" => Class::Agent,
        "ext" => Class::Ext,
        _ => Class::System,
    }
}

/// `select max(id) from tx where at <= AT` (0 when none).
pub fn tx_at(conn: &Connection, at: f64) -> rusqlite::Result<i64> {
    conn.query_row(
        "select coalesce(max(id), 0) from tx where at <= ?1",
        [at],
        |r| r.get(0),
    )
}

/// An `entity_hist` row.
struct Hist {
    ver: i64,
    tx_from: i64,
    kind: String,
    snap: Snap,
    field_tx: BTreeMap<String, i64>,
    lease: Lease,
    /// `None` in a row written without one (a test's hand-made row): the entity's origin then.
    origin: Option<Origin>,
    retired_tx: Option<i64>,
}

const HIST_COLS: &str = "ver, tx_from, kind, project, title, status, body, priority, assignee, data, field_tx, \
     lease_holder, lease_epoch, lease_until, origin, retired_tx";

fn hist_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Hist> {
    let bad = |col: usize, e: serde_json::Error| {
        rusqlite::Error::FromSqlConversionFailure(
            col,
            rusqlite::types::Type::Text,
            e.to_string().into(),
        )
    };
    let data: Option<String> = r.get(9)?;
    let field_tx: Option<String> = r.get(10)?;
    Ok(Hist {
        ver: r.get(0)?,
        tx_from: r.get(1)?,
        kind: r.get(2)?,
        snap: Snap {
            project: r.get(3)?,
            title: r.get(4)?,
            status: r.get(5)?,
            body: r.get(6)?,
            priority: r.get(7)?,
            assignee: r.get(8)?,
            data: match data {
                Some(d) => serde_json::from_str(&d).map_err(|e| bad(9, e))?,
                None => Value::Object(Default::default()),
            },
        },
        field_tx: match field_tx {
            Some(f) => serde_json::from_str(&f).map_err(|e| bad(10, e))?,
            None => BTreeMap::new(),
        },
        lease: Lease {
            holder: r.get(11)?,
            epoch: r.get::<_, Option<i64>>(12)?.unwrap_or(0),
            until: r.get(13)?,
        },
        origin: r
            .get::<_, Option<String>>(14)?
            .and_then(|o| Origin::parse(&o)),
        retired_tx: r.get(15)?,
    })
}

fn hist_version(conn: &Connection, n: i64, ver: i64) -> rusqlite::Result<Option<Hist>> {
    conn.query_row(
        &format!("select {HIST_COLS} from entity_hist where n = ?1 and ver = ?2"),
        params![n, ver],
        hist_from_row,
    )
    .optional()
}

fn tx_imported(conn: &Connection, tx: i64) -> rusqlite::Result<bool> {
    Ok(conn
        .query_row("select imported from tx where id = ?1", [tx], |r| {
            r.get::<_, i64>(0)
        })
        .optional()?
        .unwrap_or(0)
        != 0)
}

/// Entity N as of TX: the current row if `updated_tx <= TX`, else the `entity_hist` row with `tx_from <= TX < tx_to`,
/// none if it was created after TX.
pub fn entity_as_of(conn: &Connection, n: i64, tx: i64) -> rusqlite::Result<Option<AsOf>> {
    let Some(cur) = entity::by_n(conn, n)? else {
        return Ok(None);
    };
    if cur.created_tx > tx {
        return Ok(None);
    }
    if cur.updated_tx <= tx {
        let approximate = tx_imported(conn, cur.updated_tx)?;
        return Ok(Some(AsOf {
            ent: cur,
            approximate,
        }));
    }
    // Versions are consecutive intervals: the first `tx_to` past TX is the one that held at TX (a zero-width row,
    // one tx writing twice, fails the `tx_from` test and the scan goes on to the real one).
    let h = conn
        .query_row(
            &format!(
                "select {HIST_COLS} from entity_hist indexed by entity_hist_tx \
                 where n = ?1 and tx_to > ?2 and tx_from <= ?2 order by tx_to limit 1"
            ),
            params![n, tx],
            hist_from_row,
        )
        .optional()?;
    let Some(h) = h else {
        return Ok(None);
    };
    let approximate = tx_imported(conn, h.tx_from)?;
    Ok(Some(AsOf {
        ent: Ent {
            n,
            id: cur.id,
            kind: h.kind,
            project: h.snap.project,
            title: h.snap.title,
            status: h.snap.status,
            body: h.snap.body,
            priority: h.snap.priority,
            assignee: h.snap.assignee,
            lease: h.lease,
            data: h.snap.data,
            field_tx: h.field_tx,
            origin: h.origin.unwrap_or(cur.origin),
            source: cur.source,
            ver: h.ver,
            created_tx: cur.created_tx,
            updated_tx: h.tx_from,
            retired_tx: h.retired_tx,
        },
        approximate,
    }))
}

const LINK_COLS: &str = "id, src, kind, dst, data, origin, source, tx_from, tx_to";

fn link_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Link> {
    let data: Option<String> = r.get(4)?;
    let origin: String = r.get(5)?;
    let bad = |col: usize, what: String| {
        rusqlite::Error::FromSqlConversionFailure(col, rusqlite::types::Type::Text, what.into())
    };
    Ok(Link {
        id: r.get(0)?,
        src: r.get(1)?,
        kind: r.get(2)?,
        dst: r.get(3)?,
        data: match data {
            Some(d) => Some(serde_json::from_str(&d).map_err(|e| bad(4, e.to_string()))?),
            None => None,
        },
        origin: Origin::parse(&origin).ok_or_else(|| bad(5, "unknown origin".into()))?,
        source: r.get(6)?,
        tx_from: r.get(7)?,
        tx_to: r.get(8)?,
    })
}

/// The links of N in DIRECTION with a kind in KINDS (all when empty) that existed at TX.
pub fn links_as_of(
    conn: &Connection,
    n: i64,
    kinds: &[String],
    direction: Direction,
    tx: i64,
) -> rusqlite::Result<Vec<Link>> {
    let mut out: BTreeMap<i64, Link> = BTreeMap::new();
    let sides: &[(&str, &str)] = match direction {
        Direction::Out => &[("src", "link_out")],
        Direction::In => &[("dst", "link_in")],
        Direction::Both => &[("src", "link_out"), ("dst", "link_in")],
    };
    for (col, index) in sides {
        let mut run = |kind: Option<&str>| -> rusqlite::Result<()> {
            // `kind = ?3` as its own conjunct lets the index seek (src, kind, tx_to range).
            let sql = format!(
                "select {LINK_COLS} from link indexed by {index} where {col} = ?1 and tx_to > ?2 and tx_from <= ?2{}",
                if kind.is_some() { " and kind = ?3" } else { "" }
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = match kind {
                Some(k) => stmt.query_map(params![n, tx, k], link_from_row)?,
                None => stmt.query_map(params![n, tx], link_from_row)?,
            };
            for l in rows {
                let l = l?;
                out.insert(l.id, l);
            }
            Ok(())
        };
        if kinds.is_empty() {
            run(None)?;
        } else {
            for k in kinds {
                run(Some(k))?;
            }
        }
    }
    Ok(out.into_values().collect())
}

/// Entity N's versions since tx SINCE (inclusive), oldest first.
pub fn history(conn: &Connection, n: i64, since: Option<i64>) -> rusqlite::Result<Vec<Version>> {
    let since = since.unwrap_or(0);
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "select h.ver, h.tx_from, h.field_tx, t.at, t.actor, t.class, t.tool, t.session, t.imported \
         from entity_hist h join tx t on t.id = h.tx_from where h.n = ?1 and h.tx_from >= ?2 order by h.ver",
    )?;
    let rows = stmt.query_map(params![n, since], |r| {
        let field_tx: Option<String> = r.get(2)?;
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            field_tx,
            r.get::<_, f64>(3)?,
            r.get::<_, String>(4)?,
            r.get::<_, String>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, Option<String>>(7)?,
            r.get::<_, i64>(8)?,
        ))
    })?;
    for row in rows {
        let (ver, tx, field_tx, at, actor, class, tool, session, imported) = row?;
        let map: BTreeMap<String, i64> = field_tx
            .and_then(|f| serde_json::from_str(&f).ok())
            .unwrap_or_default();
        out.push(Version {
            ver,
            tx,
            at,
            actor,
            class: class_of(&class),
            tool,
            session,
            fields: fields_set_by(&map, tx),
            imported: imported != 0,
        });
    }
    let cur = conn
        .query_row(
            "select e.ver, e.updated_tx, e.field_tx, e.retired_tx, t.at, t.actor, t.class, t.tool, t.session, \
             t.imported from entity e join tx t on t.id = e.updated_tx where e.n = ?1 and e.updated_tx >= ?2",
            params![n, since],
            |r| {
                let field_tx: String = r.get(2)?;
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    field_tx,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, f64>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, String>(6)?,
                    r.get::<_, Option<String>>(7)?,
                    r.get::<_, Option<String>>(8)?,
                    r.get::<_, i64>(9)?,
                ))
            },
        )
        .optional()?;
    if let Some((ver, tx, field_tx, retired, at, actor, class, tool, session, imported)) = cur {
        let map: BTreeMap<String, i64> = serde_json::from_str(&field_tx).unwrap_or_default();
        let mut fields = fields_set_by(&map, tx);
        if retired == Some(tx) {
            fields.push("retired".into());
        }
        out.push(Version {
            ver,
            tx,
            at,
            actor,
            class: class_of(&class),
            tool,
            session,
            fields,
            imported: imported != 0,
        });
    }
    Ok(out)
}

fn fields_set_by(map: &BTreeMap<String, i64>, tx: i64) -> Vec<String> {
    map.iter()
        .filter(|&(_, &t)| t == tx)
        .map(|(f, _)| f.clone())
        .collect()
}

/// Every link row of entity N (either end) with the authors of its `tx_from` and `tx_to`, oldest first.
pub fn link_history(conn: &Connection, n: i64) -> rusqlite::Result<Vec<LinkVersion>> {
    let mut stmt = conn.prepare(&format!(
        "select {LINK_COLS} from link where src = ?1 union select {LINK_COLS} from link where dst = ?1 \
         order by tx_from, id"
    ))?;
    let links: Vec<Link> = stmt
        .query_map([n], link_from_row)?
        .collect::<rusqlite::Result<_>>()?;
    let who = |tx: i64| -> rusqlite::Result<(String, Class)> {
        Ok(conn
            .query_row("select actor, class from tx where id = ?1", [tx], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .optional()?
            .map_or(("unknown".to_string(), Class::System), |(a, c)| {
                (a, class_of(&c))
            }))
    };
    let mut out = Vec::new();
    for link in links {
        let (added_by, added_class) = who(link.tx_from)?;
        let (retired_by, retired_class) = if link.tx_to == SENTINEL {
            (None, None)
        } else {
            let (a, c) = who(link.tx_to)?;
            (Some(a), Some(c))
        };
        out.push(LinkVersion {
            link,
            added_by,
            added_class,
            retired_by,
            retired_class,
        });
    }
    Ok(out)
}

/// Revert TARGET as a new tx (`tx.reverts = target`), or answer `Blocked` writing nothing.
pub fn revert(tx: &mut Tx<'_>, target: i64) -> Result<Revert, WriteError> {
    let out = revert_one(tx, target, &BTreeSet::new())?;
    if matches!(out, Revert::Done { .. }) {
        tx.sql().execute(
            "update tx set reverts = ?1 where id = ?2",
            params![target, tx.id()],
        )?;
    }
    Ok(out)
}

/// IGNORE: txs of the same rejection, already reverted in this tx, which are not "later changes".
fn revert_one(tx: &mut Tx<'_>, target: i64, ignore: &BTreeSet<i64>) -> Result<Revert, WriteError> {
    let me = tx.id();
    let known: Option<i64> = tx
        .sql()
        .query_row("select id from tx where id = ?1", [target], |r| r.get(0))
        .optional()?;
    if known.is_none() || target >= me {
        return Err(WriteError::Refused(format!("no tx {target} to revert")));
    }
    // The entities the target wrote a version of.
    let ns: Vec<i64> = {
        let mut stmt = tx.sql().prepare(
            "select n from entity where updated_tx = ?1 union select n from entity_hist where tx_from = ?1",
        )?;
        stmt.query_map([target], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    struct Plan {
        cur: Ent,
        first: i64,
    }
    let mut plans = Vec::new();
    let mut later: BTreeSet<i64> = BTreeSet::new();
    for n in ns {
        let cur = entity::by_n(tx.sql(), n)?.expect("listed by its row");
        let first: i64 = tx.sql().query_row(
            "select coalesce(min(ver), ?2) from entity_hist where n = ?1 and tx_from = ?3",
            params![n, cur.ver, target],
            |r| r.get(0),
        )?;
        {
            let mut stmt = tx.sql().prepare(
                "select tx_from from entity_hist where n = ?1 and tx_from > ?2 and tx_from <> ?3",
            )?;
            for t in stmt.query_map(params![n, target, me], |r| r.get::<_, i64>(0))? {
                let t = t?;
                if !ignore.contains(&t) {
                    later.insert(t);
                }
            }
        }
        if cur.updated_tx > target && cur.updated_tx != me && !ignore.contains(&cur.updated_tx) {
            later.insert(cur.updated_tx);
        }
        plans.push(Plan { cur, first });
    }
    if !later.is_empty() {
        return Ok(Revert::Blocked {
            later: later.into_iter().collect(),
        });
    }
    let mut entities = Vec::new();
    for Plan { cur, first } in plans {
        let changed = if first <= 1 {
            // The target created the entity: reverting it retires it.
            if cur.retired_tx.is_some() {
                false
            } else {
                entity::set_version(tx, &cur, &Snap::of(&cur), Some(Some(me)))?
            }
        } else {
            let prev = hist_version(tx.sql(), cur.n, first - 1)?.ok_or_else(|| {
                WriteError::Refused(format!(
                    "entity {}: version {} is no longer kept",
                    cur.n,
                    first - 1
                ))
            })?;
            let retired = (cur.retired_tx == Some(target)).then_some(None);
            entity::set_version(tx, &cur, &prev.snap, retired)?
        };
        if changed {
            entities.push(cur.n);
        }
    }
    // Links the target added are retired; links it retired are added again as new rows.
    let added: Vec<(i64, String, i64)> = {
        let mut stmt = tx
            .sql()
            .prepare("select src, kind, dst from link where tx_from = ?1 and tx_to = ?2")?;
        stmt.query_map(params![target, SENTINEL], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<rusqlite::Result<_>>()?
    };
    let mut links = Vec::new();
    for (src, kind, dst) in added {
        let id: Option<i64> = tx
            .sql()
            .query_row(
                "select id from link where src = ?1 and kind = ?2 and dst = ?3 and tx_to = ?4",
                params![src, kind, dst, SENTINEL],
                |r| r.get(0),
            )
            .optional()?;
        if link::retire(tx, src, &kind, dst)?
            && let Some(id) = id
        {
            links.push(id);
        }
    }
    let gone: Vec<Link> = {
        let mut stmt = tx.sql().prepare(&format!(
            "select {LINK_COLS} from link where tx_to = ?1 and tx_from < ?1"
        ))?;
        stmt.query_map([target], link_from_row)?
            .collect::<rusqlite::Result<_>>()?
    };
    for l in gone {
        let added = link::add(
            tx,
            l.src,
            &l.kind,
            l.dst,
            l.data,
            l.origin,
            l.source.as_deref(),
        )?;
        if !added.existed {
            links.push(added.id);
        }
    }
    Ok(Revert::Done { entities, links })
}

/// Set entity N's fields to version VER's (a new version). Its retirement is left as it is.
pub fn restore(tx: &mut Tx<'_>, n: i64, ver: i64) -> Result<Update, WriteError> {
    let cur =
        entity::by_n(tx.sql(), n)?.ok_or_else(|| WriteError::Refused(format!("no entity {n}")))?;
    if ver == cur.ver {
        return Ok(Update::Done { ver });
    }
    let h = hist_version(tx.sql(), n, ver)?
        .ok_or_else(|| WriteError::Refused(format!("entity {n} has no version {ver}")))?;
    if entity::set_version(tx, &cur, &h.snap, None)? {
        Ok(Update::Done { ver: cur.ver + 1 })
    } else {
        Ok(Update::Done { ver: cur.ver })
    }
}

/// Accept (mark `accepted`) or reject (revert newest first, mark `reverted`) the proposed TXS. This tx is the user's
/// record of the decision. A tx that is not `proposed` is refused; a rejection that meets a later change writes
/// nothing and answers `Blocked`.
pub fn settle_proposed(tx: &mut Tx<'_>, txs: &[i64], accept: bool) -> Result<Revert, WriteError> {
    for &t in txs {
        let state: Option<String> = tx
            .sql()
            .query_row("select state from tx where id = ?1", [t], |r| r.get(0))
            .optional()?;
        if state.as_deref() != Some(TxState::Proposed.as_str()) {
            return Err(WriteError::Refused(format!("tx {t} is not proposed")));
        }
    }
    let mut result = Revert::Done {
        entities: Vec::new(),
        links: Vec::new(),
    };
    let mark = if accept {
        TxState::Accepted
    } else {
        TxState::Reverted
    };
    if !accept {
        let mut ordered = txs.to_vec();
        ordered.sort_unstable_by(|a, b| b.cmp(a));
        ordered.dedup();
        let batch: BTreeSet<i64> = txs.iter().copied().collect();
        tx.sql().execute_batch("savepoint hist_settle")?;
        let mut all_entities = Vec::new();
        let mut all_links = Vec::new();
        for t in ordered {
            match revert_one(tx, t, &batch) {
                Ok(Revert::Done { entities, links }) => {
                    all_entities.extend(entities);
                    all_links.extend(links);
                }
                Ok(blocked) => {
                    tx.sql()
                        .execute_batch("rollback to hist_settle; release hist_settle")?;
                    return Ok(blocked);
                }
                Err(e) => {
                    tx.sql()
                        .execute_batch("rollback to hist_settle; release hist_settle")?;
                    return Err(e);
                }
            }
        }
        tx.sql().execute_batch("release hist_settle")?;
        all_entities.sort_unstable();
        all_entities.dedup();
        result = Revert::Done {
            entities: all_entities,
            links: all_links,
        };
        if let [only] = txs {
            tx.sql().execute(
                "update tx set reverts = ?1 where id = ?2",
                params![only, tx.id()],
            )?;
        }
    }
    for &t in txs {
        tx.sql().execute(
            "update tx set state = ?1 where id = ?2",
            params![mark.as_str(), t],
        )?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::entity::{Changes, EntityNew};
    use crate::graph::guard::Guard;
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::TxMeta;
    use serde_json::json;
    use std::sync::Arc;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        conn
    }

    /// One committed tx of ACTOR in CLASS running F; the tx id and F's answer.
    fn run<R>(conn: &mut Connection, meta: TxMeta, f: impl FnOnce(&mut Tx<'_>) -> R) -> (i64, R) {
        let mut tx = Tx::for_test(conn, meta, Arc::new(Guard::default()));
        let r = f(&mut tx);
        let id = tx.id();
        tx.commit_for_test().unwrap();
        (id, r)
    }

    fn user() -> TxMeta {
        TxMeta::new("user", Class::User, "test")
    }

    fn agent() -> TxMeta {
        let mut m = TxMeta::new("agent:s1", Class::Agent, "mcp:task_write");
        m.session = Some("s1".into());
        m
    }

    fn proposed() -> TxMeta {
        let mut m = agent();
        m.state = TxState::Proposed;
        m
    }

    fn new_ent(id: &str, title: &str) -> EntityNew {
        EntityNew {
            id: id.into(),
            kind: "task".into(),
            project: None,
            title: Some(title.into()),
            status: Some("open".into()),
            body: None,
            priority: None,
            assignee: None,
            data: json!({}),
            origin: Origin::Recorded,
            source: None,
        }
    }

    fn create(conn: &mut Connection, meta: TxMeta, id: &str, title: &str) -> (i64, i64) {
        let (t, e) = run(conn, meta, |tx| {
            entity::create(tx, new_ent(id, title)).unwrap()
        });
        (t, e.n)
    }

    fn set_title(conn: &mut Connection, meta: TxMeta, n: i64, title: &str) -> i64 {
        run(conn, meta, |tx| {
            entity::update(
                tx,
                n,
                None,
                Changes {
                    title: Some(Some(title.into())),
                    ..Changes::default()
                },
            )
            .unwrap()
        })
        .0
    }

    fn title(conn: &Connection, n: i64) -> Option<String> {
        entity::by_n(conn, n).unwrap().unwrap().title
    }

    fn as_title(conn: &Connection, n: i64, tx: i64) -> Option<String> {
        entity_as_of(conn, n, tx).unwrap().and_then(|a| a.ent.title)
    }

    #[test]
    fn as_of_before_creation_is_none() {
        let mut conn = db();
        let (t0, ()) = run(&mut conn, user(), |_| ());
        let (t1, n) = create(&mut conn, user(), "task:a", "a");
        assert!(entity_as_of(&conn, n, t0).unwrap().is_none());
        assert!(entity_as_of(&conn, n, t1).unwrap().is_some());
        assert!(entity_as_of(&conn, 99, t1).unwrap().is_none());
    }

    #[test]
    fn as_of_between_versions() {
        let mut conn = db();
        let (t1, n) = create(&mut conn, user(), "task:a", "a");
        let t2 = set_title(&mut conn, agent(), n, "b");
        let (t3, ()) = run(&mut conn, user(), |_| ());
        let t4 = set_title(&mut conn, agent(), n, "c");
        assert_eq!(as_title(&conn, n, t1).as_deref(), Some("a"));
        assert_eq!(as_title(&conn, n, t2).as_deref(), Some("b"));
        assert_eq!(as_title(&conn, n, t3).as_deref(), Some("b"));
        assert_eq!(as_title(&conn, n, t4).as_deref(), Some("c"));
        let old = entity_as_of(&conn, n, t1).unwrap().unwrap();
        assert_eq!((old.ent.ver, old.ent.updated_tx), (1, t1));
        assert!(!old.approximate);
    }

    /// URDR-HIST-RETIRED-1: every version keeps its retirement, lease and origin, so an as-of read shows them as they
    /// were: an entity retired then brought back is retired as of the time between; a lease held then is held.
    #[test]
    fn as_of_shows_retirement_and_lease_as_they_were() {
        let mut conn = db();
        let (t1, n) = create(&mut conn, user(), "task:a", "a");
        let held = Lease {
            holder: Some("agent:s1".into()),
            epoch: 1,
            until: Some(2_000_000_000.0),
        };
        let lease = |l: Lease| Changes {
            lease: Some(l),
            ..Changes::default()
        };
        let h2 = held.clone();
        let (t2, _) = run(&mut conn, agent(), |tx| {
            entity::update(tx, n, None, lease(h2)).unwrap()
        });
        let (t3, _) = run(&mut conn, agent(), |tx| {
            entity::update(
                tx,
                n,
                None,
                lease(Lease {
                    holder: None,
                    epoch: 1,
                    until: None,
                }),
            )
            .unwrap()
        });
        let (t4, ()) = run(&mut conn, user(), |tx| entity::retire(tx, n).unwrap());
        let (t5, _) = run(&mut conn, user(), |tx| entity::unretire(tx, n).unwrap());
        let at = |t: i64| entity_as_of(&conn, n, t).unwrap().unwrap().ent;
        assert_eq!(at(t1).lease, Lease::default());
        assert_eq!(at(t2).lease, held, "the lease held as of then");
        assert_eq!(at(t3).lease.holder, None);
        assert_eq!(at(t3).lease.epoch, 1);
        assert_eq!(at(t3).retired_tx, None);
        assert_eq!(at(t4).retired_tx, Some(t4), "retired as of then");
        assert_eq!(at(t5).retired_tx, None, "and back now");
        assert_eq!(entity::by_n(&conn, n).unwrap().unwrap().retired_tx, None);
        for t in [t1, t2, t3, t4, t5] {
            assert_eq!(at(t).origin, Origin::Recorded);
        }
        // every version row carries the columns
        let cols: i64 = conn
            .query_row(
                "select count(*) from pragma_table_info('entity_hist') where name in \
                 ('retired_tx', 'lease_holder', 'lease_epoch', 'lease_until', 'origin')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cols, 5);
    }

    #[test]
    fn imported_is_approximate() {
        let mut conn = db();
        let mut m = TxMeta::new("hub", Class::System, "migrate");
        m.imported = true;
        let (t1, n) = create(&mut conn, m, "task:a", "a");
        let t2 = set_title(&mut conn, agent(), n, "b");
        assert!(entity_as_of(&conn, n, t1).unwrap().unwrap().approximate);
        assert!(!entity_as_of(&conn, n, t2).unwrap().unwrap().approximate);
        let (t3, ()) = run(&mut conn, user(), |_| ());
        assert!(!entity_as_of(&conn, n, t3).unwrap().unwrap().approximate);
    }

    #[test]
    fn history_names_actors_and_fields() {
        let mut conn = db();
        let (t1, n) = create(&mut conn, user(), "task:a", "a");
        let t2 = set_title(&mut conn, agent(), n, "b");
        let (t3, ()) = run(&mut conn, user(), |tx| entity::retire(tx, n).unwrap());
        let h = history(&conn, n, None).unwrap();
        assert_eq!(h.len(), 3);
        assert_eq!((h[0].ver, h[0].tx, h[0].actor.as_str()), (1, t1, "user"));
        assert_eq!(h[0].class, Class::User);
        assert_eq!(h[0].fields, vec!["status".to_string(), "title".to_string()]);
        assert_eq!(
            (h[1].tx, h[1].actor.as_str(), h[1].class),
            (t2, "agent:s1", Class::Agent)
        );
        assert_eq!(h[1].session.as_deref(), Some("s1"));
        assert_eq!(h[1].tool.as_deref(), Some("mcp:task_write"));
        assert_eq!(h[1].fields, vec!["title".to_string()]);
        assert_eq!(
            (h[2].tx, h[2].fields.clone()),
            (t3, vec!["retired".to_string()])
        );
        let since = history(&conn, n, Some(t2)).unwrap();
        assert_eq!(since.iter().map(|v| v.tx).collect::<Vec<_>>(), vec![t2, t3]);
    }

    #[test]
    fn revert_restores_the_previous_version() {
        let mut conn = db();
        let (_t1, n) = create(&mut conn, user(), "task:a", "a");
        let t2 = set_title(&mut conn, agent(), n, "b");
        let (t3, r) = run(&mut conn, user(), |tx| revert(tx, t2).unwrap());
        assert_eq!(
            r,
            Revert::Done {
                entities: vec![n],
                links: vec![]
            }
        );
        let e = entity::by_n(&conn, n).unwrap().unwrap();
        assert_eq!(
            (e.title.as_deref(), e.ver, e.updated_tx),
            (Some("a"), 3, t3)
        );
        let reverts: Option<i64> = conn
            .query_row("select reverts from tx where id = ?1", [t3], |r| r.get(0))
            .unwrap();
        assert_eq!(reverts, Some(t2));
        // The FTS row follows the restored title.
        let hits = crate::graph::search::find_fts(&conn, "a", 5).unwrap();
        assert!(hits.iter().any(|h| h.n == n));
        // Reverting the revert brings "b" back.
        let (_t4, r) = run(&mut conn, user(), |tx| revert(tx, t3).unwrap());
        assert!(matches!(r, Revert::Done { .. }));
        assert_eq!(title(&conn, n).as_deref(), Some("b"));
    }

    #[test]
    fn reverting_a_creation_retires_and_reverting_that_restores() {
        let mut conn = db();
        let (t1, n) = create(&mut conn, user(), "task:a", "a");
        let (t2, r) = run(&mut conn, user(), |tx| revert(tx, t1).unwrap());
        assert!(matches!(r, Revert::Done { .. }));
        assert_eq!(
            entity::by_n(&conn, n).unwrap().unwrap().retired_tx,
            Some(t2)
        );
        let (_t3, r) = run(&mut conn, user(), |tx| revert(tx, t2).unwrap());
        assert!(matches!(r, Revert::Done { .. }));
        assert_eq!(entity::by_n(&conn, n).unwrap().unwrap().retired_tx, None);
        assert_eq!(title(&conn, n).as_deref(), Some("a"));
    }

    #[test]
    fn revert_blocked_by_a_later_change_lists_it() {
        let mut conn = db();
        let (_t1, n) = create(&mut conn, user(), "task:a", "a");
        let t2 = set_title(&mut conn, agent(), n, "b");
        let t3 = set_title(&mut conn, agent(), n, "c");
        let t4 = set_title(&mut conn, agent(), n, "d");
        let ver = entity::by_n(&conn, n).unwrap().unwrap().ver;
        let (t5, r) = run(&mut conn, user(), |tx| revert(tx, t2).unwrap());
        assert_eq!(
            r,
            Revert::Blocked {
                later: vec![t3, t4]
            }
        );
        assert_eq!(entity::by_n(&conn, n).unwrap().unwrap().ver, ver);
        let reverts: Option<i64> = conn
            .query_row("select reverts from tx where id = ?1", [t5], |r| r.get(0))
            .unwrap();
        assert_eq!(reverts, None);
    }

    fn link_set(conn: &Connection, n: i64, tx: i64) -> Vec<(i64, String, i64)> {
        let mut v: Vec<_> = links_as_of(conn, n, &[], Direction::Both, tx)
            .unwrap()
            .into_iter()
            .map(|l| (l.src, l.kind, l.dst))
            .collect();
        v.sort();
        v
    }

    #[test]
    fn revert_retires_added_links_and_readds_retired() {
        let mut conn = db();
        let (_, a) = create(&mut conn, user(), "task:a", "a");
        let (_, b) = create(&mut conn, user(), "task:b", "b");
        let (_, c) = create(&mut conn, user(), "task:c", "c");
        let (t_ab, _) = run(&mut conn, user(), |tx| {
            link::add(
                tx,
                a,
                "blocks",
                b,
                Some(json!({"at": "x"})),
                Origin::Recorded,
                Some("s"),
            )
            .unwrap()
        });
        let (t3, ()) = run(&mut conn, agent(), |tx| {
            assert!(link::retire(tx, a, "blocks", b).unwrap());
            link::add(tx, a, "blocks", c, None, Origin::Recorded, None).unwrap();
        });
        assert_eq!(link_set(&conn, a, t3), vec![(a, "blocks".to_string(), c)]);
        let (t4, r) = run(&mut conn, user(), |tx| revert(tx, t3).unwrap());
        let Revert::Done { entities, links } = r else {
            panic!("blocked")
        };
        assert!(entities.is_empty());
        assert_eq!(links.len(), 2);
        // Before: a -> b only; now the same again, as a new row that kept data, origin and source.
        assert_eq!(link_set(&conn, a, t4), vec![(a, "blocks".to_string(), b)]);
        assert_eq!(link_set(&conn, a, t_ab), link_set(&conn, a, t4));
        let back = links_as_of(&conn, a, &["blocks".into()], Direction::Out, t4).unwrap();
        assert_eq!(back[0].data, Some(json!({"at": "x"})));
        assert_eq!(back[0].source.as_deref(), Some("s"));
        assert_eq!(back[0].tx_from, t4);
        // Both ends see the link in the In direction.
        assert_eq!(
            links_as_of(&conn, b, &[], Direction::In, t4).unwrap().len(),
            1
        );
        assert!(
            links_as_of(&conn, b, &[], Direction::Out, t4)
                .unwrap()
                .is_empty()
        );
        // The link history names who added and who retired each row.
        let lh = link_history(&conn, a).unwrap();
        assert_eq!(lh.len(), 3);
        assert_eq!(lh[0].added_by, "user");
        assert_eq!(lh[0].retired_by.as_deref(), Some("agent:s1"));
        assert_eq!(lh[0].retired_class, Some(Class::Agent));
    }

    fn state(conn: &Connection, t: i64) -> String {
        conn.query_row("select state from tx where id = ?1", [t], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn accept_and_reject_proposed() {
        let mut conn = db();
        let (_t1, a) = create(&mut conn, user(), "task:a", "a");
        let t2 = set_title(&mut conn, proposed(), a, "b");
        let t3 = set_title(&mut conn, proposed(), a, "c");
        let (t4, e2) = create(&mut conn, proposed(), "task:e2", "new");
        assert_eq!(state(&conn, t2), "proposed");
        // Accept one: marked, nothing else changes.
        let (_t5, r) = run(&mut conn, user(), |tx| {
            settle_proposed(tx, &[t4], true).unwrap()
        });
        assert!(matches!(r, Revert::Done { .. }));
        assert_eq!(state(&conn, t4), "accepted");
        assert_eq!(title(&conn, a).as_deref(), Some("c"));
        // Reject the other two: newest first, back to "a", marked reverted.
        let (t6, r) = run(&mut conn, user(), |tx| {
            settle_proposed(tx, &[t2, t3], false).unwrap()
        });
        assert!(matches!(r, Revert::Done { .. }));
        assert_eq!(title(&conn, a).as_deref(), Some("a"));
        assert_eq!(
            (state(&conn, t2).as_str(), state(&conn, t3).as_str()),
            ("reverted", "reverted")
        );
        assert_eq!(state(&conn, t6), "committed");
        assert_eq!(entity::by_n(&conn, e2).unwrap().unwrap().retired_tx, None);
        // A tx that is not proposed is refused.
        let mut tx = Tx::for_test(&mut conn, user(), Arc::new(Guard::default()));
        assert!(matches!(
            settle_proposed(&mut tx, &[t2], true),
            Err(WriteError::Refused(_))
        ));
    }

    #[test]
    fn rejecting_a_created_proposal_retires_it_and_a_blocked_rejection_writes_nothing() {
        let mut conn = db();
        let (_, a) = create(&mut conn, user(), "task:a", "a");
        let (_, b) = create(&mut conn, user(), "task:b", "b");
        let t3 = set_title(&mut conn, proposed(), b, "b2");
        let t4 = set_title(&mut conn, proposed(), a, "a2");
        let _t5 = set_title(&mut conn, agent(), b, "b3"); // a later committed change to b
        let (_, r) = run(&mut conn, user(), |tx| {
            settle_proposed(tx, &[t3, t4], false).unwrap()
        });
        assert_eq!(r, Revert::Blocked { later: vec![_t5] });
        // t4 (newest) was reverted first inside the call, then rolled back with the block.
        assert_eq!(title(&conn, a).as_deref(), Some("a2"));
        assert_eq!(state(&conn, t3), "proposed");
        assert_eq!(state(&conn, t4), "proposed");
        let (t6, e) = create(&mut conn, proposed(), "task:p", "p");
        let (_, r) = run(&mut conn, user(), |tx| {
            settle_proposed(tx, &[t6], false).unwrap()
        });
        assert_eq!(
            r,
            Revert::Done {
                entities: vec![e],
                links: vec![]
            }
        );
        assert!(
            entity::by_n(&conn, e)
                .unwrap()
                .unwrap()
                .retired_tx
                .is_some()
        );
    }

    #[test]
    fn restore_sets_an_old_versions_fields() {
        let mut conn = db();
        let (_, n) = create(&mut conn, user(), "task:a", "a");
        set_title(&mut conn, agent(), n, "b");
        set_title(&mut conn, agent(), n, "c");
        let (_, r) = run(&mut conn, user(), |tx| restore(tx, n, 1).unwrap());
        assert_eq!(r, Update::Done { ver: 4 });
        assert_eq!(title(&conn, n).as_deref(), Some("a"));
        let (_, r) = run(&mut conn, user(), |tx| restore(tx, n, 4).unwrap());
        assert_eq!(r, Update::Done { ver: 4 });
        let (_, r) = run(&mut conn, user(), |tx| restore(tx, n, 40));
        assert!(matches!(r, Err(WriteError::Refused(_))));
    }

    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    type Row = (Option<String>, Option<String>, Option<i64>);

    /// The model: entity fields and the current link set, as the log has made them.
    #[derive(Clone, Default)]
    struct Model {
        ents: BTreeMap<i64, Row>,
        links: BTreeSet<(i64, String, i64)>,
    }

    /// Apply a random op in its own tx; the tx id.
    fn random_op(conn: &mut Connection, rng: &mut Rng, ns: &[i64], model: &mut Model) -> i64 {
        let n = ns[rng.below(ns.len() as u64) as usize];
        let m = ns[rng.below(ns.len() as u64) as usize];
        let kind = ["blocks", "refs"][rng.below(2) as usize].to_string();
        let which = rng.below(4);
        let v = rng.below(5);
        run(conn, agent(), |tx| match which {
            0 => {
                let t = format!("t{v}");
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        title: Some(Some(t.clone())),
                        ..Changes::default()
                    },
                )
                .unwrap();
                model.ents.get_mut(&n).unwrap().0 = Some(t);
            }
            1 => {
                let s = format!("s{v}");
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        status: Some(Some(s.clone())),
                        priority: Some(Some(v as i64)),
                        ..Changes::default()
                    },
                )
                .unwrap();
                let row = model.ents.get_mut(&n).unwrap();
                row.1 = Some(s);
                row.2 = Some(v as i64);
            }
            2 => {
                if n != m {
                    link::add(tx, n, &kind, m, None, Origin::Recorded, None).unwrap();
                    model.links.insert((n, kind, m));
                }
            }
            _ => {
                if link::retire(tx, n, &kind, m).unwrap() {
                    model.links.remove(&(n, kind, m));
                }
            }
        })
        .0
    }

    fn seeded(seed: u64) -> (Connection, Vec<i64>, Model, Rng) {
        let mut conn = db();
        let mut model = Model::default();
        let mut ns = Vec::new();
        for i in 0..3 {
            let (_, n) = create(&mut conn, user(), &format!("task:{i}"), "t0");
            ns.push(n);
            model
                .ents
                .insert(n, (Some("t0".into()), Some("open".into()), None));
        }
        (conn, ns, model, Rng(seed))
    }

    fn row_of(conn: &Connection, n: i64, tx: i64) -> Option<Row> {
        entity_as_of(conn, n, tx)
            .unwrap()
            .map(|a| (a.ent.title, a.ent.status, a.ent.priority))
    }

    #[test]
    fn replayed_log_equals_as_of() {
        for seed in 1..=12u64 {
            let (mut conn, ns, mut model, mut rng) = seeded(seed * 7919);
            let mut states: Vec<(i64, Model)> = Vec::new();
            let last: i64 = conn
                .query_row("select max(id) from tx", [], |r| r.get(0))
                .unwrap();
            states.push((last, model.clone()));
            for _ in 0..60 {
                let t = random_op(&mut conn, &mut rng, &ns, &mut model);
                states.push((t, model.clone()));
            }
            for (t, m) in &states {
                for &n in &ns {
                    assert_eq!(
                        row_of(&conn, n, *t).as_ref(),
                        m.ents.get(&n),
                        "seed {seed} tx {t} entity {n}"
                    );
                    let mut want: Vec<_> = m
                        .links
                        .iter()
                        .filter(|(s, _, d)| *s == n || *d == n)
                        .cloned()
                        .collect();
                    want.sort();
                    assert_eq!(
                        link_set(&conn, n, *t),
                        want,
                        "seed {seed} tx {t} links of {n}"
                    );
                }
            }
            // A time bound maps to the last tx at or before it.
            let at: f64 = conn
                .query_row("select at from tx where id = ?1", [states[10].0], |r| {
                    r.get(0)
                })
                .unwrap();
            assert!(tx_at(&conn, at).unwrap() >= states[10].0);
            assert_eq!(tx_at(&conn, -1.0).unwrap(), 0);
        }
    }

    #[test]
    fn revert_then_as_of_equals_before() {
        let mut done = 0;
        for seed in 1..=12u64 {
            let (mut conn, ns, mut model, mut rng) = seeded(seed * 104729);
            let mut txs = Vec::new();
            for _ in 0..40 {
                txs.push(random_op(&mut conn, &mut rng, &ns, &mut model));
            }
            for &target in &txs {
                let (me, r) = run(&mut conn, user(), |tx| revert(tx, target).unwrap());
                let Revert::Done { entities, .. } = r else {
                    continue;
                };
                for n in entities {
                    let now = row_of(&conn, n, me);
                    let before = row_of(&conn, n, target - 1);
                    assert_eq!(now, before, "seed {seed} reverting {target} entity {n}");
                    done += 1;
                }
            }
        }
        assert!(done > 20, "only {done} reverts changed an entity");
    }

    fn plan(conn: &Connection, sql: &str) -> String {
        let mut stmt = conn.prepare(&format!("explain query plan {sql}")).unwrap();
        stmt.query_map([], |r| r.get::<_, String>(3))
            .unwrap()
            .map(|r| r.unwrap())
            .collect::<Vec<_>>()
            .join(" | ")
    }

    #[test]
    fn as_of_time_is_bounded_under_churn() {
        let mut conn = db();
        let (_, n) = create(&mut conn, user(), "task:a", "a");
        let (_, b) = create(&mut conn, user(), "task:b", "b");
        let mut mid = 0;
        for i in 0..10_000 {
            let (t, ()) = run(&mut conn, agent(), |tx| {
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        data_patch: Some(json!({"i": i})),
                        ..Changes::default()
                    },
                )
                .unwrap();
            });
            if i == 5_000 {
                mid = t;
            }
        }
        let mut mid_link = 0;
        for i in 0..10_000 {
            run(&mut conn, agent(), |tx| {
                link::add(tx, n, "refs", b, None, Origin::Recorded, None).unwrap();
            });
            let (t, ()) = run(&mut conn, agent(), |tx| {
                link::retire(tx, n, "refs", b).unwrap();
            });
            if i == 5_000 {
                mid_link = t - 1;
            }
        }
        // The entity read: one index seek.
        assert!(
            plan(
                &conn,
                "select ver from entity_hist indexed by entity_hist_tx where n = 1 and tx_to > 5 and tx_from <= 5 \
                 order by tx_to limit 1"
            )
            .contains("entity_hist_tx")
        );
        let ops = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = ops.clone();
        conn.progress_handler(
            100,
            Some(move || {
                seen.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                false
            }),
        )
        .unwrap();
        let a = entity_as_of(&conn, n, mid).unwrap().unwrap();
        assert_eq!(a.ent.data, json!({"i": 5_000}));
        let calls = ops.swap(0, std::sync::atomic::Ordering::Relaxed);
        assert!(calls < 20, "an as-of hop ran {calls} x 100 VM steps");
        // The link read: the index range, never a table scan.
        let l = links_as_of(&conn, n, &["refs".into()], Direction::Out, mid_link).unwrap();
        assert_eq!(l.len(), 1);
        assert!(l[0].tx_from <= mid_link && l[0].tx_to > mid_link);
        let p = plan(
            &conn,
            "select id from link indexed by link_out where src = 1 and tx_to > 5 and tx_from <= 5 and kind = 'refs'",
        );
        assert!(p.contains("link_out") && !p.contains("SCAN link"), "{p}");
        conn.progress_handler(100, None::<fn() -> bool>).unwrap();
    }
}
