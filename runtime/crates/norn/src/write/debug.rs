//! The debug run writer (graphical debugging spec §19.2, D1): a recorded run is an entity of kind `debug_run`, id
//! `debug_run:<run>`, its status `recording` or `ended`, its title the configuration's name and its data the run's
//! record (the hub's `debug::record::RunMeta`: the configuration's hash, the launch snapshot, git HEAD, the outcome,
//! the counts, the task). The run's bulk (stops, probe hits) stays in its run file; only the hub writes this.

use crate::store::{CoordError, WTx};
use serde_json::Value;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};

/// The entity id of run RUN.
pub fn id_of(run: &str) -> String {
    format!("debug_run:{run}")
}

/// Record run RUN (DATA, its record; ENDED: it has ended) under TITLE in PROJECT: created at its start, its data and
/// status replaced after.
pub fn put(
    tx: &mut WTx<'_>,
    run: &str,
    title: &str,
    ended: bool,
    data: Value,
    project: Option<i64>,
) -> Result<String, CoordError> {
    let id = id_of(run);
    let status = if ended { "ended" } else { "recording" };
    match entity::by_id(tx.sql(), &id)?.filter(|e| e.retired_tx.is_none()) {
        Some(e) => {
            entity::update(
                tx,
                e.n,
                None,
                Changes {
                    status: Some(Some(status.into())),
                    data_patch: Some(data),
                    ..Changes::default()
                },
            )?;
        }
        None => {
            entity::create(
                tx,
                EntityNew {
                    id: id.clone(),
                    kind: "debug_run".into(),
                    project,
                    title: Some(title.to_owned()),
                    status: Some(status.into()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data,
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
        }
    }
    Ok(id)
}

/// Run RUN's record retired (its file was removed with the retention).
pub fn gone(tx: &mut WTx<'_>, run: &str) -> Result<(), CoordError> {
    if let Some(e) = entity::by_id(tx.sql(), &id_of(run))?.filter(|e| e.retired_tx.is_none()) {
        entity::retire(tx, e.n)?;
    }
    Ok(())
}

/// The states a hypothesis is in.
pub const HYPOTHESIS_STATES: [&str; 3] = ["open", "confirmed", "rejected"];

/// A partner agent's hypothesis (spec §19.5, D4): entity `debug_hypothesis:<id>`, its title TITLE, its status STATE
/// (`open`, `confirmed`, `rejected`) and its data `{root, agent, evidence}` (EVIDENCE: what it rests on, "run R stop
/// N", "fork F").  Created by session AGENT, and changed afterwards only by it.  The record's id, and its data.
#[allow(clippy::too_many_arguments)]
pub fn hypothesis(
    tx: &mut WTx<'_>,
    id: &str,
    agent: &str,
    root: &str,
    title: &str,
    state: &str,
    evidence: &[String],
    project: Option<i64>,
) -> Result<String, CoordError> {
    if !HYPOTHESIS_STATES.contains(&state) {
        return Err(CoordError::Refused(format!(
            "a hypothesis is open, confirmed or rejected, not {state}"
        )));
    }
    let eid = format!("debug_hypothesis:{id}");
    let data = serde_json::json!({"root": root, "agent": agent, "evidence": evidence});
    match entity::by_id(tx.sql(), &eid)?.filter(|e| e.retired_tx.is_none()) {
        Some(e) => {
            if e.data.get("agent").and_then(Value::as_str) != Some(agent) {
                return Err(CoordError::Refused(format!(
                    "hypothesis {id} is another agent's"
                )));
            }
            entity::update(
                tx,
                e.n,
                None,
                Changes {
                    title: Some(Some(title.to_owned())),
                    status: Some(Some(state.to_owned())),
                    data_patch: Some(data),
                    ..Changes::default()
                },
            )?;
        }
        None => {
            entity::create(
                tx,
                EntityNew {
                    id: eid.clone(),
                    kind: "debug_hypothesis".into(),
                    project,
                    title: Some(title.to_owned()),
                    status: Some(state.to_owned()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data,
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
        }
    }
    Ok(eid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use serde_json::json;

    #[test]
    fn a_run_is_recorded_then_ended_then_retired() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = put(
            &mut tx,
            "r1-1",
            "Python: stock",
            false,
            json!({"stops": 0}),
            None,
        )
        .unwrap();
        assert_eq!(id, "debug_run:r1-1");
        put(
            &mut tx,
            "r1-1",
            "Python: stock",
            true,
            json!({"stops": 3, "outcome": "exited"}),
            None,
        )
        .unwrap();
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(
            (
                e.kind.as_str(),
                e.status.as_deref(),
                &e.data["stops"],
                &e.data["outcome"]
            ),
            ("debug_run", Some("ended"), &json!(3), &json!("exited"))
        );
        gone(&mut tx, "r1-1").unwrap();
        assert!(
            entity::by_id(tx.sql(), &id)
                .unwrap()
                .unwrap()
                .retired_tx
                .is_some()
        );
        // gone twice: nothing to do
        gone(&mut tx, "r1-1").unwrap();
    }

    #[test]
    fn a_hypothesis_is_recorded_changed_by_its_agent_only() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let ev = vec!["run r1 stop 4".to_owned()];
        let id = hypothesis(
            &mut tx,
            "h1",
            "s1",
            "/p",
            "reserve goes negative",
            "open",
            &ev,
            None,
        )
        .unwrap();
        assert_eq!(id, "debug_hypothesis:h1");
        hypothesis(
            &mut tx,
            "h1",
            "s1",
            "/p",
            "reserve goes negative",
            "confirmed",
            &["fork f2".to_owned()],
            None,
        )
        .unwrap();
        let e = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(
            (
                e.kind.as_str(),
                e.status.as_deref(),
                &e.data["agent"],
                &e.data["evidence"]
            ),
            (
                "debug_hypothesis",
                Some("confirmed"),
                &json!("s1"),
                &json!(["fork f2"])
            )
        );
        // another agent's, and a state that is none of the three, are refused
        let e = hypothesis(&mut tx, "h1", "s2", "/p", "x", "rejected", &[], None).unwrap_err();
        assert!(e.to_string().contains("another agent's"), "{e}");
        let e = hypothesis(&mut tx, "h2", "s1", "/p", "x", "maybe", &[], None).unwrap_err();
        assert!(e.to_string().contains("not maybe"), "{e}");
    }
}
