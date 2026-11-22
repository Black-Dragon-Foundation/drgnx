//! `records/write` and a new plan's view file: specs, decisions and plans written through the graph, one transaction
//! as the caller, the file created from the render and adopted, later changes reaching it at the next sync.

use super::paths;
use super::{
    Piece, ViewEvent, Views, adopted_key, apply_acts, data_of, diff, link_structure, pieces,
};
use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::runner::effects::Scope;
use norn::store::CoordDb;
use runstav::methods::plans::{PlanWritten, TaskId, WriteParams};
use runstav::methods::records::{DocKind, RecordKind, RecordWrite, RecordWritten, SectionId};
use runstav::wire::{Error, ErrorCode};
use saga::import::{self, AnyDoc};
use saga::spec::{SectionEdit, SpecEdits};
use std::path::{Path, PathBuf};
use urdr::graph::TxMeta;
use urdr::graph::entity;

/// Who writes and what they may reach.
pub(crate) struct Actor {
    /// The `tx` row of the write.
    pub(crate) meta: TxMeta,
    /// An agent (its checks apply); the user's writes are not checked.
    pub(crate) agent: bool,
    pub(crate) scope: Scope,
    /// The project's root: where a new file may go.
    pub(crate) root: Option<PathBuf>,
    /// The matrix lets this agent approve (`task.done`).
    pub(crate) may_approve: bool,
}

fn invalid(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: msg.into(),
        path: None,
    }
}

fn refuse(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: msg.into(),
        path: None,
    }
}

/// The actor of caller C writing as METHOD, with SCOPE (`effects::scope_of`) and the project named PROJECT (a user's
/// new record needs one; an agent's is its own).
pub(crate) async fn actor_for(
    f: &Front,
    c: &Caller,
    scope: Scope,
    project: Option<&str>,
    method: &str,
) -> Result<Actor, Error> {
    let agent = c.class == runstav::registry::Class::Agent;
    let root = match (&scope, project) {
        (Scope::Project { root, .. }, _) => root.clone(),
        (Scope::Anyone, Some(id)) => {
            let id = id.to_owned();
            let path: Option<String> = f
                .writer
                .db
                .read(move |c| {
                    Ok(entity::by_id(c, &id)?
                        .filter(|e| e.kind == "project" && e.retired_tx.is_none())
                        .and_then(|e| {
                            e.data
                                .get("path")
                                .and_then(|p| p.as_str().map(str::to_owned))
                        }))
                })
                .await
                .map_err(fail)?;
            path.map(PathBuf::from)
        }
        (Scope::Anyone, None) => None,
    };
    let may_approve = !agent || crate::runner::effects::may_approve(f, c).await.is_ok();
    Ok(Actor {
        meta: crate::coord::tx_meta(c, method),
        agent,
        scope,
        root,
        may_approve,
    })
}

fn kinds(k: DocKind) -> (RecordKind, &'static str) {
    match k {
        DocKind::Spec => (RecordKind::Specs, "spec"),
        DocKind::Decision => (RecordKind::Decisions, "decision"),
    }
}

/// The graph's `done` as the file's word for the kind; any other word as given.
fn file_word(status: &str, k: DocKind) -> String {
    match (status, k) {
        ("done", DocKind::Spec) => "approved".into(),
        ("done", DocKind::Decision) => "accepted".into(),
        (w, _) => w.to_owned(),
    }
}

fn approves(word: &str) -> bool {
    import::spec_status(word) == "done"
}

/// The refusal of a text only the user may write (`matrix: …`).
fn user_only(texts: &[&str]) -> Result<(), Error> {
    if texts.iter().any(|t| saga::merge::touches_user_only(t)) {
        return Err(refuse(
            "that text sets a field only the user may set (`matrix`): an agent does not write it",
        ));
    }
    Ok(())
}

async fn version_of(db: &CoordDb, path: &Path) -> Result<u64, Error> {
    let key = import::source_key(path);
    db.read(move |c| {
        let v: i64 = c.query_row(
            "select coalesce(max(updated_tx), 0) from entity where source = ?1 and retired_tx is null",
            [&key],
            |r| r.get(0),
        )?;
        Ok(v as u64)
    })
    .await
    .map_err(fail)
}

/// The record file and kind a head id names.
pub(super) async fn locate(db: &CoordDb, id: &str) -> Result<(PathBuf, DocKind), Error> {
    let id = id.to_owned();
    let found = db
        .read(move |c| {
            Ok(entity::by_id(c, &id)?
                .filter(|e| e.retired_tx.is_none())
                .map(|e| {
                    (
                        e.kind.clone(),
                        e.data["records"]["role"].as_str().unwrap_or("").to_owned(),
                        e.data["records"]["file"].as_str().unwrap_or("").to_owned(),
                    )
                }))
        })
        .await
        .map_err(fail)?;
    match found {
        Some((kind, role, file)) if role == "head" && !file.is_empty() => match kind.as_str() {
            "spec" => Ok((PathBuf::from(file), DocKind::Spec)),
            "decision" => Ok((PathBuf::from(file), DocKind::Decision)),
            _ => Err(invalid("that is not a spec or a decision record")),
        },
        _ => Err(invalid("no such spec or decision record")),
    }
}

fn key_of(p: &Piece) -> String {
    p.data["records"]["key"].as_str().unwrap_or("").to_owned()
}

async fn written(db: &CoordDb, path: &Path, tx: u64) -> Result<RecordWritten, Error> {
    let ps = pieces(db, path).await?;
    let head = ps
        .first()
        .ok_or_else(|| invalid("the record has no pieces"))?;
    Ok(RecordWritten {
        record: head.id.clone(),
        path: path.to_string_lossy().into_owned(),
        tx,
        version: version_of(db, path).await?,
        sections: ps
            .iter()
            .filter(|p| p.role == "section")
            .map(|p| SectionId {
                key: key_of(p),
                id: p.id.clone(),
            })
            .collect(),
    })
}

/// The graph's text of a record file: its pieces' bodies in order.
fn text_of(ps: &[Piece]) -> String {
    ps.iter().map(|p| p.body.as_str()).collect()
}

/// Make the graph hold TEXT (a record file's text) as the pieces of PATH, in one transaction as ACTOR's meta; with
/// ADOPT the file is marked adopted in the same one.  Answers the tx id.
async fn apply_text(
    db: &CoordDb,
    actor: &Actor,
    path: &Path,
    rk: RecordKind,
    parse: &'static str,
    text: &str,
    adopt: bool,
) -> Result<u64, Error> {
    let doc: AnyDoc = import::parse(parse, text).ok_or_else(|| invalid("unknown record kind"))?;
    let ops = import::ops(&doc, path);
    let data: Vec<serde_json::Value> = ops.iter().map(|o| data_of(o, path, rk)).collect();
    let mark = adopt.then(|| adopted_key(path));
    db.write(actor.meta.clone(), move |tx| {
        let acts = diff(tx.sql(), &ops, &data)?;
        apply_acts(acts, &ops, &data, Some(&mut *tx))?;
        link_structure(tx, &ops)?;
        if let Some(k) = &mark {
            tx.sql().execute(
                "insert or replace into kv (key, value) values (?1, ?2)",
                (k, "1"),
            )?;
        }
        Ok(tx.id() as u64)
    })
    .await
    .map_err(fail)
}

/// Create the file at REL under the actor's root with TEXT, adopt it and put it in the graph.  A failed import removes
/// the file again.
async fn create_file(
    db: &CoordDb,
    actor: &Actor,
    rel: &str,
    rk: RecordKind,
    text: &str,
) -> Result<(PathBuf, u64), Error> {
    let root = actor
        .root
        .as_deref()
        .ok_or_else(|| invalid("a new record needs a project with a root folder"))?;
    let file = paths::planning_path(root, rel, rk).map_err(invalid)?;
    actor.scope.allows_path(&file).map_err(fail)?;
    paths::create_new_file(root, &file, text).map_err(invalid)?;
    let parse = super::parse_of(rk);
    match apply_text(db, actor, &file, rk, parse, text, true).await {
        Ok(tx) => Ok((file, tx)),
        Err(e) => {
            let _ = std::fs::remove_file(&file);
            Err(e)
        }
    }
}

/// The sync after a write: the file takes the graph's change and a hand edit is merged; the events it makes.
async fn sync_after(
    db: &CoordDb,
    views: &Views,
    path: &Path,
    rk: RecordKind,
) -> Result<Vec<ViewEvent>, Error> {
    let (fl, _acts, flagged) = views.sync_flagged(db, path).await?;
    Ok(Views::events_of(path, rk, &fl, flagged))
}

/// `records/write`: as [`write_core_events`], the events dropped (tests).
#[cfg(test)]
pub(crate) async fn write_core(
    db: &CoordDb,
    views: &Views,
    actor: &Actor,
    p: RecordWrite,
) -> Result<RecordWritten, Error> {
    write_core_events(db, views, actor, p).await.map(|x| x.0)
}

pub(crate) async fn write_core_events(
    db: &CoordDb,
    views: &Views,
    actor: &Actor,
    p: RecordWrite,
) -> Result<(RecordWritten, Vec<ViewEvent>), Error> {
    let (rk, parse) = kinds(p.kind);
    if actor.agent {
        let mut texts: Vec<&str> = p
            .sections
            .0
            .iter()
            .flat_map(|s| [s.heading.as_str(), s.body.as_str()])
            .collect();
        texts.extend(p.title.iter().map(|t| t.as_str()));
        user_only(&texts)?;
    }
    let sections: Vec<(String, String)> = p
        .sections
        .0
        .iter()
        .map(|s| (s.heading.as_str().to_owned(), s.body.as_str().to_owned()))
        .collect();
    match &p.record {
        None => {
            if p.base_version != 0 {
                return Err(invalid("a new record has base_version 0"));
            }
            let rel = p
                .path
                .as_ref()
                .ok_or_else(|| invalid("a new record needs a path"))?;
            let title = p
                .title
                .as_ref()
                .ok_or_else(|| invalid("a new record needs a title"))?;
            let status = p.status.as_ref().map_or("proposed", |s| s.as_str());
            if actor.agent && !actor.may_approve && approves(status) {
                return Err(refuse(
                    "an agent may not approve a record: it starts proposed and the user approves it",
                ));
            }
            let word = file_word(status, p.kind);
            // the sections are checked as an edit of an empty spec would check them
            let blank = saga::spec::new_text(title.as_str(), &word, &[]);
            let edits = SpecEdits {
                sections: p
                    .sections
                    .0
                    .iter()
                    .map(|s| SectionEdit {
                        key: None,
                        heading: s.heading.as_str().to_owned(),
                        body: s.body.as_str().to_owned(),
                        after: None,
                    })
                    .collect(),
                ..Default::default()
            };
            saga::spec::edit(&blank, &edits).map_err(invalid)?;
            let text = saga::spec::new_text(title.as_str(), &word, &sections);
            let (file, tx) = create_file(db, actor, rel.as_str(), rk, &text).await?;
            let events = sync_after(db, views, &file, rk).await?;
            Ok((written(db, &file, tx).await?, events))
        }
        Some(id) => {
            let (file, kind) = locate(db, id.as_str()).await?;
            if kind != p.kind {
                return Err(invalid("that record is of the other kind"));
            }
            actor.scope.allows_path(&file).map_err(fail)?;
            let ps = pieces(db, &file).await?;
            let current = version_of(db, &file).await?;
            if p.base_version != current {
                return Err(invalid(format!(
                    "held: the record changed since version {} (now {current}); read it again",
                    p.base_version
                )));
            }
            let old = text_of(&ps);
            let old_done = ps.first().and_then(|h| h.status.as_deref()) == Some("done");
            let edits = SpecEdits {
                title: p.title.as_ref().map(|t| t.as_str().to_owned()),
                status: p.status.as_ref().map(|s| file_word(s.as_str(), p.kind)),
                sections: p
                    .sections
                    .0
                    .iter()
                    .map(|s| SectionEdit {
                        key: s.key.as_ref().map(|k| k.as_str().to_owned()),
                        heading: s.heading.as_str().to_owned(),
                        body: s.body.as_str().to_owned(),
                        after: s.after.as_ref().map(|a| a.as_str().to_owned()),
                    })
                    .collect(),
                remove: p
                    .remove
                    .iter()
                    .flat_map(|r| r.0.iter().map(|k| k.as_str().to_owned()))
                    .collect(),
            };
            let new = saga::spec::edit(&old, &edits).map_err(invalid)?;
            if actor.agent && !actor.may_approve && !old_done {
                let now = saga::spec::parse(&new).status;
                if now.as_deref().is_some_and(approves) {
                    return Err(refuse(
                        "an agent may not approve a record: the user does (the status stays proposed)",
                    ));
                }
            }
            let tx = apply_text(db, actor, &file, rk, parse, &new, false).await?;
            let events = sync_after(db, views, &file, rk).await?;
            Ok((written(db, &file, tx).await?, events))
        }
    }
}

/// A new plan with a view file at REL: the file made from the tasks (`saga::plan::new_text`), adopted and imported as
/// the caller; the answer names the imported ids.
pub(crate) async fn create_plan_core(
    db: &CoordDb,
    views: &Views,
    actor: &Actor,
    p: &WriteParams,
    rel: &str,
) -> Result<PlanWritten, Error> {
    let title = p
        .title
        .as_ref()
        .ok_or_else(|| invalid("a new plan needs a title"))?;
    let tasks: Vec<saga::plan::NewTask> = p
        .tasks
        .0
        .iter()
        .map(|t| saga::plan::NewTask {
            number: t.number.as_str().to_owned(),
            title: t
                .title
                .as_ref()
                .map(|x| x.as_str().to_owned())
                .unwrap_or_default(),
            body: t
                .body
                .as_ref()
                .map(|b| b.as_str().to_owned())
                .unwrap_or_default(),
            steps: t
                .steps
                .iter()
                .flat_map(|s| s.0.iter().map(|s| (s.done, s.text.as_str().to_owned())))
                .collect(),
            depends: t
                .blocks
                .iter()
                .flat_map(|b| b.0.iter().map(|n| n.as_str().to_owned()))
                .collect(),
            role: t.role.as_ref().map(|r| r.as_str().to_owned()),
            model: t.model.as_ref().map(|m| m.as_str().to_owned()),
            interfaces: t.interfaces.as_ref().map(|i| i.as_str().to_owned()),
        })
        .collect();
    let text = saga::plan::new_text(title.as_str(), &tasks);
    let (file, tx) = create_file(db, actor, rel, RecordKind::Plans, &text).await?;
    sync_after(db, views, &file, RecordKind::Plans).await?;
    let ps = pieces(db, &file).await?;
    let plan = ps
        .first()
        .ok_or_else(|| invalid("the plan has no pieces"))?
        .id
        .clone();
    Ok(PlanWritten {
        plan,
        tx,
        tasks: ps
            .iter()
            .filter(|p| p.role == "task")
            .map(|p| TaskId {
                number: p.data["number"].as_str().unwrap_or("").to_owned(),
                id: p.id.clone(),
            })
            .collect(),
    })
}

pub(crate) async fn records_write(
    f: &Front,
    c: &Caller,
    p: RecordWrite,
) -> Result<RecordWritten, Error> {
    let scope = crate::runner::effects::scope_of(f, c).await?;
    crate::runner::effects::may_change(f, c, None).await?;
    let actor = actor_for(
        f,
        c,
        scope,
        p.project.as_ref().map(|i| i.as_str()),
        "records/write",
    )
    .await?;
    let (out, events) = write_core_events(&f.writer.db, &f.core.records, &actor, p).await?;
    for e in events {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::super::status_core;
    use super::super::tests::{Fix, fix};
    use super::*;
    use crate::coord::tx_meta;
    use runstav::registry::Class;
    use serde_json::{Value, json};

    fn user(f: &Fix) -> Actor {
        Actor {
            meta: tx_meta(
                &Caller {
                    class: Class::User,
                    sid: None,
                    job: None,
                    conn_id: 0,
                },
                "records/write",
            ),
            agent: false,
            scope: Scope::Anyone,
            root: Some(f.root.clone()),
            may_approve: true,
        }
    }

    fn agent(f: &Fix, sid: &str, may_approve: bool) -> Actor {
        let c = Caller {
            class: Class::Agent,
            sid: Some(sid.into()),
            job: None,
            conn_id: 0,
        };
        Actor {
            meta: tx_meta(&c, "records/write"),
            agent: true,
            scope: Scope::Project {
                id: Some("project:a".into()),
                root: Some(f.root.clone()),
                jobs: vec![],
                sessions: vec![sid.into()],
            },
            root: Some(f.root.clone()),
            may_approve,
        }
    }

    fn w(v: Value) -> RecordWrite {
        serde_json::from_value(v).unwrap()
    }

    fn new_spec(path: &str) -> RecordWrite {
        w(
            json!({"kind": "spec", "project": "project:a", "path": path, "title": "Menus",
                 "sections": [{"heading": "Goals", "body": "Small.\n\n"}, {"heading": "Data", "body": "Rows.\n"}],
                 "base_version": 0}),
        )
    }

    const SPEC_PATH: &str = "docs/specs/r/menus.md";

    async fn created(f: &Fix) -> RecordWritten {
        write_core(&f.db, &f.views, &user(f), new_spec(SPEC_PATH))
            .await
            .unwrap()
    }

    fn file_of(f: &Fix) -> PathBuf {
        f.root.join(SPEC_PATH)
    }

    fn key_id(r: &RecordWritten, key: &str) -> String {
        r.sections
            .iter()
            .find(|s| s.key == key)
            .unwrap_or_else(|| panic!("no {key}: {:?}", r.sections))
            .id
            .clone()
    }

    const TX: &str = "select count(*) from tx";

    #[tokio::test]
    async fn a_new_spec_creates_its_file_adopted_and_in_the_graph() {
        let f = fix();
        let r = created(&f).await;
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        let want = saga::spec::new_text(
            "Menus",
            "proposed",
            &[
                ("Goals".into(), "Small.\n\n".into()),
                ("Data".into(), "Rows.\n".into()),
            ],
        );
        assert_eq!(text, want);
        let adopted = adopted_key(&file_of(&f));
        let marks: i64 =
            f.db.read(move |c| {
                Ok(
                    c.query_row("select count(*) from kv where key = ?1", [&adopted], |r| {
                        r.get(0)
                    })?,
                )
            })
            .await
            .unwrap();
        assert_eq!(marks, 1);
        assert_eq!(r.sections.len(), 2);
        assert!(r.record.starts_with("spec:rec-"));
        let st = status_core(&f.db, &f.views, Some(&file_of(&f)))
            .await
            .unwrap();
        assert_eq!(st.views.len(), 1);
        let n = f
            .count("select count(*) from entity where source like 'records:%' and json_extract(data, '$.records.file') like '%/r/menus.md' and retired_tx is null")
            .await;
        assert_eq!(n, 3, "a head and two sections");
    }

    #[tokio::test]
    async fn a_write_behind_base_version_is_refused_and_writes_nothing() {
        let f = fix();
        let r = created(&f).await;
        let before = f.count(TX).await;
        let stale = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": key_id_key("data"), "heading": "Data", "body": "X.\n"}],
            "base_version": r.version - 1}));
        let e = write_core(&f.db, &f.views, &user(&f), stale)
            .await
            .unwrap_err();
        assert!(e.message.contains("changed since"), "{}", e.message);
        assert_eq!(f.count(TX).await, before);
    }

    fn key_id_key(slug: &str) -> String {
        format!("section {slug}")
    }

    #[tokio::test]
    async fn a_section_edit_reaches_the_file_and_keeps_other_ids() {
        let f = fix();
        let r = created(&f).await;
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section data", "heading": "Data", "body": "New rows.\n"}],
            "base_version": r.version}));
        let r2 = write_core(&f.db, &f.views, &user(&f), edit).await.unwrap();
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        assert!(text.contains("New rows."), "{text}");
        assert!(text.contains("Small."), "{text}");
        assert_eq!(key_id(&r, "section goals"), key_id(&r2, "section goals"));
        assert_eq!(key_id(&r, "section data"), key_id(&r2, "section data"));
        assert!(r2.version > r.version);
    }

    #[tokio::test]
    async fn a_hand_edit_of_another_section_is_merged() {
        let f = fix();
        let r = created(&f).await;
        let p = file_of(&f);
        let hand = std::fs::read_to_string(&p)
            .unwrap()
            .replace("Rows.", "Hand rows.");
        std::fs::write(&p, hand).unwrap();
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section goals", "heading": "Goals", "body": "Graph goals.\n\n"}],
            "base_version": r.version}));
        write_core(&f.db, &f.views, &user(&f), edit).await.unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.contains("Hand rows."), "{text}");
        assert!(text.contains("Graph goals."), "{text}");
    }

    #[tokio::test]
    async fn a_hand_edit_of_the_same_section_is_a_conflict() {
        let f = fix();
        let r = created(&f).await;
        let p = file_of(&f);
        let hand = std::fs::read_to_string(&p)
            .unwrap()
            .replace("Small.", "Hand small.");
        std::fs::write(&p, hand).unwrap();
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section goals", "heading": "Goals", "body": "Graph goals.\n\n"}],
            "base_version": r.version}));
        write_core(&f.db, &f.views, &user(&f), edit).await.unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(
            text.contains("Hand small."),
            "the file keeps its text: {text}"
        );
        assert!(!text.contains("Graph goals."), "{text}");
        let st = status_core(&f.db, &f.views, Some(&p)).await.unwrap();
        assert_eq!(st.views[0].conflicts.len(), 1, "{:?}", st.views);
    }

    #[tokio::test]
    async fn remove_retires_the_section() {
        let f = fix();
        let r = created(&f).await;
        let edit = w(
            json!({"record": r.record, "kind": "spec", "remove": ["section data"],
            "base_version": r.version}),
        );
        write_core(&f.db, &f.views, &user(&f), edit).await.unwrap();
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        assert!(!text.contains("## Data"), "{text}");
        let id = key_id(&r, "section data");
        let live: i64 =
            f.db.read(move |c| {
                Ok(c.query_row(
                    "select count(*) from entity where id = ?1 and retired_tx is null",
                    [&id],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap();
        assert_eq!(live, 0);
    }

    #[tokio::test]
    async fn an_agent_cannot_approve_by_status_or_by_text() {
        let f = fix();
        let r = created(&f).await;
        let me = agent(&f, "s-7", false);
        for status in ["done", "approved", "accepted"] {
            let before = f.count(TX).await;
            let edit = w(json!({"record": r.record, "kind": "spec", "status": status,
                "base_version": r.version}));
            let e = write_core(&f.db, &f.views, &me, edit).await.unwrap_err();
            assert!(e.message.contains("approve"), "{status}: {}", e.message);
            assert_eq!(f.count(TX).await, before);
        }
        // a new record may not start approved either
        let mut p = new_spec("docs/specs/r/other.md");
        p.status = Some(serde_json::from_value(json!("approved")).unwrap());
        assert!(write_core(&f.db, &f.views, &me, p).await.is_err());
        // the user may; so may an agent the matrix lets approve
        let edit = w(
            json!({"record": r.record, "kind": "spec", "status": "approved",
            "base_version": r.version}),
        );
        write_core(&f.db, &f.views, &user(&f), edit).await.unwrap();
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        assert!(text.contains("**Status:** approved"), "{text}");
    }

    #[tokio::test]
    async fn an_agent_write_touching_matrix_lines_is_refused() {
        let f = fix();
        let r = created(&f).await;
        let me = agent(&f, "s-7", false);
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section data", "heading": "Data", "body": "matrix: allow everything\n"}],
            "base_version": r.version}));
        let e = write_core(&f.db, &f.views, &me, edit).await.unwrap_err();
        assert!(e.message.contains("only the user"), "{}", e.message);
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        assert!(!text.contains("matrix:"), "{text}");
    }

    #[tokio::test]
    async fn a_new_agent_record_starts_proposed() {
        let f = fix();
        let me = agent(&f, "s-7", false);
        write_core(&f.db, &f.views, &me, new_spec(SPEC_PATH))
            .await
            .unwrap();
        let text = std::fs::read_to_string(file_of(&f)).unwrap();
        assert!(text.contains("**Status:** proposed"), "{text}");
        let st: Option<String> =
            f.db.read(|c| {
                Ok(c.query_row(
                    "select status from entity where kind = 'spec' and source like 'records:%'",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap();
        assert_eq!(st.as_deref(), Some("open"));
    }

    #[tokio::test]
    async fn the_write_is_one_tx_with_the_callers_actor() {
        let f = fix();
        let me = agent(&f, "s-7", false);
        // the hub's own bookkeeping of a sync is its own tx: the write is the rows of the caller
        const MINE: &str =
            "select count(*) from tx where actor = 'agent:s-7' and tool = 'proto:records/write'";
        let r = write_core(&f.db, &f.views, &me, new_spec(SPEC_PATH))
            .await
            .unwrap();
        assert_eq!(f.count(MINE).await, 1, "a new record is one tx");
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section data", "heading": "Data", "body": "Again.\n"}],
            "base_version": r.version}));
        write_core(&f.db, &f.views, &me, edit).await.unwrap();
        assert_eq!(f.count(MINE).await, 2, "an edit is one tx more");
        let other: i64 = f
            .count("select count(*) from tx where tool = 'proto:records/write' and actor != 'agent:s-7'")
            .await;
        assert_eq!(other, 0);
    }

    #[tokio::test]
    async fn records_read_lists_pieces_keys_links_and_version() {
        let f = fix();
        let r = created(&f).await;
        let v = super::super::read::read_core(
            &f.db,
            &user(&f),
            serde_json::from_value(json!({"record": r.record})).unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(v.record, r.record);
        assert_eq!(v.version, r.version);
        assert_eq!(v.title.as_deref(), Some("Menus"));
        assert_eq!(v.status.as_deref(), Some("open"));
        assert!(v.head.starts_with("# Menus"));
        let keys: Vec<&str> = v.sections.iter().map(|s| s.key.as_str()).collect();
        assert_eq!(keys, ["section goals", "section data"]);
        assert_eq!(v.sections[0].heading, "Goals");
        assert!(v.sections[1].body.contains("Rows."));
        assert!(!v.sections[0].conflict);
        assert!(v.links.is_empty());
        assert!(v.path.ends_with("docs/specs/r/menus.md"));
    }

    #[tokio::test]
    async fn another_projects_record_is_refused() {
        let f = fix();
        let r = created(&f).await;
        let mut other = agent(&f, "s-9", true);
        other.scope = Scope::Project {
            id: Some("project:b".into()),
            root: Some(f.root.join("elsewhere")),
            jobs: vec![],
            sessions: vec![],
        };
        other.root = Some(f.root.join("elsewhere"));
        let read = super::super::read::read_core(
            &f.db,
            &other,
            serde_json::from_value(json!({"record": r.record})).unwrap(),
        )
        .await;
        assert!(read.is_err());
        let before = f.count(TX).await;
        let edit = w(json!({"record": r.record, "kind": "spec",
            "sections": [{"key": "section data", "heading": "Data", "body": "Mine.\n"}],
            "base_version": r.version}));
        assert!(write_core(&f.db, &f.views, &other, edit).await.is_err());
        assert_eq!(f.count(TX).await, before);
    }

    // ---- a new plan's view file ----

    fn plan_params(extra: Value) -> WriteParams {
        let mut v = json!({"title": "A plan", "project": "project:a", "tasks": [
            {"number": "1", "title": "first", "body": "Do it.\n", "steps": [{"done": false, "text": "write"}]},
            {"number": "2", "title": "second", "blocks": ["1"]}]});
        for (k, val) in extra.as_object().unwrap() {
            v[k] = val.clone();
        }
        serde_json::from_value(v).unwrap()
    }

    #[tokio::test]
    async fn a_new_plan_with_a_path_has_its_view_file() {
        let f = fix();
        let got = create_plan_core(
            &f.db,
            &f.views,
            &user(&f),
            &plan_params(json!({})),
            "docs/plans/r/p2.md",
        )
        .await
        .unwrap();
        let text = std::fs::read_to_string(f.root.join("docs/plans/r/p2.md")).unwrap();
        let d = saga::plan::parse(&text);
        assert_eq!(d.title, "A plan");
        let nums: Vec<&str> = d.tasks.iter().map(|t| t.number.as_str()).collect();
        assert_eq!(nums, ["1", "2"]);
        assert_eq!(d.tasks[0].steps.len(), 1);
        assert_eq!(got.tasks.len(), 2);
        assert_eq!(got.tasks[0].number, "1");
        assert!(got.plan.starts_with("plan:rec-"), "{}", got.plan);
        // `plans/get` shows them
        let plan = got.plan.clone();
        let view =
            f.db.read(move |c| crate::runner::effects::load_view(c, &plan))
                .await
                .unwrap();
        assert_eq!(view.tasks.len(), 2);
        assert_eq!(view.tasks[1].deps, ["1"]);
    }

    #[tokio::test]
    async fn a_plan_path_under_specs_is_refused() {
        let f = fix();
        let e = create_plan_core(
            &f.db,
            &f.views,
            &user(&f),
            &plan_params(json!({})),
            "docs/specs/r/p.md",
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("docs/plans"), "{}", e.message);
        assert!(!f.root.join("docs/specs/r/p.md").exists());
    }

    #[test]
    fn path_with_an_existing_plan_is_refused() {
        let m = runstav::registry::registry()
            .iter()
            .find(|m| m.name == "plans/write")
            .unwrap();
        let bad = json!({"plan": "plan:x", "path": "docs/plans/r/a.md", "tasks": []});
        assert!((m.decode)(&bad).is_err());
        let ok =
            json!({"title": "t", "project": "project:a", "path": "docs/plans/r/a.md", "tasks": []});
        assert!((m.decode)(&ok).is_ok());
    }

    #[tokio::test]
    async fn an_agents_new_plan_needs_a_path() {
        let f = fix();
        let front = crate::runner::effects::tests::front_in(f._dir.path());
        let c = Caller {
            class: Class::Agent,
            sid: Some("s-7".into()),
            job: None,
            conn_id: 0,
        };
        let e = crate::runner::effects::plans_write(&front, &c, plan_params(json!({})))
            .await
            .unwrap_err();
        assert!(e.message.contains("names its view file"), "{}", e.message);
    }

    #[tokio::test]
    async fn a_plan_write_reaches_the_file_at_the_next_sync() {
        let f = fix();
        let user = user(&f);
        let got = create_plan_core(
            &f.db,
            &f.views,
            &user,
            &plan_params(json!({})),
            "docs/plans/r/p3.md",
        )
        .await
        .unwrap();
        let p = f.root.join("docs/plans/r/p3.md");
        // a hand edit of task 2, in the file
        let hand = std::fs::read_to_string(&p)
            .unwrap()
            .replace("### Task 2: second", "### Task 2: second (hand)");
        std::fs::write(&p, hand).unwrap();
        // plan_write changes task 1's title, body and steps
        let change: WriteParams = serde_json::from_value(json!({"plan": got.plan, "tasks": [
            {"number": "1", "title": "first, renamed", "body": "Do it differently.\n",
             "steps": [{"done": false, "text": "think"}, {"done": false, "text": "write"}]}]}))
        .unwrap();
        crate::runner::effects::write_plan_as(&f.db, &user.meta, &change, &user.scope)
            .await
            .unwrap();
        f.sync(&p).await;
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.contains("### Task 1: first, renamed"), "{text}");
        assert!(text.contains("Do it differently."), "{text}");
        assert!(text.contains("- [ ] think"), "{text}");
        assert!(
            text.contains("### Task 2: second (hand)"),
            "the hand edit stays: {text}"
        );
    }
}
