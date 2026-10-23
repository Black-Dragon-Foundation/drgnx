//! The review-mark writer (Task 5): `drgnx-coord-review-mark` (`core/drgnx-coord.el`).

use super::event::{Event, event};
use crate::store::{CoordError, WTx};

/// Mark `agent`'s change to `path`, as it stood at `hash`, `state` (`accepted` or `pending`).  A review layer only:
/// nothing in the files changes.  The optional `ev` (the review's own event) is written in the same transaction.
/// The row carries the tx that wrote it.
pub fn review_mark(
    tx: &mut WTx<'_>,
    agent: &str,
    path: &str,
    state: &str,
    hash: &str,
    now: f64,
    ev: Option<Event>,
) -> Result<bool, CoordError> {
    if !matches!(state, "accepted" | "pending") {
        return Err(CoordError::Refused(format!(
            "Not a review state: {state:?}"
        )));
    }
    let by = tx.id();
    tx.sql().execute(
        "insert or replace into review_mark (agent, path, state, hash, at, tx) values (?1, ?2, ?3, ?4, ?5, ?6)",
        (agent, path, state, hash, now, by),
    )?;
    if let Some(ev) = ev {
        event(tx, ev)?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::review::review_marks;
    use crate::store::tests::{db7, tx_of};
    use crate::write::event::EventKind;

    #[test]
    fn a_mark_replaces_the_one_before_and_its_event_goes_with_it() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        assert!(review_mark(&mut tx, "a", "x.rs", "pending", "h1", 1.0, None).unwrap());
        let ev = Event {
            at: 2.0,
            agent: Some("user".into()),
            job: None,
            task: None,
            kind: EventKind::Review,
            summary: "accepted x.rs".into(),
            data: None,
            turn: false,
        };
        review_mark(&mut tx, "a", "x.rs", "accepted", "h2", 2.0, Some(ev)).unwrap();
        let marks = review_marks(tx.sql(), "a").unwrap();
        assert_eq!(marks.len(), 1);
        assert_eq!(marks[0].state, "accepted");
        let n: i64 = tx
            .sql()
            .query_row("select count(*) from event", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
        let by: i64 = tx
            .sql()
            .query_row("select tx from review_mark", [], |r| r.get(0))
            .unwrap();
        assert_eq!(by, tx.id());
        assert!(review_mark(&mut tx, "a", "x.rs", "bogus", "h", 3.0, None).is_err());
    }
}
