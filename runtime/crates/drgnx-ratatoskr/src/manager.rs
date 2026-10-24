//! The manager role (Task 25; `docs/guide/agents.md`, "A manager agent"): `agents/role` (the user's only), the
//! manager tools on its socket only, each through the matrix with the manager's column (`agent_start` delegates
//! grants that only narrow its own; one level), `agents/slice` (never a whole transcript), the digest of graph
//! changes that wakes it (debounced 30 s, at most 4 KiB) and its rotation past 70 % of its context.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::agents::{RoleParams, Slice, SliceParams};
use runstav::wire::Error;

/// The manager sessions and their digests (Task 25 fills it).
#[derive(Default)]
pub struct Managers {}

pub async fn role(_: &Front, _: &Caller, _: RoleParams) -> Result<bool, Error> {
    Err(not_yet("agents/role", "25"))
}

pub async fn slice(_: &Front, _: &Caller, _: SliceParams) -> Result<Slice, Error> {
    Err(not_yet("agents/slice", "25"))
}
