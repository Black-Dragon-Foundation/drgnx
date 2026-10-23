//! Jobs (Task 6): `drgnx-coord-job-create` and `drgnx-coord-job-set` (`core/drgnx-coord.el`).

use super::event::{Event, EventKind, event};
use crate::read::tasks::opt;
use crate::store::{CoordError, Tx};
use serde_json::{Value, json};

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

/// Make the job, its tasks (`ID#N`) and their dependencies, at time NOW: the job's id (`drgnx-coord-job-create`).
pub fn job_create(tx: &Tx, j: NewJob, now: f64) -> Result<String, CoordError> {
    tx.execute(
        "insert into job values (?1, ?2, ?3, ?4, 'proposed', ?5, ?6)",
        (
            &j.id,
            &j.title,
            &j.plan,
            &j.repo,
            now,
            j.data.as_ref().map(Value::to_string),
        ),
    )?;
    for t in &j.tasks {
        let tid = format!("{}#{}", j.id, t.n);
        tx.execute(
            "insert into jtask (id, job, n, title, role, status) values (?1, ?2, ?3, ?4, ?5, ?6)",
            (
                &tid,
                &j.id,
                t.n,
                &t.title,
                &t.role,
                if t.deps.is_empty() {
                    "ready"
                } else {
                    "pending"
                },
            ),
        )?;
        for d in &t.deps {
            tx.execute(
                "insert into jdep values (?1, ?2)",
                (&tid, format!("{}#{d}", j.id)),
            )?;
        }
    }
    Ok(j.id)
}

/// Change job ID's STATUS and/or DATA.  A change of STATUS leaves a `job` event (`drgnx-coord-job-set`).
pub fn job_set(
    tx: &Tx,
    id: &str,
    status: Option<&str>,
    data: Option<&Value>,
    now: f64,
) -> Result<(), CoordError> {
    if let Some(status) = status {
        let old: Option<Option<String>> =
            opt(tx.query_row("select status from job where id = ?1", [id], |r| r.get(0)))?;
        tx.execute("update job set status = ?1 where id = ?2", (status, id))?;
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
        tx.execute(
            "update job set data = ?1 where id = ?2",
            (data.to_string(), id),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn a_job_with_dependencies_and_a_status_change() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        let task = |n, deps: &[i64]| NewTask {
            n,
            title: format!("t{n}"),
            role: None,
            deps: deps.to_vec(),
        };
        job_create(
            &c,
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
            let mut s = c.prepare("select status from jtask order by n").unwrap();
            s.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(st, ["ready", "pending"]);
        job_set(&c, "j", Some("running"), None, 6.0).unwrap();
        job_set(&c, "j", Some("running"), None, 7.0).unwrap();
        let n: i64 = c
            .query_row("select count(*) from event where kind = 'job'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(n, 1);
    }
}
