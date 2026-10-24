//! `settings/record` (unified-settings Task 24; design §12): one write of a settings file, reported by the editor,
//! recorded as one transaction on entities of kind `option` (docs/develop/store.md, "Settings history and grants").
//!
//! - **One tx per call**, the editor's (user class), its `tool` the call's (`ui:settings`, `file:<name>`,
//!   `lisp:<file>`), its `req` the call's key under `settings ` (a repeat answers the first tx and writes nothing; the
//!   prefix keeps it apart from the user's other keyed writes), `reverts` the tx it undoes, and `project` the ids'
//!   (one project per call: [`project_of`]).
//! - **Each change** makes its entity (`data {value, file, line}`, origin `recorded`) or gives it a new version; a
//!   removed setting's `data` has no `value` (it reads as `null`). A retired entity (one the scan saw go) comes back.
//! - **A secret is never stored:** a value [`runstav::secrets::looks_like_secret`] flags is recorded with no `value`
//!   and `redacted: true` (the change shows in the history, the secret does not; the next value in the clear drops
//!   the flag). Two secrets in a row are one version, as the same value twice is.
//! - The store's rule for kind `option` ([`crate::options::rule`]) holds as for every write: the user writes any
//!   well-formed id.

use runstav::methods::settings::{OptionChange, RecordParams};
use serde_json::{Map, Value};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Origin, Update};
use urdr::graph::{Tx, TxMeta, WriteError};

use crate::options::parse_id;

/// The prefix of a record's request key in the `tx` table.
pub const REQ_PREFIX: &str = "settings ";

fn refused(text: String) -> WriteError {
    WriteError::Refused(text)
}

/// The live `project` entity ID's `n`.
fn project_n(conn: &Connection, id: &str) -> Result<Option<i64>, WriteError> {
    Ok(entity::by_id(conn, id)?
        .filter(|e| e.kind == "project" && e.retired_tx.is_none())
        .map(|e| e.n))
}

/// The project CHANGES are in: `None` for global ids and `root-` folders, else the live project entity the ids name.
/// Refused when an id is not an option id (its index named), when the ids name more than one project, or when the
/// store has no such project.
pub fn project_of(conn: &Connection, changes: &[OptionChange]) -> Result<Option<i64>, WriteError> {
    let mut named: Option<Option<String>> = None;
    for (i, c) in changes.iter().enumerate() {
        let id = parse_id(&c.id)
            .map_err(|e| refused(format!("changes[{i}].id: not an option id ({e})")))?;
        let p = id.project();
        match &named {
            None => named = Some(p),
            Some(first) if *first == p => {}
            Some(_) => {
                return Err(refused(format!(
                    "changes[{i}].id: one record is one project's settings"
                )));
            }
        }
    }
    match named.flatten() {
        None => Ok(None),
        Some(pid) => project_n(conn, &pid)?
            .map(Some)
            .ok_or_else(|| refused(format!("no project {pid} in the store"))),
    }
}

/// The tx of a record: BASE (the editor's connection, user class) with P's tool, key, reverts and PROJECT.
pub fn meta(mut base: TxMeta, p: &RecordParams, project: Option<i64>) -> TxMeta {
    base.tool = p.tool.to_string();
    base.req = Some(format!("{REQ_PREFIX}{}", p.req.as_str()));
    base.reverts = p.reverts.map(|t| i64::try_from(t).unwrap_or(i64::MAX));
    base.project = project;
    base
}

/// CHANGE's `data`: `value`, `file` and `line`, each left out when it has none (merged, a `null` removes it). A value
/// that looks like a secret ([`runstav::secrets::looks_like_secret`]) is never stored: the version has no `value` and
/// `redacted: true` instead, so the history shows that the setting changed but never what the secret was.
fn data_of(c: &OptionChange) -> Map<String, Value> {
    let mut m = Map::new();
    let value = c.value.as_ref().map(|v| v.as_str());
    // The printed form escapes `"` and `\`, which hides a `"api_key": "…"` inside a string: look at the text as well.
    let redacted = value.is_some_and(|v| {
        runstav::secrets::looks_like_secret(v).is_some()
            || runstav::secrets::looks_like_secret(&v.replace("\\\"", "\"").replace("\\\\", "\\"))
                .is_some()
    });
    m.insert(
        "value".into(),
        match value {
            Some(v) if !redacted => Value::String(v.into()),
            _ => Value::Null,
        },
    );
    m.insert(
        "redacted".into(),
        if redacted {
            Value::Bool(true)
        } else {
            Value::Null
        },
    );
    m.insert("file".into(), Value::String(c.file.to_string()));
    m.insert("line".into(), c.line.map_or(Value::Null, Value::from));
    m
}

/// Record CHANGES in TX (its meta from [`meta`]): each option made, brought back or given a new version. Refused when
/// an id is not an option id, is stored as another kind or names another project than the tx's, or when the tx it
/// reverts does not exist.
pub fn record(tx: &mut Tx<'_>, changes: &[OptionChange]) -> Result<(), WriteError> {
    if let Some(r) = tx.meta().reverts {
        let n: i64 = tx.sql().query_row(
            "select count(*) from tx where id = ?1 and id <> ?2",
            [r, tx.id()],
            |row| row.get(0),
        )?;
        if n == 0 {
            return Err(refused(format!("reverts: no tx {r}")));
        }
    }
    for (i, c) in changes.iter().enumerate() {
        let id = parse_id(&c.id)
            .map_err(|e| refused(format!("changes[{i}].id: not an option id ({e})")))?;
        let project = match id.project() {
            Some(pid) => project_n(tx.sql(), &pid)?,
            None => None,
        };
        if project != tx.meta().project {
            return Err(refused(format!(
                "changes[{i}].id: one record is one project's settings"
            )));
        }
        let data = data_of(c);
        match entity::by_id(tx.sql(), &c.id)? {
            None => {
                let kept: Map<String, Value> =
                    data.into_iter().filter(|(_, v)| !v.is_null()).collect();
                entity::create(
                    tx,
                    EntityNew {
                        id: c.id.to_string(),
                        kind: "option".into(),
                        project,
                        title: None,
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: Value::Object(kept),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )?;
            }
            Some(cur) if cur.kind != "option" => {
                return Err(refused(format!(
                    "changes[{i}].id: {} is stored as a {}",
                    cur.id, cur.kind
                )));
            }
            Some(cur) => {
                entity::unretire(tx, cur.n)?;
                let changes = Changes {
                    project: (cur.project != project).then_some(project),
                    data_patch: Some(Value::Object(data)),
                    ..Changes::default()
                };
                if let Update::Conflict { .. } = entity::update(tx, cur.n, None, changes)? {
                    return Err(refused(format!("{} changed meanwhile", cur.id)));
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::testkit::{db, project, user, write};
    use crate::store::CoordDb;
    use serde_json::json;
    use urdr::graph::Class;

    fn params(v: Value) -> RecordParams {
        serde_json::from_value(v).unwrap()
    }

    fn change(id: &str, value: Option<&str>, line: Option<u64>) -> Value {
        json!({"id": id, "value": value, "file": "/c/settings.el", "line": line})
    }

    /// P recorded on CONN as the user: its tx.
    fn rec(conn: &mut Connection, p: &RecordParams) -> Result<i64, WriteError> {
        let project = project_of(conn, &p.changes)?;
        let changes = p.changes.clone();
        write(conn, meta(user(), p, project), move |tx| {
            record(tx, &changes)?;
            Ok(tx.id())
        })
    }

    fn data(conn: &Connection, id: &str) -> Value {
        entity::by_id(conn, id).unwrap().unwrap().data
    }

    #[test]
    fn one_tx_per_call() {
        let (_d, _p, mut conn) = db();
        let a = project(&mut conn, "a");
        let pa = entity::by_n(&conn, a).unwrap().unwrap().id;
        let pa = pa.strip_prefix("project:").unwrap();
        let p = params(json!({
            "changes": [change("option:global:fill-column", Some("80"), Some(3)),
                        change("option:global:mode/c-mode:tab-width", Some("4"), Some(5))],
            "tool": "ui:settings", "req": "r1"}));
        let t = rec(&mut conn, &p).unwrap();
        let (n, tool, class, req, project): (i64, String, String, String, Option<i64>) = conn
            .query_row(
                "select (select count(*) from entity where kind = 'option' and created_tx = ?1), \
                 tool, class, req, project from tx where id = ?1",
                [t],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(
            (n, tool.as_str(), class.as_str(), req.as_str(), project),
            (2, "ui:settings", "user", "settings r1", None)
        );
        assert_eq!(
            data(&conn, "option:global:fill-column"),
            json!({"value": "80", "file": "/c/settings.el", "line": 3})
        );
        // A second call is a second tx, and a new version of what it changes.
        let p2 = params(
            json!({"changes": [change("option:global:fill-column", Some("100"), Some(3))],
                               "tool": "file:settings.el", "req": "r2"}),
        );
        let t2 = rec(&mut conn, &p2).unwrap();
        assert_ne!(t, t2);
        let e = entity::by_id(&conn, "option:global:fill-column")
            .unwrap()
            .unwrap();
        assert_eq!((e.ver, e.updated_tx, e.project), (2, t2, None));
        // A project's ids carry its project, on the entities and the tx.
        let shared = format!("option:shared/{pa}:fill-column");
        let p3 = params(json!({"changes": [change(&shared, Some("72"), Some(1)),
                                           change(&format!("option:private/{pa}:dir/src/:tab-width"), Some("2"), None)],
                               "tool": "ui:settings", "req": "r3"}));
        let t3 = rec(&mut conn, &p3).unwrap();
        let tx_project: Option<i64> = conn
            .query_row("select project from tx where id = ?1", [t3], |r| r.get(0))
            .unwrap();
        assert_eq!(tx_project, Some(a));
        assert_eq!(
            entity::by_id(&conn, &shared).unwrap().unwrap().project,
            Some(a)
        );
        // One call is one project's; an unknown project, a bad id and another kind are refused, writing nothing.
        let before: i64 = conn
            .query_row("select count(*) from tx", [], |r| r.get(0))
            .unwrap();
        for (changes, want) in [
            (
                json!([
                    change(&shared, Some("1"), None),
                    change("option:global:x", Some("1"), None)
                ]),
                "changes[1].id: one record is one project's settings",
            ),
            (
                json!([change("option:shared/nosuch:x", Some("1"), None)]),
                "no project project:nosuch in the store",
            ),
        ] {
            let p = params(json!({"changes": changes, "tool": "ui:settings", "req": "rx"}));
            assert_eq!(rec(&mut conn, &p), Err(WriteError::Refused(want.into())));
        }
        let bad = params(
            json!({"changes": [change("option:global:", None, None)], "tool": "ui:settings", "req": "rb"}),
        );
        assert!(
            matches!(rec(&mut conn, &bad), Err(WriteError::Refused(t)) if t.starts_with("changes[0].id: not an option id"))
        );
        let after: i64 = conn
            .query_row("select count(*) from tx", [], |r| r.get(0))
            .unwrap();
        assert_eq!(before, after);
    }

    #[test]
    fn a_tx_of_another_project_is_refused_in_the_write() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let pa = entity::by_n(&conn, a).unwrap().unwrap().id;
        let p = params(
            json!({"changes": [change(&format!("option:shared/{}:x", &pa[8..]), Some("1"), None)],
                              "tool": "ui:settings", "req": "r"}),
        );
        let changes = p.changes.clone();
        // The project the hub read before the write, gone by the write: the ids' project is checked again.
        let got = write(&mut conn, meta(user(), &p, Some(b)), move |tx| {
            record(tx, &changes)
        });
        assert_eq!(
            got,
            Err(WriteError::Refused(
                "changes[0].id: one record is one project's settings".into()
            ))
        );
        // An id stored as another kind is not an option's.
        let changes = params(
            json!({"changes": [change("option:global:x", Some("1"), None)],
                                    "tool": "ui:settings", "req": "r"}),
        )
        .changes;
        write(&mut conn, user(), |tx| {
            entity::create(
                tx,
                EntityNew {
                    id: "option:global:x".into(),
                    kind: "task".into(),
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
            )
        })
        .unwrap();
        assert_eq!(
            write(&mut conn, user(), move |tx| record(tx, &changes)),
            Err(WriteError::Refused(
                "changes[0].id: option:global:x is stored as a task".into()
            ))
        );
    }

    #[test]
    fn the_project_is_the_ids_live_project() {
        let (_d, _p, mut conn) = db();
        let a = project(&mut conn, "a");
        let pa = entity::by_n(&conn, a).unwrap().unwrap().id;
        let shared = format!("option:shared/{}:x", &pa[8..]);
        // Two projects in one call: refused before any write.
        let mixed = params(json!({"changes": [change(&shared, Some("1"), None),
                                             change("option:global:x", Some("1"), None)],
                                 "tool": "ui:settings", "req": "r"}));
        assert_eq!(
            project_of(&conn, &mixed.changes),
            Err(refused(
                "changes[1].id: one record is one project's settings".into()
            ))
        );
        // An entity of the id stored under another project moves to the ids' project.
        write(&mut conn, user(), |tx| {
            entity::create(
                tx,
                EntityNew {
                    id: shared.clone(),
                    kind: "option".into(),
                    project: None,
                    title: None,
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({"value": "1"}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )
        })
        .unwrap();
        let one = params(
            json!({"changes": [change(&shared, Some("2"), None)], "tool": "ui:settings", "req": "r1"}),
        );
        rec(&mut conn, &one).unwrap();
        assert_eq!(
            entity::by_id(&conn, &shared).unwrap().unwrap().project,
            Some(a)
        );
        // A retired project is no project of the store.
        write(&mut conn, user(), |tx| entity::retire(tx, a)).unwrap();
        assert_eq!(
            project_of(&conn, &one.changes),
            Err(refused(format!("no project {pa} in the store")))
        );
    }

    #[tokio::test]
    async fn a_retry_is_one_tx() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let w = db.graph_writer().unwrap().clone();
        w.tick().await;
        let p = params(
            json!({"changes": [change("option:global:fill-column", Some("80"), Some(3))],
                              "tool": "file:settings.el", "req": "stamp-1"}),
        );
        let run = |p: RecordParams| {
            let w = w.clone();
            async move {
                let changes = p.changes.clone();
                w.write(
                    meta(TxMeta::new("user", Class::User, "x"), &p, None),
                    move |tx| record(tx, &changes),
                )
                .await
                .unwrap()
            }
        };
        let first = run(p.clone()).await;
        let again = run(p.clone()).await;
        assert!(!first.replayed);
        assert!(again.replayed);
        assert_eq!(first.tx, again.tx);
        // Another key is another tx, even with the same changes.
        let mut other = p.clone();
        other.req = serde_json::from_value(json!("stamp-2")).unwrap();
        let third = run(other).await;
        assert_ne!(third.tx, first.tx);
        let conn = Connection::open(dir.path().join("work.db")).unwrap();
        let (txs, ver): (i64, i64) = conn
            .query_row(
                "select (select count(*) from tx where tool = 'file:settings.el'), \
                 (select ver from entity where id = 'option:global:fill-column')",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        // The third wrote the same data: a tx, but no new version.
        assert_eq!((txs, ver), (2, 1));
    }

    #[test]
    fn removed_is_null() {
        let (_d, _p, mut conn) = db();
        let id = "option:global:fill-column";
        let set = params(
            json!({"changes": [change(id, Some("80"), Some(3))], "tool": "ui:settings", "req": "r1"}),
        );
        rec(&mut conn, &set).unwrap();
        let gone = params(
            json!({"changes": [change(id, None, None)], "tool": "ui:settings", "req": "r2"}),
        );
        rec(&mut conn, &gone).unwrap();
        let d = data(&conn, id);
        assert_eq!(d, json!({"file": "/c/settings.el"}));
        assert!(d["value"].is_null());
        // Removed before it was ever recorded: made with no value.
        let fresh = "option:global:tab-width";
        let gone = params(
            json!({"changes": [change(fresh, None, Some(2))], "tool": "ui:settings", "req": "r3"}),
        );
        rec(&mut conn, &gone).unwrap();
        assert_eq!(
            data(&conn, fresh),
            json!({"file": "/c/settings.el", "line": 2})
        );
        // Set again: the value is back.
        let again = params(
            json!({"changes": [change(id, Some("80"), Some(3))], "tool": "ui:settings", "req": "r4"}),
        );
        rec(&mut conn, &again).unwrap();
        assert_eq!(
            data(&conn, id),
            json!({"value": "80", "file": "/c/settings.el", "line": 3})
        );
    }

    /// Every case of the shared secret table, as the printed Lisp string the editor sends: a value that looks like a
    /// secret is recorded as a change (a new version, `redacted: true`) with no value, and its text is nowhere in the
    /// store; any other value is kept as it is. A redacted value set again in the clear drops the flag.
    #[test]
    fn a_secret_is_never_stored() {
        let (_d, _p, mut conn) = db();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../test/fixtures/secret-cases.json");
        let table: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let cases = table["cases"].as_array().unwrap();
        assert!(cases.len() > 30);
        let id = "option:global:my-key";
        let mut wrong = Vec::new();
        for (i, case) in cases.iter().enumerate() {
            // From a plain value each time, so each case is a change (two secrets in a row are one version).
            let plain = params(json!({"changes": [change(id, Some("1"), Some(1))],
                                      "tool": "ui:settings", "req": format!("p{i}")}));
            rec(&mut conn, &plain).unwrap();
            assert_eq!(
                data(&conn, id),
                json!({"value": "1", "file": "/c/settings.el", "line": 1})
            );
            let text: String = match &case["text"] {
                Value::String(s) => s.clone(),
                Value::Array(parts) => parts.iter().map(|p| p.as_str().unwrap()).collect(),
                other => panic!("text: {other}"),
            };
            let printed = format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
            let secret = case["rule"].is_string();
            if secret != runstav::secrets::looks_like_secret(&text).is_some() {
                wrong.push(format!("{}: printed, the rule differs", case["name"]));
                continue;
            }
            let ver = entity::by_id(&conn, id).unwrap().unwrap().ver;
            let p = params(json!({"changes": [change(id, Some(&printed), Some(1))],
                                  "tool": "ui:settings", "req": format!("r{}", i + 1)}));
            rec(&mut conn, &p).unwrap();
            let e = entity::by_id(&conn, id).unwrap().unwrap();
            let want = if secret {
                json!({"redacted": true, "file": "/c/settings.el", "line": 1})
            } else {
                json!({"value": printed, "file": "/c/settings.el", "line": 1})
            };
            if e.data != want || e.ver != ver + 1 {
                wrong.push(format!("{}: {} at ver {}", case["name"], e.data, e.ver));
            }
            if secret {
                let needle = case["text"].as_array().map_or(text.clone(), |parts| {
                    parts.last().unwrap().as_str().unwrap().into()
                });
                let found: i64 = conn
                    .query_row(
                        "select (select count(*) from entity where instr(data, ?1) > 0) \
                         + (select count(*) from entity_hist where instr(data, ?1) > 0) \
                         + (select count(*) from tx where instr(coalesce(answer, '') || coalesce(note, '') \
                            || coalesce(req, ''), ?1) > 0)",
                        [&needle],
                        |r| r.get(0),
                    )
                    .unwrap();
                if found != 0 {
                    wrong.push(format!("{}: its text is in the store", case["name"]));
                }
            }
        }
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    }

    #[test]
    fn reverts_is_recorded() {
        let (_d, _p, mut conn) = db();
        let id = "option:global:fill-column";
        let first = rec(
            &mut conn,
            &params(
                json!({"changes": [change(id, Some("80"), Some(3))], "tool": "ui:settings", "req": "r1"}),
            ),
        )
        .unwrap();
        rec(
            &mut conn,
            &params(
                json!({"changes": [change(id, Some("100"), Some(3))], "tool": "ui:settings", "req": "r2"}),
            ),
        )
        .unwrap();
        let undo = params(
            json!({"changes": [change(id, Some("80"), Some(3))], "tool": "ui:settings",
                                 "req": "r3", "reverts": first}),
        );
        let t = rec(&mut conn, &undo).unwrap();
        let reverts: Option<i64> = conn
            .query_row("select reverts from tx where id = ?1", [t], |r| r.get(0))
            .unwrap();
        assert_eq!(reverts, Some(first));
        assert_eq!(data(&conn, id)["value"], json!("80"));
        // A tx that does not exist is never reverted.
        let bad = params(
            json!({"changes": [change(id, Some("1"), None)], "tool": "ui:settings",
                                "req": "r4", "reverts": 999}),
        );
        assert_eq!(
            rec(&mut conn, &bad),
            Err(WriteError::Refused("reverts: no tx 999".into()))
        );
    }

    #[test]
    fn a_retired_option_comes_back() {
        let (_d, _p, mut conn) = db();
        let id = "option:global:fill-column";
        let set = params(
            json!({"changes": [change(id, Some("80"), Some(3))], "tool": "ui:settings", "req": "r1"}),
        );
        rec(&mut conn, &set).unwrap();
        let n = entity::by_id(&conn, id).unwrap().unwrap().n;
        write(&mut conn, user(), |tx| entity::retire(tx, n)).unwrap();
        let again = params(
            json!({"changes": [change(id, Some("90"), Some(3))], "tool": "ui:settings", "req": "r2"}),
        );
        rec(&mut conn, &again).unwrap();
        let e = entity::by_id(&conn, id).unwrap().unwrap();
        assert_eq!((e.retired_tx, e.data["value"].clone()), (None, json!("90")));
    }
}
