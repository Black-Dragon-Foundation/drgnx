//! Tasks and leases (Task 6): `drgnx-coord-force-status`, `-claim`, `-heartbeat`, `-renew`, `-release-stale` and
//! `-set-status` (`core/drgnx-coord.el`).  Every function takes the time as NOW (seconds since the epoch, as
//! `float-time` gives) so a test can fix it.

use super::decisions::{Held, held_check};
use super::event::{Event, EventKind, event};
use crate::read::tasks::{deps, label, task_job, task_row};
use crate::store::{CoordError, Tx};
use serde_json::json;

/// Task statuses that belong to an agent (`drgnx-coord--active`).
pub const ACTIVE: [&str; 4] = ["claimed", "running", "needs-input", "in-review"];
/// A claim not renewed for this long is released (`drgnx-coord-lease-minutes`, in seconds).
pub const LEASE_SECS: f64 = 15.0 * 60.0;

fn lease(now: f64) -> f64 {
    now + LEASE_SECS
}

/// The answer of `claim` and `set_status`.
#[derive(Debug, Clone, PartialEq)]
pub enum ClaimResult {
    Ok,
    /// The log moved on since the agent read it.
    Held(Held),
    /// Another agent holds the task.
    Taken(String),
    /// The dependencies not yet done.
    NotReady(Vec<String>),
    Error(String),
}

/// A task whose lease ran out and was released.
#[derive(Debug, Clone, PartialEq)]
pub struct Released {
    pub task: String,
    pub agent: Option<String>,
    pub job: Option<String>,
}

fn status_event(
    tx: &Tx,
    now: f64,
    agent: Option<&str>,
    task: &str,
    status: &str,
) -> Result<(), CoordError> {
    event(
        tx,
        Event {
            at: now,
            agent: agent.map(str::to_owned),
            job: task_job(tx, task)?,
            task: Some(task.to_owned()),
            kind: EventKind::Status,
            summary: format!(
                "{} -> {status}",
                label(tx, task)?.unwrap_or_else(|| "nil".into())
            ),
            data: Some(json!({"status": status})),
            turn: false,
        },
    )?;
    Ok(())
}

/// The tasks that waited only on TASK become ready (`drgnx-coord--ready-dependents`).
fn ready_dependents(tx: &Tx, task: &str) -> Result<(), CoordError> {
    let waiting: Vec<String> = {
        let mut st = tx.prepare("select task from jdep where dep = ?1")?;
        let rows = st.query_map([task], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    let is_done = |id: &str| -> Result<bool, CoordError> {
        Ok(task_row(tx, id)?.is_some_and(|r| r.status.as_deref() == Some("done")))
    };
    for w in waiting {
        let pending = task_row(tx, &w)?.is_some_and(|r| r.status.as_deref() == Some("pending"));
        if !pending {
            continue;
        }
        let mut all = true;
        for d in deps(tx, &w)? {
            all &= is_done(&d)?;
        }
        if all {
            tx.execute("update jtask set status = 'ready' where id = ?1", [&w])?;
        }
    }
    Ok(())
}

/// Set TASK's STATUS (and holder AGENT) as the job engine decides: no holder check; done readies its dependents
/// (`drgnx-coord-force-status`).
pub fn force_status(
    tx: &Tx,
    task: &str,
    status: &str,
    agent: Option<&str>,
    now: f64,
) -> Result<bool, CoordError> {
    let until = (agent.is_some() && ACTIVE.contains(&status)).then(|| lease(now));
    tx.execute(
        "update jtask set status = ?1, agent = ?2, lease_until = ?3 where id = ?4",
        (status, agent, until, task),
    )?;
    if label(tx, task)?.is_some() {
        status_event(tx, now, agent, task, status)?;
    }
    if status == "done" {
        ready_dependents(tx, task)?;
    }
    Ok(true)
}

/// AGENT claims TASK, having read the log at version SEEN (`drgnx-coord-claim`).
pub fn claim(
    tx: &Tx,
    task: &str,
    agent: &str,
    seen: Option<u64>,
    now: f64,
) -> Result<ClaimResult, CoordError> {
    if let Some(h) = held_check(tx, seen)? {
        return Ok(ClaimResult::Held(h));
    }
    let Some(row) = task_row(tx, task)? else {
        return Ok(ClaimResult::Error(format!("no task {task}")));
    };
    let status = row.status.as_deref();
    let holder = row.agent.as_deref();
    if let Some(h) = holder
        && status.is_some_and(|s| ACTIVE.contains(&s))
        && h != agent
    {
        return Ok(ClaimResult::Taken(h.to_owned()));
    }
    if status == Some("pending") {
        let mut open = Vec::new();
        for d in deps(tx, task)? {
            let done = task_row(tx, &d)?.is_some_and(|r| r.status.as_deref() == Some("done"));
            if !done {
                open.push(d);
            }
        }
        return Ok(ClaimResult::NotReady(open));
    }
    if status == Some("ready") || holder == Some(agent) {
        tx.execute(
            "update jtask set status = (case when status = 'ready' then 'claimed' else status end), \
             agent = ?1, lease_until = ?2 where id = ?3",
            (agent, lease(now), task),
        )?;
        if status == Some("ready") {
            // a renewal by the holder changes nothing: no event
            event(
                tx,
                Event {
                    at: now,
                    agent: Some(agent.to_owned()),
                    job: task_job(tx, task)?,
                    task: Some(task.to_owned()),
                    kind: EventKind::Claim,
                    summary: format!("claimed {}", label(tx, task)?.unwrap_or_default()),
                    data: None,
                    turn: false,
                },
            )?;
        }
        return Ok(ClaimResult::Ok);
    }
    Ok(ClaimResult::Error(format!(
        "task {task} is {}",
        status.unwrap_or("nil")
    )))
}

/// AGENT still works on TASK: its lease is renewed (`drgnx-coord-heartbeat`).
pub fn heartbeat(tx: &Tx, task: &str, agent: &str, now: f64) -> Result<(), CoordError> {
    tx.execute(
        "update jtask set lease_until = ?1 where id = ?2 and agent = ?3",
        (lease(now), task, agent),
    )?;
    Ok(())
}

/// AGENT is alive: every claim it holds is renewed (`drgnx-coord-renew`).
pub fn renew(tx: &Tx, agent: &str, now: f64) -> Result<(), CoordError> {
    tx.execute(
        "update jtask set lease_until = ?1 where agent = ?2 and status in ('claimed', 'running')",
        (lease(now), agent),
    )?;
    Ok(())
}

/// Release the claims whose lease ran out (`drgnx-coord-release-stale`).  A task waiting on the user (`needs-input`,
/// `in-review`) keeps its claim: the wait is the user's, not the agent's.
pub fn release_stale(tx: &Tx, now: f64) -> Result<Vec<Released>, CoordError> {
    let rows: Vec<(String, Option<String>, Option<String>)> = {
        let mut st = tx.prepare(
            "select id, agent, job from jtask where lease_until < ?1 and status in ('claimed', 'running')",
        )?;
        let rows = st.query_map([now], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    let mut out = Vec::new();
    for (task, agent, job) in rows {
        tx.execute(
            "update jtask set status = 'ready', agent = null, lease_until = null where id = ?1",
            [&task],
        )?;
        event(
            tx,
            Event {
                at: now,
                agent: agent.clone(),
                job: job.clone(),
                task: Some(task.clone()),
                kind: EventKind::Release,
                summary: format!(
                    "lease ran out: {}",
                    label(tx, &task)?.unwrap_or_else(|| "nil".into())
                ),
                data: None,
                turn: false,
            },
        )?;
        out.push(Released { task, agent, job });
    }
    Ok(out)
}

/// AGENT (TASK's holder) sets TASK's STATUS, having read the log at SEEN.  Done readies the tasks that waited only
/// on it (`drgnx-coord-set-status`).
pub fn set_status(
    tx: &Tx,
    task: &str,
    agent: &str,
    status: &str,
    seen: Option<u64>,
    now: f64,
) -> Result<ClaimResult, CoordError> {
    if let Some(h) = held_check(tx, seen)? {
        return Ok(ClaimResult::Held(h));
    }
    let Some(row) = task_row(tx, task)? else {
        return Ok(ClaimResult::Error(format!("no task {task}")));
    };
    match row.agent.as_deref() {
        None => Ok(ClaimResult::Error(format!(
            "task {task} is not claimed (claim it first)"
        ))),
        Some(h) if h != agent => Ok(ClaimResult::Taken(h.to_owned())),
        Some(_) => {
            let until = ACTIVE.contains(&status).then(|| lease(now));
            tx.execute(
                "update jtask set status = ?1, lease_until = ?2 where id = ?3",
                (status, until, task),
            )?;
            status_event(tx, now, Some(agent), task, status)?;
            if status == "done" {
                ready_dependents(tx, task)?;
            }
            Ok(ClaimResult::Ok)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    fn db() -> urdr::Connection {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into jtask (id, job, n, title, status) values ('j#1', 'j', 1, 'one', 'ready');
             insert into jtask (id, job, n, title, status) values ('j#2', 'j', 2, 'two', 'pending');
             insert into jdep values ('j#2', 'j#1');",
        )
        .unwrap();
        c
    }

    fn status(c: &urdr::Connection, id: &str) -> String {
        c.query_row("select status from jtask where id = ?1", [id], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn claim_work_done_readies_the_dependent() {
        let c = db();
        assert_eq!(
            claim(&c, "j#2", "a", None, 10.0).unwrap(),
            ClaimResult::NotReady(vec!["j#1".into()])
        );
        assert_eq!(
            claim(&c, "j#1", "a", None, 10.0).unwrap(),
            ClaimResult::Ok
        );
        assert_eq!(
            claim(&c, "j#1", "b", None, 11.0).unwrap(),
            ClaimResult::Taken("a".into())
        );
        assert_eq!(
            set_status(&c, "j#1", "a", "done", None, 12.0).unwrap(),
            ClaimResult::Ok
        );
        assert_eq!(status(&c, "j#2"), "ready");
    }

    #[test]
    fn in_review_keeps_its_claim_when_the_lease_ends() {
        let c = db();
        claim(&c, "j#1", "a", None, 10.0).unwrap();
        set_status(&c, "j#1", "a", "in-review", None, 10.0).unwrap();
        assert!(release_stale(&c, 10_000.0).unwrap().is_empty());
        set_status(&c, "j#1", "a", "running", None, 10.0).unwrap();
        let released = release_stale(&c, 10_000.0).unwrap();
        assert_eq!(released.len(), 1);
        assert_eq!(status(&c, "j#1"), "ready");
    }
}
