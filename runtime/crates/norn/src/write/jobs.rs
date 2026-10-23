//! Jobs (Task 6; entities since Urdr Task 12): `drgnx-coord-job-create` and `drgnx-coord-job-set`
//! (`core/drgnx-coord.el`).  A job is a row of the kept `job` table; its tasks are entities `task:JOB#N` (call 5) with
//! `blocks` links from each dependency to the task that waits on it.

use super::event::{Event, EventKind, event};
use super::tasks::entity_id;
use crate::read::tasks::opt;
use crate::store::{CoordError, WTx};
use serde_json::{Value, json};
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::link;

/// One task of a new job; those without dependencies start `ready`, the rest `pending`.
#[derive(Debug, Clone)]
pub struct NewTask {
    pub n: i64,
    pub title: String,
    pub role: Option<String>,
    /// The numbers of the tasks (of the same job) this one waits on.
    pub deps: Vec<i64>,
}

#[derive(Debug, Clone)]
pub struct NewJob {
    pub id: String,
    pub title: String,
    pub plan: Option<String>,
    pub repo: Option<String>,
    pub tasks: Vec<NewTask>,
    /// Kept with the job (`drgnx-coord-job`'s data).
    pub data: Option<Value>,
}

/// Make the job, its tasks (`ID#N`, entities) and their dependencies (`blocks` links), at time NOW: the job's id
/// (`drgnx-coord-job-create`).  A dependency naming a task the job does not have is left out (a link needs both ends).
pub fn job_create(tx: &mut WTx<'_>, j: NewJob, now: f64) -> Result<String, CoordError> {
    let by = tx.id();
    tx.sql().execute(
        // the columns named: schema 7 adds `tx`
        "insert into job (id, title, plan, repo, status, created, data, tx) values (?1, ?2, ?3, ?4, 'proposed', ?5, ?6, ?7)",
        (
            &j.id,
            &j.title,
            &j.plan,
            &j.repo,
            now,
            j.data.as_ref().map(Value::to_string),
            by,
        ),
    )?;
    let project = tx.meta().project;
    let mut made: Vec<(i64, i64)> = Vec::new();
    for t in &j.tasks {
        let tid = format!("{}#{}", j.id, t.n);
        let e = entity::create(
            tx,
            EntityNew {
                id: entity_id(&tid),
                kind: "task".into(),
                project,
                title: Some(t.title.clone()),
                status: Some(if t.deps.is_empty() { "ready" } else { "pending" }.into()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({"job": j.id, "n": t.n, "role": t.role}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        made.push((t.n, e.n));
    }
    for t in &j.tasks {
        let Some(&(_, task)) = made.iter().find(|(n, _)| *n == t.n) else {
            continue;
        };
        for d in &t.deps {
            if let Some(&(_, dep)) = made.iter().find(|(n, _)| n == d) {
                link::add(tx, dep, "blocks", task, None, Origin::Recorded, None)?;
            }
        }
    }
    Ok(j.id)
}

/// Change job ID's STATUS and/or DATA.  A change of STATUS leaves a `job` event (`drgnx-coord-job-set`).
pub fn job_set(
    tx: &mut WTx<'_>,
    id: &str,
    status: Option<&str>,
    data: Option<&Value>,
    now: f64,
) -> Result<(), CoordError> {
    let by = tx.id();
    if let Some(status) = status {
        let old: Option<Option<String>> = opt(tx
            .sql()
            .query_row("select status from job where id = ?1", [id], |r| r.get(0)))?;
        tx.sql().execute(
            "update job set status = ?1, tx = ?3 where id = ?2",
            (status, id, by),
        )?;
        if let Some(old) = old.flatten()
            && old != status
        {
            event(
                tx,
                Event {
                    at: now,
                    agent: None,
                    job: Some(id.to_owned()),
                    task: None,
                    kind: EventKind::Job,
                    summary: format!("job {id}: {old} -> {status}"),
                    data: Some(json!({"status": status})),
                    turn: false,
                },
            )?;
        }
    }
    if let Some(data) = data {
        tx.sql().execute(
            "update job set data = ?1, tx = ?3 where id = ?2",
            (data.to_string(), id, by),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};

    #[test]
    fn a_job_with_dependencies_and_a_status_change() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let task = |n, deps: &[i64]| NewTask {
            n,
            title: format!("t{n}"),
            role: None,
            deps: deps.to_vec(),
        };
        job_create(
            &mut tx,
            NewJob {
                id: "j".into(),
                title: "J".into(),
                plan: None,
                repo: None,
                tasks: vec![task(1, &[]), task(2, &[1])],
                data: None,
            },
            5.0,
        )
        .unwrap();
        let st: Vec<String> = {
            let mut s = tx
                .sql()
                .prepare("select status from jtask order by n")
                .unwrap();
            s.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(st, ["ready", "pending"]);
        let deps: Vec<(String, String)> = {
            let mut s = tx.sql().prepare("select task, dep from jdep").unwrap();
            s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(deps, [("j#2".to_string(), "j#1".to_string())]);
        job_set(&mut tx, "j", Some("running"), None, 6.0).unwrap();
        job_set(&mut tx, "j", Some("running"), None, 7.0).unwrap();
        let n: i64 = tx
            .sql()
            .query_row("select count(*) from event where kind = 'job'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(n, 1);
    }
}
