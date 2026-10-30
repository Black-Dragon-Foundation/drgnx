//! The view-proposal tools (agent system part 1, Task 14b): `proposal_read` (a hand edit's diff and graph ops) and
//! `proposal_decide` (accept or reject, under the matrix's `graph.change`; a user-only field is never a manager's to
//! accept), in `runstav::methods::records`'s shapes.  The hub does the work ([`super::Hub::proposal`]).

use mimir::BoxFuture;
use mimir::Tool;
use runstav::methods::exec::ById;
use runstav::methods::records::DecideParams;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

fn session(who: &Identity) -> Option<String> {
    match who {
        Identity::Session { sid, .. } => Some(sid.clone()),
        _ => None,
    }
}

pub struct ProposalRead;

impl CoordTool for ProposalRead {
    type Args = ById;
    const NAME: &'static str = "proposal_read";
    const DESCRIPTION: &'static str =
        "A hand edit to a record view: its diff and the graph operations it would apply.";
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

pub struct ProposalDecide;

impl CoordTool for ProposalDecide {
    type Args = DecideParams;
    const NAME: &'static str = "proposal_decide";
    const DESCRIPTION: &'static str =
        "Accept or reject a view proposal (needs the matrix's graph.change).";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: DecideParams,
    ) -> BoxFuture<'a, Result<String, String>> {
        coord
            .hub()
            .proposal(args.id.as_str().to_owned(), Some(args.accept), session(who))
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ProposalRead), guarded(ProposalDecide)]
}
