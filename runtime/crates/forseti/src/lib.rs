//! forseti: the scheduler core shared by the drgnx hub, its runners and jobq.
//!
//! Pure: no I/O, no clock and no threads. Time (`u64` seconds since the epoch) and machine state are parameters;
//! sizes are MiB. The shells (the hub's queue, `sleipnir`, jobq's daemons) read the machine, call these functions
//! and carry out what they return. `docs/develop/forseti.md` describes each rule and where its numbers come from.

pub mod admit;
pub mod classify;
pub mod drain;
pub mod evict;
pub mod history;
pub mod model;
pub mod priority;
pub mod reserve;
pub mod safety;

#[cfg(test)]
mod testkit;

pub use admit::{Budget, admit, budget, head_protection, oom_rerun, size};
pub use classify::{ExitEvidence, classify};
pub use drain::{drain_abandon, drain_may_evict_p5, drain_may_start, drain_paused};
pub use evict::{may_evict, preempt_victims};
pub use history::{HistRow, expected, history_key};
pub use model::*;
pub use priority::{check_no_cycle, effective_priorities, promote, queue_order};
pub use reserve::{count_others, ladder_actor};
pub use safety::{
    Action, CapOrder, CapWrite, Level, cap_step, cap_target, ladder_actions, ladder_level,
    static_ceiling, throttle_actions,
};
