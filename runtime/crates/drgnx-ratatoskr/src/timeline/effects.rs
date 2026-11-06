//! What a revert to a step cannot undo (`docs/develop/hub.md`, "Revert to here"), each from a hub record made after
//! the step began: commits a remote already has, messages the session sent that were read, its decisions another
//! decision relies on, the tasks it filed, its merges, the settings it changed, what it spent and its jobs.  The card
//! lists them first.  [`blocked`] names the commits of another session that build on what the revert undoes and are
//! already in the integration branch: such a revert is refused and offered as a fork.
//!
//! Git runs only in a trusted store or an untouched repository ([`crate::runner::effects::store_of`]), off the async
//! threads.
#![cfg_attr(
    not(test),
    expect(dead_code, reason = "called by the revert's preview")
)]

use crate::agents::rewind::Target;
use crate::front::Front;
use crate::runner::effects::{Dependents, git, store_of};
use crate::work::conclusions::{self, Concluded};
use norn::store::{CoordError, Tx};
use runstav::methods::history::{Blocked, Pushed, RevertEffects, Spent};
use runstav::wire::Error;
use serde_json::Value;
use std::path::{Path, PathBuf};

fn internal(e: impl std::fmt::Display) -> Error {
    crate::agents::session::internal(format!("what a revert cannot undo: {e}"))
}

/// What the store says of step T and after it.
struct Read {
    task: Option<String>,
    messages: Vec<i64>,
    tasks: Vec<String>,
    settings: Vec<String>,
    commits: Vec<(String, Value)>,
    decisions: Vec<i64>,
    spent: Spent,
}

/// The names a session's messages carry as their sender: its hub id, and its step's agent name with and without
/// `agent:`.
fn senders(sid: &str, agent: Option<&str>) -> Vec<String> {
    let mut v = vec![sid.to_owned(), format!("agent:{sid}")];
    if let Some(a) = agent {
        v.push(a.to_owned());
        v.push(a.trim_start_matches("agent:").to_owned());
    }
    v.sort();
    v.dedup();
    v
}

fn read(c: &Tx, t: &Target) -> Result<Read, CoordError> {
    let key = format!("session:{}", t.sid);
    let steps = norn::read::steps::for_session(c, &key, t.seq - 1)?;
    let Some(step) = steps.iter().find(|s| s.seq == t.seq) else {
        return Err(CoordError::Refused(format!(
            "session {} has no step {}",
            t.sid, t.seq
        )));
    };
    let start = step.start;
    let mut spent = Spent::default();
    for s in steps.iter().filter(|s| s.seq > t.seq) {
        spent.tokens += s.tokens_in + s.tokens_out;
        if let (Some(cost), Some(unit)) = (s.cost, s.cost_unit.as_ref()) {
            *spent.cost_by_unit.entry(unit.clone()).or_default() += cost;
        }
    }
    // the ids a query of (sid, start, the settings tool) answers
    let ids = |sql: &str| -> Result<Vec<String>, CoordError> {
        let mut st = c.prepare(sql)?;
        let tool = norn::tools::settings::PROPOSED_TOOL;
        let rows = st.query_map((&t.sid, start, tool), |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    };
    let who = serde_json::to_string(&senders(&t.sid, step.agent.as_deref())).unwrap_or_default();
    let messages: Vec<i64> = {
        let mut st = c.prepare(
            "select id from message where sender in (select value from json_each(?1)) and at > ?2 \
             and state in ('read', 'acted') order by id",
        )?;
        let rows = st.query_map((&who, start), |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    let tasks = ids(
        "select e.id from entity e join tx t on t.id = e.created_tx \
         where e.kind = 'task' and t.session = ?1 and t.at > ?2 and ?3 is not null order by e.n",
    )?;
    let settings = ids(
        "select distinct e.id from entity e join tx t on t.session = ?1 and t.tool = ?3 and t.at > ?2 \
         where e.updated_tx = t.id or e.created_tx = t.id \
         or e.n in (select n from entity_hist where tx_from = t.id) order by e.id",
    )?;
    let commits: Vec<(String, Value)> = {
        let mut st = c.prepare(
            "select json_extract(e.data, '$.sha'), e.data from entity e join tx t on t.id = e.created_tx \
             where e.kind = 'commit' and e.retired_tx is null and json_extract(e.data, '$.session') = ?1 \
             and t.at > ?2 order by e.n",
        )?;
        let rows = st.query_map((&t.sid, start), |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .map(|(sha, data)| (sha, serde_json::from_str(&data).unwrap_or(Value::Null)))
            .collect()
    };
    let decisions = conclusions::after(c, &t.sid, t.seq)?
        .into_iter()
        .filter_map(|x| match x {
            Concluded::Decision(n) => Some(n),
            Concluded::Finding(_) => None,
        })
        .collect();
    Ok(Read {
        task: steps.iter().find_map(|s| s.task.clone()),
        messages,
        tasks,
        settings,
        commits,
        decisions,
        spent,
    })
}

/// The job a session's task belongs to (`task:<job>#<n>`), whose `job/<job>` branch its work merges into.
fn job_of(task: Option<&str>) -> Option<String> {
    let t = task?;
    let (job, _) = t.strip_prefix("task:").unwrap_or(t).split_once('#')?;
    Some(job.to_owned())
}

/// The branch a session's work is integrated on in STORE: its job's, else the branch the store's `HEAD` names.
fn integration_branch(store: &Path, job: Option<&str>) -> Option<String> {
    match job {
        Some(j) => Some(format!("job/{j}")),
        None => git(store, &["symbolic-ref", "--short", "-q", "HEAD"])
            .ok()
            .map(|b| b.trim().to_owned())
            .filter(|b| !b.is_empty()),
    }
}

fn is_ancestor(store: &Path, commit: &str, branch: &str) -> bool {
    git(
        store,
        &[
            "merge-base",
            "--is-ancestor",
            commit,
            &format!("refs/heads/{branch}"),
        ],
    )
    .is_ok()
}

/// The remote-tracking refs of STORE that contain COMMIT.
fn remote_refs(store: &Path, commit: &str) -> Vec<String> {
    git(
        store,
        &[
            "for-each-ref",
            "--format=%(refname:short)",
            "--contains",
            commit,
            "refs/remotes",
        ],
    )
    .map(|o| {
        o.lines()
            .map(str::to_owned)
            .filter(|l| !l.is_empty())
            .collect()
    })
    .unwrap_or_default()
}

/// The session's jobs that run or wait: the hub's own (by the session that started each), then the runners queue's
/// queued rows and remote attempts (`runtime.db`), each named with where it runs.
async fn jobs(front: &Front, sid: &str) -> Vec<String> {
    let mut out: Vec<String> = front
        .core
        .exec
        .live()
        .ids(sid)
        .into_iter()
        .map(|id| format!("{id} (here)"))
        .collect();
    let Some(db) = front.core.agents.db() else {
        return out;
    };
    let s = sid.to_owned();
    let rows: Vec<(String, String, Option<String>)> = db
        .read(move |c| {
            let mut st = c.prepare(
                "select j.id, j.state, a.runner from rq_job j left join rq_attempt a \
                 on a.job = j.id and a.attempt = j.attempt and j.attempt > 0 \
                 where json_extract(j.spec, '$.session') = ?1 and j.state in ('queued', 'running') order by j.id",
            )?;
            let rows = st.query_map([&s], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            Ok(rows.collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap_or_else(|e| {
            tracing::warn!(sid, "the queue's jobs are not read: {e}");
            Vec::new()
        });
    for (id, state, runner) in rows {
        let line = match (state.as_str(), runner) {
            ("queued", _) => format!("{id} (queued)"),
            (_, Some(r)) => format!("{id} (on {r})"),
            _ => format!("{id} (here)"),
        };
        if !out.contains(&line) {
            out.push(line);
        }
    }
    out
}

/// What reverting to T cannot undo.
pub(crate) async fn of(front: &Front, t: &Target) -> Result<RevertEffects, Error> {
    let tt = t.clone();
    let r = front
        .writer
        .db
        .read(move |c| read(c, &tt))
        .await
        .map_err(|e| match e {
            CoordError::Refused(m) => crate::agents::session::invalid("seq", m),
            e => internal(e),
        })?;
    let mut relied = Vec::new();
    for n in &r.decisions {
        if !crate::runner::effects::dependents(front, *n)
            .await?
            .decisions
            .is_empty()
        {
            relied.push(*n);
        }
    }
    let job = job_of(r.task.as_deref());
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    for (sha, data) in &r.commits {
        if let Some(store) = store_of(front, data).await {
            found.push((sha.clone(), store));
        }
    }
    let (pushed, merges) = crate::clock::blocking(move || {
        let (mut pushed, mut merges) = (Vec::new(), Vec::new());
        for (sha, store) in &found {
            let refs = remote_refs(store, sha);
            if !refs.is_empty() {
                pushed.push(Pushed {
                    commit: sha.clone(),
                    refs,
                });
            }
            // a session with a job merges into the job's branch; one without works on the branch itself
            if let Some(j) = job.as_deref()
                && is_ancestor(store, sha, &format!("job/{j}"))
            {
                merges.push(format!("{sha} into job/{j}"));
            }
        }
        (pushed, merges)
    })
    .await
    .map_err(internal)?;
    Ok(RevertEffects {
        pushed,
        messages_read: r.messages,
        decisions_relied_on: relied,
        tasks_filed: r.tasks,
        merges,
        settings: r.settings,
        spent: r.spent,
        jobs_running: jobs(front, &t.sid).await,
        label: "computed".into(),
    })
}

/// The commits of DEPS (a decision's computed dependents) that another session than SID made and the integration
/// branch already holds (`merge-base --is-ancestor` in the commit's trusted store): reverting would pull the ground
/// from under them.
pub(crate) async fn blocked(
    front: &Front,
    deps: &Dependents,
    sid: &str,
) -> Result<Vec<Blocked>, Error> {
    let (key, commits) = (format!("session:{sid}"), deps.commits.clone());
    let (task, rows) = front
        .writer
        .db
        .read(move |c| {
            let task: Option<String> = c
                .query_row(
                    "select task from step where session = ?1 and task is not null order by seq limit 1",
                    [&key],
                    |r| r.get(0),
                )
                .or_else(|e| match e {
                    urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                    e => Err(e),
                })?;
            let mut rows = Vec::new();
            for sha in commits {
                let Some(e) = urdr::graph::entity::by_id(c, &format!("commit:{sha}"))? else {
                    continue;
                };
                let decision: Option<i64> = c
                    .query_row(
                        "select d.id from link l join entity d on d.n = l.dst where l.src = ?1 \
                         and l.kind = 'implements' and l.tx_to = ?2 and d.kind = 'decision' order by d.n limit 1",
                        (e.n, urdr::graph::schema::SENTINEL),
                        |r| r.get::<_, String>(0),
                    )
                    .map(|id| id.strip_prefix("decision:").and_then(|n| n.parse().ok()))
                    .or_else(|e| match e {
                        urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                        e => Err(e),
                    })?;
                rows.push((sha, e.data, decision));
            }
            Ok((task, rows))
        })
        .await
        .map_err(internal)?;
    let job = job_of(task.as_deref());
    let mut found = Vec::new();
    for (sha, data, decision) in rows {
        let session = data
            .get("session")
            .and_then(Value::as_str)
            .unwrap_or("user")
            .to_owned();
        if session == sid {
            continue;
        }
        let (Some(store), Some(decision)) = (store_of(front, &data).await, decision) else {
            continue;
        };
        found.push((sha, store, session, decision));
    }
    crate::clock::blocking(move || {
        found
            .into_iter()
            .filter_map(|(commit, store, session, decision)| {
                let branch = integration_branch(&store, job.as_deref())?;
                is_ancestor(&store, &commit, &branch).then_some(Blocked {
                    decision,
                    commit,
                    session,
                    branch,
                })
            })
            .collect()
    })
    .await
    .map_err(internal)
}

#[cfg(test)]
mod tests;
