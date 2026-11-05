//! forseti: the scheduler core shared by the drgnx hub, its runners and jobq.
//!
//! Pure: no I/O, no clock and no threads. Time (`u64` seconds since the epoch) and machine state are parameters;
//! sizes are MiB. The shells (the hub's queue, `sleipnir`, jobq's daemons) read the machine, call these functions
//! and carry out what they return. `docs/develop/forseti.md` describes each rule and where its numbers come from.

pub mod model;
pub mod priority;
pub mod reserve;

#[cfg(test)]
mod testkit;

pub use model::*;
pub use priority::{check_no_cycle, effective_priorities, promote, queue_order};
