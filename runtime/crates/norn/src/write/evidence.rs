//! The evidence writer (orchestration in the hub): one fact a gate reads is an entity of kind `evidence`, id
//! `evidence:<prefix>-<5 base36>`, its status the evidence's kind and its data the whole record
//! (`vordr::evidence::Evidence`).  Only the hub writes it; nothing changes it after.

use crate::store::{CoordError, WTx};
use urdr::graph::entity::{self, EntityNew, Origin};
use vordr::evidence::{Evidence, KINDS};

/// Record E (in PROJECT); answers its id.  An unknown kind, or no task, is refused.
pub fn record(tx: &mut WTx<'_>, e: &Evidence, project: Option<i64>) -> Result<String, CoordError> {
    if !KINDS.contains(&e.kind.as_str()) {
        return Err(CoordError::Refused(format!(
            "{} is not an evidence kind ({})",
            e.kind,
            KINDS.join(", ")
        )));
    }
    if e.task.is_empty() {
        return Err(CoordError::Refused("evidence needs its task".into()));
    }
    let id = crate::tracker::new_id(tx, "evidence", project)?;
    let data = serde_json::to_value(e).map_err(|err| CoordError::Refused(err.to_string()))?;
    entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "evidence".into(),
            project,
            title: Some(format!("{} {}", e.kind, e.task)),
            status: Some(e.kind.clone()),
            body: None,
            priority: None,
            assignee: None,
            data,
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use vordr::facts::Facts;

    fn ev(kind: &str, task: &str) -> Evidence {
        Evidence {
            kind: kind.into(),
            task: task.into(),
            job: "x1".into(),
            facts: Facts {
                tree_key: "t".into(),
                env_stamp: "e".into(),
                platform: "p".into(),
                selector: "s".into(),
            },
            rows: vordr::rows::parse("test a ... FAILED\n"),
            truncated: false,
            at: 12.5,
            note: None,
        }
    }

    #[test]
    fn evidence_is_recorded_and_read_back_by_task() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = record(&mut tx, &ev("red", "task:J#1"), None).unwrap();
        assert!(id.starts_with("evidence:"));
        record(&mut tx, &ev("green", "task:J#1"), None).unwrap();
        record(&mut tx, &ev("green", "task:J#2"), None).unwrap();
        let back = crate::read::evidence::of_task(tx.sql(), "task:J#1").unwrap();
        assert_eq!(back, vec![ev("red", "task:J#1"), ev("green", "task:J#1")]);
        assert!(record(&mut tx, &ev("maybe", "task:J#1"), None).is_err());
        assert!(record(&mut tx, &ev("red", ""), None).is_err());
    }
}
