//! The huddle records (agent system part 3; docs/develop/coordination.md, "Huddles"): `huddle:<id>`, whose data is
//! the huddle as `agents/huddle/get` answers it.  Only the hub writes them, as `("hub", Class::System)`; an agent, a
//! user connection or the scan never does.

use crate::store::{CoordError, Tx, WTx};
use serde_json::Value;
use urdr::graph::guard::{self, Guard};
use urdr::graph::tx::Class;

/// The refusal text for a write of a huddle record by anyone else.
pub const HUB_ONLY: &str = "huddle records are the hub's";

/// Put the class rule of `huddle` into GUARD: only a system-class author writes it.
pub fn register(guard: &mut Guard) {
    guard::register(guard, "huddle", Class::System, HUB_ONLY);
}

/// Make the record `huddle:ID` with DATA, or replace its data; answers its id.  Only the hub writes it.
pub fn put(tx: &mut WTx<'_>, id: &str, data: Value) -> Result<String, CoordError> {
    let m = tx.meta();
    if !(m.class == Class::System && m.actor == "hub") {
        return Err(CoordError::Refused(HUB_ONLY.into()));
    }
    super::runners::put_record(tx, "huddle", id, data)
}

/// The data of the record `huddle:ID`, if there is one.
pub fn get(conn: &Tx, id: &str) -> Result<Option<Value>, CoordError> {
    Ok(urdr::graph::entity::by_id(conn, &format!("huddle:{id}"))?
        .filter(|e| e.retired_tx.is_none())
        .map(|e| e.data))
}
