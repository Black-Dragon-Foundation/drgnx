//! The view-proposal tools (agent system part 1, Task 14b): `proposal_read` (a hand edit's diff and graph ops) and
//! `proposal_decide` (accept or reject, under the matrix's `graph.change`; a user-only field is never a manager's to
//! accept), in `runstav::methods::records`'s shapes.

use mimir::Tool;
use runstav::methods::exec::ById;
use runstav::methods::records::DecideParams;

use super::guard::guarded;
use super::{Ctx, stub_tool};

stub_tool!(
    ProposalRead,
    "proposal_read",
    ById,
    "14b",
    "A hand edit to a record view: its diff and the graph operations it would apply."
);
stub_tool!(
    ProposalDecide,
    "proposal_decide",
    DecideParams,
    "14b",
    "Accept or reject a view proposal (needs the matrix's graph.change)."
);

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ProposalRead), guarded(ProposalDecide)]
}
