//! The card writers (Task 5): `drgnx-coord-card-create`, `-card-settle` and `-card-set`, each with its event in the
//! same transaction (`core/drgnx-coord.el`, "Cards").  The title is stored as given (the Lisp does not shorten it);
//! the event summary is cut by the event writer.  Card `data` is checked by the tool layer against
//! `drgnx-records-card-data`; here it is stored as the JSON it is.

use super::event::{Event, EventKind, event};
use crate::store::{CoordError, WTx};
use serde_json::{Value, json};

/// A new card.
#[derive(Debug, Clone, Default)]
pub struct NewCard {
    pub job: Option<String>,
    pub task: Option<String>,
    pub kind: Option<String>,
    pub title: Option<String>,
    pub data: Option<Value>,
}

/// What `card_set` changes; `None` leaves a field alone.
#[derive(Debug, Clone, Default)]
pub struct CardSet {
    pub title: Option<String>,
    pub data: Option<Value>,
    pub state: Option<String>,
}

/// Emacs prints a missing string as `nil` under `%s`.
fn lisp(s: &Option<String>) -> &str {
    s.as_deref().unwrap_or("nil")
}

fn ev(
    now: f64,
    agent: Option<&str>,
    job: Option<String>,
    task: Option<String>,
    kind: EventKind,
    summary: String,
    data: Value,
) -> Event {
    Event {
        at: now,
        agent: agent.map(str::to_owned),
        job,
        task,
        kind,
        summary,
        data: Some(data),
        turn: false,
    }
}

/// `drgnx-coord-card-create`: a new open card; an `ask` card is a question to the user (its `ref` is that event).
pub fn card_create(tx: &mut WTx<'_>, c: NewCard, now: f64) -> Result<i64, CoordError> {
    let by = tx.id();
    tx.sql().execute(
        "insert into card (job, task, kind, title, data, state, at, tx) values (?1, ?2, ?3, ?4, ?5, 'open', ?6, ?7)",
        (
            &c.job,
            &c.task,
            &c.kind,
            &c.title,
            c.data.as_ref().map(Value::to_string),
            now,
            by,
        ),
    )?;
    let id = tx.sql().last_insert_rowid();
    let summary = format!("{}: {}", lisp(&c.kind), lisp(&c.title));
    if c.kind.as_deref() == Some("ask") {
        let q = event(
            tx,
            ev(
                now,
                None,
                c.job,
                c.task,
                EventKind::Question,
                summary,
                json!({"card": id}),
            ),
        )?;
        tx.sql()
            .execute("update card set ref = ?1 where id = ?2", (q, id))?;
    } else {
        event(
            tx,
            ev(
                now,
                None,
                c.job,
                c.task,
                EventKind::Card,
                summary,
                json!({"card": id, "state": "open"}),
            ),
        )?;
    }
    Ok(id)
}

/// `drgnx-coord-card-settle`: settle open card `id` with `choice`; false when it was not open (nothing happens twice).
pub fn card_settle(tx: &mut WTx<'_>, id: i64, choice: &str, now: f64) -> Result<bool, CoordError> {
    let by = tx.id();
    let n = tx.sql().execute(
        "update card set state = 'settled', settled_at = ?1, choice = ?2, tx = ?4 where id = ?3 and state = 'open'",
        (now, choice, id, by),
    )?;
    if n == 0 {
        return Ok(false);
    }
    // job, task, kind, title, ref
    type Settled = (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<i64>,
    );
    let (job, task, kind, title, reference): Settled = tx.sql().query_row(
        "select job, task, kind, title, ref from card where id = ?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
    )?;
    let summary = format!("{}: {} -> {choice}", lisp(&kind), lisp(&title));
    let question = reference.filter(|_| kind.as_deref() == Some("ask"));
    let e = match question {
        Some(q) => ev(
            now,
            Some("user"),
            job,
            task,
            EventKind::Answer,
            summary,
            json!({"question": q}),
        ),
        None => ev(
            now,
            None,
            job,
            task,
            EventKind::Card,
            summary,
            json!({"card": id, "state": "settled", "choice": choice}),
        ),
    };
    event(tx, e)?;
    Ok(true)
}

/// `drgnx-coord-card-set`: change card `id`'s title, data and/or state.  A change of state (a reopened card) leaves a
/// `card` event.
pub fn card_set(tx: &mut WTx<'_>, id: i64, set: CardSet, now: f64) -> Result<(), CoordError> {
    let by = tx.id();
    if let Some(title) = &set.title {
        tx.sql().execute(
            "update card set title = ?1, tx = ?3 where id = ?2",
            (title, id, by),
        )?;
    }
    if let Some(data) = &set.data {
        tx.sql().execute(
            "update card set data = ?1, tx = ?3 where id = ?2",
            (data.to_string(), id, by),
        )?;
    }
    if let Some(state) = &set.state {
        let old = match tx.sql().query_row(
            "select state, job, task, kind, title from card where id = ?1",
            [id],
            |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                ))
            },
        ) {
            Ok(row) => Some(row),
            Err(urdr::SqliteError::QueryReturnedNoRows) => None,
            Err(e) => return Err(e.into()),
        };
        if let Some((old, job, task, kind, title)) = old
            && old.as_deref() != Some(state.as_str())
        {
            tx.sql().execute(
                "update card set state = ?1, tx = ?3 where id = ?2",
                (state, id, by),
            )?;
            event(
                tx,
                ev(
                    now,
                    None,
                    job,
                    task,
                    EventKind::Card,
                    format!("{}: {} -> {state}", lisp(&kind), lisp(&title)),
                    json!({"card": id, "state": state}),
                ),
            )?;
        }
    }
    Ok(())
}

/// Blank the title and data of the cards an excise reached: those written (or last updated) by an excised tx, those
/// about an excised entity (`card.entity`, an entity `n`) and those whose `data.task` is an excised task's id.  The
/// title becomes the marker, `data` (when there was any) MARK.  How many.
pub(crate) fn blank_cards(
    tx: &mut WTx<'_>,
    ex: &urdr::graph::excise::Excised,
    ids: &[String],
    mark: &str,
) -> Result<u64, CoordError> {
    const CHANGED: &str = "(title is not ?1 or (data is not null and data <> ?2))";
    let set = "title = case when title is null then null else ?1 end, \
               data = case when data is null then null else ?2 end";
    let mut n = 0;
    for t in &ex.txs {
        n += tx.sql().execute(
            &format!("update card set {set} where tx = ?3 and {CHANGED}"),
            (&ex.marker, mark, t),
        )?;
    }
    for e in &ex.entities {
        n += tx.sql().execute(
            &format!("update card set {set} where entity = ?3 and {CHANGED}"),
            (&ex.marker, mark, e),
        )?;
    }
    for id in ids {
        n += tx.sql().execute(
            &format!("update card set {set} where json_extract(data, '$.task') = ?3 and {CHANGED}"),
            (&ex.marker, mark, id),
        )?;
    }
    Ok(n as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};

    fn card(kind: &str) -> NewCard {
        NewCard {
            job: Some("j".into()),
            kind: Some(kind.into()),
            title: Some("t".into()),
            ..NewCard::default()
        }
    }

    fn kinds(c: &urdr::Connection) -> Vec<String> {
        let mut st = c.prepare("select kind from event order by id").unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    #[test]
    fn an_ask_card_is_a_question_and_settling_answers_it_once() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = card_create(&mut tx, card("ask"), 1.0).unwrap();
        let reference: i64 = tx
            .sql()
            .query_row("select ref from card where id = ?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(reference, 1);
        assert!(card_settle(&mut tx, id, "yes", 2.0).unwrap());
        assert!(!card_settle(&mut tx, id, "no", 3.0).unwrap());
        assert_eq!(kinds(tx.sql()), ["question", "answer"]);
    }

    #[test]
    fn card_set_writes_an_event_only_when_the_state_changes() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = card_create(&mut tx, card("rate"), 1.0).unwrap();
        let same = CardSet {
            state: Some("open".into()),
            ..CardSet::default()
        };
        card_set(&mut tx, id, same, 2.0).unwrap();
        assert_eq!(kinds(tx.sql()), ["card"]);
        let reopen = CardSet {
            title: Some("u".into()),
            state: Some("dismissed".into()),
            ..CardSet::default()
        };
        card_set(&mut tx, id, reopen, 3.0).unwrap();
        assert_eq!(kinds(tx.sql()), ["card", "card"]);
    }
}
