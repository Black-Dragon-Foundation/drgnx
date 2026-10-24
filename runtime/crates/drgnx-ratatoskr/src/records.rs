//! Records (Tasks 14, 14b; `docs/develop/records.md`): the importer (a backup of every file first, then `saga`'s
//! graph operations with `Origin::Imported`) and the views — written atomically at the imported file's path after
//! every change of the records they show (debounced 2 s), never committed, never over a hand edit: a changed view
//! becomes a proposal (`records/proposals`, `records/decide`) and is not rewritten while one is open.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::records::{
    ByPath, DecideParams, Decided, ImportParams, ImportReport, Proposals, Views as ViewsAnswer,
};
use runstav::wire::Error;

/// The views written and their hashes, the open proposals (Tasks 14, 14b fill it).
#[derive(Default)]
pub struct Views {}

pub async fn import(_: &Front, _: &Caller, _: ImportParams) -> Result<ImportReport, Error> {
    Err(not_yet("records/import", "14"))
}

pub async fn status(_: &Front, _: &Caller, _: ByPath) -> Result<ViewsAnswer, Error> {
    Err(not_yet("records/status", "14"))
}

pub async fn proposals(_: &Front, _: &Caller, _: ByPath) -> Result<Proposals, Error> {
    Err(not_yet("records/proposals", "14b"))
}

pub async fn decide(_: &Front, _: &Caller, _: DecideParams) -> Result<Decided, Error> {
    Err(not_yet("records/decide", "14b"))
}
