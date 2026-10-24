//! The report writer (agent system part 1, Task 4): what an agent ends a task with is an entity of kind `report`
//! (id `report:<prefix>-<5 base36>`) with a `report_of` link to its task.  `body` is the report's fields as the
//! `report_submit` tool checked them (commits, checks, decisions, differences, interfaces, followups).

use crate::store::{CoordError, WTx};
use serde_json::{Value, json};
use urdr::graph::entity::{self, EntityNew, Origin};
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
}
