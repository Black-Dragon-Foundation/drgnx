//! Plans in the graph and what decisions did (Task 21): `plans/get`, `plans/write` (under `graph.change` for an
//! agent's `plan_write`), `reports/get`, and `decisions/effects` (a decision's commits and the later hunks that
//! overlap its lines, computed from git and labelled `computed`); commits linked to the decisions their session
//! recorded since the branch's previous commit.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::plans::{
    ByPlan, Effects, EffectsParams, PlanView, PlanWritten, Reports, ReportsParams, WriteParams,
};
use runstav::wire::Error;

pub async fn plans_get(_: &Front, _: &Caller, _: ByPlan) -> Result<PlanView, Error> {
    Err(not_yet("plans/get", "21"))
}

pub async fn plans_write(_: &Front, _: &Caller, _: WriteParams) -> Result<PlanWritten, Error> {
    Err(not_yet("plans/write", "21"))
}

pub async fn reports_get(_: &Front, _: &Caller, _: ReportsParams) -> Result<Reports, Error> {
    Err(not_yet("reports/get", "21"))
}

pub async fn decision_effects(_: &Front, _: &Caller, _: EffectsParams) -> Result<Effects, Error> {
    Err(not_yet("decisions/effects", "21"))
}
