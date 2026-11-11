//! The evidence writer (orchestration in the hub): one fact a gate reads is an entity of kind `evidence`, id
//! `evidence:<prefix>-<5 base36>`, its status the evidence's kind and its data the whole record
//! (`vordr::evidence::Evidence`).  Only the hub writes it; nothing changes it after.

use crate::store::{CoordError, WTx};
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::guard::{self, Guard, Target};
use urdr::graph::{Class, TxMeta, WriteError};
use vordr::evidence::{Evidence, KINDS};
use vordr::pack::Pack;

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
    let waiver = e.kind == "waiver";
    if waiver && e.note.as_deref().is_none_or(|n| n.trim().is_empty()) {
        return Err(CoordError::Refused("a waiver needs its reason".into()));
    }
    // a waiver's id says it is one, so the guard's rule sees it ([`register`])
    let id = crate::tracker::new_id(tx, if waiver { "waiver" } else { "evidence" }, project)?;
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

/// Only the user waives; the hub records every other kind.
const WAIVERS_ARE_THE_USERS: &str = "only the user waives a gate";
const EVIDENCE_IS_THE_HUBS: &str = "evidence is the hub's own record";

/// The guard's rule for kind `evidence`, a hard rule like the matrix's `always_never`: a waiver (id `waiver:…`) is
/// written only by the user's connection, every other record only by the hub. No cell, preset or manager grant opens
/// it: the guard runs below them, on every write.
fn rule(_: &urdr::Connection, meta: &TxMeta, _: f64, t: Target<'_>) -> Result<(), WriteError> {
    let (class, refusal) = if t.id.starts_with("waiver:") {
        (Class::User, WAIVERS_ARE_THE_USERS)
    } else {
        (Class::System, EVIDENCE_IS_THE_HUBS)
    };
    if meta.class == class {
        Ok(())
    } else {
        Err(WriteError::Refused(refusal.into()))
    }
}

/// The evidence rule in GUARD.
pub fn register(guard: &mut Guard) {
    guard::register_rule(guard, "evidence", rule);
}

/// A followup the gates leave (a red line, a flake): an entity of kind `followup`, status `open`, its DATA what was
/// seen; one open followup per TITLE (a gate that holds again finds the one it made).  Answers its id.
pub fn followup(
    tx: &mut WTx<'_>,
    title: &str,
    data: serde_json::Value,
    project: Option<i64>,
) -> Result<String, CoordError> {
    let open: Option<String> = tx
        .sql()
        .query_row(
            "select id from entity where kind = 'followup' and status = 'open' and retired_tx is null \
             and title = ?1",
            [title],
            |r| r.get(0),
        )
        .ok();
    if let Some(id) = open {
        return Ok(id);
    }
    let id = crate::tracker::new_id(tx, "followup", project)?;
    entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "followup".into(),
            project,
            title: Some(title.to_owned()),
            status: Some("open".into()),
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

/// Record PACK as job JOB's rule pack (`rule_pack`, frozen at the job's approval: the gates read this record, never
/// the plan's file again); answers its id.
pub fn rule_pack(
    tx: &mut WTx<'_>,
    job: &str,
    pack: &Pack,
    project: Option<i64>,
) -> Result<String, CoordError> {
    let id = crate::tracker::new_id(tx, "rule_pack", project)?;
    entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "rule_pack".into(),
            project,
            title: Some(format!("{} v{}", pack.name, pack.version)),
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: serde_json::json!({"job": job, "pack": pack}),
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

    /// A transaction on C written as META, under the store's guard.
    fn tx_as(c: &mut urdr::Connection, meta: TxMeta) -> WTx<'_> {
        let mut guard = urdr::graph::guard::Guard::default();
        crate::grants::register(&mut guard);
        WTx::for_test(c, meta, std::sync::Arc::new(guard))
    }

    #[test]
    fn only_the_user_waives_and_only_the_hub_records_the_rest() {
        let mut c = db7();
        let mut w = ev("waiver", "task:J#1");
        w.job = String::new();
        w.note = Some("a docs change".into());
        // the hub, an agent (a manager is one) and a service cannot waive: a hard rule, no grant opens it
        for (actor, class) in [
            ("hub", Class::System),
            ("agent:m1", Class::Agent),
            ("ext:s1", Class::Agent),
        ] {
            let mut tx = tx_as(&mut c, TxMeta::new(actor, class, "proto:job/card"));
            assert!(record(&mut tx, &w, None).is_err(), "{actor} waived");
        }
        // an agent cannot write the hub's evidence either
        let mut tx = tx_as(&mut c, TxMeta::new("agent:w1", Class::Agent, "mcp:x"));
        assert!(record(&mut tx, &ev("green", "task:J#1"), None).is_err());
        drop(tx);
        // the user waives with a reason, never without one
        let mut tx = tx_as(&mut c, TxMeta::new("user", Class::User, "proto:job/card"));
        let mut bare = w.clone();
        bare.note = None;
        assert!(record(&mut tx, &bare, None).is_err());
        let id = record(&mut tx, &w, None).unwrap();
        assert!(id.starts_with("waiver:"), "{id}");
        assert_eq!(
            crate::read::evidence::of_task(tx.sql(), "task:J#1").unwrap(),
            vec![w.clone()]
        );
        // and the user's connection records no other kind
        assert!(record(&mut tx, &ev("green", "task:J#1"), None).is_err());
    }

    #[test]
    fn a_held_gate_leaves_one_open_followup_per_title() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let a = followup(
            &mut tx,
            "flaky: a::t",
            serde_json::json!({"rows": ["a::t"]}),
            None,
        )
        .unwrap();
        assert!(a.starts_with("followup:"), "{a}");
        assert_eq!(
            followup(&mut tx, "flaky: a::t", serde_json::json!({}), None).unwrap(),
            a
        );
        assert_ne!(
            followup(&mut tx, "flaky: b::u", serde_json::json!({}), None).unwrap(),
            a
        );
    }

    #[test]
    fn a_jobs_rule_pack_is_recorded_and_read_back() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let p = Pack {
            name: "p".into(),
            version: 2,
            batch_size: 3,
            ..Pack::default()
        };
        assert!(
            rule_pack(&mut tx, "J", &p, None)
                .unwrap()
                .starts_with("rule_pack:")
        );
        assert_eq!(
            crate::read::evidence::pack_of_job(tx.sql(), "J").unwrap(),
            Some(p)
        );
        assert_eq!(
            crate::read::evidence::pack_of_job(tx.sql(), "K").unwrap(),
            None
        );
    }
}
