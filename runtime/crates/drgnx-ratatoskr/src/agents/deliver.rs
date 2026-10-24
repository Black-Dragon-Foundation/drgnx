//! Delivery, ported from `drgnx-hub--deliver` (free agents only, quoted peer headers, the decision-log notice once
//! per version, the freshness gate on `edit|delete|move|execute`), and take-back: `messages/retract` succeeds only
//! while the message is queued (Task 24).

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::coord::{RetractParams, Retracted};
use runstav::wire::Error;

pub async fn retract(_: &Front, _: &Caller, _: RetractParams) -> Result<Retracted, Error> {
    Err(not_yet("messages/retract", "24"))
}
