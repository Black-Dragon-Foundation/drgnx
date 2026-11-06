//! Notes the hub changes after the fact: a finding whose step was reverted is withdrawn, so the map stops showing it as
//! live.  A note with no status is live.

use super::event::{Event, EventKind, event};
use super::meta;
use crate::store::{CoordError, WTx};
use serde_json::json;
use urdr::graph::entity::{self, Changes};

/// Withdraw note ID (a finding): its status becomes `withdrawn`, the decision log's version moves (so every reader is
/// held at its next write) and one event says so.  False when there is no such note or it is withdrawn already.
pub fn withdraw(
    tx: &mut WTx<'_>,
    id: &str,
    reason: &str,
    by: &str,
    now: f64,
) -> Result<bool, CoordError> {
    let Some(e) =
        entity::by_id(tx.sql(), id)?.filter(|e| e.kind == "note" && e.retired_tx.is_none())
    else {
        return Ok(false);
    };
    if e.status.as_deref() == Some("withdrawn") {
        return Ok(false);
    }
    let v = meta::bump_version(tx)?;
    entity::update(
        tx,
        e.n,
        None,
        Changes {
            status: Some(Some("withdrawn".into())),
            data_patch: Some(json!({
                "withdrawn_by": by,
                "withdrawn_reason": reason,
                "withdrawn_at": now,
            })),
            ..Changes::default()
        },
    )?;
    event(
        tx,
        Event {
            at: now,
            agent: Some(by.to_owned()),
            job: None,
            task: None,
            kind: EventKind::Decision,
            summary: format!("{id} withdrawn: {reason}"),
            data: Some(json!({"id": id, "status": "withdrawn", "version": v})),
            turn: false,
        },
    )?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use crate::write::decisions::held_check;
    use urdr::graph::entity::{EntityNew, Origin};

    fn finding(tx: &mut crate::store::WTx<'_>, id: &str) {
        let project = tx.meta().project;
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "note".into(),
                project,
                title: Some("t".into()),
                status: None,
                body: Some("b".into()),
                priority: None,
                assignee: None,
                data: json!({"kind": "finding"}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
    }

    // pattern: D
    #[test]
    fn withdraw_reaches_findings() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        finding(&mut tx, "note:1");
        assert!(withdraw(&mut tx, "note:1", "its step was reverted", "user", 2.0).unwrap());
        let e = entity::by_id(tx.sql(), "note:1").unwrap().unwrap();
        assert_eq!(e.status.as_deref(), Some("withdrawn"));
        // the version moved: a reader at version 0 is held
        assert_eq!(meta::version(tx.sql()).unwrap(), 1);
        assert!(held_check(tx.sql(), Some(0)).unwrap().is_some());
        // twice is false; a note nothing has is false
        assert!(!withdraw(&mut tx, "note:1", "r", "user", 3.0).unwrap());
        assert!(!withdraw(&mut tx, "note:9", "r", "user", 3.0).unwrap());
    }
}
