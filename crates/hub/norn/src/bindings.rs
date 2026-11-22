//! Bindings (outside agents in the matrix, MP-1): the user's record that outside agents of KIND whose connection
//! root is ROOT act as ROLE (`docs/develop/coordination.md`, "Agents outside drgnx").  A binding is an entity of kind
//! `binding` (id `binding:<kind>-<12 hex of the root>`, no project), `status` `active`, `data {kind, root, role}`;
//! an unbind retires it.  Only the user writes one ([`register`]: urdr's guard refuses every other class), and
//! [`role_for`] counts a binding only when every tx that wrote it is the user's, so a row a guard-less path wrote
//! opens nothing.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::guard::{self, Guard};
use urdr::graph::{Class, Tx, WriteError};

use crate::matrix::Role;

/// The refusal of a binding write by any class but the user's.
pub const BINDINGS_ARE_THE_USERS: &str = "bindings are the user's";

/// One live binding.
#[derive(Clone, Debug, PartialEq)]
pub struct Binding {
    pub id: String,
    pub kind: String,
    pub root: PathBuf,
    pub role: Role,
    /// When it was last written (the tx's time).
    pub at: f64,
}

/// The id of the binding of KIND in ROOT: `binding:<kind>-<12 hex of sha1 over the root>`.
pub fn binding_id(kind: &str, root: &Path) -> String {
    let hex: String = Sha1::digest(root.as_os_str().as_encoded_bytes())
        .iter()
        .take(6)
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("binding:{kind}-{hex}")
}

fn role_word(r: Role) -> &'static str {
    match r {
        Role::Manager => "manager",
        Role::Worker => "worker",
        Role::Chat => "chat",
    }
}

fn role_of(v: &Value) -> Option<Role> {
    serde_json::from_value(v.clone()).ok()
}

/// Bind outside agents of KIND in ROOT (an absolute folder) as ROLE: a live binding of the same (kind, root) is
/// updated, a retired one comes back.  The guard refuses any class but `User`.
pub fn bind(tx: &mut Tx<'_>, kind: &str, root: &Path, role: Role) -> Result<Binding, WriteError> {
    guard::check(tx.guard(), tx.meta(), "binding")?;
    if !crate::tools::identity::valid_kind(kind) {
        return Err(WriteError::Refused(format!(
            "an agent kind is a short lower-case name (claude, codex, zed…), not {kind:?}"
        )));
    }
    if !root.is_absolute() {
        return Err(WriteError::Refused(
            "a binding's root is an absolute folder".into(),
        ));
    }
    let id = binding_id(kind, root);
    let data = json!({"kind": kind, "root": root.to_string_lossy(), "role": role_word(role)});
    let title = format!(
        "{kind} agents in {} act as {}",
        root.display(),
        role_word(role)
    );
    match entity::by_id(tx.sql(), &id)? {
        Some(e) => {
            if e.kind != "binding" {
                return Err(WriteError::Refused(format!("{id} is not a binding")));
            }
            if e.retired_tx.is_some() {
                entity::unretire(tx, e.n)?;
            }
            entity::update(
                tx,
                e.n,
                None,
                Changes {
                    title: Some(Some(title)),
                    status: Some(Some("active".into())),
                    data_patch: Some(data),
                    ..Changes::default()
                },
            )?;
        }
        None => {
            entity::create(
                tx,
                EntityNew {
                    id: id.clone(),
                    kind: "binding".into(),
                    project: None,
                    title: Some(title),
                    status: Some("active".into()),
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
    Ok(Binding {
        id,
        kind: kind.to_owned(),
        root: root.to_path_buf(),
        role,
        at: tx.at(),
    })
}

/// Retire binding ID; false when there was no live one.  The guard refuses any class but `User`, found or not.
pub fn unbind(tx: &mut Tx<'_>, id: &str) -> Result<bool, WriteError> {
    guard::check(tx.guard(), tx.meta(), "binding")?;
    let Some(e) = entity::by_id(tx.sql(), id)? else {
        return Ok(false);
    };
    if e.kind != "binding" || e.retired_tx.is_some() {
        return Ok(false);
    }
    entity::retire(tx, e.n)?;
    Ok(true)
}

/// The tx time of TX.
fn tx_at(conn: &Connection, tx: i64) -> f64 {
    conn.query_row("select at from tx where id = ?1", [tx], |r| r.get(0))
        .unwrap_or(0.0)
}

/// Whether every tx that wrote E (its creation, its last write and each field's) is of class `user`.
fn by_the_user(conn: &Connection, e: &entity::Ent) -> Result<bool, urdr::SqliteError> {
    let mut txs = vec![e.created_tx, e.updated_tx];
    txs.extend(e.field_tx.values().copied());
    for t in txs {
        let class: Option<String> = conn
            .query_row("select class from tx where id = ?1", [t], |r| r.get(0))
            .ok();
        if class.as_deref() != Some("user") {
            return Ok(false);
        }
    }
    Ok(true)
}

/// E as a binding, when it is a live one that parses.
fn parse(conn: &Connection, e: &entity::Ent) -> Option<Binding> {
    if e.kind != "binding" || e.retired_tx.is_some() || e.status.as_deref() != Some("active") {
        return None;
    }
    Some(Binding {
        id: e.id.clone(),
        kind: e.data.get("kind")?.as_str()?.to_owned(),
        root: PathBuf::from(e.data.get("root")?.as_str()?),
        role: role_of(e.data.get("role")?)?,
        at: tx_at(conn, e.updated_tx),
    })
}

/// Every live binding, by id (whoever wrote it: [`role_for`] is what counts).
pub fn list(conn: &Connection) -> Result<Vec<Binding>, urdr::SqliteError> {
    let mut stmt = conn.prepare(
        "select id from entity where project is null and kind = 'binding' and retired_tx is null order by id",
    )?;
    let ids: Vec<String> = stmt
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut out = Vec::new();
    for id in ids {
        if let Some(e) = entity::by_id(conn, &id)? {
            out.extend(parse(conn, &e));
        }
    }
    Ok(out)
}

/// The role outside agents of KIND in ROOT act as: the live binding's, counted only when the user's txs alone wrote
/// it; `None` when there is none.
pub fn role_for(
    conn: &Connection,
    kind: &str,
    root: &Path,
) -> Result<Option<Role>, urdr::SqliteError> {
    let Some(e) = entity::by_id(conn, &binding_id(kind, root))? else {
        return Ok(None);
    };
    let Some(b) = parse(conn, &e) else {
        return Ok(None);
    };
    if b.kind != kind || b.root != root || !by_the_user(conn, &e)? {
        return Ok(None);
    }
    Ok(Some(b.role))
}

/// Put the class rule of `binding` into GUARD: only the user writes it.
pub fn register(guard: &mut Guard) {
    guard::register(guard, "binding", Class::User, BINDINGS_ARE_THE_USERS);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::testkit::{db, user, write};
    use urdr::graph::TxMeta;

    fn root() -> PathBuf {
        PathBuf::from("/w/org")
    }

    #[test]
    fn a_binding_is_the_users() {
        let (_d, _p, mut conn) = db();
        for class in [Class::Agent, Class::Ext, Class::System] {
            let r = write(&mut conn, TxMeta::new("agent:s1", class, "test"), |tx| {
                bind(tx, "claude", &root(), Role::Worker)
            });
            assert_eq!(
                r,
                Err(WriteError::Refused(BINDINGS_ARE_THE_USERS.into())),
                "{class:?}"
            );
            let r = write(&mut conn, TxMeta::new("agent:s1", class, "test"), |tx| {
                unbind(tx, &binding_id("claude", &root()))
            });
            assert_eq!(
                r,
                Err(WriteError::Refused(BINDINGS_ARE_THE_USERS.into())),
                "{class:?}"
            );
        }
        let b = write(&mut conn, user(), |tx| {
            bind(tx, "claude", &root(), Role::Worker)
        })
        .unwrap();
        assert!(b.id.starts_with("binding:claude-") && b.id.len() == "binding:claude-".len() + 12);
        assert_eq!(
            role_for(&conn, "claude", &root()).unwrap(),
            Some(Role::Worker)
        );
    }

    #[test]
    fn a_binding_written_by_another_class_is_ignored() {
        let (_d, _p, mut conn) = db();
        // a guard-less tx (no rules registered) of class system writes a binding row
        let mut tx = urdr::graph::Tx::for_test(
            &mut conn,
            TxMeta::new("hub", Class::System, "test"),
            std::sync::Arc::new(Guard::default()),
        );
        entity::create(
            &mut tx,
            EntityNew {
                id: binding_id("claude", &root()),
                kind: "binding".into(),
                project: None,
                title: None,
                status: Some("active".into()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({"kind": "claude", "root": "/w/org", "role": "manager"}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
        tx.commit_for_test().unwrap();
        assert_eq!(role_for(&conn, "claude", &root()).unwrap(), None);
        // the user's binding then written over it still carries the system tx's creation: ignored
        write(&mut conn, user(), |tx| {
            bind(tx, "claude", &root(), Role::Worker)
        })
        .unwrap();
        assert_eq!(role_for(&conn, "claude", &root()).unwrap(), None);
        // a user's binding that a guard-less agent tx later touched is ignored too
        let other = PathBuf::from("/w/other");
        write(&mut conn, user(), |tx| {
            bind(tx, "claude", &other, Role::Worker)
        })
        .unwrap();
        assert_eq!(
            role_for(&conn, "claude", &other).unwrap(),
            Some(Role::Worker)
        );
        let n = entity::by_id(&conn, &binding_id("claude", &other))
            .unwrap()
            .unwrap()
            .n;
        let mut tx = urdr::graph::Tx::for_test(
            &mut conn,
            TxMeta::new("agent:s1", Class::Agent, "test"),
            std::sync::Arc::new(Guard::default()),
        );
        entity::update(
            &mut tx,
            n,
            None,
            Changes {
                data_patch: Some(json!({"role": "manager"})),
                ..Changes::default()
            },
        )
        .unwrap();
        tx.commit_for_test().unwrap();
        assert_eq!(role_for(&conn, "claude", &other).unwrap(), None);
    }

    #[test]
    fn rebind_replaces_and_unbind_revokes() {
        let (_d, _p, mut conn) = db();
        let a = write(&mut conn, user(), |tx| {
            bind(tx, "claude", &root(), Role::Worker)
        })
        .unwrap();
        let b = write(&mut conn, user(), |tx| {
            bind(tx, "claude", &root(), Role::Chat)
        })
        .unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(
            role_for(&conn, "claude", &root()).unwrap(),
            Some(Role::Chat)
        );
        assert_eq!(list(&conn).unwrap().len(), 1);
        // another kind or another root is another binding
        assert_eq!(role_for(&conn, "codex", &root()).unwrap(), None);
        assert_eq!(role_for(&conn, "claude", Path::new("/w")).unwrap(), None);
        assert!(write(&mut conn, user(), |tx| unbind(tx, &a.id)).unwrap());
        assert!(!write(&mut conn, user(), |tx| unbind(tx, &a.id)).unwrap());
        assert_eq!(role_for(&conn, "claude", &root()).unwrap(), None);
        assert!(list(&conn).unwrap().is_empty());
        // bound again after the unbind: live again, with the new role
        write(&mut conn, user(), |tx| {
            bind(tx, "claude", &root(), Role::Manager)
        })
        .unwrap();
        assert_eq!(
            role_for(&conn, "claude", &root()).unwrap(),
            Some(Role::Manager)
        );
        let l = list(&conn).unwrap();
        assert_eq!(
            (l.len(), l[0].role, l[0].root.clone()),
            (1, Role::Manager, root())
        );
        // a bad kind or a relative root is refused
        assert!(
            write(&mut conn, user(), |tx| bind(
                tx,
                "Claude",
                &root(),
                Role::Worker
            ))
            .is_err()
        );
        assert!(
            write(&mut conn, user(), |tx| bind(
                tx,
                "claude",
                Path::new("w"),
                Role::Worker
            ))
            .is_err()
        );
    }
}
