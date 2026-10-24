//! Briefs (Task 22; `docs/guide/agents.md`, "Briefs"): `brief::build(task) -> Brief` from the graph — the plan's
//! section for the task (by its heading, through `saga`), the project's AGENTS.md, the matrix as it applies, the
//! base branch, earlier tasks' reported interfaces, the check, the view path — capped at 16 KiB; an edited brief (a
//! `brief` note, `brief/set`) wins at dispatch.
//!
//! A task is named by its job-task id (`JOB#N`, with or without the `task:` prefix of its entity).  The edited
//! brief is the note `note:brief-<JOB#N>` (label `brief` in its data, an `about` link to the task), so setting it
//! twice replaces it.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::{ActionCtx, MatrixGate};
use norn::matrix::{Action, Effective, Role, Who};
use norn::store::{CoordError, Tx};
use runstav::methods::plans::{Brief, BriefPart, BriefPartText, BriefSet, BriefSetParams, ByTask};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::path::Path;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::link;

/// What a brief may hold in all.
pub const CAP: usize = 16 * 1024;
/// The project's AGENTS.md is cut here with a pointer (the plan section is the part that gives way to the cap).
const AGENTS_CAP: usize = 6 * 1024;
/// The interfaces of earlier tasks.
const INTERFACES_CAP: usize = 4 * 1024;
/// Room kept for the part headings and the pointer at the cut.
const SLACK: usize = 600;
/// A link's open end (`urdr::graph::schema::SENTINEL`).
const OPEN: i64 = 4_611_686_018_427_387_904;

/// Kept for the agent core's state (briefs are built on demand; nothing is held).
#[derive(Default)]
pub struct Briefs {}

fn err(code: ErrorCode, msg: impl Into<String>) -> Error {
    Error {
        code,
        message: msg.into(),
        path: None,
    }
}

fn store_err(e: CoordError) -> Error {
    err(ErrorCode::Internal, format!("{e:?}"))
}

/// The job-task id without the entity prefix.
fn bare(task: &str) -> &str {
    task.strip_prefix("task:").unwrap_or(task)
}

fn note_id(task: &str) -> String {
    format!("note:brief-{}", bare(task))
}

fn label_of(p: BriefPart) -> &'static str {
    match p {
        BriefPart::PlanSection => "The task (from the plan)",
        BriefPart::AgentsMd => "The project's AGENTS.md",
        BriefPart::Matrix => "What you may do (the permissions matrix)",
        BriefPart::BaseBranch => "Base branch",
        BriefPart::Interfaces => "Interfaces from earlier tasks",
        BriefPart::Check => "Check to run",
        BriefPart::ViewPath => "Without drgnx's tools",
    }
}

/// The edited brief of TASK, if the user set one.
fn edited(conn: &Tx, task: &str) -> Result<Option<String>, CoordError> {
    let Some(n) = entity::by_id(conn, &note_id(task))? else {
        return Ok(None);
    };
    let labelled = n.data.get("label").and_then(Value::as_str) == Some("brief");
    Ok((n.kind == "note" && n.retired_tx.is_none() && labelled)
        .then_some(n.body)
        .flatten())
}

/// Cut S to at most MAX bytes at the last heading line (a line starting with `#`, never the first line); with none,
/// at the last blank line; with none, at the last char boundary.
fn cut_at_heading(s: &str, max: usize) -> &str {
    let mut end = max.min(s.len());
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    let head = &s[..end];
    if end == s.len() {
        return head;
    }
    let mut at = None;
    let mut pos = 0;
    for line in head.split_inclusive('\n') {
        if pos > 0 && line.starts_with('#') {
            at = Some(pos);
        }
        pos += line.len();
    }
    let at = at.or_else(|| head.rfind("\n\n").filter(|&i| i > 0).map(|i| i + 1));
    &head[..at.unwrap_or(end)]
}

/// The most of S that fits MAX bytes, with a note where it was cut.
fn cut_with_pointer(s: &str, max: usize, pointer: &str) -> String {
    if s.len() <= max {
        return s.to_owned();
    }
    let kept = cut_at_heading(s, max).trim_end();
    format!("{kept}\n\n[cut here to fit the brief: {pointer}]")
}

/// The parts, joined, as the brief's text; the plan section is cut at a heading to fit [`CAP`].  The bool says it was.
fn assemble(
    task: &str,
    mut parts: Vec<(BriefPart, String)>,
    pointer: &str,
) -> (String, Vec<(BriefPart, String)>, bool) {
    let render = |parts: &[(BriefPart, String)]| {
        let mut out = format!("# Brief for task {task}\n");
        for (p, t) in parts.iter().filter(|(_, t)| !t.trim().is_empty()) {
            out.push_str(&format!("\n## {}\n{}\n", label_of(*p), t.trim_end()));
        }
        out
    };
    let mut cut = false;
    if render(&parts).len() > CAP {
        let others: usize = parts
            .iter()
            .filter(|(p, _)| *p != BriefPart::PlanSection)
            .map(|(_, t)| t.len())
            .sum();
        let room = CAP.saturating_sub(others + SLACK);
        for (p, t) in &mut parts {
            if *p == BriefPart::PlanSection {
                *t = cut_with_pointer(t, room, pointer);
                cut = true;
            }
        }
    }
    (render(&parts), parts, cut)
}

/// The cells that are not Never, one line each.
fn matrix_lines(e: &Effective) -> String {
    let word = |v: &Value| v.as_str().unwrap_or_default().to_owned();
    Action::ALL
        .into_iter()
        .filter_map(|a| {
            let c = e.cell(a);
            let verdict = word(&json!(c.verdict));
            if verdict == "never" {
                return None;
            }
            let limit = c
                .limit
                .map(|l| format!(", up to {} {}", l.amount, word(&json!(l.unit))))
                .unwrap_or_default();
            Some(format!("- {}: {verdict}{limit}", a.id()))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// TASK's section of the plan FILE (by the task's number), through saga.
fn section_from_file(file: &str, n: i64) -> Option<String> {
    if !Path::new(file).is_absolute() {
        return None;
    }
    let text = std::fs::read_to_string(file).ok()?;
    let doc = saga::plan::parse(&text);
    let t = doc.tasks.iter().find(|t| t.number == n.to_string())?;
    let mut raw = format!("{}{}", t.heading, t.body);
    for s in &t.after {
        raw.push_str(&s.heading);
        raw.push_str(&s.body);
    }
    Some(raw.trim().to_owned())
}

/// The line of the section that names the check, if it does.
fn check_of(section: &str) -> Option<String> {
    section
        .lines()
        .map(str::trim)
        .find(|l| {
            let l = l.to_ascii_lowercase();
            l.contains("author check") || l.starts_with("**check")
        })
        .map(str::to_owned)
}

/// The interfaces the reports of TASK's dependencies list (`blocks` links in, `report_of` links in), newest last.
fn interfaces(conn: &Tx, task_n: i64) -> Result<String, CoordError> {
    let ins = |dst: i64, kind: &str| -> Result<Vec<i64>, CoordError> {
        let mut st = conn.prepare(
            "select src from link where dst = ?1 and kind = ?2 and tx_to = ?3 order by id",
        )?;
        let rows = st.query_map((dst, kind, OPEN), |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    };
    let mut out = String::new();
    for dep in ins(task_n, "blocks")? {
        let Some(d) = entity::by_n(conn, dep)? else {
            continue;
        };
        for r in ins(dep, "report_of")? {
            let Some(r) = entity::by_n(conn, r)? else {
                continue;
            };
            let text = r
                .data
                .get("interfaces")
                .and_then(Value::as_str)
                .unwrap_or("");
            if r.kind == "report" && r.retired_tx.is_none() && !text.trim().is_empty() {
                out.push_str(&format!(
                    "- {}: {}\n",
                    d.id.trim_start_matches("task:"),
                    text.trim()
                ));
            }
        }
    }
    Ok(cut_with_pointer(&out, INTERFACES_CAP, "see the reports"))
}

/// What the graph says about TASK; PROJECT is the repo's project id (resolved by the caller, off the db's thread).
fn gather(
    conn: &Tx,
    gate: &MatrixGate,
    task: &str,
    project: Option<String>,
    now: f64,
) -> Result<(Vec<(BriefPart, String)>, String), CoordError> {
    let task = bare(task);
    let ent = entity::by_id(conn, &format!("task:{task}"))?
        .filter(|e| e.kind == "task" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no task {task}")))?;
    let job_id = ent
        .data
        .get("job")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let n = ent.data.get("n").and_then(Value::as_i64);
    let job = match &job_id {
        Some(j) => norn::read::jobs::job(conn, j)?,
        None => None,
    };
    let plan_file = job.as_ref().and_then(|j| j.plan.clone());
    // the section: the plan file through saga, else what the job kept of it, else the task entity's own text
    let kept = job.as_ref().and_then(|j| j.data.as_ref()).and_then(|d| {
        d.get("tasks")?
            .as_array()?
            .iter()
            .find(|t| t.get("n").and_then(Value::as_i64) == n)?
            .get("body")?
            .as_str()
            .map(str::to_owned)
    });
    let heading = ent.title.clone().unwrap_or_default();
    let section = plan_file
        .as_deref()
        .zip(n)
        .and_then(|(f, n)| section_from_file(f, n))
        .or_else(|| {
            kept.filter(|b| !b.trim().is_empty())
                .map(|b| format!("### Task {}: {heading}\n\n{b}", n.unwrap_or_default()))
        })
        .or_else(|| ent.body.clone().filter(|b| !b.trim().is_empty()))
        .unwrap_or_default();
    // the project's AGENTS.md: the one at the run's repo root
    let agents = job
        .as_ref()
        .and_then(|j| j.repo.as_deref())
        .and_then(|r| std::fs::read_to_string(Path::new(r).join("AGENTS.md")).ok())
        .map(|t| cut_with_pointer(&t, AGENTS_CAP, "read AGENTS.md in the repo root"))
        .unwrap_or_default();
    let ctx = ActionCtx {
        project,
        plan: plan_file.as_ref().map(|p| format!("plan:{p}")),
        ..ActionCtx::default()
    };
    let who = Who {
        role: Some(Role::Worker),
        ..Who::default()
    };
    let matrix = matrix_lines(&gate.effective_for(conn, &who, &ctx, now));
    let base = match (&job_id, n) {
        (Some(j), Some(n)) => format!(
            "job/{j} (your branch is job/{j}-{n}, in a worktree of your own; commit there, never on the base)"
        ),
        _ => "the repository's HEAD".to_owned(),
    };
    let check = check_of(&section).unwrap_or_else(|| {
        "format and lint what you touched, run your own new tests once, commit, then report"
            .to_owned()
    });
    let view = plan_file
        .filter(|p| Path::new(p).is_absolute())
        .map(|p| {
            format!(
                "The plan's view is the file {p}; read it for the rest of the plan. End your last message with one \
                 fenced `drgnx-report` JSON block (tip, commits, checks, decisions, differences, interfaces, followups)."
            )
        })
        .unwrap_or_default();
    let pointer = if view.is_empty() {
        "the plan section continues in the graph (plan_read)".to_owned()
    } else {
        "the rest of the section is in the plan view named below".to_owned()
    };
    let parts = vec![
        (BriefPart::PlanSection, section),
        (BriefPart::AgentsMd, agents),
        (BriefPart::Matrix, matrix),
        (BriefPart::BaseBranch, base),
        (BriefPart::Interfaces, interfaces(conn, ent.n)?),
        (BriefPart::Check, check),
        (BriefPart::ViewPath, view),
    ];
    Ok((parts, pointer))
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// The brief of TASK as the graph builds it, or the user's edited one.
pub async fn build(front: &Front, task: &str) -> Result<Brief, Error> {
    let task = bare(task).to_owned();
    let t = task.clone();
    let db = front.writer.db.clone();
    let hit = db.read(move |c| edited(c, &t)).await.map_err(store_err)?;
    if let Some(text) = hit {
        return Ok(Brief {
            task,
            text,
            parts: Vec::new(),
            edited: true,
            cut: false,
        });
    }
    front.core.matrix.refresh(front);
    // the project is found by git, off the db's thread
    let t = task.clone();
    let repo = db
        .read(move |c| {
            Ok(entity::by_id(c, &format!("task:{t}"))?
                .and_then(|e| e.data.get("job").and_then(Value::as_str).map(str::to_owned))
                .and_then(|j| norn::read::jobs::job(c, &j).ok().flatten())
                .and_then(|j| j.repo))
        })
        .await
        .map_err(store_err)?;
    let project = match repo {
        Some(r) => {
            tokio::task::spawn_blocking(move || norn::project::resolve(Path::new(&r)).map(|p| p.id))
                .await
                .ok()
                .flatten()
        }
        None => None,
    };
    let (gate, t) = (front.core.matrix.clone(), task.clone());
    let (parts, pointer) = db
        .read(move |c| gather(c, &gate, &t, project, now()))
        .await
        .map_err(|e| match e {
            CoordError::Refused(m) => err(ErrorCode::InvalidParams, m),
            e => store_err(e),
        })?;
    let (text, parts, cut) = assemble(&task, parts, &pointer);
    Ok(Brief {
        task,
        text,
        parts: parts
            .into_iter()
            .map(|(part, text)| BriefPartText { part, text })
            .collect(),
        edited: false,
        cut,
    })
}

/// What the runner sends a task's worker: the edited brief if there is one, else the built one; `None` when the graph
/// cannot say (the runner then keeps its own prompt).
pub async fn for_dispatch(front: &Front, task: &str) -> Option<String> {
    build(front, task).await.ok().map(|b| b.text)
}

pub async fn build_method(f: &Front, _: &Caller, p: ByTask) -> Result<Brief, Error> {
    build(f, &p.task.0).await
}

/// Keep TEXT as TASK's edited brief (the note is made, or its body replaced); the note's id.
fn set_in(tx: &mut norn::store::WTx<'_>, t: &str, text: String) -> Result<String, CoordError> {
    let id = note_id(t);
    let task = entity::by_id(tx.sql(), &format!("task:{t}"))?
        .filter(|e| e.kind == "task" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no task {t}")))?;
    match entity::by_id(tx.sql(), &id)?.filter(|e| e.retired_tx.is_none()) {
        Some(cur) => {
            entity::update(
                tx,
                cur.n,
                None,
                Changes {
                    body: Some(Some(text)),
                    ..Changes::default()
                },
            )?;
        }
        None => {
            let e = entity::create(
                tx,
                EntityNew {
                    id: id.clone(),
                    kind: "note".into(),
                    project: task.project,
                    title: Some(format!("brief for {t}")),
                    status: None,
                    body: Some(text),
                    priority: None,
                    assignee: None,
                    data: json!({"label": "brief"}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            link::add(tx, e.n, "about", task.n, None, Origin::Recorded, None)?;
        }
    }
    Ok(id)
}

pub async fn set(f: &Front, c: &Caller, p: BriefSetParams) -> Result<BriefSet, Error> {
    let (task, text) = (bare(&p.task.0).to_owned(), p.text.0);
    let note = f
        .writer
        .write(c, "brief/set", move |tx| set_in(tx, &task, text))
        .await
        .map_err(|e| match e {
            CoordError::Refused(m) => err(ErrorCode::InvalidParams, m),
            e => store_err(e),
        })?;
    Ok(BriefSet { note })
}

#[cfg(test)]
mod tests;
