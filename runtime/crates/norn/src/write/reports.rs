//! The report writer (agent system part 1, Task 4): what an agent ends a task with is an entity of kind `report`
//! (id `report:<prefix>-<5 base36>`) with a `report_of` link to its task.  `body` is the report's fields as the
//! `report_submit` tool checked them (commits, checks, decisions, differences, interfaces, followups).

use crate::store::{CoordError, WTx};
use runstav::methods::plans::ReportSubmit;
use serde_json::{Value, json};
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::link;

/// A report that is submitted.
#[derive(Clone, Debug, PartialEq)]
pub struct ReportNew {
    /// The task's entity id.
    pub task: String,
    pub session: Option<String>,
    pub agent: Option<String>,
    /// Seconds since the epoch.
    pub at: f64,
    /// The branch's tip commit.
    pub tip: String,
    /// A JSON object; its keys are kept as they are.
    pub body: Value,
}

/// Keep the report; answers its id.
pub fn submit(tx: &mut WTx<'_>, new: ReportNew) -> Result<String, CoordError> {
    let task = entity::by_id(tx.sql(), &new.task)?
        .filter(|e| e.kind == "task" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no task {}", new.task)))?;
    let Value::Object(mut data) = new.body else {
        return Err(CoordError::Refused("a report's body is an object".into()));
    };
    data.insert("task".into(), json!(new.task));
    data.insert("session".into(), json!(new.session));
    data.insert("agent".into(), json!(new.agent));
    data.insert("at".into(), json!(new.at));
    data.insert("tip".into(), json!(new.tip));
    let id = crate::tracker::new_id(tx, "report", task.project)?;
    let e = entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "report".into(),
            project: task.project,
            title: Some(format!("report on {}", new.task)),
            status: None,
            body: None,
            priority: None,
            assignee: new.agent,
            data: Value::Object(data),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    link::add(tx, e.n, "report_of", task.n, None, Origin::Recorded, None)?;
    Ok(id)
}

/// What [`file`] made.
#[derive(Clone, Debug, PartialEq)]
pub struct Filed {
    pub report: String,
    /// The follow-ups it filed (a `task`, or a `todo` for area `deferred`).
    pub followups: Vec<String>,
    /// Decisions the report lists that were never recorded.
    pub unrecorded: Vec<String>,
}

/// The decision entity a report's DECISION names (`12`, `#12`, `decision:12`), when it was recorded.
fn recorded(tx: &WTx<'_>, id: &str) -> Result<bool, CoordError> {
    let bare = id
        .trim()
        .trim_start_matches("decision:")
        .trim_start_matches('#');
    Ok(entity::by_id(tx.sql(), &format!("decision:{bare}"))?
        .is_some_and(|e| e.retired_tx.is_none()))
}

/// File report R of TASK (an entity id), written by AGENT: the `report` entity (its fields as `data`, so
/// `data.interfaces` is what briefs and `plan_read` read), a ledger note on the task, a follow-up per entry
/// (`discovered_from`), unrecorded decisions flagged, and the task `in-review`.
pub fn file(
    tx: &mut WTx<'_>,
    task: &str,
    agent: &str,
    session: Option<&str>,
    r: &ReportSubmit,
    now: f64,
) -> Result<Filed, CoordError> {
    let t = entity::by_id(tx.sql(), task)?
        .filter(|e| e.kind == "task" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no task {task}")))?;
    let mut unrecorded = Vec::new();
    for d in &r.decisions.0 {
        if !recorded(tx, d.id.as_str())? {
            unrecorded.push(d.id.as_str().to_owned());
        }
    }
    let mut followups = Vec::new();
    for f in &r.followups.0 {
        let area = f.area.as_ref().map(|a| a.as_str().to_owned());
        let todo = area.as_deref() == Some("deferred");
        let kind = if todo { "todo" } else { "task" };
        let id = crate::tracker::new_id(tx, kind, t.project)?;
        let e = entity::create(
            tx,
            EntityNew {
                id: id.clone(),
                kind: kind.into(),
                project: t.project,
                title: Some(f.title.as_str().to_owned()),
                status: Some("open".into()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({"area": area, "from_report_of": task}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        link::add(
            tx,
            e.n,
            if todo { "relates" } else { "discovered_from" },
            t.n,
            None,
            Origin::Recorded,
            None,
        )?;
        followups.push(id);
    }
    let body = json!({
        "commits": r.commits.0.iter().map(|c| c.as_str()).collect::<Vec<_>>(),
        "checks": r.checks.0.iter().map(|c| json!({"name": c.name.as_str(), "passed": c.passed, "failed": c.failed})).collect::<Vec<_>>(),
        "decisions": r.decisions.0.iter().map(|d| json!({"id": d.id.as_str(), "origin": d.origin})).collect::<Vec<_>>(),
        "differences": r.differences.as_ref().map(|d| d.as_str()),
        "interfaces": r.interfaces.as_ref().map(|d| d.as_str()),
        "followups": followups,
        "unrecorded": unrecorded,
    });
    let report = submit(
        tx,
        ReportNew {
            task: task.to_owned(),
            session: session.map(str::to_owned),
            agent: Some(agent.to_owned()),
            at: now,
            tip: r.tip.as_str().to_owned(),
            body,
        },
    )?;
    let passed: u64 = r.checks.0.iter().map(|c| c.passed).sum();
    let failed: u64 = r.checks.0.iter().map(|c| c.failed).sum();
    let mut text = format!(
        "{report}: tip {}, {} commits, checks {passed} passed / {failed} failed, {} follow-ups",
        r.tip.as_str(),
        r.commits.0.len(),
        followups.len()
    );
    if let Some(d) = &r.differences {
        text.push_str(&format!("\ndifferences: {}", d.as_str()));
    }
    if !unrecorded.is_empty() {
        text.push_str(&format!(
            "\nunrecorded decisions: {}",
            unrecorded.join(", ")
        ));
    }
    let note = crate::tracker::new_id(tx, "note", t.project)?;
    let n = entity::create(
        tx,
        EntityNew {
            id: note,
            kind: "note".into(),
            project: t.project,
            title: Some(format!("ledger: {task}")),
            status: None,
            body: Some(text),
            priority: None,
            assignee: None,
            data: json!({"label": "ledger", "report": report}),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    link::add(tx, n.n, "about", t.n, None, Origin::Recorded, None)?;
    let job_task =
        t.id.strip_prefix("task:")
            .filter(|_| t.data.get("job").is_some_and(|j| !j.is_null()));
    match job_task {
        Some(jt) => {
            let holder = t.lease.holder.clone().unwrap_or_else(|| agent.to_owned());
            super::tasks::force_status(tx, jt, "in-review", Some(&holder), now)?;
        }
        None => {
            entity::update(
                tx,
                t.n,
                None,
                Changes {
                    status: Some(Some("in-review".into())),
                    ..Changes::default()
                },
            )?;
        }
    }
    Ok(Filed {
        report,
        followups,
        unrecorded,
    })
}

/// The task entity id AGENT (or its session SID) works on: the one it holds, newest first.
pub fn task_of(tx: &WTx<'_>, agent: &str, sid: Option<&str>) -> Result<Option<String>, CoordError> {
    let sid = sid.unwrap_or(agent);
    Ok(tx
        .sql()
        .query_row(
            "select id from entity where kind = 'task' and retired_tx is null \
             and status in ('claimed', 'running', 'needs-input') \
             and (assignee in (?1, ?2) or lease_holder in (?1, ?2)) order by n desc limit 1",
            (agent, sid),
            |r| r.get(0),
        )
        .map(Some)
        .or_else(|e| match e {
            urdr::SqliteError::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};

    fn task(tx: &mut WTx<'_>, id: &str) {
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "task".into(),
                project: None,
                title: Some("t".into()),
                status: Some("open".into()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
    }

    #[test]
    fn a_report_links_its_task() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        task(&mut tx, "task:t-1");
        let new = ReportNew {
            task: "task:t-1".into(),
            session: Some("s1".into()),
            agent: Some("a1".into()),
            at: 5.0,
            tip: "abc".into(),
            body: json!({"commits": ["abc"], "interfaces": "fn x()"}),
        };
        let id = submit(&mut tx, new.clone()).unwrap();
        assert!(id.starts_with("report:"));
        let linked: String = tx
            .sql()
            .query_row(
                "select t.id from link l join entity r on r.n = l.src join entity t on t.n = l.dst \
                 where r.id = ?1 and l.kind = 'report_of' and l.tx_to = ?2",
                (&id, urdr::graph::schema::SENTINEL),
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(linked, "task:t-1");
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(e.data["tip"], "abc");
        assert_eq!(e.data["commits"][0], "abc");
        assert!(
            submit(
                &mut tx,
                ReportNew {
                    task: "task:none".into(),
                    ..new.clone()
                }
            )
            .is_err()
        );
        assert!(
            submit(
                &mut tx,
                ReportNew {
                    body: json!([1]),
                    ..new
                }
            )
            .is_err()
        );
    }

    fn rep(v: Value) -> ReportSubmit {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn report_schema_refuses_prose_blobs() {
        let blob = "x".repeat(2001);
        for bad in [
            json!({"tip": "abc", "differences": blob}),
            json!({"tip": "abc", "interfaces": blob}),
            json!({"tip": "abc", "notes": "free-form"}),
            json!({"tip": "abc", "followups": [{"title": blob}]}),
        ] {
            assert!(serde_json::from_value::<ReportSubmit>(bad).is_err());
        }
    }

    #[test]
    fn followups_become_tasks() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        task(&mut tx, "task:t-1");
        let r = rep(
            json!({"tip": "abc", "followups": [{"title": "more", "area": "ui"},
                           {"title": "later", "area": "deferred"}]}),
        );
        let f = file(&mut tx, "task:t-1", "a1", Some("s1"), &r, 5.0).unwrap();
        assert_eq!(f.followups.len(), 2);
        let (kind, from): (String, String) = tx
            .sql()
            .query_row(
                "select f.kind, t.id from link l join entity f on f.n = l.src join entity t on t.n = l.dst \
                 where l.kind = 'discovered_from' and l.tx_to = ?1",
                [urdr::graph::schema::SENTINEL],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((kind.as_str(), from.as_str()), ("task", "task:t-1"));
        let status: String = tx
            .sql()
            .query_row("select status from entity where id = 'task:t-1'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(status, "in-review");
        // the ledger note is about the task
        let notes: i64 = tx
            .sql()
            .query_row(
                "select count(*) from link l join entity n on n.n = l.src where l.kind = 'about' and n.kind = 'note'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(notes, 1);
    }

    #[test]
    fn unrecorded_decision_flagged() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        task(&mut tx, "task:t-1");
        entity::create(
            &mut tx,
            EntityNew {
                id: "decision:7".into(),
                kind: "decision".into(),
                project: None,
                title: Some("d".into()),
                status: Some("current".into()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
        let r = rep(json!({"tip": "abc", "decisions": [
            {"id": "7", "origin": "own"}, {"id": "99", "origin": "from-brief"}]}));
        let f = file(&mut tx, "task:t-1", "a1", None, &r, 5.0).unwrap();
        assert_eq!(f.unrecorded, vec!["99".to_owned()]);
        let e = entity::by_id(tx.sql(), &f.report).unwrap().unwrap();
        assert_eq!(e.data["unrecorded"][0], "99");
    }
}
