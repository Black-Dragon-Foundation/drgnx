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
}
