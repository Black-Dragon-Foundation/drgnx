//! The class guard (Task 2 implements the check; norn registers its rules, Task 10): an entity kind, or a `kv` key
//! prefix, that only one class may write. [`super::entity::create`] and [`super::entity::update`] check it on every
//! path (proposed txs and imports included); norn's `kv` writer checks keys (Task 12). Generic: it knows no kind.

use std::collections::BTreeMap;

use super::tx::{Class, TxMeta};
use super::writer::WriteError;

/// The registered rules: kind → (class, refusal text), and key prefix → (class, refusal text).
#[derive(Clone, Debug, Default)]
pub struct Guard {
    kinds: BTreeMap<String, (Class, &'static str)>,
    keys: Vec<(String, Class, &'static str)>,
}

/// Writes of entities of KIND need CLASS; any other class is `Refused(REFUSAL)` (e.g. "grants are the user's").
pub fn register(guard: &mut Guard, kind: &str, class: Class, refusal: &'static str) {
    guard.kinds.insert(kind.to_string(), (class, refusal));
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
