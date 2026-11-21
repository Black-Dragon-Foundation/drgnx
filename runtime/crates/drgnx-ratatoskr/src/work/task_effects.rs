//! The effect of a change on the tasks under way (`review/effects`; docs/develop/hub.md, "The effect on tasks"): what
//! would happen to each running or queued task if a spec, a plan or code changed as the review shows.
//!
//! The chain walked: the change → its record (the plan's tasks, old aligned to new) → the runs of that plan → each
//! task → its `works_on` session → that session's files. The pure part ([`of_plan_edit`], [`of_code`]) takes the
//! tasks as [`Live`] rows and does no I/O; [`effects`] reads them from the store, the agents and the presence model.
//!
//! Tasks are matched old to new by their text first (a renumbered task is the same task), then by number with a
//! similar text, then by the most similar text; a task with no match was removed.

use crate::agents::session::{internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::work::{ChangeRef, Effect, EffectsParams, TaskEffect, TaskState};
use runstav::wire::Error;
use saga::plan::{PlanDoc, TaskDoc};
use std::path::{Path, PathBuf};

/// A task the change may reach: a run's task that is under way or queued.
#[derive(Clone, Debug, PartialEq)]
pub struct Live {
    /// `JOB#N`.
    pub task: String,
    /// Its number in the plan the run started from.
    pub n: i64,
    pub title: String,
    /// The plan file of its run.
    pub plan: Option<PathBuf>,
    pub state: TaskState,
    /// The session working on it (`works_on`), and its name.
    pub session: Option<String>,
    pub agent: Option<String>,
    /// The files its agent edited and is reading now, relative to its worktree.
    pub edits: Vec<String>,
    pub reads: Vec<String>,
}

/// How similar two texts must be (`similar`'s line ratio) for a task to be the same task under another number.
const SAME_TASK: f32 = 0.5;

/// A task's own text: its title and body, without its number (so a renumbered task reads the same).
fn own_text(t: &TaskDoc) -> String {
    format!("{}\n{}", t.title.trim(), t.body)
}

/// The text every task of the plan shares: the sections before the first task, between tasks and after the last.
fn shared_text(p: &PlanDoc) -> String {
    let mut out = String::new();
    let sections = p
        .preamble
        .iter()
        .chain(p.tasks.iter().flat_map(|t| t.after.iter()))
        .chain(p.rest.iter());
    for s in sections {
        out.push_str(&s.heading);
        out.push_str(&s.body);
    }
    out
}

fn ratio(a: &str, b: &str) -> f32 {
    similar::TextDiff::from_lines(a, b).ratio()
}

/// For each task of OLD, the index of the same task in NEW (none: removed): by text, then by number with a similar
/// text, then by the most similar text.
pub fn align(old: &[TaskDoc], new: &[TaskDoc]) -> Vec<Option<usize>> {
    let mut out: Vec<Option<usize>> = vec![None; old.len()];
    let mut used = vec![false; new.len()];
    let texts: Vec<String> = new.iter().map(own_text).collect();
    for (i, o) in old.iter().enumerate() {
        let t = own_text(o);
        if let Some(j) = (0..new.len()).find(|&j| !used[j] && texts[j] == t) {
            (out[i], used[j]) = (Some(j), true);
        }
    }
    for (i, o) in old.iter().enumerate() {
        if out[i].is_some() {
            continue;
        }
        let t = own_text(o);
        if let Some(j) = (0..new.len())
            .find(|&j| !used[j] && new[j].number == o.number && ratio(&t, &texts[j]) >= SAME_TASK)
        {
            (out[i], used[j]) = (Some(j), true);
        }
    }
    for (i, o) in old.iter().enumerate() {
        if out[i].is_some() {
            continue;
        }
        let t = own_text(o);
        let best = (0..new.len())
            .filter(|&j| !used[j])
            .map(|j| (j, ratio(&t, &texts[j])))
            .filter(|&(_, r)| r >= SAME_TASK)
            .max_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((j, _)) = best {
            (out[i], used[j]) = (Some(j), true);
        }
    }
    out
}

/// What the task's state says in a sentence: "is running", "is queued"…
fn state_words(s: TaskState) -> &'static str {
    match s {
        TaskState::Running => "is running",
        TaskState::NeedsInput => "is waiting for an answer",
        TaskState::InReview => "is in review",
        TaskState::Queued => "is queued",
    }
}

fn effect(t: &Live, effect: Effect, why: String) -> TaskEffect {
    TaskEffect {
        task: t.task.clone(),
        task_title: t.title.clone(),
        plan: t.plan.as_ref().map(|p| p.to_string_lossy().into_owned()),
        agent: t.agent.clone(),
        state: t.state,
        effect,
        why,
    }
}

fn stops(t: &Live) -> TaskEffect {
    let then = if t.state == TaskState::Queued {
        "it would not start"
    } else {
        "it would stop"
    };
    effect(
        t,
        Effect::Stops,
        format!("Task {} {}: {then}.", t.n, state_words(t.state)),
    )
}

/// Whether a plan's or spec's text retires it: no text, or a `**Status:**` (`Status:`) that says it is dropped,
/// superseded or rejected.
pub fn retired(text: Option<&str>) -> bool {
    let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
        return true;
    };
    text.lines()
        .find_map(|l| {
            l.trim()
                .strip_prefix("**Status:**")
                .or_else(|| l.trim().strip_prefix("Status:"))
        })
        .is_some_and(|s| saga::status::normalize(s.trim()) == "dropped")
}

/// The effect of the plan going from OLD to NEW (none or retired: the plan is gone) on TASKS, its runs' tasks: a
/// removed task stops, a running task whose own text or the plan's shared text changed gets a steer.
pub fn of_plan_edit(old: &str, new: Option<&str>, tasks: &[Live]) -> Vec<TaskEffect> {
    if retired(new) {
        return tasks.iter().map(stops).collect();
    }
    let (old, new) = (saga::plan::parse(old), saga::plan::parse(new.unwrap_or("")));
    let matched = align(&old.tasks, &new.tasks);
    let shared_changed = shared_text(&old) != shared_text(&new);
    let mut out = Vec::new();
    for t in tasks {
        let n = t.n.to_string();
        let Some(i) = old.tasks.iter().position(|o| o.number == n) else {
            continue;
        };
        match matched[i] {
            None => out.push(stops(t)),
            Some(_) if t.state == TaskState::Queued => {}
            Some(j) if shared_changed || own_text(&old.tasks[i]) != own_text(&new.tasks[j]) => {
                out.push(effect(
                    t,
                    Effect::BriefChanges,
                    format!(
                        "Task {} {}: its brief changes; the agent gets a steer.",
                        t.n,
                        state_words(t.state)
                    ),
                ));
            }
            Some(_) => {}
        }
    }
    out
}

fn file_name(p: &str) -> &str {
    p.rsplit('/').next().unwrap_or(p)
}

/// The effect of a code change on PATHS (relative to the repository) on TASKS: a task under way whose agent edits or
/// reads one of them would need to rebase. BRANCH, the change's own branch, leaves out the task working on it.
pub fn of_code(paths: &[String], branch: Option<&str>, tasks: &[Live]) -> Vec<TaskEffect> {
    let mut out = Vec::new();
    for t in tasks.iter().filter(|t| t.state != TaskState::Queued) {
        if branch.is_some_and(|b| own_branch(&t.task) == b) {
            continue;
        }
        let hit = |files: &[String]| files.iter().find(|f| paths.contains(f)).cloned();
        let (verb, file) = match (hit(&t.edits), hit(&t.reads)) {
            (Some(f), _) => ("edits", f),
            (None, Some(f)) => ("reads", f),
            (None, None) => continue,
        };
        out.push(effect(
            t,
            Effect::Overlaps,
            format!(
                "Task {} {verb} {}: it would need to rebase.",
                t.n,
                file_name(&file)
            ),
        ));
    }
    out
}

/// The branch the runner makes for task `JOB#N`: `job/JOB-N`.
fn own_branch(task: &str) -> String {
    format!("job/{}", task.replacen('#', "-", 1))
}

/// A run's task row as the store has it.
struct Row {
    task: String,
    n: i64,
    title: String,
    status: String,
    job_status: String,
    plan: Option<String>,
    session: Option<String>,
    agent: Option<String>,
}

/// The state of a task with STATUS in a run with JOB_STATUS; none: not started or done.
fn state_of(status: &str, job_status: &str) -> Option<TaskState> {
    match status {
        "claimed" | "running" => Some(TaskState::Running),
        "needs-input" => Some(TaskState::NeedsInput),
        "in-review" => Some(TaskState::InReview),
        "ready" | "pending" if matches!(job_status, "running" | "paused") => {
            Some(TaskState::Queued)
        }
        _ => None,
    }
}

/// Every run task under way or queued, with its session (the latest `works_on` link to it).
async fn rows(f: &Front) -> Result<Vec<Row>, Error> {
    f.writer
        .db
        .read(|c| {
            let mut st = c.prepare(
                "select t.id, coalesce(json_extract(t.data, '$.n'), 0), coalesce(t.title, ''), \
                 coalesce(t.status, ''), j.status, j.plan, s.id, s.title \
                 from entity t join job j on j.id = json_extract(t.data, '$.job') \
                 left join link l on l.dst = t.n and l.kind = 'works_on' and l.tx_to = ?1 \
                   and l.src = (select max(l2.src) from link l2 where l2.dst = t.n and l2.kind = 'works_on' \
                                and l2.tx_to = ?1) \
                 left join entity s on s.n = l.src \
                 where t.kind = 'task' and t.retired_tx is null \
                 order by t.id",
            )?;
            let rows = st
                .query_map([urdr::graph::schema::SENTINEL], |r| {
                    Ok(Row {
                        task: r
                            .get::<_, String>(0)?
                            .trim_start_matches("task:")
                            .to_owned(),
                        n: r.get(1)?,
                        title: r.get(2)?,
                        status: r.get(3)?,
                        job_status: r.get(4)?,
                        plan: r.get(5)?,
                        session: r.get(6)?,
                        agent: r.get(7)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(crate::coord::fail)
}

/// PATH by its true name (as written when it does not exist).
fn true_path(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// The tasks under way or queued; with FILES, each with its agent's edited and read files.
async fn live(f: &Front, files: bool) -> Result<Vec<Live>, Error> {
    let mut out = Vec::new();
    for r in rows(f).await? {
        let Some(state) = state_of(&r.status, &r.job_status) else {
            continue;
        };
        let sid = r
            .session
            .as_deref()
            .map(|s| s.trim_start_matches("session:").to_owned());
        let (mut edits, mut reads) = (Vec::new(), Vec::new());
        if files && let Some(sid) = &sid {
            if let Ok(Some(c)) = crate::work::edits::edited(f, sid).await {
                edits = c.files.into_iter().map(|c| c.path).collect();
            }
            if let Some(tree) = f.core.agents.worktree(sid) {
                let tree = true_path(&tree);
                for (file, entries) in f.core.presence.all_now() {
                    if entries.iter().any(|e| e.session == *sid)
                        && let Ok(rel) = Path::new(&file).strip_prefix(&tree)
                    {
                        reads.push(rel.to_string_lossy().into_owned());
                    }
                }
            }
        }
        out.push(Live {
            task: r.task,
            n: r.n,
            title: r.title,
            plan: r.plan.map(PathBuf::from),
            state,
            session: sid,
            agent: r.agent,
            edits,
            reads,
        });
    }
    Ok(out)
}

/// The text of git object FROM (a blob id) in the repository DOC is in, read in its main checkout (never in an agent's
/// tree).
fn old_text(doc: &Path, from: &str) -> Result<String, Error> {
    if !(from.len() == 40 || from.len() == 64) || !from.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(invalid("from", "a git blob id (40 or 64 hex digits)"));
    }
    let main = crate::work::presence::main_checkout(doc)
        .ok_or_else(|| invalid("doc", "the document is not in a git repository"))?;
    let out = std::process::Command::new("git")
        .args(["cat-file", "blob", from])
        .current_dir(&main)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|e| internal(format!("git: {e}")))?;
    if !out.status.success() {
        return Err(invalid("from", "no such blob in the document's repository"));
    }
    String::from_utf8(out.stdout).map_err(|_| invalid("from", "the old text is not UTF-8"))
}

/// The plan files a spec at SPEC is the source of (`derives` links from a plan to the spec's record).
async fn plans_of_spec(f: &Front, spec: &Path) -> Result<Vec<PathBuf>, Error> {
    let source = saga::import::source_key(spec);
    let ids: Vec<(String, Option<String>)> = f
        .writer
        .db
        .read(move |c| {
            let mut st = c.prepare(
                "select a.id, json_extract(a.data, '$.records.file') from link l \
                 join entity a on a.n = l.src join entity b on b.n = l.dst \
                 where b.source = ?1 and b.kind = 'spec' and l.kind = 'derives' and l.tx_to = ?2 \
                 and a.retired_tx is null",
            )?;
            let rows = st
                .query_map((source, urdr::graph::schema::SENTINEL), |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(crate::coord::fail)?;
    Ok(ids
        .into_iter()
        .filter_map(|(id, file)| {
            file.or_else(|| {
                id.strip_prefix("plan:")
                    .filter(|p| p.starts_with('/'))
                    .map(str::to_owned)
            })
        })
        .map(|p| true_path(Path::new(&p)))
        .collect())
}

/// `review/effects`.
pub async fn effects(f: &Front, _: &Caller, p: EffectsParams) -> Result<Vec<TaskEffect>, Error> {
    match p.change {
        ChangeRef::Code(c) => {
            let tasks = live(f, true).await?;
            Ok(of_code(&c.paths, c.branch.as_deref(), &tasks))
        }
        ChangeRef::Doc(d) => {
            if !d.doc.is_absolute() {
                return Err(invalid("doc", "an absolute path"));
            }
            let doc = true_path(&d.doc);
            let old = old_text(&doc, &d.from)?;
            let new = std::fs::read_to_string(&doc).ok();
            let tasks = live(f, false).await?;
            let of_plan = |plan: &Path| -> Vec<Live> {
                tasks
                    .iter()
                    .filter(|t| t.plan.as_deref().map(true_path).as_deref() == Some(plan))
                    .cloned()
                    .collect()
            };
            let runs = of_plan(&doc);
            if !runs.is_empty() {
                return Ok(of_plan_edit(&old, new.as_deref(), &runs));
            }
            // a spec: retiring it stops every task of the plans made from it
            if retired(new.as_deref()) && !retired(Some(&old)) {
                let mut out = Vec::new();
                for plan in plans_of_spec(f, &doc).await? {
                    out.extend(of_plan(&plan).iter().map(stops));
                }
                return Ok(out);
            }
            Ok(Vec::new())
        }
    }
}

#[cfg(test)]
mod tests;
