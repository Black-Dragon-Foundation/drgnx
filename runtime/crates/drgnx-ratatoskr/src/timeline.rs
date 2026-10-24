//! The timeline (Task 19; `docs/develop/hub.md`, "The timeline"): every step of every session classified from the
//! hub's stamps (`think`, `tool`, `user-wait`, `job-wait`, `machine-queue`, `paused`, `stalled`), written to the
//! `step` table with its anchors (message id, turn id, decision log version, step snapshot: a tree in the worktree's
//! shadow repository, `refs/drgnx/s/<sid>/<seq>`), the `agent-step` event, and `timeline/get`.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::timeline::{Timeline as TimelineAnswer, TimelineParams};
use runstav::wire::Error;

/// The step classifier's state per session (Task 19 fills it).
#[derive(Default)]
pub struct Timeline {}

pub async fn get(_: &Front, _: &Caller, _: TimelineParams) -> Result<TimelineAnswer, Error> {
    Err(not_yet("timeline/get", "19"))
}
