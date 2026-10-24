//! Plans in the graph and what decisions did (Task 21): `plans/get`, `plans/write` (under `graph.change` for an
//! agent's `plan_write`), `reports/get`, and `decisions/effects` (a decision's commits and the later hunks that
//! overlap its lines, computed from git and labelled `computed`); commits linked to the decisions their session
//! recorded since the branch's previous commit; the fallback `drgnx-report` block.
//!
//! A plan in the graph is a `plan` entity whose tasks are `task` entities under it (`parent_of`), each with
//! `data.{number, model, interfaces, steps, role}`; a task waits on the tasks that `block` it.  Git runs in blocking
//! tasks (never on the tick).

use crate::coord::{Writer, fail};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::runner::plan::{self, Plan};
use crate::runner::{internal, invalid, now};
use norn::store::{CoordError, Tx, WTx};
use runstav::methods::plans::{
    ByPlan, CheckRun, DecisionRef, Effects, EffectsParams, Hunk, PlanStep, PlanTask, PlanView,
    PlanWritten, Report, ReportSubmit, Reports, ReportsParams, TaskId, WriteParams,
};
use runstav::registry::Class;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use urdr::graph::entity::{self, Changes, Ent, EntityNew, Origin};
use urdr::graph::link;
use urdr::graph::schema::SENTINEL;

fn refuse(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: msg.into(),
        path: None,
    }
}

// ---- who may reach what -----------------------------------------------------------------------------------------

/// What a caller may reach in the graph.  The user and the hub reach everything; an agent reaches its own project's
/// records only (its session's project: the plan run's, else the one its folder is in), so a worker in project A
/// can neither read nor change project B's plans, reports or proposals (records of no project stay open).
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Scope {
    Anyone,
    Project {
        /// The project entity id (none: the session's folder is in no project).
        id: Option<String>,
        /// The project's git top-level (none: not known).
        root: Option<PathBuf>,
    },
}

impl Scope {
    /// Whether a record of PROJECT (an entity id) is the caller's.
    pub(crate) fn allows_project(&self, project: Option<&str>) -> Result<(), CoordError> {
        match self {
            // a record of no project (a job's tasks, which the hub writes) is nobody's in particular
            Scope::Project { id, .. } if project.is_some() && id.as_deref() != project => Err(CoordError::Refused(
                "that belongs to another project: an agent reaches its own project's records only".into(),
            )),
            _ => Ok(()),
        }
    }

    /// Whether PATH (a file a record is about) lies in the caller's project.
    pub(crate) fn allows_path(&self, path: &Path) -> Result<(), CoordError> {
        match self {
            Scope::Project { root, .. } if !root.as_deref().is_some_and(|r| path.starts_with(r)) => {
                Err(CoordError::Refused(
                    "that is about a file outside your project: an agent reaches its own project's records only"
                        .into(),
                ))
            }
            _ => Ok(()),
        }
    }
}

/// The scope of session SID.
pub(crate) async fn scope_of_session(f: &Front, sid: &str) -> Result<Scope, Error> {
    let cwd = f.core.agents.find(sid)?.cwd().to_path_buf();
    let found = tokio::task::spawn_blocking(move || norn::project::resolve(&cwd))
        .await
        .ok()
        .flatten();
    let from_run = f.core.runs.scope_of(sid).and_then(|(_, project)| project);
    Ok(Scope::Project {
        id: from_run.or_else(|| found.as_ref().map(|p| p.id.clone())),
        root: found.map(|p| p.root),
    })
}

/// The scope of caller C: everything for the user and the hub, the session's project for an agent.
pub(crate) async fn scope_of(f: &Front, c: &Caller) -> Result<Scope, Error> {
    if c.class != Class::Agent {
        return Ok(Scope::Anyone);
    }
    match &c.sid {
        Some(sid) => scope_of_session(f, sid).await,
        None => Err(refuse("an agent call without a session reaches no project")),
    }
}

// ---- reading a plan ---------------------------------------------------------------------------------------------

/// A plan as the graph has it, with what the job needs beyond the view.
struct Loaded {
    view: PlanView,
    roles: BTreeMap<String, String>,
    repo: Option<String>,
}

fn srcs(conn: &Tx, dst: i64, kind: &str) -> Result<Vec<i64>, CoordError> {
    let mut st = conn
        .prepare("select src from link where dst = ?1 and kind = ?2 and tx_to = ?3 order by id")?;
    let rows = st.query_map((dst, kind, SENTINEL), |r| r.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn dsts(conn: &Tx, src: i64, kind: &str) -> Result<Vec<i64>, CoordError> {
    let mut st = conn
        .prepare("select dst from link where src = ?1 and kind = ?2 and tx_to = ?3 order by id")?;
    let rows = st.query_map((src, kind, SENTINEL), |r| r.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn live(conn: &Tx, n: i64) -> Result<Option<Ent>, CoordError> {
    Ok(entity::by_n(conn, n)?.filter(|e| e.retired_tx.is_none()))
}

fn str_of(e: &Ent, key: &str) -> Option<String> {
    e.data.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// The version of a plan: the latest change to it or to one of its tasks.
fn version(conn: &Tx, plan: i64) -> Result<u64, CoordError> {
    let v: i64 = conn.query_row(
        "select coalesce(max(updated_tx), 0) from entity where n = ?1 or n in \
         (select dst from link where src = ?1 and kind = 'parent_of' and tx_to = ?2)",
        (plan, SENTINEL),
        |r| r.get(0),
    )?;
    Ok(v as u64)
}

pub(crate) fn reports_of(conn: &Tx, task: i64) -> Result<Vec<Ent>, CoordError> {
    let mut out = Vec::new();
    for n in srcs(conn, task, "report_of")? {
        out.extend(live(conn, n)?.filter(|e| e.kind == "report"));
    }
    out.sort_by(|a, b| b.n.cmp(&a.n));
    Ok(out)
}

fn load(conn: &Tx, id: &str) -> Result<Loaded, CoordError> {
    let plan = entity::by_id(conn, id)?
        .filter(|e| e.kind == "plan" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no plan {id}")))?;
    let project = match plan.project {
        Some(p) => live(conn, p)?,
        None => None,
    };
    let mut ents = Vec::new();
    for n in dsts(conn, plan.n, "parent_of")? {
        ents.extend(live(conn, n)?.filter(|e| e.kind == "task"));
    }
    let number = |e: &Ent| str_of(e, "number").unwrap_or_else(|| e.id.clone());
    let mut roles = BTreeMap::new();
    let mut tasks = Vec::new();
    for e in &ents {
        let mut deps = Vec::new();
        for d in srcs(conn, e.n, "blocks")? {
            deps.extend(live(conn, d)?.map(|d| number(&d)));
        }
        let steps = e
            .data
            .get("steps")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|s| PlanStep {
                        done: s.get("done").and_then(Value::as_bool).unwrap_or(false),
                        text: s.get("text").and_then(Value::as_str).unwrap_or("").into(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        let reports = reports_of(conn, e.n)?;
        // the latest report that names interfaces (`report.data.interfaces`, the field Task 22's briefs read)
        let report_interfaces = reports
            .iter()
            .find_map(|r| str_of(r, "interfaces").filter(|s| !s.trim().is_empty()));
        if let Some(r) = str_of(e, "role") {
            roles.insert(number(e), r);
        }
        tasks.push(PlanTask {
            id: e.id.clone(),
            number: number(e),
            title: e.title.clone().unwrap_or_default(),
            status: e.status.clone().unwrap_or_else(|| "open".into()),
            model: str_of(e, "model"),
            deps,
            interfaces: str_of(e, "interfaces"),
            steps,
            reports: reports.iter().map(|r| r.id.clone()).collect(),
            report_interfaces,
        });
    }
    Ok(Loaded {
        view: PlanView {
            id: plan.id.clone(),
            title: plan.title.clone().unwrap_or_default(),
            status: plan.status.clone(),
            project: project.as_ref().map(|p| p.id.clone()),
            version: version(conn, plan.n)?,
            tasks,
        },
        roles,
        repo: plan
            .data
            .get("repo")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| project.as_ref().and_then(|p| str_of(p, "path"))),
    })
}

pub async fn plans_get(f: &Front, c: &Caller, p: ByPlan) -> Result<PlanView, Error> {
    let id = p.plan.as_str().to_owned();
    let scope = scope_of(f, c).await?;
    f.writer
        .db
        .read(move |c| {
            let view = load(c, &id)?.view;
            scope.allows_project(view.project.as_deref())?;
            Ok(view)
        })
        .await
        .map_err(fail)
}

/// The plan entity ID as a job's plan (`job/propose` with a plan in the graph): its text stands in for the file, so
/// the job keeps the title, the tasks with their roles and dependencies, and the repository.  The file path of the
/// pair is the entity id.
pub async fn plan_for_job(front: &Front, id: &str) -> Result<(PathBuf, Plan), Error> {
    let key = id.to_owned();
    let loaded = front
        .writer
        .db
        .read(move |c| load(c, &key))
        .await
        .map_err(fail)?;
    let num = |s: &str| -> Result<i64, Error> {
        let digits: String = s.chars().take_while(char::is_ascii_digit).collect();
        digits
            .parse()
            .map_err(|_| invalid(format!("task {s:?} has no number a job can run")))
    };
    let mut tasks = Vec::new();
    for t in &loaded.view.tasks {
        let mut body = String::new();
        for s in &t.steps {
            body.push_str(&format!(
                "- [{}] {}\n",
                if s.done { "x" } else { " " },
                s.text
            ));
        }
        if let Some(i) = &t.interfaces {
            body.push_str(&format!("\nInterfaces: {i}\n"));
        }
        tasks.push(plan::PlanTask {
            n: num(&t.number)?,
            title: t.title.clone(),
            role: loaded
                .roles
                .get(&t.number)
                .cloned()
                .unwrap_or_else(|| "implement".into()),
            deps: t.deps.iter().map(|d| num(d)).collect::<Result<_, _>>()?,
            body: body.trim().to_owned(),
        });
    }
    let hash = format!("{}:{}", loaded.view.id, loaded.view.version);
    Ok((
        PathBuf::from(id),
        Plan {
            title: loaded.view.title,
            repo: loaded
                .repo
                .map(|r| if r.ends_with('/') { r } else { format!("{r}/") }),
            tasks,
            wont_build: Vec::new(),
            hash,
        },
    ))
}

// ---- writing a plan ---------------------------------------------------------------------------------------------

/// Whether the agent C may change the graph: the matrix's `graph.change`, as the worker column says.
async fn may_change(f: &Front, c: &Caller, plan: Option<String>) -> Result<(), Error> {
    use crate::matrix_gate::{ActionCtx, Gate};
    if c.class != Class::Agent {
        return Ok(());
    }
    let who = norn::matrix::Who {
        role: Some(norn::matrix::Role::Worker),
        ..Default::default()
    };
    let ctx = ActionCtx {
        session: c.sid.clone(),
        plan,
        ..Default::default()
    };
    match f
        .core
        .matrix
        .decide(
            &f.settings,
            &f.writer,
            who,
            norn::matrix::Action::GraphChange,
            ctx,
        )
        .await
    {
        Gate::Allow => Ok(()),
        Gate::Ask(card) => Err(refuse(format!(
            "the matrix asks the user first (card {card}); write the plan again once it is settled"
        ))),
        Gate::Never(why) => Err(refuse(why)),
    }
}

fn task_by_number(conn: &Tx, plan: i64, number: &str) -> Result<Option<Ent>, CoordError> {
    for n in dsts(conn, plan, "parent_of")? {
        if let Some(e) = live(conn, n)?.filter(|e| e.kind == "task")
            && str_of(&e, "number").as_deref() == Some(number)
        {
            return Ok(Some(e));
        }
    }
    Ok(None)
}

fn write_plan(tx: &mut WTx<'_>, p: &WriteParams, scope: &Scope) -> Result<PlanWritten, CoordError> {
    let plan = match &p.plan {
        Some(id) => {
            let e = entity::by_id(tx.sql(), id.as_str())?
                .filter(|e| e.kind == "plan" && e.retired_tx.is_none())
                .ok_or_else(|| CoordError::Refused(format!("no plan {}", id.as_str())))?;
            let owner = match e.project {
                Some(n) => live(tx.sql(), n)?.map(|p| p.id),
                None => None,
            };
            scope.allows_project(owner.as_deref())?;
            if let Some(base) = p.base_version {
                let now = version(tx.sql(), e.n)?;
                if now > base {
                    return Err(CoordError::Refused(format!(
                        "held: the plan changed since version {base} (now {now}); read it again"
                    )));
                }
            }
            if let Some(t) = &p.title {
                entity::update(
                    tx,
                    e.n,
                    None,
                    Changes {
                        title: Some(Some(t.as_str().to_owned())),
                        ..Changes::default()
                    },
                )?;
            }
            e
        }
        None => {
            // a new plan of an agent is in its own project (once that is in the graph); naming another is refused
            let named = p.project.as_ref().map(|i| i.as_str().to_owned());
            if named.is_some() {
                scope.allows_project(named.as_deref())?;
            }
            let own = match scope {
                Scope::Project { id, .. } => id.clone(),
                Scope::Anyone => None,
            };
            let project = match named.as_ref().or(own.as_ref()) {
                Some(id) => {
                    let found = entity::by_id(tx.sql(), id)?
                        .filter(|e| e.kind == "project" && e.retired_tx.is_none());
                    match (found, &named) {
                        (Some(e), _) => Some(e.n),
                        (None, Some(_)) => {
                            return Err(CoordError::Refused(format!("no project {id}")));
                        }
                        (None, None) => None,
                    }
                }
                None => None,
            };
            let title = p.title.as_ref().map(|t| t.as_str().to_owned());
            let id = norn::tracker::new_id(tx, "plan", project)?;
            entity::create(
                tx,
                EntityNew {
                    id,
                    kind: "plan".into(),
                    project,
                    title,
                    status: Some("open".into()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?
        }
    };
    let mut written: Vec<TaskId> = Vec::new();
    for w in &p.tasks.0 {
        let number = w.number.as_str();
        let mut data = serde_json::Map::new();
        data.insert("number".into(), json!(number));
        if let Some(m) = &w.model {
            data.insert("model".into(), json!(m.as_str()));
        }
        if let Some(i) = &w.interfaces {
            data.insert("interfaces".into(), json!(i.as_str()));
        }
        if let Some(s) = &w.steps {
            let steps: Vec<Value> =
                s.0.iter()
                    .map(|s| json!({"done": s.done, "text": s.text.as_str()}))
                    .collect();
            data.insert("steps".into(), json!(steps));
        }
        let task = match task_by_number(tx.sql(), plan.n, number)? {
            Some(e) => {
                entity::update(
                    tx,
                    e.n,
                    None,
                    Changes {
                        title: w.title.as_ref().map(|t| Some(t.as_str().to_owned())),
                        status: w.status.as_ref().map(|s| Some(s.as_str().to_owned())),
                        data_patch: Some(Value::Object(data)),
                        ..Changes::default()
                    },
                )?;
                e
            }
            None => {
                let id = norn::tracker::new_id(tx, "task", plan.project)?;
                let e = entity::create(
                    tx,
                    EntityNew {
                        id,
                        kind: "task".into(),
                        project: plan.project,
                        title: Some(
                            w.title
                                .as_ref()
                                .map_or_else(|| number.to_owned(), |t| t.as_str().to_owned()),
                        ),
                        status: Some(
                            w.status
                                .as_ref()
                                .map_or_else(|| "open".to_owned(), |s| s.as_str().to_owned()),
                        ),
                        body: None,
                        priority: None,
                        assignee: None,
                        data: Value::Object(data),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )?;
                link::add(tx, plan.n, "parent_of", e.n, None, Origin::Recorded, None)?;
                e
            }
        };
        written.push(TaskId {
            number: number.to_owned(),
            id: task.id,
        });
    }
    // `blocks` after every task exists, so a task may wait on one written in the same call
    for w in &p.tasks.0 {
        let Some(deps) = &w.blocks else { continue };
        let task = task_by_number(tx.sql(), plan.n, w.number.as_str())?
            .ok_or_else(|| CoordError::Refused(format!("no task {}", w.number.as_str())))?;
        for old in srcs(tx.sql(), task.n, "blocks")? {
            link::retire(tx, old, "blocks", task.n)?;
        }
        for d in &deps.0 {
            let dep = task_by_number(tx.sql(), plan.n, d.as_str())?.ok_or_else(|| {
                CoordError::Refused(format!(
                    "task {} waits on {}, which the plan does not have",
                    w.number.as_str(),
                    d.as_str()
                ))
            })?;
            if dep.n == task.n {
                return Err(CoordError::Refused(format!(
                    "task {} cannot wait on itself",
                    w.number.as_str()
                )));
            }
            link::add(tx, dep.n, "blocks", task.n, None, Origin::Recorded, None)?;
        }
    }
    Ok(PlanWritten {
        plan: plan.id,
        tx: tx.id() as u64,
        tasks: written,
    })
}

pub async fn plans_write(f: &Front, c: &Caller, p: WriteParams) -> Result<PlanWritten, Error> {
    may_change(f, c, p.plan.as_ref().map(|i| i.as_str().to_owned())).await?;
    may_finish(f, c, &p).await?;
    let scope = scope_of(f, c).await?;
    f.writer
        .write(c, "plans/write", move |tx| write_plan(tx, &p, &scope))
        .await
        .map_err(fail)
}

/// A task an agent marks `done` is the matrix's `task.done` (never for a worker), not just `graph.change`: the
/// status is the same fact the review and the user's own close write.
async fn may_finish(f: &Front, c: &Caller, p: &WriteParams) -> Result<(), Error> {
    use crate::matrix_gate::{ActionCtx, Gate};
    if c.class != Class::Agent
        || !p
            .tasks
            .0
            .iter()
            .any(|t| t.status.as_ref().is_some_and(|s| s.as_str() == "done"))
    {
        return Ok(());
    }
    let who = c
        .sid
        .as_deref()
        .and_then(|s| f.core.agents.who(s))
        .unwrap_or(norn::matrix::Who {
            role: Some(norn::matrix::Role::Worker),
            ..Default::default()
        });
    let ctx = ActionCtx {
        session: c.sid.clone(),
        plan: p.plan.as_ref().map(|i| i.as_str().to_owned()),
        ..Default::default()
    };
    match f
        .core
        .matrix
        .decide(
            &f.settings,
            &f.writer,
            who,
            norn::matrix::Action::TaskDone,
            ctx,
        )
        .await
    {
        Gate::Allow => Ok(()),
        Gate::Ask(card) => Err(refuse(format!(
            "marking a task done asks the user first (card {card}); write the plan again once it is settled"
        ))),
        Gate::Never(why) => Err(refuse(why)),
    }
}

// ---- reports ----------------------------------------------------------------------------------------------------

pub(crate) fn report_of(conn: &Tx, e: &Ent) -> Result<Report, CoordError> {
    let task = dsts(conn, e.n, "report_of")?
        .into_iter()
        .find_map(|n| live(conn, n).ok().flatten())
        .map(|t| t.id)
        .or_else(|| str_of(e, "task"))
        .unwrap_or_default();
    let list = |k: &str| -> Vec<String> {
        e.data
            .get(k)
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    };
    let typed = |k: &str| e.data.get(k).cloned().unwrap_or(Value::Null);
    Ok(Report {
        id: e.id.clone(),
        task,
        session: str_of(e, "session"),
        agent: str_of(e, "agent"),
        at: e.data.get("at").and_then(Value::as_f64).unwrap_or(0.0),
        tip: str_of(e, "tip").unwrap_or_default(),
        commits: list("commits"),
        checks: serde_json::from_value::<Vec<CheckRun>>(typed("checks")).unwrap_or_default(),
        decisions: serde_json::from_value::<Vec<DecisionRef>>(typed("decisions"))
            .unwrap_or_default(),
        differences: str_of(e, "differences"),
        interfaces: str_of(e, "interfaces"),
        followups: list("followups"),
        unrecorded: list("unrecorded"),
    })
}

pub async fn reports_get(f: &Front, c: &Caller, p: ReportsParams) -> Result<Reports, Error> {
    let scope = scope_of(f, c).await?;
    reports_get_in(f, scope, p).await
}

/// `reports/get` for a caller whose reach is SCOPE: a report or task of another project is refused.
pub(crate) async fn reports_get_in(
    f: &Front,
    scope: Scope,
    p: ReportsParams,
) -> Result<Reports, Error> {
    f.writer
        .db
        .read(move |c| {
            let owner = |e: &Ent| -> Result<Option<String>, CoordError> {
                match e.project {
                    Some(n) => Ok(live(c, n)?.map(|p| p.id)),
                    None => Ok(None),
                }
            };
            let ents = match (&p.task, &p.id) {
                (Some(t), _) => {
                    let t = entity::by_id(c, t.as_str())?
                        .ok_or_else(|| CoordError::Refused(format!("no task {}", t.as_str())))?;
                    scope.allows_project(owner(&t)?.as_deref())?;
                    reports_of(c, t.n)?
                }
                (_, Some(id)) => vec![
                    entity::by_id(c, id.as_str())?
                        .filter(|e| e.kind == "report" && e.retired_tx.is_none())
                        .ok_or_else(|| CoordError::Refused(format!("no report {}", id.as_str())))?,
                ],
                _ => Vec::new(),
            };
            for e in &ents {
                scope.allows_project(owner(e)?.as_deref())?;
            }
            let reports = ents
                .iter()
                .map(|e| report_of(c, e))
                .collect::<Result<_, _>>()?;
            Ok(Reports { reports })
        })
        .await
        .map_err(fail)
}

/// The task entity of a session's `task` and `job` (a `task:` id, `JOB#N`, or `N` with the job).
fn task_entity(task: &str, job: Option<&str>) -> Option<String> {
    if task.starts_with("task:") {
        Some(task.to_owned())
    } else if task.contains('#') {
        Some(norn::write::tasks::entity_id(task))
    } else {
        Some(norn::write::tasks::entity_id(&format!("{}#{task}", job?)))
    }
}

/// The last fenced `drgnx-report` block of TEXT as a report; `None` when there is no block.  A block that is not a
/// valid report is an error (the schema is the tool's).
pub fn fallback_block(text: &str) -> Option<Result<ReportSubmit, String>> {
    let start = text.rfind("```drgnx-report")?;
    let rest = &text[start + "```drgnx-report".len()..];
    let body = rest.split("```").next().unwrap_or(rest);
    Some(serde_json::from_str::<ReportSubmit>(body.trim()).map_err(|e| e.to_string()))
}

/// A session that has no drgnx tools ended its turn with a `drgnx-report` block in MESSAGE: validate it and submit it
/// as that session's agent (the same filing as `report_submit`).  Nothing happens without a block, without a task, or
/// when the task is already in review or done.  Answers the report's id.
pub async fn submit_fallback(
    writer: &Writer,
    session: &str,
    task: Option<&str>,
    job: Option<&str>,
    message: &str,
) -> Option<Result<String, String>> {
    let report = fallback_block(message)?;
    let task = task_entity(task?, job)?;
    let report = match report {
        Ok(r) => r,
        Err(e) => {
            return Some(Err(format!(
                "the drgnx-report block is not a valid report: {e}"
            )));
        }
    };
    let caller = crate::runner::service();
    let sid = session.to_owned();
    let out = writer
        .write(&caller, "reports/fallback", move |tx| {
            let status = entity::by_id(tx.sql(), &task)?.and_then(|e| e.status);
            if matches!(status.as_deref(), Some("in-review" | "done")) {
                return Ok(None);
            }
            norn::write::reports::file(tx, &task, &sid, Some(&sid), &report, now()).map(Some)
        })
        .await;
    match out {
        Ok(Some(filed)) => {
            writer.signals.events_soon();
            Some(Ok(filed.report))
        }
        Ok(None) => None,
        Err(e) => Some(Err(e.to_string())),
    }
}

// ---- commits and decisions --------------------------------------------------------------------------------------

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

/// The commits of REPO's HEAD that BASE does not have, oldest first, merge commits left out (the hub's own are never
/// linked), each with its subject.
fn commits_since(repo: &Path, base: &str) -> Vec<(String, String)> {
    let range = format!("{base}..HEAD");
    git(
        repo,
        &[
            "log",
            "--reverse",
            "--no-merges",
            "--format=%H%x09%s",
            &range,
        ],
    )
    .map(|o| {
        o.lines()
            .filter_map(|l| {
                let (sha, subject) = l.split_once('\t')?;
                Some((sha.to_owned(), subject.to_owned()))
            })
            .collect()
    })
    .unwrap_or_default()
}

/// Make each of COMMITS (sha, subject; oldest first) an entity and link it (`implements`) to every decision SESSION
/// recorded that no commit implements yet; a commit already known is left as it is.  Decisions recorded before the
/// session's next commit belong to that commit (the brief asks for one commit per decision); none: unlinked.
pub fn link_commits_in(
    tx: &mut WTx<'_>,
    session: &str,
    repo: &Path,
    commits: &[(String, String)],
) -> Result<Vec<String>, CoordError> {
    let mut made = Vec::new();
    for (sha, subject) in commits {
        let id = format!("commit:{sha}");
        if entity::by_id(tx.sql(), &id)?.is_some() {
            continue;
        }
        let project = tx.meta().project;
        let c = entity::create(
            tx,
            EntityNew {
                id: id.clone(),
                kind: "commit".into(),
                project,
                title: Some(subject.clone()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({"sha": sha, "repo": repo.to_string_lossy(), "session": session}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        let open: Vec<i64> = {
            let mut st = tx.sql().prepare(
                "select n from entity where kind = 'decision' and retired_tx is null \
                 and json_extract(data, '$.session') = ?1 \
                 and n not in (select dst from link where kind = 'implements' and tx_to = ?2) order by n",
            )?;
            let rows = st.query_map((session, SENTINEL), |r| r.get(0))?;
            rows.collect::<Result<_, _>>()?
        };
        for d in open {
            link::add(tx, c.n, "implements", d, None, Origin::Recorded, None)?;
        }
        made.push(id);
    }
    Ok(made)
}

/// After a tool step of SESSION in CWD (a task's tree): link the commits the task's branch has gained since the job
/// branch.  Best effort; git runs in a blocking task.
pub async fn link_new_commits(writer: &Writer, session: &str, task: &str, cwd: &Path) {
    let Some(job) = task.strip_prefix("task:").unwrap_or(task).split_once('#') else {
        return;
    };
    let (dir, base) = (cwd.to_path_buf(), format!("job/{}", job.0));
    let commits = tokio::task::spawn_blocking(move || commits_since(&dir, &base))
        .await
        .unwrap_or_default();
    if commits.is_empty() {
        return;
    }
    let (sid, dir) = (session.to_owned(), cwd.to_path_buf());
    let caller = crate::runner::service();
    if let Err(e) = writer
        .write(&caller, "commits/link", move |tx| {
            link_commits_in(tx, &sid, &dir, &commits)
        })
        .await
    {
        tracing::warn!(session, "commits not linked: {e}");
    }
}

/// One changed range of a commit: the path, and the old and new line ranges (first, last).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Range {
    pub path: String,
    pub old: (u64, u64),
    pub new: (u64, u64),
}

fn span(start: u64, len: u64) -> (u64, u64) {
    (start, start + len.max(1) - 1)
}

/// The ranges COMMIT changed (`git diff-tree -U0`, renames off).
pub fn hunks_of(repo: &Path, commit: &str) -> Vec<Range> {
    let Ok(out) = git(
        repo,
        &[
            "diff-tree",
            "--root",
            "-p",
            "-U0",
            "--no-color",
            "--no-renames",
            "--no-commit-id",
            "-r",
            commit,
        ],
    ) else {
        return Vec::new();
    };
    let (mut path, mut ranges) = (String::new(), Vec::new());
    for line in out.lines() {
        if let Some(p) = line.strip_prefix("+++ b/") {
            path = p.to_owned();
        } else if line.starts_with("--- /dev/null") || line.starts_with("--- a/") {
            // the old side's name; the new side names the path
        } else if let Some(h) = line.strip_prefix("@@ -") {
            let mut it = h.split(' ');
            let (Some(old), Some(new)) = (it.next(), it.next()) else {
                continue;
            };
            let pair = |s: &str| -> Option<(u64, u64)> {
                let s = s.trim_start_matches('+');
                let (a, b) = s.split_once(',').unwrap_or((s, "1"));
                Some((a.parse().ok()?, b.parse().ok()?))
            };
            if let (Some((os, ol)), Some((ns, nl))) = (pair(old), pair(new)) {
                ranges.push(Range {
                    path: path.clone(),
                    old: span(os, ol),
                    new: span(ns, nl),
                });
            }
        }
    }
    ranges
}

fn overlap(a: (u64, u64), b: (u64, u64)) -> bool {
    a.0 <= b.1 && b.0 <= a.1
}

/// The later changes that touched lines COMMITS changed: for each commit, every commit after it on HEAD whose old
/// side overlaps the commit's new side, as the lines of the commit's change that were touched again.  Computed from
/// git; line numbers are not followed through the commits between (an approximation, labelled `computed`).
pub fn later_hunks(repo: &Path, commits: &[String]) -> Vec<Hunk> {
    let mut out: Vec<Hunk> = Vec::new();
    for c in commits {
        let mine = hunks_of(repo, c);
        if mine.is_empty() {
            continue;
        }
        let range = format!("{c}..HEAD");
        let Ok(later) = git(repo, &["rev-list", "--reverse", "--no-merges", &range]) else {
            continue;
        };
        for l in later.lines().filter(|l| !commits.iter().any(|x| x == l)) {
            for h in hunks_of(repo, l) {
                for m in mine.iter().filter(|m| m.path == h.path) {
                    if overlap(h.old, m.new) {
                        let hunk = Hunk {
                            commit: l.to_owned(),
                            path: h.path.clone(),
                            lines: (h.old.0.max(m.new.0), h.old.1.min(m.new.1)),
                        };
                        if !out.contains(&hunk) {
                            out.push(hunk);
                        }
                    }
                }
            }
        }
    }
    out
}

pub async fn decision_effects(f: &Front, _: &Caller, p: EffectsParams) -> Result<Effects, Error> {
    let raw = p.decision.as_str().to_owned();
    let id = if raw.starts_with("decision:") {
        raw
    } else {
        format!("decision:{}", raw.trim_start_matches('#'))
    };
    let key = id.clone();
    let commits: Vec<(String, Option<String>)> = f
        .writer
        .db
        .read(move |c| {
            let d = entity::by_id(c, &key)?
                .filter(|e| e.kind == "decision" && e.retired_tx.is_none())
                .ok_or_else(|| CoordError::Refused(format!("no decision {key}")))?;
            let mut out = Vec::new();
            for n in srcs(c, d.n, "implements")? {
                if let Some(e) = live(c, n)?.filter(|e| e.kind == "commit") {
                    out.push((
                        str_of(&e, "sha")
                            .unwrap_or_else(|| e.id.trim_start_matches("commit:").into()),
                        str_of(&e, "repo"),
                    ));
                }
            }
            Ok(out)
        })
        .await
        .map_err(fail)?;
    let shas: Vec<String> = commits.iter().map(|(s, _)| s.clone()).collect();
    let repo = commits
        .iter()
        .find_map(|(_, r)| r.as_ref().map(PathBuf::from))
        .filter(|r| r.is_dir());
    let later_hunks = match repo {
        Some(repo) => {
            let shas = shas.clone();
            tokio::task::spawn_blocking(move || later_hunks(&repo, &shas))
                .await
                .map_err(|e| internal(e.to_string()))?
        }
        None => Vec::new(),
    };
    Ok(Effects {
        decision: id,
        commits: shas,
        later_hunks,
        label: "computed".into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use norn::store::CoordDb;
    use norn::write::decisions::{Decide, decide};
    use runstav::methods::plans::TaskWrite;
    use runstav::types::Bounded;

    fn sh(dir: &Path, args: &[&str]) {
        let ok = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    }

    fn repo() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        sh(d.path(), &["init", "-q", "-b", "main"]);
        d
    }

    fn commit(dir: &Path, file: &str, text: &str, msg: &str) -> String {
        std::fs::write(dir.join(file), text).unwrap();
        sh(dir, &["add", "."]);
        sh(dir, &["commit", "-q", "-m", msg]);
        git(dir, &["rev-parse", "HEAD"]).unwrap().trim().to_owned()
    }

    fn lines(n: usize) -> String {
        (1..=n).map(|i| format!("line {i}\n")).collect()
    }

    #[test]
    fn effects_finds_overlapping_later_hunks() {
        let d = repo();
        let c1 = commit(d.path(), "a.txt", &lines(10), "base");
        let c2 = commit(
            d.path(),
            "a.txt",
            &lines(10).replace("line 3", "THREE"),
            "decision",
        );
        let c3 = commit(
            d.path(),
            "a.txt",
            &lines(10)
                .replace("line 3", "THREE")
                .replace("line 9", "NINE"),
            "far away",
        );
        let c4 = commit(
            d.path(),
            "a.txt",
            &lines(10)
                .replace("line 3", "again")
                .replace("line 9", "NINE"),
            "same lines",
        );
        let found = later_hunks(d.path(), std::slice::from_ref(&c2));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].commit, c4);
        assert_eq!(found[0].path, "a.txt");
        assert_eq!(found[0].lines, (3, 3));
        assert!(!found.iter().any(|h| h.commit == c3 || h.commit == c1));
    }

    fn meta() -> urdr::graph::TxMeta {
        urdr::graph::TxMeta::new("t", urdr::graph::Class::System, "test")
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn commit_links_to_the_turns_decision() {
        let d = repo();
        commit(d.path(), "a.txt", "x\n", "base");
        sh(d.path(), &["branch", "job/j"]);
        let first = commit(d.path(), "a.txt", "y\n", "first");
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let commits = commits_since(d.path(), "job/j");
        assert_eq!(commits.len(), 1);
        assert_eq!(commits[0].0, first);
        let (repo_dir, c2) = (d.path().to_path_buf(), commits.clone());
        let (made, again, linked) = db
            .write(meta(), move |tx| {
                // a decision this session recorded, one another session recorded
                for (author, session) in [("a1", "s1"), ("a2", "s2")] {
                    let r = decide(
                        tx,
                        Decide {
                            kind: "build".into(),
                            subject: format!("by {author}"),
                            author: author.into(),
                            ..Decide::default()
                        },
                        10.0,
                    )?;
                    let norn::write::decisions::DecideResult::Ok { n, .. } = r else {
                        panic!("{r:?}")
                    };
                    let e = entity::by_id(tx.sql(), &format!("decision:{n}"))?.unwrap();
                    entity::update(
                        tx,
                        e.n,
                        None,
                        Changes {
                            data_patch: Some(json!({"session": session})),
                            ..Changes::default()
                        },
                    )?;
                }
                let made = link_commits_in(tx, "s1", &repo_dir, &c2)?;
                let again = link_commits_in(tx, "s1", &repo_dir, &c2)?;
                let mut st = tx.sql().prepare(
                    "select d.title from link l join entity d on d.n = l.dst join entity c on c.n = l.src \
                     where l.kind = 'implements' and c.kind = 'commit' and l.tx_to = ?1",
                )?;
                let linked: Vec<String> = st
                    .query_map([SENTINEL], |r| r.get(0))?
                    .collect::<Result<_, _>>()?;
                Ok((made, again, linked))
            })
            .await
            .unwrap();
        assert_eq!(made, vec![format!("commit:{first}")]);
        assert!(again.is_empty());
        assert_eq!(linked, vec!["by a1".to_owned()]);
    }

    fn write_task(number: &str, blocks: &[&str]) -> TaskWrite {
        serde_json::from_value(json!({"number": number, "title": format!("task {number}"),
            "blocks": blocks}))
        .unwrap()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_plan_round_trips_and_reports_feed_its_interfaces() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let p = WriteParams {
            plan: None,
            project: None,
            title: Some(serde_json::from_value(json!("P")).unwrap()),
            tasks: Bounded(vec![write_task("1", &[]), write_task("2", &["1"])]),
            base_version: None,
        };
        let p2 = p.clone();
        let (w, deps, ri, status, stale) = db
            .write(meta(), move |tx| {
                let w = write_plan(tx, &p2, &Scope::Anyone)?;
                let deps = load(tx.sql(), &w.plan)?.view.tasks[1].deps.clone();
                // task 1 reports its interfaces; plan_read shows them beside task 1
                let r: ReportSubmit =
                    serde_json::from_value(json!({"tip": "abc", "interfaces": "fn x()"})).unwrap();
                norn::write::reports::file(tx, &w.tasks[0].id, "a1", Some("s1"), &r, 5.0)?;
                let view = load(tx.sql(), &w.plan)?.view;
                let stale = WriteParams {
                    plan: Some(serde_json::from_value(json!(w.plan)).unwrap()),
                    tasks: Bounded(vec![write_task("1", &[])]),
                    base_version: Some(0),
                    ..p2.clone()
                };
                let stale = write_plan(tx, &stale, &Scope::Anyone).is_err();
                Ok((
                    w.clone(),
                    deps,
                    view.tasks[0].report_interfaces.clone(),
                    view.tasks[0].status.clone(),
                    stale,
                ))
            })
            .await
            .unwrap();
        assert_eq!(w.tasks.len(), 2);
        assert_eq!(deps, vec!["1".to_owned()]);
        assert_eq!(ri.as_deref(), Some("fn x()"));
        assert_eq!(status, "in-review");
        assert!(stale);
    }

    fn project_entity(tx: &mut WTx<'_>, id: &str) -> Result<(), CoordError> {
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "project".into(),
                project: None,
                title: Some(id.into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        Ok(())
    }

    /// S4: an agent in project A neither reads, changes nor creates plans of project B.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_agent_reaches_its_own_projects_plans_only() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        db.write(meta(), move |tx| {
            project_entity(tx, "project:a")?;
            project_entity(tx, "project:b")?;
            let plan_in = |project: &str| WriteParams {
                plan: None,
                project: Some(serde_json::from_value(json!(project)).unwrap()),
                title: Some(serde_json::from_value(json!("P")).unwrap()),
                tasks: Bounded(vec![write_task("1", &[])]),
                base_version: None,
            };
            let theirs = write_plan(tx, &plan_in("project:b"), &Scope::Anyone)?;
            let mine = Scope::Project {
                id: Some("project:a".into()),
                root: None,
            };
            // reads
            let view = load(tx.sql(), &theirs.plan)?.view;
            assert!(mine.allows_project(view.project.as_deref()).is_err());
            assert!(
                Scope::Anyone
                    .allows_project(view.project.as_deref())
                    .is_ok()
            );
            // changes, `done` included
            let change = WriteParams {
                plan: Some(serde_json::from_value(json!(theirs.plan)).unwrap()),
                project: None,
                title: None,
                tasks: Bounded(vec![
                    serde_json::from_value(json!({"number": "1", "status": "done"})).unwrap(),
                ]),
                base_version: None,
            };
            assert!(write_plan(tx, &change, &mine).is_err());
            assert_eq!(
                load(tx.sql(), &theirs.plan)?.view.tasks[0].status,
                "open",
                "the refused write changed nothing"
            );
            // creating one in B is refused; with no project it lands in A
            assert!(write_plan(tx, &plan_in("project:b"), &mine).is_err());
            let none = WriteParams {
                project: None,
                ..plan_in("project:a")
            };
            let own = write_plan(tx, &none, &mine)?;
            assert_eq!(
                load(tx.sql(), &own.plan)?.view.project.as_deref(),
                Some("project:a")
            );
            // an agent in no project reaches no project's plan
            let nowhere = Scope::Project {
                id: None,
                root: None,
            };
            assert!(write_plan(tx, &change, &nowhere).is_err());
            Ok(())
        })
        .await
        .unwrap();
    }

    /// S4: a proposal is about a file; an agent reaches those under its own project's root.
    #[test]
    fn an_agent_reaches_proposals_about_its_own_projects_files_only() {
        let mine = Scope::Project {
            id: Some("project:a".into()),
            root: Some("/work/a".into()),
        };
        assert!(mine.allows_path(Path::new("/work/a/docs/x.md")).is_ok());
        assert!(mine.allows_path(Path::new("/work/b/docs/x.md")).is_err());
        assert!(mine.allows_path(Path::new("/work/ab/x.md")).is_err());
        let nowhere = Scope::Project {
            id: None,
            root: None,
        };
        assert!(nowhere.allows_path(Path::new("/work/a/x.md")).is_err());
        assert!(Scope::Anyone.allows_path(Path::new("/work/b/x.md")).is_ok());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_fallback_report_block_is_submitted() {
        let msg = "done.\n```drgnx-report\n{\"tip\": \"abc\", \"interfaces\": \"fn y()\"}\n```\n";
        let r = fallback_block(msg).unwrap().unwrap();
        assert_eq!(r.tip.as_str(), "abc");
        assert!(fallback_block("no block").is_none());
        assert!(
            fallback_block("```drgnx-report\n{\"tip\": 1}\n```")
                .unwrap()
                .is_err()
        );
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let job = norn::write::jobs::NewJob {
            id: "J".into(),
            title: "j".into(),
            plan: None,
            repo: None,
            tasks: vec![norn::write::jobs::NewTask {
                n: 1,
                title: "t".into(),
                role: None,
                deps: vec![],
            }],
            data: None,
        };
        db.write(meta(), move |tx| {
            norn::write::jobs::job_create(tx, job, 1.0)
        })
        .await
        .unwrap();
        let w = Writer {
            db: db.clone(),
            signals: Default::default(),
        };
        let id = submit_fallback(&w, "s1", Some("1"), Some("J"), msg)
            .await
            .unwrap()
            .unwrap();
        assert!(id.starts_with("report:"));
        let (iface, status) = db
            .read(move |c| {
                let e = entity::by_id(c, &id)?.unwrap();
                let t = entity::by_id(c, "task:J#1")?.unwrap();
                Ok((str_of(&e, "interfaces"), t.status))
            })
            .await
            .unwrap();
        assert_eq!(iface.as_deref(), Some("fn y()"));
        assert_eq!(status.as_deref(), Some("in-review"));
        // a second block for a task in review is ignored
        assert!(
            submit_fallback(&w, "s1", Some("1"), Some("J"), msg)
                .await
                .is_none()
        );
    }
}
