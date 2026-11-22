//! The notice writer (Task 13; storage §6.3, call 11): `message` rows of kind `task-changed`, and the close cards of
//! "only I close my tasks" (call 17). Both are written in the change's own tx (`tx` column) and carry the task's entity
//! `n` (`entity` column), so excise blanks them by either (`write::CoordBlanker`).
//!
//! A notice's `text` is JSON: `{"kind": "task-changed", "task", "title", "fields", "by", "tx", "notes", "says",
//! "changes"}`. It never copies a note's text, only the note's id: excising the note leaves no copy in the inbox.
//! The sender is [`SENDER`] (never null, which would read as the user's own message).

use serde_json::{Value, json};
use urdr::graph::{Tx, WriteError};

/// The `sender` of every notice.
pub const SENDER: &str = "tracker";
/// The notice's kind, the first key of its text.
pub const KIND: &str = "task-changed";
/// A coalesced notice keeps at most this many note ids (the newest).
const NOTES_MAX: usize = 10;

/// One notice: RECIPIENT is told that BY changed FIELDS of the task (entity `n` ENTITY, id TASK).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Notice {
    pub recipient: String,
    pub entity: i64,
    pub task: String,
    pub title: Option<String>,
    pub fields: Vec<String>,
    pub by: String,
    /// The id of a note the change wrote (a handoff, a reassign's reason).
    pub note: Option<String>,
    /// What the change means for the recipient: `now ready`, `lease lost`, `close proposed`.
    pub says: Option<String>,
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn union(mut into: Vec<String>, more: impl IntoIterator<Item = String>) -> Vec<String> {
    for s in more {
        if !into.contains(&s) {
            into.push(s);
        }
    }
    into
}

/// Write N in TX at NOW: a new queued row, or, while the recipient has a queued notice about the same task, that row
/// updated (fields, notes and says joined; title, by and tx the newest; `changes` counted). The row's id.
pub fn notice(tx: &mut Tx<'_>, n: Notice, now: f64) -> Result<i64, WriteError> {
    let open: Option<(i64, Option<String>)> = tx
        .sql()
        .query_row(
            "select id, text from message where recipient = ?1 and entity = ?2 and sender = ?3 \
             and state = 'queued' order by id desc limit 1",
            (&n.recipient, n.entity, SENDER),
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map(Some)
        .or_else(|e| match e {
            urdr::SqliteError::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?;
    // An excised (or otherwise unreadable) text starts over.
    let old: Option<Value> = open
        .as_ref()
        .and_then(|(_, t)| t.as_deref())
        .and_then(|t| serde_json::from_str::<Value>(t).ok())
        .filter(|v| v.get("kind").and_then(Value::as_str) == Some(KIND));
    let fields = union(
        strings(old.as_ref().and_then(|o| o.get("fields"))),
        n.fields.iter().cloned(),
    );
    let mut notes = union(
        strings(old.as_ref().and_then(|o| o.get("notes"))),
        n.note.iter().cloned(),
    );
    if notes.len() > NOTES_MAX {
        notes.drain(..notes.len() - NOTES_MAX);
    }
    let says = union(
        strings(old.as_ref().and_then(|o| o.get("says"))),
        n.says.iter().cloned(),
    );
    let changes = old
        .as_ref()
        .and_then(|o| o.get("changes"))
        .and_then(Value::as_i64)
        .unwrap_or(0)
        + 1;
    let text = json!({
        "kind": KIND,
        "task": n.task,
        "title": n.title,
        "fields": fields,
        "by": n.by,
        "tx": tx.id(),
        "notes": notes,
        "says": says,
        "changes": changes,
    })
    .to_string();
    let by = tx.id();
    match open {
        Some((id, _)) => {
            tx.sql().execute(
                "update message set text = ?1, at = ?2, tx = ?3 where id = ?4",
                (&text, now, by, id),
            )?;
            Ok(id)
        }
        None => {
            tx.sql().execute(
                "insert into message (sender, recipient, text, state, at, tx, entity) \
                 values (?1, ?2, ?3, 'queued', ?4, ?5, ?6)",
                (SENDER, &n.recipient, &text, now, by, n.entity),
            )?;
            Ok(tx.sql().last_insert_rowid())
        }
    }
}

/// AGENT's notices not read yet (queued or delivered).
pub fn unread(conn: &urdr::Connection, agent: &str) -> Result<u32, urdr::SqliteError> {
    conn.query_row(
        "select count(*) from message where recipient = ?1 and sender = ?2 and entity is not null \
         and state in ('queued', 'delivered')",
        (agent, SENDER),
        |r| r.get(0),
    )
}

/// A proposal to close a user-made task: who (BY, an actor) proposes closing the task (entity `n` ENTITY, id TASK,
/// at version VER), with the id of the note that came with it.
#[derive(Clone, Debug, PartialEq)]
pub struct Close<'a> {
    pub entity: i64,
    pub task: &'a str,
    pub title: &'a str,
    pub ver: i64,
    pub by: &'a str,
    pub note: Option<&'a str>,
}

/// The close card of "only I close my tasks" (call 17): `card` of kind `close` about the task (`entity` = its `n`),
/// `data {task, ver, by, note}` (`note` a note's id), no `job`. A second proposal while one is open merges into it
/// (its `ver`, `by` and `note` the newest). The card's id.
pub fn close_card(tx: &mut Tx<'_>, c: Close<'_>, now: f64) -> Result<i64, WriteError> {
    let data = json!({"task": c.task, "ver": c.ver, "by": c.by, "note": c.note}).to_string();
    let title = runstav::text::one_line(&format!("close {}: {}?", c.task, c.title), 200, false);
    let stamp = tx.id();
    let open: Option<i64> = tx
        .sql()
        .query_row(
            "select id from card where kind = 'close' and entity = ?1 and state = 'open' order by id desc limit 1",
            [c.entity],
            |r| r.get(0),
        )
        .map(Some)
        .or_else(|e| match e {
            urdr::SqliteError::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?;
    match open {
        Some(id) => {
            tx.sql().execute(
                "update card set title = ?1, data = ?2, at = ?3, tx = ?4 where id = ?5",
                (&title, &data, now, stamp, id),
            )?;
            Ok(id)
        }
        None => {
            tx.sql().execute(
                "insert into card (kind, title, data, state, at, tx, entity) values ('close', ?1, ?2, 'open', ?3, ?4, ?5)",
                (&title, &data, now, stamp, c.entity),
            )?;
            Ok(tx.sql().last_insert_rowid())
        }
    }
}
