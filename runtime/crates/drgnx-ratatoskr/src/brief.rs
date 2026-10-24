//! Briefs (Task 22; `docs/guide/agents.md`, "Briefs"): `brief::build(task) -> Brief` from the graph — the plan's
//! section for the task (by its heading, through `saga`), the project's AGENTS.md, the matrix as it applies, the
//! base branch, earlier tasks' reported interfaces, the check, the view path — capped at 16 KiB; an edited brief (a
//! `brief` note, `brief/set`) wins at dispatch.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::plans::{Brief, BriefSet, BriefSetParams, ByTask};
use runstav::wire::Error;

/// Task 22 fills it.
#[derive(Default)]
pub struct Briefs {}

pub async fn build_method(_: &Front, _: &Caller, _: ByTask) -> Result<Brief, Error> {
    Err(not_yet("brief/build", "22"))
}

pub async fn set(_: &Front, _: &Caller, _: BriefSetParams) -> Result<BriefSet, Error> {
    Err(not_yet("brief/set", "22"))
}
