//! The tracker's operations, one function per op (Task 13; storage §6.3). Each runs in the caller's tx; [`super::op`]
//! adds the op's event. Times are the tx's (`tx.at()`).

use serde_json::{Value, json};
use urdr::graph::entity::{self, Changes, Ent, EntityNew, Lease, Origin, Update};
use urdr::graph::link;
use urdr::graph::schema::SENTINEL;
use urdr::graph::{Class, Tx, WriteError};

use super::notices;
use super::{
    CLOSED, LEASE_SECS, LostHow, STATUSES, TaskAnswer, clean_labels, clean_text, clean_title,
    creator, from_a_file, is_parsed, is_ready, job_of, labels_of, live, new_id, of_a_job,
    only_user_closes, refused, user_made, visible, writable_task,
};
use crate::grants;
use crate::kinds;
use crate::scope::Caller;
use crate::write::notices::{Close, close_card};

/// What `Create` takes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NewTask {
    pub title: String,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub labels: Vec<String>,
    pub acceptance: Option<String>,
    pub parent: Option<String>,
}

/// What `Update` changes; `None` leaves a field alone.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Fields {
    pub title: Option<String>,
    pub body: Option<String>,
    pub priority: Option<i64>,
    pub acceptance: Option<String>,
    pub status: Option<String>,
}

const NEXT_CONFLICT: &str = "re-read with task_read get, then retry with ver";
const NEXT_LOST: &str = "stop work on this task; read your notices";

fn done(e: &Ent, ver: i64, lease: Option<i64>) -> TaskAnswer {
    TaskAnswer::Done {
        id: e.id.clone(),
        title: e.title.clone().unwrap_or_default(),
        ver,
        lease,
        parts: Vec::new(),
    }
}

fn conflict(e: &Ent, ver: i64, changed_since: Vec<entity::FieldChange>) -> TaskAnswer {
    TaskAnswer::Conflict {
        id: e.id.clone(),
        ver,
        changed_since,
        next: format!("{NEXT_CONFLICT} {ver}"),
    }
}

/// Write CHANGES to E (with EXPECT a `ver` check): its new version, or the conflict answer.
fn apply(
    tx: &mut Tx<'_>,
    e: &Ent,
    expect: Option<i64>,
    changes: Changes,
) -> Result<Result<i64, TaskAnswer>, WriteError> {
    match entity::update(tx, e.n, expect, changes)? {
        Update::Done { ver } => Ok(Ok(ver)),
        Update::Conflict { ver, changed_since } => Ok(Err(conflict(e, ver, changed_since))),
    }
}

/// E is still at VER (nothing written either way).
fn check_ver(tx: &mut Tx<'_>, e: &Ent, ver: i64) -> Result<Option<TaskAnswer>, WriteError> {
    Ok(apply(tx, e, Some(ver), Changes::default())?.err())
}

/// E as it is now.
fn reload(tx: &Tx<'_>, e: &Ent) -> Result<Ent, WriteError> {
    entity::by_n(tx.sql(), e.n)?.ok_or_else(|| refused(format!("no such task: {}", e.id)))
}

/// The fence (storage §6.3): CALLER holds E's lease, LEASE is its epoch and it has not run out. `None` when it holds;
/// else the `lease_lost` answer.
fn fence(tx: &Tx<'_>, caller: &Caller, e: &Ent, lease: i64) -> Result<Option<TaskAnswer>, WriteError> {
    let holds = e.lease.holder.as_deref() == Some(caller.actor.as_str())
        && e.lease.epoch == lease
        && e.lease.until.is_some_and(|u| u > tx.at());
    if holds {
        return Ok(None);
    }
    // How the lease of epoch LEASE ended: recorded by the reassign or the claim that ended it; else it ran out (the
    // same epoch), or someone claimed after it.
    if let Some(end) = e
        .data
        .get("lease_end")
        .filter(|end| end.get("epoch").and_then(Value::as_i64) == Some(lease))
    {
        let how = match end.get("how").and_then(Value::as_str) {
            Some("reassign") => LostHow::Reassign,
            _ => LostHow::Reclaimed,
        };
        let note = match end.get("note").and_then(Value::as_str) {
            Some(id) => entity::by_id(tx.sql(), id)?.and_then(|n| n.body),
            None => None,
        };
        return Ok(Some(TaskAnswer::LeaseLost {
            by: end.get("by").and_then(Value::as_str).map(str::to_owned),
            how,
            tx: end.get("tx").and_then(Value::as_i64).unwrap_or(0),
            note,
            next: NEXT_LOST.into(),
        }));
    }
    let at = e.field_tx.get("lease").copied().unwrap_or(e.updated_tx);
    let (by, how) = if e.lease.epoch == lease {
        (None, LostHow::Expired)
    } else {
        (e.lease.holder.clone(), LostHow::Reclaimed)
    };
    Ok(Some(TaskAnswer::LeaseLost {
        by,
        how,
        tx: at,
        note: None,
        next: NEXT_LOST.into(),
    }))
}

/// A lease with no holder (the epoch kept, for the next claim to move on).
fn cleared(e: &Ent, bump: bool) -> Lease {
    Lease {
        holder: None,
        epoch: e.lease.epoch + i64::from(bump),
        until: None,
    }
}

/// A `note` about E (kind KIND: `progress`, `handoff`, `reassign`), linked `about` → E: its id. The text passes the
/// secret check and the cut; an empty one makes nothing.
fn add_note(
    tx: &mut Tx<'_>,
    e: &Ent,
    kind: &str,
    text: &str,
) -> Result<Option<String>, WriteError> {
    let body = clean_text("note", text)?;
    if body.is_empty() {
        return Ok(None);
    }
    let id = new_id(tx, "note", e.project)?;
    let note = entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "note".into(),
            project: e.project,
            title: Some(runstav::text::one_line(&body, 80, false)),
            status: None,
            body: Some(body),
            priority: None,
            assignee: None,
            data: json!({ "kind": kind }),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    link::add(tx, note.n, "about", e.n, None, Origin::Recorded, None)?;
    Ok(Some(id))
}

/// A required note.
fn need_note(text: &str, op: &str) -> Result<(), WriteError> {
    if text.trim().is_empty() {
        return Err(refused(format!(
            "{op} needs a note: what was done and what is left"
        )));
    }
    Ok(())
}

/// Who a task may be given to: nobody, the user, or an agent's id.
fn check_to(to: &Option<String>) -> Result<(), WriteError> {
    match to.as_deref() {
        None | Some("user") => Ok(()),
        Some(a) if crate::tools::identity::plain_id(a) => Ok(()),
        Some(a) => Err(refused(format!(
            "{a:?} is not an agent's id (letters, digits and . _ : - only)"
        ))),
    }
}

/// CALLER's `session:<sid>` entity (made on first use), for the `works_on` link of a claim.
fn session_entity(tx: &mut Tx<'_>, caller: &Caller) -> Result<Option<i64>, WriteError> {
    let Some(sid) = caller.session.as_deref() else {
        return Ok(None);
    };
    let id = format!("session:{sid}");
    if let Some(e) = entity::by_id(tx.sql(), &id)? {
        return Ok(e.retired_tx.is_none().then_some(e.n));
    }
    let e = entity::create(
        tx,
        EntityNew {
            id,
            kind: "session".into(),
            project: caller.project,
            title: Some(sid.to_owned()),
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: json!({}),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    Ok(Some(e.n))
}

/// Why E cannot be claimed: its status, its open blockers, its open parts.
fn not_ready(tx: &Tx<'_>, e: &Ent) -> Result<WriteError, WriteError> {
    let status = e.status.as_deref().unwrap_or("");
    if status != "open" {
        return Ok(refused(format!(
            "{} is {status}, not open: only an open task is claimed",
            e.id
        )));
    }
    let ids = |sql: &str| -> Result<Vec<String>, WriteError> {
        let mut stmt = tx.sql().prepare(sql)?;
        let rows = stmt
            .query_map((e.n, SENTINEL), |r| r.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(rows)
    };
    let blockers = ids(
        "select b.id from link l join entity b on b.n = l.src where l.dst = ?1 and l.kind = 'blocks' \
         and l.tx_to = ?2 and b.retired_tx is null and coalesce(b.status, '') not in ('done', 'dropped') order by b.n",
    )?;
    if !blockers.is_empty() {
        return Ok(refused(format!(
            "{} is not ready: blocked by {} (they finish first)",
            e.id,
            blockers.join(", ")
        )));
    }
    let parts = ids(
        "select c.id from link l join entity c on c.n = l.dst where l.src = ?1 and l.kind = 'parent_of' \
         and l.tx_to = ?2 and c.retired_tx is null and coalesce(c.status, '') not in ('done', 'dropped') order by c.n",
    )?;
    if !parts.is_empty() {
        return Ok(refused(format!(
            "{} is not ready: it waits for its parts {}",
            e.id,
            parts.join(", ")
        )));
    }
    Ok(refused(format!("{} is not ready", e.id)))
}

// ---------------------------------------------------------------------------------------------------------- the ops

/// `create`: a new open task in CALLER's project (a caller without one writes nothing), under PARENT when given.
pub fn create(tx: &mut Tx<'_>, caller: &Caller, t: NewTask) -> Result<TaskAnswer, WriteError> {
    let Some(project) = caller.project else {
        return Err(refused(
            "you have no project: tasks are made in the project (git repository) you work in",
        ));
    };
    let title = clean_title(&t.title)?;
    let body = t.body.as_deref().map(|b| clean_text("body", b)).transpose()?;
    let acceptance = t
        .acceptance
        .as_deref()
        .map(|a| clean_text("acceptance", a))
        .transpose()?;
    let labels = clean_labels(&t.labels)?;
    let parent = match &t.parent {
        Some(p) => Some(writable_task(tx, caller, p, false)?),
        None => None,
    };
    let mut data = json!({});
    if !labels.is_empty() {
        data["labels"] = json!(labels);
    }
    if let Some(a) = &acceptance {
        data["acceptance"] = json!(a);
    }
    let id = new_id(tx, "task", Some(project))?;
    let e = entity::create(
        tx,
        EntityNew {
            id,
            kind: "task".into(),
            project: Some(project),
            title: Some(title),
            status: Some("open".into()),
            body,
            priority: t.priority,
            assignee: None,
            data,
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    if let Some(p) = parent {
        link::add(tx, p.n, "parent_of", e.n, None, Origin::Recorded, None)?;
        notices::changed(tx, caller, &p, &["parts"], None, None)?;
    }
    Ok(done(&e, e.ver, None))
}

/// `update`: fields of task ID at VER. The user's rules on a user-made task (answer 4, call 17); a status change
/// while another holds the lease is refused.
pub fn update(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    ver: i64,
    f: Fields,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    let now = tx.at();
    let agent = caller.class != Class::User;
    let users = agent && user_made(tx, &e)?;
    let grant = users && grants::may_edit_user_task(tx.sql(), caller, e.n, now)?;
    if users && !grant && (f.title.is_some() || f.body.is_some() || f.acceptance.is_some()) {
        return Err(refused(format!(
            "{id} is the user's task: its title, body and acceptance change only with the user's permission; add a note instead"
        )));
    }
    let mut propose = false;
    if let Some(s) = f.status.as_deref() {
        if !STATUSES.contains(&s) {
            return Err(refused(format!(
                "{s:?} is not a status to set: one of {} (claim a task to work on it; ready is computed)",
                STATUSES.join(", ")
            )));
        }
        if live(&e, now) && e.lease.holder.as_deref() != Some(caller.actor.as_str()) {
            return Err(refused(format!(
                "{id} is claimed by {}: only the holder changes its status (or reassign it, with a note)",
                e.lease.holder.as_deref().unwrap_or("someone")
            )));
        }
        if users {
            if s == "dropped" {
                return Err(refused(format!(
                    "{id} is the user's task: only the user drops it"
                )));
            }
            if s == "done" && !grant {
                return Err(refused(format!(
                    "the user closes this task; set it in-review (or complete it) and the user will close it ({id})"
                )));
            }
            if !grant && s != "in-review" {
                return Err(refused(format!(
                    "{id} is the user's task: without the user's permission an agent sets only in-review"
                )));
            }
            propose = s == "done" && only_user_closes(tx.sql())?;
        }
    }
    let title = f.title.as_deref().map(clean_title).transpose()?;
    let body = f.body.as_deref().map(|b| clean_text("body", b)).transpose()?;
    let acceptance = f
        .acceptance
        .as_deref()
        .map(|a| clean_text("acceptance", a))
        .transpose()?;
    let status = if propose { None } else { f.status.clone() };
    let closes = status.as_deref().is_some_and(|s| CLOSED.contains(&s));
    let mut fields: Vec<&str> = Vec::new();
    let mut changes = Changes::default();
    if let Some(t) = title {
        changes.title = Some(Some(t));
        fields.push("title");
    }
    if let Some(b) = body {
        changes.body = Some(Some(b));
        fields.push("body");
    }
    if let Some(p) = f.priority {
        changes.priority = Some(Some(p));
        fields.push("priority");
    }
    if let Some(a) = acceptance {
        changes.data_patch = Some(json!({ "acceptance": a }));
        fields.push("acceptance");
    }
    if let Some(s) = &status {
        changes.status = Some(Some(s.clone()));
        fields.push("status");
        if closes && e.lease.holder.is_some() {
            changes.lease = Some(cleared(&e, false));
        }
    }
    let ver = match apply(tx, &e, Some(ver), changes)? {
        Ok(v) => v,
        Err(c) => return Ok(c),
    };
    if !fields.is_empty() {
        notices::changed(tx, caller, &e, &fields, None, None)?;
    }
    if closes {
        notices::now_ready(tx, caller, e.n)?;
    }
    if propose {
        return propose_close(tx, caller, &reload(tx, &e)?, None);
    }
    Ok(done(&e, ver, None))
}

/// "Only I close my tasks" (call 17): a close card (or the open one, merged) and a notice to the user; the task
/// itself is not changed.
fn propose_close(
    tx: &mut Tx<'_>,
    caller: &Caller,
    e: &Ent,
    note: Option<&str>,
) -> Result<TaskAnswer, WriteError> {
    let now = tx.at();
    let card = close_card(
        tx,
        Close {
            entity: e.n,
            task: &e.id,
            title: e.title.as_deref().unwrap_or(""),
            ver: e.ver,
            by: &caller.actor,
            note,
        },
        now,
    )?;
    notices::tell(
        tx,
        caller,
        e,
        "user",
        &["status"],
        note,
        Some("close proposed"),
    )?;
    Ok(TaskAnswer::Proposed { card })
}

/// The user accepts a close card (call 17, Urdr Task 15b): task ID done if it is still at VER (the proposal's), the
/// proposer's lease ended with it; else the conflict, nothing written.
pub fn accept_close(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    ver: i64,
) -> Result<TaskAnswer, WriteError> {
    if caller.class != Class::User {
        return Err(refused("only the user accepts a close"));
    }
    let e = writable_task(tx, caller, id, false)?;
    let mut changes = Changes {
        status: Some(Some("done".into())),
        ..Changes::default()
    };
    if e.lease.holder.is_some() {
        changes.lease = Some(cleared(&e, false));
    }
    let ver = match apply(tx, &e, Some(ver), changes)? {
        Ok(v) => v,
        Err(c) => return Ok(c),
    };
    notices::changed(tx, caller, &e, &["status"], None, None)?;
    notices::now_ready(tx, caller, e.n)?;
    Ok(done(&e, ver, None))
}

/// `claim`: a ready task, or one whose lease ran out, becomes CALLER's (lease epoch + 1, 15 minutes, status
/// `claimed`, assignee CALLER, a `works_on` link from its session).
pub fn claim(tx: &mut Tx<'_>, caller: &Caller, id: &str) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    let now = tx.at();
    if live(&e, now) {
        let holder = e.lease.holder.as_deref().unwrap_or("");
        return Err(if holder == caller.actor {
            refused(format!(
                "you hold {id} already (lease {}): heartbeat to keep it",
                e.lease.epoch
            ))
        } else {
            refused(format!(
                "{id} is claimed by {holder}: reassign it (with a note) to take it over"
            ))
        });
    }
    let expired = e.lease.holder.is_some();
    if !expired && !is_ready(tx.sql(), e.n, now)? {
        return Err(not_ready(tx, &e)?);
    }
    let epoch = e.lease.epoch + 1;
    let mut changes = Changes {
        status: Some(Some("claimed".into())),
        assignee: Some(Some(caller.actor.clone())),
        lease: Some(Lease {
            holder: Some(caller.actor.clone()),
            epoch,
            until: Some(now + LEASE_SECS),
        }),
        ..Changes::default()
    };
    if expired {
        changes.data_patch = Some(json!({"lease_end": {
            "epoch": e.lease.epoch, "how": "reclaimed", "by": caller.actor, "tx": tx.id(), "note": null,
        }}));
    }
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    if let Some(s) = session_entity(tx, caller)? {
        link::add(tx, s, "works_on", e.n, None, Origin::Recorded, None)?;
    }
    let says = expired.then_some("lease lost");
    notices::changed(tx, caller, &e, &["status", "assignee"], None, says)?;
    Ok(done(&e, ver, Some(epoch)))
}

/// `heartbeat`: the holder's lease runs 15 minutes from now.
pub fn heartbeat(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    lease: i64,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    if let Some(lost) = fence(tx, caller, &e, lease)? {
        return Ok(lost);
    }
    let changes = Changes {
        lease: Some(Lease {
            until: Some(tx.at() + LEASE_SECS),
            ..e.lease.clone()
        }),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    Ok(done(&e, ver, Some(lease)))
}

/// `release`: the holder gives the task back (status `open`, no holder), with a note.
pub fn release(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    lease: i64,
    note: Option<&str>,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    if let Some(lost) = fence(tx, caller, &e, lease)? {
        return Ok(lost);
    }
    let note = match note {
        Some(t) => add_note(tx, &e, "progress", t)?,
        None => None,
    };
    let changes = Changes {
        status: Some(Some("open".into())),
        lease: Some(cleared(&e, false)),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    notices::changed(tx, caller, &e, &["status"], note.as_deref(), None)?;
    Ok(done(&e, ver, None))
}

/// `handoff`: the holder gives the task to TO (an agent, the user or nobody), status `open`, with a `handoff` note.
pub fn handoff(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    lease: i64,
    to: Option<String>,
    note: &str,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    if let Some(lost) = fence(tx, caller, &e, lease)? {
        return Ok(lost);
    }
    need_note(note, "a handoff")?;
    check_to(&to)?;
    let note = add_note(tx, &e, "handoff", note)?;
    let changes = Changes {
        status: Some(Some("open".into())),
        assignee: Some(to),
        lease: Some(cleared(&e, false)),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    notices::changed(
        tx,
        caller,
        &e,
        &["status", "assignee"],
        note.as_deref(),
        None,
    )?;
    Ok(done(&e, ver, None))
}

/// `reassign`: anyone in the project ends the lease (epoch + 1, no holder), gives the task to TO and sets it `open`;
/// the note is required and the old holder's next holder op answers `lease_lost` with it.
pub fn reassign(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    ver: i64,
    to: Option<String>,
    note: &str,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    need_note(note, "a reassign")?;
    check_to(&to)?;
    if let Some(c) = check_ver(tx, &e, ver)? {
        return Ok(c);
    }
    let note = add_note(tx, &e, "reassign", note)?;
    let mut changes = Changes {
        status: Some(Some("open".into())),
        assignee: Some(to),
        lease: Some(cleared(&e, true)),
        ..Changes::default()
    };
    if e.lease.holder.is_some() {
        changes.data_patch = Some(json!({"lease_end": {
            "epoch": e.lease.epoch, "how": "reassign", "by": caller.actor, "tx": tx.id(), "note": note,
        }}));
    }
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    let says = e.lease.holder.is_some().then_some("lease lost");
    notices::changed(
        tx,
        caller,
        &e,
        &["status", "assignee"],
        note.as_deref(),
        says,
    )?;
    Ok(done(&e, ver, None))
}

/// `split`: PARTS become tasks (`split_from` the original; project, labels and priority inherited). `children`
/// (default) adds `parent_of`, so the original waits for its parts; `replace` drops the original with `duplicates`
/// links.
pub fn split(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    ver: i64,
    parts: &[String],
    mode: Option<&str>,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    let replace = match mode.unwrap_or("children") {
        "children" => false,
        "replace" => true,
        m => {
            return Err(refused(format!(
                "{m:?} is not a split mode: children or replace"
            )));
        }
    };
    if parts.is_empty() {
        return Err(refused("a split needs its parts' titles"));
    }
    let titles = parts
        .iter()
        .map(|p| clean_title(p))
        .collect::<Result<Vec<_>, _>>()?;
    let now = tx.at();
    if replace {
        if caller.class != Class::User && user_made(tx, &e)? {
            return Err(refused(format!(
                "{id} is the user's task: only the user drops it (split it into children instead)"
            )));
        }
        if live(&e, now) && e.lease.holder.as_deref() != Some(caller.actor.as_str()) {
            return Err(refused(format!(
                "{id} is claimed by {}: only the holder replaces it (or reassign it, with a note)",
                e.lease.holder.as_deref().unwrap_or("someone")
            )));
        }
    }
    if let Some(c) = check_ver(tx, &e, ver)? {
        return Ok(c);
    }
    let labels = labels_of(&e);
    let mut made = Vec::with_capacity(titles.len());
    for title in titles {
        let mut data = json!({});
        if !labels.is_empty() {
            data["labels"] = json!(labels);
        }
        let part_id = new_id(tx, "task", e.project)?;
        let part = entity::create(
            tx,
            EntityNew {
                id: part_id,
                kind: "task".into(),
                project: e.project,
                title: Some(title),
                status: Some("open".into()),
                body: None,
                priority: e.priority,
                assignee: None,
                data,
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        link::add(tx, part.n, "split_from", e.n, None, Origin::Recorded, None)?;
        let (kind, src, dst) = if replace {
            ("duplicates", e.n, part.n)
        } else {
            ("parent_of", e.n, part.n)
        };
        link::add(tx, src, kind, dst, None, Origin::Recorded, None)?;
        made.push(part.id);
    }
    let mut ver = ver;
    if replace {
        let changes = Changes {
            status: Some(Some("dropped".into())),
            lease: e.lease.holder.is_some().then(|| cleared(&e, false)),
            ..Changes::default()
        };
        ver = apply(tx, &e, None, changes)?.unwrap_or(ver);
        notices::changed(tx, caller, &e, &["status", "parts"], None, None)?;
        notices::now_ready(tx, caller, e.n)?;
    } else {
        notices::changed(tx, caller, &e, &["parts"], None, None)?;
    }
    Ok(TaskAnswer::Done {
        id: e.id.clone(),
        title: e.title.clone().unwrap_or_default(),
        ver,
        lease: None,
        parts: made,
    })
}

/// `complete`: the holder is done. An agent-made task goes `in-review` (the user's own completion: `done`); a
/// user-made one `done` with the user's grant (or a close card while "only I close my tasks" is on), `in-review`
/// without it. The task's maker hears of it.
pub fn complete(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    lease: i64,
    note: Option<&str>,
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    if let Some(lost) = fence(tx, caller, &e, lease)? {
        return Ok(lost);
    }
    let now = tx.at();
    let status = if caller.class == Class::User {
        "done"
    } else if user_made(tx, &e)? {
        if grants::may_edit_user_task(tx.sql(), caller, e.n, now)? {
            if only_user_closes(tx.sql())? {
                let note = match note {
                    Some(t) => add_note(tx, &e, "progress", t)?,
                    None => None,
                };
                return propose_close(tx, caller, &e, note.as_deref());
            }
            "done"
        } else {
            "in-review"
        }
    } else {
        "in-review"
    };
    let note = match note {
        Some(t) => add_note(tx, &e, "progress", t)?,
        None => None,
    };
    let changes = Changes {
        status: Some(Some(status.into())),
        lease: Some(cleared(&e, false)),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    notices::changed(tx, caller, &e, &["status"], note.as_deref(), None)?;
    if let Some(maker) = creator(tx, &e)? {
        notices::tell(tx, caller, &e, &maker, &["status"], note.as_deref(), None)?;
    }
    if CLOSED.contains(&status) {
        notices::now_ready(tx, caller, e.n)?;
    }
    Ok(done(&e, ver, None))
}

/// `label`: add and remove labels (idempotent, never a whole-list replace; no `ver`).
pub fn label(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    add: &[String],
    remove: &[String],
) -> Result<TaskAnswer, WriteError> {
    let e = writable_task(tx, caller, id, false)?;
    let add = clean_labels(add)?;
    let remove = clean_labels(remove)?;
    let mut labels = labels_of(&e);
    labels.retain(|l| !remove.contains(l));
    for l in add {
        if !labels.contains(&l) {
            labels.push(l);
        }
    }
    if labels == labels_of(&e) {
        return Ok(done(&e, e.ver, None));
    }
    let patch = if labels.is_empty() {
        json!({ "labels": null })
    } else {
        json!({ "labels": labels })
    };
    let changes = Changes {
        data_patch: Some(patch),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    notices::changed(tx, caller, &e, &["labels"], None, None)?;
    Ok(done(&e, ver, None))
}

/// The two ends of a link op: SRC (CALLER's to change: in its project, not parsed, no job's task) and DST (in scope;
/// for a link that changes readiness, in CALLER's project, not parsed and no job's task).
fn ends(
    tx: &Tx<'_>,
    caller: &Caller,
    src: &str,
    kind: &str,
    dst: &str,
) -> Result<(Ent, Ent, &'static kinds::LinkKind), WriteError> {
    let Some(lk) = kinds::link_kind(kind) else {
        let names: Vec<&str> = kinds::LINKS.iter().map(|l| l.name).collect();
        return Err(refused(format!(
            "{kind:?} is not a link kind: one of {}",
            names.join(", ")
        )));
    };
    let (s, full) = visible(tx, caller, src, "entity")?;
    if is_parsed(&s) {
        return Err(from_a_file(&s, full));
    }
    if let Some(job) = job_of(&s) {
        return Err(of_a_job(&job));
    }
    if !caller.may_write_into(s.project) {
        return Err(refused(format!(
            "{src} is in another project: a grant opens reading only; link from a task of your project"
        )));
    }
    let (d, full) = visible(tx, caller, dst, "entity")?;
    if lk.affects_ready {
        if is_parsed(&d) {
            return Err(from_a_file(&d, full));
        }
        if let Some(job) = job_of(&d) {
            return Err(of_a_job(&job));
        }
        if !caller.may_write_into(d.project) {
            return Err(refused(format!(
                "a {kind} link changes what is ready in {dst}'s project, and writes into another project are not \
                 grantable; link with relates instead"
            )));
        }
        if s.n == d.n {
            return Err(refused(format!("a task cannot {kind} itself")));
        }
    }
    if !kinds::link_allowed(kind, &s.kind, &d.kind) {
        return Err(refused(format!(
            "a {kind} link joins {} to {}, not a {} to a {}",
            lk.from.join("/"),
            lk.to.join("/"),
            s.kind,
            d.kind
        )));
    }
    Ok((s, d, lk))
}

/// The path DST → … → SRC over current `blocks` links, if there is one (adding SRC blocks DST would close it): a
/// breadth-first walk of at most 10,000 tasks.
fn blocks_path(tx: &Tx<'_>, src: i64, dst: i64) -> Result<Option<Vec<i64>>, WriteError> {
    const MAX: usize = 10_000;
    let mut parent: std::collections::HashMap<i64, i64> = std::collections::HashMap::new();
    let mut frontier = vec![dst];
    parent.insert(dst, dst);
    let mut stmt = tx
        .sql()
        .prepare("select dst from link where src = ?1 and kind = 'blocks' and tx_to = ?2")?;
    while !frontier.is_empty() {
        let mut next = Vec::new();
        for n in frontier {
            let outs: Vec<i64> = stmt
                .query_map((n, SENTINEL), |r| r.get(0))?
                .collect::<Result<_, _>>()?;
            for m in outs {
                if parent.contains_key(&m) {
                    continue;
                }
                parent.insert(m, n);
                if m == src {
                    let mut path = vec![m];
                    let mut at = m;
                    while at != dst {
                        at = parent[&at];
                        path.push(at);
                    }
                    path.reverse();
                    return Ok(Some(path));
                }
                if parent.len() > MAX {
                    return Err(refused(
                        "too many tasks to check this blocks link for a cycle",
                    ));
                }
                next.push(m);
            }
        }
        frontier = next;
    }
    Ok(None)
}

/// `link`: SRC KIND DST (`norn::kinds`' ends); a `blocks` cycle is refused with its path.
pub fn link(
    tx: &mut Tx<'_>,
    caller: &Caller,
    src: &str,
    kind: &str,
    dst: &str,
) -> Result<TaskAnswer, WriteError> {
    let (s, d, _) = ends(tx, caller, src, kind, dst)?;
    if kind == "blocks"
        && let Some(path) = blocks_path(tx, s.n, d.n)?
    {
        let mut ids = vec![s.id.clone()];
        for n in path {
            ids.push(
                entity::by_n(tx.sql(), n)?
                    .map(|e| e.id)
                    .unwrap_or_else(|| n.to_string()),
            );
        }
        return Err(refused(format!(
            "this would make a blocks cycle: {}",
            ids.join(" → ")
        )));
    }
    let added = link::add(tx, s.n, kind, d.n, None, Origin::Recorded, None)?;
    if !added.existed {
        notices::changed(tx, caller, &s, &["links"], None, None)?;
        if d.kind == "task" {
            notices::changed(tx, caller, &d, &["links"], None, None)?;
        }
    }
    Ok(done(&s, s.ver, None))
}

/// `unlink`: retire SRC KIND DST; a `blocks` gone tells the dependent's assignee when it is ready now.
pub fn unlink(
    tx: &mut Tx<'_>,
    caller: &Caller,
    src: &str,
    kind: &str,
    dst: &str,
) -> Result<TaskAnswer, WriteError> {
    let (s, d, _) = ends(tx, caller, src, kind, dst)?;
    if link::retire(tx, s.n, kind, d.n)? {
        notices::changed(tx, caller, &s, &["links"], None, None)?;
        if d.kind == "task" {
            let says = (kind == "blocks" && is_ready(tx.sql(), d.n, tx.at())?).then_some("now ready");
            notices::changed(tx, caller, &d, &["links"], None, says)?;
        }
    }
    Ok(done(&s, s.ver, None))
}

/// `tools` (call 16, user class only): set or clear a task's `data.tracker_tools`, on tracker and job tasks.
pub fn tools(
    tx: &mut Tx<'_>,
    caller: &Caller,
    id: &str,
    tracker: Option<bool>,
) -> Result<TaskAnswer, WriteError> {
    if caller.class != Class::User {
        return Err(refused("only the user sets a task's tools"));
    }
    let e = writable_task(tx, caller, id, true)?;
    let changes = Changes {
        data_patch: Some(json!({ "tracker_tools": tracker })),
        ..Changes::default()
    };
    let ver = apply(tx, &e, None, changes)?.unwrap_or(e.ver);
    Ok(done(&e, ver, None))
}
