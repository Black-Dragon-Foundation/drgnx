//! The Always ledger (agent system part 3): `always:<session>:<key>`, one record for each "Always" the user gave a
//! session on a permission request, whose data is the grant as `agents/grants` answers it.  Only the hub writes them,
//! as `("hub", Class::System)`; an agent, a user connection or the scan never does.

use crate::store::{CoordError, WTx};
use serde_json::Value;
use urdr::graph::guard::{self, Guard};
use urdr::graph::tx::Class;

/// The refusal text for a write of an Always record by anyone else.
pub const HUB_ONLY: &str = "always records are the hub's";

/// Put the class rule of `always` into GUARD: only a system-class author writes it.
pub fn register(guard: &mut Guard) {
    guard::register(guard, "always", Class::System, HUB_ONLY);
}

/// Make the record `always:NAME` (SESSION:KEY) with DATA, or replace its data; answers its id.  Only the hub writes it.
pub fn put(tx: &mut WTx<'_>, name: &str, data: Value) -> Result<String, CoordError> {
    let m = tx.meta();
    if !(m.class == Class::System && m.actor == "hub") {
        return Err(CoordError::Refused(HUB_ONLY.into()));
    }
    super::runners::put_record(tx, "always", name, data)
}
