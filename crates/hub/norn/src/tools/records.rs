//! The record tools: `records_read` (a spec or decision record by section, with its version) and `records_write`
//! (create one, or change its sections, title and status, under the matrix's `graph.change`), done by the hub's
//! `records/read` and `records/write` as the caller; and the record-conflict tools, `record_conflict_read` (a
//! conflicted record's file text and graph version) and `record_conflict_resolve` (keep one, under the matrix's
//! `graph.change`), in `runstav::methods::records`'s shapes ([`super::Hub::proposal`]).

use mimir::BoxFuture;
use mimir::Tool;
use runstav::methods::exec::ById;
use runstav::methods::records::{Keep, RecordRead, RecordWrite, ResolveParams};

use super::guard::{CoordTool, guarded};
use super::plan::actor;
use super::{Coord, Ctx, Identity};

fn session(who: &Identity) -> Option<String> {
    match who {
        Identity::Session { sid, .. } => Some(sid.clone()),
        _ => None,
    }
}

pub struct RecordsRead;

impl CoordTool for RecordsRead {
    type Args = RecordRead;
    const NAME: &'static str = "records_read";
    const DESCRIPTION: &'static str = "A spec or decision record by section: each section's key and text, and the record's version.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: RecordRead,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let sid = actor(who, Self::NAME)?;
            let p = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            Ok(coord.hub().exec(sid, "records/read", p).await?.to_string())
        })
    }
}

pub struct RecordsWrite;

impl CoordTool for RecordsWrite {
    type Args = RecordWrite;
    const NAME: &'static str = "records_write";
    const DESCRIPTION: &'static str = "Create a spec or decision record, or change its sections, title or status (needs the matrix's graph.change).";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: RecordWrite,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let sid = actor(who, Self::NAME)?;
            let p = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            Ok(coord.hub().exec(sid, "records/write", p).await?.to_string())
        })
    }
}

pub struct ConflictRead;

impl CoordTool for ConflictRead {
    type Args = ById;
    const NAME: &'static str = "record_conflict_read";
    const DESCRIPTION: &'static str =
        "A record both its file and the graph changed: the file's text and the graph's version.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ById,
    ) -> BoxFuture<'a, Result<String, String>> {
        coord
            .hub()
            .proposal(args.id.as_str().to_owned(), None, session(who))
    }
}

pub struct ConflictResolve;

impl CoordTool for ConflictResolve {
    type Args = ResolveParams;
    const NAME: &'static str = "record_conflict_resolve";
    const DESCRIPTION: &'static str = "Resolve a conflicted record: keep the file's text or the graph's version (needs the matrix's graph.change).";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ResolveParams,
    ) -> BoxFuture<'a, Result<String, String>> {
        coord.hub().proposal(
            args.id.as_str().to_owned(),
            Some(args.keep == Keep::File),
            session(who),
        )
    }
}

/// This file's tools: the conflict tools, then `records_read` and `records_write` (the order of
/// [`super::CORE_TOOLS`]).
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![
        guarded(ConflictRead),
        guarded(ConflictResolve),
        guarded(RecordsRead),
        guarded(RecordsWrite),
    ]
}

/// `records_read` and `records_write`, which every session gets.
pub fn rw_tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(RecordsRead), guarded(RecordsWrite)]
}

/// The tools of [`super::OUTSIDE_TOOLS`], in that order: what a bound outside agent gets on top of [`super::tools`].
pub fn outside_tools() -> Vec<Box<dyn Tool<Ctx>>> {
    let mut all = super::plan::tools();
    all.extend(rw_tools());
    all
}
