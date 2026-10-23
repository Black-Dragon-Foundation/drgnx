//! The tracker (Task 13; storage §6.3, answers 2 and 4, calls 5, 6, 16, 17): agents create and change tasks in their
//! project — optimistic versions, fenced leases, splits, links without cycles, labels by add and remove, user-made
//! tasks behind the user's grant — and the agents affected get notices (docs/develop/coordination.md, "The
//! tracker").
//!
//! A tracker task is an entity of kind `task`, origin `recorded`, id `task:<prefix>-<5 base36>`, in its project, with
//! `data {labels?, acceptance?, tracker_tools?, lease_end?}` and no `data.job` (a job's task is `task:JOB#N`, the job
//! runner's: call 5). Every op is one tx (the caller's) and one `event` of kind `task`; [`op`] runs it, [`ops`] holds
//! one function per op, [`notices`] says who is told.

pub mod notices;
pub mod ops;

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Ent, FieldChange, Origin};
use urdr::graph::schema::SENTINEL;
use urdr::graph::walk::{Scope, Seen};
use urdr::graph::{Class, Tx, WriteError};

use crate::project::base36;
use crate::scope::{self, Caller, Reach, StoreScope};

/// A link op's kind (a `norn::kinds::LINKS` name).
pub type LinkName = String;

/// How long a claim holds without a heartbeat (as the job runner's lease, `drgnx-coord-lease-minutes`).
pub const LEASE_SECS: f64 = 15.0 * 60.0;
/// The longest body, acceptance or note, in characters.
pub const TEXT_MAX: usize = 8000;
/// The longest title, in characters (one line).
pub const TITLE_MAX: usize = 200;
/// The longest label, in characters (one line).
pub const LABEL_MAX: usize = 64;
/// The store setting of "only I close my tasks" (call 17): `1`, `true`, `on` or `t` turns it on.
pub const ONLY_USER_CLOSES: &str = "setting:only-user-closes";
/// The statuses an `Update` may set: `claimed` comes from `Claim`, and `ready` is computed, never stored.
pub const STATUSES: &[&str] = &[
    "open",
    "running",
    "needs-input",
    "in-review",
    "blocked",
    "done",
    "dropped",
];
/// The statuses that close a task: its `blocks` and its parent's wait end.
pub const CLOSED: &[&str] = &["done", "dropped"];

/// One tracker operation (`task_write`'s ops; `tasks/write`).
#[derive(Clone, Debug, PartialEq)]
pub enum TaskOp {
    Create {
        title: String,
        body: Option<String>,
        priority: Option<i64>,
        labels: Vec<String>,
        acceptance: Option<String>,
        parent: Option<String>,
    },
    Update {
        id: String,
        ver: i64,
        title: Option<String>,
        body: Option<String>,
        priority: Option<i64>,
        acceptance: Option<String>,
        status: Option<String>,
    },
    Claim {
        id: String,
    },
    Heartbeat {
        id: String,
        lease: i64,
    },
    Release {
        id: String,
        lease: i64,
        note: Option<String>,
    },
    Handoff {
        id: String,
        lease: i64,
        to: Option<String>,
        note: String,
    },
    Reassign {
        id: String,
        ver: i64,
        to: Option<String>,
        note: String,
    },
    Split {
        id: String,
        ver: i64,
        parts: Vec<String>,
        /// `children` (default) or `replace`.
        mode: Option<String>,
    },
    Complete {
        id: String,
        lease: i64,
        note: Option<String>,
    },
    Link {
        src: String,
        kind: LinkName,
        dst: String,
    },
    Unlink {
        src: String,
        kind: LinkName,
        dst: String,
    },
    Label {
        id: String,
        add: Vec<String>,
        remove: Vec<String>,
    },
    /// User class only: set or clear `data.tracker_tools`.
    Tools {
        id: String,
        tracker: Option<bool>,
    },
}

impl TaskOp {
    /// The op's name (`task_write`'s `op`, the event's first word).
    pub fn name(&self) -> &'static str {
        match self {
            TaskOp::Create { .. } => "create",
            TaskOp::Update { .. } => "update",
            TaskOp::Claim { .. } => "claim",
            TaskOp::Heartbeat { .. } => "heartbeat",
            TaskOp::Release { .. } => "release",
            TaskOp::Handoff { .. } => "handoff",
            TaskOp::Reassign { .. } => "reassign",
            TaskOp::Split { .. } => "split",
            TaskOp::Complete { .. } => "complete",
            TaskOp::Link { .. } => "link",
            TaskOp::Unlink { .. } => "unlink",
            TaskOp::Label { .. } => "label",
            TaskOp::Tools { .. } => "tools",
        }
    }

    /// The existing entity the op is about (a link's source); `None` for `Create`.
    fn subject(&self) -> Option<&str> {
        match self {
            TaskOp::Create { .. } => None,
            TaskOp::Link { src, .. } | TaskOp::Unlink { src, .. } => Some(src),
            TaskOp::Update { id, .. }
            | TaskOp::Claim { id }
            | TaskOp::Heartbeat { id, .. }
            | TaskOp::Release { id, .. }
            | TaskOp::Handoff { id, .. }
            | TaskOp::Reassign { id, .. }
            | TaskOp::Split { id, .. }
            | TaskOp::Complete { id, .. }
            | TaskOp::Label { id, .. }
            | TaskOp::Tools { id, .. } => Some(id),
        }
    }
}

/// How a lease was lost.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LostHow {
    Expired,
    Reassign,
    Reclaimed,
}

/// What an op answers (a refusal is `Err(WriteError::Refused)` with what to do next).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskAnswer {
    Done {
        id: String,
        title: String,
        ver: i64,
        lease: Option<i64>,
        /// The tasks a `Split` made, in the order of its parts.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        parts: Vec<String>,
    },
    Conflict {
        id: String,
        ver: i64,
        changed_since: Vec<FieldChange>,
        next: String,
    },
    LeaseLost {
        by: Option<String>,
        how: LostHow,
        tx: i64,
        note: Option<String>,
        next: String,
    },
    /// "Only I close my tasks": a close card instead of `done`.
    Proposed { card: i64 },
}

/// Run OP for CALLER in TX: one tx and one `event`, plus the notices it raises. A conflict or a lost lease writes
/// nothing (no event; a request rolls it back with [`op_or_roll_back`]); a refusal is an error, so the caller's
/// request rolls back. The hub's `notify()` is the caller's, after `COMMIT`.
pub fn op(tx: &mut Tx<'_>, caller: &Caller, op: TaskOp) -> Result<TaskAnswer, WriteError> {
    let name = op.name();
    let subject = op.subject().map(str::to_owned);
    let answer = match op {
        TaskOp::Create {
            title,
            body,
            priority,
            labels,
            acceptance,
            parent,
        } => ops::create(
            tx,
            caller,
            ops::NewTask {
                title,
                body,
                priority,
                labels,
                acceptance,
                parent,
            },
        )?,
        TaskOp::Update {
            id,
            ver,
            title,
            body,
            priority,
            acceptance,
            status,
        } => ops::update(
            tx,
            caller,
            &id,
            ver,
            ops::Fields {
                title,
                body,
                priority,
                acceptance,
                status,
            },
        )?,
        TaskOp::Claim { id } => ops::claim(tx, caller, &id)?,
        TaskOp::Heartbeat { id, lease } => ops::heartbeat(tx, caller, &id, lease)?,
        TaskOp::Release { id, lease, note } => {
            ops::release(tx, caller, &id, lease, note.as_deref())?
        }
        TaskOp::Handoff {
            id,
            lease,
            to,
            note,
        } => ops::handoff(tx, caller, &id, lease, to, &note)?,
        TaskOp::Reassign { id, ver, to, note } => ops::reassign(tx, caller, &id, ver, to, &note)?,
        TaskOp::Split {
            id,
            ver,
            parts,
            mode,
        } => ops::split(tx, caller, &id, ver, &parts, mode.as_deref())?,
        TaskOp::Complete { id, lease, note } => {
            ops::complete(tx, caller, &id, lease, note.as_deref())?
        }
        TaskOp::Link { src, kind, dst } => ops::link(tx, caller, &src, &kind, &dst)?,
        TaskOp::Unlink { src, kind, dst } => ops::unlink(tx, caller, &src, &kind, &dst)?,
        TaskOp::Label { id, add, remove } => ops::label(tx, caller, &id, &add, &remove)?,
        TaskOp::Tools { id, tracker } => ops::tools(tx, caller, &id, tracker)?,
    };
    // The ops answer from the entity as they read it; an `Update` may have changed the title since.
    let answer = match answer {
        TaskAnswer::Done {
            id,
            title,
            ver,
            lease,
            parts,
        } => TaskAnswer::Done {
            title: entity::by_id(tx.sql(), &id)?
                .and_then(|e| e.title)
                .unwrap_or(title),
            id,
            ver,
            lease,
            parts,
        },
        other => other,
    };
    match &answer {
        TaskAnswer::Done {
            id,
            title,
            ver,
            parts,
            ..
        } => {
            let mut data = json!({"op": name, "id": id, "ver": ver});
            if !parts.is_empty() {
                data["parts"] = json!(parts);
            }
            task_event(tx, caller, &format!("{name} {id}: {title}"), id, &data)?;
        }
        TaskAnswer::Proposed { card } => {
            let id = subject.unwrap_or_default();
            let title = entity::by_id(tx.sql(), &id)?
                .and_then(|e| e.title)
                .unwrap_or_default();
            let data = json!({"op": name, "id": id, "proposed": card});
            task_event(
                tx,
                caller,
                &format!("{name} {id}: {title} (close proposed)"),
                &id,
                &data,
            )?;
        }
        TaskAnswer::Conflict { .. } | TaskAnswer::LeaseLost { .. } => {}
    }
    Ok(answer)
}

impl TaskAnswer {
    /// Whether the op wrote: a conflict or a lost lease wrote nothing.
    pub fn wrote(&self) -> bool {
        matches!(self, TaskAnswer::Done { .. } | TaskAnswer::Proposed { .. })
    }
}

/// [`op`] as a request's whole write closure: an answer that wrote nothing (a conflict, a lost lease) goes into KEPT
/// and the request fails, so its savepoint rolls back and no empty `tx` row commits. The caller answers with what
/// KEPT holds when the write failed.
pub fn op_or_roll_back(
    tx: &mut Tx<'_>,
    caller: &Caller,
    op: TaskOp,
    kept: &std::sync::Mutex<Option<TaskAnswer>>,
) -> Result<TaskAnswer, WriteError> {
    let answer = self::op(tx, caller, op)?;
    if answer.wrote() {
        return Ok(answer);
    }
    *kept
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(answer);
    Err(refused("the op wrote nothing; rolled back"))
}

/// The user accepts a close card: task ID done at VER (the card's), with its event, as [`op`] would ([`ops::accept_close`]).
pub fn accept_close(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    ver: i64,
) -> Result<TaskAnswer, WriteError> {
    let answer = ops::accept_close(tx, caller, id, ver)?;
    if let TaskAnswer::Done { id, title, ver, .. } = &answer {
        let data = json!({"op": "update", "id": id, "ver": ver, "accepted": true});
        task_event(
            tx,
            caller,
            &format!("close accepted {id}: {title}"),
            id,
            &data,
        )?;
    }
    Ok(answer)
}

/// The op's `event` (kind `task`; `event.task` is the entity id, so excise blanks it with the task).
fn task_event(
    tx: &mut Tx<'_>,
    caller: &Caller,
    summary: &str,
    id: &str,
    data: &Value,
) -> Result<(), WriteError> {
    use crate::write::event::{SUMMARY_MAX, data_text};
    let summary = runstav::text::one_line(summary, SUMMARY_MAX, false);
    tx.sql().execute(
        "insert into event (at, agent, task, kind, summary, data, tx) values (?1, ?2, ?3, 'task', ?4, ?5, ?6)",
        (
            tx.at(),
            &caller.actor,
            id,
            summary,
            data_text(data),
            tx.id(),
        ),
    )?;
    Ok(())
}

/// The ready tasks in SCOPE with all of LABELS (computed over `link_in`, never stored): open tracker tasks (or claimed
/// ones whose lease ran out) with no open `blocks` into them, no open `parent_of` child and no live lease, by
/// priority then age, at most LIMIT.
pub fn ready(
    conn: &Connection,
    scope: &StoreScope,
    labels: &[String],
    limit: u32,
) -> Result<Vec<Ent>, urdr::SqliteError> {
    let within = match scope.reach() {
        Reach::Everything => String::new(),
        Reach::AnyProject => " and e.project is not null".into(),
        Reach::Projects(ps) => format!(
            " and e.project in ({})",
            ps.iter().map(i64::to_string).collect::<Vec<_>>().join(", ")
        ),
    };
    let sql = format!(
        "select e.n from entity e where e.kind = 'task' and e.retired_tx is null and e.origin = 'recorded' \
         and json_extract(e.data, '$.job') is null{within} and {} \
         and not exists (select 1 from json_each(?2) w \
                         where w.value not in (select value from json_each(e.data, '$.labels'))) \
         order by coalesce(e.priority, 1000000), e.n limit ?3",
        ready_sql()
    );
    let mut stmt = conn.prepare(&sql)?;
    let ns: Vec<i64> = stmt
        .query_map(
            (now_secs(), json!(labels).to_string(), i64::from(limit)),
            |r| r.get(0),
        )?
        .collect::<Result<_, _>>()?;
    let mut out = Vec::with_capacity(ns.len());
    for n in ns {
        out.extend(entity::by_n(conn, n)?);
    }
    Ok(out)
}

/// The readiness condition on the entity `e` at the time `?1`.
fn ready_sql() -> String {
    format!(
        "(e.status = 'open' or (e.status = 'claimed' and e.lease_until <= ?1)) \
         and (e.lease_holder is null or e.lease_until is null or e.lease_until <= ?1) \
         and not exists (select 1 from link l join entity b on b.n = l.src \
                         where l.dst = e.n and l.kind = 'blocks' and l.tx_to = {SENTINEL} \
                         and b.retired_tx is null and coalesce(b.status, '') not in ('done', 'dropped')) \
         and not exists (select 1 from link l join entity c on c.n = l.dst \
                         where l.src = e.n and l.kind = 'parent_of' and l.tx_to = {SENTINEL} \
                         and c.retired_tx is null and coalesce(c.status, '') not in ('done', 'dropped'))"
    )
}

/// Whether entity N is ready at NOW.
pub(crate) fn is_ready(conn: &Connection, n: i64, now: f64) -> Result<bool, urdr::SqliteError> {
    conn.query_row(
        &format!(
            "select exists (select 1 from entity e where e.n = ?2 and {})",
            ready_sql()
        ),
        (now, n),
        |r| r.get(0),
    )
}

fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

// ---------------------------------------------------------------------------------------------------------- helpers

pub(crate) fn refused(text: impl Into<String>) -> WriteError {
    WriteError::Refused(text.into())
}

/// A row, or `None` for no row.
pub(crate) fn opt<T>(r: Result<T, urdr::SqliteError>) -> Result<Option<T>, urdr::SqliteError> {
    match r {
        Ok(v) => Ok(Some(v)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e),
    }
}

/// Whether E comes from a file the scan reads (call 6): read-only to agents and the user alike, since the next scan
/// would overwrite a change.
pub(crate) fn is_parsed(e: &Ent) -> bool {
    e.origin == Origin::Parsed
        || e.id.starts_with("task:/")
        || matches!(
            e.kind.as_str(),
            "spec" | "plan" | "step" | "ruling" | "todo"
        )
}

/// The job of a job task (`task:JOB#N`, `data.job`), else `None`.
pub(crate) fn job_of(e: &Ent) -> Option<String> {
    if e.kind != "task" {
        return None;
    }
    match e.data.get("job") {
        Some(Value::String(j)) => Some(j.clone()),
        Some(Value::Null) | None => None,
        Some(other) => Some(other.to_string()),
    }
}

/// Whether E was made by the user (its creating tx's class is `user`; answer 4, call 17).
pub(crate) fn user_made(tx: &Tx<'_>, e: &Ent) -> Result<bool, WriteError> {
    let class: Option<String> =
        opt(tx
            .sql()
            .query_row("select class from tx where id = ?1", [e.created_tx], |r| {
                r.get(0)
            }))?;
    Ok(class.as_deref() == Some(Class::User.as_str()))
}

/// The actor of the tx that made E.
pub(crate) fn creator(tx: &Tx<'_>, e: &Ent) -> Result<Option<String>, WriteError> {
    Ok(opt(tx.sql().query_row(
        "select actor from tx where id = ?1",
        [e.created_tx],
        |r| r.get(0),
    ))?)
}

/// Whether "only I close my tasks" is on.
pub(crate) fn only_user_closes(conn: &Connection) -> Result<bool, urdr::SqliteError> {
    let v: Option<String> = opt(conn.query_row(
        "select value from kv where key = ?1",
        [ONLY_USER_CLOSES],
        |r| r.get(0),
    ))?;
    Ok(v.is_some_and(|v| {
        matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "on" | "t"
        )
    }))
}

/// Whether E's lease is held and not run out at NOW.
pub(crate) fn live(e: &Ent, now: f64) -> bool {
    e.lease.holder.is_some() && e.lease.until.is_some_and(|u| u > now)
}

/// The entity ID as CALLER may see it (`what` names it in the refusal): missing, retired or out of scope is "no such
/// WHAT" (never "forbidden", so nothing leaks). The flag is false for a stub (an entity without a project, seen by
/// an agent).
pub(crate) fn visible(
    tx: &Tx<'_>,
    caller: &Caller,
    id: &str,
    what: &str,
) -> Result<(Ent, bool), WriteError> {
    let no = || refused(format!("no such {what}: {id}"));
    let Some(e) = entity::by_id(tx.sql(), id)?.filter(|e| e.retired_tx.is_none()) else {
        return Err(no());
    };
    if caller.may_write_into(e.project) {
        return Ok((e, true));
    }
    match scope::for_caller(tx.sql(), caller, tx.at())?.allows(e.project) {
        Seen::Hidden => Err(no()),
        Seen::Full => Ok((e, true)),
        Seen::Stub => Ok((e, false)),
    }
}

/// The refusal for a parsed entity (call 6): FULL names its file.
pub(crate) fn from_a_file(e: &Ent, full: bool) -> WriteError {
    let file = if full {
        e.data
            .get("path")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| e.source.clone())
            .unwrap_or_else(|| e.id.clone())
    } else {
        "a file the scan reads".into()
    };
    refused(format!(
        "this comes from {file}; add a note or a task that relates to it"
    ))
}

/// The refusal for a job's task (call 5).
pub(crate) fn of_a_job(job: &str) -> WriteError {
    refused(format!(
        "this task belongs to job {job}; use claim_task, update_task or complete_task"
    ))
}

/// The task ID that CALLER may change: a tracker task (a job's task too when JOBS) in CALLER's project.
pub(crate) fn writable_task(
    tx: &Tx<'_>,
    caller: &Caller,
    id: &str,
    jobs: bool,
) -> Result<Ent, WriteError> {
    let (e, full) = visible(tx, caller, id, "task")?;
    if is_parsed(&e) {
        return Err(from_a_file(&e, full));
    }
    if !jobs && let Some(job) = job_of(&e) {
        return Err(of_a_job(&job));
    }
    if e.kind != "task" {
        return Err(refused(format!("{id} is a {}, not a task", e.kind)));
    }
    if !caller.may_write_into(e.project) {
        return Err(refused(format!(
            "{id} is in another project: a grant opens reading only; add a task in your project that relates to it"
        )));
    }
    Ok(e)
}

/// A new id `KIND:<prefix>-<5 base36>`: the prefix is the first two letters of PROJECT's first alias (`xx` without
/// one), the suffix random; an id already taken is drawn again.
pub(crate) fn new_id(tx: &Tx<'_>, kind: &str, project: Option<i64>) -> Result<String, WriteError> {
    let slug: Option<String> = match project {
        Some(p) => opt(tx.sql().query_row(
            "select slug from project_alias where project = ?1 order by tx, slug limit 1",
            [p],
            |r| r.get(0),
        ))?,
        None => None,
    };
    let mut prefix: String = slug
        .unwrap_or_default()
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .take(2)
        .collect();
    while prefix.len() < 2 {
        prefix.push('x');
    }
    let state = RandomState::new();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    for attempt in 0..32u32 {
        let mut h = state.build_hasher();
        h.write_i64(tx.id());
        h.write_u32(attempt);
        h.write_u128(nanos);
        let id = format!("{kind}:{prefix}-{}", base36(h.finish(), 5));
        if entity::by_id(tx.sql(), &id)?.is_none() {
            return Ok(id);
        }
    }
    Err(refused("no free id was found; try again"))
}

/// Refuse FIELD's TEXT when it looks like a secret (with the rule's name).
pub(crate) fn no_secret(field: &str, text: &str) -> Result<(), WriteError> {
    match runstav::secrets::looks_like_secret(text) {
        Some(rule) => Err(refused(format!(
            "the {field} looks like a secret ({rule}); do not store credentials"
        ))),
        None => Ok(()),
    }
}

/// A title: no secret, one line of at most [`TITLE_MAX`], not empty.
pub(crate) fn clean_title(text: &str) -> Result<String, WriteError> {
    no_secret("title", text)?;
    let t = runstav::text::one_line(text, TITLE_MAX, false)
        .trim()
        .to_owned();
    if t.is_empty() {
        return Err(refused("a task needs a title"));
    }
    Ok(t)
}

/// A body, acceptance or note: no secret, at most [`TEXT_MAX`].
pub(crate) fn clean_text(field: &str, text: &str) -> Result<String, WriteError> {
    no_secret(field, text)?;
    Ok(runstav::text::cut(text, TEXT_MAX).0)
}

/// Labels: no secret, each one line of at most [`LABEL_MAX`], empty ones dropped, each once.
pub(crate) fn clean_labels(labels: &[String]) -> Result<Vec<String>, WriteError> {
    let mut out: Vec<String> = Vec::new();
    for l in labels {
        no_secret("label", l)?;
        let l = runstav::text::one_line(l, LABEL_MAX, false)
            .trim()
            .to_owned();
        if !l.is_empty() && !out.contains(&l) {
            out.push(l);
        }
    }
    Ok(out)
}

/// E's labels (`data.labels`).
pub(crate) fn labels_of(e: &Ent) -> Vec<String> {
    e.data
        .get("labels")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
