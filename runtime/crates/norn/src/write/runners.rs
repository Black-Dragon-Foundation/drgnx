//! The runners' hub-only records (runners plan, Task 19): a `runner` (a machine that runs the hub's jobs), the cloud's
//! `cloud_spend`, and the key handover's `key_sent` and `key_use`.  The hub writes them as `("hub", Class::System)`;
//! an agent, a user connection or the scan never does, so each writer refuses any other author and nothing is
//! written.  A record's id is `<kind>:<name>`.

use crate::store::{CoordError, WTx};
use serde_json::Value;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::guard::{self, Guard};
use urdr::graph::tx::Class;

/// The refusal text for a write of one of these records by anyone else.
pub const HUB_ONLY: &str = "runners, their spend and their key records are the hub's";

/// The kinds only the hub writes.
pub const KINDS: &[&str] = &["runner", "cloud_spend", "key_sent", "key_use"];

/// Put the class rule of the kinds in [`KINDS`] into GUARD: only a system-class author writes them.
pub fn register(guard: &mut Guard) {
    for kind in KINDS {
        guard::register(guard, kind, Class::System, HUB_ONLY);
    }
}

fn hub_only(tx: &WTx<'_>, kind: &str) -> Result<(), CoordError> {
    let m = tx.meta();
    if !KINDS.contains(&kind) {
        return Err(CoordError::Refused(format!("{kind} is no runner record")));
    }
    if m.class == Class::System && m.actor == "hub" {
        Ok(())
    } else {
        Err(CoordError::Refused(HUB_ONLY.into()))
    }
}

/// Make the record KIND:NAME with DATA, or replace its data (one that was removed is made again); answers its id.
pub fn put(tx: &mut WTx<'_>, kind: &str, name: &str, data: Value) -> Result<String, CoordError> {
    hub_only(tx, kind)?;
    put_record(tx, kind, name, data)
}

/// Make the record KIND:NAME with DATA, or replace its data; the caller checked who writes it.
pub(crate) fn put_record(
    tx: &mut WTx<'_>,
    kind: &str,
    name: &str,
    data: Value,
) -> Result<String, CoordError> {
    let id = format!("{kind}:{name}");
    match entity::by_id(tx.sql(), &id)? {
        Some(e) => {
            if e.retired_tx.is_some() {
                entity::unretire(tx, e.n)?;
            }
            // a merge patch keeps keys the new data lacks, so the old data is cleared key by key first
            let mut patch = serde_json::Map::new();
            if let Some(old) = e.data.as_object() {
                for k in old.keys() {
                    patch.insert(k.clone(), Value::Null);
                }
            }
            if let Some(new) = data.as_object() {
                for (k, v) in new {
                    patch.insert(k.clone(), v.clone());
                }
            }
            entity::update(
                tx,
                e.n,
                None,
                Changes {
                    data_patch: Some(Value::Object(patch)),
                    ..Changes::default()
                },
            )?;
        }
        None => {
            entity::create(
                tx,
                EntityNew {
                    id: id.clone(),
                    kind: kind.into(),
                    project: None,
                    title: Some(name.into()),
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
    }
    Ok(id)
}

/// Retire the record KIND:NAME; one that is not there is left as it is.
pub fn remove(tx: &mut WTx<'_>, kind: &str, name: &str) -> Result<(), CoordError> {
    hub_only(tx, kind)?;
    if let Some(e) = entity::by_id(tx.sql(), &format!("{kind}:{name}"))?
        && e.retired_tx.is_none()
    {
        entity::retire(tx, e.n)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use serde_json::json;
    use urdr::graph::entity::{self, EntityNew, Origin};
    use urdr::graph::tx::{Class, TxMeta};

    fn guarded_tx<'a>(c: &'a mut urdr::Connection, class: Class, actor: &str) -> WTx<'a> {
        let mut g = Guard::default();
        crate::grants::register(&mut g);
        WTx::for_test(c, TxMeta::new(actor, class, "test"), std::sync::Arc::new(g))
    }

    /// Pattern D: every writer, from every author but the hub, writes nothing and says why.
    #[test]
    fn an_agent_write_of_runner_is_refused() {
        let mut c = db7();
        for kind in KINDS {
            for (class, actor) in [
                (Class::Agent, "agent:s1"),
                (Class::User, "user"),
                (Class::Ext, "ext:s2"),
                (Class::System, "scan:/w"),
            ] {
                let mut tx = guarded_tx(&mut c, class, actor);
                let refused = CoordError::Refused(HUB_ONLY.into());
                assert_eq!(
                    put(&mut tx, kind, "desktop", json!({"host": "h"})),
                    Err(refused.clone()),
                    "{kind} by {actor}"
                );
                assert_eq!(
                    remove(&mut tx, kind, "desktop"),
                    Err(refused),
                    "{kind} by {actor}"
                );
                // the graph's own door is shut to the kind as well (a scan is a system author: only the writer's own
                // author check stops it, above)
                let direct = entity::create(
                    &mut tx,
                    EntityNew {
                        id: format!("{kind}:direct"),
                        kind: (*kind).into(),
                        project: None,
                        title: None,
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({}),
                        origin: Origin::Recorded,
                        source: None,
                    },
                );
                assert_eq!(direct.is_ok(), class == Class::System, "{kind} by {actor}");
                drop(tx);
            }
        }
        let n: i64 = c
            .query_row(
                "select count(*) from entity where id like '%:desktop'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn the_hub_writes_replaces_and_retires_a_record() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = put(
            &mut tx,
            "runner",
            "desktop",
            json!({"host": "a", "trust": "mine"}),
        )
        .unwrap();
        assert_eq!(id, "runner:desktop");
        assert_eq!(
            put(&mut tx, "runner", "desktop", json!({"host": "b"})).unwrap(),
            id
        );
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(
            (e.data["host"].as_str(), e.data["trust"].as_str()),
            // a put replaces the data: a key the new data lacks is gone
            (Some("b"), None)
        );
        remove(&mut tx, "runner", "desktop").unwrap();
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert!(e.retired_tx.is_some());
        // a name that was removed can be added again
        put(&mut tx, "runner", "desktop", json!({"host": "c"})).unwrap();
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert_eq!((e.retired_tx, e.data["host"].as_str()), (None, Some("c")));
        assert!(put(&mut tx, "task", "x", json!({})).is_err());
    }
}
