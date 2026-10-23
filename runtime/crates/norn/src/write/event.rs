//! The event writer (Task 4): `drgnx-coord--event` and `drgnx-coord-event-add[-best-effort]`, exactly
//! (`core/drgnx-coord.el`).

use crate::store::{CoordDb, CoordError, Tx};
use runstav::text;

/// The longest event summary, in characters (`drgnx-coord--summary-max`).
pub const SUMMARY_MAX: usize = 200;
/// The longest stored event data, in characters (`drgnx-coord--data-max`).
pub const DATA_MAX: usize = 4096;

/// What an event can be: `drgnx-coord-event-kinds`, in the Lisp order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Start,
    Stop,
    Claim,
    Release,
    Status,
    Decision,
    Edit,
    Test,
    Question,
    Answer,
    Review,
    Message,
    Card,
    Accept,
    Revert,
    Comment,
    Job,
}

impl EventKind {
    pub const ALL: [EventKind; 17] = [
        EventKind::Start,
        EventKind::Stop,
        EventKind::Claim,
        EventKind::Release,
        EventKind::Status,
        EventKind::Decision,
        EventKind::Edit,
        EventKind::Test,
        EventKind::Question,
        EventKind::Answer,
        EventKind::Review,
        EventKind::Message,
        EventKind::Card,
        EventKind::Accept,
        EventKind::Revert,
        EventKind::Comment,
        EventKind::Job,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            EventKind::Start => "start",
            EventKind::Stop => "stop",
            EventKind::Claim => "claim",
            EventKind::Release => "release",
            EventKind::Status => "status",
            EventKind::Decision => "decision",
            EventKind::Edit => "edit",
            EventKind::Test => "test",
            EventKind::Question => "question",
            EventKind::Answer => "answer",
            EventKind::Review => "review",
            EventKind::Message => "message",
            EventKind::Card => "card",
            EventKind::Accept => "accept",
            EventKind::Revert => "revert",
            EventKind::Comment => "comment",
            EventKind::Job => "job",
        }
    }

    pub fn parse(name: &str) -> Option<EventKind> {
        EventKind::ALL.into_iter().find(|k| k.as_str() == name)
    }
}

/// One event to record.
#[derive(Debug, Clone)]
pub struct Event {
    /// Seconds since the epoch, as `float-time` gives.
    pub at: f64,
    pub agent: Option<String>,
    pub job: Option<String>,
    pub task: Option<String>,
    pub kind: EventKind,
    pub summary: String,
    pub data: Option<serde_json::Value>,
    /// A turn's `start`/`stop` (`data` carries `turn: true`): sets the `turn` column.  Ignored for other kinds.
    pub turn: bool,
}

/// The data as stored: its JSON, or `{"truncated": true, "size": N}` over [`DATA_MAX`] characters.
pub(crate) fn data_text(data: &serde_json::Value) -> String {
    let text = data.to_string();
    let size = text.chars().count();
    if size > DATA_MAX {
        serde_json::json!({"truncated": true, "size": size}).to_string()
    } else {
        text
    }
}

/// Insert one event inside the caller's transaction: its id (`drgnx-coord--event`).  Public so the parity test replays it.
pub fn event(tx: &Tx, e: Event) -> Result<i64, CoordError> {
    let turn = matches!(e.kind, EventKind::Start | EventKind::Stop) && e.turn;
    tx.execute(
        "insert into event (at, agent, job, task, kind, summary, data, turn) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        (
            e.at,
            e.agent,
            e.job,
            e.task,
            e.kind.as_str(),
            text::one_line(&e.summary, SUMMARY_MAX, false),
            e.data.as_ref().map(data_text),
            turn.then_some(1),
        ),
    )?;
    Ok(tx.last_insert_rowid())
}

/// `drgnx-coord-event-add`: one event in a transaction of its own.  A busy database is `Busy` (after the timeout).
pub async fn event_add(db: &CoordDb, e: Event) -> Result<i64, CoordError> {
    db.write(move |tx| event(tx, e)).await
}

/// `drgnx-coord-event-add-best-effort`: `None`, not an error, when the database stays busy; for telemetry that must
/// never fail the work it describes.  Any other error still comes out.
pub async fn event_add_best_effort(db: &CoordDb, e: Event) -> Result<Option<i64>, CoordError> {
    match event_add(db, e).await {
        Ok(id) => Ok(Some(id)),
        Err(CoordError::Busy) => Ok(None),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    fn db() -> urdr::Connection {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c
    }

    fn ev(kind: EventKind, summary: &str, data: Option<serde_json::Value>) -> Event {
        Event {
            at: 10.0,
            agent: Some("a".into()),
            job: None,
            task: None,
            kind,
            summary: summary.into(),
            data,
            turn: false,
        }
    }

    #[test]
    fn summary_is_one_line_of_200() {
        let c = db();
        let long = format!("a\nb\u{202e}c{}", "x".repeat(300));
        let id = event(&c, ev(EventKind::Edit, &long, None)).unwrap();
        let s: String = c
            .query_row("select summary from event where id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(s.chars().count(), 200);
        assert!(s.starts_with("a b c"), "{s:?}");
    }

    #[test]
    fn data_over_4096_is_truncated() {
        let c = db();
        let big = serde_json::json!({"text": "y".repeat(5000)});
        let size = big.to_string().chars().count();
        let id = event(&c, ev(EventKind::Edit, "s", Some(big))).unwrap();
        let d: String = c
            .query_row("select data from event where id = ?1", [id], |r| r.get(0))
            .unwrap();
        let v: serde_json::Value = serde_json::from_str(&d).unwrap();
        assert_eq!(v, serde_json::json!({"truncated": true, "size": size}));
        let id = event(
            &c,
            ev(EventKind::Edit, "s", Some(serde_json::json!({"k": 1}))),
        )
        .unwrap();
        let d: String = c
            .query_row("select data from event where id = ?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(d, r#"{"k":1}"#);
    }

    #[test]
    fn turn_is_one_for_start_and_stop_only() {
        let c = db();
        let mut e = ev(
            EventKind::Start,
            "s",
            Some(serde_json::json!({"turn": true})),
        );
        e.turn = true;
        let a = event(&c, e.clone()).unwrap();
        e.kind = EventKind::Edit;
        let b = event(&c, e).unwrap();
        let turn = |id: i64| -> Option<i64> {
            c.query_row("select turn from event where id = ?1", [id], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(turn(a), Some(1));
        assert_eq!(turn(b), None);
    }

    #[test]
    fn kinds_are_the_lisp_list() {
        let src = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../core/drgnx-coord.el"
        ))
        .unwrap();
        let at = src
            .find("(defconst drgnx-coord-event-kinds")
            .expect("defconst");
        let rest = &src[at..];
        let open = rest.find("'(").expect("quoted list") + 2;
        let close = rest[open..].find(')').expect("end of list") + open;
        let lisp: Vec<&str> = rest[open..close]
            .split('"')
            .enumerate()
            .filter(|(i, _)| i % 2 == 1)
            .map(|(_, s)| s)
            .collect();
        let rust: Vec<&str> = EventKind::ALL.iter().map(|k| k.as_str()).collect();
        assert_eq!(rust, lisp);
        assert_eq!(rust.len(), 17);
    }
}
