//! The permissions matrix in the hub (Task 12; `docs/guide/security.md`, "The permissions matrix"): every action an
//! agent takes is checked (`MatrixGate::check(who, action, ctx) -> Gate`) against `norn::matrix`'s effective cells
//! for its columns, with the `agents-matrix` setting, the project's and the plan's overrides and the away signal;
//! an Ask makes one `matrix` card from facts the hub derived; it is re-checked when it executes; a manager's grants
//! to its workers only narrow its own (`delegate`).  Methods `matrix/get`, `matrix/check`, `presence/set`.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::matrix::{CheckAnswer, CheckParams, GetParams, MatrixView, PresenceParams};
use runstav::wire::Error;

/// What the gate decides for one action: allowed, asked through a card (its id), or refused (why).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Gate {
    Allow,
    Ask(i64),
    Never(String),
}

/// The gate's state: the away flag, the matrix as last read (Task 12 fills it).
#[derive(Default)]
pub struct MatrixGate {}

pub async fn get(_: &Front, _: &Caller, _: GetParams) -> Result<MatrixView, Error> {
    Err(not_yet("matrix/get", "12"))
}

pub async fn check_method(_: &Front, _: &Caller, _: CheckParams) -> Result<CheckAnswer, Error> {
    Err(not_yet("matrix/check", "12"))
}

pub async fn presence(_: &Front, _: &Caller, _: PresenceParams) -> Result<bool, Error> {
    Err(not_yet("presence/set", "12"))
}
