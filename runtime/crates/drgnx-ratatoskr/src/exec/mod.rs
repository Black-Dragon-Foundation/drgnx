//! Jobs: the execution layer (`exec/*`; Task 11, container jobs Task 11b, the wake Task 15; `docs/guide/jobs.md`).
//! A job runs in its starter's Gleipnir spec as a unit of its own (a `systemd-run --user` transient unit on Linux,
//! else its own session and process group), its exit and log in `<state>/hub/exec/<id>/`; a hub restart re-attaches
//! it; its end is the `exec-done` event and the starter's wake.
//!
//! - [`unit`]: the transient unit or process group, and re-attaching after a restart.
//! - [`summary`]: cargo test, ERT and domr output read for failing names, at most 20 lines.

pub mod summary;
pub mod unit;

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::exec::{
    ById, ExecRow, Jobs, ListParams, LogParams, LogSlice, StartParams, Started,
};
use runstav::wire::Error;

/// The jobs the hub runs (Task 11 fills it).
#[derive(Default)]
pub struct Runner {}

pub async fn start(_: &Front, _: &Caller, _: StartParams) -> Result<Started, Error> {
    Err(not_yet("exec/start", "11"))
}

pub async fn get(_: &Front, _: &Caller, _: ById) -> Result<ExecRow, Error> {
    Err(not_yet("exec/get", "11"))
}

pub async fn list(_: &Front, _: &Caller, _: ListParams) -> Result<Jobs, Error> {
    Err(not_yet("exec/list", "11"))
}

pub async fn stop(_: &Front, _: &Caller, _: ById) -> Result<ExecRow, Error> {
    Err(not_yet("exec/stop", "11"))
}

pub async fn log(_: &Front, _: &Caller, _: LogParams) -> Result<LogSlice, Error> {
    Err(not_yet("exec/log", "11"))
}
