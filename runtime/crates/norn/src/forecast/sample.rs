//! Forecast samples: one row per finished task, derived from the `step` and `spend` tables (docs/develop/hub.md,
//! "Forecasts").
//!
//! A task is sampled when it is `done` or `dropped`, every step of it has closed, and no sample covers its newest
//! step.  Every step with `task = T` counts, whichever session wrote it and whatever a rewind marked: spent is spent.
//! A finished job's manager has no task, so its steps make one row keyed `JOB#manager`.  The rows hold numbers and
//! ids only; a brief is kept as its length.

use crate::read::tasks::opt;
use crate::store::{CoordError, Tx, WTx};
use serde_json::Value;

/// One finished task (or a job's manager) as the forecast sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct SampleRow {
    pub task: String,
    pub job: String,
    pub project: Option<String>,
    pub role: String,
    pub profile: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub brief_bytes: i64,
    /// How many tasks a `manager` row covers, else 1.
    pub tasks: i64,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub turns: i64,
    pub active_secs: f64,
    pub wall_secs: f64,
    pub job_wait_secs: f64,
    pub wakes: i64,
    pub cold_wakes: i64,
    pub context: Option<i64>,
    pub cost: Option<f64>,
    pub cost_unit: Option<String>,
    pub outcome: String,
    pub last_step: i64,
    pub at: f64,
}

/// What the hub knows of a profile that the store does not.
pub struct ProfileFacts {
    pub model: Option<String>,
    pub ttl_secs: f64,
}

/// What a forecast said of a task (`JOB#N`) or a plan (`JOB`) when the job was proposed.
#[derive(Clone, Debug, PartialEq)]
pub struct Made {
    pub job: String,
    pub task: String,
    pub made_at: f64,
    pub role: Option<String>,
    pub profile: Option<String>,
    pub model: Option<String>,
    pub tokens_p50: f64,
    pub tokens_p90: f64,
    pub secs_p50: f64,
    pub secs_p90: f64,
    pub cost_p50: Option<f64>,
    pub cost_p90: Option<f64>,
    pub cost_unit: Option<String>,
    pub basis: String,
    pub n: i64,
}

const MANAGER: &str = "#manager";

/// The finished jobs whose manager steps no sample covers yet, `?1` at most.  The sweep runs it every tick, so each
/// job's managers are looked up through `entity_manager_job` (migration 11): the terms are the index's own, and the
/// job id is compared as `+j.id`, with no affinity, which an expression index needs to be searched; then their steps
/// through `step_session`.  Nothing reads the whole entity table.
const MANAGER_DUE: &str = "select j.id || '#manager' from job j \
     where j.status in ('done', 'stopped') \
       and exists (select 1 from entity e join step s on s.session = e.id \
                   where json_extract(e.data, '$.job') = +j.id \
                     and json_extract(e.data, '$.role') = 'manager' and e.retired_tx is null \
                     and s.turn_id is not null) \
       and not exists (select 1 from entity e join step s on s.session = e.id \
                       where json_extract(e.data, '$.job') = +j.id \
                         and json_extract(e.data, '$.role') = 'manager' and e.retired_tx is null \
                         and s.end is null) \
       and coalesce((select max(s.id) from entity e join step s on s.session = e.id \
                     where json_extract(e.data, '$.job') = +j.id \
                       and json_extract(e.data, '$.role') = 'manager' and e.retired_tx is null), 0) \
           > coalesce((select f.last_step from forecast_sample f where f.task = j.id || '#manager'), 0) \
     order by j.id limit ?1";

/// Up to LIMIT keys to (re)sample: finished tasks with closed steps and no sample covering their newest step, and
/// finished jobs whose manager steps are not covered.
pub fn due(conn: &Tx, limit: i64) -> Result<Vec<String>, CoordError> {
    let mut out: Vec<String> = {
        let mut st = conn.prepare(
            "select t.id from jtask t \
             where t.status in ('done', 'dropped') \
               and exists (select 1 from step s where s.task = t.id and s.turn_id is not null) \
               and not exists (select 1 from step s where s.task = t.id and s.end is null) \
               and coalesce((select f.last_step from forecast_sample f where f.task = t.id), 0) \
                   < (select max(s.id) from step s where s.task = t.id) \
             order by t.id limit ?1",
        )?;
        let rows = st.query_map([limit], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    let room = limit - i64::try_from(out.len()).unwrap_or(limit);
    if room > 0 {
        let mut st = conn.prepare(MANAGER_DUE)?;
        let rows = st.query_map([room], |r| r.get::<_, String>(0))?;
        for r in rows {
            out.push(r?);
        }
    }
    Ok(out)
}

/// A step as the sample reads it.
struct S {
    id: i64,
    session: String,
    class: String,
    start: f64,
    end: Option<f64>,
    provider: Option<String>,
    project: Option<String>,
    turn: Option<String>,
    tokens_in: i64,
    tokens_out: i64,
    cache_read: i64,
    cache_write: i64,
    cost: Option<f64>,
    cost_unit: Option<String>,
    context: Option<i64>,
}

fn steps_where(conn: &Tx, filter: &str, key: &str) -> Result<Vec<S>, CoordError> {
    let mut st = conn.prepare(&format!(
        "select id, session, class, start, end, provider, project, turn_id, tokens_in, tokens_out, cache_read, \
         cache_write, cost, cost_unit, context from step where {filter} order by id"
    ))?;
    let rows = st.query_map([key], |r| {
        Ok(S {
            id: r.get(0)?,
            session: r.get(1)?,
            class: r.get(2)?,
            start: r.get(3)?,
            end: r.get(4)?,
            provider: r.get(5)?,
            project: r.get(6)?,
            turn: r.get(7)?,
            tokens_in: r.get(8)?,
            tokens_out: r.get(9)?,
            cache_read: r.get(10)?,
            cache_write: r.get(11)?,
            cost: r.get(12)?,
            cost_unit: r.get(13)?,
            context: r.get(14)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// `(profile, review)` of session entity ID: its profile, and whether it reviews the task (the runner marks it).
fn session_facts(conn: &Tx, id: &str) -> Result<(Option<String>, bool), CoordError> {
    Ok(opt(conn.query_row(
        "select json_extract(data, '$.profile'), coalesce(json_extract(data, '$.review'), 0) from entity \
         where id = ?1 and retired_tx is null",
        [id],
        |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)),
    ))?
    .unwrap_or((None, false)))
}

/// The step of STEPS whose session did the task: the last one of a session that is no review (a reviewer's steps
/// count on the task, but the task's class is its worker's), else the last.
fn worker_step<'a>(conn: &Tx, steps: &'a [S]) -> Result<(&'a S, Option<String>), CoordError> {
    let mut seen: Option<&str> = None;
    for s in steps.iter().rev() {
        if seen == Some(s.session.as_str()) {
            continue;
        }
        seen = Some(&s.session);
        let (profile, review) = session_facts(conn, &s.session)?;
        if !review {
            return Ok((s, profile));
        }
    }
    let last = steps.last().expect("a task with steps");
    Ok((last, session_facts(conn, &last.session)?.0))
}

/// The sample of TASK (`JOB#N`, or `JOB#manager`) from its steps and the gateway's spend; `None` when it has no
/// steps, a step still open, no turn, or is no task of a job.  FACTS gives a profile's model and cache TTL.
pub fn gather(
    conn: &Tx,
    task: &str,
    facts: &dyn Fn(Option<&str>, &str) -> ProfileFacts,
) -> Result<Option<SampleRow>, CoordError> {
    let manager_of = task.strip_suffix(MANAGER);
    let (job, steps, role, outcome, tasks, n) = if let Some(job) = manager_of {
        let steps = steps_where(
            conn,
            "session in (select id from entity where retired_tx is null \
             and json_extract(data, '$.role') = 'manager' and json_extract(data, '$.job') = ?1)",
            job,
        )?;
        let count: i64 =
            conn.query_row("select count(*) from jtask where job = ?1", [job], |r| {
                r.get(0)
            })?;
        (
            job.to_string(),
            steps,
            "manager".to_string(),
            "done".to_string(),
            count,
            None,
        )
    } else {
        let Some(row) = crate::read::tasks::task_row(conn, task)? else {
            return Ok(None);
        };
        let job: Option<String> =
            conn.query_row("select job from jtask where id = ?1", [task], |r| r.get(0))?;
        let steps = steps_where(conn, "task = ?1", task)?;
        (
            job.unwrap_or_default(),
            steps,
            row.role.unwrap_or_else(|| "task".into()),
            row.status.unwrap_or_default(),
            1,
            Some(row.n),
        )
    };
    let Some(last) = steps.last() else {
        return Ok(None);
    };
    if steps.iter().any(|s| s.end.is_none()) {
        return Ok(None);
    }
    let turns = steps
        .iter()
        .filter_map(|s| s.turn.as_deref())
        .collect::<std::collections::BTreeSet<_>>()
        .len() as i64;
    if turns == 0 {
        return Ok(None);
    }
    let (worker, profile) = worker_step(conn, &steps)?;
    let f = facts(profile.as_deref(), &role);
    let secs = |s: &S| s.end.map_or(0.0, |e| (e - s.start).max(0.0));
    let sum_class = |classes: &[&str]| -> f64 {
        steps
            .iter()
            .filter(|s| classes.contains(&s.class.as_str()))
            .map(secs)
            .sum()
    };
    let first = steps.iter().map(|s| s.start).fold(f64::INFINITY, f64::min);
    let end = steps
        .iter()
        .filter_map(|s| s.end)
        .fold(f64::NEG_INFINITY, f64::max);
    let waits: Vec<f64> = steps
        .iter()
        .filter(|s| s.class == "job-wait")
        .map(secs)
        .collect();
    let (cost, cost_unit) = if manager_of.is_some() {
        (None, None)
    } else {
        let spent = crate::read::spend::spend_sum(conn, None, Some(task), None)?;
        if spent.requests > 0 {
            (Some(spent.cost), Some("usd".to_string()))
        } else {
            let est: Vec<f64> = steps
                .iter()
                .filter(|s| s.cost_unit.as_deref() == Some("usd-est"))
                .filter_map(|s| s.cost)
                .collect();
            if est.is_empty() {
                (None, None)
            } else {
                (Some(est.iter().sum()), Some("usd-est".to_string()))
            }
        }
    };
    let brief_bytes = match (n, manager_of) {
        (Some(n), None) => brief_len(conn, &job, n)?,
        _ => 0,
    };
    Ok(Some(SampleRow {
        task: task.to_string(),
        job,
        project: last.project.clone(),
        role,
        profile,
        provider: worker.provider.clone(),
        model: f.model,
        brief_bytes,
        tasks,
        tokens_in: steps.iter().map(|s| s.tokens_in).sum(),
        tokens_out: steps.iter().map(|s| s.tokens_out).sum(),
        cache_read: steps.iter().map(|s| s.cache_read).sum(),
        cache_write: steps.iter().map(|s| s.cache_write).sum(),
        turns,
        active_secs: sum_class(&["think", "tool"]),
        wall_secs: (end - first - sum_class(&["user-wait", "paused"])).max(0.0),
        job_wait_secs: waits.iter().sum(),
        wakes: waits.len() as i64,
        cold_wakes: waits.iter().filter(|w| **w > f.ttl_secs).count() as i64,
        context: steps.iter().rev().find_map(|s| s.context),
        cost,
        cost_unit,
        outcome,
        last_step: steps.iter().map(|s| s.id).max().unwrap_or(0),
        at: end,
    }))
}

/// The byte length of task N's brief in JOB's data (0 when there is none).
fn brief_len(conn: &Tx, job: &str, n: i64) -> Result<i64, CoordError> {
    let data: Option<String> =
        opt(conn.query_row("select data from job where id = ?1", [job], |r| r.get(0)))?.flatten();
    let Some(Value::Object(m)) = data.and_then(|d| serde_json::from_str(&d).ok()) else {
        return Ok(0);
    };
    Ok(m.get("tasks")
        .and_then(Value::as_array)
        .and_then(|a| {
            a.iter()
                .find(|t| t.get("n").and_then(Value::as_i64) == Some(n))
        })
        .and_then(|t| t.get("body").and_then(Value::as_str))
        .map_or(0, |b| b.len() as i64))
}

/// Insert ROW, or replace the sample of its task.
pub fn put(tx: &mut WTx<'_>, row: &SampleRow) -> Result<(), CoordError> {
    // two statements (a parameter list is at most 16 long): the row with its required columns, then the rest
    tx.sql().execute(
        "insert or replace into forecast_sample (task, job, role, brief_bytes, tasks, tokens_in, tokens_out, \
         cache_read, cache_write, turns, active_secs, wall_secs, job_wait_secs, wakes, cold_wakes, outcome, \
         last_step, at) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, 0, 0.0)",
        (
            &row.task,
            &row.job,
            &row.role,
            row.brief_bytes,
            row.tasks,
            row.tokens_in,
            row.tokens_out,
            row.cache_read,
            row.cache_write,
            row.turns,
            row.active_secs,
            row.wall_secs,
            row.job_wait_secs,
            row.wakes,
            row.cold_wakes,
            &row.outcome,
        ),
    )?;
    tx.sql().execute(
        "update forecast_sample set project = ?2, profile = ?3, provider = ?4, model = ?5, context = ?6, cost = ?7, \
         cost_unit = ?8, last_step = ?9, at = ?10 where task = ?1",
        (
            &row.task,
            &row.project,
            &row.profile,
            &row.provider,
            &row.model,
            row.context,
            row.cost,
            &row.cost_unit,
            row.last_step,
            row.at,
        ),
    )?;
    Ok(())
}

/// The newest LIMIT samples, newest first.
pub fn all(conn: &Tx, limit: i64) -> Result<Vec<SampleRow>, CoordError> {
    let mut st = conn.prepare(
        "select task, job, project, role, profile, provider, model, brief_bytes, tasks, tokens_in, tokens_out, \
         cache_read, cache_write, turns, active_secs, wall_secs, job_wait_secs, wakes, cold_wakes, context, cost, \
         cost_unit, outcome, last_step, at from forecast_sample order by at desc, rowid desc limit ?1",
    )?;
    let rows = st.query_map([limit], |r| {
        Ok(SampleRow {
            task: r.get(0)?,
            job: r.get(1)?,
            project: r.get(2)?,
            role: r.get(3)?,
            profile: r.get(4)?,
            provider: r.get(5)?,
            model: r.get(6)?,
            brief_bytes: r.get(7)?,
            tasks: r.get(8)?,
            tokens_in: r.get(9)?,
            tokens_out: r.get(10)?,
            cache_read: r.get(11)?,
            cache_write: r.get(12)?,
            turns: r.get(13)?,
            active_secs: r.get(14)?,
            wall_secs: r.get(15)?,
            job_wait_secs: r.get(16)?,
            wakes: r.get(17)?,
            cold_wakes: r.get(18)?,
            context: r.get(19)?,
            cost: r.get(20)?,
            cost_unit: r.get(21)?,
            outcome: r.get(22)?,
            last_step: r.get(23)?,
            at: r.get(24)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Keep what forecasts said for ROWS (a job's tasks and its total); a task already forecast is replaced.
pub fn record_made(tx: &mut WTx<'_>, rows: &[Made]) -> Result<(), CoordError> {
    for m in rows {
        tx.sql().execute(
            "insert or replace into forecast_made (job, task, made_at, role, profile, model, tokens_p50, tokens_p90, \
             secs_p50, secs_p90, cost_p50, cost_p90, cost_unit, basis, n) \
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            (
                &m.job,
                &m.task,
                m.made_at,
                &m.role,
                &m.profile,
                &m.model,
                m.tokens_p50,
                m.tokens_p90,
                m.secs_p50,
                m.secs_p90,
                m.cost_p50,
                m.cost_p90,
                &m.cost_unit,
                &m.basis,
                m.n,
            ),
        )?;
    }
    Ok(())
}

/// `(p90 tokens, actual tokens)` of the latest LIMIT forecasts of this class that have a sample, newest first.
pub fn made_pairs(
    conn: &Tx,
    role: &str,
    profile: &str,
    model: Option<&str>,
    limit: i64,
) -> Result<Vec<(f64, f64)>, CoordError> {
    let mut st = conn.prepare(
        "select m.tokens_p90, s.tokens_in + s.tokens_out + s.cache_read + s.cache_write \
         from forecast_made m join forecast_sample s on s.task = m.task \
         where m.role = ?1 and m.profile = ?2 and m.model is ?3 \
         order by m.made_at desc, m.rowid desc limit ?4",
    )?;
    let rows = st.query_map((role, profile, model, limit), |r| {
        Ok((r.get::<_, f64>(0)?, r.get::<_, i64>(1)? as f64))
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The latest LIMIT (p90, actual) pairs of whole plans, newest first: what a job's forecast said of its total tokens
/// (`forecast_made`'s row for the job itself, before calibration) and what its tasks used, summed (managers apart).
/// Only a `done` job whose every task that ran has its sample counts, so a sweep that has not caught up never reads
/// as a plan that used less.
pub fn plan_pairs(conn: &Tx, limit: i64) -> Result<Vec<(f64, f64)>, CoordError> {
    let mut st = conn.prepare(
        "select m.tokens_p90, \
           (select sum(s.tokens_in + s.tokens_out + s.cache_read + s.cache_write) from forecast_sample s \
            where s.job = m.job and s.role <> 'manager') \
         from forecast_made m join job j on j.id = m.job \
         where m.task = m.job and j.status = 'done' \
           and exists (select 1 from forecast_sample s where s.job = m.job and s.role <> 'manager') \
           and not exists (select 1 from jtask t where t.job = m.job \
                           and exists (select 1 from step st where st.task = t.id) \
                           and not exists (select 1 from forecast_sample s where s.task = t.id)) \
         order by m.made_at desc, m.rowid desc limit ?1",
    )?;
    let rows = st.query_map([limit], |r| {
        Ok((r.get::<_, f64>(0)?, r.get::<_, i64>(1)? as f64))
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use crate::write::jobs::{NewJob, NewTask, job_create};
    use crate::write::spend::{SpendRow, add_spend};
    use crate::write::steps::{StepClass, StepEnd, StepNew, close, open};
    use crate::write::tasks::force_status;
    use serde_json::json;
    use urdr::graph::entity::{self, EntityNew, Origin};

    fn facts(_: Option<&str>, _: &str) -> ProfileFacts {
        ProfileFacts {
            model: Some("opus".into()),
            ttl_secs: 300.0,
        }
    }

    /// Job ID with N tasks `ID#1..`, each with a brief of `brief-<n>` in the job's data.
    fn job(tx: &mut crate::store::WTx<'_>, id: &str, n: i64) {
        let tasks = (1..=n)
            .map(|i| NewTask {
                n: i,
                title: format!("t{i}"),
                role: Some("implement".into()),
                deps: Vec::new(),
            })
            .collect();
        let bodies: Vec<_> = (1..=n)
            .map(|i| json!({"n": i, "body": format!("brief-{i}")}))
            .collect();
        job_create(
            tx,
            NewJob {
                id: id.into(),
                title: "J".into(),
                plan: None,
                repo: None,
                tasks,
                data: Some(json!({"tasks": bodies})),
            },
            1.0,
        )
        .unwrap();
    }

    fn session(tx: &mut crate::store::WTx<'_>, sid: &str, profile: &str, role: &str, job: &str) {
        entity::create(
            tx,
            EntityNew {
                id: format!("session:{sid}"),
                kind: "session".into(),
                project: None,
                title: Some(sid.into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({"profile": profile, "role": role, "job": job}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
    }

    /// One closed step of SID on TASK.
    fn step(
        tx: &crate::store::WTx<'_>,
        sid: &str,
        task: Option<&str>,
        class: StepClass,
        (start, end): (f64, f64),
        tokens_in: i64,
        turn: Option<&str>,
    ) -> i64 {
        let id = open(
            tx,
            StepNew {
                session: format!("session:{sid}"),
                task: task.map(str::to_string),
                plan: None,
                project: Some("project:q".into()),
                agent: None,
                provider: Some("claude".into()),
                class,
                start,
                tool: None,
                tool_kind: None,
                message_id: None,
                turn_id: turn.map(str::to_string),
                snapshot: None,
                log_version: None,
                acp: None,
            },
        )
        .unwrap();
        close(
            tx,
            id,
            StepEnd {
                end,
                tokens_in,
                tokens_out: 1,
                cache_read: 10,
                cache_write: 2,
                ..StepEnd::default()
            },
        )
        .unwrap();
        id
    }

    fn finish(tx: &mut crate::store::WTx<'_>, task: &str, status: &str) {
        assert!(force_status(tx, task, status, None, 9.0).unwrap());
    }

    /// Pattern D. A task that two sessions worked on (a fallback, then a move; a reviewer too) is one row with every
    /// step counted once.
    #[test]
    fn every_session_on_a_task_counts_once() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        session(&mut tx, "s2", "p2", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 10.0),
            100,
            Some("t1"),
        );
        step(
            &tx,
            "s2",
            Some("J#1"),
            StepClass::Think,
            (10.0, 20.0),
            200,
            Some("t2"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.tokens_in, 300);
        assert_eq!(row.tokens_out, 2);
        assert_eq!(row.cache_read, 20);
        assert_eq!(row.cache_write, 4);
        assert_eq!(row.turns, 2);
        assert_eq!((row.job.as_str(), row.role.as_str()), ("J", "implement"));
        assert_eq!(
            row.profile.as_deref(),
            Some("p2"),
            "the last session's profile"
        );
        assert_eq!(row.model.as_deref(), Some("opus"));
        put(&mut tx, &row).unwrap();
        put(&mut tx, &row).unwrap();
        assert_eq!(all(tx.sql(), 10).unwrap().len(), 1);
    }

    /// Pattern D. The reviewer's steps come last and count on the task, but the task's class is its worker's: the
    /// sample takes the profile of the last session that is no review (a review session is marked `review`).
    #[test]
    fn a_reviewers_profile_is_not_the_tasks() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "w", "p1", "worker", "J");
        entity::create(
            &mut tx,
            EntityNew {
                id: "session:r".into(),
                kind: "session".into(),
                project: None,
                title: Some("r".into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({"profile": "p2", "role": "worker", "job": "J", "review": true}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
        step(
            &tx,
            "w",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        step(
            &tx,
            "r",
            Some("J#1"),
            StepClass::Think,
            (5.0, 9.0),
            20,
            Some("t2"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.tokens_in, 30);
        assert_eq!(row.profile.as_deref(), Some("p1"));
    }

    /// Pattern D. A reviewer's steps carry the task they review and count on it.
    #[test]
    fn a_review_session_counts_on_its_task() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "w", "p1", "worker", "J");
        session(&mut tx, "r", "p1", "reviewer", "J");
        step(
            &tx,
            "w",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        step(
            &tx,
            "r",
            Some("J#1"),
            StepClass::Think,
            (5.0, 9.0),
            20,
            Some("t2"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.tokens_in, 30);
    }

    /// Pattern D. After `put`, nothing is due.
    #[test]
    fn a_second_sweep_writes_nothing() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        assert!(due(tx.sql(), 100).unwrap().is_empty(), "not finished");
        finish(&mut tx, "J#1", "done");
        assert_eq!(due(tx.sql(), 100).unwrap(), ["J#1"]);
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        put(&mut tx, &row).unwrap();
        assert!(due(tx.sql(), 100).unwrap().is_empty());
    }

    /// Pattern D. A step id above `last_step` makes the task due again, and `put` replaces the row.
    #[test]
    fn a_task_reopened_after_its_sample_is_sampled_again() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        finish(&mut tx, "J#1", "done");
        let first = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        put(&mut tx, &first).unwrap();
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (5.0, 9.0),
            30,
            Some("t2"),
        );
        assert_eq!(due(tx.sql(), 100).unwrap(), ["J#1"]);
        let second = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert!(second.last_step > first.last_step);
        assert_eq!(second.tokens_in, 40);
        put(&mut tx, &second).unwrap();
        let rows = all(tx.sql(), 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].tokens_in, 40);
    }

    /// Pattern D. A step that has not closed keeps its task out of `due`.
    #[test]
    fn an_open_step_keeps_the_task_out_of_due() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        open(
            &tx,
            StepNew {
                session: "session:s1".into(),
                task: Some("J#1".into()),
                plan: None,
                project: None,
                agent: None,
                provider: None,
                class: StepClass::Tool,
                start: 5.0,
                tool: None,
                tool_kind: None,
                message_id: None,
                turn_id: None,
                snapshot: None,
                log_version: None,
                acp: None,
            },
        )
        .unwrap();
        finish(&mut tx, "J#1", "done");
        assert!(due(tx.sql(), 100).unwrap().is_empty());
        assert!(gather(tx.sql(), "J#1", &facts).unwrap().is_none());
    }

    /// Pattern D. Spent is spent: a rewound step still counts (the sample never filters on any undo mark).
    #[test]
    fn every_step_of_a_task_counts_after_a_rewind() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        for i in 0..4 {
            let at = f64::from(i) * 10.0;
            step(
                &tx,
                "s1",
                Some("J#1"),
                StepClass::Think,
                (at, at + 5.0),
                100,
                Some("t1"),
            );
        }
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.tokens_in, 400);
    }

    /// Pattern D. A chat, or a fork from a step, has no task: no sample.
    #[test]
    fn a_session_with_no_task_makes_no_sample() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        session(&mut tx, "chat", "p1", "chat", "");
        step(
            &tx,
            "chat",
            None,
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        assert!(due(tx.sql(), 100).unwrap().is_empty());
        assert!(all(tx.sql(), 10).unwrap().is_empty());
    }

    /// Pattern D. Each job wait is a wake; one longer than the TTL is a cold one.
    #[test]
    fn a_cold_wake_is_a_job_wait_longer_than_the_ttl() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 10.0),
            10,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::JobWait,
            (10.0, 70.0),
            0,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (70.0, 80.0),
            10,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::JobWait,
            (80.0, 480.0),
            0,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (480.0, 490.0),
            10,
            Some("t1"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!((row.wakes, row.cold_wakes), (2, 1));
        assert_eq!(row.job_wait_secs, 460.0);
    }

    /// Pattern D. Waiting for the user and a pause are not the task's time.
    #[test]
    fn user_wait_and_paused_are_not_wall_time() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 10.0),
            10,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::UserWait,
            (10.0, 30.0),
            0,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Paused,
            (30.0, 40.0),
            0,
            None,
        );
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Tool,
            (40.0, 50.0),
            10,
            Some("t1"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.wall_secs, 20.0);
        assert_eq!(row.active_secs, 20.0);
    }

    /// Pattern D. Gateway spend is exact dollars; otherwise the steps' estimates; otherwise none.
    #[test]
    fn gateway_cost_is_exact_and_subscription_cost_is_an_estimate() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 3);
        session(&mut tx, "s1", "p1", "worker", "J");
        for (i, t) in ["J#1", "J#2", "J#3"].into_iter().enumerate() {
            let at = i as f64 * 10.0;
            let id = step(
                &tx,
                "s1",
                Some(t),
                StepClass::Think,
                (at, at + 5.0),
                10,
                Some("t"),
            );
            if t == "J#2" {
                tx.sql()
                    .execute(
                        "update step set cost = 0.25, cost_unit = 'usd-est' where id = ?1",
                        [id],
                    )
                    .unwrap();
            }
            finish(&mut tx, t, "done");
        }
        add_spend(
            &tx,
            &SpendRow {
                job: Some("J".into()),
                task: Some("J#1".into()),
                provider: "openrouter".into(),
                cost: 1.5,
                status: 200,
                ..SpendRow::default()
            },
            1.0,
        )
        .unwrap();
        let cost = |t: &str| {
            let r = gather(tx.sql(), t, &facts).unwrap().unwrap();
            (r.cost, r.cost_unit)
        };
        assert_eq!(cost("J#1"), (Some(1.5), Some("usd".into())));
        assert_eq!(cost("J#2"), (Some(0.25), Some("usd-est".into())));
        assert_eq!(cost("J#3"), (None, None));
    }

    /// Pattern D. A dropped task that ran a turn is a sample; one that never did is not.
    #[test]
    fn a_dropped_task_with_turns_is_sampled_and_one_with_none_is_not() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 2);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 5.0),
            10,
            Some("t1"),
        );
        step(
            &tx,
            "s1",
            Some("J#2"),
            StepClass::UserWait,
            (5.0, 9.0),
            0,
            None,
        );
        finish(&mut tx, "J#1", "dropped");
        finish(&mut tx, "J#2", "dropped");
        let one = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(one.outcome, "dropped");
        assert!(gather(tx.sql(), "J#2", &facts).unwrap().is_none());
    }

    /// Pattern D. A finished job's manager steps have no task: they make one row, with the job's task count.
    #[test]
    fn a_finished_jobs_manager_steps_make_one_manager_row() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 4);
        session(&mut tx, "m", "mgr", "manager", "J");
        step(
            &tx,
            "m",
            None,
            StepClass::Think,
            (0.0, 10.0),
            500,
            Some("t1"),
        );
        assert!(due(tx.sql(), 100).unwrap().is_empty(), "the job still runs");
        crate::write::jobs::job_set(&mut tx, "J", Some("done"), None, 20.0).unwrap();
        assert_eq!(due(tx.sql(), 100).unwrap(), ["J#manager"]);
        let row = gather(tx.sql(), "J#manager", &facts).unwrap().unwrap();
        assert_eq!(
            (row.role.as_str(), row.tasks, row.tokens_in),
            ("manager", 4, 500)
        );
        put(&mut tx, &row).unwrap();
        assert!(due(tx.sql(), 100).unwrap().is_empty());
    }

    /// Pattern D. The sweep asks for its managers every tick: each finished job's manager sessions are found through
    /// an index by the job, so the query never reads the whole entity table.
    #[test]
    fn the_manager_query_reads_no_whole_table() {
        let c = db7();
        let mut st = c
            .prepare(&format!("explain query plan {MANAGER_DUE}"))
            .unwrap();
        let plan: Vec<String> = st
            .query_map([100], |r| r.get(3))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(
            !plan
                .iter()
                .any(|d| d == "SCAN e" || d.starts_with("SCAN e USING")),
            "{plan:#?}"
        );
        assert!(
            plan.iter()
                .filter(|d| d.starts_with("SEARCH e USING INDEX entity_manager_job"))
                .count()
                == 3,
            "{plan:#?}"
        );
    }

    /// Pattern D. The tables have the numeric and id columns and nothing that could hold a brief; the brief is a length.
    #[test]
    fn the_tables_hold_no_text_from_a_brief() {
        let mut c = db7();
        let cols = |t: &str| -> Vec<String> {
            let mut st = c
                .prepare("select name from pragma_table_info(?1) order by cid")
                .unwrap();
            st.query_map([t], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            cols("forecast_sample"),
            "task job project role profile provider model brief_bytes tasks tokens_in tokens_out cache_read \
             cache_write turns active_secs wall_secs job_wait_secs wakes cold_wakes context cost cost_unit outcome \
             last_step at"
                .split(' ')
                .collect::<Vec<_>>()
        );
        assert_eq!(
            cols("forecast_made"),
            "job task made_at role profile model tokens_p50 tokens_p90 secs_p50 secs_p90 cost_p50 cost_p90 \
             cost_unit basis n"
                .split(' ')
                .collect::<Vec<_>>()
        );
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        finish(&mut tx, "J#1", "done");
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        assert_eq!(row.brief_bytes, "brief-1".len() as i64);
    }

    /// Pattern D. What a forecast said is kept beside what the task then took.
    #[test]
    fn a_made_forecast_pairs_with_the_sample() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 1);
        session(&mut tx, "s1", "p1", "worker", "J");
        step(
            &tx,
            "s1",
            Some("J#1"),
            StepClass::Think,
            (0.0, 4.0),
            10,
            Some("t1"),
        );
        finish(&mut tx, "J#1", "done");
        record_made(
            &mut tx,
            &[Made {
                job: "J".into(),
                task: "J#1".into(),
                made_at: 1.0,
                role: Some("implement".into()),
                profile: Some("p1".into()),
                model: Some("opus".into()),
                tokens_p50: 10.0,
                tokens_p90: 40.0,
                secs_p50: 1.0,
                secs_p90: 2.0,
                cost_p50: None,
                cost_p90: None,
                cost_unit: None,
                basis: "prior".into(),
                n: 0,
            }],
        )
        .unwrap();
        assert!(
            made_pairs(tx.sql(), "implement", "p1", Some("opus"), 10)
                .unwrap()
                .is_empty()
        );
        let row = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        put(&mut tx, &row).unwrap();
        assert_eq!(
            made_pairs(tx.sql(), "implement", "p1", Some("opus"), 10).unwrap(),
            [(40.0, 10.0 + 1.0 + 10.0 + 2.0)]
        );
    }

    /// Pattern D. A whole plan pairs its total's p90 with what its tasks used, once the job is done and every task
    /// that ran is sampled: a task still unsampled keeps the plan out.
    #[test]
    fn a_done_plan_pairs_its_total_with_its_tasks_summed() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        job(&mut tx, "J", 2);
        session(&mut tx, "s1", "p1", "worker", "J");
        for t in ["J#1", "J#2"] {
            step(
                &tx,
                "s1",
                Some(t),
                StepClass::Think,
                (0.0, 4.0),
                10,
                Some("t1"),
            );
            finish(&mut tx, t, "done");
        }
        let plan = Made {
            job: "J".into(),
            task: "J".into(),
            made_at: 1.0,
            role: None,
            profile: None,
            model: None,
            tokens_p50: 20.0,
            tokens_p90: 80.0,
            secs_p50: 1.0,
            secs_p90: 2.0,
            cost_p50: None,
            cost_p90: None,
            cost_unit: None,
            basis: "2 tasks".into(),
            n: 0,
        };
        record_made(&mut tx, std::slice::from_ref(&plan)).unwrap();
        crate::write::jobs::job_set(&mut tx, "J", Some("done"), None, 5.0).unwrap();
        let one = gather(tx.sql(), "J#1", &facts).unwrap().unwrap();
        put(&mut tx, &one).unwrap();
        assert!(
            plan_pairs(tx.sql(), 10).unwrap().is_empty(),
            "J#2 not sampled yet"
        );
        let two = gather(tx.sql(), "J#2", &facts).unwrap().unwrap();
        put(&mut tx, &two).unwrap();
        let used = (one.tokens_in
            + one.tokens_out
            + one.cache_read
            + one.cache_write
            + two.tokens_in
            + two.tokens_out
            + two.cache_read
            + two.cache_write) as f64;
        assert_eq!(plan_pairs(tx.sql(), 10).unwrap(), [(80.0, used)]);
        // a job that is not done is no plan pair
        crate::write::jobs::job_set(&mut tx, "J", Some("stopped"), None, 6.0).unwrap();
        assert!(plan_pairs(tx.sql(), 10).unwrap().is_empty());
    }
}
