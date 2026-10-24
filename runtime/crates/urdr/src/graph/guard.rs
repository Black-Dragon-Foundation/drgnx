//! The class guard (Task 2 implements the check; norn registers its rules, Task 10): an entity kind, or a `kv` key
//! prefix, that only one class may write. [`super::entity::create`] and [`super::entity::update`] check it on every
//! path (proposed txs and imports included); norn's `kv` writer checks keys (Task 12). Generic: it knows no kind.
//!
//! A kind may also have a rule that decides from the write itself ([`register_rule`]; norn's kind `option`, Urdr
//! Task 10b): who writes, the entity's id and project, and the rows the rule reads through the tx (grants).

use std::collections::BTreeMap;

use rusqlite::Connection;

use super::entity::Origin;
use super::tx::{Class, Tx, TxMeta};
use super::writer::WriteError;

/// The entity a write is about: its id, its project after the write, and the origin a create gives it (`None` for a
/// write to a stored entity, which keeps its origin).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target<'a> {
    pub id: &'a str,
    pub project: Option<i64>,
    pub origin: Option<Origin>,
}

/// A kind's rule: given the tx's connection, its metadata, its time and the entity written, `Ok` or a refusal.
pub type Rule = fn(&Connection, &TxMeta, f64, Target<'_>) -> Result<(), WriteError>;

/// The registered rules: kind → (class, refusal text), kind → rule, and key prefix → (class, refusal text).
#[derive(Clone, Debug, Default)]
pub struct Guard {
    kinds: BTreeMap<String, (Class, &'static str)>,
    rules: BTreeMap<String, Rule>,
    keys: Vec<(String, Class, &'static str)>,
}

/// Writes of entities of KIND need CLASS; any other class is `Refused(REFUSAL)` (e.g. "grants are the user's").
pub fn register(guard: &mut Guard, kind: &str, class: Class, refusal: &'static str) {
    guard.kinds.insert(kind.to_string(), (class, refusal));
}

/// Writes of entities of KIND pass only when RULE answers `Ok` (checked after a class registered for KIND).
pub fn register_rule(guard: &mut Guard, kind: &str, rule: Rule) {
    guard.rules.insert(kind.to_string(), rule);
}

/// Whether TX may write the entity TARGET of KIND: KIND's class, then KIND's rule. Every entity write calls it.
pub fn check_entity(tx: &Tx<'_>, kind: &str, target: Target<'_>) -> Result<(), WriteError> {
    check(tx.guard(), tx.meta(), kind)?;
    match tx.guard().rules.get(kind) {
        Some(rule) => rule(tx.sql(), tx.meta(), tx.at(), target),
        None => Ok(()),
    }
}

/// Writes of `kv` keys starting with PREFIX need CLASS; any other class is `Refused(REFUSAL)`.
pub fn register_key_prefix(guard: &mut Guard, prefix: &str, class: Class, refusal: &'static str) {
    guard.keys.push((prefix.to_string(), class, refusal));
}

/// Whether META's class may write an entity of KIND. An unregistered kind passes.
pub fn check(guard: &Guard, meta: &TxMeta, kind: &str) -> Result<(), WriteError> {
    match guard.kinds.get(kind) {
        Some((class, refusal)) if *class != meta.class => {
            Err(WriteError::Refused((*refusal).to_string()))
        }
        _ => Ok(()),
    }
}

/// Whether META's class may write the `kv` key KEY. A key no prefix matches passes.
pub fn check_key(guard: &Guard, meta: &TxMeta, key: &str) -> Result<(), WriteError> {
    for (prefix, class, refusal) in &guard.keys {
        if key.starts_with(prefix.as_str()) && *class != meta.class {
            return Err(WriteError::Refused((*refusal).to_string()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::entity::{self, Changes, EntityNew, Origin};
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::Tx;
    use rusqlite::Connection;
    use std::sync::Arc;

    fn guarded() -> Arc<Guard> {
        let mut g = Guard::default();
        register(&mut g, "grant", Class::User, "grants are the user's");
        register_key_prefix(
            &mut g,
            "privacy.",
            Class::User,
            "privacy settings are the user's",
        );
        Arc::new(g)
    }

    fn new_grant() -> EntityNew {
        EntityNew {
            id: "grant:abc".into(),
            kind: "grant".into(),
            project: None,
            title: Some("g".into()),
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: serde_json::json!({}),
            origin: Origin::Recorded,
            source: None,
        }
    }

    #[test]
    fn a_registered_kind_needs_its_class() {
        let g = guarded();
        let agent = TxMeta::new("agent:s1", Class::Agent, "mcp:test");
        let user = TxMeta::new("user", Class::User, "cli:test");
        assert_eq!(
            check(&g, &agent, "grant"),
            Err(WriteError::Refused("grants are the user's".into()))
        );
        assert_eq!(check(&g, &user, "grant"), Ok(()));
        assert!(check_key(&g, &agent, "privacy.allow").is_err());
        assert_eq!(check_key(&g, &user, "privacy.allow"), Ok(()));
        assert_eq!(check_key(&g, &agent, "other"), Ok(()));

        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let mut tx = Tx::for_test(&mut conn, agent, g);
        let err = entity::create(&mut tx, new_grant()).unwrap_err();
        assert_eq!(err, WriteError::Refused("grants are the user's".into()));
    }

    #[test]
    fn an_unregistered_kind_passes() {
        let g = guarded();
        let agent = TxMeta::new("agent:s1", Class::Agent, "mcp:test");
        assert_eq!(check(&g, &agent, "task"), Ok(()));
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let mut tx = Tx::for_test(&mut conn, agent, g);
        let mut new = new_grant();
        new.kind = "task".into();
        assert!(entity::create(&mut tx, new).is_ok());
    }

    /// A rule sees the id and the project after the write (an update's new project), and runs for every class.
    #[test]
    fn a_rule_decides_from_the_target() {
        fn only_ok(_: &Connection, meta: &TxMeta, _: f64, t: Target<'_>) -> Result<(), WriteError> {
            if meta.class == Class::User && t.id.starts_with("grant:ok") && t.project.is_none() {
                Ok(())
            } else {
                Err(WriteError::Refused("no".into()))
            }
        }
        let mut g = Guard::default();
        register_rule(&mut g, "grant", only_ok);
        let g = Arc::new(g);
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let user = TxMeta::new("user", Class::User, "cli:test");
        let mut tx = Tx::for_test(&mut conn, user, g.clone());
        let refused = entity::create(&mut tx, new_grant()).unwrap_err();
        assert_eq!(refused, WriteError::Refused("no".into()));
        let mut ok = new_grant();
        ok.id = "grant:ok".into();
        let n = entity::create(&mut tx, ok).unwrap().n;
        let moved = Changes {
            project: Some(Some(7)),
            ..Changes::default()
        };
        assert!(entity::update(&mut tx, n, None, moved).is_err());
        let titled = Changes {
            title: Some(Some("t".into())),
            ..Changes::default()
        };
        assert!(entity::update(&mut tx, n, None, titled).is_ok());
        assert!(entity::retire(&mut tx, n).is_ok());
        drop(tx);
        let agent = TxMeta::new("agent:s1", Class::Agent, "mcp:test");
        let mut tx = Tx::for_test(&mut conn, agent, g);
        let mut ok = new_grant();
        ok.id = "grant:ok".into();
        assert!(entity::create(&mut tx, ok).is_err());
    }

    /// A rule sees the origin a create gives the entity, and none for a write to a stored one (it keeps its own).
    #[test]
    fn a_rule_sees_a_creates_origin_only() {
        fn says(_: &Connection, _: &TxMeta, _: f64, t: Target<'_>) -> Result<(), WriteError> {
            Err(WriteError::Refused(format!("{:?}", t.origin)))
        }
        let mut g = Guard::default();
        register_rule(&mut g, "grant", says);
        let g = Arc::new(g);
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let user = TxMeta::new("user", Class::User, "cli:test");
        let n = {
            let mut tx = Tx::for_test(&mut conn, user.clone(), Arc::new(Guard::default()));
            let n = entity::create(&mut tx, new_grant()).unwrap().n;
            tx.commit_for_test().unwrap();
            n
        };
        let mut tx = Tx::for_test(&mut conn, user, g);
        let mut parsed = new_grant();
        parsed.id = "grant:p".into();
        parsed.origin = Origin::Parsed;
        assert_eq!(
            entity::create(&mut tx, parsed).unwrap_err(),
            WriteError::Refused("Some(Parsed)".into())
        );
        let titled = Changes {
            title: Some(Some("t".into())),
            ..Changes::default()
        };
        assert_eq!(
            entity::update(&mut tx, n, None, titled).unwrap_err(),
            WriteError::Refused("None".into())
        );
        assert_eq!(
            entity::retire(&mut tx, n).unwrap_err(),
            WriteError::Refused("None".into())
        );
    }

    /// Every entity write runs the kind's rule before it writes: create, update, retire, unretire, history's restore
    /// and revert (both through `set_version`). Import's two paths are pinned in `export`'s tests.
    #[test]
    fn every_entity_write_runs_the_rule() {
        fn never(_: &Connection, _: &TxMeta, _: f64, _: Target<'_>) -> Result<(), WriteError> {
            Err(WriteError::Refused("never".into()))
        }
        let mut g = Guard::default();
        register_rule(&mut g, "grant", never);
        let g = Arc::new(g);
        let open = Arc::new(Guard::default());
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let user = TxMeta::new("user", Class::User, "cli:test");
        let (n, retired) = {
            let mut tx = Tx::for_test(&mut conn, user.clone(), open.clone());
            let n = entity::create(&mut tx, new_grant()).unwrap().n;
            let mut r = new_grant();
            r.id = "grant:r".into();
            let r = entity::create(&mut tx, r).unwrap().n;
            entity::retire(&mut tx, r).unwrap();
            tx.commit_for_test().unwrap();
            (n, r)
        };
        let retitled = {
            let mut tx = Tx::for_test(&mut conn, user.clone(), open);
            let titled = Changes {
                title: Some(Some("t2".into())),
                ..Changes::default()
            };
            entity::update(&mut tx, n, None, titled).unwrap();
            let id = tx.id();
            tx.commit_for_test().unwrap();
            id
        };
        let mut tx = Tx::for_test(&mut conn, user, g);
        let never = || WriteError::Refused("never".into());
        let mut other = new_grant();
        other.id = "grant:new".into();
        assert_eq!(entity::create(&mut tx, other).unwrap_err(), never());
        let titled = Changes {
            title: Some(Some("t3".into())),
            ..Changes::default()
        };
        assert_eq!(
            entity::update(&mut tx, n, None, titled).unwrap_err(),
            never()
        );
        assert_eq!(entity::retire(&mut tx, n).unwrap_err(), never());
        assert_eq!(entity::unretire(&mut tx, retired).unwrap_err(), never());
        assert_eq!(
            crate::graph::hist::restore(&mut tx, n, 1).unwrap_err(),
            never()
        );
        assert_eq!(
            crate::graph::hist::revert(&mut tx, retitled).unwrap_err(),
            never()
        );
        let e = entity::by_n(tx.sql(), n).unwrap().unwrap();
        assert_eq!((e.ver, e.title.as_deref()), (2, Some("t2")));
    }

    #[test]
    fn the_guard_runs_on_update_too() {
        let g = guarded();
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        let user = TxMeta::new("user", Class::User, "cli:test");
        let n = {
            let mut tx = Tx::for_test(&mut conn, user, g.clone());
            let e = entity::create(&mut tx, new_grant()).unwrap();
            tx.commit_for_test().unwrap();
            e.n
        };
        let agent = TxMeta::new("agent:s1", Class::Agent, "mcp:test");
        let mut tx = Tx::for_test(&mut conn, agent, g);
        let changes = Changes {
            title: Some(Some("x".into())),
            ..Changes::default()
        };
        assert_eq!(
            entity::update(&mut tx, n, None, changes).unwrap_err(),
            WriteError::Refused("grants are the user's".into())
        );
    }
}
