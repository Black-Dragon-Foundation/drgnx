//! `work/target/set`: the target date of a spec or a plan, written into its data through the writer.

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::wire::{Error, ErrorCode};

/// `work/target/set`: the target date of a spec or plan, written into its data through the writer; null removes it.
/// False when no such live entity.
pub async fn target_set(
    f: &Front,
    _: &Caller,
    p: runstav::methods::work::TargetSetParams,
) -> Result<bool, Error> {
    let id = p.item.as_str().to_owned();
    let at = p.target_at;
    f.writer
        .db
        .write(
            urdr::graph::TxMeta::new("user", urdr::graph::Class::User, "work/target"),
            move |tx| {
                let Some(e) =
                    urdr::graph::entity::by_id(tx.sql(), &id)?.filter(|e| e.retired_tx.is_none())
                else {
                    return Ok(false);
                };
                urdr::graph::entity::update(
                    tx,
                    e.n,
                    None,
                    urdr::graph::entity::Changes {
                        data_patch: Some(serde_json::json!({ "target_at": at })),
                        ..Default::default()
                    },
                )?;
                Ok(true)
            },
        )
        .await
        .map_err(|e| Error {
            code: ErrorCode::Internal,
            message: format!("work/target/set: {e}"),
            path: None,
        })
}
