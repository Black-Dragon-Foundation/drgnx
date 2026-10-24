//! Pruning the event log (Task 6): `drgnx-coord-events-prune`, `--events-cap` and `-events-prune-daily`
//! (`core/drgnx-coord.el`).  Questions, answers and decisions are never pruned.

use crate::store::{CoordDb, CoordError, WTx};
use urdr::graph::TxMeta;

/// Days an event is kept (`drgnx-coord-event-retention-days`).
pub const RETENTION_DAYS: f64 = 30.0;
/// The most events kept (`drgnx-coord-event-max-rows`).
pub const MAX_ROWS: i64 = 100_000;

const DAY: f64 = 86_400.0;

/// Forget the events older than BEFORE, except questions, answers and decisions: how many.
pub fn events_prune_before(tx: &mut WTx<'_>, before: f64) -> Result<usize, CoordError> {
    Ok(tx.sql().execute(
        "delete from event where at < ?1 and kind not in ('question', 'answer', 'decision')",
        [before],
    )?)
}

/// [`events_prune_before`] the retention (30 days) ago (`drgnx-coord-events-prune`).
pub fn events_prune(tx: &mut WTx<'_>, now: f64) -> Result<usize, CoordError> {
    events_prune_before(tx, now - DAY * RETENTION_DAYS)
}

/// Forget the oldest events past MAX, questions, answers and decisions apart: how many, or `None` when the log is
/// not over MAX (`drgnx-coord--events-cap`).
pub fn events_cap_to(tx: &mut WTx<'_>, max: i64) -> Result<Option<usize>, CoordError> {
    let n: i64 = tx
        .sql()
        .query_row("select count(*) from event", [], |r| r.get(0))?;
    if n <= max {
        return Ok(None);
    }
    Ok(Some(tx.sql().execute(
        "delete from event where id in (select id from event \
         where kind not in ('question', 'answer', 'decision') order by id limit ?1)",
        [n - max],
    )?))
}

/// [`events_cap_to`] [`MAX_ROWS`].
pub fn events_cap(tx: &mut WTx<'_>) -> Result<Option<usize>, CoordError> {
    events_cap_to(tx, MAX_ROWS)
}

/// Prune unless it ran in the last 24 hours (then record the time in `kv.event-pruned`), and always hold the log
/// to the cap: whether it pruned (`drgnx-coord-events-prune-daily`, inside the caller's transaction).
pub fn prune_daily_tx(tx: &mut WTx<'_>, now: f64) -> Result<bool, CoordError> {
    let last = super::meta::get_text(tx.sql(), "event-pruned")?;
    // `string-to-number`: text that is not a number reads as 0.
    let last: f64 = last.and_then(|s| s.trim().parse().ok()).unwrap_or(0.0);
    let ran = now - last > DAY;
    if ran {
        events_prune(tx, now)?;
        // `number-to-string` of a float: "100.0", not "100"
        super::meta::put_text(tx, "event-pruned", &format!("{now:?}"))?;
    }
    events_cap(tx)?;
    Ok(ran)
}

/// The hub's periodic tick: [`prune_daily_tx`] in a transaction of its own (by META's author).  Never fails: a busy
/// database waits for the next call, any other error is logged and answers `false`.
pub async fn prune_daily(db: &CoordDb, meta: TxMeta, now: f64) -> bool {
    match db.write(meta, move |tx| prune_daily_tx(tx, now)).await {
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
    use crate::store::tests::{db7, tx_of};

    fn add(tx: &WTx<'_>, at: f64, kind: &str) {
        tx.sql()
            .execute(
                "insert into event (at, kind, summary) values (?1, ?2, 's')",
                (at, kind),
            )
            .unwrap();
    }

    fn count(tx: &WTx<'_>) -> i64 {
        tx.sql()
            .query_row("select count(*) from event", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn prune_keeps_questions_answers_and_decisions() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        add(&tx, 1.0, "edit");
        add(&tx, 1.0, "question");
        add(&tx, 1.0, "answer");
        add(&tx, 1.0, "decision");
        add(&tx, 1e9, "edit");
        assert_eq!(events_prune_before(&mut tx, 100.0).unwrap(), 1);
        assert_eq!(count(&tx), 4);
    }

    #[test]
    fn the_cap_drops_the_oldest_unprotected_first() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        add(&tx, 1.0, "question");
        for i in 0..4 {
            add(&tx, 2.0 + f64::from(i), "edit");
        }
        assert_eq!(events_cap_to(&mut tx, 10).unwrap(), None);
        assert_eq!(events_cap_to(&mut tx, 3).unwrap(), Some(2));
        assert_eq!(count(&tx), 3);
        let kinds: i64 = tx
            .sql()
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
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        assert!(prune_daily_tx(&mut tx, 200_000.0).unwrap());
        assert!(!prune_daily_tx(&mut tx, 200_100.0).unwrap());
        assert!(prune_daily_tx(&mut tx, 300_000.0).unwrap());
    }
}
