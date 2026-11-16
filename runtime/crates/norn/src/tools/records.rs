//! The record-conflict tools: `record_conflict_read` (a conflicted record's file text and graph version) and
//! `record_conflict_resolve` (keep one, under the matrix's `graph.change`), in `runstav::methods::records`'s shapes.
//! The hub does the work ([`super::Hub::proposal`]).

use mimir::BoxFuture;
use mimir::Tool;
use runstav::methods::exec::ById;
use runstav::methods::records::{Keep, ResolveParams};

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

fn session(who: &Identity) -> Option<String> {
    match who {
        Identity::Session { sid, .. } => Some(sid.clone()),
        _ => None,
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

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ConflictRead), guarded(ConflictResolve)]
}
