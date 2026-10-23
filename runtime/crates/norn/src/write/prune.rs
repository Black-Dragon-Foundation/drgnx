//! Pruning the event log (Task 6): `drgnx-coord-events-prune`, `--events-cap` and `-events-prune-daily`
//! (`core/drgnx-coord.el`).  Questions, answers and decisions are never pruned.

use crate::store::{CoordDb, CoordError, Tx};

/// Days an event is kept (`drgnx-coord-event-retention-days`).
pub const RETENTION_DAYS: f64 = 30.0;
/// The most events kept (`drgnx-coord-event-max-rows`).
pub const MAX_ROWS: i64 = 100_000;

const DAY: f64 = 86_400.0;

/// Forget the events older than BEFORE, except questions, answers and decisions: how many.
pub fn events_prune_before(tx: &Tx, before: f64) -> Result<usize, CoordError> {
    Ok(tx.execute(
        "delete from event where at < ?1 and kind not in ('question', 'answer', 'decision')",
        [before],
    )?)
}

/// [`events_prune_before`] the retention (30 days) ago (`drgnx-coord-events-prune`).
pub fn events_prune(tx: &Tx, now: f64) -> Result<usize, CoordError> {
    events_prune_before(tx, now - DAY * RETENTION_DAYS)
}

/// Forget the oldest events past MAX, questions, answers and decisions apart: how many, or `None` when the log is
/// not over MAX (`drgnx-coord--events-cap`).
pub fn events_cap_to(tx: &Tx, max: i64) -> Result<Option<usize>, CoordError> {
    let n: i64 = tx.query_row("select count(*) from event", [], |r| r.get(0))?;
    if n <= max {
        return Ok(None);
    }
    Ok(Some(tx.execute(
        "delete from event where id in (select id from event \
         where kind not in ('question', 'answer', 'decision') order by id limit ?1)",
        [n - max],
    )?))
}

/// [`events_cap_to`] [`MAX_ROWS`].
pub fn events_cap(tx: &Tx) -> Result<Option<usize>, CoordError> {
    events_cap_to(tx, MAX_ROWS)
}

/// Prune unless it ran in the last 24 hours (then record the time in `meta.event-pruned`), and always hold the log
/// to the cap: whether it pruned (`drgnx-coord-events-prune-daily`, inside the caller's transaction).
pub fn prune_daily_tx(tx: &Tx, now: f64) -> Result<bool, CoordError> {
    let last: Option<String> = crate::read::tasks::opt(tx.query_row(
        "select value from meta where key = 'event-pruned'",
        [],
        |r| r.get(0),
    ))?;
    // `string-to-number`: text that is not a number reads as 0.
    let last: f64 = last.and_then(|s| s.trim().parse().ok()).unwrap_or(0.0);
    let ran = now - last > DAY;
    if ran {
        events_prune(tx, now)?;
        // `number-to-string` of a float: "100.0", not "100"
        tx.execute(
            "insert or replace into meta values ('event-pruned', ?1)",
            [format!("{now:?}")],
        )?;
    }
    events_cap(tx)?;
    Ok(ran)
}

/// The hub's periodic tick: [`prune_daily_tx`] in a transaction of its own.  Never fails: a busy database waits for
/// the next call, any other error is logged and answers `false`.
pub async fn prune_daily(db: &CoordDb, now: f64) -> bool {
    match db.write(move |tx| prune_daily_tx(tx, now)).await {
        Ok(ran) => ran,
        Err(CoordError::Busy) => false,
        Err(e) => {
            tracing::warn!("drgnx coord: pruning events: {e}");
            false
        }
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

    fn add(c: &urdr::Connection, at: f64, kind: &str) {
        c.execute(
            "insert into event (at, kind, summary) values (?1, ?2, 's')",
            (at, kind),
        )
        .unwrap();
    }

    fn count(c: &urdr::Connection) -> i64 {
        c.query_row("select count(*) from event", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn prune_keeps_questions_answers_and_decisions() {
        let c = db();
        add(&c, 1.0, "edit");
        add(&c, 1.0, "question");
        add(&c, 1.0, "answer");
        add(&c, 1.0, "decision");
        add(&c, 1e9, "edit");
        assert_eq!(events_prune_before(&c, 100.0).unwrap(), 1);
        assert_eq!(count(&c), 4);
    }

    #[test]
    fn the_cap_drops_the_oldest_unprotected_first() {
        let c = db();
        add(&c, 1.0, "question");
        for i in 0..4 {
            add(&c, 2.0 + f64::from(i), "edit");
        }
        assert_eq!(events_cap_to(&c, 10).unwrap(), None);
        assert_eq!(events_cap_to(&c, 3).unwrap(), Some(2));
        assert_eq!(count(&c), 3);
        let kinds: i64 = c
            .query_row(
                "select count(*) from event where kind = 'question'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(kinds, 1);
    }

    #[test]
    fn daily_runs_once_a_day() {
        let c = db();
        assert!(prune_daily_tx(&c, 200_000.0).unwrap());
        assert!(!prune_daily_tx(&c, 200_100.0).unwrap());
        assert!(prune_daily_tx(&c, 300_000.0).unwrap());
    }
}
