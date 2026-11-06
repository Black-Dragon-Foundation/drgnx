//! forseti: the scheduler core shared by the drgnx hub, its runners and jobq.
//!
//! Pure: no I/O, no clock and no threads. Time (`u64` seconds since the epoch) and machine state are parameters;
//! sizes are MiB. The shells (the hub's queue, `sleipnir`, jobq's daemons) read the machine, call these functions
//! and carry out what they return. `docs/develop/forseti.md` describes each rule and where its numbers come from.

pub mod admit;
pub mod backfill;
pub mod bisect;
pub mod cachekey;
pub mod classify;
pub mod cost;
pub mod drain;
pub mod evict;
pub mod fair;
pub mod history;
pub mod learn;
pub mod model;
pub mod place;
pub mod priority;
pub mod reserve;
pub mod safety;
pub mod sim;
pub mod split;

#[cfg(test)]
mod testkit;

pub use admit::{Budget, admit, budget, head_protection, oom_rerun, size};
// `backfill::Reservation` stays in its module: at the root it would shadow the two schedulers' `Reservation`.
pub use backfill::{Need, backfill_ok, budget_at, expected_end, reservation};
pub use classify::{ExitEvidence, classify};
pub use drain::{drain_abandon, drain_may_evict_p5, drain_may_start, drain_paused};
pub use evict::{may_evict, preempt_victims};
pub use fair::Drr;
pub use history::{HistRow, expected, history_key};
pub use learn::{Ewma, Learned, Warmth};
pub use model::*;
// `place::Send` stays in its module: at the root, a glob import would shadow the `Send` trait.
pub use place::{
    Accept, Candidate, CloudTerms, FinishEstimate, Pick, PlaceCtx, RunnerState, cloud_counts,
    filter, finish, finish_with, pick, pick_with, trust_ok, why_here,
};
pub use priority::{check_no_cycle, effective_priorities, promote, queue_order};
pub use reserve::{count_others, ladder_actor};
pub use safety::{
    Action, CapOrder, CapWrite, Level, cap_step, cap_target, ladder_actions, ladder_level,
    static_ceiling, throttle_actions,
};
