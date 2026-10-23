//! Tasks and leases (Task 6; entities since Urdr Task 12): `drgnx-coord-force-status`, `-claim`, `-heartbeat`,
//! `-renew`, `-release-stale` and `-set-status` (`core/drgnx-coord.el`).  Every function takes the time as NOW (seconds
//! since the epoch, as `float-time` gives) so a test can fix it.
//!
//! A job task is the entity `task:JOB#N` (call 5) with `data {job, n, role}`: its status is the entity's `status`, its
//! holder `assignee` and `lease_holder` (both), its lease `lease_until`, and every claim bumps `lease_epoch`, so the
//! fence is consistent from day one.  Each change is an entity update (a version, its `field_tx`).  The readers see
//! the tasks through the `jtask` and `jdep` views.

use super::decisions::{Held, held_check};
use super::event::{Event, EventKind, event};
use crate::read::tasks::{deps, label, task_job, task_row};
use crate::store::{CoordError, Tx, WTx};
use serde_json::json;
use urdr::graph::entity::{self, Changes, Ent, Lease};

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

/// The entity id of job task TASK (`JOB#N`).
pub fn entity_id(task: &str) -> String {
    format!("task:{task}")
}

/// Change job task TASK's entity as F says of its current row; false (nothing written) when there is no such job
/// task (a parsed or tracker task is no job task: its `data.job` is empty).
fn update_task(
    tx: &mut WTx<'_>,
    task: &str,
    f: impl FnOnce(&Ent) -> Changes,
) -> Result<bool, CoordError> {
    let Some(cur) = entity::by_id(tx.sql(), &entity_id(task))? else {
        return Ok(false);
    };
    if cur.retired_tx.is_some()
        || cur.kind != "task"
        || cur.data.get("job").is_none_or(|j| j.is_null())
    {
        return Ok(false);
    }
    entity::update(tx, cur.n, None, f(&cur))?;
    Ok(true)
}

/// The lease of CUR with a new HOLDER and UNTIL; the epoch goes up by one when BUMP.
fn lease_with(cur: &Ent, holder: Option<String>, until: Option<f64>, bump: bool) -> Lease {
    Lease {
        holder,
        epoch: cur.lease.epoch + i64::from(bump),
        until,
    }
}

fn status_event(
    tx: &mut WTx<'_>,
    now: f64,
    agent: Option<&str>,
    task: &str,
    status: &str,
) -> Result<(), CoordError> {
    let job = task_job(tx.sql(), task)?;
    let summary = format!(
        "{} -> {status}",
        label(tx.sql(), task)?.unwrap_or_else(|| "nil".into())
    );
    event(
        tx,
        Event {
            at: now,
            agent: agent.map(str::to_owned),
            job,
            task: Some(task.to_owned()),
            kind: EventKind::Status,
            summary,
            data: Some(json!({"status": status})),
            turn: false,
        },
    )?;
    Ok(())
}

/// The tasks that waited only on TASK become ready (`drgnx-coord--ready-dependents`).
fn ready_dependents(tx: &mut WTx<'_>, task: &str) -> Result<(), CoordError> {
    let waiting: Vec<String> = {
        let mut st = tx.sql().prepare("select task from jdep where dep = ?1")?;
        let rows = st.query_map([task], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    fn is_done(conn: &Tx, id: &str) -> Result<bool, CoordError> {
        Ok(task_row(conn, id)?.is_some_and(|r| r.status.as_deref() == Some("done")))
    }
    for w in waiting {
        let pending =
            task_row(tx.sql(), &w)?.is_some_and(|r| r.status.as_deref() == Some("pending"));
        if !pending {
            continue;
        }
        let mut all = true;
        for d in deps(tx.sql(), &w)? {
            all &= is_done(tx.sql(), &d)?;
        }
        if all {
            update_task(tx, &w, |_| Changes {
                status: Some(Some("ready".into())),
                ..Changes::default()
            })?;
        }
    }
    Ok(())
}

/// Set TASK's STATUS (and holder AGENT) as the job engine decides: no holder check; done readies its dependents
/// (`drgnx-coord-force-status`).
pub fn force_status(
    tx: &mut WTx<'_>,
    task: &str,
    status: &str,
    agent: Option<&str>,
    now: f64,
) -> Result<bool, CoordError> {
    let until = (agent.is_some() && ACTIVE.contains(&status)).then(|| lease(now));
    update_task(tx, task, |cur| {
        let holder = agent.map(str::to_owned);
        let bump = holder.is_some() && holder != cur.lease.holder;
        Changes {
            status: Some(Some(status.to_owned())),
            assignee: Some(holder.clone()),
            lease: Some(lease_with(cur, holder, until, bump)),
            ..Changes::default()
        }
    })?;
    if label(tx.sql(), task)?.is_some() {
        status_event(tx, now, agent, task, status)?;
    }
    if status == "done" {
        ready_dependents(tx, task)?;
    }
    Ok(true)
}

/// AGENT claims TASK, having read the log at version SEEN (`drgnx-coord-claim`).  A claim bumps the lease epoch, a
/// renewal by the holder included.
pub fn claim(
    tx: &mut WTx<'_>,
    task: &str,
    agent: &str,
    seen: Option<u64>,
    now: f64,
) -> Result<ClaimResult, CoordError> {
    if let Some(h) = held_check(tx.sql(), seen)? {
        return Ok(ClaimResult::Held(h));
    }
    let Some(row) = task_row(tx.sql(), task)? else {
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
        for d in deps(tx.sql(), task)? {
            let done = task_row(tx.sql(), &d)?.is_some_and(|r| r.status.as_deref() == Some("done"));
            if !done {
                open.push(d);
            }
        }
        return Ok(ClaimResult::NotReady(open));
    }
    if status == Some("ready") || holder == Some(agent) {
        update_task(tx, task, |cur| Changes {
            status: (cur.status.as_deref() == Some("ready")).then(|| Some("claimed".to_owned())),
            assignee: Some(Some(agent.to_owned())),
            lease: Some(lease_with(
                cur,
                Some(agent.to_owned()),
                Some(lease(now)),
                true,
            )),
            ..Changes::default()
        })?;
        if status == Some("ready") {
            // a renewal by the holder changes nothing: no event
            let job = task_job(tx.sql(), task)?;
            let summary = format!("claimed {}", label(tx.sql(), task)?.unwrap_or_default());
            event(
                tx,
                Event {
                    at: now,
                    agent: Some(agent.to_owned()),
                    job,
                    task: Some(task.to_owned()),
                    kind: EventKind::Claim,
                    summary,
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
pub fn heartbeat(tx: &mut WTx<'_>, task: &str, agent: &str, now: f64) -> Result<(), CoordError> {
    update_task(tx, task, |cur| {
        if cur.assignee.as_deref() != Some(agent) {
            return Changes::default();
        }
        Changes {
            lease: Some(lease_with(
                cur,
                cur.assignee.clone(),
                Some(lease(now)),
                false,
            )),
            ..Changes::default()
        }
    })?;
    Ok(())
}

/// AGENT is alive: every claim it holds is renewed (`drgnx-coord-renew`).
pub fn renew(tx: &mut WTx<'_>, agent: &str, now: f64) -> Result<(), CoordError> {
    let ids: Vec<String> = {
        let mut st = tx.sql().prepare(
            "select id from jtask where agent = ?1 and status in ('claimed', 'running')",
        )?;
        let rows = st.query_map([agent], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    for id in ids {
        heartbeat(tx, &id, agent, now)?;
    }
    Ok(())
}

/// Release the claims whose lease ran out (`drgnx-coord-release-stale`).  A task waiting on the user (`needs-input`,
/// `in-review`) keeps its claim: the wait is the user's, not the agent's.
pub fn release_stale(tx: &mut WTx<'_>, now: f64) -> Result<Vec<Released>, CoordError> {
    let rows: Vec<(String, Option<String>, Option<String>)> = {
        let mut st = tx.sql().prepare(
            "select id, agent, job from jtask where lease_until < ?1 and status in ('claimed', 'running')",
        )?;
        let rows = st.query_map([now], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    let mut out = Vec::new();
    for (task, agent, job) in rows {
        update_task(tx, &task, |cur| Changes {
            status: Some(Some("ready".into())),
            assignee: Some(None),
            lease: Some(lease_with(cur, None, None, false)),
            ..Changes::default()
        })?;
        let summary = format!(
            "lease ran out: {}",
            label(tx.sql(), &task)?.unwrap_or_else(|| "nil".into())
        );
        event(
            tx,
            Event {
                at: now,
                agent: agent.clone(),
                job: job.clone(),
                task: Some(task.clone()),
                kind: EventKind::Release,
                summary,
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
    tx: &mut WTx<'_>,
    task: &str,
    agent: &str,
    status: &str,
    seen: Option<u64>,
    now: f64,
) -> Result<ClaimResult, CoordError> {
    if let Some(h) = held_check(tx.sql(), seen)? {
        return Ok(ClaimResult::Held(h));
    }
    let Some(row) = task_row(tx.sql(), task)? else {
        return Ok(ClaimResult::Error(format!("no task {task}")));
    };
    match row.agent.as_deref() {
        None => Ok(ClaimResult::Error(format!(
            "task {task} is not claimed (claim it first)"
        ))),
        Some(h) if h != agent => Ok(ClaimResult::Taken(h.to_owned())),
        Some(_) => {
            let until = ACTIVE.contains(&status).then(|| lease(now));
            update_task(tx, task, |cur| Changes {
                status: Some(Some(status.to_owned())),
                lease: Some(lease_with(cur, cur.lease.holder.clone(), until, false)),
                ..Changes::default()
            })?;
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
    use crate::store::tests::{db7, tx_of};
    use crate::write::jobs::{NewJob, NewTask, job_create};

    /// A job `j` with tasks `j#1` (ready) and `j#2` (waits on `j#1`).
    fn job(tx: &mut WTx<'_>) {
        let task = |n, deps: &[i64]| NewTask {
            n,
            title: format!("t{n}"),
            role: None,
            deps: deps.to_vec(),
        };
        job_create(
            tx,
            NewJob {
                id: "j".into(),
                title: "J".into(),
                plan: None,
                repo: None,
                tasks: vec![task(1, &[]), task(2, &[1])],
                data: None,
            },
            1.0,
        )
        .unwrap();
    }

    fn status(tx: &WTx<'_>, id: &str) -> String {
        tx.sql()
            .query_row("select status from jtask where id = ?1", [id], |r| r.get(0))
            .unwrap()
    }

    fn lease_of(tx: &WTx<'_>, id: &str) -> (Option<String>, i64, Option<f64>) {
        tx.sql()
            .query_row(
                "select lease_holder, lease_epoch, lease_until from entity where id = ?1",
                [entity_id(id)],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap()
    }

    #[test]
    fn claim_work_done_readies_the_dependent() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx);
        assert_eq!(
            claim(&mut tx, "j#2", "a", None, 10.0).unwrap(),
            ClaimResult::NotReady(vec!["j#1".into()])
        );
        assert_eq!(
            claim(&mut tx, "j#1", "a", None, 10.0).unwrap(),
            ClaimResult::Ok
        );
        assert_eq!(
            claim(&mut tx, "j#1", "b", None, 11.0).unwrap(),
            ClaimResult::Taken("a".into())
        );
        assert_eq!(
            set_status(&mut tx, "j#1", "a", "done", None, 12.0).unwrap(),
            ClaimResult::Ok
        );
        assert_eq!(status(&tx, "j#2"), "ready");
    }

    #[test]
    fn in_review_keeps_its_claim_when_the_lease_ends() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx);
        claim(&mut tx, "j#1", "a", None, 10.0).unwrap();
        set_status(&mut tx, "j#1", "a", "in-review", None, 10.0).unwrap();
        assert!(release_stale(&mut tx, 10_000.0).unwrap().is_empty());
        set_status(&mut tx, "j#1", "a", "running", None, 10.0).unwrap();
        let released = release_stale(&mut tx, 10_000.0).unwrap();
        assert_eq!(released.len(), 1);
        assert_eq!(status(&tx, "j#1"), "ready");
    }

    #[test]
    fn a_claim_fills_the_lease_and_bumps_the_epoch() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx);
        claim(&mut tx, "j#1", "a", None, 10.0).unwrap();
        assert_eq!(
            lease_of(&tx, "j#1"),
            (Some("a".into()), 1, Some(10.0 + LEASE_SECS))
        );
        // a renewal by the holder is a claim again: the epoch moves, so a reconnecting session never reuses one
        claim(&mut tx, "j#1", "a", None, 20.0).unwrap();
        assert_eq!(lease_of(&tx, "j#1").1, 2);
        heartbeat(&mut tx, "j#1", "a", 30.0).unwrap();
        assert_eq!(lease_of(&tx, "j#1").2, Some(30.0 + LEASE_SECS));
        assert_eq!(lease_of(&tx, "j#1").1, 2);
        // released: no holder, the epoch kept for the next claim to move on
        release_stale(&mut tx, 100_000.0).unwrap();
        assert_eq!(lease_of(&tx, "j#1"), (None, 2, None));
        claim(&mut tx, "j#1", "b", None, 100_001.0).unwrap();
        assert_eq!(lease_of(&tx, "j#1").1, 3);
    }

    #[test]
    fn every_change_is_a_version_with_its_tx() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx);
        claim(&mut tx, "j#1", "a", None, 10.0).unwrap();
        let (ver, status_tx): (i64, i64) = tx
            .sql()
            .query_row(
                "select ver, json_extract(field_tx, '$.status') from entity where id = 'task:j#1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(ver, 2);
        assert_eq!(status_tx, tx.id());
    }
}
